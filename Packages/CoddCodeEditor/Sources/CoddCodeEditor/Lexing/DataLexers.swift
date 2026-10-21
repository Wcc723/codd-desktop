import Foundation

/// JSON (and JSONC: `tsconfig.json` style comments): keys as properties, string values, numbers,
/// `true` / `false` / `null`, punctuation.
struct JSONLexer {
    enum Mode {
        static let code: UInt8 = 0
        static let comment: UInt8 = 1
    }

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
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
            if c == A.slash, t[i + 1] == A.slash { out.add(i, end, .comment); return }
            if c == A.slash, t[i + 1] == A.star {
                s.mode = Mode.comment
                out.add(i, i + 2, .comment)
                i += 2
                continue
            }
            if c == A.dquote || c == A.squote {
                let close = t.stringEnd(i, quote: c, end: end) ?? end
                out.add(i, close, t[t.skipSpaces(close, end: end)] == A.colon ? .property : .string)
                i = close
                continue
            }
            if A.isDigit(c) || ((c == A.minus || c == A.plus) && (A.isDigit(t[i + 1]) || t[i + 1] == A.dot)) || (c == A.dot && A.isDigit(t[i + 1])) {
                let numberEnd = t.numberEnd(c == A.minus || c == A.plus ? i + 1 : i, end: end)
                out.add(i, numberEnd, .number)
                i = numberEnd
                continue
            }
            if A.isIdentStart(c) {
                let k = t.identEnd(i, end: end)
                switch t.text(i, k) {
                case "true", "false", "null": out.add(i, k, .keyword)
                default: out.add(i, k, t[t.skipSpaces(k, end: end)] == A.colon ? .property : .plain)
                }
                i = k
                continue
            }
            out.add(i, i + 1, .punctuation)
            i += 1
        }
    }
}

/// YAML: keys, sequence markers, quoted strings (multi-line too), block scalars (`|`, `>`) as
/// strings while they are indented deeper than their key, anchors / aliases / tags, comments,
/// numbers and booleans / null.
struct YAMLLexer {
    enum Mode {
        static let normal: UInt8 = 0
        static let blockScalar: UInt8 = 1
        static let quoted: UInt8 = 2
    }

    private static let literals: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        if s.mode == Mode.blockScalar {
            if t.skipSpaces(from, end: end) >= end { return }
            let indent = t.skipSpaces(from, end: end) - from
            if indent > Int(s.aux) {
                out.add(from + indent, end, .string)
                return
            }
            s.mode = Mode.normal
            s.aux = 0
        }
        if s.mode == Mode.quoted {
            guard let close = closingQuote(t, from: i, quote: s.aux, end) else {
                out.add(i, end, .string)
                return
            }
            out.add(i, close, .string)
            s.mode = Mode.normal
            s.aux = 0
            i = close
        }
        i = t.skipSpaces(i, end: end)
        let lineIndent = i - from
        if t[i] == A.hash { out.add(i, end, .comment); return }
        if i == from, t.has("---", at: i) || t.has("...", at: i) {
            out.add(i, i + 3, .punctuation)
            i = t.skipSpaces(i + 3, end: end)
        }
        // Sequence markers (`- - item`) and explicit keys.
        while (t[i] == A.minus || t[i] == A.question), A.isSpace(t[i + 1]) || i + 1 >= end {
            out.add(i, i + 1, .punctuation)
            i = t.skipSpaces(i + 1, end: end)
        }
        i = key(t, i, end, &out)
        value(t, i, end, lineIndent: lineIndent, &s, &out)
    }

    /// A `key:` at `i` (plain or quoted) as a property; returns the index after its colon, or `i`.
    private func key(_ t: LineText, _ i: Int, _ end: Int, _ out: inout TokenSink) -> Int {
        if t[i] == A.dquote || t[i] == A.squote, let close = t.stringEnd(i, quote: t[i], end: end) {
            let colon = t.skipSpaces(close, end: end)
            if t[colon] == A.colon, A.isSpace(t[colon + 1]) || colon + 1 >= end {
                out.add(i, close, .property)
                out.add(colon, colon + 1, .punctuation)
                return colon + 1
            }
            return i
        }
        guard t[i] != A.lbracket, t[i] != A.lbrace, t[i] != A.amp, t[i] != A.star, t[i] != A.bang else { return i }
        var j = i
        while j < end {
            let c = t[j]
            if c == A.hash, j > i, A.isSpace(t[j - 1]) { return i }
            if c == A.colon, A.isSpace(t[j + 1]) || j + 1 >= end {
                var keyEnd = j
                while keyEnd > i, A.isSpace(t[keyEnd - 1]) { keyEnd -= 1 }
                guard keyEnd > i else { return i }
                out.add(i, keyEnd, .property)
                out.add(j, j + 1, .punctuation)
                return j + 1
            }
            j += 1
        }
        return i
    }

    private func value(_ t: LineText, _ start: Int, _ end: Int, lineIndent: Int, _ s: inout LexState, _ out: inout TokenSink) {
        var i = start
        var flow = 0
        while i < end {
            let c = t[i]
            if A.isSpace(c) { i = t.skipSpaces(i, end: end); continue }
            if c == A.hash, i == start || A.isSpace(t[i - 1]) { out.add(i, end, .comment); return }
            if (c == A.pipe || c == A.gt), flow == 0 {
                var k = i + 1
                while k < end, t[k] == A.plus || t[k] == A.minus || A.isDigit(t[k]) { k += 1 }
                let rest = t.skipSpaces(k, end: end)
                if rest >= end || t[rest] == A.hash {
                    out.add(i, k, .punctuation)
                    if rest < end { out.add(rest, end, .comment) }
                    s.mode = Mode.blockScalar
                    s.aux = UInt16(lineIndent)
                    return
                }
            }
            if c == A.dquote || c == A.squote {
                guard let close = closingQuote(t, from: i + 1, quote: c, end) else {
                    out.add(i, end, .string)
                    s.mode = Mode.quoted
                    s.aux = c
                    return
                }
                out.add(i, close, t[t.skipSpaces(close, end: end)] == A.colon && flow > 0 ? .property : .string)
                i = close
                continue
            }
            if (c == A.amp || c == A.star || c == A.bang), !A.isSpace(t[i + 1]), i + 1 < end {
                var k = i + 1
                while k < end, !A.isSpace(t[k]), t[k] != A.comma, t[k] != A.rbracket, t[k] != A.rbrace { k += 1 }
                out.add(i, k, .directive)
                i = k
                continue
            }
            if c == A.lbracket || c == A.lbrace { flow += 1; out.add(i, i + 1, .punctuation); i += 1; continue }
            if c == A.rbracket || c == A.rbrace { flow -= 1; out.add(i, i + 1, .punctuation); i += 1; continue }
            if c == A.comma || (c == A.colon && flow > 0) { out.add(i, i + 1, .punctuation); i += 1; continue }
            // A plain scalar up to a comment (or a flow delimiter inside `[ ]` / `{ }`).
            var k = i
            while k < end {
                let d = t[k]
                if d == A.hash, A.isSpace(t[k - 1]) { break }
                if flow > 0, d == A.comma || d == A.rbracket || d == A.rbrace || (d == A.colon && A.isSpace(t[k + 1])) { break }
                k += 1
            }
            var stop = k
            while stop > i, A.isSpace(t[stop - 1]) { stop -= 1 }
            let word = t.text(i, stop)
            if Self.literals.contains(word.lowercased()) {
                out.add(i, stop, .keyword)
            } else if Self.isNumber(word) {
                out.add(i, stop, .number)
            } else if flow > 0, t[k] == A.colon {
                out.add(i, stop, .property)
            }
            i = max(k, i + 1)
        }
    }

    static func isNumber(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first else { return false }
        let body = first == "-" || first == "+" ? word.dropFirst() : Substring(word)
        guard let lead = body.unicodeScalars.first, ("0" ... "9").contains(lead) || lead == "." else {
            return [".inf", ".nan", "-.inf"].contains(word.lowercased())
        }
        return body.unicodeScalars.allSatisfy { ("0" ... "9").contains($0) || "._xXoOabcdefABCDEFeE+-:".unicodeScalars.contains($0) }
    }

    /// YAML single quotes escape by doubling (`''`); double quotes by backslash.
    private func closingQuote(_ t: LineText, from: Int, quote: UInt16, _ end: Int) -> Int? {
        var j = from
        while j < end {
            if quote == A.dquote, t[j] == A.backslash { j += 2; continue }
            if t[j] == quote {
                if quote == A.squote, t[j + 1] == A.squote { j += 2; continue }
                return j + 1
            }
            j += 1
        }
        return nil
    }
}

/// TOML (and INI-style files): `[table]` headers in the tag color, keys, strings including
/// multi-line `"""` / `'''`, numbers and dates, booleans, inline tables and arrays, comments.
struct TOMLLexer {
    enum Mode {
        static let normal: UInt8 = 0
        static let basic: UInt8 = 1
        static let literal: UInt8 = 2
    }

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        if s.mode != Mode.normal {
            let close = s.mode == Mode.basic ? tripleEnd(t, from: i, "\"\"\"", escapes: true, end) : tripleEnd(t, from: i, "'''", escapes: false, end)
            guard let close else {
                out.add(i, end, .string)
                return
            }
            out.add(i, close, .string)
            s.mode = Mode.normal
            i = close
        }
        i = t.skipSpaces(i, end: end)
        if t[i] == A.hash || t[i] == A.semicolon { out.add(i, end, .comment); return }
        if t[i] == A.lbracket, i == t.skipSpaces(from, end: end), s.depth == 0 {
            let double = t[i + 1] == A.lbracket
            let nameStart = i + (double ? 2 : 1)
            let close = t.find(unit: A.rbracket, from: nameStart, end: end) ?? end
            out.add(i, nameStart, .punctuation)
            out.add(nameStart, close, .tag)
            let closeEnd = min(end, close + (double && t[close + 1] == A.rbracket ? 2 : 1))
            out.add(close, closeEnd, .punctuation)
            i = closeEnd
            let rest = t.skipSpaces(i, end: end)
            if t[rest] == A.hash { out.add(rest, end, .comment) }
            return
        }
        if s.depth == 0, let equals = keyEquals(t, i, end) {
            var k = i
            while k < equals {
                let c = t[k]
                if c == A.dquote || c == A.squote {
                    let close = t.stringEnd(k, quote: c, end: equals) ?? equals
                    out.add(k, close, .property)
                    k = close
                } else if c == A.dot {
                    out.add(k, k + 1, .punctuation)
                    k += 1
                } else if A.isSpace(c) {
                    k += 1
                } else {
                    var stop = k
                    while stop < equals, !A.isSpace(t[stop]), t[stop] != A.dot { stop += 1 }
                    out.add(k, stop, .property)
                    k = stop
                }
            }
            out.add(equals, equals + 1, .punctuation)
            i = equals + 1
        }
        value(t, i, end, &s, &out)
    }

    /// The `=` of a `key = value` line (outside quotes, before a comment).
    private func keyEquals(_ t: LineText, _ i: Int, _ end: Int) -> Int? {
        var j = i
        while j < end {
            let c = t[j]
            if c == A.dquote || c == A.squote { j = t.stringEnd(j, quote: c, end: end) ?? end; continue }
            if c == A.equals { return j > i ? j : nil }
            if c == A.hash || c == A.lbracket || c == A.lbrace { return nil }
            j += 1
        }
        return nil
    }

    private func value(_ t: LineText, _ start: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) {
        var i = start
        while i < end {
            let c = t[i]
            if A.isSpace(c) { i = t.skipSpaces(i, end: end); continue }
            if c == A.hash { out.add(i, end, .comment); return }
            if c == A.dquote || c == A.squote {
                let triple = c == A.dquote ? t.has("\"\"\"", at: i) : t.has("'''", at: i)
                if triple {
                    let close = c == A.dquote ? tripleEnd(t, from: i + 3, "\"\"\"", escapes: true, end) : tripleEnd(t, from: i + 3, "'''", escapes: false, end)
                    guard let close else {
                        out.add(i, end, .string)
                        s.mode = c == A.dquote ? Mode.basic : Mode.literal
                        return
                    }
                    out.add(i, close, .string)
                    i = close
                    continue
                }
                let close = t.stringEnd(i, quote: c, end: end, escapes: c == A.dquote) ?? end
                out.add(i, close, .string)
                i = close
                continue
            }
            if c == A.lbracket || c == A.lbrace {
                s.depth &+= 1
                out.add(i, i + 1, .punctuation)
                i += 1
                continue
            }
            if c == A.rbracket || c == A.rbrace {
                if s.depth > 0 { s.depth -= 1 }
                out.add(i, i + 1, .punctuation)
                i += 1
                continue
            }
            if c == A.comma || c == A.equals || c == A.dot {
                out.add(i, i + 1, .punctuation)
                i += 1
                continue
            }
            var k = i
            while k < end, !A.isSpace(t[k]), t[k] != A.comma, t[k] != A.rbracket, t[k] != A.rbrace, t[k] != A.equals, t[k] != A.hash { k += 1 }
            let word = t.text(i, k)
            if word == "true" || word == "false" {
                out.add(i, k, .keyword)
            } else if A.isDigit(c) || ((c == A.plus || c == A.minus) && (A.isDigit(t[i + 1]) || t[i + 1] == 0x69 || t[i + 1] == 0x6E))
                        || word == "inf" || word == "nan" {
                out.add(i, k, .number)
            } else if t[t.skipSpaces(k, end: end)] == A.equals {
                out.add(i, k, .property)
            }
            i = max(k, i + 1)
        }
    }

    private func tripleEnd(_ t: LineText, from: Int, _ close: StaticString, escapes: Bool, _ end: Int) -> Int? {
        var j = from
        while j < end {
            if escapes, t[j] == A.backslash { j += 2; continue }
            if t.has(close, at: j) {
                var stop = j + 3
                // `""""` / `''''`: up to two quotes may belong to the content.
                while stop < end, t[stop] == t[j], stop < j + 5 { stop += 1 }
                return stop
            }
            j += 1
        }
        return nil
    }
}
