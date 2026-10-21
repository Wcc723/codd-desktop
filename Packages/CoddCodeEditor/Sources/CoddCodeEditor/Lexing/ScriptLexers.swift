import Foundation

/// Python: comments, string prefixes (`r`, `b`, `f`, `rb`…), triple-quoted strings across lines,
/// backslash-continued strings, decorators, `def` / `class` names, calls, numbers.
struct PythonLexer {
    enum Mode {
        static let code: UInt8 = 0
        static let triple: UInt8 = 1
        static let single: UInt8 = 2
    }

    /// `flags` bit 0: the open string is raw (no escapes).
    static let raw: UInt8 = 1

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        let first = t.skipSpaces(from, end: end)
        var pendingName = false
        while i < end {
            if s.mode == Mode.triple || s.mode == Mode.single {
                i = continueString(t, i, end, tokenStart: i, &s, &out)
                continue
            }
            let c = t[i]
            if A.isSpace(c) { i = t.skipSpaces(i, end: end); continue }
            if c == A.hash { out.add(i, end, .comment); return }
            if c == A.dquote || c == A.squote {
                i = openString(t, i, tokenStart: i, raw: false, end, &s, &out)
                continue
            }
            if c == A.at, i == first, A.isIdentStart(t[i + 1]) {
                let nameEnd = t.identEnd(i + 1, end: end, extra: A.dot)
                out.add(i, nameEnd, .directive)
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
                if k - i <= 2, t[k] == A.dquote || t[k] == A.squote {
                    let prefix = t.text(i, k).lowercased()
                    if prefix.allSatisfy({ "rbuf".contains($0) }) {
                        i = openString(t, k, tokenStart: i, raw: prefix.contains("r"), end, &s, &out)
                        continue
                    }
                }
                let word = t.text(i, k)
                if Keywords.python.contains(word) {
                    out.add(i, k, .keyword)
                    pendingName = word == "def" || word == "class"
                } else {
                    if pendingName || t[t.skipSpaces(k, end: end)] == A.lparen { out.add(i, k, .function) }
                    pendingName = false
                }
                i = k
                continue
            }
            pendingName = false
            if c != A.dot { out.add(i, i + 1, .punctuation) }
            i += 1
        }
    }

    private func openString(_ t: LineText, _ quoteIndex: Int, tokenStart: Int, raw: Bool, _ end: Int,
                            _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let quote = t[quoteIndex]
        s.aux = quote
        s.flags = raw ? Self.raw : 0
        if t[quoteIndex + 1] == quote, t[quoteIndex + 2] == quote {
            s.mode = Mode.triple
            return continueString(t, quoteIndex + 3, end, tokenStart: tokenStart, &s, &out)
        }
        s.mode = Mode.single
        return continueString(t, quoteIndex + 1, end, tokenStart: tokenStart, &s, &out)
    }

    private func continueString(_ t: LineText, _ i: Int, _ end: Int, tokenStart: Int, _ s: inout LexState,
                                _ out: inout TokenSink) -> Int {
        let quote = s.aux
        let raw = s.flags & Self.raw != 0
        let triple = s.mode == Mode.triple
        var j = i
        while j < end {
            let c = t[j]
            if c == A.backslash, !raw || t[j + 1] == quote { j += 2; continue }
            if c == quote {
                if !triple {
                    out.add(tokenStart, j + 1, .string)
                    s = Self.reset(s)
                    return j + 1
                }
                if t[j + 1] == quote, t[j + 2] == quote {
                    out.add(tokenStart, j + 3, .string)
                    s = Self.reset(s)
                    return j + 3
                }
            }
            j += 1
        }
        out.add(tokenStart, end, .string)
        if !triple, !(end > 0 && t[end - 1] == A.backslash) { s = Self.reset(s) }
        return end
    }

    private static func reset(_ s: LexState) -> LexState {
        var copy = s
        copy.mode = Mode.code
        copy.aux = 0
        copy.flags = 0
        return copy
    }
}

/// Ruby: comments and `=begin` / `=end`, strings across lines, heredocs (`<<~EOS`), symbols,
/// instance / class / global variables, hash keys, `def` names, calls.
struct RubyLexer {
    enum Mode {
        static let code: UInt8 = 0
        static let blockComment: UInt8 = 1
        static let heredoc: UInt8 = 2
        static let string: UInt8 = 3
    }

    /// `flags` bit 0: the heredoc terminator may be indented (`<<~` / `<<-`).
    static let indented: UInt8 = 1

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        if s.mode == Mode.blockComment {
            out.add(from, end, .comment)
            if t.has("=end", at: from) { s.mode = Mode.code }
            return
        }
        if s.mode == Mode.heredoc {
            let start = s.flags & Self.indented != 0 ? t.skipSpaces(from, end: end) : from
            var stop = end
            while stop > start, A.isSpace(t[stop - 1]) { stop -= 1 }
            if t.text(start, stop) == s.delimiter {
                out.add(start, stop, .directive)
                s.mode = Mode.code
                s.delimiter = ""
                s.flags = 0
            } else {
                out.add(from, end, .string)
            }
            return
        }
        if s.mode == Mode.code, t.has("=begin", at: from) {
            out.add(from, end, .comment)
            s.mode = Mode.blockComment
            return
        }
        var pendingName = false
        var heredoc: (word: String, indented: Bool)?
        while i < end {
            if s.mode == Mode.string {
                if let close = closing(t, from: i, quote: s.aux, end) {
                    out.add(i, close, .string)
                    s.mode = Mode.code
                    s.aux = 0
                    i = close
                } else {
                    out.add(i, end, .string)
                    i = end
                }
                continue
            }
            let c = t[i]
            if A.isSpace(c) { i = t.skipSpaces(i, end: end); continue }
            if c == A.hash { out.add(i, end, .comment); break }
            if c == A.dquote || c == A.squote || c == A.backtick {
                if let close = closing(t, from: i + 1, quote: c, end) {
                    out.add(i, close, .string)
                    i = close
                } else {
                    out.add(i, end, .string)
                    s.mode = Mode.string
                    s.aux = c
                    i = end
                }
                continue
            }
            if c == A.lt, t[i + 1] == A.lt {
                var k = i + 2
                let squiggly = t[k] == A.tilde || t[k] == A.minus
                if squiggly { k += 1 }
                var quote: UInt16 = 0
                if t[k] == A.dquote || t[k] == A.squote { quote = t[k]; k += 1 }
                let wordStart = k
                if A.isIdentStart(t[k]), squiggly || quote != 0 || (t[k] >= 0x41 && t[k] <= 0x5A) || t[k] == A.underscore {
                    let wordEnd = t.identEnd(wordStart, end: end)
                    out.add(i, wordStart - (quote != 0 ? 1 : 0), .punctuation)
                    let tokenEnd = quote != 0 && t[wordEnd] == quote ? wordEnd + 1 : wordEnd
                    out.add(wordStart - (quote != 0 ? 1 : 0), tokenEnd, .directive)
                    heredoc = (t.text(wordStart, wordEnd), squiggly)
                    i = tokenEnd
                    continue
                }
            }
            if c == A.colon, A.isIdentStart(t[i + 1]), t[i - 1] != A.colon, !A.isIdentPart(t[i - 1]) {
                var k = t.identEnd(i + 1, end: end)
                if t[k] == A.question || t[k] == A.bang { k += 1 }
                out.add(i, k, .string)
                i = k
                continue
            }
            if c == A.at || c == A.dollar, A.isIdentStart(t[i + 1]) || (c == A.at && t[i + 1] == A.at) {
                let nameStart = t[i + 1] == A.at ? i + 2 : i + 1
                let nameEnd = t.identEnd(nameStart, end: end)
                out.add(i, nameEnd, .property)
                i = nameEnd
                continue
            }
            if A.isDigit(c) {
                let numberEnd = t.numberEnd(i, end: end)
                out.add(i, numberEnd, .number)
                i = numberEnd
                continue
            }
            if A.isIdentStart(c) {
                var k = t.identEnd(i, end: end)
                if t[k] == A.question || (t[k] == A.bang && t[k + 1] != A.equals) { k += 1 }
                let word = t.text(i, k)
                if t[k] == A.colon, t[k + 1] != A.colon, A.isSpace(t[k + 1]) || k + 1 >= end {
                    out.add(i, k, .property)
                    out.add(k, k + 1, .punctuation)
                    i = k + 1
                    continue
                }
                if Keywords.ruby.contains(word), !(pendingName && word != "self") {
                    out.add(i, k, .keyword)
                    if word == "def" { pendingName = true }
                } else if pendingName || t[k] == A.lparen {
                    out.add(i, k, .function)
                    pendingName = false
                }
                i = k
                continue
            }
            if c != A.dot { out.add(i, i + 1, .punctuation) }
            i += 1
        }
        if let heredoc, s.mode == Mode.code {
            s.mode = Mode.heredoc
            s.delimiter = heredoc.word
            s.flags = heredoc.indented ? Self.indented : 0
        }
    }

    private func closing(_ t: LineText, from: Int, quote: UInt16, _ end: Int) -> Int? {
        var j = from
        while j < end {
            if t[j] == A.backslash, quote != A.squote || t[j + 1] == A.squote || t[j + 1] == A.backslash { j += 2; continue }
            if t[j] == quote { return j + 1 }
            j += 1
        }
        return nil
    }
}

/// POSIX shells and zsh (also Makefile / Dockerfile / `.env` by approximation): comments, single
/// and double quoted strings across lines with `$VAR` / `${…}` expansions, heredocs (`<<EOF`,
/// `<<-EOF`, `<<'EOF'`), keywords, builtins in command position, assignments, function names.
struct ShellLexer {
    enum Mode {
        static let code: UInt8 = 0
        static let single: UInt8 = 1
        static let double: UInt8 = 2
        static let heredoc: UInt8 = 3
    }

    /// `flags`: the heredoc strips leading tabs (`<<-`); its word was quoted (no expansions).
    static let stripTabs: UInt8 = 1
    static let quoted: UInt8 = 2

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        if s.mode == Mode.heredoc {
            var start = from
            if s.flags & Self.stripTabs != 0 { while t[start] == A.tab { start += 1 } }
            if t.text(start, end) == s.delimiter {
                out.add(start, end, .directive)
                s.mode = Mode.code
                s.delimiter = ""
                s.flags = 0
            } else if s.flags & Self.quoted != 0 {
                out.add(from, end, .string)
            } else {
                _ = expanding(t, from: from, tokenStart: from, end, closeAt: 0, &out)
            }
            return
        }
        var i = from
        var command = true
        var heredoc: (word: String, flags: UInt8)?
        while i < end {
            if s.mode == Mode.single {
                if let close = t.find(unit: A.squote, from: i, end: end) {
                    out.add(i, close + 1, .string)
                    s.mode = Mode.code
                    i = close + 1
                } else {
                    out.add(i, end, .string)
                    i = end
                }
                continue
            }
            if s.mode == Mode.double {
                let (next, closed) = expanding(t, from: i, tokenStart: i, end, closeAt: A.dquote, &out)
                if closed { s.mode = Mode.code }
                i = next
                continue
            }
            let c = t[i]
            if A.isSpace(c) { i = t.skipSpaces(i, end: end); continue }
            if c == A.hash, i == from || A.isSpace(t[i - 1]) || t[i - 1] == A.semicolon || t[i - 1] == A.lparen {
                out.add(i, end, .comment)
                break
            }
            if c == A.squote {
                if let close = t.find(unit: A.squote, from: i + 1, end: end) {
                    out.add(i, close + 1, .string)
                    i = close + 1
                } else {
                    out.add(i, end, .string)
                    s.mode = Mode.single
                    i = end
                }
                command = false
                continue
            }
            if c == A.dquote {
                let (next, closed) = expanding(t, from: i + 1, tokenStart: i, end, closeAt: A.dquote, &out)
                if !closed { s.mode = Mode.double }
                i = next
                command = false
                continue
            }
            if c == A.backtick {
                let close = t.find(unit: A.backtick, from: i + 1, end: end).map { $0 + 1 } ?? end
                out.add(i, close, .string)
                i = close
                continue
            }
            if c == A.dollar {
                i = variable(t, i, end, &out)
                command = false
                continue
            }
            if c == A.lt, t[i + 1] == A.lt {
                if t[i + 2] == A.lt {
                    out.add(i, i + 3, .punctuation)
                    i += 3
                    continue
                }
                var k = i + 2
                var flags: UInt8 = 0
                if t[k] == A.minus { flags |= Self.stripTabs; k += 1 }
                let operatorEnd = k
                k = t.skipSpaces(k, end: end)
                var quote: UInt16 = 0
                if t[k] == A.squote || t[k] == A.dquote || t[k] == A.backslash { quote = t[k]; flags |= Self.quoted; k += 1 }
                let wordStart = k
                let wordEnd = t.identEnd(wordStart, end: end, extra: A.minus)
                if wordEnd > wordStart {
                    out.add(i, operatorEnd, .punctuation)
                    let tokenEnd = quote != 0 && quote != A.backslash && t[wordEnd] == quote ? wordEnd + 1 : wordEnd
                    out.add(quote != 0 ? wordStart - 1 : wordStart, tokenEnd, .directive)
                    heredoc = (t.text(wordStart, wordEnd), flags)
                    i = tokenEnd
                    continue
                }
            }
            if A.isDigit(c), !A.isIdentPart(t[i - 1]) {
                var k = i
                while k < end, A.isDigit(t[k]) { k += 1 }
                if !A.isIdentPart(t[k]), t[k] != A.dot, t[k] != A.minus {
                    out.add(i, k, .number)
                    i = k
                    command = false
                    continue
                }
            }
            if A.isIdentStart(c) {
                let k = t.identEnd(i, end: end, extra: A.minus)
                let word = t.text(i, k)
                // `NAME=value` (also after `export` / `local` / `readonly`).
                if t[k] == A.equals, !word.contains("-"), A.isIdentStart(c) {
                    out.add(i, k, .property)
                    out.add(k, k + 1, .punctuation)
                    i = k + 1
                    continue
                }
                if Keywords.shell.contains(word), command || word == "in" || word == "do" || word == "then" {
                    out.add(i, k, .keyword)
                    command = word != "in"
                    if word == "function" {
                        let nameStart = t.skipSpaces(k, end: end)
                        let nameEnd = t.identEnd(nameStart, end: end, extra: A.minus)
                        out.add(nameStart, nameEnd, .function)
                        i = max(k, nameEnd)
                        command = false
                        continue
                    }
                } else if t[t.skipSpaces(k, end: end)] == A.lparen, t[t.skipSpaces(k, end: end) + 1] == A.rparen {
                    out.add(i, k, .function)
                    command = false
                } else if command, Keywords.shellBuiltins.contains(word) {
                    out.add(i, k, .function)
                    command = false
                } else {
                    command = false
                }
                i = k
                continue
            }
            switch c {
            case A.semicolon, A.pipe, A.amp, A.lparen, A.lbrace, A.bang:
                command = true
                out.add(i, i + 1, .punctuation)
            case A.rparen, A.rbrace, A.lbracket, A.rbracket, A.lt, A.gt, A.equals:
                out.add(i, i + 1, .punctuation)
            default:
                // Options (`-x`, `--flag`), paths and globs stay plain.
                var k = i + 1
                while k < end, !A.isSpace(t[k]), t[k] != A.semicolon, t[k] != A.pipe, t[k] != A.dquote, t[k] != A.squote,
                      t[k] != A.dollar, t[k] != A.rparen { k += 1 }
                command = false
                i = k
                continue
            }
            i += 1
        }
        if let heredoc, s.mode == Mode.code {
            s.mode = Mode.heredoc
            s.delimiter = heredoc.word
            s.flags = heredoc.flags
        }
    }

    /// `$VAR`, `${…}`, `$1`, `$?`, `$(` (the substitution's own text stays code).
    private func variable(_ t: LineText, _ i: Int, _ end: Int, _ out: inout TokenSink) -> Int {
        let next = t[i + 1]
        if next == A.lbrace {
            let close = t.find(unit: A.rbrace, from: i + 2, end: end).map { $0 + 1 } ?? end
            out.add(i, close, .property)
            return close
        }
        if next == A.lparen {
            out.add(i, t[i + 2] == A.lparen ? i + 3 : i + 2, .punctuation)
            return t[i + 2] == A.lparen ? i + 3 : i + 2
        }
        if A.isIdentStart(next) {
            let nameEnd = t.identEnd(i + 1, end: end)
            out.add(i, nameEnd, .property)
            return nameEnd
        }
        if A.isDigit(next) || next == A.question || next == A.hash || next == A.at || next == A.star || next == A.dollar
            || next == A.bang || next == A.minus {
            out.add(i, i + 2, .property)
            return i + 2
        }
        out.add(i, i + 1, .punctuation)
        return i + 1
    }

    /// A double-quoted run (or a heredoc line when `closeAt` is 0): string with `$` expansions as
    /// properties. Returns the index after the closing quote and whether it closed.
    private func expanding(_ t: LineText, from: Int, tokenStart: Int, _ end: Int, closeAt quote: UInt16,
                           _ out: inout TokenSink) -> (Int, Bool) {
        var runStart = tokenStart
        var j = from
        while j < end {
            let c = t[j]
            if c == A.backslash { j += 2; continue }
            if quote != 0, c == quote {
                out.add(runStart, j + 1, .string)
                return (j + 1, true)
            }
            if c == A.dollar, A.isIdentStart(t[j + 1]) || t[j + 1] == A.lbrace || A.isDigit(t[j + 1]) {
                out.add(runStart, j, .string)
                var k: Int
                if t[j + 1] == A.lbrace {
                    k = t.find(unit: A.rbrace, from: j + 2, end: end).map { $0 + 1 } ?? end
                } else if A.isDigit(t[j + 1]) {
                    k = j + 2
                } else {
                    k = t.identEnd(j + 1, end: end)
                }
                out.add(j, k, .property)
                runStart = k
                j = k
                continue
            }
            j += 1
        }
        out.add(runStart, end, .string)
        return (end, false)
    }
}
