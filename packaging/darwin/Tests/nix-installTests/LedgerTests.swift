import Foundation
import XCTest

@testable import nix_install

final class LedgerTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nix-install-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let miniPlan: [Action] = [.syntheticConf(SyntheticConf())]

    private func engine() -> Engine {
        Engine(store: LedgerStore(root: root), ctx: Context(root: root))
    }

    func testInstallWritesLedgerAndAppliesActions() throws {
        try engine().install(plan: miniPlan)

        let conf = root.appendingPathComponent("etc/synthetic.conf")
        let text = try String(contentsOf: conf, encoding: .utf8)
        XCTAssertEqual(text, "nix\n", "the trailing newline is load-bearing")

        let ledger = try LedgerStore(root: root).load()
        XCTAssertEqual(ledger.format, Ledger.expectedFormat)
        XCTAssertEqual(ledger.actions.count, 1)
        XCTAssertEqual(ledger.actions[0].state, .completed)
    }

    func testReinstallIsIdempotent() throws {
        try engine().install(plan: miniPlan)
        try engine().install(plan: miniPlan) // resumes; nothing to do

        let conf = root.appendingPathComponent("etc/synthetic.conf")
        let text = try String(contentsOf: conf, encoding: .utf8)
        XCTAssertEqual(text, "nix\n", "no duplicate entries on re-install")
    }

    func testPreexistingStateIsSkippedAndNeverReverted() throws {
        // Simulate a machine that already has the nix line (e.g. another
        // installer put it there): our install marks it skipped, and our
        // uninstall must leave it alone.
        let conf = root.appendingPathComponent("etc/synthetic.conf")
        try FileManager.default.createDirectory(
            at: conf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "nix\n".write(to: conf, atomically: true, encoding: .utf8)

        try engine().install(plan: miniPlan)
        var ledger = try LedgerStore(root: root).load()
        XCTAssertEqual(ledger.actions[0].state, .skipped)

        // Uninstall with only skipped entries: clean, ledger removed,
        // pre-existing state untouched.
        try engine().uninstall()
        XCTAssertTrue(FileManager.default.fileExists(atPath: conf.path))
        XCTAssertFalse(LedgerStore(root: root).exists)
    }

    func testPurgeUninstallRevertsInReverseAndRemovesLedger() throws {
        // syntheticConf is store-layer, so full teardown needs --purge; a
        // soft uninstall keeps it (covered in VolumeActionsTests).
        try engine().install(plan: miniPlan)
        try engine().uninstall(purge: true)

        let conf = root.appendingPathComponent("etc/synthetic.conf")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: conf.path),
            "file we created (with only our line) is removed entirely")
        XCTAssertFalse(LedgerStore(root: root).exists, "clean uninstall removes the ledger")
    }

    func testUninstallWithoutLedgerRefuses() {
        XCTAssertThrowsError(try engine().uninstall()) { error in
            guard case LedgerError.missingLedger = error else {
                return XCTFail("expected missingLedger, got \(error)")
            }
        }
    }

    func testForeignLedgerIsRefused() throws {
        let store = LedgerStore(root: root)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"version": 1, "actions": [], "planner": "macos"}"#
            .write(to: store.fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try engine().install(plan: miniPlan)) { error in
            guard case LedgerError.foreignLedger = error else {
                return XCTFail("expected foreignLedger, got \(error)")
            }
        }
        XCTAssertThrowsError(try engine().uninstall()) { error in
            guard case LedgerError.foreignLedger = error else {
                return XCTFail("expected foreignLedger, got \(error)")
            }
        }
    }

    func testNewerLedgerVersionIsRefused() throws {
        let store = LedgerStore(root: root)
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"format": "\(Ledger.expectedFormat)", "version": 999, "actions": []}
        """.write(to: store.fileURL, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try engine().uninstall()) { error in
            guard case LedgerError.unsupportedVersion = error else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testLedgerRoundTripsThroughJSON() throws {
        let store = LedgerStore(root: root)
        var ledger = Ledger(plan: miniPlan)
        ledger.actions[0].state = .completed
        try store.save(ledger)

        let reloaded = try store.load()
        XCTAssertEqual(reloaded.actions.count, 1)
        XCTAssertEqual(reloaded.actions[0].state, .completed)
        XCTAssertEqual(reloaded.actions[0].action.summary, ledger.actions[0].action.summary)
    }

    func testDryRunTouchesNothing() throws {
        var ctx = Context(root: root)
        ctx.dryRun = true
        let engine = Engine(store: LedgerStore(root: root), ctx: ctx)
        try engine.install(plan: miniPlan)

        let conf = root.appendingPathComponent("etc/synthetic.conf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: conf.path))
        XCTAssertFalse(LedgerStore(root: root).exists, "dry-run writes nothing")
    }

    func testUpgradeReappliesUpgradeSensitiveActions() throws {
        // A completed ledger + the org.nixos.nix receipt present (the pkgutil
        // upgrade key) ⇒ the rerunOnUpgrade actions re-apply even though
        // they're already .completed. NixConf is one of them, so its receipt
        // work is observable.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("opt/nix/etc/includes.install"),
            withIntermediateDirectories: true)
        try "experimental-features = nix-command flakes\n".write(
            to: root.appendingPathComponent("opt/nix/etc/includes.install/flakes.conf"),
            atomically: true, encoding: .utf8)

        let store = LedgerStore(root: root)
        var ledger = Ledger(plan: [.nixConf(NixConf()), .pathsD(PathsD())])
        ledger.actions[0].state = .skipped  // nothing to wire at first install
        ledger.actions[1].state = .completed
        try store.save(ledger)

        var ctx = Context(root: root)
        let runner = FakeRunner { _ in .ok() }  // pkg-info succeeds ⇒ prior install
        ctx.runner = runner
        try Engine(store: store, ctx: ctx).install(plan: [.nixConf(NixConf()), .pathsD(PathsD())])

        XCTAssertTrue(
            runner.calls.contains { $0.contains("--pkg-info") && $0.contains("org.nixos.nix") },
            "install reads the receipt to detect an upgrade")
        let confText = try String(
            contentsOf: root.appendingPathComponent("etc/nix/nix.conf"), encoding: .utf8)
        XCTAssertTrue(
            confText.contains("!include /opt/nix/etc/includes/flakes.conf"),
            "the upgrade pass re-runs NixConf, wiring the staged fragment")
        let after = try LedgerStore(root: root).load()
        XCTAssertEqual(
            after.actions[0].state, .completed,
            "a re-applied action is marked completed so uninstall reverts it (and cleans /etc/nix)")
    }
}
