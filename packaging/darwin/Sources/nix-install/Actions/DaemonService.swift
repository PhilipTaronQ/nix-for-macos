import Foundation

/// The nix-daemon LaunchDaemon. The installer writes the plist itself —
/// /opt/nix is a plain directory, present from boot, so the daemon execs
/// directly with no wait4path shim. Then the modern
/// bootstrap/enable/kickstart dance; never legacy `load`.
struct DaemonService: Codable {
    static let label = "org.nixos.nix-daemon"
    static let daemonBinary = "/opt/nix/bin/nix-daemon"
    static let installedPlist = "/Library/LaunchDaemons/org.nixos.nix-daemon.plist"
    static let daemonSocket = "/var/run/nix-daemon.socket"
    static let logFile = "/var/log/nix-daemon.log"
    static let newsyslogConf = "/etc/newsyslog.d/org.nixos.nix-daemon.conf"

    var summary: String {
        "the \(Self.label) LaunchDaemon"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        FileManager.default.fileExists(atPath: ctx.path(Self.installedPlist).path)
    }

    func apply(_ ctx: Context) throws {
        let plist: [String: Any] = [
            "Label": Self.label,
            "KeepAlive": true,
            "RunAtLoad": true,
            "ProgramArguments": [Self.daemonBinary],
            // Both streams: upstream's template discards stdout.
            "StandardOutPath": Self.logFile,
            "StandardErrorPath": Self.logFile,
            // Hard limit too: the macOS default hard cap (10240) would
            // silently floor the soft value otherwise.
            "SoftResourceLimits": ["NumberOfFiles": 1_048_576],
            "HardResourceLimits": ["NumberOfFiles": 1_048_576],
            // Let in-flight builds wind down on SIGTERM before SIGKILL
            // (launchd's default is 20s).
            "ExitTimeOut": 60,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try atomicWriteData(data, to: ctx.path(Self.installedPlist))

        // Rotate the daemon log (10MB, keep 5, bzip2) — nothing else does.
        try atomicWrite(
            "# Written by the Nix installer.\n"
                + "# logfilename          [owner:group]  mode count size(KB) when flags\n"
                + "\(Self.logFile)                        644  5     10240    *    J\n",
            to: ctx.path(Self.newsyslogConf))

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
        // its plist: bootout is asynchronous, and removing the plist while
        // the service is still registered leaves launchd holding a stale
        // definition (a lesson inherited from the Rust installer).
        try? retrying(times: 20, delayMilliseconds: 100, ctx) {
            let r = try ctx.runner.run(
                VolumeMountService.launchctl, ["print", "system/\(Self.label)"])
            if r.ok {
                throw InstallActionError.postconditionFailed("daemon still registered")
            }
        }
        let fm = FileManager.default
        for path in [Self.installedPlist, Self.newsyslogConf] {
            let url = ctx.path(path)
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
        }
        // launchd leaves stale sockets that break the next bootstrap.
        try? fm.removeItem(at: ctx.path(Self.daemonSocket))
    }
}
