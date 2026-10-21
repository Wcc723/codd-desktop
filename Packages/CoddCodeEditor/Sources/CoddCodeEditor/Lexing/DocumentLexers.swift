import Foundation

/// SQL (case-insensitive keywords): `--` and block comments, strings with `''` escapes across
/// lines, Postgres `$$` / `$tag$` bodies, quoted identifiers and parameters as properties, calls.
struct SQLLexer {
    enum Mode {
        static let code: UInt8 = 0
        static let comment: UInt8 = 1
        static let string: UInt8 = 2
        static let dollar: UInt8 = 3
    }

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        while i < end {
            switch s.mode {
            case Mode.comment:
                if let close = t.find("*/", from: i, end: end) {
                    out.add(i, close + 2, .comment)
                    s.mode = Mode.code
                    i = close + 2
                } else {
                    out.add(i, end, .comment)
                    i = end
                }
                continue
            case Mode.string:
                if let close = stringClose(t, from: i, end) {
                    out.add(i, close, .string)
                    s.mode = Mode.code
                    i = close
                } else {
                    out.add(i, end, .string)
                    i = end
                }
                continue
            case Mode.dollar:
                let close = Array(s.delimiter.utf16)
                var j = i
                var found: Int?
                while j + close.count <= end {
                    if (0 ..< close.count).allSatisfy({ t[j + $0] == close[$0] }) { found = j + close.count; break }
                    j += 1
                }
                if let found {
                    out.add(i, found, .string)
                    s.mode = Mode.code
                    s.delimiter = ""
                    i = found
                } else {
                    out.add(i, end, .string)
                    i = end
                }
                continue
            default:
                break
            }
            let c = t[i]
            if A.isSpace(c) { i = t.skipSpaces(i, end: end); continue }
            if c == A.minus, t[i + 1] == A.minus { out.add(i, end, .comment); return }
            if c == A.slash, t[i + 1] == A.star {
                out.add(i, i + 2, .comment)
                s.mode = Mode.comment
                i += 2
                continue
            }
            if c == A.squote {
                if let close = stringClose(t, from: i + 1, end) {
                    out.add(i, close, .string)
                    i = close
                } else {
                    out.add(i, end, .string)
                    s.mode = Mode.string
                    i = end
                }
                continue
            }
            if c == A.dquote || c == A.backtick || c == A.lbracket {
                let closeUnit = c == A.lbracket ? A.rbracket : c
                if let close = t.find(unit: closeUnit, from: i + 1, end: end), c != A.lbracket || close > i + 1 {
                    out.add(i, close + 1, .property)
                    i = close + 1
                    continue
                }
            }
            if c == A.dollar {
                var k = i + 1
                while k < end, A.isIdentPart(t[k]) { k += 1 }
                if t[k] == A.dollar {
                    let delimiter = t.text(i, k + 1)
                    out.add(i, k + 1, .string)
                    s.mode = Mode.dollar
                    s.delimiter = delimiter
                    i = k + 1
                    continue
                }
                if k > i + 1 {
                    out.add(i, k, .property)
                    i = k
                    continue
                }
            }
            if (c == A.at || c == A.colon || c == A.question), A.isIdentStart(t[i + 1]) || A.isDigit(t[i + 1]), t[i - 1] != A.colon {
                if c == A.colon, t[i + 1] == A.colon { out.add(i, i + 2, .punctuation); i += 2; continue }
                let nameEnd = t.identEnd(i + 1, end: end)
                out.add(i, nameEnd, .property)
                i = nameEnd
                continue
            }
            if A.isDigit(c) || (c == A.dot && A.isDigit(t[i + 1])) {
                let numberEnd = t.numberEnd(i, end: end)
                out.add(i, numberEnd, .number)
                i = numberEnd
                continue
            }
            if A.isIdentStart(c) {
                let k = t.identEnd(i, end: end)
                if Keywords.sql.contains(t.text(i, k).lowercased()) {
                    out.add(i, k, .keyword)
                } else if t[t.skipSpaces(k, end: end)] == A.lparen {
                    out.add(i, k, .function)
                }
                i = k
                continue
            }
            if c != A.dot { out.add(i, i + 1, .punctuation) }
            i += 1
        }
    }

    private func stringClose(_ t: LineText, from: Int, _ end: Int) -> Int? {
        var j = from
        while j < end {
            if t[j] == A.squote {
                if t[j + 1] == A.squote { j += 2; continue }
                return j + 1
            }
            j += 1
        }
        return nil
    }
}

/// Markdown: headings, quotes, list markers and tasks, rules, code spans, emphasis, links and
/// images, inline HTML, HTML comments, YAML front matter on the first line, and fenced code
/// blocks lexed in the fence's language (`ts`, `swift`, `bash`, …) with that lexer's own state.
struct MarkdownLexer {
    enum Mode {
        static let normal: UInt8 = 0
        static let fence: UInt8 = 1
        static let comment: UInt8 = 2
        static let frontMatter: UInt8 = 3
    }

    /// `flags` bit 0: past the first line (front matter only opens there).
    static let pastFirstLine: UInt8 = 1

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        let firstLine = s.flags & Self.pastFirstLine == 0
        s.flags |= Self.pastFirstLine
        switch s.mode {
        case Mode.fence:
            let start = t.skipSpaces(from, end: end)
            let marker = s.delimiter.utf16.first ?? A.backtick
            var k = start
            while k < end, t[k] == marker { k += 1 }
            if start - from <= 3, k - start >= s.delimiter.utf16.count, t.skipSpaces(k, end: end) >= end {
                out.add(start, k, .punctuation)
                s.mode = Mode.normal
                s.delimiter = ""
                s.embedded = nil
                return
            }
            if let embedded = s.embedded {
                var inner = embedded.state
                Lexers.lex(embedded.language, t, from: from, to: end, state: &inner, out: &out)
                s.embedded = EmbeddedLexState(embedded.language, inner)
            }
            return
        case Mode.frontMatter:
            if t.text(from, end).trimmingCharacters(in: .whitespaces) == "---" || t.text(from, end) == "..." {
                out.add(from, end, .punctuation)
                s.mode = Mode.normal
                s.embedded = nil
                return
            }
            var inner = s.embedded?.state ?? .initial
            YAMLLexer().lex(t, from: from, to: end, state: &inner, out: &out)
            s.embedded = EmbeddedLexState(.yaml, inner)
            return
        case Mode.comment:
            guard let close = t.find("-->", from: from, end: end) else {
                out.add(from, end, .comment)
                return
            }
            out.add(from, close + 3, .comment)
            s.mode = Mode.normal
            inline(t, close + 3, end, &s, &out)
            return
        default:
            break
        }
        if firstLine, t.text(from, end) == "---" {
            out.add(from, end, .punctuation)
            s.mode = Mode.frontMatter
            return
        }
        var i = t.skipSpaces(from, end: end)
        guard i < end else { return }
        let indent = i - from
        // Fences.
        if indent <= 3, t[i] == A.backtick || t[i] == A.tilde {
            let marker = t[i]
            var k = i
            while k < end, t[k] == marker { k += 1 }
            if k - i >= 3 {
                out.add(i, k, .punctuation)
                let infoStart = t.skipSpaces(k, end: end)
                var infoEnd = infoStart
                while infoEnd < end, !A.isSpace(t[infoEnd]), t[infoEnd] != A.lbrace { infoEnd += 1 }
                out.add(infoStart, end, .attribute)
                s.mode = Mode.fence
                s.delimiter = t.text(i, k)
                if let language = Self.fenceLanguage(t.text(infoStart, infoEnd)) {
                    s.embedded = EmbeddedLexState(language, .initial)
                }
                return
            }
        }
        // Headings.
        if t[i] == A.hash {
            var k = i
            while k < end, t[k] == A.hash { k += 1 }
            if k - i <= 6, k >= end || A.isSpace(t[k]) {
                out.add(i, end, .keyword)
                return
            }
        }
        // Rules (`---`, `***`, `___`).
        if t[i] == A.minus || t[i] == A.star || t[i] == A.underscore {
            let marker = t[i]
            var count = 0
            var k = i
            while k < end, t[k] == marker || A.isSpace(t[k]) {
                if t[k] == marker { count += 1 }
                k += 1
            }
            if count >= 3, k >= end {
                out.add(i, end, .punctuation)
                return
            }
        }
        // Block quotes.
        while t[i] == A.gt {
            out.add(i, i + 1, .punctuation)
            i = t.skipSpaces(i + 1, end: end)
        }
        // List markers and tasks.
        if (t[i] == A.minus || t[i] == A.star || t[i] == A.plus), A.isSpace(t[i + 1]) {
            out.add(i, i + 1, .punctuation)
            i = t.skipSpaces(i + 1, end: end)
        } else if A.isDigit(t[i]) {
            var k = i
            while k < end, A.isDigit(t[k]) { k += 1 }
            if t[k] == A.dot || t[k] == A.rparen, A.isSpace(t[k + 1]) || k + 1 >= end {
                out.add(i, k + 1, .punctuation)
                i = t.skipSpaces(k + 1, end: end)
            }
        }
        if t[i] == A.lbracket, t[i + 2] == A.rbracket, t[i + 1] == A.space || t[i + 1] == 0x78 || t[i + 1] == 0x58 {
            out.add(i, i + 3, .directive)
            i += 3
        }
        // Link reference definitions: `[id]: url`.
        if t[i] == A.lbracket, let close = t.find(unit: A.rbracket, from: i + 1, end: end), t[close + 1] == A.colon {
            out.add(i, i + 1, .punctuation)
            out.add(i + 1, close, .property)
            out.add(close, close + 2, .punctuation)
            out.add(t.skipSpaces(close + 2, end: end), end, .string)
            return
        }
        inline(t, i, end, &s, &out)
    }

    private func inline(_ t: LineText, _ start: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) {
        var i = start
        while i < end {
            let c = t[i]
            if c == A.backslash { i += 2; continue }
            if c == A.backtick {
                var ticks = 0
                while t[i + ticks] == A.backtick { ticks += 1 }
                var j = i + ticks
                var close: Int?
                while j < end {
                    if t[j] == A.backtick {
                        var run = 0
                        while t[j + run] == A.backtick { run += 1 }
                        if run == ticks { close = j + run; break }
                        j += run
                        continue
                    }
                    j += 1
                }
                guard let close else { i += ticks; continue }
                out.add(i, close, .string)
                i = close
                continue
            }
            if c == A.star || c == A.underscore {
                let double = t[i + 1] == c
                let width = double ? 2 : 1
                let openerOK = !A.isSpace(t[i + width]) && i + width < end && (c == A.star || !A.isIdentPart(t[i - 1]))
                if openerOK, let close = emphasisClose(t, from: i + width, marker: c, width: width, end) {
                    out.add(i, close, double ? .function : .attribute)
                    i = close
                    continue
                }
                i += width
                continue
            }
            if c == A.lbracket || (c == A.bang && t[i + 1] == A.lbracket) {
                let open = c == A.bang ? i + 1 : i
                if let close = t.find(unit: A.rbracket, from: open + 1, end: end), t[close + 1] == A.lparen,
                   let urlClose = t.find(unit: A.rparen, from: close + 2, end: end) {
                    out.add(i, open + 1, .punctuation)
                    out.add(open + 1, close, .property)
                    out.add(close, close + 2, .punctuation)
                    out.add(close + 2, urlClose, .string)
                    out.add(urlClose, urlClose + 1, .punctuation)
                    i = urlClose + 1
                    continue
                }
                i += 1
                continue
            }
            if c == A.lt {
                if t.has("<!--", at: i) {
                    if let close = t.find("-->", from: i + 4, end: end) {
                        out.add(i, close + 3, .comment)
                        i = close + 3
                    } else {
                        out.add(i, end, .comment)
                        s.mode = Mode.comment
                        return
                    }
                    continue
                }
                if let close = t.find(unit: A.gt, from: i + 1, end: end) {
                    let inner = t.text(i + 1, close)
                    if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                        out.add(i, close + 1, .string)
                        i = close + 1
                        continue
                    }
                    let nameStart = t[i + 1] == A.slash ? i + 2 : i + 1
                    if A.isAsciiLetter(t[nameStart]) {
                        let nameEnd = t.identEnd(nameStart, end: close, extra: A.minus)
                        out.add(i, nameStart, .punctuation)
                        out.add(nameStart, nameEnd, .tag)
                        out.add(close, close + 1, .punctuation)
                        i = close + 1
                        continue
                    }
                }
            }
            if c == A.pipe {
                out.add(i, i + 1, .punctuation)
            } else if c == A.amp {
                var k = i + 1
                while k < end, A.isIdentPart(t[k]) || t[k] == A.hash { k += 1 }
                if k > i + 1, t[k] == A.semicolon {
                    out.add(i, k + 1, .number)
                    i = k + 1
                    continue
                }
            }
            i += 1
        }
    }

    private func emphasisClose(_ t: LineText, from: Int, marker: UInt16, width: Int, _ end: Int) -> Int? {
        var j = from
        while j < end {
            if t[j] == A.backslash { j += 2; continue }
            if t[j] == marker, width == 1 || t[j + 1] == marker, !A.isSpace(t[j - 1]) {
                if width == 1, t[j + 1] == marker { j += 2; continue }
                if marker == A.underscore, A.isIdentPart(t[j + width]) { j += 1; continue }
                return j + width
            }
            j += 1
        }
        return nil
    }

    /// A fence's info word to a lexer.
    static func fenceLanguage(_ info: String) -> CodeLanguage? {
        switch info.lowercased() {
        case "js", "javascript", "mjs", "cjs", "node": .javascript
        case "ts", "typescript": .typescript
        case "jsx": .jsx
        case "tsx": .tsx
        case "json", "jsonc", "json5": .json
        case "css": .css
        case "scss", "sass", "less": .scss
        case "html", "htm": .html
        case "xml", "svg", "plist": .xml
        case "vue": .vue
        case "md", "markdown": .markdown
        case "swift": .swift
        case "py", "python", "python3": .python
        case "sh", "bash", "zsh", "shell", "console", "shellscript", "fish", "dockerfile", "makefile", "make": .shell
        case "yaml", "yml": .yaml
        case "toml", "ini": .toml
        case "go", "golang": .go
        case "rust", "rs": .rust
        case "c", "h": .c
        case "cpp", "c++", "cc", "hpp", "cxx": .cpp
        case "objc", "objective-c", "objectivec", "m": .objc
        case "java": .java
        case "kotlin", "kt": .kotlin
        case "ruby", "rb": .ruby
        case "php": .php
        case "sql", "postgres", "postgresql", "mysql", "sqlite": .sql
        default: nil
        }
    }
}
