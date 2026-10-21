import AppKit
import CoddCore
import CoddUI

/// `.ns-cbox`: the 46 pt project box of the ⌘N sheet: the group's tag square, the name field
/// (typing filters the list below), the short path under it and the amber `▾`. Amber border with
/// its glow while it has focus or its list is open (NewSession artboard).
final class ProjectComboBox: FieldBoxView, NSTextFieldDelegate {
    let field = NSTextField()
    private let square = ColorSquareView(color: nil)
    private let pathLabel = Label.make(style: TextStyle.mono(10.5, Palette.dim))
    private let caret = CoddButton("▾", style: .glyph(size: 22))
    var onTextChange: ((String) -> Void)?
    /// The field editor's commands (↑ ↓ ⏎ esc), after the input method; true = handled.
    var onCommand: ((Selector) -> Bool)?
    var onToggle: (() -> Void)?
    /// The list is open (the box keeps its focused look).
    var isOpen = false { didSet { updateFocus() } }
    private var hasFocus = false

    static let height: CGFloat = 46

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(12.5)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(12.5, Palette.dimmer).string("輸入名稱或路徑")
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityRole(.comboBox)
        field.setAccessibilityLabel("專案")
        pathLabel.lineBreakMode = .byTruncatingHead
        caret.target = self
        caret.action = #selector(toggle)
        caret.setAccessibilityLabel("專案清單")
        let text = vStack([field, pathLabel], spacing: 2, alignment: .width)
        let row = hStack([square, text, caret], spacing: 9, edgeInsets: NSEdgeInsets(top: 0, left: 11, bottom: 0, right: 4))
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(row)
        row.pinEdges(to: self)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).zoomed(Self.height).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    /// The chosen folder: its group square (dashed when none), the short path line.
    func showChoice(tag: TagColor?, known: Bool, path: String) {
        square.color = tag?.color
        square.isHidden = !known && path.isEmpty
        Label.set(pathLabel, path.isEmpty ? "還沒有選資料夾" : ProjectDropdownModel.shortPath(path),
                  style: TextStyle.mono(10.5, path.isEmpty ? Palette.dimmer : Palette.dim))
        field.setAccessibilityValue(field.stringValue + (path.isEmpty ? "" : "，\(path)"))
    }

    func focus() { window?.makeFirstResponder(field) }

    @objc private func toggle() { onToggle?() }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        // While 注音 composes, the marked text is not the filter yet.
        if isComposing { return }
        onTextChange?(field.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        onCommand?(selector) ?? false
    }

    /// Only the window observation is dropped: a blanket `removeObserver(self)` also drops the
    /// NSControl delegate registration behind `controlTextDidChange` (typing stopped filtering once
    /// the box was in the sheet; fixed in M3 I1a with CoddUI's InputField).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated), name: NSWindow.didUpdateNotification, object: window)
    }

    @objc private func windowUpdated() {
        let focused = (window?.firstResponder as? NSTextView).map { $0.delegate === field } ?? false
        guard focused != hasFocus else { return }
        hasFocus = focused
        if focused { (window?.firstResponder as? NSTextView)?.insertionPointColor = Palette.amber }
        updateFocus()
    }

    private func updateFocus() { isFocused = hasFocus || isOpen }
}

/// The open project list, a borderless child window of the sheet (it closes with it). It never
/// becomes key: the keyboard stays in the combobox field. It still claims ⌘⏎ (and esc) itself so
/// the main menu's 允許 never sees a ⌘⏎ sent to it.
final class ProjectDropdownPanel: NSPanel {
    let list = ProjectDropdownListView()
    private let scroll = NSScrollView()
    var onCommandReturn: (() -> Void)?
    var onCancel: (() -> Void)?

    static let maxHeight: CGFloat = 300

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 348, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.transient, .ignoresCycle]
        let root = PanelView(fill: Palette.bgLift, edges: [.top, .bottom, .left, .right], edgeColor: Palette.amberDim)
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        // The dashed separator and `+ 選擇資料夾… ⌘O` stay under the rows however many there are
        // (review spec-fidelity-1): only the rows scroll.
        let footer = list.footer
        for view in [scroll, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 1),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -1),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 1),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -1),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -1),
            footer.heightAnchor.constraint(equalToConstant: ProjectDropdownListView.footerHeight).zoomed(ProjectDropdownListView.footerHeight),
        ])
        contentView = root
        setAccessibilityLabel("專案清單")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        if event.keyCode == 0x24 || event.keyCode == 0x4C, modifiers == .command {
            onCommandReturn?()
            return true
        }
        if event.keyCode == 0x35, modifiers.isEmpty {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Under the box (`gap: 3px`), as wide as it; as tall as the list and its footer, at most
    /// 300 pt; above the box when the screen has no room below it.
    func place(under box: CGRect, screen: CGRect?) {
        let height = min(Self.maxHeight, list.contentHeight + ProjectDropdownListView.footerHeight + 2)
        var origin = CGPoint(x: box.minX, y: box.minY - 3 - height)
        if let screen, origin.y < screen.minY + 4 { origin.y = box.maxY + 3 }
        setFrame(CGRect(origin: origin, size: CGSize(width: box.width, height: height)), display: true)
        list.setFrameSize(NSSize(width: box.width - 2, height: list.contentHeight))
    }

    func scrollToHighlighted() {
        guard let rect = list.highlightedFrame else { return }
        list.scrollToVisible(rect.insetBy(dx: 0, dy: -4))
    }
}

/// `.menu.ns-list`, drawn in one view: `.mh` heads (`最近 Recent` `5`, `建議 · 來自 ~/.claude.json`
/// `未加入`), 26 pt `.mi` rows (tag square, name with matched characters in amber, `2 live` / the
/// parent folder, ✓ or `+ 加入`). Its `footer` (another instance, outside the scroll view) draws
/// the dashed separator and `+ 選擇資料夾…` `⌘O`; the list passes its model, highlight and
/// callbacks on.
final class ProjectDropdownListView: FlippedView {
    enum Part { case rows, footer }

    let part: Part
    private(set) var model = ProjectDropdownModel()
    private(set) var highlighted = 0
    private var layoutRows: [(frame: CGRect, index: Int)] = []
    private var heads: [(y: CGFloat, title: String, plain: String, note: String)] = []
    private var separatorY: CGFloat?
    private var trackingArea: NSTrackingArea?
    private var lastMouse: NSPoint?
    var onHover: ((Int) -> Void)?
    var onPick: ((Int) -> Void)?
    var onAdd: ((Int) -> Void)?
    /// The pinned `+ 選擇資料夾…` part (nil for the footer itself).
    private(set) lazy var footer: ProjectDropdownListView = {
        let footer = ProjectDropdownListView(part: .footer)
        footer.onHover = { [weak self] index in self?.onHover?(index) }
        footer.onPick = { [weak self] index in self?.onPick?(index) }
        return footer
    }()

    static let padding: CGFloat = 4
    static let rowHeight: CGFloat = 26
    static let headHeight: CGFloat = 22
    static let separatorHeight: CGFloat = 9
    /// The footer: separator, the `+ 選擇資料夾…` row, the bottom padding.
    static let footerHeight: CGFloat = separatorHeight + rowHeight + padding
    static let addLabel = "+ 加入"

    /// The rows' height (the footer's for the footer part).
    private(set) var contentHeight: CGFloat = 0

    init(part: Part = .rows) {
        self.part = part
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ model: ProjectDropdownModel, highlighted: Int) {
        self.model = model
        self.highlighted = min(max(0, highlighted), model.rows.count - 1)
        if part == .rows { footer.show(model, highlighted: highlighted) }
        var y = Self.padding
        var rows: [(CGRect, Int)] = []
        heads = []
        separatorY = nil
        var index = 0
        switch part {
        case .rows:
            if !model.recent.isEmpty {
                heads.append((y, "最近 Recent", "", "\(model.recent.count)"))
                y += Self.headHeight
                for _ in model.recent { rows.append((CGRect(x: Self.padding, y: y, width: 0, height: Self.rowHeight), index)); y += Self.rowHeight; index += 1 }
            }
            if !model.suggested.isEmpty {
                // `.ns-nt`: the path keeps its case (only the label is caps).
                heads.append((y, "建議 · 來自 ", "~/.claude.json", "未加入"))
                y += Self.headHeight
                for _ in model.suggested { rows.append((CGRect(x: Self.padding, y: y, width: 0, height: Self.rowHeight), index)); y += Self.rowHeight; index += 1 }
            }
            if model.recent.isEmpty && model.suggested.isEmpty {
                heads.append((y, "// 沒有符合的專案", "", ""))
                y += Self.headHeight + 4
            }
        case .footer:
            y = 0
            separatorY = 4
            y += Self.separatorHeight
            rows.append((CGRect(x: Self.padding, y: y, width: 0, height: Self.rowHeight), model.rows.count - 1))
            y += Self.rowHeight + Self.padding
        }
        layoutRows = rows
        contentHeight = y
        if part == .rows { setFrameSize(NSSize(width: max(frame.width, 1), height: y)) }
        updateAccessibility()
        needsDisplay = true
    }

    func setHighlighted(_ index: Int) {
        if part == .rows { footer.setHighlighted(index) }
        let clamped = min(max(0, index), model.rows.count - 1)
        guard clamped != highlighted else { return }
        highlighted = clamped
        updateAccessibility()
        needsDisplay = true
    }

    var highlightedFrame: CGRect? {
        layoutRows.first { $0.index == highlighted }.map { CGRect(x: 0, y: $0.frame.minY, width: bounds.width, height: $0.frame.height) }
    }

    private func updateAccessibility() {
        rowElements = drawnRowElements(reusing: rowElements)
        guard part == .rows else {
            // The pinned `+ 選擇資料夾…` row (M5 D21: a row element of its own).
            setAccessibilityRole(.list)
            setAccessibilityLabel("其他資料夾")
            return
        }
        setAccessibilityRole(.list)
        setAccessibilityLabel("專案清單，\(model.rows.count - 1) 個")
        let rows = model.rows
        let value = rows.indices.contains(highlighted) ? rows[highlighted].title : ""
        let changed = (accessibilityValue() as? String) != value
        setAccessibilityValue(value)
        // ↑ ↓ in the project field move the highlight; VoiceOver hears the new row.
        if changed { NSAccessibility.post(element: self, notification: .valueChanged) }
    }

    /// One VoiceOver element per row (M5 D21).
    private var rowElements: [DrawnRowElement] = []
    override func accessibilityChildren() -> [Any]? { rowElements }

    private func rowIndex(at point: NSPoint) -> Int? {
        layoutRows.first { point.y >= $0.frame.minY && point.y < $0.frame.maxY }?.index
    }

    /// The `+ 加入` button of a suggestion row.
    private func addFrame(in row: CGRect) -> CGRect {
        // `.ns-sug .btn{padding:1px 5px}`: `[`, 4, label, 4, `]` inside 5 pt of padding.
        let style = addText
        let width = ceil(Draw.width(style.string("[")) + 4 + Draw.width(style.string(Self.addLabel)) + 4 + Draw.width(style.string("]")) + 10)
        return CGRect(x: row.maxX - 10 - width, y: row.minY + 2, width: width, height: row.height - 4)
    }

    private var addText: TextStyle { TextStyle(font: Typeface.mono(10.5, .medium), color: Palette.cream, tracking: 0.08, uppercase: true) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer { lastMouse = point }
        guard let last = lastMouse, last != point, let index = rowIndex(at: point) else { return }
        onHover?(index)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = rowIndex(at: point), let entry = layoutRows.first(where: { $0.index == index }) else { return }
        let rows = model.rows
        let frame = CGRect(x: entry.frame.minX, y: entry.frame.minY, width: bounds.width - 2 * Self.padding, height: entry.frame.height)
        if rows[index].kind == .suggestion, addFrame(in: frame).insetBy(dx: -2, dy: -2).contains(point) {
            onAdd?(index)
        } else {
            onPick?(index)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let width = bounds.width - 2 * Self.padding
        for head in heads {
            let mid = head.y + 6 + 6
            let title = NSMutableAttributedString(attributedString: TextStyle.caps(9.5, Palette.dim, tracking: 0.2).string(head.title))
            if !head.plain.isEmpty { title.append(TextStyle.mono(9.5, Palette.dim, tracking: 0.04).string(head.plain)) }
            Draw.text(title, x: Self.padding + 10, centerY: mid)
            if !head.note.isEmpty {
                let note = TextStyle.mono(10, Palette.dimmer, tracking: 0.02).string(head.note)
                Draw.text(note, x: Self.padding + width - 10 - Draw.width(note), centerY: mid)
            }
        }
        if let separatorY {
            Draw.dashedLine(from: CGPoint(x: Self.padding + 2, y: separatorY), to: CGPoint(x: Self.padding + width - 2, y: separatorY),
                            color: Palette.lineBright)
        }
        let rows = model.rows
        for entry in layoutRows {
            let rect = CGRect(x: entry.frame.minX, y: entry.frame.minY, width: width, height: entry.frame.height)
            guard rect.intersects(dirtyRect), rows.indices.contains(entry.index) else { continue }
            draw(rows[entry.index], in: rect, highlighted: entry.index == highlighted)
        }
    }

    private func draw(_ row: ProjectDropdownModel.Row, in rect: CGRect, highlighted: Bool) {
        if highlighted {
            Draw.fill(rect, Palette.bgRaise)
            Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height), Palette.amber)
        }
        let mid = rect.midY
        var x = rect.minX + 10
        var right = rect.maxX - 10
        let nameColor = highlighted ? Palette.cream : Palette.bone
        switch row.kind {
        case .chooseFolder:
            let plus = TextStyle.mono(12, Palette.dim).string("+")
            Draw.text(plus, x: x + (14 - Draw.width(plus)) / 2, centerY: mid)
            x += 14 + 9
            let key = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04).string(row.detail)
            right -= Draw.width(key)
            Draw.text(key, x: right, centerY: mid)
            Draw.text(TextStyle.mono(12, nameColor).string(row.title), x: x, centerY: mid, maxWidth: max(0, right - 9 - x))
            return
        case .recent:
            let square = CGRect(x: x, y: round(mid - 4), width: 8, height: 8)
            if let tag = row.choice?.tag { Draw.fill(square, tag.color) } else { Draw.dashedRect(square, color: Palette.dimmer) }
            x += 8 + 9
            // ✓ cell (12 pt), then the `n live` count left of it.
            let check = TextStyle.mono(12, Palette.amber).string(row.isChosen ? "✓" : "")
            if row.isChosen { Draw.text(check, x: right - 12 + (12 - Draw.width(check)) / 2, centerY: mid) }
            right -= 12 + 9
            if !row.detail.isEmpty {
                let live = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04).string(row.detail)
                right -= Draw.width(live)
                Draw.text(live, x: right, centerY: mid)
                right -= 9
            }
            drawName(row, x: x, mid: mid, maxWidth: right - x, color: nameColor)
        case .suggestion:
            Draw.dashedRect(CGRect(x: x, y: round(mid - 4), width: 8, height: 8), color: Palette.dimmer)
            x += 8 + 9
            let button = addFrame(in: rect)
            CoddButton.drawSmallBracket(Self.addLabel, in: button)
            right = button.minX - 9
            let nameWidth = drawName(row, x: x, mid: mid, maxWidth: max(0, right - x - 40), color: nameColor)
            x += nameWidth + 9
            if right - x > 16 {
                Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(row.detail), x: x, centerY: mid, maxWidth: right - x)
            }
        }
    }

    @discardableResult
    private func drawName(_ row: ProjectDropdownModel.Row, x: CGFloat, mid: CGFloat, maxWidth: CGFloat, color: NSColor) -> CGFloat {
        let name = NSMutableAttributedString(attributedString: TextStyle.mono(12, color).string(row.title))
        for span in row.spans where span.location + span.length <= name.length {
            let range = NSRange(location: span.location, length: span.length)
            name.addAttribute(.foregroundColor, value: Palette.amber, range: range)
            name.addAttribute(.shadow, value: HomeHeaderView.glow(Palette.amberGlow, radius: 8), range: range)
        }
        return Draw.text(name, x: x, centerY: mid, maxWidth: max(0, maxWidth))
    }
}

// MARK: Accessibility (M5 D21)

extension ProjectDropdownListView: DrawnRowsHost {
    var drawnRowCount: Int { layoutRows.count }

    /// `orb-toolkit-backend，最近使用，2 live`, `選擇資料夾…，⌘O`.
    func drawnRowLabel(_ index: Int) -> String? {
        guard layoutRows.indices.contains(index) else { return nil }
        let rows = model.rows
        let modelIndex = layoutRows[index].index
        guard rows.indices.contains(modelIndex) else { return nil }
        let row = rows[modelIndex]
        let kind: String = switch row.kind {
        case .recent: "最近使用"
        case .suggestion: "建議，未加入"
        case .chooseFolder: ""
        }
        return [row.title, row.isChosen ? "已選" : "", kind, row.detail].filter { !$0.isEmpty }.joined(separator: "，")
    }

    func drawnRowFrame(_ index: Int) -> CGRect {
        guard layoutRows.indices.contains(index) else { return .zero }
        var rect = layoutRows[index].frame
        rect.size.width = bounds.width - Self.padding * 2
        return rect
    }

    func isDrawnRowSelected(_ index: Int) -> Bool { layoutRows.indices.contains(index) && layoutRows[index].index == highlighted }
    func pressDrawnRow(_ index: Int) {
        guard layoutRows.indices.contains(index) else { return }
        onPick?(layoutRows[index].index)
    }
}

/// The resume picker (`.ns-picker`): `Past transcripts` head with `<project> · n`, then up to
/// five 40 pt rows (`❯ title  size` / `⎇ branch · age` + the amber expiry or `執行中`) before it
/// scrolls. A click (or ↑↓ while it has focus) selects; running rows cannot be selected.
final class ResumePickerView: FlippedView {
    enum Content: Equatable {
        case noFolder, loading, empty
        case rows([ResumePickerRow])
    }

    private let head = ResumePickerHeadView()
    private let scroll = NSScrollView()
    private let list = ResumePickerListView()
    private(set) var content: Content = .loading
    var onSelect: ((ResumePickerRow) -> Void)?

    static let headHeight: CGFloat = 24
    static let messageHeight: CGFloat = 34

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        for view in [head, scroll] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        list.onSelect = { [weak self] row in self?.onSelect?(row) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("選擇要接續的對話")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var rows: [ResumePickerRow] { if case .rows(let rows) = content { rows } else { [] } }
    var selectedID: String? { list.selectedID }

    func show(_ content: Content, project: String, selected: String?) {
        self.content = content
        head.text = (title: "Past transcripts", note: ResumePicker.headText(project: project, count: rows.count))
        list.show(content, selected: selected)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    func select(_ id: String?) { list.select(id) }

    override var intrinsicContentSize: NSSize {
        let body: CGFloat
        switch content {
        case .rows(let rows) where !rows.isEmpty:
            body = CGFloat(min(rows.count, ResumePicker.visibleRows)) * ResumePickerListView.rowHeight
        default:
            body = Self.messageHeight
        }
        return NSSize(width: NSView.noIntrinsicMetric, height: Self.headHeight + body + 2)
    }

    override func layout() {
        super.layout()
        let b = bounds.insetBy(dx: 1, dy: 1)
        head.frame = CGRect(x: b.minX, y: b.minY, width: b.width, height: Self.headHeight)
        scroll.frame = CGRect(x: b.minX, y: b.minY + Self.headHeight, width: b.width, height: max(0, b.height - Self.headHeight))
        list.setFrameSize(NSSize(width: b.width, height: max(list.contentHeight, scroll.frame.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }

    /// Keeps the selected row in view (after a list arrives or ↑↓).
    func scrollToSelected() {
        guard let frame = list.selectedFrame else { return }
        list.scrollToVisible(frame)
    }

    /// ↑↓ from the sheet (the picker has no field of its own).
    func moveSelection(by step: Int) { list.moveSelection(by: step) }
}

/// `.ns-ph`: `PAST TRANSCRIPTS` caps on the left, `orb-toolkit-backend · 4` faint on the right,
/// dashed rule under it.
final class ResumePickerHeadView: FlippedView {
    var text: (title: String, note: String) = ("", "") { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        let titleWidth = Draw.text(TextStyle.caps(9.5, Palette.dim, tracking: 0.18).string(text.title), x: 10, centerY: mid)
        // A long project name gives way (truncated) to the head; the count always shows.
        let style = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02)
        let split = text.note.range(of: " · ", options: .backwards)
        let name = split.map { String(text.note[..<$0.lowerBound]) } ?? text.note
        let count = style.string(split.map { String(text.note[$0.lowerBound...]) } ?? "")
        var right = bounds.width - 10 - Draw.width(count)
        Draw.text(count, x: right, centerY: mid)
        let nameText = style.string(name)
        let width = min(Draw.width(nameText), max(0, right - (10 + titleWidth + 8)))
        right -= width
        Draw.text(nameText, x: right, centerY: mid, maxWidth: width)
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.lineBright)
    }
}

/// The picker's rows (`.ns-tr`), drawn in one view.
final class ResumePickerListView: FlippedView {
    private(set) var content: ResumePickerView.Content = .loading
    private(set) var selectedID: String?
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?
    var onSelect: ((ResumePickerRow) -> Void)?

    static let rowHeight: CGFloat = 40

    private var rows: [ResumePickerRow] { if case .rows(let rows) = content { rows } else { [] } }

    var contentHeight: CGFloat {
        rows.isEmpty ? ResumePickerView.messageHeight : CGFloat(rows.count) * Self.rowHeight
    }

    override var acceptsFirstResponder: Bool { !rows.isEmpty }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ content: ResumePickerView.Content, selected: String?) {
        self.content = content
        selectedID = selected
        hovered = nil
        setFrameSize(NSSize(width: max(frame.width, 1), height: contentHeight))
        updateAccessibility()
        needsDisplay = true
    }

    func select(_ id: String?) {
        guard id != selectedID else { return }
        selectedID = id
        updateAccessibility()
        needsDisplay = true
    }

    var selectedFrame: CGRect? {
        rows.firstIndex { $0.id == selectedID }.map { CGRect(x: 0, y: CGFloat($0) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }
    }

    func moveSelection(by step: Int) {
        let rows = self.rows
        guard !rows.isEmpty else { return }
        var index = rows.firstIndex { $0.id == selectedID } ?? (step > 0 ? -1 : rows.count)
        repeat {
            index += step
        } while rows.indices.contains(index) && rows[index].disabled
        guard rows.indices.contains(index) else { NSSound.beep(); return }
        onSelect?(rows[index])
        if let frame = selectedFrame { scrollToVisible(frame) }
    }

    private func updateAccessibility() {
        setAccessibilityRole(.list)
        setAccessibilityLabel("先前的對話，\(rows.count) 段")
        setAccessibilityValue(rows.first { $0.id == selectedID }?.title ?? "")
        rowElements = drawnRowElements(reusing: rowElements)
    }

    /// One VoiceOver element per conversation (M5 D21); ↑ ↓ move the selection while the list is focused.
    private var rowElements: [DrawnRowElement] = []
    override func accessibilityChildren() -> [Any]? { rowElements }

    /// ↑↓ move; other keys (the sheet's 1–8 colors, esc) go up the responder chain.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 0x7E, 0x7D: interpretKeyEvents([event])
        default: super.keyDown(with: event)
        }
    }
    override func moveUp(_ sender: Any?) { moveSelection(by: -1) }
    override func moveDown(_ sender: Any?) { moveSelection(by: 1) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let index = Int(convert(event.locationInWindow, from: nil).y / Self.rowHeight)
        let next = rows.indices.contains(index) && !rows[index].disabled ? index : nil
        if next != hovered { hovered = next; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        let index = Int(convert(event.locationInWindow, from: nil).y / Self.rowHeight)
        guard rows.indices.contains(index) else { return }
        guard !rows[index].disabled else { NSSound.beep(); return }
        window?.makeFirstResponder(self)
        onSelect?(rows[index])
    }

    override func draw(_ dirtyRect: NSRect) {
        switch content {
        case .noFolder: drawMessage(ResumePicker.noFolderText)
        case .loading: drawMessage(ResumePicker.loadingText)
        case .empty: drawMessage(ResumePicker.emptyText)
        case .rows(let rows):
            if rows.isEmpty { drawMessage(ResumePicker.emptyText); return }
            for (index, row) in rows.enumerated() {
                let rect = CGRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
                if rect.intersects(dirtyRect) { draw(row, in: rect, last: index == rows.count - 1, hovered: index == hovered) }
            }
        }
    }

    private func drawMessage(_ text: String) {
        Draw.text(TextStyle.mono(11.5, Palette.dimmer).string(text), x: 10, centerY: ResumePickerView.messageHeight / 2)
    }

    private func draw(_ row: ResumePickerRow, in rect: CGRect, last: Bool, hovered: Bool) {
        let on = row.id == selectedID && !row.disabled
        if on {
            Draw.fill(rect, Palette.bgRaise)
            Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height), Palette.amber)
        } else if hovered {
            Draw.fill(rect, Palette.bgSoft)
        }
        if !last {
            Draw.dashedLine(from: CGPoint(x: rect.minX, y: rect.maxY - 1), to: CGPoint(x: rect.maxX, y: rect.maxY - 1), color: Palette.line)
        }
        let line1 = rect.minY + 5 + 8
        let line2 = rect.minY + 5 + 16 + 1 + 7
        var x = rect.minX + 8
        if on { Draw.text(TextStyle.mono(12, Palette.amber).string("❯"), x: x, centerY: line1) }
        x += 10 + 7
        let size = TextStyle.mono(10.5, row.disabled ? Palette.dimmer : Palette.dim).string(row.sizeText)
        let sizeX = rect.maxX - 10 - Draw.width(size)
        Draw.text(size, x: sizeX, centerY: line1)
        let titleColor = row.disabled ? Palette.dimmer : (on ? Palette.cream : Palette.bone)
        Draw.text(TextStyle.mono(12, titleColor).string(row.title), x: x, centerY: line1, maxWidth: max(0, sizeX - 7 - x))
        var right = rect.maxX - 10
        if row.disabled {
            let running = TextStyle.mono(10.5, Palette.dim).string(ResumePicker.runningText)
            right -= Draw.width(running)
            Draw.text(running, x: right, centerY: line2)
            right -= 8
        } else if let expiry = row.expiryText {
            let text = TextStyle.mono(10.5, Palette.amber).string(expiry)
            right -= Draw.width(text)
            Draw.text(text, x: right, centerY: line2)
            right -= 8
        }
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(row.detailText), x: x, centerY: line2, maxWidth: max(0, right - x))
    }
}

extension ResumePickerListView: DrawnRowsHost {
    var drawnRowCount: Int { rows.count }

    /// `修正登入 API 401，⎇ fix/login-401，2d，12 KB`, `…，執行中` for one that cannot be picked.
    func drawnRowLabel(_ index: Int) -> String? {
        guard rows.indices.contains(index) else { return nil }
        let row = rows[index]
        var parts = [row.title, row.branch.map { "⎇ \($0)" } ?? "", row.ageText, row.sizeText]
        if let expiry = row.expiryText { parts.append(String(expiry.drop { $0 == "!" || $0 == " " })) }
        if row.disabled { parts.append("執行中") }
        return parts.filter { !$0.isEmpty }.joined(separator: "，")
    }

    func drawnRowFrame(_ index: Int) -> CGRect { CGRect(x: 0, y: CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight) }
    func isDrawnRowSelected(_ index: Int) -> Bool { rows.indices.contains(index) && rows[index].id == selectedID }
    func pressDrawnRow(_ index: Int) {
        guard rows.indices.contains(index), !rows[index].disabled else { return }
        onSelect?(rows[index])
    }
}
