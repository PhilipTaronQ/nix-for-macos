import Foundation

/// The APFS volume that becomes /nix.
///
/// Wisdom inherited from the Rust installer:
///   - `addVolume` is async: poll `diskutil info` until the volume is
///     queryable before anyone relies on it.
///   - Deletion races unmount: `unmount force` first, then `deleteVolume`
///     retried (upstream issues #647/#1085/#1267/#1303).
///   - A volume that already exists is `skipped`, never deleted by us.
struct ApfsVolume: Codable {
    static let diskutil = "/usr/sbin/diskutil"

    var volumeName = "Nix"
    /// Discovered at apply time and captured into the ledger.
    var containerDisk: String?
    var volumeUUID: String?

    var summary: String {
        "the '\(volumeName)' APFS volume"
    }

    // MARK: plist helpers

    static func plist(_ data: Data) -> [String: Any] {
        (try? PropertyListSerialization.propertyList(from: data, format: nil))
            as? [String: Any] ?? [:]
    }

    func volumeInfo(_ ctx: Context) -> [String: Any]? {
        guard let result = try? ctx.runner.run(Self.diskutil, ["info", "-plist", volumeName]),
            result.ok
        else {
            return nil
        }
        return Self.plist(result.stdout)
    }

    // MARK: lifecycle

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        volumeInfo(ctx) != nil
    }

    mutating func apply(_ ctx: Context) throws {
        // Discover the container of the root filesystem — the volume joins
        // the same APFS container the system lives in.
        let rootInfo = Self.plist(
            try ctx.runner.runChecked(Self.diskutil, ["info", "-plist", "/"]).stdout)
        guard let parent = rootInfo["ParentWholeDisk"] as? String else {
            throw InstallActionError.preconditionFailed(
                "could not determine the root filesystem's whole disk from diskutil")
        }
        containerDisk = parent

        try ctx.runner.runChecked(
            Self.diskutil, ["apfs", "addVolume", parent, "APFS", volumeName, "-nomount"])

        // Creation is async; wait for the volume to become queryable and
        // capture its UUID for the fstab entry and for our own revert.
        let info = try retrying(times: 50, delayMilliseconds: 100, ctx) {
            () throws -> [String: Any] in
            guard let info = volumeInfo(ctx) else {
                throw InstallActionError.postconditionFailed(
                    "volume '\(volumeName)' not yet visible to diskutil")
            }
            return info
        }
        volumeUUID = info["VolumeUUID"] as? String
    }

    func revert(_ ctx: Context) throws {
        try Self.destroy(ctx, name: volumeName, deleteTarget: volumeUUID ?? volumeName)
    }

    /// Unmount (force, tolerated) and delete the volume, retried — deletion
    /// races unmount and the OS. A no-op when the volume is already gone, so
    /// it is safe to call from more than one revert. `deleteVolume` needs no
    /// passphrase, so this destroys an encrypted volume outright.
    static func destroy(_ ctx: Context, name: String, deleteTarget: String) throws {
        guard let result = try? ctx.runner.run(diskutil, ["info", "-plist", name]), result.ok
        else {
            return // already gone
        }
        let info = plist(result.stdout)
        if (info["MountPoint"] as? String)?.isEmpty == false {
            _ = try? ctx.runner.run(diskutil, ["unmount", "force", name])
        }
        try retrying(times: 10, delayMilliseconds: 500, ctx) {
            try ctx.runner.runChecked(diskutil, ["apfs", "deleteVolume", deleteTarget])
        }
    }
}
