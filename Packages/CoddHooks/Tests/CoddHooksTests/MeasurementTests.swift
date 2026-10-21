import Foundation
import Testing
@testable import CoddHooks

/// Opt-in timing of `codd-hook` and `codd-statusline` (startup + POST + exit), run against the
/// real server:
///
///     swift build -c release --package-path Packages/CoddHooks --scratch-path .build-hooks --product codd-hook
///     swift build -c release --package-path Packages/CoddHooks --scratch-path .build-hooks --product codd-statusline
///     CODD_HOOK_MEASURE=1 CODD_HOOK_BINARY=$PWD/.build-hooks/release/codd-hook \
///       CODD_STATUSLINE_BINARY=$PWD/.build-hooks/release/codd-statusline \
///       swift test --package-path Packages/CoddHooks --scratch-path .build-hooks --filter MeasurementTests
@Suite("Measurements", .enabled(if: ProcessInfo.processInfo.environment["CODD_HOOK_MEASURE"] == "1"))
struct MeasurementTests {
    /// Runs `script` under `zsh -f` and returns the wall time.
    func time(_ script: String, environment: [String: String]) throws -> TimeInterval {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-f", "-c", script]
        p.environment = environment
        p.standardOutput = FileHandle.nullDevice
        let start = Date()
        try p.run()
        p.waitUntilExit()
        return Date().timeIntervalSince(start)
    }

    @Test func coddHookStartupAndPost() async throws {
        let binary = try CoddHookEndToEndTests.binary().path
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        let events = Collector(server.events)
        let tmp = try TempDir("codd-measure")
        defer { tmp.remove() }
        let payload = tmp.file("payload.json")
        try Data(#"{"hook_event_name":"SessionStart","session_id":"11111111-aaaa-4aaa-8aaa-111111111111","source":"startup","cwd":"/tmp"}"#.utf8)
            .write(to: payload)
        let n = 200
        let env = ["CODD_HOOK_TOKEN": testToken, "CODD_SESSION_ID": "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"]
        let baseline = try time("for i in {1..\(n)}; do /usr/bin/true < '\(payload.path)'; done", environment: env)
        let hook = try time("for i in {1..\(n)}; do '\(binary)' session-start --url http://127.0.0.1:\(port)/hooks < '\(payload.path)'; done",
                            environment: env)
        let down = try time("for i in {1..20}; do '\(binary)' session-start --url http://127.0.0.1:1/hooks < '\(payload.path)'; done",
                            environment: env)
        #expect(await events.wait(count: n, timeout: 10))
        let perHook = hook / Double(n) * 1000, perTrue = baseline / Double(n) * 1000
        print(String(format: "MEASURE codd-hook: %.2f ms per run (spawn+post+exit), /usr/bin/true: %.2f ms, net %.2f ms; server down: %.2f ms per run",
                     perHook, perTrue, perHook - perTrue, down / 20 * 1000))
        await server.finish()
    }

    /// `codd-statusline` per status-line refresh: no chain (report only), and with a trivial chain
    /// (`printf`, i.e. the extra `/bin/sh` spawn every CODD session with a user status line pays).
    @Test func coddStatusLineStartupAndPost() async throws {
        let binary = try CoddStatusLineEndToEndTests.binary().path
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        let reports = Collector(server.statusLines)
        let tmp = try TempDir("codd-measure-sl")
        defer { tmp.remove() }
        let payload = tmp.file("statusline.json")
        try Data((#"{"session_id":"11111111-aaaa-4aaa-8aaa-111111111111","cwd":"/tmp","model":{"id":"m"},"#
            + #""rate_limits":{"five_hour":{"used_percentage":9.5,"resets_at":1792042740},"seven_day":{"used_percentage":85,"resets_at":1792296000}}}"#).utf8)
            .write(to: payload)
        let n = 200
        var env = ["CODD_HOOK_TOKEN": testToken, "CODD_SESSION_ID": "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17",
                   "CODD_HOOK_URL": "http://127.0.0.1:\(port)/hooks", "HOME": "/Users/u",
                   "CLAUDE_CONFIG_DIR": "/Users/u/.claude-swap-backup/sessions/2-x"]
        let baseline = try time("for i in {1..\(n)}; do /usr/bin/true < '\(payload.path)'; done", environment: env)
        let plain = try time("for i in {1..\(n)}; do '\(binary)' < '\(payload.path)'; done", environment: env)
        #expect(await reports.wait(count: n, timeout: 10))
        env["CODD_STATUSLINE_CHAIN"] = Data("printf ok".utf8).base64EncodedString()
        let chained = try time("for i in {1..\(n)}; do '\(binary)' < '\(payload.path)'; done", environment: env)
        #expect(await reports.wait(count: 2 * n, timeout: 10))
        env["CODD_HOOK_URL"] = "http://127.0.0.1:1/hooks"
        env["CODD_STATUSLINE_CHAIN"] = nil
        let down = try time("for i in {1..20}; do '\(binary)' < '\(payload.path)'; done", environment: env)
        let perPlain = plain / Double(n) * 1000, perTrue = baseline / Double(n) * 1000, perChained = chained / Double(n) * 1000
        print(String(format: "MEASURE codd-statusline: %.2f ms per run without chain (spawn+post+exit), /usr/bin/true: %.2f ms, net %.2f ms; with a printf chain: %.2f ms; server down: %.2f ms per run",
                     perPlain, perTrue, perPlain - perTrue, perChained, down / 20 * 1000))
        #expect(perPlain < 10)
        await server.finish()
    }
}
