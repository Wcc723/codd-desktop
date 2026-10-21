import Foundation

/// A highlighted run's class; `CodeEditorStyle` maps each to the FileEditor artboard's color
/// (`.k .s .cm .nu .p .tg .at .dv .fn .pr`, `plain` is the code's base color).
public enum SyntaxToken: Sendable {
    case keyword, string, comment, number, punctuation, tag, attribute, directive, function, property, plain
}

/// What a lexer knows at the start of a line: inside a block comment, a multi-line string, a tag, a
/// Vue `<script>` region, a JS template literal substitution… Lexing a line from its start state is
/// all a line needs, so the code view caches one state per line and re-lexes from the first edited
/// line only until a computed state equals the cached one again (D28).
///
/// The fields are lexer specific and opaque outside the package; two states are equal exactly when
/// every lexer would continue identically from them.
public struct LexState: Sendable, Hashable {
    public static let initial = LexState()

    public init() {}

    /// The lexer's mode: code, block comment, string kinds, markup tag, embedded region, …
    var mode: UInt8 = 0
    /// Lexer flags (JS: a regular expression may start here; markup: closing tag, directive value).
    var flags: UInt8 = 0
    /// Quote character, block comment nesting, raw string hash count or indentation.
    var aux: UInt16 = 0
    /// Brace depth inside template literal / JSX substitutions (0 while none is open).
    var braces: UInt16 = 0
    /// JSX element depth, CSS block depth, markup embedded-language choice.
    var depth: UInt16 = 0
    /// A text that ends the mode: a heredoc word, a raw string delimiter, a closing tag name, a fence.
    var delimiter: String = ""
    /// Return points of nested substitutions (JS template literals and JSX), innermost last.
    var stack: [UInt32] = []
    /// The state of an embedded language: Vue / HTML `<script>` and `<style>`, PHP code, Markdown fences.
    var embedded: EmbeddedLexState?
}

/// A boxed `LexState` of another language (the recursion `LexState` cannot hold inline).
final class EmbeddedLexState: Sendable, Hashable {
    let language: CodeLanguage
    let state: LexState

    init(_ language: CodeLanguage, _ state: LexState) {
        self.language = language
        self.state = state
    }

    static func == (lhs: EmbeddedLexState, rhs: EmbeddedLexState) -> Bool {
        lhs === rhs || (lhs.language == rhs.language && lhs.state == rhs.state)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(language)
        hasher.combine(state)
    }
}

/// Collects a line's tokens in order; drops empty and plain runs and merges touching runs of one
/// class (fewer temporary attribute runs).
struct TokenSink {
    var tokens: [(NSRange, SyntaxToken)] = []

    @inline(__always)
    mutating func add(_ start: Int, _ end: Int, _ token: SyntaxToken) {
        guard end > start, token != .plain else { return }
        if let last = tokens.last, last.1 == token, NSMaxRange(last.0) == start {
            tokens[tokens.count - 1].0.length = end - last.0.location
        } else {
            tokens.append((NSRange(location: start, length: end - start), token))
        }
    }
}
