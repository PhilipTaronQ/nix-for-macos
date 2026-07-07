import Foundation

/// §11.2 step 9: Time Machine exclusions for /nix/store and /nix/var.
/// The volume itself can't be excluded without Full Disk Access, so the
/// subdirectories are (set_tmutil_exclusion.rs). tmutil is flaky enough
/// (SIGKILL under load) that failures never abort an install.
struct TmutilExclusions: Codable {
    static let tmutil = "/usr/bin/tmutil"
    static let paths = ["/nix/store", "/nix/var"]

    var summary: String {
        "Time Machine exclusions for /nix/store and /nix/var"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        false // cheap and idempotent; just (re)apply
    }

    func apply(_ ctx: Context) throws {
        for path in Self.paths {
            try? FileManager.default.createDirectory(
                at: ctx.path(path), withIntermediateDirectories: true)
            let r = try? ctx.runner.run(Self.tmutil, ["addexclusion", path])
            if r?.ok != true {
                ctx.log("warning: tmutil addexclusion \(path) failed; continuing")
            }
        }
    }

    func revert(_ ctx: Context) throws {
        for path in Self.paths {
            _ = try? ctx.runner.run(Self.tmutil, ["removeexclusion", path])
        }
    }
}
