import AppKit

/// The editor's NSTextView, always TextKit 1 (built on an explicit NSTextStorage / NSLayoutManager /
/// NSTextContainer stack, so `textLayoutManager` is nil).
///
/// IME rules (the composer's, M2): keys are never inspected in `keyDown`. Every key goes through
/// `interpretKeyEvents`, so 注音 consumes Return, Tab, arrows and Esc while it composes, and only what
/// it passes on arrives here as a command. Every command checks `hasMarkedText()` first; ⌘⏎ / ⌘B /
/// ⌘I / ⌘⇧A live in `performKeyEquivalent`. Smart quotes / dashes, text replacement, spelling
/// correction, data detection, inline prediction and Writing Tools are off. The pasteboard is read
/// only in the user's paste / drop.
@MainActor
final class MarkdownTextView: NSTextView {
    weak var editor: MarkdownEditorView?
    /// Per document (the editor clears it on `load`), so ⌘Z never crosses notes.
    let ownUndoManager = UndoManager()
    /// Inside AppKit's marked-text handling (`setMarkedText`, `unmarkText`, a committing
    /// `insertText`): storage edits there belong to the composition.
    private(set) var markedInputDepth = 0
    /// Modifier flags of the key being handled; tests inject them.
    var modifierFlagsProvider: () -> NSEvent.ModifierFlags = { NSApp?.currentEvent?.modifierFlags ?? [] }
    var contentInsets = NSEdgeInsets()
    /// Recursion guard for selection snapping.
    private var adjustingSelection = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MarkdownTextView is built in code")
    }

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
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        drawsBackground = true
        setAccessibilityLabel("Markdown")
    }

    func applyInsets(_ insets: NSEdgeInsets) {
        contentInsets = insets
        // textContainerInset is symmetric; the origin override places the text at the asymmetric
        // padding while the summed inset keeps the container width and view height right.
        textContainerInset = NSSize(width: (insets.left + insets.right) / 2, height: (insets.top + insets.bottom) / 2)
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: contentInsets.left, y: contentInsets.top)
    }

    // MARK: Undo

    override var undoManager: UndoManager? {
        ownUndoManager
    }

    // NSWindow answers the Edit menu's undo: / redo: with its own manager; the editor takes them
    // while it is first responder, so ⌘Z reaches `ownUndoManager`.

    @objc func undo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        ownUndoManager.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        ownUndoManager.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = ownUndoManager.undoMenuItemTitle
            return ownUndoManager.canUndo && !hasMarkedText()
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = ownUndoManager.redoMenuItemTitle
            return ownUndoManager.canRedo && !hasMarkedText()
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Marked text

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedInputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedInputDepth -= 1
        editor?.markedTextDidChange()
    }

    override func unmarkText() {
        markedInputDepth += 1
        super.unmarkText()
        markedInputDepth -= 1
        editor?.compositionMayHaveEnded()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let marked = hasMarkedText()
        if marked { markedInputDepth += 1 }
        super.insertText(Self.normalizingLineEndings(string), replacementRange: replacementRange)
        if marked {
            markedInputDepth -= 1
            editor?.compositionMayHaveEnded()
        }
    }

    override func didChangeText() {
        editor?.restyleAfterEdit()
        super.didChangeText()
        if markedInputDepth == 0, !hasMarkedText() { editor?.committedTextDidChange() }
    }

    /// True while an input method composes (or AppKit is inside its marked-text handling).
    var isComposing: Bool {
        markedInputDepth > 0 || hasMarkedText()
    }

    /// Return while marked text exists (an input method passed the key on): keep the composed
    /// text and end the composition (NSTextView's newline would replace the composition).
    func commitComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        unmarkText()
    }

    // MARK: Commands

    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else {
            commitComposition()
            return
        }
        let flags = modifierFlagsProvider()
        if flags.contains(.command) {
            // ⌘⏎ that no key equivalent took (a custom key binding): the send action, never a newline.
            editor?.commandReturn()
            return
        }
        if flags.contains(.shift) || flags.contains(.option) {
            insertPlainNewline()
            return
        }
        editor?.insertNewlineContinuingBlock()
    }

    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        lineFeedRequested()
    }

    override func insertLineBreak(_ sender: Any?) {
        lineFeedRequested()
    }

    override func insertParagraphSeparator(_ sender: Any?) {
        lineFeedRequested()
    }

    private func lineFeedRequested() {
        guard !hasMarkedText() else {
            commitComposition()
            return
        }
        insertPlainNewline()
    }

    /// Always LF (NSTextView would insert U+2028 for a line break).
    func insertPlainNewline() {
        insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        if editor?.indentListLines(outdent: false) == true { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        _ = editor?.indentListLines(outdent: true)
    }

    override func deleteBackward(_ sender: Any?) {
        guard !hasMarkedText() else {
            super.deleteBackward(sender)
            return
        }
        if editor?.deleteListPrefixIfAtContentStart() == true { return }
        super.deleteBackward(sender)
    }

    /// Esc: an input method's composition keeps AppKit's handling; otherwise it goes up the
    /// responder chain (NSTextView would open its word-completion list).
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            super.cancelOperation(sender)
        } else {
            nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
        }
    }

    /// No word-completion list (⌥Esc / F5); with marked text AppKit's handling commits it.
    override func complete(_ sender: Any?) {
        if hasMarkedText() { super.complete(sender) }
    }

    // MARK: Key equivalents

    /// ⌘⏎ (send), ⌘B / ⌘I (wrap), ⌘⇧A (annotations) and the standard editing chords; everything
    /// else (⌘E, ⌘K, ⌘F, …) is left to the main menu. Only while this view is first responder.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (key, flags) {
        case ("\r", [.command]), ("\u{3}", [.command]):
            // With marked text the chord is swallowed: nothing is sent and no menu item fires.
            if hasMarkedText() { return true }
            return editor?.commandReturn() ?? false
        case ("b", [.command]):
            if !hasMarkedText() { editor?.wrapSelection(with: "**") }
            return true
        case ("i", [.command]):
            if !hasMarkedText() { editor?.wrapSelection(with: "*") }
            return true
        case ("a", [.command, .shift]):
            if hasMarkedText() { return true }
            return editor?.editImageAnnotationsAtCaret() ?? false
        case ("a", [.command]), ("c", [.command]), ("x", [.command]), ("v", [.command]),
             ("v", [.command, .option]), ("v", [.command, .option, .shift]), ("v", [.command, .shift]),
             ("z", [.command]), ("z", [.command, .shift]):
            return super.performKeyEquivalent(with: event)
        default:
            return false
        }
    }

    // MARK: Text input normalization

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

    // MARK: Paste and drop

    override func paste(_ sender: Any?) {
        guard !hasMarkedText() else { return }
        _ = editor?.insertContents(of: .general)
    }

    override func pasteAsPlainText(_ sender: Any?) {
        paste(sender)
    }

    override func pasteAsRichText(_ sender: Any?) {
        paste(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .string, .png, .tiff]
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .string, .png, .tiff]
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        editor?.insertContents(of: pboard) ?? false
    }

    override func readSelection(from pboard: NSPasteboard) -> Bool {
        editor?.insertContents(of: pboard) ?? false
    }

    // MARK: Selection

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let previous = selectedRange()
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !adjustingSelection else { return }
        if !stillSelecting, !isComposing, let editor,
           let snapped = editor.snappedSelection(selectedRange(), previous: previous), snapped != selectedRange() {
            adjustingSelection = true
            super.setSelectedRanges([NSValue(range: snapped)], affinity: affinity, stillSelecting: false)
            adjustingSelection = false
        }
        editor?.selectionDidChange(stillSelecting: stillSelecting)
    }

    // MARK: Focus

    /// First responder (the window still names this view while it resigns, so the editor reads this).
    private(set) var hasFocus = false

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            hasFocus = true
            editor?.focusDidChange()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            hasFocus = false
            editor?.focusDidChange()
        }
        return resigned
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if !hasMarkedText(), let editor {
            let point = convert(event.locationInWindow, from: nil)
            if editor.handleClick(at: point, clickCount: event.clickCount, modifiers: event.modifierFlags) { return }
        }
        super.mouseDown(with: event)
    }

    // MARK: Drawing

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard let editor else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
            return
        }
        guard flag else {
            super.drawInsertionPoint(in: rect, color: color, turnedOn: false)
            return
        }
        editor.drawCaret(defaultRect: rect)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        // The caret is wider than AppKit's and glows; widen its invalidation so blinking leaves no trail.
        super.setNeedsDisplay(invalidRect.insetBy(dx: -8, dy: 0), avoidAdditionalLayout: flag)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        editor?.drawTextViewDecorations(.underlay, in: rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        // NSTextView leaves the clip narrowed to the text container; the fold glyphs and figure
        // rings drawn next reach into the padding.
        NSGraphicsContext.saveGraphicsState()
        super.draw(dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        editor?.drawTextViewDecorations(.foreground, in: dirtyRect)
        editor?.drawPlaceholderIfNeeded()
    }

    /// The input method's candidate window sits under the text line, not under a figure or the
    /// title's chips row that share its line fragment.
    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let rect = super.firstRect(forCharacterRange: range, actualRange: actualRange)
        guard let editor, let window, let line = editor.textLineRect(forCharacterAt: range.location) else { return rect }
        let inWindow = convert(line, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return NSRect(x: rect.minX, y: onScreen.minY, width: rect.width, height: onScreen.height)
    }
}
