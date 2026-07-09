#if canImport(Darwin)
    import Darwin
#else
    import Glibc  // the engine is testable on Linux: scratch roots, fake runners
#endif
import Foundation

/// The install ledger.
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

/// The ledger's timestamp format: ISO-8601 UTC, seconds precision. A
/// fixed-format DateFormatter rather than ISO8601DateFormatter: the output
/// is byte-identical, and it also works on corelibs-foundation (where
/// ISO8601DateFormatter traps), keeping the engine testable on Linux.
private let ledgerDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return f
}()

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
        // did not write is ever replayed.
        struct Probe: Codable {
            var format: String?
            var version: Int?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .formatted(ledgerDateFormatter)
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
        encoder.dateEncodingStrategy = .formatted(ledgerDateFormatter)
        try atomicWriteData(try encoder.encode(ledger), to: fileURL)
    }

    func remove() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: lockURL)
    }

    /// Single-writer discipline: install, uninstall, and the self-heal
    /// repair daemon all take this lock — repair racing an uninstall would
    /// otherwise be corruption by design.
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
            // The upgrade key: an `org.nixos.nix` receipt already present means
            // a prior install completed and we're (re)installing over it. Read
            // it now, before the resume loop marks anything.
            let upgrade = priorInstallPresent()

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

            // Upgrade: the payload was just replaced with new binaries. The
            // resume loop skipped the launchd services (their plists already
            // exist), so re-apply the upgrade-sensitive actions — chiefly to
            // restart the daemons onto the new binaries.
            if upgrade && !ctx.dryRun {
                for i in ledger.actions.indices where ledger.actions[i].action.rerunOnUpgrade {
                    ctx.log("upgrading: \(ledger.actions[i].action.summary)")
                    var action = ledger.actions[i].action
                    try action.apply(ctx)
                    ledger.actions[i].action = action
                    try saveUnlessDry(ledger)
                }
            }
        }
    }

    /// The pkgutil upgrade key: is the core package's receipt already present?
    /// A missing receipt (or a --root/test refusing runner) reads as false.
    private func priorInstallPresent() -> Bool {
        ((try? ctx.runner.run(Payload.pkgutil, ["--pkg-info", Payload.pkgIdentifier]))?.ok) ?? false
    }

    /// Reverse, best-effort. By default this is a *soft* uninstall: it
    /// removes Nix's OS integration but keeps the store layer — the APFS
    /// volume and its data — so a later install re-adopts it with nothing to
    /// rebuild. `purge` reverts everything, the store included. One failed
    /// revert never strands the rest; failures are collected and the ledger
    /// records what remains. The ledger is removed only when nothing is left
    /// behind (a soft uninstall keeps it, so a reinstall can re-adopt).
    func uninstall(purge: Bool = false) throws {
        try store.withLock {
            guard store.exists else {
                throw LedgerError.missingLedger(path: store.fileURL.path)
            }
            var ledger = try store.load()
            var failures: [String] = []
            var kept = false
            for i in ledger.actions.indices.reversed() {
                let entry = ledger.actions[i]
                guard entry.state == .completed else { continue }
                if !purge && entry.action.isStoreLayer {
                    kept = true
                    ctx.log("keeping (store): \(entry.action.summary)")
                    continue
                }
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
            if !failures.isEmpty {
                throw LedgerError.revertFailures(failures)
            }
            if !kept && !ctx.dryRun {
                store.remove()
            }
        }
    }

    /// The self-heal entry point: re-apply the repairable
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
