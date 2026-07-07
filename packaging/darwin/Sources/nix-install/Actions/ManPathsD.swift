import Foundation

/// The man(1) sibling of PathsD: /etc/manpaths.d/nix, which path_helper
/// folds into MANPATH so `man nix` works from any login shell.
struct ManPathsD: Codable {
    static let content = "/opt/nix/share/man\n"

    var summary: String {
        "/etc/manpaths.d/nix (MANPATH entry for /opt/nix/share/man)"
    }

    private func fileURL(_ ctx: Context) -> URL {
        ctx.path("/etc/manpaths.d/nix")
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        (try? String(contentsOf: fileURL(ctx), encoding: .utf8)) == Self.content
    }

    func apply(_ ctx: Context) throws {
        try atomicWrite(Self.content, to: fileURL(ctx))
    }

    func revert(_ ctx: Context) throws {
        let url = fileURL(ctx)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        if text == Self.content {
            try FileManager.default.removeItem(at: url)
        } else {
            ctx.log("leaving modified /etc/manpaths.d/nix in place")
        }
    }
}
