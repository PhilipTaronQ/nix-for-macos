import Foundation

/// /etc/nix configuration.
///
/// A default install manages **nothing** — a root nix-daemon already defaults
/// `build-users-group` to `nixbld` (globals.cc: `isRootUser() ? "nixbld" :
/// ""`) and macOS ships `sandbox` off, so stock Nix needs no config file.
///
/// Optional settings ship as real nix.conf fragments under
/// `/opt/nix/etc/includes/` — each its own installer choice (flakes, the
/// build sandbox, …), present only if the user selected it. This action
/// scans that directory and wires every fragment present into
/// `/etc/nix/nix.conf` with an `!include` line, coexisting with a user's
/// existing file. The lines it adds are recorded in the ledger, so uninstall
/// removes exactly those; if nix.conf is left empty, it is deleted. Adding a
/// future toggle is one more choice package dropping one more fragment — no
/// code here changes.
struct NixConf: Codable {
    static let includesDir = "/opt/nix/etc/includes"
    static let confPath = "/etc/nix/nix.conf"

    /// The `!include` lines this action added, captured so revert removes
    /// exactly them — never anything the user wrote.
    var addedIncludes: [String] = []

    var summary: String {
        "/etc/nix/nix.conf (!include lines for selected config fragments)"
    }

    /// The `!include` line for every fragment currently shipped under the
    /// includes dir. Paths are the real deployment paths (what nix reads at
    /// runtime), independent of any test/scratch root.
    private func wantedIncludes(_ ctx: Context) -> [String] {
        let dir = ctx.path(Self.includesDir)
        let fragments = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".conf") }
            .sorted()
        return fragments.map { "!include \(Self.includesDir)/\($0)" }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        let existing = (try? String(contentsOf: ctx.path(Self.confPath), encoding: .utf8)) ?? ""
        let present = Set(existing.components(separatedBy: "\n"))
        return wantedIncludes(ctx).allSatisfy { present.contains($0) }
    }

    mutating func apply(_ ctx: Context) throws {
        let url = ctx.path(Self.confPath)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        // A file ending in "\n" splits to a trailing "" — drop it, restore on write.
        if lines.last == "" { lines.removeLast() }

        let present = Set(lines)
        let missing = wantedIncludes(ctx).filter { !present.contains($0) }
        // Idempotent, and a stock install (no fragments) leaves /etc/nix untouched.
        guard !missing.isEmpty else { return }

        // Includes go at the TOP: nix.conf resolves later assignments over
        // earlier (configuration.cc applies settings in file order, last wins),
        // so a user's own settings below our includes take precedence.
        lines = missing + lines
        addedIncludes = missing  // record for exact reversal
        try atomicWrite(lines.joined(separator: "\n") + "\n", to: url)
    }

    func revert(_ ctx: Context) throws {
        let url = ctx.path(Self.confPath)
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return }
        let ours = Set(addedIncludes)
        let kept = existing.components(separatedBy: "\n").filter { !ours.contains($0) }
        let remaining = kept.joined(separator: "\n")
        if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // nix.conf held only our includes — remove it entirely.
            try? FileManager.default.removeItem(at: url)
        } else {
            try atomicWrite(remaining, to: url)
        }
        // Remove /etc/nix if we emptied it.
        let dir = ctx.path("/etc/nix")
        if let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
            contents.isEmpty
        {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}
