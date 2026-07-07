import Foundation

/// Make the synthetic.conf changes take effect without a
/// reboot by running BOTH `apfs.util -t` and `apfs.util -B`, ignoring
/// their exit codes — exactly the Rust installer's incantation
/// (create_synthetic_objects.rs), which in turn mirrors Nix's old
/// create-darwin-volume.sh.
///
/// Deliberately separate from SyntheticConf so that action stays a pure
/// file edit. Note the flat-ledger trade-off: on uninstall this reverts
/// BEFORE the synthetic.conf line is removed, so the re-run here is a
/// no-op and the empty /nix mount-point directory lingers until the next
/// reboot. That residue is cosmetic and accepted.
struct MaterializeFirmlinks: Codable {
    static let apfsUtil = "/System/Library/Filesystems/apfs.fs/Contents/Resources/apfs.util"

    var summary: String {
        "materialize synthetic.conf firmlinks (apfs.util -t / -B)"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        // If /nix already exists as a directory, there is nothing to
        // materialize (previous install, or a reboot did it).
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: ctx.path("/nix").path, isDirectory: &isDir)
            && isDir.boolValue
    }

    private func runBoth(_ ctx: Context) throws {
        // Both invocations, errors ignored — apfs.util's exit codes are
        // not meaningful here and differ across macOS releases.
        _ = try? ctx.runner.run(Self.apfsUtil, ["-t"])
        _ = try? ctx.runner.run(Self.apfsUtil, ["-B"])
    }

    func apply(_ ctx: Context) throws {
        try runBoth(ctx)
        // Unlike the tool's exit codes, this is checkable: the whole point
        // was to make /nix appear.
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: ctx.path("/nix").path, isDirectory: &isDir)
        guard exists && isDir.boolValue else {
            throw InstallActionError.postconditionFailed(
                "/nix did not appear after apfs.util -t/-B; "
                    + "check /etc/synthetic.conf and consider rebooting")
        }
    }

    func revert(_ ctx: Context) throws {
        // Best-effort refresh; see the type comment for why this is
        // usually a no-op during uninstall.
        try runBoth(ctx)
    }
}

enum InstallActionError: Error, CustomStringConvertible {
    case postconditionFailed(String)
    case preconditionFailed(String)

    var description: String {
        switch self {
        case .postconditionFailed(let s): return s
        case .preconditionFailed(let s): return s
        }
    }
}
