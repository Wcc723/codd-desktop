import Foundation
import Testing
@testable import CoddMCP

/// `notes_create` (user feedback 2026-10-19): the server validates and normalizes, the backend is
/// called once with a clean request (or never), the model gets the new ref and the file, and the
/// app hears about it through `MCPEvent.created`.
@Suite("notes_create")
struct CreateToolTests {
    func call(_ arguments: String, caller: MCPCaller = Fixture.caller) async throws
        -> (result: JSON, request: MCPCreateRequest?, backend: FakeBackend)
    {
        let backend = FakeBackend()
        let result = try await Fixture.server(backend).tool("notes_create", arguments, caller: caller)
        #expect(backend.calls.count <= 1)
        guard case .create(let request, let seen)? = backend.calls.first else { return (result, nil, backend) }
        #expect(seen == caller)
        return (result, request, backend)
    }

    func refusal(_ arguments: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        let (result, request, _) = try await call(arguments)
        #expect(request == nil, "backend called for \(arguments)", sourceLocation: sourceLocation)
        #expect(result.isErrorResult, "not an error: \(arguments)", sourceLocation: sourceLocation)
        let text = result.texts.first ?? ""
        #expect(text.hasPrefix("Invalid arguments: "), sourceLocation: sourceLocation)
        return text
    }

    @Test func plainCreateReachesTheBackendWithDefaults() async throws {
        let (result, request, _) = try await call(####"{"title":"打卡頁 RWD 檢查報告","body":"## 結論\n- 375 寬會跑版"}"####)
        #expect(request == MCPCreateRequest(title: "打卡頁 RWD 檢查報告", body: "## 結論\n- 375 寬會跑版", tags: [], kind: "note"))
        #expect(!result.isErrorResult)
        #expect(result.texts == ["""
            已建立筆記 codd://note/ai-report-x7k2「打卡頁 RWD 檢查報告」（INBOX · AI APPEND）
            file: /tmp/codd-test/notes/2026-10-17-打卡頁 RWD 檢查報告.md
            之後可以用 notes_append 附加內容到這則筆記。
            """])
        #expect(result["structuredContent"] == nil)
    }

    @Test func titleIsOneTrimmedLineWithoutAHeadingMarker() async throws {
        #expect(try await call(####"{"title":"  # 每週回顧 \n 10/19 ","body":"x"}"####).request?.title == "每週回顧 10/19")
        #expect(try await call(####"{"title":"### Plan","body":"x"}"####).request?.title == "Plan")
        #expect(try await call(####"{"title":"#12 修正","body":"x"}"####).request?.title == "#12 修正", "a # that is not a heading marker stays")
        _ = try await refusal(####"{"body":"x"}"####)
        _ = try await refusal(####"{"title":"   ","body":"x"}"####)
        _ = try await refusal(####"{"title":"# ","body":"x"}"####)
        _ = try await refusal(####"{"title":42,"body":"x"}"####)
        let long = String(repeating: "長", count: 201)
        #expect(try await refusal("{\"title\":\"\(long)\",\"body\":\"x\"}").contains("200"))
        #expect(try await call("{\"title\":\"\(String(long.dropFirst()))\",\"body\":\"x\"}").request?.title.count == 200)
    }

    @Test func bodyIsRequiredAndAtMostAHundredThousandCharacters() async throws {
        _ = try await refusal(####"{"title":"t"}"####)
        _ = try await refusal(####"{"title":"t","body":" \n\t "}"####)
        _ = try await refusal(####"{"title":"t","body":["x"]}"####)
        #expect(MCPLimits.createMaxBodyCharacters == 100_000)
        // The limit counts characters like notes_append / notes_write: CJK counts one each.
        let exact = String(repeating: "字", count: MCPLimits.createMaxBodyCharacters)
        #expect(try await call("{\"title\":\"t\",\"body\":\"\(exact)\"}").request?.body.count == 100_000)
        let over = try await refusal("{\"title\":\"t\",\"body\":\"\(exact)a\"}")
        #expect(over.contains("100001 characters") && over.contains("notes_append"))
        // The largest body, even as `\uXXXX` escapes (6 bytes a character) inside the JSON-RPC
        // envelope, stays under the hook server's 1 MiB request cap: the tool's own refusal above
        // always answers, never a bare HTTP 413 (CoddHooks `HTTPRequestParser.Limits`).
        #expect(MCPLimits.createMaxBodyCharacters * 6 + 64 * 1024 < 1 << 20)
    }

    @Test func tagsAreCleanedLikeTheTagEditor() async throws {
        let request = try await call(####"{"title":"t","body":"x","tags":[" #rwd ","RWD","two words","##ui#","", " ","café"]}"####).request
        #expect(request?.tags == ["rwd", "two-words", "ui", "café"])
        #expect(try await call(####"{"title":"t","body":"x","tags":"#solo"}"####).request?.tags == ["solo"], "a single string is one tag")
        #expect(try await call(####"{"title":"t","body":"x","tags":null}"####).request?.tags == [])
        _ = try await refusal(####"{"title":"t","body":"x","tags":[1]}"####)
        let tooMany = (1...21).map { "\"t\($0)\"" }.joined(separator: ",")
        #expect(try await refusal("{\"title\":\"t\",\"body\":\"x\",\"tags\":[\(tooMany)]}").contains("20"))
        let twenty = (1...20).map { "\"t\($0)\"" }.joined(separator: ",")
        #expect(try await call("{\"title\":\"t\",\"body\":\"x\",\"tags\":[\(twenty),\"T1\"]}").request?.tags.count == 20,
                "duplicates do not count")
        _ = try await refusal("{\"title\":\"t\",\"body\":\"x\",\"tags\":[\"\(String(repeating: "x", count: 65))\"]}")
    }

    @Test func kindIsNoteOrPrompt() async throws {
        #expect(try await call(####"{"title":"t","body":"x","kind":"PROMPT"}"####).request?.kind == "prompt")
        #expect(try await call(####"{"title":"t","body":"x","kind":" note "}"####).request?.kind == "note")
        #expect(try await call(####"{"title":"t","body":"x","kind":""}"####).request?.kind == "note")
        #expect(try await refusal(####"{"title":"t","body":"x","kind":"scratch"}"####).contains("\"note\" or \"prompt\""))
        _ = try await refusal(####"{"title":"t","body":"x","kind":"report"}"####)
    }

    @Test func listedAndCallableWhetherOrNotWritingIsAllowed() async throws {
        for writeEnabled in [false, true] {
            var canned = FakeBackend.Canned()
            canned.writeEnabled = writeEnabled
            let backend = FakeBackend(canned)
            let server = Fixture.server(backend)
            let names = try await server.reply(Wire.rpc("tools/list"))["result"]?["tools"]?.array?.compactMap { $0["name"]?.string }
            #expect(names?.contains("notes_create") == true)
            let result = try await server.tool("notes_create", ####"{"title":"t","body":"x"}"####)
            #expect(!result.isErrorResult)
            #expect(backend.calls.count == 1)
        }
    }

    @Test func backendRefusalsReachTheModel() async throws {
        let backend = FakeBackend(.failing(MCPBackendError.accessDenied("濃縮工作只能讀取筆記")))
        let result = try await Fixture.server(backend).tool("notes_create", ####"{"title":"t","body":"x"}"####)
        #expect(result.isErrorResult && result.texts == ["濃縮工作只能讀取筆記"])
        let unavailable = FakeBackend(.failing(MCPBackendError.unavailable("筆記本尚未開啟")))
        let text = try await Fixture.server(unavailable).tool("notes_create", ####"{"title":"t","body":"x"}"####).texts
        #expect(text == ["CODD 筆記本目前無法使用：筆記本尚未開啟"])
    }

    @Test func aSuccessfulCreateEmitsCreatedBeforeItsToolEvent() async throws {
        let server = Fixture.server()
        _ = await server.post(Wire.call("notes_create", ####"{"title":"每週回顧","body":"x"}"####))
        _ = await server.post(Wire.call("notes_create", ####"{"title":" ","body":"x"}"####))  // refused: no `created`
        let events = await collect(server.events, count: 5)
        #expect(events.count == 5)
        guard events.count == 5 else { return }
        #expect(events[0] == .request(caller: Fixture.caller, method: "tools/call", at: Fixture.now))
        #expect(events[1] == .created(caller: Fixture.caller, id: "ai-report-x7k2", uri: "codd://note/ai-report-x7k2",
                                      title: "每週回顧", at: Fixture.now))
        guard case .tool(Fixture.caller, "notes_create", .ok, _, _) = events[2] else {
            Issue.record("tool event \(events[2])")
            return
        }
        #expect(events[3] == .request(caller: Fixture.caller, method: "tools/call", at: Fixture.now))
        guard case .tool(_, "notes_create", .isError, _, _) = events[4] else {
            Issue.record("refused tool event \(events[4])")
            return
        }
    }

    @Test func instructionsMentionCreate() {
        for needle in ["notes_create", "INBOX", "instead of writing a Markdown file into the project"] {
            #expect(MCPInstructions.notes.contains(needle), "\(needle)")
        }
    }
}
