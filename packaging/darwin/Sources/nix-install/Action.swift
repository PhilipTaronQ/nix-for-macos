import Foundation

/// Execution context. `root` is "/" for real installs and a scratch
/// directory in tests — every action resolves system paths through it, so
/// the whole engine (uninstall included) is exercisable without touching
/// the machine. That property is load-bearing: once Nix builds itself and
/// the bootstrap Nix goes away, CI will install *and uninstall* between
/// runs, using exactly this code path.
struct Context {
    var root = URL(fileURLWithPath: "/", isDirectory: true)
    var dryRun = false

    /// Resolve an absolute system path ("/etc/synthetic.conf") under root.
    func path(_ absolute: String) -> URL {
        var relative = absolute
        while relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return root.appendingPathComponent(relative)
    }

    func log(_ message: String) {
        print(message)
    }
}

/// The fixed set of install actions (§11.2), as an enum with associated
/// values: Codable is synthesized (the case name is the discriminator), and
/// there is deliberately no open-ended plugin machinery — the Rust
/// installer's typetag ceremony is what this replaces.
enum Action: Codable {
    case syntheticConf(SyntheticConf)
    // Coming per DESIGN.md §11.2:
    // case apfsVolume(ApfsVolume)          // step 3
    // case fstabEntry(FstabEntry)          // step 4
    // case encryptVolume(EncryptVolume)    // step 5
    // ... etc.

    var summary: String {
        switch self {
        case .syntheticConf(let a): return a.summary
        }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        switch self {
        case .syntheticConf(let a): return try a.isAlreadyDone(ctx)
        }
    }

    func apply(_ ctx: Context) throws {
        switch self {
        case .syntheticConf(let a): try a.apply(ctx)
        }
    }

    func revert(_ ctx: Context) throws {
        switch self {
        case .syntheticConf(let a): try a.revert(ctx)
        }
    }
}

/// The default install plan, in §11.2 order.
func defaultPlan() -> [Action] {
    [
        .syntheticConf(SyntheticConf())
    ]
}
