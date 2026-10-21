import AppKit
import CoddUI

/// One tab of `.nb-cl-review .tabs`: `NOTES_ 8` (`.tab.on`: --bg, a 2 px amber top line, amber label
/// with the static `_` cursor, amber count) or `SESSIONS 5` (--dim, cream on hover).
final class CleanupTabButton: KeyFocusView, CleanupTextShowing {
    let tab: CleanupTab
    var count = 0 { didSet { if count != oldValue { refresh() } } }
    var isOn = false { didSet { if isOn != oldValue { refresh() } } }
    var onClick: (() -> Void)?
    /// ← → while the tab has the keyboard focus (the strip moves to the neighbouring tab).
    var onStep: ((Int) -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(tab: CleanupTab) {
        self.tab = tab
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private func labelStyle(_ color: NSColor) -> TextStyle { TextStyle.caps(10.5, color, tracking: 0.12) }
    private var countStyle: TextStyle { TextStyle.mono(10.5, isOn ? Palette.amber : Palette.dim) }
    private var labelText: String { isOn ? tab.title + "_" : tab.title }

    var displayedText: String { "\(labelText.uppercased()) \(count)" }

    /// `padding: 0 14px` · label (+ `_`) · gap 7 · count · `border-right: 1px`.
    var preferredWidth: CGFloat {
        ceil(14 + Draw.width(labelStyle(Palette.dim).string(labelText)) + (isOn ? 2 : 0) + 7 + Draw.width(countStyle.string("\(count)")) + 14 + 1)
    }

    private func refresh() {
        setAccessibilityLabel("\(tab.title.uppercased()) \(count)")
        setAccessibilityValue(isOn ? 1 : 0)
        setAccessibilitySelected(isOn)
        needsDisplay = true
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        if let step = Self.arrowStep(event), event.keyCode == 123 || event.keyCode == 124 {
            onStep?(step)
            return true
        }
        return super.handleKey(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn {
            Draw.fill(bounds, Palette.bg)
            Draw.fill(CGRect(x: 0, y: 0, width: bounds.width, height: kz(2)), Palette.amber)
        }
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        let color = isOn ? Palette.amber : (isHovered ? Palette.cream : Palette.dim)
        var x: CGFloat = kz(14)
        x += Draw.text(labelStyle(color).string(tab.title), x: x, centerY: bounds.midY)
        if isOn { x += kz(2) + Draw.text(labelStyle(color).string("_"), x: x + kz(2), centerY: bounds.midY) }
        Draw.text(countStyle.string("\(count)"), x: x + kz(7), centerY: bounds.midY)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
}

/// `.tabs` (30 px, --bg-soft, 1 px --line-bright bottom): the three tabs and the key hints
/// `space 勾選 ⌘A 全選 ⌫ 封存` right-aligned (`.tfill`: gap 10, `padding: 0 10px`, 10.5 --dimmer).
final class TabStripView: NSView {
    static var height: CGFloat { kz(30) }
    static let hints: [(key: String, text: String)] = [("space", "勾選"), ("⌘A", "全選"), ("⌫", "封存")]

    let tabs = CleanupTab.allCases.map { CleanupTabButton(tab: $0) }
    private var hintViews: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        tabs.forEach { addSubview($0) }
        for (index, tab) in tabs.enumerated() {
            tab.onStep = { [weak self] step in self?.step(from: index, by: step) }
        }
        for hint in Self.hints {
            let key = ChipBox(hint.key, style: CleanupStyles.hintKbd)
            let text = TextLine(hint.text, style: TextStyle.mono(10.5, Palette.dimmer))
            hintViews += [key, text]
        }
        hintViews.forEach { addSubview($0) }
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("候選類別")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func tab(_ tab: CleanupTab) -> CleanupTabButton { tabs[CleanupTab.allCases.firstIndex(of: tab) ?? 0] }

    /// ← → on a focused tab: clicks the neighbouring tab (the app switches the list) and moves the
    /// keyboard focus with it.
    private func step(from index: Int, by delta: Int) {
        guard tabs.indices.contains(index + delta) else { return }
        let next = tabs[index + delta]
        next.onClick?()
        window?.makeFirstResponder(next)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), Palette.lineBright)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for tab in tabs {
            let width = tab.preferredWidth
            tab.frame = CGRect(x: x, y: 0, width: width, height: bounds.height - 1)
            x += width
        }
        // Right-aligned hints; hidden when they would run into the tabs.
        var right = bounds.width - kz(10)
        var frames: [CGRect] = []
        for view in hintViews.reversed() {
            let size: CGSize = (view as? TextLine).map { CGSize(width: $0.textWidth, height: kz(16)) } ?? view.intrinsicContentSize
            frames.insert(CGRect(x: right - size.width, y: ((bounds.height - 1 - size.height) / 2).rounded(), width: size.width, height: size.height), at: 0)
            right -= size.width + kz(10)
        }
        let fits = right + 10 >= x + 10
        for (view, frame) in zip(hintViews, frames) {
            view.frame = frame
            view.isHidden = !fits
        }
    }
}

/// `thead` (30 px, --bg, 1 px --line-bright bottom): the select-all checkbox, `ITEM 項目`,
/// `WHY 原因`, `STATUS`, `AI` and `已選 n / m` right-aligned.
final class TableHeaderView: NSView {
    static var height: CGFloat { kz(30) }

    let checkbox = CheckboxButton(title: "", style: .plain)
    private let titles: [TextLine] = (0..<4).map { _ in TextLine(style: CleanupStyles.columnTitle) }
    let countLabel = TextLine(style: CleanupStyles.columnTitle)
    var columns = TableColumns(width: 926) { didSet { if columns != oldValue { needsLayout = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        checkbox.refusesFirstResponder = true
        addSubview(checkbox)
        let labels: [(String, String?)] = [("Item", "項目"), ("Why", "原因"), ("Status", nil), ("AI", nil)]
        for (line, label) in zip(titles, labels) {
            let title = NSMutableAttributedString(attributedString: CleanupStyles.columnTitle.string(label.0))
            if let cjk = label.1 {
                // `.cjk{margin-left:4px}` after the caps' own .16em.
                title.addAttribute(.kern, value: UIZoom.scaled(0.16 * 10 + 4), range: NSRange(location: title.length - 1, length: 1))
                title.append(CleanupStyles.columnCJK.string(cjk))
            }
            line.set(attributed: title)
            addSubview(line)
        }
        countLabel.alignRight = true
        addSubview(countLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func set(selected: Int, total: Int) {
        countLabel.set("已選 \(selected) / \(total)", style: CleanupStyles.columnTitle)
        checkbox.isOn = total > 0 && selected == total
        checkbox.setAccessibilityLabel("全選 \(total) 個項目")
        checkbox.isEnabled = total > 0
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), Palette.lineBright)
    }

    override func layout() {
        super.layout()
        let mid = (bounds.height - 1) / 2
        checkbox.frame = CGRect(x: kz(14), y: (mid - kz(7)).rounded(), width: kz(14), height: kz(14))
        for (index, line) in titles.enumerated() {
            let cell = columns.content(index + 1)
            line.isHidden = cell.width == 0
            line.frame = CGRect(x: cell.x, y: (mid - kz(8)).rounded(), width: cell.width, height: kz(16))
        }
        let last = columns.content(5)
        countLabel.frame = CGRect(x: last.x, y: (mid - kz(8)).rounded(), width: last.width, height: kz(16))
    }
}

/// `.nb-cl-bulk` (sticky, 47 px): `已選 n` (fill chip) `[封存]` `[移到垃圾桶]` (danger)
/// `[✻ 交給 Claude 濃縮…]` (accent) … `封存可隨時還原 · 垃圾桶 30 天後清除` `✕`. An amber wash over
/// --bg-soft with a 1 px --amber-dim top line.
final class BulkBarView: NSView {
    static var height: CGFloat { kz(47) }
    static let hintText = "封存可隨時還原 · 垃圾桶 30 天後清除"

    let countChip = ChipBox("", style: ChipStyle.chip(.fill, height: 22))
    private(set) var buttons: [String: CoddButton] = [:]
    private var holders: [ButtonAction] = []
    let hint = TextLine(BulkBarView.hintText, style: TextStyle.hint)
    let closeButton = CoddButton("✕", style: .glyph(size: 28))
    private var closeHolder: ButtonAction?
    var onAction: ((String) -> Void)?
    var onClear: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(countChip)
        for action in CleanupBulkAction.all {
            let variant: CoddButton.Variant = action == CleanupBulkAction.trash ? .danger : (action == CleanupBulkAction.condense ? .accent : .normal)
            let label = action == CleanupBulkAction.condense ? "✻ " + action : action
            let button = CoddButton(label, style: .bracket(variant, small: true))
            button.setAccessibilityLabel(action)
            holders.append(button.onPress { [weak self] in self?.onAction?(action) })
            buttons[action] = button
            addSubview(button)
        }
        addSubview(hint)
        closeButton.setAccessibilityLabel("取消選取")
        closeHolder = closeButton.onPress { [weak self] in self?.onClear?() }
        addSubview(closeButton)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("批次動作")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(count: Int, disabled: Set<String>) {
        countChip.set("已選 \(count)", style: ChipStyle.chip(.fill, height: 22))
        for (action, button) in buttons { button.isEnabled = !disabled.contains(action) }
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.hGradient(bounds, from: Palette.amber.withAlphaComponent(0.10), to: Palette.amber.withAlphaComponent(0.02))
        Draw.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1), Palette.amberDim)
    }

    override func layout() {
        super.layout()
        // `padding: 9px 10px 9px 14px` below the 1 px top border; items centered, gap 8.
        let mid = 1 + kz(9) + kz(14)
        var x: CGFloat = kz(14)
        let chip = countChip.intrinsicContentSize
        countChip.frame = CGRect(x: x, y: CGFloat(mid) - kz(11), width: chip.width, height: kz(22))
        x += chip.width + kz(8)
        for action in CleanupBulkAction.all {
            guard let button = buttons[action] else { continue }
            let width = button.intrinsicContentSize.width
            button.frame = CGRect(x: x, y: CGFloat(mid) - kz(11), width: width, height: kz(22))
            x += width + kz(8)
        }
        let closeX = bounds.width - kz(10) - kz(28)
        closeButton.frame = CGRect(x: closeX, y: CGFloat(mid) - kz(14), width: kz(28), height: kz(28))
        let hintWidth = min(hint.textWidth, max(0, closeX - kz(8) - x))
        hint.frame = CGRect(x: closeX - kz(8) - hintWidth, y: CGFloat(mid) - kz(9), width: hintWidth, height: kz(18))
        hint.isHidden = hintWidth < 40
    }
}

/// `.panel.nb-cl-review`: the tab strip, the table (header + rows or the empty state) and the
/// bulk bar while something is selected. The panel can be taller than its rows (the grid row
/// stretches it to the CONDENSE card); the bar then sits at the panel's bottom, or, when the
/// panel runs below the visible area, at the visible bottom (`position: sticky; bottom: 0`).
final class ReviewPanelView: NSView {
    let tabStrip = TabStripView()
    let header = TableHeaderView()
    let rowsView = FlippedView()
    let emptyLabel = TextLine(style: TextStyle.comment)
    let bulkBar = BulkBarView()
    private(set) var rowViews: [String: CleanupRowView] = [:]
    private(set) var order: [String] = []
    private var heights: [String: CGFloat] = [:]
    private var heightColumns: TableColumns?
    /// The visible area's bottom in this view's coordinates (nil: everything is visible).
    var visibleBottom: CGFloat? { didSet { if visibleBottom != oldValue { needsLayout = true } } }
    var showsBulkBar = false { didSet { if showsBulkBar != oldValue { needsLayout = true } } }

    var onToggle: ((String) -> Void)?
    var onClick: ((String) -> Void)?
    var onRowAction: ((String, String) -> Void)?

    static var emptyHeight: CGFloat { kz(64) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view: NSView in [tabStrip, header, rowsView, emptyLabel, bulkBar] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("清理候選項目")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// STATUS: the widest badge + the cell padding.
    private(set) var statusWidth: CGFloat = kz(128)

    var columns: TableColumns { TableColumns(width: max(0, bounds.width - 2), status: statusWidth) }

    /// Rows in model order.
    var orderedRows: [CleanupRowView] { order.compactMap { rowViews[$0] } }

    func setRows(_ rows: [CleanupRow], emptyText: String) {
        var next: [String: CleanupRowView] = [:]
        for row in rows {
            let view: CleanupRowView
            if let existing = rowViews[row.id] {
                view = existing
                if view.row != row { heights[row.id] = nil }
                view.apply(row)
            } else {
                view = CleanupRowView(row: row)
                let id = row.id
                view.onToggle = { [weak self] in self?.onToggle?(id) }
                view.onClick = { [weak self] in self?.onClick?(id) }
                view.onAction = { [weak self] title in self?.onRowAction?(id, title) }
                rowsView.addSubview(view)
            }
            next[row.id] = view
        }
        for (id, view) in rowViews where next[id] == nil {
            view.removeFromSuperview()
            heights[id] = nil
        }
        rowViews = next
        order = rows.map(\.id)
        statusWidth = max(kz(128), (rows.map { CleanupStyles.statusChip($0.badgeTone).size(for: $0.badge).width }.max() ?? 0) + 16)
        emptyLabel.set(emptyText, style: TextStyle.comment)
        emptyLabel.isHidden = !rows.isEmpty
        needsLayout = true
    }

    /// The height of each row at the current width (cached per row value).
    func rowHeight(_ id: String) -> CGFloat {
        let columns = columns
        if heightColumns != columns {
            heights = [:]
            heightColumns = columns
        }
        if let cached = heights[id] { return cached }
        guard let row = rowViews[id]?.row else { return 0 }
        let height = CleanupRowView.height(for: row, columns: columns)
        heights[id] = height
        return height
    }

    /// The panel height its content needs at `width` (1 px border top and bottom).
    func naturalHeight(width: CGFloat) -> CGFloat {
        let columns = TableColumns(width: max(0, width - kz(2)), status: statusWidth)
        let rows = order.isEmpty ? Self.emptyHeight
            : order.reduce(CGFloat(0)) { sum, id in sum + (rowViews[id].map { CleanupRowView.height(for: $0.row, columns: columns) } ?? 0) }
        return 1 + TabStripView.height + TableHeaderView.height + rows + (showsBulkBar ? BulkBarView.height : 0) + 1
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }

    override func layout() {
        super.layout()
        let inner = CGRect(x: 1, y: 1, width: max(0, bounds.width - kz(2)), height: max(0, bounds.height - kz(2)))
        let columns = columns
        tabStrip.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: TabStripView.height)
        header.columns = columns
        header.frame = CGRect(x: inner.minX, y: tabStrip.frame.maxY, width: inner.width, height: TableHeaderView.height)
        let rowsTop = header.frame.maxY
        var y: CGFloat = 0
        for id in order {
            guard let view = rowViews[id] else { continue }
            let height = rowHeight(id)
            view.columns = columns
            view.frame = CGRect(x: 0, y: y, width: inner.width, height: height)
            y += height
        }
        let barSpace = showsBulkBar ? BulkBarView.height : 0
        rowsView.frame = CGRect(x: inner.minX, y: rowsTop, width: inner.width, height: max(y, inner.maxY - rowsTop - barSpace))
        emptyLabel.frame = CGRect(x: inner.minX + kz(14), y: rowsTop + (Self.emptyHeight - kz(18)) / 2, width: inner.width - kz(28), height: kz(18))
        bulkBar.isHidden = !showsBulkBar
        if showsBulkBar {
            var barY = inner.maxY - BulkBarView.height
            if let visibleBottom { barY = min(barY, visibleBottom - BulkBarView.height) }
            barY = max(barY, rowsTop)
            bulkBar.frame = CGRect(x: inner.minX, y: barY.rounded(), width: inner.width, height: BulkBarView.height)
        }
    }
}
