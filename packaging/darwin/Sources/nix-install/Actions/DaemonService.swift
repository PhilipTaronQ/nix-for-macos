import Foundation

/// §11.2 step 13: the nix-daemon LaunchDaemon. The plist itself is
/// upstream's, meson-installed into the payload (@bindir@-parameterized,
/// §11.2a) — this action copies it to /Library/LaunchDaemons and does the
/// modern bootstrap/enable/kickstart dance; never legacy `load`.
struct DaemonService: Codable {
    static let label = "org.nixos.nix-daemon"
    static let payloadPlist = "/opt/nix/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
    static let installedPlist = "/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
    static let daemonSocket = "/var/run/nix-daemon.socket"

    var summary: String {
        "the \(Self.label) LaunchDaemon"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        FileManager.default.fileExists(atPath: ctx.path(Self.installedPlist).path)
    }

    func apply(_ ctx: Context) throws {
        let source = ctx.path(Self.payloadPlist)
        guard let data = try? Data(contentsOf: source) else {
            throw InstallActionError.preconditionFailed(
                "\(Self.payloadPlist) is missing from the payload")
        }
        try atomicWriteData(data, to: ctx.path(Self.installedPlist))

        _ = try? ctx.runner.run(
            VolumeMountService.launchctl, ["bootout", "system/\(Self.label)"])
        try ctx.runner.runChecked(
            VolumeMountService.launchctl,
            ["bootstrap", "system", ctx.path(Self.installedPlist).path])
        _ = try? ctx.runner.run(
            VolumeMountService.launchctl, ["enable", "system/\(Self.label)"])
        try ctx.runner.runChecked(
            VolumeMountService.launchctl, ["kickstart", "-k", "system/\(Self.label)"])
    }

    func revert(_ ctx: Context) throws {
        _ = try? ctx.runner.run(
            VolumeMountService.launchctl, ["bootout", "system/\(Self.label)"])
        // Wait for launchd to actually forget the service before deleting
        // its plist (configure_init_service.rs:500-527).
        try? retrying(times: 20, delayMilliseconds: 100, ctx) {
            let r = try ctx.runner.run(
                VolumeMountService.launchctl, ["print", "system/\(Self.label)"])
            if r.ok {
                throw InstallActionError.postconditionFailed("daemon still registered")
            }
        }
        let plist = ctx.path(Self.installedPlist)
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
        }
        // launchd leaves stale sockets that break the next bootstrap.
        try? FileManager.default.removeItem(at: ctx.path(Self.daemonSocket))
    }
}
