import Foundation

/// /etc/nix configuration.
///
/// A default install manages **nothing** — a root nix-daemon already defaults
/// `build-users-group` to `nixbld` (globals.cc: `isRootUser() ? "nixbld" :
/// ""`) and macOS ships `sandbox` off, so stock Nix needs no config file.
///
/// Optional settings ship as real nix.conf fragments — each its own installer
/// choice (flakes, the build sandbox, …). A selected choice's package drops
/// its `.conf` into a **staging** dir, `/opt/nix/etc/includes.install/`, and
/// this action **reconciles**: it moves each staged fragment into the live
/// dir `/opt/nix/etc/includes/` and drops any live fragment that wasn't staged
/// this run. Because the move empties the staging dir, it's a fresh manifest
/// of *this install's* selection every time — so a reinstall with a choice
/// unticked removes it, not just a reinstall that adds one. `nix.conf` is then
/// reconciled to match: our `!include` lines (which point into the live dir,
/// so they're self-identifying) are rewritten at the top, above any user
/// settings so those win. If nothing is left, nix.conf is deleted.
///
/// Deselecting a fragment also retires its pkg receipt (`pkgutil --forget`):
/// the fragment package is only a config carrier. This can only run on
/// *removal*, not on wiring — macOS writes a package's receipt at the end of
/// the install session, after this postinstall, so we can't forget a receipt
/// the current session just created; but a deselected fragment's receipt is
/// from a prior session, so forgetting it takes. The rest are swept at
/// uninstall (Payload.revert).
struct NixConf: Codable {
    static let includesDir = "/opt/nix/etc/includes"
    static let includesInstallDir = "/opt/nix/etc/includes.install"
    static let confPath = "/etc/nix/nix.conf"
    static let pkgutil = "/usr/sbin/pkgutil"

    var summary: String {
        "/etc/nix/nix.conf (!include lines for selected config fragments)"
    }

    private func confURL(_ ctx: Context) -> URL { ctx.path(Self.confPath) }

    private func confFiles(_ dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".conf") }
            .sorted()
    }
    private func stagedFiles(_ ctx: Context) -> [String] {
        confFiles(ctx.path(Self.includesInstallDir))
    }
    private func liveFiles(_ ctx: Context) -> [String] {
        confFiles(ctx.path(Self.includesDir))
    }

    private func includeLine(_ file: String) -> String {
        "!include \(Self.includesDir)/\(file)"
    }
    private func isOurInclude(_ line: String) -> Bool {
        line.hasPrefix("!include \(Self.includesDir)/")
    }

    /// Make the live dir exactly the set staged this run: move staged
    /// fragments in (the move empties staging), then drop any live fragment
    /// that wasn't staged.
    private func reconcileFragments(_ ctx: Context) throws {
        let fm = FileManager.default
        let staging = ctx.path(Self.includesInstallDir)
        let live = ctx.path(Self.includesDir)
        let staged = stagedFiles(ctx)

        if !staged.isEmpty {
            try fm.createDirectory(at: live, withIntermediateDirectories: true)
        }
        for file in staged {
            let dst = live.appendingPathComponent(file)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: staging.appendingPathComponent(file), to: dst)
        }
        let stagedSet = Set(staged)
        for file in liveFiles(ctx) where !stagedSet.contains(file) {
            try? fm.removeItem(at: live.appendingPathComponent(file))
            // Its receipt is from a prior session now, so this takes.
            let name = String(file.dropLast(".conf".count))
            _ = try? ctx.runner.run(Self.pkgutil, ["--forget", "org.nixos.nix.\(name)"])
        }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        if !stagedFiles(ctx).isEmpty { return false }  // staging pending
        let wanted = Set(liveFiles(ctx).map(includeLine))
        let existing = (try? String(contentsOf: confURL(ctx), encoding: .utf8)) ?? ""
        let ours = Set(existing.components(separatedBy: "\n").filter(isOurInclude))
        return wanted == ours
    }

    func apply(_ ctx: Context) throws {
        try reconcileFragments(ctx)

        // Reconcile nix.conf: drop our (possibly stale) include lines, re-add
        // the current set at the top so a user's own settings below win.
        let wanted = liveFiles(ctx).map(includeLine)
        let url = confURL(ctx)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let kept = lines.filter { !isOurInclude($0) }
        let newLines = wanted + kept
        if newLines.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try atomicWrite(newLines.joined(separator: "\n") + "\n", to: url)
        }
    }

    func revert(_ ctx: Context) throws {
        let url = confURL(ctx)
        // nix.conf may already be gone (a reconcile that dropped the last
        // fragment deletes it), so this is best-effort — but the /etc/nix
        // cleanup below must still run either way.
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            let kept = existing.components(separatedBy: "\n").filter { !isOurInclude($0) }
            let remaining = kept.joined(separator: "\n")
            if remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try atomicWrite(remaining, to: url)
            }
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
