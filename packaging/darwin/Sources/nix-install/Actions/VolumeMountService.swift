import Foundation

/// §11.2 step 6: the org.nixos.darwin-store LaunchDaemon — the boot
/// remount, without which /nix vanishes at reboot. Generated (not shipped):
/// the argv depends on the volume UUID and whether the volume is encrypted.
struct VolumeMountService: Codable {
    static let label = "org.nixos.darwin-store"
    static let plistPath = "/Library/LaunchDaemons/org.nixos.darwin-store.plist"
    static let launchctl = "/bin/launchctl"

    var volumeName = "Nix"
    /// Captured at apply time.
    var volumeUUID: String?
    var encrypted: Bool?

    var summary: String {
        "the \(Self.label) LaunchDaemon (mounts /nix at boot)"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        FileManager.default.fileExists(atPath: ctx.path(Self.plistPath).path)
    }

    static func programArguments(uuid: String, encrypted: Bool) -> [String] {
        if encrypted {
            return [
                "/bin/sh", "-c",
                "/usr/bin/security find-generic-password -a Nix -s '\(EncryptVolume.service)' -w "
                    + "| /usr/sbin/diskutil apfs unlockVolume \(uuid) -mountpoint /nix -stdinpassphrase",
            ]
        }
        return ["/usr/sbin/diskutil", "mount", "-mountPoint", "/nix", uuid]
    }

    mutating func apply(_ ctx: Context) throws {
        let info = ApfsVolume.plist(
            try ctx.runner.runChecked(ApfsVolume.diskutil, ["info", "-plist", volumeName]).stdout)
        guard let uuid = info["VolumeUUID"] as? String, !uuid.isEmpty else {
            throw InstallActionError.preconditionFailed(
                "no VolumeUUID for '\(volumeName)' — was the volume created?")
        }
        volumeUUID = uuid
        let isEncrypted =
            (info["FileVault"] as? Bool ?? false) || (info["Encrypted"] as? Bool ?? false)
        encrypted = isEncrypted

        let plist: [String: Any] = [
            "Label": Self.label,
            "RunAtLoad": true,
            "ProgramArguments": Self.programArguments(uuid: uuid, encrypted: isEncrypted),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try atomicWriteData(data, to: ctx.path(Self.plistPath))

        // Modern launchctl only: bootout any stale instance (tolerated),
        // bootstrap, kickstart — then wait for /nix to actually be mounted
        // (the boot-race pattern, run at install time too).
        _ = try? ctx.runner.run(Self.launchctl, ["bootout", "system/\(Self.label)"])
        try ctx.runner.runChecked(
            Self.launchctl, ["bootstrap", "system", ctx.path(Self.plistPath).path])
        try ctx.runner.runChecked(Self.launchctl, ["kickstart", "-k", "system/\(Self.label)"])

        try retrying(times: 150, delayMilliseconds: 100, ctx) {
            let mounted =
                (try? ctx.runner.run(ApfsVolume.diskutil, ["info", "-plist", volumeName]))
                .flatMap { $0.ok ? ApfsVolume.plist($0.stdout)["MountPoint"] as? String : nil }
            guard mounted == "/nix" else {
                throw InstallActionError.postconditionFailed(
                    "'\(volumeName)' is not mounted at /nix yet")
            }
        }
    }

    func revert(_ ctx: Context) throws {
        _ = try? ctx.runner.run(Self.launchctl, ["bootout", "system/\(Self.label)"])
        let url = ctx.path(Self.plistPath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
