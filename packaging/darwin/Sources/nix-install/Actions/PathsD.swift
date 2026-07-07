import Foundation

/// The canonical PATH mechanism (§11.2a): a one-line file at
/// /etc/paths.d/nix that path_helper folds into every login shell's PATH.
struct PathsD: Codable {
    static let content = "/opt/nix/bin\n"

    var summary: String {
        "/etc/paths.d/nix (PATH entry for /opt/nix/bin)"
    }

    private func fileURL(_ ctx: Context) -> URL {
        ctx.path("/etc/paths.d/nix")
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        (try? String(contentsOf: fileURL(ctx), encoding: .utf8)) == Self.content
    }

    func apply(_ ctx: Context) throws {
        try atomicWrite(Self.content, to: fileURL(ctx))
    }

    func revert(_ ctx: Context) throws {
        let url = fileURL(ctx)
        // Remove only what we wrote; a user-modified file is left in place
        // (never destroy what we did not create).
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        if text == Self.content {
            try FileManager.default.removeItem(at: url)
        } else {
            ctx.log("leaving modified /etc/paths.d/nix in place")
        }
    }
}
