import Foundation
import Testing
@testable import CoddMCP

@Suite("Tool argument validation and clamping")
struct ToolArgumentTests {
    /// Calls `tool` and returns the single backend call it caused (nil when it caused none).
    func call(_ tool: String, _ arguments: String, writeEnabled: Bool = true) async throws
        -> (result: JSON, call: FakeBackend.Call?)
    {
        var canned = FakeBackend.Canned()
        canned.writeEnabled = writeEnabled
        let backend = FakeBackend(canned)
        let result = try await Fixture.server(backend).tool(tool, arguments)
        #expect(backend.calls.count <= 1)
        return (result, backend.calls.first)
    }

    func read(_ arguments: String) async throws -> MCPReadRequest? {
        guard case .read(let r, _)? = try await call("notes_read", arguments).call else { return nil }
        return r
    }

    func search(_ arguments: String) async throws -> MCPSearchRequest? {
        guard case .search(let r, _)? = try await call("notes_search", arguments).call else { return nil }
        return r
    }

    func list(_ arguments: String) async throws -> MCPListRequest? {
        guard case .list(let r, _)? = try await call("notes_list", arguments).call else { return nil }
        return r
    }

    func refusal(_ tool: String, _ arguments: String, sourceLocation: SourceLocation = #_sourceLocation) async throws
        -> String
    {
        let (result, backendCall) = try await call(tool, arguments)
        #expect(backendCall == nil, "backend called for \(arguments)", sourceLocation: sourceLocation)
        #expect(result.isErrorResult, "not an error: \(arguments)", sourceLocation: sourceLocation)
        let text = result.texts.first ?? ""
        #expect(text.hasPrefix("Invalid arguments: "), sourceLocation: sourceLocation)
        return text
    }

    @Test func readMaxCharsIsClampedWithDefault() async throws {
        #expect(try await read(#"{"ref":"rwd-punch-k7x2"}"#) == MCPReadRequest(ref: "rwd-punch-k7x2", offset: 0,
                                                                                 maxChars: 12000, includeImages: true))
        #expect(try await read(#"{"ref":"x","max_chars":10}"#)?.maxChars == 1000)
        #expect(try await read(#"{"ref":"x","max_chars":999999}"#)?.maxChars == 50000)
        #expect(try await read(#"{"ref":"x","max_chars":1e30}"#)?.maxChars == 50000)
        #expect(try await read(#"{"ref":"x","max_chars":-5}"#)?.maxChars == 1000)
        #expect(try await read(#"{"ref":"x","max_chars":20000}"#)?.maxChars == 20000)
        #expect(try await read(#"{"ref":"x","max_chars":20000.0}"#)?.maxChars == 20000)
        #expect(try await read(#"{"ref":"x","max_chars":"30000"}"#)?.maxChars == 30000)
        #expect(try await read(#"{"ref":"x","max_chars":null}"#)?.maxChars == 12000)
        _ = try await refusal("notes_read", #"{"ref":"x","max_chars":1500.5}"#)
        _ = try await refusal("notes_read", #"{"ref":"x","max_chars":"lots"}"#)
        _ = try await refusal("notes_read", #"{"ref":"x","max_chars":true}"#)
    }

    @Test func readOffsetRefAndImages() async throws {
        #expect(try await read(#"{"ref":"x","offset":-3}"#)?.offset == 0)
        #expect(try await read(#"{"ref":"x","offset":12000}"#)?.offset == 12000)
        #expect(try await read(#"{"ref":"  codd://note/rwd-punch-k7x2 \n"}"#)?.ref == "codd://note/rwd-punch-k7x2")
        #expect(try await read(#"{"ref":"[[note:a-b]]","include_images":false}"#)?.includeImages == false)
        #expect(try await read(#"{"ref":"x","include_images":"false"}"#)?.includeImages == false)
        #expect(try await read(#"{"ref":"x","unknown":{"deep":[1,2]}}"#)?.ref == "x")
        #expect(try await refusal("notes_read", "{}").contains("\"ref\" is required"))
        _ = try await refusal("notes_read", #"{"ref":"   "}"#)
        _ = try await refusal("notes_read", #"{"ref":42}"#)
        _ = try await refusal("notes_read", #"{"ref":"x","include_images":"maybe"}"#)
        _ = try await refusal("notes_read", "{\"ref\":\"\(String(repeating: "a", count: 501))\"}")
    }

    @Test func searchDefaultsAndScope() async throws {
        let plain = try #require(try await search(#"{"query":"打卡"}"#))
        #expect(plain == MCPSearchRequest(query: "打卡", scope: .all, tags: [], kind: nil, includeArchived: false, limit: 10))
        #expect(try await search(#"{"query":"x","scope":"project"}"#)?.scope == .project)
        #expect(try await search(#"{"query":"x","scope":"ALL"}"#)?.scope == .all)
        #expect(try await search(#"{"query":"x","scope":""}"#)?.scope == .all)
        #expect(try await refusal("notes_search", #"{"query":"x","scope":"everything"}"#).contains("scope"))
        #expect(try await search(#"{"query":"x","limit":0}"#)?.limit == 1)
        #expect(try await search(#"{"query":"x","limit":100}"#)?.limit == 20)
        #expect(try await search(#"{"query":"x","limit":"5"}"#)?.limit == 5)
        #expect(try await search(#"{"query":"x","include_archived":true}"#)?.includeArchived == true)
        #expect(try await search(#"{"query":"  RWD 打卡  "}"#)?.query == "RWD 打卡")
    }

    @Test func searchTagsKindAndQuery() async throws {
        #expect(try await search(##"{"query":"x","tags":["#rwd"," punch ","rwd",""]}"##)?.tags == ["rwd", "punch"])
        #expect(try await search(##"{"query":"x","tags":"#rwd"}"##)?.tags == ["rwd"])
        #expect(try await search(#"{"query":"x","kind":"PROMPT"}"#)?.kind == "prompt")
        #expect(try await search(#"{"query":"","tags":["rwd"]}"#)?.tags == ["rwd"])
        #expect(try await search(#"{"query":"","kind":"scratch"}"#)?.kind == "scratch")
        _ = try await refusal("notes_search", #"{"query":"x","kind":"todo"}"#)
        _ = try await refusal("notes_search", #"{"query":"x","tags":[1]}"#)
        _ = try await refusal("notes_search", "{}")
        _ = try await refusal("notes_search", #"{"query":"   "}"#)
        _ = try await refusal("notes_search", #"{"query":["a"]}"#)
        _ = try await refusal("notes_search", "{\"query\":\"\(String(repeating: "字", count: 1001))\"}")
    }

    @Test func listDefaultsAndValidation() async throws {
        #expect(try await list("{}") == MCPListRequest(limit: 20))
        #expect(try await list(#"{"limit":0}"#)?.limit == 1)
        #expect(try await list(#"{"limit":51}"#)?.limit == 50)
        #expect(try await list(#"{"session":"current"}"#)?.session == "current")
        #expect(try await list(#"{"session":"CURRENT"}"#)?.session == "current")
        #expect(try await list(#"{"session":"7C1E9A04-5B3D-4F0E-9A52-3D6C1B2E8F10"}"#)?.session
            == "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10")
        #expect(try await list(#"{"project":"current"}"#)?.project == "current")
        #expect(try await list(#"{"project":"~/Project/north"}"#)?.project == "~/Project/north")
        #expect(try await list(#"{"project":""}"#)?.project == nil)
        #expect(try await list(#"{"days":0}"#)?.days == 1)
        #expect(try await list(#"{"days":999999}"#)?.days == 3650)
        #expect(try await list(#"{"days":7,"pinned":true,"kind":"prompt","include_archived":true}"#)
            == MCPListRequest(kind: "prompt", pinned: true, days: 7, includeArchived: true, limit: 20))
        _ = try await refusal("notes_list", #"{"session":"mine"}"#)
        _ = try await refusal("notes_list", #"{"pinned":"yes"}"#)
        _ = try await refusal("notes_list", #"{"days":1.5}"#)
    }

    @Test func appendLimitsAndHeading() async throws {
        let ok = String(repeating: "字", count: 20_000)
        guard case .append(let r, _)? = try await call("notes_append", "{\"ref\":\"x\",\"markdown\":\"\(ok)\"}").call else {
            Issue.record("append not called")
            return
        }
        #expect(r.markdown.count == 20_000 && r.heading == nil)
        let tooLong = try await refusal("notes_append", "{\"ref\":\"x\",\"markdown\":\"\(ok)a\"}")
        #expect(tooLong.contains("20001") && tooLong.contains("20000"))
        _ = try await refusal("notes_append", #"{"ref":"x","markdown":"  \n "}"#)
        _ = try await refusal("notes_append", #"{"ref":"x"}"#)
        _ = try await refusal("notes_append", #"{"markdown":"hi"}"#)
        guard case .append(let h, _)? = try await call(
            "notes_append", #"{"ref":"x","markdown":"- [x] 修好","heading":"  Fix\nresult：修正\n結果  "}"#).call
        else {
            Issue.record("append not called")
            return
        }
        #expect(h.heading == "Fix result：修正結果")
        #expect(h.markdown == "- [x] 修好")
        guard case .append(let e, _)? = try await call("notes_append", #"{"ref":"x","markdown":"a","heading":" "}"#).call
        else { return }
        #expect(e.heading == nil)
    }

    @Test func writeIsRefusedWhileDisabled() async throws {
        let (result, refusedCall) = try await call("notes_write", #"{"ref":"x","markdown":"new body"}"#, writeEnabled: false)
        #expect(refusedCall == nil)
        #expect(result.isErrorResult)
        #expect(result.texts.first?.contains("AI 可寫入") == true)
        let (enabled, writeCall) = try await call("notes_write", #"{"ref":"x","markdown":"new body"}"#)
        #expect(!enabled.isErrorResult)
        #expect(writeCall == .write(MCPWriteRequest(ref: "x", markdown: "new body"), Fixture.caller))
        #expect(enabled.texts == ["已改寫 codd://note/ai-append-note"])
        let long = String(repeating: "a", count: 50_001)
        _ = try await refusal("notes_write", "{\"ref\":\"x\",\"markdown\":\"\(long)\"}")
    }

    @Test func toolsCallParamsErrorsAreJSONRPC() async throws {
        let server = Fixture.server()
        for params in [#"{"arguments":{}}"#, #"{"name":5}"#, #"{"name":"notes_read","arguments":[1]}"#,
                       #"{"name":"notes_delete","arguments":{}}"#] {
            let reply = try await server.reply(Wire.rpc("tools/call", params: params))
            #expect(reply["error"]?["code"]?.int == -32602, "\(params)")
            #expect(reply["result"] == nil)
        }
        // Missing arguments count as {}.
        let reply = try await server.reply(Wire.rpc("tools/call", params: #"{"name":"notes_list"}"#))
        #expect(reply["result"]?.isErrorResult == false)
    }

    @Test func callerReachesTheBackend() async throws {
        let backend = FakeBackend()
        let server = Fixture.server(backend)
        _ = try await server.tool("notes_list", "{}", caller: .external)
        _ = try await server.tool("notes_list", "{}", caller: Fixture.caller)
        #expect(backend.calls == [.list(MCPListRequest(), .external), .list(MCPListRequest(), Fixture.caller)])
    }
}
