import AppKit

public enum ComposerHistoryDirection: Sendable {
    case previous, next
}

/// The composer's text view: plain text, IME-safe Enter, ↑ / ↓ history at the edges, image paste.
///
/// Keys are never inspected in `keyDown`: every key goes through the input system
/// (`interpretKeyEvents`), so an input method such as 注音 consumes Return, arrows and Esc while it
/// composes, and only what it passes on arrives here as a command in `doCommand(by:)`. A command
/// that still arrives while marked text exists never reaches `onSubmit` / `onEscape` / `onHistory`:
/// a newline command commits the composition, anything else goes to AppKit.
///
/// TextKit 1 (built in `init(frame:)`): line fragments make the first / last visual line checks and
/// the field's line count exact, and `markedTextAttributes` is honored.
///
/// The view never clears itself: `onSubmit` receives the whole text as shown and the owner decides
/// (send, then set `ComposerField.text = ""`, or keep it when the send failed).
@MainActor
public final class ComposerTextView: NSTextView {
    /// Enter without Shift / Option; the whole text, unmodified (marked text never exists here).
    public var onSubmit: ((String) -> Void)?
    /// Esc (or the completion key) while nothing is being composed.
    public var onEscape: (() -> Void)?
    /// ↑ with the caret on the first visual line, ↓ on the last. A returned string replaces the text
    /// (caret at the end, one undo step); nil lets the arrow move the caret as usual.
    public var onHistory: ((ComposerHistoryDirection) -> String?)?
    /// A pasted or dropped image, as the pasteboard had it (never converted here: that can take
    /// 100 ms). True when the owner takes it: it saves the file off the main actor and then puts
    /// the escaped path in with `insertAttachmentText(_:)`. False declines (nothing is inserted).
    public var onPasteImage: ((ComposerPastedImage) -> Bool)?
    /// Every user edit (typing, paste, delete, undo, history recall, a committed composition), not
    /// programmatic `string` sets. The text never includes marked text: an input method's
    /// composition (`ㄅㄚ` before a candidate is picked) is not the user's text until committed.
    public var onTextChange: ((String) -> Void)?
    /// First responder gained (true) or lost (false); the owner draws the focused border.
    public var onFocusChange: ((Bool) -> Void)?
    /// Drawn in `placeholderColor` while the view is empty; never part of the text.
    public var placeholder: String = "" {
        didSet {
            setAccessibilityPlaceholderValue(placeholder)
            needsDisplay = true
        }
    }

    /// The modifiers held when Enter arrives. AppKit maps Shift+Return and Return to the same
    /// `insertNewline:`, so the modifiers come from the event being handled; tests inject them.
    public var modifierFlagsProvider: () -> NSEvent.ModifierFlags = {
        NSApp?.currentEvent?.modifierFlags ?? []
    }

    /// The field's hook: the laid-out text may have changed height.
    var onLayoutChange: (() -> Void)?
    private(set) var style: ComposerStyle = .standard
    /// The storage of the TextKit 1 stack built in `init(frame:)`, the root object nothing else retains.
    private var ownedStorage: NSTextStorage?
    /// Per composer, so recalls and pastes undo here only and a programmatic text set can drop them.
    private let ownUndoManager = UndoManager()
    private var systemSelectedTextAttributes: [NSAttributedString.Key: Any] = [:]
    /// `setText` is replacing the text: nothing it causes (the commit of a composition in
    /// progress included) is a user edit, and it must not reach the owner's draft of whichever
    /// session the field now shows.
    private var settingText = false
    /// Inside AppKit's own marked-text handling: `didChangeText` arrives there before the marked
    /// range is updated, so the report waits until the call returns (then the range is right).
    private(set) var inputDepth = 0
    /// The `codd://note/<id>` and `[圖已過期]` ranges currently drawn as chips (`ComposerStyle.referenceChips`).
    var referenceChipRanges: [NSRange] = []

    override public convenience init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: frameRect.width, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        self.init(frame: frameRect, textContainer: container)
    }

    override public init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        ownedStorage = container?.layoutManager?.textStorage
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
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
        systemSelectedTextAttributes = selectedTextAttributes
        setAccessibilityLabel("Composer")
        apply(.standard)
        updateDragTypeRegistration()
    }

    // MARK: Style

    public func apply(_ style: ComposerStyle) {
        self.style = style
        let attributes = style.textAttributes
        font = style.font
        textColor = style.textColor
        backgroundColor = style.background
        drawsBackground = true
        insertionPointColor = style.caretColor
        defaultParagraphStyle = style.paragraphStyle
        typingAttributes = attributes
        if let storage = textStorage, storage.length > 0, !hasMarkedText() {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
        markedTextAttributes = [
            .foregroundColor: style.markedTextColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: style.markedTextColor,
        ]
        var selection: [NSAttributedString.Key: Any] = [:]
        if let background = style.selectionBackground { selection[.backgroundColor] = background }
        if let text = style.selectionTextColor { selection[.foregroundColor] = text }
        selectedTextAttributes = selection.isEmpty ? systemSelectedTextAttributes : selection
        refreshReferenceChips()
        // textContainerInset is symmetric; the origin override below places the text at the
        // asymmetric insets, while the summed inset keeps the container width and view height right.
        textContainerInset = NSSize(
            width: (style.insets.left + style.insets.right) / 2,
            height: (style.insets.top + style.insets.bottom) / 2
        )
        needsDisplay = true
        onLayoutChange?()
    }

    override public var textContainerOrigin: NSPoint {
        NSPoint(x: style.insets.left, y: style.insets.top)
    }

    override public var undoManager: UndoManager? {
        ownUndoManager
    }

    // NSWindow answers the Edit menu's undo: / redo: with its own undo manager, so the composer
    // takes them while it is first responder; otherwise ⌘Z would not reach `ownUndoManager`.

    @objc public func undo(_ sender: Any?) {
        ownUndoManager.undo()
    }

    @objc public func redo(_ sender: Any?) {
        ownUndoManager.redo()
    }

    override public func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = ownUndoManager.undoMenuItemTitle
            return ownUndoManager.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = ownUndoManager.redoMenuItemTitle
            return ownUndoManager.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// Replaces the text without an undo step or `onTextChange` (drafts, clearing after a send,
    /// session switches); the caret goes to the end.
    func setText(_ text: String) {
        settingText = true
        defer { settingText = false }
        if hasMarkedText() {
            inputContext?.discardMarkedText()
            unmarkText()
        }
        string = Self.normalizingLineEndings(text)
        if let storage = textStorage, storage.length > 0 {
            storage.setAttributes(style.textAttributes, range: NSRange(location: 0, length: storage.length))
        }
        typingAttributes = style.textAttributes
        refreshReferenceChips()
        ownUndoManager.removeAllActions()
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        needsDisplay = true
        onLayoutChange?()
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Commands

    override public func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            returnPressed()
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)),
             #selector(insertParagraphSeparator(_:)):
            lineFeedRequested()
        case #selector(moveUp(_:)):
            if !recallHistory(.previous) { super.doCommand(by: selector) }
        case #selector(moveDown(_:)):
            if !recallHistory(.next) { super.doCommand(by: selector) }
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            // NSTextView maps Esc to completion; here it is the owner's (close the composer). With
            // marked text AppKit's own handling is harmless (cancel keeps it, complete commits it).
            if hasMarkedText() {
                super.doCommand(by: selector)
            } else {
                onEscape?()
            }
        default:
            super.doCommand(by: selector)
        }
    }

    // The newline actions are also reached directly (accessibility, a menu item, a custom key
    // binding), so they repeat the marked text guard instead of relying on `doCommand(by:)`.

    override public func insertNewline(_ sender: Any?) {
        returnPressed()
    }

    override public func insertNewlineIgnoringFieldEditor(_ sender: Any?) {
        lineFeedRequested()
    }

    override public func insertLineBreak(_ sender: Any?) {
        lineFeedRequested()
    }

    override public func insertParagraphSeparator(_ sender: Any?) {
        lineFeedRequested()
    }

    /// Return: submit, or a newline with Shift / Option (AppKit sends `insertNewline:` for both
    /// Return and Shift+Return, so the modifiers decide).
    private func returnPressed() {
        guard !hasMarkedText() else {
            commitComposition()
            return
        }
        let flags = modifierFlagsProvider()
        if flags.contains(.command) || flags.contains(.control) {
            // ⌘⏎ belongs to the main menu (允許); a disabled item must not turn it into a send.
            return
        }
        if flags.contains(.shift) || flags.contains(.option) {
            insertLineFeed()
            return
        }
        onSubmit?(string)
    }

    /// Option+Return, Control+Return: a newline, always LF (NSTextView would insert U+2028).
    private func lineFeedRequested() {
        guard !hasMarkedText() else {
            commitComposition()
            return
        }
        insertLineFeed()
    }

    /// Return while marked text exists (an input method passed the key on): keep what was composed
    /// as plain text and end the composition. NSTextView's own newline actions would replace the
    /// composed text with the newline.
    private func commitComposition() {
        guard hasMarkedText() else { return }
        inputContext?.discardMarkedText()
        unmarkText()
    }

    private func insertLineFeed() {
        breakUndoCoalescing()
        insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Asks the owner for a history entry when the caret is on the edge line for `direction`;
    /// false lets the arrow move the caret.
    private func recallHistory(_ direction: ComposerHistoryDirection) -> Bool {
        guard !hasMarkedText(), let onHistory else { return false }
        let onEdge = direction == .previous ? caretIsOnFirstLine : caretIsOnLastLine
        guard onEdge, let text = onHistory(direction) else { return false }
        replaceAllText(with: text)
        return true
    }

    /// One undoable replacement of the whole text, caret at the end.
    private func replaceAllText(with text: String) {
        let replacement = Self.normalizingLineEndings(text)
        let all = NSRange(location: 0, length: (string as NSString).length)
        breakUndoCoalescing()
        if shouldChangeText(in: all, replacementString: replacement) {
            textStorage?.replaceCharacters(in: all, with: NSAttributedString(string: replacement, attributes: style.textAttributes))
            didChangeText()
        }
        breakUndoCoalescing()
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Visual lines

    /// The caret (start of the selection) is on the first laid-out line; true when empty.
    var caretIsOnFirstLine: Bool {
        guard let layoutManager, let caret = lineFragment(forCaretAt: selectedRange().location) else { return true }
        let first = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        return caret.minY <= first.minY + 0.5
    }

    /// The caret (end of the selection) is on the last laid-out line; true when empty.
    var caretIsOnLastLine: Bool {
        guard let layoutManager, let caret = lineFragment(forCaretAt: NSMaxRange(selectedRange())) else { return true }
        let extra = layoutManager.extraLineFragmentRect
        let last = extra.height > 0
            ? extra
            : layoutManager.lineFragmentRect(forGlyphAt: max(0, layoutManager.numberOfGlyphs - 1), effectiveRange: nil)
        return caret.maxY >= last.maxY - 0.5
    }

    /// Laid-out lines, including the empty line after a trailing newline; at least 1.
    var visualLineCount: Int {
        guard let layoutManager, let textContainer else { return 1 }
        layoutManager.ensureLayout(for: textContainer)
        var count = 0
        let glyphs = NSRange(location: 0, length: layoutManager.numberOfGlyphs)
        if glyphs.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, _, _ in count += 1 }
        }
        if layoutManager.extraLineFragmentRect.height > 0 { count += 1 }
        return max(1, count)
    }

    /// The line fragment holding a caret at character `location` (nil for an empty text).
    private func lineFragment(forCaretAt location: Int) -> NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        if location >= storage.length {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 { return extra }
            let glyph = layoutManager.glyphIndexForCharacter(at: storage.length - 1)
            return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: location)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    // MARK: Key equivalents

    /// Only the standard editing chords; everything else (⌘L ⌘K ⌘1–9 ⌘⏎ ⌘J ⌘T ⌘P ⌘. …) is left
    /// for the main menu.
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
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

    /// Line endings arrive as LF whatever inserts them (an input method, a service, Shift+Return
    /// routed as text), so the text and its line count match what will be sent.
    override public func insertText(_ string: Any, replacementRange: NSRange) {
        let marked = hasMarkedText()
        if marked { inputDepth += 1 }
        super.insertText(Self.normalizingLineEndings(string), replacementRange: replacementRange)
        if marked {
            inputDepth -= 1
            reportTextChange()
            refreshReferenceChips()
        }
    }

    override public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputDepth -= 1
        needsDisplay = true
        onLayoutChange?()
        // Usually the committed text is unchanged; a replacement range may have edited it.
        reportTextChange()
        // A cancelled composition (empty marked text) is over: chips may be recomputed.
        refreshReferenceChips()
    }

    override public func unmarkText() {
        inputDepth += 1
        super.unmarkText()
        inputDepth -= 1
        needsDisplay = true
        onLayoutChange?()
        // The composition is text now (AppKit does not always call didChangeText for it).
        reportTextChange()
        refreshReferenceChips()
    }

    override public func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onLayoutChange?()
        if inputDepth == 0 {
            reportTextChange()
            refreshReferenceChips()
        }
    }

    /// A new caret never inherits a chip's attributes (a composition next to a chip stays outside it).
    override public func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if style.referenceChips, !hasMarkedText() { typingAttributes = style.textAttributes }
    }

    /// The text without the marked range (what a draft may keep).
    public var committedText: String {
        guard hasMarkedText() else { return string }
        let marked = markedRange()
        let all = string as NSString
        guard marked.location != NSNotFound, NSMaxRange(marked) <= all.length else { return string }
        return all.replacingCharacters(in: marked, with: "")
    }

    private func reportTextChange() {
        guard !settingText else { return }
        onTextChange?(committedText)
    }

    override public func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override public func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    static func normalizingLineEndings(_ text: String) -> String {
        // Scalars, not Characters: "\r\n" is one Character that `contains("\r")` would not match.
        guard text.unicodeScalars.contains("\r") else { return text }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func normalizingLineEndings(_ value: Any) -> Any {
        if let text = value as? String {
            return normalizingLineEndings(text)
        }
        if let attributed = value as? NSAttributedString, attributed.string.unicodeScalars.contains("\r") {
            return normalizingLineEndings(attributed.string)
        }
        return value
    }

    // MARK: Paste and drop

    override public func paste(_ sender: Any?) {
        paste(from: .general)
    }

    override public func pasteAsPlainText(_ sender: Any?) {
        paste(from: .general)
    }

    override public func pasteAsRichText(_ sender: Any?) {
        paste(from: .general)
    }

    /// File URLs as escaped paths (a Finder copy pastes like a drop, not as the bare name it also
    /// puts on the pasteboard), else plain text, else an image through `onPasteImage`.
    func paste(from pasteboard: NSPasteboard) {
        _ = insertContents(of: pasteboard)
    }

    override public var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .string, .png, .tiff]
    }

    override public var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .string, .png, .tiff]
    }

    /// Drops and services read through here (AppKit has already put the selection at the drop point).
    override public func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        insertContents(of: pboard)
    }

    override public func readSelection(from pboard: NSPasteboard) -> Bool {
        insertContents(of: pboard)
    }

    @discardableResult
    func insertContents(of pasteboard: NSPasteboard) -> Bool {
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        if !fileURLs.isEmpty {
            let paths = fileURLs.map { $0.path(percentEncoded: false) }
            // Handled either way: a refused drop must not fall back to the name as plain text.
            guard paths.allSatisfy(ComposerPaths.isInsertable) else {
                NSSound.beep()
                return true
            }
            insertPlain(paths.map(ComposerPaths.escaped).joined(separator: " "))
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            insertPlain(text)
            return true
        }
        if let image = Self.image(from: pasteboard) {
            return onPasteImage?(image) ?? false
        }
        return false
    }

    /// PNG preferred; else TIFF (what most apps put for a copied image), handed over unconverted.
    static func image(from pasteboard: NSPasteboard) -> ComposerPastedImage? {
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return .png(png)
        }
        if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
            return .tiff(tiff)
        }
        return nil
    }

    /// The owner's answer to `onPasteImage` once its file is written: inserted at the caret as one
    /// undo step, like a paste.
    public func insertAttachmentText(_ text: String) {
        insertPlain(text)
    }

    private func insertPlain(_ text: String) {
        guard !text.isEmpty else { return }
        breakUndoCoalescing()
        insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        breakUndoCoalescing()
    }

    // MARK: Drawing

    override public func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawReferenceChips(in: rect)
    }

    override public func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !placeholder.isEmpty, (textStorage?.length ?? 0) == 0, !hasMarkedText() else { return }
        var attributes = style.textAttributes
        attributes[.foregroundColor] = style.placeholderColor
        if let paragraph = style.paragraphStyle.mutableCopy() as? NSMutableParagraphStyle {
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }
        let origin = textContainerOrigin
        let rect = NSRect(
            x: origin.x, y: origin.y,
            width: max(0, bounds.width - style.insets.left - style.insets.right),
            height: style.resolvedLineHeight
        )
        NSAttributedString(string: placeholder, attributes: attributes)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
