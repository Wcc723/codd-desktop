import Foundation
import Testing
@testable import CoddMCP

@Suite("Events, instructions and concurrency")
struct EventsConcurrencyTests {
    @Test func eventsComeInOrder() async throws {
        let server = Fixture.server()
        let external = MCPCaller.external
        _ = await server.post(NegotiationTests.probe, version: nil)
        _ = await server.post(Wire.rpc("initialize", params: #"{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code","version":"2.1.302"}}"#), version: nil)
        _ = await server.post(Wire.notification("notifications/initialized"))
        _ = await server.post(Wire.rpc("tools/list"))
        _ = await server.post(Wire.call("notes_search", #"{"query":"打卡"}"#))
        _ = await server.post(Wire.rpc("resources/read", params: #"{"uri":"codd://note/rwd-punch-k7x2"}"#), caller: external)
        _ = await server.post(Wire.rpc("initialize", params: #"{"protocolVersion":"2025-11-25"}"#), caller: external)
        _ = await server.post("{")  // parse errors emit nothing
        let events = await collect(server.events, count: 11)
        let now = Fixture.now
        let caller = Fixture.caller
        #expect(events.count == 11)
        guard events.count == 11 else { return }
        #expect(events[0] == .request(caller: caller, method: "server/discover", at: now))
        #expect(events[1] == .request(caller: caller, method: "initialize", at: now))
        #expect(events[2] == .initialized(caller: caller, clientName: "claude-code", clientVersion: "2.1.302",
                                          protocolVersion: "2025-06-18", at: now))
        #expect(events[3] == .request(caller: caller, method: "notifications/initialized", at: now))
        #expect(events[4] == .request(caller: caller, method: "tools/list", at: now))
        #expect(events[5] == .request(caller: caller, method: "tools/call", at: now))
        guard case .tool(caller, "notes_search", .ok, let ms, now) = events[6] else {
            Issue.record("tool event \(events[6])")
            return
        }
        #expect(ms >= 0 && ms < 10_000)
        #expect(events[7] == .request(caller: external, method: "resources/read", at: now))
        #expect(events[8] == .resource(caller: external, uri: "codd://note/rwd-punch-k7x2", ok: true, at: now))
        #expect(events[9] == .request(caller: external, method: "initialize", at: now))
        #expect(events[10] == .initialized(caller: external, clientName: nil, clientVersion: nil,
                                           protocolVersion: "2025-11-25", at: now))
    }

    @Test func eventBufferKeepsTheNewest512() async throws {
        let server = Fixture.server()
        for i in 0..<600 { _ = await server.post(Wire.rpc("ping", id: i)) }
        _ = await server.post(Wire.rpc("tools/list"))
        let events = await collect(server.events, count: 512)
        #expect(events.count == 512)
        #expect(events.last == .request(caller: Fixture.caller, method: "tools/list", at: Fixture.now))
    }

    @Test func instructionsFitClaudesLimit() {
        let text = MCPInstructions.notes
        #expect(text.count <= 4096)
        #expect(text.utf16.count <= 4096)
        #expect(MCPServerInfo(version: "1").instructions == text)
        for needle in ["codd://note/<id>", "[[note:<id>]]", "notes_read", "notes_search", "notes_list", "notes_append",
                       "<codd-note", "ORIGINAL image pixels", "APPEND", "Never guess"] {
            #expect(text.contains(needle), "\(needle)")
        }
        // English, apart from naming the notes' language.
        let nonASCII = text.unicodeScalars.filter { !$0.isASCII }.map(String.init).joined()
        #expect(nonASCII == "繁體中文")
        print("MCP-NUMBERS instructions: \(text.count) characters")
    }

    @Test func hundredConcurrentRequests() async throws {
        var canned = FakeBackend.Canned()
        canned.echoQuery = true
        let backend = FakeBackend(canned)
        let server = Fixture.server(backend)
        let clock = ContinuousClock()
        let start = clock.now
        let mismatches = await withTaskGroup(of: Int.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let query = "查詢\(i)"
                    let response = await server.post(Wire.call("notes_search", #"{"query":"\#(query)"}"#, id: i))
                    guard response.status == 200, let reply = try? JSONParser.parse(response.body),
                          reply["id"]?.int == i,
                          reply["result"]?["structuredContent"]?["results"]?[0]?["title"]?.string == query
                    else { return 1 }
                    return 0
                }
            }
            return await group.reduce(0, +)
        }
        #expect(mismatches == 0)
        #expect(backend.calls.count == 100)
        print("MCP-NUMBERS 100 concurrent notes_search: \(clock.now - start)")
    }

    @Test func serverIsSendableAcrossTasks() async {
        let server = Fixture.server()
        let task = Task.detached { await server.post(Wire.rpc("ping")).status }
        #expect(await task.value == 200)
    }
}
