import Foundation

/// What distinguishes the C-syntax languages for the shared lexer.
struct CFamilyConfig: Sendable {
    var keywords: Set<String>
    /// After these a `/` starts a regular expression and a `<` a JSX element (JS family).
    var expressionKeywords: Set<String> = []
    /// The identifier after one of these is a function name (`function`, `func`, `fn`, `fun`).
    var functionKeywords: Set<String> = []
    var slashComments = true
    var hashComments = false
    var nestedComments = false
    /// `"…"` may span lines (Rust, PHP).
    var multilineStrings = false
    var templateLiterals = false
    var backtickRawStrings = false
    var backtickIdentifiers = false
    var tripleQuoteStrings = false
    var swiftStrings = false
    var rustStrings = false
    var cppRawStrings = false
    var regexLiterals = false
    var jsx = false
    var annotations = false
    var objcAt = false
    var preprocessor = false
    var hashDirectives = false
    var rustAttributes = false
    var macroBang = false
    var dollarVariables = false
    var dollarInIdentifiers = false

    static let javascript = CFamilyConfig(
        keywords: Keywords.javascript, expressionKeywords: Keywords.jsExpressionKeywords,
        functionKeywords: ["function"], templateLiterals: true, regexLiterals: true, jsx: true, annotations: true,
        dollarInIdentifiers: true)
    static let typescript: CFamilyConfig = {
        var config = javascript
        config.keywords = Keywords.typescript
        config.jsx = false
        return config
    }()
    static let tsx: CFamilyConfig = {
        var config = typescript
        config.jsx = true
        return config
    }()
    static let swift = CFamilyConfig(
        keywords: Keywords.swift, functionKeywords: ["func"], nestedComments: true, backtickIdentifiers: true,
        tripleQuoteStrings: true, swiftStrings: true, annotations: true, hashDirectives: true)
    static let go = CFamilyConfig(keywords: Keywords.go, functionKeywords: ["func"], backtickRawStrings: true)
    static let rust = CFamilyConfig(
        keywords: Keywords.rust, functionKeywords: ["fn"], nestedComments: true, multilineStrings: true,
        rustStrings: true, rustAttributes: true, macroBang: true)
    static let c = CFamilyConfig(keywords: Keywords.c, preprocessor: true)
    static let cpp = CFamilyConfig(keywords: Keywords.cpp, cppRawStrings: true, preprocessor: true)
    static let objc = CFamilyConfig(keywords: Keywords.objc, objcAt: true, preprocessor: true)
    static let java = CFamilyConfig(
        keywords: Keywords.java, tripleQuoteStrings: true, annotations: true, dollarInIdentifiers: true)
    static let kotlin = CFamilyConfig(
        keywords: Keywords.kotlin, functionKeywords: ["fun"], nestedComments: true, backtickIdentifiers: true,
        tripleQuoteStrings: true, annotations: true)
    static let php = CFamilyConfig(
        keywords: Keywords.php, functionKeywords: ["function", "fn"], hashComments: true, multilineStrings: true,
        rustAttributes: true, dollarVariables: true)
}

/// One lexer for the C-syntax family: comments (nested where the language nests them), strings
/// of every kind the languages have (template literals with `${}` nesting, Go / Rust / C++ raw
/// strings, Swift / Kotlin / Java triple quotes), JS regular expression literals, JSX elements,
/// annotations, preprocessor lines, numbers, keywords and calls.
struct CFamilyLexer {
    let config: CFamilyConfig

    enum Mode {
        static let code: UInt8 = 0
        static let blockComment: UInt8 = 1
        static let string: UInt8 = 2
        static let tripleString: UInt8 = 3
        static let template: UInt8 = 4
        static let backtickRaw: UInt8 = 5
        static let rustRaw: UInt8 = 6
        static let cppRaw: UInt8 = 7
        static let jsxTag: UInt8 = 8
        static let jsxChildren: UInt8 = 9
    }

    /// `flags` bit 0: the previous token was an operand (a `/` divides, a `<` compares).
    static let afterOperand: UInt8 = 1
    /// `flags` bit 1: the JSX tag being read is a closing tag.
    static let closingTag: UInt8 = 2

    /// Stack entry kinds: the mode a closing `}` (or a JSX root's end) returns to.
    enum Return {
        static let template: UInt32 = 1
        static let jsxRoot: UInt32 = 2
        static let jsxChild: UInt32 = 3
        static let jsxAttribute: UInt32 = 4
    }

    private static let literalKeywords: Set<String> = [
        "this", "true", "false", "null", "undefined", "super", "self", "Self", "nil", "NULL", "nullptr", "YES", "NO",
    ]

    func lex(_ t: LineText, from: Int, to end: Int, state s: inout LexState, out: inout TokenSink) {
        var i = from
        let firstNonSpace = t.skipSpaces(from, end: end)
        var pendingFunction = false
        while i < end {
            let before = i
            switch s.mode {
            case Mode.blockComment: i = blockComment(t, i, end, tokenStart: i, &s, &out)
            case Mode.string: i = continueString(t, i, end, &s, &out)
            case Mode.tripleString: i = tripleString(t, i, end, tokenStart: i, &s, &out)
            case Mode.template: i = template(t, i, end, tokenStart: i, &s, &out)
            case Mode.backtickRaw: i = backtickRaw(t, i, end, tokenStart: i, &s, &out)
            case Mode.rustRaw: i = rustRaw(t, i, end, tokenStart: i, &s, &out)
            case Mode.cppRaw: i = cppRaw(t, i, end, tokenStart: i, &s, &out)
            case Mode.jsxTag: i = jsxTag(t, i, end, &s, &out)
            case Mode.jsxChildren: i = jsxChildren(t, i, end, &s, &out)
            default: i = code(t, i, end, firstNonSpace: firstNonSpace, pendingFunction: &pendingFunction, &s, &out)
            }
            if i <= before { i = before + 1 }
        }
    }

    // MARK: Code

    private func setOperand(_ s: inout LexState, _ operand: Bool) {
        if operand { s.flags |= Self.afterOperand } else { s.flags &= ~Self.afterOperand }
    }

    private func code(_ t: LineText, _ i: Int, _ end: Int, firstNonSpace: Int, pendingFunction: inout Bool,
                      _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let c = t[i]
        if A.isSpace(c) { return t.skipSpaces(i, end: end) }
        let wasPending = pendingFunction
        pendingFunction = false

        if c == A.slash {
            if config.slashComments, t[i + 1] == A.slash {
                out.add(i, end, .comment)
                return end
            }
            if t[i + 1] == A.star {
                s.mode = Mode.blockComment
                s.aux = 1
                return blockComment(t, i + 2, end, tokenStart: i, &s, &out)
            }
            if config.regexLiterals, s.flags & Self.afterOperand == 0, let close = regexEnd(t, i, end) {
                out.add(i, close, .string)
                setOperand(&s, true)
                return close
            }
        }
        if c == A.hash {
            if config.preprocessor, i == firstNonSpace {
                let nameStart = t.skipSpaces(i + 1, end: end)
                let nameEnd = t.identEnd(nameStart, end: end)
                out.add(i, nameEnd, .directive)
                let name = t.text(nameStart, nameEnd)
                if name == "include" || name == "import" {
                    let open = t.skipSpaces(nameEnd, end: end)
                    if t[open] == A.lt, let close = t.find(unit: A.gt, from: open + 1, end: end) {
                        out.add(open, close + 1, .string)
                        return close + 1
                    }
                }
                return nameEnd
            }
            if config.rustAttributes, t[i + 1] == A.lbracket || (t[i + 1] == A.bang && t[i + 2] == A.lbracket) {
                let close = bracketEnd(t, from: t[i + 1] == A.bang ? i + 2 : i + 1, end)
                out.add(i, close, .directive)
                return close
            }
            if config.swiftStrings {
                var hashes = 0
                while t[i + hashes] == A.hash { hashes += 1 }
                if t[i + hashes] == A.dquote {
                    return swiftRawString(t, i, hashes: hashes, end, &s, &out)
                }
            }
            if config.hashDirectives, A.isIdentStart(t[i + 1]) {
                let nameEnd = t.identEnd(i + 1, end: end)
                out.add(i, nameEnd, .directive)
                return nameEnd
            }
            if config.hashComments {
                out.add(i, end, .comment)
                return end
            }
        }
        if c == A.dquote {
            if config.tripleQuoteStrings, t.has("\"\"\"", at: i) {
                s.mode = Mode.tripleString
                s.aux = 0
                return tripleString(t, i + 3, end, tokenStart: i, &s, &out)
            }
            return string(t, i, tokenStart: i, quote: A.dquote, end, &s, &out)
        }
        if c == A.squote {
            if config.rustStrings, A.isIdentStart(t[i + 1]), t[i + 2] != A.squote {
                let nameEnd = t.identEnd(i + 1, end: end)
                if t[nameEnd] != A.squote {
                    out.add(i, nameEnd, .keyword)   // a lifetime ('a, 'static)
                    return nameEnd
                }
            }
            return string(t, i, tokenStart: i, quote: A.squote, end, &s, &out)
        }
        if c == A.backtick {
            if config.templateLiterals {
                out.add(i, i + 1, .string)
                s.mode = Mode.template
                return template(t, i + 1, end, tokenStart: i + 1, &s, &out)
            }
            if config.backtickRawStrings {
                s.mode = Mode.backtickRaw
                return backtickRaw(t, i + 1, end, tokenStart: i, &s, &out)
            }
            if config.backtickIdentifiers, let close = t.find(unit: A.backtick, from: i + 1, end: end) {
                setOperand(&s, true)
                return close + 1
            }
        }
        if c == A.at {
            if config.objcAt {
                if t[i + 1] == A.dquote { return string(t, i + 1, tokenStart: i, quote: A.dquote, end, &s, &out) }
                if A.isIdentStart(t[i + 1]) {
                    let nameEnd = t.identEnd(i + 1, end: end)
                    out.add(i, nameEnd, Keywords.objcAt.contains(t.text(i + 1, nameEnd)) ? .keyword : .directive)
                    return nameEnd
                }
            }
            if config.annotations, A.isIdentStart(t[i + 1]) {
                let nameEnd = t.identEnd(i + 1, end: end, extra: A.dot)
                out.add(i, nameEnd, .directive)
                return nameEnd
            }
            out.add(i, i + 1, .punctuation)
            return i + 1
        }
        if c == A.dollar, config.dollarVariables, A.isIdentStart(t[i + 1]) {
            let nameEnd = t.identEnd(i + 1, end: end)
            out.add(i, nameEnd, .property)
            setOperand(&s, true)
            return nameEnd
        }
        if A.isDigit(c) || (c == A.dot && A.isDigit(t[i + 1])) {
            let numberEnd = t.numberEnd(i, end: end)
            out.add(i, numberEnd, .number)
            setOperand(&s, true)
            return numberEnd
        }
        if A.isIdentStart(c) || (config.dollarInIdentifiers && c == A.dollar) {
            return identifier(t, i, end, wasPending: wasPending, pendingFunction: &pendingFunction, &s, &out)
        }
        if c == A.lt, config.jsx, s.flags & Self.afterOperand == 0, A.isIdentStart(t[i + 1]) || t[i + 1] == A.gt {
            s.stack.append(Self.entry(Return.jsxRoot, braces: s.braces, depth: s.depth))
            s.depth = 0
            s.flags &= ~Self.closingTag
            out.add(i, i + 1, .punctuation)
            let nameEnd = t.identEnd(i + 1, end: end, extra: A.minus, extra2: A.dot)
            out.add(i + 1, nameEnd, .tag)
            s.mode = Mode.jsxTag
            return nameEnd
        }
        switch c {
        case A.lbrace:
            if !s.stack.isEmpty { s.braces &+= 1 }
            out.add(i, i + 1, .punctuation)
            setOperand(&s, false)
            return i + 1
        case A.rbrace:
            out.add(i, i + 1, .punctuation)
            if let top = s.stack.last, s.braces > 0, Self.braces(top) == s.braces - 1 {
                let kind = Self.kind(top)
                if kind == Return.template || kind == Return.jsxChild || kind == Return.jsxAttribute {
                    s.stack.removeLast()
                    s.braces = Self.braces(top)
                    s.depth = Self.depth(top)
                    s.mode = kind == Return.template ? Mode.template : (kind == Return.jsxChild ? Mode.jsxChildren : Mode.jsxTag)
                    return i + 1
                }
            }
            if s.braces > 0, !s.stack.isEmpty { s.braces -= 1 }
            setOperand(&s, false)
            return i + 1
        case A.rparen, A.rbracket:
            out.add(i, i + 1, .punctuation)
            setOperand(&s, true)
            return i + 1
        case A.dot:
            return i + 1
        case A.lparen, A.lbracket, A.semicolon, A.comma, A.colon, A.question, A.tilde, A.bang, A.percent, A.caret,
             A.amp, A.star, A.minus, A.plus, A.equals, A.lt, A.gt, A.pipe, A.slash, A.backslash, A.hash:
            var j = i + 1
            // Operator runs (`=>`, `===`, `&&`) are one token; brackets stand alone.
            if c != A.lparen, c != A.lbracket {
                while j < end, Self.isOperator(t[j]) { j += 1 }
            }
            out.add(i, j, .punctuation)
            setOperand(&s, false)
            return j
        default:
            return i + 1
        }
    }

    private static func isOperator(_ c: UInt16) -> Bool {
        switch c {
        case A.equals, A.gt, A.lt, A.bang, A.amp, A.pipe, A.plus, A.minus, A.star, A.percent, A.caret, A.tilde,
             A.question, A.colon:
            true
        default:
            false
        }
    }

    private func identifier(_ t: LineText, _ i: Int, _ end: Int, wasPending: Bool, pendingFunction: inout Bool,
                            _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let k = t.identEnd(i, end: end, extra: config.dollarInIdentifiers ? A.dollar : 0)
        let next = t[k]
        if config.rustStrings, k - i <= 2 {
            let word = t.text(i, k)
            if word == "r" || word == "br", next == A.dquote || next == A.hash {
                var hashes = 0
                while t[k + hashes] == A.hash { hashes += 1 }
                if t[k + hashes] == A.dquote {
                    s.mode = Mode.rustRaw
                    s.aux = UInt16(hashes)
                    return rustRaw(t, k + hashes + 1, end, tokenStart: i, &s, &out)
                }
            }
            if word == "b", next == A.dquote || next == A.squote {
                return string(t, k, tokenStart: i, quote: next, end, &s, &out)
            }
        }
        if (config.cppRawStrings || config.preprocessor), next == A.dquote, k - i <= 3 {
            let word = t.text(i, k)
            if config.cppRawStrings, ["R", "u8R", "uR", "UR", "LR"].contains(word),
               let paren = t.find(unit: A.lparen, from: k + 1, end: min(end, k + 18)) {
                s.mode = Mode.cppRaw
                s.delimiter = ")" + t.text(k + 1, paren) + "\""
                return cppRaw(t, paren + 1, end, tokenStart: i, &s, &out)
            }
            if ["L", "u", "U", "u8"].contains(word) {
                return string(t, k, tokenStart: i, quote: A.dquote, end, &s, &out)
            }
        }
        if config.macroBang, next == A.bang, t[k + 1] != A.equals {
            out.add(i, k + 1, .function)
            setOperand(&s, false)
            return k + 1
        }
        let word = t.text(i, k)
        // A member (`record.type`, `a?.default`) is never a keyword.
        let isMember = t[i - 1] == A.dot && t[i - 2] != A.dot
        if !isMember, config.keywords.contains(word) {
            out.add(i, k, .keyword)
            pendingFunction = config.functionKeywords.contains(word)
            setOperand(&s, Self.literalKeywords.contains(word))
            if config.expressionKeywords.contains(word) { setOperand(&s, false) }
            return k
        }
        if wasPending || t[t.skipSpaces(k, end: end)] == A.lparen {
            out.add(i, k, .function)
        }
        setOperand(&s, true)
        return k
    }

    /// The end of a regular expression literal starting at `start` (a `/`), flags included; nil
    /// when the line ends first (then it was a division).
    private func regexEnd(_ t: LineText, _ start: Int, _ end: Int) -> Int? {
        var j = start + 1
        var inClass = false
        guard t[j] != A.slash, t[j] != A.star else { return nil }
        while j < end {
            let c = t[j]
            if c == A.backslash { j += 2; continue }
            if c == A.lbracket { inClass = true } else if c == A.rbracket { inClass = false } else if c == A.slash, !inClass {
                j += 1
                while j < end, A.isAsciiLetter(t[j]) { j += 1 }
                return j
            }
            j += 1
        }
        return nil
    }

    /// The index after the `]` closing the `[` at `open` (nested brackets and strings skipped).
    private func bracketEnd(_ t: LineText, from open: Int, _ end: Int) -> Int {
        var depth = 0
        var j = open
        while j < end {
            let c = t[j]
            if c == A.dquote, let close = t.stringEnd(j, quote: A.dquote, end: end) { j = close; continue }
            if c == A.lbracket { depth += 1 } else if c == A.rbracket {
                depth -= 1
                if depth == 0 { return j + 1 }
            }
            j += 1
        }
        return end
    }

    // MARK: Strings

    private func string(_ t: LineText, _ quoteIndex: Int, tokenStart: Int, quote: UInt16, _ end: Int,
                        _ s: inout LexState, _ out: inout TokenSink) -> Int {
        if let close = closing(t, from: quoteIndex + 1, quote: quote, end) {
            out.add(tokenStart, close, .string)
            setOperand(&s, true)
            return close
        }
        out.add(tokenStart, end, .string)
        if config.multilineStrings || (end > 0 && t[end - 1] == A.backslash) {
            s.mode = Mode.string
            s.aux = quote
        }
        return end
    }

    private func continueString(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        if let close = closing(t, from: i, quote: s.aux, end) {
            out.add(i, close, .string)
            s.mode = Mode.code
            s.aux = 0
            setOperand(&s, true)
            return close
        }
        out.add(i, end, .string)
        if !config.multilineStrings, !(end > 0 && t[end - 1] == A.backslash) {
            s.mode = Mode.code
            s.aux = 0
        }
        return end
    }

    /// The index after the closing quote, scanning from `from`; Swift `\( … )` interpolations are
    /// skipped whole (their parentheses may hold quotes).
    private func closing(_ t: LineText, from: Int, quote: UInt16, _ end: Int) -> Int? {
        var j = from
        while j < end {
            let c = t[j]
            if c == A.backslash {
                if config.swiftStrings, t[j + 1] == A.lparen {
                    var depth = 0
                    j += 1
                    while j < end {
                        if t[j] == A.lparen { depth += 1 } else if t[j] == A.rparen {
                            depth -= 1
                            if depth == 0 { break }
                        }
                        j += 1
                    }
                    j += 1
                    continue
                }
                j += 2
                continue
            }
            if c == quote { return j + 1 }
            j += 1
        }
        return nil
    }

    /// `"""` … `"""` (Swift `#"""` … `"""#` with `aux` hashes); escapes skipped unless raw.
    private func tripleString(_ t: LineText, _ i: Int, _ end: Int, tokenStart: Int, _ s: inout LexState,
                              _ out: inout TokenSink) -> Int {
        let hashes = Int(s.aux)
        var j = i
        while j < end {
            if t[j] == A.backslash, hashes == 0 { j += 2; continue }
            if t.has("\"\"\"", at: j) {
                var k = 0
                while k < hashes, t[j + 3 + k] == A.hash { k += 1 }
                if k == hashes {
                    let close = j + 3 + hashes
                    out.add(tokenStart, close, .string)
                    s.mode = Mode.code
                    s.aux = 0
                    setOperand(&s, true)
                    return close
                }
            }
            j += 1
        }
        out.add(tokenStart, end, .string)
        return end
    }

    /// Swift `#"…"#` (single line) or `#"""` multi-line raw strings.
    private func swiftRawString(_ t: LineText, _ i: Int, hashes: Int, _ end: Int, _ s: inout LexState,
                                _ out: inout TokenSink) -> Int {
        let quote = i + hashes
        if t.has("\"\"\"", at: quote) {
            s.mode = Mode.tripleString
            s.aux = UInt16(hashes)
            return tripleString(t, quote + 3, end, tokenStart: i, &s, &out)
        }
        var j = quote + 1
        while j < end {
            if t[j] == A.dquote {
                var k = 0
                while k < hashes, t[j + 1 + k] == A.hash { k += 1 }
                if k == hashes {
                    out.add(i, j + 1 + hashes, .string)
                    setOperand(&s, true)
                    return j + 1 + hashes
                }
            }
            j += 1
        }
        out.add(i, end, .string)
        return end
    }

    /// JS template literal text: `${` opens a substitution whose `}` returns here.
    private func template(_ t: LineText, _ i: Int, _ end: Int, tokenStart: Int, _ s: inout LexState,
                          _ out: inout TokenSink) -> Int {
        var j = i
        while j < end {
            let c = t[j]
            if c == A.backslash { j += 2; continue }
            if c == A.backtick {
                out.add(tokenStart, j + 1, .string)
                s.mode = Mode.code
                setOperand(&s, true)
                return j + 1
            }
            if c == A.dollar, t[j + 1] == A.lbrace {
                out.add(tokenStart, j, .string)
                out.add(j, j + 2, .punctuation)
                s.stack.append(Self.entry(Return.template, braces: s.braces, depth: s.depth))
                s.braces &+= 1
                s.mode = Mode.code
                setOperand(&s, false)
                return j + 2
            }
            j += 1
        }
        out.add(tokenStart, min(j, end), .string)
        return end
    }

    private func backtickRaw(_ t: LineText, _ i: Int, _ end: Int, tokenStart: Int, _ s: inout LexState,
                             _ out: inout TokenSink) -> Int {
        if let close = t.find(unit: A.backtick, from: i, end: end) {
            out.add(tokenStart, close + 1, .string)
            s.mode = Mode.code
            setOperand(&s, true)
            return close + 1
        }
        out.add(tokenStart, end, .string)
        return end
    }

    /// Rust `r#"…"#`: a `"` followed by `aux` hashes closes it.
    private func rustRaw(_ t: LineText, _ i: Int, _ end: Int, tokenStart: Int, _ s: inout LexState,
                         _ out: inout TokenSink) -> Int {
        let hashes = Int(s.aux)
        var j = i
        while j < end {
            if t[j] == A.dquote {
                var k = 0
                while k < hashes, t[j + 1 + k] == A.hash { k += 1 }
                if k == hashes {
                    out.add(tokenStart, j + 1 + hashes, .string)
                    s.mode = Mode.code
                    s.aux = 0
                    setOperand(&s, true)
                    return j + 1 + hashes
                }
            }
            j += 1
        }
        out.add(tokenStart, end, .string)
        return end
    }

    /// C++ `R"delim(…)delim"`: `delimiter` holds `)delim"`.
    private func cppRaw(_ t: LineText, _ i: Int, _ end: Int, tokenStart: Int, _ s: inout LexState,
                        _ out: inout TokenSink) -> Int {
        let close = Array(s.delimiter.utf16)
        var j = i
        while j + close.count <= end {
            var match = true
            for k in 0 ..< close.count where t[j + k] != close[k] { match = false; break }
            if match {
                out.add(tokenStart, j + close.count, .string)
                s.mode = Mode.code
                s.delimiter = ""
                setOperand(&s, true)
                return j + close.count
            }
            j += 1
        }
        out.add(tokenStart, end, .string)
        return end
    }

    private func blockComment(_ t: LineText, _ i: Int, _ end: Int, tokenStart: Int, _ s: inout LexState,
                              _ out: inout TokenSink) -> Int {
        var j = i
        while j < end {
            if config.nestedComments, t[j] == A.slash, t[j + 1] == A.star {
                s.aux &+= 1
                j += 2
                continue
            }
            if t[j] == A.star, t[j + 1] == A.slash {
                j += 2
                s.aux = s.aux > 0 ? s.aux - 1 : 0
                if s.aux == 0 {
                    out.add(tokenStart, j, .comment)
                    s.mode = Mode.code
                    return j
                }
                continue
            }
            j += 1
        }
        out.add(tokenStart, end, .comment)
        return end
    }

    // MARK: JSX

    private func popJSXRoot(_ s: inout LexState) {
        guard let top = s.stack.last, Self.kind(top) == Return.jsxRoot else {
            s.mode = Mode.code
            s.depth = 0
            return
        }
        s.stack.removeLast()
        s.braces = Self.braces(top)
        s.depth = Self.depth(top)
        s.mode = Mode.code
        s.flags &= ~Self.closingTag
        setOperand(&s, true)
    }

    private func jsxTag(_ t: LineText, _ start: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        let i = t.skipSpaces(start, end: end)
        guard i < end else { return end }
        let c = t[i]
        let closing = s.flags & Self.closingTag != 0
        if c == A.slash, t[i + 1] == A.gt {
            out.add(i, i + 2, .punctuation)
            s.flags &= ~Self.closingTag
            if s.depth == 0 { popJSXRoot(&s) } else { s.mode = Mode.jsxChildren }
            return i + 2
        }
        if c == A.gt {
            out.add(i, i + 1, .punctuation)
            s.flags &= ~Self.closingTag
            if closing {
                if s.depth > 0 { s.depth -= 1 }
                if s.depth == 0 { popJSXRoot(&s) } else { s.mode = Mode.jsxChildren }
            } else {
                s.depth &+= 1
                s.mode = Mode.jsxChildren
            }
            return i + 1
        }
        if c == A.lbrace {
            out.add(i, i + 1, .punctuation)
            s.stack.append(Self.entry(Return.jsxAttribute, braces: s.braces, depth: s.depth))
            s.braces &+= 1
            s.mode = Mode.code
            setOperand(&s, false)
            return i + 1
        }
        if c == A.dquote || c == A.squote {
            let close = t.stringEnd(i, quote: c, end: end, escapes: false) ?? end
            out.add(i, close, .string)
            return close
        }
        if c == A.equals {
            out.add(i, i + 1, .punctuation)
            return i + 1
        }
        if A.isIdentStart(c) {
            let nameEnd = t.identEnd(i, end: end, extra: A.minus, extra2: A.colon)
            out.add(i, nameEnd, .attribute)
            return nameEnd
        }
        return i + 1
    }

    private func jsxChildren(_ t: LineText, _ i: Int, _ end: Int, _ s: inout LexState, _ out: inout TokenSink) -> Int {
        var j = i
        while j < end {
            let c = t[j]
            if c == A.lbrace {
                out.add(j, j + 1, .punctuation)
                s.stack.append(Self.entry(Return.jsxChild, braces: s.braces, depth: s.depth))
                s.braces &+= 1
                s.mode = Mode.code
                setOperand(&s, false)
                return j + 1
            }
            if c == A.lt {
                if t[j + 1] == A.slash {
                    out.add(j, j + 2, .punctuation)
                    let nameEnd = t.identEnd(j + 2, end: end, extra: A.minus, extra2: A.dot)
                    out.add(j + 2, nameEnd, .tag)
                    s.flags |= Self.closingTag
                    s.mode = Mode.jsxTag
                    return nameEnd
                }
                if A.isIdentStart(t[j + 1]) || t[j + 1] == A.gt {
                    out.add(j, j + 1, .punctuation)
                    let nameEnd = t.identEnd(j + 1, end: end, extra: A.minus, extra2: A.dot)
                    out.add(j + 1, nameEnd, .tag)
                    s.flags &= ~Self.closingTag
                    s.mode = Mode.jsxTag
                    return nameEnd
                }
            }
            j += 1
        }
        return end
    }

    // MARK: Stack entries

    static func entry(_ kind: UInt32, braces: UInt16, depth: UInt16) -> UInt32 {
        (kind << 28) | (UInt32(braces & 0x3FFF) << 14) | UInt32(depth & 0x3FFF)
    }

    static func kind(_ entry: UInt32) -> UInt32 { entry >> 28 }
    static func braces(_ entry: UInt32) -> UInt16 { UInt16((entry >> 14) & 0x3FFF) }
    static func depth(_ entry: UInt32) -> UInt16 { UInt16(entry & 0x3FFF) }
}
