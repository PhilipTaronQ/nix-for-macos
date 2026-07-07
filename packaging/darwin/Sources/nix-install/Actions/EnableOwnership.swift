import Foundation

/// §11.2 step 7: `diskutil enableOwnership /nix` — the store must respect
/// real uids/gids. One of the actions with a legitimately empty revert:
/// add+remove is the universal *shape*, not universal symmetry.
struct EnableOwnership: Codable {
    var summary: String {
        "ownership enforcement on /nix (diskutil enableOwnership)"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        guard let r = try? ctx.runner.run(ApfsVolume.diskutil, ["info", "-plist", "/nix"]),
            r.ok
        else { return false }
        return ApfsVolume.plist(r.stdout)["GlobalPermissionsEnabled"] as? Bool ?? false
    }

    func apply(_ ctx: Context) throws {
        try ctx.runner.runChecked(ApfsVolume.diskutil, ["enableOwnership", "/nix"])
    }

    func revert(_ ctx: Context) throws {
        // Deliberately empty: the volume is being deleted anyway, and
        // disabling ownership on a live volume helps nobody.
    }
}
