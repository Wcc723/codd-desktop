import Foundation
import Testing
@testable import CoddMCP

@Suite("Backend errors")
struct ErrorMappingTests {
    /// 2026-11-14 09:30 +08:00.
    static let purgeAt = Date(timeIntervalSince1970: 1_794_619_800)

    static let cases: [(MCPBackendError, String)] = [
        (.notFound("codd://note/nope-0000"), "找不到筆記 codd://note/nope-0000"),
        (.trashed(id: "old-a1b2", purgeAt: purgeAt), "這則筆記在 CODD 垃圾桶（2026-11-14 永久刪除），請使用者先還原"),
        (.trashed(id: "old-a1b2", purgeAt: nil), "這則筆記在 CODD 垃圾桶，請使用者先還原"),
        (.purged(id: "old-a1b2"), "這則筆記已永久刪除"),
        (.accessDenied("這則筆記的 AI 存取是 READ，不能附加"), "這則筆記的 AI 存取是 READ，不能附加"),
        (.accessDenied(""), "AI 無法存取這則筆記"),
        (.invalid("offset 超過筆記長度"), "offset 超過筆記長度"),
        (.tooLarge("筆記超過 2 MiB"), "筆記超過 2 MiB"),
        (.unavailable("索引重建中"), "CODD 筆記本目前無法使用：索引重建中"),
        (.unavailable(""), "CODD 筆記本目前無法使用"),
    ]

    @Test func everyBackendErrorIsAnIsErrorResult() async throws {
        let tools: [(String, String)] = [
            ("notes_search", #"{"query":"打卡"}"#), ("notes_list", "{}"), ("notes_read", #"{"ref":"x"}"#),
            ("notes_append", #"{"ref":"x","markdown":"y"}"#), ("notes_write", #"{"ref":"x","markdown":"y"}"#),
            ("notes_create", #"{"title":"t","body":"y"}"#),
        ]
        for (error, text) in Self.cases {
            var canned = FakeBackend.Canned.failing(error)
            canned.writeEnabled = true
            let server = Fixture.server(FakeBackend(canned))
            for (tool, arguments) in tools {
                let result = try await server.tool(tool, arguments)
                #expect(result == ["content": [["type": "text", "text": .string(text)]], "isError": true],
                        "\(tool) \(error)")
            }
        }
    }

    @Test func messageUsesTheGivenTimeZone() {
        let error = MCPBackendError.trashed(id: "x", purgeAt: Self.purgeAt)  // 01:30 UTC on 11-14
        #expect(error.message(timeZone: TimeZone(identifier: "America/Los_Angeles")!).contains("2026-11-13"))
        #expect(error.message(timeZone: Fixture.timeZone).contains("2026-11-14"))
    }

    @Test func notFoundEchoIsClipped() {
        let message = MCPBackendError.notFound(String(repeating: "a", count: 1000)).message()
        #expect(message.count < 220)
    }

    @Test func otherErrorsGetAGenericMessage() async throws {
        let backend = FakeBackend(.failing(Boom()))
        let server = Fixture.server(backend)
        let result = try await server.tool("notes_read", #"{"ref":"x"}"#)
        #expect(result.isErrorResult)
        #expect(result.texts == ["CODD 處理這個請求時發生內部錯誤，請稍後再試。"])
        let events = await collect(server.events, count: 2)
        #expect(events.count == 2)
        guard case .tool(_, "notes_read", .failed(let detail), _, _) = events.last else {
            Issue.record("no failed tool event: \(events)")
            return
        }
        #expect(detail == "Boom")
    }

    @Test func outcomesInEvents() async throws {
        let server = Fixture.server(FakeBackend(.failing(MCPBackendError.purged(id: "x"))))
        _ = try await server.tool("notes_read", #"{"ref":"x"}"#)
        _ = try await server.tool("notes_read", "{}")
        let events = await collect(server.events, count: 4)
        let outcomes = events.compactMap { event -> MCPToolOutcome? in
            if case .tool(_, _, let outcome, _, _) = event { return outcome }
            return nil
        }
        #expect(outcomes.count == 2)
        #expect(outcomes.first == .isError("這則筆記已永久刪除"))
        if case .isError(let text)? = outcomes.last { #expect(text.hasPrefix("Invalid arguments:")) } else {
            Issue.record("validation outcome \(outcomes)")
        }
    }
}
