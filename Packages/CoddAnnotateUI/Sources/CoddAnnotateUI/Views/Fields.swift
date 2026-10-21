import AppKit
import CoddUI

/// A text view that reports focus (begin / end editing miss a click that only focuses) and never
/// substitutes quotes, dashes or text (the M4 IME rules).
final class FocusTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    func configure(font: NSFont, lineHeight: CGFloat) {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        insertionPointColor = Palette.amber
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        selectedTextAttributes = [.backgroundColor: Palette.amber, .foregroundColor: NSColor.black]
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Palette.cream, .paragraphStyle: paragraph, .ligature: 0,
            .baselineOffset: max(0, (lineHeight - Typeface.lineHeight(font)) / 2),
        ]
        typingAttributes = attributes
        defaultParagraphStyle = paragraph
        self.font = font
        textColor = Palette.cream
    }

    /// The text without the input method's marked (composing) range: what a commit may store.
    var committedString: String {
        guard hasMarkedText() else { return string }
        let marked = markedRange()
        guard marked.location != NSNotFound, let range = Range(marked, in: string) else { return string }
        var text = string
        text.removeSubrange(range)
        return text
    }

    /// Replaces the text without touching the undo stack or the typing attributes.
    func setPlainText(_ text: String) {
        guard string != text else { return }
        textStorage?.setAttributedString(NSAttributedString(string: text, attributes: typingAttributes))
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}

/// `.input.ia-in`: a 26 pt coordinate field (12 px, `padding: 3px 7px`). Commits on ⏎ (only without
/// marked text) and on blur; ⎋ puts the shown value back. The window's field editor edits it, so
/// input methods work; its typing undo never reaches the board's undo manager.
final class CoordField: FieldBoxView, NSTextFieldDelegate, AnnotateTextShowing {
    let field = NSTextField()
    let label: String
    /// The committed text (⏎ or blur); the owner validates it and calls `show(_:)` with the result.
    var onCommit: ((String) -> Void)?
    /// ⎋: the owner shows the stored value again.
    var onRevert: (() -> Void)?

    init(label: String) {
        self.label = label
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(12)
        field.textColor = Palette.cream
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel(label)
        addSubview(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var displayedText: String { field.stringValue }

    override func layout() {
        super.layout()
        let height = Typeface.lineHeight(Typeface.mono(12)) + az(2)
        field.frame = CGRect(x: az(7), y: round((bounds.height - height) / 2), width: max(0, bounds.width - az(14)), height: height)
    }

    /// The field editor is editing this field right now.
    var isEditingText: Bool { field.currentEditor() != nil }
    var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    /// Shows `value` unless the user is typing in the field (`force` overrides: a restore).
    func show(_ value: Int, force: Bool = false) {
        guard force || !isEditingText else { return }
        let text = "\(value)"
        // While the field editor types here, it holds the text (setting the control's value
        // could end the editing session); otherwise the control does.
        if let editor = field.currentEditor() as? NSTextView {
            // Also while editing ends (blur): the control takes the editor's text after the
            // end-editing notification, so the editor must hold the restored value.
            if editor.string != text { editor.string = text }
            if window?.firstResponder === editor, !isEndingEditing {
                editor.selectAll(nil)
            } else if field.stringValue != text {
                // Editing is ending (blur): the control already took the editor's text.
                field.stringValue = text
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }
    }

    /// The field editor's text without a composing range (the control's value when not editing).
    private func committedText() -> String {
        guard let editor = field.currentEditor() as? NSTextView else { return field.stringValue }
        guard editor.hasMarkedText() else { return editor.string }
        let marked = editor.markedRange()
        guard let range = Range(marked, in: editor.string) else { return editor.string }
        var text = editor.string
        text.removeSubrange(range)
        return text
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
    }

    /// True while the end-editing notification runs (a restore must set the control's value).
    private var isEndingEditing = false

    func controlTextDidEndEditing(_ obj: Notification) {
        isFocused = false
        isEndingEditing = true
        defer { isEndingEditing = false }
        onCommit?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if textView.hasMarkedText() { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onCommit?(committedText())
            textView.selectAll(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onRevert?()
            return true
        default:
            return false
        }
    }

    /// Commits a pending edit now (`完成`), without the composing range.
    func commitIfEditing() {
        guard isEditingText else { return }
        onCommit?(committedText())
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(responderMayHaveChanged), name: NSWindow.didUpdateNotification,
                                               object: window)
    }

    @objc private func responderMayHaveChanged() {
        let focused = (window?.firstResponder as? NSTextView).map { $0.delegate === field } ?? false
        if focused != isFocused { isFocused = focused }
    }
}

/// `.input.ia-ta`: the `說明 · Comment` area (12.5 px, line height 1.5, `padding: 5px 9px`, three
/// rows). IME-safe: it never commits while marked text exists; the owner reads it on blur and on
/// `完成` (`committedText`). Typing has its own undo manager, so the board's stack only holds whole
/// edits.
final class CommentArea: FieldBoxView, NSTextViewDelegate, AnnotateTextShowing {
    let scroll = NSScrollView()
    let textView = FocusTextView(usingTextLayoutManager: false)
    private let typingUndo = UndoManager()
    /// Blur (focus left the area): the committed text.
    var onCommit: ((String) -> Void)?
    /// ⎋ without marked text: the owner moves focus back to the canvas (which commits).
    var onEscape: (() -> Void)?

    static var lineHeight: CGFloat { az(18.75) }
    /// `rows="3"` + padding 5 + 5 + border.
    static var preferredHeight: CGFloat { az(68) }

    init(accessibilityLabel: String) {
        super.init(frame: .zero)
        textView.configure(font: Typeface.mono(12.5), lineHeight: Self.lineHeight)
        textView.textContainerInset = NSSize(width: az(8), height: az(4))
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel(accessibilityLabel)
        textView.onFocusChange = { [weak self] focused in self?.isFocused = focused }
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var displayedText: String { textView.string }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 1, dy: 1)
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.frame.size.width = scroll.contentSize.width
    }

    var isEditingText: Bool { window?.firstResponder === textView }
    var hasMarkedText: Bool { textView.hasMarkedText() }
    var committedText: String { textView.committedString }

    /// Shows `text` unless the user is typing in the area.
    func show(_ text: String, force: Bool = false) {
        guard force || !isEditingText else { return }
        textView.setPlainText(text)
    }

    func textDidEndEditing(_ notification: Notification) {
        isFocused = false
        onCommit?(committedText)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }
}

/// The text tool's inline field on the canvas: opened by a click, committed on ⏎ (only without
/// marked text) or when focus leaves it, cancelled by ⎋.
final class InlineTextEditor: FlippedView, NSTextViewDelegate {
    static var height: CGFloat { az(28) }
    let pixel: (x: Int, y: Int)
    let textView = FocusTextView(usingTextLayoutManager: false)
    private let typingUndo = UndoManager()
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false

    init(pixel: (x: Int, y: Int)) {
        self.pixel = pixel
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        textView.configure(font: Typeface.mono(12.5), lineHeight: az(18))
        textView.textContainerInset = NSSize(width: az(6), height: az(4))
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: Self.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: Self.height)
        textView.delegate = self
        textView.setAccessibilityLabel("標註文字")
        // Focus leaving the field commits it (a click elsewhere, another field, the window closing).
        textView.onFocusChange = { [weak self] focused in if !focused { self?.commit() } }
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        textView.frame = CGRect(x: 1, y: 1, width: max(bounds.width - 2, textView.frame.width), height: bounds.height - 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, NSColor.black.withAlphaComponent(0.85))
        Draw.strokeRect(bounds, color: Palette.amber)
    }

    func commit() {
        guard !finished else { return }
        finished = true
        onCommit?(textView.committedString)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onCancel?()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        default:
            return false
        }
    }
}
