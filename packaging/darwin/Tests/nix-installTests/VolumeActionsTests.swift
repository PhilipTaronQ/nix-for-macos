import Foundation
import XCTest

@testable import nix_install

/// A scripted CommandRunner: records every invocation, answers via a
/// handler. Reference semantics so tests can assert on calls afterwards.
final class FakeRunner: CommandRunner {
    var calls: [[String]] = []
    var handler: ([String]) -> CommandResult

    init(_ handler: @escaping ([String]) -> CommandResult) {
        self.handler = handler
    }

    func run(_ program: String, _ arguments: [String], stdin: Data?) throws -> CommandResult {
        let call = [program] + arguments
        calls.append(call)
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
        ctx.runner = FakeRunner { call in
            let joined = call.dropFirst().joined(separator: " ")
            switch joined {
            case "-t", "-B":
                // apfs.util: simulate the firmlink appearing.
                try? FileManager.default.createDirectory(
                    at: self.root.appendingPathComponent("nix"),
                    withIntermediateDirectories: true)
                return .ok()
            case "info -plist /":
                return .plist(["ParentWholeDisk": "disk3"])
            case "apfs addVolume disk3 APFS Nix -nomount":
                volumeExists = true
                return .ok()
            case "info -plist Nix":
                // A faithful diskutil: the volume is only queryable once it
                // has actually been created (and again not after deletion).
                return volumeExists
                    ? .plist(["VolumeUUID": "AAAA-BBBB", "MountPoint": ""])
                    : .fail(1, stderr: "Could not find disk: Nix")
            case "apfs deleteVolume AAAA-BBBB":
                volumeExists = false
                return .ok()
            default:
                return .fail(1, stderr: "unexpected: \(joined)")
            }
        }
        let engine = Engine(store: LedgerStore(root: root), ctx: ctx)

        try engine.install(plan: defaultPlan())
        let ledger = try LedgerStore(root: root).load()
        XCTAssertEqual(ledger.actions.count, 5)
        XCTAssertTrue(ledger.actions.allSatisfy { $0.state == .completed })
        // Captured state made it into the persisted ledger.
        guard case .apfsVolume(let vol) = ledger.actions[2].action else {
            return XCTFail("expected apfsVolume at index 2")
        }
        XCTAssertEqual(vol.volumeUUID, "AAAA-BBBB")

        try engine.uninstall()
        XCTAssertFalse(LedgerStore(root: root).exists)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/fstab").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("etc/paths.d/nix").path))
    }
}
