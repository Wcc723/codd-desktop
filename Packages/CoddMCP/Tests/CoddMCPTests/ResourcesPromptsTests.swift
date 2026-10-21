import Foundation
import Testing
@testable import CoddMCP

@Suite("Resources and prompts")
struct ResourcesPromptsTests {
    @Test func listResources() async throws {
        var canned = FakeBackend.Canned()
        canned.resources = [Fixture.resource, MCPResourceEntry(uri: "codd://note/global-note", name: "全域筆記")]
        let reply = try await Fixture.server(FakeBackend(canned)).reply(Wire.rpc("resources/list"))
        #expect(reply["result"] == ["resources": [
            ["uri": "codd://note/rwd-punch-k7x2", "name": "打卡頁 RWD 跑版紀錄", "mimeType": "text/markdown",
             "annotations": ["lastModified": "2026-10-15T10:05:44+08:00"]],
            ["uri": "codd://note/global-note", "name": "全域筆記", "mimeType": "text/markdown"],
        ]])
    }

    @Test func listIsCappedAt200() async throws {
        var canned = FakeBackend.Canned()
        canned.resources = (0..<250).map { MCPResourceEntry(uri: "codd://note/n\($0)", name: "n\($0)") }
        let reply = try await Fixture.server(FakeBackend(canned)).reply(Wire.rpc("resources/list"))
        #expect(reply["result"]?["resources"]?.array?.count == 200)
        #expect(reply["result"]?["resources"]?[199]?["uri"] == "codd://note/n199")
    }

    @Test func templates() async throws {
        let reply = try await Fixture.server().reply(Wire.rpc("resources/templates/list"))
        let templates = try #require(reply["result"]?["resourceTemplates"]?.array)
        #expect(templates.count == 1)
        #expect(templates[0]["uriTemplate"] == "codd://note/{id}")
        #expect(templates[0]["mimeType"] == "text/markdown")
        #expect(templates[0]["name"] == "note")
    }

    @Test func readResource() async throws {
        let backend = FakeBackend()
        let server = Fixture.server(backend)
        let reply = try await server.reply(Wire.rpc("resources/read", params: #"{"uri":"codd://note/rwd-punch-k7x2"}"#))
        #expect(reply["result"] == ["contents": [
            ["uri": "codd://note/rwd-punch-k7x2", "mimeType": "text/markdown", "text": .string(Fixture.noteText)],
        ]])
        #expect(backend.calls == [.readResource("codd://note/rwd-punch-k7x2", Fixture.caller)])
        let events = await collect(server.events, count: 2)
        #expect(events.last == .resource(caller: Fixture.caller, uri: "codd://note/rwd-punch-k7x2", ok: true, at: Fixture.now))
    }

    @Test func readResourceErrorsCarryTheState() async throws {
        let uri = "codd://note/old-a1b2"
        let expectations: [(MCPBackendError, JSON, String)] = [
            (.trashed(id: "old-a1b2", purgeAt: ErrorMappingTests.purgeAt),
             ["state": "trashed", "purgeAt": "2026-11-14T09:30:00+08:00"], "這則筆記在 CODD 垃圾桶（2026-11-14 永久刪除），請使用者先還原"),
            (.trashed(id: "old-a1b2", purgeAt: nil), ["state": "trashed"], "這則筆記在 CODD 垃圾桶，請使用者先還原"),
            (.purged(id: "old-a1b2"), ["state": "purged"], "這則筆記已永久刪除"),
            (.notFound(uri), ["state": "unknown"], "找不到筆記 \(uri)"),
            // OFF / out of scope look exactly like a missing note.
            (.accessDenied("AI 存取為 OFF"), ["state": "unknown"], "找不到筆記 \(uri)"),
            (.invalid("bad uri"), ["state": "unknown"], "找不到筆記 \(uri)"),
        ]
        for (error, data, message) in expectations {
            let server = Fixture.server(FakeBackend(.failing(error)))
            let reply = try await server.reply(Wire.rpc("resources/read", id: 3, params: #"{"uri":"\#(uri)"}"#))
            #expect(reply["id"]?.int == 3)
            #expect(reply["error"] == ["code": -32602, "message": .string(message), "data": data], "\(error)")
            let events = await collect(server.events, count: 2)
            #expect(events.last == .resource(caller: Fixture.caller, uri: uri, ok: false, at: Fixture.now))
        }
        for error in [MCPBackendError.unavailable("索引重建中"), .tooLarge("太大")] {
            let reply = try await Fixture.server(FakeBackend(.failing(error))).reply(
                Wire.rpc("resources/read", params: #"{"uri":"\#(uri)"}"#))
            #expect(reply["error"]?["code"]?.int == -32603)
            #expect(reply["error"]?["message"]?.string == error.message(timeZone: Fixture.timeZone))
        }
        let other = try await Fixture.server(FakeBackend(.failing(Boom()))).reply(
            Wire.rpc("resources/read", params: #"{"uri":"\#(uri)"}"#))
        #expect(other["error"] == ["code": -32603, "message": "Internal error"])
    }

    @Test func readResourceNeedsAURI() async throws {
        let backend = FakeBackend()
        let server = Fixture.server(backend)
        for params in ["{}", #"{"uri":5}"#, #"{"uri":""}"#] {
            let reply = try await server.reply(Wire.rpc("resources/read", params: params))
            #expect(reply["error"]?["code"]?.int == -32602)
        }
        #expect(backend.calls.isEmpty)
    }

    @Test func listResourcesFailure() async throws {
        let reply = try await Fixture.server(FakeBackend(.failing(MCPBackendError.unavailable("x")))).reply(
            Wire.rpc("resources/list"))
        #expect(reply["error"]?["code"]?.int == -32603)
    }

    @Test func promptsList() async throws {
        let reply = try await Fixture.server().reply(Wire.rpc("prompts/list"))
        let prompts = try #require(reply["result"]?["prompts"]?.array)
        #expect(prompts.count == 1)
        #expect(prompts[0]["name"] == "note")
        #expect(prompts[0]["arguments"]?[0]?["name"] == "id")
        #expect(prompts[0]["arguments"]?[0]?["required"] == true)
    }

    @Test func promptsGet() async throws {
        let backend = FakeBackend()
        let reply = try await Fixture.server(backend).reply(
            Wire.rpc("prompts/get", params: #"{"name":"note","arguments":{"id":" rwd-punch-k7x2 "}}"#))
        #expect(reply["result"]?["messages"] == [
            ["role": "user", "content": ["type": "text", "text": .string(Fixture.noteText)]],
        ])
        #expect(reply["result"]?["description"] == "CODD note rwd-punch-k7x2")
        #expect(backend.calls == [.prompt("rwd-punch-k7x2", Fixture.caller)])
    }

    @Test func promptsGetErrors() async throws {
        let backend = FakeBackend()
        let server = Fixture.server(backend)
        for params in [#"{"name":"note"}"#, #"{"name":"note","arguments":{"id":""}}"#, #"{"name":"note","arguments":{"id":3}}"#,
                       #"{"name":"inbox","arguments":{"id":"x"}}"#, #"{"arguments":{"id":"x"}}"#,
                       #"{"name":"note","arguments":"x"}"#] {
            let reply = try await server.reply(Wire.rpc("prompts/get", params: params))
            #expect(reply["error"]?["code"]?.int == -32602, "\(params)")
        }
        #expect(backend.calls.isEmpty)
        let purged = try await Fixture.server(FakeBackend(.failing(MCPBackendError.purged(id: "x")))).reply(
            Wire.rpc("prompts/get", params: #"{"name":"note","arguments":{"id":"x"}}"#))
        #expect(purged["error"] == ["code": -32602, "message": "這則筆記已永久刪除", "data": ["state": "purged"]])
    }
}
