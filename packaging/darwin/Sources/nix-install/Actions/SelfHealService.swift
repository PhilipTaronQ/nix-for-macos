import Foundation

/// The self-heal LaunchDaemon. macOS updates wipe /etc/zshrc et al.;
/// this daemon re-applies the drift-prone file actions after every boot.
/// Direct exec: /opt/nix is a plain directory, present from boot.
struct SelfHealService: Codable {
    static let label = "org.nixos.nix-repair"
    static let plistPath = "/Library/LaunchDaemons/org.nixos.nix-repair.plist"
    static let installerBinary = "/opt/nix/libexec/nix-install"

    var summary: String {
        "the \(Self.label) self-heal LaunchDaemon"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        FileManager.default.fileExists(atPath: ctx.path(Self.plistPath).path)
    }

    func apply(_ ctx: Context) throws {
        let plist: [String: Any] = [
            "Label": Self.label,
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProgramArguments": [Self.installerBinary, "repair"],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try atomicWriteData(data, to: ctx.path(Self.plistPath))

        _ = try? ctx.runner.run(
            VolumeMountService.launchctl, ["bootout", "system/\(Self.label)"])
        try ctx.runner.runChecked(
            VolumeMountService.launchctl,
            ["bootstrap", "system", ctx.path(Self.plistPath).path])
    }

    func revert(_ ctx: Context) throws {
        _ = try? ctx.runner.run(
            VolumeMountService.launchctl, ["bootout", "system/\(Self.label)"])
        let url = ctx.path(Self.plistPath)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
