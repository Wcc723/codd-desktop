import Foundation
import Testing
@testable import CoddTextKit

@Suite("Block parser")
struct ParserTests {
    private func kinds(_ text: String) -> [MarkdownBlockKind] {
        MarkdownBlockParser.blocks(in: text).map(\.kind)
    }

    private func marks(_ text: String, block: Int = 0) -> [String] {
        let blocks = MarkdownBlockParser.blocks(in: text)
        return blocks[block].inlineMarks.map { (text as NSString).substring(with: $0) }
    }

    @Test func everyKind() {
        let text = """
        # Title
        ## Section
        ### Sub
        #### Minor
        paragraph line
        - bullet
          - nested
        * star
        1. first
        12) twelfth
        - [ ] open task
        - [x] done task
        > quote
        ---
        | a | b |
        |---|---|
        | 1 | 2 |

        ![alt text](assets/n/abc123.png)
        ```codd-annotations
        {"v":1}
        ```
        ```css
        a { b: c; }
        ```
        """
        #expect(kinds(text) == [
            .heading(level: 1), .heading(level: 2), .heading(level: 3), .heading(level: 4), .paragraph,
            .bullet(indent: 0), .bullet(indent: 1), .bullet(indent: 0), .ordered(indent: 0, number: 1), .ordered(indent: 0, number: 12),
            .task(indent: 0, done: false), .task(indent: 0, done: true), .quote, .rule, .table, .blank,
            .image(alt: "alt text", path: "assets/n/abc123.png"), .hiddenFence(info: "codd-annotations"), .codeFence(info: "css"),
        ])
    }

    @Test func blocksTileTheTextInWholeLines() {
        let text = MarkdownSamples.n1
        let blocks = MarkdownBlockParser.blocks(in: text)
        var expected = 0
        for block in blocks {
            #expect(block.range.location == expected)
            expected = NSMaxRange(block.range)
        }
        #expect(expected == (text as NSString).length)
        #expect(MarkdownBlockParser.blocks(in: "").isEmpty)
        #expect(kinds("\n") == [.blank])
        #expect(kinds("a\r\nb\rc") == [.paragraph, .paragraph, .paragraph])
        #expect(MarkdownBlockParser.blocks(in: "a\r\nb").first?.range.length == 3)
    }

    @Test func frontmatterOnlyAtTheStart() {
        #expect(kinds("---\nid: x\n---\n# T") == [.frontmatterLike, .heading(level: 1)])
        #expect(kinds("# T\n---\nid: x\n---") == [.heading(level: 1), .rule, .paragraph, .rule])
        // Unclosed: just a rule.
        #expect(kinds("---\nid: x") == [.rule, .paragraph])
    }

    @Test func annotationFenceIsHiddenOnlyRightAfterAnImage() {
        let after = "![a](p.png)\n```codd-annotations\n{}\n```\n"
        #expect(kinds(after) == [.image(alt: "a", path: "p.png"), .hiddenFence(info: "codd-annotations")])
        let alone = "text\n```codd-annotations\n{}\n```\n"
        #expect(kinds(alone) == [.paragraph, .codeFence(info: "codd-annotations")])
        let gap = "![a](p.png)\n\n```codd-annotations\n{}\n```\n"
        #expect(kinds(gap) == [.image(alt: "a", path: "p.png"), .blank, .codeFence(info: "codd-annotations")])
        // Configurable set.
        let custom = MarkdownBlockParser.blocks(in: "![a](p.png)\n```x-meta\n```\n", hiddenFenceInfoStrings: ["x-meta"]).map(\.kind)
        #expect(custom == [.image(alt: "a", path: "p.png"), .hiddenFence(info: "x-meta")])
    }

    @Test func fencesSwallowUntilTheirCloseOrTheEnd() {
        let text = "```js\n# not a heading\n- not a list\n```\nafter"
        #expect(kinds(text) == [.codeFence(info: "js"), .paragraph])
        #expect(kinds("~~~\na\n~~~~\nb") == [.codeFence(info: ""), .paragraph])
        #expect(kinds("```\nopen to the end\n# still code") == [.codeFence(info: "")])
        let blocks = MarkdownBlockParser.blocks(in: text)
        #expect(blocks[0].inlineMarks.map { (text as NSString).substring(with: $0) } == ["```js\n", "```\n"])
    }

    @Test func inlineMarks() {
        #expect(marks("## Hello **bold** and `code`") == ["## ", "**", "**", "`", "`"])
        #expect(marks("plain *em* _em_ ***both*** ~~gone~~") == ["*", "*", "_", "_", "***", "***", "~~", "~~"])
        #expect(marks("snake_case_name and 中_文_字") == [])
        #expect(marks("see [the docs](https://example.com/a(b)) now") == ["[", "](https://example.com/a(b))"])
        #expect(marks("- **Safari 底部工具列展開時**才會") == ["- ", "**", "**"])
        #expect(marks("- [x] done `x`") == ["- ", "`", "`"])
        #expect(marks("  1. nested") == ["  "])
        #expect(marks("> quoted **b**") == ["> ", "**", "**"])
        #expect(marks("escaped \\*not\\*") == ["\\", "\\"])
        #expect(marks("`a **not bold** b`") == ["`", "`"])
        #expect(marks("## Title ##") == ["## ", " ##"])
        #expect(marks("![alt](p.png)") == ["![", "](p.png)"])
        // Note refs and bare URLs are chips / links, not marks.
        #expect(marks("ref codd://note/rwd-punch-k7x2 and https://x.y/z") == [])
    }

    @Test func listIndentAndTaskShapes() {
        #expect(kinds("    - deep") == [.bullet(indent: 2)])
        #expect(kinds("\t- tab") == [.bullet(indent: 2)])
        #expect(kinds("- [X] upper") == [.task(indent: 0, done: true)])
        #expect(kinds("- [ ]") == [.task(indent: 0, done: false)])
        #expect(kinds("- [ ]x") == [.bullet(indent: 0)])
        #expect(kinds("-no space") == [.paragraph])
        #expect(kinds("- ") == [.bullet(indent: 0)])
        #expect(kinds("#hashtag") == [.paragraph])
        #expect(kinds("* * *") == [.rule])
    }

    // MARK: Incremental reparse

    private static let alphabet: [String] = [
        "a", "注", " ", "\n", "\n\n", "#", "## ", "- ", "- [ ] ", "1. ", "> ", "```", "```css\n", "```codd-annotations\n",
        "![x](a.png)\n", "**", "*", "`", "|", "---\n", "[l](u)", "codd://note/ab-c", "~~", "\\", "_", "\r\n",
    ]

    private static func randomEdit(of text: NSString, using generator: inout SeededGenerator) -> (NSRange, String) {
        let length = text.length
        let location = length == 0 ? 0 : Int.random(in: 0 ... length, using: &generator)
        var deleteLength = 0
        if length > 0, Bool.random(using: &generator) {
            deleteLength = Int.random(in: 0 ... min(12, length - location), using: &generator)
        }
        var range = NSRange(location: location, length: deleteLength)
        // Never split a CRLF or a surrogate pair (the editor never does).
        range = text.rangeOfComposedCharacterSequences(for: range)
        let count = Int.random(in: 0 ... 3, using: &generator)
        let insert = (0 ..< count).map { _ in alphabet.randomElement(using: &generator)! }.joined()
        return (range, insert)
    }

    @Test(arguments: [UInt64(1), 7, 42, 2026, 98_765])
    func incrementalReparseEqualsAFullParse(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        var text = MarkdownSamples.n1 as NSString
        var blocks = MarkdownBlockParser.blocks(in: text as String)
        var inPlace = blocks
        for step in 0 ..< 300 {
            let (range, insert) = Self.randomEdit(of: text, using: &generator)
            let next = text.replacingCharacters(in: range, with: insert) as NSString
            let edited = NSRange(location: range.location, length: (insert as NSString).length)
            let delta = (insert as NSString).length - range.length
            blocks = MarkdownBlockParser.reparse(blocks, text: next as String, edited: edited, delta: delta)
            MarkdownBlockParser.applyEdit(&inPlace, text: next, edited: edited, delta: delta,
                                          hidden: MarkdownBlockParser.defaultHiddenFenceInfoStrings)
            let full = MarkdownBlockParser.blocks(in: next as String)
            #expect(blocks == full, "seed \(seed) step \(step): \(range) → \(insert.debugDescription)")
            #expect(inPlace == full, "in place, seed \(seed) step \(step)")
            if blocks != full || inPlace != full { return }
            text = next
        }
    }

    @Test func reparseOfAFenceOpeningRestylesWhatItSwallows() {
        let text = "a\n- b\n## c\n" as NSString
        var blocks = MarkdownBlockParser.blocks(in: text as String)
        let next = text.replacingCharacters(in: NSRange(location: 0, length: 0), with: "```\n") as NSString
        let changed = MarkdownBlockParser.applyEdit(&blocks, text: next, edited: NSRange(location: 0, length: 4), delta: 4,
                                                    hidden: MarkdownBlockParser.defaultHiddenFenceInfoStrings)
        #expect(blocks.map(\.kind) == [.codeFence(info: "")])
        #expect(changed == 0 ..< 1)
        // Typing in a paragraph reparses only around it.
        let long = (0 ..< 200).map { "line \($0)" }.joined(separator: "\n") as NSString
        var many = MarkdownBlockParser.blocks(in: long as String)
        let at = long.range(of: "line 100").location + 2
        let typed = long.replacingCharacters(in: NSRange(location: at, length: 0), with: "x") as NSString
        let touched = MarkdownBlockParser.applyEdit(&many, text: typed, edited: NSRange(location: at, length: 1), delta: 1,
                                                    hidden: MarkdownBlockParser.defaultHiddenFenceInfoStrings)
        #expect(touched.count <= 2)
        #expect(many == MarkdownBlockParser.blocks(in: typed as String))
    }
}
