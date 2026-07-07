import Darwin
import Foundation

/// The install ledger (DESIGN.md §11.1).
///
/// A flat, ordered list of actions, each carrying its captured parameters
/// and a state. Install iterates forward, fail-fast, persisting the ledger
/// after every state transition — including on failure — so a half-applied
/// install is always reversible. Uninstall replays the ledger in reverse,
/// best-effort: revert errors are collected, never fatal mid-walk.
///
/// The ledger is ours alone: it lives at /var/db/nix/install-ledger.json
/// (outside /nix, so it survives volume deletion mid-uninstall), carries a
/// format magic the parser requires, and is guarded by an flock shared by
/// install, uninstall, and the self-heal repair daemon.

enum ActionState: String, Codable {
    /// Not applied (yet, or anymore). Skipped by uninstall.
    case uncompleted
    /// Applied by us. Reverted by uninstall.
    case completed
    /// Detected as already true at plan time. Never reverted.
    case skipped
}

struct LedgerEntry: Codable {
    var action: Action
    var state: ActionState
}

struct Ledger: Codable {
    static let expectedFormat = "org.nixos.nix.install-ledger"
    static let expectedVersion = 1

    var format: String
    var version: Int
    var createdAt: Date
    var actions: [LedgerEntry]

    init(plan: [Action]) {
        format = Self.expectedFormat
        version = Self.expectedVersion
        createdAt = Date()
        actions = plan.map { LedgerEntry(action: $0, state: .uncompleted) }
    }
}

enum LedgerError: Error, CustomStringConvertible {
    case foreignLedger(path: String, format: String)
    case unsupportedVersion(Int)
    case missingLedger(path: String)
    case revertFailures([String])
    case mustBeRoot

    var description: String {
        switch self {
        case .foreignLedger(let path, let format):
            return "refusing to touch '\(path)': its format is '\(format)', "
                + "not '\(Ledger.expectedFormat)' — it was not written by this installer"
        case .unsupportedVersion(let v):
            return "ledger version \(v) is newer than this installer understands "
                + "(max \(Ledger.expectedVersion)); upgrade the installer"
        case .missingLedger(let path):
            return "no install ledger at '\(path)' — nothing to uninstall"
        case .revertFailures(let failures):
            return "uninstall finished with \(failures.count) failure(s); "
                + "the ledger records what remains:\n  "
                + failures.joined(separator: "\n  ")
        case .mustBeRoot:
            return "this command modifies the system and must run as root"
        }
    }
}

/// Loads, saves (atomically), and locks the ledger file.
struct LedgerStore {
    let fileURL: URL
    let lockURL: URL

    init(root: URL) {
        let dir = root.appendingPathComponent("var/db/nix", isDirectory: true)
        fileURL = dir.appendingPathComponent("install-ledger.json")
        lockURL = dir.appendingPathComponent("install-ledger.lock")
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    func load() throws -> Ledger {
        let data = try Data(contentsOf: fileURL)
        // Probe the magic before trusting the rest of the shape: nothing we
        // did not write is ever replayed (§11.1).
        struct Probe: Codable {
            var format: String?
            var version: Int?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let probe = (try? decoder.decode(Probe.self, from: data)) ?? Probe()
        guard probe.format == Ledger.expectedFormat else {
            throw LedgerError.foreignLedger(path: fileURL.path, format: probe.format ?? "(none)")
        }
        guard let version = probe.version, version <= Ledger.expectedVersion else {
            throw LedgerError.unsupportedVersion(probe.version ?? -1)
        }
        return try decoder.decode(Ledger.self, from: data)
    }

    /// Atomic: write a temp sibling, then rename over the destination.
    func save(_ ledger: Ledger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ledger)

        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".install-ledger.json.tmp")
        try data.write(to: tmp)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: tmp.path)
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: lockURL)
    }

    /// Single-writer discipline: install, uninstall, and the self-heal
    /// repair daemon all take this lock — repair racing an uninstall would
    /// otherwise be corruption by design (§11.1).
    func withLock<T>(_ body: () throws -> T) throws -> T {
        let dir = lockURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Executes plans against a ledger.
struct Engine {
    var store: LedgerStore
    var ctx: Context

    private func saveUnlessDry(_ ledger: Ledger) throws {
        if !ctx.dryRun {
            try store.save(ledger)
        }
    }

    /// Forward, fail-fast, persist-always. Re-running resumes: entries that
    /// are already `completed`/`skipped` are left alone.
    func install(plan: [Action]) throws {
        try store.withLock {
            var ledger: Ledger
            if store.exists {
                ledger = try store.load() // throws on foreign ledgers
            } else {
                ledger = Ledger(plan: plan)
                try saveUnlessDry(ledger)
            }
            for i in ledger.actions.indices {
                let entry = ledger.actions[i]
                guard entry.state == .uncompleted else {
                    ctx.log("already \(entry.state.rawValue): \(entry.action.summary)")
                    continue
                }
                if try entry.action.isAlreadyDone(ctx) {
                    ctx.log("skipped (already true): \(entry.action.summary)")
                    ledger.actions[i].state = .skipped
                    try saveUnlessDry(ledger)
                    continue
                }
                ctx.log("applying: \(entry.action.summary)")
                do {
                    if !ctx.dryRun {
                        var action = entry.action
                        try action.apply(ctx)
                        // Actions capture discovered state (disk, UUID) in
                        // apply; the ledger must record it for revert.
                        ledger.actions[i].action = action
                    }
                    ledger.actions[i].state = .completed
                    try saveUnlessDry(ledger)
                } catch {
                    // Persist how far we got; the ledger stays replayable.
                    try? saveUnlessDry(ledger)
                    throw error
                }
            }
        }
    }

    /// Reverse, best-effort. One failed revert never strands the rest;
    /// failures are collected and the ledger records what remains. The
    /// ledger itself is removed only after a fully clean uninstall.
    func uninstall() throws {
        try store.withLock {
            guard store.exists else {
                throw LedgerError.missingLedger(path: store.fileURL.path)
            }
            var ledger = try store.load()
            var failures: [String] = []
            for i in ledger.actions.indices.reversed() {
                let entry = ledger.actions[i]
                guard entry.state == .completed else { continue }
                ctx.log("reverting: \(entry.action.summary)")
                do {
                    if !ctx.dryRun {
                        try entry.action.revert(ctx)
                    }
                    ledger.actions[i].state = .uncompleted
                    try saveUnlessDry(ledger)
                } catch {
                    failures.append("\(entry.action.summary): \(error)")
                    try? saveUnlessDry(ledger)
                }
            }
            if failures.isEmpty {
                if !ctx.dryRun {
                    store.remove()
                }
            } else {
                throw LedgerError.revertFailures(failures)
            }
        }
    }

    /// The self-heal entry point (§11.2 step 14): re-apply the repairable
    /// file actions whose effects have drifted (macOS updates clobbering
    /// /etc/zshrc is the canonical case). Only entries we completed are
    /// candidates; states never change.
    func repair() throws {
        try store.withLock {
            var ledger = try store.load()
            for i in ledger.actions.indices {
                let entry = ledger.actions[i]
                guard entry.state == .completed, entry.action.isRepairable else {
                    continue
                }
                if try entry.action.isAlreadyDone(ctx) {
                    continue
                }
                ctx.log("repairing: \(entry.action.summary)")
                if !ctx.dryRun {
                    var action = entry.action
                    try action.apply(ctx)
                    ledger.actions[i].action = action
                    try store.save(ledger)
                }
            }
        }
    }
}
