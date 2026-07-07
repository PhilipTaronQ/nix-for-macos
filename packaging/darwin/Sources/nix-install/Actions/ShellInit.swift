import Foundation

/// §11.2 step 12: marker-delimited PATH/profile fragments in the system
/// shell init files. Never writes through a symlink (a symlinked /etc/zshrc
/// means nix-darwin owns it — configure_shell_profile.rs:44).
struct ShellInit: Codable {
    static let files = ["/etc/bashrc", "/etc/zshrc"]
    static let begin = "# Nix"
    static let end = "# End Nix"
    static let fragment = """
        # Nix
        if [ -d /nix/var/nix/profiles/default/bin ]; then
            export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
        fi
        # End Nix
        """ + "\n"

    var summary: String {
        "shell init fragments in /etc/bashrc and /etc/zshrc"
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        Self.files.allSatisfy { file in
            let url = ctx.path(file)
            if isSymlink(url) {
                return true // not ours to manage
            }
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.contains(Self.fragment)
        }
    }

    func apply(_ ctx: Context) throws {
        for file in Self.files {
            let url = ctx.path(file)
            if isSymlink(url) {
                ctx.log("skipping \(file): it is a symlink (nix-darwin?)")
                continue
            }
            var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains(Self.fragment) {
                continue
            }
            if !text.isEmpty && !text.hasSuffix("\n") {
                text += "\n"
            }
            text += Self.fragment
            try atomicWrite(text, to: url)
        }
    }

    func revert(_ ctx: Context) throws {
        for file in Self.files {
            let url = ctx.path(file)
            if isSymlink(url) {
                continue
            }
            guard var text = try? String(contentsOf: url, encoding: .utf8),
                let range = text.range(of: Self.fragment, options: .backwards)
            else { continue }
            text.removeSubrange(range)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try FileManager.default.removeItem(at: url)
            } else {
                try atomicWrite(text, to: url)
            }
        }
    }
}
