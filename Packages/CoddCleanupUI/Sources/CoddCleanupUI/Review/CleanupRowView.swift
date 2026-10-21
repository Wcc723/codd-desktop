import AppKit
import CoddUI

/// The table's column widths (`<colgroup>`: 36 · 226 · 184 · 128 · 156 · 196 = 926, the artboard's
/// table at a 1368 px page). Width beyond (or short of) 926 goes to ITEM, WHY and AI in proportion,
/// down to their minimums; the checkbox and the action column stay fixed, and STATUS widens for a
/// badge longer than its 112 px (`resume expires 4d`).
struct TableColumns: Equatable {
    /// Design points, at the interface zoom.
    static var base: [CGFloat] { [36, 226, 184, 128, 156, 196].map(kz) }
    static var minimum: [CGFloat] { [36, 120, 104, 128, 96, 196].map(kz) }
    static let flexible = [1, 2, 4]

    let widths: [CGFloat]

    /// `status`: the STATUS column's width (at least 128). A table narrower than every column's
    /// minimum (a small window, the interface zoom) folds the AI hint column (width 0) and gives its
    /// width to ITEM and WHY.
    init(width: CGFloat, status: CGFloat = 128) {
        var widths = Self.base
        widths[3] = max(Self.base[3], ceil(status))
        var minimum = Self.minimum
        minimum[3] = widths[3]
        var flexible = Self.flexible
        if width < minimum.reduce(0, +) {
            widths[4] = 0
            minimum[4] = 0
            flexible = [1, 2]
            // Still too narrow: ITEM and WHY share what the fixed columns leave (down to 60 pt).
            let fixed = widths[0] + widths[3] + widths[5]
            if width < fixed + minimum[1] + minimum[2] {
                let share = max(0, width - fixed) / (minimum[1] + minimum[2])
                minimum[1] = max(kz(60), (minimum[1] * share).rounded(.down))
                minimum[2] = max(kz(60), (minimum[2] * share).rounded(.down))
            }
        }
        let extra = width - widths.reduce(0, +)
        let flexBase = flexible.map { widths[$0] }.reduce(0, +)
        for index in flexible {
            widths[index] = max(minimum[index], (widths[index] + extra * widths[index] / flexBase).rounded(.down))
        }
        // Rounding leftovers go to ITEM so the columns fill the width exactly.
        let total = widths.reduce(0, +)
        if total < width { widths[1] += width - total }
        // A column held up at its minimum (AI at 96 on a 684 pt table) overflows the width: the
        // excess comes off the other flexible columns, ITEM first, down to their minimums; on a
        // folded table ITEM then gives what is still over, down to 40 pt.
        var over = total - width
        for index in flexible where over > 0 {
            let cut = min(over, max(0, widths[index] - minimum[index]))
            widths[index] -= cut
            over -= cut
        }
        if over > 0, widths[4] == 0 { widths[1] -= min(over, max(0, widths[1] - kz(40))) }
        self.widths = widths
    }

    var total: CGFloat { widths.reduce(0, +) }

    func x(_ column: Int) -> CGFloat { widths.prefix(column).reduce(0, +) }

    /// The content box of a cell (`td{padding:6px 8px}`; the checkbox column has `padding-left:14px`).
    func content(_ column: Int) -> (x: CGFloat, width: CGFloat) {
        column == 0 ? (kz(14), widths[0] - kz(14)) : (x(column) + kz(8), max(0, widths[column] - kz(16)))
    }

    /// Whether the AI hint column shows (it folds on a narrow table).
    var showsAI: Bool { widths[4] > 0 }
}

/// One candidate row (`.nb-cl-tbl tbody tr`): checkbox · title + chips · why + sub · status chip ·
/// AI hint · row actions. Selected: an amber 5 % wash and a 2 px amber bar at the left; hovered:
/// --bg-lift; the keyboard focus (space toggles it) draws a 1 px --amber-dim outline.
final class CleanupRowView: NSView {
    /// `td{padding:6px 8px;border-bottom:1px dashed}`: 12 + 1 around the tallest cell.
    static let verticalChrome: CGFloat = 13
    /// `.nb-cl-it`: title line (12.5 × 1.5) + gap 4 + the 17 px chip line.
    static let itemHeight: CGFloat = 12.5 * 1.5 + 4 + 17

    private(set) var row: CleanupRow
    var isSelected = false {
        didSet {
            checkbox.isOn = isSelected
            guard isSelected != oldValue else { return }
            setAccessibilitySelected(isSelected)
            restyle()
        }
    }
    var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true } } }
    private(set) var isHovered = false
    var onToggle: (() -> Void)?
    var onClick: (() -> Void)?
    var onAction: ((String) -> Void)?

    let checkbox = CheckboxButton(title: "", style: .plain)
    private var checkboxHolder: ButtonAction?
    private let title = TextLine(style: CleanupStyles.rowTitle)
    private var secondLine: [NSView] = []
    private let why = TextBlock(style: CleanupStyles.why, lineHeight: CleanupStyles.whyLineHeight)
    private let sub = TextBlock(style: CleanupStyles.whySub(highlighted: false), lineHeight: CleanupStyles.subLineHeight)
    private let badge = ChipBox("", style: CleanupStyles.statusChip(.plain))
    private let aiGlyph = AIGlyphView()
    private let aiText = TextBlock(style: CleanupStyles.ai(Palette.dim), lineHeight: CleanupStyles.aiLineHeight)
    private(set) var actionButtons: [CoddButton] = []
    private var actionHolders: [ButtonAction] = []
    private var trackingArea: NSTrackingArea?
    var columns = TableColumns(width: 926) { didSet { if columns != oldValue { needsLayout = true } } }

    init(row: CleanupRow) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The page keeps the keyboard focus: space toggles the focused row there.
        checkbox.refusesFirstResponder = true
        checkboxHolder = checkbox.onPress { [weak self] in self?.onToggle?() }
        for view: NSView in [checkbox, title, why, sub, badge, aiGlyph, aiText] { addSubview(view) }
        // The row is one element with the combined label; only its checkbox and buttons stay
        // separate (the texts would be read twice).
        for view: NSView in [title, why, sub, badge, aiText] { view.setAccessibilityElement(false) }
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
        apply(row, force: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    // MARK: Model

    func apply(_ row: CleanupRow, force: Bool = false) {
        guard force || row != self.row else { return }
        let old = self.row
        self.row = row
        title.set(row.title, style: CleanupStyles.rowTitle)
        checkbox.setAccessibilityLabel("選取「\(row.title)」")
        setAccessibilityLabel(Self.accessibilityText(row))
        if force || row.chips != old.chips { rebuildSecondLine() }
        why.set(row.why, style: CleanupStyles.why)
        badge.set(row.badge, style: CleanupStyles.statusChip(row.badgeTone))
        aiGlyph.hint = row.aiHint
        if force || row.actions != old.actions { rebuildActions() }
        restyle()
        needsLayout = true
    }

    /// The row as VoiceOver reads it (D21): item, kind and project, why (age), status, the AI hint,
    /// in the columns' order, so one element tells what the row suggests.
    static func accessibilityText(_ row: CleanupRow) -> String {
        var parts = [row.title]
        parts += row.chips.map(\.text)
        parts.append(row.sub.isEmpty ? row.why : "\(row.why) \(row.sub)")
        if !row.badge.isEmpty { parts.append(row.badge) }
        switch row.aiHint {
        case .none: break
        case .keep(let text), .read(let text): parts.append(text)
        case .condense(let text): parts.append(AIGlyphView.condenseText(text))
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "，")
    }

    private func rebuildSecondLine() {
        secondLine.forEach { $0.removeFromSuperview() }
        secondLine = []
        for chip in row.chips {
            switch chip.style {
            case .chip:
                secondLine.append(ChipBox(chip.text, style: CleanupStyles.smallChip(chip.tone, dashed: chip.dashed)))
            case .project:
                secondLine.append(TagSquareView(color: chip.tagColor))
                secondLine.append(TextLine(chip.text, style: CleanupStyles.rowSecond))
            case .faint:
                secondLine.append(TextLine(chip.text, style: TextStyle.mono(10.5, Palette.dimmer)))
            }
        }
        // Right after the title, so the reading order follows the row (title, chips, why, …).
        var previous: NSView = title
        for view in secondLine {
            view.setAccessibilityElement(false)
            addSubview(view, positioned: .above, relativeTo: previous)
            previous = view
        }
    }

    private func rebuildActions() {
        actionButtons.forEach { $0.removeFromSuperview() }
        actionButtons = []
        actionHolders = []
        for title in row.actions {
            let button = CoddButton(title, style: .bracket(.normal, small: true))
            button.setAccessibilityLabel("\(title)「\(row.title)」")
            actionHolders.append(button.onPress { [weak self] in self?.onAction?(title) })
            actionButtons.append(button)
            addSubview(button)
        }
    }

    /// The why sub-line and the AI hint follow the selection / hover (`.sub` turns --dim).
    private func restyle() {
        sub.set(row.sub, style: CleanupStyles.whySub(highlighted: isSelected || isHovered))
        switch row.aiHint {
        case .none: aiText.set("", style: CleanupStyles.ai(Palette.dim))
        case .keep(let text): aiText.set(text, style: CleanupStyles.ai(Palette.cyan))
        case .condense(let text): aiText.set(AIGlyphView.condenseText(text), style: CleanupStyles.ai(Palette.amberDim))
        case .read(let text): aiText.set(text, style: CleanupStyles.ai(Palette.dim))
        }
        needsDisplay = true
    }

    // MARK: Layout

    /// The row height at `columns`: the tallest cell + 13.
    static func height(for row: CleanupRow, columns: TableColumns) -> CGFloat {
        let whyWidth = columns.content(2).width
        var why = TextMeasure.height(CleanupStyles.why.string(row.why, lineHeight: CleanupStyles.whyLineHeight), width: whyWidth,
                                     lineHeight: CleanupStyles.whyLineHeight)
        if !row.sub.isEmpty {
            why += kz(2) + TextMeasure.height(CleanupStyles.whySub(highlighted: false).string(row.sub, lineHeight: CleanupStyles.subLineHeight),
                                          width: whyWidth, lineHeight: CleanupStyles.subLineHeight)
        }
        let aiWidth = columns.content(4).width - AIGlyphView.width - kz(6)
        let ai: CGFloat
        switch columns.showsAI ? row.aiHint : .none {
        case .none: ai = TextMeasure.zoomed(CleanupStyles.aiLineHeight)
        case .keep(let text), .read(let text):
            ai = TextMeasure.height(CleanupStyles.ai(Palette.dim).string(text, lineHeight: CleanupStyles.aiLineHeight), width: aiWidth,
                                    lineHeight: CleanupStyles.aiLineHeight)
        case .condense(let text):
            ai = TextMeasure.height(CleanupStyles.ai(Palette.dim).string(AIGlyphView.condenseText(text), lineHeight: CleanupStyles.aiLineHeight),
                                    width: aiWidth, lineHeight: CleanupStyles.aiLineHeight)
        }
        return (max(TextMeasure.zoomed(itemHeight), why, kz(20), ai, kz(22)) + kz(verticalChrome)).rounded()
    }

    override func layout() {
        super.layout()
        let contentHeight = bounds.height - kz(Self.verticalChrome)
        /// The top of a cell content of `height`, centered in the row (`vertical-align: middle`).
        func top(_ height: CGFloat) -> CGFloat { (kz(6) + (contentHeight - height) / 2).rounded() }

        checkbox.frame = CGRect(x: kz(14), y: top(kz(14)), width: kz(14), height: kz(14))

        let item = columns.content(1)
        let itemTop = top(TextMeasure.zoomed(Self.itemHeight))
        let titleHeight = TextMeasure.zoomed(12.5 * 1.5)
        title.frame = CGRect(x: item.x, y: itemTop, width: item.width, height: titleHeight)
        var x = item.x
        let lineY = itemTop + titleHeight + kz(4)
        for (index, view) in secondLine.enumerated() {
            let size: CGSize
            if view is TagSquareView {
                size = CGSize(width: kz(8), height: kz(8))
            } else if let text = view as? TextLine {
                size = CGSize(width: min(text.textWidth, max(0, item.x + item.width - x)), height: kz(15.75))
            } else {
                size = view.intrinsicContentSize
            }
            view.frame = CGRect(x: x, y: lineY + ((kz(17) - size.height) / 2).rounded(), width: size.width, height: size.height)
            x += size.width + (index == secondLine.count - 1 ? 0 : kz(6))
        }

        let whyCell = columns.content(2)
        let whyHeight = why.height(forWidth: whyCell.width)
        let subHeight = row.sub.isEmpty ? 0 : sub.height(forWidth: whyCell.width)
        let whyTotal = whyHeight + (row.sub.isEmpty ? 0 : kz(2) + subHeight)
        let whyTop = top(whyTotal)
        why.frame = CGRect(x: whyCell.x, y: whyTop, width: whyCell.width, height: whyHeight)
        sub.isHidden = row.sub.isEmpty
        sub.frame = CGRect(x: whyCell.x, y: whyTop + whyHeight + kz(2), width: whyCell.width, height: subHeight)

        let status = columns.content(3)
        let badgeSize = badge.intrinsicContentSize
        badge.frame = CGRect(x: status.x, y: top(kz(20)), width: min(badgeSize.width, status.width), height: kz(20))

        let ai = columns.content(4)
        let aiTextWidth = max(0, ai.width - AIGlyphView.width - kz(6))
        aiGlyph.isHidden = !columns.showsAI
        aiText.isHidden = !columns.showsAI
        let aiLine = TextMeasure.zoomed(CleanupStyles.aiLineHeight)
        let aiHeight = row.aiHint == .none ? aiLine : aiText.height(forWidth: aiTextWidth)
        let aiTop = top(aiHeight)
        aiGlyph.frame = CGRect(x: ai.x, y: aiTop, width: AIGlyphView.width, height: aiLine)
        aiText.frame = CGRect(x: ai.x + AIGlyphView.width + kz(6), y: aiTop, width: aiTextWidth, height: aiHeight)

        let actions = columns.content(5)
        var right = actions.x + actions.width
        for button in actionButtons.reversed() {
            let width = button.intrinsicContentSize.width
            button.frame = CGRect(x: right - width, y: top(22), width: width, height: kz(22))
            right -= width + kz(6)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            Draw.fill(bounds, Palette.bgLift)
        } else if isSelected {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.05))
        }
        if isSelected { Draw.fill(CGRect(x: 0, y: 0, width: kz(2), height: bounds.height - 1), Palette.amber) }
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.lineBright)
        if isFocused { Draw.strokeRect(CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1), color: Palette.amberDim) }
    }

    // MARK: Input

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click on the row (outside its buttons and the checkbox) toggles it, like a `<label>`.
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ value: Bool) {
        guard value != isHovered else { return }
        isHovered = value
        restyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
    }

    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    /// Row texts in reading order (tests).
    var texts: [String] { cleanupVisibleTexts() }
}

/// The AI column's leading glyph (`.nb-cl-ai svg` / `.g`): the eye (cyan for keep, --dim for read),
/// `✻` (--amber-dim) for condense, `—` (--dim) for none. 13 px wide.
final class AIGlyphView: NSView, CleanupTextShowing {
    static var width: CGFloat { kz(13) }

    var hint: CleanupAIHint = .none { didSet { if hint != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// `—` for none (the only text this glyph shows; the eye and `✻` are decoration).
    var displayedText: String {
        if case .none = hint { return "—" }
        if case .condense = hint { return "✻" }
        return ""
    }

    /// The condense text without a leading `✻ ` (the glyph is drawn separately).
    static func condenseText(_ text: String) -> String {
        var value = text
        if value.hasPrefix("✻") { value.removeFirst() }
        return value.trimmingCharacters(in: .whitespaces)
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.minY + TextMeasure.zoomed(CleanupStyles.aiLineHeight) / 2
        switch hint {
        case .none:
            let dash = TextStyle.mono(11.5, Palette.dim).string("—")
            Draw.text(dash, x: (bounds.width - Draw.width(dash)) / 2, centerY: mid)
        case .condense:
            let star = TextStyle.mono(11.5, Palette.amberDim).string("✻")
            Draw.text(star, x: (bounds.width - Draw.width(star)) / 2, centerY: mid)
        case .keep:
            // `svg{margin-top:2px}`.
            Glyphs.eye(in: CGRect(x: 0, y: kz(2), width: kz(13), height: kz(13)), color: Palette.cyan)
        case .read:
            Glyphs.eye(in: CGRect(x: 0, y: kz(2), width: kz(13), height: kz(13)), color: Palette.dim)
        }
    }
}
