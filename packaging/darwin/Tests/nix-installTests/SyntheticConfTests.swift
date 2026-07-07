import Foundation
import XCTest

@testable import nix_install

final class SyntheticConfTests: XCTestCase {
    var root: URL!
    var ctx: Context!
    let action = SyntheticConf()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("synthetic-conf-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ctx = Context(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var conf: URL { root.appendingPathComponent("etc/synthetic.conf") }

    private func write(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: conf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: conf, atomically: true, encoding: .utf8)
    }

    func testApplyPreservesExistingEntries() throws {
        try write("mnt\thomes\n")
        try action.apply(ctx)
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "mnt\thomes\nnix\n")
    }

    func testApplyRepairsMissingTrailingNewline() throws {
        // An unterminated last line would make apfs.util segfault after our
        // append; apply must terminate it first.
        try write("mnt\thomes")
        try action.apply(ctx)
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "mnt\thomes\nnix\n")
    }

    func testEntryMatchingIsTokenExact() throws {
        try write("nixos\n")
        XCTAssertFalse(SyntheticConf.hasEntry(in: "nixos\n"))
        XCTAssertTrue(SyntheticConf.hasEntry(in: "nix\tsomewhere\n"))
        XCTAssertTrue(SyntheticConf.hasEntry(in: "nix\n"))

        try action.apply(ctx)
        XCTAssertEqual(
            try String(contentsOf: conf, encoding: .utf8), "nixos\nnix\n",
            "a 'nixos' entry is not our entry")
    }

    func testApplyIsIdempotent() throws {
        try action.apply(ctx)
        try action.apply(ctx)
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "nix\n")
    }

    func testRevertKeepsOtherEntries() throws {
        try write("mnt\thomes\nnix\n")
        try action.revert(ctx)
        XCTAssertEqual(try String(contentsOf: conf, encoding: .utf8), "mnt\thomes\n")
    }

    func testRevertRemovesFileWhenOnlyOurEntry() throws {
        try write("nix\n")
        try action.revert(ctx)
        XCTAssertFalse(FileManager.default.fileExists(atPath: conf.path))
    }

    func testRevertWithoutFileIsANoOp() throws {
        XCTAssertNoThrow(try action.revert(ctx))
    }
}
