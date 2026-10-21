import Foundation

/// The incremental highlighter behind the code view: the start state of every line, which of
/// them are known to be right, and which lines currently show their tokens.
///
/// After an edit only the lines from the edited one on are lexed again, and only until a computed
/// line-start state equals the one cached before the edit (past the edited lines): from there the
/// cached states, and the colors of the lines after them, are right again. Lexing is lazy: it
/// stops at the end of the window the view needs (the visible lines plus a margin) and resumes when
/// the view scrolls further.
final class HighlightModel {
    var highlighter: SyntaxHighlighter

    /// `states[i]`: the state line `i` starts in; right for `i < validCount`.
    private(set) var states: [LexState] = [.initial]
    private(set) var validCount = 1
    /// Cached states in `convergeFloor ..< staleUntil` may be reused once a recomputed state
    /// matches (they were lexed from the same text, which no edit since has touched).
    private var convergeFloor = 0
    private var staleUntil = 0
    /// Lines whose temporary attributes show their current tokens.
    private(set) var colored = IndexSet()
    /// Lines lexed since the counter was reset (tests: an edit re-lexes only what it must).
    var lexedLineCount = 0

    private var buffer = [UInt16](repeating: 0, count: 256)

    init(highlighter: SyntaxHighlighter) {
        self.highlighter = highlighter
    }

    func reset(lineCount: Int) {
        states = Array(repeating: .initial, count: max(1, lineCount))
        validCount = 1
        convergeFloor = 0
        staleUntil = 0
        colored = IndexSet()
    }

    /// Forgets the colors of every line (the language or the token colors changed).
    func uncolorAll() {
        colored = IndexSet()
    }

    func uncolor(_ lines: Range<Int>) {
        colored.remove(integersIn: lines)
    }

    /// Splices the cached states and colors for a text edit (no lexing here: edits may arrive while
    /// an input method composes, when nothing may be restyled).
    func edit(_ edit: LineIndex.Edit) {
        let first = edit.line
        let oldEnd = first + edit.oldCount
        let newFloor = first + edit.newCount
        func shifted(_ x: Int) -> Int {
            x <= first ? x : (x < oldEnd ? newFloor : x + edit.delta)
        }
        if oldEnd <= states.count {
            let placeholder = states[min(first, states.count - 1)]
            states.replaceSubrange(first + 1 ..< oldEnd, with: repeatElement(placeholder, count: edit.newCount - 1))
        }
        colored.remove(integersIn: first ..< max(first, oldEnd))
        if edit.delta != 0 { colored.shift(startingAt: oldEnd, by: edit.delta) }

        if first + 1 < validCount {
            staleUntil = shifted(validCount)
            convergeFloor = newFloor
            validCount = first + 1
        } else if staleUntil > 0 {
            let floor = shifted(convergeFloor)
            let until = shifted(staleUntil)
            convergeFloor = first < until ? max(floor, newFloor) : floor
            staleUntil = until
        }
        if staleUntil <= convergeFloor {
            staleUntil = 0
            convergeFloor = 0
        }
        validCount = min(validCount, states.count)
    }

    /// Makes the start states right through `window`'s last line and gives every line of `window`
    /// its tokens (`apply` sets them on the text). `maxGap`: when the first window line lies further
    /// than that beyond the known states (huge files), its lines are lexed from the initial state
    /// instead of lexing everything above them.
    func ensure(window: Range<Int>, text: NSString, lines: LineIndex, maxGap: Int? = nil,
                apply: (Int, [(NSRange, SyntaxToken)]) -> Void) {
        let lineCount = min(lines.count, states.count)
        let window = max(0, window.lowerBound) ..< min(window.upperBound, lineCount)
        guard !window.isEmpty else { return }
        if let maxGap, window.lowerBound - validCount > maxGap {
            var state = LexState.initial
            for line in window {
                let result = lex(line, state: state, text: text, lines: lines)
                state = result.endState
                if !colored.contains(line) {
                    apply(line, result.tokens)
                    colored.insert(line)
                }
            }
            return
        }
        while validCount < window.upperBound {
            let line = validCount - 1
            let result = lex(line, state: states[line], text: text, lines: lines)
            if window.contains(line), !colored.contains(line) {
                apply(line, result.tokens)
                colored.insert(line)
            }
            let next = line + 1
            guard next < lineCount else {
                validCount = lineCount
                break
            }
            if next >= convergeFloor, next < staleUntil, states[next] == result.endState {
                validCount = min(staleUntil, lineCount)
                staleUntil = 0
                convergeFloor = 0
                continue
            }
            if states[next] != result.endState {
                states[next] = result.endState
                colored.remove(next)
            }
            validCount = next + 1
        }
        for line in window where !colored.contains(line) {
            let result = lex(line, state: states[line], text: text, lines: lines)
            apply(line, result.tokens)
            colored.insert(line)
        }
    }

    /// The tokens of `line` from its cached start state (callers made it valid with `ensure`).
    func tokens(of line: Int, text: NSString, lines: LineIndex) -> [(NSRange, SyntaxToken)] {
        guard line < states.count else { return [] }
        return lex(line, state: states[line], text: text, lines: lines).tokens
    }

    func state(at line: Int) -> LexState {
        line < states.count ? states[line] : .initial
    }

    private func lex(_ line: Int, state: LexState, text: NSString, lines: LineIndex) -> (tokens: [(NSRange, SyntaxToken)], endState: LexState) {
        lexedLineCount += 1
        let range = lines.range(of: line)
        if buffer.count < range.length { buffer = [UInt16](repeating: 0, count: max(range.length, buffer.count * 2)) }
        return buffer.withUnsafeMutableBufferPointer { units in
            if range.length > 0, let base = units.baseAddress {
                text.getCharacters(base, range: range)
            }
            let slice = UnsafeBufferPointer(rebasing: units[0 ..< range.length])
            return highlighter.tokens(units: slice, startState: state)
        }
    }
}
