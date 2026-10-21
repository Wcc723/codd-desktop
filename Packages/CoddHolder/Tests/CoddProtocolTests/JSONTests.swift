import Testing
@testable import CoddProtocol

@Suite("Minimal JSON")
struct JSONTests {
    @Test("round trip keeps order, 64-bit integers and unicode")
    func roundTrip() throws {
        let value = JSONValue.object([
            JSONMember("z", .int(-5)),
            JSONMember("a", .uint(UInt64.max)),
            JSONMember("max", .int(Int64.max)),
            JSONMember("min", .int(Int64.min)),
            JSONMember("pi", .double(3.25)),
            JSONMember("s", .string("quote \" backslash \\ newline \n tab \t ctl \u{01} 中文 ✳")),
            JSONMember("list", .array([.null, .bool(true), .bool(false), .array([]), .object([JSONMember]())])),
        ])
        let text = value.serializedString()
        #expect(text.hasPrefix("{\"z\":-5,\"a\":18446744073709551615,"))
        #expect(try JSONValue.parse(text) == value)
    }

    @Test("parses standard documents")
    func parsing() throws {
        let parsed = try JSONValue.parse(" { \"a\" : [1, 2.5, -0.5e2, true, null], \"b\": {\"c\": \"\\u00e9\\ud83d\\ude00\\/\"} } ")
        #expect(parsed["a"]?.arrayValue?.count == 5)
        #expect(parsed["a"]?.arrayValue?[1].doubleValue == 2.5)
        #expect(parsed["a"]?.arrayValue?[2].doubleValue == -50)
        #expect(parsed["b"]?["c"]?.stringValue == "é\u{1F600}/")
        #expect(try JSONValue.parse("18446744073709551615").uint64Value == UInt64.max)
        #expect(try JSONValue.parse("-9223372036854775808").int64Value == Int64.min)
        #expect(try JSONValue.parse("1e400").doubleValue == Double.infinity)
        #expect(try JSONValue.parse("\"\\ud800\"").stringValue == "\u{FFFD}")
    }

    @Test("rejects invalid documents", arguments: [
        "", "{", "[1,]", "{\"a\":1,}", "01", "1.", "-", "+1", "\"\u{01}\"", "\"\\x\"", "tru", "nul",
        "{\"a\" 1}", "[1 2]", "1 2", "\"abc", "{1:2}", "\"\\u12\"",
    ])
    func rejects(_ text: String) {
        #expect(throws: JSONError.self) { try JSONValue.parse(text) }
    }

    @Test("nesting is limited")
    func depthLimit() throws {
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(throws: JSONError.self) { try JSONValue.parse(deep, maxDepth: 64) }
        _ = try JSONValue.parse(deep, maxDepth: 128)
    }

    @Test("accessors convert only exact values")
    func accessors() {
        #expect(JSONValue.double(3.0).intValue == 3)
        #expect(JSONValue.double(3.5).intValue == nil)
        #expect(JSONValue.int(-1).uint64Value == nil)
        #expect(JSONValue.string("x").boolValue == nil)
        #expect(JSONValue.double(.nan).serializedString() == "null")
        #expect(JSONValue.compactObject([("a", JSONValue.int(1)), ("b", nil)]).serializedString() == "{\"a\":1}")
    }
}
