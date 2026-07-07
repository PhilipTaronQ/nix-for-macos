import Foundation

/// /etc/nix configuration — the deliberate inversion of the DetSys
/// installer's split: a pristine nix.conf containing only the
/// !include, with every managed setting in nix.install.conf. The user's
/// nix.conf edits survive uninstall; upstream's filename stays unclaimed.
struct NixConf: Codable {
    static let confContent = "!include nix.install.conf\n"
    static let installConfContent = """
        # Written by the Nix installer; do not edit (edit nix.conf instead —
        # your settings there take precedence and survive uninstall).
        build-users-group = nixbld
        experimental-features = nix-command flakes
        """ + "\n"

    var summary: String {
        "/etc/nix/nix.conf (!include) + nix.install.conf (managed settings)"
    }

    private func confURL(_ ctx: Context) -> URL { ctx.path("/etc/nix/nix.conf") }
    private func installConfURL(_ ctx: Context) -> URL { ctx.path("/etc/nix/nix.install.conf") }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        (try? String(contentsOf: confURL(ctx), encoding: .utf8)) == Self.confContent
            && (try? String(contentsOf: installConfURL(ctx), encoding: .utf8))
                == Self.installConfContent
    }

    func apply(_ ctx: Context) throws {
        if let existing = try? String(contentsOf: confURL(ctx), encoding: .utf8),
            existing != Self.confContent
        {
            // A foreign /etc/nix/nix.conf means a prior Nix installation —
            // exactly what the pre-flight posture refuses to trample.
            throw InstallActionError.preconditionFailed(
                "/etc/nix/nix.conf already exists and was not written by this installer; "
                    + "remove the previous Nix installation first")
        }
        try atomicWrite(Self.installConfContent, to: installConfURL(ctx))
        try atomicWrite(Self.confContent, to: confURL(ctx))
    }

    func revert(_ ctx: Context) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: installConfURL(ctx))
        // nix.conf goes only if it is still byte-for-byte ours; a user who
        // added settings keeps their file (the !include target being gone
        // is harmless: nix warns, nothing breaks).
        if (try? String(contentsOf: confURL(ctx), encoding: .utf8)) == Self.confContent {
            try? fm.removeItem(at: confURL(ctx))
        }
        // Remove /etc/nix if we emptied it.
        let dir = ctx.path("/etc/nix")
        if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
            try? fm.removeItem(at: dir)
        }
    }
}
