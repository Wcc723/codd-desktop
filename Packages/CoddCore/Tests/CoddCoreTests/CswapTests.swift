import Foundation
import Testing
@testable import CoddCore

@Suite("cswap JSON models")
struct CswapModelTests {
    func decodeList(_ file: String) throws -> CswapListResponse {
        try JSONDecoder().decode(CswapListResponse.self, from: Fixtures.data("cswap", file))
    }

    @Test func canonicalList() throws {
        let list = try decodeList("list-canonical.json")
        #expect(list.schemaVersion == 1)
        #expect(list.activeAccountNumber == 3)
        #expect(list.accounts.map(\.number) == [1, 2, 3])
        #expect(list.activeAccount?.number == 3)
        #expect(list.lockstepUsageWarnings?.arrayValue?.count == 1)

        let a3 = list.accounts[2]
        #expect(a3.alias == "工作")
        #expect(a3.active)
        #expect(a3.usageStatus == .ok)
        let five = try #require(a3.usage?.fiveHour)
        #expect(five.pct == 9)
        #expect(five.remainingPercent == 91)
        #expect(five.resetsAt == JSDate.date(fromISO: "2026-10-15T05:39:00Z"))
        #expect(five.countdown == "2h 57m")
        #expect(five.clock == "13:39")
        let week = try #require(a3.usage?.sevenDay)
        #expect(week.remainingPercent == 15)
        #expect(week.aheadOfPace == true)
        #expect(week.expectedPct == 52.1)
        #expect(week.willLastToReset == false)
        #expect(week.projectedExhaustionAt == JSDate.date(fromISO: "2026-10-17T10:00:00Z"))
        #expect(a3.usage?.scoped.first?.name == "Fable")
        #expect(a3.usage?.scoped.first?.window.remainingPercent == 100)
        #expect(a3.usage?.spend?.limit == 50)
        #expect(a3.usageFetchedAt == JSDate.date(fromISO: "2026-10-15T02:41:48Z"))
        #expect(a3.usageAgeSeconds == 12)

        let a2 = list.accounts[1]
        #expect(a2.isOrganization)
        #expect(a2.organizationName == "Synthetic Org")
        #expect(a2.usage?.sevenDay?.remainingPercent == 46)

        let a1 = list.accounts[0]
        #expect(a1.usageStatus == .unavailable)
        #expect(a1.usage == nil)
        #expect(a1.isUsingLastGoodUsage)
        #expect(a1.effectiveUsage?.fiveHour?.resetsAt == nil) // 5h not started
        #expect(a1.effectiveUsage?.sevenDay?.resetsAt == JSDate.date(milliseconds: 1_792_411_200_441))
        #expect(a1.effectiveUsageFetchedAt == JSDate.date(fromISO: "2026-10-15T02:39:00Z"))
    }

    @Test func emailsAreNeverDecoded() throws {
        // The model has no e-mail property at all; make sure nothing echoes it either.
        let list = try decodeList("list-canonical.json")
        #expect(!String(describing: list).contains("example.invalid"))
    }

    @Test func brokenRowsAreSkippedOrDefaulted() throws {
        let list = try decodeList("list-broken-rows.json")
        #expect(list.accounts.map(\.number) == [5, 6, 7])
        let a5 = list.accounts[0]
        #expect(!a5.active)               // "yes" is not a bool
        #expect(a5.usageStatus == .other("brand_new_status"))
        #expect(a5.usage == nil)
        #expect(a5.alias == nil)          // blank alias
        let a6 = list.accounts[1]
        #expect(a6.usageStatus == .reloginRequired)
        #expect(a6.usage?.fiveHour == nil) // no pct
        #expect(a6.usage?.sevenDay == nil) // pct is a string
        #expect(a6.usage?.scoped.map(\.name) == ["Fable"])
        #expect(a6.usage?.spend == nil)
        let a7 = list.accounts[2]
        #expect(a7.disabled)
        #expect(a7.usage?.fiveHour?.remainingPercent == 0)   // 101.5 % used clamps
        #expect(a7.usage?.sevenDay?.remainingPercent == 100) // negative used clamps
        #expect(a7.usage?.fiveHour?.resetsAt == JSDate.date(milliseconds: 1_792_040_340_000)) // epoch seconds
        #expect(a7.usage?.sevenDay?.resetsAt == JSDate.date(milliseconds: 1_792_296_000_000)) // epoch ms
        #expect(list.activeAccount?.number == 5)
    }

    @Test func unsupportedSchemaIsAnError() throws {
        #expect(throws: CswapError.unsupportedSchema(2)) { try decodeList("list-schema2.json") }
        #expect(throws: CswapError.unsupportedSchema(nil)) {
            try JSONDecoder().decode(CswapListResponse.self, from: Data("{\"accounts\":[]}".utf8))
        }
    }

    @Test func statusSwitchAndError() throws {
        let status = try JSONDecoder().decode(CswapStatusResponse.self, from: Fixtures.data("cswap", "status.json"))
        #expect(status.active?.number == 3)
        #expect(status.totalManagedAccounts == 3)
        let sw = try JSONDecoder().decode(CswapSwitchResponse.self, from: Fixtures.data("cswap", "switch.json"))
        #expect(sw.switched)
        #expect(sw.fromNumber == 3)
        #expect(sw.toNumber == 2)
        #expect(sw.reason == "switched")
        #expect(sw.warnings.count == 1)
        let err = try #require(CswapErrorEnvelope.parse(try Fixtures.data("cswap", "error.json")))
        #expect(err.type == "ClaudeCodeLockTimeout")
        #expect(CswapErrorEnvelope.parse(try Fixtures.data("cswap", "status.json")) == nil)
    }

    @Test func usageStatusTargetRules() {
        #expect(CswapUsageStatus.ok.allowsAutoSwitchTarget)
        #expect(CswapUsageStatus.unavailable.allowsAutoSwitchTarget)
        #expect(CswapUsageStatus.tokenExpired.allowsAutoSwitchTarget)
        for s: CswapUsageStatus in [.reloginRequired, .noCredentials, .apiKey, .keychainUnavailable, .foreignCredential, .other("x")] {
            #expect(!s.allowsAutoSwitchTarget)
        }
        #expect(CswapUsageStatus(raw: nil) == .unavailable)
    }
}

@Suite("cswap client")
struct CswapClientTests {
    let parentEnv: [String: String] = [
        "PATH": "/usr/bin:/bin", "HOME": "/Users/synthetic", "LANG": "C",
        "ANTHROPIC_API_KEY": "sk-synthetic", "ANTHROPIC_BASE_URL": "http://x", "CLAUDE_CONFIG_DIR": "/p",
        "CLAUDE_CODE_OAUTH_TOKEN": "t", "DYLD_INSERT_LIBRARIES": "/x.dylib", "KEEP_ME": "1",
        "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/p", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli",
        "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR": "3", "CODD_HOOK_TOKEN": "tok", "CODD_SESSION_ID": "x",
    ]

    func client(_ runner: FakeRunner) -> CswapClient {
        CswapClient(runner: runner, configuration: .init(executable: "/Users/synthetic/.local/bin/cswap", parentEnvironment: parentEnv))
    }

    @Test func listInvocationEnvironmentAndTimeout() async throws {
        let runner = FakeRunner(stdout: try Fixtures.data("cswap", "list-canonical.json"))
        let c = client(runner)
        let list = try await c.list()
        #expect(list.accounts.count == 3)
        let inv = try #require(runner.invocations.first)
        #expect(inv.executable == "/Users/synthetic/.local/bin/cswap")
        #expect(inv.arguments == ["list", "--json"])
        #expect(inv.timeout == .seconds(20))
        #expect(inv.environment["LANG"] == "en_US.UTF-8")
        #expect(inv.environment["PYTHONIOENCODING"] == "utf-8")
        #expect(inv.environment["KEEP_ME"] == "1")
        for stripped in ["ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "DYLD_INSERT_LIBRARIES",
                         "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT",
                         "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CODD_HOOK_TOKEN", "CODD_SESSION_ID"] {
            #expect(inv.environment[stripped] == nil, "\(stripped) must be stripped")
        }
        #expect(await c.lastGoodList == list)
        #expect(await c.lastGoodListAt != nil)
    }

    @Test func statusAndSwitchInvocations() async throws {
        let runner = FakeRunner { inv in
            let file = inv.arguments.first == "status" ? "status.json" : "switch.json"
            return CommandResult(status: 0, stdout: try Fixtures.data("cswap", file))
        }
        let c = client(runner)
        #expect(try await c.status().active?.number == 3)
        #expect(try await c.switchAccount(to: 2).toNumber == 2)
        #expect(runner.invocations.map(\.arguments) == [["status", "--json"], ["switch", "2", "--json"]])
        #expect(runner.invocations.map(\.timeout) == [.seconds(10), .seconds(30)])
    }

    @Test func concurrentListsCoalesce() async throws {
        let data = try Fixtures.data("cswap", "list-canonical.json")
        let runner = FakeRunner { _ in
            try await Task.sleep(for: .milliseconds(100))
            return CommandResult(status: 0, stdout: data)
        }
        let c = client(runner)
        async let a = c.list()
        async let b = c.list()
        async let d = c.list()
        let results = try await [a, b, d]
        #expect(results.allSatisfy { $0.accounts.count == 3 })
        #expect(runner.invocations.count == 1)
        _ = try await c.list() // a new call after completion runs again
        #expect(runner.invocations.count == 2)
    }

    @Test func callsAreSerialized() async throws {
        let data = try Fixtures.data("cswap", "list-canonical.json")
        let switchData = try Fixtures.data("cswap", "switch.json")
        let gate = ConcurrencyProbe()
        let runner = FakeRunner { inv in
            await gate.enter()
            try await Task.sleep(for: .milliseconds(50))
            await gate.leave()
            return CommandResult(status: 0, stdout: inv.arguments.first == "list" ? data : switchData)
        }
        let c = client(runner)
        async let l = c.list()
        async let s1 = c.switchAccount(to: 2)
        async let s2 = c.switchAccount(to: 1)
        _ = try await (l, s1, s2)
        #expect(runner.invocations.count == 3)
        #expect(await gate.maxConcurrent == 1)
    }

    @Test func errorEnvelopeAndFailures() async throws {
        let env = FakeRunner(stdout: try Fixtures.data("cswap", "error.json"), status: 1)
        await #expect(throws: CswapError.reported(type: "ClaudeCodeLockTimeout", message: "Timed out waiting for ~/.claude.lock")) {
            try await client(env).switchAccount(to: 1)
        }
        let crash = FakeRunner(stdout: Data(), status: 2, stderr: Data("Traceback: boom".utf8))
        await #expect(throws: CswapError.failed(status: 2, stderr: "Traceback: boom")) { try await client(crash).list() }
        let junk = FakeRunner(stdout: Data("not json".utf8))
        await #expect { try await client(junk).list() } throws: { error in
            if case CswapError.malformedOutput = error { return true }
            return false
        }
        let timeout = FakeRunner { _ in throw CommandRunnerError.timedOut(.seconds(20)) }
        await #expect(throws: CswapError.runner(.timedOut(.seconds(20)))) { try await client(timeout).list() }
    }

    @Test func lastGoodSurvivesFailure() async throws {
        let good = try Fixtures.data("cswap", "list-canonical.json")
        let flip = Flag()
        let runner = FakeRunner { _ in
            if await flip.toggle() { return CommandResult(status: 0, stdout: good) }
            return CommandResult(status: 0, stdout: try Fixtures.data("cswap", "list-schema2.json"))
        }
        let c = client(runner)
        _ = try await c.list()
        await #expect(throws: CswapError.unsupportedSchema(2)) { try await c.list() }
        #expect(await c.lastGoodList?.accounts.count == 3)
    }

    @Test func standardConfiguration() {
        let conf = CswapClient.Configuration.standard(home: "/Users/x", environment: [:])
        #expect(conf.executable == "/Users/x/.local/bin/cswap")
        #expect(CswapEnvironment.make(from: [:])["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}

/// Records the maximum number of overlapping runner calls.
actor ConcurrencyProbe {
    private var current = 0
    private(set) var maxConcurrent = 0
    func enter() {
        current += 1
        maxConcurrent = max(maxConcurrent, current)
    }
    func leave() { current -= 1 }
}

actor Flag {
    private var value = false
    /// Returns true on the first call, then alternates.
    func toggle() -> Bool {
        value.toggle()
        return value
    }
}
