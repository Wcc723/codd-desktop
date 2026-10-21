import Foundation
import Testing
@testable import CoddMCP

@Suite("Tool results")
struct ToolResultTests {
    static let archived = MCPNoteHit(
        id: "old-note-a1b2", uri: "codd://note/old-note-a1b2", title: "舊的\n筆記", kind: "scratch", tags: [],
        updated: Date(timeIntervalSince1970: 1_760_000_000), snippet: "", path: "/tmp/codd-test/notes/old.md",
        state: "archived")

    func backend(hits: [MCPNoteHit] = [Fixture.hit, ToolResultTests.archived]) -> FakeBackend {
        var canned = FakeBackend.Canned()
        canned.hits = hits
        return FakeBackend(canned)
    }

    @Test func searchTextList() async throws {
        let result = try await Fixture.server(backend()).tool("notes_search", #"{"query":"打卡"}"#)
        #expect(result.texts == ["""
            1. 打卡頁 RWD 跑版紀錄 · codd://note/rwd-punch-k7x2 · NOTE · updated 10/15 10:05
               iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。
            2. 舊的筆記 · codd://note/old-note-a1b2 · SCRATCH · updated 2025/10/9 16:53 · ARCHIVED
            """])
        #expect(!result.isErrorResult)
    }

    @Test func structuredContentOnlyFrom20250618() async throws {
        let server = Fixture.server(backend())
        for version in ["2025-06-18", "2025-11-25"] {
            let result = try await server.tool("notes_search", #"{"query":"打卡"}"#, version: version)
            let results = try #require(result["structuredContent"]?["results"]?.array)
            #expect(results.count == 2)
            #expect(results[0] == [
                "id": "rwd-punch-k7x2", "uri": "codd://note/rwd-punch-k7x2", "title": "打卡頁 RWD 跑版紀錄",
                "kind": "note", "tags": ["rwd", "punch"], "updated": "2026-10-15T10:05:44+08:00",
                "snippet": "iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；\n橫向時表格溢出。",
                "path": "/tmp/codd-test/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md", "state": "active",
            ])
            let list = try await server.tool("notes_list", "{}", version: version)
            #expect(list["structuredContent"]?["results"]?.array?.count == 2)
        }
        for version in [nil, "2025-03-26"] as [String?] {
            let result = try await server.tool("notes_search", #"{"query":"打卡"}"#, version: version)
            #expect(result["structuredContent"] == nil)
            #expect(result.object?.keys == ["content"])
            #expect(result.texts.count == 1)
        }
    }

    /// Claude Code validates structuredContent against the tool's outputSchema; check every
    /// required member is present with the declared type.
    @Test func structuredContentMatchesOutputSchema() async throws {
        let server = Fixture.server(backend())
        let tools = try await server.reply(Wire.rpc("tools/list"))["result"]?["tools"]?.array ?? []
        for name in ["notes_search", "notes_list"] {
            let schema = try #require(tools.first { $0["name"]?.string == name }?["outputSchema"])
            let result = try await server.tool(name, name == "notes_search" ? #"{"query":"x"}"# : "{}")
            try validate(try #require(result["structuredContent"]), schema, path: name)
        }
        // An empty result still carries the structure.
        let empty = try await Fixture.server(backend(hits: [])).tool("notes_search", #"{"query":"x"}"#)
        #expect(empty["structuredContent"] == ["results": []])
    }

    func validate(_ value: JSON, _ schema: JSON, path: String) throws {
        switch schema["type"]?.string {
        case "object":
            let object = try #require(value.object, "\(path) not an object")
            for required in schema["required"]?.array ?? [] {
                #expect(object[required.string ?? ""] != nil, "\(path) lacks \(required)")
            }
            for member in object.members {
                if let sub = schema["properties"]?[member.key] { try validate(member.value, sub, path: path + "." + member.key) }
            }
        case "array":
            let items = try #require(value.array, "\(path) not an array")
            for item in items { try validate(item, try #require(schema["items"]), path: path + "[]") }
        case "string": #expect(value.string != nil, "\(path) not a string")
        default: Issue.record("\(path): unexpected schema \(schema)")
        }
    }

    @Test func emptyResults() async throws {
        let server = Fixture.server(backend(hits: []))
        #expect(try await server.tool("notes_search", #"{"query":"不存在"}"#).texts == ["找不到符合「不存在」的筆記。"])
        #expect(try await server.tool("notes_search", #"{"query":"","tags":["x"]}"#).texts == ["找不到符合的筆記。"])
        #expect(try await server.tool("notes_list", "{}").texts == ["沒有符合條件的筆記。"])
    }

    @Test func resultsAreCutToTheLimit() async throws {
        let many = (0..<30).map { i -> MCPNoteHit in
            var hit = Fixture.hit
            hit.id = "n\(i)"
            return hit
        }
        let server = Fixture.server(backend(hits: many))
        let search = try await server.tool("notes_search", #"{"query":"x","limit":3}"#)
        #expect(search["structuredContent"]?["results"]?.array?.count == 3)
        let list = try await server.tool("notes_list", "{}")
        #expect(list["structuredContent"]?["results"]?.array?.count == 20)
    }

    func readServer(_ content: MCPNoteContent) -> FakeBackend {
        var canned = FakeBackend.Canned()
        canned.content = content
        return FakeBackend(canned)
    }

    static func image(_ n: Int, bytes: Int = 64) -> MCPImage {
        MCPImage(data: Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ n) }), mimeType: "image/png",
                 path: "/tmp/codd-test/notes/assets/rwd-punch-k7x2/img\(n).annotated.png")
    }

    @Test func readTextImagesAndExtraPaths() async throws {
        let images = (1...6).map { Self.image($0) }
        let content = MCPNoteContent(text: Fixture.noteText, images: images,
                                     extraImagePaths: ["/tmp/codd-test/notes/assets/rwd-punch-k7x2/big.png"])
        let result = try await Fixture.server(readServer(content)).tool("notes_read", #"{"ref":"rwd-punch-k7x2"}"#)
        let blocks = try #require(result["content"]?.array)
        #expect(blocks.count == 6)
        #expect(blocks[0] == ["type": "text", "text": .string(Fixture.noteText)])
        for i in 1...4 {
            #expect(blocks[i]["type"] == "image")
            #expect(blocks[i]["mimeType"] == "image/png")
            #expect(blocks[i]["data"]?.string.flatMap { Data(base64Encoded: $0) } == images[i - 1].data)
            #expect(blocks[i].object?.keys == ["type", "data", "mimeType"])
        }
        #expect(blocks[5] == ["type": "text", "text": """
            其他圖片（未附上，需要時用 Read 開啟）：
            /tmp/codd-test/notes/assets/rwd-punch-k7x2/img5.annotated.png
            /tmp/codd-test/notes/assets/rwd-punch-k7x2/img6.annotated.png
            /tmp/codd-test/notes/assets/rwd-punch-k7x2/big.png
            """])
        #expect(result["structuredContent"] == nil)
        #expect(!result.isErrorResult)
    }

    @Test func readWithoutImagesListsThem() async throws {
        let content = MCPNoteContent(text: "x", images: [Self.image(1)])
        let backend = readServer(content)
        let result = try await Fixture.server(backend).tool("notes_read", #"{"ref":"x","include_images":false}"#)
        #expect(result["content"]?.array?.count == 2)
        #expect(result.texts.last?.hasSuffix("img1.annotated.png") == true)
        #expect(backend.calls == [.read(MCPReadRequest(ref: "x", includeImages: false), Fixture.caller)])
    }

    @Test func readImagesStayUnderTheByteBudget() async throws {
        let big = (1...4).map { Self.image($0, bytes: 3 * 1024 * 1024) }
        let result = try await Fixture.server(readServer(MCPNoteContent(text: "x", images: big))).tool(
            "notes_read", #"{"ref":"x"}"#)
        let blocks = result["content"]?.array ?? []
        #expect(blocks.filter { $0["type"] == "image" }.count == 2)
        #expect(result.texts.last?.contains("img3.annotated.png") == true)
    }

    @Test func pagingLine() async throws {
        let cut = MCPNoteContent(text: "前 12000 字", truncated: true, nextOffset: 12000, totalChars: 30500)
        let server = Fixture.server(readServer(cut))
        #expect(try await server.tool("notes_read", #"{"ref":"x"}"#).texts
            == ["前 12000 字\n\n（第 1–12000 字，共 30500 字；下一段 offset=12000）"])
        let second = MCPNoteContent(text: "中段", truncated: true, nextOffset: 24000)
        #expect(try await Fixture.server(readServer(second)).tool("notes_read", #"{"ref":"x","offset":12000}"#).texts
            == ["中段\n\n（第 12001–24000 字；下一段 offset=24000）"])
        let noNext = MCPNoteContent(text: "尾", truncated: true)
        #expect(try await Fixture.server(readServer(noNext)).tool("notes_read", #"{"ref":"x"}"#).texts
            == ["尾\n\n（第 1 字起，內容已截斷）"])
    }

    @Test func appendResult() async throws {
        let backend = FakeBackend()
        let result = try await Fixture.server(backend).tool(
            "notes_append", ###"{"ref":"ai-append-note","markdown":"## 結果\n已修好"}"###)
        #expect(result == ["content": [["type": "text", "text": "已附加到 codd://note/ai-append-note（### AI 附加 · 10:12）"]]])
        #expect(backend.calls == [.append(MCPAppendRequest(ref: "ai-append-note", markdown: "## 結果\n已修好"), Fixture.caller)])
    }

    /// D17's "3 MB" worst case: the base64 survives the writer and the parser byte for byte.
    @Test func threeMegabyteImageEncodes() async throws {
        let bytes = 3 * 1024 * 1024
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { raw in
            var x: UInt32 = 0x9E37_79B9
            for i in 0..<bytes {
                x ^= x << 13; x ^= x >> 17; x ^= x << 5
                raw[i] = UInt8(truncatingIfNeeded: x)
            }
        }
        let image = MCPImage(data: data, mimeType: "image/jpeg", path: "/tmp/codd-test/big.jpg")
        let server = Fixture.server(readServer(MCPNoteContent(text: "大圖", images: [image])))
        let clock = ContinuousClock()
        var response = MCPHTTPResponse(status: 0)
        let elapsed = await clock.measure {
            response = await server.post(Wire.call("notes_read", #"{"ref":"x"}"#))
        }
        #expect(response.status == 200)
        #expect(response.body.count > bytes * 4 / 3)
        let reply = try JSONParser.parse(response.body)
        let block = try #require(reply["result"]?["content"]?[1])
        #expect(block["mimeType"] == "image/jpeg")
        #expect(block["data"]?.string.flatMap { Data(base64Encoded: $0) } == data)
        print("MCP-NUMBERS 3MB image result: \(response.body.count) bytes in \(elapsed)")
    }
}
