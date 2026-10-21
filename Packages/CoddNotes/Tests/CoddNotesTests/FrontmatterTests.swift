import Foundation
import Testing
@testable import CoddNotes

@Suite struct FrontmatterTests {
    @Test func untouchedRoundTripsByteForByte() {
        let texts = [
            specNote1(),
            "---\n# comment line\nid: a-1  # trailing comment\nfoo: 'it''s'\nbar: \"x \\\"y\\\"\"\nlist:\n  - one\n  - \"two, three\"\n\nempty:\n---\nbody\n",
            "---\r\nid: crlf-note\r\ntags: [a, b]\r\n---\r\n# CRLF\r\n\r\nline\r\n",
            "no frontmatter at all\n",
            "---\nunclosed: yes\nbody without a closing line\n",
            "\u{FEFF}---\nid: bom-note\n---\nbody",
        ]
        for t in texts {
            let (fm, body, offset) = Frontmatter.split(t)
            #expect((fm?.serialized() ?? "") + body == t)
            #expect(offset == (fm?.serialized().utf16.count ?? 0))
        }
    }

    @Test func readsTheSubset() {
        let (fm, body, _) = Frontmatter.split(specNote1())
        let f = try! #require(fm)
        #expect(f.isParsable)
        #expect(f.scalar("id") == "rwd-punch-k7x2")
        #expect(f.scalar("title") == "打卡頁 RWD 跑版紀錄")
        #expect(f.list("tags") == ["rwd", "punch"])
        #expect(f.list("projects") == ["~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend"])
        #expect(f.scalar("pinned") == "false")
        #expect(body.hasPrefix("# 打卡頁 RWD 跑版紀錄\n"))

        let (g, _, _) = Frontmatter.split("---\nfoo: 'it''s'\nbar: \"a \\\"q\\\" \\u4e2d\"\nlist:\n  - one\n  - \"two, three\"\nnull:\nc: v # note\n---\n")
        let h = try! #require(g)
        #expect(h.scalar("foo") == "it's")
        #expect(h.scalar("bar") == "a \"q\" 中")
        #expect(h.list("list") == ["one", "two, three"])
        #expect(h.scalar("null") == nil)
        #expect(h.list("null") == [])
        #expect(h.scalar("c") == "v")
    }

    @Test func singleKeyPatchChangesOnlyThatLine() {
        let original = specNote1()
        var (fm, body, _) = Frontmatter.split(original)
        fm!.set("ai", scalar: "append")
        let patched = fm!.serialized() + body
        let a = original.components(separatedBy: "\n"), b = patched.components(separatedBy: "\n")
        #expect(a.count == b.count)
        let diff = zip(a, b).filter { $0 != $1 }
        #expect(diff.count == 1)
        #expect(diff.first?.1 == "ai: append")

        // A new key goes right before the closing `---`.
        fm!.set("sent", scalar: "2026-10-15T10:02:00+08:00")
        let lines = fm!.serialized().components(separatedBy: "\n")
        #expect(lines[lines.count - 3] == "sent: 2026-10-15T10:02:00+08:00")
        #expect(lines[lines.count - 2] == "---")

        // Removing a key removes its line only.
        fm!.set("sent", scalar: nil)
        fm!.set("ai", scalar: "read")
        #expect(fm!.serialized() + body == original)
    }

    @Test func commentsUnknownKeysAndOrderKept() {
        let t = "---\n# keep me\nzeta: 1\nid: x-1\nalpha: [q]\n# and me\n---\nbody\n"
        var (fm, body, _) = Frontmatter.split(t)
        fm!.set("tags", list: ["a", "b c", "d,e"])
        fm!.set("alpha", list: ["q", "r"])
        #expect(fm!.serialized() + body == "---\n# keep me\nzeta: 1\nid: x-1\nalpha: [q, r]\n# and me\ntags: [a, b c, \"d,e\"]\n---\nbody\n")
        #expect(fm!.list("tags") == ["a", "b c", "d,e"])
    }

    @Test func blockListStaysBlock() {
        let t = "---\ntags:\n  - a\n  - b\nid: q-1\n---\n"
        var (fm, _, _) = Frontmatter.split(t)
        fm!.set("tags", list: ["a", "b", "c"])
        #expect(fm!.serialized() == "---\ntags:\n  - a\n  - b\n  - c\nid: q-1\n---\n")
    }

    @Test func crlfStaysCRLF() {
        let t = "---\r\nid: crlf-note\r\nkind: note\r\n---\r\n# CRLF\r\n"
        var (fm, body, _) = Frontmatter.split(t)
        #expect(fm!.lineEnding == .crlf)
        fm!.set("kind", scalar: "prompt")
        fm!.set("pinned", bool: true)
        #expect(fm!.serialized() + body == "---\r\nid: crlf-note\r\nkind: prompt\r\npinned: true\r\n---\r\n# CRLF\r\n")
    }

    @Test func quotesWhatYAMLWouldMisread() {
        var fm = Frontmatter()
        fm.set("title", scalar: "筆記: 第一章")
        fm.set("a", scalar: "true")
        fm.set("b", scalar: "2026")
        fm.set("c", scalar: "#tag")
        fm.set("d", scalar: "~/Project/x y")
        fm.set("e", scalar: "say \"hi\"")
        #expect(fm.serialized() == "---\ntitle: \"筆記: 第一章\"\na: \"true\"\nb: \"2026\"\nc: \"#tag\"\nd: ~/Project/x y\ne: say \"hi\"\n---\n")
        let (re, _, _) = Frontmatter.split(fm.serialized())
        #expect(re?.scalar("title") == "筆記: 第一章")
        #expect(re?.scalar("e") == "say \"hi\"")
    }

    @Test func unparsableIsRefusedAndUntouched() {
        let bad = [
            "---\nid: x-1\nnested:\n  key: value\n---\nbody\n",
            "---\nid: x-1\ntext: |\n  block\n---\n",
            "---\nid: x-1\nmap: {a: 1}\n---\n",
            "---\nid: x-1\nid: x-2\n---\n",
            "---\nid: x-1\ntitle: \"unterminated\n---\n",
        ]
        for t in bad {
            var (fm, body, _) = Frontmatter.split(t)
            #expect(fm != nil)
            #expect(fm?.isParsable == false)
            fm!.set("ai", scalar: "append")
            #expect(fm!.serialized() + body == t)
        }
    }
}
