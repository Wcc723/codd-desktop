import Foundation

/// CSS and SCSS: selectors in the tag color (the artboard's `.punch-sticky`), properties, values with
/// numbers / functions / `!important`, at-rules and their preludes (`@media (max-width: 640px)`),
/// comments (SCSS `//` too), SCSS variables, placeholders and `#{}` interpolation. Values and block
/// comments continue across lines; the brace depth is part of the state, so nested SCSS rules know
/// they are inside a block.
struct CSSLexer {
    let scss: Bool

    enum Mode {
        static let code: UInt8 = 0
        static let comment: UInt8 = 1
    }

    /// `flags`: inside a declaration value (after `:` until `;` / `}`), or an at-rule prelude.
    static let inValue: UInt8 = 1
    static let inPrelude: UInt8 = 2

    private enum Statement { case selector, declaration }

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        var statement: Statement?
        while i < end {
            if s.mode == Mode.comment {
                if let close = t.find("*/", from: i, end: end) {
                    out.add(i, close + 2, .comment)
                    s.mode = Mode.code
                    i = close + 2
                } else {
                    out.add(i, end, .comment)
                    return
                }
                continue
            }
            let c = t[i]
            if A.isSpace(c) { i = t.skipSpaces(i, end: end); continue }
            if c == A.slash, t[i + 1] == A.star {
                if let close = t.find("*/", from: i + 2, end: end) {
                    out.add(i, close + 2, .comment)
                    i = close + 2
                } else {
                    out.add(i, end, .comment)
                    s.mode = Mode.comment
                    return
                }
                continue
            }
            if scss, c == A.slash, t[i + 1] == A.slash {
                out.add(i, end, .comment)
                return
            }
            if c == A.dquote || c == A.squote {
                let close = t.stringEnd(i, quote: c, end: end) ?? end
                out.add(i, close, .string)
                i = close
                continue
            }
            switch c {
            case A.lbrace:
                out.add(i, i + 1, .punctuation)
                s.depth &+= 1
                s.flags = 0
                s.aux = 0
                statement = nil
                i += 1
                continue
            case A.rbrace:
                out.add(i, i + 1, .punctuation)
                if s.depth > 0 { s.depth -= 1 }
                s.flags = 0
                s.aux = 0
                statement = nil
                i += 1
                continue
            case A.semicolon:
                out.add(i, i + 1, .punctuation)
                s.flags = 0
                s.aux = 0
                statement = nil
                i += 1
                continue
            default:
                break
            }
            if c == A.at, A.isIdentStart(t[i + 1]) {
                let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
                out.add(i, nameEnd, .keyword)
                let name = t.text(i + 1, nameEnd)
                if s.flags & Self.inValue == 0 { s.flags |= Self.inPrelude }
                i = nameEnd
                if scss, name == "include" || name == "mixin" || name == "function" {
                    let start = t.skipSpaces(i, end: end)
                    let functionEnd = t.identEnd(start, end: end, extra: A.minus)
                    out.add(start, functionEnd, .function)
                    i = max(i, functionEnd)
                }
                continue
            }
            if s.flags & Self.inValue != 0 {
                i = value(t, i, end, &s, &out)
            } else if s.flags & Self.inPrelude != 0 {
                i = prelude(t, i, end, &s, &out)
            } else {
                if statement == nil { statement = classify(t, i, end, depth: s.depth) }
                if statement == .declaration {
                    i = declarationStart(t, i, end, &s, &out)
                } else {
                    i = selector(t, i, end, &out)
                }
            }
        }
    }

    /// Selector or declaration, decided at a statement's start: at the top level a selector (SCSS
    /// `$var:` aside); inside a block whichever of `{` and `;` / `}` comes first on the line.
    private func classify(_ t: LineText, _ i: Int, _ end: Int, depth: UInt16) -> Statement {
        if scss, t[i] == A.dollar { return .declaration }
        if t[i] == A.minus, t[i + 1] == A.minus { return .declaration }
        guard depth > 0 else { return .selector }
        var j = i
        var firstColon: Int?
        while j < end {
            let c = t[j]
            if c == A.dquote || c == A.squote { j = t.stringEnd(j, quote: c, end: end) ?? end; continue }
            if c == A.lparen, let close = t.find(unit: A.rparen, from: j, end: end) { j = close + 1; continue }
            if c == A.lbrace { return .selector }
            if c == A.semicolon || c == A.rbrace { return .declaration }
            if c == A.colon, firstColon == nil { firstColon = j }
            j += 1
        }
        var last = end - 1
        while last > i, A.isSpace(t[last]) { last -= 1 }
        if t[last] == A.comma { return .selector }
        if let colon = firstColon, A.isSpace(t[colon + 1]) || colon + 1 >= end { return .declaration }
        return .selector
    }

    private func declarationStart(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let c = t[i]
        if A.isIdentStart(c) || c == A.minus || c == A.dollar {
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
            out.add(i, nameEnd, .property)
            return nameEnd
        }
        if c == A.colon {
            out.add(i, i + 1, .punctuation)
            s.flags |= Self.inValue
            return i + 1
        }
        if c == A.hash, t[i + 1] == A.lbrace {
            out.add(i, i + 2, .punctuation)
            return i + 2
        }
        out.add(i, i + 1, .punctuation)
        return i + 1
    }

    private func value(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let c = t[i]
        if c == A.hash {
            if t[i + 1] == A.lbrace {
                out.add(i, i + 2, .punctuation)
                return i + 2
            }
            let colorEnd = t.identEnd(i + 1, end: end)
            out.add(i, colorEnd, .number)
            return colorEnd
        }
        if A.isDigit(c) || (c == A.dot && A.isDigit(t[i + 1])) || ((c == A.minus || c == A.plus) && (A.isDigit(t[i + 1])
            || (t[i + 1] == A.dot && A.isDigit(t[i + 2]))) && !A.isIdentPart(t[i - 1])) {
            var numberEnd = t.numberEnd(c == A.minus || c == A.plus ? i + 1 : i, end: end)
            if t[numberEnd] == A.percent { numberEnd += 1 }
            out.add(i, numberEnd, .number)
            return numberEnd
        }
        if c == A.bang, A.isIdentStart(t[i + 1]) {
            let nameEnd = t.identEnd(i + 1, end: end)
            out.add(i, nameEnd, .keyword)
            return nameEnd
        }
        if scss, c == A.dollar, A.isIdentStart(t[i + 1]) {
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
            out.add(i, nameEnd, .property)
            return nameEnd
        }
        if c == A.minus, t[i + 1] == A.minus {
            let nameEnd = t.identEnd(i + 2, end: end, extra: A.minus)
            out.add(i, nameEnd, .property)
            return nameEnd
        }
        if A.isIdentStart(c) || (c == A.minus && A.isIdentStart(t[i + 1])) {
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
            if t[nameEnd] == A.lparen {
                out.add(i, nameEnd, .function)
                if t.text(i, nameEnd).lowercased() == "url" {
                    out.add(nameEnd, nameEnd + 1, .punctuation)
                    let close = t.find(unit: A.rparen, from: nameEnd + 1, end: end) ?? end
                    let inner = t.skipSpaces(nameEnd + 1, end: close)
                    if t[inner] != A.dquote, t[inner] != A.squote { out.add(nameEnd + 1, close, .string); return close }
                }
            }
            return nameEnd
        }
        out.add(i, i + 1, .punctuation)
        return i + 1
    }

    private func prelude(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let c = t[i]
        if c == A.lparen { s.aux &+= 1; out.add(i, i + 1, .punctuation); return i + 1 }
        if c == A.rparen { if s.aux > 0 { s.aux -= 1 }; out.add(i, i + 1, .punctuation); return i + 1 }
        if A.isDigit(c) || (c == A.dot && A.isDigit(t[i + 1])) {
            var numberEnd = t.numberEnd(i, end: end)
            if t[numberEnd] == A.percent { numberEnd += 1 }
            out.add(i, numberEnd, .number)
            return numberEnd
        }
        if A.isIdentStart(c) || c == A.minus {
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
            if s.aux > 0, t[t.skipSpaces(nameEnd, end: end)] == A.colon {
                out.add(i, nameEnd, .property)
            } else if t[nameEnd] == A.lparen {
                out.add(i, nameEnd, .function)
            }
            return nameEnd
        }
        if scss, c == A.dollar {
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
            out.add(i, nameEnd, .property)
            return nameEnd
        }
        out.add(i, i + 1, .punctuation)
        return i + 1
    }

    private func selector(_ t: LineText, _ i: Int, _ end: Int, _ out: inout TokenSink) -> Int {
        let c = t[i]
        if (c == A.dot || c == A.hash || c == A.percent), A.isIdentStart(t[i + 1]) || t[i + 1] == A.minus {
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
            out.add(i, nameEnd, .tag)
            return nameEnd
        }
        if c == A.hash, t[i + 1] == A.lbrace {
            out.add(i, i + 2, .punctuation)
            return i + 2
        }
        if c == A.colon {
            var nameStart = i + 1
            if t[nameStart] == A.colon { nameStart += 1 }
            let nameEnd = t.identEnd(nameStart, end: end, extra: A.minus)
            out.add(i, nameEnd, .tag)
            return max(nameEnd, i + 1)
        }
        if c == A.amp || c == A.star {
            out.add(i, i + 1, .tag)
            return i + 1
        }
        if c == A.lbracket {
            out.add(i, i + 1, .punctuation)
            let nameStart = t.skipSpaces(i + 1, end: end)
            let nameEnd = t.identEnd(nameStart, end: end, extra: A.minus)
            out.add(nameStart, nameEnd, .attribute)
            return max(nameEnd, i + 1)
        }
        if A.isDigit(c) {
            var numberEnd = t.numberEnd(i, end: end)
            if t[numberEnd] == A.percent { numberEnd += 1 }
            out.add(i, numberEnd, .number)
            return numberEnd
        }
        if A.isIdentStart(c) || c == A.minus {
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus)
            out.add(i, nameEnd, .tag)
            return nameEnd
        }
        out.add(i, i + 1, .punctuation)
        return i + 1
    }
}
