import Foundation
import XCTest

@testable import nix_install

final class ServiceActionsTests: XCTestCase {
    var root: URL!
    var ctx: Context!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("svc-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ctx = Context(root: root)
        ctx.pollScale = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = ctx.path(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: EncryptVolume

    func testEncryptSkipsWhenFileVaultInactive() throws {
        ctx.runner = FakeRunner { call in
            switch call[0] {
            case EncryptVolume.fdesetup: return .ok("false\n")
            default: return .fail(1)
            }
        }
        XCTAssertTrue(try EncryptVolume().isAlreadyDone(ctx))
    }

    func testEncryptAppliesWithKeychainACLAndStdinPassphrase() throws {
        let runner = FakeRunner { call in
            switch call.dropFirst().first {
            case "mount": return .ok()
            case "add-generic-password": return .ok()
            case "apfs": return .ok()  // encryptVolume
            case "info": return .plist(["MountPoint": "/nix"])  // SIGBUS guard: no unmount
            default: return .fail(1, stderr: "unexpected \(call)")
            }
        }
        ctx.runner = runner
        try EncryptVolume().apply(ctx)

        let keychainCall = runner.calls.first { $0.contains("add-generic-password") }!
        XCTAssertTrue(keychainCall.contains("/System/Library/CoreServices/APFSUserAgent"))
        XCTAssertTrue(keychainCall.contains("/System/Library/CoreServices/CSUserAgent"))
        XCTAssertTrue(keychainCall.contains(EncryptVolume.keychain))

        let encryptIndex = runner.calls.firstIndex { $0.contains("encryptVolume") }!
        let passphrase = runner.stdins[encryptIndex].map { String(data: $0, encoding: .utf8)! }
        XCTAssertEqual(passphrase?.count, 32, "32-char generated passphrase on stdin")
        XCTAssertFalse(
            runner.calls.contains { $0.contains("unmount") },
            "mounted at /nix ⇒ never force-unmounted (SIGBUS guard)")
    }

    func testEncryptRevertDestroysVolumeThenPasswordInOnePass() throws {
        var deleted = false
        let runner = FakeRunner { call in
            switch call.dropFirst().first {
            case "info":
                return deleted
                    ? .fail(1, stderr: "Could not find disk")
                    : .plist(["FileVault": true, "MountPoint": "/nix"])
            case "unmount": return .ok()
            case "apfs":  // deleteVolume
                deleted = true
                return .ok()
            case "delete-generic-password": return .ok()
            default: return .fail(1, stderr: "unexpected \(call)")
            }
        }
        ctx.runner = runner

        try EncryptVolume().revert(ctx)  // no throw: single pass, no rerun

        let deleteVolume = runner.calls.firstIndex { $0.contains("deleteVolume") }
        let deletePassword = runner.calls.firstIndex { $0.contains("delete-generic-password") }
        XCTAssertNotNil(deleteVolume, "the encrypted volume is destroyed by revert")
        XCTAssertNotNil(deletePassword, "the keychain password is removed")
        XCTAssertLessThan(
            deleteVolume!, deletePassword!,
            "password removed only after the volume's data is destroyed")
    }

    func testEncryptRevertDeletesPasswordOnceVolumeIsGone() throws {
        let runner = FakeRunner { call in
            switch call.dropFirst().first {
            case "info": return .fail(1, stderr: "Could not find disk")
            case "delete-generic-password": return .ok()
            default: return .fail(1)
            }
        }
        ctx.runner = runner
        try EncryptVolume().revert(ctx)
        XCTAssertTrue(runner.calls.contains { $0.contains("delete-generic-password") })
    }

    // MARK: VolumeMountService

    func testMountServiceWritesPlistAndBootstraps() throws {
        var mountPoint = ""
        let runner = FakeRunner { call in
            switch call.dropFirst().first {
            case "info":
                return .plist(["VolumeUUID": "AAAA-BBBB", "MountPoint": mountPoint])
            case "bootout": return .fail(3)  // nothing loaded: tolerated
            case "bootstrap": return .ok()
            case "kickstart":
                mountPoint = "/nix"  // the daemon mounts it
                return .ok()
            default: return .fail(1, stderr: "unexpected \(call)")
            }
        }
        ctx.runner = runner

        var action = VolumeMountService()
        try action.apply(ctx)

        XCTAssertEqual(action.volumeUUID, "AAAA-BBBB")
        XCTAssertEqual(action.encrypted, false)
        let data = try Data(contentsOf: ctx.path(VolumeMountService.plistPath))
        let plist = ApfsVolume.plist(data)
        XCTAssertEqual(plist["Label"] as? String, "org.nixos.darwin-store")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/usr/sbin/diskutil", "mount", "-mountPoint", "/nix", "AAAA-BBBB"])
    }

    func testMountServiceEncryptedVariantUsesKeychainUnlock() {
        let args = VolumeMountService.programArguments(uuid: "U", encrypted: true)
        XCTAssertEqual(args[0], "/bin/sh")
        XCTAssertTrue(args[2].contains("find-generic-password"))
        XCTAssertTrue(args[2].contains("unlockVolume U"))
        XCTAssertTrue(args[2].contains("-stdinpassphrase"))
    }

    // MARK: BuildUsers

    func testBuildUsersRetriesFlakyDsclAndCreatesSequentially() throws {
        var failedOnce = false
        let runner = FakeRunner { call in
            if call[0] == BuildUsers.dseditgroup { return .ok() }
            // One eNotYetImplemented flake on the very first user create.
            if call.contains("/Users/_nixbld1") && call.contains("-create") && !failedOnce
                && call.count == 4
            {
                failedOnce = true
                return .fail(140, stderr: "eNotYetImplemented")
            }
            return .ok()
        }
        ctx.runner = runner

        var users = BuildUsers()
        users.count = 2
        try users.apply(ctx)

        XCTAssertTrue(failedOnce, "the flake was exercised")
        let uidCall = runner.calls.first { $0.contains("UniqueID") }!
        XCTAssertEqual(uidCall.last, "351", "UID base 350 ⇒ _nixbld1 = 351 (Sequoia-safe)")
        XCTAssertTrue(
            runner.calls.contains {
                $0.contains("GroupMembership") && $0.contains("_nixbld2")
            })
    }

    func testBuildUsersRevertToleratesEphemeralMacFailures() throws {
        let runner = FakeRunner { call in
            call.contains("-delete") && call.contains("/Users/_nixbld1")
                ? .fail(40, stderr: "no secure token") : .ok()
        }
        ctx.runner = runner
        var users = BuildUsers()
        users.count = 2
        XCTAssertNoThrow(try users.revert(ctx), "exit 40 tolerated, walk continues")
        XCTAssertTrue(runner.calls.contains { $0.contains("/Groups/nixbld") })
    }

    // MARK: NixConf

    func testNixConfNoFragmentsManagesNothing() throws {
        try NixConf().apply(ctx)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path("/etc/nix/nix.conf").path),
            "a stock install with no selected fragments writes no config")
    }

    func testNixConfStagesAndWiresSelectedFragments() throws {
        try write(
            "experimental-features = nix-command flakes\n",
            "/opt/nix/etc/includes.install/flakes.conf")
        try write("sandbox = true\n", "/opt/nix/etc/includes.install/sandbox.conf")
        try NixConf().apply(ctx)

        let text = try String(contentsOf: ctx.path("/etc/nix/nix.conf"), encoding: .utf8)
        XCTAssertTrue(text.contains("!include /opt/nix/etc/includes/flakes.conf"))
        XCTAssertTrue(text.contains("!include /opt/nix/etc/includes/sandbox.conf"))
        // Staged fragments were moved into the live dir; staging is emptied.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ctx.path("/opt/nix/etc/includes/flakes.conf").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ctx.path("/opt/nix/etc/includes.install/flakes.conf").path))
    }

    func testNixConfReconcileDropsDeselectedFragmentOnReinstall() throws {
        // First install: flakes staged ⇒ wired and moved into place.
        try write(
            "experimental-features = nix-command flakes\n",
            "/opt/nix/etc/includes.install/flakes.conf")
        try NixConf().apply(ctx)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ctx.path("/opt/nix/etc/includes/flakes.conf").path))

        // Reinstall with flakes deselected: nothing staged ⇒ reconcile drops it.
        try NixConf().apply(ctx)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path("/opt/nix/etc/includes/flakes.conf").path),
            "a deselected fragment is removed from the live dir")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path("/etc/nix/nix.conf").path),
            "and its include line goes with it — nix.conf is now empty, so removed")
    }

    func testNixConfForgetsFragmentReceiptOnDeselect() throws {
        // Install flakes, then reinstall without it: reconcile drops the
        // fragment and forgets its (now prior-session) receipt. Forgetting
        // can't happen on wire — macOS writes the receipt after this runs.
        try write(
            "experimental-features = nix-command flakes\n",
            "/opt/nix/etc/includes.install/flakes.conf")
        try NixConf().apply(ctx)  // flakes now live

        let runner = FakeRunner { _ in .ok() }
        ctx.runner = runner
        try NixConf().apply(ctx)  // nothing staged ⇒ reconcile drops + forgets flakes

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path("/opt/nix/etc/includes/flakes.conf").path))
        XCTAssertTrue(
            runner.calls.contains { $0 == [NixConf.pkgutil, "--forget", "org.nixos.nix.flakes"] },
            "deselecting a fragment forgets its prior-session pkg receipt")
    }

    func testNixConfCoexistsWithExistingUserConf() throws {
        try write("max-jobs = 4\n", "/etc/nix/nix.conf")
        try write("sandbox = true\n", "/opt/nix/etc/includes.install/sandbox.conf")
        try NixConf().apply(ctx)

        let text = try String(contentsOf: ctx.path("/etc/nix/nix.conf"), encoding: .utf8)
        XCTAssertTrue(text.contains("max-jobs = 4"), "user content is preserved")
        let include = text.range(of: "!include /opt/nix/etc/includes/sandbox.conf")!
        let userLine = text.range(of: "max-jobs = 4")!
        XCTAssertTrue(
            include.lowerBound < userLine.lowerBound,
            "includes go above user settings, so a user's own edits below win")
    }

    func testNixConfRevertRemovesOnlyOursAndDeletesIfEmpty() throws {
        try write(
            "experimental-features = nix-command flakes\n",
            "/opt/nix/etc/includes.install/flakes.conf")
        try NixConf().apply(ctx)
        try NixConf().revert(ctx)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path("/etc/nix/nix.conf").path),
            "nix.conf held only our !include, so it is removed")
    }

    func testNixConfRevertPreservesUserEditedConf() throws {
        try write("max-jobs = 4\n", "/etc/nix/nix.conf")
        try write("sandbox = true\n", "/opt/nix/etc/includes.install/sandbox.conf")
        try NixConf().apply(ctx)

        try NixConf().revert(ctx)
        let text = try String(contentsOf: ctx.path("/etc/nix/nix.conf"), encoding: .utf8)
        XCTAssertTrue(text.contains("max-jobs = 4"), "user setting survives uninstall")
        XCTAssertFalse(text.contains("!include"), "our line is gone")
    }

    // MARK: ShellInit

    func testShellInitAppendsAndRemovesFragment() throws {
        try write("export EDITOR=vi\n", "/etc/bashrc")
        try ShellInit().apply(ctx)

        let text = try String(contentsOf: ctx.path("/etc/bashrc"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("export EDITOR=vi\n# Nix\n"))
        XCTAssertTrue(text.hasSuffix("# End Nix\n"))

        try ShellInit().revert(ctx)
        XCTAssertEqual(
            try String(contentsOf: ctx.path("/etc/bashrc"), encoding: .utf8),
            "export EDITOR=vi\n")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path("/etc/zshrc").path),
            "zshrc we created (fragment only) is removed entirely")
    }

    func testShellInitNeverWritesThroughSymlinks() throws {
        try write("nix-darwin owns this\n", "/etc/zshrc.real")
        try FileManager.default.createDirectory(
            at: ctx.path("/etc"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: ctx.path("/etc/zshrc"), withDestinationURL: ctx.path("/etc/zshrc.real"))

        try ShellInit().apply(ctx)
        XCTAssertEqual(
            try String(contentsOf: ctx.path("/etc/zshrc.real"), encoding: .utf8),
            "nix-darwin owns this\n", "symlinked shell files are never touched")
    }

    // MARK: ManPathsD

    func testManPathsDRoundTrip() throws {
        try ManPathsD().apply(ctx)
        let url = root.appendingPathComponent("etc/manpaths.d/nix")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "/opt/nix/share/man\n")
        try ManPathsD().revert(ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Payload

    func testPayloadCopiesFromSourceAndRevertRemoves() throws {
        let src = root.appendingPathComponent("payload-src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try "fake".write(
            to: src.appendingPathComponent("bin/nix"), atomically: true, encoding: .utf8)

        try Payload(source: src.path).apply(ctx)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ctx.path("/opt/nix/bin/nix").path))

        try Payload(source: src.path).revert(ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.path("/opt/nix").path))
    }

    func testPayloadWithoutSourceVerifiesPkgLaidTree() throws {
        XCTAssertThrowsError(try Payload().apply(ctx), "no tree, no source: refuse")
        try write("fake", "/opt/nix/bin/nix")
        XCTAssertNoThrow(try Payload().apply(ctx))
    }

    func testPayloadRevertSweepsOurReceipts() throws {
        let runner = FakeRunner { call in
            call.contains("--pkgs=^org\\.nixos\\.nix")
                ? .ok("org.nixos.nix\norg.nixos.nix.flakes\n") : .ok()
        }
        ctx.runner = runner
        try FileManager.default.createDirectory(
            at: ctx.path("/opt/nix"), withIntermediateDirectories: true)

        try Payload().revert(ctx)

        XCTAssertFalse(FileManager.default.fileExists(atPath: ctx.path("/opt/nix").path))
        XCTAssertTrue(
            runner.calls.contains { $0 == [Payload.pkgutil, "--forget", "org.nixos.nix"] })
        XCTAssertTrue(
            runner.calls.contains { $0 == [Payload.pkgutil, "--forget", "org.nixos.nix.flakes"] },
            "uninstall sweeps the core receipt and any fragment receipts")
    }

    // MARK: DaemonService + SelfHealService

    func testDaemonServiceWritesPlistAndCleansSocket() throws {
        try write("stale", DaemonService.daemonSocket)
        let runner = FakeRunner { call in
            switch call.dropFirst().first {
            case "bootout": return .ok()
            case "bootstrap", "enable", "kickstart": return .ok()
            case "print": return .fail(113)  // service gone
            default: return .fail(1, stderr: "unexpected \(call)")
            }
        }
        ctx.runner = runner

        try DaemonService().apply(ctx)
        let plist = ApfsVolume.plist(
            try Data(contentsOf: ctx.path(DaemonService.installedPlist)))
        XCTAssertEqual(plist["Label"] as? String, "org.nixos.nix-daemon")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String], ["/opt/nix/bin/nix-daemon"],
            "direct exec: /opt/nix needs no wait4path")
        XCTAssertEqual(plist["StandardOutPath"] as? String, DaemonService.logFile)
        XCTAssertEqual(plist["StandardErrorPath"] as? String, DaemonService.logFile)
        XCTAssertEqual(
            (plist["SoftResourceLimits"] as? [String: Int])?["NumberOfFiles"], 1_048_576)
        XCTAssertEqual(
            (plist["HardResourceLimits"] as? [String: Int])?["NumberOfFiles"], 1_048_576)
        XCTAssertEqual(plist["ExitTimeOut"] as? Int, 60)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: ctx.path(DaemonService.newsyslogConf).path),
            "log rotation entry written alongside the plist")

        try DaemonService().revert(ctx)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path(DaemonService.installedPlist).path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path(DaemonService.newsyslogConf).path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: ctx.path(DaemonService.daemonSocket).path),
            "stale daemon socket unlinked (launchd leaves them)")
    }

    func testSelfHealPlistExecsInstallerDirectly() throws {
        ctx.runner = FakeRunner { call in
            ["bootout", "bootstrap"].contains(call.dropFirst().first ?? "") ? .ok() : .fail(1)
        }
        try SelfHealService().apply(ctx)

        let plist = ApfsVolume.plist(
            try Data(contentsOf: ctx.path(SelfHealService.plistPath)))
        XCTAssertEqual(plist["Label"] as? String, "org.nixos.nix-repair")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            ["/opt/nix/libexec/nix-install", "repair"],
            "direct exec: /opt/nix needs no wait4path")
        XCTAssertEqual(
            (plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false)
    }
}
