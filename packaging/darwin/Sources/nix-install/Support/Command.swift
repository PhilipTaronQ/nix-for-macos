import Foundation

/// External tool execution, injectable so every diskutil/apfs.util/dscl
/// interaction is fakeable in tests. The real installer only ever shells
/// out to Apple-stable tools by absolute path.

struct CommandResult {
    var status: Int32
    var stdout: Data
    var stderr: Data

    var ok: Bool { status == 0 }
    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

protocol CommandRunner {
    func run(_ program: String, _ arguments: [String], stdin: Data?) throws -> CommandResult
}

extension CommandRunner {
    @discardableResult
    func run(_ program: String, _ arguments: [String]) throws -> CommandResult {
        try run(program, arguments, stdin: nil)
    }

    /// Run and require exit 0.
    @discardableResult
    func runChecked(_ program: String, _ arguments: [String], stdin: Data? = nil) throws
        -> CommandResult
    {
        let result = try run(program, arguments, stdin: stdin)
        guard result.ok else {
            throw CommandError.failed(
                program: program, arguments: arguments, status: result.status,
                stderr: result.stderrText)
        }
        return result
    }
}

enum CommandError: Error, CustomStringConvertible {
    case failed(program: String, arguments: [String], status: Int32, stderr: String)
    case unavailable(program: String)

    var description: String {
        switch self {
        case .failed(let program, let arguments, let status, let stderr):
            let cmd = ([program] + arguments).joined(separator: " ")
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "'\(cmd)' failed with exit code \(status)"
                + (detail.isEmpty ? "" : ": \(detail)")
        case .unavailable(let program):
            return "'\(program)' cannot run against a --root tree; "
                + "system commands need root = / (use --dry-run to preview)"
        }
    }
}

/// The real thing.
struct SystemCommandRunner: CommandRunner {
    func run(_ program: String, _ arguments: [String], stdin: Data?) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            try process.run()
            inPipe.fileHandleForWriting.write(stdin)
            inPipe.fileHandleForWriting.closeFile()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        let stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// Used when operating on a --root scratch tree: file actions work, but
/// anything that would touch real system state via a tool refuses loudly
/// rather than, say, creating an actual APFS volume during a test.
struct RefusingCommandRunner: CommandRunner {
    func run(_ program: String, _ arguments: [String], stdin: Data?) throws -> CommandResult {
        throw CommandError.unavailable(program: program)
    }
}

/// Retry helper for the APFS races: diskutil create/unmount/delete
/// complete asynchronously.
func retrying<T>(
    times: Int, delayMilliseconds: Int, _ ctx: Context, _ body: () throws -> T
) throws -> T {
    var lastError: Error?
    for attempt in 1...times {
        do {
            return try body()
        } catch {
            lastError = error
            if attempt < times {
                usleep(UInt32(delayMilliseconds * ctx.pollScale * 1000))
            }
        }
    }
    throw lastError!
}
