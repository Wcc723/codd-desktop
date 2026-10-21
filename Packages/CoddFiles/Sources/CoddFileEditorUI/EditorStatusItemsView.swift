import AppKit
import CoddUI

/// The editor's items of the app status bar (`.statusbar`, 10.5 px dim, gap 14), between the MCP
/// item and `⌘K`: `⎇ feat/punch-rwd ↑2`, `▪ <session> 正在編輯此專案`, a flexible gap, then the
/// clickable `Ln 42, Col 18` · `UTF-8` · `LF` · `Vue` · `2 spaces` (`.fe-sbb`, amber on hover)
/// and `● 已儲存 10:39`. Transparent: the app's bar draws the background.
public final class EditorStatusItemsView: FlippedView {
    public private(set) var model: EditorStatusModel
    public var onItem: ((EditorStatusItem) -> Void)?

    private(set) var buttonFrames: [(EditorStatusItem, CGRect)] = []
    private var hovered: EditorStatusItem?
    private var trackingArea: NSTrackingArea?

    public init(model: EditorStatusModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: fz(900), height: Metrics.statusBarHeight))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Items that do not fit are left out (`shownItems`), never drawn over the bar's MCP item.
        clipsToBounds = true
        setContentHuggingPriority(.init(1), for: .horizontal)
        // Above a label's (250): in a narrow bar the MCP endpoint truncates before the position,
        // language and save state; below the window's stay-put (500).
        setContentCompressionResistancePriority(.init(255), for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The essentials' width (position, language, the save state); the bar may give it more.
    public override var intrinsicContentSize: NSSize {
        var width = Draw.width(Self.base.string(text(.position))) + fz(14) + Draw.width(Self.base.string(text(.language)))
        if let saved = savedWidth { width += fz(14) + saved }
        return NSSize(width: ceil(width), height: Metrics.statusBarHeight)
    }

    public func update(_ model: EditorStatusModel) {
        guard model != self.model else { return }
        self.model = model
        updateAccessibility()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private var savedWidth: CGFloat? {
        guard let saved = savedParts() else { return nil }
        var width = Draw.width(Self.base.string(saved.text))
        if saved.dot != nil { width += Draw.width(Self.base.string("● ")) }
        return width
    }

    /// The right-hand items that fit (a narrow bar drops the indentation, the line ending, the
    /// encoding, then the language, before the position).
    func shownItems() -> [EditorStatusItem] {
        var items = EditorStatusItem.allCases
        let gap = fz(14)
        func need(_ items: [EditorStatusItem]) -> CGFloat {
            items.reduce(CGFloat(0)) { $0 + Draw.width(Self.base.string(text($1))) + gap } + (savedWidth.map { $0 + gap } ?? 0)
        }
        for drop in [EditorStatusItem.indentation, .lineEnding, .encoding, .language] where need(items) > bounds.width {
            items.removeAll { $0 == drop }
        }
        return items
    }

    private static let base = TextStyle.mono(10.5, Palette.dim, tracking: 0.04)

    private func text(_ item: EditorStatusItem) -> String {
        switch item {
        case .position: "Ln \(model.line), Col \(model.column)"
        case .encoding: model.encoding
        case .lineEnding: model.lineEnding
        case .language: model.language
        case .indentation: model.indentation
        }
    }

    private func savedParts() -> (dot: NSColor?, text: String)? {
        switch model.saved {
        case .saved(let time): (Palette.amberDim, "已儲存 \(time)")
        case .dirty: (Palette.amber, "未儲存")
        case .readOnly: (nil, "唯讀")
        case .none: nil
        }
    }

    private func updateAccessibility() {
        var parts: [String] = []
        if let branch = model.branch { parts.append("分支 \(branch)") }
        parts += EditorStatusItem.allCases.map(text)
        setAccessibilityLabel(parts.joined(separator: "，"))
    }

    /// Lays the right-hand items out from the right edge (also used for hit tests).
    func computeButtonFrames() -> [(EditorStatusItem, CGRect)] {
        var right = bounds.width
        if let saved = savedWidth { right -= saved + fz(14) }
        var out: [(EditorStatusItem, CGRect)] = []
        for item in shownItems().reversed() {
            let width = Draw.width(Self.base.string(text(item)))
            out.insert((item, CGRect(x: right - width, y: 0, width: width, height: bounds.height)), at: 0)
            right -= width + fz(14)
        }
        return out
    }

    public override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        buttonFrames = computeButtonFrames()
        let limit = (buttonFrames.first?.1.minX ?? bounds.width) - fz(14)
        var x: CGFloat = 0
        if let branch = model.branch {
            let label = "⎇ \(branch)" + (model.ahead > 0 ? " ↑\(model.ahead)" : "")
            x += Draw.text(Self.base.string(label), x: x, centerY: mid, maxWidth: max(0, limit - x)) + fz(14)
        }
        if let session = model.session, x + fz(14) + fz(40) < limit {
            Parts.drawTag(session.tag, x: x, centerY: mid)
            x += fz(8) + fz(6)
            x += Draw.text(Self.base.string("\(session.title) 正在編輯此專案"), x: x, centerY: mid, maxWidth: max(0, limit - x)) + fz(14)
        }
        for (item, frame) in buttonFrames {
            Draw.text(Self.base.with(color: hovered == item ? Palette.amber : Palette.dim).string(text(item)), x: frame.minX, centerY: mid)
        }
        if let saved = savedParts() {
            var sx = (buttonFrames.last?.1.maxX ?? 0) + fz(14)
            if let dot = saved.dot { sx += Draw.text(Self.base.with(color: dot).string("● "), x: sx, centerY: mid) }
            Draw.text(Self.base.string(saved.text), x: sx, centerY: mid)
        }
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) { click(at: convert(event.locationInWindow, from: nil)) }

    /// A click at `point` (tests call this directly).
    func click(at point: CGPoint) {
        guard let hit = computeButtonFrames().first(where: { $0.1.contains(point) }) else { return }
        onItem?(hit.0)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let item = computeButtonFrames().first { $0.1.contains(point) }?.0
        guard item != hovered else { return }
        hovered = item
        needsDisplay = true
    }

    public override func mouseExited(with event: NSEvent) {
        hovered = nil
        needsDisplay = true
    }

    // MARK: Keyboard and VoiceOver (D21)

    /// A key view while Full Keyboard Access is on: ← → move over the clickable items (outlined
    /// like a hover), ⏎ / space press the one under the cursor.
    public override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: !shownItems().isEmpty, refuses: false) }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    public override func becomeFirstResponder() -> Bool {
        hovered = shownItems().first
        needsDisplay = true
        return true
    }

    public override func resignFirstResponder() -> Bool {
        hovered = nil
        needsDisplay = true
        return true
    }

    public override func keyDown(with event: NSEvent) {
        guard window?.firstResponder === self, event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return super.keyDown(with: event)
        }
        let items = shownItems()
        let index = hovered.flatMap { items.firstIndex(of: $0) } ?? 0
        switch event.keyCode {
        case 123, 124:
            let next = min(max(0, index + (event.keyCode == 124 ? 1 : -1)), items.count - 1)
            if items.indices.contains(next) { hovered = items[next]; needsDisplay = true }
        case 36, 76, 49:
            if items.indices.contains(index) { onItem?(items[index]) }
        default:
            super.keyDown(with: event)
        }
    }

    private var itemElements: [DrawnItemElement] = []

    /// One button per shown item (`Ln 42, Col 18`, `UTF-8`, …); the group keeps the whole line
    /// as its label.
    public override func accessibilityChildren() -> [Any]? {
        let count = shownItems().count
        if itemElements.count != count { itemElements = (0..<count).map { DrawnItemElement(host: self, index: $0) } }
        return itemElements
    }
}

extension EditorStatusItemsView: DrawnItemsHost {
    var drawnItemCount: Int { shownItems().count }

    func drawnItemLabel(_ index: Int) -> String? {
        let items = shownItems()
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        let name = switch item {
        case .position: "游標位置"
        case .encoding: "編碼"
        case .lineEnding: "行尾"
        case .language: "語言"
        case .indentation: "縮排"
        }
        return "\(name) \(text(item))"
    }

    func drawnItemFrame(_ index: Int) -> CGRect {
        let frames = computeButtonFrames()
        return frames.indices.contains(index) ? frames[index].1 : .zero
    }

    func pressDrawnItem(_ index: Int) {
        let items = shownItems()
        if items.indices.contains(index) { onItem?(items[index]) }
    }
}
