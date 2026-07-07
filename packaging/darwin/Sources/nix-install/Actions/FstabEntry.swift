import Foundation

/// The /etc/fstab line that mounts the Nix volume at /nix —
/// keyed by UUID, never by name (upstream issue #212), with the mount
/// options the Rust installer settled on.
///
/// On a real install /etc/fstab is edited through `vifs`, the only sanctioned
/// way to mutate it: it takes the advisory lock the mount machinery expects
/// and, crucially, rewrites the file in place. A direct `removeItem`/rename
/// fails with EPERM even as root once macOS has flagged the file (observed on
/// a FileVault-enabled Mac during uninstall). Against a `--root` scratch tree
/// there is no fstab to protect, so tests take a plain file-I/O path.
struct FstabEntry: Codable {
    static let marker = "# Added by Nix"
    static let options = "rw,noatime,noauto,nobrowse,nosuid,owners"
    static let env = "/usr/bin/env"
    static let vifs = "/usr/sbin/vifs"

    var volumeName = "Nix"
    /// Captured at apply time (from diskutil) for precise revert.
    var volumeUUID: String?

    var summary: String {
        "the /nix mount entry in /etc/fstab"
    }

    private func fstabURL(_ ctx: Context) -> URL {
        ctx.path("/etc/fstab")
    }

    /// Any line whose second whitespace field is /nix — ours or not.
    static func hasNixMount(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            !line.hasPrefix("#") && line.split(separator: " ", omittingEmptySubsequences: true)
                .dropFirst().first == "/nix"
        }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        guard let text = try? String(contentsOf: fstabURL(ctx), encoding: .utf8) else {
            return false
        }
        return Self.hasNixMount(text)
    }

    mutating func apply(_ ctx: Context) throws {
        let info = ApfsVolume.plist(
            try ctx.runner.runChecked(
                ApfsVolume.diskutil, ["info", "-plist", volumeName]
            ).stdout)
        guard let uuid = info["VolumeUUID"] as? String, !uuid.isEmpty else {
            throw InstallActionError.preconditionFailed(
                "no VolumeUUID for '\(volumeName)' — was the volume created?")
        }
        volumeUUID = uuid
        let line = "UUID=\(uuid) /nix apfs \(Self.options) \(Self.marker)"

        if isRealRoot(ctx) {
            // Drop any stale /nix mount, then append ours — idempotent, and
            // never touching the file except through vifs.
            try editRealFstab(ctx, append: line)
            return
        }

        // Scratch tree (tests / --root): plain file I/O, no system tool.
        let url = fstabURL(ctx)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if Self.hasNixMount(text) {
            return
        }
        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        text += line + "\n"
        try atomicWrite(text, to: url)
    }

    func revert(_ ctx: Context) throws {
        if isRealRoot(ctx) {
            // Rewrite through vifs, dropping the /nix line. Never unlink: an
            // empty fstab is macOS's default state, and the unlink is exactly
            // what hit EPERM.
            try editRealFstab(ctx, append: nil)
            return
        }

        let url = fstabURL(ctx)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let kept = Self.withoutNixMounts(text)
        if kept.isEmpty {
            // macOS has no /etc/fstab by default; ours was the only content.
            try FileManager.default.removeItem(at: url)
        } else {
            try atomicWrite(kept.joined(separator: "\n") + "\n", to: url)
        }
    }

    private func isRealRoot(_ ctx: Context) -> Bool {
        ctx.root.path == "/"
    }

    /// Lines that are not a /nix mount (comments and other mounts survive).
    static func withoutNixMounts(_ text: String) -> [String] {
        text.split(separator: "\n").map(String.init).filter { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            let mountsNix = !line.hasPrefix("#") && fields.dropFirst().first == "/nix"
            return !mountsNix
        }
    }

    /// Edit the real /etc/fstab through vifs: strip every /nix mount line and,
    /// if `append` is given, add it back. vifs invokes `$EDITOR <tempfile>`,
    /// so the edit is expressed as a throwaway shell script.
    private func editRealFstab(_ ctx: Context, append line: String?) throws {
        // awk keeps comment lines and any mount that is not /nix.
        var body = "#!/bin/sh\nset -e\n"
        body += "awk 'substr($1,1,1)==\"#\" || $2!=\"/nix\"' \"$1\" > \"$1.nixtmp\"\n"
        body += "mv \"$1.nixtmp\" \"$1\"\n"
        if let line {
            body += "printf '%s\\n' '\(line)' >> \"$1\"\n"
        }
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nix-fstab-\(UUID().uuidString).sh")
        try body.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        try ctx.runner.runChecked(Self.env, ["EDITOR=\(scriptURL.path)", Self.vifs])
    }
}
