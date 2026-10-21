import CoddCore
import Darwin
import Foundation
import Network
import Synchronization
import Testing
@testable import CoddHooks

@Suite("Hook server (real loopback)")
struct HookServerTests {
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"

    func makeServer(_ configure: (inout HookServer.Configuration) -> Void = { _ in }) async throws
        -> (HookServer, UInt16, Collector<HookEvent>, ManualHookClock) {
        var configuration = HookServer.Configuration(port: 0, token: testToken)
        configure(&configuration)
        let clock = ManualHookClock(now: referenceNow)
        let server = HookServer(configuration: configuration, clock: clock)
        let port = try await server.start()
        #expect(port != 0)
        #expect(server.state == .listening(port: port))
        return (server, port, Collector(server.events), clock)
    }

    @Test func acceptsAValidHookAndYieldsIt() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let body = #"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash","tool_response":{"stdout":"x"}}"#
        #expect(try exchange(port: port, hookRequest(port: port, body: body)) == 204)
        #expect(await events.wait(count: 1))
        let e = try #require(events.values.first)
        #expect(e.sessionID == UUID(uuidString: sid))
        #expect(e.payload.eventName == "PostToolUse")
        #expect(e.payload.toolName == "Bash")
        #expect(e.payload.raw["tool_response"] == nil) // dropped at the boundary
        #expect(e.receivedAt == referenceNow)
    }

    /// Review SEC-1: any token holder could kill CODD with a ~2 KB body nested 300 deep (the decode
    /// recursed on the server's queue until the worker thread's stack ran out, after the 204).
    @Test func deeplyNestedBodiesDoNotCrashTheServer() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        for depth in [300, 511] {
            let objects = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
            let arrays = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
            let body = #"{"hook_event_name":"PostToolUse","tool_name":"mcp__x__y","tool_input":{"q":"# + arrays
                + #"},"tool_response":"# + objects + "}"
            #expect(try exchange(port: port, hookRequest(port: port, body: body)) == 204)
        }
        #expect(try exchange(port: port, hookRequest(port: port, body: #"{"hook_event_name":"Stop"}"#)) == 204)
        #expect(await events.wait(count: 3))
        #expect(events.values.map(\.payload.eventName) == ["PostToolUse", "PostToolUse", "Stop"])
        #expect(events.values.first?.payload.toolName == "mcp__x__y")
        #expect(events.values.first?.payload.raw["tool_response"] == nil)
    }

    @Test func authMatrixOverTheNetworkYieldsNoEvents() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let cases: [(String, Int)] = [
            (hookRequest(port: port, token: nil), 401),
            (hookRequest(port: port, token: String(repeating: "cd", count: 32)), 401),
            (hookRequest(port: port, extraHeaders: ["Origin: http://evil.example"]), 403),
            (hookRequest(port: port, host: "evil.example:\(port)"), 403),
            (hookRequest(port: port, host: "127.0.0.1"), 403),
            (hookRequest(port: port, session: "nope"), 400),
            (hookRequest(port: port, session: nil), 400),
            (hookRequest(port: port, method: "GET"), 405),
            (hookRequest(port: port, path: "/nope"), 404),
            ("POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-CODD-Token: \(testToken)\r\nX-CODD-Session: \(sid)\r\n\r\n", 411),
            ("POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: x\r\n\r\n", 400),
            ("NONSENSE\r\n\r\n", 400),
        ]
        for (request, expected) in cases {
            #expect(try exchange(port: port, request) == expected, "\(request.prefix(60))")
        }
        // A valid request afterwards is the first and only event.
        #expect(try exchange(port: port, hookRequest(port: port, body: #"{"hook_event_name":"Stop"}"#)) == 204)
        #expect(await events.wait(count: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.count == 1)
        #expect(events.values.first?.payload.eventName == "Stop")
        // The counters explain the refusals without ever quoting a token.
        let stats = await server.statistics()
        #expect(stats.accepted == 1)
        #expect(stats.rejected == [401: 2, 403: 3, 400: 4, 405: 1, 404: 1, 411: 1])
        #expect(stats.lastRejection?.hasPrefix("400 ") == true)
        _ = try exchange(port: port, hookRequest(port: port, token: String(repeating: "cd", count: 32)))
        #expect(await server.statistics().lastRejection == "401 wrong token")
        _ = try exchange(port: port, hookRequest(port: port, extraHeaders: ["Origin: http://evil.example"]))
        #expect(await server.statistics().lastRejection == #"403 Origin header present ("http://evil.example")"#)
    }

    @Test func healthNeedsNoTokenAndRevealsNothing() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let client = try RawClient(port: port)
        client.send("GET /health HTTP/1.1\r\nHost: localhost:\(port)\r\n\r\n")
        let response = String(decoding: client.readAll(), as: UTF8.self)
        client.close()
        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.hasSuffix("\r\n\r\n{\"ok\":true,\"app\":\"codd\"}"))
        #expect(response.contains("Content-Type: application/json"))
        let headClient = try RawClient(port: port)
        headClient.send("HEAD /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        let headResponse = String(decoding: headClient.readAll(), as: UTF8.self)
        headClient.close()
        #expect(headResponse.hasPrefix("HTTP/1.1 200 OK"))
        #expect(!headResponse.contains("{"))
        #expect(await HookHealthProbe.probe(port: port) == .codd)
        #expect(events.count == 0)
    }

    /// Review SEC-3: any process holding the port could answer `{"app":"codd"}` and be shown as
    /// "another CODD". With the token, the probe proves it (HMAC of a fresh nonce).
    @Test func healthProbeProvesTheTokenAndUnmasksAnImpostor() async throws {
        let (server, port, _, _) = try await makeServer()
        defer { Task { await server.finish() } }
        #expect(await HookHealthProbe.probe(port: port, token: testToken) == .codd)
        #expect(await HookHealthProbe.probe(port: port, token: String(repeating: "cd", count: 32)) == .otherService(status: 200))
        // The plain body (curl, scripts) is unchanged.
        #expect(await HookHealthProbe.probe(port: port) == .codd)
        let challenge = String(repeating: "ab", count: 16)
        let proof = HookRequestPolicy.proof(token: testToken, challenge: challenge)
        #expect(proof.count == 64 && !proof.contains(testToken))
        let client = try RawClient(port: port)
        client.send("GET /health HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\(HookRequestPolicy.challengeHeader): \(challenge)\r\n\r\n")
        let response = String(decoding: client.readAll(), as: UTF8.self)
        client.close()
        #expect(response.hasSuffix(#"{"ok":true,"app":"codd","proof":"\#(proof)"}"#))

        // A squatter that copies the plain answer.
        let impostor = try StalledListener()
        defer { impostor.close() }
        let fd = impostor.fd
        DispatchQueue.global().async {
            for _ in 0..<2 {
                let connection = accept(fd, nil, nil)
                guard connection >= 0 else { return }
                var buffer = [UInt8](repeating: 0, count: 4096)
                _ = read(connection, &buffer, buffer.count)
                let answer = Array("HTTP/1.1 200 OK\r\nContent-Length: 24\r\nConnection: close\r\n\r\n".utf8) + HookRequestPolicy.healthBody
                _ = answer.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
                Darwin.close(connection)
            }
        }
        #expect(await HookHealthProbe.probe(port: impostor.port) == .codd)  // what the old check concluded
        #expect(await HookHealthProbe.probe(port: impostor.port, token: testToken) == .otherService(status: 200))
    }

    @Test func healthProbeDistinguishesListeners() async throws {
        #expect(await HookHealthProbe.probe(port: freeNonEphemeralPort()) == .noListener)
        let stalled = try StalledListener()
        defer { stalled.close() }
        #expect(await HookHealthProbe.probe(port: stalled.port, timeoutMilliseconds: 200) == .timedOut)
    }

    @Test func splitPacketsAndExpectContinue() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let body = #"{"hook_event_name":"UserPromptSubmit","prompt":"split"}"#
        let request = Array(hookRequest(port: port, body: body).utf8)
        let client = try RawClient(port: port)
        for piece in stride(from: 0, to: request.count, by: 7) {
            client.send(Array(request[piece..<min(piece + 7, request.count)]))
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(RawClient.status(client.readAll()) == 204)
        client.close()

        // Expect: 100-continue (what curl does for bodies over 1 KiB).
        let big = #"{"hook_event_name":"Notification","notification_type":"permission_prompt","pad":""#
            + String(repeating: "x", count: 4000) + #""}"#
        let head = "POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-CODD-Token: \(testToken)\r\nX-CODD-Session: \(sid)\r\n"
            + "Content-Length: \(big.utf8.count)\r\nExpect: 100-continue\r\n\r\n"
        let c2 = try RawClient(port: port)
        c2.send(head)
        let interim = String(decoding: c2.read(until: "\r\n\r\n"), as: UTF8.self)
        #expect(interim == "HTTP/1.1 100 Continue\r\n\r\n")
        c2.send(big)
        #expect(RawClient.status(c2.readAll()) == 204)
        c2.close()
        #expect(await events.wait(count: 2))
        #expect(events.values.map { $0.payload.eventName } == ["UserPromptSubmit", "Notification"])
    }

    @Test func oversizedBodyGets413NotAReset() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let client = try RawClient(port: port)
        client.send("POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-CODD-Token: \(testToken)\r\nX-CODD-Session: \(sid)\r\nContent-Length: 2000000\r\n\r\n")
        client.send([UInt8](repeating: 0x61, count: 200_000)) // keeps sending part of the body anyway
        #expect(RawClient.status(client.readAll()) == 413)
        client.close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.count == 0)
    }

    @Test func clientThatHalfClosesStillGetsTheAnswer() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        for _ in 0..<20 {
            let client = try RawClient(port: port)
            client.send(hookRequest(port: port))
            client.shutdownWrite()
            #expect(RawClient.status(client.readAll()) == 204)
            client.close()
        }
        #expect(await events.wait(count: 20))
        #expect(await eventually { await server.connectionCount() == 0 })
    }

    @Test func curlClient() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let tmp = try TempDir("codd-curl")
        defer { tmp.remove() }
        let small = tmp.file("small.json"), big = tmp.file("big.json")
        try Data(#"{"hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8).write(to: small)
        // Over 1 KiB: curl sends Expect: 100-continue.
        try Data((#"{"hook_event_name":"Stop","pad":""# + String(repeating: "y", count: 5000) + #""}"#).utf8).write(to: big)
        func curl(_ file: URL, token: String) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-s", "--noproxy", "*", "-m", "5", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST",
                           "-H", "Content-Type: application/json", "-H", "X-CODD-Token: \(token)", "-H", "X-CODD-Session: \(sid)",
                           "--data-binary", "@\(file.path)", "http://127.0.0.1:\(port)/hooks"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }
        #expect(try curl(small, token: testToken) == "204")
        #expect(try curl(big, token: testToken) == "204")
        #expect(try curl(big, token: String(repeating: "0", count: 64)) == "401")
        #expect(await events.wait(count: 2))
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.values.map { $0.payload.eventName } == ["UserPromptSubmit", "Stop"])
    }

    @Test func pipelinedRequestsProduceOneEvent() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let one = hookRequest(port: port, body: #"{"hook_event_name":"Stop"}"#)
        let two = hookRequest(port: port, body: #"{"hook_event_name":"SessionEnd"}"#)
        let client = try RawClient(port: port)
        client.send(one + two)
        let response = String(decoding: client.readAll(), as: UTF8.self)
        client.close()
        #expect(response.components(separatedBy: "HTTP/1.1").count == 2) // exactly one response
        #expect(await events.wait(count: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(events.values.map { $0.payload.eventName } == ["Stop"])
    }

    @Test func slowClientTimesOut() async throws {
        let (server, port, events, _) = try await makeServer { $0.readTimeout = .milliseconds(300) }
        defer { Task { await server.finish() } }
        let client = try RawClient(port: port)
        let start = Date()
        client.send("POST /hooks HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n")
        #expect(RawClient.status(client.readAll()) == 408)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.25 && elapsed < 2.5)
        client.close()
        #expect(events.count == 0)
        #expect(await eventually { await server.connectionCount() == 0 })
    }

    /// Review SEC-4 / E2E-5: past the limit, connections were reset (a burst of hooks lost, and 64
    /// idle sockets from any local account blocked every hook for 5 s at a time). They wait now,
    /// and idle sockets lose their slot after the head timeout.
    @Test func connectionsPastTheLimitWaitInsteadOfBeingReset() async throws {
        let (server, port, events, _) = try await makeServer {
            $0.maxConnections = 2
            $0.headTimeout = .milliseconds(300)
        }
        defer { Task { await server.finish() } }
        let a = try RawClient(port: port)
        let b = try RawClient(port: port)
        #expect(await eventually { await server.connectionCount() == 2 })
        // A third client with a valid hook: queued, answered once an idle slot times out.
        let c = try RawClient(port: port, receiveTimeout: 5)
        let start = Date()
        c.send(hookRequest(port: port))
        let raw = c.readAll()
        c.close()
        #expect(RawClient.status(raw) == 204, "\(String(decoding: raw, as: UTF8.self))")
        #expect(Date().timeIntervalSince(start) >= 0.2, "it waited for a slot")
        #expect(await events.wait(count: 1))
        #expect(RawClient.status(a.readAll()) == 408)
        #expect(RawClient.status(b.readAll()) == 408)
        a.close()
        b.close()
        #expect(await server.statistics().lastRejection == "408 request head not complete in time")
        #expect(await eventually { await server.connectionCount() == 0 })
    }

    @Test func aBurstLargerThanTheLimitIsServedInFull() async throws {
        let (server, port, events, _) = try await makeServer { $0.maxConnections = 4 }
        defer { Task { await server.finish() } }
        let statuses = Mutex<[Int?]>([])
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    let status = try? exchange(port: port, hookRequest(port: port, body: #"{"hook_event_name":"Stop"}"#))
                    statuses.withLock { $0.append(status ?? nil) }
                }
            }
        }
        #expect(statuses.withLock { $0 }.filter { $0 == 204 }.count == 40, "\(statuses.withLock { $0 })")
        #expect(await events.wait(count: 40))
        #expect(await server.statistics().refusedConnections == 0)
    }

    @Test func urlSessionClient() async throws {
        let (server, port, events, _) = try await makeServer()
        defer { Task { await server.finish() } }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hooks")!)
        request.httpMethod = "POST"
        request.setValue(testToken, forHTTPHeaderField: "X-CODD-Token")
        request.setValue(sid, forHTTPHeaderField: "X-CODD-Session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#.utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)
        #expect(await events.wait(count: 1))
        #expect(events.values.first?.payload.event == .permissionRequest)
    }

    @Test func portInUseIsATypedError() async throws {
        let occupied = occupyNonEphemeralPort()
        defer { occupied.close() }
        let server = HookServer(configuration: .init(port: occupied.port, token: testToken))
        await #expect(throws: HookServerError.portInUse(occupied.port)) {
            try await server.start()
        }
        #expect(server.state == .failed(.portInUse(occupied.port)))
        // After the port is released, a retry works.
        occupied.close()
        let port = try await server.start()
        #expect(port == occupied.port)
        await server.finish()
    }

    @Test func restartKeepsTheEventStream() async throws {
        let fixed = freeNonEphemeralPort(in: TestPorts.restart)
        let (server, port, events, _) = try await makeServer { $0.port = fixed }
        #expect(port == fixed)
        #expect(try exchange(port: port, hookRequest(port: port)) == 204)
        await server.stop()
        #expect(server.state == .stopped)
        #expect(throws: (any Error).self) { try exchange(port: port, hookRequest(port: port)) }
        let newPort = try await server.restart(port: port)
        #expect(newPort == port)
        #expect(try exchange(port: port, hookRequest(port: newPort)) == 204)
        // A new token takes effect on restart.
        let other = String(repeating: "cd", count: 32)
        let p3 = try await server.restart(port: 0, token: other)
        #expect(try exchange(port: p3, hookRequest(port: p3)) == 401)
        #expect(try exchange(port: p3, hookRequest(port: p3, token: other)) == 204)
        #expect(await events.wait(count: 3))
        await server.finish()
    }

    @Test func startTwiceIsRejected() async throws {
        let (server, _, _, _) = try await makeServer()
        await #expect(throws: HookServerError.alreadyRunning) { try await server.start() }
        await server.finish()
    }

    @Test func loopbackPeerCheck() {
        #expect(HookServer.isLoopbackPeer(.hostPort(host: .ipv4(.loopback), port: 5)))
        #expect(HookServer.isLoopbackPeer(.hostPort(host: .ipv4(IPv4Address("127.9.9.9")!), port: 5)))
        #expect(!HookServer.isLoopbackPeer(.hostPort(host: .ipv4(IPv4Address("192.168.1.2")!), port: 5)))
        #expect(!HookServer.isLoopbackPeer(.hostPort(host: .ipv6(.loopback), port: 5)))
        #expect(!HookServer.isLoopbackPeer(.hostPort(host: .name("localhost", nil), port: 5)))
    }

    @Test func emptyTokenRefusesToStart() async {
        let server = HookServer(configuration: .init(port: 0, token: ""))
        await #expect(throws: HookServerError.invalidToken) { try await server.start() }
    }
}
