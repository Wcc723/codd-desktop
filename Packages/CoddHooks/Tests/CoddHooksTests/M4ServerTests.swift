import CoddCore
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoddHooks

/// A response read off the wire.
struct WireResponse {
    var status: Int?
    var headers: [(String, String)]
    var body: [UInt8]

    init(_ bytes: [UInt8]) {
        status = RawClient.status(bytes)
        let marker: [UInt8] = [13, 10, 13, 10]
        var split = bytes.count
        if bytes.count >= 4 {
            for i in 0...(bytes.count - 4) where Array(bytes[i..<(i + 4)]) == marker {
                split = i
                break
            }
        }
        let head = String(decoding: bytes[..<split], as: UTF8.self)
        headers = head.components(separatedBy: "\r\n").dropFirst().compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        body = split + 4 <= bytes.count ? Array(bytes[(split + 4)...]) : []
    }

    func header(_ name: String) -> String? {
        headers.first { $0.0.lowercased() == name.lowercased() }?.1
    }

    var text: String { String(decoding: body, as: UTF8.self) }
}

func send(port: UInt16, _ request: String, halfClose: Bool = false, receiveTimeout: TimeInterval = 5) throws -> WireResponse {
    let client = try RawClient(port: port, receiveTimeout: receiveTimeout)
    defer { client.close() }
    client.send(request)
    if halfClose { client.shutdownWrite() }
    return WireResponse(client.readAll())
}

func mcpRequest(port: UInt16, headers: [String], body: String = #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                method: String = "POST", target: String = "/mcp") -> String {
    var lines = ["\(method) \(target) HTTP/1.1", "Host: 127.0.0.1:\(port)"] + headers
    if method == "POST" {
        lines.append("Content-Type: application/json")
        lines.append("Content-Length: \(body.utf8.count)")
    }
    return lines.joined(separator: "\r\n") + "\r\n\r\n" + (method == "POST" ? body : "")
}

/// Records what a handler saw (thread-safe).
final class Seen<T: Sendable>: Sendable {
    let items = Mutex<[T]>([])
    func add(_ item: T) { items.withLock { $0.append(item) } }
    var values: [T] { items.withLock { $0 } }
}

@Suite("M4 hook server: /mcp, /hooks/prompt, /n/ (real loopback)")
struct M4ServerTests {
    let sid = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17"
    var uuid: UUID { UUID(uuidString: sid)! }
    var sessionHeaders: [String] {
        ["X-CODD-Session: \(sid)", "X-CODD-Token: \(MCPAuth.sessionToken(hookToken: testToken, sessionID: uuid))"]
    }

    func makeServer(_ configure: (inout HookServer.Configuration) -> Void = { _ in }) async throws -> (HookServer, UInt16) {
        var configuration = HookServer.Configuration(port: 0, token: testToken, mcpToken: testMCPToken)
        configure(&configuration)
        let server = HookServer(configuration: configuration, clock: ManualHookClock(now: referenceNow))
        let port = try await server.start()
        return (server, port)
    }

    // MARK: /mcp

    @Test func mcpHandlerPassThrough() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        let seen = Seen<(MCPRouteCaller, HTTPRouteRequest)>()
        await server.setMCPHandler { caller, request in
            seen.add((caller, request))
            if request.body.contains(UInt8(ascii: "!")) { return .status(202) }
            return HTTPRouteResponse(status: 200, contentType: "application/json",
                                     headers: [(name: "MCP-Protocol-Version", value: "2025-11-25"), (name: "Content-Length", value: "1"),
                                               (name: "X-Bad", value: "a\r\nInjected: 1")],
                                     body: Array(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8))
        }
        let r = try send(port: port, mcpRequest(port: port, headers: sessionHeaders + ["MCP-Protocol-Version: 2025-11-25"],
                                                target: "/mcp?debug=1"))
        #expect(r.status == 200)
        #expect(r.header("Content-Type") == "application/json")
        #expect(r.header("MCP-Protocol-Version") == "2025-11-25")
        #expect(r.header("Content-Length") == "\(r.body.count)") // the handler's copy was dropped
        #expect(r.header("X-Bad") == nil && r.header("Injected") == nil)
        #expect(r.header("Connection") == "close")
        #expect(r.header("WWW-Authenticate") == nil)
        #expect(r.text == #"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#)
        let first = try #require(seen.values.first)
        #expect(first.0 == .session(uuid))
        #expect(first.1.method == "POST" && first.1.path == "/mcp" && first.1.query == ["debug": "1"])
        #expect(first.1.header("mcp-protocol-version") == "2025-11-25")
        #expect(first.1.body == Array(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        // A notification: 202, no body; the external token as Bearer.
        let n = try send(port: port, mcpRequest(port: port, headers: ["Authorization: Bearer \(testMCPToken)"],
                                                body: #"{"jsonrpc":"2.0","method":"notifications/initialized","x":"!"}"#))
        #expect(n.status == 202 && n.body.isEmpty && n.header("Content-Length") == "0")
        #expect(seen.values.last?.0 == .external)
        // An allowed Origin, and the external token as X-CODD-Token.
        let o = try send(port: port, mcpRequest(port: port, headers: ["Origin: http://localhost:\(port)", "X-CODD-Token: \(testMCPToken)"]))
        #expect(o.status == 200)
        let stats = await server.statistics()
        #expect(stats.mcpRequests == 3 && stats.mcpRejected == 0 && stats.lastMCPAt == referenceNow)
        #expect(stats.accepted == 0 && stats.rejected.isEmpty)
    }

    @Test func mcpRefusals() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        let calls = Seen<Int>()
        await server.setMCPHandler { _, _ in
            calls.add(1)
            return .status(200)
        }
        let unauthorized = try send(port: port, mcpRequest(port: port, headers: ["X-CODD-Token: \(testToken)"]))
        #expect(unauthorized.status == 401)
        #expect(unauthorized.header("WWW-Authenticate") == nil)
        #expect(try send(port: port, mcpRequest(port: port, headers: sessionHeaders + ["Origin: http://evil.example"])).status == 403)
        let get = try send(port: port, mcpRequest(port: port, headers: sessionHeaders, method: "GET"))
        #expect(get.status == 405 && get.header("Allow") == "POST")
        let delete = try send(port: port, mcpRequest(port: port, headers: sessionHeaders, method: "DELETE"))
        #expect(delete.status == 405 && delete.header("Allow") == "POST")
        let noLength = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" + sessionHeaders.joined(separator: "\r\n") + "\r\n\r\n"
        #expect(try send(port: port, noLength).status == 411)
        let big = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n" + sessionHeaders.joined(separator: "\r\n")
            + "\r\nContent-Length: \((1 << 20) + 1)\r\n\r\n"
        #expect(try send(port: port, big).status == 413)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls.values.isEmpty)
        let stats = await server.statistics()
        #expect(stats.mcpRequests == 0)
        #expect(stats.mcpRejected == 5) // 401, 403, 405, 405, 411 (the 413 comes from the parser, before routing)
        #expect(stats.rejected == [401: 1, 403: 1, 405: 2, 411: 1, 413: 1])
        #expect(stats.lastRejection?.hasPrefix("413 ") == true)
        _ = try send(port: port, mcpRequest(port: port, headers: ["X-CODD-Token: \(String(repeating: "0", count: 64))"]))
        #expect(await server.statistics().lastRejection == "401 wrong MCP token")
    }

    @Test func noHandlerIsA503WithAJSONRPCError() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        let r = try send(port: port, mcpRequest(port: port, headers: sessionHeaders))
        #expect(r.status == 503)
        #expect(r.header("Content-Type") == "application/json")
        let error = try #require(JSONValue.parse(Data(r.body)))
        #expect(error["jsonrpc"] == "2.0" && error["id"] == .null && error["error"]?["code"] == -32603)
    }

    @Test func aSlowHandlerKeepsItsConnectionPastTheReadTimeouts() async throws {
        let (server, port) = try await makeServer {
            $0.readTimeout = .milliseconds(100)
            $0.headTimeout = .milliseconds(100)
        }
        defer { Task { await server.finish() } }
        await server.setMCPHandler { _, _ in
            try? await Task.sleep(for: .milliseconds(400))
            return .json(Array(#"{"ok":true}"#.utf8))
        }
        let start = Date()
        let r = try send(port: port, mcpRequest(port: port, headers: sessionHeaders))
        #expect(r.status == 200 && r.text == #"{"ok":true}"#)
        #expect(Date().timeIntervalSince(start) >= 0.35)
        #expect(await server.statistics().rejected.isEmpty)
        #expect(await eventually { await server.connectionCount() == 0 })
    }

    @Test func aHandlerPastTheDeadlineIs503() async throws {
        let (server, port) = try await makeServer { $0.handlerDeadline = .milliseconds(150) }
        defer { Task { await server.finish() } }
        await server.setMCPHandler { _, _ in
            try? await Task.sleep(for: .seconds(2))
            return .status(200)
        }
        let start = Date()
        let r = try send(port: port, mcpRequest(port: port, headers: sessionHeaders))
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.status == 503)
        #expect(elapsed >= 0.12 && elapsed < 1.5)
        let error = try #require(JSONValue.parse(Data(r.body)))
        #expect(error["error"]?["code"] == -32001)
        let stats = await server.statistics()
        #expect(stats.mcpTimedOut == 1 && stats.rejected == [503: 1])
        #expect(stats.lastRejection == "503 MCP handler over 150 ms")
    }

    @Test func aClientThatHalfClosesStillGetsTheHandlersAnswer() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        await server.setMCPHandler { _, _ in
            try? await Task.sleep(for: .milliseconds(100))
            return .json(Array(#"{"late":true}"#.utf8))
        }
        let r = try send(port: port, mcpRequest(port: port, headers: sessionHeaders), halfClose: true)
        #expect(r.status == 200 && r.text == #"{"late":true}"#)
        // A client that goes away entirely: the handler finishes, nothing breaks.
        let client = try RawClient(port: port)
        client.send(mcpRequest(port: port, headers: sessionHeaders))
        client.close()
        try await Task.sleep(for: .milliseconds(250))
        #expect(try send(port: port, mcpRequest(port: port, headers: sessionHeaders)).status == 200)
        #expect(await eventually { await server.connectionCount() == 0 })
    }

    @Test func oversizedHandlerAnswersAre500() async throws {
        let (server, port) = try await makeServer { $0.maxResponseBytes = 1024 }
        defer { Task { await server.finish() } }
        await server.setMCPHandler { _, _ in .json([UInt8](repeating: 0x61, count: 2048)) }
        let r = try send(port: port, mcpRequest(port: port, headers: sessionHeaders))
        #expect(r.status == 500 && r.body.isEmpty)
        #expect(await server.statistics().lastRejection == "500 handler response over 1024 bytes")
    }

    @Test func tokenRotationAndHandlersSurviveARestart() async throws {
        let (server, port) = try await makeServer { $0.port = freeNonEphemeralPort(in: TestPorts.restart) }
        defer { Task { await server.finish() } }
        await server.setMCPHandler { caller, _ in .json(Array("\(caller)".utf8)) }
        await server.setNoteURLHandler { id in HTTPRouteResponse(status: 200, contentType: "text/markdown; charset=utf-8", body: Array(id.utf8)) }
        let note = "/n/a1.md?t=\(MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "a1"))"
        #expect(try send(port: port, mcpRequest(port: port, headers: ["X-CODD-Token: \(testMCPToken)"])).status == 200)
        let rotated = String(repeating: "ef", count: 32)
        await server.setMCPToken(rotated)
        #expect(try send(port: port, mcpRequest(port: port, headers: ["X-CODD-Token: \(testMCPToken)"])).status == 401)
        #expect(try send(port: port, mcpRequest(port: port, headers: ["X-CODD-Token: \(rotated)"])).status == 200)
        // Session tokens derive from the hook token: unchanged by the rotation.
        #expect(try send(port: port, mcpRequest(port: port, headers: sessionHeaders)).status == 200)
        // Old note URLs die.
        #expect(try send(port: port, "GET \(note) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n").status == 404)
        // A stop / start keeps the handlers and the rotated token.
        let again = try await server.restart(port: port)
        #expect(again == port)
        let r = try send(port: port, mcpRequest(port: port, headers: ["X-CODD-Token: \(rotated)"]))
        #expect(r.status == 200 && r.text == "external")
        let fresh = "/n/a1.md?t=\(MCPAuth.noteURLToken(mcpToken: rotated, noteID: "a1"))"
        #expect(try send(port: port, "GET \(fresh) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n").text == "a1")
        // nil refuses every external caller.
        await server.setMCPToken(nil)
        #expect(try send(port: port, mcpRequest(port: port, headers: ["X-CODD-Token: \(rotated)"])).status == 401)
        await server.setMCPHandler(nil)
        #expect(try send(port: port, mcpRequest(port: port, headers: sessionHeaders)).status == 503)
    }

    @Test func curlWithABearerToken() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        await server.setMCPHandler { _, request in .json(request.body) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        p.arguments = ["-s", "--noproxy", "*", "-m", "5", "-X", "POST", "-H", "Content-Type: application/json",
                       "-H", "Authorization: Bearer \(testMCPToken)", "--data-binary", #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#,
                       "-w", "\n%{http_code}", "http://127.0.0.1:\(port)/mcp"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"ping\"}\n200")
    }

    // MARK: /hooks/prompt

    func promptRequest(port: UInt16, prompt: String = "看一下 codd://note/rwd-punch-k7x2") -> String {
        let body = String(decoding: try! JSONValue.object(["hook_event_name": "UserPromptSubmit", "session_id": "c1",
                                                           "prompt": .string(prompt)]).jsonData(), as: UTF8.self)
        return hookRequest(port: port, body: body, path: "/hooks/prompt")
    }

    @Test func promptEventIsYieldedBeforeTheHandlerRuns() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        let events = server.events
        // The handler reads the stream itself: it can only answer if the event was already yielded.
        await server.setPromptHandler { sessionID, payload in
            var iterator = events.makeAsyncIterator()
            guard let event = await iterator.next() else { return nil }
            return PromptHookAnswer(additionalContext: "event=\(event.payload.prompt ?? "-") same=\(event.payload == payload) id=\(sessionID == event.sessionID)",
                                    systemMessage: "codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 2 張圖片）")
        }
        let r = try send(port: port, promptRequest(port: port))
        #expect(r.status == 200)
        #expect(r.header("Content-Type") == "application/json")
        let json = try #require(JSONValue.parse(Data(r.body)))
        #expect(json["hookSpecificOutput"]?["hookEventName"] == "UserPromptSubmit")
        #expect(json["hookSpecificOutput"]?["additionalContext"] == "event=看一下 codd://note/rwd-punch-k7x2 same=true id=true")
        #expect(json["systemMessage"] == "codd：已展開 codd://note/rwd-punch-k7x2（打卡頁 RWD 跑版紀錄 · 2 張圖片）")
        let stats = await server.statistics()
        #expect(stats.promptHooks == 1 && stats.promptAnswered == 1 && stats.promptLate == 0 && stats.accepted == 1)
    }

    @Test func promptAnswersWithoutSystemMessageNilAndNoHandler() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        let collected = Collector(server.events)
        // No handler: 204, and the event still arrives.
        let none = try send(port: port, promptRequest(port: port))
        #expect(none.status == 204 && none.body.isEmpty)
        await server.setPromptHandler { _, payload in
            guard let prompt = payload.prompt, prompt.contains("codd://") else { return nil }
            return PromptHookAnswer(additionalContext: "ctx")
        }
        let answered = try send(port: port, promptRequest(port: port))
        #expect(answered.status == 200)
        #expect(answered.text == #"{"hookSpecificOutput":{"additionalContext":"ctx","hookEventName":"UserPromptSubmit"}}"#)
        let plain = try send(port: port, promptRequest(port: port, prompt: "沒有引用"))
        #expect(plain.status == 204)
        #expect(await collected.wait(count: 3))
        #expect(collected.values.map { $0.payload.prompt } == ["看一下 codd://note/rwd-punch-k7x2", "看一下 codd://note/rwd-punch-k7x2", "沒有引用"])
        #expect(collected.values.allSatisfy { $0.sessionID == uuid && $0.receivedAt == referenceNow })
        let stats = await server.statistics()
        #expect(stats.promptHooks == 3 && stats.promptAnswered == 1 && stats.accepted == 3)
        // The /hooks auth applies.
        #expect(try exchange(port: port, hookRequest(port: port, token: testMCPToken, path: "/hooks/prompt")) == 401)
        #expect(try exchange(port: port, hookRequest(port: port, extraHeaders: ["Origin: http://127.0.0.1:\(port)"], path: "/hooks/prompt")) == 403)
        #expect(try exchange(port: port, hookRequest(port: port, method: "GET", path: "/hooks/prompt")) == 405)
        collected.cancel()
    }

    @Test func aLatePromptHandlerGets204() async throws {
        let (server, port) = try await makeServer { $0.promptDeadline = .milliseconds(100) }
        defer { Task { await server.finish() } }
        let collected = Collector(server.events)
        await server.setPromptHandler { _, _ in
            try? await Task.sleep(for: .milliseconds(800))
            return PromptHookAnswer(additionalContext: "too late")
        }
        let start = Date()
        let r = try send(port: port, promptRequest(port: port))
        #expect(r.status == 204)
        #expect(Date().timeIntervalSince(start) < 0.6)
        #expect(await collected.wait(count: 1))
        let stats = await server.statistics()
        #expect(stats.promptLate == 1 && stats.promptAnswered == 0 && stats.rejected.isEmpty)
        collected.cancel()
    }

    @Test func hooksIsStill204BeforeDecodingWithHandlersInstalled() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        let collected = Collector(server.events)
        let called = Seen<Int>()
        await server.setPromptHandler { _, _ in
            called.add(1)
            return PromptHookAnswer(additionalContext: "x")
        }
        let r = try send(port: port, hookRequest(port: port, body: #"{"hook_event_name":"UserPromptSubmit","prompt":"codd://note/a"}"#))
        #expect(r.status == 204 && r.body.isEmpty)
        #expect(await collected.wait(count: 1))
        #expect(called.values.isEmpty)
        #expect(await server.statistics().promptHooks == 0)
        collected.cancel()
    }

    // MARK: /n/

    @Test func noteURLs() async throws {
        let (server, port) = try await makeServer()
        defer { Task { await server.finish() } }
        func get(_ target: String, host: String? = nil, extra: String = "") throws -> WireResponse {
            try send(port: port, "GET \(target) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n\(extra)\r\n")
        }
        func url(_ id: String) -> String { "/n/\(id).md?t=\(MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: id))" }
        // No handler: 404.
        #expect(try get(url("rwd-punch-k7x2")).status == 404)
        let asked = Seen<String>()
        await server.setNoteURLHandler { id in
            asked.add(id)
            switch id {
            case "trashed-note": return HTTPRouteResponse(status: 410, contentType: "text/markdown; charset=utf-8",
                                                          body: Array("這則筆記在 CODD 垃圾桶\n".utf8))
            case "unknown": return .status(404)
            default: return HTTPRouteResponse(status: 200, contentType: "text/markdown; charset=utf-8", body: Array("# 打卡頁 RWD 跑版紀錄\n".utf8))
            }
        }
        let ok = try get(url("rwd-punch-k7x2"))
        #expect(ok.status == 200 && ok.text == "# 打卡頁 RWD 跑版紀錄\n")
        #expect(ok.header("Content-Type") == "text/markdown; charset=utf-8")
        let gone = try get(url("trashed-note"))
        #expect(gone.status == 410 && gone.text == "這則筆記在 CODD 垃圾桶\n")
        #expect(try get(url("unknown")).status == 404)
        // Refused before the handler.
        #expect(try get("/n/rwd-punch-k7x2.md?t=\(MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "other"))").status == 404)
        #expect(try get("/n/rwd-punch-k7x2.md").status == 404)
        #expect(try get(url("rwd-punch-k7x2"), host: "evil.example:\(port)").status == 403)
        #expect(try get(url("rwd-punch-k7x2"), extra: "Origin: http://127.0.0.1:\(port)\r\n").status == 403)
        let post = try send(port: port, "POST \(url("rwd-punch-k7x2")) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 0\r\n\r\n")
        #expect(post.status == 405 && post.header("Allow") == "GET")
        #expect(asked.values == ["rwd-punch-k7x2", "trashed-note", "unknown"])
        let stats = await server.statistics()
        #expect(stats.noteURLRequests == 4) // the first one had no handler yet (404)
        #expect(stats.lastRejection == "405 POST not allowed on /n/rwd-punch-k7x2.md")
        // The token never appears in a rejection.
        _ = try get("/n/rwd-punch-k7x2.md?t=\(String(repeating: "0", count: 24))")
        let last = await server.statistics().lastRejection ?? ""
        #expect(last == "404 note URL token wrong or MCP token not set")
    }

    @Test func aSlowNoteHandlerIs503() async throws {
        let (server, port) = try await makeServer { $0.handlerDeadline = .milliseconds(100) }
        defer { Task { await server.finish() } }
        await server.setNoteURLHandler { _ in
            try? await Task.sleep(for: .seconds(1))
            return .status(200)
        }
        let target = "/n/a.md?t=\(MCPAuth.noteURLToken(mcpToken: testMCPToken, noteID: "a"))"
        #expect(try send(port: port, "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n").status == 503)
        #expect(await server.statistics().lastRejection == "503 note URL handler over 100 ms")
    }
}
