import Foundation
import Testing
@testable import CoddCore

@Suite("JS-compatible text helpers")
struct JSTextTests {
    @Test func trimUsesECMAScriptWhitespace() {
        #expect(JSText.trim("\u{FEFF}\u{3000} a b \u{2028}\n") == "a b")
        #expect(JSText.trim("\u{85}x\u{85}") == "\u{85}x\u{85}") // NEL is not JS whitespace
        #expect(JSText.trim("\u{200B}x") == "\u{200B}x")         // ZWSP is not JS whitespace
        #expect(JSText.trim("   ") == "")
    }

    @Test func nonBlankKeepsOriginalString() {
        #expect(JSText.nonBlank(.string(" a ")) == " a ")
        #expect(JSText.nonBlank(.string(" \t ")) == nil)
        #expect(JSText.nonBlank(.number(1)) == nil)
        #expect(JSText.nonBlank(nil) == nil)
        #expect(JSText.nonBlankTrimmed(.string(" a ")) == "a")
    }

    @Test(arguments: [
        ("\u{1B}[31mred\u{1B}[0m", "red"),
        ("a\u{1B}[?2004hb", "ab"),
        ("a\u{1B}[ 5 qb", "a [ 5 qb"), // intermediates before parameters: not a CSI match
        ("a\u{1B}]0;t\u{07}b", "a ]0;t b"),
        ("\u{1B}\u{1B}[31m[0m", "[0m"),
        ("x\u{1B}[", "x ["),
        ("\r\n\tline  two\u{7F}", "line two"),
        ("\u{A0}\u{3000}", nil),
        ("", nil),
    ] as [(String, String?)])
    func cleanText(input: String, expected: String?) {
        #expect(JSText.cleanText(input, max: 500) == expected)
    }

    @Test func cleanTextTruncatesByCodePoint() {
        let s = String(repeating: "\u{1F600}", count: 5)
        #expect(JSText.cleanText(s, max: 3) == String(repeating: "\u{1F600}", count: 3))
        // A grapheme made of 2 scalars is cut between them, exactly like Array.from().
        #expect(JSText.cleanText("e\u{301}x", max: 1) == "e")
        #expect(JSText.cleanText(.number(3), max: 10) == nil)
    }

    @Test func asciiCaseInsensitiveSearch() {
        #expect(JSText.containsCaseInsensitiveASCII("Needs PERMISSION now", "permission"))
        #expect(!JSText.containsCaseInsensitiveASCII("permi\u{17F}sion", "permission")) // long s does not fold
        #expect(!JSText.containsCaseInsensitiveASCII("perm", "permission"))
        #expect(JSText.containsCaseInsensitiveASCII("權限 permission", "permission"))
    }
}

@Suite("JS-compatible dates")
struct JSDateTests {
    @Test func formatsLikeToISOString() {
        #expect(JSDate.isoString(milliseconds: 0) == "1970-01-01T00:00:00.000Z")
        #expect(JSDate.isoString(milliseconds: 1_792_032_120_123) == "2026-10-15T02:42:00.123Z")
        #expect(JSDate.isoString(milliseconds: -1) == "1969-12-31T23:59:59.999Z")
        #expect(JSDate.isoString(milliseconds: 253_402_300_800_000) == "+010000-01-01T00:00:00.000Z")
        #expect(JSDate.isoString(milliseconds: JSDate.maxTimeValue + 1) == nil)
        #expect(JSDate.isoString(referenceNow) == "2026-10-15T02:42:00.000Z")
    }

    @Test(arguments: [
        ("2026-10-15T02:42:00.000Z", Int64(1_792_032_120_000)),
        ("2026-10-15T02:42:00Z", 1_792_032_120_000),
        ("2026-10-15T10:42:00+08:00", 1_792_032_120_000),
        ("2026-10-18T12:00:00.441208+00:00", 1_792_324_800_441),
        ("2026-10-15T02:42Z", 1_792_032_120_000),
        ("2026-10-15", 1_792_022_400_000),
        ("2026-10", 1_790_812_800_000),
        ("2024-02-29T00:00:00Z", 1_709_164_800_000),
        ("+002026-10-15T02:42:00.000Z", 1_792_032_120_000),
    ] as [(String, Int64)])
    func parsesISOStrings(_ s: String, _ ms: Int64) {
        #expect(JSDate.parse(s) == ms)
    }

    @Test(arguments: ["", "garbage", "2026-13-01", "2026-02-30", "2025-02-29T00:00:00Z", "2026-10-15T25:00:00Z",
                      "2026-10-15 02:42:00Z", "2026-10-15T02:42:00+0800", "-000000-01-01T00:00:00Z", "Thu Oct 15 2026"])
    func rejectsNonISO(_ s: String) {
        #expect(JSDate.parse(s) == nil)
    }

    @Test func dateTimeWithoutOffsetIsLocal() throws {
        let tz = try #require(TimeZone(identifier: "Asia/Taipei"))
        #expect(JSDate.parse("2026-10-15T10:42:00", timeZone: tz) == 1_792_032_120_000)
    }

    @Test func toISOPortsSessionInsights() {
        #expect(JSDate.toISO(.number(1_792_032_120)) == "2026-10-15T02:42:00.000Z")        // seconds
        #expect(JSDate.toISO(.number(1_792_032_120_000)) == "2026-10-15T02:42:00.000Z")    // milliseconds
        #expect(JSDate.toISO(.number(1_792_032_123.4567)) == "2026-10-15T02:42:03.456Z")   // truncated
        #expect(JSDate.toISO(.number(0)) == nil)
        #expect(JSDate.toISO(.number(-5)) == nil)
        #expect(JSDate.toISO(.string("  ")) == nil)
        #expect(JSDate.toISO(.bool(true)) == nil)
        #expect(JSDate.toISO(nil) == nil)
    }

    @Test func millisecondRoundTrip() {
        for ms: Int64 in [0, 1, 999, 1_792_032_120_001, 1_792_032_145_965] {
            #expect(JSDate.milliseconds(JSDate.date(milliseconds: ms)) == ms)
        }
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test func lenientObjectParsing() {
        #expect(JSONValue.parseObjectLeniently(Data("{\"a\":1}".utf8)) == ["a": .number(1)])
        #expect(JSONValue.parseObjectLeniently(Data("[1]".utf8)).isEmpty)
        #expect(JSONValue.parseObjectLeniently(Data("  \n".utf8)).isEmpty)
        #expect(JSONValue.parseObjectLeniently(Data([0xFF, 0xFE])).isEmpty)
        #expect(JSONValue.parseObjectLeniently(Data("{\"a\":".utf8)).isEmpty)
    }

    @Test func truthinessAndIntegers() {
        #expect(!JSONValue.string("").isTruthy)
        #expect(JSONValue.string("0").isTruthy)
        #expect(!JSONValue.number(.nan).isTruthy)
        #expect(JSONValue.number(7).nonNegativeIntegerValue == 7)
        #expect(JSONValue.number(7.5).nonNegativeIntegerValue == nil)
        #expect(JSONValue.number(-1).nonNegativeIntegerValue == nil)
        #expect(JSONValue.number(1e300).nonNegativeIntegerValue == nil)
        #expect(JSONValue.string("3").nonNegativeIntegerValue == nil)
    }

    @Test func boolsAreNotNumbers() throws {
        let v = try #require(JSONValue.parse(Data("[true, 1, \"x\", null, {\"k\": false}]".utf8)))
        #expect(v == .array([.bool(true), .number(1), .string("x"), .null, .object(["k": .bool(false)])]))
    }

    /// `JSON.stringify` of a string cut inside a surrogate pair emits a lone `\ud83d`; JS parses it,
    /// Foundation alone would reject the whole document.
    @Test func unpairedSurrogateEscapesDoNotDropTheDocument() throws {
        let body = #"{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"ok \ud83d","x":"\udc00\\ud800"},"pair":"\#u{1F600}","esc":"a\\u0041\"\ud800"}"#
        let o = JSONValue.parseObjectLeniently(Data(body.utf8))
        #expect(HookPayload(object: o).event == .postToolUse)
        #expect(o["tool_response"]?["stdout"] == .string("ok \u{FFFD}"))
        // An escaped backslash before "ud800" is literal text, not an escape.
        #expect(o["tool_response"]?["x"] == .string("\u{FFFD}\\ud800"))
        #expect(o["pair"] == .string("\u{1F600}"))
        #expect(o["esc"] == .string("a\\u0041\"\u{FFFD}"))
        // Valid documents are returned untouched (no repair pass).
        #expect(JSONValue.replacingUnpairedSurrogateEscapes(Data(#"{"a":"\#u{1F600}\\"}"#.utf8)) == nil)
        // Still invalid after repair → nil.
        #expect(JSONValue.parse(Data(#"{"a":"\ud800"#.utf8)) == nil)
    }

    /// Review SEC-1: a hook body nested 300 deep (about 2 KB) overflowed a dispatch worker's stack
    /// in the recursive decode and killed the app. Deeper levels now become `null` before decoding.
    @Test(arguments: [300, 511, 2000])
    func deepNestingIsCutBeforeDecodingOffTheMainThread(depth: Int) async throws {
        let objects = String(repeating: #"{"a":"#, count: depth) + "1" + String(repeating: "}", count: depth)
        let arrays = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        let body = #"{"hook_event_name":"PostToolUse","tool_name":"mcp__x__y","tool_input":"# + arrays
            + #","tool_response":"# + objects + #","deep":"# + objects + "}"
        // On a GCD worker thread, like the hook server's queue (the stack the crash ran out of).
        let parsed = await withCheckedContinuation { (c: CheckedContinuation<[String: JSONValue], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(returning: HookPayload(body: Data(body.utf8), droppingKeys: ["tool_response"]).raw)
            }
        }
        #expect(HookPayload(object: parsed).toolName == "mcp__x__y")
        #expect(parsed["tool_response"] == nil)
        // The kept members are cut at the limit: `maximumNestingDepth` levels, then null.
        var level = parsed["deep"]
        var levels = 1  // the top-level object
        while let next = level?["a"] { levels += 1; level = next }
        #expect(levels == JSONValue.maximumNestingDepth)
        #expect(level == .object(["a": .null]) || level == .null)
    }

    @Test func nestingPassLeavesShallowDocumentsAlone() throws {
        let body = Data(#"{"a":[1,{"b":"}]\"[{"}],"tool_response":{"x":[1,2]},"c":"tool_response"}"#.utf8)
        // Nothing to change: no copy.
        #expect(JSONNesting.pruned(body, maxDepth: 64) == nil)
        // A dropped member is replaced in place, braces inside strings do not confuse the pass.
        let dropped = try #require(JSONNesting.pruned(body, maxDepth: 64, nullingTopLevelKeys: ["tool_response"]))
        #expect(String(decoding: dropped, as: UTF8.self) == #"{"a":[1,{"b":"}]\"[{"}],"tool_response":null,"c":"tool_response"}"#)
        // Only top-level members: the same name deeper down is kept.
        let nested = Data(#"{"k":{"tool_response":1},"tool_response" : "big" }"#.utf8)
        let cut = try #require(JSONNesting.pruned(nested, maxDepth: 64, nullingTopLevelKeys: ["tool_response"]))
        #expect(String(decoding: cut, as: UTF8.self) == #"{"k":{"tool_response":1},"tool_response" : null }"#)
        // Depth: the third level becomes null.
        let deep = try #require(JSONNesting.pruned(Data(#"[[[1],[2]],3]"#.utf8), maxDepth: 2))
        #expect(String(decoding: deep, as: UTF8.self) == "[[null,null],3]")
        // Invalid input stays invalid (and is still rejected).
        #expect(JSONValue.parse(Data(#"{"a":[1,"#.utf8)) == nil)
        #expect(JSONValue.parseObjectLeniently(Data(#"{"tool_response":"#.utf8), nullingTopLevelKeys: ["tool_response"]).isEmpty)
    }

    @Test func reducerAcceptsPayloadWithLoneSurrogate() throws {
        let body = #"{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"hi \ud83d"}"#
        let next = try #require(HookReducer(configDir: nil).apply(nil, HookPayload(body: Data(body.utf8)), terminalId: "t", now: referenceNow))
        #expect(next.state == .busy)
        #expect(next.lastPrompt == "hi \u{FFFD}")
    }
}
