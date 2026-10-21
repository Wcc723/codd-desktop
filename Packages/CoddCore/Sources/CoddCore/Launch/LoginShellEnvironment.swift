import Foundation

/// Supplies the user's login-shell environment (injectable so tests never run the real shell).
public protocol LoginEnvironmentProviding: Sendable {
    func captureEnvironment() async throws -> [String: String]
}

public enum LoginShellCaptureError: Error, Equatable {
    case shellFailed(status: Int32)
    case markersMissing
}

/// Captures the environment by running the user's shell as a login + interactive shell
/// (`$SHELL -l -i -c '…'`), printing `env -0` between NUL-delimited markers so anything the rc
/// files print is ignored. Bounded by ``timeout`` (a hanging rc file must not hang CODD).
///
/// The default ``ProcessCommandRunner`` starts the shell in a new session without a controlling
/// terminal. A runner that leaves it in CODD's own terminal session (CODD started from a terminal
/// or from inside a CODD session) lets the interactive shell try job control on that terminal from
/// a background process group, where it is stopped by SIGTTIN/SIGTTOU until the timeout.
public struct LoginShellEnvironmentCapture: LoginEnvironmentProviding {
    public static let beginMarker = "__CODD_ENV_BEGIN__"
    public static let endMarker = "__CODD_ENV_END__"
    /// Prints the markers and the environment, NUL separated (works in zsh, bash and sh).
    public static let script = "printf '%s\\0' \(beginMarker); /usr/bin/env -0; printf '%s\\0' \(endMarker)"

    public var shell: String
    /// Flags before the script; tests pass `["-f", "-c"]` (zsh without rc files).
    public var flags: [String]
    public var timeout: Duration
    public var runner: any CommandRunner
    /// Environment of the capture process itself (minimal; the shell builds the rest).
    public var environment: [String: String]

    public init(shell: String, flags: [String] = ["-l", "-i", "-c"], timeout: Duration = .seconds(5),
                runner: any CommandRunner = ProcessCommandRunner(), environment: [String: String]) {
        self.shell = shell
        self.flags = flags
        self.timeout = timeout
        self.runner = runner
        self.environment = environment
    }

    /// The user's `$SHELL` (default `/bin/zsh`) with a minimal environment taken from `base`.
    public static func standard(base: [String: String] = ProcessInfo.processInfo.environment) -> Self {
        var env: [String: String] = ["TERM": "dumb", "LANG": SpawnEnvironmentBuilder.fallbackLocale]
        for name in ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "PATH"] { env[name] = base[name] }
        return Self(shell: base["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh", environment: env)
    }

    public func captureEnvironment() async throws -> [String: String] {
        let result = try await runner.run(CommandInvocation(
            executable: shell, arguments: flags + [Self.script], environment: environment, timeout: timeout,
            maxOutputBytes: 4 << 20))
        guard let env = Self.parse(result.stdout) else {
            if !result.succeeded { throw LoginShellCaptureError.shellFailed(status: result.status) }
            throw LoginShellCaptureError.markersMissing
        }
        return env
    }

    /// Extracts the `KEY=VALUE` entries between the markers.
    public static func parse(_ stdout: Data) -> [String: String]? {
        let parts = stdout.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        // rc output before the marker ends up glued to it; match the marker as a suffix.
        guard let begin = parts.firstIndex(where: { $0.hasSuffix(beginMarker) }),
              let end = parts[(begin + 1)...].firstIndex(of: endMarker) else { return nil }
        var env: [String: String] = [:]
        for entry in parts[(begin + 1)..<end] {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env
    }
}

/// Captures the login environment once and serves it to every launch.
public actor LoginEnvironmentCache {
    private let provider: any LoginEnvironmentProviding
    private var cached: [String: String]?
    private var attempted = false
    private var inFlight: Task<[String: String]?, Never>?

    public init(provider: any LoginEnvironmentProviding) {
        self.provider = provider
    }

    /// The captured environment, or `nil` when the capture failed (callers fall back to defaults).
    /// A failure is not retried within the same app run.
    public func environment() async -> [String: String]? {
        if attempted { return cached }
        if let inFlight { return await inFlight.value }
        let provider = self.provider
        let task = Task<[String: String]?, Never> { try? await provider.captureEnvironment() }
        inFlight = task
        let value = await task.value
        cached = value
        attempted = true
        inFlight = nil
        return value
    }
}
