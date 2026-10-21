import Foundation

/// A one-shot child process invocation.
public struct CommandInvocation: Sendable, Equatable {
    /// Absolute path of the executable (no PATH search).
    public var executable: String
    public var arguments: [String]
    /// The EXACT environment of the child (nothing is inherited).
    public var environment: [String: String]
    public var currentDirectory: String?
    public var timeout: Duration
    /// stdout or stderr beyond this many bytes aborts the run (``CommandRunnerError/outputTooLarge``).
    public var maxOutputBytes: Int

    public init(executable: String, arguments: [String], environment: [String: String],
                currentDirectory: String? = nil, timeout: Duration, maxOutputBytes: Int = 8 << 20) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }
}

/// What a finished child produced.
public struct CommandResult: Sendable, Equatable {
    /// Exit status, or the signal number when ``terminatedBySignal``.
    public var status: Int32
    public var terminatedBySignal: Bool
    public var stdout: Data
    public var stderr: Data

    public init(status: Int32, terminatedBySignal: Bool = false, stdout: Data, stderr: Data = Data()) {
        self.status = status
        self.terminatedBySignal = terminatedBySignal
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 && !terminatedBySignal }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

public enum CommandRunnerError: Error, Equatable {
    case launchFailed(String)
    case timedOut(Duration)
    case outputTooLarge(Int)
    case cancelled
}

/// Runs child processes. Production: ``ProcessCommandRunner``; tests: a fake.
public protocol CommandRunner: Sendable {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult
}
