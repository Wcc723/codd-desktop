import Foundation
import Testing
@testable import CoddCodeEditor

@Suite("Find engine")
struct FindEngineTests {
    private func texts(_ text: String, _ query: String, _ options: FindOptions = FindOptions()) throws -> [String] {
        try FindEngine.matches(in: text, query: query, options: options).map { (text as NSString).substring(with: $0) }
    }

    @Test func caseInsensitiveByDefaultAndCaseSensitiveOnRequest() throws {
        let text = "Sticky sticky STICKY"
        #expect(try texts(text, "sticky").count == 3)
        #expect(try texts(text, "sticky", FindOptions(caseSensitive: true)) == ["sticky"])
        #expect(try FindEngine.matches(in: text, query: "sticky", options: FindOptions(caseSensitive: true)) == [NSRange(location: 7, length: 6)])
    }

    @Test func literalQueriesAreEscaped() throws {
        #expect(try texts("a.b axb a+b", "a.b") == ["a.b"])
        #expect(try texts("a.b axb a+b", "a+b") == ["a+b"])
        #expect(try texts("(x) [y]", "(x)") == ["(x)"])
    }

    @Test func wholeWordWithCJKNeighbours() throws {
        let options = FindOptions(wholeWord: true)
        let text = "修正API錯誤 myAPI API_x a API APIs (API)"
        let ranges = try FindEngine.matches(in: text, query: "API", options: options)
        #expect(ranges.map(\.location) == [2, 22, 32])
        // CJK queries: every CJK character is a word of its own, so neighbours never block them.
        #expect(try texts("今日打卡頁 a打卡 打卡b", "打卡", options).count == 3)
        // A Latin neighbour does block a Latin edge.
        #expect(try texts("sticky stickyNote 黏sticky", "sticky", options).count == 2)
    }

    @Test func regexWithGroupTemplates() throws {
        let options = FindOptions(regex: true)
        let text = "punch-page punch-head"
        let matches = try FindEngine.matches(in: text, query: #"(\w+)-(\w+)"#, options: options)
        #expect(matches.count == 2)
        #expect(try FindEngine.replacement(for: matches[0], in: text, query: #"(\w+)-(\w+)"#, template: "$2_$1", options: options) == "page_punch")
        #expect(try FindEngine.replacement(for: matches[1], in: text, query: #"(\w+)-(\w+)"#, template: "[$0]", options: options) == "[punch-head]")
        // Literal mode keeps `$1` as typed.
        let literal = try FindEngine.matches(in: text, query: "punch", options: FindOptions())
        #expect(try FindEngine.replacement(for: literal[0], in: text, query: "punch", template: "$1x", options: FindOptions()) == "$1x")
        // Whole word around a regex keeps the user's group numbers.
        let word = FindOptions(wholeWord: true, regex: true)
        let grouped = try FindEngine.matches(in: "a-b ab-c", query: #"(a)-(\w)"#, options: word)
        #expect(grouped.count == 1)
        #expect(try FindEngine.replacement(for: grouped[0], in: "a-b ab-c", query: #"(a)-(\w)"#, template: "$2$1", options: word) == "ba")
    }

    @Test func regexAnchorsMatchLinesAndEmptyMatchesAreSkipped() throws {
        let options = FindOptions(regex: true)
        #expect(try texts("  a\n    b\nc", #"^\s+"#, options) == ["  ", "    "])
        #expect(try texts("abc", "x*", options).isEmpty)
    }

    @Test func invalidRegexThrows() {
        #expect(throws: FindError.invalidPattern("(sticky")) {
            try FindEngine.matches(in: "sticky", query: "(sticky", options: FindOptions(regex: true))
        }
        // The same text is fine as a literal.
        #expect((try? FindEngine.matches(in: "(sticky", query: "(sticky", options: FindOptions()))?.count == 1)
    }

    @Test func emptyQueryFindsNothing() throws {
        #expect(try FindEngine.matches(in: "anything", query: "", options: FindOptions()).isEmpty)
    }
}
