import Foundation

/// The `nix` line in /etc/synthetic.conf, which makes the
/// read-only APFS system volume synthesize an empty /nix directory at the
/// filesystem apex — the mount point for the Nix store volume.
///
/// Wisdom inherited from the Rust installer:
///   - The trailing newline is load-bearing: apfs.util segfaults parsing a
///     synthetic.conf whose last line is unterminated.
///   - Materializing the firmlink without a reboot (`apfs.util -t`/`-B`) is
///     a SEPARATE action (MaterializeFirmlinks), so this one stays a pure
///     file edit
///     with a pure file-edit revert.
struct SyntheticConf: Codable {
    static let entryName = "nix"

    var summary: String {
        "the '\(Self.entryName)' line in /etc/synthetic.conf"
    }

    private func confURL(_ ctx: Context) -> URL {
        ctx.path("/etc/synthetic.conf")
    }

    /// synthetic.conf entries are `name` or `name<TAB>target`; the first
    /// whitespace-separated token is the created apex name. Matching on the
    /// token (never on a substring) is what keeps us from confusing `nix`
    /// with somebody's `nixos` entry.
    static func hasEntry(in text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
                == entryName
        }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        guard let text = try? String(contentsOf: confURL(ctx), encoding: .utf8) else {
            return false
        }
        return Self.hasEntry(in: text)
    }

    func apply(_ ctx: Context) throws {
        let url = confURL(ctx)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if Self.hasEntry(in: text) {
            return
        }
        // Repair an existing file whose last line is unterminated before
        // appending — and terminate our own line: apfs.util segfaults on a
        // missing trailing newline.
        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        text += Self.entryName + "\n"
        try atomicWrite(text, to: url)
    }

    func revert(_ ctx: Context) throws {
        let url = confURL(ctx)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return // nothing to revert
        }
        let kept = text.split(separator: "\n").filter { line in
            line.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
                != Self.entryName
        }
        if kept.isEmpty {
            try FileManager.default.removeItem(at: url)
        } else {
            try atomicWrite(kept.joined(separator: "\n") + "\n", to: url)
        }
    }
}
