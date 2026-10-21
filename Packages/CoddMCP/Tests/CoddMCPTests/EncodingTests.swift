import Foundation
import Testing
@testable import CoddMCP

@Suite("JSON encoding")
struct EncodingTests {
    static let cjk = "打卡頁 RWD 跑版紀錄：iPhone SE（375×667）「按鈕」被蓋住 — 注音ㄅㄆㄇ\u{2028}行尾"

    @Test func cjkSurvivesByteExact() async throws {
        var canned = FakeBackend.Canned()
        canned.content = MCPNoteContent(text: Self.cjk)
        let response = await Fixture.server(FakeBackend(canned)).post(Wire.call("notes_read", #"{"ref":"x"}"#))
        let body = response.body
        // The raw UTF-8 of the text is in the body: nothing was \u-escaped.
        #expect(body.firstRange(of: Array(Self.cjk.utf8)) != nil)
        #expect(!response.bodyText.contains("\\u"))
        let reply = try JSONParser.parse(body)
        #expect(reply["result"]?.texts == [Self.cjk])
        // Foundation agrees on the content.
        let foundation = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
        let result = foundation?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == Self.cjk)
    }

    @Test func cjkArgumentsReachTheBackend() async throws {
        let backend = FakeBackend()
        _ = try await Fixture.server(backend).tool("notes_search", #"{"query":"注音輸入法 \u7b46\u8a18"}"#)
        #expect(backend.calls == [.search(MCPSearchRequest(query: "注音輸入法 筆記"), Fixture.caller)])
    }

    @Test func slashesAreNotEscaped() async throws {
        let response = await Fixture.server().post(Wire.rpc("initialize", params: #"{"protocolVersion":"2025-11-25"}"#))
        #expect(response.bodyText.contains("\"CODD notes\""))
        #expect(!response.bodyText.contains("\\/"))
        let search = await Fixture.server().post(Wire.call("notes_search", #"{"query":"x"}"#))
        #expect(search.bodyText.contains("codd://note/rwd-punch-k7x2"))
        #expect(search.bodyText.contains("/tmp/codd-test/notes/"))
    }

    @Test func writerEscapesOnlyWhatJSONRequires() throws {
        let text = "a\"b\\c\nd\re\tf\u{08}g\u{0C}h\u{01}i\u{1F}j/k\u{7F}l"
        let written = String(decoding: JSONWriter.compact(.string(text)), as: UTF8.self)
        #expect(written == #""a\"b\\c\nd\re\tf\bg\fh\u0001i\u001fj/k"# + "\u{7F}l\"")
        #expect(try JSONParser.parse(written) == .string(text))
    }

    @Test func wordScanMatchesTheByteRule() throws {
        func slow(_ word: UInt64) -> Bool {
            (0..<8).contains { i in
                let b = UInt8(truncatingIfNeeded: word >> (8 * UInt64(i)))
                return b == 0x22 || b == 0x5C || b < 0x20
            }
        }
        var x: UInt64 = 0x2545_F491_4F6C_DD1D
        for _ in 0..<200_000 {
            x ^= x << 13; x ^= x >> 7; x ^= x << 17
            // Bias toward the interesting bytes and their neighbours.
            var word = x
            let pick = Int(x % 8)
            let interesting: [UInt8] = [0x00, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x5B, 0x5C, 0x5D, 0x7F, 0x80, 0xFF]
            word &= ~(UInt64(0xFF) << (8 * UInt64(pick)))
            word |= UInt64(interesting[Int((x >> 32) % UInt64(interesting.count))]) << (8 * UInt64(pick))
            #expect(JSONWriter.needsEscape(word) == slow(word))
            #expect(JSONWriter.needsEscape(x) == slow(x))
        }
        // An escape at every offset of a 40-byte string, with CJK around it.
        for position in 0..<40 {
            for special in ["\"", "\\", "\n", "\u{01}"] {
                var characters = Array(repeating: "a", count: 40)
                characters[position] = special
                let text = "打" + characters.joined() + "卡"
                let written = String(decoding: JSONWriter.compact(.string(text)), as: UTF8.self)
                #expect(try JSONParser.parse(written) == .string(text))
                let foundation = try JSONSerialization.jsonObject(with: Data(written.utf8), options: .fragmentsAllowed)
                #expect(foundation as? String == text)
            }
        }
    }

    @Test func writerKeepsMemberOrder() {
        let value: JSON = ["z": 1, "a": [true, false, .null], "m": ["k": "v"], "e": [], "o": .object(JSONObject())]
        #expect(String(decoding: JSONWriter.compact(value), as: UTF8.self)
            == #"{"z":1,"a":[true,false,null],"m":{"k":"v"},"e":[],"o":{}}"#)
        #expect(JSONWriter.pretty(value) == """
            {
              "z": 1,
              "a": [
                true,
                false,
                null
              ],
              "m": {
                "k": "v"
              },
              "e": [],
              "o": {}
            }
            """)
    }

    @Test func parserAcceptsValidJSON() throws {
        #expect(try JSONParser.parse(#" {"a" : [1, -0.5, 2e3, 1E-2, true, false, null, "x"]} "#)
            == ["a": [1, .number(JSONNumber(validatedText: "-0.5")), .number(JSONNumber(validatedText: "2e3")),
                      .number(JSONNumber(validatedText: "1E-2")), true, false, .null, "x"]])
        #expect(try JSONParser.parse(#""\ud842\udfb7 \u00e9 \/ \u6253""#) == .string("\u{20BB7} é / 打"))
        // Unpaired surrogates become U+FFFD instead of failing.
        #expect(try JSONParser.parse(#""\ud800x\udc00""#) == .string("\u{FFFD}x\u{FFFD}"))
        // Duplicate keys: the last one wins, like JSON.parse.
        #expect(try JSONParser.parse(#"{"a":1,"a":2}"#)["a"]?.int == 2)
        // A BOM is skipped.
        #expect(try JSONParser.parse([0xEF, 0xBB, 0xBF] + Array("[1]".utf8)) == [1])
        #expect(try JSONParser.parse("2").int == 2)
    }

    @Test func parserRejectsInvalidJSON() {
        for text in ["", " ", "[1,]", "{\"a\"}", "01", "1.", "-", "+1", ".5", "1e", "\"\t\"", "\"\\x\"", "\"\\u12\"",
                     "tru", "nul", "[1 2]", "{\"a\":1 \"b\":2}", "{1:2}", "\"abc", "[", "{}x", "NaN", "'a'"] {
            #expect(throws: JSONParseError.self, "\(text)") { try JSONParser.parse(text) }
        }
        #expect(throws: JSONParseError.self) { try JSONParser.parse([0x22, 0xC3, 0x28, 0x22]) }
    }

    @Test func parserCapsNesting() throws {
        let ok = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        #expect(throws: Never.self) { try JSONParser.parse(ok) }
        let deep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(throws: JSONParseError.self) { try JSONParser.parse(deep) }
        let hostile = String(repeating: "{\"a\":", count: 100_000)
        #expect(throws: JSONParseError.self) { try JSONParser.parse(hostile) }
    }

    /// A hostile 1.5 MB body with 100k members in one object parses in linear time.
    @Test func manyMembersStayLinear() async throws {
        let members = (0..<100_000).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
        let body = #"{"jsonrpc":"2.0","id":1,"method":"ping","params":{"#  + members + "}}"
        let clock = ContinuousClock()
        let start = clock.now
        let response = await Fixture.server().post(body)
        let elapsed = clock.now - start
        #expect(response.status == 200)
        #expect(elapsed < .seconds(5))
        print("MCP-NUMBERS 100k-member body (\(body.utf8.count) bytes): \(elapsed)")
    }

    @Test func lineFolding() {
        #expect(MCPText.oneLine("a\nb") == "a b")
        #expect(MCPText.oneLine("a\r\n\n\tb") == "a b")
        #expect(MCPText.oneLine(" a \n b ") == "a b")
        #expect(MCPText.oneLine("打卡\n頁面") == "打卡頁面")
        #expect(MCPText.oneLine("RWD\n打卡") == "RWD 打卡")
        #expect(MCPText.oneLine("\n\n") == "")
        #expect(MCPText.clip("打卡頁面", 2) == "打卡…")
        #expect(MCPText.clip("abc", 3) == "abc")
    }

    @Test func numbers() {
        #expect(JSONNumber(12).text == "12")
        #expect(JSONNumber(1568.0)?.text == "1568")
        #expect(JSONNumber(0.25)?.text == "0.25")
        #expect(JSONNumber(Double.nan) == nil)
        #expect(JSONNumber(validatedText: "1e3").integerValue == 1000)
        #expect(JSONNumber(validatedText: "1.5").integerValue == nil)
        #expect(JSONNumber(validatedText: "1e300").integerValue == nil)
    }
}
