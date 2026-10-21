import AppKit
import CoddUI

/// The session pane's notes drawer (Split artboard `.sp-pad`, 300 pt): head `SESSION PAD · 筆記`
/// + `✕`; `LINKED NOTES n` with one card per note (kind chip, title link, AI glyph, up to two
/// thumbnails with captions, the caption line, up to three tasks, the meta line, `[插入引用]
/// [送出全文]`; the note referenced in the composer draft has the amber border); `+ 新筆記（連結此
/// session）`; the optional `AI 改過的檔案 · n  vs HEAD` section; the footer (notes path, `⌘⇧N
/// 快速筆記`). Without cards: `// 還沒有連結這個 session 的筆記`.
///
/// While `model.editing` is set the drawer edits that note in place: under the head the editing
/// bar `‹ LINKED NOTES n` (back to the cards) and `[筆記本 ↗]`, the `documentView` slot (the app's
/// note editor) filling the column, then `[插入引用] [送出全文]` and the save state above the footer.
public final class NotesDrawerView: NSView {
    public static var preferredWidth: CGFloat { zp(300) }
    static var headHeight: CGFloat { zp(36) }
    static var footHeight: CGFloat { zp(28) }
    static var editBarHeight: CGFloat { zp(32) }
    static var editActionsHeight: CGFloat { zp(40) }

    public private(set) var model: NotesDrawerModel
    public var onClose: (() -> Void)?
    /// The note in the Notebook: a card's title when `onEditNote` is nil, the editing bar's
    /// `[筆記本 ↗]` when `onOpenInNotebook` is nil.
    public var onOpenNote: ((String) -> Void)?
    /// A card's title: the note opens in the drawer's editor (nil: `onOpenNote`).
    public var onEditNote: ((String) -> Void)?
    /// The editing bar's `‹ LINKED NOTES`: back to the cards.
    public var onBack: (() -> Void)?
    /// The editing bar's `[筆記本 ↗]` (nil: `onOpenNote`).
    public var onOpenInNotebook: ((String) -> Void)?
    /// 插入引用 / 送出全文 of a card, or of the note being edited.
    public var onInsertRef: ((String) -> Void)?
    public var onSendFull: ((String) -> Void)?
    public var onNewNote: (() -> Void)?
    public var onOpenFile: ((String) -> Void)?
    public var onDiff: ((String) -> Void)?
    public var onQuickNote: (() -> Void)?

    /// The note editor, filling the column while a note is edited (hidden with its slot otherwise).
    public var documentView: NSView? {
        didSet {
            guard documentView !== oldValue else { return }
            if oldValue?.superview === documentSlot { oldValue?.removeFromSuperview() }
            if let documentView {
                documentView.frame = documentSlot.bounds
                documentView.autoresizingMask = [.width, .height]
                documentSlot.addSubview(documentView)
            }
        }
    }

    /// The area the document view fills (tests, the demo's placeholder).
    public let documentSlot = PanelView(fill: Palette.bgSoft)
    let backControl = DrawnControl()
    let notebookButton = CoddButton("筆記本 ↗", style: .bracket(.normal, small: true))
    let editInsertRefButton = CoddButton("插入引用", style: .bracket(.normal, small: true))
    let editSendFullButton = CoddButton("送出全文", style: .bracket(.normal, small: true))
    private let saveLabel = InlineLabel(gap: 0)
    let closeButton = CoddButton("✕", style: .glyph(size: 24))
    private let title = InlineLabel()
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let linkedHeader = DrawerSectionHeader()
    private(set) var cardViews: [DrawerCardView] = []
    private let emptyLabel = InlineLabel()
    let newNoteButton = CoddButton("+ 新筆記（連結此 session）", style: .addRow)
    private let filesHeader = DrawerSectionHeader()
    private(set) var filesList: DrawerFilesListView?
    let footer = DrawnControl()

    public init(model: NotesDrawerModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: zp(900)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Session pad 筆記")
        var titleStyle = TextStyle(font: Typeface.display(11.5), color: Palette.amber, tracking: 0.16, uppercase: true)
        titleStyle.shadow = Draw.glow(Palette.amberGlow, radius: 8)
        title.set([.text("Session pad", titleStyle), .text("· 筆記", TextStyle.mono(11.5, Palette.dim, tracking: 0.06), gapBefore: 6)])
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.setAccessibilityLabel("關閉 Session pad")
        newNoteButton.target = self
        newNoteButton.action = #selector(newNoteClicked)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.documentView = document
        footer.onClick = { [weak self] in self?.onQuickNote?() }
        footer.drawer = { [weak self] control, rect in self?.drawFooter(control, rect) }
        footer.setAccessibilityLabel("⌘⇧N 快速筆記")
        backControl.onClick = { [weak self] in self?.onBack?() }
        backControl.drawer = { [weak self] control, rect in
            guard let self else { return }
            let pieces = self.backPieces(hot: control.isHot)
            InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: rect, gap: 0))
        }
        backControl.setAccessibilityLabel("回到 LINKED NOTES")
        notebookButton.target = self
        notebookButton.action = #selector(notebookClicked)
        notebookButton.toolTip = "在筆記本開啟"
        editInsertRefButton.target = self
        editInsertRefButton.action = #selector(editInsertRefClicked)
        editSendFullButton.target = self
        editSendFullButton.action = #selector(editSendFullClicked)
        for view in [linkedHeader, emptyLabel, newNoteButton, filesHeader] as [NSView] { document.addSubview(view) }
        for view in [title, closeButton, scroll, documentSlot, backControl, notebookButton, editInsertRefButton, editSendFullButton,
                     saveLabel, footer] as [NSView] { addSubview(view) }
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: NotesDrawerModel) {
        guard model != self.model else { return }
        var cardsPart = model
        cardsPart.editing = self.model.editing
        let onlyEditingChanged = cardsPart == self.model
        self.model = model
        // The save state moves with every autosave: the cards are not rebuilt for it.
        if onlyEditingChanged { applyEditing() } else { rebuild() }
    }

    /// A note is open in the drawer's editor.
    public var isEditing: Bool { model.editing != nil }

    @objc private func closeClicked() { onClose?() }
    @objc private func newNoteClicked() { onNewNote?() }

    @objc private func notebookClicked() {
        guard let id = model.editing?.id else { return }
        if let onOpenInNotebook { onOpenInNotebook(id) } else { onOpenNote?(id) }
    }

    @objc private func editInsertRefClicked() {
        guard let id = model.editing?.id else { return }
        onInsertRef?(id)
    }

    @objc private func editSendFullClicked() {
        guard let id = model.editing?.id else { return }
        onSendFull?(id)
    }

    private func openCard(_ id: String) {
        if let onEditNote { onEditNote(id) } else { onOpenNote?(id) }
    }

    private func rebuild() {
        linkedHeader.configure(title: "Linked notes", count: String(model.cards.count), trailing: nil, caps: true)
        cardViews.forEach { $0.removeFromSuperview() }
        cardViews = model.cards.map { card in
            let view = DrawerCardView(card: card, disabledReason: model.actionsDisabledReason)
            view.onOpen = { [weak self] in self?.openCard(card.id) }
            view.onInsertRef = { [weak self] in self?.onInsertRef?(card.id) }
            view.onSendFull = { [weak self] in self?.onSendFull?(card.id) }
            document.addSubview(view)
            return view
        }
        emptyLabel.set([.text(model.emptyText, TextStyle.comment)])
        emptyLabel.isHidden = !model.cards.isEmpty
        filesList?.removeFromSuperview()
        filesList = nil
        if let files = model.files {
            filesHeader.configure(title: files.title, count: String(files.count), trailing: files.baseline, caps: false)
            let list = DrawerFilesListView(section: files)
            list.onDiff = { [weak self] id in self?.onDiff?(id) }
            list.onOpen = { [weak self] id in self?.onOpenFile?(id) }
            document.addSubview(list)
            filesList = list
        }
        filesHeader.isHidden = model.files == nil
        footer.texts = [model.notesPath, "⌘⇧N", "快速筆記"]
        footer.needsDisplay = true
        applyEditing()
    }

    /// The editing parts follow `model.editing` (the cards' scroll view hides under them).
    private func applyEditing() {
        let editing = model.editing
        // A hidden editor never keeps the keyboard (keys would go to a view nobody sees).
        if editing == nil, let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: documentSlot) {
            window.makeFirstResponder(nil)
        }
        scroll.isHidden = editing != nil
        for view in [documentSlot, backControl, notebookButton, editInsertRefButton, editSendFullButton, saveLabel] as [NSView] {
            view.isHidden = editing == nil
        }
        backControl.texts = backPieces(hot: false).compactMap(\.plain)
        backControl.setAccessibilityLabel("回到 LINKED NOTES")
        backControl.needsDisplay = true
        if let editing {
            notebookButton.setAccessibilityLabel("在筆記本開啟：\(editing.title)")
            documentSlot.setAccessibilityLabel("筆記內容：\(editing.title)")
            for button in [editInsertRefButton, editSendFullButton] {
                button.isEnabled = model.actionsDisabledReason == nil
                button.toolTip = model.actionsDisabledReason
            }
            saveLabel.set(Self.savePieces(editing.save, compact: false))
        }
        needsLayout = true
        needsDisplay = true
    }

    /// `‹ LINKED NOTES 2` (amber while the pointer is over it).
    private func backPieces(hot: Bool) -> [InlinePiece] {
        let color = hot ? Palette.amber : Palette.dim
        return [
            .text("‹", TextStyle.mono(12, color)),
            .text("Linked notes", TextStyle(font: Typeface.mono(10), color: color, tracking: 0.18, uppercase: true), gapBefore: 7),
            .text(String(model.cards.count), TextStyle.mono(10, Palette.amberDim), gapBefore: 8),
        ]
    }

    /// The doc status bar's save state (`NoteDocStatusView`): `● 已儲存 10:05` (green dot; `compact`
    /// drops the time), `● 未儲存` (amber), `◌ 儲存中…`; nothing while the note loads.
    static func savePieces(_ save: NoteSaveState?, compact: Bool) -> [InlinePiece] {
        let base = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06)
        switch save {
        case .saved(let time)?:
            return [.text("●", TextStyle.mono(10.5, Palette.success)), .text(compact ? "已儲存" : "已儲存 \(time)", base, gapBefore: 4)]
        case .unsaved?:
            return [.text("● 未儲存", TextStyle.mono(10.5, Palette.amber, tracking: 0.06))]
        case .saving?:
            return [.text("◌ 儲存中…", base)]
        case nil:
            return []
        }
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
        let titleSize = title.intrinsicContentSize
        title.frame = CGRect(x: 1 + zp(14), y: round((Self.headHeight - titleSize.height) / 2), width: min(titleSize.width, width - zp(60)),
                             height: titleSize.height)
        closeButton.frame = CGRect(x: width - zp(6) - zp(24), y: (Self.headHeight - zp(24)) / 2, width: zp(24), height: zp(24))
        footer.frame = CGRect(x: 1, y: bounds.height - Self.footHeight, width: width - 1, height: Self.footHeight)
        scroll.frame = CGRect(x: 1, y: Self.headHeight, width: width - 1, height: max(0, footer.frame.minY - Self.headHeight))
        if isEditing { layoutEditing(width: width) }
        // The clip's width: a legacy (always shown) scroller takes its share of the frame. An
        // autohiding legacy scroller appears once the document is taller than the clip, which
        // narrows the clip: lay out again at that width (rows would be cut at the scroller).
        let clipWidth = scroll.contentSize.width
        layoutDocument(width: clipWidth)
        if scroll.contentSize.width != clipWidth { layoutDocument(width: scroll.contentSize.width) }
    }

    /// The editing bar (32), the document slot, the action row (40) above the footer. A narrow
    /// drawer keeps both buttons and drops the save state before it would be cut.
    private func layoutEditing(width: CGFloat) {
        let x = 1 + zp(12)
        let barTop = Self.headHeight
        let open = notebookButton.intrinsicContentSize
        notebookButton.frame = CGRect(x: width - zp(10) - open.width, y: barTop + round((Self.editBarHeight - open.height) / 2),
                                      width: open.width, height: open.height)
        let backWidth = InlineLayout.width(backPieces(hot: false), gap: 0)
        backControl.frame = CGRect(x: x, y: barTop + round((Self.editBarHeight - zp(20)) / 2),
                                   width: max(0, min(backWidth, notebookButton.frame.minX - zp(8) - x)), height: zp(20))
        let actionsTop = footer.frame.minY - Self.editActionsHeight
        documentSlot.frame = CGRect(x: 1, y: barTop + Self.editBarHeight, width: width - 1,
                                    height: max(0, actionsTop - barTop - Self.editBarHeight))
        documentView?.frame = documentSlot.bounds
        let buttonY = actionsTop + round((Self.editActionsHeight - zp(22)) / 2)
        let ref = editInsertRefButton.intrinsicContentSize
        editInsertRefButton.frame = CGRect(x: x, y: buttonY, width: ref.width, height: zp(22))
        let send = editSendFullButton.intrinsicContentSize
        editSendFullButton.frame = CGRect(x: editInsertRefButton.frame.maxX + zp(6), y: buttonY, width: send.width, height: zp(22))
        // The save state at the right: in full, else without its time (`● 已儲存`), else hidden.
        let saveRight = width - zp(12)
        let room = saveRight - (editSendFullButton.frame.maxX + zp(10))
        let full = Self.savePieces(model.editing?.save, compact: false)
        let compact = Self.savePieces(model.editing?.save, compact: true)
        let pieces = InlineLayout.width(full, gap: 0) <= room ? full : InlineLayout.width(compact, gap: 0) <= room ? compact : []
        if saveLabel.pieces.compactMap(\.plain) != pieces.compactMap(\.plain) { saveLabel.set(pieces) }
        if saveLabel.isHidden != pieces.isEmpty { saveLabel.isHidden = pieces.isEmpty }
        let save = saveLabel.intrinsicContentSize
        saveLabel.frame = CGRect(x: saveRight - save.width, y: actionsTop + round((Self.editActionsHeight - save.height) / 2),
                                 width: save.width, height: save.height)
    }

    /// `.sp-pad-b{padding:10px 12px 12px;gap:10px}`.
    private func layoutDocument(width: CGFloat) {
        let x: CGFloat = zp(12)
        let inner = width - zp(24)
        var y: CGFloat = zp(10) + zp(2) // `.sp-sec{margin-top:2px}`
        linkedHeader.frame = CGRect(x: x, y: y, width: inner, height: zp(15))
        y += zp(15)
        if cardViews.isEmpty {
            y += zp(10)
            emptyLabel.frame = CGRect(x: x, y: y, width: inner, height: zp(18))
            y += zp(18)
        }
        for card in cardViews {
            y += zp(10)
            let height = card.height(for: inner)
            card.frame = CGRect(x: x, y: y, width: inner, height: height)
            y += height
        }
        y += zp(10)
        newNoteButton.frame = CGRect(x: x, y: y, width: inner, height: zp(28))
        y += zp(28)
        if let filesList {
            y += zp(10) + zp(2)
            filesHeader.frame = CGRect(x: x, y: y, width: inner, height: zp(15))
            y += zp(15) + zp(10)
            let height = filesList.height
            filesList.frame = CGRect(x: x, y: y, width: inner, height: height)
            y += height
        }
        y += zp(12)
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: 0, y: 0, width: 1, height: bounds.height), Palette.lineBright)
        Draw.fill(CGRect(x: 1, y: 0, width: bounds.width - 1, height: Self.headHeight), Palette.bgSoft)
        Draw.dashedLine(from: CGPoint(x: 1, y: Self.headHeight - 1), to: CGPoint(x: bounds.width, y: Self.headHeight - 1),
                        color: Palette.lineBright)
        guard isEditing else { return }
        let barBottom = Self.headHeight + Self.editBarHeight
        Draw.dashedLine(from: CGPoint(x: 1, y: barBottom - 1), to: CGPoint(x: bounds.width, y: barBottom - 1), color: Palette.line)
        let actionsTop = bounds.height - Self.footHeight - Self.editActionsHeight
        Draw.dashedLine(from: CGPoint(x: 1, y: actionsTop), to: CGPoint(x: bounds.width, y: actionsTop), color: Palette.line)
    }

    private func drawFooter(_ control: DrawnControl, _ rect: CGRect) {
        Draw.dashedLine(from: .zero, to: CGPoint(x: rect.width, y: 0), color: Palette.line)
        let base = TextStyle.mono(10.5, Palette.dimmer)
        let kbd = NotebookChip(text: "⌘⇧N", style: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 18,
                               padding: 5)
        let pieces: [InlinePiece] = [
            .text(model.notesPath, TextStyle.mono(10.5, Palette.dimmer), shrink: true, lineBreak: .byTruncatingMiddle),
            .flex,
            .chip(kbd),
            .text("快速筆記", control.isHot ? base.with(color: Palette.amber) : base),
        ]
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: rect.insetBy(dx: zp(12), dy: 0), gap: 8))
    }

    // MARK: Test access

    var visibleTexts: [String] { notebookVisibleTexts() }
    var isShowingEmptyState: Bool { !emptyLabel.isHidden }
    func card(_ id: String) -> DrawerCardView? { cardViews.first { $0.card.id == id } }
    var isShowingCards: Bool { !scroll.isHidden }
    /// The save state as drawn (`● 已儲存 10:05`), empty when hidden.
    var saveText: String { saveLabel.isHidden ? "" : saveLabel.drawnTexts.joined(separator: " ") }
}

/// `.sec.sp-sec`: `LINKED NOTES 2 ────` / `AI 改過的檔案 · 3 ── vs HEAD`.
final class DrawerSectionHeader: CanvasView, NotebookTextProviding {
    private var title = ""
    private var count = ""
    private var trailing: String?
    private var caps = true

    func configure(title: String, count: String, trailing: String?, caps: Bool) {
        self.title = title
        self.count = count
        self.trailing = trailing
        self.caps = caps
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(drawnTexts.joined(separator: " "))
        needsDisplay = true
    }

    var drawnTexts: [String] { [caps ? title.uppercased() : title, count] + (trailing.map { [$0] } ?? []) }

    override func draw(_ dirtyRect: NSRect) {
        let titleStyle = TextStyle(font: Typeface.mono(10), color: Palette.dim, tracking: 0.18, uppercase: caps)
        var pieces: [InlinePiece] = [
            .text(title, titleStyle),
            .text(count, TextStyle.mono(10, Palette.amberDim)),
            .box(CGSize(width: 0, height: 1)) { _ in },
            .flex,
        ]
        if let trailing { pieces.append(.text(trailing, TextStyle.mono(10, Palette.dimmer, tracking: 0.04))) }
        let rects = InlineLayout.layout(pieces, in: bounds, gap: 8)
        InlineLayout.draw(pieces, rects)
        // `.sp-rule{flex:1;border-top:1px dashed var(--line)}` in the flexible gap.
        if rects.count > 3 {
            let rule = rects[3]
            Draw.dashedLine(from: CGPoint(x: rule.minX, y: round(bounds.midY)), to: CGPoint(x: rule.maxX, y: round(bounds.midY)),
                            color: Palette.line)
        }
    }
}

/// One `.sp-note` card.
final class DrawerCardView: CanvasView, NotebookTextProviding {
    let card: NotesDrawerCard
    let titleLink = DrawnControl()
    let insertRefButton = CoddButton("插入引用", style: .bracket(.normal, small: true))
    let sendFullButton = CoddButton("送出全文", style: .bracket(.normal, small: true))
    var onOpen: (() -> Void)?
    var onInsertRef: (() -> Void)?
    var onSendFull: (() -> Void)?

    static var headLineHeight: CGFloat { zp(19) }
    static var shotsHeight: CGFloat { 1 + zp(8) + zp(74) + zp(4) + zp(16) + zp(6) + 1 }
    static var captionHeight: CGFloat { zp(16) }
    static var taskLineHeight: CGFloat { zp(17) }
    static var metaLineHeight: CGFloat { zp(16) }

    init(card: NotesDrawerCard, disabledReason: String?) {
        self.card = card
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("筆記：\(card.title)")
        titleLink.texts = [card.title]
        titleLink.onClick = { [weak self] in self?.onOpen?() }
        titleLink.drawer = { [card] control, rect in
            Draw.text(TextStyle.mono(12.5, control.isHot ? Palette.amber : Palette.cream, .medium).string(card.title), x: 0,
                      centerY: rect.midY, maxWidth: rect.width)
        }
        insertRefButton.target = self
        insertRefButton.action = #selector(insertRefClicked)
        sendFullButton.target = self
        sendFullButton.action = #selector(sendFullClicked)
        for button in [insertRefButton, sendFullButton] {
            button.isEnabled = disabledReason == nil
            button.toolTip = disabledReason
            addSubview(button)
        }
        addSubview(titleLink)
    }

    @objc private func insertRefClicked() { onInsertRef?() }
    @objc private func sendFullClicked() { onSendFull?() }

    private var images: [NotesDrawerImage] { Array(card.images.prefix(2)) }
    private var tasks: [NotesDrawerTask] { Array(card.tasks.prefix(3)) }
    private func metaLines(width: CGFloat) -> Int { metaPieces(width: width).count }

    /// The meta line's parts wrapped like `flex-wrap: wrap; gap: 5px`.
    private func metaPieces(width: CGFloat) -> [[String]] {
        let style = TextStyle.mono(10.5, Palette.dimmer)
        var lines: [[String]] = [[]]
        var x: CGFloat = 0
        let parts = card.metaParts
        var tokens: [String] = []
        for (index, part) in parts.enumerated() {
            if index > 0 { tokens.append("·") }
            tokens.append(part)
        }
        for token in tokens {
            let w = Draw.width(style.string(token))
            if x > 0, x + w > width {
                lines.append([])
                x = 0
            }
            lines[lines.count - 1].append(token)
            x += w + zp(5)
        }
        return lines
    }

    /// `padding: 9 11 10; gap: 8` + the 1 px border.
    func height(for width: CGFloat) -> CGFloat {
        let inner = width - zp(22) - zp(2)
        var height: CGFloat = 1 + zp(9) + Self.headLineHeight
        if !images.isEmpty { height += zp(8) + Self.shotsHeight }
        if card.imageCaption != nil || card.imageSummary != nil { height += zp(8) - zp(3) + CGFloat(captionLines(width: inner)) * Self.captionHeight }
        if !tasks.isEmpty {
            height += zp(8) + tasks.reduce(0) { $0 + CGFloat(taskLines($1, width: inner)) * Self.taskLineHeight } + CGFloat(tasks.count - 1) * zp(3)
        }
        height += zp(8) + CGFloat(metaLines(width: inner)) * Self.metaLineHeight
        height += zp(8) + zp(22) + zp(10) + 1
        return ceil(height)
    }

    var drawnTexts: [String] {
        var texts = [card.kind.text.uppercased(), card.ai.label]
        texts.append(contentsOf: images.map(\.caption))
        if let caption = card.imageCaption { texts.append(caption) }
        if let summary = card.imageSummary { texts.append(summary) }
        for task in tasks { texts.append("\(task.done ? "[x]" : "[ ]") \(task.text.replacingOccurrences(of: "`", with: ""))") }
        texts.append(card.metaParts.joined(separator: " · "))
        return texts
    }

    override func layout() {
        super.layout()
        let inner = bounds.width - zp(22) - zp(2)
        let x: CGFloat = 1 + zp(11)
        let kindWidth = NotebookChip.drawerKind(card.kind).width
        let aiWidth = aiWidthValue
        titleLink.frame = CGRect(x: x + kindWidth + zp(7), y: 1 + zp(9), width: max(0, inner - kindWidth - zp(7) - aiWidth - zp(7)), height: Self.headLineHeight)
        let buttonY = bounds.height - 1 - zp(10) - zp(22)
        let size1 = insertRefButton.intrinsicContentSize
        insertRefButton.frame = CGRect(x: x, y: buttonY, width: size1.width, height: zp(22))
        let size2 = sendFullButton.intrinsicContentSize
        sendFullButton.frame = CGRect(x: x + size1.width + zp(6), y: buttonY, width: size2.width, height: zp(22))
    }

    private var aiWidthValue: CGFloat {
        13 + 3 + Draw.width(TextStyle.mono(9.5, Palette.dim, tracking: 0.12).string(card.ai.label))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: card.isReferenced ? Palette.amberDim : Palette.lineBright)
        let x: CGFloat = 1 + zp(11)
        let inner = bounds.width - zp(22) - zp(2)
        var y: CGFloat = 1 + zp(9)
        // Head: kind chip, title (subview), AI glyph.
        let kind = NotebookChip.drawerKind(card.kind)
        kind.draw(in: CGRect(x: x, y: y, width: kind.width, height: Self.headLineHeight))
        let aiColor = card.ai == .off ? Palette.dimmer : Palette.dim
        let aiPieces: [InlinePiece] = [.icon(card.ai.icon, size: 13, color: aiColor),
                                       .text(card.ai.label, TextStyle.mono(9.5, aiColor, tracking: 0.12))]
        let aiRect = CGRect(x: x + inner - aiWidthValue, y: y, width: aiWidthValue, height: Self.headLineHeight)
        InlineLayout.draw(aiPieces, InlineLayout.layout(aiPieces, in: aiRect, gap: 3))
        y += Self.headLineHeight
        // Shots.
        if !images.isEmpty {
            y += zp(8)
            let box = CGRect(x: x, y: y, width: inner, height: Self.shotsHeight)
            Draw.fill(box, .black)
            Draw.strokeRect(box, color: Palette.line)
            var fx = box.minX + 1 + zp(10)
            let bottom = box.maxY - 1 - zp(6)
            // A narrow drawer (small window, zoom 20) scales the figures down to fit the box
            // (captions end in `…`) instead of drawing past its edge.
            let figures = images.map { image -> (size: CGSize, caption: NSAttributedString) in
                let size = image.orientation == .portrait ? CGSize(width: zp(42), height: zp(74)) : CGSize(width: zp(118), height: zp(58))
                return (size, TextStyle.mono(10.5, Palette.dim).string(image.caption))
            }
            let natural = figures.reduce(CGFloat(0)) { $0 + max($1.size.width, Draw.width($1.caption)) }
            let room = box.width - 2 - zp(10) * CGFloat(figures.count + 1)
            let scale = natural > 0 ? min(1, max(0.3, room / natural)) : 1
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: box.insetBy(dx: 1, dy: 1)).addClip()
            defer { NSGraphicsContext.restoreGraphicsState() }
            for (image, figure) in zip(images, figures) {
                let size = CGSize(width: round(figure.size.width * scale), height: round(figure.size.height * scale))
                let captionText = figure.caption
                let figWidth = max(size.width, min(Draw.width(captionText), round(max(figure.size.width, Draw.width(captionText)) * scale)))
                let thumb = CGRect(x: fx + (figWidth - size.width) / 2, y: bottom - zp(16) - zp(4) - size.height, width: size.width, height: size.height)
                if let picture = image.image {
                    Draw.fill(thumb, Palette.bgSoft)
                    NotebookDraw.thumbnail(picture, orientation: image.orientation, in: thumb.insetBy(dx: 1, dy: 1), schematic: .drawer)
                    Draw.strokeRect(thumb, color: Palette.lineBright)
                } else {
                    NotebookDraw.thumbnail(nil, orientation: image.orientation, in: thumb, schematic: .drawer)
                }
                let captionWidth = min(Draw.width(captionText), figWidth)
                Draw.text(captionText, x: fx + (figWidth - captionWidth) / 2, centerY: bottom - zp(8), maxWidth: figWidth)
                fx += figWidth + zp(10)
            }
            y = box.maxY
        }
        // Caption line (`margin-top:-3px`).
        if card.imageCaption != nil || card.imageSummary != nil {
            y += zp(8) - zp(3)
            let lines = captionLines(width: inner)
            if let summary = card.imageSummary {
                let text = Self.captionStyle.string(summary)
                Draw.text(text, x: x + inner - Draw.width(text), centerY: y + Self.captionHeight / 2)
            }
            if let caption = captionAttributed {
                caption.draw(with: CGRect(x: x, y: y, width: captionWidth(inner), height: CGFloat(lines) * Self.captionHeight),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            y += CGFloat(lines) * Self.captionHeight
        }
        // Tasks.
        if !tasks.isEmpty {
            y += zp(8)
            for (index, task) in tasks.enumerated() {
                if index > 0 { y += 3 }
                let lines = taskLines(task, width: inner)
                drawTask(task, in: CGRect(x: x, y: y, width: inner, height: CGFloat(lines) * Self.taskLineHeight), lines: lines)
                y += CGFloat(lines) * Self.taskLineHeight
            }
        }
        // Meta line.
        y += zp(8)
        let style = TextStyle.mono(10.5, Palette.dimmer)
        for line in metaPieces(width: inner) {
            let pieces = line.map { InlinePiece.text($0, style) }
            InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: CGRect(x: x, y: y, width: inner, height: Self.metaLineHeight), gap: 5))
            y += Self.metaLineHeight
        }
    }

    // MARK: Caption and tasks (they wrap like the artboard's flex items, never cut a word off)

    static var captionStyle: TextStyle { TextStyle.mono(10.5, Palette.dimmer) }

    private func captionWidth(_ inner: CGFloat) -> CGFloat {
        let summary = card.imageSummary.map { Draw.width(Self.captionStyle.string($0)) + zp(8) } ?? 0
        return max(40, inner - summary)
    }

    private var captionAttributed: NSAttributedString? {
        card.imageCaption.map { Self.captionStyle.string($0, lineHeight: 16, lineBreak: .byWordWrapping) }
    }

    /// The caption wraps (at most two lines); the summary stays on the first line at the right.
    func captionLines(width inner: CGFloat) -> Int {
        guard let caption = captionAttributed else { return 1 }
        let rect = caption.boundingRect(with: CGSize(width: captionWidth(inner), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return min(2, max(1, Int((ceil(rect.height) + Self.captionHeight / 2) / Self.captionHeight)))
    }

    private func boxText(_ task: NotesDrawerTask) -> NSAttributedString {
        TextStyle.mono(11.5, task.done ? Palette.amberDim : Palette.dim).string(task.done ? "[x]" : "[ ]")
    }

    /// One line with code chips (`.sp-tasks code`), as in the artboard.
    private func taskPieces(_ task: NotesDrawerTask) -> [InlinePiece] {
        var pieces: [InlinePiece] = [.text(boxText(task))]
        let color = task.done ? Palette.dimmer : Palette.bone
        for (index, part) in NotebookDraw.codeSpans(task.text).enumerated() {
            if part.1 {
                pieces.append(.chip(NotebookChip.code(part.0), gapBefore: index == 0 ? 7 : 2))
            } else {
                pieces.append(.text(part.0, TextStyle.mono(11.5, color), shrink: true, gapBefore: index == 0 ? 7 : 2))
            }
        }
        return pieces
    }

    /// The wrapped form: code spans keep their amber on --bg, done tasks are struck through.
    private func taskAttributed(_ task: NotesDrawerTask) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let color = task.done ? Palette.dimmer : Palette.bone
        for part in NotebookDraw.codeSpans(task.text) {
            let style = part.1 ? TextStyle.mono(11, Palette.amber) : TextStyle.mono(11.5, color)
            let piece = NSMutableAttributedString(attributedString: style.string(part.0, lineHeight: 17,
                                                                                   lineBreak: .byWordWrapping))
            if part.1 { piece.addAttribute(.backgroundColor, value: Palette.bg, range: NSRange(location: 0, length: piece.length)) }
            out.append(piece)
        }
        if task.done {
            out.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: Palette.dimmer],
                              range: NSRange(location: 0, length: out.length))
        }
        return out
    }

    private func taskTextWidth(_ task: NotesDrawerTask, inner: CGFloat) -> CGFloat { inner - Draw.width(boxText(task)) - zp(7) }

    /// 1 when the task fits on one line, else its wrapped lines (at most 3).
    func taskLines(_ task: NotesDrawerTask, width inner: CGFloat) -> Int {
        if InlineLayout.width(taskPieces(task), gap: 7) <= inner { return 1 }
        let rect = taskAttributed(task).boundingRect(with: CGSize(width: taskTextWidth(task, inner: inner), height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin])
        return min(3, max(1, Int((ceil(rect.height) + Self.taskLineHeight / 2) / Self.taskLineHeight)))
    }

    private func drawTask(_ task: NotesDrawerTask, in rect: CGRect, lines: Int) {
        let pieces = taskPieces(task)
        if InlineLayout.width(pieces, gap: 7) <= rect.width {
            let rects = InlineLayout.layout(pieces, in: rect, gap: 7)
            InlineLayout.draw(pieces, rects)
            if task.done, rects.count > 1 {
                // `text-decoration: line-through` across the text.
                let start = rects[1].minX
                let end = rects.last.map(\.maxX) ?? start
                Draw.fill(CGRect(x: start, y: round(rect.midY), width: end - start, height: 1), Palette.dimmer)
            }
            return
        }
        let box = boxText(task)
        Draw.text(box, x: rect.minX, centerY: rect.minY + Self.taskLineHeight / 2)
        let textX = rect.minX + Draw.width(box) + zp(7)
        taskAttributed(task).draw(with: CGRect(x: textX, y: rect.minY, width: rect.maxX - textX, height: CGFloat(lines) * Self.taskLineHeight),
                                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// `.sp-files`: the AI-touched files with `M`, the AI chip (the session's tag color, D26), the
/// directory and `[差異]`.
final class DrawerFilesListView: CanvasView, NotebookTextProviding {
    let section: NotesDrawerFilesSection
    private(set) var diffButtons: [CoddButton] = []
    private(set) var rows: [DrawnControl] = []
    private var targets: [ClosureTarget] = []
    var onDiff: ((String) -> Void)?
    var onOpen: ((String) -> Void)?
    static var rowHeight: CGFloat { zp(47) }

    init(section: NotesDrawerFilesSection) {
        self.section = section
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("AI 改過的檔案")
        for file in section.files {
            let row = DrawnControl()
            row.texts = [file.name, file.status, file.aiChip, file.directory].compactMap { $0 }
            row.drawer = { [weak self] control, rect in self?.drawRow(file, control: control, in: rect) }
            row.onClick = { [weak self] in self?.onOpen?(file.id) }
            addSubview(row)
            rows.append(row)
            let button = CoddButton("差異", style: .bracket(.normal, small: true))
            button.setAccessibilityLabel("差異：\(file.directory)\(file.name)")
            let target = ClosureTarget { [weak self] in self?.onDiff?(file.id) }
            targets.append(target)
            button.target = target
            button.action = #selector(ClosureTarget.run)
            addSubview(button)
            diffButtons.append(button)
        }
    }

    var drawnTexts: [String] { [] }

    var height: CGFloat {
        section.files.isEmpty ? 0 : 2 + CGFloat(section.files.count) * Self.rowHeight + CGFloat(section.files.count - 1)
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 1
        for (row, button) in zip(rows, diffButtons) {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: bounds.width - 1 - zp(8) - size.width, y: y + round((Self.rowHeight - size.height) / 2), width: size.width,
                                  height: size.height)
            row.frame = CGRect(x: 1, y: y, width: max(0, button.frame.minX - zp(8) - 1), height: Self.rowHeight)
            y += Self.rowHeight + 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.line)
        var y: CGFloat = 1 + Self.rowHeight
        for _ in section.files.dropLast() {
            Draw.dashedLine(from: CGPoint(x: 1, y: y), to: CGPoint(x: bounds.width - 1, y: y), color: Palette.line)
            y += Self.rowHeight + 1
        }
    }

    private func drawRow(_ file: NotesDrawerFile, control: DrawnControl, in rect: CGRect) {
        var pieces: [InlinePiece] = [.text(file.name, TextStyle.mono(12, control.isHot ? Palette.amber : Palette.cream, .medium), shrink: true)]
        if let status = file.status { pieces.append(.text(status, TextStyle.mono(10.5, Palette.amber, .bold))) }
        if let chip = file.aiChip {
            let color = section.aiTag?.color ?? Palette.bone
            let border = section.aiTag?.color.withAlphaComponent(0.45) ?? Palette.lineBright
            let style = TextStyle(font: Typeface.mono(9.5), color: color, tracking: 0.06)
            pieces.append(.chip(NotebookChip(text: chip, style: style, border: border, height: 15, padding: 4)))
        }
        let line1 = CGRect(x: zp(10), y: zp(6), width: rect.width - zp(10), height: zp(18))
        InlineLayout.draw(pieces, InlineLayout.layout(pieces, in: line1, gap: 7))
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(file.directory), x: zp(10), centerY: zp(6) + zp(18) + 1 + zp(8), maxWidth: rect.width - zp(10))
    }
}

/// A target object running a closure (per-row buttons; the owner keeps it alive).
final class ClosureTarget: NSObject {
    let handler: @MainActor () -> Void

    init(handler: @escaping @MainActor () -> Void) {
        self.handler = handler
    }

    @MainActor @objc func run() { handler() }
}
