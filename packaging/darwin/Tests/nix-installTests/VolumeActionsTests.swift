import Foundation
import XCTest

@testable import nix_install

/// A scripted CommandRunner: records every invocation, answers via a
/// handler. Reference semantics so tests can assert on calls afterwards.
final class FakeRunner: CommandRunner {
    var calls: [[String]] = []
    var stdins: [Data?] = []
    var handler: ([String]) -> CommandResult

    init(_ handler: @escaping ([String]) -> CommandResult) {
        self.handler = handler
    }

    func run(_ program: String, _ arguments: [String], stdin: Data?) throws -> CommandResult {
        let call = [program] + arguments
        calls.append(call)
        stdins.append(stdin)
        return handler(call)
    }
}

extension CommandResult {
    static func ok(_ text: String = "") -> CommandResult {
        CommandResult(status: 0, stdout: Data(text.utf8), stderr: Data())
    }

    static func fail(_ status: Int32 = 1, stderr: String = "") -> CommandResult {
        CommandResult(status: status, stdout: Data(), stderr: Data(stderr.utf8))
    }

    static func plist(_ dict: [String: Any]) -> CommandResult {
        let data = try! PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        return CommandResult(status: 0, stdout: data, stderr: Data())
    }
}

final class VolumeActionsTests: XCTestCase {
    var root: URL!
    var ctx: Context!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("volume-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ctx = Context(root: root)
        ctx.pollScale = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: MaterializeFirmlinks

    func testMaterializeRunsBothUtilsAndToleratesTheirFailures() throws {
        let runner = FakeRunner { _ in .fail(1, stderr: "apfs.util always exits oddly") }
        ctx.runner = runner
        // Postcondition: /nix must exist afterwards; simulate the firmlink.
        try FileManager.default.createDirectory(
            at: ctx.path("/nix"), withIntermediateDirectories: true)

        try MaterializeFirmlinks().apply(ctx)

        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertEqual(runner.calls[0].suffix(1), ["-t"])
        XCTAssertEqual(runner.calls[1].suffix(1), ["-B"])
    }

    func testMaterializeFailsWhenNixDoesNotAppear() {
        ctx.runner = FakeRunner { _ in .ok() }
        XCTAssertThrowsError(try MaterializeFirmlinks().apply(ctx))
    }

    // MARK: ApfsVolume

    private func volumeRunner(visibleAfter attempts: Int) -> FakeRunner {
        var infoCalls = 0
        return FakeRunner { call in
            switch call.dropFirst().joined(separator: " ") {
            case "info -plist /":
                return .plist(["ParentWholeDisk": "disk3"])
            case "apfs addVolume disk3 APFS Nix -nomount":
                return .ok()
            case "info -plist Nix":
                infoCalls += 1
                if infoCalls >= attempts {
                    return .plist(["VolumeUUID": "AAAA-BBBB", "MountPoint": ""])
                }
                return .fail(1, stderr: "Could not find disk: Nix")
            default:
                return .fail(1, stderr: "unexpected: \(call)")
            }
        }
    }

    func testApfsVolumeAppliesAndCapturesUUIDAfterPolling() throws {
        let runner = volumeRunner(visibleAfter: 3) // async creation: 2 misses
        ctx.runner = runner

        var action = ApfsVolume()
        try action.apply(ctx)

        XCTAssertEqual(action.containerDisk, "disk3")
        XCTAssertEqual(action.volumeUUID, "AAAA-BBBB")
        XCTAssertTrue(
            runner.calls.contains(["\(ApfsVolume.diskutil)", "apfs", "addVolume", "disk3", "APFS", "Nix", "-nomount"]))
    }

    func testApfsVolumeRevertUnmountsAndDeletesWithRetries() throws {
        var deleteAttempts = 0
        let runner = FakeRunner { call in
            switch call.dropFirst().joined(separator: " ") {
            case "info -plist Nix":
                return .plist(["VolumeUUID": "AAAA-BBBB", "MountPoint": "/nix"])
            case "unmount force Nix":
                return .ok()
            case "apfs deleteVolume AAAA-BBBB":
                deleteAttempts += 1
                return deleteAttempts < 3 ? .fail(1, stderr: "in use") : .ok()
            default:
                return .fail(1, stderr: "unexpected: \(call)")
            }
        }
        ctx.runner = runner

        var action = ApfsVolume()
        action.volumeUUID = "AAAA-BBBB"
        try action.revert(ctx)

        XCTAssertEqual(deleteAttempts, 3, "delete retried through the unmount race")
        XCTAssertTrue(runner.calls.contains(["\(ApfsVolume.diskutil)", "unmount", "force", "Nix"]))
    }

    func testApfsVolumeRevertIsANoOpWhenAlreadyGone() throws {
        let runner = FakeRunner { _ in .fail(1, stderr: "Could not find disk: Nix") }
        ctx.runner = runner
        try ApfsVolume().revert(ctx)
        XCTAssertEqual(runner.calls.count, 1, "one probe, no destructive calls")
    }

    // MARK: FstabEntry

    func testFstabEntryWritesUUIDKeyedLine() throws {
        ctx.runner = FakeRunner { _ in .plist(["VolumeUUID": "AAAA-BBBB"]) }

        var action = FstabEntry()
        try action.apply(ctx)

        let text = try String(
            contentsOf: root.appendingPathComponent("etc/fstab"), encoding: .utf8)
        XCTAssertEqual(
            text,
            "UUID=AAAA-BBBB /nix apfs rw,noatime,noauto,nobrowse,nosuid,owners # Added by Nix\n")
        XCTAssertEqual(action.volumeUUID, "AAAA-BBBB")
    }

    func testFstabEntryPreservesOtherLinesOnApplyAndRevert() throws {
        let fstab = root.appendingPathComponent("etc/fstab")
        try FileManager.default.createDirectory(
            at: fstab.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "UUID=OTHER /backup apfs rw\n".write(to: fstab, atomically: true, encoding: .utf8)
        ctx.runner = FakeRunner { _ in .plist(["VolumeUUID": "AAAA-BBBB"]) }

        var action = FstabEntry()
        try action.apply(ctx)
        try action.revert(ctx)

        XCTAssertEqual(
            try String(contentsOf: fstab, encoding: .utf8), "UUID=OTHER /backup apfs rw\n")
    }

    func testFstabPreexistingNixMountIsDetected() throws {
        XCTAssertTrue(FstabEntry.hasNixMount("UUID=X /nix apfs rw\n"))
        XCTAssertFalse(FstabEntry.hasNixMount("# UUID=X /nix apfs rw\n"), "comments don't count")
        XCTAssertFalse(FstabEntry.hasNixMount("UUID=X /nixos apfs rw\n"))
    }

    // MARK: PathsD

    func testPathsDRoundTrip() throws {
        let action = PathsD()
        try action.apply(ctx)
        let url = root.appendingPathComponent("etc/paths.d/nix")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "/opt/nix/bin\n")

        try action.revert(ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPathsDRevertLeavesModifiedFileAlone() throws {
        let url = root.appendingPathComponent("etc/paths.d/nix")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "/usr/odd/path\n".write(to: url, atomically: true, encoding: .utf8)

        try PathsD().revert(ctx)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "never destroy what we did not create")
    }

    // MARK: full plan, end to end against a scratch root

    func testDefaultPlanInstallUninstallRoundTrip() throws {
        var volumeExists = false
        var mountPoint = ""
        ctx.runner = FakeRunner { call in
            let joined = call.dropFirst().joined(separator: " ")
            switch call[0] {
            case MaterializeFirmlinks.apfsUtil:
                try? FileManager.default.createDirectory(
                    at: self.root.appendingPathComponent("nix"),
                    withIntermediateDirectories: true)
                return .ok()
            case EncryptVolume.fdesetup:
                return .ok("false\n")  // unencrypted system: encrypt skips
            case BuildUsers.dseditgroup:
                return .ok()
            case BuildUsers.dscl:
                // isAlreadyDone probes (-read) say "not there"; everything
                // else (create/append/delete) succeeds.
                return call.contains("-read") ? .fail(56) : .ok()
            case TmutilExclusions.tmutil:
                return .ok()
            case VolumeMountService.launchctl:
                switch call.dropFirst().first {
                case "print": return .fail(113)
                case "kickstart":
                    if mountPoint.isEmpty { mountPoint = "/nix" }
                    return .ok()
                default: return .ok()
                }
            default: break
            }
            switch joined {
            case "info -plist /":
                return .plist(["ParentWholeDisk": "disk3"])
            case "apfs addVolume disk3 APFS Nix -nomount":
                volumeExists = true
                return .ok()
            case "info -plist Nix":
                return volumeExists
                    ? .plist([
                        "VolumeUUID": "AAAA-BBBB", "MountPoint": mountPoint,
                        "GlobalPermissionsEnabled": false,
                    ])
                    : .fail(1, stderr: "Could not find disk: Nix")
            case "info -plist /nix":
                return volumeExists
                    ? .plist(["GlobalPermissionsEnabled": false]) : .fail(1)
            case "enableOwnership /nix":
                return .ok()
            case "apfs deleteVolume AAAA-BBBB":
                volumeExists = false
                mountPoint = ""
                return .ok()
            case "unmount force Nix":
                mountPoint = ""
                return .ok()
            default:
                return .fail(1, stderr: "unexpected: \(call.joined(separator: " "))")
            }
        }

        // The payload the .pkg (here: a source dir) provides, including the
        // meson-installed daemon plist the DaemonService action copies.
        let src = root.appendingPathComponent("payload-src")
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: src.appendingPathComponent("Library/LaunchDaemons"),
            withIntermediateDirectories: true)
        try "fake-nix".write(
            to: src.appendingPathComponent("bin/nix"), atomically: true, encoding: .utf8)
        try "<plist/>".write(
            to: src.appendingPathComponent("Library/LaunchDaemons/org.nixos.nix-daemon.plist"),
            atomically: true, encoding: .utf8)

        let engine = Engine(store: LedgerStore(root: root), ctx: ctx)
        try engine.install(plan: defaultPlan(payloadSource: src.path))

        let ledger = try LedgerStore(root: root).load()
        XCTAssertEqual(ledger.actions.count, 15)
        let states = ledger.actions.map(\.state)
        XCTAssertFalse(states.contains(.uncompleted), "everything applied or skipped")
        guard case .apfsVolume(let vol) = ledger.actions[2].action else {
            return XCTFail("expected apfsVolume at index 2")
        }
        XCTAssertEqual(vol.volumeUUID, "AAAA-BBBB")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: ctx.path(DaemonService.installedPlist).path))

        try engine.uninstall()
        XCTAssertFalse(LedgerStore(root: root).exists)
        for path in [
            "/etc/fstab", "/etc/paths.d/nix", "/etc/nix/nix.conf", "/opt/nix",
            DaemonService.installedPlist, VolumeMountService.plistPath,
            SelfHealService.plistPath,
        ] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: ctx.path(path).path),
                "\(path) should be gone")
        }
        XCTAssertFalse(volumeExists, "the APFS volume was deleted")
    }

}
