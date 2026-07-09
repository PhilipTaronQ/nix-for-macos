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

/// The fixed set of install actions, as an enum with associated
/// values: Codable is synthesized (the case name is the discriminator), and
/// there is deliberately no open-ended plugin machinery — the Rust
/// installer's typetag ceremony is what this replaces.
///
/// `apply` is mutating: actions capture discovered state (container disk,
/// volume UUID, encryption) into themselves, and the engine persists the
/// mutated action back into the ledger — that captured state is what
/// revert uses.
enum Action: Codable {
    case syntheticConf(SyntheticConf)
    case materializeFirmlinks(MaterializeFirmlinks)
    case apfsVolume(ApfsVolume)
    case fstabEntry(FstabEntry)
    case encryptVolume(EncryptVolume)
    case volumeMountService(VolumeMountService)
    case enableOwnership(EnableOwnership)
    case buildUsers(BuildUsers)
    case tmutilExclusions(TmutilExclusions)
    case payload(Payload)
    case nixConf(NixConf)
    case pathsD(PathsD)
    case manPathsD(ManPathsD)
    case shellInit(ShellInit)
    case daemonService(DaemonService)
    case selfHealService(SelfHealService)

    var summary: String {
        switch self {
        case .syntheticConf(let a): return a.summary
        case .materializeFirmlinks(let a): return a.summary
        case .apfsVolume(let a): return a.summary
        case .fstabEntry(let a): return a.summary
        case .encryptVolume(let a): return a.summary
        case .volumeMountService(let a): return a.summary
        case .enableOwnership(let a): return a.summary
        case .buildUsers(let a): return a.summary
        case .tmutilExclusions(let a): return a.summary
        case .payload(let a): return a.summary
        case .nixConf(let a): return a.summary
        case .pathsD(let a): return a.summary
        case .manPathsD(let a): return a.summary
        case .shellInit(let a): return a.summary
        case .daemonService(let a): return a.summary
        case .selfHealService(let a): return a.summary
        }
    }

    /// Actions the self-heal daemon may re-apply: the file edits macOS
    /// updates are known to clobber. Everything else heals only via a
    /// deliberate reinstall.
    var isRepairable: Bool {
        switch self {
        case .syntheticConf, .nixConf, .pathsD, .manPathsD, .shellInit: return true
        default: return false
        }
    }

    /// The store-layer actions: the APFS volume and everything that makes it
    /// exist, mount, and stay encrypted. A default `uninstall` keeps these —
    /// the store is expensive and a reinstall re-adopts them untouched — so
    /// only `uninstall --purge` reverts them. Everything else is cheap OS
    /// integration (binaries, config, users, daemons) and is always reverted.
    var isStoreLayer: Bool {
        switch self {
        case .syntheticConf, .materializeFirmlinks, .apfsVolume, .fstabEntry,
            .encryptVolume, .volumeMountService, .enableOwnership, .tmutilExclusions:
            return true
        default:
            return false
        }
    }

    /// Actions re-applied on an upgrade — a reinstall detected by the
    /// `org.nixos.nix` receipt already being present. These are the ones that
    /// must react to replaced binaries: restarting the launchd services picks
    /// up the new nix-daemon and repair binaries (the plist already exists, so
    /// the resume loop skips them), and re-running NixConf re-retires any
    /// fragment receipts the re-selected fragment packages recreated. The
    /// volume, users, and store are unchanged by an upgrade and stay skipped.
    var rerunOnUpgrade: Bool {
        switch self {
        case .nixConf, .daemonService, .selfHealService: return true
        default: return false
        }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        switch self {
        case .syntheticConf(let a): return try a.isAlreadyDone(ctx)
        case .materializeFirmlinks(let a): return try a.isAlreadyDone(ctx)
        case .apfsVolume(let a): return try a.isAlreadyDone(ctx)
        case .fstabEntry(let a): return try a.isAlreadyDone(ctx)
        case .encryptVolume(let a): return try a.isAlreadyDone(ctx)
        case .volumeMountService(let a): return try a.isAlreadyDone(ctx)
        case .enableOwnership(let a): return try a.isAlreadyDone(ctx)
        case .buildUsers(let a): return try a.isAlreadyDone(ctx)
        case .tmutilExclusions(let a): return try a.isAlreadyDone(ctx)
        case .payload(let a): return try a.isAlreadyDone(ctx)
        case .nixConf(let a): return try a.isAlreadyDone(ctx)
        case .pathsD(let a): return try a.isAlreadyDone(ctx)
        case .manPathsD(let a): return try a.isAlreadyDone(ctx)
        case .shellInit(let a): return try a.isAlreadyDone(ctx)
        case .daemonService(let a): return try a.isAlreadyDone(ctx)
        case .selfHealService(let a): return try a.isAlreadyDone(ctx)
        }
    }

    mutating func apply(_ ctx: Context) throws {
        switch self {
        case .syntheticConf(let a): try a.apply(ctx)
        case .materializeFirmlinks(let a): try a.apply(ctx)
        case .apfsVolume(var a):
            try a.apply(ctx)
            self = .apfsVolume(a)
        case .fstabEntry(var a):
            try a.apply(ctx)
            self = .fstabEntry(a)
        case .encryptVolume(let a): try a.apply(ctx)
        case .volumeMountService(var a):
            try a.apply(ctx)
            self = .volumeMountService(a)
        case .enableOwnership(let a): try a.apply(ctx)
        case .buildUsers(let a): try a.apply(ctx)
        case .tmutilExclusions(let a): try a.apply(ctx)
        case .payload(let a): try a.apply(ctx)
        case .nixConf(var a):
            try a.apply(ctx)
            self = .nixConf(a)
        case .pathsD(let a): try a.apply(ctx)
        case .manPathsD(let a): try a.apply(ctx)
        case .shellInit(let a): try a.apply(ctx)
        case .daemonService(let a): try a.apply(ctx)
        case .selfHealService(let a): try a.apply(ctx)
        }
    }

    func revert(_ ctx: Context) throws {
        switch self {
        case .syntheticConf(let a): try a.revert(ctx)
        case .materializeFirmlinks(let a): try a.revert(ctx)
        case .apfsVolume(let a): try a.revert(ctx)
        case .fstabEntry(let a): try a.revert(ctx)
        case .encryptVolume(let a): try a.revert(ctx)
        case .volumeMountService(let a): try a.revert(ctx)
        case .enableOwnership(let a): try a.revert(ctx)
        case .buildUsers(let a): try a.revert(ctx)
        case .tmutilExclusions(let a): try a.revert(ctx)
        case .payload(let a): try a.revert(ctx)
        case .nixConf(let a): try a.revert(ctx)
        case .pathsD(let a): try a.revert(ctx)
        case .manPathsD(let a): try a.revert(ctx)
        case .shellInit(let a): try a.revert(ctx)
        case .daemonService(let a): try a.revert(ctx)
        case .selfHealService(let a): try a.revert(ctx)
        }
    }
}

/// The default install plan, in execution order.
func defaultPlan(payloadSource: String? = nil) -> [Action] {
    [
        .syntheticConf(SyntheticConf()),
        .materializeFirmlinks(MaterializeFirmlinks()),
        .apfsVolume(ApfsVolume()),
        .fstabEntry(FstabEntry()),
        .encryptVolume(EncryptVolume()),
        .volumeMountService(VolumeMountService()),
        .enableOwnership(EnableOwnership()),
        .buildUsers(BuildUsers()),
        .tmutilExclusions(TmutilExclusions()),
        .payload(Payload(source: payloadSource)),
        .nixConf(NixConf()),
        .pathsD(PathsD()),
        .manPathsD(ManPathsD()),
        .shellInit(ShellInit()),
        .daemonService(DaemonService()),
        .selfHealService(SelfHealService()),
    ]
}
