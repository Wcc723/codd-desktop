import AppKit
import CoddUI

/// A clickable chip (the chips row's tag / session / project chips: `a.chip:hover` turns the
/// border --amber-dim and the text cream).
final class ChipControl: HoverControl, NotebookTextProviding {
    var chip: NotebookChip { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(chip.text) } }
    /// Draws the hover look (links only).
    var isLink: Bool
    var onRightClick: (() -> NSMenu?)?

    init(_ chip: NotebookChip, isLink: Bool) {
        self.chip = chip
        self.isLink = isLink
        super.init(frame: .zero)
        setAccessibilityLabel(chip.text)
        if !isLink {
            setAccessibilityRole(.staticText)
            // A plain chip is text, not a control: no key view (D21).
            takesKeyboardFocus = false
        }
    }

    var drawnTexts: [String] { [chip.attributed.string] }
    override var intrinsicContentSize: NSSize { NSSize(width: chip.width, height: chip.height) }

    override func draw(_ dirtyRect: NSRect) {
        var look = chip
        if isLink, isHot {
            look.border = Palette.amberDim
            look.style = look.style.with(color: Palette.cream)
        }
        look.draw(in: bounds)
    }

    override func menu(for event: NSEvent) -> NSMenu? { onRightClick?() }

    /// VoiceOver's "show menu" (VO-⇧-M) pops the right-click menu at the chip.
    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = onRightClick?() else { return false }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: bounds.height), in: self)
        return true
    }
}

/// The `.nb-meta` row under the note title (C4's `titleAccessory`): kind chip, `#tag` chips, the
/// linked session (lamp + title) and project (tag square + name), `updated HH:mm`; wraps like
/// `flex-wrap: wrap; gap: 5px`. A dashed `+ #` chip (shown while the pointer is over the row or
/// when the note has no tags) opens an inline tag field: ⏎ adds the tag only without marked text
/// (注音 commits first), ⎋ closes it.
public final class NoteChipsRowView: NSView {
    public private(set) var model: NoteChipsRowModel
    public var onAddTag: ((String) -> Void)?
    public var onRemoveTag: ((String) -> Void)?
    public var onTagClick: ((String) -> Void)?
    public var onOpenSession: ((String) -> Void)?
    public var onOpenProject: ((String) -> Void)?

    static var lineHeight: CGFloat { zp(20) }
    static var gap: CGFloat { zp(5) }

    private var chips: [NSView] = []
    let addChip = ChipControl(.meta("+ #", color: Palette.dim, dashed: true), isLink: true)
    let tagField = NotebookTextField(placeholder: "新標籤", fontSize: 10.5, accessibilityLabel: "新增標籤")
    private let updatedLabel = InlineLabel()
    private(set) var isEditingTag = false
    private var isPointerInside = false
    private var trackingArea: NSTrackingArea?
    /// The width the last layout used (the intrinsic height follows it).
    private var layoutWidth: CGFloat = 0

    public init(model: NoteChipsRowModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: zp(520), height: Self.lineHeight))
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("筆記標籤與連結")
        addChip.setAccessibilityLabel("新增標籤")
        addChip.onClick = { [weak self] in self?.beginTagEditing() }
        tagField.onSubmit = { [weak self] text in self?.commitTag(text) }
        tagField.onCancel = { [weak self] in
            self?.endTagEditing()
            return true
        }
        tagField.onFocusChange = { [weak self] focused in
            guard let self, !focused, self.isEditingTag, !self.tagField.isComposing else { return }
            if self.tagField.text.trimmingCharacters(in: .whitespaces).isEmpty { self.endTagEditing() }
        }
        tagField.isHidden = true
        addSubview(addChip)
        addSubview(tagField)
        addSubview(updatedLabel)
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: NoteChipsRowModel) {
        guard model != self.model else { return }
        self.model = model
        rebuild()
    }

    private func rebuild() {
        chips.forEach { $0.removeFromSuperview() }
        var views: [NSView] = []
        let kind = ChipControl(.meta(model.kind.text, caps: true, color: model.kind.amber ? Palette.amber : Palette.bone,
                                     border: model.kind.amber ? Palette.amberDim : Palette.lineBright, dashed: model.kind.dashed),
                               isLink: false)
        views.append(kind)
        for tag in model.tags {
            let chip = ChipControl(.meta("#\(tag)"), isLink: true)
            chip.onClick = { [weak self] in self?.onTagClick?(tag) }
            chip.onRightClick = { [weak self] in self?.tagMenu(tag) }
            // Removing is a right click; VoiceOver and the keyboard reach it as an action (D21).
            chip.setAccessibilityCustomActions([NSAccessibilityCustomAction(name: "移除 #\(tag)") { [weak self] in
                self?.onRemoveTag?(tag)
                return true
            }])
            views.append(chip)
        }
        if let session = model.session {
            let chip = ChipControl(.meta(session.title, lead: .lamp(session.state, size: 9)), isLink: true)
            chip.setAccessibilityLabel("開啟 session：\(session.title)")
            chip.onClick = { [weak self] in self?.onOpenSession?(session.id) }
            views.append(chip)
        }
        if let project = model.project {
            let chip = ChipControl(.meta(project.title, lead: .tag(project.tag, size: 8)), isLink: true)
            chip.setAccessibilityLabel("開啟專案：\(project.title)")
            chip.onClick = { [weak self] in self?.onOpenProject?(project.id) }
            views.append(chip)
        }
        for view in views { addSubview(view, positioned: .below, relativeTo: addChip) }
        chips = views
        updatedLabel.set([.text(model.updated, TextStyle.mono(10.5, Palette.dimmer))])
        updateAddChip()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func tagMenu(_ tag: String) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "移除 #\(tag)") { [weak self] in self?.onRemoveTag?(tag) })
        return menu
    }

    private func updateAddChip() {
        addChip.isHidden = !model.allowsAddTag || isEditingTag || !(isPointerInside || model.tags.isEmpty)
        tagField.isHidden = !isEditingTag
        needsLayout = true
    }

    // MARK: Tag editing

    /// Opens the inline tag field and focuses it.
    public func beginTagEditing() {
        guard model.allowsAddTag else { return }
        isEditingTag = true
        tagField.text = ""
        updateAddChip()
        layoutSubtreeIfNeeded()
        tagField.focus()
    }

    private func commitTag(_ text: String) {
        // The field already refused ⏎ while composing; strip `#` and spaces.
        let tag = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !tag.isEmpty else {
            endTagEditing()
            return
        }
        onAddTag?(tag)
        tagField.text = ""
    }

    func endTagEditing() {
        guard isEditingTag else { return }
        isEditingTag = false
        if window?.firstResponder === tagField.field.currentEditor() { window?.makeFirstResponder(nil) }
        updateAddChip()
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { setPointerInside(true) }
    public override func mouseExited(with event: NSEvent) { setPointerInside(false) }

    func setPointerInside(_ inside: Bool) {
        guard inside != isPointerInside else { return }
        isPointerInside = inside
        updateAddChip()
    }

    // MARK: Layout

    private var flowViews: [NSView] {
        var views = chips
        if !addChip.isHidden { views.append(addChip) }
        if !tagField.isHidden { views.append(tagField) }
        views.append(updatedLabel)
        return views
    }

    private func size(of view: NSView) -> CGSize {
        if view === tagField { return CGSize(width: zp(120), height: Self.lineHeight) }
        let size = view.intrinsicContentSize
        return CGSize(width: size.width, height: max(1, size.height))
    }

    /// The row's height at `width` (wrapped lines of 20 with 5 between).
    public func height(for width: CGFloat) -> CGFloat {
        var x: CGFloat = 0
        var lines = 1
        for view in flowViews {
            let w = min(size(of: view).width, width)
            if x > 0, x + w > width + 0.5 {
                lines += 1
                x = 0
            }
            x += w + Self.gap
        }
        return CGFloat(lines) * Self.lineHeight + CGFloat(lines - 1) * Self.gap
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: layoutWidth > 0 ? layoutWidth : (bounds.width > 0 ? bounds.width : 10_000)))
    }

    public override func layout() {
        super.layout()
        if layoutWidth != bounds.width {
            layoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        var x: CGFloat = 0
        var y: CGFloat = 0
        for view in flowViews {
            let s = size(of: view)
            let w = min(s.width, bounds.width)
            if x > 0, x + w > bounds.width + 0.5 {
                x = 0
                y += Self.lineHeight + Self.gap
            }
            view.frame = CGRect(x: x, y: y + round((Self.lineHeight - s.height) / 2), width: w, height: s.height)
            x += w + Self.gap
        }
    }

    var visibleTexts: [String] { notebookVisibleTexts() }
}

/// `.nb-annp` (C4's image accessory to the right of the figure): `標註 3 · ⌘⇧A [編輯標註]`, the
/// numbered list with each note and its coordinates, and the hint line.
public final class ImageAnnotationSummaryView: NSView {
    public private(set) var model: ImageAnnotationSummaryModel
    public var onEdit: (() -> Void)?
    /// An annotation's number was clicked.
    public var onSelectItem: ((Int) -> Void)?

    let editButton = CoddButton("編輯標註", style: .bracket(.normal, small: true))
    private let header = InlineLabel()
    private var itemViews: [AnnotationItemView] = []
    private let hint = WrapLabel(style: TextStyle.mono(11, Palette.dimmer, tracking: 0.02), lineHeight: 16)

    public init(model: ImageAnnotationSummaryModel) {
        self.model = model
        super.init(frame: CGRect(x: 0, y: 0, width: zp(420), height: zp(200)))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("圖片標註")
        editButton.target = self
        editButton.action = #selector(editClicked)
        addSubview(header)
        addSubview(editButton)
        addSubview(hint)
        rebuild()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public func update(_ model: ImageAnnotationSummaryModel) {
        guard model != self.model else { return }
        self.model = model
        rebuild()
    }

    private func rebuild() {
        let kbd = NotebookChip(text: model.shortcut, style: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg,
                               height: 18, padding: 5)
        header.set([
            .text("標註", TextStyle.mono(11, Palette.bone)),
            .text(String(model.items.count), TextStyle.mono(11, Palette.amber, .bold)),
            .text("·", TextStyle.mono(11, Palette.dimmer)),
            .chip(kbd),
        ])
        header.gap = 7
        itemViews.forEach { $0.removeFromSuperview() }
        itemViews = model.items.map { item in
            let view = AnnotationItemView(item: item)
            view.onClick = { [weak self] in self?.onSelectItem?(item.number) }
            addSubview(view)
            return view
        }
        hint.set(model.hint)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func editClicked() { onEdit?() }

    /// `padding: 8 10 9 12`, gap 8: header 22, the list (gap 6), the hint.
    public func height(for width: CGFloat) -> CGFloat {
        let inner = width - zp(12) - zp(10) - zp(2)
        var height: CGFloat = 1 + zp(8) + zp(22)
        if !itemViews.isEmpty {
            height += zp(8) + itemViews.reduce(0) { $0 + $1.height(for: inner) } + CGFloat(itemViews.count - 1) * zp(6)
        }
        height += zp(8) + hint.height(for: inner) + zp(9) + 1
        return ceil(height)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(for: bounds.width > 0 ? bounds.width : zp(420)))
    }

    public override func layout() {
        super.layout()
        let x: CGFloat = 1 + zp(12)
        let inner = bounds.width - zp(12) - zp(10) - zp(2)
        let editSize = editButton.intrinsicContentSize
        editButton.frame = CGRect(x: bounds.width - 1 - zp(10) - editSize.width, y: 1 + zp(8), width: editSize.width, height: editSize.height)
        header.frame = CGRect(x: x, y: 1 + zp(8), width: max(0, editButton.frame.minX - zp(8) - x), height: zp(22))
        var y = header.frame.maxY
        for (index, view) in itemViews.enumerated() {
            y += index == 0 ? zp(8) : zp(6)
            let height = view.height(for: inner)
            view.frame = CGRect(x: x, y: y, width: inner, height: height)
            y += height
        }
        y += zp(8)
        hint.frame = CGRect(x: x, y: y, width: inner, height: hint.height(for: inner))
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        Draw.fill(CGRect(x: 1, y: 1, width: zp(2), height: bounds.height - zp(2)), Palette.amberDim)
    }

    var visibleTexts: [String] { notebookVisibleTexts() }
}

/// `.ann-item`: the 18 px amber number square spanning two rows, the note (12 px, 1.45) and the
/// dimmer coordinates line.
final class AnnotationItemView: HoverControl, NotebookTextProviding {
    let item: ImageAnnotationSummaryItem
    private let note: WrapLabel
    private static let noteLineHeight: CGFloat = round(12 * 1.45)

    init(item: ImageAnnotationSummaryItem) {
        self.item = item
        note = WrapLabel(item.note, style: TextStyle.mono(12, Palette.bone), lineHeight: Self.noteLineHeight)
        super.init(frame: .zero)
        setAccessibilityLabel("\(item.number) \(item.note)")
        setAccessibilityValue(item.coordinates)
    }

    var drawnTexts: [String] { [String(item.number), item.note, item.coordinates] }

    /// Grid `20px 1fr`, gap `2px 8px`: the note lines + 2 + the coordinates line (15).
    func height(for width: CGFloat) -> CGFloat {
        note.height(for: width - zp(28)) + zp(2) + zp(15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = CGRect(x: 0, y: 0, width: zp(18), height: zp(18))
        Draw.fill(box, Palette.amber)
        let number = TextStyle.mono(10.5, .black, .bold).string(String(item.number))
        Draw.text(number, x: box.midX - Draw.width(number) / 2, centerY: box.midY)
        let textX: CGFloat = zp(28)
        let noteHeight = note.height(for: bounds.width - textX)
        note.attributed.draw(with: CGRect(x: textX, y: 0, width: bounds.width - textX, height: noteHeight), options: [.usesLineFragmentOrigin])
        Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(item.coordinates), x: textX, centerY: noteHeight + zp(2) + zp(7.5),
                  maxWidth: bounds.width - textX)
    }
}
