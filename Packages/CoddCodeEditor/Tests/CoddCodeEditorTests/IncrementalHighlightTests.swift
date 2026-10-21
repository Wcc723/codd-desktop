import AppKit
import Testing
@testable import CoddCodeEditor

/// After any sequence of edits the cached line-start states (and the colors on screen) equal a
/// fresh lex of the whole text, while each edit re-lexes only until the states converge.
@Suite("Incremental highlighting", .serialized)
@MainActor
struct IncrementalHighlightTests {
    static let seedText = """
    <script setup lang="ts">
    const a = `x ${b} y`
    /* comment */ const re = /a+/g
    </script>
    <template>
      <div :class="{ on: active }" @click="go(1)">{{ label }}</div>
    </template>
    <style scoped>
    .a { color: red; } /* c */
    @media (max-width: 1px) { .b { top: 0 } }
    </style>
    """

    static let snippets = ["\n", "\"", "'", "`", "/*", "*/", "//", "${", "}", "{", "<", ">", "</script>", "<script>",
                           "<style>", "</style>", "<!--", "-->", "x", " ", "{{", "}}", "\n\n", "abc\ndef", "中文", "\"\"\""]

    private func fullStates(_ text: NSString, _ language: CodeLanguage) -> [LexState] {
        var lines = LineIndex()
        lines.rebuild(text)
        let model = HighlightModel(highlighter: SyntaxHighlighter(language: language))
        model.reset(lineCount: lines.count)
        model.ensure(window: 0 ..< lines.count, text: text, lines: lines) { _, _ in }
        return model.states
    }

    @Test(arguments: [(CodeLanguage.vue, UInt64(1)), (.javascript, 2), (.python, 3), (.css, 4), (.markdown, 5), (.shell, 6)])
    func modelMatchesAFullLexAfterRandomEdits(language: CodeLanguage, seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let text = NSMutableString(string: Self.seedText + "\n" + Self.seedText)
        var lines = LineIndex()
        lines.rebuild(text)
        let model = HighlightModel(highlighter: SyntaxHighlighter(language: language))
        model.reset(lineCount: lines.count)
        model.ensure(window: 0 ..< 8, text: text, lines: lines) { _, _ in }
        for step in 0 ..< 300 {
            let location = Int.random(in: 0 ... text.length, using: &generator)
            let maxDelete = min(6, text.length - location)
            let deleteLength = Int.random(in: 0 ... maxDelete, using: &generator)
            let insert = Bool.random(using: &generator) ? Self.snippets.randomElement(using: &generator)! : ""
            text.replaceCharacters(in: NSRange(location: location, length: deleteLength), with: insert)
            let edit = lines.apply(editedRange: NSRange(location: location, length: (insert as NSString).length),
                                   delta: (insert as NSString).length - deleteLength, text: text)
            model.edit(edit)
            // A random window, like a scrolled view.
            let start = Int.random(in: 0 ..< lines.count, using: &generator)
            model.ensure(window: start ..< min(lines.count, start + 10), text: text, lines: lines) { _, _ in }
            if step % 25 == 0 || step == 299 {
                var fresh = LineIndex()
                fresh.rebuild(text)
                #expect(fresh.starts == lines.starts, "line index diverged at step \(step)")
                model.ensure(window: 0 ..< lines.count, text: text, lines: lines) { _, _ in }
                #expect(Array(model.states.prefix(lines.count)) == fullStates(text, language), "\(language) states diverged at step \(step)")
            }
        }
    }

    @Test func anEditInsideALineReLexesOnlyUntilTheStatesConverge() {
        let text = NSMutableString(string: (0 ..< 400).map { "const value\($0) = compute(\($0)) // note" }.joined(separator: "\n"))
        var lines = LineIndex()
        lines.rebuild(text)
        let model = HighlightModel(highlighter: SyntaxHighlighter(language: .javascript))
        model.reset(lineCount: lines.count)
        model.ensure(window: 0 ..< 400, text: text, lines: lines) { _, _ in }
        model.lexedLineCount = 0
        let location = lines.start(of: 200) + 6
        text.replaceCharacters(in: NSRange(location: location, length: 0), with: "x")
        model.edit(lines.apply(editedRange: NSRange(location: location, length: 1), delta: 1, text: text))
        var applied: [Int] = []
        model.ensure(window: 150 ..< 260, text: text, lines: lines) { line, _ in applied.append(line) }
        #expect(applied == [200])
        #expect(model.lexedLineCount <= 3)
        // Opening a block comment changes every following state: lexing runs to the window's end only.
        model.lexedLineCount = 0
        let open = lines.start(of: 210)
        text.replaceCharacters(in: NSRange(location: open, length: 0), with: "/*")
        model.edit(lines.apply(editedRange: NSRange(location: open, length: 2), delta: 2, text: text))
        model.ensure(window: 150 ..< 260, text: text, lines: lines) { _, _ in }
        #expect(model.lexedLineCount < 70)
        #expect(model.validCount == 260)
        model.ensure(window: 0 ..< lines.count, text: text, lines: lines) { _, _ in }
        #expect(Array(model.states.prefix(lines.count)) == fullStates(text, .javascript))
    }

    /// Through the view: random edits in the text view, then every line's temporary colors equal
    /// a fresh lex (states, splicing and the layout manager's attribute shifting together).
    @Test func viewColorsMatchAFullLexAfterRandomEdits() {
        let harness = EditorHarness(width: 900, height: 2400, text: Self.seedText, language: .vue)
        defer { harness.tearDown() }
        var generator = SeededGenerator(seed: 0xE017)
        for _ in 0 ..< 120 {
            let length = (harness.textView.string as NSString).length
            let location = Int.random(in: 0 ... length, using: &generator)
            let deleteLength = Int.random(in: 0 ... min(4, length - location), using: &generator)
            let insert = Self.snippets.randomElement(using: &generator)!
            let range = NSRange(location: location, length: deleteLength)
            if harness.textView.shouldChangeText(in: range, replacementString: insert) {
                harness.textView.textStorage?.replaceCharacters(in: range, with: insert)
                harness.textView.didChangeText()
            }
        }
        harness.settle()
        let text = harness.textView.string
        let lines = text.components(separatedBy: "\n")
        let expected = SyntaxHighlighter(language: .vue).tokenize(text)
        let style = harness.editor.style
        var offset = 0
        for (index, line) in lines.enumerated() {
            let length = (line as NSString).length
            var position = 0
            for (range, token) in expected[index] {
                for plain in position ..< range.location {
                    #expect(harness.color(at: offset + plain) == nil, "line \(index) col \(plain) should be plain")
                }
                #expect(harness.color(at: offset + range.location) == style.color(for: token), "line \(index) col \(range.location) \(token)")
                position = NSMaxRange(range)
            }
            for plain in position ..< length {
                #expect(harness.color(at: offset + plain) == nil, "line \(index) col \(plain) should be plain")
            }
            offset += length + 1
        }
    }
}
