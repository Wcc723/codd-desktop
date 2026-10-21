import AppKit
import CoddOnboarding
import CoddUI

/// The row's group menu (`.menu.ob-gmenu`, 248 px), opening above its select: `移到群組 · GROUP`, each
/// group with its square (dashed for 未分類), `建議` on the suggestion, `✓` on the current one, a
/// dashed separator, `+ 新群組… 命名後套用` (naming inline). An overlay view inside the window (no
/// child window, no NSMenu), so snapshots and background runs need nothing special. A click outside
/// or esc closes it; ↑ / ↓ move, ⏎ picks.
final class GroupMenuOverlay: NSView {
    let panel = GroupMenuPanel()
    private(set) var path: String?
    /// The select's frame in this view's coordinates.
    var anchor: CGRect {
        get { storedAnchor }
        set { if newValue != storedAnchor { storedAnchor = newValue; needsLayout = true } }
    }
    private var storedAnchor = CGRect.zero
    var onPick: (String, String) -> Void = { _, _ in }
    var onCreate: (String, String) -> Void = { _, _ in }
    var onClose: () -> Void = {}
    /// The select's current frame (asked at every layout, so a resize or a scroll keeps the menu on it).
    var anchorProvider: () -> CGRect? = { nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(panel)
        isHidden = true
        panel.onPick = { [weak self] key in
            guard let self, let path = self.path else { return }
            self.onPick(path, key)
        }
        panel.onCreate = { [weak self] name in
            guard let self, let path = self.path else { return }
            self.onCreate(path, name)
        }
        panel.onCancel = { [weak self] in self?.onClose() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var isOpen: Bool { !isHidden }

    func show(path: String, model: ImportStepModel, anchor: CGRect) {
        self.path = path
        self.anchor = anchor
        let current = model.selection.groupKey(for: path)
        panel.configure(options: model.options, current: current, suggested: model.suggestion[path])
        isHidden = false
        needsLayout = true
    }

    func hide() {
        path = nil
        panel.stopNaming()
        isHidden = true
    }

    override func layout() {
        super.layout()
        if isOpen, let current = anchorProvider() { storedAnchor = current }
        let size = panel.preferredSize
        var y = storedAnchor.minY - dz(4) - size.height
        if y < dz(8) { y = storedAnchor.maxY + dz(4) }
        let x = max(dz(8), min(storedAnchor.maxX - size.width, bounds.width - size.width - dz(8)))
        panel.place(CGRect(x: x, y: y, width: size.width, height: size.height))
    }

    /// Clicks outside the panel close the menu (and are not passed on).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        if panel.frame.contains(local) { return super.hitTest(point) }
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClose() }

    override var acceptsFirstResponder: Bool { isOpen }

    override func keyDown(with event: NSEvent) {
        if !panel.handle(event) { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onClose() }
}

/// The menu box (`.menu`: --bg-lift, 1 px --amber-dim, padding 4, a dark drop shadow).
final class GroupMenuPanel: NSView, OnboardingTextShowing {
    private(set) var items: [GroupMenuItemView] = []
    let newItem = GroupMenuItemView(kind: .new)
    let nameField = InputField(placeholder: "群組名稱", size: 12, accessibilityLabel: "新群組名稱")
    private(set) var isNaming = false
    private(set) var highlighted = 0 { didSet { if highlighted != oldValue { updateHighlight() } } }
    var onPick: (String) -> Void = { _ in }
    var onCreate: (String) -> Void = { _ in }
    var onCancel: () -> Void = {}

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 30
        shadow.shadowOffset = NSSize(width: 0, height: -10)
        self.shadow = shadow
        addSubview(newItem)
        newItem.onPress = { [weak self] in self?.startNaming() }
        newItem.onHover = { [weak self] in
            guard let self else { return }
            self.highlighted = self.items.count
        }
        nameField.isHidden = true
        nameField.onCommand = { [weak self] selector in
            guard let self else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                let name = self.nameField.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { self.onCreate(name) }
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                self.stopNaming()
                self.window?.makeFirstResponder(self.superview)
                return true
            }
            return false
        }
        addSubview(nameField)
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        setAccessibilityLabel("選擇群組")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { items + [isNaming ? nameField.field : newItem] }

    var displayedText: String { (["移到群組 · GROUP"] + items.map(\.displayedText) + [newItem.displayedText]).joined(separator: "\n") }

    func configure(options: [GroupOption], current: String, suggested: String?) {
        for item in items { item.removeFromSuperview() }
        items = options.map { option in
            let item = GroupMenuItemView(kind: .group(option, suggested: option.key == suggested, current: option.key == current))
            item.onPress = { [weak self] in self?.onPick(option.key) }
            addSubview(item)
            return item
        }
        for item in items { item.onHover = { [weak self, weak item] in
            guard let self, let item, let index = self.items.firstIndex(where: { $0 === item }) else { return }
            self.highlighted = index
        } }
        stopNaming()
        highlighted = options.firstIndex { $0.key == current } ?? 0
        updateHighlight()
        needsLayout = true
    }

    func startNaming() {
        isNaming = true
        newItem.isHidden = true
        nameField.isHidden = false
        nameField.text = ""
        needsLayout = true
        superview?.needsLayout = true
        window?.makeFirstResponder(nameField.field)
    }

    func stopNaming() {
        isNaming = false
        newItem.isHidden = false
        nameField.isHidden = true
        needsLayout = true
        superview?.needsLayout = true
    }

    /// `.mh`: 9.5 caps .2em, padding 6 10 4.
    static var headerHeight: CGFloat { ceil(dz(6) + UIZoom.scaled(9.5 * 1.5) + dz(4)) }
    static var itemHeight: CGFloat { dz(28) }
    /// `.sep`: 1 px dashed, margin 4 2.
    static var separatorHeight: CGFloat { dz(9) }
    static var nameRowHeight: CGFloat { dz(30) + dz(4) }

    var preferredSize: CGSize {
        let last = isNaming ? Self.nameRowHeight : Self.itemHeight
        let height = 2 + dz(8) + Self.headerHeight + Self.itemHeight * CGFloat(items.count) + Self.separatorHeight + last
        return CGSize(width: dz(248), height: height)
    }

    private var separatorY: CGFloat { 1 + dz(4) + Self.headerHeight + Self.itemHeight * CGFloat(items.count) }

    override func layout() {
        super.layout()
        let x = 1 + dz(4)
        let width = bounds.width - 2 - dz(8)
        var y = 1 + dz(4) + Self.headerHeight
        for item in items {
            item.place(CGRect(x: x, y: y, width: width, height: Self.itemHeight))
            y += Self.itemHeight
        }
        y += Self.separatorHeight
        newItem.place(CGRect(x: x, y: y, width: width, height: Self.itemHeight))
        nameField.frame = CGRect(x: x + dz(2), y: y + dz(2), width: width - dz(4), height: dz(30))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgLift)
        Draw.strokeRect(bounds, color: Palette.amberDim)
        let header = TextStyle.caps(9.5, Palette.dim, tracking: 0.2)
        let top = 1 + dz(4)
        Draw.text(header.string("移到群組 · GROUP"), x: 1 + dz(4) + dz(10), centerY: top + dz(6) + UIZoom.scaled(9.5 * 1.5) / 2)
        let sep = separatorY + dz(4)
        Draw.dashedLine(from: CGPoint(x: 1 + dz(6), y: sep), to: CGPoint(x: bounds.width - 1 - dz(6), y: sep), color: Palette.lineBright)
    }

    private func updateHighlight() {
        for (index, item) in items.enumerated() { item.isHighlighted = index == highlighted }
        newItem.isHighlighted = highlighted == items.count && !isNaming
    }

    /// Menu keys; returns whether the event was used.
    func handle(_ event: NSEvent) -> Bool {
        let count = items.count + 1
        if event.specialKey == .upArrow { highlighted = (highlighted - 1 + count) % count; return true }
        if event.specialKey == .downArrow { highlighted = (highlighted + 1) % count; return true }
        if event.specialKey == .carriageReturn || event.specialKey == .enter || event.charactersIgnoringModifiers == " " {
            if highlighted < items.count { items[highlighted].onPress() } else { startNaming() }
            return true
        }
        if event.keyCode == 53 { onCancel(); return true }
        return false
    }
}

/// One `.mi` (28 px, padding 0 10, gap 9; `.hl`: --bg-raise with the 2 px amber inset bar, cream).
final class GroupMenuItemView: NSView, OnboardingTextShowing {
    enum Kind: Equatable {
        case group(GroupOption, suggested: Bool, current: Bool)
        case new
    }

    let kind: Kind
    var isHighlighted = false { didSet { if isHighlighted != oldValue { needsDisplay = true } } }
    var onPress: () -> Void = {}
    var onHover: () -> Void = {}
    private var trackingArea: NSTrackingArea?

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        switch kind {
        case .group(let option, let suggested, let current):
            var label = option.name
            if suggested { label += "（建議）" }
            if current { label += "，目前的群組" }
            setAccessibilityLabel(label)
        case .new:
            setAccessibilityLabel("新群組…，命名後套用")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var displayedText: String {
        switch kind {
        case .group(let option, let suggested, let current):
            return [option.name, suggested ? "建議" : nil, current ? "✓" : nil].compactMap { $0 }.joined(separator: " ")
        case .new:
            return "+ 新群組… 命名後套用"
        }
    }

    /// The `建議` chip (`.chip.amber.ob-sug`: 16 px, 9.5 px, padding 0 5, margin-left 2).
    static var suggestionChip: ChipStyle {
        var style = ChipStyle.chip(.amber, mini: true)
        style.height = 16
        return style
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            Draw.fill(bounds, Palette.bgRaise)
            Draw.fill(CGRect(x: 0, y: 0, width: dz(2), height: bounds.height), Palette.amber)
        }
        let mid = bounds.midY
        let text = TextStyle.mono(12, isHighlighted ? Palette.cream : Palette.bone)
        var x = dz(10)
        switch kind {
        case .group(let option, let suggested, let current):
            let tag = CGRect(x: x, y: (mid - dz(4)).rounded(), width: dz(8), height: dz(8))
            TagColor.drawSquare(option.color, in: tag)
            x = tag.maxX + dz(9)
            var right = bounds.width - dz(10)
            if current {
                let check = TextStyle.mono(10.5, Palette.amber).string("✓")
                right -= Draw.width(check)
                Draw.text(check, x: right, centerY: mid)
                right -= dz(9)
            }
            let chipWidth = suggested ? Self.suggestionChip.size(for: "建議").width + dz(2) + dz(9) : 0
            x += Draw.text(text.string(option.name), x: x, centerY: mid, maxWidth: max(0, right - x - chipWidth))
            if suggested { Self.suggestionChip.draw("建議", x: x + dz(9) + dz(2), centerY: mid) }
        case .new:
            let plus = TextStyle.mono(12, Palette.dim).string("+")
            Draw.text(plus, x: x + (dz(14) - Draw.width(plus)) / 2, centerY: mid)
            x += dz(14) + dz(9)
            Draw.text(text.string("新群組…"), x: x, centerY: mid)
            let hint = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04).string("命名後套用")
            Draw.text(hint, x: bounds.width - dz(10) - Draw.width(hint), centerY: mid)
        }
    }

    override func mouseDown(with event: NSEvent) { onPress() }

    override func accessibilityPerformPress() -> Bool {
        onPress()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover() }
}
