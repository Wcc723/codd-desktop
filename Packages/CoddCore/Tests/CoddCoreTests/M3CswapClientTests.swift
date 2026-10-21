import Foundation
import Testing
@testable import CoddCore

private let parentEnv: [String: String] = [
    "PATH": "/usr/bin:/bin", "HOME": "/Users/synthetic", "LANG": "C", "KEEP_ME": "1",
    "CLAUDE_CONFIG_DIR": "/Users/synthetic/.claude-swap-backup/sessions/2-north-example-com",
    "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/p", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
    "CLAUDE_CODE_OAUTH_TOKEN": "t", "ANTHROPIC_API_KEY": "sk-synthetic", "CODD_HOOK_TOKEN": "tok",
]

private func client(_ runner: FakeRunner) -> CswapClient {
    CswapClient(runner: runner, configuration: .init(executable: "/Users/synthetic/.local/bin/cswap", parentEnvironment: parentEnv))
}

private func envelope(_ type: String, _ message: String) -> Data {
    Data(#"{"schemaVersion":1,"error":{"type":"\#(type)","message":"\#(message)"}}"#.utf8)
}

private let switchOK = Data("""
{"schemaVersion":1,"switched":true,"from":{"number":3,"email":"work@example.com"},"to":{"number":2,"email":"north@example.com"},
 "strategy":"direct for north@example.com","reason":"switched","message":"Switched to north@example.com",
 "warnings":["Session of work@example.com still open","plain warning"]}
""".utf8)

/// Collects `onAttempt` calls from any thread.
final class AttemptLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ n: Int) { lock.withLock { values.append(n) } }
    var all: [Int] { lock.withLock { values } }
}

@Suite("cswap version")
struct CswapVersionTests {
    @Test func parsing() {
        let rows: [(String, CswapVersion?)] = [
            ("cswap 0.26.0", CswapVersion(0, 26, 0)),
            ("claude-swap 0.26.0\n", CswapVersion(0, 26, 0)),
            ("cswap 0.27.1rc1", CswapVersion(0, 27, 1)),
            ("0.26.2", CswapVersion(0, 26, 2)),
            ("\n  cswap 1.0\n", CswapVersion(1, 0, 0)),
            ("cswap v0.30.4", CswapVersion(0, 30, 4)),
            ("cswap", nil),
            ("", nil),
            ("cswap version unknown", nil),
            ("cswap x.y.z", nil),
            ("Traceback (most recent call last):", nil),
        ]
        for (output, expected) in rows {
            #expect(CswapVersion(output: output) == expected, "\(output)")
        }
    }

    @Test func ordering() {
        #expect(CswapVersion.minimum == CswapVersion(0, 26, 0))
        #expect(CswapVersion(0, 25, 9) < .minimum)
        #expect(CswapVersion(0, 26, 0) >= .minimum)
        #expect(CswapVersion(1, 0, 0) > CswapVersion(0, 99, 99))
        #expect(!CswapVersion(0, 25, 3).isSupported)
        #expect(CswapVersion(0, 26, 1).isSupported)
        #expect(CswapVersion(0, 26, 1).description == "0.26.1")
    }

    @Test func versionInvocation() async throws {
        let runner = FakeRunner(stdout: Data("cswap 0.26.0\n".utf8))
        #expect(try await client(runner).version() == CswapVersion(0, 26, 0))
        let inv = try #require(runner.invocations.first)
        #expect(inv.arguments == ["--version"])
        #expect(inv.timeout == .seconds(5))
        #expect(inv.executable == "/Users/synthetic/.local/bin/cswap")
        #expect(inv.environment["CLAUDE_CONFIG_DIR"] == nil)
        #expect(inv.environment["KEEP_ME"] == "1")
        // argparse may print to stderr on old Pythons.
        let stderrOnly = FakeRunner(stdout: Data(), stderr: Data("claude-swap 0.27.0".utf8))
        #expect(try await client(stderrOnly).version() == CswapVersion(0, 27, 0))
    }

    @Test func versionFailures() async throws {
        let crash = FakeRunner(stdout: Data(), status: 1, stderr: Data("ModuleNotFoundError for north@example.com".utf8))
        await #expect(throws: CswapError.failed(status: 1, stderr: "ModuleNotFoundError for •••@•••")) { try await client(crash).version() }
        let junk = FakeRunner(stdout: Data("hello north@example.com world".utf8))
        await #expect(throws: CswapError.malformedOutput("hello •••@••• world")) { try await client(junk).version() }
    }
}

@Suite("cswap add / alias / switch (M3)")
struct CswapClientM3Tests {
    @Test func addArgvAndEnvironment() async throws {
        let runner = FakeRunner(stdout: Data("Added Account-4 (new@example.com).\n".utf8))
        try await client(runner).addCurrentLogin(slot: 4, alias: " Studio ")
        let inv = try #require(runner.invocations.first)
        #expect(inv.arguments == ["add", "--slot", "4", "--alias", "studio"])
        #expect(inv.timeout == .seconds(60))
        #expect(inv.environment["NO_COLOR"] == "1")
        #expect(inv.environment["LANG"] == "en_US.UTF-8")
        for stripped in ["CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
                         "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "CODD_HOOK_TOKEN"] {
            #expect(inv.environment[stripped] == nil, "\(stripped)")
        }
        #expect(inv.environment["KEEP_ME"] == "1")
    }

    @Test func addWithoutSlotOrAlias() async throws {
        let runner = FakeRunner(stdout: Data())
        try await client(runner).addCurrentLogin(slot: nil, alias: nil)
        #expect(runner.invocations.map(\.arguments) == [["add"]])
    }

    @Test func invalidAliasesAreRefusedBeforeRunningCswap() async throws {
        let runner = FakeRunner(stdout: Data())
        let c = client(runner)
        for bad in ["工作室", "工作", "123", "-x", "a b", "a@b", "", "  "] {
            await #expect(throws: CswapError.reported(type: "ValidationError", message: CswapAlias.hint)) {
                try await c.addCurrentLogin(slot: 4, alias: bad)
            }
            await #expect(throws: CswapError.reported(type: "ValidationError", message: CswapAlias.hint)) {
                try await c.setAlias(bad, account: 2)
            }
        }
        await #expect(throws: CswapError.self) { try await c.addCurrentLogin(slot: 0, alias: "studio") }
        await #expect(throws: CswapError.self) { try await c.setAlias("studio", account: -1) }
        #expect(runner.invocations.isEmpty)
    }

    /// `add` prints the e-mail; neither a success nor a failure surfaces stdout, and stderr is redacted.
    @Test func addOutputNeverSurfaces() async throws {
        let ok = FakeRunner(stdout: Data("Added Account-4 (new@example.com) [personal]\n".utf8))
        try await client(ok).addCurrentLogin(slot: 4, alias: "studio")
        let failing = FakeRunner(stdout: Data("Account new@example.com could not be read\n".utf8), status: 1,
                                 stderr: Data("Error: credential for new@example.com missing\n".utf8))
        do {
            try await client(failing).addCurrentLogin(slot: 4, alias: "studio")
            Issue.record("expected a failure")
        } catch {
            #expect(error as? CswapError == .failed(status: 1, stderr: "Error: credential for •••@••• missing\n"))
            for text in renderings(error) {
                #expect(!text.contains("example.com"))
                #expect(!text.contains("could not be read"))
            }
        }
    }

    @Test func setAliasArgv() async throws {
        let runner = FakeRunner(stdout: Data("Alias 'studio' set for Account-2 (north@example.com)\n".utf8))
        let c = client(runner)
        try await c.setAlias("Studio", account: 2)
        try await c.setAlias(nil, account: 3)
        #expect(runner.invocations.map(\.arguments) == [["alias", "2", "studio"], ["alias", "3", "--unset"]])
        #expect(runner.invocations.map(\.timeout) == [.seconds(10), .seconds(10)])
        #expect(runner.invocations.allSatisfy { $0.environment["NO_COLOR"] == "1" && $0.environment["CLAUDE_CONFIG_DIR"] == nil })
        let refused = FakeRunner(stdout: Data(), status: 1, stderr: Data("cswap alias refuses inside a session for north@example.com".utf8))
        await #expect(throws: CswapError.failed(status: 1, stderr: "cswap alias refuses inside a session for •••@•••")) {
            try await client(refused).setAlias("studio", account: 2)
        }
    }

    @Test func switchRetriesOnTheClaudeCodeLock() async throws {
        let calls = AttemptLog()
        let runner = FakeRunner { inv in
            calls.append(0)
            if calls.all.count <= 2 { return CommandResult(status: 1, stdout: envelope("ClaudeCodeLockTimeout", "Timed out waiting for ~/.claude.lock")) }
            return CommandResult(status: 0, stdout: switchOK)
        }
        let attempts = AttemptLog()
        let response = try await client(runner).switchAccount(to: 2, maxAttempts: 3) { attempts.append($0) }
        #expect(attempts.all == [1, 2, 3])
        #expect(runner.invocations.count == 3)
        #expect(runner.invocations.allSatisfy { $0.arguments == ["switch", "2", "--json"] && $0.timeout == .seconds(30) })
        #expect(response.switched)
        #expect(response.toNumber == 2)
    }

    @Test func switchGivesUpAfterMaxAttempts() async throws {
        let runner = FakeRunner(stdout: envelope("ClaudeCodeLockTimeout", "Timed out for work@example.com"), status: 1)
        let attempts = AttemptLog()
        await #expect(throws: CswapError.reported(type: "ClaudeCodeLockTimeout", message: "Timed out for •••@•••")) {
            try await client(runner).switchAccount(to: 2) { attempts.append($0) }
        }
        #expect(attempts.all == [1, 2, 3])
        #expect(runner.invocations.count == 3)
        // maxAttempts below 1 still runs once.
        let once = AttemptLog()
        await #expect(throws: CswapError.self) { try await client(runner).switchAccount(to: 2, maxAttempts: 0) { once.append($0) } }
        #expect(once.all == [1])
    }

    @Test func otherSwitchErrorsAreNotRetried() async throws {
        let runner = FakeRunner(stdout: envelope("SwitchError", "Account north@example.com has no backup"), status: 1)
        let attempts = AttemptLog()
        await #expect(throws: CswapError.reported(type: "SwitchError", message: "Account •••@••• has no backup")) {
            try await client(runner).switchAccount(to: 2) { attempts.append($0) }
        }
        #expect(attempts.all == [1])
        let crash = FakeRunner(stdout: Data(), status: 2, stderr: Data("Traceback for north@example.com".utf8))
        await #expect(throws: CswapError.failed(status: 2, stderr: "Traceback for •••@•••")) {
            try await client(crash).switchAccount(to: 2) { _ in }
        }
        let timeout = FakeRunner { _ in throw CommandRunnerError.timedOut(.seconds(30)) }
        await #expect(throws: CswapError.runner(.timedOut(.seconds(30)))) { try await client(timeout).switchAccount(to: 2) { _ in } }
        let launch = FakeRunner { _ in throw CommandRunnerError.launchFailed("no such file for north@example.com") }
        await #expect(throws: CswapError.runner(.launchFailed("no such file for •••@•••"))) {
            try await client(launch).switchAccount(to: 2) { _ in }
        }
    }

    @Test func switchResponseStringsAreRedacted() async throws {
        let response = try await client(FakeRunner(stdout: switchOK)).switchAccount(to: 2) { _ in }
        #expect(response.message == "Switched to •••@•••")
        #expect(response.strategy == "direct for •••@•••")
        #expect(response.reason == "switched")
        #expect(response.warnings == ["Session of •••@••• still open", "plain warning"])
        #expect(response.fromNumber == 3)
        for text in renderings(response) { #expect(!text.contains("example.com")) }
    }

    /// The M2 API is byte-compatible: same argv, timeout and decoding.
    @Test func theExistingSwitchIsUnchanged() async throws {
        let runner = FakeRunner(stdout: try Fixtures.data("cswap", "switch.json"))
        let response = try await client(runner).switchAccount(to: 2)
        #expect(runner.invocations.map(\.arguments) == [["switch", "2", "--json"]])
        #expect(runner.invocations.first?.environment["NO_COLOR"] == nil)
        #expect(response == (try JSONDecoder().decode(CswapSwitchResponse.self, from: Fixtures.data("cswap", "switch.json"))))
    }

    @Test func newCallsShareTheSerialization() async throws {
        let gate = ConcurrencyProbe()
        let list = try Fixtures.data("cswap", "list-canonical.json")
        let runner = FakeRunner { inv in
            await gate.enter()
            try await Task.sleep(for: .milliseconds(30))
            await gate.leave()
            switch inv.arguments.first {
            case "list": return CommandResult(status: 0, stdout: list)
            case "--version": return CommandResult(status: 0, stdout: Data("cswap 0.26.0".utf8))
            case "switch": return CommandResult(status: 0, stdout: switchOK)
            default: return CommandResult(status: 0, stdout: Data())
            }
        }
        let c = client(runner)
        async let a = c.list()
        async let b = c.version()
        async let d: Void = c.addCurrentLogin(slot: 4, alias: "studio")
        async let e: Void = c.setAlias("x1", account: 2)
        async let f = c.switchAccount(to: 2) { _ in }
        _ = try await (a, b, d, e, f)
        #expect(runner.invocations.count == 5)
        #expect(await gate.maxConcurrent == 1)
    }
}

@Suite("cswap alias rule (D34)")
struct CswapAliasTests {
    @Test func normalizeTable() {
        let rows: [(String, String?)] = [
            ("studio", "studio"),
            (" Studio ", "studio"),
            ("Studio ", "studio"),
            ("my.alias_2-x", "my.alias_2-x"),
            ("x-", "x-"),
            ("1a", "1a"),
            ("\t\u{3000}North\u{85}", "north"), // Python's str.strip() set
            ("工作", nil),
            ("工作室", nil),
            ("123", nil),
            ("-x", nil),
            ("a b", nil),
            ("a@b", nil),
            ("", nil),
            ("   ", nil),
            ("café", nil),
            ("\u{FEFF}x", nil), // not whitespace for Python: stays and fails the rule
        ]
        for (input, expected) in rows {
            #expect(CswapAlias.normalize(input) == expected, "\(input.debugDescription)")
        }
    }

    @Test func hint() {
        #expect(CswapAlias.hint == "別名只能用英文小寫、數字與 - _ .（cswap 規則）")
    }
}
