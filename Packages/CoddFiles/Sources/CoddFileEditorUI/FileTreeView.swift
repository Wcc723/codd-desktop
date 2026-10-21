import AppKit
import CoddFiles
import CoddUI

/// The FileEditor artboard's tree column (`aside.side.fe-tree`, 264 pt): the `.fe-head`
/// (`FILES · <project>`, the git line, 新增檔案 (disabled in M4) and 全部收合), the filter field
/// (`/ 篩選檔案… ⌘P`, IME-safe), the RECENT and PROJECT sections of `.fe-node` rows, and the foot
/// (`LOCAL <path>`, the session line). Value model in, closures out; the app owns the tree state.
public final class FileTreeView: FlippedView {
    public static var width: CGFloat { fz(264) }
    public static var headHeight: CGFloat { fz(60) }

    public private(set) var model: FileTreeModelView
    /// A file row was clicked: `preview` for a single click (a preview tab), false for a double click.
    public var onOpen: ((_ id: String, _ preview: Bool) -> Void)?
    /// A folder row was clicked.
    public var onToggle: ((String) -> Void)?
    /// The filter text changed (never while an input method composes).
    public var onFilter: ((String) -> Void)?
    /// The filter field's editor commands (↑ ↓ ⏎ esc) after the input method; true = handled.
    public var onFilterCommand: ((Selector) -> Bool)?
    public var onCollapseAll: (() -> Void)?
    public var onToggleSection: ((FileTreeSection) -> Void)?

    let head = TreeHeadView()
    let filterField = TreeFilterField()
    let list = TreeListView()
    let scroll = NSScrollView()
    let foot = TreeFootView()

    public init(model: FileTreeModelView) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: fz(900)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = list
        for view in [head, filterField, scroll, foot] as [NSView] { addSubview(view) }
        head.collapseButton.onClick = { [weak self] in self?.onCollapseAll?() }
        filterField.onChange = { [weak self] text in self?.onFilter?(text) }
        filterField.onCommand = { [weak self] selector in self?.onFilterCommand?(selector) ?? false }
        list.onOpen = { [weak self] id, preview in self?.onOpen?(id, preview) }
        list.onToggle = { [weak self] id in self?.onToggle?(id) }
        list.onToggleSection = { [weak self] section in self?.onToggleSection?(section) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("檔案")
        apply()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: NSView.noIntrinsicMetric) }

    public func update(_ model: FileTreeModelView) {
        guard model != self.model else { return }
        self.model = model
        apply()
    }

    /// ⌘P: puts the caret in the filter field.
    public func focusFilter() { filterField.focus() }

    /// The filter field is composing (注音): keys belong to the input method.
    public var isComposingFilter: Bool { filterField.isComposing }

    private func apply() {
        head.model = model
        foot.session = model.session
        foot.path = model.footPath
        filterField.setText(model.filter)
        list.model = model
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let width = bounds.width - 1 // the 1 px right border stays visible
        let footHeight = foot.preferredHeight
        head.frame = CGRect(x: 0, y: 0, width: width, height: Self.headHeight)
        filterField.frame = CGRect(x: fz(8), y: Self.headHeight + fz(8), width: width - fz(16), height: fz(26))
        let listTop = Self.headHeight + fz(36)
        scroll.frame = CGRect(x: 0, y: listTop, width: width, height: max(0, bounds.height - listTop - footHeight))
        foot.frame = CGRect(x: 0, y: bounds.height - footHeight, width: width, height: footHeight)
        list.frame = CGRect(x: 0, y: 0, width: width, height: max(list.contentHeight, scroll.contentSize.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
    }
}

// MARK: - Head

/// `.fe-head`: r1 `FILES · <project>`, r2 the git line and the two icon buttons.
final class TreeHeadView: FlippedView {
    let newFileButton = FileEditorIconButton(.icon(.newFile), label: "新增檔案")
    let collapseButton = FileEditorIconButton(.icon(.collapseAll), label: "全部收合")

    var model: FileTreeModelView? {
        didSet {
            newFileButton.isEnabled = model?.newFileEnabled ?? false
            newFileButton.toolTip = newFileButton.isEnabled ? "新增檔案" : "新增檔案（之後提供）"
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        collapseButton.toolTip = "全部收合"
        for button in [newFileButton, collapseButton] {
            button.translatesAutoresizingMaskIntoConstraints = true
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// r1 and r2 centers: the column (21 + 4 + 22) is centered in the 60 pt head.
    static var row1Center: CGFloat { fz(17) }
    static var row2Center: CGFloat { fz(42.5) }

    override func layout() {
        super.layout()
        let right = bounds.width - fz(8)
        collapseButton.frame = CGRect(x: right - fz(22), y: Self.row2Center - fz(11), width: fz(22), height: fz(22))
        newFileButton.frame = CGRect(x: right - fz(22) - fz(6) - fz(22), y: Self.row2Center - fz(11), width: fz(22), height: fz(22))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.line)
        guard let model else { return }
        // r1: FILES · project (baseline aligned)
        var brand = TextStyle(font: Typeface.display(14), color: Palette.amber, tracking: 0.04)
        brand.shadow = Draw.glow(Palette.amberGlow, radius: 8)
        var x: CGFloat = fz(14)
        x += Draw.text(brand.string("FILES"), x: x, centerY: Self.row1Center) + fz(7)
        x += Draw.text(TextStyle.mono(13, Palette.dimmer).string("·"), x: x, centerY: Self.row1Center + 0.5) + fz(7)
        Draw.text(TextStyle.mono(12, Palette.cream).string(model.project), x: x, centerY: Self.row1Center + 1,
                  maxWidth: bounds.width - fz(8) - x)
        // r2: ⎇ branch ↑n · M n · AI n
        let y = Self.row2Center
        let limit = newFileButton.frame.minX - fz(6)
        var items: [(String, NSColor)] = []
        if let git = model.git {
            items.append(("⎇ \(git.branch)", Palette.dim))
            if git.ahead > 0 { items.append(("↑\(git.ahead)", Palette.dimmer)) }
            if git.behind > 0 { items.append(("↓\(git.behind)", Palette.dimmer)) }
            items.append(("·", Palette.dimmer))
            items.append(("M \(git.modified)", git.modified > 0 ? Palette.amber : Palette.dimmer))
            items.append(("·", Palette.dimmer))
            items.append(("AI \(model.aiCount)", model.aiCount > 0 ? (model.aiColor ?? Palette.bone) : Palette.dimmer))
        } else {
            items.append(("// 不是 git 專案", Palette.dimmer))
            if model.aiCount > 0 {
                items.append(("·", Palette.dimmer))
                items.append(("AI \(model.aiCount)", model.aiColor ?? Palette.bone))
            }
        }
        // The counts always show; the first item (the branch) gives way, truncated at its tail.
        let strings = items.map { TextStyle.mono(10.5, $0.1).string($0.0) }
        let rest = strings.dropFirst().reduce(CGFloat(0)) { $0 + Draw.width($1) + fz(6) }
        x = fz(14)
        for (index, string) in strings.enumerated() {
            let room = index == 0 ? max(fz(24), limit - x - rest) : limit - x
            guard room > 0 else { break }
            x += Draw.text(string, x: x, centerY: y, maxWidth: room) + fz(6)
        }
    }
}

// MARK: - Filter

/// `.fe-filter`: `/`, the field (placeholder `篩選檔案…`), `⌘P`. The system field editor edits
/// it (注音 works); `onChange` stays silent while the editor has marked text and fires with the
/// committed text afterwards.
final class TreeFilterField: FieldBoxView, NSTextFieldDelegate {
    let field = NSTextField()
    var onChange: ((String) -> Void)?
    var onCommand: ((Selector) -> Bool)?
    private let kbd = ChipView.kbd("⌘P")
    private var lastReported = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(11.5)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(11.5, Palette.dimmer).string("篩選檔案…")
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel("篩選檔案")
        addSubview(field)
        addSubview(kbd)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The editor composes (注音).
    var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    /// Sets the text from the model unless the user is composing (marked text is never replaced).
    func setText(_ text: String) {
        guard !isComposing, field.stringValue != text else { return }
        field.stringValue = text
        lastReported = text
    }

    func focus() { window?.makeFirstResponder(field) }

    private var slashWidth: CGFloat { Draw.width(TextStyle.mono(11.5, Palette.dim).string("/")) }

    override func layout() {
        super.layout()
        let kbdSize = kbd.intrinsicContentSize
        kbd.frame = CGRect(x: bounds.width - fz(8) - kbdSize.width, y: (bounds.height - kbdSize.height) / 2, width: kbdSize.width,
                           height: kbdSize.height)
        let left = fz(8) + slashWidth + fz(6)
        let height: CGFloat = fz(16)
        field.frame = CGRect(x: left - fz(2), y: (bounds.height - height) / 2, width: max(0, kbd.frame.minX - fz(6) - left + fz(2)), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        Draw.text(TextStyle.mono(11.5, Palette.dim).string("/"), x: fz(8), centerY: bounds.midY)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
        isFocused = true
    }

    func controlTextDidEndEditing(_ obj: Notification) { isFocused = false }

    func controlTextDidChange(_ obj: Notification) {
        let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView ?? field.currentEditor() as? NSTextView
        guard !(editor?.hasMarkedText() ?? false) else { return }
        report(field.stringValue)
    }

    private func report(_ text: String) {
        guard text != lastReported else { return }
        lastReported = text
        onChange?(text)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        return onCommand?(selector) ?? false
    }
}

// MARK: - List

/// The custom-drawn rows of `.side-scroll` (`padding: 8px 6px 12px`): section heads (`.sbsec`,
/// 26 pt, PROJECT with 6 pt above) and `.fe-node` rows (22 pt + 1 pt gap). Draws only what is
/// visible, so a folder of 2,000 names costs nothing until it scrolls in.
final class TreeListView: FlippedView {
    enum Item: Equatable {
        case section(FileTreeSection, count: Int?, collapsed: Bool)
        case row(FileTreeRow, section: FileTreeSection)
    }

    struct Placed {
        var item: Item
        var frame: CGRect
    }

    static var rowHeight: CGFloat { fz(22) }
    static let rowGap: CGFloat = 1
    static var sectionHeight: CGFloat { fz(26) }
    static var inset: CGFloat { fz(6) }

    var model: FileTreeModelView? { didSet { rebuild() } }
    var onOpen: ((String, Bool) -> Void)?
    var onToggle: ((String) -> Void)?
    var onToggleSection: ((FileTreeSection) -> Void)?
    private(set) var placed: [Placed] = []
    private(set) var contentHeight: CGFloat = 0
    private(set) var hovered: Int?
    private var trackingArea: NSTrackingArea?
    /// The keyboard cursor (D21): the placed item ↑ ↓ move over and ⏎ / space / ← → act on;
    /// outlined in --amber-dim while the list is the first responder.
    private(set) var keyIndex: Int?
    private var rowElements: [TreeItemElement] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("專案檔案樹")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func rebuild() {
        var out: [Placed] = []
        var y: CGFloat = fz(8)
        let width = bounds.width
        func add(_ item: Item, height: CGFloat, gapAfter: CGFloat) {
            out.append(Placed(item: item, frame: CGRect(x: 0, y: y, width: width, height: height)))
            y += height + gapAfter
        }
        guard let model else { placed = []; return }
        if !model.recent.isEmpty {
            add(.section(.recent, count: model.recent.count, collapsed: model.recentCollapsed), height: Self.sectionHeight, gapAfter: Self.rowGap)
            if !model.recentCollapsed {
                for row in model.recent { add(.row(row, section: .recent), height: Self.rowHeight, gapAfter: Self.rowGap) }
            }
            y += fz(6) // `.sbsec` PROJECT: margin-top 6
        }
        add(.section(.project, count: nil, collapsed: model.projectCollapsed), height: Self.sectionHeight, gapAfter: Self.rowGap)
        if !model.projectCollapsed {
            for row in model.rows { add(.row(row, section: .project), height: Self.rowHeight, gapAfter: Self.rowGap) }
        }
        // The keyboard cursor stays on the same item when it is still there (a folder toggled).
        let cursorKey = keyIndex.flatMap { placed.indices.contains($0) ? Self.key(placed[$0].item) : nil }
        placed = out
        keyIndex = cursorKey.flatMap { key in placed.firstIndex { Self.key($0.item) == key } } ?? (keyIndex.map { min($0, placed.count - 1) })
        if keyIndex == -1 { keyIndex = nil }
        rowElements = placed.indices.map { TreeItemElement(list: self, index: $0) }
        contentHeight = y + fz(12)
        hovered = nil
        needsDisplay = true
    }

    /// An item's identity across rebuilds (section or row id).
    private static func key(_ item: Item) -> String {
        switch item {
        case .section(let section, _, _): "section:\(section)"
        case .row(let row, let section): "\(section):\(row.id)"
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged {
            for index in placed.indices { placed[index].frame.size.width = newSize.width }
            needsDisplay = true
        }
    }

    func index(at point: CGPoint) -> Int? {
        placed.firstIndex { $0.frame.minY <= point.y && point.y < $0.frame.maxY }
    }

    /// The frame of the row with `id` (tests, scrolling to the current file).
    func frame(ofRow id: String) -> CGRect? {
        placed.first {
            if case .row(let row, _) = $0.item { return row.id == id }
            return false
        }?.frame
    }

    // MARK: Events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        click(at: convert(event.locationInWindow, from: nil), count: event.clickCount)
    }

    /// A click at `point` (`count` 2 = double click). Internal so tests can click without events.
    func click(at point: CGPoint, count: Int) {
        guard let index = index(at: point) else { return }
        switch placed[index].item {
        case .section(let section, _, _):
            if count == 1 { onToggleSection?(section) }
        case .row(let row, _):
            switch row.kind {
            case .folder:
                if count == 1 { onToggle?(row.id) }
            case .file:
                onOpen?(row.id, count < 2)
            case .overflow:
                break
            }
        }
    }

    // MARK: Keyboard (D21)

    /// A key view while Full Keyboard Access is on (a click keeps the editor's focus as before).
    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: !placed.isEmpty, refuses: false) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        if keyIndex == nil { keyIndex = currentIndex ?? placed.indices.first }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    /// The PROJECT row of the open file.
    private var currentIndex: Int? {
        guard let current = model?.currentID else { return nil }
        return placed.firstIndex {
            if case .row(let row, .project) = $0.item { return row.id == current }
            return false
        }
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// ↑ ↓ move the cursor; ⏎ opens a file (a kept tab) or toggles a folder / section; space opens
    /// a file as a preview; → expands and ← collapses a folder or section. True when handled.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty, !placed.isEmpty else { return false }
        let index = keyIndex ?? 0
        switch event.keyCode {
        case 125, 126:
            let next = min(max(0, index + (event.keyCode == 125 ? 1 : -1)), placed.count - 1)
            moveCursor(to: next)
        case 36, 76:
            activate(index, preview: false)
        case 49:
            activate(index, preview: true)
        case 123, 124:
            let expand = event.keyCode == 124
            switch placed[index].item {
            case .section(let section, _, let collapsed) where collapsed == expand:
                onToggleSection?(section)
            case .row(let row, _):
                if case .folder(let expanded) = row.kind, expanded != expand { onToggle?(row.id) }
            default:
                break
            }
        default:
            return false
        }
        return true
    }

    private func moveCursor(to index: Int) {
        guard placed.indices.contains(index) else { return }
        let old = keyIndex
        keyIndex = index
        if let old, placed.indices.contains(old) { setNeedsDisplay(placed[old].frame) }
        setNeedsDisplay(placed[index].frame)
        scrollToVisible(placed[index].frame)
        NSAccessibility.post(element: rowElements.indices.contains(index) ? rowElements[index] : self, notification: .focusedUIElementChanged)
    }

    /// What a click does, for the keyboard and VoiceOver (`preview` = a single click).
    func activate(_ index: Int, preview: Bool) {
        guard placed.indices.contains(index) else { return }
        switch placed[index].item {
        case .section(let section, _, _):
            onToggleSection?(section)
        case .row(let row, _):
            switch row.kind {
            case .folder: onToggle?(row.id)
            case .file: onOpen?(row.id, preview)
            case .overflow: break
            }
        }
    }

    private var showsKeyCursor: Bool { window?.firstResponder === self }

    // MARK: VoiceOver (D21)

    /// One row element per placed item (sections, folders, files), the open file selected.
    override func accessibilityChildren() -> [Any]? { rowElements }

    func itemLabel(_ index: Int) -> String? {
        guard placed.indices.contains(index) else { return nil }
        switch placed[index].item {
        case .section(let section, let count, let collapsed):
            let title = section == .recent ? "RECENT" : "PROJECT"
            return [title, count.map { "\($0) 個" }, collapsed ? "已收合" : "已展開"].compactMap { $0 }.joined(separator: "，")
        case .row(let row, let section):
            switch row.kind {
            case .overflow(let count):
                return "還有 \(count) 個項目"
            case .folder(let expanded):
                var parts = ["\(row.name)/", "資料夾", expanded ? "已展開" : "已收合"]
                if row.containsChanges { parts.append("含修改") }
                return parts.joined(separator: "，")
            case .file:
                var parts = [row.name]
                if section == .recent, let hint = row.dirHint { parts.append(hint) }
                if row.modified { parts.append("已修改") }
                if row.ai != nil { parts.append("AI 改過") }
                if row.ignored { parts.append("git 忽略") }
                return parts.joined(separator: "，")
            }
        }
    }

    func itemIsSelected(_ index: Int) -> Bool { index == currentIndex }

    func itemFrame(_ index: Int) -> CGRect {
        guard placed.indices.contains(index), let window else { return .zero }
        return window.convertToScreen(convert(placed[index].frame, to: nil))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ index: Int?) {
        guard index != hovered else { return }
        if let old = hovered, placed.indices.contains(old) { setNeedsDisplay(placed[old].frame) }
        hovered = index
        if let index, placed.indices.contains(index) { setNeedsDisplay(placed[index].frame) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(dirtyRect, Palette.bg)
        guard let model else { return }
        for (index, entry) in placed.enumerated() where entry.frame.intersects(dirtyRect) {
            switch entry.item {
            case .section(let section, let count, let collapsed):
                drawSection(section, count: count, collapsed: collapsed, in: entry.frame)
            case .row(let row, let section):
                // Only the PROJECT row of the open file is `.cur` (the artboard's RECENT punch.vue is not).
                drawRow(row, recent: section == .recent, current: section == .project && row.id == model.currentID,
                        hovered: index == hovered, in: entry.frame)
            }
            if index == keyIndex, showsKeyCursor {
                let box = CGRect(x: Self.inset, y: entry.frame.minY, width: entry.frame.width - Self.inset * 2, height: entry.frame.height)
                Draw.strokeRect(box, color: Palette.amberDim)
            }
        }
    }

    private func drawSection(_ section: FileTreeSection, count: Int?, collapsed: Bool, in frame: CGRect) {
        // `.sbsec{padding:8px 8px 4px}`: the text line is centered at 8 + 7.5.
        let centerY = frame.minY + fz(16)
        var x = Self.inset + fz(8)
        Draw.caret(open: !collapsed, at: CGPoint(x: x, y: centerY), color: Palette.dimmer)
        x += fz(10) + fz(6)
        x += Draw.text(TextStyle.caps(10, Palette.dim, tracking: 0.18).string(section == .recent ? "Recent" : "Project"), x: x,
                       centerY: centerY) + fz(6)
        if let count {
            x += Draw.text(TextStyle.mono(10, Palette.amberDim).string("\(count)"), x: x, centerY: centerY) + fz(6)
        }
        let end = frame.maxX - Self.inset - fz(8)
        if end > x + fz(4) {
            Draw.dashedLine(from: CGPoint(x: x + fz(4), y: centerY), to: CGPoint(x: end, y: centerY), color: Palette.line)
        }
    }

    private func drawRow(_ row: FileTreeRow, recent: Bool, current: Bool, hovered: Bool, in frame: CGRect) {
        let box = CGRect(x: Self.inset, y: frame.minY, width: frame.width - Self.inset * 2, height: frame.height)
        if current {
            Draw.fill(box, Palette.bgLift)
            Draw.fill(CGRect(x: box.minX, y: box.minY, width: fz(2), height: box.height), Palette.amber)
        } else if hovered {
            Draw.fill(box, Palette.bgSoft)
        }
        let centerY = box.midY
        var x = box.minX + fz(2) + fz(10) + CGFloat(row.depth) * 14
        let right = box.maxX - fz(8)
        let rowColor: NSColor = row.ignored ? Palette.dimmer : (current || hovered ? Palette.cream : Palette.bone)
        switch row.kind {
        case .overflow(let count):
            Draw.text(TextStyle.mono(11, Palette.dimmer).string("… 還有 \(count) 個項目"), x: x, centerY: centerY, maxWidth: right - x)
        case .folder(let expanded):
            Draw.caret(open: expanded, at: CGPoint(x: x, y: centerY), color: Palette.dimmer)
            x += fz(10) + fz(6)
            let dotSpace: CGFloat = row.containsChanges ? fz(5) + fz(6) : 0
            let name = NSMutableAttributedString(attributedString: TextStyle.mono(12, rowColor).string(row.name))
            name.append(TextStyle.mono(12, Palette.dimmer).string("/"))
            Draw.text(name, x: x, centerY: centerY, maxWidth: right - dotSpace - x)
            if row.containsChanges {
                Draw.fill(CGRect(x: right - fz(5), y: round(centerY - fz(2.5)), width: fz(5), height: fz(5)), Palette.amberDim)
            }
        case .file:
            Draw.text(Parts.extStyle.string(row.ext), x: x, centerY: centerY, maxWidth: fz(28))
            x += fz(28) + fz(6)
            var badges: CGFloat = 0
            if row.modified { badges += fz(10) }
            if row.ai != nil { badges += (badges > 0 ? fz(5) : 0) + Parts.aiChipWidth() }
            let badgeStart = right - badges
            let nameEnd = badges > 0 ? badgeStart - fz(6) : right
            let nameColor: NSColor = row.ignored ? Palette.dimmer
                : (current ? Palette.cream : (row.modified ? FileEditorColors.modifiedName : rowColor))
            let name = TextStyle.mono(12, nameColor).string(row.name)
            let nameWidth = Draw.text(name, x: x, centerY: centerY, maxWidth: max(0, nameEnd - x))
            if recent, let hint = row.dirHint, x + nameWidth + 6 < nameEnd {
                Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(hint), x: x + nameWidth + fz(6), centerY: centerY,
                          maxWidth: nameEnd - (x + nameWidth + fz(6)))
            }
            var bx = badgeStart
            if row.modified { bx += Parts.drawModified(x: bx, centerY: centerY) + fz(5) }
            if let ai = row.ai { Parts.drawAIChip(x: bx, centerY: centerY, color: ai.color) }
        }
    }
}

// MARK: - Foot

/// `.side-foot`: `LOCAL <path>` and the session line (`● ▪ <title>` · `AI 改 2 · 10:41`).
final class TreeFootView: FlippedView {
    var path = "" { didSet { if path != oldValue { needsDisplay = true } } }
    var session: FileTreeSessionLine? { didSet { if session != oldValue { needsDisplay = true; superview?.needsLayout = true } } }

    /// `padding: 8px 12px 10px`, rows 16 pt, gap 6.
    var preferredHeight: CGFloat { session == nil ? fz(8) + fz(16) + fz(10) : fz(8) + fz(16) + fz(6) + fz(16) + fz(10) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.line)
        let left: CGFloat = fz(12)
        let right = bounds.width - fz(12)
        var y: CGFloat = fz(8) + fz(8)
        let local = TextStyle.caps(9.5, Palette.dim, tracking: 0.18).string("Local")
        let localWidth = Draw.text(local, x: left, centerY: y)
        let pathText = TextStyle.mono(11, Palette.dimmer).string(path)
        let available = right - (left + localWidth + fz(8))
        let pathWidth = min(Draw.width(pathText), available)
        Draw.text(pathText, x: right - pathWidth, centerY: y, maxWidth: available)
        guard let session else { return }
        y += fz(16) + fz(6)
        let detail = TextStyle.mono(11, Palette.dim).string(session.detail)
        let detailWidth = Draw.width(detail)
        Draw.text(detail, x: right - detailWidth, centerY: y)
        var x = left
        x += Parts.drawLamp(session.lamp, color: session.lampColor, x: x, centerY: y) + fz(6)
        Parts.drawTag(session.tag, x: x, centerY: y)
        x += fz(8) + fz(6)
        Draw.text(TextStyle.mono(11, Palette.bone).string(session.title), x: x, centerY: y, maxWidth: right - detailWidth - fz(8) - x)
    }
}

/// One tree item as VoiceOver sees it (D21): a row labeled with the name and its badges (modified,
/// AI, folder state), the open file selected; pressing it acts like a click. The list (a main-actor
/// view, Sendable) is read before the isolated closures, which never capture `self`.
final class TreeItemElement: NSAccessibilityElement {
    private weak var list: TreeListView?
    let index: Int

    @MainActor
    init(list: TreeListView, index: Int) {
        self.list = list
        self.index = index
        super.init()
        setAccessibilityParent(list)
        setAccessibilityRole(.row)
    }

    override func accessibilityLabel() -> String? {
        let list = list, index = index
        return MainActor.assumeIsolated { list?.itemLabel(index) }
    }

    override func isAccessibilitySelected() -> Bool {
        let list = list, index = index
        return MainActor.assumeIsolated { list?.itemIsSelected(index) ?? false }
    }

    override func accessibilityFrame() -> NSRect {
        let list = list, index = index
        return MainActor.assumeIsolated { list?.itemFrame(index) ?? .zero }
    }

    override func accessibilityPerformPress() -> Bool {
        let list = list, index = index
        return MainActor.assumeIsolated {
            guard let list else { return false }
            list.activate(index, preview: true)
            return true
        }
    }
}
