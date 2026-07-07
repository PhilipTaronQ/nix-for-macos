import Foundation

/// The /etc/fstab line that mounts the Nix volume at /nix —
/// keyed by UUID, never by name (upstream issue #212), with the mount
/// options the Rust installer settled on.
struct FstabEntry: Codable {
    static let marker = "# Added by Nix"
    static let options = "rw,noatime,noauto,nobrowse,nosuid,owners"

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

        let url = fstabURL(ctx)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if Self.hasNixMount(text) {
            return
        }
        if !text.isEmpty && !text.hasSuffix("\n") {
            text += "\n"
        }
        text += "UUID=\(uuid) /nix apfs \(Self.options) \(Self.marker)\n"
        try atomicWrite(text, to: url)
    }

    func revert(_ ctx: Context) throws {
        let url = fstabURL(ctx)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return
        }
        let kept = text.split(separator: "\n").filter { line in
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            let mountsNix = !line.hasPrefix("#") && fields.dropFirst().first == "/nix"
            return !mountsNix
        }
        if kept.isEmpty {
            // macOS has no /etc/fstab by default; ours was the only content.
            try FileManager.default.removeItem(at: url)
        } else {
            try atomicWrite(kept.joined(separator: "\n") + "\n", to: url)
        }
    }
}
