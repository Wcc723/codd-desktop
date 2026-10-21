import Foundation

/// HTML, XML, Vue single-file components and the HTML around PHP code. Tags, attributes, quoted
/// values, comments, CDATA, declarations and entities; `<script>` / `<style>` contents (and PHP
/// `<?php … ?>`) go to the embedded language's lexer, whose state rides in `LexState.embedded`
/// until the closing tag. Vue adds directive attributes (`v-if`, `:key`, `@punch`, `#slot`) in the
/// directive color with their values lexed as JavaScript, and `{{ }}` interpolations; `lang="ts"`
/// / `lang="scss"` pick the region's language.
struct MarkupLexer {
    enum Flavor { case html, xml, vue, php }

    let flavor: Flavor

    enum Mode {
        static let content: UInt8 = 0
        static let comment: UInt8 = 1
        static let tag: UInt8 = 2
        static let value: UInt8 = 3
        static let cdata: UInt8 = 4
        static let declaration: UInt8 = 5
        static let mustache: UInt8 = 6
        static let embedded: UInt8 = 7
        static let php: UInt8 = 8
    }

    /// `flags`: reading a closing tag; the current attribute is a Vue directive (its value is
    /// JavaScript); the current attribute is `lang` / `type` (its value picks the region language).
    static let closing: UInt8 = 1
    static let directive: UInt8 = 2
    static let languageAttribute: UInt8 = 4

    private static let javascript = CFamilyLexer(config: .javascript)
    private static let phpCode = CFamilyLexer(config: .php)

    private var embeds: Bool { flavor != .xml }

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        while i < end {
            let before = i
            switch s.mode {
            case Mode.comment:
                i = closeRun(t, i, end, "-->", .comment, &s, &out)
            case Mode.cdata:
                i = closeRun(t, i, end, "]]>", .string, &s, &out)
            case Mode.declaration:
                if let close = t.find(unit: A.gt, from: i, end: end) {
                    out.add(i, close + 1, .directive)
                    s.mode = Mode.content
                    i = close + 1
                } else {
                    out.add(i, end, .directive)
                    i = end
                }
            case Mode.tag: i = tag(t, i, end, &s, &out)
            case Mode.value: i = continueValue(t, i, end, &s, &out)
            case Mode.mustache: i = mustache(t, i, end, &s, &out)
            case Mode.embedded: i = embedded(t, i, end, &s, &out)
            case Mode.php: i = php(t, i, end, &s, &out)
            default: i = content(t, i, end, &s, &out)
            }
            if i <= before { i = before + 1 }
        }
    }

    private func closeRun(_ t: LineText, _ i: Int, _ end: Int, _ close: StaticString, _ token: SyntaxToken,
                          _ s: inout LexState, _ out: inout TokenSink) -> Int {
        if let found = t.find(close, from: i, end: end) {
            let stop = found + close.utf8CodeUnitCount
            out.add(i, stop, token)
            s.mode = Mode.content
            return stop
        }
        out.add(i, end, token)
        return end
    }

    // MARK: Content

    private func content(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        var j = i
        while j < end {
            let c = t[j]
            if c == A.lt || c == A.amp || (flavor == .vue && c == A.lbrace && t[j + 1] == A.lbrace) { break }
            j += 1
        }
        guard j < end else { return end }
        let c = t[j]
        if c == A.amp {
            var k = j + 1
            while k < end, A.isIdentPart(t[k]) || t[k] == A.hash { k += 1 }
            if k > j + 1, t[k] == A.semicolon {
                out.add(j, k + 1, .number)
                return k + 1
            }
            return j + 1
        }
        if c == A.lbrace {
            out.add(j, j + 2, .directive)
            s.mode = Mode.mustache
            return j + 2
        }
        // `<`
        if t.has("<!--", at: j) {
            s.mode = Mode.comment
            out.add(j, j + 4, .comment)
            return closeRun(t, j + 4, end, "-->", .comment, &s, &out)
        }
        if t.has("<![CDATA[", at: j) {
            s.mode = Mode.cdata
            out.add(j, j + 9, .string)
            return closeRun(t, j + 9, end, "]]>", .string, &s, &out)
        }
        if t[j + 1] == A.bang {
            s.mode = Mode.declaration
            return j
        }
        if t[j + 1] == A.question {
            if flavor == .php, !t.hasIgnoringCase("<?xml", at: j) {
                let openerEnd = t.hasIgnoringCase("<?php", at: j) ? j + 5 : (t[j + 2] == A.equals ? j + 3 : j + 2)
                out.add(j, openerEnd, .directive)
                s.mode = Mode.php
                s.embedded = EmbeddedLexState(.php, .initial)
                return openerEnd
            }
            if let close = t.find("?>", from: j + 2, end: end) {
                out.add(j, close + 2, .directive)
                return close + 2
            }
            out.add(j, end, .directive)
            s.mode = Mode.declaration
            return end
        }
        if t[j + 1] == A.slash {
            out.add(j, j + 2, .punctuation)
            let nameEnd = tagNameEnd(t, j + 2, end)
            out.add(j + 2, nameEnd, .tag)
            s.mode = Mode.tag
            s.flags = Self.closing
            s.delimiter = ""
            return nameEnd
        }
        if A.isIdentStart(t[j + 1]) {
            out.add(j, j + 1, .punctuation)
            let nameEnd = tagNameEnd(t, j + 1, end)
            out.add(j + 1, nameEnd, .tag)
            s.mode = Mode.tag
            s.flags = 0
            s.depth = 0
            s.delimiter = t.text(j + 1, nameEnd).lowercased()
            return nameEnd
        }
        return j + 1
    }

    private func tagNameEnd(_ t: LineText, _ from: Int, _ end: Int) -> Int {
        var k = from
        while k < end, A.isIdentPart(t[k]) || t[k] == A.minus || t[k] == A.colon || t[k] == A.dot { k += 1 }
        return k
    }

    // MARK: Tags

    private func tag(_ t: LineText, _ start: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let i = t.skipSpaces(start, end: end)
        guard i < end else { return end }
        let c = t[i]
        if c == A.slash, t[i + 1] == A.gt {
            out.add(i, i + 2, .punctuation)
            endTag(&s, enterRegion: false)
            return i + 2
        }
        if c == A.gt {
            out.add(i, i + 1, .punctuation)
            endTag(&s, enterRegion: true)
            return i + 1
        }
        if c == A.equals {
            out.add(i, i + 1, .punctuation)
            return i + 1
        }
        if c == A.dquote || c == A.squote {
            if s.flags & Self.directive != 0 {
                out.add(i, i + 1, .punctuation)
                s.mode = Mode.value
                s.aux = c
                return i + 1
            }
            if let close = t.stringEnd(i, quote: c, end: end, escapes: false) {
                out.add(i, close, .string)
                if s.flags & Self.languageAttribute != 0 { s.depth = Self.code(for: t.text(i + 1, close - 1)) }
                s.flags &= ~(Self.directive | Self.languageAttribute)
                return close
            }
            out.add(i, end, .string)
            s.mode = Mode.value
            s.aux = c
            return end
        }
        // An attribute name, or an unquoted value after `=`.
        var k = i
        while k < end {
            let d = t[k]
            if A.isSpace(d) || d == A.equals || d == A.gt || d == A.dquote || d == A.squote || (d == A.slash && t[k + 1] == A.gt) { break }
            k += 1
        }
        if k == i { return i + 1 }
        var previous = i - 1
        while previous >= 0, A.isSpace(t[previous]) { previous -= 1 }
        if previous >= 0, t[previous] == A.equals {
            out.add(i, k, .string)
            if s.flags & Self.languageAttribute != 0 { s.depth = Self.code(for: t.text(i, k)) }
            s.flags &= ~(Self.directive | Self.languageAttribute)
            return k
        }
        let name = t.text(i, k)
        let isDirective = flavor == .vue && (name.hasPrefix("v-") || c == A.colon || c == A.at || c == A.hash)
        out.add(i, k, isDirective ? .directive : .attribute)
        s.flags &= ~(Self.directive | Self.languageAttribute)
        if isDirective { s.flags |= Self.directive }
        let lower = name.lowercased()
        if lower == "lang" || lower == "type" { s.flags |= Self.languageAttribute }
        return k
    }

    private func endTag(_ s: inout LexState, enterRegion: Bool) {
        let closing = s.flags & Self.closing != 0
        s.flags = 0
        s.aux = 0
        if enterRegion, !closing, embeds, s.delimiter == "script" || s.delimiter == "style" {
            let fallback: CodeLanguage = s.delimiter == "script" ? .javascript : .css
            let chosen = s.depth > 0 ? CodeLanguage.allCases[Int(s.depth) - 1] : fallback
            s.mode = Mode.embedded
            s.embedded = EmbeddedLexState(chosen, .initial)
            s.depth = 0
            return
        }
        s.mode = Mode.content
        s.delimiter = ""
        s.depth = 0
    }

    /// The embedded language a `lang` / `type` value names, as `CodeLanguage` index + 1 (0: default).
    static func code(for value: String) -> UInt16 {
        let language: CodeLanguage?
        switch value.lowercased() {
        case "ts", "typescript", "text/typescript": language = .typescript
        case "tsx": language = .tsx
        case "jsx": language = .jsx
        case "js", "javascript", "module", "text/javascript", "application/javascript": language = .javascript
        case "scss", "sass", "less": language = .scss
        case "css", "postcss", "text/css": language = .css
        case "json", "application/json", "importmap", "application/ld+json", "speculationrules": language = .json
        case "text/x-template", "text/html", "text/template", "html": language = .plain
        default: language = nil
        }
        guard let language, let index = CodeLanguage.allCases.firstIndex(of: language) else { return 0 }
        return UInt16(index + 1)
    }

    private func continueValue(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let quote = s.aux
        let close = t.find(unit: quote, from: i, end: end)
        if s.flags & Self.directive != 0 {
            var inner = LexState.initial
            Self.javascript.lex(t, from: i, to: close ?? end, state: &inner, out: &out)
            guard let close else { return end }
            out.add(close, close + 1, .punctuation)
            s.mode = Mode.tag
            s.aux = 0
            s.flags &= ~(Self.directive | Self.languageAttribute)
            return close + 1
        }
        guard let close else {
            out.add(i, end, .string)
            return end
        }
        out.add(i, close + 1, .string)
        s.mode = Mode.tag
        s.aux = 0
        s.flags &= ~(Self.directive | Self.languageAttribute)
        return close + 1
    }

    // MARK: Regions

    private func mustache(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let close = t.find("}}", from: i, end: end)
        var inner = LexState.initial
        Self.javascript.lex(t, from: i, to: close ?? end, state: &inner, out: &out)
        guard let close else { return end }
        out.add(close, close + 2, .directive)
        s.mode = Mode.content
        return close + 2
    }

    private func embedded(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let close = s.delimiter == "style"
            ? t.find("</style", from: i, end: end, ignoringCase: true)
            : t.find("</script", from: i, end: end, ignoringCase: true)
        let language = s.embedded?.language ?? .javascript
        var inner = s.embedded?.state ?? .initial
        Lexers.lex(language, t, from: i, to: close ?? end, state: &inner, out: &out)
        guard let close else {
            s.embedded = EmbeddedLexState(language, inner)
            return end
        }
        s.embedded = nil
        out.add(close, close + 2, .punctuation)
        let nameEnd = tagNameEnd(t, close + 2, end)
        out.add(close + 2, nameEnd, .tag)
        s.mode = Mode.tag
        s.flags = Self.closing
        s.delimiter = ""
        return nameEnd
    }

    private func php(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let close = t.find("?>", from: i, end: end)
        var inner = s.embedded?.state ?? .initial
        Self.phpCode.lex(t, from: i, to: close ?? end, state: &inner, out: &out)
        guard let close else {
            s.embedded = EmbeddedLexState(.php, inner)
            return end
        }
        out.add(close, close + 2, .directive)
        s.embedded = nil
        s.mode = Mode.content
        return close + 2
    }
}
