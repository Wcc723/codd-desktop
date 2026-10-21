import AppKit
import CoddOnboarding
import CoddUI

/// Step 2 (exactly the artboard): the toolbar (filter, `[依父資料夾建議分組]`, `已選 9`, hint), the
/// table (header, 30 px rows, foot). Changes are applied by the owner (`onChange`), which recomputes
/// the model and calls `apply(_:)` again.
final class ImportStepView: NSView {
    private(set) var model: ImportStepModel?
    var onChange: (ImportSelection) -> Void = { _ in }
    var onSuggest: () -> Void = {}
    var onOpenMenu: (String) -> Void = { _ in }
    /// ⏎ in the filter (not while composing).
    var onSubmit: () -> Void = {}

    let filter = FilterField(placeholder: "篩選名稱或路徑…", accessibility: "篩選專案")
    let suggest = PressButton("依父資料夾建議分組", style: .bracket(.accent, small: false))
    let chip = ChipView("已選 0", style: .chip(.amber))
    let hint = TextLine()
    let table = ImportTableView()
    /// What the `已選 n` chip shows (ChipView keeps its label private).
    private(set) var chipText = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [filter, suggest.button, chip, hint, table] { addSubview(view) }
        hint.set("依最近使用排序 · 群組可之後在側欄拖曳調整", style: TextStyle.hint)
        filter.onChange = { [weak self] text in
            guard let self, let model = self.model else { return }
            self.onChange(model.selection.filtering(text))
        }
        filter.onSubmit = { [weak self] in self?.onSubmit() }
        suggest.run = { [weak self] in
            guard let self, let model = self.model else { return }
            self.onSuggest()
            self.onChange(model.selection.applyingSuggestions(model.suggestion))
        }
        table.rows.onToggle = { [weak self] path in
            guard let self, let model = self.model else { return }
            self.onChange(model.selection.toggling(path))
        }
        table.rows.onOpenMenu = { [weak self] path in self?.onOpenMenu(path) }
        table.header.checkbox.onToggle = { [weak self] in
            guard let self, let model = self.model else { return }
            let visible = model.selection.visible(in: model.catalog).map(\.path)
            let allOn = !visible.isEmpty && visible.allSatisfy(model.selection.checked.contains)
            self.onChange(model.selection.setting(visible, checked: !allOn))
        }
        table.foot.hiddenToggle.run = { [weak self] in
            guard let self, let model = self.model else { return }
            self.onChange(model.selection.togglingHidden())
        }
        table.foot.more.run = { [weak self] in
            guard let self, let model = self.model else { return }
            self.onChange(model.selection.loadingMore())
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(_ model: ImportStepModel) {
        guard model != self.model else { return }
        self.model = model
        if filter.text != model.selection.filter { filter.text = model.selection.filter }
        chipText = "已選 \(model.checkedCount)"
        chip.set(chipText)
        chip.setAccessibilityLabel("已選 \(model.checkedCount) 個專案")
        suggest.button.isEnabled = !model.selection.checked.isEmpty
        table.apply(model)
        needsLayout = true
    }

    /// The lead's markup for this catalog.
    static func lead(for catalog: ProjectCatalog) -> String {
        guard let source = catalog.source else {
            return "找不到 `~/.claude.json`，沒有可以匯入的專案。之後可以用 ⌘N 或側欄的 + 加入專案。"
        }
        return "從 `\(source)` 找到 **\(catalog.visibleTotal)** 個專案（依最近使用排序）。只勾選你要的，CODD 不會一次全部匯入。"
    }

    static var toolbarHeight: CGFloat { dz(30) }

    /// Toolbar, gap 10, the table at its natural height (or `available`, the rows scrolling).
    func height(available: CGFloat) -> CGFloat {
        let tableNatural = table.naturalHeight()
        return min(available, Self.toolbarHeight + dz(10) + tableNatural)
    }

    override func layout() {
        super.layout()
        let height = Self.toolbarHeight
        let gap = dz(10)
        filter.place(CGRect(x: 0, y: 0, width: min(dz(340), bounds.width), height: height))
        var x = filter.frame.maxX + gap
        let button = suggest.button.intrinsicContentSize
        suggest.button.place(CGRect(x: x, y: (height - button.height) / 2, width: button.width, height: button.height))
        x = suggest.button.frame.maxX + gap
        let chipSize = chip.intrinsicContentSize
        chip.place(CGRect(x: x, y: (height - chipSize.height) / 2, width: chipSize.width, height: chipSize.height))
        x = chip.frame.maxX + gap
        // The hint is pushed right by the spacer and, on narrow windows, goes whole (never cut).
        let hintWidth = hint.textWidth
        hint.place(CGRect(x: bounds.width - hintWidth, y: 0, width: hintWidth, height: height))
        hint.isHidden = hintWidth > max(0, bounds.width - x)
        let tableTop = height + gap
        let tableHeight = min(table.naturalHeight(), max(0, bounds.height - tableTop))
        table.place(CGRect(x: 0, y: tableTop, width: bounds.width, height: tableHeight))
    }
}

/// `.ob-filter`: 340 × 30, --line-bright border on --bg-soft, padding 0 10, gap 8, a dim `/`, the
/// cream 12 px input. The system field editor edits it, so input methods (注音) work; the focused
/// box draws the helmet `.input:focus` look.
final class FilterField: FieldBoxView, NSTextFieldDelegate {
    let field = NSTextField()
    var onChange: (String) -> Void = { _ in }
    var onSubmit: () -> Void = {}

    init(placeholder: String, accessibility: String) {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(12)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(12, Palette.dimmer).string(placeholder)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel(accessibility)
        addSubview(field)
    }

    var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    /// The field editor composes (注音): ⏎ belongs to the input method.
    var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }
    var isEditingText: Bool { field.currentEditor() != nil }

    override func layout() {
        super.layout()
        let slash = Draw.width(TextStyle.mono(12, Palette.dimmer).string("/"))
        let x = dz(10) + slash + dz(8)
        let height = ceil(Typeface.lineHeight(Typeface.mono(12))) + 2
        field.frame = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: max(0, bounds.width - x - dz(10)), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.text(TextStyle.mono(12, Palette.dimmer).string("/"), x: dz(10), centerY: bounds.midY)
    }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(field) }

    func controlTextDidChange(_ obj: Notification) { onChange(field.stringValue) }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
        isFocused = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { isFocused = false }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onSubmit()
            return true
        }
        return false
    }

    /// Focus follows the field editor (a click that only focuses sends no begin-editing).
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

// MARK: - Table

/// Column widths of the table (design 42 · 262 · flex · 118 · 112 · 214). When the window is too
/// narrow for the fixed columns and a 160 px path, the name, group, last-used and transcript
/// columns give way proportionally down to their minimums before the path does. The last-used and
/// transcript minimums keep their header labels whole (`LAST USED ↓`, `TRANSCRIPTS`; at 1011 px
/// they used to read `LAST US…`, `TRANSC…`).
struct ImportColumns: Equatable {
    var check: CGFloat
    var name: CGFloat
    var path: CGFloat
    var last: CGFloat
    var transcripts: CGFloat
    var group: CGFloat

    @MainActor
    static func fit(_ width: CGFloat) -> ImportColumns {
        let check = dz(42)
        var name = dz(262), last = dz(118), transcripts = dz(112), group = dz(214)
        // The name and group minimums gave the header labels' room (the path still keeps 160 px).
        let mins: [CGFloat] = [dz(132), max(dz(84), ImportHeaderView.titleWidth(2) + dz(20)),
                               max(dz(72), ImportHeaderView.titleWidth(3) + dz(20)), dz(126)]
        let fixed = check + name + last + transcripts + group
        let wantedPath = dz(160)
        let deficit = fixed + wantedPath - width
        if deficit > 0 {
            let values = [name, last, transcripts, group]
            let excess = zip(values, mins).map { max(0, $0 - $1) }
            let total = excess.reduce(0, +)
            let ratio = total > 0 ? min(1, deficit / total) : 0
            let shrunk = zip(values, excess).map { ($0 - $1 * ratio).rounded() }
            name = shrunk[0]; last = shrunk[1]; transcripts = shrunk[2]; group = shrunk[3]
        }
        let path = max(dz(60), width - check - name - last - transcripts - group)
        return ImportColumns(check: check, name: name, path: path, last: last, transcripts: transcripts, group: group)
    }

    /// Left edges of the six columns.
    var edges: [CGFloat] {
        var x: CGFloat = 0
        return [check, name, path, last, transcripts, group].map { width in defer { x += width }; return x }
    }
}

/// `.ob-tblwrap`: 1 px --line-bright border on --bg-soft; header 30, rows (scrolling when the window
/// is short), foot 36.
final class ImportTableView: NSView {
    let header = ImportHeaderView()
    let scroll = NSScrollView()
    let rows = ImportRowsView()
    let foot = TableFootView()
    let empty = TextLine()
    private(set) var columns = ImportColumns(check: 42, name: 262, path: 350, last: 118, transcripts: 112, group: 214)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = rows
        scroll.contentView.drawsBackground = false
        for view in [header, scroll, empty, foot] { addSubview(view) }
        empty.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(_ model: ImportStepModel) {
        let visible = model.selection.visible(in: model.catalog)
        rows.apply(model, visible: visible)
        let all = !visible.isEmpty && visible.allSatisfy { model.selection.checked.contains($0.path) }
        let some = visible.contains { model.selection.checked.contains($0.path) }
        header.checkbox.state = all ? .on : (some ? .mixed : .off)
        header.checkbox.isEnabled = !visible.isEmpty
        foot.apply(model, visible: visible.count)
        let message = Self.emptyMessage(model, visibleCount: visible.count)
        empty.isHidden = message == nil
        if let message { empty.set("// " + message, style: TextStyle.comment) }
        needsLayout = true
    }

    /// §2.4's empty states.
    static func emptyMessage(_ model: ImportStepModel, visibleCount: Int) -> String? {
        guard visibleCount == 0 else { return nil }
        let catalog = model.catalog
        if catalog.source == nil { return "找不到 ~/.claude.json：還沒用過 Claude Code？之後可以用 ⌘N 或側欄的 + 加入專案" }
        if let problem = catalog.problem { return problem }
        if !model.selection.filter.trimmingCharacters(in: .whitespaces).isEmpty { return "沒有符合「\(model.selection.filter)」的專案" }
        if catalog.candidates.isEmpty, catalog.alreadyInCODD > 0 { return "這些專案都已在側欄" }
        return "~/.claude.json 裡沒有可以匯入的專案"
    }

    static var headerHeight: CGFloat { dz(30) }
    static var footHeight: CGFloat { dz(36) }
    static var rowHeight: CGFloat { dz(30) }
    static var emptyHeight: CGFloat { dz(48) }

    var bodyHeight: CGFloat { empty.isHidden ? Self.rowHeight * CGFloat(rows.rowViews.count) : Self.emptyHeight }

    func naturalHeight() -> CGFloat { 1 + Self.headerHeight + bodyHeight + Self.footHeight + 1 }

    override func layout() {
        super.layout()
        let inner = CGRect(x: 1, y: 1, width: bounds.width - 2, height: bounds.height - 2)
        columns = ImportColumns.fit(inner.width)
        header.columns = columns
        rows.columns = columns
        header.place(CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: Self.headerHeight))
        let bodyTop = header.frame.maxY
        let footTop = inner.maxY - Self.footHeight
        let body = CGRect(x: inner.minX, y: bodyTop, width: inner.width, height: max(0, footTop - bodyTop))
        scroll.place(body)
        rows.setFrameSize(NSSize(width: body.width, height: Self.rowHeight * CGFloat(rows.rowViews.count)))
        rows.needsLayout = true
        empty.place(CGRect(x: inner.minX + dz(12), y: bodyTop, width: inner.width - dz(24), height: body.height))
        foot.place(CGRect(x: inner.minX, y: footTop, width: inner.width, height: Self.footHeight))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }
}

/// `thead`: 30 px --bg-lift, 1 px --line-bright bottom border, 10 px caps .16em --dim (`LAST USED ↓`
/// in --amber-dim, `TRANSCRIPTS` right aligned), the select-all checkbox.
final class ImportHeaderView: NSView, OnboardingTextShowing {
    let checkbox = RowCheckbox(label: "全選目前顯示的專案")
    var columns = ImportColumns(check: 42, name: 262, path: 350, last: 118, transcripts: 112, group: 214) {
        didSet { if columns != oldValue { needsLayout = true; needsDisplay = true } }
    }

    static let titles = ["PROJECT", "PATH", "LAST USED ↓", "TRANSCRIPTS", "GROUP"]

    static func titleStyle(_ index: Int) -> TextStyle {
        TextStyle.caps(10, index == 2 ? Palette.amberDim : Palette.dim, tracking: 0.16, .medium)
    }

    /// The drawn width of `titles[index]`.
    static func titleWidth(_ index: Int) -> CGFloat { ceil(Draw.width(titleStyle(index).string(titles[index]))) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(checkbox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { Self.titles.joined(separator: " ") }

    override func layout() {
        super.layout()
        checkbox.place(CGRect(x: 0, y: 0, width: columns.check, height: bounds.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgLift)
        Draw.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), Palette.lineBright)
        let edges = columns.edges
        let widths = [columns.name, columns.path, columns.last, columns.transcripts, columns.group]
        let mid = (bounds.height - 1) / 2
        for (index, title) in Self.titles.enumerated() {
            let string = Self.titleStyle(index).string(title)
            let x = edges[index + 1] + dz(10)
            let width = widths[index] - dz(20)
            if index == 3 {
                let drawn = min(Draw.width(string), width)
                Draw.text(string, x: x + width - drawn, centerY: mid, maxWidth: width)
            } else {
                Draw.text(string, x: x, centerY: mid, maxWidth: width)
            }
        }
    }
}

/// The rows (the scroll view's document). One key-view stop: ↑ / ↓ move the row focus, space
/// toggles, ⌥↓ opens the row's group menu (§2.4).
final class ImportRowsView: NSView {
    private(set) var rowViews: [ImportRowView] = []
    private var byPath: [String: ImportRowView] = [:]
    var columns = ImportColumns(check: 42, name: 262, path: 350, last: 118, transcripts: 112, group: 214) {
        didSet { if columns != oldValue { for row in rowViews { row.columns = columns } } }
    }
    var onToggle: (String) -> Void = { _ in }
    var onOpenMenu: (String) -> Void = { _ in }
    private(set) var focusedIndex: Int? { didSet { if focusedIndex != oldValue { updateFocus() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("可匯入的專案")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { rowViews.flatMap { $0.accessibilityChildren() ?? [] } }

    func row(for path: String) -> ImportRowView? { byPath[path] }

    func apply(_ model: ImportStepModel, visible: [ImportCandidate]) {
        var next: [ImportRowView] = []
        var keep: [String: ImportRowView] = [:]
        for candidate in visible {
            let row = byPath[candidate.path] ?? {
                let row = ImportRowView()
                row.onToggle = { [weak self] path in self?.onToggle(path) }
                row.onOpenMenu = { [weak self] path in self?.onOpenMenu(path) }
                addSubview(row)
                return row
            }()
            row.columns = columns
            row.configure(candidate, model: model)
            next.append(row)
            keep[candidate.path] = row
        }
        for (path, row) in byPath where keep[path] == nil { row.removeFromSuperview() }
        let focusedPath = focusedIndex.flatMap { rowViews.indices.contains($0) ? rowViews[$0].path : nil }
        rowViews = next
        byPath = keep
        if let focusedPath, let index = next.firstIndex(where: { $0.path == focusedPath }) {
            focusedIndex = index
        } else if let focused = focusedIndex {
            focusedIndex = next.isEmpty ? nil : min(focused, next.count - 1)
        }
        updateFocus()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = ImportTableView.rowHeight
        for (index, row) in rowViews.enumerated() {
            row.place(CGRect(x: 0, y: height * CGFloat(index), width: bounds.width, height: height))
        }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { !rowViews.isEmpty }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    private var hasFocus = false

    override func becomeFirstResponder() -> Bool {
        hasFocus = true
        if focusedIndex == nil, !rowViews.isEmpty { focusedIndex = 0 }
        updateFocus()
        return true
    }

    override func resignFirstResponder() -> Bool {
        hasFocus = false
        updateFocus()
        return true
    }

    /// Moves the row focus (tests, the App's actions).
    func focus(row index: Int) {
        guard rowViews.indices.contains(index) else { return }
        focusedIndex = index
        scrollToFocused()
    }

    var focusedPath: String? { focusedIndex.flatMap { rowViews.indices.contains($0) ? rowViews[$0].path : nil } }

    private var isFocusVisible: Bool { hasFocus }

    private func updateFocus() {
        let visible = isFocusVisible
        for (index, row) in rowViews.enumerated() { row.isKeyFocused = visible && index == focusedIndex }
    }

    private func scrollToFocused() {
        guard let index = focusedIndex, rowViews.indices.contains(index) else { return }
        scrollToVisible(rowViews[index].frame)
    }

    override func keyDown(with event: NSEvent) {
        let option = event.modifierFlags.contains(.option)
        if event.specialKey == .upArrow {
            guard let index = focusedIndex else { focus(row: 0); return }
            focus(row: max(0, index - 1))
        } else if event.specialKey == .downArrow {
            if option, let path = focusedPath {
                onOpenMenu(path)
                return
            }
            guard let index = focusedIndex else { focus(row: 0); return }
            focus(row: min(rowViews.count - 1, index + 1))
        } else if event.charactersIgnoringModifiers == " " {
            if let path = focusedPath { onToggle(path) }
        } else {
            super.keyDown(with: event)
        }
    }
}

/// One table row (`tbody tr`, 30 px, dashed --line bottom border, hover --bg-lift). Unchecked rows
/// are dimmed with a disabled group select; hidden rows (shown with `顯示隱藏項目`) are dimmed
/// further and carry a `WORKTREE` / `SDK` mark.
final class ImportRowView: NSView, OnboardingTextShowing {
    let checkbox = RowCheckbox(label: "")
    let pathCell = PathCellView()
    let select = GroupSelectView()
    private(set) var path = ""
    private(set) var candidate: ImportCandidate?
    private(set) var isChecked = false
    private(set) var lastUsed = ""
    var onToggle: (String) -> Void = { _ in }
    var onOpenMenu: (String) -> Void = { _ in }
    var columns = ImportColumns(check: 42, name: 262, path: 350, last: 118, transcripts: 112, group: 214) {
        didSet { if columns != oldValue { needsLayout = true; needsDisplay = true } }
    }
    var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(checkbox)
        addSubview(pathCell)
        addSubview(select)
        checkbox.onToggle = { [weak self] in
            guard let self else { return }
            self.onToggle(self.path)
        }
        select.onOpen = { [weak self] in
            guard let self else { return }
            self.onOpenMenu(self.path)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { [checkbox, pathCell, select] }

    func configure(_ candidate: ImportCandidate, model: ImportStepModel) {
        let checked = model.selection.checked.contains(candidate.path)
        let last = LastUsedFormat.text(candidate.lastUsed, now: model.now, timeZone: model.timeZone)
        let option = model.option(model.selection.groupKey(for: candidate.path))
        let changed = candidate != self.candidate || checked != isChecked || last != lastUsed
        self.candidate = candidate
        path = candidate.path
        isChecked = checked
        lastUsed = last
        checkbox.state = checked ? .on : .off
        checkbox.setAccessibilityLabel("\(candidate.name)，\(candidate.displayPath)，\(last)，\(candidate.transcripts) 個對話")
        pathCell.configure(candidate.displayPath, dimmed: candidate.hidden != nil)
        select.configure(option: option, enabled: checked, projectName: candidate.name)
        alphaValue = candidate.hidden != nil ? 0.6 : 1
        if changed { needsDisplay = true }
    }

    var displayedText: String {
        guard let candidate else { return "" }
        return [(candidate.prefix ?? "") + candidate.name, pathCell.displayedText, lastUsed, "\(candidate.transcripts)", select.displayedText]
            .joined(separator: " ")
    }

    override func layout() {
        super.layout()
        let edges = columns.edges
        checkbox.place(CGRect(x: 0, y: 0, width: columns.check, height: bounds.height - 1))
        pathCell.place(CGRect(x: edges[2] + dz(10), y: 0, width: max(0, columns.path - dz(20)), height: bounds.height - 1))
        select.place(CGRect(x: edges[5] + dz(10), y: ((bounds.height - 1 - dz(24)) / 2).rounded(), width: max(0, columns.group - dz(20)),
                            height: dz(24)))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered { Draw.fill(bounds, Palette.bgLift) }
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.line)
        guard let candidate else { return }
        let edges = columns.edges
        let mid = (bounds.height - 1) / 2
        let off = !isChecked
        // `.ob-nm` cream with `.pp` --dim; `tr.off` both --dim.
        let nameColor = off ? Palette.dim : Palette.cream
        var parts: [(String, TextStyle)] = []
        if let prefix = candidate.prefix { parts.append((prefix, TextStyle.mono(12, Palette.dim))) }
        parts.append((candidate.name, TextStyle.mono(12, nameColor)))
        let nameX = edges[1] + dz(10)
        var nameWidth = columns.name - dz(20)
        if let hidden = candidate.hidden {
            let mark = ChipStyle.ext
            let label = hidden == .worktree ? "WORKTREE" : "SDK"
            let markWidth = mark.size(for: label).width
            mark.draw(label, x: edges[1] + columns.name - dz(10) - markWidth, centerY: mid)
            nameWidth -= markWidth + dz(6)
        }
        Draw.text(runs(parts), x: nameX, centerY: mid, maxWidth: max(0, nameWidth))
        let cellColor = off ? Palette.dimmer : Palette.bone
        Draw.text(TextStyle.mono(12, cellColor).string(lastUsed), x: edges[3] + dz(10), centerY: mid, maxWidth: columns.last - dz(20))
        let count = TextStyle.mono(12, cellColor).string("\(candidate.transcripts)")
        let countWidth = Draw.width(count)
        Draw.text(count, x: edges[4] + columns.transcripts - dz(10) - countWidth, centerY: mid)
        if isKeyFocused {
            Draw.strokeRect(bounds, color: Palette.amber)
        }
    }

    // MARK: Mouse

    /// A click on the name toggles the row (`<label for>`).
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = columns.edges
        if point.x >= edges[1], point.x < edges[2] { onToggle(path) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
}

/// A 13 px square checkbox (the artboard's native checkbox with `accent-color: amber`, drawn square:
/// radius 0). Off: --bg with a --dim border; on: amber with a black `✓`; mixed: amber `−`. A click
/// and VoiceOver's press toggle; the table handles the keyboard (it is not a key-view stop).
final class RowCheckbox: NSView {
    var state: NSControl.StateValue = .off {
        didSet {
            guard state != oldValue else { return }
            setAccessibilityValue(state == .on ? 1 : (state == .mixed ? 2 : 0))
            needsDisplay = true
        }
    }
    var isEnabled = true { didSet { if isEnabled != oldValue { alphaValue = isEnabled ? 1 : 0.4 } } }
    var onToggle: () -> Void = {}

    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(label)
        setAccessibilityValue(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var boxRect: CGRect {
        let side = dz(13)
        return CGRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = boxRect
        switch state {
        case .on, .mixed:
            Draw.fill(box, Palette.amber)
            let mark = TextStyle.mono(10, .black, .bold).string(state == .on ? "✓" : "−")
            Draw.text(mark, x: (box.midX - Draw.width(mark) / 2).rounded(), centerY: box.midY)
        default:
            Draw.fill(box, Palette.bg)
            Draw.strokeRect(box, color: Palette.dim)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onToggle()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onToggle()
        return true
    }
}

/// `.ob-path` (11.5 --dimmer): the path elided from the front by whole components to the column
/// (D10); the full path in the tooltip and the accessibility value.
final class PathCellView: NSView, OnboardingTextShowing {
    private(set) var fullPath = ""
    private(set) var shown = ""
    private var dimmed = false
    private var measuredWidth: CGFloat = -1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("路徑")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { shown }

    static var style: TextStyle { TextStyle.mono(11.5, Palette.dimmer, tracking: 0.01) }

    func configure(_ path: String, dimmed: Bool) {
        guard path != fullPath || dimmed != self.dimmed else { return }
        fullPath = path
        self.dimmed = dimmed
        toolTip = path
        setAccessibilityValue(path)
        measuredWidth = -1
        needsLayout = true
        needsDisplay = true
    }

    func invalidateMeasurement() {
        measuredWidth = -1
        needsLayout = true
    }

    /// The text shown at `width` (D10 front elision; tests call it with the artboard's widths).
    static func elided(_ path: String, width: CGFloat) -> String {
        let style = style
        return PathText.elide(path) { Draw.width(style.string($0)) <= width }
    }

    override func layout() {
        super.layout()
        if bounds.width != measuredWidth {
            measuredWidth = bounds.width
            shown = Self.elided(fullPath, width: bounds.width)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.text(Self.style.string(shown), x: 0, centerY: bounds.midY, maxWidth: bounds.width)
    }
}

/// The row's group select (`.select.ob-gsel`, 24 px): the tag square, the name, the amber caret; open
/// = amber border + 1 px inset + glow; disabled at 45 %. It opens the overlay menu (`onOpen`).
final class GroupSelectView: NSView, OnboardingTextShowing {
    private(set) var option = GroupOption.ungrouped
    private(set) var isEnabled = true
    var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            setAccessibilityExpanded(isOpen)
            updateGlow()
            needsDisplay = true
        }
    }
    var onOpen: () -> Void = {}
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var displayedText: String { option.name }

    func configure(option: GroupOption, enabled: Bool, projectName: String) {
        let label = "\(projectName) 的群組：\(option.name)" + (enabled ? "" : "（未勾選）")
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
        setAccessibilityValue(option.name)
        guard option != self.option || enabled != isEnabled else { return }
        self.option = option
        isEnabled = enabled
        alphaValue = enabled ? 1 : 0.45
        setAccessibilityEnabled(enabled)
        needsDisplay = true
    }

    private func updateGlow() {
        shadow = isOpen ? Draw.glow(Palette.amberGlow, radius: 8) : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        let hot = isHovered && isEnabled
        if isOpen {
            Draw.strokeRect(bounds, color: Palette.amber)
            Draw.strokeRect(bounds.insetBy(dx: 1, dy: 1), color: Palette.amber)
        } else {
            Draw.strokeRect(bounds, color: hot ? Palette.amberDim : Palette.lineBright)
        }
        let tag = CGRect(x: dz(8), y: ((bounds.height - dz(8)) / 2).rounded(), width: dz(8), height: dz(8))
        TagColor.drawSquare(option.color, in: tag)
        let textX = tag.maxX + dz(8)
        let color = (isOpen || hot) ? Palette.cream : Palette.bone
        Draw.text(TextStyle.mono(12, color).string(option.name), x: textX, centerY: bounds.midY, maxWidth: max(0, bounds.width - textX - dz(26)))
        // helmet `.select` caret: one amber ▼ (10 × 5) centered 13 px from the right edge.
        let x = bounds.maxX - dz(13)
        let y = bounds.midY
        let w = UIZoom.scaled(5)
        let h = UIZoom.scaled(2.5)
        let caret = NSBezierPath()
        caret.move(to: CGPoint(x: x - w, y: y - h))
        caret.line(to: CGPoint(x: x + w, y: y - h))
        caret.line(to: CGPoint(x: x, y: y + h))
        caret.close()
        Palette.amber.setFill()
        caret.fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onOpen()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onOpen()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
}

/// `tfoot` (36 px, --bg): `// ~/.claude-worktrees/* 與 SDK 產生的專案預設隱藏` + `[顯示隱藏項目]` (toggles
/// to `[隱藏]`), spacer, `顯示 12 / 187`, `[載入更多 ↓]`.
final class TableFootView: NSView {
    let note = RichTextView("// `~/.claude-worktrees/*` 與 SDK 產生的專案預設隱藏",
                            look: RichLook(size: 11.5, color: Palette.dimmer, lineHeight: 11.5 * 1.5, codeSize: 11, codeColor: Palette.bone))
    let hiddenToggle = BoxButton("顯示隱藏項目")
    let count = TextLine()
    let more = PressButton("載入更多 ↓", style: .bracket(.normal, small: true), accessibility: "載入更多專案")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [note, hiddenToggle, count, more.button] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func apply(_ model: ImportStepModel, visible: Int) {
        let selection = model.selection
        hiddenToggle.label = selection.showHidden ? "隱藏" : "顯示隱藏項目"
        hiddenToggle.setAccessibilityLabel(selection.showHidden ? "隱藏 worktree 與 SDK 專案" : "顯示隱藏項目")
        let matching = selection.matching(in: model.catalog).count
        var text = "顯示 \(visible) / \(matching)"
        if model.catalog.alreadyInCODD > 0 { text += " · 另有 \(model.catalog.alreadyInCODD) 個已在側欄" }
        count.set(text, style: TextStyle.hint)
        more.button.isHidden = matching <= visible
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let mid = bounds.height / 2
        let gap = dz(10)
        var right = bounds.width - dz(4)
        if !more.button.isHidden {
            let size = more.button.intrinsicContentSize
            more.button.place(CGRect(x: right - size.width, y: mid - size.height / 2, width: size.width, height: size.height))
            right = more.button.frame.minX - gap
        }
        let countWidth = count.textWidth
        count.place(CGRect(x: right - countWidth, y: 0, width: countWidth, height: bounds.height))
        right = count.frame.minX - gap
        let noteWidth = min(note.naturalWidth, max(0, right - dz(12) - gap - hiddenToggle.intrinsicContentSize.width))
        let noteHeight = ceil(UIZoom.scaled(11.5 * 1.5))
        note.place(CGRect(x: dz(12), y: mid - noteHeight / 2, width: noteWidth, height: noteHeight))
        let toggle = hiddenToggle.intrinsicContentSize
        hiddenToggle.place(CGRect(x: note.frame.maxX + gap, y: mid - toggle.height / 2, width: toggle.width, height: toggle.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
    }
}

/// A zoom change re-measures the elided path (the font changed even where the column did not).
extension PathCellView: ZoomRefreshing {
    func zoomDidChange() {
        invalidateMeasurement()
    }
}
