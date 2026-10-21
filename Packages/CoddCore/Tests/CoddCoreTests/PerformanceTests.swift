import Foundation
import Testing
@testable import CoddCore

/// Coarse timing checks against docs/ARCHITECTURE.md budgets (hook handling < 2 ms p99).
/// Thresholds are generous so debug builds on a loaded machine stay green; numbers are printed.
@Suite("Performance", .serialized)
struct PerformanceTests {
    func percentiles(_ samples: [Duration]) -> (p50: Duration, p99: Duration) {
        let s = samples.sorted()
        return (s[s.count / 2], s[min(s.count - 1, Int(Double(s.count) * 0.99))])
    }

    func micros(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1e6 + Double(d.components.attoseconds) / 1e12
    }

    @Test func hookEventHandling() throws {
        let body = Data(#"{"hook_event_name":"PostToolUse","session_id":"11111111-aaaa-4aaa-8aaa-111111111111","transcript_path":"/synthetic/t.jsonl","cwd":"/synthetic/project","permission_mode":"default","tool_name":"Edit","tool_input":{"file_path":"/synthetic/a.ts","old_string":"x","new_string":"y"},"tool_response":{"success":true}}"#.utf8)
        let reducer = HookReducer(dialect: .desktop, configDir: "/synthetic/.claude")
        var state: HookSessionState? = HookSessionState(sessionId: "11111111-aaaa-4aaa-8aaa-111111111111", state: .busy)
        let encoder = JSONEncoder()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for i in 0..<3000 {
            let t = clock.now
            let payload = HookPayload(body: body)
            state = reducer.apply(state, payload, terminalId: "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17",
                                  now: referenceNow.addingTimeInterval(Double(i)))
            _ = try encoder.encode(state)
            samples.append(clock.now - t)
        }
        let (p50, p99) = percentiles(Array(samples.dropFirst(100)))
        print("PERF hook parse+apply+encode: p50 \(micros(p50)) µs, p99 \(micros(p99)) µs")
        #expect(p99 < .milliseconds(2))
        #expect(state?.toolCount == 3000)
    }

    @Test func activityMerge() {
        let merger = ActivityMerger()
        let hook = HookSessionState(terminalId: "t", sessionId: "s", state: .busy, stateSince: "2026-10-15T02:42:00.000Z",
                                    lastEventAt: "2026-10-15T02:42:00.000Z", lastTool: "Bash", toolCount: 3)
        let registry = (0..<20).map { ClaudeRegistryEntry(pid: 40000 + $0, sessionId: "x\($0)", status: "idle", statusTimestampMilliseconds: 1_792_032_125_000) }
            + [ClaudeRegistryEntry(pid: 42, sessionId: "s", status: "idle", statusTimestampMilliseconds: 1_792_032_125_000)]
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var last: SessionActivity?
        for _ in 0..<3000 {
            let t = clock.now
            last = merger.merge(context: ActivityContext(terminalId: "t", pid: 42, process: .running), hook: hook, registry: registry)
            samples.append(clock.now - t)
        }
        let (p50, p99) = percentiles(Array(samples.dropFirst(100)))
        print("PERF activity merge (21 registry entries): p50 \(micros(p50)) µs, p99 \(micros(p99)) µs")
        #expect(last?.state == .idle)
        #expect(p99 < .milliseconds(2))
    }

    /// A registry directory scan (open + read + decode each `<pid>.json`) plus the liveness filter,
    /// which the agent runs after every (debounced) FSEvents change.
    @Test func registryScanAndLiveness() throws {
        let tmp = try TempDir("codd-perf-registry")
        defer { tmp.remove() }
        let me = Int(getpid())
        let start = DarwinProcessLiveness.formatProcStart(DarwinProcessLiveness.startTime(pid: getpid()) ?? referenceNow)
        for i in 0..<50 {
            let pid = i == 0 ? me : 40_000 + i
            let body = #"{"pid":\#(pid),"sessionId":"s\#(i)","cwd":"/synthetic/p\#(i)","procStart":"\#(start)","status":"idle","#
                + #""statusUpdatedAt":1792032125000,"updatedAt":1792032125000,"kind":"interactive","entrypoint":"cli","version":"2.1.300"}"#
            try Data(body.utf8).write(to: tmp.file("\(pid).json"))
            try Data("SYNTHETIC".utf8).write(to: tmp.file("\(pid).abc123.key"))
        }
        let reader = ClaudeRegistryReader()
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var live: [ClaudeRegistryEntry] = []
        for _ in 0..<200 {
            let t = clock.now
            live = ClaudeRegistryReader.liveEntries(reader.read(directory: tmp.url))
            samples.append(clock.now - t)
        }
        let (p50, p99) = percentiles(Array(samples.dropFirst(10)))
        print("PERF registry scan + liveness (50 files): p50 \(micros(p50)) µs, p99 \(micros(p99)) µs")
        #expect(live.map(\.pid) == [me])
        #expect(p99 < .milliseconds(50))
    }

    @Test func cswapListDecodeAndPolicy() throws {
        let data = try Fixtures.data("cswap", "list-canonical.json")
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<500 {
            let t = clock.now
            let list = try JSONDecoder().decode(CswapListResponse.self, from: data)
            let accounts = Account.accounts(from: list)
            _ = AutoSwitchPolicy.evaluate(accounts: accounts, settings: AutoSwitchSettings(isEnabled: true), now: referenceNow, lastAutoSwitchAt: nil)
            samples.append(clock.now - t)
        }
        let (p50, p99) = percentiles(Array(samples.dropFirst(20)))
        print("PERF cswap list decode + R8 evaluate: p50 \(micros(p50)) µs, p99 \(micros(p99)) µs")
        #expect(p99 < .milliseconds(20))
    }
}
