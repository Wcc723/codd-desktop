import Darwin
import Foundation
import Testing
@testable import CoddCore

@Suite("External sessions")
struct ExternalSessionTests {
    let started = JSDate.date(milliseconds: 1_792_030_000_000)

    func entry(_ pid: Int, sessionId: String? = nil, cwd: String? = "/synthetic/project", status: String? = "idle",
               waitingFor: String? = nil, entrypoint: String? = "cli", kind: String? = "interactive",
               startedAt: Date? = nil, bridge: String? = nil, name: String? = nil) -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: pid, sessionId: sessionId ?? "11111111-0000-4000-8000-\(String(format: "%012d", pid))",
                            cwd: cwd, startedAt: startedAt ?? started, version: "2.1.301", kind: kind, entrypoint: entrypoint,
                            name: name, status: status, waitingFor: waitingFor,
                            statusTimestampMilliseconds: 1_792_032_000_000, bridgeSessionId: bridge)
    }

    /// No real process lookups in these tests.
    let noAncestors: @Sendable (Int) -> [Int] = { _ in [] }

    @Test func plainExternalSession() throws {
        let e = entry(48211, status: "busy", bridge: "cse_x", name: "  修正\n登入  ")
        let s = try #require(ExternalSessionDetector.detect([e], owned: .init(), ancestors: noAncestors).first)
        #expect(s.id == "ext-48211-1792030000000")
        #expect(s.pid == 48211)
        #expect(s.claudeSessionId == e.sessionId)
        #expect(s.cwd == "/synthetic/project")
        #expect(s.name == "修正 登入")
        #expect(s.kind == "interactive")
        #expect(s.entrypoint == "cli")
        #expect(s.version == "2.1.301")
        #expect(s.state == .busy)
        #expect(s.stateSince == JSDate.date(milliseconds: 1_792_032_000_000))
        #expect(s.startedAt == started)
        #expect(s.remoteControl)
        #expect(s.hostHolderPid == nil)
    }

    @Test func entriesWithoutPidOrCwdAreSkipped() {
        let entries = [ClaudeRegistryEntry(pid: nil, sessionId: "a", cwd: "/p"), ClaudeRegistryEntry(pid: 5, sessionId: "b", cwd: nil),
                       ClaudeRegistryEntry(pid: 0, sessionId: "c", cwd: "/p")]
        #expect(ExternalSessionDetector.detect(entries, owned: .init(), ancestors: noAncestors).isEmpty)
    }

    @Test func ownershipRules() {
        let entries = [entry(100), entry(200, sessionId: "owned-session"), entry(300), entry(400), entry(500)]
        let owned = OwnedClaudeProcesses(claudePids: [100], claudeSessionIds: ["owned-session"], claudeHolderPids: [9300],
                                         shellHolderPids: [9500])
        let chains: [Int: [Int]] = [300: [9300, 1], 400: [7000, 9300, 1], 500: [7001, 9500, 1]]
        let out = ExternalSessionDetector.detect(entries, owned: owned, ancestors: { chains[$0] ?? [] })
        // 100: our pid; 200: our session id; 300: child of our claude holder (pid not known yet).
        // 400: the holder is only a grandparent, so it is someone else's claude below our holder's child.
        #expect(out.map(\.pid) == [400, 500])
        #expect(out.first { $0.pid == 500 }?.hostHolderPid == 9500)
        #expect(out.first { $0.pid == 400 }?.hostHolderPid == nil)
    }

    @Test func hostShellHolderAtAnyDepth() {
        let entries = [entry(600), entry(601), entry(602)]
        let owned = OwnedClaudeProcesses(shellHolderPids: [9600, 9601])
        let chains: [Int: [Int]] = [600: [9600, 1], 601: [7100, 7101, 7102, 9601, 1], 602: [7200, 1]]
        let out = ExternalSessionDetector.detect(entries, owned: owned, ancestors: { chains[$0] ?? [] })
        #expect(out.map(\.hostHolderPid) == [9600, 9601, nil])
    }

    @Test func ancestorsAreNotLookedUpWithoutHolders() {
        let calls = Counter()
        _ = ExternalSessionDetector.detect([entry(1), entry(2)], owned: OwnedClaudeProcesses(claudePids: [3]),
                                           ancestors: { _ in calls.increment(); return [] })
        #expect(calls.value == 0)
        _ = ExternalSessionDetector.detect([entry(1), entry(2)], owned: OwnedClaudeProcesses(shellHolderPids: [3]),
                                           ancestors: { _ in calls.increment(); return [] })
        #expect(calls.value == 2)
    }

    @Test func sdkAndDesktopFilters() {
        let entries = [entry(1, entrypoint: "sdk-cli"), entry(2, entrypoint: "sdk-ts"), entry(3, kind: "sdk"),
                       entry(4, entrypoint: "claude-desktop"), entry(5, entrypoint: "claude-vscode"), entry(6, entrypoint: nil)]
        let detect = { (filter: ExternalSessionFilter) in
            ExternalSessionDetector.detect(entries, owned: .init(), filter: filter, ancestors: noAncestors).map(\.pid)
        }
        #expect(detect(.init()) == [5, 6])
        #expect(detect(ExternalSessionFilter(hideSDK: false, hideDesktop: true)) == [1, 2, 3, 5, 6])
        #expect(detect(ExternalSessionFilter(hideSDK: true, hideDesktop: false)) == [4, 5, 6])
        var all = ExternalSessionFilter()
        all.hideSDK = false
        all.hideDesktop = false
        #expect(detect(all) == [1, 2, 3, 4, 5, 6])
    }

    @Test(arguments: [
        ("busy", String?.none, SessionState.busy), ("idle", nil, .idle), ("waiting", "permission prompt", .waiting(.permission)),
        ("waiting", "input needed", .waiting(.question)), ("waiting", "sandbox request", .waiting(.permission)),
        ("waiting", "worker request", .waiting(.permission)), ("waiting", "dialog open", .waiting(.other)),
        ("waiting", "goal proposal", .waiting(.other)), ("waiting", nil, .waiting(.other)), ("compacting", nil, .unknown),
    ])
    func stateMapping(status: String, waitingFor: String?, expected: SessionState) {
        let out = ExternalSessionDetector.detect([entry(7, status: status, waitingFor: waitingFor)], owned: .init(), ancestors: noAncestors)
        #expect(out.first?.state == expected)
    }

    @Test func missingStatusIsUnknown() {
        let out = ExternalSessionDetector.detect([entry(7, status: nil)], owned: .init(), ancestors: noAncestors)
        #expect(out.first?.state == .unknown)
    }

    @Test func idIsStablePerProcess() throws {
        let before = try #require(ExternalSessionDetector.detect([entry(48211, sessionId: "aaaa")], owned: .init(), ancestors: noAncestors).first)
        // `/clear` inside the external claude: new Claude session id, same process.
        let after = try #require(ExternalSessionDetector.detect([entry(48211, sessionId: "bbbb")], owned: .init(), ancestors: noAncestors).first)
        #expect(before.id == after.id)
        #expect(after.claudeSessionId == "bbbb")
        // The pid reused by a later process.
        let reused = try #require(ExternalSessionDetector.detect(
            [entry(48211, startedAt: started.addingTimeInterval(3600))], owned: .init(), ancestors: noAncestors).first)
        #expect(reused.id != before.id)
        var noStart = entry(48211)
        noStart.startedAt = nil
        #expect(ExternalSessionDetector.detect([noStart], owned: .init(), ancestors: noAncestors).first?.id == "ext-48211")
        #expect(ExternalSession.id(pid: 1, startedAt: JSDate.date(milliseconds: 42)) == "ext-1-42")
    }

    @Test func duplicateProcessesAreListedOnce() {
        let out = ExternalSessionDetector.detect([entry(9, name: "first"), entry(9, name: "second")], owned: .init(), ancestors: noAncestors)
        #expect(out.map(\.name) == ["first"])
    }

    @Test func sortedByCwdThenStartThenPid() {
        var unstarted = entry(1, cwd: "/b")
        unstarted.startedAt = nil
        let entries = [
            entry(30, cwd: "/b", startedAt: started.addingTimeInterval(20)), unstarted,
            entry(20, cwd: "/b", startedAt: started.addingTimeInterval(10)), entry(10, cwd: "/b", startedAt: started.addingTimeInterval(10)),
            entry(99, cwd: "/a"),
        ]
        let out = ExternalSessionDetector.detect(entries, owned: .init(), ancestors: noAncestors)
        #expect(out.map(\.pid) == [99, 10, 20, 30, 1])
    }

    @Test func realAncestryChain() {
        let chain = ProcessAncestry.chain(Int(getpid()))
        #expect(chain.first == Int(getppid()))
        #expect(chain.count <= ProcessAncestry.maxDepth)
        #expect(!chain.contains(Int(getpid())))
        #expect(ProcessAncestry.chain(1).isEmpty)
        #expect(ProcessAncestry.chain(-5).isEmpty)
        #expect(ProcessAncestry.parentPid(Int(getpid())) == Int(getppid()))
        #expect(ProcessAncestry.parentPid(Int(Int32.max)) == nil)
    }

    @Test func perfFiftyEntries() {
        let entries = (0..<50).map { entry(70_000 + $0, cwd: "/synthetic/p\($0 % 7)", status: $0 % 3 == 0 ? "busy" : "idle") }
        let owned = OwnedClaudeProcesses(claudePids: [70_001, 70_002], claudeHolderPids: [1], shellHolderPids: [2])
        let clock = ContinuousClock()
        var out: [ExternalSession] = []
        let start = clock.now
        for _ in 0..<100 { out = ExternalSessionDetector.detect(entries, owned: owned, ancestors: { [$0 + 1, 1] }) }
        let pureTime = (clock.now - start) / 100
        // The real sysctl chain for 50 (dead, synthetic) pids: one failing lookup each.
        let realStart = clock.now
        _ = ExternalSessionDetector.detect(entries, owned: owned)
        let realTime = clock.now - realStart
        print("PERF external detect, 50 entries: \(pureTime) (injected ancestry), \(realTime) (sysctl)")
        #expect(out.count == 48)
        #expect(pureTime < .milliseconds(20))
    }
}

/// A thread-safe call counter for the ancestry closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
