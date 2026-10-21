import Darwin

/// Names shared with CoddCore (`CoddEnvironmentName`, `CoddHookHeader`). Duplicated because this
/// target cannot import CoddCore (Foundation); a test asserts they stay equal.
public enum HookWireNames {
    public static let tokenEnvironment = "CODD_HOOK_TOKEN"
    public static let sessionEnvironment = "CODD_SESSION_ID"
    /// Fallback endpoint when no `--url` argument is given.
    public static let urlEnvironment = "CODD_HOOK_URL"
    public static let debugEnvironment = "CODD_HOOK_DEBUG"
    public static let tokenHeader = "X-CODD-Token"
    public static let sessionHeader = "X-CODD-Session"
}

/// The `codd-hook` command: `codd-hook <event-hint> --url <url>`, hook JSON on stdin.
///
/// It runs as Claude Code's SessionStart `command` hook, where stdout is injected into the model's
/// context and a non-zero exit is reported to the user, so it never writes to stdout and its
/// process always exits 0 (see ``HookCommandMain``). Everything here only decides what to send.
public struct HookCommand: Sendable, Equatable {
    /// Requests and stdin larger than this are dropped (the endpoint's body limit).
    public static let maxBodyBytes = 1 << 20
    /// Total budget for reading stdin, connecting, sending and reading the response.
    public static let budgetMilliseconds = 1800

    /// The first non-flag argument (`session-start`); only used for debug output.
    public var eventHint: String?
    /// `--url <u>` / `--url=<u>`, else `CODD_HOOK_URL`.
    public var url: String?

    public init(eventHint: String?, url: String?) {
        self.eventHint = eventHint
        self.url = url
    }

    /// Lenient argv parsing: unknown flags are ignored, a missing `--url` value is `nil`.
    public init(arguments: [String], environment: (String) -> String?) {
        var hint: String?
        var url: String?
        var i = 1
        while i < arguments.count {
            let arg = arguments[i]
            if arg == "--url" {
                url = i + 1 < arguments.count ? arguments[i + 1] : nil
                i += 2
                continue
            }
            if arg.hasPrefix("--url=") {
                url = String(arg.dropFirst("--url=".count))
            } else if !arg.hasPrefix("-"), hint == nil {
                hint = arg
            }
            i += 1
        }
        self.init(eventHint: hint, url: url ?? environment(HookWireNames.urlEnvironment))
    }

    /// What the command decided to do.
    public enum Outcome: Sendable, Equatable {
        case posted(status: Int)
        case skipped(Skip)
        case failed(LoopbackHTTPError)
    }

    public enum Skip: String, Error, Sendable, Equatable {
        case missingURL = "no --url and no CODD_HOOK_URL"
        case notLoopbackURL = "url is not http://127.0.0.1 or http://localhost"
        case missingToken = "CODD_HOOK_TOKEN missing or unsafe"
        case missingSession = "CODD_SESSION_ID missing or unsafe"
        case emptyBody = "stdin was empty"
        case bodyTooLarge = "stdin exceeded 1 MiB"
        case stdinTimedOut = "stdin did not reach EOF in time"
    }

    /// Builds the request, or the reason not to send one.
    public func request(environment: (String) -> String?, body: StdinBody) -> Result<(LoopbackURL, [UInt8]), Skip> {
        guard let raw = url, !raw.isEmpty else { return .failure(.missingURL) }
        guard let target = LoopbackURL(raw) else { return .failure(.notLoopbackURL) }
        guard let token = environment(HookWireNames.tokenEnvironment), ASCII.isSafeHeaderValue(token) else {
            return .failure(.missingToken)
        }
        guard let session = environment(HookWireNames.sessionEnvironment), ASCII.isSafeHeaderValue(session) else {
            return .failure(.missingSession)
        }
        let bytes: [UInt8]
        switch body {
        case .bytes(let b) where b.isEmpty: return .failure(.emptyBody)
        case .bytes(let b): bytes = b
        case .tooLarge: return .failure(.bodyTooLarge)
        case .timedOut: return .failure(.stdinTimedOut)
        }
        let request = LoopbackHTTPClient.requestBytes(
            method: "POST", url: target,
            headers: [
                ("Content-Type", "application/json"),
                (HookWireNames.tokenHeader, token),
                (HookWireNames.sessionHeader, session),
            ],
            body: bytes)
        return .success((target, request))
    }

    /// Runs the whole command against the real network.
    public func run(environment: (String) -> String?, body: StdinBody, deadline: MonotonicDeadline) -> Outcome {
        switch request(environment: environment, body: body) {
        case .failure(let skip):
            return .skipped(skip)
        case .success(let (target, bytes)):
            switch LoopbackHTTPClient.send(bytes, port: target.port, deadline: deadline) {
            case .success(let response): return .posted(status: response.status)
            case .failure(let error): return .failed(error)
            }
        }
    }
}

/// stdin as read by ``StdinReader``.
public enum StdinBody: Sendable, Equatable {
    case bytes([UInt8])
    case tooLarge
    case timedOut
}

/// Reads a descriptor to EOF within a deadline and a size limit.
public enum StdinReader {
    public static func read(fd: Int32 = 0, limit: Int, deadline: MonotonicDeadline) -> StdinBody {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, deadline.pollTimeout)
            if ready < 0, errno == EINTR { continue }
            if ready == 0 { return .timedOut }
            // POLLNVAL (stdin closed) or a poll error: treat as an empty stdin.
            if ready < 0 || p.revents & Int16(POLLNVAL) != 0 { return .bytes(out) }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
                if out.count > limit { return .tooLarge }
            } else if n == 0 {
                return .bytes(out)
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                return .bytes(out)
            }
        }
    }
}

/// Process-level behaviour of `codd-hook`: protects stdout, bounds the run time, exits 0.
public enum HookCommandMain {
    /// Hard stop: whatever happens, the process is gone (with status 0) after this long.
    public static let hardLimitMilliseconds = 1950

    public static func main() -> Never {
        // Point fd 1 at /dev/null so nothing (not even a runtime diagnostic) can reach Claude's
        // context. Done before any socket is opened, so fd 1 is never reused for one.
        let devNull = open("/dev/null", O_WRONLY | O_CLOEXEC)
        if devNull >= 0 {
            _ = dup2(devNull, STDOUT_FILENO)
            if devNull != STDOUT_FILENO { close(devNull) }
        }
        signal(SIGPIPE, SIG_IGN)
        // The deadlines below already end the run in time; the timer is the backstop for anything
        // that blocks outside poll(2). The handler only calls _exit, which is async-signal-safe.
        signal(SIGALRM) { _ in _exit(0) }
        var timer = itimerval(
            it_interval: timeval(tv_sec: 0, tv_usec: 0),
            it_value: timeval(tv_sec: hardLimitMilliseconds / 1000, tv_usec: Int32(hardLimitMilliseconds % 1000) * 1000))
        _ = setitimer(ITIMER_REAL, &timer, nil)

        let deadline = MonotonicDeadline.after(milliseconds: HookCommand.budgetMilliseconds)
        let environment: (String) -> String? = { name in getenv(name).map { String(cString: $0) } }
        let command = HookCommand(arguments: CommandLine.arguments, environment: environment)
        let body = StdinReader.read(fd: STDIN_FILENO, limit: HookCommand.maxBodyBytes, deadline: deadline)
        let outcome = command.run(environment: environment, body: body, deadline: deadline)
        if environment(HookWireNames.debugEnvironment) == "1" {
            debugLog(command: command, outcome: outcome)
        }
        exit(0)
    }

    static func debugLog(command: HookCommand, outcome: HookCommand.Outcome) {
        let hint = command.eventHint ?? "-"
        let line: String
        switch outcome {
        case .posted(let status) where status == 204:
            line = "codd-hook[\(hint)]: delivered\n"
        case .posted(let status):
            line = "codd-hook[\(hint)]: endpoint answered \(status)\n"
        case .skipped(let skip):
            line = "codd-hook[\(hint)]: not sent: \(skip.rawValue)\n"
        case .failed(let error):
            line = "codd-hook[\(hint)]: failed: \(error)\n"
        }
        var bytes = Array(line.utf8)
        _ = bytes.withUnsafeMutableBytes { write(STDERR_FILENO, $0.baseAddress, $0.count) }
    }
}
