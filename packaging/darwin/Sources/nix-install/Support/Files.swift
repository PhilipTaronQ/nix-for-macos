#if canImport(Darwin)
    import Darwin
#else
    import Glibc  // the engine is testable on Linux: scratch roots, fake runners
#endif
import Foundation

/// Write-temp-then-rename, the same safety net the Rust installer uses for
/// every system file it touches: the destination is never observable in a
/// half-written state, and there is no `.bak` litter.
func atomicWrite(_ text: String, to url: URL, mode: Int = 0o644) throws {
    try atomicWriteData(text.data(using: .utf8)!, to: url, mode: mode)
}

func atomicWriteData(_ data: Data, to url: URL, mode: Int = 0o644) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())")
    try data.write(to: tmp)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: tmp.path)
    // rename(2), not FileManager.replaceItemAt: plain POSIX rename is
    // atomic everywhere and, unlike corelibs-foundation's replaceItemAt,
    // does not require the destination to already exist.
    guard rename(tmp.path, url.path) == 0 else {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
    }
}
