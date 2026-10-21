import Foundation
import Testing
@testable import CoddCore

@Suite("Fuzzy matcher")
struct FuzzyMatcherTests {
    func score(_ q: String, _ c: String) throws -> Int {
        try #require(FuzzyMatcher.match(q, in: c)).score
    }

    func spans(_ q: String, _ c: String) throws -> [TextSpan] {
        try #require(FuzzyMatcher.match(q, in: c)).spans
    }

    /// Candidates ranked by score (highest first; ties keep input order), non-matches dropped.
    func ranked(_ q: String, _ candidates: [String]) -> [String] {
        candidates.enumerated().compactMap { i, c in FuzzyMatcher.match(q, in: c).map { (c, $0.score, i) } }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.map(\.0)
    }

    @Test func emptyAndWhitespaceQueries() {
        #expect(FuzzyMatcher.match("", in: "anything") == FuzzyMatch(score: 0, spans: []))
        #expect(FuzzyMatcher.match("  \t\u{3000}", in: "anything") == FuzzyMatch(score: 0, spans: []))
        #expect(FuzzyMatcher.match("", in: "") == FuzzyMatch(score: 0, spans: []))
    }

    @Test func noMatch() {
        #expect(FuzzyMatcher.match("xyz", in: "orb-toolkit-backend") == nil)
        #expect(FuzzyMatcher.match("dnah", in: "hand") == nil)      // all characters, wrong order
        #expect(FuzzyMatcher.match("abc", in: "") == nil)
        #expect(FuzzyMatcher.match("打卡頁面", in: "打卡頁") == nil)  // query longer than candidate
    }

    @Test func tiersAreOrdered() throws {
        let prefix = try score("orb", "orb-toolkit-backend")
        let wordStart = try score("tool", "orb-toolkit-backend")
        let substring = try score("olki", "orb-toolkit-backend")
        let subsequence = try score("otb", "orb-toolkit-backend")
        #expect(prefix > wordStart)
        #expect(wordStart > substring)
        #expect(substring > subsequence)
        // Tiers beat length: a long prefix match outranks a short word-start match, and so on.
        #expect(try score("ab", String(repeating: "ab", count: 200)) > (try score("ab", "x ab")))
        #expect(try score("ab", "x ab" + String(repeating: "z", count: 300)) > (try score("ab", "xab")))
        #expect(try score("ab", "xab" + String(repeating: "z", count: 300)) > (try score("ab", "a-b")))
    }

    @Test func shorterCandidateWinsWithinATier() {
        #expect(ranked("api", ["api gateway refactor", "api"]) == ["api", "api gateway refactor"])
        #expect(ranked("rwd", ["打卡頁 RWD 調整與測試", "打卡頁 RWD 調整"]) == ["打卡頁 RWD 調整", "打卡頁 RWD 調整與測試"])
        #expect(ranked("olki", ["orb-toolkit-backend", "toolkit"]) == ["toolkit", "orb-toolkit-backend"])
    }

    @Test func cjkPrefixAndWordStarts() throws {
        let m = try #require(FuzzyMatcher.match("打卡", in: "打卡頁 RWD 調整"))
        #expect(m.spans == [TextSpan(location: 0, length: 2)])
        #expect(m.score >= FuzzyMatcher.tierScale * FuzzyMatcher.prefixTier)
        let rwd = try #require(FuzzyMatcher.match("rwd", in: "打卡頁 RWD 調整"))
        #expect(rwd.spans == [TextSpan(location: 4, length: 3)])
        #expect(rwd.score >= FuzzyMatcher.tierScale * FuzzyMatcher.wordStartTier)
        #expect(rwd.score < FuzzyMatcher.tierScale * FuzzyMatcher.prefixTier)
        // CJK↔Latin boundary without a space is a word start too.
        let glued = try #require(FuzzyMatcher.match("rwd", in: "打卡頁RWD調整"))
        #expect(glued.score >= FuzzyMatcher.tierScale * FuzzyMatcher.wordStartTier)
        let cjkAfterLatin = try #require(FuzzyMatcher.match("調整", in: "RWD調整"))
        #expect(cjkAfterLatin.score >= FuzzyMatcher.tierScale * FuzzyMatcher.wordStartTier)
        // Inside a CJK run it is a plain substring.
        let inside = try #require(FuzzyMatcher.match("卡頁", in: "打卡頁"))
        #expect(inside.score < FuzzyMatcher.tierScale * FuzzyMatcher.wordStartTier)
        #expect(inside.score >= FuzzyMatcher.tierScale * FuzzyMatcher.substringTier)
    }

    @Test func wordStartSeparators() throws {
        for candidate in ["a b", "a-b", "a_b", "a.b", "a/b", "a·b"] {
            let m = try #require(FuzzyMatcher.match("b", in: candidate))
            #expect(m.score >= FuzzyMatcher.tierScale * FuzzyMatcher.wordStartTier, "\(candidate)")
            #expect(m.spans == [TextSpan(location: 2, length: 1)])
        }
        let plain = try #require(FuzzyMatcher.match("b", in: "ab"))
        #expect(plain.score < FuzzyMatcher.tierScale * FuzzyMatcher.wordStartTier)
    }

    @Test func subsequencePrefersWordStartsAndRuns() throws {
        // `otb`: three word starts beat a run in a shorter candidate.
        #expect(ranked("otb", ["outbox", "orb-toolkit-backend"]) == ["orb-toolkit-backend", "outbox"])
        #expect(try spans("otb", "orb-toolkit-backend")
            == [TextSpan(location: 0, length: 1), TextSpan(location: 4, length: 1), TextSpan(location: 12, length: 1)])
        // Fewer gaps / longer runs win.
        #expect(ranked("abc", ["axbxc", "abxc"]) == ["abxc", "axbxc"])
        #expect(ranked("abcd", ["axbxcxd", "abxcd", "abcxd"]) == ["abcxd", "abxcd", "axbxcxd"])
        // The best alignment is found, not the greedy first one (word starts at 5 and 7, not 1 and 3).
        #expect(try spans("ab", "xaxb a-b") == [TextSpan(location: 5, length: 1), TextSpan(location: 7, length: 1)])
        #expect(try spans("nsr", "new session · resume picker sheet") == [
            TextSpan(location: 0, length: 1), TextSpan(location: 4, length: 1), TextSpan(location: 14, length: 1)])
    }

    @Test func spansAreMergedRunsInUTF16() throws {
        #expect(try spans("tool", "orb-toolkit-backend") == [TextSpan(location: 4, length: 4)])
        // An emoji (two UTF-16 units) and CJK before the match.
        let candidate = "\u{1F680} 部署 deploy-api"
        let m = try #require(FuzzyMatcher.match("dep", in: candidate))
        #expect(m.spans == [TextSpan(location: 6, length: 3)])
        let ns = candidate as NSString
        #expect(ns.substring(with: NSRange(location: m.spans[0].location, length: m.spans[0].length)) == "dep")
        let cjk = try #require(FuzzyMatcher.match("部署", in: candidate))
        #expect(ns.substring(with: NSRange(location: cjk.spans[0].location, length: cjk.spans[0].length)) == "部署")
        // A subsequence spanning the emoji.
        let sub = try #require(FuzzyMatcher.match("\u{1F680}da", in: candidate))
        #expect(sub.spans.first == TextSpan(location: 0, length: 2))
    }

    @Test func caseWidthAndDiacriticFolding() throws {
        let full = try #require(FuzzyMatcher.match("ＲＷＤ", in: "打卡頁 RWD 調整"))
        #expect(full.spans == [TextSpan(location: 4, length: 3)])
        let fullCandidate = try #require(FuzzyMatcher.match("rwd", in: "打卡頁 ＲＷＤ 調整"))
        #expect(fullCandidate.spans == [TextSpan(location: 4, length: 3)])
        #expect(try spans("RESUME", "résumé picker") == [TextSpan(location: 0, length: 6)])
        #expect(try spans("cafe", "Café") == [TextSpan(location: 0, length: 4)])
        // Folding that changes length: `ß` → `ss` maps back to the one original character.
        let strasse = try #require(FuzzyMatcher.match("strasse", in: "Straße 1"))
        #expect(strasse.spans == [TextSpan(location: 0, length: 6)])
        let half = try #require(FuzzyMatcher.match("ss", in: "aß"))
        #expect(half.spans == [TextSpan(location: 1, length: 1)])
        // Decomposed accents are one character with two UTF-16 units.
        let decomposed = "Cafe\u{301} 菜單"
        let m = try #require(FuzzyMatcher.match("cafe 菜", in: decomposed))
        #expect(m.spans == [TextSpan(location: 0, length: 7)])
    }

    @Test func queryWhitespaceTrimmedButInnerSpacesCount() throws {
        #expect(try spans("  rwd ", "打卡頁 RWD 調整") == [TextSpan(location: 4, length: 3)])
        let m = try #require(FuzzyMatcher.match("打卡 rwd", in: "打卡頁 RWD 調整"))
        #expect(m.spans == [TextSpan(location: 0, length: 2), TextSpan(location: 3, length: 4)])
        #expect(FuzzyMatcher.match("a b", in: "ab") == nil)
    }

    @Test func fiveHundredCandidates() {
        let words = ["orb", "toolkit", "backend", "打卡頁", "RWD", "調整", "refresh", "token", "流程", "改寫", "auth",
                     "middleware", "單元測試", "登入頁", "錯誤訊息", "i18n", "CI", "設定", "deploy", "api"]
        let candidates = (0..<500).map { i in
            (0..<(3 + i % 5)).map { words[(i * 7 + $0 * 3) % words.count] }.joined(separator: i % 2 == 0 ? " " : "-")
        }
        let clock = ContinuousClock()
        var matched = 0
        let start = clock.now
        for q in ["otb", "rwd", "打卡", "refresh token", "midw", "zzz"] {
            matched += candidates.compactMap { FuzzyMatcher.match(q, in: $0) }.count
        }
        let elapsed = clock.now - start
        print("PERF fuzzy match, 500 candidates × 6 queries: \(elapsed) (\(matched) matches)")
        #expect(matched > 0)
        #expect(elapsed < .milliseconds(600)) // debug build; ≈ 100 ms per keystroke budget for 500 rows
    }
}
