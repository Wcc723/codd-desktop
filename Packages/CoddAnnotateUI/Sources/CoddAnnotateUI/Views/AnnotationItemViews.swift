import AppKit
import CoddUI

/// The selected item, expanded (`.ann-item.ia-ex`): number square, `RECT` chip + `框選`, `已選取`,
/// collapse `▾`; the X / Y / W / H fields (arrow X1 / Y1 / X2 / Y2, point and text X / Y); the
/// `說明 · Comment` area; `單位 px（原圖）· Del` and `[刪除]`.
final class ExpandedItemView: FlippedView, AnnotateTextShowing {
    private(set) var item: AnnotationDraft
    let header = RunLineView()
    let selectedHint = RunLineView([.text("已選取", AnnotateTheme.hint)])
    let collapseButton = BoardButton(.glyph("▾", size: 11), accessibilityLabel: "收合標註")
    private(set) var fields: [(CoordinateField, CoordField)] = []
    private var fieldLabels: [RunLineView] = []
    let commentLabel = RunLineView([.text("說明 · Comment", AnnotateTheme.fieldLabel)])
    let comment = CommentArea(accessibilityLabel: "說明")
    let footerHint = RunLineView([.text("單位 px（原圖）·", AnnotateTheme.hint), .gap(5), .kbd("Del")])
    let deleteButton = CoddButton("刪除", style: .bracket(.danger, small: true))

    /// Edits of this item (its `n` at the time) — the owner never applies them to another item.
    var onField: ((Int, CoordinateField, String) -> Void)?
    var onRevertField: ((Int, CoordinateField) -> Void)?
    var onComment: ((Int, String) -> Void)?
    var onCommentEscape: (() -> Void)?

    init(item: AnnotationDraft) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [header, selectedHint, collapseButton, commentLabel, comment, footerHint, deleteButton] as [NSView] {
            addSubview(view)
        }
        comment.onCommit = { [weak self] text in
            guard let self else { return }
            self.onComment?(self.item.n, text)
        }
        comment.onEscape = { [weak self] in self?.onCommentEscape?() }
        buildFields()
        update(item)
        comment.show(item.note, force: true)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var displayedText: String { "\(item.n)" }

    private func buildFields() {
        for (_, field) in fields { field.removeFromSuperview() }
        for label in fieldLabels { label.removeFromSuperview() }
        fields = []
        fieldLabels = []
        for (kind, title) in CoordinateField.fields(for: item.kind) {
            let field = CoordField(label: title)
            field.onCommit = { [weak self] text in
                guard let self else { return }
                self.onField?(self.item.n, kind, text)
            }
            field.onRevert = { [weak self] in
                guard let self else { return }
                self.onRevertField?(self.item.n, kind)
            }
            let label = RunLineView([.text(title, AnnotateTheme.fieldLabel)])
            fields.append((kind, field))
            fieldLabels.append(label)
            addSubview(label)
            addSubview(field)
        }
    }

    func field(_ kind: CoordinateField) -> CoordField? { fields.first { $0.0 == kind }?.1 }

    /// Drops the callbacks before the view leaves the panel: removing a field that is being edited
    /// ends its editing, and that late commit must not land on whatever item is selected next (the
    /// owner commits pending edits itself before it changes the selection).
    func detach() {
        onField = nil
        onRevertField = nil
        onComment = nil
        onCommentEscape = nil
        removeFromSuperview()
    }

    /// Shows `item`'s values; fields being typed in keep their text (`force` overrides).
    func update(_ item: AnnotationDraft, force: Bool = false) {
        let kindChanged = item.kind != self.item.kind
        self.item = item
        if kindChanged { buildFields() }
        header.set([.chip(item.kind.chipLabel, AnnotateTheme.typeChip(amber: true)), .gap(7), .text(item.kind.title, AnnotateTheme.typeName)])
        for (kind, field) in fields { field.show(kind.value(of: item), force: force) }
        comment.show(item.note, force: force)
        collapseButton.setAccessibilityLabel("收合標註 \(item.n)")
        setAccessibilityLabel("標註 \(item.n) · \(item.kind.title)（已選取）")
        needsDisplay = true
        needsLayout = true
    }

    /// `padding: 10px 10px 10px 8px` + 1 pt border; the 20 pt number column and its 8 pt gap.
    static var bodyX: CGFloat { 1 + az(8) + az(20) + az(8) }

    static func height(for kind: AnnotationKind) -> CGFloat {
        // header 22 · 9 · fields (15 + 4 + 26) · 9 · comment (15 + 4 + 68) · 9 · footer 22
        1 + az(10) + az(22) + az(9) + az(45) + az(9) + (az(15) + az(4) + CommentArea.preferredHeight) + az(9) + az(22) + az(10) + 1
    }

    override func layout() {
        super.layout()
        let x = Self.bodyX
        let width = max(0, bounds.width - x - az(11))
        var y: CGFloat = az(11)
        // Header row (min-height 22): chip + name … 已選取 · ▾
        collapseButton.frame = CGRect(x: x + width - az(22), y: y, width: az(22), height: az(22))
        let hintWidth = selectedHint.naturalWidth
        selectedHint.frame = CGRect(x: collapseButton.frame.minX - az(7) - hintWidth, y: y, width: hintWidth, height: az(22))
        header.frame = CGRect(x: x, y: y, width: max(0, selectedHint.frame.minX - az(7) - x), height: az(22))
        y += az(22) + az(9)
        // `.ia-xywh`: four columns, gap 6 (two fields keep their quarter width).
        let column = floor((width - az(18)) / 4)
        for (index, (_, field)) in fields.enumerated() {
            let fx = x + CGFloat(index) * (column + az(6))
            fieldLabels[index].frame = CGRect(x: fx, y: y, width: column, height: az(15))
            field.frame = CGRect(x: fx, y: y + az(19), width: column, height: az(26))
        }
        y += az(45) + az(9)
        commentLabel.frame = CGRect(x: x, y: y, width: width, height: az(15))
        comment.frame = CGRect(x: x, y: y + az(19), width: width, height: CommentArea.preferredHeight)
        y += az(19) + CommentArea.preferredHeight + az(9)
        let deleteSize = deleteButton.intrinsicContentSize
        deleteButton.frame = CGRect(x: x + width - deleteSize.width, y: y, width: deleteSize.width, height: az(22))
        footerHint.frame = CGRect(x: x, y: y, width: max(0, deleteButton.frame.minX - az(8) - x), height: az(22))
    }

    override func draw(_ dirtyRect: NSRect) {
        // `background: --bg-lift; border: 1px solid --amber-dim; box-shadow: inset 2px 0 0 --amber, 0 0 14px rgba(255,184,74,.06)`
        Draw.fill(bounds, Palette.bgLift)
        Draw.strokeRect(bounds, color: Palette.amberDim)
        Draw.fill(CGRect(x: 1, y: 1, width: az(2), height: bounds.height - 2), Palette.amber)
        drawNumber(item.n, at: CGPoint(x: az(9), y: az(11)), color: item.color)
    }
}

/// A collapsed item (`.ann-item.ia-row`): number, type chip, the note (one line, ellipsis) and
/// the coordinates line; a click selects it.
final class CollapsedItemRow: KeyFocusView, AnnotateTextShowing, KeyListRow {
    private(set) var item: AnnotationDraft
    var onSelect: (() -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    static var height: CGFloat { az(52) }

    init(item: AnnotationDraft) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var displayedText: String { "\(item.n) \(item.kind.chipLabel) \(noteText) \(item.coordinateText)" }

    /// `（尚無說明）` for an item without a comment yet (new copy).
    private var noteText: String { item.note.isEmpty ? "（尚無說明）" : item.note.replacingOccurrences(of: "\n", with: " ") }

    func update(_ item: AnnotationDraft) {
        self.item = item
        setAccessibilityLabel("標註 \(item.n) · \(item.kind.title)：\(noteText)")
        needsDisplay = true
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
    override func mouseDown(with event: NSEvent) { onSelect?() }

    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }

    /// ↑ ↓ step through the collapsed rows of the list (D21).
    var isKeyListRow: Bool { true }

    override func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 125 || event.keyCode == 126, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            KeyFocus.moveInList(from: self, by: event.keyCode == 125 ? 1 : -1)
            return true
        }
        return super.handleKey(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered { Draw.fill(bounds, Palette.bgSoft) }
        Draw.strokeRect(bounds, color: isHovered ? Palette.amberDim : Palette.lineBright)
        drawNumber(item.n, at: CGPoint(x: az(9), y: az(9)), color: item.color)
        let x = ExpandedItemView.bodyX
        let chip = AnnotateTheme.typeChip(amber: false)
        let chipWidth = chip.draw(item.kind.chipLabel, x: x, centerY: az(9) + az(8.5))
        let noteStyle = item.note.isEmpty ? AnnotateTheme.itemNote.with(color: Palette.dimmer) : AnnotateTheme.itemNote
        Draw.text(noteStyle.string(noteText), x: x + chipWidth + az(7), centerY: az(9) + az(8.5), maxWidth: max(0, bounds.width - x - chipWidth - az(7) - az(11)))
        Draw.text(AnnotateTheme.itemXY.string(item.coordinateText), x: x, centerY: az(9) + az(17) + az(2) + az(7.5), maxWidth: max(0, bounds.width - x - az(11)))
    }
}

/// `.ann-item .no`: 18 pt square with the black number, in the item's color (amber by default) so
/// the list matches the pins on the image.
@MainActor
func drawNumber(_ n: Int, at origin: CGPoint, color: AnnotationColor) {
    let rect = CGRect(x: origin.x, y: origin.y, width: az(18), height: az(18))
    Draw.fill(rect, AnnotateTheme.color(color))
    let number = AnnotateTheme.number.string("\(n)")
    Draw.text(number, x: rect.midX - Draw.width(number) / 2, centerY: rect.midY)
}

/// `.ia-ck`: a checkbox row (amber box with a black check when on; the label dims when off) with an
/// optional right-aligned hint (`9f3a1c.png`). Click / Space / VoiceOver toggle it.
final class SendOptionRow: KeyFocusView, AnnotateTextShowing {
    let title: String
    var hint: String? { didSet { needsDisplay = true; setAccessibilityHelp(hint) } }
    var isOn: Bool { didSet { if isOn != oldValue { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } } }
    var onToggle: ((Bool) -> Void)?
    static var height: CGFloat { az(18) }

    init(title: String, hint: String? = nil, isOn: Bool) {
        self.title = title
        self.hint = hint
        self.isOn = isOn
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        setAccessibilityHelp(hint)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var displayedText: String { [title, hint].compactMap { $0 }.joined(separator: " ") }

    func toggle() {
        isOn.toggle()
        onToggle?(isOn)
    }

    override func mouseDown(with event: NSEvent) { toggle() }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        // `input{margin-top:2px}`: a 13 pt box at the top of the 17.4 pt line.
        let box = CGRect(x: 0, y: az(2.5), width: az(13), height: az(13))
        if isOn {
            Draw.fill(box, Palette.amber)
            let mark = TextStyle.mono(10, .black, .bold).string("✓")
            Draw.text(mark, x: box.midX - Draw.width(mark) / 2, centerY: box.midY)
        } else {
            Draw.fill(box, Palette.bg)
            Draw.strokeRect(box, color: Palette.dimmer)
        }
        var hintWidth: CGFloat = 0
        if let hint, !hint.isEmpty {
            let text = AnnotateTheme.hint.string(hint)
            hintWidth = Draw.width(text)
            Draw.text(text, x: bounds.width - hintWidth, centerY: bounds.midY)
        }
        let style = AnnotateTheme.check.with(color: isOn ? Palette.bone : Palette.dim)
        Draw.text(style.string(title), x: box.maxX + az(9), centerY: bounds.midY,
                  maxWidth: max(0, bounds.width - box.maxX - az(9) - (hintWidth > 0 ? hintWidth + az(9) : 0)))
    }
}
