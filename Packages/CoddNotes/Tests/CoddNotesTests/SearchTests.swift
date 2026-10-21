import Foundation
import Testing
@testable import CoddNotes

@Suite struct SearchTests {
    func library() async throws -> (TempRoot, NotesLibrary) {
        let root = TempRoot()
        root.write("2026-10-15-打卡頁-rwd-跑版紀錄.md", specNote1())
        root.write("ime.md", "---\nid: ime-note\ntags: [ime]\n---\n# 注音輸入法筆記\n\n筆記裡寫了注音輸入法與打卡流程。\n")
        root.write("phrase.md", "---\nid: phrase-note\n---\n# 片語\n\n這裡有「跑版 紀錄」四個字中間有空格\n")
        root.write("wide.md", "---\nid: wide-note\n---\n# 全形\n\n全形的 ＲＷＤ 寫法\n")
        root.write("syntax.md", "---\nid: syntax-note\n---\n# 語法\n\nuse a-b and AND or \"quoted\" plus star*x and 100%_done\n")
        root.write("archived.md", "---\nid: old-note\nstatus: archived\n---\n# 舊的打卡頁筆記\n")
        root.write("ascii.md", "---\nid: ascii-note\n---\n# Mixed Case\n\nHello World of Notes\n")
        let lib = makeLibrary(root)
        _ = try await lib.open()
        return (root, lib)
    }

    func ids(_ hits: [NoteSearchHit]) -> Set<String> { Set(hits.map(\.summary.id.rawValue)) }

    @Test func cjkThreeCharactersUseMatch() async throws {
        let (root, lib) = try await library()
        _ = root
        #expect(SearchQuery("打卡頁").matchTerms == ["打卡頁"])
        let hits = try await lib.search(NoteQuery(text: "打卡頁"))
        #expect(ids(hits) == ["rwd-punch-k7x2"])
        #expect(hits.first!.score < 0)  // bm25
        // Archived only when asked.
        #expect(ids(try await lib.search(NoteQuery(text: "打卡頁", includeArchived: true))) == ["rwd-punch-k7x2", "old-note"])
        await lib.close()
    }

    @Test func shortTermsUseLike() async throws {
        let (_, lib) = try await library()
        #expect(SearchQuery("打卡").likeTerms == ["打卡"])
        #expect(ids(try await lib.search(NoteQuery(text: "打卡"))) == ["rwd-punch-k7x2", "ime-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "卡"))) == ["rwd-punch-k7x2", "ime-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "筆記"))) == ["ime-note"])
        await lib.close()
    }

    @Test func mixedAndTagsAndPhrases() async throws {
        let (_, lib) = try await library()
        #expect(ids(try await lib.search(NoteQuery(text: "RWD 打卡"))) == ["rwd-punch-k7x2"])
        #expect(ids(try await lib.search(NoteQuery(text: "#rwd"))) == ["rwd-punch-k7x2"])
        #expect(ids(try await lib.search(NoteQuery(text: "#RWD 問題"))) == ["rwd-punch-k7x2"])
        #expect(ids(try await lib.search(NoteQuery(text: "#ime 打卡"))) == ["ime-note"])
        // A quoted phrase keeps its space: only the note that has 跑版 紀錄 with the blank.
        #expect(ids(try await lib.search(NoteQuery(text: "\"跑版 紀錄\""))) == ["phrase-note"])
        // Unquoted, the two words are AND-ed anywhere.
        #expect(ids(try await lib.search(NoteQuery(text: "跑版 紀錄"))) == ["rwd-punch-k7x2", "phrase-note"])
        #expect(try await lib.search(NoteQuery(text: "")).isEmpty)
        await lib.close()
    }

    @Test func caseAndWidthInsensitive() async throws {
        let (_, lib) = try await library()
        #expect(ids(try await lib.search(NoteQuery(text: "hello world"))) == ["ascii-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "HELLO"))) == ["ascii-note"])
        let wide = try await lib.search(NoteQuery(text: "rwd"))
        #expect(ids(wide) == ["rwd-punch-k7x2", "wide-note"])
        let hit = try #require(wide.first { $0.summary.id.rawValue == "wide-note" })
        let ns = hit.snippet as NSString
        #expect(hit.highlights.count == 1)
        #expect(ns.substring(with: hit.highlights[0]) == "ＲＷＤ")
        await lib.close()
    }

    @Test func highlightRangesAreUTF16() async throws {
        let (_, lib) = try await library()
        let hits = try await lib.search(NoteQuery(text: "注音 打卡"))
        let hit = try #require(hits.first)
        #expect(hit.summary.id.rawValue == "ime-note")
        let ns = hit.snippet as NSString
        let marked = hit.highlights.map { ns.substring(with: $0) }
        #expect(marked == ["注音", "打卡"])
        #expect(hit.snippet == "筆記裡寫了注音輸入法與打卡流程。")
        await lib.close()
    }

    @Test func ftsSyntaxIsLiteral() async throws {
        let (_, lib) = try await library()
        #expect(ids(try await lib.search(NoteQuery(text: "a-b"))) == ["syntax-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "AND"))) == ["syntax-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "\""))) == ["syntax-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "\"quoted\""))) == ["syntax-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "star*x"))) == ["syntax-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "*"))) == ["syntax-note"])
        #expect(ids(try await lib.search(NoteQuery(text: "%_d"))) == ["syntax-note"])
        // `%` and `_` are not wildcards.
        #expect(try await lib.search(NoteQuery(text: "%")).count == 1)
        #expect(try await lib.search(NoteQuery(text: "OR NOT")).isEmpty == false)
        #expect(try await lib.search(NoteQuery(text: "NEAR(")).isEmpty)
        #expect(SearchQuery("x\"y").terms == ["x\"y"])
        #expect(NotesIndex.ftsLiteral("a\"b") == "\"a\"\"b\"")
        await lib.close()
    }

    @Test func filters() async throws {
        let (_, lib) = try await library()
        #expect(try await lib.search(NoteQuery(text: "打卡", kinds: [.prompt])).isEmpty)
        #expect(ids(try await lib.search(NoteQuery(text: "打卡", project: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend"))) == ["rwd-punch-k7x2"])
        #expect(try await lib.search(NoteQuery(text: "打卡", limit: 1)).count == 1)
        await lib.close()
    }
}
