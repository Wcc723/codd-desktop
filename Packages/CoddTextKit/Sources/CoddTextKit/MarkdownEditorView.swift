import AppKit

/// The notebook's Markdown editor (M4 D11): a TextKit 1 NSTextView in a scroll view with a live
/// preview of the Notebook artboard, IME-safe editing commands and block decorations.
///
/// Live preview: syntax marks are hidden off the caret's paragraph by glyph generation (the text
/// never changes), headings / lists / tasks / code are styled through text-storage attributes, and
/// figures, the title accessory, code blocks and rules are drawn by the layout manager in space the
/// line fragments reserve. Source mode shows every character in one monospaced size.
///
/// While an input method composes (`isComposing`), nothing is restyled, revealed, replaced or
/// reloaded and `onTextChange` never fires: `load`, `applyExternalText`, `replace`, `insertAtCaret`,
/// `insertImageMarkdown`, `mode`, `setFontScale` and `reloadImage` wait and run, in order, when the
/// composition is committed or cancelled.
@MainActor
public final class MarkdownEditorView: NSView {
    // MARK: Public state

    /// The mode the app asked for; the display follows once nothing is being composed.
    public var mode: MarkdownEditorMode {
        get { requestedMode }
        set {
            guard newValue != requestedMode else { return }
            requestedMode = newValue
            settingsChanged()
        }
    }

    /// The committed text (an input method's composition is not text until it is committed).
    public private(set) var text: String = ""

    /// The text view has marked text (an input method is composing).
    public var isComposing: Bool { textView.hasMarkedText() }

    /// Every committed change to the document: typing, paste, delete, undo, a task toggle,
    /// `replace`, `insertAtCaret`, `insertImageMarkdown`. Never while composing, never for `load` /
    /// `applyExternalText` (the app knows that text) unless a composition committed meanwhile.
    public var onTextChange: ((String) -> Void)?
    public var onCaretChange: ((MarkdownCaret) -> Void)?
    /// A pasted or dropped image; true = handled (the app saves it and calls `insertImageMarkdown`).
    public var onPasteImage: ((MarkdownPastedImage) -> Bool)?
    /// Relative path of an image line → its image, original pixel size, caption and overlay. Called
    /// lazily (when the line is laid out) and cached until `reloadImage(path:)` or a new document.
    public var imageResolver: ((String) -> MarkdownImageInfo?)? {
        didSet { imageSourcesChanged() }
    }
    /// The panel right of a figure (the annotation summary); cached per path.
    public var imageAccessoryProvider: ((MarkdownImageInfo) -> NSView?)? {
        didSet { imageSourcesChanged() }
    }
    /// Shown under the H1 title line (the chips row), live preview only.
    public var titleAccessory: NSView? {
        didSet {
            if oldValue !== titleAccessory { oldValue?.removeFromSuperview() }
            invalidateTitleLine()
        }
    }
    /// A click on a link / note chip in live preview (⌘-click in source mode): the URL as written.
    public var onOpenLink: ((String) -> Void)?
    /// ⌘⇧A on an image line, a double click on a figure: the image's relative path.
    public var onEditImageAnnotations: ((String) -> Void)?
    /// ⌘⏎ (send), only without marked text.
    public var onCommandReturn: (() -> Void)?
    /// Fences hidden after an image line in live preview (§3.3).
    public var hiddenFenceInfoStrings: Set<String> = MarkdownBlockParser.defaultHiddenFenceInfoStrings {
        didSet {
            guard oldValue != hiddenFenceInfoStrings else { return }
            fencesChanged = true
            settingsChanged()
        }
    }
    /// Drawn on an empty first line (or `# ` alone) in the title style.
    public var placeholderTitle: String = "標題" {
        didSet { textView.needsDisplay = true }
    }

    /// Live preview shows the caret paragraph's syntax (and the caret band) while the editor is
    /// first responder, like a rendered page otherwise; true shows it without focus too
    /// (snapshots, a second view of the same note).
    public var revealsCaretLineWhenInactive = false {
        didSet { if oldValue != revealsCaretLineWhenInactive { updateReveal(force: true) } }
    }

    public var textViewForTesting: NSTextView { textView }

    // MARK: Stack

    let storage: NSTextStorage
    let layoutManagerRef: MarkdownLayoutManager
    let container: NSTextContainer
    let textView: MarkdownTextView
    let scrollView: NSScrollView

    // MARK: Model

    let baseStyle: MarkdownEditorStyle
    private(set) var style: MarkdownEditorStyle
    private(set) var styler: MarkdownStyler
    private(set) var appliedMode: MarkdownEditorMode = .livePreview
    private var requestedMode: MarkdownEditorMode = .livePreview
    private var requestedScale: CGFloat = 1
    private var appliedScale: CGFloat = 1
    private var fencesChanged = false
    var appliedHiddenFences: Set<String> = MarkdownBlockParser.defaultHiddenFenceInfoStrings
    var blocks: [MarkdownBlock] = []
    /// Whole blocks the selection touches: their syntax is shown (live preview).
    var revealedRange: NSRange?
    /// Starts of the folded H2 lines, ascending, and the sections they hide.
    var foldedHeadings: [Int] = []
    var foldedSections: [NSRange] = []
    var imageCache: [String: MarkdownImageInfo?] = [:]
    var accessoryViews: [String: [NSView]] = [:]
    var accessoryHeights: [String: (width: CGFloat, height: CGFloat)] = [:]
    var titleAccessoryHeightCache: (width: CGFloat, height: CGFloat)?

    // MARK: Composition queue

    enum PendingOperation {
        case load(String, NSRange?)
        case external(String, base: String)
        case replace(NSRange, String, actionName: String, base: String)
        case insertAtCaret(String)
        case insertImage(alt: String, path: String)
        case reloadImage(String?)
    }

    private var queue: [PendingOperation] = []
    private var pendingSettings = false
    /// Composition edits not yet reparsed (current coordinates).
    var pendingDirty: NSRange?
    /// Committed edits reparsed but not restyled yet (current coordinates; `restyleAfterEdit`).
    var pendingRestyle: NSRange?
    /// Inside `load`: the storage edit is parsed and styled as a whole.
    var loading = false
    /// Programmatic text replacements (`applyExternalText`) that the app already knows.
    private var suppressTextChange = false
    /// What the app last saw: given by `load` / `applyExternalText` or sent by `onTextChange`.
    private var lastKnownText = ""
    /// Increments with every character edit (a paste then an edit = "the note changed meanwhile").
    var generation = 0
    var pasteGeneration: Int?
    /// The user placed the caret since the last `load` (else inserts go to the end).
    var hasUserCaret = false
    var programmaticSelection = false
    private var clipObserver: NSObjectProtocol?

    // MARK: Init

    public init(style: MarkdownEditorStyle = .notebook) {
        baseStyle = style
        self.style = style
        styler = MarkdownStyler(style: style, mode: .livePreview)
        storage = NSTextStorage()
        layoutManagerRef = MarkdownLayoutManager()
        storage.addLayoutManager(layoutManagerRef)
        container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManagerRef.addTextContainer(container)
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        layoutManagerRef.editor = self
        layoutManagerRef.delegate = self
        layoutManagerRef.allowsNonContiguousLayout = true
        layoutManagerRef.backgroundLayoutEnabled = true
        storage.delegate = self
        textView.editor = self
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)
        applyStyleToView()
        clipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("MarkdownEditorView is built in code")
    }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    private func applyStyleToView() {
        textView.applyInsets(style.padding)
        textView.backgroundColor = style.background
        scrollView.backgroundColor = style.background
        textView.insertionPointColor = style.caret
        textView.selectedTextAttributes = [.backgroundColor: style.selectionBackground, .foregroundColor: style.selectionText]
        textView.markedTextAttributes = [
            .foregroundColor: style.markedText,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: style.markedText,
        ]
        textView.typingAttributes = styler.base(for: blocks.isEmpty ? .heading(level: 1) : .paragraph)
    }

    // MARK: Layout

    override public var isFlipped: Bool { true }

    override public func layout() {
        super.layout()
        scrollView.frame = bounds
        let content = scrollView.contentSize
        textView.minSize = NSSize(width: 0, height: content.height)
        if textView.frame.width != content.width {
            textView.setFrameSize(NSSize(width: content.width, height: max(textView.frame.height, content.height)))
        }
        layoutAccessories()
    }

    // MARK: Public API

    /// A new document: replaces the text without an undo step, clears undo, folds and the image
    /// cache. Waits while composing.
    public func load(_ text: String, selection: NSRange?) {
        if textView.isComposing {
            queue.removeAll { if case .load = $0 { true } else if case .external = $0 { true } else { false } }
            queue.append(.load(text, selection))
            return
        }
        performLoad(text, selection: selection)
    }

    /// The same document changed on disk: the editor shows `text`, keeping the selection (mapped
    /// through the change) and the scroll position; one undoable step. Waits while composing; if a
    /// composition was committed meanwhile, it is kept in the new text.
    public func applyExternalText(_ text: String) {
        if textView.isComposing {
            queue.append(.external(text, base: committedText))
            return
        }
        performExternal(text, mine: nil, base: nil)
    }

    /// One undoable edit (the ImageAnnotate `完成` rewrite of a `codd-annotations` block).
    public func replace(_ range: NSRange, with string: String, actionName: String) {
        if textView.isComposing {
            queue.append(.replace(range, string, actionName: actionName, base: committedText))
            return
        }
        performReplace(range, with: string, actionName: actionName)
    }

    /// Inserts at the caret (replacing a selection), or at the end when the user never placed one.
    public func insertAtCaret(_ string: String) {
        if textView.isComposing {
            queue.append(.insertAtCaret(string))
            return
        }
        performInsertAtCaret(string)
    }

    /// D9: `![alt](path)` on a line of its own at the caret, or at the end when the note changed
    /// since the paste (or there is no caret). Never while marked text exists.
    public func insertImageMarkdown(alt: String, path: String) {
        if textView.isComposing {
            queue.append(.insertImage(alt: alt, path: path))
            return
        }
        performInsertImage(alt: alt, path: path)
    }

    /// The app decoded (or changed) an image: drop the cached info for `path` (nil = all) and redraw.
    public func reloadImage(path: String?) {
        if textView.isComposing {
            queue.append(.reloadImage(path))
            return
        }
        performReloadImage(path)
    }

    /// The title accessory or a figure accessory changed its height: lay those lines out again.
    public func invalidateAccessoryLayout() {
        accessoryHeights.removeAll()
        titleAccessoryHeightCache = nil
        // Only the lines accessories size (the chips row's `updated` changes with every save
        // minute; a whole-document relayout then could move the text under the caret).
        if !blocks.isEmpty { invalidateLayout(of: 0) }
        for (index, block) in blocks.enumerated() {
            if case .image = block.kind { invalidateLayout(of: index) }
        }
        textView.needsDisplay = true
        needsLayout = true
    }

    /// Makes the text view first responder (never activates the app).
    public func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Multiplies every font size and metric (⌘+ / ⌘−). Waits while composing.
    public func setFontScale(_ scale: CGFloat) {
        let clamped = max(0.5, min(3, scale))
        guard clamped != requestedScale else { return }
        requestedScale = clamped
        settingsChanged()
    }

    /// The image path of the caret's image line (or of the image a hidden annotation block
    /// belongs to); the app's ⌘⇧A menu item can ask before opening ImageAnnotate.
    public var imagePathAtCaret: String? {
        imageBlockIndex(near: textView.selectedRange().location).flatMap { index -> String? in
            if case let .image(_, path) = blocks[index].kind { return path }
            return nil
        }
    }

    /// Starts of the folded H2 lines (view state only; the text never changes).
    public var foldedHeadingLocations: [Int] { foldedHeadings }

    /// Folds or unfolds the H2 whose line starts at `location` (the `▾` glyph's click). Ignored
    /// while composing (nothing is hidden or revealed then).
    public func setFolded(_ folded: Bool, headingAt location: Int) {
        guard !textView.isComposing, let index = MarkdownBlockParser.blockIndex(containing: location, in: blocks), case .heading(2) = blocks[index].kind,
              isFolded(headingAt: index) != folded
        else { return }
        toggleFold(headingAt: index)
    }

    /// Puts the caret at `location` (UTF-16, clamped) and scrolls its line into view, as a click
    /// there would (the app's ASSETS thumbnail jumps to its image line). Ignored while composing:
    /// the composition keeps its place.
    public func revealLocation(_ location: Int) {
        guard !textView.isComposing else { return }
        let target = NSRange(location: min(max(0, location), storage.length), length: 0)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
    }

    /// The caret's rectangle in this view's coordinates (for a popover at the caret).
    public func caretRect() -> NSRect? {
        guard let rect = caretRectInTextView() else { return nil }
        return convert(rect, from: textView)
    }

    /// A new resolver or accessory provider: the cached figures go (after the composition).
    private func imageSourcesChanged() {
        if textView.isComposing {
            queue.append(.reloadImage(nil))
        } else {
            resetImages()
        }
    }

    // MARK: Composition

    /// The text without the marked range.
    var committedText: String {
        guard textView.hasMarkedText() else { return storage.string }
        let marked = textView.markedRange()
        let all = storage.string as NSString
        guard marked.location != NSNotFound, NSMaxRange(marked) <= all.length else { return storage.string }
        return all.replacingCharacters(in: marked, with: "")
    }

    func markedTextDidChange() {
        if !textView.hasMarkedText() { flushAfterComposition() }
    }

    func compositionMayHaveEnded() {
        if !textView.hasMarkedText() { flushAfterComposition() }
    }

    /// The composition ended: reparse what it edited, apply what waited, then report once.
    private func flushAfterComposition() {
        guard !textView.isComposing else { return }
        restyleAfterEdit()
        if let dirty = pendingDirty {
            pendingDirty = nil
            reparseAndRestyle(dirty)
        }
        if pendingSettings {
            pendingSettings = false
            applySettings()
        }
        let operations = queue
        queue = []
        let composedText = storage.string
        for operation in operations {
            switch operation {
            case let .load(text, selection):
                performLoad(text, selection: selection)
            case let .external(text, base):
                performExternal(text, mine: storage.string, base: base)
                lastKnownText = text
            case let .replace(range, string, actionName, base):
                performReplace(Self.map(range, from: base, to: composedText), with: string, actionName: actionName)
            case let .insertAtCaret(string):
                performInsertAtCaret(string)
            case let .insertImage(alt, path):
                performInsertImage(alt: alt, path: path)
            case let .reloadImage(path):
                performReloadImage(path)
            }
        }
        selectionDidChange(stillSelecting: false)
        publishIfChanged()
    }

    private func settingsChanged() {
        if textView.isComposing {
            pendingSettings = true
        } else {
            applySettings()
        }
    }

    /// Mode, scale or hidden fences changed: new styler, full restyle, every glyph and line again.
    private func applySettings() {
        let reparse = fencesChanged
        fencesChanged = false
        appliedMode = requestedMode
        appliedScale = requestedScale
        appliedHiddenFences = hiddenFenceInfoStrings
        style = baseStyle.scaled(by: appliedScale)
        styler = MarkdownStyler(style: style, mode: appliedMode)
        accessoryHeights.removeAll()
        titleAccessoryHeightCache = nil
        applyStyleToView()
        storage.beginEditing()
        if reparse { blocks = MarkdownBlockParser.blocks(in: storage.mutableString, hiddenFenceInfoStrings: appliedHiddenFences) }
        restyleAll()
        storage.endEditing()
        recomputeFolds()
        invalidateEverything()
        updateReveal(force: true)
    }

    // MARK: Text operations

    /// One editing pass: the text, its parse (with the inline spans, so every line is scanned
    /// once) and its attributes, so the layout manager invalidates once.
    private func performLoad(_ text: String, selection: NSRange?) {
        loading = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        let parsed = MarkdownBlockParser.blocksWithSpans(in: storage.mutableString, hiddenFenceInfoStrings: appliedHiddenFences)
        blocks = parsed.blocks
        if !blocks.isEmpty {
            styler.apply(blocks, spans: parsed.spans, to: storage, window: UTF16Window(storage.mutableString, from: 0, prefetchAll: true))
        }
        storage.endEditing()
        loading = false
        textView.ownUndoManager.removeAllActions()
        foldedHeadings = []
        foldedSections = []
        resetImages(invalidate: false)
        self.text = storage.string
        lastKnownText = self.text
        pasteGeneration = nil
        revealedRange = nil
        let length = storage.length
        let target = selection.map { NSRange(location: min(max(0, $0.location), length), length: 0) }
            .map { NSRange(location: $0.location, length: min(selection?.length ?? 0, length - $0.location)) }
        setSelectionProgrammatically(target ?? NSRange(location: 0, length: 0))
        hasUserCaret = selection != nil
        textView.typingAttributes = typingAttributes(at: textView.selectedRange().location)
        updateReveal(force: true)
        if let target {
            textView.scrollRangeToVisible(target)
        } else {
            textView.scroll(.zero)
        }
        needsLayout = true
    }

    private func performExternal(_ text: String, mine: String?, base: String?) {
        let target: String
        if let mine, let base, mine != base {
            target = Self.merge(base: base, mine: mine, theirs: text)
        } else {
            target = text
        }
        let origin = scrollView.contentView.bounds.origin
        suppressTextChange = true
        applyTextChange(to: target, actionName: "外部變更")
        suppressTextChange = false
        self.text = storage.string
        lastKnownText = text
        layoutManagerRef.ensureLayout(forBoundingRect: NSRect(origin: origin, size: scrollView.contentSize), in: container)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsLayout = true
    }

    private func performReplace(_ range: NSRange, with string: String, actionName: String) {
        let length = storage.length
        let location = min(max(0, range.location), length)
        let clamped = NSRange(location: location, length: min(max(0, range.length), length - location))
        let selection = textView.selectedRange()
        let mapped = Self.mapSelection(selection, through: clamped, replacementLength: (string as NSString).length)
        performEdit(clamped, with: string, actionName: actionName, selectionAfter: mapped)
    }

    private func performInsertAtCaret(_ string: String) {
        let selection = hasUserCaret ? textView.selectedRange() : NSRange(location: storage.length, length: 0)
        let inserted = MarkdownTextView.normalizingLineEndings(string)
        performEdit(selection, with: inserted, actionName: nil,
                    selectionAfter: NSRange(location: selection.location + (inserted as NSString).length, length: 0))
    }

    private func performInsertImage(alt: String, path: String) {
        let changedSincePaste = pasteGeneration.map { $0 != generation } ?? false
        pasteGeneration = nil
        let all = storage.mutableString
        let length = all.length
        let atEnd = changedSincePaste || !hasUserCaret
        let selection = atEnd ? NSRange(location: length, length: 0) : textView.selectedRange()
        var line = "![\(Self.escapedAlt(alt))](\(Self.escapedPath(path)))"
        let before = selection.location > 0 ? all.character(at: selection.location - 1) : Unit.newline
        let afterIndex = NSMaxRange(selection)
        let after = afterIndex < length ? all.character(at: afterIndex) : Unit.newline
        if before != Unit.newline { line = "\n" + line }
        if after != Unit.newline || afterIndex >= length { line += "\n" }
        let caret = selection.location + (line as NSString).length
        performEdit(selection, with: line, actionName: "貼上圖片", selectionAfter: NSRange(location: caret, length: 0))
    }

    private func performReloadImage(_ path: String?) {
        if let path {
            imageCache[path] = nil
            accessoryHeights[path] = nil
            for (index, block) in blocks.enumerated() {
                if case let .image(_, blockPath) = block.kind, blockPath == path { invalidateLayout(of: index) }
            }
        } else {
            resetImages()
        }
        textView.needsDisplay = true
        needsLayout = true
    }

    /// One undoable edit through the text view (so undo, notifications and the restyle all apply).
    @discardableResult
    func performEdit(_ range: NSRange, with string: String, actionName: String?, selectionAfter: NSRange?) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return false }
        let undo = textView.ownUndoManager
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        if let actionName { undo.setActionName(actionName) }
        textView.breakUndoCoalescing()
        if let selectionAfter {
            let length = storage.length
            let location = min(selectionAfter.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selectionAfter.length, length - location)))
        }
        return true
    }

    /// The whole text becomes `target` through the smallest replacement (selection mapped).
    private func applyTextChange(to target: String, actionName: String) {
        let old = storage.mutableString
        let new = target as NSString
        guard let (range, replacement) = Self.difference(old, new) else { return }
        let mapped = Self.mapSelection(textView.selectedRange(), through: range, replacementLength: (replacement as NSString).length)
        performEdit(range, with: replacement, actionName: actionName, selectionAfter: mapped)
    }

    func committedTextDidChange() {
        guard !suppressTextChange else { return }
        publish()
    }

    private func publish() {
        let current = storage.string
        text = current
        lastKnownText = current
        onTextChange?(current)
    }

    private func publishIfChanged() {
        let current = storage.string
        text = current
        guard current != lastKnownText else { return }
        lastKnownText = current
        onTextChange?(current)
    }

    func setSelectionProgrammatically(_ range: NSRange) {
        programmaticSelection = true
        textView.setSelectedRange(range)
        programmaticSelection = false
    }

    // MARK: Text helpers

    /// The common-prefix / common-suffix difference: the range in `old` and its replacement. The
    /// edges never split a surrogate pair or a CRLF.
    static func difference(_ old: NSString, _ new: NSString) -> (NSRange, String)? {
        let oldLength = old.length
        let newLength = new.length
        let limit = min(oldLength, newLength)
        var prefix = 0
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        if prefix == oldLength, prefix == newLength { return nil }
        while prefix > 0, splits(old, at: prefix) || splits(new, at: prefix) { prefix -= 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        while suffix > 0, splits(old, at: oldLength - suffix) || splits(new, at: newLength - suffix) { suffix -= 1 }
        let range = NSRange(location: prefix, length: oldLength - suffix - prefix)
        let replacement = new.substring(with: NSRange(location: prefix, length: newLength - suffix - prefix))
        return (range, replacement)
    }

    /// A cut at `index` would split a surrogate pair or a CRLF.
    private static func splits(_ text: NSString, at index: Int) -> Bool {
        guard index > 0, index < text.length else { return false }
        let before = text.character(at: index - 1)
        let after = text.character(at: index)
        return (after >= 0xDC00 && after <= 0xDFFF && before >= 0xD800 && before <= 0xDBFF)
            || (before == Unit.carriageReturn && after == Unit.newline)
    }

    static func mapSelection(_ selection: NSRange, through range: NSRange, replacementLength: Int) -> NSRange {
        let delta = replacementLength - range.length
        func map(_ position: Int) -> Int {
            if position <= range.location { return position }
            if position >= NSMaxRange(range) { return position + delta }
            return range.location + replacementLength
        }
        let start = map(selection.location)
        let end = map(NSMaxRange(selection))
        return NSRange(location: start, length: max(0, end - start))
    }

    /// A range given against `base` mapped into `current` (the committed composition in between).
    static func map(_ range: NSRange, from base: String, to current: String) -> NSRange {
        guard let (change, replacement) = difference(base as NSString, current as NSString) else { return range }
        let length = (replacement as NSString).length
        return mapSelection(range, through: change, replacementLength: length)
    }

    /// Three-way merge of two single-region changes against `base`: the external change applied to
    /// the user's text; when both touched the same place, the external text wins and the user's
    /// insertion is kept right after it (nothing typed is lost; one ⌘Z restores the user's text).
    static func merge(base: String, mine: String, theirs: String) -> String {
        let b = base as NSString
        guard let (userRange, userText) = difference(b, mine as NSString) else { return theirs }
        guard let (externalRange, externalText) = difference(b, theirs as NSString) else { return mine }
        let userDelta = (userText as NSString).length - userRange.length
        if NSMaxRange(userRange) <= externalRange.location, userRange != externalRange {
            let shifted = NSRange(location: externalRange.location + userDelta, length: externalRange.length)
            return (mine as NSString).replacingCharacters(in: shifted, with: externalText)
        }
        if NSMaxRange(externalRange) <= userRange.location {
            return (mine as NSString).replacingCharacters(in: externalRange, with: externalText)
        }
        let externalLength = (externalText as NSString).length
        let position = userRange.location <= externalRange.location ? userRange.location : externalRange.location + externalLength
        return (theirs as NSString).replacingCharacters(in: NSRange(location: position, length: 0), with: userText)
    }

    static func escapedAlt(_ alt: String) -> String {
        alt.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "]", with: "\\]").replacingOccurrences(of: "[", with: "\\[")
    }

    static func escapedPath(_ path: String) -> String {
        path.contains(" ") || path.contains("(") || path.contains(")") ? "<\(path)>" : path
    }
}
