import Foundation

/// The lexer of every `CodeLanguage` (embedded regions call back in here).
enum Lexers {
    private static let javascript = CFamilyLexer(config: .javascript)
    private static let typescript = CFamilyLexer(config: .typescript)
    private static let tsx = CFamilyLexer(config: .tsx)
    private static let swift = CFamilyLexer(config: .swift)
    private static let go = CFamilyLexer(config: .go)
    private static let rust = CFamilyLexer(config: .rust)
    private static let c = CFamilyLexer(config: .c)
    private static let cpp = CFamilyLexer(config: .cpp)
    private static let objc = CFamilyLexer(config: .objc)
    private static let java = CFamilyLexer(config: .java)
    private static let kotlin = CFamilyLexer(config: .kotlin)

    static func lex(_ language: CodeLanguage, _ t: LineText, from: Int, to end: Int, state: inout LexState,
                    out: inout TokenSink) {
        switch language {
        case .javascript, .jsx: javascript.lex(t, from: from, to: end, state: &state, out: &out)
        case .typescript: typescript.lex(t, from: from, to: end, state: &state, out: &out)
        case .tsx: tsx.lex(t, from: from, to: end, state: &state, out: &out)
        case .swift: swift.lex(t, from: from, to: end, state: &state, out: &out)
        case .go: go.lex(t, from: from, to: end, state: &state, out: &out)
        case .rust: rust.lex(t, from: from, to: end, state: &state, out: &out)
        case .c: c.lex(t, from: from, to: end, state: &state, out: &out)
        case .cpp: cpp.lex(t, from: from, to: end, state: &state, out: &out)
        case .objc: objc.lex(t, from: from, to: end, state: &state, out: &out)
        case .java: java.lex(t, from: from, to: end, state: &state, out: &out)
        case .kotlin: kotlin.lex(t, from: from, to: end, state: &state, out: &out)
        case .php: MarkupLexer(flavor: .php).lex(t, from: from, to: end, state: &state, out: &out)
        case .vue: MarkupLexer(flavor: .vue).lex(t, from: from, to: end, state: &state, out: &out)
        case .html: MarkupLexer(flavor: .html).lex(t, from: from, to: end, state: &state, out: &out)
        case .xml: MarkupLexer(flavor: .xml).lex(t, from: from, to: end, state: &state, out: &out)
        case .css: CSSLexer(scss: false).lex(t, from: from, to: end, state: &state, out: &out)
        case .scss: CSSLexer(scss: true).lex(t, from: from, to: end, state: &state, out: &out)
        case .json: JSONLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .yaml: YAMLLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .toml: TOMLLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .python: PythonLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .ruby: RubyLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .shell: ShellLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .sql: SQLLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .markdown: MarkdownLexer().lex(t, from: from, to: end, state: &state, out: &out)
        case .plain: break
        }
    }
}

/// Native per-line highlighting (D28): `tokens(line:startState:)` lexes one line (no terminator)
/// from the state its previous line ended in and returns the line's runs (UTF-16 ranges within the
/// line, sorted, not overlapping, plain runs omitted) and the state the next line starts in.
/// Reversible behind this type: another engine (tree-sitter) could answer the same call.
public struct SyntaxHighlighter: Sendable {
    public let language: CodeLanguage

    public init(language: CodeLanguage) {
        self.language = language
    }

    public func tokens(line: String, startState: LexState) -> (tokens: [(NSRange, SyntaxToken)], endState: LexState) {
        var units = Array(line.utf16)
        // Line terminators are not part of a line; tolerate them anyway.
        while let last = units.last, last == A.lf || last == A.cr { units.removeLast() }
        return units.withUnsafeBufferPointer { tokens(units: $0, startState: startState) }
    }

    /// The same over UTF-16 units already in memory (the editor's text storage).
    func tokens(units: UnsafeBufferPointer<UInt16>, startState: LexState) -> (tokens: [(NSRange, SyntaxToken)], endState: LexState) {
        var state = startState
        var sink = TokenSink()
        let text = LineText(units: units)
        Lexers.lex(language, text, from: 0, to: text.count, state: &state, out: &sink)
        return (sink.tokens, state)
    }

    /// Every line of `text` from the initial state: line-start states and tokens (tests, samples).
    public func tokenize(_ text: String) -> [[(NSRange, SyntaxToken)]] {
        var state = LexState.initial
        return text.components(separatedBy: "\n").map { line in
            let result = tokens(line: line, startState: state)
            state = result.endState
            return result.tokens
        }
    }
}
