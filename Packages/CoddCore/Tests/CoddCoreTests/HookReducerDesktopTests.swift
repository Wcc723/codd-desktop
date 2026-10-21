import Foundation
import Testing
@testable import CoddCore

/// The documented desktop extensions of the hook state machine.
@Suite("HookReducer desktop extensions")
struct HookReducerDesktopTests {
    let tid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"
    let sid = "11111111-aaaa-4aaa-8aaa-111111111111"

    func payload(_ event: String, _ extra: [String: JSONValue] = [:]) -> HookPayload {
        var o: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(sid), "cwd": .string("/synthetic")]
        for (k, v) in extra { o[k] = v }
        return HookPayload(object: o)
    }

    /// Applies events at 1 s intervals starting at `referenceNow`.
    func run(_ events: [HookPayload], dialect: HookDialect = .desktop, from prev: HookSessionState? = nil) -> [HookSessionState] {
        let r = HookReducer(dialect: dialect, configDir: "/synthetic/.claude")
        var state = prev
        var out: [HookSessionState] = []
        for (i, e) in events.enumerated() {
            if let next = r.apply(state, e, terminalId: tid, now: referenceNow.addingTimeInterval(Double(i))) {
                state = next
                out.append(next)
            }
        }
        return out
    }

    @Test func stopFailureBecomesErrorWithKind() throws {
        let s = run([
            payload("UserPromptSubmit", ["prompt": "go"]),
            payload("StopFailure", ["error": "overloaded", "error_details": "API Error: 529\nOverloaded"]),
        ])
        let last = try #require(s.last)
        #expect(last.state == .error)
        #expect(last.errorKind == .overloaded)
        #expect(last.errorDetail == "API Error: 529 Overloaded")
        #expect(last.waitingReason == nil)
        #expect(last.stateSince == JSDate.isoString(referenceNow.addingTimeInterval(1)))
    }

    @Test(arguments: [
        ("rate_limit", HookErrorKind.rateLimit, "RATE LIMIT"),
        ("authentication_failed", .authenticationFailed, "AUTH"),
        ("oauth_org_not_allowed", .oauthOrgNotAllowed, "AUTH"),
        ("billing_error", .billingError, "BILLING"),
        ("max_output_tokens", .maxOutputTokens, "MAX TOKENS"),
        ("something_new", .unknown, "UNKNOWN"),
    ])
    func stopFailureErrorEnum(raw: String, kind: HookErrorKind, label: String) throws {
        let last = try #require(run([payload("StopFailure", ["error": .string(raw)])]).last)
        #expect(last.errorKind == kind)
        #expect(kind.label == label)
    }

    @Test func stopFailureWithoutErrorFieldIsUnknownAndUsesLastMessage() throws {
        let last = try #require(run([payload("StopFailure", ["last_assistant_message": "API Error: Rate limit reached"])]).last)
        #expect(last.errorKind == .unknown)
        #expect(last.errorDetail == "API Error: Rate limit reached")
    }

    @Test func webDialectKeepsStopFailureIdle() throws {
        let last = try #require(run([payload("StopFailure", ["error": "overloaded"])], dialect: .web).last)
        #expect(last.state == .idle)
        #expect(last.errorKind == nil)
        #expect(try jsonValue(last)["error_kind"] == nil)
    }

    @Test func errorSurvivesIdlePromptButNotANewPrompt() throws {
        let s = run([
            payload("StopFailure", ["error": "rate_limit"]),
            payload("Notification", ["notification_type": "idle_prompt"]),
            payload("UserPromptSubmit", ["prompt": "retry"]),
        ])
        #expect(s[1].state == .error)
        #expect(s[1].errorKind == .rateLimit)
        #expect(s[1].stateSince == s[0].stateSince)
        #expect(s[2].state == .busy)
        #expect(s[2].errorKind == nil)
        #expect(s[2].errorDetail == nil)
    }

    @Test func errorClearedBySessionStartAndStop() throws {
        let a = run([payload("StopFailure", ["error": "overloaded"]), payload("SessionStart", ["source": "resume"])])
        #expect(a.last?.state == .idle)
        #expect(a.last?.errorKind == nil)
        let b = run([payload("StopFailure", ["error": "overloaded"]), payload("Stop")])
        #expect(b.last?.state == .idle)
        #expect(b.last?.errorKind == nil)
    }

    @Test func autoCompactionRestoresBusy() throws {
        let s = run([
            payload("UserPromptSubmit", ["prompt": "long"]),
            payload("PreCompact", ["trigger": "auto"]),
            payload("SessionStart", ["source": "compact"]),
            payload("PostCompact", ["trigger": "auto", "compact_summary": "…"]),
        ])
        #expect(s[1].state == .compacting)
        #expect(s[1].stateBeforeCompact == .busy)
        #expect(s[1].compactTrigger == "auto")
        #expect(s[2].state == .busy) // SessionStart(compact) ends compaction (PostCompact may be lost)
        #expect(s[2].stateBeforeCompact == nil)
        #expect(s[3].state == .busy) // a later PostCompact(auto) changes nothing
        #expect(s[3].stateSince == s[2].stateSince)
        #expect(s[3].stateBeforeCompact == nil)
        #expect(s[3].compactTrigger == nil)
    }

    @Test func compactionEndsWithoutPostCompactInEitherOrder() throws {
        // Manual /compact, PostCompact never delivered: SessionStart(compact) alone ends it.
        let manual = run([payload("Stop"), payload("PreCompact", ["trigger": "manual"]), payload("SessionStart", ["source": "compact"])])
        #expect(manual.last?.state == .idle)
        // PostCompact first, then SessionStart(compact): same final state as the other order.
        let a = run([payload("UserPromptSubmit"), payload("PreCompact", ["trigger": "auto"]),
                     payload("PostCompact", ["trigger": "auto"]), payload("SessionStart", ["source": "compact"])])
        let b = run([payload("UserPromptSubmit"), payload("PreCompact", ["trigger": "auto"]),
                     payload("SessionStart", ["source": "compact"]), payload("PostCompact", ["trigger": "auto"])])
        #expect(a.last?.state == .busy)
        #expect(b.last?.state == .busy)
        // SessionStart(compact) when not compacting keeps the state, as in the original.
        let keep = run([payload("PermissionRequest", ["tool_name": "Bash"]), payload("SessionStart", ["source": "compact"])])
        #expect(keep.last?.state == .waiting)
        #expect(keep.last?.waitingReason == .permission)
    }

    @Test func idleCompactionRestoresIdle() throws {
        let s = run([payload("Stop"), payload("PreCompact", ["trigger": "auto"]), payload("PostCompact", ["trigger": "auto"])])
        #expect(s.last?.state == .idle)
    }

    @Test func manualCompactionEndsIdle() throws {
        let s = run([payload("UserPromptSubmit"), payload("PreCompact", ["trigger": "manual"]), payload("PostCompact", ["trigger": "manual"])])
        #expect(s[1].state == .compacting)
        #expect(s.last?.state == .idle)
    }

    @Test func postCompactWithoutTriggerUsesStoredTrigger() throws {
        let s = run([payload("Stop"), payload("PreCompact", ["trigger": "manual"]), payload("PostCompact")])
        #expect(s.last?.state == .idle)
    }

    @Test func compactionFromWaitingRestoresBusy() throws {
        let s = run([payload("PermissionRequest", ["tool_name": "Bash"]), payload("PreCompact", ["trigger": "auto"]), payload("PostCompact", ["trigger": "auto"])])
        #expect(s[1].stateBeforeCompact == .waiting)
        #expect(s.last?.state == .busy)
    }

    @Test func repeatedPreCompactKeepsOriginalPriorState() throws {
        let s = run([payload("UserPromptSubmit"), payload("PreCompact", ["trigger": "auto"]), payload("PreCompact", ["trigger": "auto"])])
        #expect(s.last?.stateBeforeCompact == .busy)
        #expect(s.last?.stateSince == s[1].stateSince)
    }

    @Test func autoPostCompactWhenNotCompactingChangesNothing() throws {
        let s = run([payload("UserPromptSubmit"), payload("PostCompact", ["trigger": "auto"])])
        #expect(s.last?.state == .busy)
        #expect(s.last?.stateSince == s[0].stateSince)
    }

    @Test func compactingIsLeftByAnyStateEvent() throws {
        let s = run([payload("PreCompact", ["trigger": "auto"]), payload("PreToolUse", ["tool_name": "Edit"])])
        #expect(s.last?.state == .busy)
        #expect(s.last?.stateBeforeCompact == nil)
    }

    @Test func subagentCounterNeverNegativeAndResets() throws {
        let s = run([
            payload("UserPromptSubmit"),
            payload("SubagentStop"),
            payload("SubagentStart", ["agent_id": "a"]),
            payload("SubagentStart", ["agent_id": "b"]),
            payload("SubagentStop", ["agent_id": "a"]),
            payload("SessionStart", ["source": "compact"]),
            payload("SessionStart", ["source": "resume"]),
        ])
        #expect(s.map(\.subagentsActive) == [nil, 0, 1, 2, 1, 1, nil])
        #expect(s.dropLast().allSatisfy { $0.state == .busy }) // subagent events never change the state
        #expect(s.last?.state == .idle)
    }

    @Test func subagentCounterResetsOnNewClaudeSession() throws {
        let s = run([
            payload("SubagentStart"),
            payload("SessionEnd", ["reason": "clear"]),
        ])
        #expect(s.last?.subagentsActive == nil)
        #expect(s.last?.state == .ended)
    }

    @Test func extensionFieldsRoundTripThroughTheFileFormat() throws {
        let last = try #require(run([payload("StopFailure", ["error": "server_error", "error_details": "boom"])]).last)
        let data = try JSONEncoder().encode(last)
        let decoded = try JSONDecoder().decode(HookSessionState.self, from: data)
        #expect(decoded == last)
        let json = try #require(JSONValue.parse(data))
        #expect(json["v"] == .number(2))
        #expect(json["error_kind"] == .string("server_error"))
        #expect(json["last_prompt"] == .null) // v2 fields are always written, like the original
    }

    /// A crashed / rebooted claude leaves a non-ended record. Relaunching under another Claude
    /// session id is then ignored by the nested-claude guard unless the baseline marks it ended.
    @Test(arguments: [HookDialect.web, .desktop])
    func relaunchBaselineLetsTheNewProcessTakeOver(dialect: HookDialect) throws {
        let r = HookReducer(dialect: dialect, configDir: "/synthetic/.claude")
        let stale = try #require(run([payload("UserPromptSubmit", ["prompt": "long task"])], dialect: dialect).last)
        #expect(stale.state == .busy)
        var resume = payload("SessionStart", ["source": "resume"])
        resume = HookPayload(object: resume.raw.merging(["session_id": "22222222-bbbb-4bbb-8bbb-222222222222"]) { $1 })
        let later = referenceNow.addingTimeInterval(60)
        #expect(r.apply(stale, resume, terminalId: tid, now: later) == nil) // the guard, as in the original
        let baseline = try #require(r.relaunchBaseline(stale, now: later))
        #expect(baseline.state == .ended)
        let next = try #require(r.apply(baseline, resume, terminalId: tid, now: later))
        #expect(next.state == .idle)
        #expect(next.sessionId == "22222222-bbbb-4bbb-8bbb-222222222222")
        #expect(next.lastPrompt == nil) // belonged to the old conversation
        // Same conversation resumed: its fields survive.
        let same = try #require(r.apply(baseline, payload("SessionStart", ["source": "resume"]), terminalId: tid, now: later))
        #expect(same.lastPrompt == "long task")
        #expect(r.relaunchBaseline(nil, now: later) == nil)
        #expect(r.relaunchBaseline(baseline, now: later.addingTimeInterval(5)) == baseline)
    }

    @Test func dateAccessors() throws {
        let s = try #require(run([payload("UserPromptSubmit", ["prompt": "hi"])]).last)
        #expect(s.stateSinceDate == referenceNow)
        #expect(s.lastEventDate == referenceNow)
        #expect(s.lastPromptDate == referenceNow)
    }
}

@Suite("ActivityMerger desktop extensions")
struct ActivityMergerDesktopTests {
    let tid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"
    let t0: Int64 = 1_792_032_120_000

    func hook(_ state: HookActivityState, kind: HookErrorKind? = nil) -> HookSessionState {
        var h = HookSessionState(terminalId: tid, sessionId: "s1", state: state,
                                 stateSince: JSDate.isoString(milliseconds: t0), lastEventAt: JSDate.isoString(milliseconds: t0),
                                 lastTool: "Bash", toolCount: 2)
        h.errorKind = kind
        return h
    }

    func registry(_ status: String, dt: Int64, waitingFor: String? = nil) -> [ClaudeRegistryEntry] {
        [ClaudeRegistryEntry(pid: 42, sessionId: "s1", status: status, waitingFor: waitingFor, statusTimestampMilliseconds: t0 + dt)]
    }

    func merge(_ hook: HookSessionState?, _ reg: [ClaudeRegistryEntry], dialect: HookDialect = .desktop) -> SessionActivity {
        ActivityMerger(dialect: dialect).merge(context: ActivityContext(terminalId: tid, pid: 42, process: .running), hook: hook, registry: reg)
    }

    @Test func errorStateIsReported() {
        let a = merge(hook(.error, kind: .rateLimit), [])
        #expect(a.state == .error)
        #expect(a.errorKind == .rateLimit)
        #expect(a.source == .hook)
    }

    @Test func errorIgnoresNewerRegistryIdleButNotBusy() {
        #expect(merge(hook(.error, kind: .overloaded), registry("idle", dt: 5000)).state == .error)
        let busy = merge(hook(.error, kind: .overloaded), registry("busy", dt: 5000))
        #expect(busy.state == .busy)
        #expect(busy.errorKind == nil)
        #expect(busy.source == .registry)
    }

    @Test func compactingIgnoresRegistryBusyButNotIdle() {
        #expect(merge(hook(.compacting), registry("busy", dt: 5000)).state == .compacting)
        #expect(merge(hook(.compacting), registry("idle", dt: 5000)).state == .idle)
    }

    @Test(arguments: [
        ("input needed", WaitingReason.question),
        ("permission prompt", .permission),
        ("sandbox request", .permission),
        ("worker request", .permission),
        ("dialog open", .other),
        ("goal proposal", .other),
        ("brand new reason", .other),
    ])
    func registryOnlyWaitingCarriesReason(waitingFor: String, reason: WaitingReason) {
        let a = merge(nil, registry("waiting", dt: 0, waitingFor: waitingFor))
        #expect(a.state == .waiting)
        #expect(a.reason == reason)
        #expect(merge(nil, registry("waiting", dt: 0, waitingFor: waitingFor), dialect: .web).reason == nil)
    }

    @Test func registryWaitingWithoutWaitingForIsOther() {
        #expect(merge(nil, registry("waiting", dt: 0)).reason == .other)
    }

    @Test func exitedProcessIsEnded() {
        let at = JSDate.date(milliseconds: t0 + 9000)
        let a = ActivityMerger().merge(context: ActivityContext(terminalId: tid, pid: 42, process: .exited(at: at)),
                                       hook: hook(.busy), registry: registry("busy", dt: 0))
        #expect(a.state == .ended)
        #expect(a.sinceDate == at)
        #expect(a.lastTool == "Bash")
    }

    @Test func registryMatchPrefersFirstEntryInOrder() {
        let entries = [
            ClaudeRegistryEntry(pid: 7, sessionId: "s1", status: "idle"),
            ClaudeRegistryEntry(pid: 42, sessionId: "other", status: "busy"),
        ]
        // Both match (one by session id, one by pid); the original's `find` returns the first.
        #expect(ClaudeRegistryReader.match(entries, pid: 42, sessionId: "s1")?.pid == 7)
        #expect(ClaudeRegistryReader.match(entries, pid: nil, sessionId: nil) == nil)
    }
}
