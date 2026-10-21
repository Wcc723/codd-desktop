import AppKit
import CoddUI

/// A square `.icon-btn` with one of the board's icons or a text glyph, and optionally the tool
/// strip's key letter in its corner (`.ia-tool .ia-k`). Transparent; hover = amber + line-bright
/// border; `.on` = amber, --amber-dim border and the inset glow; disabled at 40 %.
final class BoardButton: KeyFocusView {
    enum Content {
        case icon(AnnotateIcon, size: CGFloat)
        case glyph(String, size: CGFloat)
    }

    let content: Content
    let keyLetter: String?
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } } }
    var isEnabled = true { didSet { if isEnabled != oldValue { needsDisplay = true; setAccessibilityEnabled(isEnabled) } } }
    var onPress: (() -> Void)?
    private(set) var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(_ content: Content, keyLetter: String? = nil, accessibilityLabel: String) {
        self.content = content
        self.keyLetter = keyLetter
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }

    /// A click (also VoiceOver's press and the tests).
    func press() {
        guard isEnabled else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        press()
        return true
    }

    override var acceptsKeyFocus: Bool { isEnabled }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.4)
        let hot = isHovered && isEnabled
        if isOn {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.08))
            Draw.strokeRect(bounds, color: Palette.amberDim)
        } else if hot {
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
        if isPressed { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.1)) }
        let color = (hot || isOn) ? Palette.amber : Palette.dim
        switch content {
        case .icon(let icon, let size):
            icon.draw(in: CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size), color: color)
        case .glyph(let glyph, let size):
            let text = TextStyle.mono(size, color).string(glyph)
            Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
        }
        if let keyLetter {
            // `.ia-k{right:2px;bottom:1px;font-size:9px;line-height:1}`
            let key = TextStyle.mono(9, isOn ? Palette.amberDim : Palette.dim).string(keyLetter)
            Draw.text(key, x: bounds.width - 2 - Draw.width(key), centerY: bounds.height - 1 - az(4.5))
        }
    }
}

/// `.ia-color`: a 36 pt square with the current annotation color (`.sq`, 14 pt, black ring and glow).
final class ColorSwatchButton: KeyFocusView {
    var color: AnnotationColor = .amber {
        didSet { if color != oldValue { needsDisplay = true; setAccessibilityLabel("標註顏色：\(color.title)") } }
    }
    var onPress: (() -> Void)?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("標註顏色：\(color.title)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { onPress?() }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    /// Space, ⏎ and ↓ open the color menu (a pop-up button).
    override func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 125, event.modifierFlags.intersection([.command, .option, .control]).isEmpty { return accessibilityPerformPress() }
        return super.handleKey(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.strokeRect(bounds, color: isHovered ? Palette.amberDim : Palette.lineBright)
        let fill = AnnotateTheme.color(color)
        let square = CGRect(x: (bounds.width - az(14)) / 2, y: (bounds.height - az(14)) / 2, width: az(14), height: az(14))
        // `box-shadow: 0 0 0 1px #000, 0 0 8px <color glow>`
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(fill.withAlphaComponent(0.22), radius: 8).set()
        Draw.fill(square.insetBy(dx: -1, dy: -1), .black)
        NSGraphicsContext.restoreGraphicsState()
        Draw.fill(square, fill)
    }
}

/// `.seg.ia-zoom`: the vertical Fit / 100% / 200% switch (40 pt wide, 24 pt segments, the selected
/// one filled amber with black bold text).
final class VerticalSegmentView: KeyFocusView, AnnotateTextShowing {
    let titles: [String]
    var selectedIndex = 0 { didSet { if selectedIndex != oldValue { needsDisplay = true; setAccessibilityValue(titles[selectedIndex]) } } }
    var onSelect: ((Int) -> Void)?
    static var segmentHeight: CGFloat { az(24) }

    init(titles: [String]) {
        self.titles = titles
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("縮放")
        setAccessibilityValue(titles.first ?? "")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var displayedText: String { titles.map { $0.uppercased() }.joined(separator: " ") }

    /// Border 1 + segments of 24 with 1 pt rules between them + border 1.
    var preferredHeight: CGFloat { CGFloat(titles.count) * Self.segmentHeight + CGFloat(max(0, titles.count - 1)) + 2 }

    func segmentRect(_ index: Int) -> CGRect {
        CGRect(x: 1, y: 1 + CGFloat(index) * (Self.segmentHeight + 1), width: bounds.width - 2, height: Self.segmentHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.strokeRect(bounds, color: Palette.lineBright)
        for (index, title) in titles.enumerated() {
            let rect = segmentRect(index)
            let on = index == selectedIndex
            if on { Draw.fill(rect, Palette.amber) }
            let style = TextStyle(font: Typeface.mono(9.5, on ? .bold : .regular), color: on ? .black : Palette.dim,
                                  tracking: 0.04, uppercase: true)
            let text = style.string(title)
            Draw.text(text, x: rect.midX - Draw.width(text) / 2, centerY: rect.midY)
            if index < titles.count - 1 { Draw.fill(CGRect(x: 1, y: rect.maxY, width: rect.width, height: 1), Palette.lineBright) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for index in titles.indices where segmentRect(index).insetBy(dx: 0, dy: -0.5).contains(point) {
            select(index)
            return
        }
    }

    func select(_ index: Int) {
        guard titles.indices.contains(index) else { return }
        if selectedIndex != index {
            selectedIndex = index
        }
        onSelect?(index)
    }

    // MARK: Keyboard and VoiceOver (D21)

    /// ↑ ↓ (and ← →) pick the previous / next zoom; space and ⏎ keep the current one.
    override func handleKey(_ event: NSEvent) -> Bool {
        if let step = Self.arrowStep(event) {
            let next = selectedIndex + step
            if titles.indices.contains(next) { select(next) }
            return true
        }
        return KeyFocus.isPressKey(event)
    }

    private var segmentElements: [ZoomSegmentElement] = []

    /// One radio button per zoom, so VoiceOver can read and pick each.
    override func accessibilityChildren() -> [Any]? {
        if segmentElements.count != titles.count {
            segmentElements = titles.indices.map { ZoomSegmentElement(owner: self, index: $0) }
        }
        return segmentElements
    }
}

/// A zoom segment as VoiceOver sees it: a radio button with its title, pressable. The owner (a
/// main-actor view, Sendable) is read before the isolated closures, which never capture `self`.
final class ZoomSegmentElement: NSAccessibilityElement {
    private weak var owner: VerticalSegmentView?
    let index: Int

    @MainActor
    init(owner: VerticalSegmentView, index: Int) {
        self.owner = owner
        self.index = index
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.radioButton)
    }

    override func accessibilityLabel() -> String? {
        let owner = owner, index = index
        return MainActor.assumeIsolated { owner.flatMap { $0.titles.indices.contains(index) ? "縮放 \($0.titles[index])" : nil } }
    }

    override func accessibilityValue() -> Any? {
        let owner = owner, index = index
        let selected: Int? = MainActor.assumeIsolated { owner.map { $0.selectedIndex == index ? 1 : 0 } }
        return selected
    }

    override func accessibilityFrame() -> NSRect {
        let owner = owner, index = index
        return MainActor.assumeIsolated {
            guard let owner, let window = owner.window else { return .zero }
            return window.convertToScreen(owner.convert(owner.segmentRect(index), to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let owner = owner, index = index
        return MainActor.assumeIsolated {
            guard let owner else { return false }
            owner.select(index)
            return true
        }
    }
}
