import AppKit
import Foundation
@testable import CoddCodeEditor

/// One `CodeEditorView` in a window that is never ordered on screen (it never becomes key, so no
/// caret blink timer runs and nothing takes focus), its text view first responder, callbacks recorded.
@MainActor
final class EditorHarness {
    let window: NSWindow
    let editor: CodeEditorView
    var textView: CodeTextView { editor.textView }

    var textChanges: [String] = []
    var carets: [CodeCaret] = []
    var finds: [(query: String, current: Int, total: Int)] = []
    var hunkActions: [(Int, HunkAction)] = []

    init(width: CGFloat = 900, height: CGFloat = 600, text: String = "", language: CodeLanguage = .plain,
         readOnly: Bool = false, plainMode: Bool = false) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        editor = CodeEditorView()
        editor.frame = NSRect(x: 0, y: 0, width: width, height: height)
        window.contentView = editor
        editor.onTextChange = { [weak self] in self?.textChanges.append($0) }
        editor.onCaretChange = { [weak self] in self?.carets.append($0) }
        editor.onFindChange = { [weak self] query, _, current, total in self?.finds.append((query, current, total)) }
        editor.onHunkAction = { [weak self] id, action in self?.hunkActions.append((id, action)) }
        editor.load(text, language: language, readOnly: readOnly, plainMode: plainMode)
        settle()
        window.makeFirstResponder(textView)
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    /// Layout plus the deferred work the editor queues on the run loop (flushes, overlay
    /// placement), run synchronously: spinning the run loop here would let Swift Testing start
    /// other main-actor tests in the middle of this one.
    func settle() {
        editor.layoutSubtreeIfNeeded()
        editor.performPendingWork()
        editor.layoutSubtreeIfNeeded()
    }

    func caret(at location: Int) {
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// An input method composition at the caret, as 注音 does (`ㄓㄨˋ` before conversion).
    func compose(_ marked: String = "ㄓㄨˋ") {
        textView.setMarkedText(marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Picks a candidate: the marked text is replaced by the committed text.
    func commit(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// The foreground temporary attribute at a UTF-16 offset.
    func color(at location: Int) -> NSColor? {
        editor.layoutManagerImpl.temporaryAttribute(.foregroundColor, atCharacterIndex: location, effectiveRange: nil) as? NSColor
    }

    func keyEvent(_ characters: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }
}

/// Lexer test helpers: each line's runs as (text, token).
enum Lex {
    static func runs(_ language: CodeLanguage, _ text: String) -> [[(String, SyntaxToken)]] {
        let highlighter = SyntaxHighlighter(language: language)
        let lines = text.components(separatedBy: "\n")
        return zip(lines, highlighter.tokenize(text)).map { line, tokens in
            let ns = line as NSString
            return tokens.map { (ns.substring(with: $0.0), $0.1) }
        }
    }

    /// The token of the run whose text is exactly `text` on `line` (nil: no such run).
    static func token(_ runs: [[(String, SyntaxToken)]], line: Int, _ text: String) -> SyntaxToken? {
        runs[line].first(where: { $0.0 == text })?.1
    }

    /// The token covering the first occurrence of `text` on `line` (`.plain` when no run covers it).
    static func tokenCovering(_ language: CodeLanguage, _ text: String, line: Int, _ needle: String) -> SyntaxToken? {
        let lines = text.components(separatedBy: "\n")
        let tokens = SyntaxHighlighter(language: language).tokenize(text)
        let range = (lines[line] as NSString).range(of: needle)
        guard range.location != NSNotFound else { return nil }
        for (run, token) in tokens[line] where NSIntersectionRange(run, range).length == range.length { return token }
        return .plain
    }
}

/// A fixed-seed generator (SplitMix64) for the randomized edit tests.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
