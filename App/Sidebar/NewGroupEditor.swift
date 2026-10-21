import AppKit
import CoddUI

/// The inline new-group editor's state (SidebarStates D), owned by the sidebar controller while it
/// is open. Enter creates the group (a blank name becomes `新群組`), Esc cancels; the color starts at
/// the first color no group uses yet; while the color popover is open, 1–8 pick a color (0 = none).
@MainActor
final class NewGroupEditor {
    static let fallbackName = "新群組"

    var name = ""
    var color: TagColor?
    var isColorPopoverOpen = false

    init(color: TagColor?) {
        self.color = color
    }

    /// The first tag color no group uses, else cyan (the artboard's example).
    static func defaultColor(in store: any SessionStore) -> TagColor? {
        let used = Set(store.groups.compactMap(\.color))
        return TagColor.allCases.first { !used.contains($0) } ?? .cyan
    }

    /// What Enter creates.
    var committedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.fallbackName : trimmed
    }

    /// `群組顏色：cyan` (the color button's accessibility label).
    var colorButtonLabel: String { "群組顏色：\(color?.rawValue ?? "無顏色")" }

    /// A typed character while the popover is open: `1`…`8` pick that swatch, `0` no color (the
    /// popover then closes). Returns whether it was taken (it is not typed into the name).
    func pickDigit(_ text: String) -> Bool {
        guard isColorPopoverOpen, text.count == 1, let digit = Int(text) else { return false }
        if digit == 0 {
            color = nil
        } else if digit <= TagColor.allCases.count {
            color = TagColor.allCases[digit - 1]
        } else {
            return false
        }
        isColorPopoverOpen = false
        return true
    }
}

/// The name input of the new-group row. Digits go to the color popover while it is open (unless an
/// input method is composing: 注音 uses the number keys for tones and candidates).
final class NewGroupNameField: NSTextField {
    var onDigit: ((String) -> Bool)?

    /// The field editor asks its delegate (this field) before every edit. The field has no
    /// formatter, so every other edit is allowed.
    @objc(textView:shouldChangeTextInRange:replacementString:)
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if let replacementString, !textView.hasMarkedText(), onDigit?(replacementString) == true { return false }
        return true
    }
}

/// `[■▾]` color button of the new-group row (`.ss-cbtn`): the 10 px glowing tag square and `▾`.
final class GroupColorButton: NSButton {
    var color: TagColor? { didSet { if color != oldValue { needsDisplay = true } } }
    var isOpen = false { didSet { if isOpen != oldValue { needsDisplay = true } } }

    init() {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        // Clicking it must never take the focus from the name input.
        refusesFirstResponder = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 5 + 10 + 4 + 8 + 5, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: isOpen ? Palette.amber : Palette.amberDim)
        let square = CGRect(x: 5, y: round(bounds.midY - 5), width: 10, height: 10)
        if let color {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = color.color
            glow.shadowBlurRadius = 6
            glow.shadowOffset = .zero
            glow.set()
            Draw.fill(square, color.color)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Draw.strokeRect(square, color: Palette.lineBright)
        }
        Draw.text(TextStyle.mono(9, Palette.amber).string("▾"), x: square.maxX + 4, centerY: bounds.midY)
    }
}

/// The new-group row (SidebarStates D `.ss-newblk` + `.ss-newgrp`): a block tinted with the
/// chosen color, the color button, the focused name input (`群組名稱`) and a `⏎` kbd.
final class NewGroupCellView: SidebarCellView, NSTextFieldDelegate {
    static let identifier = NSUserInterfaceItemIdentifier("newGroup")
    /// `.ss-newblk{margin-top:8px}` above a 34 px row inside a 1 px block border.
    static let rowHeight: CGFloat = 8 + 34 + 2
    static let topGap: CGFloat = 8

    let colorButton = GroupColorButton()
    let field = NewGroupNameField()
    private let fieldBox = PanelView(fill: Palette.bgSoft, edges: [.top, .bottom, .left, .right], edgeColor: Palette.amber)
    private let kbd = ChipView.kbd("⏎")
    /// Set while the controller ends the editor, so the field's end-of-editing is not a focus loss.
    private var ending = false

    /// The row while a group is being named (M5 D21; the field and the color button are its children).
    override var spokenLabel: String? { "新群組" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(12)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(12, Palette.dimmer).string("群組名稱")
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.setAccessibilityLabel("新群組名稱")
        fieldBox.addSubview(field)
        // `.input.focus`: amber border + inset 1 px amber + an 8 px amber glow.
        let glow = NSShadow()
        glow.shadowColor = Palette.amberGlow
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        fieldBox.shadow = glow
        colorButton.target = self
        colorButton.action = #selector(colorClicked)
        for view in [colorButton, fieldBox, kbd] as [NSView] { addSubview(view) }
        field.onDigit = { [weak self] text in self?.env?.controller?.newGroupDigit(text) ?? false }
    }

    var editor: NewGroupEditor? { env?.controller?.newGroupEditor }

    override func refresh() {
        guard let env, let editor else { return }
        _ = env.shell.isAddingGroup // re-run when the editor opens or closes
        colorButton.color = editor.color
        colorButton.isOpen = editor.isColorPopoverOpen
        colorButton.setAccessibilityLabel(editor.colorButtonLabel)
        if field.stringValue != editor.name, field.currentEditor() == nil { field.stringValue = editor.name }
        decoration = RowDecoration(block: editor.color.map(BlockStyle.tinted) ?? .ungrouped, hover: .none, topGap: Self.topGap)
    }

    /// Pulls the editor state in again (the controller changed the color or the popover).
    func sync() {
        guard let editor else { return }
        colorButton.color = editor.color
        colorButton.isOpen = editor.isColorPopoverOpen
        colorButton.setAccessibilityLabel(editor.colorButtonLabel)
        decoration = RowDecoration(block: editor.color.map(BlockStyle.tinted) ?? .ungrouped, hover: .none, topGap: Self.topGap)
        (superview as? SidebarRowView)?.needsDisplay = true
    }

    func focus() {
        // Already editing: making the field first responder again would end that editing (and the
        // end would read as a focus loss).
        if let editor = field.currentEditor(), window?.firstResponder === editor { return }
        window?.makeFirstResponder(field)
        (field.currentEditor() as? NSTextView)?.insertionPointColor = Palette.amber
    }

    /// The controller is closing the editor: the field's end of editing that follows is expected.
    func prepareToEnd() { ending = true }

    override func layout() {
        super.layout()
        let centerY = Self.topGap + 1 + 17
        var x = contentLeft + 6
        let colorSize = colorButton.intrinsicContentSize
        colorButton.frame = CGRect(x: x, y: centerY - colorSize.height / 2, width: colorSize.width, height: colorSize.height)
        x += colorSize.width + 6
        let kbdSize = kbd.intrinsicContentSize
        let kbdX = contentRight - 6 - kbdSize.width
        kbd.frame = CGRect(x: kbdX, y: centerY - kbdSize.height / 2, width: kbdSize.width, height: kbdSize.height)
        fieldBox.frame = CGRect(x: x, y: centerY - 12, width: max(40, kbdX - 6 - x), height: 24)
        field.frame = CGRect(x: 8, y: 4, width: max(20, fieldBox.frame.width - 16), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The inset 1 px amber of `.input.focus` (the box draws the outer 1 px).
        Draw.strokeRect(fieldBox.frame.insetBy(dx: 1, dy: 1), color: Palette.amber)
    }

    @objc private func colorClicked() { env?.controller?.toggleNewGroupColorPopover() }

    // MARK: NSTextFieldDelegate (after the input method: IME-safe)

    func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
    }

    func controlTextDidChange(_ obj: Notification) {
        editor?.name = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            editor?.name = field.stringValue
            env?.controller?.commitNewGroup()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            env?.controller?.cancelNewGroup()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !ending else { return }
        editor?.name = field.stringValue
        env?.controller?.newGroupFocusLost()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ending = false }
    }
}

/// `.pop.ss-cpop` color popover under the new-group row: `COLOR · 群組顏色`, the 8 swatches + none
/// with their numbers (the current one amber), `1–8 快速選色`. A child panel that never becomes
/// key, so the name input keeps the focus; clicks pick a swatch.
final class GroupColorPopoverView: NSView {
    var current: TagColor? { didSet { if current != oldValue { needsDisplay = true } } }
    var onPick: ((TagColor?) -> Void)?
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?
    /// M5 D21: one VoiceOver radio button per swatch (keys 1–8 pick them too).
    private var swatchElements: [DrawnRowElement] = []

    override func accessibilityChildren() -> [Any]? {
        swatchElements = drawnRowElements(reusing: swatchElements, role: .radioButton)
        return swatchElements
    }

    static let size = CGSize(width: 10 + 9 * 20 + 8 * 6 + 10, height: 10 + 14 + 8 + 34 + 8 + 15 + 9)
    private static let swatchTop: CGFloat = 10 + 14 + 8

    private var options: [TagColor?] { TagColor.allCases.map { Optional($0) } + [nil] }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.group)
        setAccessibilityLabel("選擇群組顏色")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func rect(at index: Int) -> CGRect {
        CGRect(x: 10 + CGFloat(index) * 26, y: Self.swatchTop, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return options.indices.first { rect(at: $0).insetBy(dx: -3, dy: -3).contains(point) }
    }

    override func mouseMoved(with event: NSEvent) {
        let i = index(at: event)
        if i != hovered { hovered = i; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        onPick?(options[i])
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.amberDim)
        Draw.text(TextStyle.caps(10.5, Palette.dim, tracking: 0.16).string("Color · 群組顏色"), x: 10, centerY: 10 + 7)
        for (i, option) in options.enumerated() {
            let r = rect(at: i)
            if let option {
                Draw.fill(r, option.color)
            } else {
                Draw.strokeRect(r, color: Palette.lineBright)
                let slash = NSBezierPath()
                slash.move(to: CGPoint(x: r.minX + 4, y: r.maxY - 4))
                slash.line(to: CGPoint(x: r.maxX - 4, y: r.minY + 4))
                slash.lineWidth = 1.5
                Palette.dim.setStroke()
                slash.stroke()
            }
            if option == current {
                Draw.strokeRect(r, color: Palette.cream)
                Draw.strokeRect(r.insetBy(dx: -3, dy: -3), color: Palette.amber)
            } else if hovered == i {
                Draw.strokeRect(r.insetBy(dx: -2, dy: -2), color: Palette.dim)
            }
            if option != nil {
                let number = TextStyle.mono(10.5, option == current ? Palette.amber : Palette.dim).string("\(i + 1)")
                Draw.text(number, x: r.midX - Draw.width(number) / 2, centerY: r.maxY + 3 + 5.5)
            }
        }
        Draw.text(TextStyle.mono(11.5, Palette.dimmer, tracking: 0.02).string("1–8 快速選色"), x: 10,
                  centerY: Self.swatchTop + 34 + 8 + 7.5)
    }
}

/// The panel that carries `GroupColorPopoverView` (child of the main window, never key).
final class GroupColorPopoverPanel: NSPanel {
    let popover = GroupColorPopoverView(frame: CGRect(origin: .zero, size: GroupColorPopoverView.size))

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: GroupColorPopoverView.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.transient, .ignoresCycle]
        contentView = popover
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Under the new-group block, at the sidebar's inner left edge (`top:4px;left:0`); above the
    /// row when there is no room below it in the window.
    static func place(size: CGSize, rowOnScreen row: CGRect, sidebarMinX: CGFloat, windowFrame: CGRect) -> CGRect {
        var origin = CGPoint(x: sidebarMinX + Metrics.sidebarInset, y: row.minY - 4 - size.height)
        if origin.y < windowFrame.minY + 4 { origin.y = row.maxY + 4 }
        return CGRect(origin: origin, size: size)
    }
}

// MARK: Accessibility (M5 D21)

extension GroupColorPopoverView: DrawnRowsHost {
    var drawnRowCount: Int { options.count }
    func drawnRowLabel(_ index: Int) -> String? { swatchSpokenName(options.indices.contains(index) ? options[index] : nil) }
    func drawnRowFrame(_ index: Int) -> CGRect { rect(at: index) }
    func isDrawnRowSelected(_ index: Int) -> Bool { options.indices.contains(index) && options[index] == current }
    func pressDrawnRow(_ index: Int) { if options.indices.contains(index) { onPick?(options[index]) } }
}
