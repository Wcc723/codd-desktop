import Foundation
import Testing
@testable import CoddMCP

/// Builds requests the way Claude Code's Streamable HTTP client sends them.
enum Wire {
    static func request(_ json: String, version: String? = nil, caller: MCPCaller = Fixture.caller,
                        method: String = "POST", extraHeaders: [(name: String, value: String)] = []) -> MCPHTTPRequest
    {
        var headers: [(name: String, value: String)] = [
            (name: "Content-Type", value: "application/json"),
            (name: "Accept", value: "application/json, text/event-stream"),
        ]
        if let version { headers.append((name: "MCP-Protocol-Version", value: version)) }
        headers += extraHeaders
        return MCPHTTPRequest(method: method, headers: headers, body: Array(json.utf8), caller: caller)
    }

    static func rpc(_ method: String, id: Int = 1, params: String? = nil) -> String {
        if let params { return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)","params":\#(params)}"# }
        return #"{"jsonrpc":"2.0","id":\#(id),"method":"\#(method)"}"#
    }

    static func notification(_ method: String) -> String {
        #"{"jsonrpc":"2.0","method":"\#(method)"}"#
    }

    /// A tools/call body; `arguments` is JSON text.
    static func call(_ tool: String, _ arguments: String = "{}", id: Int = 1) -> String {
        rpc("tools/call", id: id, params: #"{"name":"\#(tool)","arguments":\#(arguments)}"#)
    }
}

extension MCPServer {
    /// POSTs `json` and returns the response.
    func post(_ json: String, version: String? = "2025-11-25", caller: MCPCaller = Fixture.caller) async
        -> MCPHTTPResponse
    {
        await handle(Wire.request(json, version: version, caller: caller))
    }

    /// POSTs a request and returns its parsed reply (status 200 expected).
    func reply(_ json: String, version: String? = "2025-11-25", caller: MCPCaller = Fixture.caller,
               sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSON
    {
        let response = await post(json, version: version, caller: caller)
        #expect(response.status == 200, "status \(response.status): \(response.bodyText)", sourceLocation: sourceLocation)
        #expect(response.contentType == "application/json", sourceLocation: sourceLocation)
        return try JSONParser.parse(response.body)
    }

    /// The `result` of a tools/call.
    func tool(_ name: String, _ arguments: String = "{}", version: String? = "2025-11-25",
              caller: MCPCaller = Fixture.caller, sourceLocation: SourceLocation = #_sourceLocation) async throws -> JSON
    {
        let reply = try await reply(Wire.call(name, arguments), version: version, caller: caller,
                                    sourceLocation: sourceLocation)
        return try #require(reply["result"], "no result: \(JSONWriter.pretty(reply))", sourceLocation: sourceLocation)
    }
}

extension JSON {
    /// The text of every text block of a tool result.
    var texts: [String] { (self["content"]?.array ?? []).compactMap { $0["type"] == "text" ? $0["text"]?.string : nil } }
    var isErrorResult: Bool { self["isError"] == .bool(true) }
}

extension FakeBackend.Canned {
    static func failing(_ error: any Error & Sendable) -> FakeBackend.Canned {
        var canned = FakeBackend.Canned()
        canned.failure = error
        return canned
    }
}

/// Collects `count` events (or fewer when the stream ends).
func collect(_ events: AsyncStream<MCPEvent>, count: Int) async -> [MCPEvent] {
    var out: [MCPEvent] = []
    for await event in events {
        out.append(event)
        if out.count == count { break }
    }
    return out
}
