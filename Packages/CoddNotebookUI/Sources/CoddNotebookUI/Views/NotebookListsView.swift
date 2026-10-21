import AppKit
import CoddUI

/// The Notebook's lists column (`.nb-lists`, 220 pt): `NOTEBOOK` + `[+ ⌘⇧N]`, the IME-safe search
/// field, the six smart lists, `▸ BY PROJECT`, `▸ LOCAL FILES 最近 n` + `[開啟資料夾…]`, and the
/// footer (`清理建議 [n] →`, the notes path, `● MCP codd · n clients`).
public final class NotebookListsView: NSView {
    public static var preferredWidth: CGFloat { zp(220) }
    static var headHeight: CGFloat { zp(52) }
    static var smartRowHeight: CGFloat { zp(28) }
    static var trashRowHeight: CGFloat { zp(43) }
    static var sectionRowHeight: CGFloat { zp(27) }
    static var projectRowHeight: CGFloat { zp(24) }
    static var fileRowHeight: CGFloat { zp(24) }

    public private(set) var model: NotebookListsModel

    public var onNew: (() -> Void)?
    /// The search text, never while the field has marked text (debouncing is the app's).
    public var onSearch: ((String) -> Void)?
    public var onSelect: ((NotebookListID) -> Void)?
    public var onToggleSection: ((NotebookListsSection, Bool) -> Void)?
    public var onOpenFile: ((String) -> Void)?
    public var onOpenFolder: (() -> Void)?
    public var onOpenCleanup: (() -> Void)?

    let newButton = CoddButton("+ ⌘⇧N", style: .bracket(.accent, small: true))
    let searchField = NotebookTextField(placeholder: "搜尋筆記、#標籤…", prefix: "/", keyCap: "⌘F", accessibilityLabel: "搜尋筆記")
    private let brand = InlineLabel()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private(set) var smartRows: [NotebookSmartList: SmartListRow] = [:]
    private let projectsHeader = SectionHeaderRow(title: "By project")
    private let filesHeader = SectionHeaderRow(title: "Local files")
    private(set) var projectRows: [ProjectRow] = []
    private(set) var fileRows: [FileRow] = []
    let openFolderButton = CoddButton("開啟資料夾…", style: .bracket(.normal, small: true))
    let footer = ListsFooterView()
    private var projectsExpanded: Bool
    private var filesExpanded: Bool

    public init(model: NotebookListsModel) {
        self.model = model
        projectsExpanded = model.projectsExpanded
        filesExpanded = model.filesExpanded
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: zp(900)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("筆記本清單")

        var brandStyle = TextStyle(font: Typeface.display(14), color: Palette.amber, tracking: 0.12)
        brandStyle.shadow = Draw.glow(Palette.amberGlow, radius: 8)
        brand.set([.text("NOTEBOOK", brandStyle)])
        newButton.setAccessibilityLabel("新增筆記 ⌘⇧N")
        newButton.target = self
        newButton.action = #selector(newClicked)
        searchField.onChange = { [weak self] text in self?.onSearch?(text) }
        searchField.text = model.searchText

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = document
        for list in NotebookSmartList.allCases {
            let row = SmartListRow(list: list)
            row.onClick = { [weak self] in self?.select(.smart(list)) }
            smartRows[list] = row
            document.addSubview(row)
        }
        projectsHeader.onClick = { [weak self] in self?.toggle(.byProject) }
        filesHeader.onClick = { [weak self] in self?.toggle(.localFiles) }
        document.addSubview(projectsHeader)
        document.addSubview(filesHeader)
        openFolderButton.target = self
        openFolderButton.action = #selector(openFolderClicked)
        document.addSubview(openFolderButton)
        footer.cleanup.onClick = { [weak self] in self?.onOpenCleanup?() }
        for view in [brand, newButton, searchField, scroll, footer] as [NSView] { addSubview(view) }
        apply(model, force: true)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Applies a new model in place (the field keeps the text being edited).
    public func update(_ model: NotebookListsModel) {
        guard model != self.model else { return }
        apply(model, force: false)
    }

    /// Puts the caret in the search field (⌘F).
    public func focusSearch() { searchField.focus() }

    /// The text in the search field (what the user typed, composing or not).
    public var searchText: String { searchField.text }

    private func apply(_ model: NotebookListsModel, force: Bool) {
        let old = self.model
        self.model = model
        if force || model.projectsExpanded != old.projectsExpanded { projectsExpanded = model.projectsExpanded }
        if force || model.filesExpanded != old.filesExpanded { filesExpanded = model.filesExpanded }
        if !searchField.isEditing, searchField.text != model.searchText { searchField.text = model.searchText }
        for (list, row) in smartRows {
            row.configure(count: model.counts[list], selected: model.selected == .smart(list),
                          hint: list == .trash ? model.trashHint : nil)
        }
        if force || model.projects != old.projects || model.selected != old.selected {
            projectRows.forEach { $0.removeFromSuperview() }
            projectRows = model.projects.map { project in
                let row = ProjectRow(project: project, selected: model.selected == .project(project.id))
                row.onClick = { [weak self] in self?.select(.project(project.id)) }
                document.addSubview(row)
                return row
            }
        }
        if force || model.recentFiles != old.recentFiles || model.filesDisabledReason != old.filesDisabledReason {
            fileRows.forEach { $0.removeFromSuperview() }
            fileRows = model.recentFiles.map { file in
                let row = FileRow(file: file)
                row.isEnabled = model.filesDisabledReason == nil
                row.toolTip = model.filesDisabledReason
                row.onClick = { [weak self] in self?.onOpenFile?(file.id) }
                document.addSubview(row)
                return row
            }
            openFolderButton.isEnabled = model.filesDisabledReason == nil
            openFolderButton.toolTip = model.filesDisabledReason
        }
        projectsHeader.configure(open: projectsExpanded, count: nil)
        filesHeader.configure(open: filesExpanded, count: "最近 \(model.recentFiles.count)")
        footer.configure(model)
        needsLayout = true
    }

    private func select(_ id: NotebookListID) {
        onSelect?(id)
    }

    private func toggle(_ section: NotebookListsSection) {
        switch section {
        case .byProject: projectsExpanded.toggle()
        case .localFiles: filesExpanded.toggle()
        }
        projectsHeader.configure(open: projectsExpanded, count: nil)
        filesHeader.configure(open: filesExpanded, count: "最近 \(model.recentFiles.count)")
        needsLayout = true
        onToggleSection?(section, section == .byProject ? projectsExpanded : filesExpanded)
    }

    @objc private func newClicked() { onNew?() }
    @objc private func openFolderClicked() { onOpenFolder?() }

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
        let brandSize = brand.intrinsicContentSize
        brand.frame = CGRect(x: zp(14), y: round((Self.headHeight - brandSize.height) / 2), width: brandSize.width, height: brandSize.height)
        let newSize = newButton.intrinsicContentSize
        newButton.frame = CGRect(x: width - zp(10) - newSize.width, y: round((Self.headHeight - newSize.height) / 2),
                                 width: newSize.width, height: newSize.height)
        // `.nb-search{padding:8px 8px 4px}` label 26.
        searchField.frame = CGRect(x: zp(8), y: Self.headHeight + zp(8), width: width - zp(16), height: zp(26))
        let footerHeight = footer.preferredHeight
        footer.frame = CGRect(x: 0, y: bounds.height - footerHeight, width: width, height: footerHeight)
        let scrollTop = Self.headHeight + zp(8) + zp(26) + zp(4)
        scroll.frame = CGRect(x: 0, y: scrollTop, width: width, height: max(0, footer.frame.minY - scrollTop))
        // The clip's width: a legacy (always shown) scroller takes its share of the frame. An
        // autohiding legacy scroller appears once the document is taller than the clip, which
        // narrows the clip: lay out again at that width (rows would be cut at the scroller).
        let clipWidth = scroll.contentSize.width
        layoutDocument(width: clipWidth)
        if scroll.contentSize.width != clipWidth { layoutDocument(width: scroll.contentSize.width) }
    }

    /// `.side-scroll{padding:8px 6px 12px;gap:1px}`.
    private func layoutDocument(width: CGFloat) {
        let inner = width - zp(12)
        var y: CGFloat = zp(8) + zp(2) // `.nb-smart{padding:2px 0 4px;gap:1px}`
        for list in NotebookSmartList.allCases {
            guard let row = smartRows[list] else { continue }
            let height = list == .trash ? Self.trashRowHeight : Self.smartRowHeight
            row.frame = CGRect(x: zp(6), y: y, width: inner, height: height)
            y += height + 1
        }
        y += zp(4) - 1 + 1
        projectsHeader.frame = CGRect(x: zp(6), y: y, width: inner, height: Self.sectionRowHeight)
        y += Self.sectionRowHeight + 1
        for row in projectRows {
            row.isHidden = !projectsExpanded
            guard projectsExpanded else { continue }
            row.frame = CGRect(x: zp(6), y: y, width: inner, height: Self.projectRowHeight)
            y += Self.projectRowHeight + 1
        }
        y += zp(6) // `margin-top:6px`
        filesHeader.frame = CGRect(x: zp(6), y: y, width: inner, height: Self.sectionRowHeight)
        y += Self.sectionRowHeight + 1
        for row in fileRows {
            row.isHidden = !filesExpanded
            guard filesExpanded else { continue }
            row.frame = CGRect(x: zp(6), y: y, width: inner, height: Self.fileRowHeight)
            y += Self.fileRowHeight + 1
        }
        openFolderButton.isHidden = !filesExpanded
        if filesExpanded {
            let size = openFolderButton.intrinsicContentSize
            openFolderButton.frame = CGRect(x: zp(6) + zp(12), y: y + zp(6) - 1, width: size.width, height: size.height)
            y = openFolderButton.frame.maxY
        }
        y += zp(12)
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        Draw.dashedLine(from: CGPoint(x: 0, y: Self.headHeight - 1), to: CGPoint(x: bounds.width - 1, y: Self.headHeight - 1),
                        color: Palette.line)
    }

    // MARK: Test access

    func smartRow(_ list: NotebookSmartList) -> SmartListRow? { smartRows[list] }
    var visibleTexts: [String] { notebookVisibleTexts() }
}

// MARK: - Rows

/// `.nb-li` (28 pt; TRASH `.two` with its hint line).
final class SmartListRow: HoverControl, NotebookTextProviding {
    let list: NotebookSmartList
    private(set) var count: Int?
    private(set) var isSelected = false
    private var hint: String?

    init(list: NotebookSmartList) {
        self.list = list
        super.init(frame: .zero)
        steppedByArrows = true
        setAccessibilityLabel(list.title.uppercased())
    }

    func configure(count: Int?, selected: Bool, hint: String?) {
        guard count != self.count || selected != isSelected || hint != self.hint else { return }
        self.count = count
        isSelected = selected
        self.hint = hint
        setAccessibilityValue(count.map(String.init))
        setAccessibilityHelp(hint)
        setAccessibilitySelected(selected)
        needsDisplay = true
    }

    var drawnTexts: [String] {
        var texts = [list.title.uppercased()]
        if let hint { texts.append(hint) }
        if let count { texts.append(String(count)) }
        return texts
    }

    override func draw(_ dirtyRect: NSRect) {
        let on = isSelected
        if on {
            Draw.fill(bounds, Palette.bgLift)
            Draw.fill(CGRect(x: 0, y: 0, width: zp(2), height: bounds.height), Palette.amber)
        } else if isHot {
            Draw.fill(bounds, Palette.bgSoft)
        }
        let two = hint != nil
        let textColor = on ? Palette.amber : (isHot ? Palette.cream : Palette.bone)
        let iconColor = on ? Palette.amber : Palette.dim
        let lineCenter = two ? zp(5) + zp(8) : bounds.midY
        let iconRect = CGRect(x: zp(12), y: round(lineCenter - zp(7) + (two ? 1 : 0)), width: zp(14), height: zp(14))
        if list == .prompts {
            let glyph = TextStyle.mono(12, iconColor).string("❯")
            Draw.text(glyph, x: iconRect.midX - Draw.width(glyph) / 2, centerY: iconRect.midY)
        } else {
            NotebookIconRenderer.draw(icon, in: iconRect, color: iconColor)
        }
        var label = TextStyle.caps(11, textColor, tracking: 0.14)
        if on { label.shadow = Draw.glow(Palette.amberGlow, radius: 6) }
        let labelX = iconRect.maxX + zp(9)
        var countWidth: CGFloat = 0
        if let count {
            let color = on ? Palette.amber : (list == .stale ? Palette.amberDim : Palette.dim)
            let text = TextStyle.mono(10.5, color).string(String(count))
            countWidth = Draw.width(text)
            Draw.text(text, x: bounds.width - zp(8) - countWidth, centerY: lineCenter)
        }
        Draw.text(label.string(list.title), x: labelX, centerY: lineCenter, maxWidth: bounds.width - zp(8) - countWidth - zp(6) - labelX)
        if let hint {
            Draw.text(TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02).string(hint), x: labelX, centerY: zp(5) + zp(16.5) + 1 + zp(8),
                      maxWidth: bounds.width - zp(8) - labelX)
        }
    }

    private var icon: NotebookIcon {
        switch list {
        case .inbox: .inbox
        case .pinned: .star
        case .prompts: .inbox
        case .stale: .clock
        case .archive: .archive
        case .trash: .trash
        }
    }
}

/// `.sbsec` (`▸ BY PROJECT ────`, `▸ LOCAL FILES 最近 4 ──`), a toggle.
final class SectionHeaderRow: HoverControl, NotebookTextProviding {
    let title: String
    private(set) var isOpen = true
    private var count: String?

    init(title: String) {
        self.title = title
        super.init(frame: .zero)
        steppedByArrows = true
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(title.uppercased())
    }

    func configure(open: Bool, count: String?) {
        guard open != isOpen || count != self.count else { return }
        isOpen = open
        self.count = count
        setAccessibilityExpanded(open)
        setAccessibilityValue(open ? 1 : 0)
        setAccessibilityLabel([title.uppercased(), count].compactMap { $0 }.joined(separator: " "))
        needsDisplay = true
    }

    var drawnTexts: [String] { [title.uppercased()] + (count.map { [$0] } ?? []) }

    override func draw(_ dirtyRect: NSRect) {
        // padding 8 8 4; line box 15.
        let centerY = zp(8) + zp(7.5)
        Draw.caret(open: isOpen, at: CGPoint(x: zp(8), y: centerY), color: Palette.dimmer)
        var x: CGFloat = zp(8) + zp(10) + zp(6)
        let titleText = TextStyle.caps(10, isHot ? Palette.cream : Palette.dim, tracking: 0.18).string(title)
        x += Draw.text(titleText, x: x, centerY: centerY)
        if let count {
            x += zp(6)
            x += Draw.text(TextStyle.mono(10, Palette.amberDim).string(count), x: x, centerY: centerY)
        }
        Draw.dashedLine(from: CGPoint(x: x + zp(6) + zp(4), y: round(centerY)), to: CGPoint(x: bounds.width - zp(8), y: round(centerY)), color: Palette.line)
    }
}

/// `.nb-pj`: `■ orb-toolkit-frontend  2`.
final class ProjectRow: HoverControl, NotebookTextProviding {
    let project: NotebookProjectRow
    let isSelected: Bool

    init(project: NotebookProjectRow, selected: Bool) {
        self.project = project
        isSelected = selected
        super.init(frame: .zero)
        steppedByArrows = true
        setAccessibilityLabel(project.name)
        setAccessibilityValue(String(project.count))
        setAccessibilitySelected(selected)
    }

    var drawnTexts: [String] { [project.name, String(project.count)] }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            Draw.fill(bounds, Palette.bgLift)
            Draw.fill(CGRect(x: 0, y: 0, width: zp(2), height: bounds.height), Palette.amber)
        } else if isHot {
            Draw.fill(bounds, Palette.bgSoft)
        }
        let pieces: [InlinePiece] = [
            .tag(project.tag),
            .text(project.name, TextStyle.mono(11.5, isSelected ? Palette.amber : (isHot ? Palette.cream : Palette.bone)), shrink: true),
            .flex,
            .text(String(project.count), TextStyle.mono(10.5, Palette.dimmer)),
        ]
        let rect = CGRect(x: zp(14), y: 0, width: bounds.width - zp(14) - zp(8), height: bounds.height)
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: rect, gap: 8))
    }
}

/// `.nb-fr`: file icon, name, dim root.
final class FileRow: HoverControl, NotebookTextProviding {
    let file: NotebookFileRow

    init(file: NotebookFileRow) {
        self.file = file
        super.init(frame: .zero)
        steppedByArrows = true
        setAccessibilityLabel("\(file.name)，\(file.rootHint)")
        setAccessibilityHelp(file.id)
    }

    var drawnTexts: [String] { [file.name, file.rootHint] }

    override func draw(_ dirtyRect: NSRect) {
        if isHot { Draw.fill(bounds, Palette.bgSoft) }
        let pieces: [InlinePiece] = [
            .icon(.file, size: 13, color: Palette.dim),
            .text(file.name, TextStyle.mono(11.5, isHot ? Palette.cream : Palette.bone), shrink: true),
            .flex,
            .text(file.rootHint, TextStyle.mono(10.5, Palette.dimmer)),
        ]
        let rect = CGRect(x: zp(12), y: 0, width: bounds.width - zp(12) - zp(8), height: bounds.height)
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: rect, gap: 7))
    }
}

/// `.side-foot` of the lists column.
final class ListsFooterView: CanvasView, NotebookTextProviding {
    let cleanup = DrawnControl()
    private var model: NotebookListsModel?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(cleanup)
        cleanup.drawer = { [weak self] control, rect in self?.drawCleanup(control, rect) }
    }

    func configure(_ model: NotebookListsModel) {
        self.model = model
        cleanup.isHidden = model.cleanupCount == nil
        cleanup.texts = model.cleanupCount.map { ["清理建議", String($0), "→"] } ?? []
        cleanup.needsDisplay = true
        setAccessibilityLabel(drawnTexts.joined(separator: " "))
        needsLayout = true
        needsDisplay = true
    }

    /// `padding: 8 12 10; gap 6`: cleanup line (16.5 + 6 + 1) and two 15.75 rows.
    var preferredHeight: CGFloat {
        let rows: CGFloat = zp(16) + zp(6) + zp(16)
        return zp(8) + (model?.cleanupCount == nil ? 0 : zp(24) + zp(6)) + rows + zp(10)
    }

    var drawnTexts: [String] {
        guard let model else { return [] }
        return [model.notesPath, "● MCP \(model.mcp.serverName)", model.mcp.clients]
    }

    override func layout() {
        super.layout()
        cleanup.frame = CGRect(x: zp(12), y: zp(8), width: bounds.width - zp(24), height: zp(24))
    }

    private func drawCleanup(_ control: DrawnControl, _ rect: CGRect) {
        guard let count = model?.cleanupCount else { return }
        let color = control.isHot ? Palette.amber : Palette.bone
        let badge = NotebookChip(text: String(count), style: TextStyle.mono(10, Palette.bone, .bold), fill: Palette.lineBright, height: 15,
                                 padding: 3)
        let pieces: [InlinePiece] = [.text("清理建議", TextStyle.mono(11, color)), .chip(badge), .flex,
                                     .text("→", TextStyle.mono(11, control.isHot ? Palette.amber : Palette.dimmer))]
        let line = CGRect(x: 0, y: 0, width: rect.width, height: zp(17))
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: line, gap: 7))
        Draw.dashedLine(from: CGPoint(x: 0, y: rect.height - 1), to: CGPoint(x: rect.width, y: rect.height - 1), color: Palette.line)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.dashedLine(from: CGPoint(x: 0, y: 0), to: CGPoint(x: bounds.width, y: 0), color: Palette.line)
        guard let model else { return }
        var y: CGFloat = zp(8) + (model.cleanupCount == nil ? 0 : zp(24) + zp(6))
        let rowHeight: CGFloat = zp(16)
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(model.notesPath, lineBreak: .byTruncatingMiddle), x: zp(12), centerY: y + rowHeight / 2,
                  maxWidth: bounds.width - zp(24))
        y += rowHeight + zp(6)
        let lampColor = model.mcp.running ? NotebookSessionState.busy : NotebookSessionState.stopped
        let pieces: [InlinePiece] = [
            .lamp(lampColor, size: 9),
            .text("MCP", TextStyle.mono(10.5, Palette.dim), gapBefore: 4),
            .text(model.mcp.serverName, TextStyle.mono(10.5, Palette.dimmer), gapBefore: 4),
            .flex,
            .text(model.mcp.clients, TextStyle.mono(10.5, Palette.dim)),
        ]
        let line = CGRect(x: zp(12), y: y, width: bounds.width - zp(24), height: rowHeight)
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: line, gap: 6))
    }
}
