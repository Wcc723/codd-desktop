import AppKit
import CoddUI
import CoreText

/// The file editor's code view (D11, D27, D28): a TextKit 1 text view with the FileEditor
/// artboard's gutter (line numbers, `+` / `−` / AI markers), native syntax highlighting applied
/// as temporary attributes to the visible lines + 200, the find / replace widget, inline AI diff
/// hunks as block decorations with `[還原此段]` `[接受]`, and the 14 pt overview ruler.
///
/// The view holds LF text (line endings are the codec's business). Nothing here writes a file;
/// the owner maps its data in (`load`, `setInlineDiff`, `modifiedLineMarkers`, `overviewMarks`)
/// and reacts to the closures. Undo is the view's own `UndoManager`; `load` clears it.
@MainActor
public final class CodeEditorView: NSView {
    public let style: CodeEditorStyle

    // MARK: Public state

    /// The committed text (an input method's composition is not part of it).
    public var text: String { textView.committedText }

    /// An input method is composing (注音 before a candidate is picked).
    public var isComposing: Bool { textView.hasMarkedText() }

    /// Every committed user edit: typing, paste, delete, undo / redo, replace, `replaceLines`.
    /// Not `load` / `applyExternalText`, and never while an input method composes.
    public var onTextChange: ((String) -> Void)? {
        didSet { textView.onTextChange = onTextChange }
    }

    public var onCaretChange: ((CodeCaret) -> Void)?

    /// Changing it re-highlights the whole text.
    public var language: CodeLanguage = .plain {
        didSet { if language != oldValue, !applyingLoad { languageDidChange() } }
    }

    public var fontSize: CGFloat {
        didSet { if fontSize != oldValue { fontDidChange() } }
    }

    public var readOnly = false {
        didSet {
            textView.isEditable = !readOnly
            findWidget.replaceAllowed = !readOnly
            if readOnly, findWidget.replaceVisible { setReplaceVisible(false) }
        }
    }

    /// No highlighting and no wrapping (huge files, D24); set by `load`.
    public private(set) var plainMode = false

    /// Soft wrapping (off by default: the artboard's `white-space: pre`); always off in plain mode.
    public var wrapsLines = false {
        didSet { if wrapsLines != oldValue { applyWrapping() } }
    }

    /// Draw the caret while the view is not focused (snapshots, a split's other side).
    public var showsInactiveCaret: Bool {
        get { textView.showsInactiveCaret }
        set {
            textView.showsInactiveCaret = newValue
            textView.invalidateCaret()
        }
    }

    /// Query, options, the current match (1-based, 0 for none) and the match count after every
    /// search; `total` is -1 while a `.*` pattern does not compile.
    public var onFindChange: ((_ query: String, _ options: FindOptions, _ current: Int, _ total: Int) -> Void)?

    /// A hunk bar's button: the hunk's id and `.revert` (`還原此段`) or `.accept` (`接受`).
    public var onHunkAction: ((Int, HunkAction) -> Void)?

    /// `.mod` bars (3 pt, the color given) in the marker column of lines changed by AI outside a
    /// shown hunk; keys are 0-based lines. They follow edits that add or remove lines above them.
    public var modifiedLineMarkers: [Int: NSColor] = [:] {
        didSet { gutter.needsDisplay = true }
    }

    /// The owner's overview ruler marks (AI changes, added, removed); hits and the caret are drawn
    /// by the view itself.
    public var overviewMarks: [OverviewMark] = [] {
        didSet { ruler.needsDisplay = true }
    }

    public var textViewForTesting: NSTextView { textView }

    // MARK: Parts

    let geometry = EditorGeometry()
    let layoutManagerImpl = CodeLayoutManager()
    let fragmentDelegate: FragmentDelegate
    let textView: CodeTextView
    let scrollView = NSScrollView()
    let gutter = GutterView()
    let overlay = HunkOverlayView()
    let ruler = OverviewRulerView()
    let findWidget: FindWidgetView
    let highlight = HighlightModel(highlighter: SyntaxHighlighter(language: .plain))
    /// The storage and text view delegate (kept off the public type).
    private lazy var delegates = EditorDelegates(editor: self)

    var storage: NSTextStorage { layoutManagerImpl.textStorage ?? NSTextStorage() }
    var container: NSTextContainer { textView.textContainer! }

    // Metrics
    var font: NSFont
    var lineHeight: CGFloat
    var digitWidth: CGFloat = 7.5
    var gutterWidth: CGFloat = 62
    var baseAttributes: [NSAttributedString.Key: Any] = [:]
    var tokenAttributes: [SyntaxToken: [NSAttributedString.Key: Any]] = [:]

    // Decorations
    var hunks: [InlineDiffHunk] = []
    /// Hunk indices per anchor line (a decoration above the line) and after the last fragment.
    var aboveHunks: [Int: [Int]] = [:]
    var trailingHunks: [Int] = []
    var hunkBars: [Int: HunkBarView] = [:]
    var removedLineCache: [Int: (state: LexState, lines: [NSAttributedString])] = [:]
    /// Anchors whose layout must be redone at the next flush (their decoration changed).
    var staleAnchorRanges: [NSRange] = []

    // Find
    var findVisible = false
    var findMatches: [NSRange] = []
    var findCurrent: Int?
    var findInvalid = false
    var currentHitRange: NSRange?
    var caretMovedSinceFind = false
    var navigatingFind = false
    var findRefreshScheduled = false

    // Pending work
    var pendingExternalText: String?
    var pendingActions: [() -> Void] = []
    var flushScheduled = false
    var layoutRefreshScheduled = false
    var hunkBarsNeedRebuild = false
    var needsFlush = false
    var applyingLoad = false
    var lastCaretLine = 0
    var pendingFontChange = false
    /// Highlight passes (tests: nothing is restyled while marked text exists).
    var highlightPassCount = 0

    // MARK: Init

    public init(style: CodeEditorStyle = .fileEditor) {
        self.style = style
        self.fontSize = style.fontSize
        self.font = Self.codeFont(size: style.fontSize)
        self.lineHeight = style.lineHeight
        fragmentDelegate = FragmentDelegate(geometry: geometry)
        layoutManagerImpl.geometry = geometry
        layoutManagerImpl.obliqueness = style.commentObliqueness
        layoutManagerImpl.allowsNonContiguousLayout = false
        layoutManagerImpl.delegate = fragmentDelegate
        textView = CodeTextView(frame: .zero, layoutManager: layoutManagerImpl)
        findWidget = FindWidgetView(style: style)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        assert(textView.textLayoutManager == nil, "the code view must run on TextKit 1")
        configureViews()
        applyMetrics()
        load("", language: .plain, readOnly: false, plainMode: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    private func configureViews() {
        storage.delegate = delegates
        textView.editor = self
        textView.delegate = delegates
        textView.textContainerInset = NSSize(width: style.textLeftInset, height: style.topInset)
        geometry.textOrigin = textView.textContainerOrigin
        textView.backgroundColor = style.background
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        textView.caretColor = style.caret
        textView.caretGlow = style.caretGlow
        textView.caretSize = NSSize(width: style.caretWidth, height: style.caretHeight)
        textView.caretDrop = style.caretDrop
        textView.selectedTextAttributes = [.backgroundColor: style.selectionBackground, .foregroundColor: style.selectionText]
        textView.markedTextAttributes = [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: style.markedTextUnderline,
        ]
        textView.postsFrameChangedNotifications = true

        scrollView.drawsBackground = true
        scrollView.backgroundColor = style.background
        scrollView.borderType = .noBorder
        // The overview ruler is the vertical scroll indicator (the artboard has no scroll bar: its
        // thumb, click and drag do that job). Long lines keep an overlay horizontal scroller that
        // never paints a track over the code.
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScroller = TracklessScroller()
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true

        // Views do not clip to their bounds by default (macOS 14+), and the gutter and ruler fill
        // whatever dirty rect they get: they must not paint over the text beside them.
        for view: NSView in [gutter, ruler, findWidget, overlay] { view.clipsToBounds = true }
        gutter.editor = self
        ruler.editor = self
        findWidget.editor = self
        findWidget.isHidden = true

        addSubview(scrollView)
        addSubview(gutter)
        addSubview(overlay)
        addSubview(ruler)
        addSubview(findWidget)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(textFrameChanged), name: NSView.frameDidChangeNotification, object: textView)
        fragmentDelegate.onLayoutComplete = { [weak self] in self?.scheduleLayoutRefresh() }
    }

    // MARK: Fonts and metrics

    /// JetBrains Mono (PingFang TC cascade) without ligatures or contextual alternates
    /// (`font-variant-ligatures:none; font-feature-settings:'calt' 0`).
    static func codeFont(size: CGFloat) -> NSFont {
        let base = Typeface.mono(size)
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
            [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
        ]
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: features])
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    func applyMetrics() {
        font = Self.codeFont(size: fontSize)
        lineHeight = (style.lineHeight * fontSize / style.fontSize).rounded()
        let content = font.ascender - font.descender
        let halfLeading = (lineHeight - content) / 2
        geometry.lineHeight = lineHeight
        geometry.baseline = halfLeading + font.ascender
        geometry.contentTop = halfLeading
        geometry.contentHeight = content
        digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.tabStops = []
        paragraph.defaultTabInterval = CGFloat(style.tabWidth) * (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.lineBreakMode = effectiveWraps ? .byWordWrapping : .byClipping
        baseAttributes = [.font: font, .foregroundColor: style.text, .paragraphStyle: paragraph, .ligature: 0]
        textView.font = font
        textView.textColor = style.text
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = baseAttributes
        var tokens: [SyntaxToken: [NSAttributedString.Key: Any]] = [:]
        for token in [SyntaxToken.keyword, .string, .comment, .number, .punctuation, .tag, .attribute, .directive, .function, .property] {
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.color(for: token)]
            if token == .comment { attributes[.coddOblique] = true }
            tokens[token] = attributes
        }
        tokenAttributes = tokens
        removedLineCache = [:]
        updateGutterWidth()
    }

    func fontDidChange() {
        guard !textView.hasMarkedText() else {
            pendingFontChange = true
            return
        }
        pendingFontChange = false
        applyMetrics()
        let all = NSRange(location: 0, length: storage.length)
        if all.length > 0 { storage.setAttributes(baseAttributes, range: all) }
        rebuildDecorations()
        layoutManagerImpl.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        refreshAll()
    }

    var effectiveWraps: Bool { wrapsLines && !plainMode }

    func applyWrapping() {
        let wraps = effectiveWraps
        textView.isHorizontallyResizable = !wraps
        container.widthTracksTextView = wraps
        if wraps {
            container.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            textView.frame.size.width = scrollView.contentSize.width
        } else {
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        scrollView.hasHorizontalScroller = !wraps
        let mode: NSLineBreakMode = wraps ? .byWordWrapping : .byClipping
        if let current = baseAttributes[.paragraphStyle] as? NSParagraphStyle, current.lineBreakMode != mode,
           let paragraph = current.mutableCopy() as? NSMutableParagraphStyle {
            paragraph.lineBreakMode = mode
            baseAttributes[.paragraphStyle] = paragraph
            textView.defaultParagraphStyle = paragraph
            textView.typingAttributes = baseAttributes
            if storage.length > 0, !textView.hasMarkedText() {
                storage.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: storage.length))
            }
        }
        needsLayout = true
        refreshAll()
    }

    func updateGutterWidth() {
        let width = style.gutterWidth(lineCount: geometry.lines.count, digitWidth: digitWidth)
        if width != gutterWidth {
            gutterWidth = width
            for bar in hunkBars.values { bar.textLeft = gutterWidth + style.textLeftInset }
            needsLayout = true
        }
    }

    // MARK: Layout

    override public func layout() {
        super.layout()
        layoutParts()
    }

    override public func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutParts()
    }

    func layoutParts() {
        let width = bounds.width
        let height = bounds.height
        let rulerWidth = style.rulerWidth
        gutter.frame = NSRect(x: 0, y: 0, width: min(gutterWidth, width), height: height)
        scrollView.frame = NSRect(x: gutterWidth, y: 0, width: max(0, width - gutterWidth - rulerWidth), height: height)
        overlay.frame = NSRect(x: 0, y: 0, width: max(0, width - rulerWidth), height: height)
        ruler.frame = NSRect(x: max(0, width - rulerWidth), y: 0, width: rulerWidth, height: height)
        let content = scrollView.contentSize
        textView.minSize = NSSize(width: content.width, height: content.height)
        if effectiveWraps {
            container.containerSize = NSSize(width: content.width, height: CGFloat.greatestFiniteMagnitude)
        }
        if textView.frame.width < content.width || textView.frame.height < content.height {
            textView.setFrameSize(NSSize(width: max(textView.frame.width, content.width), height: max(textView.frame.height, content.height)))
        }
        layoutFindWidget()
        layoutOverlay()
        ensureHighlight()
        gutter.needsDisplay = true
        ruler.needsDisplay = true
    }

    func layoutFindWidget() {
        let insets = FindWidgetView.shadowInsets
        // The box stays inside the editor (a 12 pt margin at the left; the right inset as styled).
        findWidget.maximumBoxWidth = max(0, bounds.width - style.findRightInset - UIZoom.pt(12))
        let size = findWidget.fittingFrameSize
        findWidget.frame = NSRect(x: bounds.width - style.findRightInset - size.width + insets.right, y: 0,
                                  width: size.width, height: size.height)
        findWidget.needsLayout = true
        findWidget.needsDisplay = true
    }

    @objc private func clipBoundsChanged() {
        gutter.needsDisplay = true
        ruler.needsDisplay = true
        layoutOverlay()
        ensureHighlight()
    }

    @objc private func textFrameChanged() {
        gutter.needsDisplay = true
        ruler.needsDisplay = true
        layoutOverlay()
    }

    /// Layout may change row positions (decorations, background layout): the gutter, the ruler
    /// and the hunk bars follow on the next turn of the run loop, never inside layout itself.
    func scheduleLayoutRefresh() {
        guard !layoutRefreshScheduled else { return }
        layoutRefreshScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutRefreshScheduled = false
                self.gutter.needsDisplay = true
                self.ruler.needsDisplay = true
                self.layoutOverlay()
            }
        }
    }

    func refreshAll() {
        textView.needsDisplay = true
        gutter.needsDisplay = true
        ruler.needsDisplay = true
        layoutOverlay()
        textView.invalidateCaret()
    }

    // MARK: Loading

    /// Replaces the text (no undo step, undo history cleared, no `onTextChange`), caret at the
    /// start, scrolled to the top; hunks, markers and ruler marks are cleared. `plainMode`: no
    /// highlighting, no wrapping. A composition in progress is discarded.
    public func load(_ text: String, language: CodeLanguage, readOnly: Bool, plainMode: Bool) {
        if textView.hasMarkedText() {
            textView.inputContext?.discardMarkedText()
            textView.unmarkText()
        }
        pendingExternalText = nil
        pendingActions = []
        let normalized = CodeTextView.normalizingLineEndings(text)
        applyingLoad = true
        self.plainMode = plainMode
        self.language = language
        self.readOnly = readOnly
        if plainMode { textView.isHorizontallyResizable = true }
        textView.suspendsCaretUpdates = true
        storage.beginEditing()
        storage.setAttributedString(NSAttributedString(string: normalized, attributes: baseAttributes))
        storage.endEditing()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.suspendsCaretUpdates = false
        applyingLoad = false
        geometry.lines.rebuild(storage.mutableString)
        highlight.highlighter = SyntaxHighlighter(language: highlightLanguage)
        highlight.reset(lineCount: geometry.lines.count)
        hunks = []
        modifiedLineMarkers = [:]
        overviewMarks = []
        rebuildDecorations()
        rebuildHunkBars()
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        lastCaretLine = 0
        applyWrapping()
        updateGutterWidth()
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if findVisible { runFind(resetCurrent: true, reveal: false) }
        ensureHighlight()
        refreshAll()
        reportCaret()
    }

    /// The lexer in use (`plain` in plain mode).
    var highlightLanguage: CodeLanguage { plainMode ? .plain : language }

    func languageDidChange() {
        highlight.highlighter = SyntaxHighlighter(language: highlightLanguage)
        highlight.reset(lineCount: geometry.lines.count)
        clearSyntaxAttributes()
        removedLineCache = [:]
        ensureHighlight()
        textView.needsDisplay = true
    }

    func clearSyntaxAttributes() {
        let all = NSRange(location: 0, length: storage.length)
        guard all.length > 0 else { return }
        layoutManagerImpl.setTemporaryAttributes([:], forCharacterRange: all)
        if let currentHitRange { layoutManagerImpl.addTemporaryAttribute(.foregroundColor, value: style.currentHitText, forCharacterRange: currentHitRange) }
    }

    // MARK: Caret

    /// Puts the caret at a 1-based line and column (clamped) and scrolls it into view.
    public func goTo(line: Int, column: Int) {
        let index = max(0, min(line - 1, geometry.lines.count - 1))
        let range = geometry.lines.range(of: index)
        let offset = max(0, min(column - 1, range.length))
        textView.setSelectedRange(NSRange(location: range.location + offset, length: 0))
        scrollLineIntoView(index)
    }

    public var caret: CodeCaret {
        let selection = textView.selectedRange()
        let line = geometry.lines.line(containing: selection.location)
        return CodeCaret(line: line + 1, column: selection.location - geometry.lines.start(of: line) + 1, selectionLength: selection.length)
    }

    func reportCaret() {
        let line = geometry.lines.line(containing: textView.selectedRange().location)
        if line != lastCaretLine {
            invalidateRows(lines: [lastCaretLine, line])
            lastCaretLine = line
        }
        gutter.needsDisplay = true
        ruler.needsDisplay = true
        onCaretChange?(caret)
    }

    func selectionDidChange() {
        // Replacing the whole text moves the selection to its end; asking where that is would lay
        // out the whole file. `load` puts the caret at the start itself.
        guard !applyingLoad else { return }
        if !navigatingFind { caretMovedSinceFind = true }
        reportCaret()
        textView.invalidateCaret()
    }

    /// Esc from the text view: closes the find widget; false when there was nothing to close.
    func handleEscape() -> Bool {
        guard findVisible else { return false }
        hideFind()
        return true
    }

    // MARK: Key equivalents

    /// ⌘F / ⌥⌘F / ⌘G / ⇧⌘G while the text view or the find widget has focus and nothing is
    /// being composed (key equivalents, never a key monitor).
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, let window, let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let responder = window.firstResponder
        let ownsFocus = responder === textView || (responder as? NSView)?.isDescendant(of: self) == true
        let fieldComposing = (responder as? NSTextView)?.hasMarkedText() ?? false
        guard ownsFocus, !textView.hasMarkedText(), !fieldComposing else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (key, flags) {
        case ("f", [.command]):
            showFind(replace: false, query: nil)
            return true
        case ("f", [.command, .option]):
            showFind(replace: !readOnly, query: nil)
            return true
        case ("g", [.command]):
            findNext()
            return findVisible
        case ("g", [.command, .shift]):
            findPrevious()
            return findVisible
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    // MARK: Scrolling

    func scrollLineIntoView(_ line: Int, center: Bool = false) {
        guard let row = textRowRect(line: line) else { return }
        let clip = scrollView.contentView.bounds
        if !center, row.minY >= clip.minY, row.maxY <= clip.maxY { return }
        let target = center || row.minY < clip.minY || row.maxY > clip.maxY ? row.midY - clip.height / 2 : clip.minY
        scroll(toY: target)
    }

    func scroll(toY y: CGFloat) {
        let clip = scrollView.contentView
        // Layout is lazy (contiguous TextKit 1): lay out through the target screen first so the
        // text view is tall enough to scroll there.
        let origin = textView.textContainerOrigin
        layoutManagerImpl.ensureLayout(forBoundingRect: NSRect(x: 0, y: max(0, y - origin.y), width: 1, height: clip.bounds.height + lineHeight),
                                       in: container)
        textView.sizeToFit()
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, min(y, maxY))))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolls so that 1-based `line` is the first visible one (demos, restoring a position).
    public func scrollToLine(_ line: Int) {
        guard let row = textRowRect(line: max(0, line - 1)) else { return }
        scroll(toY: row.minY - style.topInset)
    }

    func rulerScroll(toFraction fraction: CGFloat) {
        let line = Int(max(0, min(1, fraction)) * CGFloat(geometry.lines.count))
        guard let row = textRowRect(line: min(line, geometry.lines.count - 1)) else { return }
        scroll(toY: row.midY - scrollView.contentView.bounds.height / 2)
    }

    func gutterClicked(at point: NSPoint) {
        let y = point.y + scrollView.contentView.bounds.minY
        for row in visualRows(in: NSRect(x: 0, y: y, width: 1, height: 1)) {
            if case .text(let line, _) = row.kind {
                window?.makeFirstResponder(textView)
                textView.setSelectedRange(geometry.lines.rangeWithNewline(of: line))
                return
            }
        }
    }
}

/// Receives the text storage's edits and the text view's selection changes for the editor.
@MainActor
final class EditorDelegates: NSObject, @preconcurrency NSTextStorageDelegate, NSTextViewDelegate {
    weak var editor: CodeEditorView?

    init(editor: CodeEditorView) {
        self.editor = editor
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        editor?.storageDidProcessEditing(textStorage, mask: editedMask, range: editedRange, delta: delta)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        editor?.selectionDidChange()
    }
}

/// An overlay scroller without a knob slot: only the knob shows (and only while scrolling).
final class TracklessScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
