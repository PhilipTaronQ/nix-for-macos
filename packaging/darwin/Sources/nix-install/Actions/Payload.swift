import Foundation

/// The /opt/nix payload tree (binaries, helpers, man pages). The daemon
/// plist is deliberately absent: DaemonService writes its own.
///
/// In the .pkg flow, pkgbuild lays the files down and this action runs
/// with no source, recording ownership of the tree in the ledger; in a
/// tarball/CI flow, `source` points at an extracted tree and apply copies
/// it into place. Either way the tree is ours: isAlreadyDone is always
/// false so uninstall always removes /opt/nix.
struct Payload: Codable {
    static let destination = "/opt/nix"

    /// Optional source tree to copy from (nil = the .pkg already did).
    var source: String?

    var summary: String {
        "the /opt/nix payload tree"
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        false // we own this tree's lifecycle unconditionally
    }

    func apply(_ ctx: Context) throws {
        let dest = ctx.path(Self.destination)
        if let source {
            let from = URL(fileURLWithPath: source, isDirectory: true)
            guard FileManager.default.fileExists(atPath: from.path) else {
                throw InstallActionError.preconditionFailed(
                    "payload source '\(source)' does not exist")
            }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: from, to: dest)
        } else {
            guard
                FileManager.default.fileExists(
                    atPath: dest.appendingPathComponent("bin/nix").path)
            else {
                throw InstallActionError.preconditionFailed(
                    "\(Self.destination)/bin/nix is missing — the package payload "
                        + "should have been installed before this step")
            }
        }
    }

    func revert(_ ctx: Context) throws {
        let dest = ctx.path(Self.destination)
        if FileManager.default.fileExists(atPath: dest.path) {
            // Unlinking a running executable's file is safe on APFS: this
            // is why the installer binary living at
            // /opt/nix/libexec/nix-install can delete its own tree, where
            // the Rust installer (inside the /nix volume it deletes) needs
            // a copy-self-to-tmp dance.
            try FileManager.default.removeItem(at: dest)
        }
    }
}
