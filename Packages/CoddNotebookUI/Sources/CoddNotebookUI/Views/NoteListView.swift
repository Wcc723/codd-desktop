import AppKit
import CoddUI

/// The note list (`.nb-notes`, 300 pt): head (`INBOX` `.h-sub` + count + `最近更新 ▾`), day
/// separators, `.nb-nrow` rows (title, time, a 2-line snippet, kind / session / project chips,
/// extra text, warnings, the AI glyph), the end comment and the empty state. Search results are
/// rows with highlighted ranges. Click selects, double click opens, right click shows the row's
/// context menu, ↑ ↓ ⏎ work while the list is first responder.
public final class NoteListView: NSView {
    public static var preferredWidth: CGFloat { zp(300) }
    static var headHeight: CGFloat { zp(52) }
    static var daySeparatorHeight: CGFloat { zp(26) }
    static var endCommentHeight: CGFloat { zp(46) }

    public private(set) var model: NoteListModel
    /// The selected row id (set locally on click, then confirmed by the next model).
    public private(set) var selectedID: String?

    public var onSelect: ((String) -> Void)?
    public var onOpen: ((String) -> Void)?
    public var onSort: ((NoteListSort) -> Void)?
    /// Row id, action id.
    public var onRowAction: ((String, String) -> Void)?
    public var menuPresenter: NotebookMenuPresenting = PopoverMenuPresenter()

    private let titleLabel = InlineLabel()
    let sortButton = PlainSmallButton("最近更新 ▾")
    private let scroll = NSScrollView()
    private let document = ListDocumentView()
    private(set) var rowViews: [NoteListRowView] = []
    private var dayViews: [DaySeparatorView] = []
    private let endComment = InlineLabel()
    private let emptyLabel = InlineLabel()
    private(set) var sortMenu: NotebookMenuView?

    public init(model: NoteListModel) {
        self.model = model
        selectedID = model.selectedID
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: zp(900)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        sortButton.onClick = { [weak self] in self?.openSortMenu() }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.owner = self
        endComment.alignment = .center
        emptyLabel.alignment = .center
        document.addSubview(endComment)
        document.addSubview(emptyLabel)
        for view in [titleLabel, sortButton, scroll] as [NSView] { addSubview(view) }
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public func update(_ model: NoteListModel) {
        guard model != self.model else { return }
        let old = self.model
        self.model = model
        selectedID = model.selectedID
        if old.sections == model.sections, old.endComment == model.endComment, old.emptyText == model.emptyText,
           old.rowActions == model.rowActions {
            rowViews.forEach { $0.isSelected = $0.row.id == selectedID }
            configureHead()
        } else {
            rebuild()
        }
    }

    private func configureHead() {
        setAccessibilityLabel("\(model.title.uppercased()) 筆記列表")
        titleLabel.set([
            .text(model.title, TextStyle.subTitle),
            .text(model.count, TextStyle.mono(11, Palette.dimmer), gapBefore: 8),
        ])
        sortButton.label = "\(model.sort.title) ▾"
        sortButton.isHidden = !model.showsSort
        needsLayout = true
    }

    private func rebuild() {
        configureHead()
        rowViews.forEach { $0.removeFromSuperview() }
        dayViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        dayViews = []
        for section in model.sections where !section.rows.isEmpty {
            if let day = section.day {
                let view = DaySeparatorView(day: day)
                dayViews.append(view)
                document.addSubview(view)
            }
            for row in section.rows {
                let view = NoteListRowView(row: row, actions: row.actions ?? model.rowActions)
                view.isSelected = row.id == selectedID
                view.onClick = { [weak self] in
                    guard let self else { return }
                    self.window?.makeFirstResponder(self)
                    self.select(row.id)
                }
                view.onDoubleClick = { [weak self] in self?.onOpen?(row.id) }
                view.onAction = { [weak self] action in self?.onRowAction?(row.id, action) }
                rowViews.append(view)
                document.addSubview(view)
            }
        }
        endComment.set(model.endComment.map { [.text($0, TextStyle.comment)] } ?? [])
        endComment.isHidden = model.endComment == nil || rowViews.isEmpty
        emptyLabel.set([.text(model.emptyText, TextStyle.comment)])
        emptyLabel.isHidden = !rowViews.isEmpty
        needsLayout = true
    }

    /// Selects `id` and reports it.
    public func select(_ id: String) {
        selectedID = id
        rowViews.forEach { $0.isSelected = $0.row.id == id }
        if let view = rowViews.first(where: { $0.row.id == id }) { document.scrollToVisible(view.frame) }
        onSelect?(id)
    }

    // MARK: Layout

    /// A new width (window resize, a column folding, zoom) lays the hand-placed rows out again:
    /// AppKit does not always ask a frame-laid view for layout when only its frame changed.
    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { needsLayout = true }
    }

    public override func layout() {
        super.layout()
        let width = bounds.width
        let titleSize = titleLabel.intrinsicContentSize
        titleLabel.frame = CGRect(x: zp(14), y: round((Self.headHeight - titleSize.height) / 2), width: min(titleSize.width, width - zp(120)),
                                  height: titleSize.height)
        let sortSize = sortButton.intrinsicContentSize
        sortButton.frame = CGRect(x: width - zp(8) - sortSize.width, y: round((Self.headHeight - sortSize.height) / 2), width: sortSize.width,
                                  height: sortSize.height)
        scroll.frame = CGRect(x: 0, y: Self.headHeight, width: width - 1, height: max(0, bounds.height - Self.headHeight))
        // The clip's width: a legacy (always shown) scroller takes its share of the frame. An
        // autohiding legacy scroller appears once the document is taller than the clip, which
        // narrows the clip: lay out again at that width (rows would be cut at the scroller).
        let clipWidth = scroll.contentSize.width
        layoutDocument(width: clipWidth)
        if scroll.contentSize.width != clipWidth { layoutDocument(width: scroll.contentSize.width) }
    }

    private func layoutDocument(width: CGFloat) {
        var y: CGFloat = 0
        var rowIndex = 0
        var dayIndex = 0
        for section in model.sections where !section.rows.isEmpty {
            if section.day != nil, dayIndex < dayViews.count {
                dayViews[dayIndex].frame = CGRect(x: 0, y: y, width: width, height: Self.daySeparatorHeight)
                y += Self.daySeparatorHeight
                dayIndex += 1
            }
            for _ in section.rows where rowIndex < rowViews.count {
                let view = rowViews[rowIndex]
                let height = view.height(for: width)
                view.frame = CGRect(x: 0, y: y, width: width, height: height)
                y += height
                rowIndex += 1
            }
        }
        if !endComment.isHidden {
            endComment.frame = CGRect(x: zp(14), y: y + zp(14), width: width - zp(28), height: zp(18))
            y += Self.endCommentHeight
        }
        if !emptyLabel.isHidden {
            emptyLabel.frame = CGRect(x: zp(14), y: zp(24), width: width - zp(28), height: zp(18))
            y = max(y, 66)
        }
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        Draw.dashedLine(from: CGPoint(x: 0, y: Self.headHeight - 1), to: CGPoint(x: bounds.width - 1, y: Self.headHeight - 1), color: Palette.line)
    }

    // MARK: Sort menu

    /// The sort menu's model (current order checked).
    public var sortMenuModel: NotebookMenuModel {
        NotebookMenuModel(entries: NoteListSort.allCases.map { sort in
            .item(NotebookMenuItem(id: sort.rawValue, title: sort.title, isChecked: sort == model.sort))
        }, width: 220, initialHighlight: model.sort.rawValue)
    }

    func openSortMenu() {
        if sortMenu != nil { menuPresenter.dismiss(); return }
        let menu = NotebookMenuView(model: sortMenuModel)
        menu.onActivate = { [weak self] item in
            guard let self else { return }
            self.menuPresenter.dismiss()
            if let sort = NoteListSort(rawValue: item.id) { self.onSort?(sort) }
        }
        menu.onDismiss = { [weak self] in self?.menuPresenter.dismiss() }
        sortMenu = menu
        sortButton.isOn = true
        let origin = CGPoint(x: sortButton.frame.maxX - menu.preferredSize.width, y: sortButton.frame.maxY + zp(4))
        menuPresenter.present(menu, at: origin, in: self) { [weak self] in
            self?.sortMenu = nil
            self?.sortButton.isOn = false
        }
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// ↑ ↓ move the selection, ⏎ opens it.
    @discardableResult
    public func handleKey(_ event: NSEvent) -> Bool {
        let ids = rowViews.map(\.row.id)
        guard !ids.isEmpty else { return false }
        let index = selectedID.flatMap { ids.firstIndex(of: $0) }
        switch event.keyCode {
        case 125: select(ids[min(ids.count - 1, (index ?? -1) + 1)])
        case 126: select(ids[max(0, (index ?? ids.count) - 1)])
        case 36, 76:
            guard let selectedID else { return false }
            onOpen?(selectedID)
        default: return false
        }
        return true
    }

    // MARK: Test access

    func rowView(_ id: String) -> NoteListRowView? { rowViews.first { $0.row.id == id } }
    var visibleTexts: [String] { notebookVisibleTexts() }
    var isShowingEmptyState: Bool { !emptyLabel.isHidden }
}

/// The scroll document; clicks on empty space give the list the focus.
final class ListDocumentView: FlippedView {
    weak var owner: NoteListView?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(owner)
    }
}

/// `.nb-day`: `TODAY · 10/15 ────`.
final class DaySeparatorView: CanvasView, NotebookTextProviding {
    let day: String

    init(day: String) {
        self.day = day
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(day)
    }

    var drawnTexts: [String] { [day.uppercased()] }

    override func draw(_ dirtyRect: NSRect) {
        // padding 8 14 4, 9.5 caps .2em dim, then a dashed rule.
        let centerY: CGFloat = zp(8) + zp(7)
        let width = Draw.text(TextStyle.caps(9.5, Palette.dim, tracking: 0.2).string(day), x: zp(14), centerY: centerY)
        Draw.dashedLine(from: CGPoint(x: zp(14) + width + zp(8), y: round(centerY)), to: CGPoint(x: bounds.width - zp(14), y: round(centerY)),
                        color: Palette.line)
    }
}

/// One `.nb-nrow`.
final class NoteListRowView: HoverControl, NotebookTextProviding {
    let row: NoteListRow
    let actions: [NoteRowAction]
    var isSelected = false { didSet { if isSelected != oldValue { needsDisplay = true; setAccessibilitySelected(isSelected) } } }
    var onDoubleClick: (() -> Void)?
    var onAction: ((String) -> Void)?

    /// CSS line boxes: `.tt` 12.5 × 1.5, `.sn` 11.5 × 1.55 (two lines clamp), `.nb-xs` chips 17.
    static var titleLineHeight: CGFloat { zp(18.75) }
    static var snippetLineHeight: CGFloat { zp(17.825) }
    static var chipsLineHeight: CGFloat { zp(17) }

    init(row: NoteListRow, actions: [NoteRowAction]) {
        self.row = row
        self.actions = actions
        super.init(frame: .zero)
        // The list keeps the keyboard focus (↑ ↓ ⏎), so a row is never a key view of its own.
        takesKeyboardFocus = false
        setAccessibilityRole(.row)
        setAccessibilityLabel(Self.accessibilityText(row))
        setAccessibilityValue(row.snippet)
    }

    /// The row as one element (D21): title, time, the chips line and the AI access, the snippet
    /// is the value.
    static func accessibilityText(_ row: NoteListRow) -> String {
        var parts = [row.pinned ? "已釘選 \(row.title)" : row.title, row.time, row.kind.text.uppercased()]
        switch row.link {
        case .session(let title, _): parts.append("session \(title)")
        case .project(let name, _): parts.append("專案 \(name)")
        case nil: break
        }
        if let extra = row.extra { parts.append(extra) }
        parts += row.warnings
        parts.append("AI \(row.ai.label)")
        return parts.filter { !$0.isEmpty }.joined(separator: "，")
    }

    /// The row's height: `padding 9 / 10`, the title line, gap 5, the snippet (1–2 lines), gap 5,
    /// chips 17, the 1 px dashed bottom border; rounded (101 pt with a 2-line snippet).
    func height(for width: CGFloat) -> CGFloat {
        let lines = snippetLines(width: width)
        return round(zp(9) + Self.titleLineHeight + (lines > 0 ? zp(5) + CGFloat(lines) * Self.snippetLineHeight : 0) + zp(5) + Self.chipsLineHeight
                     + zp(10) + 1)
    }

    private var contentInsetLeft: CGFloat { zp(2) + zp(14) }
    private func contentWidth(_ width: CGFloat) -> CGFloat { width - contentInsetLeft - zp(12) }

    private var snippetString: NSAttributedString {
        let style = TextStyle.mono(11.5, Palette.dim)
        let text = NotebookDraw.highlighted(row.snippet, style: style, ranges: row.snippetHighlights, lineBreak: .byWordWrapping)
        let out = NSMutableAttributedString(attributedString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        paragraph.minimumLineHeight = Self.snippetLineHeight
        paragraph.maximumLineHeight = Self.snippetLineHeight
        out.addAttributes([.paragraphStyle: paragraph, .baselineOffset: max(0, (Self.snippetLineHeight - Typeface.lineHeight(style.font)) / 2)],
                          range: NSRange(location: 0, length: out.length))
        return out
    }

    func snippetLines(width: CGFloat) -> Int {
        guard !row.snippet.isEmpty else { return 0 }
        let rect = snippetString.boundingRect(with: CGSize(width: contentWidth(width), height: .greatestFiniteMagnitude),
                                              options: [.usesLineFragmentOrigin])
        let lines = Int((ceil(rect.height) + Self.snippetLineHeight / 2) / Self.snippetLineHeight)
        return min(2, max(1, lines))
    }

    var drawnTexts: [String] {
        var texts = [row.title, row.time]
        if !row.snippet.isEmpty { texts.append(row.snippet) }
        texts.append(row.kind.text.uppercased())
        switch row.link {
        case .session(let title, _): texts.append(title)
        case .project(let name, _): texts.append(name)
        case nil: break
        }
        if let extra = row.extra { texts.append(extra) }
        texts.append(contentsOf: row.warnings)
        texts.append(row.ai.label)
        return texts
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu()
    }

    /// The row's context menu (native: right click is the standard path).
    func contextMenu() -> NSMenu? {
        guard !actions.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in actions {
            let item = ClosureMenuItem(title: action.title) { [weak self] in self?.onAction?(action.id) }
            item.isEnabled = action.isEnabled
            if action.isDestructive {
                item.attributedTitle = NSAttributedString(string: action.title, attributes: [.foregroundColor: Palette.danger])
            }
            menu.addItem(item)
        }
        return menu
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Draw.fill(bounds, Palette.bgLift)
            Draw.fill(CGRect(x: 0, y: 0, width: zp(2), height: bounds.height), Palette.amber)
        } else if isHot {
            Draw.fill(bounds, Palette.bgSoft)
        }
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.line)
        if row.stale { NSGraphicsContext.current?.cgContext.setAlpha(0.6) }
        let x = contentInsetLeft
        let width = contentWidth(bounds.width)
        // Title line.
        var title: [InlinePiece] = []
        if row.pinned { title.append(.icon(.star, size: 12, color: Palette.amber, filled: true)) }
        let titleColor = isSelected ? Palette.amber : (row.stale ? Palette.dim : Palette.cream)
        title.append(.text(NotebookDraw.highlighted(row.title, style: TextStyle.mono(12.5, titleColor), ranges: row.titleHighlights),
                           shrink: true))
        title.append(.flex)
        title.append(.text(row.time, TextStyle.mono(10.5, isSelected ? Palette.dim : Palette.dimmer)))
        let titleRect = CGRect(x: x, y: zp(9), width: width, height: Self.titleLineHeight)
        InlineLayout.draw(title, InlineLayout.layout(title, in: titleRect, gap: 6))
        // Snippet.
        var y = titleRect.maxY
        let lines = snippetLines(width: bounds.width)
        if lines > 0 {
            y += zp(5)
            let rect = CGRect(x: x, y: y, width: width, height: CGFloat(lines) * Self.snippetLineHeight)
            snippetString.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            y = rect.maxY
        }
        // Chips line.
        y += zp(5)
        var chips: [InlinePiece] = [.chip(.kind(row.kind))]
        switch row.link {
        case .session(let title, let state):
            chips.append(.chip(.xs(title, lead: .lamp(state, size: 9))))
        case .project(let name, let tag):
            chips.append(.chip(.xs(name, lead: .tag(tag, size: 8))))
        case nil:
            break
        }
        if let extra = row.extra { chips.append(.text(extra, TextStyle.mono(10.5, Palette.dimmer), shrink: true)) }
        for warning in row.warnings {
            chips.append(.chip(.xs(warning, color: Palette.danger, border: Palette.danger.withAlphaComponent(0.45))))
        }
        chips.append(.flex)
        let aiColor = row.ai == .off ? Palette.dimmer : Palette.dim
        chips.append(.icon(row.ai.icon, size: 13, color: aiColor))
        chips.append(.text(row.ai.label, TextStyle.mono(10.5, aiColor, tracking: 0.08), gapBefore: 4))
        let chipsRect = CGRect(x: x, y: y, width: width, height: Self.chipsLineHeight)
        InlineLayout.draw(chips, InlineLayout.layout(chips, in: chipsRect, gap: 5))
    }
}
