import Foundation

/// §11.2 step 8: the nixbld group and _nixbld1…N build users.
///
/// Inherited wisdom (create_user.rs):
///   - UID/GID base 350 — macOS Sequoia squatted the old 300 range.
///   - dscl create is flaky (eNotYetImplemented -14988 / exit 140, or
///     SIGKILL): retry each invocation.
///   - dscl is not thread-safe: users are created strictly sequentially.
///   - User deletion legitimately fails on ephemeral/CI Macs (no secure
///     token, no GUI login): tolerated, never fails the uninstall.
struct BuildUsers: Codable {
    static let dscl = "/usr/bin/dscl"
    static let dseditgroup = "/usr/sbin/dseditgroup"

    var groupName = "nixbld"
    var userPrefix = "_nixbld"
    var gid = 350
    var uidBase = 350
    var count = 32

    var summary: String {
        "the \(groupName) group and \(userPrefix)1…\(count) build users"
    }

    private func retryDscl(_ ctx: Context, _ args: [String]) throws {
        // Exit 140 wraps eNotYetImplemented; 137/9 is SIGKILL flakiness.
        try retrying(times: 5, delayMilliseconds: 500, ctx) {
            let r = try ctx.runner.run(Self.dscl, args)
            if !r.ok {
                throw CommandError.failed(
                    program: Self.dscl, arguments: args, status: r.status, stderr: r.stderrText)
            }
        }
    }

    func isAlreadyDone(_ ctx: Context) throws -> Bool {
        guard let g = try? ctx.runner.run(Self.dscl, [".", "-read", "/Groups/\(groupName)"]),
            g.ok,
            let u = try? ctx.runner.run(Self.dscl, [".", "-read", "/Users/\(userPrefix)1"]),
            u.ok
        else { return false }
        return true
    }

    func apply(_ ctx: Context) throws {
        try ctx.runner.runChecked(
            Self.dseditgroup,
            [
                "-o", "create",
                "-r", "Nix build group for nix-daemon",
                "-i", String(gid),
                groupName,
            ])

        // Sequential on purpose; see the type comment.
        for index in 1...count {
            let name = "\(userPrefix)\(index)"
            let path = "/Users/\(name)"
            try retryDscl(ctx, [".", "-create", path])
            try retryDscl(ctx, [".", "-create", path, "UniqueID", String(uidBase + index)])
            try retryDscl(ctx, [".", "-create", path, "PrimaryGroupID", String(gid)])
            try retryDscl(ctx, [".", "-create", path, "NFSHomeDirectory", "/var/empty"])
            try retryDscl(ctx, [".", "-create", path, "UserShell", "/sbin/nologin"])
            try retryDscl(ctx, [".", "-create", path, "RealName", "Nix build user \(index)"])
            try retryDscl(ctx, [".", "-create", path, "IsHidden", "1"])
            try retryDscl(
                ctx, [".", "-append", "/Groups/\(groupName)", "GroupMembership", name])
        }
    }

    func revert(_ ctx: Context) throws {
        for index in 1...count {
            let name = "\(userPrefix)\(index)"
            let r = try ctx.runner.run(Self.dscl, [".", "-delete", "/Users/\(name)"])
            // 40 wraps -14120 (no secure token / ephemeral Mac); 185 wraps
            // -14009 (already gone). Both fine; anything else is logged
            // but still doesn't abort the walk — the engine collects it.
            if !r.ok && r.status != 40 && r.status != 185 {
                ctx.log("warning: could not delete \(name) (exit \(r.status)); continuing")
            }
        }
        _ = try? ctx.runner.run(Self.dscl, [".", "-delete", "/Groups/\(groupName)"])
    }
}
