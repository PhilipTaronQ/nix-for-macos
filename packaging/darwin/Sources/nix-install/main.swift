#if canImport(Darwin)
    import Darwin
#else
    import Glibc  // the engine is testable on Linux: scratch roots, fake runners
#endif
import Foundation

/// nix-install — the macOS installer engine.
///
///   nix-install install    apply the default plan (forward, fail-fast)
///   nix-install uninstall  reverse-replay the ledger (best-effort)
///   nix-install plan       show the plan / ledger states, change nothing
///
/// Options:
///   --root PATH   operate on a filesystem tree other than / (testing; no
///                 root privileges required)
///   --dry-run     log what would happen; write no system state
///
///   nix-install repair     re-apply drifted repairable actions (self-heal)

let usage = """
usage: nix-install <install|uninstall|plan|repair> [--root PATH] [--dry-run] [--payload-source PATH]
"""

var root = URL(fileURLWithPath: "/", isDirectory: true)
var dryRun = false
var payloadSource: String?
var command: String?

var argv = Array(CommandLine.arguments.dropFirst())
while !argv.isEmpty {
    let arg = argv.removeFirst()
    switch arg {
    case "--root":
        guard !argv.isEmpty else {
            FileHandle.standardError.write(Data("--root needs a path\n".utf8))
            exit(64)
        }
        root = URL(fileURLWithPath: argv.removeFirst(), isDirectory: true)
    case "--dry-run":
        dryRun = true
    case "--payload-source":
        guard !argv.isEmpty else {
            FileHandle.standardError.write(Data("--payload-source needs a path\n".utf8))
            exit(64)
        }
        payloadSource = argv.removeFirst()
    case "install", "uninstall", "plan", "repair":
        command = arg
    default:
        FileHandle.standardError.write(Data("unknown argument '\(arg)'\n\(usage)\n".utf8))
        exit(64)
    }
}

guard let command else {
    FileHandle.standardError.write(Data((usage + "\n").utf8))
    exit(64)
}

let ctx = Context(root: root, dryRun: dryRun)
let store = LedgerStore(root: root)
let engine = Engine(store: store, ctx: ctx)

func requireRootIfReal() {
    if root.path == "/" && !dryRun && geteuid() != 0 {
        FileHandle.standardError.write(Data("\(LedgerError.mustBeRoot)\n".utf8))
        exit(77)
    }
}

do {
    switch command {
    case "install":
        requireRootIfReal()
        try engine.install(plan: defaultPlan(payloadSource: payloadSource))
        print("install complete; ledger: \(store.fileURL.path)")
    case "uninstall":
        requireRootIfReal()
        try engine.uninstall()
        print("uninstall complete")
    case "plan":
        if store.exists {
            let ledger = try store.load()
            for entry in ledger.actions {
                print("[\(entry.state.rawValue)] \(entry.action.summary)")
            }
        } else {
            for action in defaultPlan(payloadSource: payloadSource) {
                print("[planned] \(action.summary)")
            }
        }
    case "repair":
        requireRootIfReal()
        try engine.repair()
        print("repair complete")
    default:
        fatalError("unreachable")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
