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
    /// External tool execution. SystemCommandRunner for real installs;
    /// tests inject fakes; --root trees get a runner that refuses (file
    /// actions work, diskutil-class actions cannot sanely target a scratch
    /// tree).
    var runner: CommandRunner = SystemCommandRunner()
    /// Multiplier for poll/retry sleeps; tests set 0.
    var pollScale = 1

    init(root: URL = URL(fileURLWithPath: "/", isDirectory: true), dryRun: Bool = false) {
        self.root = root
        self.dryRun = dryRun
        if root.path != "/" {
            runner = RefusingCommandRunner()
        }
    }

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
///
/// `apply` is mutating: actions capture discovered state (container disk,
/// volume UUID) into themselves, and the engine persists the mutated action
/// back into the ledger — that captured state is what revert uses.
enum Action: Codable {
    case syntheticConf(SyntheticConf)
    case materializeFirmlinks(MaterializeFirmlinks)
    case apfsVolume(ApfsVolume)
    case fstabEntry(FstabEntry)
    case pathsD(PathsD)
    // Coming per DESIGN.md §11.2: encryptVolume, volumeMountService,
    // enableOwnership, buildUsers, tmutilExclusions, payload, nixConf,
    // shellInit, daemonService, selfHealService.

    var summary: String {
        switch self {
        case .syntheticConf(let a): return a.summary
        case .materializeFirmlinks(let a): return a.summary
        case .apfsVolume(let a): return a.summary
        case .fstabEntry(let a): return a.summary
        case .pathsD(let a): return a.summary
        }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        switch self {
        case .syntheticConf(let a): return try a.isAlreadyDone(ctx)
        case .materializeFirmlinks(let a): return try a.isAlreadyDone(ctx)
        case .apfsVolume(let a): return try a.isAlreadyDone(ctx)
        case .fstabEntry(let a): return try a.isAlreadyDone(ctx)
        case .pathsD(let a): return try a.isAlreadyDone(ctx)
        }
    }

    mutating func apply(_ ctx: Context) throws {
        switch self {
        case .syntheticConf(let a):
            try a.apply(ctx)
        case .materializeFirmlinks(let a):
            try a.apply(ctx)
        case .apfsVolume(var a):
            try a.apply(ctx)
            self = .apfsVolume(a)
        case .fstabEntry(var a):
            try a.apply(ctx)
            self = .fstabEntry(a)
        case .pathsD(let a):
            try a.apply(ctx)
        }
    }

    func revert(_ ctx: Context) throws {
        switch self {
        case .syntheticConf(let a): try a.revert(ctx)
        case .materializeFirmlinks(let a): try a.revert(ctx)
        case .apfsVolume(let a): try a.revert(ctx)
        case .fstabEntry(let a): try a.revert(ctx)
        case .pathsD(let a): try a.revert(ctx)
        }
    }
}

/// The default install plan, in §11.2 order.
func defaultPlan() -> [Action] {
    [
        .syntheticConf(SyntheticConf()),
        .materializeFirmlinks(MaterializeFirmlinks()),
        .apfsVolume(ApfsVolume()),
        .fstabEntry(FstabEntry()),
        .pathsD(PathsD()),
    ]
}
