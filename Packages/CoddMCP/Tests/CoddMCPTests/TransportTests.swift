import Foundation
import Testing
@testable import CoddMCP

@Suite("HTTP and JSON-RPC framing")
struct TransportTests {
    @Test func notificationsAndResponsesAre202() async throws {
        let server = Fixture.server()
        for body in [
            Wire.notification("notifications/initialized"),
            Wire.notification("notifications/cancelled"),
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":3,"reason":"user"}}"#,
            Wire.notification("notifications/whatever"),
            #"{"jsonrpc":"2.0","id":5,"result":{}}"#,
            #"{"jsonrpc":"2.0","id":5,"error":{"code":-1,"message":"x"}}"#,
        ] {
            let response = await server.post(body)
            #expect(response.status == 202, "\(body)")
            #expect(response.body.isEmpty)
            #expect(response.contentType == nil)
            #expect(response.headers.isEmpty)
        }
    }

    @Test func batchOfOnlyNotificationsIs202() async throws {
        let server = Fixture.server()
        let batch = "[\(Wire.notification("notifications/initialized")),\(Wire.notification("notifications/cancelled")),{\"jsonrpc\":\"2.0\",\"id\":9,\"result\":{}}]"
        let response = await server.post(batch)
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test func batchWithRequestsAnswersAnArrayInOrder() async throws {
        let server = Fixture.server()
        let batch = "[\(Wire.rpc("ping", id: 1)),\(Wire.notification("notifications/initialized")),\(Wire.rpc("tools/list", id: 2)),\(Wire.rpc("nope/nope", id: 3)),5]"
        let response = await server.post(batch)
        #expect(response.status == 200)
        let replies = try #require(try JSONParser.parse(response.body).array)
        #expect(replies.count == 4)
        #expect(replies[0]["id"]?.int == 1 && replies[0]["result"] == .object(JSONObject()))
        #expect(replies[1]["id"]?.int == 2 && replies[1]["result"]?["tools"] != nil)
        #expect(replies[2]["id"]?.int == 3 && replies[2]["error"]?["code"]?.int == -32601)
        #expect(replies[3]["id"] == .null && replies[3]["error"]?["code"]?.int == -32600)
    }

    @Test func emptyBatchIsInvalid() async throws {
        let response = await Fixture.server().post("[]")
        #expect(response.status == 400)
        let reply = try JSONParser.parse(response.body)
        #expect(reply["error"]?["code"]?.int == -32600)
        #expect(reply["id"] == .null)
    }

    @Test func parseErrorIs400WithNullID() async throws {
        let server = Fixture.server()
        for body in ["", "{", "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"", "not json", "{\"a\":1,}", "\u{FEFF}"] {
            let response = await server.post(body)
            #expect(response.status == 400, "\(body)")
            #expect(response.contentType == "application/json")
            let reply = try JSONParser.parse(response.body)
            #expect(reply["jsonrpc"] == "2.0")
            #expect(reply["id"] == .null)
            #expect(reply["error"]?["code"]?.int == -32700)
        }
        // Invalid UTF-8 inside a string.
        let response = await server.handle(MCPHTTPRequest(
            body: Array(#"{"jsonrpc":"2.0","id":1,"method":""#.utf8) + [0xFF, 0xFE] + Array(#""}"#.utf8),
            caller: Fixture.caller))
        #expect(response.status == 400)
    }

    @Test func invalidSingleMessagesAre400() async throws {
        let server = Fixture.server()
        let cases: [(String, JSON)] = [
            ("5", .null),
            (#"{"id":1,"method":"ping"}"#, 1),
            (#"{"jsonrpc":"1.0","id":"a","method":"ping"}"#, "a"),
            (#"{"jsonrpc":"2.0","id":2,"method":5}"#, 2),
            (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, .null),
            (#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#, .null),
            (#"{"jsonrpc":"2.0","id":3}"#, 3),
        ]
        for (body, id) in cases {
            let response = await server.post(body)
            #expect(response.status == 400, "\(body)")
            let reply = try JSONParser.parse(response.body)
            #expect(reply["error"]?["code"]?.int == -32600, "\(body)")
            #expect(reply["id"] == id, "\(body)")
        }
    }

    @Test func paramsMustBeAnObject() async throws {
        let reply = try await Fixture.server().reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":[1]}"#)
        #expect(reply["error"]?["code"]?.int == -32602)
    }

    @Test func getAndDeleteAre405() async throws {
        let server = Fixture.server()
        for method in ["GET", "DELETE", "PUT", "get"] {
            let response = await server.handle(Wire.request("", method: method))
            #expect(response.status == 405)
            #expect(response.headers.count == 1)
            #expect(response.headers.first?.name == "Allow" && response.headers.first?.value == "POST")
            #expect(response.body.isEmpty)
        }
        #expect(await server.handle(Wire.request(Wire.rpc("ping"), method: "post")).status == 200)
    }

    @Test func pingAndUnknownMethods() async throws {
        let server = Fixture.server()
        let ping = try await server.reply(Wire.rpc("ping", id: 42))
        #expect(ping == ["jsonrpc": "2.0", "id": 42, "result": .object(JSONObject())])
        for method in ["logging/setLevel", "completion/complete", "resources/subscribe", "sampling/createMessage"] {
            let reply = try await server.reply(Wire.rpc(method))
            #expect(reply["error"]?["code"]?.int == -32601, "\(method)")
        }
    }

    @Test func idsAreEchoedExactly() async throws {
        let server = Fixture.server()
        for id in ["0", "-3", "1.50", "1e3", "12345678901234567890", "\"abc\"", "\"打卡\""] {
            let response = await server.post(#"{"jsonrpc":"2.0","id":\#(id),"method":"ping"}"#)
            #expect(response.bodyText == #"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
        }
    }

    @Test func neverSendsASessionID() async throws {
        let server = Fixture.server()
        let bodies = [Wire.rpc("initialize", params: #"{"protocolVersion":"2025-11-25"}"#), Wire.rpc("tools/list"),
                      Wire.notification("notifications/initialized"), Wire.call("notes_search", #"{"query":"x"}"#), "{"]
        for body in bodies {
            let response = await server.post(body)
            #expect(!response.headers.contains { $0.name.lowercased() == "mcp-session-id" })
        }
    }

    @Test func requestHeaderLookupIsCaseInsensitive() {
        let request = MCPHTTPRequest(headers: [(name: "mcp-protocol-version", value: " 2025-06-18 ")], body: [],
                                     caller: .external)
        #expect(request.header("MCP-Protocol-Version") == "2025-06-18")
        #expect(request.header("X-Other") == nil)
    }
}
