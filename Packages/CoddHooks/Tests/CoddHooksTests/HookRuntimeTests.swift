import CoddCore
import Foundation
import Testing
@testable import CoddHooks

/// The whole pipeline: config.json → server → engine, with a temp registry directory.
@Suite("Hook runtime")
struct HookRuntimeTests {
    @Test func hooksMoveASessionThroughItsStatesAndWrongTokensChangeNothing() async throws {
        let tmp = try TempDir("codd-runtime")
        defer { tmp.remove() }
        let registry = tmp.file("claude/sessions")
        let id = UUID()
        // A fixed port, as in production. Parallel tests also bind random ports, so a port that
        // was free a moment ago may be taken by the time the server binds: retry with another.
        var setup: (HookRuntime, HookConfig, Collector<SessionStateBatch>, URL)?
        for attempt in 0..<5 where setup == nil {
            let root = tmp.file("data-\(attempt)")
            let port = freeNonEphemeralPort(in: TestPorts.runtime)
            let config = try HookConfigStore(dataRoot: root, portRange: port...port, isPortAvailable: { _ in true })
                .loadOrCreate().config
            #expect(config.port == port)
            let runtime = HookRuntime(config: config, dataRoot: root, registryDirectories: [registry],
                                      liveness: FakeLiveness([4242]))
            await runtime.engine.register(SessionRegistration(
                sessionID: id, kind: .claude, process: .running(startedAt: Date()), claudePid: 4242,
                claudeSessionId: "11111111-aaaa-4aaa-8aaa-111111111111", freshClaudeProcess: true))
            let batches = Collector(runtime.engine.updates)
            do {
                #expect(try await runtime.start() == port)
                setup = (runtime, config, batches, root)
            } catch .portInUse {
                await runtime.finish()
            }
        }
        let (runtime, config, batches, dataRoot) = try #require(setup)
        let port = config.port
        #expect(runtime.server.state == .listening(port: port))

        func post(_ body: String, token: String? = nil) throws -> Int? {
            try exchange(port: port, hookRequest(port: port, token: token ?? config.token, session: id.uuidString.lowercased(), body: body))
        }
        func state() async -> SessionState? { await runtime.engine.update(for: id)?.state }

        #expect(await state() == .starting)
        #expect(try post(#"{"hook_event_name":"UserPromptSubmit","session_id":"11111111-aaaa-4aaa-8aaa-111111111111","prompt":"go"}"#) == 204)
        #expect(await eventually { await state() == .busy })
        #expect(try post(#"{"hook_event_name":"PermissionRequest","session_id":"11111111-aaaa-4aaa-8aaa-111111111111","tool_name":"Bash"}"#) == 204)
        #expect(await eventually { await state() == .waiting(.permission) })

        // Wrong token: 401 and the state does not move.
        #expect(try post(#"{"hook_event_name":"Stop","session_id":"11111111-aaaa-4aaa-8aaa-111111111111"}"#,
                         token: String(repeating: "0", count: 64)) == 401)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await state() == .waiting(.permission))

        #expect(try post(#"{"hook_event_name":"Stop","session_id":"11111111-aaaa-4aaa-8aaa-111111111111"}"#) == 204)
        #expect(await eventually { await state() == .done })
        await runtime.engine.setLastViewed(id, at: Date().addingTimeInterval(1))
        #expect(await eventually { await state() == .idle })
        #expect(await batches.wait { batches in batches.contains { $0.updates.contains { $0.state == .waiting(.permission) } } })

        // The registry directory appears later (Claude never ran with this config dir before).
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let later = JSDate.milliseconds(Date().addingTimeInterval(5))
        try Data(#"{"pid":4242,"sessionId":"11111111-aaaa-4aaa-8aaa-111111111111","status":"busy","statusUpdatedAt":\#(later)}"#.utf8)
            .write(to: registry.appendingPathComponent("4242.json"))
        runtime.watcher.refresh()
        #expect(await eventually(timeout: 8) { await runtime.engine.update(for: id)?.registry?.pid == 4242 })
        #expect(await eventually { await state() == .busy }) // registry busy, newer than the Stop hook

        // Stop writes the hook record; the port is released.
        await runtime.stop()
        #expect(runtime.server.state == .stopped)
        let file = dataRoot.appendingPathComponent("hooks/\(id.uuidString.lowercased()).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(throws: (any Error).self) { try post("{}") }
        // And it can start again on the same port.
        #expect(try await runtime.start() == port)
        #expect(try post(#"{"hook_event_name":"UserPromptSubmit","session_id":"11111111-aaaa-4aaa-8aaa-111111111111"}"#) == 204)
        await runtime.finish()
    }

    @Test func makeLoadsOrCreatesTheConfig() throws {
        let tmp = try TempDir("codd-runtime")
        defer { tmp.remove() }
        let (runtime, load) = try HookRuntime.make(dataRoot: tmp.url, registryDirectories: [tmp.file("none")])
        #expect(load.origin == .created)
        #expect(runtime.config == load.config)
        let (_, again) = try HookRuntime.make(dataRoot: tmp.url, registryDirectories: [tmp.file("none")])
        #expect(again.origin == .loaded)
        #expect(again.config == load.config)
    }
}
