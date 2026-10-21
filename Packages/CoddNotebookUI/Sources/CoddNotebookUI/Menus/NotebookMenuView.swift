import AppKit
import CoddUI

/// A custom popover menu (helmet `.menu`; the Notebook artboard's `.nb-refmenu` two-line rows):
/// --bg-lift, 1 px --amber-dim border, `padding: 4px`; `.mh` headers, dashed separators, one-line
/// items (28 pt) and two-line items with a wrapping hint, an optional chip (`推薦`), a shortcut,
/// a `✓` for the current choice and `▸` for a submenu (shown in place, with a `‹` back row).
///
/// Keyboard (when it is first responder, e.g. in a key `PopoverPanel`): ↑ ↓ move the highlight
/// over enabled items, ⏎ / space activate, → opens a submenu, ← goes back, ⎋ goes back or
/// dismisses. The mouse highlights on hover and activates on click. Disabled items keep their
/// tooltip (`disabledReason`) and never activate.
public final class NotebookMenuView: NSView {
    public private(set) var model: NotebookMenuModel
    /// An item was chosen (the presenter then closes the menu).
    public var onActivate: ((NotebookMenuItem) -> Void)?
    /// ⎋ at the top level.
    public var onDismiss: (() -> Void)?
    /// The view's size changed (a submenu opened or closed); the presenter resizes its panel.
    public var onSizeChange: ((NSSize) -> Void)?

    /// The submenus opened in place, innermost last.
    public private(set) var stack: [NotebookMenuItem] = []
    public private(set) var highlightedID: String?
    private var rows: [MenuRowView] = []

    public static let backRowID = "__back__"

    /// Draws the `.menu` box (off when a picker draws the box around a field and the list).
    public var drawsFrame = true { didSet { needsDisplay = true } }

    public init(model: NotebookMenuModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        rebuild(resetHighlight: true)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Replaces the menu (keeps the highlight when the item still exists).
    public func update(_ model: NotebookMenuModel) {
        guard model != self.model else { return }
        self.model = model
        stack = stack.filter { opened in model.items.contains { $0.id == opened.id } }
        rebuild(resetHighlight: false)
    }

    /// The entries on screen (the innermost open submenu, else the menu).
    public var visibleEntries: [NotebookMenuEntry] {
        guard let open = stack.last, let submenu = open.submenu else { return model.entries }
        return [.item(NotebookMenuItem(id: Self.backRowID, glyph: .text("‹"), title: open.title))] + submenu.entries
    }

    /// The selectable items on screen, in order.
    public var visibleItems: [NotebookMenuItem] {
        visibleEntries.compactMap { if case .item(let item) = $0 { item } else { nil } }
    }

    // MARK: Size

    /// `.menu{min-width:220px}` unless the model fixes the width.
    public var menuWidth: CGFloat {
        if let width = model.width { return width }
        let widest = visibleEntries.map { MenuRowView.naturalWidth(of: $0) }.max() ?? 0
        return max(zp(220), ceil(widest + zp(2) + zp(8)))
    }

    public var preferredSize: NSSize {
        let width = menuWidth
        let inner = width - zp(2) - zp(8)
        let height = visibleEntries.reduce(CGFloat(0)) { $0 + MenuRowView.height(of: $1, width: inner) }
        return NSSize(width: width, height: ceil(height + zp(2) + zp(8)))
    }

    public override var intrinsicContentSize: NSSize { preferredSize }

    // MARK: Rows

    private func rebuild(resetHighlight: Bool) {
        rows.forEach { $0.removeFromSuperview() }
        rows = visibleEntries.map { entry in
            let row = MenuRowView(entry: entry)
            row.onHover = { [weak self, weak row] in
                guard let self, let row, let item = row.item, item.isEnabled else { return }
                self.setHighlight(item.id)
            }
            row.onClick = { [weak self, weak row] in
                guard let self, let item = row?.item else { return }
                self.activate(item)
            }
            addSubview(row)
            return row
        }
        let ids = visibleItems.filter(\.isEnabled).map(\.id)
        if resetHighlight || highlightedID.map({ !ids.contains($0) }) ?? true {
            let initial = stack.isEmpty ? model.initialHighlight : nil
            highlightedID = initial.flatMap { id in ids.contains(id) ? id : nil } ?? ids.first { $0 != Self.backRowID } ?? ids.first
        }
        syncHighlight()
        let size = preferredSize
        setFrameSize(size)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
        onSizeChange?(size)
    }

    private func syncHighlight() {
        for row in rows { row.isMenuHighlighted = row.item?.id == highlightedID && highlightedID != nil }
        setAccessibilityValue(highlightedID)
    }

    public func setHighlight(_ id: String?) {
        guard id != highlightedID else { return }
        highlightedID = id
        syncHighlight()
    }

    public override func layout() {
        super.layout()
        let inner = bounds.width - zp(2) - zp(8)
        var y: CGFloat = 1 + zp(4)
        for row in rows {
            let height = MenuRowView.height(of: row.entry, width: inner)
            row.frame = CGRect(x: 1 + zp(4), y: y, width: inner, height: height)
            y += height
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard drawsFrame else { return }
        Draw.fill(bounds, Palette.bgLift)
        Draw.strokeRect(bounds, color: Palette.amberDim)
    }

    /// The row view of an item (tests: frames, tooltips).
    func row(_ id: String) -> MenuRowView? { rows.first { $0.item?.id == id } }

    // MARK: Actions

    /// Chooses `item`: opens its submenu, goes back, or reports it.
    public func activate(_ item: NotebookMenuItem) {
        guard item.isEnabled else { return }
        if item.id == Self.backRowID {
            goBack()
        } else if item.submenu != nil {
            stack.append(item)
            rebuild(resetHighlight: true)
        } else {
            onActivate?(item)
        }
    }

    /// Activates the item with `id` (tests, the app's DEBUG paths).
    @discardableResult
    public func activate(id: String) -> Bool {
        guard let item = visibleItems.first(where: { $0.id == id }), item.isEnabled else { return false }
        activate(item)
        return true
    }

    @discardableResult
    func goBack() -> Bool {
        guard let left = stack.popLast() else { return false }
        rebuild(resetHighlight: true)
        setHighlight(left.id)
        return true
    }

    /// Moves the highlight over the enabled items (wrapping), like ↑ / ↓.
    public func moveHighlight(by delta: Int) { moveHighlight(delta) }

    /// Activates the highlighted item (⏎); false when nothing is highlighted.
    @discardableResult
    public func activateHighlighted() -> Bool {
        guard let id = highlightedID, let item = visibleItems.first(where: { $0.id == id }), item.isEnabled else { return false }
        activate(item)
        return true
    }

    private func moveHighlight(_ delta: Int) {
        let ids = visibleItems.filter(\.isEnabled).map(\.id)
        guard !ids.isEmpty else { return }
        guard let current = highlightedID, let index = ids.firstIndex(of: current) else {
            setHighlight(delta > 0 ? ids.first : ids.last)
            return
        }
        setHighlight(ids[(index + delta + ids.count) % ids.count])
    }

    /// Handles a key; returns false for keys the menu does not use.
    @discardableResult
    public func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: moveHighlight(-1)
        case 125: moveHighlight(1)
        case 36, 76, 49:
            if let id = highlightedID, let item = visibleItems.first(where: { $0.id == id }) { activate(item) }
        case 124:
            if let id = highlightedID, let item = visibleItems.first(where: { $0.id == id }), item.submenu != nil { activate(item) }
        case 123:
            goBack()
        case 53:
            if !goBack() { onDismiss?() }
        default:
            return false
        }
        return true
    }

    public override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    public override func cancelOperation(_ sender: Any?) {
        if !goBack() { onDismiss?() }
    }
}

/// One menu row (header, separator or item).
final class MenuRowView: HoverControl, NotebookTextProviding {
    let entry: NotebookMenuEntry
    var onHover: (() -> Void)?
    var isMenuHighlighted = false {
        didSet { if isMenuHighlighted != oldValue { needsDisplay = true; setAccessibilitySelected(isMenuHighlighted) } }
    }

    init(entry: NotebookMenuEntry) {
        self.entry = entry
        super.init(frame: .zero)
        dimsWhenDisabled = false
        // The menu keeps the keyboard focus and moves its highlight (↑ ↓ ⏎ ⎋).
        takesKeyboardFocus = false
        switch entry {
        case .item(let item):
            isEnabled = item.isEnabled
            toolTip = item.isEnabled ? nil : item.disabledReason
            setAccessibilityRole(.menuItem)
            setAccessibilityLabel([item.title, item.hint].compactMap { $0 }.joined(separator: "，"))
            setAccessibilityEnabled(item.isEnabled)
        case .header(let title, _):
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(title)
        case .separator:
            setAccessibilityElement(false)
        }
    }

    var item: NotebookMenuItem? { if case .item(let item) = entry { item } else { nil } }

    override func setHovered(_ value: Bool) {
        super.setHovered(value)
        if value { onHover?() }
    }

    override func performClick(_ sender: Any?) {
        guard item?.isEnabled == true else { return }
        super.performClick(sender)
    }

    // MARK: Metrics

    static var oneLineHeight: CGFloat { zp(28) }
    static var valueLineHeight: CGFloat { zp(17) }
    static var hintLineHeight: CGFloat { zp(round(10.5 * 1.45)) }

    static func headerStyle() -> TextStyle { TextStyle.caps(9.5, Palette.dim, tracking: 0.2) }
    static func headerTrailingStyle() -> TextStyle { TextStyle.mono(10.5, Palette.dim, tracking: 0.04) }
    static func hintStyle() -> TextStyle { TextStyle.mono(10.5, Palette.dim) }

    static func height(of entry: NotebookMenuEntry, width: CGFloat) -> CGFloat {
        switch entry {
        case .separator:
            return zp(9)
        case .header(_, let trailing):
            return zp(trailing == nil ? 24 : 26)
        case .item(let item):
            guard let hint = item.hint else { return oneLineHeight }
            let lines = hintLines(hint, width: hintWidth(item, rowWidth: width))
            return zp(7) + valueLineHeight + zp(2) + CGFloat(lines) * hintLineHeight + zp(7)
        }
    }

    /// The hint's column: row padding 10 + 10, the 14 pt glyph and its 10 pt gap, the shortcut.
    static func hintWidth(_ item: NotebookMenuItem, rowWidth: CGFloat) -> CGFloat {
        var width = rowWidth - zp(20) - zp(14) - zp(10)
        if let trailing = trailingText(item) { width -= Draw.width(trailingStyle(item).string(trailing)) + zp(10) }
        return max(zp(40), width)
    }

    static func hintLines(_ hint: String, width: CGFloat) -> Int {
        let text = hintAttributed(hint)
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return max(1, Int((ceil(rect.height) + hintLineHeight / 2) / hintLineHeight))
    }

    /// The hint wraps like `text-wrap: pretty` (no one-character CJK orphan when avoidable).
    static func hintAttributed(_ hint: String) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: hintStyle().string(hint, lineHeight: round(10.5 * 1.45), lineBreak: .byWordWrapping))
        if let paragraph = (out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy()
            as? NSMutableParagraphStyle {
            paragraph.lineBreakStrategy = .standard
            out.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    static func trailingText(_ item: NotebookMenuItem) -> String? {
        if item.isChecked { return "✓" }
        if item.submenu != nil { return "▸" }
        return item.shortcut
    }

    static func trailingStyle(_ item: NotebookMenuItem) -> TextStyle {
        if item.isChecked { return TextStyle.mono(12, Palette.amber) }
        return TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04)
    }

    static func naturalWidth(of entry: NotebookMenuEntry) -> CGFloat {
        switch entry {
        case .separator: return 0
        case .header(let title, let trailing):
            var width = zp(20) + Draw.width(headerStyle().string(title))
            if let trailing { width += zp(8) + Draw.width(headerTrailingStyle().string(trailing)) }
            return width
        case .item(let item):
            var width = zp(20) + zp(14) + zp(10) + Draw.width(titleStyle(item, highlighted: false).string(item.title))
            if let chip = item.chip { width += zp(6) + NotebookChip.recommended(chip).width }
            if let detail = item.detail { width += zp(10) + Draw.width(detailStyle.string(detail)) }
            if let trailing = trailingText(item) { width += zp(10) + Draw.width(trailingStyle(item).string(trailing)) }
            return item.hint == nil ? width : min(width, 404)
        }
    }

    static var detailStyle: TextStyle { TextStyle.mono(10.5, Palette.dimmer) }

    static func titleStyle(_ item: NotebookMenuItem, highlighted: Bool) -> TextStyle {
        let size: CGFloat = item.isTwoLine ? zp(11.5) : zp(12)
        let color: NSColor
        switch item.tone {
        case .amber: color = Palette.amber
        case .dim: color = Palette.dim
        case .danger: color = Palette.danger
        case .normal: color = item.isTwoLine || highlighted ? Palette.cream : Palette.bone
        }
        return TextStyle.mono(size, color)
    }

    // MARK: Drawing

    var drawnTexts: [String] {
        switch entry {
        case .separator: []
        case .header(let title, let trailing): [title.uppercased()] + (trailing.map { [$0] } ?? [])
        case .item(let item):
            [item.title] + (item.chip.map { [$0] } ?? []) + (item.detail.map { [$0] } ?? [])
                + (Self.trailingText(item).map { [$0] } ?? []) + (item.hint.map { [$0] } ?? [])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        switch entry {
        case .separator:
            // `.menu .sep{margin:4px 2px}` inside the menu's padding.
            Draw.dashedLine(from: CGPoint(x: zp(2), y: zp(4)), to: CGPoint(x: bounds.width - zp(2), y: zp(4)), color: Palette.lineBright)
        case .header(let title, let trailing):
            let titleText = Self.headerStyle().string(title)
            let centerY = zp(6) + (bounds.height - zp(10)) / 2
            Draw.text(titleText, x: zp(10), centerY: centerY)
            if let trailing {
                let text = Self.headerTrailingStyle().string(trailing)
                Draw.text(text, x: bounds.width - zp(10) - Draw.width(text), centerY: centerY)
            }
        case .item(let item):
            drawItem(item)
        }
    }

    private func drawItem(_ item: NotebookMenuItem) {
        let alpha: CGFloat = item.isEnabled ? 1 : 0.4
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        if isMenuHighlighted, item.isEnabled {
            Draw.fill(bounds, Palette.bgRaise)
            Draw.fill(CGRect(x: 0, y: 0, width: zp(2), height: bounds.height), Palette.amber)
        }
        let twoLine = item.isTwoLine
        let lineCenter = twoLine ? zp(7) + Self.valueLineHeight / 2 : bounds.midY
        // `.g`: 14 pt column (svg 14, `padding-top:1px` in two-line rows).
        let glyphRect = CGRect(x: zp(10), y: round(lineCenter - zp(7) + (twoLine ? 1 : 0)), width: zp(14), height: zp(14))
        if let glyph = item.glyph { drawGlyph(glyph, in: glyphRect, item: item) }
        var trailingWidth: CGFloat = 0
        if let trailing = Self.trailingText(item) {
            let text = Self.trailingStyle(item).string(trailing)
            trailingWidth = Draw.width(text)
            Draw.text(text, x: bounds.width - zp(10) - trailingWidth, centerY: twoLine ? zp(7) + zp(2) + zp(8) : bounds.midY)
        }
        let textX = glyphRect.maxX + zp(10)
        let textMax = bounds.width - zp(10) - (trailingWidth > 0 ? trailingWidth + zp(10) : 0)
        var pieces: [InlinePiece] = [.text(Self.titleStyle(item, highlighted: isMenuHighlighted).string(item.title), shrink: true)]
        if let chip = item.chip { pieces.append(.chip(.recommended(chip))) }
        if let detail = item.detail {
            pieces.append(.flex)
            var piece = InlinePiece.text(Self.detailStyle.string(detail), shrink: true, gapBefore: 10)
            piece.shrinksFirst = true
            pieces.append(piece)
        }
        let lineRect = CGRect(x: textX, y: lineCenter - Self.valueLineHeight / 2, width: max(0, textMax - textX), height: Self.valueLineHeight)
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: lineRect, gap: 6))
        if let hint = item.hint {
            let width = Self.hintWidth(item, rowWidth: bounds.width)
            let lines = Self.hintLines(hint, width: width)
            let rect = CGRect(x: textX, y: zp(7) + Self.valueLineHeight + zp(2), width: width, height: CGFloat(lines) * Self.hintLineHeight)
            Self.hintAttributed(hint).draw(with: rect, options: [.usesLineFragmentOrigin])
        }
    }

    private func drawGlyph(_ glyph: NotebookMenuGlyph, in rect: CGRect, item: NotebookMenuItem) {
        let color = item.tone == .danger ? Palette.danger : Palette.dim
        switch glyph {
        case .icon(let icon):
            NotebookIconRenderer.draw(icon, in: rect, color: color)
        case .text(let text):
            let string = TextStyle.mono(12, color).string(text)
            Draw.text(string, x: rect.midX - Draw.width(string) / 2, centerY: rect.midY)
        case .lamp(let state):
            let glyph = TextStyle.mono(11, state.color).string(state.glyph)
            NotebookDraw.lamp(state, x: rect.midX - Draw.width(glyph) / 2, centerY: rect.midY, size: 11)
        case .tag(let tag):
            NotebookDraw.tagSquare(tag, in: CGRect(x: rect.midX - zp(4), y: rect.midY - zp(4), width: zp(8), height: zp(8)))
        }
    }
}
