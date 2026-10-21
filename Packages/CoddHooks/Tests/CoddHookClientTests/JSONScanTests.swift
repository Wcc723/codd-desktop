import Testing
@testable import CoddHookClient

@Suite("JSON scanner")
struct JSONScanTests {
    func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    /// The raw text of each member's span.
    func raw(_ s: String) -> [String: String]? {
        let b = bytes(s)
        return JSONScan.members(b)?.mapValues { String(decoding: b[$0], as: UTF8.self) }
    }

    /// The decoded string of a one-member document `{"s":<token>}`.
    func decoded(_ token: String) -> String? {
        let b = bytes(#"{"s":"# + token + "}")
        guard let span = JSONScan.members(b)?["s"] else { return nil }
        return JSONScan.string(b, span)
    }

    @Test func membersOfAFlatObject() {
        #expect(raw(#"{"a":1,"b":"x","c":null,"d":true,"e":false,"f":-2.5e3}"#)
            == ["a": "1", "b": #""x""#, "c": "null", "d": "true", "e": "false", "f": "-2.5e3"])
        #expect(raw("{}") == [:])
        #expect(raw(" \n\t{ }\r\n") == [:])
    }

    @Test func spansExcludeWhitespaceAndKeepNestedValuesWhole() {
        let doc = " \n{ \"a\" : [ 1 , 2 ] ,\n \"rate_limits\" : {\"five_hour\":{\"used_percentage\":9,\"resets_at\":1},\"x\":[{\"y\":\"}]\"}]} , \"z\":2 }\t"
        let r = raw(doc)
        #expect(r?["a"] == "[ 1 , 2 ]")
        #expect(r?["rate_limits"] == #"{"five_hour":{"used_percentage":9,"resets_at":1},"x":[{"y":"}]"}]}"#)
        #expect(r?["z"] == "2")
        #expect(r?.count == 3) // nested keys never leak to the top level
    }

    @Test func nestedObjectThroughItsSpan() throws {
        let b = bytes(#"{"rate_limits":{"five_hour":{"used_percentage":9},"seven_day":null},"k":1}"#)
        let outer = try #require(JSONScan.members(b))
        let limitsSpan = try #require(outer["rate_limits"])
        let inner = try #require(JSONScan.members(b, in: limitsSpan))
        #expect(Set(inner.keys) == ["five_hour", "seven_day"])
        let windowSpan = try #require(inner["five_hour"])
        let window = try #require(JSONScan.members(b, in: windowSpan))
        let usedSpan = try #require(window["used_percentage"])
        #expect(JSONScan.number(b, usedSpan) == 9)
        // A span that is not an object, or out of bounds.
        let kSpan = try #require(outer["k"])
        #expect(JSONScan.members(b, in: kSpan) == nil)
        #expect(JSONScan.members(b, in: 0..<(b.count + 1)) == nil)
    }

    @Test func duplicateKeysKeepTheLastValue() {
        #expect(raw(#"{"a":1,"a":{"b":2},"a":"last"}"#) == ["a": #""last""#])
    }

    @Test func stringEscapes() {
        #expect(decoded(#""plain""#) == "plain")
        #expect(decoded(#""q\"b\\s\/b\bf\fn\nr\rt\t""#) == "q\"b\\s/b\u{08}f\u{0C}n\nr\rt\t")
        #expect(decoded(#""""#) == "")
    }

    @Test func unicodeEscapesAndRawUTF8() {
        #expect(decoded(#""é中""#) == "é中")
        #expect(decoded(#""中文 é""#) == "中文 é")
        // A supplementary-plane character (U+20BB7) as a surrogate pair and raw.
        #expect(decoded(#""𠮷""#) == "\u{20BB7}")
        #expect(decoded("\"\u{20BB7}\"") == "\u{20BB7}")
        #expect(decoded(#""\u0000x""#) == "\u{0}x")
    }

    @Test func unpairedSurrogatesBecomeReplacementCharacters() {
        #expect(decoded(#""\ud800x""#) == "\u{FFFD}x")
        #expect(decoded(#""\udc00""#) == "\u{FFFD}")
        #expect(decoded(#""\ud800A""#) == "\u{FFFD}A")
        #expect(decoded(#""\ud842𠮷""#) == "\u{FFFD}\u{20BB7}")
    }

    @Test func escapedKeys() {
        #expect(raw(#"{"ab":1,"\"q\"":2}"#) == ["ab": "1", "\"q\"": "2"])
    }

    @Test(arguments: [
        "{\"s\":\"a\u{01}b\"}",      // raw control character
        "{\"s\":\"a\nb\"}",          // raw newline in a string
        #"{"s":"\x"}"#,              // unknown escape
        #"{"s":"\u12"}"#,            // short \u
        #"{"s":"\u12G4"}"#,          // non-hex \u
        #"{"s":"abc}"#,              // unterminated
        #"{"s":"abc\"}"#,            // escaped closing quote, unterminated
    ])
    func invalidStringsRejectTheDocument(_ doc: String) {
        #expect(JSONScan.members(Array(doc.utf8)) == nil)
    }

    @Test func everyTruncationOfAValidDocumentIsRejected() {
        let doc = #"{"session_id":"abc\"é","rate_limits":{"five_hour":{"used_percentage":9.5,"resets_at":1792042740},"x":[true,false,null,-0.5e-3]}}"#
        let b = bytes(doc)
        #expect(JSONScan.members(b) != nil)
        for n in 0..<b.count {
            #expect(JSONScan.members(Array(b[0..<n])) == nil, "prefix \(n)")
        }
    }

    @Test(arguments: ["[1]", #""x""#, "1", "null", "true", "", "   ", "{}x", "{} {}", "{}}", "{{}}", "{1:2}", #"{"a"}"#])
    func onlyASingleTopLevelObjectIsAccepted(_ doc: String) {
        #expect(JSONScan.members(Array(doc.utf8)) == nil)
    }

    @Test(arguments: [#"{"a":1,}"#, #"{"a" 1}"#, #"{"a":1 "b":2}"#, "{,}", #"{"a":[1,]}"#, #"{"a":[,1]}"#, #"{"a":[1 2]}"#,
                      #"{"a":{"b":1,}}"#, #"{"a":{"b"}}"#, #"{"a":]}"#, #"{"a":[}"#, #"{"a":{]}"#, #"{"a":}"#])
    func structuralErrorsAreRejected(_ doc: String) {
        #expect(JSONScan.members(Array(doc.utf8)) == nil)
    }

    @Test func nestingIsLimitedTo64Levels() {
        // The top-level object is level 1.
        func nested(_ levels: Int, open: String, close: String) -> [UInt8] {
            bytes(#"{"a":"# + String(repeating: open, count: levels) + "1" + String(repeating: close, count: levels) + "}")
        }
        #expect(JSONScan.members(nested(63, open: "[", close: "]")) != nil)
        #expect(JSONScan.members(nested(64, open: "[", close: "]")) == nil)
        #expect(JSONScan.members(nested(63, open: #"{"b":"#, close: "}")) != nil)
        #expect(JSONScan.members(nested(64, open: #"{"b":"#, close: "}")) == nil)
        // Thousands of levels cost no stack (the scanner does not recurse).
        #expect(JSONScan.members(nested(100_000, open: "[", close: "]")) == nil)
        #expect(JSONScan.maximumNestingDepth == 64)
    }

    @Test func numberGrammar() {
        for good in ["0", "-0", "1.5", "1e3", "1E+3", "-1.25e-2", "123456789012345678901234567890"] {
            #expect(JSONScan.members(bytes(#"{"n":"# + good + "}")) != nil, "\(good)")
        }
        for bad in ["01", "1.", ".5", "+1", "1e", "1e+", "-", "0x10", "NaN", "Infinity", "-Infinity", "1_000", "١"] {
            #expect(JSONScan.members(bytes(#"{"n":"# + bad + "}")) == nil, "\(bad)")
        }
    }

    @Test func literals() {
        #expect(raw(#"{"t":true,"f":false,"n":null}"#) == ["t": "true", "f": "false", "n": "null"])
        for bad in ["tru", "nul", "True", "NULL", "falsey", "undefined"] {
            #expect(JSONScan.members(bytes(#"{"x":"# + bad + "}")) == nil, "\(bad)")
        }
        let b = bytes(#"{"n":null,"s":"null"}"#)
        let m = JSONScan.members(b)!
        #expect(JSONScan.isNull(b, m["n"]!))
        #expect(!JSONScan.isNull(b, m["s"]!))
    }

    @Test func integers() {
        func int(_ token: String) -> Int? {
            let b = bytes(#"{"n":"# + token + "}")
            return JSONScan.members(b).flatMap { $0["n"] }.flatMap { JSONScan.integer(b, $0) }
        }
        #expect(int("47821") == 47821)
        #expect(int("-7") == -7)
        #expect(int("0") == 0)
        #expect(int("9223372036854775807") == Int.max)
        #expect(int("-9223372036854775808") == Int.min)
        #expect(int("9223372036854775808") == nil)
        #expect(int("1.0") == nil)
        #expect(int("1e3") == nil)
        #expect(int(#""42""#) == nil)
        #expect(int("null") == nil)
    }

    @Test func numbers() {
        func num(_ token: String) -> Double? {
            let b = bytes(#"{"n":"# + token + "}")
            return JSONScan.members(b).flatMap { $0["n"] }.flatMap { JSONScan.number(b, $0) }
        }
        #expect(num("9.5") == 9.5)
        #expect(num("-1.25e-2") == -0.0125)
        #expect(num("100") == 100)
        #expect(num("1e999") == nil) // overflows to infinity
        #expect(num(#""50""#) == nil) // strings for numbers are refused
        #expect(num("true") == nil)
    }

    @Test func stringNeedsTheExactTokenSpan() {
        let b = bytes(#"{"s":"abc","n":5}"#)
        let m = JSONScan.members(b)!
        let s = m["s"]!
        #expect(JSONScan.string(b, s) == "abc")
        #expect(JSONScan.string(b, s.lowerBound..<(s.upperBound - 1)) == nil)
        #expect(JSONScan.string(b, (s.lowerBound + 1)..<s.upperBound) == nil)
        #expect(JSONScan.string(b, m["n"]!) == nil)
        #expect(JSONScan.string(b, 0..<(b.count + 3)) == nil)
        #expect(JSONScan.integer(b, s) == nil)
    }
}
