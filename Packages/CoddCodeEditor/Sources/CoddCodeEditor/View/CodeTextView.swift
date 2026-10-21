import AppKit

/// The code view's text view: TextKit 1 (built from an explicit `NSLayoutManager` stack; the
/// editor asserts `textLayoutManager == nil`), with the composer's IME rules (D11):
///
/// - Keys are never inspected in `keyDown`; every key goes through `interpretKeyEvents`, so an
///   input method such as 注音 consumes Return, arrows and Esc while it composes.
/// - Commands that still arrive while marked text exists (Return, Esc) go to AppKit or commit the
///   composition; they never close the find widget or insert an indented newline.
/// - Text changes are reported only for committed text (`onTextChange` never sees `ㄅㄚ`), and the
///   editor restyles nothing while marked text exists (it flushes when the composition ends).
/// - Smart quotes / dashes / text replacement / spelling correction / completion are off.
///
/// The caret is drawn here (amber, 2 × 16 pt with a glow, blinking while focused) instead of the
/// system's, so decorated rows keep a text-row caret and snapshots can show it.
final class CodeTextView: NSTextView {
    weak var editor: CodeEditorView?
    /// The storage of the TextKit 1 stack, which nothing else retains.
    private var ownedStorage: NSTextStorage?
    private let ownUndoManager = UndoManager()
    /// Inside AppKit's marked-text handling: `didChangeText` arrives before the marked range is
    /// updated, so the report waits until the call returns.
    private var inputDepth = 0
    /// Programmatic replacements that are not user edits (`applyExternalText`).
    var suppressesTextChange = false
    var onTextChange: ((String) -> Void)?
    /// What `insertNewline` asks for the indentation (tests inject modifier-free behavior).
    var autoIndents = true

    // Caret
    var caretColor: NSColor = .systemOrange
    var caretGlow: NSColor = .clear
    var caretSize = NSSize(width: 2, height: 16)
    var caretDrop: CGFloat = 3
    var showsInactiveCaret = false
    private var blinkOn = true
    private var blinkTimer: Timer?
    private var lastCaretRect: NSRect?

    init(frame: NSRect, layoutManager: CodeLayoutManager) {
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        super.init(frame: frame, textContainer: container)
        ownedStorage = storage
        configure()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        ownedStorage = container?.layoutManager?.textStorage
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none
        allowsUndo = true
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        usesFontPanel = false
        usesRuler = false
        isRulerVisible = false
        allowsDocumentBackgroundColorChange = false
        displaysLinkToolTips = false
        usesAdaptiveColorMappingForDarkAppearance = false
        drawsBackground = true
        insertionPointColor = .clear
        setAccessibilityLabel("Code")
    }

    override var undoManager: UndoManager? { ownUndoManager }

    // NSWindow answers the Edit menu's undo: / redo: with its own undo manager; the editor takes
    // them while it is first responder so ⌘Z reaches its own stack.

    // A read-only view never changes its text through undo (a reload registered one).

    @objc func undo(_ sender: Any?) {
        guard !hasMarkedText(), isEditable else { return }
        ownUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard !hasMarkedText(), isEditable else { return }
        ownUndoManager.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = ownUndoManager.undoMenuItemTitle
            return ownUndoManager.canUndo && !hasMarkedText() && isEditable
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = ownUndoManager.redoMenuItemTitle
            return ownUndoManager.canRedo && !hasMarkedText() && isEditable
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Commands

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            // NSTextView maps Esc to completion; here it closes the find widget (or goes up the
            // chain). With marked text AppKit's own handling is harmless.
            if hasMarkedText() {
                super.doCommand(by: selector)
            } else if editor?.handleEscape() != true {
                nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: nil)
            }
        case #selector(insertNewline(_:)):
            insertNewline(nil)
        default:
            super.doCommand(by: selector)
        }
    }

    /// Esc sent as an action (a menu item, or AppKit's own `doCommand` for it). While marked text
    /// exists the input method owns Esc, so nothing happens here (NSTextView has no implementation
    /// of its own to defer to).
    override func cancelOperation(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        if editor?.handleEscape() != true {
            nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender)
        }
    }

    /// Return keeps the current line's indentation. While marked text exists (an input method
    /// passed the key on) it only commits the composition.
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else {
            inputContext?.discardMarkedText()
            unmarkText()
            return
        }
        guard autoIndents, let storage = textStorage else {
            super.insertNewline(sender)
            return
        }
        let text = storage.string as NSString
        let caret = selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0)).location
        var indentEnd = lineStart
        while indentEnd < min(caret, text.length) {
            let unit = text.character(at: indentEnd)
            guard unit == 0x20 || unit == 0x09 else { break }
            indentEnd += 1
        }
        let indent = text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
        insertText("\n" + indent, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        insertNewline(sender)
    }

    override func insertLineBreak(_ sender: Any?) {
        insertNewline(sender)
    }

    override func insertParagraphSeparator(_ sender: Any?) {
        insertNewline(sender)
    }

    // MARK: Key equivalents

    /// Only the standard editing chords; the editor container answers ⌘F / ⌘G itself and
    /// everything else is left for the main menu.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.isStandardEditingEquivalent(event) else { return false }
        return super.performKeyEquivalent(with: event)
    }

    static func isStandardEditingEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (key, flags) {
        case ("a", [.command]), ("c", [.command]), ("x", [.command]), ("v", [.command]),
             ("v", [.command, .option]), ("v", [.command, .option, .shift]),
             ("z", [.command]), ("z", [.command, .shift]):
            return true
        default:
            return false
        }
    }

    // MARK: Text input

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let marked = hasMarkedText()
        if marked { inputDepth += 1 }
        super.insertText(Self.normalizingLineEndings(string), replacementRange: replacementRange)
        if marked {
            inputDepth -= 1
            compositionEnded()
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputDepth -= 1
        resetBlink()
        // A replacement range may have edited committed text.
        reportTextChange()
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        inputDepth += 1
        super.unmarkText()
        inputDepth -= 1
        if wasMarked { compositionEnded() }
    }

    private func compositionEnded() {
        guard !hasMarkedText() else { return }
        reportTextChange()
        editor?.compositionDidEnd()
    }

    override func didChangeText() {
        super.didChangeText()
        if inputDepth == 0 {
            reportTextChange()
            editor?.textDidChangeCommitted()
        }
    }

    /// The text without the marked range.
    var committedText: String {
        guard hasMarkedText() else { return string }
        let marked = markedRange()
        let all = string as NSString
        guard marked.location != NSNotFound, NSMaxRange(marked) <= all.length else { return string }
        return all.replacingCharacters(in: marked, with: "")
    }

    private func reportTextChange() {
        guard !suppressesTextChange, !hasMarkedText(), let onTextChange else { return }
        onTextChange(committedText)
    }

    static func normalizingLineEndings(_ text: String) -> String {
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func normalizingLineEndings(_ value: Any) -> Any {
        if let text = value as? String { return normalizingLineEndings(text) }
        if let attributed = value as? NSAttributedString, attributed.string.unicodeScalars.contains("\r") {
            return normalizingLineEndings(attributed.string)
        }
        return value
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let text = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
        breakUndoCoalescing()
        insertText(Self.normalizingLineEndings(text), replacementRange: NSRange(location: NSNotFound, length: 0))
        breakUndoCoalescing()
        return true
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        editor?.drawTextBackground(in: rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCaret(in: dirtyRect)
    }

    var isFocused: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    /// The caret's rect (text view coordinates), nil while a selection is shown.
    func caretRect() -> NSRect? {
        let selection = selectedRange()
        guard selection.length == 0 || hasMarkedText(), let editor else { return nil }
        guard let point = editor.insertionPoint(at: selection.location) else { return nil }
        return NSRect(x: point.x - caretSize.width / 2, y: point.baseline + caretDrop - caretSize.height,
                      width: caretSize.width, height: caretSize.height)
    }

    private func drawCaret(in dirtyRect: NSRect) {
        guard isFocused ? blinkOn : showsInactiveCaret else { return }
        guard let rect = caretRect(), rect.insetBy(dx: -8, dy: -8).intersects(dirtyRect) else { return }
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = caretGlow
        glow.shadowBlurRadius = 6
        glow.shadowOffset = .zero
        glow.set()
        caretColor.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Set while the editor replaces the whole text (the old caret position means nothing then).
    var suspendsCaretUpdates = false

    func invalidateCaret() {
        guard !suspendsCaretUpdates else { return }
        if let lastCaretRect { setNeedsDisplay(lastCaretRect.insetBy(dx: -8, dy: -8)) }
        lastCaretRect = caretRect()
        if let lastCaretRect { setNeedsDisplay(lastCaretRect.insetBy(dx: -8, dy: -8)) }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        resetBlink()
    }

    /// The caret shows solid after every move and edit, then blinks (1 s period, the artboard's
    /// `codd-blink`) while the view is focused; Reduce Motion keeps it solid.
    func resetBlink() {
        blinkOn = true
        invalidateCaret()
        updateBlinkTimer()
    }

    func updateBlinkTimer() {
        let wants = isFocused && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wants, blinkTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.blink() }
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !wants {
            blinkTimer?.invalidate()
            blinkTimer = nil
            if !blinkOn {
                blinkOn = true
                invalidateCaret()
            }
        } else {
            blinkTimer?.fireDate = Date(timeIntervalSinceNow: 0.5)
        }
    }

    private func blink() {
        guard isFocused else {
            updateBlinkTimer()
            return
        }
        blinkOn.toggle()
        invalidateCaret()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { resetBlink() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.updateBlinkTimer()
                    self?.invalidateCaret()
                }
            }
        }
        return resigned
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        let center = NotificationCenter.default
        if let window {
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            center.addObserver(self, selector: #selector(keyStateChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: newWindow)
            center.addObserver(self, selector: #selector(keyStateChanged(_:)), name: NSWindow.didResignKeyNotification, object: newWindow)
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
        }
    }

    @objc private func keyStateChanged(_ notification: Notification) {
        resetBlink()
    }

    /// IME candidate windows go under the text row, not under a decoration above it.
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var rect = super.firstRect(forCharacterRange: range, actualRange: actualRange)
        if let editor, rect.height > editor.lineHeight * 1.5 { rect.size.height = editor.lineHeight }
        return rect
    }
}
