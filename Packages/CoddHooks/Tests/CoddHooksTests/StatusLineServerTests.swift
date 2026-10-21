import CoddCore
import Foundation
import Testing
@testable import CoddHooks

@Suite("Hook server: /statusline (real loopback)")
struct StatusLineServerTests {
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"

    func makeServer() async throws -> (HookServer, UInt16, Collector<StatusLineReport>, Collector<HookEvent>) {
        let server = HookServer(configuration: .init(port: 0, token: testToken), clock: ManualHookClock(now: referenceNow))
        let port = try await server.start()
        return (server, port, Collector(server.statusLines), Collector(server.events))
    }

    func report(_ key: String, five: Double? = nil, seven: Double? = nil) -> String {
        var windows: [String] = []
        if let five { windows.append(#""five_hour":{"used_percentage":\#(five),"resets_at":1792042740}"#) }
        if let seven { windows.append(#""seven_day":{"used_percentage":\#(seven),"resets_at":1792296000}"#) }
        let limits = windows.isEmpty ? "null" : "{" + windows.joined(separator: ",") + "}"
        return #"{"v":1,"session_id":"claude-\#(key)","config_key":"\#(key)","rate_limits":\#(limits)}"#
    }

    func statusLineRequest(port: UInt16, token: String? = testToken, session: String? = nil, body: String,
                           extraHeaders: [String] = []) -> String {
        var lines = ["POST /statusline HTTP/1.1", "Host: 127.0.0.1:\(port)"]
        if let token { lines.append("X-CODD-Token: \(token)") }
        if let session { lines.append("X-CODD-Session: \(session)") }
        lines.append("Content-Type: application/json")
        lines.append("Content-Length: \(body.utf8.count)")
        lines += extraHeaders
        return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
    }

    @Test func reportsAreAnswered204AndYieldedInOrder() async throws {
        let (server, port, reports, events) = try await makeServer()
        defer { Task { await server.finish() } }
        #expect(try exchange(port: port, statusLineRequest(port: port, session: sid, body: report("cswap-3", five: 9, seven: 85))) == 204)
        #expect(try exchange(port: port, statusLineRequest(port: port, body: report("default"))) == 204)
        #expect(try exchange(port: port, statusLineRequest(port: port, session: sid.uppercased(), body: report("cswap-2", seven: 54))) == 204)
        #expect(await reports.wait(count: 3))
        let r = reports.values
        #expect(r.map(\.configKey) == ["cswap-3", "default", "cswap-2"])
        #expect(r.map(\.sessionID) == [UUID(uuidString: sid), nil, UUID(uuidString: sid)])
        #expect(r[0].fiveHour == StatusLineWindow(usedPercent: 9, resetsAt: Date(timeIntervalSince1970: 1_792_042_740)))
        #expect(r[0].sevenDay?.usedPercent == 85)
        #expect(r[0].claudeSessionId == "claude-cswap-3")
        #expect(!r[1].hadRateLimits)
        #expect(r[2].fiveHour == nil && r[2].sevenDay?.usedPercent == 54)
        #expect(r.allSatisfy { $0.receivedAt == referenceNow })
        try await Task.sleep(for: .milliseconds(30))
        #expect(events.count == 0) // reports never reach the hook stream
    }

    @Test func statisticsCountReports() async throws {
        let (server, port, reports, _) = try await makeServer()
        defer { Task { await server.finish() } }
        #expect(await server.statistics().lastStatusLineAt == nil)
        for key in ["cswap-1", "cswap-2"] {
            #expect(try exchange(port: port, statusLineRequest(port: port, body: report(key, five: 1))) == 204)
        }
        // Answered before decoding, but not a report: counted apart, nothing yielded.
        #expect(try exchange(port: port, statusLineRequest(port: port, body: "not json")) == 204)
        #expect(try exchange(port: port, statusLineRequest(port: port, token: nil, body: report("default"))) == 401)
        #expect(await reports.wait(count: 2))
        let stats = await server.statistics()
        #expect(stats.statusLinesAccepted == 2)
        #expect(stats.statusLinesUndecodable == 1)
        #expect(stats.lastStatusLineAt == referenceNow)
        #expect(stats.accepted == 0) // hooks
        #expect(stats.rejected == [401: 1])
        #expect(stats.lastRejection == "401 token missing")
    }

    @Test func authAndLimitsOverTheNetwork() async throws {
        let (server, port, reports, events) = try await makeServer()
        defer { Task { await server.finish() } }
        let body = report("default", five: 1)
        let big = #"{"v":1,"config_key":"default","rate_limits":{"pad":""# + String(repeating: "y", count: 70_000) + #""}}"#
        let cases: [(String, Int)] = [
            (statusLineRequest(port: port, token: nil, body: body), 401),
            (statusLineRequest(port: port, token: String(repeating: "cd", count: 32), body: body), 401),
            (statusLineRequest(port: port, body: body, extraHeaders: ["X-CODD-Token: \(testToken)"]), 401),
            (statusLineRequest(port: port, body: body, extraHeaders: ["Origin: http://evil.example"]), 403),
            (statusLineRequest(port: port, session: "nope", body: body), 400),
            ("POST /statusline HTTP/1.1\r\nHost: evil.example:\(port)\r\nX-CODD-Token: \(testToken)\r\nContent-Length: 2\r\n\r\n{}", 403),
            ("POST /statusline HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-CODD-Token: \(testToken)\r\n\r\n", 411),
            (statusLineRequest(port: port, body: big), 413),
        ]
        for (request, expected) in cases {
            #expect(try exchange(port: port, request) == expected, "\(request.prefix(70))")
        }
        // GET gets 405 with Allow: POST.
        let client = try RawClient(port: port)
        client.send("GET /statusline HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-CODD-Token: \(testToken)\r\n\r\n")
        let response = String(decoding: client.readAll(), as: UTF8.self)
        client.close()
        #expect(response.hasPrefix("HTTP/1.1 405 "))
        #expect(response.contains("Allow: POST\r\n"))
        // A chunked body over 64 KiB is cut off by the route's limit (the parser allows 1 MiB elsewhere).
        let chunk = String(repeating: "z", count: 40_000)
        let chunked = "POST /statusline HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nX-CODD-Token: \(testToken)\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(chunk.utf8.count, radix: 16) + "\r\n" + chunk + "\r\n" + String(chunk.utf8.count, radix: 16) + "\r\n" + chunk + "\r\n0\r\n\r\n"
        #expect(try exchange(port: port, chunked) == 413)
        // /hooks is unaffected: the same server still takes a large hook.
        let hookBody = #"{"hook_event_name":"Stop","pad":""# + String(repeating: "x", count: 100_000) + #""}"#
        #expect(try exchange(port: port, hookRequest(port: port, body: hookBody)) == 204)
        #expect(await events.wait(count: 1))
        try await Task.sleep(for: .milliseconds(30))
        #expect(reports.count == 0)
        let stats = await server.statistics()
        #expect(stats.rejected == [401: 3, 403: 2, 400: 1, 405: 1, 411: 1, 413: 2])
        #expect(stats.accepted == 1)
    }

    @Test func smallChunkedReportIsAccepted() async throws {
        let (server, port, reports, _) = try await makeServer()
        defer { Task { await server.finish() } }
        let body = report("cswap-4", five: 3)
        let request = "POST /statusline HTTP/1.1\r\nHost: localhost:\(port)\r\nX-CODD-Token: \(testToken)\r\nX-CODD-Session: \(sid)\r\n"
            + "Transfer-Encoding: chunked\r\n\r\n" + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n0\r\n\r\n"
        #expect(try exchange(port: port, request) == 204)
        #expect(await reports.wait(count: 1))
        #expect(reports.values.first?.configKey == "cswap-4")
    }

    @Test func hooksAndReportsInterleave() async throws {
        let (server, port, reports, events) = try await makeServer()
        defer { Task { await server.finish() } }
        #expect(try exchange(port: port, hookRequest(port: port, body: #"{"hook_event_name":"UserPromptSubmit"}"#)) == 204)
        #expect(try exchange(port: port, statusLineRequest(port: port, session: sid, body: report("default", five: 50))) == 204)
        #expect(try exchange(port: port, hookRequest(port: port, body: #"{"hook_event_name":"Stop"}"#)) == 204)
        #expect(await events.wait(count: 2))
        #expect(await reports.wait(count: 1))
        #expect(events.values.map(\.payload.eventName) == ["UserPromptSubmit", "Stop"])
        #expect(reports.values.first?.fiveHour?.usedPercent == 50)
        let stats = await server.statistics()
        #expect(stats.accepted == 2 && stats.statusLinesAccepted == 1)
    }

    @Test func finishEndsTheReportStreamAfterTheBufferedReports() async throws {
        // No Collector here: the stream has a single consumer, this loop.
        let server = HookServer(configuration: .init(port: 0, token: testToken))
        let port = try await server.start()
        #expect(try exchange(port: port, statusLineRequest(port: port, body: report("default", five: 1))) == 204)
        #expect(try exchange(port: port, statusLineRequest(port: port, body: report("cswap-1", five: 2))) == 204)
        #expect(await eventually { await server.statistics().statusLinesAccepted == 2 })
        await server.finish()
        var keys: [String] = []
        for await r in server.statusLines { keys.append(r.configKey) }
        #expect(keys == ["default", "cswap-1"])
    }
}
