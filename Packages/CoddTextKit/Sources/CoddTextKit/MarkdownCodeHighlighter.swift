import Foundation

/// A small generic lexer for fenced code in notes (the Notebook artboard's `.nb-ck` amber, `.nb-cs`
/// cyan, `.nb-cp` dim): keywords, strings, comments, numbers and braces for js / ts, css, swift,
/// python, shell, json and html. It is a reading aid, not a parser; unknown languages get nothing.
/// (The file editor has its own per-language lexers, CoddCodeEditor.)
public enum MarkdownCodeHighlighter {
    public enum Token: Sendable, Equatable {
        /// Amber: keywords, CSS at-rules and property names, HTML tag names, JSON keys.
        case keyword
        /// Cyan: string literals and CSS values.
        case string
        /// Cyan: numbers (with CSS units).
        case number
        /// Dimmer: comments.
        case comment
        /// Dim: `{ } [ ]`.
        case punctuation
    }

    /// Spans in UTF-16 offsets of `code`, sorted and non-overlapping.
    public static func spans(code: String, language: String) -> [(NSRange, Token)] {
        let units = Array(code.utf16)
        guard let lang = Language(name: language) else { return [] }
        var lexer = Lexer(units: units, language: lang)
        return lexer.run()
    }

    /// Whether `language` (a fence's first info word) has a lexer here.
    public static func supports(_ language: String) -> Bool {
        Language(name: language) != nil
    }

    enum Language {
        case javascript, css, swift, python, shell, json, html

        init?(name: String) {
            switch name.lowercased() {
            case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx": self = .javascript
            case "css", "scss", "less", "postcss": self = .css
            case "swift": self = .swift
            case "py", "python", "python3": self = .python
            case "sh", "bash", "zsh", "shell", "console", "shellscript", "fish": self = .shell
            case "json", "jsonc", "json5": self = .json
            case "html", "xml", "vue", "svg", "xhtml", "plist": self = .html
            default: return nil
            }
        }

        var keywords: Set<String> {
            switch self {
            case .javascript:
                ["const", "let", "var", "function", "return", "if", "else", "for", "while", "do", "switch", "case",
                 "break", "continue", "new", "class", "extends", "import", "export", "from", "default", "async",
                 "await", "try", "catch", "finally", "throw", "typeof", "instanceof", "in", "of", "this", "super",
                 "null", "undefined", "true", "false", "interface", "type", "enum", "implements", "public",
                 "private", "protected", "readonly", "static", "as", "yield", "void", "delete"]
            case .swift:
                ["let", "var", "func", "return", "if", "else", "guard", "for", "in", "while", "repeat", "switch",
                 "case", "default", "break", "continue", "struct", "class", "enum", "protocol", "extension",
                 "import", "public", "private", "fileprivate", "internal", "open", "static", "final", "init",
                 "deinit", "self", "Self", "super", "nil", "true", "false", "try", "throw", "throws", "rethrows",
                 "async", "await", "actor", "some", "any", "where", "inout", "mutating", "nonisolated", "override",
                 "lazy", "weak", "unowned", "defer", "do", "catch", "is", "as", "typealias", "associatedtype"]
            case .python:
                ["def", "return", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is", "import",
                 "from", "as", "class", "try", "except", "finally", "raise", "with", "lambda", "yield", "pass",
                 "break", "continue", "None", "True", "False", "global", "nonlocal", "async", "await", "del", "assert"]
            case .shell:
                ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac",
                 "function", "return", "export", "local", "readonly", "set", "unset", "source", "echo", "cd",
                 "exit", "trap", "shift", "true", "false"]
            case .json:
                ["true", "false", "null"]
            case .css, .html:
                []
            }
        }

        var lineComment: [UInt16]? {
            switch self {
            case .javascript, .swift, .json: Array("//".utf16)
            case .python, .shell: Array("#".utf16)
            // CSS has no line comments (and `url(http://…)` must not start one).
            case .css, .html: nil
            }
        }

        var blockComment: (open: [UInt16], close: [UInt16])? {
            switch self {
            case .javascript, .swift, .css, .json: (Array("/*".utf16), Array("*/".utf16))
            case .html: (Array("<!--".utf16), Array("-->".utf16))
            case .python, .shell: nil
            }
        }
    }

    struct Lexer {
        let units: [UInt16]
        let language: Language
        var result: [(NSRange, Token)] = []
        /// CSS: inside `{ … }` (declarations), and after `:` there (a value).
        var cssDepth = 0
        var cssInValue = false

        init(units: [UInt16], language: Language) {
            self.units = units
            self.language = language
        }

        mutating func emit(_ start: Int, _ end: Int, _ token: Token) {
            guard end > start else { return }
            result.append((NSRange(location: start, length: end - start), token))
        }

        func has(_ prefix: [UInt16], at index: Int) -> Bool {
            guard index + prefix.count <= units.count else { return false }
            for (offset, unit) in prefix.enumerated() where units[index + offset] != unit { return false }
            return true
        }

        static func isIdentStart(_ c: UInt16) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c == 0x24
        }

        static func isIdent(_ c: UInt16) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }

        mutating func run() -> [(NSRange, Token)] {
            var index = 0
            let count = units.count
            let keywords = language.keywords
            while index < count {
                let c = units[index]
                if let line = language.lineComment, has(line, at: index),
                   language != .shell || index == 0 || Unit.isWhitespace(units[index - 1]) {
                    var end = index
                    while end < count, units[end] != Unit.newline { end += 1 }
                    emit(index, end, .comment)
                    index = end
                    continue
                }
                if let block = language.blockComment, has(block.open, at: index) {
                    var end = index + block.open.count
                    while end < count, !has(block.close, at: end) { end += 1 }
                    end = min(count, end + block.close.count)
                    emit(index, end, .comment)
                    index = end
                    continue
                }
                if language == .html, c == Unit.less {
                    index = htmlTag(index)
                    continue
                }
                if c == Unit.quote || c == 0x27 || (c == Unit.backtick && language == .javascript) {
                    let end = stringEnd(index)
                    if language == .json, isJSONKey(after: end) {
                        emit(index, end, .keyword)
                    } else {
                        emit(index, end, .string)
                    }
                    index = end
                    continue
                }
                if language == .css {
                    index = css(index)
                    continue
                }
                if c == 0x7B || c == 0x7D || c == Unit.openBracket || c == Unit.closeBracket {
                    emit(index, index + 1, .punctuation)
                    index += 1
                    continue
                }
                if Unit.isDigit(c), index == 0 || !Self.isIdent(units[index - 1]) {
                    var end = index + 1
                    while end < count, Self.isIdent(units[end]) || units[end] == Unit.dot { end += 1 }
                    emit(index, end, .number)
                    index = end
                    continue
                }
                if Self.isIdentStart(c) || (c == 0x40 && language == .swift) {
                    var end = index + 1
                    while end < count, Self.isIdent(units[end]) { end += 1 }
                    let word = String(decoding: units[index ..< end], as: UTF16.self)
                    if keywords.contains(word) || (language == .swift && c == 0x40) { emit(index, end, .keyword) }
                    index = end
                    continue
                }
                index += 1
            }
            return result
        }

        func stringEnd(_ start: Int) -> Int {
            let quote = units[start]
            let count = units.count
            // Python triple quotes.
            if language == .python, start + 2 < count, units[start + 1] == quote, units[start + 2] == quote {
                var end = start + 3
                while end + 2 < count, !(units[end] == quote && units[end + 1] == quote && units[end + 2] == quote) { end += 1 }
                return min(count, end + 3)
            }
            var end = start + 1
            while end < count {
                let c = units[end]
                if c == Unit.backslash { end += 2; continue }
                if c == quote { return end + 1 }
                if c == Unit.newline, quote != Unit.backtick { return end }
                end += 1
            }
            return count
        }

        func isJSONKey(after end: Int) -> Bool {
            var index = end
            while index < units.count, Unit.isWhitespace(units[index]) { index += 1 }
            return index < units.count && units[index] == Unit.colon
        }

        /// `<tag attr="v">`, `</tag>`: the name amber, attribute values cyan.
        mutating func htmlTag(_ start: Int) -> Int {
            let count = units.count
            var index = start + 1
            if index < count, units[index] == 0x2F { index += 1 }
            let nameStart = index
            while index < count, Self.isIdent(units[index]) || units[index] == Unit.dash || units[index] == Unit.colon { index += 1 }
            guard index > nameStart else { return start + 1 }
            emit(nameStart, index, .keyword)
            while index < count, units[index] != Unit.greater {
                let c = units[index]
                if c == Unit.quote || c == 0x27 {
                    let end = stringEnd(index)
                    emit(index, end, .string)
                    index = end
                    continue
                }
                if c == Unit.less { return index }
                index += 1
            }
            return min(count, index + 1)
        }

        /// CSS: at-rules and property names amber, values and numbers cyan, braces dim.
        mutating func css(_ start: Int) -> Int {
            let count = units.count
            let c = units[start]
            if c == 0x7B {
                cssDepth += 1
                cssInValue = false
                emit(start, start + 1, .punctuation)
                return start + 1
            }
            if c == 0x7D {
                cssDepth = max(0, cssDepth - 1)
                cssInValue = false
                emit(start, start + 1, .punctuation)
                return start + 1
            }
            if c == 0x3B { cssInValue = false; return start + 1 }
            if c == 0x40 {
                var end = start + 1
                while end < count, Self.isIdent(units[end]) || units[end] == Unit.dash { end += 1 }
                emit(start, end, .keyword)
                return end
            }
            if c == Unit.colon, cssDepth > 0 {
                cssInValue = true
                return start + 1
            }
            let isNumberStart = Unit.isDigit(c) || (c == Unit.dot && start + 1 < count && Unit.isDigit(units[start + 1]))
            if isNumberStart, start == 0 || !(Self.isIdent(units[start - 1]) || units[start - 1] == Unit.dash) {
                var end = start + 1
                while end < count, Self.isIdent(units[end]) || units[end] == Unit.dot || units[end] == 0x25 { end += 1 }
                emit(start, end, .number)
                return end
            }
            if Self.isIdentStart(c) || c == Unit.dash {
                var end = start + 1
                while end < count, Self.isIdent(units[end]) || units[end] == Unit.dash { end += 1 }
                if cssDepth > 0 {
                    if cssInValue {
                        emit(start, end, .string)
                    } else {
                        var next = end
                        while next < count, Unit.isSpace(units[next]) { next += 1 }
                        if next < count, units[next] == Unit.colon { emit(start, end, .keyword) }
                    }
                }
                return end
            }
            if c == 0x23, cssInValue {
                var end = start + 1
                while end < count, Self.isIdent(units[end]) { end += 1 }
                emit(start, end, .number)
                return end
            }
            return start + 1
        }
    }
}
