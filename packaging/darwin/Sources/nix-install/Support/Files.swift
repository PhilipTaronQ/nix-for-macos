import Foundation

/// Write-temp-then-rename, the same safety net the Rust installer uses for
/// every system file it touches: the destination is never observable in a
/// half-written state, and there is no `.bak` litter.
func atomicWrite(_ text: String, to url: URL, mode: Int = 0o644) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
    try text.data(using: .utf8)!.write(to: tmp)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
}
