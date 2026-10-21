import AppKit
import Testing
@testable import CoddTextKit

@Suite("MarkdownRender", .serialized)
@MainActor
struct RenderTests {
    let style = MarkdownEditorStyle.notebook

    @Test func headingsListsAndMarksForCards() {
        let rendered = MarkdownRender.attributedPreview(MarkdownSamples.n1, style: style, maxLines: nil)
        let text = rendered.string
        // Syntax removed, structure kept.
        #expect(text.hasPrefix("打卡頁 RWD 跑版紀錄\n\n問題\n"))
        #expect(text.contains("▪ 影響頁面：/punch（打卡）與 /punch/history（打卡紀錄表格）"))
        #expect(text.contains("▪ Safari 底部工具列展開時才會完全蓋住"))
        #expect(text.contains("[圖片] 截圖 2026-10-15 09:32 · iPhone SE"))
        #expect(!text.contains("codd-annotations"))
        #expect(!text.contains("\"items\""))
        #expect(text.contains("[x] 先重現（Chrome DevTools 375 寬）"))
        #expect(text.contains("@media (max-width: 640px) {"))
        #expect(!text.contains("```"))
        #expect(!text.contains("**"))
        #expect(!text.hasSuffix("\n"))
        // Fonts and colors as the editor's.
        let ns = text as NSString
        let title = rendered.attribute(.font, at: ns.range(of: "RWD").location, effectiveRange: nil) as? NSFont
        #expect(title == style.titleFont)
        let h2 = ns.range(of: "問題")
        #expect(rendered.attribute(.foregroundColor, at: h2.location, effectiveRange: nil) as? NSColor == style.heading)
        #expect((rendered.attribute(.font, at: ns.range(of: "想請 AI").location + 3, effectiveRange: nil) as? NSFont)?.pointSize
            == style.heading2Font.pointSize)
        let bullet = ns.range(of: "▪")
        #expect(rendered.attribute(.foregroundColor, at: bullet.location, effectiveRange: nil) as? NSColor == style.bullet)
        let bold = ns.range(of: "Safari")
        #expect(rendered.attribute(.foregroundColor, at: bold.location, effectiveRange: nil) as? NSColor == style.strong)
        let code = ns.range(of: "/punch/history")
        #expect(rendered.attribute(.foregroundColor, at: code.location, effectiveRange: nil) as? NSColor == style.inlineCodeText)
        let keyword = ns.range(of: "@media")
        #expect(rendered.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? NSColor == style.codeKeyword)
        let done = ns.range(of: "先重現")
        #expect(rendered.attribute(.strikethroughStyle, at: done.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }

    @Test func maxLinesTruncates() {
        let rendered = MarkdownRender.attributedPreview("# 標題\n\n第一段\n第二段\n第三段", style: style, maxLines: 3)
        #expect(rendered.string == "標題\n\n第一段…")
        let all = MarkdownRender.attributedPreview("a\n\n\n\nb", style: style, maxLines: nil)
        #expect(all.string == "a\n\nb", "blank runs collapse")
        #expect(MarkdownRender.attributedPreview("", style: style, maxLines: 2).string == "")
    }

    @Test func noteRefsAndLinksKeepTheirText() {
        let rendered = MarkdownRender.attributedPreview("見 [說明](https://x.y) 與 codd://note/ab-c", style: style, maxLines: nil)
        #expect(rendered.string == "見 說明 與 codd://note/ab-c")
        let ns = rendered.string as NSString
        #expect(rendered.attribute(.foregroundColor, at: ns.range(of: "說明").location, effectiveRange: nil) as? NSColor == style.link)
        #expect(rendered.attribute(.foregroundColor, at: ns.range(of: "codd://").location, effectiveRange: nil) as? NSColor == style.chipText)
        // No editor-only box padding in a card: only the .01em tracking.
        let tracking = style.bodyTracking * style.bodyFont.pointSize
        #expect(rendered.attribute(.kern, at: ns.range(of: "與").location - 1, effectiveRange: nil) as? CGFloat == tracking)
        #expect(rendered.attribute(.coddChip, at: ns.range(of: "codd://").location, effectiveRange: nil) == nil)
    }
}

@Suite("Code highlighter")
struct HighlighterTests {
    private func tokens(_ code: String, _ language: String) -> [(String, MarkdownCodeHighlighter.Token)] {
        MarkdownCodeHighlighter.spans(code: code, language: language).map { ((code as NSString).substring(with: $0.0), $0.1) }
    }

    private func has(_ list: [(String, MarkdownCodeHighlighter.Token)], _ text: String, _ token: MarkdownCodeHighlighter.Token) -> Bool {
        list.contains { $0.0 == text && $0.1 == token }
    }

    @Test func cssAsTheArtboard() {
        let code = "@media (max-width: 640px) {\n  .punch-table { display: block; }\n}\n"
        let list = tokens(code, "css")
        #expect(has(list, "@media", .keyword))
        #expect(has(list, "640px", .number))
        #expect(has(list, "{", .punctuation))
        #expect(has(list, "}", .punctuation))
        #expect(has(list, "display", .keyword))
        #expect(has(list, "block", .string))
        // Selectors and the media feature stay plain (cream).
        #expect(!list.contains { $0.0 == "max-width" || $0.0 == "punch-table" })
        #expect(has(tokens("a { b: url(http://x/y); } /* c */", "css"), "/* c */", .comment))
    }

    @Test func javascriptAndTypescript() {
        let list = tokens("const a = 'x'; // note\nfunction f() { return 42 }\n`t ${a}`", "ts")
        #expect(has(list, "const", .keyword))
        #expect(has(list, "'x'", .string))
        #expect(has(list, "// note", .comment))
        #expect(has(list, "function", .keyword))
        #expect(has(list, "return", .keyword))
        #expect(has(list, "42", .number))
        #expect(has(list, "`t ${a}`", .string))
        #expect(!tokens("x", "javascript").contains { $0.1 == .keyword })
    }

    @Test func swiftPythonShellJSONHTML() {
        #expect(has(tokens("@MainActor final class A { let x = 1 }", "swift"), "@MainActor", .keyword))
        #expect(has(tokens("let s = \"a\"", "swift"), "\"a\"", .string))
        let python = tokens("def f():\n    # c\n    return \"\"\"doc\"\"\"", "python")
        #expect(has(python, "def", .keyword))
        #expect(has(python, "# c", .comment))
        #expect(has(python, "\"\"\"doc\"\"\"", .string))
        let shell = tokens("if [ -f a ]; then echo \"ok\"; fi # done\nurl=http://x#y", "sh")
        #expect(has(shell, "if", .keyword))
        #expect(has(shell, "# done", .comment))
        #expect(!shell.contains { $0.0.hasPrefix("#y") }, "a # inside a word is not a comment")
        let json = tokens("{\"key\": \"value\", \"n\": 1.5, \"b\": true}", "json")
        #expect(has(json, "\"key\"", .keyword))
        #expect(has(json, "\"value\"", .string))
        #expect(has(json, "1.5", .number))
        #expect(has(json, "true", .keyword))
        let html = tokens("<div class=\"a\"><!-- c --></div>", "html")
        #expect(has(html, "div", .keyword))
        #expect(has(html, "\"a\"", .string))
        #expect(has(html, "<!-- c -->", .comment))
    }

    @Test func unknownLanguagesGetNothingAndSpansAreSorted() {
        #expect(MarkdownCodeHighlighter.spans(code: "anything", language: "brainfuck").isEmpty)
        #expect(MarkdownCodeHighlighter.spans(code: "", language: "js").isEmpty)
        #expect(!MarkdownCodeHighlighter.supports("") && MarkdownCodeHighlighter.supports("JSON"))
        let spans = MarkdownCodeHighlighter.spans(code: "let a = 1; /* b */ \"c\" [d]", language: "js").map(\.0)
        for (a, b) in zip(spans, spans.dropFirst()) {
            #expect(NSMaxRange(a) <= b.location)
        }
    }
}
