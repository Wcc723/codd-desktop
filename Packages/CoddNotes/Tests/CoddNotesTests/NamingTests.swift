import Foundation
import Testing
@testable import CoddNotes

@Suite struct NamingTests {
    @Test func specTitleFileName() {
        let name = NoteNaming.fileName(title: "打卡頁 RWD 跑版紀錄", date: iso("2026-10-15T09:00:00+08:00"), timeZone: taipei) { _ in false }
        #expect(name == "2026-10-15-打卡頁-rwd-跑版紀錄.md")
        let second = NoteNaming.fileName(title: "打卡頁 RWD 跑版紀錄", date: iso("2026-10-15T09:00:00+08:00"), timeZone: taipei) {
            $0 == "2026-10-15-打卡頁-rwd-跑版紀錄.md" || $0 == "2026-10-15-打卡頁-rwd-跑版紀錄-2.md"
        }
        #expect(second == "2026-10-15-打卡頁-rwd-跑版紀錄-3.md")
    }

    @Test func slugRules() {
        #expect(NoteNaming.slug("給後端的 prompt：401 修正條件") == "給後端的-prompt-401-修正條件")
        #expect(NoteNaming.slug("  ---  ") == "note")
        #expect(NoteNaming.slug("a/b:c?d") == "a-b-c-d")
        #expect(NoteNaming.slug(String(repeating: "長", count: 60)).count == 48)
        // NFC: a decomposed é becomes one character.
        #expect(NoteNaming.slug("Cafe\u{301}") == "café")
    }

    @Test func idFromTitleThenTags() {
        var rng = SplitMix(seed: 1)
        let id = NoteNaming.makeID(title: "打卡頁 RWD 跑版紀錄", tags: ["rwd", "punch"], taken: { _ in false }, using: &rng)
        #expect(id.rawValue.hasPrefix("rwd-punch-"))
        #expect(id.rawValue.count == "rwd-punch-".count + 4)
        #expect(NoteNaming.idPrefix(title: "隨手記 10/15", tags: []) == "10-15")
        #expect(NoteNaming.idPrefix(title: "筆記", tags: []) == "note")
        #expect(NoteNaming.idPrefix(title: "ＲＷＤ 全形", tags: []) == "rwd")
        #expect(NoteNaming.idPrefix(title: "supercalifragilisticexpialidocious", tags: []) == "supercalifragilistic")
        #expect(NoteNaming.idPrefix(title: "keynote chapter", tags: ["x"]) == "keynote-chapter")
    }

    @Test func idCollisionsAndTombstones() {
        var rng = SplitMix(seed: 7)
        var taken = Set<String>()
        for _ in 0..<200 {
            let id = NoteNaming.makeID(title: "x", tags: [], taken: { taken.contains($0.rawValue) }, using: &rng)
            #expect(!taken.contains(id.rawValue))
            taken.insert(id.rawValue)
        }
        #expect(taken.count == 200)
    }

    @Test func noteIDCharset() {
        #expect(NoteID(rawValue: "rwd-punch-k7x2") != nil)
        #expect(NoteID(rawValue: "-a") == nil)
        #expect(NoteID(rawValue: "a-") == nil)
        #expect(NoteID(rawValue: "a--b") == nil)
        #expect(NoteID(rawValue: "A") == nil)
        #expect(NoteID(rawValue: String(repeating: "a", count: 48)) != nil)
        #expect(NoteID(rawValue: String(repeating: "a", count: 49)) == nil)
    }

    @Test func derivedIDIsStable() {
        let a = NoteNaming.derivedID(relativePath: "my ideas.md")
        #expect(a == NoteNaming.derivedID(relativePath: "my ideas.md"))
        #expect(a.rawValue.hasPrefix("my-ideas-"))
        #expect(NoteNaming.derivedID(relativePath: "sub/筆記.md").rawValue.hasPrefix("note-"))
    }

    @Test func referencesParse() {
        let text = "看一下 codd://note/rwd-punch-k7x2。還有 [[note:abc-1234]] 和 @codd:codd://note/rwd-punch-k7x2 以及 codd://note/x-y-"
        #expect(NoteReferences.parse(text, limit: 5).map(\.rawValue) == ["rwd-punch-k7x2", "abc-1234", "x-y"])
        #expect(NoteReferences.parse(text, limit: 1).map(\.rawValue) == ["rwd-punch-k7x2"])
        #expect(NoteReferences.parse("[[note:bad id]] codd://note/", limit: 5).isEmpty)
        #expect(NoteReferences.parseRef("rwd-punch-k7x2")?.rawValue == "rwd-punch-k7x2")
        #expect(NoteReferences.parseRef("codd://note/rwd-punch-k7x2")?.rawValue == "rwd-punch-k7x2")
        #expect(NoteReferences.parseRef("@codd-desktop:codd://note/a-1")?.rawValue == "a-1")
        #expect(NoteReferences.parseRef("[[note:a-1]]")?.rawValue == "a-1")
        #expect(NoteReferences.parseRef("http://x/n/a-1.md") == nil)
    }

    @Test func referenceForms() {
        let id = NoteID.of("rwd-punch-k7x2")
        let file = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/CODD/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md")
        let forms = NoteReferences.forms(id: id, fileURL: file, port: 47821, urlToken: "0123456789abcdef01234567")
        #expect(forms.map(\.kind) == [.uri, .mcpResource, .filePath, .markdown, .url])
        #expect(forms[0].text == "codd://note/rwd-punch-k7x2" && forms[0].recommended)
        #expect(forms[0].hint == "CODD 啟動的 session 會由 UserPromptSubmit hook 自動展開內容")
        #expect(forms[1].text == "@codd:codd://note/rwd-punch-k7x2")
        #expect(forms[2].text == file.path)
        #expect(forms[2].display == "~/Library/Application Support/CODD/notes/2026-10-15-打卡頁-rwd-跑版紀錄.md")
        #expect(forms[3].text == nil && forms[3].display == "複製全文 Markdown")
        #expect(forms[4].text == "http://127.0.0.1:47821/n/rwd-punch-k7x2.md?t=0123456789abcdef01234567")
        #expect(forms[4].display == "http://127.0.0.1:47821/n/rwd-punch-k7x2.md?t=••••")
        #expect(NoteReferences.forms(id: id, fileURL: file, port: nil, urlToken: nil)[4].text == nil)
    }

    @Test func isoDates() {
        let d = iso("2026-10-14T18:20:11+08:00")
        #expect(ISODate.format(d, timeZone: taipei) == "2026-10-14T18:20:11+08:00")
        #expect(ISODate.parse("2026-10-14T10:20:11Z", timeZone: taipei) == d)
        #expect(ISODate.parse("2026-10-14T10:20:11.000Z", timeZone: taipei) == d)
        #expect(ISODate.parse("2026-10-14T18:20:11+0800", timeZone: taipei) == d)
        #expect(ISODate.parse("2026-10-14", timeZone: taipei) == iso("2026-10-14T00:00:00+08:00"))
        #expect(ISODate.parse("2026-13-01", timeZone: taipei) == nil)
        #expect(ISODate.format(d, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-14T10:20:11Z")
        let c = ISODate.compactUTC(d.addingTimeInterval(0.123))
        #expect(c == "20261014-102011-123")
        #expect(abs(ISODate.parseCompactUTC(c)!.timeIntervalSince(d) - 0.123) < 0.0005)
    }
}

/// Deterministic randomness for id tests.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
