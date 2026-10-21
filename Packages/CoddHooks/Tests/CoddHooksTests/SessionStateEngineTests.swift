import CoddCore
import Darwin
import Foundation
import Testing
@testable import CoddHooks

@Suite("Session state engine")
struct SessionStateEngineTests {
    let id = UUID(uuidString: "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")!
    let claudeSid = "11111111-aaaa-4aaa-8aaa-111111111111"

    struct Harness {
        let engine: SessionStateEngine
        let clock: ManualHookClock
        let batches: Collector<SessionStateBatch>

        func ingest(_ id: UUID, _ p: HookPayload) async {
            await engine.ingest(HookEvent(sessionID: id, payload: p, receivedAt: clock.now()))
        }

        func state(_ id: UUID) async -> SessionState? {
            await engine.update(for: id)?.state
        }

        /// Moves time forward (lets a pending batch timer fire) and waits for the engine to settle.
        func tick(_ seconds: TimeInterval = 1) async {
            clock.advance(by: seconds)
            try? await Task.sleep(for: .milliseconds(10))
        }

        /// Waits until no batch has arrived for 30 ms: the collector receives batches on its own
        /// task, so a count read right after a state change can still be missing that change's batch.
        func settle() async {
            var last = -1
            while batches.count != last {
                last = batches.count
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        /// The latest emitted state for `id` across all batches.
        func lastEmitted(_ id: UUID) -> SessionState? {
            batches.values.reversed().lazy.compactMap { $0.updates.first { $0.sessionID == id }?.state }.first
        }
    }

    func harness(dataRoot: URL? = nil, start: Date = referenceNow) -> Harness {
        let clock = ManualHookClock(now: start)
        let engine = SessionStateEngine(configuration: .init(dataRoot: dataRoot, persistDebounce: .milliseconds(20),
                                                             defaultConfigDir: "/synthetic/.claude"), clock: clock)
        return Harness(engine: engine, clock: clock, batches: Collector(engine.updates))
    }

    func registration(fresh: Bool = true, startedAt: Date = referenceNow, pid: Int? = 4242, lastViewed: Date? = nil) -> SessionRegistration {
        SessionRegistration(sessionID: id, kind: .claude, process: .running(startedAt: startedAt), claudePid: pid,
                            claudeSessionId: claudeSid, cwd: "/synthetic", lastViewedAt: lastViewed, freshClaudeProcess: fresh)
    }

    func entry(pid: Int, status: String, at date: Date, waitingFor: String? = nil, sessionId: String? = nil) -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: pid, sessionId: sessionId, status: status, waitingFor: waitingFor,
                            statusTimestampMilliseconds: JSDate.milliseconds(date))
    }

    @Test func busyWaitingBusyIdleThenSeen() async throws {
        let h = harness()
        await h.engine.register(registration())
        #expect(await h.state(id) == .starting)
        #expect(await h.batches.wait { $0.last?.updates.first?.state == .starting })

        await h.tick()
        await h.ingest(id, payload("SessionStart", session: claudeSid, ["source": "startup"]))
        #expect(await h.state(id) == .idle) // no turn yet: idle, not done
        await h.tick()
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid, ["prompt": "fix the login"]))
        #expect(await h.state(id) == .busy)
        await h.tick()
        await h.ingest(id, payload("PermissionRequest", session: claudeSid, ["tool_name": "Bash"]))
        #expect(await h.state(id) == .waiting(.permission))
        let waiting = try #require(await h.engine.update(for: id))
        #expect(waiting.activity.lastTool == "Bash")
        #expect(waiting.hookSeen)
        #expect(waiting.hook?.lastPrompt == "fix the login")
        await h.tick()
        await h.ingest(id, payload("PostToolUse", session: claudeSid, ["tool_name": "Bash"]))
        #expect(await h.state(id) == .busy)
        await h.tick()
        await h.ingest(id, payload("Stop", session: claudeSid))
        #expect(await h.state(id) == .done) // finished while not looked at
        await h.tick()
        await h.engine.setLastViewed(id, at: h.clock.now())
        #expect(await h.state(id) == .idle)

        // Every transition was emitted, in order (each came after a quiet period).
        #expect(await h.batches.wait { $0.last?.updates.first?.state == .idle && $0.count >= 7 })
        let emitted = h.batches.values.compactMap { $0.updates.first(where: { $0.sessionID == id })?.state }
        #expect(emitted == [.starting, .idle, .busy, .waiting(.permission), .busy, .done, .idle])
    }

    @Test func stopFailureIsError() async throws {
        let h = harness()
        await h.engine.register(registration())
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid))
        await h.tick()
        await h.ingest(id, payload("StopFailure", session: claudeSid, ["error": "overloaded", "error_details": "API Error: 529"]))
        #expect(await h.state(id) == .error(.overloaded))
        #expect(await h.engine.update(for: id)?.state.needsAttention == true)
        // idle_prompt does not hide a failed turn; a new prompt does.
        await h.tick()
        await h.ingest(id, payload("Notification", session: claudeSid, ["notification_type": "idle_prompt"]))
        #expect(await h.state(id) == .error(.overloaded))
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid))
        #expect(await h.state(id) == .busy)
    }

    @Test func compaction() async throws {
        let h = harness()
        await h.engine.register(registration())
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid))
        await h.tick()
        await h.ingest(id, payload("PreCompact", session: claudeSid, ["trigger": "auto"]))
        #expect(await h.state(id) == .compacting)
        // Registry busy during compaction is expected and does not override.
        await h.tick(3)
        await h.engine.ingestRegistry(RegistrySnapshot(entries: [entry(pid: 4242, status: "busy", at: h.clock.now())]))
        #expect(await h.state(id) == .compacting)
        await h.ingest(id, payload("PostCompact", session: claudeSid, ["trigger": "auto"]))
        #expect(await h.state(id) == .busy)
        await h.ingest(id, payload("PreCompact", session: claudeSid, ["trigger": "manual"]))
        await h.ingest(id, payload("SessionStart", session: claudeSid, ["source": "compact"]))
        #expect(await h.state(id) == .done) // manual /compact ends idle (a turn happened → done)
    }

    @Test func registryOverridesAfterEsc() async throws {
        let h = harness()
        await h.engine.register(registration())
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid))
        #expect(await h.state(id) == .busy)
        // Within the 1 s margin the hook still wins.
        await h.engine.ingestRegistry(RegistrySnapshot(entries: [entry(pid: 4242, status: "idle", at: h.clock.now().addingTimeInterval(0.5))]))
        #expect(await h.state(id) == .busy)
        // Esc: no hook fires; the registry turns idle 3 s later.
        await h.tick(3)
        await h.engine.ingestRegistry(RegistrySnapshot(entries: [entry(pid: 4242, status: "idle", at: h.clock.now())]))
        let u = try #require(await h.engine.update(for: id))
        #expect(u.state == .done)
        #expect(u.activity.source == .registry)
        #expect(u.registry?.pid == 4242)
        // Approved permission: no hook until PostToolUse; registry busy corrects WAITING.
        await h.tick()
        await h.ingest(id, payload("PermissionRequest", session: claudeSid, ["tool_name": "Edit"]))
        #expect(await h.state(id) == .waiting(.permission))
        await h.tick(2)
        await h.engine.ingestRegistry(RegistrySnapshot(entries: [entry(pid: 4242, status: "busy", at: h.clock.now())]))
        #expect(await h.state(id) == .busy)
    }

    @Test func registryOnlyWaitingHasAReasonAndMatchesBySessionId() async throws {
        let h = harness()
        await h.engine.register(registration(fresh: true, startedAt: referenceNow.addingTimeInterval(-60), pid: nil))
        #expect(await h.state(id) == .unknown)
        await h.engine.ingestRegistry(RegistrySnapshot(entries: [
            entry(pid: 7, status: "waiting", at: h.clock.now(), waitingFor: "permission prompt", sessionId: claudeSid),
        ]))
        #expect(await h.state(id) == .waiting(.permission))
        #expect(await h.engine.update(for: id)?.hookSeen == false)
    }

    @Test func persistenceAndRestore() async throws {
        let root = try TempDir("codd-engine")
        defer { root.remove() }
        let first = harness(dataRoot: root.url)
        await first.engine.register(registration())
        await first.ingest(id, payload("UserPromptSubmit", session: claudeSid, ["prompt": "deploy"]))
        await first.ingest(id, payload("PermissionRequest", session: claudeSid, ["tool_name": "Bash"]))
        await first.engine.flush()
        let file = root.url.appendingPathComponent("hooks/\(id.uuidString.lowercased()).json")
        #expect(await eventually { FileManager.default.fileExists(atPath: file.path) })
        var info = stat()
        #expect(stat(file.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(stat(file.deletingLastPathComponent().path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        let stored = try JSONDecoder().decode(HookSessionState.self, from: Data(contentsOf: file))
        #expect(stored.state == .waiting)
        #expect(stored.terminalId == id.uuidString.lowercased())
        #expect(stored.configDir == "/synthetic/.claude")
        await first.engine.finish()

        // CODD relaunched, claude kept running: the restored record is shown before any hook.
        let second = harness(dataRoot: root.url, start: referenceNow.addingTimeInterval(30))
        await second.engine.register(registration(fresh: false))
        let restored = try #require(await second.engine.update(for: id))
        #expect(restored.state == .waiting(.permission))
        #expect(restored.hookSeen)
        #expect(restored.hook?.lastPrompt == "deploy")
        await second.engine.finish()

        // RESUME into a new process under another Claude session id: the old record is hidden
        // (starting) and the new process's events are accepted thanks to the relaunch baseline.
        let third = harness(dataRoot: root.url, start: referenceNow.addingTimeInterval(60))
        await third.engine.register(registration(fresh: true, startedAt: third.clock.now()))
        #expect(await third.state(id) == .starting)
        #expect(await third.engine.update(for: id)?.hook == nil)
        await third.ingest(id, payload("SessionStart", session: "22222222-bbbb-4bbb-8bbb-222222222222", ["source": "resume"]))
        await third.ingest(id, payload("UserPromptSubmit", session: "22222222-bbbb-4bbb-8bbb-222222222222"))
        let resumed = try #require(await third.engine.update(for: id))
        #expect(resumed.state == .busy)
        #expect(resumed.hook?.sessionId == "22222222-bbbb-4bbb-8bbb-222222222222")
        await third.engine.finish()

        // Without the baseline the reducer's nested-claude guard would have ignored those events.
        let stale = try JSONDecoder().decode(HookSessionState.self, from: Data(contentsOf: file))
        #expect(stale.sessionId == "22222222-bbbb-4bbb-8bbb-222222222222")
    }

    @Test func claudeProcessStartedBaselinesAndRestartsGrace() async throws {
        let h = harness()
        await h.engine.register(registration(fresh: false, startedAt: referenceNow.addingTimeInterval(-100)))
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid))
        #expect(await h.state(id) == .busy)
        await h.engine.processExited(id, code: 0)
        #expect(await h.state(id) == .exited(code: 0))
        await h.tick()
        await h.engine.claudeProcessStarted(id, pid: 5000, startedAt: h.clock.now())
        #expect(await h.state(id) == .starting)
        await h.ingest(id, payload("SessionStart", session: "33333333-cccc-4ccc-8ccc-333333333333", ["source": "startup"]))
        #expect(await h.state(id) == .idle)
    }

    @Test func batchingCoalescesToTenHertz() async throws {
        let h = harness()
        let other = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        await h.engine.register(registration(fresh: false, startedAt: referenceNow.addingTimeInterval(-100)))
        await h.engine.register(SessionRegistration(sessionID: other, kind: .claude, process: .running(startedAt: referenceNow.addingTimeInterval(-100)),
                                                    claudePid: 99, freshClaudeProcess: false))
        #expect(await h.batches.wait(count: 1)) // the first registration went out at once
        h.clock.advance(by: 0.1) // the second one waits for the end of the 100 ms window
        #expect(await h.batches.wait(count: 2))
        await h.tick(1)
        // A burst within one 100 ms window: the first change goes out immediately, the rest are
        // coalesced into one batch with the latest value per session.
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid))
        #expect(await h.batches.wait { $0.last?.updates.first?.state == .busy })
        let before = h.batches.count
        await h.ingest(id, payload("PreToolUse", session: claudeSid, ["tool_name": "AskUserQuestion"]))
        await h.ingest(id, payload("PostToolUse", session: claudeSid, ["tool_name": "AskUserQuestion"]))
        await h.ingest(id, payload("PermissionRequest", session: claudeSid, ["tool_name": "Bash"]))
        await h.ingest(other, payload("UserPromptSubmit", session: "x"))
        await h.ingest(other, payload("Stop", session: "x"))
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.batches.count == before) // held back until the window ends
        h.clock.advance(by: 0.1)
        #expect(await h.batches.wait(count: before + 1))
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.batches.count == before + 1)
        let batch = try #require(h.batches.values.last)
        #expect(batch.updates.count == 2)
        #expect(batch.updates.first { $0.sessionID == id }?.state == .waiting(.permission))
        #expect(batch.updates.first { $0.sessionID == other }?.state == .done)
        // A change that reverts within the window is not emitted at all.
        await h.tick(1)
        await h.ingest(id, payload("PostToolUse", session: claudeSid, ["tool_name": "Bash"])) // busy, emitted at once
        let n = h.batches.count
        await h.engine.setLastViewed(other, at: h.clock.now()) // done → idle
        await h.engine.setLastViewed(other, at: h.clock.now().addingTimeInterval(-3600)) // back to done
        h.clock.advance(by: 0.1)
        try await Task.sleep(for: .milliseconds(30))
        #expect(h.batches.values.dropFirst(n).allSatisfy { !$0.updates.contains { $0.sessionID == other } })
    }

    @Test func startingBecomesUnknownOrTitleDerived() async throws {
        let h = harness()
        await h.engine.register(registration())
        #expect(await h.state(id) == .starting)
        await h.engine.ingestTitle("\u{2733} Claude Code", for: id)
        #expect(await h.state(id) == .starting) // the title is not trusted during the grace period
        h.clock.advance(by: 21)
        #expect(await eventually { await h.state(id) == .idle })
        await h.engine.ingestTitle("\u{25D0} Fixing tests", for: id)
        #expect(await h.state(id) == .busy)
        #expect(await h.engine.update(for: id)?.title?.text == "Fixing tests")
        await h.settle()
        let flips = h.batches.count
        await h.engine.ingestTitle("\u{25D1} Fixing tests", for: id) // spinner flip: no change
        #expect(await h.engine.update(for: id)?.state == .busy)
        try await Task.sleep(for: .milliseconds(20))
        #expect(h.batches.count == flips)

        let other = UUID()
        await h.engine.register(SessionRegistration(sessionID: other, kind: .claude, process: .running(startedAt: h.clock.now()),
                                                    freshClaudeProcess: true))
        h.clock.advance(by: 21)
        #expect(await eventually { await h.state(other) == .unknown })
        #expect(await h.engine.update(for: other)?.hookSeen == false)
    }

    @Test func exitShellOrphansAndRemoval() async throws {
        let h = harness()
        // Hooks that arrive before the session is registered are replayed on registration.
        await h.ingest(id, payload("UserPromptSubmit", session: claudeSid))
        await h.ingest(id, payload("PermissionRequest", session: claudeSid, ["tool_name": "ExitPlanMode"]))
        #expect(await h.engine.update(for: id) == nil)
        await h.engine.register(registration(fresh: true))
        #expect(await h.state(id) == .waiting(.plan))

        await h.engine.processExited(id, code: 1)
        #expect(await h.state(id) == .exited(code: 1))

        let shell = UUID()
        await h.engine.register(SessionRegistration(sessionID: shell, kind: .shell, process: .running(startedAt: h.clock.now()),
                                                    freshClaudeProcess: false))
        #expect(await h.state(shell) == .shell)
        let stopped = UUID()
        await h.engine.register(SessionRegistration(sessionID: stopped, kind: .claude, process: .stopped, freshClaudeProcess: false))
        #expect(await h.state(stopped) == .stopped)

        await h.tick() // fires the pending batch timer (the batch goes out "now")
        await h.tick() // a full window later: the next change is emitted at once
        await h.engine.unregister(shell)
        #expect(await h.engine.update(for: shell) == nil)
        #expect(await h.batches.wait { $0.last?.removed == [shell] })
    }

    @Test func pruneRemovesStaleFiles() async throws {
        let root = try TempDir("codd-engine")
        defer { root.remove() }
        let h = harness(dataRoot: root.url)
        let keep = UUID(), drop = UUID()
        for sid in [keep, drop] {
            await h.engine.register(SessionRegistration(sessionID: sid, kind: .claude, process: .running(startedAt: referenceNow),
                                                        freshClaudeProcess: true))
            await h.ingest(sid, payload("Stop", session: "s-\(sid)"))
        }
        await h.engine.flush()
        let dir = root.url.appendingPathComponent("hooks")
        try Data("not mine".utf8).write(to: dir.appendingPathComponent("notes.json"))
        await h.engine.pruneHookStates(keeping: [keep])
        await h.engine.flush()
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names == ["\(keep.uuidString.lowercased()).json", "notes.json"])
        // Deleting a session removes its file.
        await h.engine.unregister(keep, deletePersistedState: true)
        await h.engine.flush()
        #expect(await eventually { !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(keep.uuidString.lowercased()).json").path) })
    }
}
