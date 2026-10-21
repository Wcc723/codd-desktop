import CoddCore
import CoddHookClient
import Foundation
import Testing
@testable import CoddHooks

/// Runs the built `codd-hook` binary against a real server.
@Suite("codd-hook end to end")
struct CoddHookEndToEndTests {
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"

    /// `codd-hook` sits next to the test bundle in the build products directory (the test target
    /// depends on the executable target, so `swift test` builds it). `CODD_HOOK_BINARY` overrides
    /// (`CODD_STATUSLINE_BINARY` for `codd-statusline`).
    static func binary(named name: String = "codd-hook", overrideVariable: String = "CODD_HOOK_BINARY") throws -> URL {
        if let override = ProcessInfo.processInfo.environment[overrideVariable] { return URL(fileURLWithPath: override) }
        var candidates: [URL] = []
        for arg in CommandLine.arguments where arg.contains(".xctest") {
            var url = URL(fileURLWithPath: arg)
            while url.pathComponents.count > 1, url.pathExtension != "xctest" { url.deleteLastPathComponent() }
            candidates.append(url.deletingLastPathComponent())
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent())
        }
        candidates.append(Bundle.main.bundleURL)
        for dir in candidates {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw FixtureMissing(what: "\(name) binary near \(candidates.map(\.path))")
    }

    struct FixtureMissing: Error { var what: String }

    struct Run {
        var status: Int32
        var stdout: Data
        var stderr: Data
        var elapsed: TimeInterval
    }

    func run(_ arguments: [String], stdin: Data, environment: [String: String]) throws -> Run {
        let process = Process()
        process.executableURL = try Self.binary()
        process.arguments = arguments
        process.environment = environment
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        let start = Date()
        try process.run()
        input.fileHandleForWriting.write(stdin)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, stdout: out, stderr: err, elapsed: Date().timeIntervalSince(start))
    }

    var sessionStart: Data {
        Data(#"{"hook_event_name":"SessionStart","session_id":"11111111-aaaa-4aaa-8aaa-111111111111","source":"startup","cwd":"/tmp"}"#.utf8)
    }

    func env(token: String = testToken, debug: Bool = false) -> [String: String] {
        var e = [CoddEnvironmentName.hookToken: token, CoddEnvironmentName.sessionId: sid]
        if debug { e["CODD_HOOK_DEBUG"] = "1" }
        return e
    }

    @Test func wireNamesMatchCoddCore() {
        #expect(HookWireNames.tokenEnvironment == CoddEnvironmentName.hookToken)
        #expect(HookWireNames.sessionEnvironment == CoddEnvironmentName.sessionId)
        #expect(HookWireNames.tokenHeader == CoddHookHeader.token)
        #expect(HookWireNames.sessionHeader == CoddHookHeader.session)
        // M3: the names the app's launcher sets for codd-statusline (D8).
        #expect(HookWireNames.urlEnvironment == CoddEnvironmentName.hookURL)
        #expect(StatusLineWireNames.chainEnvironment == CoddEnvironmentName.statusLineChain)
        #expect(HookCommand.maxBodyBytes == HTTPRequestParser.Limits().maxBodyBytes)
        // The arguments ClaudeHookSettings writes are the ones codd-hook parses.
        let settings = ClaudeHookSettings(endpoint: HookEndpoint(port: 47821), sessionStartCommand: "/x/codd-hook")
        let args = settings.settingsObject["hooks"]?["SessionStart"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?["args"]?
            .arrayValue?.compactMap(\.stringValue) ?? []
        let command = HookCommand(arguments: ["codd-hook"] + args, environment: { _ in nil })
        #expect(command.eventHint == "session-start")
        #expect(command.url == "http://127.0.0.1:47821/hooks")
    }

    @Test func deliversSessionStart() async throws {
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        let events = Collector(server.events)
        let r = try run(["session-start", "--url", "http://127.0.0.1:\(port)/hooks"], stdin: sessionStart, environment: env(debug: true))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(String(decoding: r.stderr, as: UTF8.self).contains("delivered"))
        #expect(await events.wait(count: 1))
        let e = try #require(events.values.first)
        #expect(e.sessionID == UUID(uuidString: sid))
        #expect(e.payload.event == .sessionStart)
        #expect(e.payload.source == .string("startup"))
        // localhost works too and is connected as 127.0.0.1.
        let r2 = try run(["anything", "--url=http://localhost:\(port)/hooks"], stdin: sessionStart, environment: env())
        #expect(r2.status == 0)
        #expect(r2.stdout.isEmpty)
        #expect(r2.stderr.isEmpty) // silent without CODD_HOOK_DEBUG
        #expect(await events.wait(count: 2))
        await server.finish()
    }

    @Test func wrongTokenStillExitsZeroAndSilent() async throws {
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        let events = Collector(server.events)
        let r = try run(["session-start", "--url", "http://127.0.0.1:\(port)/hooks"], stdin: sessionStart,
                        environment: env(token: String(repeating: "cd", count: 32), debug: true))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(String(decoding: r.stderr, as: UTF8.self).contains("401"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.count == 0)
        await server.finish()
    }

    @Test func serverDownExitsZeroQuickly() throws {
        let port = freeNonEphemeralPort()
        let r = try run(["session-start", "--url", "http://127.0.0.1:\(port)/hooks"], stdin: sessionStart, environment: env())
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.elapsed < 2)
    }

    @Test func stalledServerExitsZeroWithinTwoSeconds() throws {
        let stalled = try StalledListener()
        defer { stalled.close() }
        let r = try run(["session-start", "--url", "http://127.0.0.1:\(stalled.port)/hooks"], stdin: sessionStart, environment: env(debug: true))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.elapsed < 2.3)
        #expect(String(decoding: r.stderr, as: UTF8.self).contains("timedOut"))
    }

    @Test func refusesNonLoopbackAndMissingEnvironment() throws {
        for url in ["http://example.com:47821/hooks", "https://127.0.0.1:47821/hooks", "http://user@127.0.0.1:1/hooks", ""] {
            let r = try run(["session-start", "--url", url], stdin: sessionStart, environment: env(debug: true))
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
        }
        let noToken = try run(["session-start", "--url", "http://127.0.0.1:1/hooks"], stdin: sessionStart,
                              environment: [CoddEnvironmentName.sessionId: sid, "CODD_HOOK_DEBUG": "1"])
        #expect(noToken.status == 0)
        #expect(String(decoding: noToken.stderr, as: UTF8.self).contains("CODD_HOOK_TOKEN"))
        let headerInjection = try run(["session-start", "--url", "http://127.0.0.1:1/hooks"], stdin: sessionStart,
                                      environment: [CoddEnvironmentName.hookToken: "a\r\nX-Evil: 1", CoddEnvironmentName.sessionId: sid,
                                                    "CODD_HOOK_DEBUG": "1"])
        #expect(headerInjection.status == 0)
        #expect(String(decoding: headerInjection.stderr, as: UTF8.self).contains("not sent"))
    }

    @Test func oversizedStdinIsNotSent() async throws {
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        let events = Collector(server.events)
        let big = Data(repeating: 0x20, count: (1 << 20) + 10)
        let r = try run(["session-start", "--url", "http://127.0.0.1:\(port)/hooks"], stdin: big, environment: env(debug: true))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(String(decoding: r.stderr, as: UTF8.self).contains("1 MiB"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.count == 0)
        await server.finish()
    }

    @Test func urlFromEnvironmentWhenNoArgument() async throws {
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        let events = Collector(server.events)
        var e = env()
        e["CODD_HOOK_URL"] = "http://127.0.0.1:\(port)/hooks"
        let r = try run(["session-start"], stdin: sessionStart, environment: e)
        #expect(r.status == 0)
        #expect(await events.wait(count: 1))
        await server.finish()
    }
}
