import Foundation
import Testing
@testable import CoddMCP

@Suite("Version negotiation")
struct NegotiationTests {
    /// Claude Code's 2026-07-28 probe (shape read from the 2.1.302 bundle).
    static let probe = #"{"jsonrpc":"2.0","id":"server-discover-probe-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#

    @Test func serverDiscoverIsMethodNotFoundWithHTTP200() async throws {
        let server = Fixture.server()
        for version in [nil, "2026-07-28", "2025-11-25", "garbage"] as [String?] {
            let response = await server.post(Self.probe, version: version)
            #expect(response.status == 200, "header \(version ?? "none")")
            #expect(response.contentType == "application/json")
            let reply = try JSONParser.parse(response.body)
            #expect(reply["id"] == .string("server-discover-probe-1"))
            #expect(reply["error"]?["code"]?.int == -32601)
            #expect(reply["result"] == nil)
        }
    }

    @Test func initializeEchoesASupportedVersion() async throws {
        let server = Fixture.server()
        for version in MCPServer.supportedProtocolVersions {
            let reply = try await server.reply(
                Wire.rpc("initialize", params: #"{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.302"}}"#),
                version: nil)
            #expect(reply["result"]?["protocolVersion"] == .string(version))
        }
    }

    @Test func initializeAnswersLatestForAnUnknownVersion() async throws {
        let server = Fixture.server()
        for requested in ["2026-07-28", "2024-11-05", "1999-01-01", ""] {
            let reply = try await server.reply(
                Wire.rpc("initialize", params: #"{"protocolVersion":"\#(requested)","capabilities":{}}"#), version: nil)
            #expect(reply["result"]?["protocolVersion"] == "2025-11-25", "requested \(requested)")
        }
        // No params at all: still answered (lenient), with the latest version.
        let bare = try await server.reply(Wire.rpc("initialize"), version: nil)
        #expect(bare["result"]?["protocolVersion"] == "2025-11-25")
        // A protocolVersion of the wrong type is bad params.
        let wrong = try await server.reply(Wire.rpc("initialize", params: #"{"protocolVersion":20251125}"#), version: nil)
        #expect(wrong["error"]?["code"]?.int == -32602)
    }

    @Test func initializeIgnoresAnUnknownVersionHeader() async throws {
        let server = Fixture.server()
        let reply = try await server.reply(
            Wire.rpc("initialize", params: #"{"protocolVersion":"2025-11-25","capabilities":{}}"#), version: "2026-07-28")
        #expect(reply["result"]?["protocolVersion"] == "2025-11-25")
        #expect(reply["result"]?["serverInfo"]?["name"] == "codd")
    }

    @Test func handshakeNotificationIsNeverBlockedByTheHeader() async throws {
        let server = Fixture.server()
        let response = await server.post(Wire.notification("notifications/initialized"), version: "2026-07-28")
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test func badHeaderOnOtherMethodsIs400() async throws {
        let server = Fixture.server()
        for body in [Wire.rpc("tools/list", id: 7), Wire.rpc("ping", id: 7), Wire.call("notes_search", #"{"query":"打卡"}"#, id: 7)] {
            let response = await server.post(body, version: "2026-07-28")
            #expect(response.status == 400)
            #expect(response.contentType == "application/json")
            let reply = try JSONParser.parse(response.body)
            #expect(reply["id"]?.int == 7)
            #expect(reply["error"]?["code"]?.int == -32600)
            let message = try #require(reply["error"]?["message"]?.string)
            for version in MCPServer.supportedProtocolVersions { #expect(message.contains(version)) }
        }
        // A notification other than notifications/initialized is refused too.
        #expect(await server.post(Wire.notification("notifications/cancelled"), version: "2026-07-28").status == 400)
        // So is a batch holding any such message.
        let batch = "[\(Wire.rpc("initialize", id: 1)),\(Wire.rpc("tools/list", id: 2))]"
        #expect(await server.post(batch, version: "2026-07-28").status == 400)
        // The backend was never asked anything.
        let backend = FakeBackend()
        _ = await Fixture.server(backend).post(Wire.call("notes_search", #"{"query":"打卡"}"#), version: "2026-07-28")
        #expect(backend.calls.isEmpty)
    }

    @Test func negotiatedVersionDefaultsTo20250326WithoutHeader() async throws {
        let server = Fixture.server()
        let legacy = try await server.reply(Wire.rpc("tools/list"), version: nil)
        let tools = try #require(legacy["result"]?["tools"]?.array)
        #expect(tools.allSatisfy { $0["outputSchema"] == nil && $0["title"] == nil })
        let modern = try await server.reply(Wire.rpc("tools/list"), version: "2025-06-18")
        let search = try #require(modern["result"]?["tools"]?[0])
        #expect(search["outputSchema"] != nil)
        #expect(search["title"] == "Search CODD notes")
    }

    @Test func initializeResultShape() async throws {
        let server = Fixture.server(version: "1.2.3")
        let reply = try await server.reply(
            Wire.rpc("initialize", params: #"{"protocolVersion":"2025-06-18"}"#), version: nil)
        let result = try #require(reply["result"]?.object)
        #expect(result.keys == ["protocolVersion", "capabilities", "serverInfo", "instructions"])
        #expect(reply["result"]?["capabilities"] == [
            "tools": ["listChanged": false], "resources": ["listChanged": false], "prompts": ["listChanged": false],
        ])
        #expect(reply["result"]?["serverInfo"] == ["name": "codd", "title": "CODD notes", "version": "1.2.3"])
        #expect(reply["result"]?["instructions"]?.string == MCPInstructions.notes)
    }

    /// The whole fallback path as Claude Code 2.1.302 walks it.
    @Test func claudeLikeHandshake() async throws {
        let backend = FakeBackend()
        let server = Fixture.server(backend)
        let discover = await server.post(Self.probe, version: nil)
        #expect(discover.status == 200)
        let initialize = try await server.reply(
            Wire.rpc("initialize", id: 0, params: #"{"protocolVersion":"2025-11-25","capabilities":{"roots":{}},"clientInfo":{"name":"claude-code","version":"2.1.302"}}"#),
            version: nil)
        let version = try #require(initialize["result"]?["protocolVersion"]?.string)
        #expect(await server.post(Wire.notification("notifications/initialized"), version: version).status == 202)
        let list = try await server.reply(Wire.rpc("tools/list", id: 1), version: version)
        let names = list["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
        #expect(names == ["notes_search", "notes_list", "notes_read", "notes_append", "notes_create"])
        let search = try await server.tool("notes_search", #"{"query":"打卡"}"#, version: version)
        #expect(search["structuredContent"]?["results"]?[0]?["id"] == "rwd-punch-k7x2")
        #expect(!search.isErrorResult)
        for response in [discover] { #expect(!response.headers.contains { $0.name.lowercased() == "mcp-session-id" }) }
    }
}
