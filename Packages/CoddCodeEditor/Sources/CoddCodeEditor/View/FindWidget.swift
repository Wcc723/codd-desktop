import AppKit
import CoddUI

/// A find-widget length (the FileEditor board's `.fe-find` px) at the current interface zoom; the
/// widget is laid out by hand, so it grows with its zoomed fonts. Exact at UI 字級 13.
func cz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

/// The find / replace fields' editor: a TextKit 1 field editor that reports committed text only
/// (no search while 注音 composes) and hands Return / Esc to the widget only without marked text.
final class FindFieldEditor: NSTextView {
    var onCommittedChange: (() -> Void)?
    /// A command the widget handles (Return, Esc); true when it did.
    var onCommand: ((Selector) -> Bool)?
    private var ownedStorage: NSTextStorage?
    private var inputDepth = 0

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        ownedStorage = storage
        isFieldEditor = true
        isRichText = false
        importsGraphics = false
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
        writingToolsBehavior = .none
        usesFindBar = false
        allowsUndo = true
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func doCommand(by selector: Selector) {
        if hasMarkedText() {
            if selector == #selector(insertNewline(_:)) {
                inputContext?.discardMarkedText()
                unmarkText()
                return
            }
            super.doCommand(by: selector)
            return
        }
        if onCommand?(selector) == true { return }
        super.doCommand(by: selector)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let marked = hasMarkedText()
        if marked { inputDepth += 1 }
        // A pasted newline would end the field's single line.
        var value = string
        if let text = value as? String { value = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ") }
        super.insertText(value, replacementRange: replacementRange)
        if marked {
            inputDepth -= 1
            report()
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        inputDepth += 1
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        inputDepth -= 1
    }

    override func unmarkText() {
        let wasMarked = hasMarkedText()
        inputDepth += 1
        super.unmarkText()
        inputDepth -= 1
        if wasMarked { report() }
    }

    override func didChangeText() {
        super.didChangeText()
        if inputDepth == 0 { report() }
    }

    private func report() {
        guard !hasMarkedText() else { return }
        onCommittedChange?()
    }
}

/// The find field's cell hands out the widget's own field editor (not the window's shared one).
final class FindFieldCell: NSTextFieldCell {
    weak var customEditor: FindFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        customEditor
    }

    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let text = super.setUpFieldEditorAttributes(textObj)
        if let editor = text as? NSTextView {
            editor.insertionPointColor = Palette.amber
            editor.markedTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Palette.amber]
            editor.selectedTextAttributes = [.backgroundColor: Palette.amber, .foregroundColor: NSColor.black]
        }
        return text
    }
}

/// `.fe-fin`: borderless 12 pt mono, cream, amber caret.
final class FindTextField: NSTextField {
    let editor = FindFieldEditor()

    init(placeholder: String) {
        super.init(frame: .zero)
        let cell = FindFieldCell(textCell: "")
        cell.customEditor = editor
        cell.isEditable = true
        cell.isSelectable = true
        cell.isScrollable = true
        cell.wraps = false
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byClipping
        cell.isBordered = false
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.focusRingType = .none
        self.cell = cell
        font = Typeface.mono(12)
        textColor = Palette.cream
        placeholderAttributedString = TextStyle.mono(12, Palette.dimmer).string(placeholder)
        setAccessibilityLabel(placeholder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What is typed (the field editor's text while editing).
    var currentText: String {
        if let editing = currentEditor() as? NSTextView { return editing.string }
        return stringValue
    }

    var isComposing: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    func setText(_ text: String) {
        stringValue = text
        if let editing = currentEditor() as? NSTextView {
            editing.string = text
            editing.selectAll(nil)
        }
    }
}

/// `.icon-btn.fe-ib`: 22 × 22, a 12 pt glyph in --dim, amber with a hairline on hover.
final class FindIconButton: NSButton {
    var glyph: String { didSet { needsDisplay = true } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(_ glyph: String, label: String) {
        self.glyph = glyph
        super.init(frame: NSRect(x: 0, y: 0, width: cz(22), height: cz(22)))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let hot = hovered && isEnabled
        if hot { Draw.strokeRect(bounds, color: Palette.lineBright) }
        if isHighlighted { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.1)) }
        let color = !isEnabled ? Palette.dim.withAlphaComponent(0.4) : (hot ? Palette.amber : Palette.dim)
        let text = TextStyle.mono(12, color).string(glyph)
        Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
    }
}

/// `.fe-opt`: `Aa`, underlined `ab`, `.*`; on = amber with an amber-dim hairline.
final class FindOptionButton: NSButton {
    let label: String
    let underlined: Bool
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn) } }
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(_ label: String, underlined: Bool = false, accessibility: String) {
        self.label = label
        self.underlined = underlined
        super.init(frame: NSRect(x: 0, y: 0, width: cz(22), height: cz(18)))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .none
        setAccessibilityLabel(accessibility)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.1))
            Draw.strokeRect(bounds, color: Palette.amberDim)
        } else if hovered {
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
        let color = isOn || hovered ? Palette.amber : Palette.dim
        var attributes = TextStyle.mono(10.5, color).attributes()
        if underlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let text = NSAttributedString(string: label, attributes: attributes)
        Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
    }
}

/// The find widget (`.fe-find`), top right of the code view under its top edge: replace toggle,
/// the 232 × 24 query field with `Aa` / `ab` / `.*`, the `3/7` count, `↑` `↓` `✕`; the replace row
/// (`取代` / `全部取代`) under it when toggled. The view is larger than its box by the shadow's
/// reach; clicks outside the box fall through.
final class FindWidgetView: FlippedView {
    weak var editor: CodeEditorView?
    let style: CodeEditorStyle

    let toggleButton = FindIconButton("▸", label: "切換取代")
    let queryField = FindTextField(placeholder: "尋找")
    let caseButton = FindOptionButton("Aa", accessibility: "大小寫須相符")
    let wordButton = FindOptionButton("ab", underlined: true, accessibility: "全字拼寫須相符")
    let regexButton = FindOptionButton(".*", accessibility: "使用規則運算式")
    let previousButton = FindIconButton("↑", label: "上一個相符項目 ⇧⏎")
    let nextButton = FindIconButton("↓", label: "下一個相符項目 ⏎")
    let closeButton = FindIconButton("✕", label: "關閉尋找 esc")
    let replaceField = FindTextField(placeholder: "取代")
    let replaceButton = CoddButton("取代", style: .bracket(.normal, small: true))
    let replaceAllButton = CoddButton("全部取代", style: .bracket(.normal, small: true))

    /// The shadow's reach around the box (`box-shadow: 0 8px 24px`).
    static let shadowInsets = NSEdgeInsets(top: 0, left: 24, bottom: 32, right: 24)

    var options = FindOptions() {
        didSet {
            caseButton.isOn = options.caseSensitive
            wordButton.isOn = options.wholeWord
            regexButton.isOn = options.regex
        }
    }

    var countText = "" { didSet { if countText != oldValue { needsLayout = true; needsDisplay = true } } }
    /// The regex does not compile: the field border dims, no glow.
    var isInvalid = false { didSet { if isInvalid != oldValue { needsDisplay = true } } }
    var replaceVisible = false {
        didSet {
            toggleButton.glyph = replaceVisible ? "▾" : "▸"
            toggleButton.setAccessibilityExpanded(replaceVisible)
            replaceField.isHidden = !replaceVisible
            replaceButton.isHidden = !replaceVisible
            replaceAllButton.isHidden = !replaceVisible
            needsLayout = true
            needsDisplay = true
        }
    }
    var replaceAllowed = true { didSet { toggleButton.isEnabled = replaceAllowed } }

    init(style: CodeEditorStyle) {
        self.style = style
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("在檔案中尋找")
        for view: NSView in [toggleButton, queryField, caseButton, wordButton, regexButton, previousButton, nextButton,
                             closeButton, replaceField, replaceButton, replaceAllButton] {
            addSubview(view)
        }
        toggleButton.target = self
        toggleButton.action = #selector(toggleReplace)
        for button in [caseButton, wordButton, regexButton] {
            button.target = self
            button.action = #selector(toggleOption(_:))
        }
        previousButton.target = self
        previousButton.action = #selector(previous)
        nextButton.target = self
        nextButton.action = #selector(next)
        closeButton.target = self
        closeButton.action = #selector(close)
        replaceButton.target = self
        replaceButton.action = #selector(replaceOne)
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceEverything)
        queryField.editor.onCommittedChange = { [weak self] in self?.editor?.findQueryChanged() }
        queryField.editor.onCommand = { [weak self] selector in self?.queryCommand(selector) ?? false }
        replaceField.editor.onCommand = { [weak self] selector in self?.replaceCommand(selector) ?? false }
        replaceVisible = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// What the field shows (the field editor's committed text while editing).
    var query: String { queryField.currentText }
    var replacement: String { replaceField.currentText }

    /// The modifiers held when Return arrives (Shift+Return also arrives as `insertNewline:`).
    var modifierFlagsProvider: () -> NSEvent.ModifierFlags = { NSApp?.currentEvent?.modifierFlags ?? [] }

    private func queryCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            if modifierFlagsProvider().contains(.shift) { editor?.findPrevious() } else { editor?.findNext() }
            return true
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            editor?.findPrevious()
            return true
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            editor?.hideFind()
            return true
        default:
            return false
        }
    }

    private func replaceCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(insertNewline(_:)):
            editor?.replaceCurrent()
            return true
        case #selector(cancelOperation(_:)), #selector(complete(_:)):
            editor?.hideFind()
            return true
        default:
            return false
        }
    }

    @objc private func toggleReplace() { editor?.setReplaceVisible(!replaceVisible) }
    @objc private func previous() { editor?.findPrevious() }
    @objc private func next() { editor?.findNext() }
    @objc private func close() { editor?.hideFind() }
    @objc private func replaceOne() { editor?.replaceCurrent() }
    @objc private func replaceEverything() { editor?.replaceAll() }

    @objc private func toggleOption(_ sender: FindOptionButton) {
        var changed = options
        if sender === caseButton { changed.caseSensitive.toggle() }
        if sender === wordButton { changed.wholeWord.toggle() }
        if sender === regexButton { changed.regex.toggle() }
        options = changed
        editor?.findOptionsChanged()
    }

    // MARK: Geometry

    private var countWidth: CGFloat {
        max(cz(44), Draw.width(TextStyle.mono(11, Palette.bone).string(countText)) + cz(14))
    }

    /// The widest the box may be (the editor's width less its margins; set by the editor): a
    /// narrow editor (small window, zoom 20) narrows the query field, down to 80, instead of
    /// letting the widget run over the views beside the editor.
    var maximumBoxWidth: CGFloat = .greatestFiniteMagnitude {
        didSet { if maximumBoxWidth != oldValue { needsLayout = true; needsDisplay = true } }
    }

    /// Everything on the query row but the field.
    private var queryRowChrome: CGFloat {
        1 + cz(6) + cz(22) + cz(2) + cz(2) + countWidth + cz(2) + cz(22) + cz(2) + cz(22) + cz(2) + cz(22) + cz(6) + 1
    }

    /// Everything on the replace row but the field.
    private var replaceRowChrome: CGFloat {
        let buttons = replaceButton.intrinsicContentSize.width + cz(4) + replaceAllButton.intrinsicContentSize.width
        return 1 + cz(6) + cz(22) + cz(2) + cz(6) + buttons + cz(6) + 1
    }

    /// The query (and replace) field's width: the style's, or less within `maximumBoxWidth`.
    var fieldWidth: CGFloat {
        var room = maximumBoxWidth - queryRowChrome
        if replaceVisible { room = min(room, maximumBoxWidth - replaceRowChrome) }
        return max(cz(80), min(cz(style.findFieldWidth), floor(room)))
    }

    /// The box (border included), excluding the shadow margin.
    var boxSize: NSSize {
        let field = fieldWidth
        var width = queryRowChrome + field
        var height: CGFloat = cz(5) + cz(style.findFieldHeight) + cz(5) + 1
        if replaceVisible {
            width = max(width, replaceRowChrome + field)
            height += cz(4) + cz(style.findFieldHeight)
        }
        return NSSize(width: ceil(width), height: height)
    }

    var boxRect: NSRect {
        let size = boxSize
        return NSRect(x: Self.shadowInsets.left, y: Self.shadowInsets.top, width: size.width, height: size.height)
    }

    var fittingFrameSize: NSSize {
        let size = boxSize
        return NSSize(width: size.width + Self.shadowInsets.left + Self.shadowInsets.right,
                      height: size.height + Self.shadowInsets.top + Self.shadowInsets.bottom)
    }

    var queryBoxRect: NSRect {
        let box = boxRect
        return NSRect(x: box.minX + 1 + cz(6) + cz(22) + cz(2), y: box.minY + cz(5), width: fieldWidth, height: cz(style.findFieldHeight))
    }

    var replaceBoxRect: NSRect {
        queryBoxRect.offsetBy(dx: 0, dy: cz(style.findFieldHeight) + cz(4))
    }

    var countRect: NSRect {
        let query = queryBoxRect
        return NSRect(x: query.maxX + cz(2), y: query.minY, width: countWidth, height: query.height)
    }

    override func layout() {
        super.layout()
        let box = boxRect
        let query = queryBoxRect
        let iconY = query.midY - cz(11)
        toggleButton.frame = NSRect(x: box.minX + cz(7), y: iconY, width: cz(22), height: cz(22))
        let optionsWidth: CGFloat = 3 * cz(22) + cz(3)
        let fieldHeight = ceil(Typeface.lineHeight(Typeface.mono(12))) + cz(2)
        queryField.frame = NSRect(x: query.minX + 1 + cz(7), y: query.midY - fieldHeight / 2, width: query.width - cz(2) - cz(7) - cz(2) - optionsWidth, height: fieldHeight)
        var x = queryField.frame.maxX + 1
        for button in [caseButton, wordButton, regexButton] {
            button.frame = NSRect(x: x, y: query.midY - cz(9), width: cz(22), height: cz(18))
            x += cz(23)
        }
        let count = countRect
        previousButton.frame = NSRect(x: count.maxX + cz(2), y: iconY, width: cz(22), height: cz(22))
        nextButton.frame = NSRect(x: previousButton.frame.maxX + cz(2), y: iconY, width: cz(22), height: cz(22))
        closeButton.frame = NSRect(x: nextButton.frame.maxX + cz(2), y: iconY, width: cz(22), height: cz(22))
        let replace = replaceBoxRect
        replaceField.frame = NSRect(x: replace.minX + 1 + cz(7), y: replace.midY - fieldHeight / 2, width: replace.width - cz(2) - cz(7) - cz(2), height: fieldHeight)
        let size = replaceButton.intrinsicContentSize
        replaceButton.frame = NSRect(x: replace.maxX + cz(6), y: replace.midY - size.height / 2, width: size.width, height: size.height)
        let allSize = replaceAllButton.intrinsicContentSize
        replaceAllButton.frame = NSRect(x: replaceButton.frame.maxX + cz(4), y: replace.midY - allSize.height / 2, width: allSize.width, height: allSize.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, boxRect.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point) ?? self
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = boxRect
        // `box-shadow: 0 8px 24px rgba(0,0,0,.6), 0 0 14px rgba(255,184,74,.08)`
        NSGraphicsContext.saveGraphicsState()
        let drop = NSShadow()
        drop.shadowColor = NSColor.black.withAlphaComponent(0.6)
        drop.shadowBlurRadius = 24
        drop.shadowOffset = NSSize(width: 0, height: -8)
        drop.set()
        Draw.fill(box, style.findBackground)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(Palette.amber.withAlphaComponent(0.08), radius: 14).set()
        Draw.fill(box, style.findBackground)
        NSGraphicsContext.restoreGraphicsState()
        // Border on three sides (`border-top:0`).
        let border = style.findBorder
        Draw.fill(NSRect(x: box.minX, y: box.minY, width: 1, height: box.height), border)
        Draw.fill(NSRect(x: box.maxX - 1, y: box.minY, width: 1, height: box.height), border)
        Draw.fill(NSRect(x: box.minX, y: box.maxY - 1, width: box.width, height: 1), border)
        drawField(queryBoxRect, active: !isInvalid)
        if replaceVisible { drawField(replaceBoxRect, active: false) }
        let count = countRect
        let countColor = isInvalid ? Palette.dim : Palette.bone
        Draw.text(TextStyle.mono(11, countColor).string(countText), x: count.minX + cz(8), centerY: count.midY)
    }

    /// `.fe-fq`: amber border with a glow (amber-dim without it while the pattern is invalid, and
    /// a line-bright border for the replace field).
    private func drawField(_ rect: NSRect, active: Bool) {
        if active {
            NSGraphicsContext.saveGraphicsState()
            Draw.glow(Palette.amberGlow, radius: 8).set()
            Draw.fill(rect, Palette.bg)
            NSGraphicsContext.restoreGraphicsState()
        }
        Draw.fill(rect, Palette.bg)
        let isReplace = rect == replaceBoxRect && replaceVisible
        Draw.strokeRect(rect, color: isReplace ? Palette.lineBright : (active ? Palette.amber : Palette.amberDim))
    }

    override func scrollWheel(with event: NSEvent) {
        editor?.scrollView.scrollWheel(with: event)
    }
}
