import Foundation
import Testing
@testable import CoddCodeEditor

@Suite("Lexers")
struct LexerTests {
    // MARK: Vue SFC (the FileEditor artboard's punch.vue)

    static let vue = """
    <script setup lang="ts">
    import { computed } from 'vue'
    const isNarrow = computed(() => width.value < 640)
    </script>

    <template>
      <main class="punch-page">
        <span class="text-sm">{{ store.todayLabel }}</span>
        <template v-if="isNarrow">
          <PunchRecordCard v-for="r in records" :key="r.id" :record="r" />
        </template>
        <PunchButton :loading="store.pending" sticky @punch="store.punch" />
        <!-- 打卡按鈕 -->
      </main>
    </template>

    <style scoped>
    .punch-sticky {
      position: sticky;
      margin-bottom: 64px; /* 底部導覽列高度 */
      padding-bottom: calc(64px + env(safe-area-inset-bottom));
    }
    @media (max-width: 640px) {
      .punch-head { top: 0; }
    }
    </style>
    <style lang="scss">
    $gap: 8px; // 間距
    .row { &:hover { gap: $gap; } }
    </style>
    """

    @Test func vueTemplateDirectivesAndMustache() {
        let runs = Lex.runs(.vue, Self.vue)
        #expect(Lex.token(runs, line: 6, "main") == .tag)
        #expect(Lex.token(runs, line: 6, "class") == .attribute)
        #expect(Lex.token(runs, line: 6, "\"punch-page\"") == .string)
        #expect(Lex.token(runs, line: 7, "{{") == .directive)
        #expect(Lex.token(runs, line: 7, "}}") == .directive)
        #expect(Lex.tokenCovering(.vue, Self.vue, line: 7, "store.todayLabel") == .plain)
        #expect(Lex.token(runs, line: 8, "v-if") == .directive)
        #expect(Lex.token(runs, line: 8, "=\"") == .punctuation)
        #expect(Lex.tokenCovering(.vue, Self.vue, line: 8, "isNarrow") == .plain)
        #expect(Lex.token(runs, line: 9, "v-for") == .directive)
        #expect(Lex.token(runs, line: 9, "in") == .keyword)
        #expect(Lex.token(runs, line: 9, ":key") == .directive)
        #expect(Lex.token(runs, line: 9, "PunchRecordCard") == .tag)
        #expect(Lex.token(runs, line: 11, "sticky") == .attribute)
        #expect(Lex.token(runs, line: 11, "@punch") == .directive)
        #expect(Lex.tokenCovering(.vue, Self.vue, line: 12, "打卡按鈕") == .comment)
    }

    @Test func vueScriptRegionUsesTheLangLexer() {
        let runs = Lex.runs(.vue, Self.vue)
        #expect(Lex.token(runs, line: 0, "script") == .tag)
        #expect(Lex.token(runs, line: 0, "setup") == .attribute)
        #expect(Lex.token(runs, line: 0, "\"ts\"") == .string)
        #expect(Lex.token(runs, line: 1, "import") == .keyword)
        #expect(Lex.token(runs, line: 1, "'vue'") == .string)
        #expect(Lex.token(runs, line: 2, "const") == .keyword)
        #expect(Lex.token(runs, line: 2, "computed") == .function)
        #expect(Lex.token(runs, line: 2, "640") == .number)
        #expect(Lex.token(runs, line: 3, "script") == .tag)
        #expect(Lex.token(runs, line: 3, "</") == .punctuation)
        // TS keywords in a lang="ts" region.
        let ts = Lex.runs(.vue, "<script lang=\"ts\">\nlet n: number = 1\n</script>")
        #expect(Lex.token(ts, line: 1, "number") == .keyword)
    }

    @Test func vueStyleRegionsCSSAndSCSS() {
        let runs = Lex.runs(.vue, Self.vue)
        #expect(Lex.token(runs, line: 16, "scoped") == .attribute)
        #expect(Lex.token(runs, line: 17, ".punch-sticky") == .tag)
        #expect(Lex.token(runs, line: 18, "position") == .property)
        #expect(Lex.tokenCovering(.vue, Self.vue, line: 18, "sticky") == .plain)
        #expect(Lex.token(runs, line: 19, "64px") == .number)
        #expect(Lex.token(runs, line: 19, "/* 底部導覽列高度 */") == .comment)
        #expect(Lex.token(runs, line: 20, "calc") == .function)
        #expect(Lex.token(runs, line: 20, "env") == .function)
        #expect(Lex.token(runs, line: 22, "@media") == .keyword)
        #expect(Lex.token(runs, line: 22, "max-width") == .property)
        #expect(Lex.token(runs, line: 22, "640px") == .number)
        #expect(Lex.token(runs, line: 23, ".punch-head") == .tag)
        #expect(Lex.token(runs, line: 23, "top") == .property)
        #expect(Lex.token(runs, line: 25, "style") == .tag)
        #expect(Lex.token(runs, line: 27, "$gap") == .property)
        #expect(Lex.token(runs, line: 27, "// 間距") == .comment)
        #expect(Lex.token(runs, line: 28, ".row") == .tag)
        // Touching runs of one class merge: `&` + `:hover`.
        #expect(Lex.token(runs, line: 28, "&:hover") == .tag)
        #expect(Lex.token(runs, line: 28, "gap") == .property)
    }

    // MARK: JavaScript

    @Test func javascriptTemplateStringsNestAndSpanLines() {
        let text = """
        const a = `x ${b + `y ${c}`} z`
        const s = `first
        second ${count} third`
        const half = total / 2
        """
        let runs = Lex.runs(.javascript, text)
        #expect(Lex.token(runs, line: 0, "`x ") == .string)
        #expect(Lex.token(runs, line: 0, "${") == .punctuation)
        #expect(Lex.tokenCovering(.javascript, text, line: 0, "b") == .plain)
        #expect(Lex.token(runs, line: 0, "`y ") == .string)
        #expect(Lex.token(runs, line: 0, " z`") == .string)
        #expect(Lex.token(runs, line: 1, "`first") == .string)
        #expect(Lex.token(runs, line: 2, "second ") == .string)
        #expect(Lex.tokenCovering(.javascript, text, line: 2, "count") == .plain)
        #expect(Lex.token(runs, line: 2, " third`") == .string)
        #expect(Lex.token(runs, line: 3, "const") == .keyword)
        #expect(Lex.token(runs, line: 3, "/") == .punctuation)
        #expect(Lex.token(runs, line: 3, "2") == .number)
    }

    @Test func javascriptRegexLiteralsVersusDivision() {
        let text = """
        const re = /ab+c[/]d/gi;
        const ratio = a / b / c;
        if (ok) return /^\\d+$/.test(value)
        x = (y) / 2
        """
        let runs = Lex.runs(.javascript, text)
        #expect(Lex.token(runs, line: 0, "/ab+c[/]d/gi") == .string)
        #expect(!runs[1].contains(where: { $0.1 == .string }))
        #expect(Lex.token(runs, line: 2, "/^\\d+$/") == .string)
        #expect(Lex.token(runs, line: 2, "test") == .function)
        #expect(!runs[3].contains(where: { $0.1 == .string }))
    }

    @Test func javascriptCommentsKeywordsCallsAndJSX() {
        let text = """
        /* block
           comment */ function save(item) { return item?.default } // trailing
        const view = <Card title="打卡" onClick={() => go(1)}>{items.map(i => <li>{i}</li>)}</Card>
        """
        let runs = Lex.runs(.javascript, text)
        #expect(Lex.token(runs, line: 0, "/* block") == .comment)
        #expect(Lex.token(runs, line: 1, "   comment */") == .comment)
        #expect(Lex.token(runs, line: 1, "function") == .keyword)
        #expect(Lex.token(runs, line: 1, "save") == .function)
        #expect(Lex.tokenCovering(.javascript, text, line: 1, "default") == .plain)
        #expect(Lex.token(runs, line: 1, "// trailing") == .comment)
        #expect(Lex.token(runs, line: 2, "Card") == .tag)
        #expect(Lex.token(runs, line: 2, "title") == .attribute)
        #expect(Lex.token(runs, line: 2, "\"打卡\"") == .string)
        #expect(Lex.token(runs, line: 2, "go") == .function)
        #expect(Lex.token(runs, line: 2, "li") == .tag)
        #expect(Lex.token(runs, line: 2, "map") == .function)
    }

    // MARK: CSS / JSON

    @Test func css() {
        let text = """
        .a:hover > b, #id::before {
          color: #fff;
          margin: 0 auto !important;
          --gap: -1.5rem;
          background: url(data/x.png) no-repeat;
        }
        """
        let runs = Lex.runs(.css, text)
        #expect(Lex.token(runs, line: 0, ".a:hover") == .tag)
        #expect(Lex.token(runs, line: 0, ">") == .punctuation)
        #expect(Lex.token(runs, line: 0, "b") == .tag)
        #expect(Lex.token(runs, line: 0, "#id::before") == .tag)
        #expect(Lex.token(runs, line: 1, "color") == .property)
        #expect(Lex.token(runs, line: 1, "#fff") == .number)
        #expect(Lex.token(runs, line: 2, "0") == .number)
        #expect(Lex.tokenCovering(.css, text, line: 2, "auto") == .plain)
        #expect(Lex.token(runs, line: 2, "!important") == .keyword)
        #expect(Lex.token(runs, line: 3, "--gap") == .property)
        #expect(Lex.token(runs, line: 3, "-1.5rem") == .number)
        #expect(Lex.token(runs, line: 4, "url") == .function)
        #expect(Lex.token(runs, line: 4, "data/x.png") == .string)
    }

    @Test func json() {
        let text = """
        {
          "name": "orb-toolkit", // jsonc
          "private": true, "count": -12.5e3, "tags": ["a", null]
        }
        """
        let runs = Lex.runs(.json, text)
        #expect(Lex.token(runs, line: 1, "\"name\"") == .property)
        #expect(Lex.token(runs, line: 1, "\"orb-toolkit\"") == .string)
        #expect(Lex.token(runs, line: 1, "// jsonc") == .comment)
        #expect(Lex.token(runs, line: 2, "true") == .keyword)
        #expect(Lex.token(runs, line: 2, "-12.5e3") == .number)
        #expect(Lex.token(runs, line: 2, "\"a\"") == .string)
        #expect(Lex.token(runs, line: 2, "null") == .keyword)
    }

    // MARK: Swift / Python / shell / Markdown

    @Test func swiftMultilineAndRawStrings() {
        let text = """
        let message = \"\"\"
          打卡 "quoted" \\(count) // not a comment
          \"\"\"
        let raw = #"a "b" \\d"#
        @MainActor func save() { #if DEBUG
        /* outer /* nested */ still comment */ let n = 0x1F
        """
        let runs = Lex.runs(.swift, text)
        #expect(Lex.token(runs, line: 0, "let") == .keyword)
        #expect(Lex.token(runs, line: 0, "\"\"\"") == .string)
        #expect(runs[1].count == 1 && runs[1][0].1 == .string)
        #expect(Lex.token(runs, line: 2, "  \"\"\"") == .string)
        #expect(Lex.token(runs, line: 3, "#\"a \"b\" \\d\"#") == .string)
        #expect(Lex.token(runs, line: 4, "@MainActor") == .directive)
        #expect(Lex.token(runs, line: 4, "save") == .function)
        #expect(Lex.token(runs, line: 4, "#if") == .directive)
        #expect(Lex.token(runs, line: 5, "/* outer /* nested */ still comment */") == .comment)
        #expect(Lex.token(runs, line: 5, "0x1F") == .number)
    }

    @Test func pythonTripleQuotesDecoratorsAndPrefixes() {
        let text = """
        @dataclass(frozen=True)
        def export(rows, target) -> int:
            doc = \"\"\"first
            # not a comment
            end\"\"\" + suffix
            pattern = r'\\d+'  # comment
            return f"{len(rows)} rows"
        """
        let runs = Lex.runs(.python, text)
        #expect(Lex.token(runs, line: 0, "@dataclass") == .directive)
        #expect(Lex.token(runs, line: 0, "True") == .keyword)
        #expect(Lex.token(runs, line: 1, "def") == .keyword)
        #expect(Lex.token(runs, line: 1, "export") == .function)
        #expect(Lex.token(runs, line: 2, "\"\"\"first") == .string)
        #expect(runs[3].count == 1 && runs[3][0].1 == .string)
        #expect(Lex.token(runs, line: 4, "    end\"\"\"") == .string)
        #expect(Lex.tokenCovering(.python, text, line: 4, "suffix") == .plain)
        #expect(Lex.token(runs, line: 5, "r'\\d+'") == .string)
        #expect(Lex.token(runs, line: 5, "# comment") == .comment)
        #expect(Lex.token(runs, line: 6, "f\"{len(rows)} rows\"") == .string)
    }

    @Test func shellHeredocsVariablesAndComments() {
        let text = """
        export NAME="打卡 $USER" # set
        cat <<EOF > out.txt
        Hello $USER, ${HOME}
        EOF
        cat <<-'END'
        \tliteral $NOT_EXPANDED
        \tEND
        if [ -n "$1" ]; then echo done; fi
        """
        let runs = Lex.runs(.shell, text)
        #expect(Lex.token(runs, line: 0, "export") == .function)
        #expect(Lex.token(runs, line: 0, "NAME") == .property)
        #expect(Lex.token(runs, line: 0, "\"打卡 ") == .string)
        #expect(Lex.token(runs, line: 0, "$USER") == .property)
        #expect(Lex.token(runs, line: 0, "# set") == .comment)
        #expect(Lex.token(runs, line: 1, "<<") == .punctuation)
        #expect(Lex.token(runs, line: 1, "EOF") == .directive)
        #expect(Lex.token(runs, line: 2, "Hello ") == .string)
        #expect(Lex.token(runs, line: 2, "$USER") == .property)
        #expect(Lex.token(runs, line: 2, "${HOME}") == .property)
        #expect(Lex.token(runs, line: 3, "EOF") == .directive)
        #expect(Lex.token(runs, line: 4, "'END'") == .directive)
        #expect(runs[5].count == 1 && runs[5][0].1 == .string)
        #expect(Lex.token(runs, line: 6, "END") == .directive)
        #expect(Lex.token(runs, line: 7, "if") == .keyword)
        #expect(Lex.token(runs, line: 7, "then") == .keyword)
        #expect(Lex.token(runs, line: 7, "echo") == .function)
        #expect(Lex.token(runs, line: 7, "fi") == .keyword)
    }

    @Test func markdownBlocksInlineAndFences() {
        let text = """
        ---
        title: 打卡頁
        ---
        # 打卡頁 RWD 跑版紀錄
        - [x] 修好 `position: sticky` 與 **底部導覽列**
        > 見 [設計稿](https://example.com/rwd) 與 *註記*
        ```swift
        let n = 1 // 計數
        ```
        <!-- 隱藏 -->
        """
        let runs = Lex.runs(.markdown, text)
        #expect(Lex.token(runs, line: 0, "---") == .punctuation)
        #expect(Lex.token(runs, line: 1, "title") == .property)
        #expect(Lex.token(runs, line: 3, "# 打卡頁 RWD 跑版紀錄") == .keyword)
        #expect(Lex.token(runs, line: 4, "-") == .punctuation)
        #expect(Lex.token(runs, line: 4, "[x]") == .directive)
        #expect(Lex.token(runs, line: 4, "`position: sticky`") == .string)
        #expect(Lex.token(runs, line: 4, "**底部導覽列**") == .function)
        #expect(Lex.token(runs, line: 5, "設計稿") == .property)
        #expect(Lex.token(runs, line: 5, "https://example.com/rwd") == .string)
        #expect(Lex.token(runs, line: 5, "*註記*") == .attribute)
        #expect(Lex.token(runs, line: 6, "```") == .punctuation)
        #expect(Lex.token(runs, line: 7, "let") == .keyword)
        #expect(Lex.token(runs, line: 7, "// 計數") == .comment)
        #expect(Lex.token(runs, line: 8, "```") == .punctuation)
        #expect(Lex.token(runs, line: 9, "<!-- 隱藏 -->") == .comment)
    }

    // MARK: The other languages

    @Test(arguments: [
        (CodeLanguage.go, "func main() { s := `raw` // c", "func", SyntaxToken.keyword),
        (.rust, "fn main() { println!(\"x\"); let r = r#\"a\"#; }", "println!", .function),
        (.rust, "#[derive(Debug)] struct A<'a> { x: &'a str }", "#[derive(Debug)]", .directive),
        (.c, "#include <stdio.h>", "<stdio.h>", .string),
        (.cpp, "auto s = R\"(raw)\"; std::vector<int> v;", "R\"(raw)\"", .string),
        (.objc, "@interface Card : NSObject", "@interface", .keyword),
        (.java, "@Override public String name() { return \"x\"; }", "@Override", .directive),
        (.kotlin, "fun greet(name: String) = \"hi\"", "greet", .function),
        (.ruby, "def save(record) = puts :done # c", "save", .function),
        (.ruby, "@count = 1", "@count", .property),
        (.php, "<?php $name = 'x'; echo $name; ?>", "$name", .property),
        (.php, "<?php $name = 'x'; ?>", "<?php", .directive),
        (.sql, "SELECT id, count(*) FROM punch WHERE kind = 'in' -- c", "SELECT", .keyword),
        (.sql, "select * from \"Punch\"", "\"Punch\"", .property),
        (.yaml, "name: orb-toolkit # c", "name", .property),
        (.yaml, "- enabled: true", "true", .keyword),
        (.toml, "[package]", "package", .tag),
        (.toml, "version = \"0.1.0\"", "version", .property),
        (.html, "<a href=\"/x\">連結 &amp; 更多</a>", "&amp;", .number),
        (.xml, "<?xml version=\"1.0\"?><plist><![CDATA[x]]></plist>", "<![CDATA[x]]>", .string),
        (.scss, "@include respond(md) { gap: $gap; }", "respond", .function),
        (.tsx, "const el = <Button variant=\"x\" />", "Button", .tag),
        (.typescript, "interface A { n: number }", "interface", .keyword),
        (.jsx, "return <div className=\"a\">{x}</div>", "className", .attribute),
    ])
    func languageSmoke(language: CodeLanguage, line: String, needle: String, expected: SyntaxToken) {
        let runs = Lex.runs(language, line)
        #expect(Lex.token(runs, line: 0, needle) == expected, "\(language): \(runs[0])")
    }

    @Test func plainHasNoTokens() {
        #expect(Lex.runs(.plain, "let x = 1 // nothing").allSatisfy { $0.isEmpty })
    }

    /// Every lexer on hostile input: runs stay inside the line, sorted, disjoint, never plain.
    @Test(arguments: CodeLanguage.allCases)
    func runsAreWellFormed(language: CodeLanguage) {
        var generator = SeededGenerator(seed: 0xC0DD)
        let pieces = ["\"", "'", "`", "/*", "*/", "//", "#", "<", ">", "</", "{", "}", "${", "(", ")", "[", "]", "<!--", "-->",
                      "\"\"\"", "'''", "<<EOF", "EOF", "=begin", "=end", "```", "---", "\\", "@", "$", "x", "1.5e3", " ", "\t",
                      "中文", "\u{1F600}", "def", "fn", "let", ":", ";", "=", "|", "-", "+", "<?php", "?>", "<script>", "</script>",
                      "<style>", "</style>", "{{", "}}", "r#\"", "\"#"]
        var state = LexState.initial
        let highlighter = SyntaxHighlighter(language: language)
        for _ in 0 ..< 400 {
            let count = Int.random(in: 0 ... 12, using: &generator)
            let line = (0 ..< count).map { _ in pieces.randomElement(using: &generator)! }.joined()
            let result = highlighter.tokens(line: line, startState: state)
            let length = (line as NSString).length
            var end = 0
            for (range, token) in result.tokens {
                #expect(range.location >= end && range.length > 0 && NSMaxRange(range) <= length && token != .plain)
                end = NSMaxRange(range)
            }
            state = result.endState
        }
    }
}
