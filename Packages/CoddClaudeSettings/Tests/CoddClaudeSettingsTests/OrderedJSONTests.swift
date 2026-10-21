import Foundation
import Testing
@testable import CoddClaudeSettings

@Suite("OrderedJSON")
struct OrderedJSONTests {
    func parse(_ text: String) throws -> OrderedJSON {
        try OrderedJSON.parse(Data(text.utf8))
    }

    func parseError(_ text: String) -> OrderedJSONError? {
        do {
            _ = try OrderedJSON.parse(Data(text.utf8))
            return nil
        } catch {
            return error
        }
    }

    // MARK: Round trips

    @Test(arguments: Fixture.roundTripNames)
    func everyFixtureRoundTripsByteForByte(_ name: String) throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let original = try Fixture.data(name)
        let url = tmp.file("settings.json")
        try original.write(to: url)
        let file = try ClaudeSettingsFile.load(url)
        #expect(file.exists)
        #expect(Data(file.serializedText.utf8) == original, "\(name) did not round-trip")
    }

    @Test func userFixtureWithTempPathsRoundTrips() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        for four in [false, true] {
            let text = try Fixture.userSettings(tmp, fourSpaces: four)
            let url = try tmp.write("s.json", text)
            let file = try ClaudeSettingsFile.load(url)
            #expect(file.indent == (four ? "    " : "  "))
            #expect(file.serializedText == text)
        }
    }

    @Test func linesRenderedForTheDiffAreTheSerializedLines() throws {
        for name in Fixture.roundTripNames {
            let data = try Fixture.data(name)
            let file = try ClaudeSettingsFile.decode(data, url: URL(fileURLWithPath: "/x"), fingerprint: nil)
            let lines = SettingsLineRenderer.render(file.root, indent: file.indent, tags: TagTable()) { _, h in HookTree.isLegacy(h) }
            #expect(lines.map(\.text).joined(separator: "\n") == file.root.serialized(indent: file.indent), "\(name)")
        }
    }

    // MARK: JSON.stringify compatibility (expected texts printed by node 25)

    @Test func nestedLayoutMatchesStringify() throws {
        // JSON.stringify({a: [1, {b: []}], c: {}}, null, 2)
        let value = try parse(#"{"a":[1,{"b":[]}],"c":{}}"#)
        #expect(value.serialized(indent: "  ") == "{\n  \"a\": [\n    1,\n    {\n      \"b\": []\n    }\n  ],\n  \"c\": {}\n}")
    }

    @Test func controlCharactersEscapeLikeStringify() {
        // JSON.stringify("\u0000\u0001\u0008\u0009\u000a\u000b\u000c\u000d\u001b\u001f\u0020\u007f")
        let s = "\u{0}\u{1}\u{8}\u{9}\u{A}\u{B}\u{C}\u{D}\u{1B}\u{1F}\u{20}\u{7F}"
        #expect(OrderedJSON.string(s).serialized(indent: "  ") == #""\u0000\u0001\b\t\n\u000b\f\r\u001b\u001f "# + "\u{7F}\"")
    }

    @Test func lineSeparatorsAndNonASCIIStayRaw() {
        // JSON.stringify("\u2028\u2029é\u{1D11E}\"\\/") keeps U+2028 / U+2029, é and the astral character raw.
        let s = "\u{2028}\u{2029}é𝄞\"\\/"
        #expect(OrderedJSON.string(s).serialized(indent: "  ") == "\"\u{2028}\u{2029}é𝄞\\\"\\\\/\"")
    }

    @Test func emptyIndentIsCompact() throws {
        // JSON.stringify({a: {b: 1, c: [true, null]}}, null, "")
        let value = try parse(#"{ "a" : { "b" : 1 , "c" : [ true , null ] } }"#)
        #expect(value.serialized(indent: "") == #"{"a":{"b":1,"c":[true,null]}}"#)
    }

    @Test func indentIsCappedAtTenCharacters() throws {
        // JSON.stringify({a: {b: 1}}, null, "            ") (12 spaces) uses 10.
        let value = try parse(#"{"a":{"b":1}}"#)
        let ten = String(repeating: " ", count: 10)
        #expect(value.serialized(indent: String(repeating: " ", count: 12)) == "{\n\(ten)\"a\": {\n\(ten)\(ten)\"b\": 1\n\(ten)}\n}")
    }

    @Test func tabIndentAndNestedArrays() throws {
        // JSON.stringify({a: [[1], []]}, null, "\t")
        let value = try parse(#"{"a":[[1],[]]}"#)
        #expect(value.serialized(indent: "\t") == "{\n\t\"a\": [\n\t\t[\n\t\t\t1\n\t\t],\n\t\t[]\n\t]\n}")
    }

    @Test func emptyContainers() throws {
        #expect(try parse("[]").serialized(indent: "  ") == "[]")
        #expect(try parse("{}").serialized(indent: "  ") == "{}")
        #expect(try parse("[{}]").serialized(indent: "  ") == "[\n  {}\n]")
        #expect(try parse(#"{"a":{},"b":[[]]}"#).serialized(indent: "  ") == "{\n  \"a\": {},\n  \"b\": [\n    []\n  ]\n}")
    }

    @Test func keysAreEscapedLikeValues() throws {
        // JSON.stringify({"k\n\"": "v"}, null, 2)
        let value = try parse(#"{"k\n\"":"v"}"#)
        #expect(value.serialized(indent: "  ") == "{\n  \"k\\n\\\"\": \"v\"\n}")
    }

    @Test func numbersKeepTheirTokens() throws {
        let value = try parse("[1e3, 0.10, -0, 12345678901234567890, -1.5E+7, 0, 1E-0]")
        #expect(value.arrayElements == [.number("1e3"), .number("0.10"), .number("-0"), .number("12345678901234567890"),
                                        .number("-1.5E+7"), .number("0"), .number("1E-0")])
        #expect(value.serialized(indent: "") == "[1e3,0.10,-0,12345678901234567890,-1.5E+7,0,1E-0]")
        #expect(value.arrayElements?[0].doubleValue == 1000)
    }

    @Test func escapesAreNormalizedLikeJavaScript() throws {
        // JSON.stringify(JSON.parse('"\\u00e9\\/\\ud834\\udd1e"')) === '"é/𝄞"'
        let value = try parse(#""\u00e9\/\ud834\udd1e\u0041""#)
        #expect(value == .string("é/𝄞A"))
        #expect(value.serialized(indent: "  ") == "\"é/𝄞A\"")
    }

    // MARK: Structure

    @Test func keyOrderIsKeptAndNotSorted() throws {
        let value = try parse(#"{"zeta":1,"alpha":2,"mid":{"y":true,"b":false}}"#)
        #expect(value.objectMembers?.map(\.key) == ["zeta", "alpha", "mid"])
        #expect(value["mid"]?.objectMembers?.map(\.key) == ["y", "b"])
        #expect(value.serialized(indent: "") == #"{"zeta":1,"alpha":2,"mid":{"y":true,"b":false}}"#)
    }

    @Test func repeatedKeysMergeLikeJSONParse() throws {
        // JSON.stringify(JSON.parse('{"a":1,"b":2,"a":3}')) === '{"a":3,"b":2}'
        let value = try parse(#"{"a":1,"b":2,"a":3}"#)
        #expect(value.serialized(indent: "") == #"{"a":3,"b":2}"#)
        #expect(value["a"] == .number("3"))
    }

    @Test func equalityIsOrderAndTokenSensitive() throws {
        #expect(try parse(#"{"a":1,"b":2}"#) != parse(#"{"b":2,"a":1}"#))
        #expect(try parse("1e3") != parse("1000"))
        #expect(try parse(#"{"a":[1,{"b":null}]}"#) == parse(#" { "a" : [ 1 , { "b" : null } ] } "#))
    }

    @Test func accessors() throws {
        let value = try parse(#"{"s":"x","n":2.5,"a":[1],"o":{}}"#)
        #expect(value["s"]?.stringValue == "x")
        #expect(value["n"]?.doubleValue == 2.5)
        #expect(value["a"]?.arrayElements?.count == 1)
        #expect(value["o"]?.isObject == true)
        #expect(value["missing"] == nil)
        #expect(OrderedJSON.array([])["s"] == nil)
    }

    @Test func mutationKeepsPositions() throws {
        var value = try parse(#"{"a":1,"b":2,"c":3}"#)
        value.setValue(.number("20"), forKey: "b")
        value.setValue(.number("4"), forKey: "d")
        value.removeValue(forKey: "a")
        #expect(value.serialized(indent: "") == #"{"b":20,"c":3,"d":4}"#)
    }

    // MARK: Strictness

    @Test(arguments: [
        ("", 1, 1),
        ("{", 1, 2),
        ("{\"a\":1,}", 1, 8),
        ("[1,]", 1, 4),
        ("{\n  \"a\": 01\n}", 2, 9),
        ("{\"a\": .5}", 1, 7),
        ("{\"a\": 1.}", 1, 9),
        ("{\"a\": 1e}", 1, 9),
        ("{'a': 1}", 1, 2),
        ("// c\n{}", 1, 1),
        ("{\"a\": NaN}", 1, 7),
        ("{\"a\": tru}", 1, 10),
        ("{\"a\": \"x\ty\"}", 1, 9),
        ("{\"a\": \"\\x\"}", 1, 9),
        ("{\"a\": \"\\u12G4\"}", 1, 12),
        ("{\"a\": \"unterminated}", 1, 21),
        ("{} {}", 1, 4),
        ("{\"a\" 1}", 1, 6),
        ("\u{FEFF}{}", 1, 1),
        ("{\n\"中文\": x}", 2, 7),
    ] as [(String, Int, Int)])
    func rejectsInvalidJSONWithLineAndColumn(_ text: String, _ line: Int, _ column: Int) {
        #expect(parseError(text) == OrderedJSONError(line: line, column: column), "\(text.debugDescription)")
    }

    @Test func rejectsLoneSurrogatesAndInvalidUTF8() {
        #expect(parseError(#"["\ud800"]"#) != nil)
        #expect(parseError(#"["\udc00"]"#) != nil)
        #expect(parseError(#"["\ud800\u0041"]"#) != nil)
        var bytes = Array(#"{"a":"x"#.utf8)
        bytes.append(contentsOf: [0xC3, 0x28])
        bytes.append(contentsOf: Array(#""}"#.utf8))
        #expect(throws: OrderedJSONError.self) { try OrderedJSON.parse(Data(bytes)) }
    }

    @Test func errorsNeverCarryContent() {
        let secret = "sk-ant-SECRET-TOKEN"
        let error = parseError(#"{"env": {"TOKEN": "\#(secret)", }}"#)
        #expect(error != nil)
        #expect(!(error?.description.contains(secret) ?? true))
        #expect(!(error?.description.contains("TOKEN") ?? true))
    }

    @Test func depthLimitIs512() throws {
        let ok = String(repeating: "[", count: 512) + String(repeating: "]", count: 512)
        let value = try parse(ok)
        #expect(value.serialized(indent: "").count == 1024)
        let deep = String(repeating: "[", count: 513) + String(repeating: "]", count: 513)
        #expect(parseError(deep) == OrderedJSONError(line: 1, column: 513))
        let objects = String(repeating: #"{"a":"#, count: 513) + "1" + String(repeating: "}", count: 513)
        #expect(parseError(objects) != nil)
    }
}
