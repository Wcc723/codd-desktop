import Foundation

public enum CswapError: Error, Equatable {
    /// `schemaVersion` missing or not 1. Keep the last good result.
    case unsupportedSchema(Int?)
    /// cswap reported an error envelope (`CredentialReadError`, `SwitchError`, `LockError`, …).
    case reported(type: String, message: String)
    /// Non-zero exit without an error envelope (stderr excerpt, at most 500 characters).
    case failed(status: Int32, stderr: String)
    /// Exit 0 but stdout is not the expected JSON.
    case malformedOutput(String)
    case runner(CommandRunnerError)
}

/// Builds cswap's child environment (cswap.md §6.8, synth.md §2 Quota).
public enum CswapEnvironment {
    /// Exact names removed from the parent environment. `CLAUDE_SECURESTORAGE_CONFIG_DIR` selects
    /// the Keychain store cswap reads (claude-swap `credentials.py`); inherited from a Claude session
    /// it makes cswap act on that session's store (its own error text: "unset it or run cswap from a
    /// normal shell"). `CLAUDECODE` marks a process running inside Claude Code.
    public static let strippedNames: Set<String> = [
        "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDECODE",
    ]
    /// Name prefixes removed from the parent environment (`CLAUDE_CODE_` covers the OAuth token,
    /// the credential file descriptors and the entrypoint markers).
    public static let strippedPrefixes = ["ANTHROPIC_", "DYLD_", "CLAUDE_CODE_", "CODD_"]

    /// The parent environment without Claude credentials / profile overrides (a session's
    /// `CLAUDE_CONFIG_DIR` would make cswap act on the wrong store or refuse), with UTF-8 forced.
    public static func make(from parent: [String: String]) -> [String: String] {
        var env = parent.filter { key, _ in
            !strippedNames.contains(key) && !strippedPrefixes.contains { key.hasPrefix($0) }
        }
        env["LANG"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"
        if env["PATH"].map({ $0.isEmpty }) ?? true { env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin" }
        return env
    }
}

/// Async client for the `cswap` CLI (claude-swap ≥ 0.26, `--json` schema 1).
///
/// All calls are serialized (one cswap process at a time — they share locks and the usage
/// endpoint budget). Concurrent ``list()`` calls coalesce onto the one in flight. The last
/// successful list is kept in ``lastGoodList`` so callers can keep showing it on failure.
public actor CswapClient {
    public struct Configuration: Sendable {
        /// Absolute path; launchd's PATH does not include `~/.local/bin`.
        public var executable: String
        /// Parent environment before ``CswapEnvironment/make(from:)``.
        public var parentEnvironment: [String: String]
        public var listTimeout: Duration
        public var statusTimeout: Duration
        public var switchTimeout: Duration
        /// `--version` (D3, D28).
        public var versionTimeout: Duration
        /// `add` captures the current login (keychain + config copy); D24.
        public var addTimeout: Duration
        /// `alias N name|--unset` (D34).
        public var aliasTimeout: Duration

        public init(executable: String, parentEnvironment: [String: String],
                    listTimeout: Duration = .seconds(20), statusTimeout: Duration = .seconds(10),
                    switchTimeout: Duration = .seconds(30), versionTimeout: Duration = .seconds(5),
                    addTimeout: Duration = .seconds(60), aliasTimeout: Duration = .seconds(10)) {
            self.executable = executable
            self.parentEnvironment = parentEnvironment
            self.listTimeout = listTimeout
            self.statusTimeout = statusTimeout
            self.switchTimeout = switchTimeout
            self.versionTimeout = versionTimeout
            self.addTimeout = addTimeout
            self.aliasTimeout = aliasTimeout
        }

        /// `~/.local/bin/cswap` with the current process environment.
        public static func standard(home: String = NSHomeDirectory(),
                                    environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            Configuration(executable: home + "/.local/bin/cswap", parentEnvironment: environment)
        }
    }

    private let runner: any CommandRunner
    private let configuration: Configuration
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlightList: Task<CswapListResponse, any Error>?

    public private(set) var lastGoodList: CswapListResponse?
    public private(set) var lastGoodListAt: Date?

    public init(runner: any CommandRunner, configuration: Configuration) {
        self.runner = runner
        self.configuration = configuration
    }

    /// `cswap list --json`. Joins an identical call already in flight.
    public func list() async throws -> CswapListResponse {
        if let task = inFlightList { return try await task.value }
        // The task is actor-isolated (created in actor context), so it clears `inFlightList` on the
        // actor the moment the run finishes. Clearing it in this caller instead would leave a window
        // (until this caller is resumed) in which a later call joins a run that already finished,
        // e.g. the refresh right after a switch would get pre-switch data.
        let task = Task {
            defer { self.inFlightList = nil }
            return try await self.serialized { try await self.performList() }
        }
        inFlightList = task
        return try await task.value
    }

    /// `cswap status --json`.
    public func status() async throws -> CswapStatusResponse {
        try await serialized {
            try await self.execute(["status", "--json"], timeout: self.configuration.statusTimeout)
        }
    }

    /// `cswap switch <number> --json`.
    public func switchAccount(to number: Int) async throws -> CswapSwitchResponse {
        try await serialized {
            try await self.execute(["switch", String(number), "--json"], timeout: self.configuration.switchTimeout)
        }
    }

    private func performList() async throws -> CswapListResponse {
        let response: CswapListResponse = try await execute(["list", "--json"], timeout: configuration.listTimeout)
        lastGoodList = response
        lastGoodListAt = Date()
        return response
    }

    private func execute<T: Decodable>(_ arguments: [String], timeout: Duration) async throws -> T {
        let invocation = CommandInvocation(
            executable: configuration.executable, arguments: arguments,
            environment: CswapEnvironment.make(from: configuration.parentEnvironment), timeout: timeout)
        let result: CommandResult
        do {
            result = try await runner.run(invocation)
        } catch let error as CommandRunnerError {
            throw CswapError.runner(error)
        }
        return try Self.decode(result)
    }

    /// Interprets a finished cswap run (exposed for tests).
    static func decode<T: Decodable>(_ result: CommandResult) throws -> T {
        if let envelope = CswapErrorEnvelope.parse(result.stdout) {
            throw CswapError.reported(type: envelope.type, message: envelope.message)
        }
        guard result.succeeded else {
            throw CswapError.failed(status: result.status, stderr: String(result.stderrText.prefix(500)))
        }
        do {
            return try JSONDecoder().decode(T.self, from: result.stdout)
        } catch let error as CswapError {
            throw error
        } catch {
            throw CswapError.malformedOutput(String(describing: error))
        }
    }

    /// Runs `body` with exclusive use of cswap (FIFO).
    private func serialized<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer { handOff() }
        return try await body()
    }

    private func handOff() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - M3 additions (D3, D5, D24, D31, D34)

/// `cswap --version` (`cswap 0.26.0`; argparse prints the program name it was started as).
public struct CswapVersion: Sendable, Comparable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// The `--json` schema 1, the state layout and the alias rule CODD relies on (D3).
    public static let minimum = CswapVersion(0, 26, 0)

    /// The first non-empty line, `<program> <version>` or `<version>` alone (`cswap 0.26.0`,
    /// `claude-swap 0.26.0`); a pre-release suffix on the patch (`0rc1`) is ignored.
    public init?(output: String) {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { !JSText.trim(String($0)).isEmpty }) else {
            return nil
        }
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard (1...2).contains(tokens.count), let version = Self.parse(tokens[tokens.count - 1]) else { return nil }
        self = version
    }

    public var isSupported: Bool { self >= Self.minimum }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: CswapVersion, b: CswapVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    static func parse(_ token: Substring) -> CswapVersion? {
        let t = token.hasPrefix("v") ? token.dropFirst() : token
        let parts = t.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let major = digits(parts[0], whole: true), let minor = digits(parts[1], whole: true) else { return nil }
        let patch = parts.count >= 3 ? digits(parts[2], whole: false) : 0
        guard let patch else { return nil }
        return CswapVersion(major, minor, patch)
    }

    /// Leading ASCII digits (all of them when `whole`), at most 6.
    private static func digits(_ s: Substring, whole: Bool) -> Int? {
        let lead = s.prefix { $0.isASCII && $0.isNumber }
        guard !lead.isEmpty, lead.count <= 6, !whole || lead.count == s.count else { return nil }
        return Int(lead)
    }
}

extension CswapClient {
    /// `cswap --version` (5 s).
    public func version() async throws -> CswapVersion {
        let result = try await serialized {
            try await self.run(["--version"], timeout: self.configuration.versionTimeout, noColor: true)
        }
        guard result.succeeded else { throw CswapError.failed(status: result.status, stderr: Self.excerpt(result.stderrText)) }
        guard let version = CswapVersion(output: result.stdoutText) ?? CswapVersion(output: result.stderrText) else {
            throw CswapError.malformedOutput(Self.excerpt(result.stdoutText, max: 200))
        }
        return version
    }

    /// `cswap add [--slot N] [--alias A]`: captures the CURRENT global login into slot N (D24).
    /// `add` has no `--json`; its stdout prints the account e-mail, so it is discarded and the exit
    /// status decides. An alias cswap would refuse (``CswapAlias/normalize(_:)``) throws
    /// `CswapError.reported(type: "ValidationError", message: CswapAlias.hint)` without running cswap.
    ///
    /// cswap answers an occupied slot of another account with an `Overwrite?` prompt; stdin is
    /// `/dev/null`, so it cancels and still exits 0. Callers verify the result by re-reading the state.
    public func addCurrentLogin(slot: Int?, alias: String?) async throws {
        var arguments = ["add"]
        if let slot {
            guard (1...9999).contains(slot) else { throw Self.validation("帳號編號必須是 1 到 9999") }
            arguments += ["--slot", String(slot)]
        }
        if let alias {
            guard let normalized = CswapAlias.normalize(alias) else { throw Self.validation(CswapAlias.hint) }
            arguments += ["--alias", normalized]
        }
        let result = try await serialized { [arguments] in
            try await self.run(arguments, timeout: self.configuration.addTimeout, noColor: true)
        }
        guard result.succeeded else { throw CswapError.failed(status: result.status, stderr: Self.excerpt(result.stderrText)) }
    }

    /// `cswap alias N <name>`, or `cswap alias N --unset` for `nil` (10 s). Same validation and
    /// output handling as ``addCurrentLogin(slot:alias:)``.
    public func setAlias(_ alias: String?, account: Int) async throws {
        guard (1...9999).contains(account) else { throw Self.validation("帳號編號必須是 1 到 9999") }
        var arguments = ["alias", String(account)]
        if let alias {
            guard let normalized = CswapAlias.normalize(alias) else { throw Self.validation(CswapAlias.hint) }
            arguments.append(normalized)
        } else {
            arguments.append("--unset")
        }
        let result = try await serialized { [arguments] in
            try await self.run(arguments, timeout: self.configuration.aliasTimeout, noColor: true)
        }
        guard result.succeeded else { throw CswapError.failed(status: result.status, stderr: Self.excerpt(result.stderrText)) }
    }

    /// `cswap switch <number> --json` retried on `ClaudeCodeLockTimeout` (Claude Code held its
    /// credential lock), at most `maxAttempts` runs in all (D5). `onAttempt(n)` is called before
    /// run n (1-based) for the progress line `（1/3）`. The attempts hold the client, so no other cswap
    /// call runs between them. Every string of the response and of a thrown error is redacted (D31).
    public func switchAccount(to number: Int, maxAttempts: Int = 3,
                              onAttempt: @escaping @Sendable (Int) -> Void) async throws -> CswapSwitchResponse {
        let attempts = max(1, maxAttempts)
        let arguments = ["switch", String(number), "--json"]
        return try await serialized {
            var attempt = 1
            while true {
                onAttempt(attempt)
                do {
                    let result = try await self.run(arguments, timeout: self.configuration.switchTimeout, noColor: false)
                    let response: CswapSwitchResponse = try Self.decodeRedacted(result)
                    return Self.redacted(response)
                } catch let CswapError.reported(type, _) where type == "ClaudeCodeLockTimeout" && attempt < attempts {
                    try Task.checkCancellation()
                    attempt += 1
                }
            }
        }
    }

    /// One cswap run with cswap's scrubbed environment (`NO_COLOR=1` for the human-output commands).
    private func run(_ arguments: [String], timeout: Duration, noColor: Bool) async throws -> CommandResult {
        var environment = CswapEnvironment.make(from: configuration.parentEnvironment)
        if noColor { environment["NO_COLOR"] = "1" }
        let invocation = CommandInvocation(executable: configuration.executable, arguments: arguments,
                                           environment: environment, timeout: timeout)
        do {
            return try await runner.run(invocation)
        } catch let error as CommandRunnerError {
            if case .launchFailed(let reason) = error { throw CswapError.runner(.launchFailed(EmailRedaction.redact(reason))) }
            throw CswapError.runner(error)
        }
    }

    /// ``decode(_:)`` with every string redacted BEFORE it is cut to length (a cut could leave
    /// half an address the redaction no longer recognizes).
    static func decodeRedacted<T: Decodable>(_ result: CommandResult) throws -> T {
        if let envelope = CswapErrorEnvelope.parse(result.stdout) {
            throw CswapError.reported(type: EmailRedaction.redact(envelope.type), message: EmailRedaction.redact(envelope.message))
        }
        guard result.succeeded else { throw CswapError.failed(status: result.status, stderr: excerpt(result.stderrText)) }
        do {
            return try JSONDecoder().decode(T.self, from: result.stdout)
        } catch let error as CswapError {
            throw error
        } catch {
            throw CswapError.malformedOutput(excerpt(String(describing: error)))
        }
    }

    static func redacted(_ r: CswapSwitchResponse) -> CswapSwitchResponse {
        var out = r
        out.message = r.message.map(EmailRedaction.redact)
        out.reason = r.reason.map(EmailRedaction.redact)
        out.strategy = r.strategy.map(EmailRedaction.redact)
        out.warnings = r.warnings.map(EmailRedaction.redact)
        return out
    }

    /// Redacted, then at most `max` characters.
    static func excerpt(_ text: String, max: Int = 500) -> String {
        String(EmailRedaction.redact(text).prefix(max))
    }

    static func validation(_ message: String) -> CswapError {
        .reported(type: "ValidationError", message: message)
    }
}
