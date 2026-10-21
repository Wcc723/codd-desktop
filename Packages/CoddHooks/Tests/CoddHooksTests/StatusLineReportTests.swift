import CoddHookClient
import Foundation
import Testing
@testable import CoddHooks

@Suite("Status-line report decoding")
struct StatusLineReportTests {
    let sid = UUID(uuidString: "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17")!

    func decode(_ body: String, session: UUID? = nil) -> StatusLineReport? {
        StatusLineReport.decode(body: Array(body.utf8), sessionID: session, receivedAt: referenceNow)
    }

    func report(rateLimits: String, key: String = "cswap-3") -> StatusLineReport? {
        decode(#"{"v":1,"session_id":"s1","config_key":"\#(key)","rate_limits":\#(rateLimits)}"#)
    }

    @Test func decodesClaudesShape() throws {
        let r = try #require(decode(#"{"v":1,"session_id":"11111111-aaaa-4aaa-8aaa-111111111111","config_key":"cswap-3","rate_limits":{"five_hour":{"used_percentage":9.5,"resets_at":1792042740},"seven_day":{"used_percentage":85,"resets_at":1792296000},"spend_limit":{"x":1}}}"#,
                                    session: sid))
        #expect(r == StatusLineReport(
            sessionID: sid, claudeSessionId: "11111111-aaaa-4aaa-8aaa-111111111111", configKey: "cswap-3",
            fiveHour: StatusLineWindow(usedPercent: 9.5, resetsAt: Date(timeIntervalSince1970: 1_792_042_740)),
            sevenDay: StatusLineWindow(usedPercent: 85, resetsAt: Date(timeIntervalSince1970: 1_792_296_000)),
            hadRateLimits: true, receivedAt: referenceNow))
    }

    @Test func resetsAtForms() throws {
        func reset(_ token: String) -> Date? {
            report(rateLimits: #"{"five_hour":{"used_percentage":1,"resets_at":\#(token)}}"#)?.fiveHour?.resetsAt
        }
        let t = Date(timeIntervalSince1970: 1_792_042_740)
        #expect(reset("1792042740") == t)                        // epoch seconds (Claude)
        #expect(reset("1792042740.5") == Date(timeIntervalSince1970: 1_792_042_740.5))
        #expect(reset("1792042740000") == t)                     // epoch milliseconds
        #expect(reset(#""2026-10-15T05:39:00Z""#) == t)           // ISO 8601
        #expect(reset(#""2026-10-15T13:39:00+08:00""#) == t)
        #expect(reset(#""2026-10-15T05:39:00.250Z""#) == Date(timeIntervalSince1970: 1_792_042_740.25))
        for bad in [#""tomorrow""#, #""2026-10-15T05:39:00""#, #""1792042740""#, #""""#, "0", "-5", "1e20", "true", "null", "{}"] {
            let w = report(rateLimits: #"{"five_hour":{"used_percentage":1,"resets_at":\#(bad)}}"#)?.fiveHour
            #expect(w == StatusLineWindow(usedPercent: 1, resetsAt: nil), "\(bad)") // the window survives without a reset
        }
        #expect(report(rateLimits: #"{"five_hour":{"used_percentage":1}}"#)?.fiveHour == StatusLineWindow(usedPercent: 1, resetsAt: nil))
    }

    @Test func absentOrNullRateLimits() throws {
        for body in [#"{"v":1,"session_id":"s","config_key":"default"}"#,
                     #"{"v":1,"session_id":"s","config_key":"default","rate_limits":null}"#,
                     #"{"v":1,"session_id":"s","config_key":"default","rate_limits":"weird"}"#,
                     #"{"v":1,"session_id":"s","config_key":"default","rate_limits":[1,2]}"#] {
            let r = try #require(decode(body), "\(body)")
            #expect(!r.hadRateLimits)
            #expect(r.fiveHour == nil && r.sevenDay == nil)
            #expect(r.configKey == "default")
            #expect(r.claudeSessionId == "s")
        }
        let empty = try #require(report(rateLimits: "{}"))
        #expect(empty.hadRateLimits && empty.fiveHour == nil && empty.sevenDay == nil)
    }

    @Test func onlyFiveHour() throws {
        let r = try #require(report(rateLimits: #"{"five_hour":{"used_percentage":2,"resets_at":1792042740}}"#))
        #expect(r.hadRateLimits)
        #expect(r.fiveHour?.usedPercent == 2)
        #expect(r.sevenDay == nil)
        let s = try #require(report(rateLimits: #"{"seven_day":{"used_percentage":54,"resets_at":1792296000},"five_hour":null}"#))
        #expect(s.fiveHour == nil && s.sevenDay?.usedPercent == 54)
    }

    @Test func usedPercentMustBeAFiniteNumber() throws {
        func used(_ token: String) -> Double? {
            report(rateLimits: #"{"five_hour":{"used_percentage":\#(token),"resets_at":1792042740}}"#)?.fiveHour?.usedPercent
        }
        #expect(used("42.5") == 42.5)
        #expect(used("150") == 100)  // clamped
        #expect(used("-3") == 0)
        for bad in [#""50""#, #""NaN""#, #""Infinity""#, "null", "true", "{}", "[50]", "1e999"] {
            #expect(used(bad) == nil, "\(bad)")
            #expect(report(rateLimits: #"{"five_hour":{"used_percentage":\#(bad)}}"#)?.hadRateLimits == true)
        }
        // Not JSON at all: the whole body is refused.
        #expect(report(rateLimits: #"{"five_hour":{"used_percentage":NaN}}"#) == nil)
        #expect(report(rateLimits: #"{"five_hour":{"used_percentage":Infinity}}"#) == nil)
    }

    @Test(arguments: [("default", "default"), ("cswap-0", "cswap-0"), ("cswap-3", "cswap-3"), ("cswap-1234", "cswap-1234"),
                      ("cfg-0123456789abcdef", "cfg-0123456789abcdef"), ("cswap-12345", "invalid"), ("cswap-", "invalid"),
                      ("cswap-3a", "invalid"), ("cfg-0123456789ABCDEF", "invalid"), ("cfg-0123456789abcde", "invalid"),
                      ("cfg-0123456789abcdef0", "invalid"), ("Default", "invalid"), ("", "invalid"), ("north-example-com", "invalid"),
                      (" default", "invalid")])
    func configKeyValidation(_ key: String, _ expected: String) {
        #expect(decode(#"{"v":1,"config_key":"\#(key)"}"#)?.configKey == expected)
    }

    @Test func configKeyMissingOrNotAString() {
        #expect(decode(#"{"v":1}"#)?.configKey == "invalid")
        #expect(decode(#"{"v":1,"config_key":3}"#)?.configKey == "invalid")
        #expect(decode(#"{"v":1,"config_key":null}"#)?.configKey == "invalid")
    }

    @Test(arguments: ["", "null", "[]", "{", "not json", #"{"v":2}"#, #"{"v":"1"}"#, #"{"v":1.0}"#, #"{"v":1}x"#,
                      #"{"v":1,"rate_limits":{"five_hour":{"used_percentage":1,}}}"#])
    func garbageBodiesYieldNothing(_ body: String) {
        #expect(decode(body) == nil)
    }

    @Test func versionMayBeOmitted() {
        #expect(decode(#"{"config_key":"default"}"#)?.configKey == "default")
    }

    @Test func deepNestingIsRefusedWithoutRecursion() {
        let deep = String(repeating: "[", count: 100) + String(repeating: "]", count: 100)
        #expect(report(rateLimits: #"{"five_hour":{"used_percentage":1,"x":\#(deep)}}"#) == nil)
        let wide = String(repeating: "[", count: 50_000)
        #expect(report(rateLimits: wide) == nil)
        // 60 levels below the window are fine.
        let ok = String(repeating: "[", count: 60) + String(repeating: "]", count: 60)
        #expect(report(rateLimits: #"{"five_hour":{"used_percentage":1,"x":\#(ok)}}"#)?.fiveHour?.usedPercent == 1)
    }

    @Test func claudeSessionIdBounds() {
        #expect(decode(#"{"session_id":""}"#)?.claudeSessionId == nil)
        #expect(decode(#"{"session_id":7}"#)?.claudeSessionId == nil)
        #expect(decode(#"{"session_id":""# + String(repeating: "a", count: 257) + #""}"#)?.claudeSessionId == nil)
        #expect(decode(#"{"session_id":""# + String(repeating: "a", count: 256) + #""}"#)?.claudeSessionId?.count == 256)
        #expect(decode(#"{"session_id":"ab"}"#)?.claudeSessionId == "ab")
    }

    @Test func roundTripThroughTheCLIBody() throws {
        let stdin = #"{"session_id":"abc","cwd":"/x","rate_limits":{"five_hour":{"used_percentage":12.3,"resets_at":1792042740},"seven_day":{"used_percentage":100,"resets_at":1792296000000}}}"#
        let command = StatusLineCommand(arguments: ["codd-statusline"], environment: {
            ["CLAUDE_CONFIG_DIR": "/Users/u/.claude-swap-backup/sessions/2-north-example-com", "HOME": "/Users/u"][$0]
        })
        let r = try #require(StatusLineReport.decode(body: command.reportBody(stdin: Array(stdin.utf8)), sessionID: sid,
                                                     receivedAt: referenceNow))
        #expect(r.configKey == "cswap-2")
        #expect(r.claudeSessionId == "abc")
        #expect(r.fiveHour == StatusLineWindow(usedPercent: 12.3, resetsAt: Date(timeIntervalSince1970: 1_792_042_740)))
        #expect(r.sevenDay == StatusLineWindow(usedPercent: 100, resetsAt: Date(timeIntervalSince1970: 1_792_296_000)))
        #expect(r.sessionID == sid)
    }
}
