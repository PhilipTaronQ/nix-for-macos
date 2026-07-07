import Foundation

/// FileVault-encrypt the Nix volume, with the password in the System
/// keychain so the volume unlocks unattended at boot. Always encrypted:
/// an unencrypted volume sitting beside FileVault system volumes is
/// exactly what enterprise compliance scans flag.
///
/// Inherited wisdom (encrypt_apfs_volume.rs):
///   - The keychain item needs a -T ACL for APFSUserAgent and CSUserAgent
///     or boot-unlock silently fails.
///   - Never force-unmount a volume mounted at /nix (live mmaps ⇒ SIGBUS)
///     during *apply* — a store is in use then. By revert the daemon is
///     stopped and the payload gone, so the teardown unmount is safe.
///   - The keychain password must not outlive the encrypted volume's data.
///     Reverse-replay reverts this before ApfsVolume (encrypt applied after
///     create), so revert destroys its own volume first — `deleteVolume`
///     needs no passphrase — then removes the password, all in one pass.
///     (An earlier design deferred to a second `uninstall` run, but uninstall
///     deletes its own binary along with /opt/nix, so no rerun is possible.)
struct EncryptVolume: Codable {
    static let security = "/usr/bin/security"
    static let fdesetup = "/usr/bin/fdesetup"
    static let keychain = "/Library/Keychains/System.keychain"
    static let service = "Nix Store"

    var volumeName = "Nix"

    var summary: String {
        "FileVault encryption for the '\(volumeName)' volume"
    }

    private func info(_ ctx: Context) -> [String: Any]? {
        guard let r = try? ctx.runner.run(ApfsVolume.diskutil, ["info", "-plist", volumeName]),
            r.ok
        else { return nil }
        return ApfsVolume.plist(r.stdout)
    }

    private func volumeIsEncrypted(_ ctx: Context) -> Bool {
        guard let info = info(ctx) else { return false }
        return (info["FileVault"] as? Bool ?? false) || (info["Encrypted"] as? Bool ?? false)
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        // Already encrypted (previous install): nothing to do, never ours
        // to un-encrypt. And on machines without FileVault on the root
        // disk we match the platform: an unencrypted system gets an
        // unencrypted store volume ("already in the desired state").
        if volumeIsEncrypted(ctx) {
            return true
        }
        if let r = try? ctx.runner.run(Self.fdesetup, ["isactive"]),
            r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines) != "true"
        {
            ctx.log("FileVault is not active on this system; leaving the Nix volume unencrypted")
            return true
        }
        return false
    }

    func apply(_ ctx: Context) throws {
        // 32 characters, generated fresh, never logged.
        let charset = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let password = String((0..<32).map { _ in charset.randomElement()! })

        // The volume must be mounted somewhere for encryptVolume; mounting
        // is async-racy like everything APFS, so retry.
        try retrying(times: 12, delayMilliseconds: 500, ctx) {
            try ctx.runner.runChecked(ApfsVolume.diskutil, ["mount", volumeName])
        }

        try ctx.runner.runChecked(
            Self.security,
            [
                "add-generic-password",
                "-a", volumeName,
                "-s", Self.service,
                "-l", "\(volumeName) encryption password",
                "-D", "Encrypted volume password",
                "-j", "Added by the Nix installer for unlocking the Nix store volume at boot",
                "-T", "/System/Library/CoreServices/APFSUserAgent",
                "-T", "/System/Library/CoreServices/CSUserAgent",
                "-T", Self.security,
                "-w", password,
                Self.keychain,
            ])

        try ctx.runner.runChecked(
            ApfsVolume.diskutil,
            ["apfs", "encryptVolume", volumeName, "-user", "disk", "-stdinpassphrase"],
            stdin: Data(password.utf8))

        // Leave it mounted if it is (or becomes) /nix — force-unmounting a
        // live /nix delivers SIGBUS to anything with store mmaps.
        if let mountPoint = info(ctx)?["MountPoint"] as? String,
            !mountPoint.isEmpty, mountPoint != "/nix"
        {
            _ = try? ctx.runner.run(ApfsVolume.diskutil, ["unmount", "force", volumeName])
        }
    }

    func revert(_ ctx: Context) throws {
        // Destroy the volume before removing its password so the password
        // never outlives the data. Reverse-replay puts this ahead of
        // ApfsVolume.revert, which then no-ops on the already-gone volume.
        if info(ctx) != nil && volumeIsEncrypted(ctx) {
            try ApfsVolume.destroy(ctx, name: volumeName, deleteTarget: volumeName)
        }
        // Volume gone (or never encrypted): the password can go too.
        let r = try ctx.runner.run(
            Self.security,
            ["delete-generic-password", "-a", volumeName, "-s", Self.service, Self.keychain])
        // Exit 44 = item not found: fine, nothing to delete.
        if !r.ok && r.status != 44 {
            throw CommandError.failed(
                program: Self.security, arguments: ["delete-generic-password"],
                status: r.status, stderr: r.stderrText)
        }
    }
}
