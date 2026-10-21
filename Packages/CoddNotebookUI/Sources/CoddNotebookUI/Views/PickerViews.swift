import AppKit
import CoddUI

/// The `+ 連結 session / 專案` picker (popover content): an IME-safe search field over a list of
/// live sessions (lamp, title, project dim) and projects (tag square, name); linked targets
/// carry `✓`. Typing filters (never while the field has marked text), ↑ ↓ move, ⏎ picks, ⎋
/// cancels; a click picks.
public final class LinkPickerView: NSView {
    public static var preferredWidth: CGFloat { zp(340) }
    static var maxListHeight: CGFloat { zp(320) }

    public private(set) var model: LinkPickerModel
    public var onPick: ((NotebookLink) -> Void)?
    public var onCancel: (() -> Void)?
    /// The size changed (the list was filtered); a presenter resizes its panel.
    public var onSizeChange: ((NSSize) -> Void)?

    let searchField = NotebookTextField(placeholder: "搜尋 session 或專案…", fontSize: 12, accessibilityLabel: "搜尋 session 或專案")
    let list: NotebookMenuView
    private let listScroll = NSScrollView()
    public private(set) var query = ""

    public init(model: LinkPickerModel) {
        self.model = model
        list = NotebookMenuView(model: NotebookMenuModel(entries: []))
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: zp(200)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("連結 session / 專案")
        list.drawsFrame = false
        list.onActivate = { [weak self] item in self?.pick(item.id) }
        list.onDismiss = { [weak self] in self?.onCancel?() }
        searchField.onChange = { [weak self] text in self?.filter(text) }
        searchField.onMove = { [weak self] delta in self?.list.moveHighlight(by: delta) }
        searchField.onSubmit = { [weak self] _ in self?.list.activateHighlighted() }
        searchField.onCancel = { [weak self] in
            self?.onCancel?()
            return true
        }
        listScroll.drawsBackground = false
        listScroll.hasVerticalScroller = true
        listScroll.scrollerStyle = .overlay
        listScroll.borderType = .noBorder
        listScroll.documentView = list
        addSubview(searchField)
        addSubview(listScroll)
        rebuildList()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: LinkPickerModel) {
        guard model != self.model else { return }
        self.model = model
        rebuildList()
    }

    /// Puts the caret in the search field.
    public func focus() { searchField.focus() }

    private func filter(_ text: String) {
        query = text
        rebuildList()
    }

    private static func matches(_ text: String, _ query: String) -> Bool {
        query.isEmpty || text.range(of: query, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]) != nil
    }

    /// The list's model for the current query.
    public var listModel: NotebookMenuModel {
        let q = query.trimmingCharacters(in: .whitespaces)
        let sessions = model.sessions.filter { Self.matches($0.title, q) || Self.matches($0.project, q) }
        let projects = model.projects.filter { Self.matches($0.name, q) }
        var entries: [NotebookMenuEntry] = []
        if !sessions.isEmpty {
            entries.append(.header("Sessions", trailing: String(sessions.count)))
            entries += sessions.map { session in
                .item(NotebookMenuItem(id: "session:\(session.id)", glyph: .lamp(session.state), title: session.title, detail: session.project,
                                       isChecked: model.linked.contains(.session(id: session.id))))
            }
        }
        if !projects.isEmpty {
            entries.append(.header("Projects", trailing: String(projects.count)))
            entries += projects.map { project in
                .item(NotebookMenuItem(id: "project:\(project.id)", glyph: .tag(project.tag), title: project.name,
                                       isChecked: model.linked.contains(.project(id: project.id))))
            }
        }
        if entries.isEmpty {
            entries.append(.item(NotebookMenuItem(id: "none", title: NotebookCopy.noMatchEmpty, tone: .dim, isEnabled: false)))
        }
        return NotebookMenuModel(entries: entries, width: Self.preferredWidth - zp(2))
    }

    private func rebuildList() {
        list.update(listModel)
        needsLayout = true
        onSizeChange?(preferredSize)
    }

    private func pick(_ id: String) {
        if id.hasPrefix("session:") {
            onPick?(.session(id: String(id.dropFirst("session:".count))))
        } else if id.hasPrefix("project:") {
            onPick?(.project(id: String(id.dropFirst("project:".count))))
        }
    }

    public var preferredSize: NSSize {
        NSSize(width: Self.preferredWidth, height: 1 + zp(8) + zp(30) + zp(4) + min(Self.maxListHeight, list.preferredSize.height) + 1)
    }

    public override var intrinsicContentSize: NSSize { preferredSize }

    public override func layout() {
        super.layout()
        searchField.frame = CGRect(x: 1 + zp(8), y: 1 + zp(8), width: bounds.width - zp(2) - zp(16), height: zp(30))
        let listSize = list.preferredSize
        listScroll.frame = CGRect(x: 1, y: searchField.frame.maxY + zp(4), width: bounds.width - zp(2),
                                  height: max(0, bounds.height - searchField.frame.maxY - zp(4) - 1))
        list.frame = CGRect(origin: .zero, size: CGSize(width: listScroll.contentSize.width, height: listSize.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgLift)
        Draw.strokeRect(bounds, color: Palette.amberDim)
    }

    var visibleTexts: [String] { notebookVisibleTexts() }
}

/// The tag editor (popover content): `TAGS · 標籤`, the note's tags as removable chips, an
/// IME-safe field (⏎ adds its text, or the highlighted suggestion when it is empty; never while
/// composing), and the existing tags that match as suggestions.
public final class TagEditorView: NSView {
    public static var preferredWidth: CGFloat { zp(300) }

    public private(set) var model: TagEditorModel
    public var onAdd: ((String) -> Void)?
    public var onRemove: ((String) -> Void)?
    public var onDone: (() -> Void)?
    public var onSizeChange: ((NSSize) -> Void)?

    let field = NotebookTextField(placeholder: "新增標籤…", prefix: "#", fontSize: 12, accessibilityLabel: "新增標籤")
    let suggestions: NotebookMenuView
    private(set) var tagChips: [ChipControl] = []
    private let header = InlineLabel()
    public private(set) var query = ""

    public init(model: TagEditorModel) {
        self.model = model
        suggestions = NotebookMenuView(model: NotebookMenuModel(entries: []))
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: zp(200)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("標籤")
        header.set([.text("Tags · 標籤", MenuRowView.headerStyle())])
        suggestions.drawsFrame = false
        suggestions.onActivate = { [weak self] item in self?.add(String(item.id.dropFirst("tag:".count))) }
        suggestions.onDismiss = { [weak self] in self?.onDone?() }
        field.onChange = { [weak self] text in
            self?.query = text
            self?.rebuild()
        }
        field.onMove = { [weak self] delta in self?.suggestions.moveHighlight(by: delta) }
        field.onSubmit = { [weak self] text in
            guard let self else { return }
            let tag = Self.clean(text)
            if !tag.isEmpty { self.add(tag) } else { self.suggestions.activateHighlighted() }
        }
        field.onCancel = { [weak self] in
            self?.onDone?()
            return true
        }
        addSubview(header)
        addSubview(field)
        addSubview(suggestions)
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: TagEditorModel) {
        guard model != self.model else { return }
        self.model = model
        rebuild()
    }

    public func focus() { field.focus() }

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .replacingOccurrences(of: " ", with: "-")
    }

    private func add(_ tag: String) {
        guard !tag.isEmpty else { return }
        onAdd?(tag)
        field.text = ""
        query = ""
        rebuild()
    }

    /// The suggestions for the current text (existing tags not on the note).
    public var suggestionsModel: NotebookMenuModel {
        let q = Self.clean(query)
        let items = model.suggestions.filter { !model.tags.contains($0) && (q.isEmpty || $0.localizedCaseInsensitiveContains(q)) }.prefix(8)
        return NotebookMenuModel(entries: items.map { .item(NotebookMenuItem(id: "tag:\($0)", glyph: .text("#"), title: $0)) },
                                 width: Self.preferredWidth - zp(2))
    }

    private func rebuild() {
        tagChips.forEach { $0.removeFromSuperview() }
        tagChips = model.tags.map { tag in
            let chip = ChipControl(.meta("#\(tag)  ✕"), isLink: true)
            chip.setAccessibilityLabel("移除 #\(tag)")
            chip.onClick = { [weak self] in self?.onRemove?(tag) }
            addSubview(chip)
            return chip
        }
        suggestions.update(suggestionsModel)
        suggestions.isHidden = suggestionsModel.entries.isEmpty
        needsLayout = true
        onSizeChange?(preferredSize)
    }

    private func chipsHeight(width: CGFloat) -> CGFloat {
        guard !tagChips.isEmpty else { return 0 }
        var x: CGFloat = 0
        var lines = 1
        for chip in tagChips {
            let w = chip.intrinsicContentSize.width
            if x > 0, x + w > width { lines += 1; x = 0 }
            x += w + zp(5)
        }
        return CGFloat(lines) * zp(20) + CGFloat(lines - 1) * zp(5)
    }

    public var preferredSize: NSSize {
        let inner = Self.preferredWidth - zp(2) - zp(20)
        var height: CGFloat = 1 + zp(6) + zp(16) + zp(6)
        let chips = chipsHeight(width: inner)
        if chips > 0 { height += chips + zp(8) }
        height += zp(30) + zp(4)
        if !suggestionsModel.entries.isEmpty { height += suggestions.preferredSize.height - zp(2) }
        return NSSize(width: Self.preferredWidth, height: ceil(height + zp(4) + 1))
    }

    public override var intrinsicContentSize: NSSize { preferredSize }

    public override func layout() {
        super.layout()
        let x: CGFloat = 1 + zp(10)
        let inner = bounds.width - zp(2) - zp(20)
        header.frame = CGRect(x: x, y: 1 + zp(6), width: inner, height: zp(16))
        var y = header.frame.maxY + zp(6)
        var cx: CGFloat = 0
        var line: CGFloat = 0
        for chip in tagChips {
            let w = chip.intrinsicContentSize.width
            if cx > 0, cx + w > inner { line += 1; cx = 0 }
            chip.frame = CGRect(x: x + cx, y: y + line * 25, width: w, height: zp(20))
            cx += w + zp(5)
        }
        if !tagChips.isEmpty { y += chipsHeight(width: inner) + zp(8) }
        field.frame = CGRect(x: x, y: y, width: inner, height: zp(30))
        y = field.frame.maxY + zp(4)
        let size = suggestions.preferredSize
        suggestions.frame = CGRect(x: 0, y: y - 1, width: bounds.width, height: size.height)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgLift)
        Draw.strokeRect(bounds, color: Palette.amberDim)
    }

    var visibleTexts: [String] { notebookVisibleTexts() }
}
