import AppKit
import CoddUI

/// A design length (a CSS px of the Status board) at the current interface zoom: the page and its
/// sidebar are laid out by hand, so offsets, row heights and widths follow the zoom like their
/// fonts. Exact at UI 字級 13 (`UIZoom.pt`).
func sz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }
import QuartzCore

// Small building blocks of the STATUS views that CoddUI does not provide (listed in the C6
// report as candidates for CoddUI): a hover control, the card frame with ASCII corners, a dashed
// rule in any color, a pulsing lamp, and frame-based row / flow layout helpers.

/// A layer-backed view on `.onSetNeedsDisplay` keeps its old drawing when only its size changes:
/// after a window resize the card borders, rules, bars and wrapped text stayed at the old width
/// while the views laid out by frame (buttons, countdowns, corners) moved (FB 「縮放尺寸時，版型會跑掉」).
/// Every STATUS view draws on `.duringViewResize`; the page and the sidebar also move the CoddUI
/// views they host (quota bars, meters, sparklines, buttons) to it as they lay out.
@MainActor
enum ResizeRedraw {
    /// Moves `root`'s subtree from `.onSetNeedsDisplay` to `.duringViewResize` (AppKit's scrollers
    /// and clip views keep their own policy).
    static func adopt(in root: NSView) {
        if root is NSScroller { return }
        if !(root is NSClipView || root is NSScrollView), root.layerContentsRedrawPolicy == .onSetNeedsDisplay {
            root.layerContentsRedrawPolicy = .duringViewResize
        }
        for view in root.subviews { adopt(in: view) }
    }
}

/// A clickable area with hover tracking (`:hover` looks), pressed by mouse or VoiceOver.
class HoverControl: NSControl, KeyboardFocusTracking {
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?
    var onClick: (() -> Void)?
    /// D21: a key view while Full Keyboard Access is on (off for text-like controls).
    var takesKeyboardFocus = true
    /// ↑ ↓ step to the sibling rows of the same list (see ``KeyListRow``).
    var steppedByArrows = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
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

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setHovered(false) }
        focusTracker.viewDidMoveToWindow()
    }

    func setHovered(_ value: Bool) {
        guard isHovered != value else { return }
        isHovered = value
        needsDisplay = true
        hoverChanged()
    }

    /// Subclasses restyle their children.
    func hoverChanged() {}

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Fires on mouse-up inside, like a button.
        var inside = true
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp { break }
        }
        if inside { performClick(nil) }
    }

    override func performClick(_ sender: Any?) {
        guard isEnabled else { return }
        onClick?()
        sendAction(action, to: target)
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    // MARK: Keyboard (D21)

    private(set) lazy var focusTracker: KeyboardFocusTracker = KeyFocus.tracker(for: self)

    override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: takesKeyboardFocus && isEnabled, refuses: refusesFirstResponder) }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { focusTracker.becameFirstResponder() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { focusTracker.resignedFirstResponder() }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        let key = KeyboardFocus.key(of: event)
        if key == .space || key == .return {
            focusTracker.noteKeyboardInteraction()
            performClick(nil)
        } else if steppedByArrows, key == .down || key == .up {
            KeyFocus.moveInList(from: self, by: key == .down ? 1 : -1)
        } else {
            super.keyDown(with: event)
        }
    }
}

extension HoverControl: KeyListRow {
    var isKeyListRow: Bool { steppedByArrows }
}

/// `.card`: `--bg-soft`, 1 px `--line-bright` (`.hot`: `--amber-dim`), and the ASCII corners
/// `┌─` (top left) / `─┘` (bottom right) in `--amber-dim` on a `--bg` box straddling the border.
/// The corners are subviews that hang outside the card's bounds.
class CardFrameView: FlippedView {
    var hot = false { didSet { if hot != oldValue { needsDisplay = true } } }
    private let topCorner = CornerGlyphView(text: "┌─")
    private let bottomCorner = CornerGlyphView(text: "─┘")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        clipsToBounds = false
        addSubview(topCorner)
        addSubview(bottomCorner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: hot ? Palette.amberDim : Palette.lineBright)
    }

    override func layout() {
        super.layout()
        let top = topCorner.intrinsicContentSize
        topCorner.frame = CGRect(x: 0, y: -top.height / 2, width: top.width, height: top.height)
        let bottom = bottomCorner.intrinsicContentSize
        bottomCorner.frame = CGRect(x: bounds.width - bottom.width, y: bounds.height - bottom.height / 2,
                                    width: bottom.width, height: bottom.height)
    }
}

/// One ASCII corner of a card (`font-size 11px; line-height 1; padding 0 4px; background --bg`).
final class CornerGlyphView: NSView {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var string: NSAttributedString { TextStyle.mono(11, Palette.amberDim).string(text) }

    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(string) + sz(8), height: sz(11)) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.text(string, x: sz(4), centerY: bounds.midY)
    }
}

/// A 1 px dashed (or solid) horizontal rule across its width, at its vertical center
/// (`.sx-rule`, `.sbsec .rule`, row separators).
final class RuleLine: NSView {
    var color: NSColor { didSet { needsDisplay = true } }
    private let dashed: Bool
    /// Draws at the top edge instead of the center (row separators).
    var atTop = false { didSet { needsDisplay = true } }

    init(color: NSColor, dashed: Bool = true) {
        self.color = color
        self.dashed = dashed
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let y = atTop ? 0 : floor(bounds.midY)
        if dashed {
            Draw.dashedLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: bounds.width, y: y), color: color)
        } else {
            Draw.fill(CGRect(x: 0, y: y, width: bounds.width, height: 1), color)
        }
    }
}

/// A state lamp glyph (`.lamp`). A waiting lamp pulses like helmet `codd-lamp` (1.1 s, opacity
/// 1 → .3 with its glow) through one committed Core Animation group, so the main thread does
/// nothing per pulse; "Reduce motion" (UITicker) leaves it lit. Same approach as the app's
/// LampView, which stays in App.
final class LampGlyph: NSView, PulseSubscriber {
    private var glyph = "●"
    private var color = Palette.bone
    private var fontSize: CGFloat = 11
    private var glows = false
    private var pulses = false
    private var subscribed = false
    private let glyphLayer = CALayer()
    private var renderedKey = ""
    var ticker = UITicker.shared

    private static let pulseKey = "codd.status.lamp.pulse"
    static let pulsePeriod: CFTimeInterval = 1.1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyphLayer.contentsGravity = .center
        glyphLayer.shadowOffset = .zero
        layer?.addSublayer(glyphLayer)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: sz(12), height: sz(16)) }
    override var wantsUpdateLayer: Bool { true }

    var text: String { glyph }
    var isPulsing: Bool { glyphLayer.animation(forKey: Self.pulseKey) != nil }

    func configure(_ glyph: StatusGlyph, size: CGFloat = 11, glows: Bool = false, pulses: Bool = false) {
        self.glyph = glyph.text
        color = glyph.color
        fontSize = size
        self.glows = glows
        renderIfNeeded()
        self.pulses = pulses
        updatePulse()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.frame = bounds
        CATransaction.commit()
        renderIfNeeded()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
        renderIfNeeded()
    }

    /// Only used when the view is drawn into a bitmap (`cacheDisplay`).
    override func draw(_ dirtyRect: NSRect) {
        let text = TextStyle.mono(fontSize, color).string(glyph)
        let size = text.size()
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    private func renderIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let key = "\(glyph)|\(color.description)|\(fontSize)|\(scale)|\(size.width)x\(size.height)"
        guard key != renderedKey else { return }
        renderedKey = key
        let text = TextStyle.mono(fontSize, color).string(glyph)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.contents = Self.render(text, size: size, scale: scale)
        glyphLayer.contentsScale = scale
        glyphLayer.shadowColor = color.cgColor
        CATransaction.commit()
    }

    func motionPreferenceChanged() { updatePulse() }

    private func updatePulse() {
        let wanted = pulses && window != nil
        if wanted, !subscribed {
            subscribed = true
            ticker.addPulse(self)
        } else if !wanted, subscribed {
            subscribed = false
            ticker.removePulse(self)
        }
        let animate = wanted && ticker.pulsesAllowed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.opacity = 1
        if pulses {
            glyphLayer.shadowRadius = 4
            glyphLayer.shadowOpacity = 0.9
        } else {
            glyphLayer.shadowRadius = glows ? 3 : 0
            glyphLayer.shadowOpacity = glows ? 0.55 : 0
        }
        if animate, !isPulsing {
            glyphLayer.add(Self.makePulse(for: glyphLayer), forKey: Self.pulseKey)
        } else if !animate, isPulsing {
            glyphLayer.removeAnimation(forKey: Self.pulseKey)
        }
        CATransaction.commit()
    }

    private static func makePulse(for layer: CALayer) -> CAAnimation {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1, 0.3, 1]
        let glow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        glow.values = [0.9, 0, 0.9]
        for animation in [opacity, glow] {
            animation.keyTimes = [0, 0.5, 1]
            animation.timingFunctions = [ease, ease]
        }
        let group = CAAnimationGroup()
        group.animations = [opacity, glow]
        group.duration = pulsePeriod
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        group.beginTime = now - now.truncatingRemainder(dividingBy: pulsePeriod)
        return group
    }

    private static func render(_ text: NSAttributedString, size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let textSize = text.size()
        text.draw(at: CGPoint(x: (size.width - textSize.width) / 2, y: (size.height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

// MARK: - Layout helpers

/// Frame layout of one horizontal line of views (the artboard's `display:flex; align-items:center;
/// gap:…` rows). Hidden or nil views are skipped; `flex` items share what is left; a `shrink`
/// item gives up width (its text truncates) when the line is too narrow.
@MainActor
struct RowItem {
    enum Width {
        case intrinsic
        case fixed(CGFloat)
        case flex(min: CGFloat)
        case shrink
    }

    var view: NSView?
    var width: Width = .intrinsic
    /// nil: the view's intrinsic height (else the line height).
    var height: CGFloat?
    /// Gap before this item instead of the row's gap.
    var gapBefore: CGFloat?

    init(_ view: NSView?, _ width: Width = .intrinsic, height: CGFloat? = nil, gapBefore: CGFloat? = nil) {
        self.view = view
        self.width = width
        self.height = height
        self.gapBefore = gapBefore
    }

    static func flex(_ view: NSView? = nil, min: CGFloat = 0) -> RowItem { RowItem(view ?? NSView(), .flex(min: min)) }
}

@MainActor
enum RowLayout {
    /// Places `items` left to right inside `rect`, each vertically centered.
    static func layout(_ items: [RowItem], in rect: CGRect, gap: CGFloat) {
        let visible = items.filter { $0.view.map { !$0.isHidden } ?? false }
        guard !visible.isEmpty else { return }
        var widths: [CGFloat] = visible.map { item in
            switch item.width {
            case .intrinsic, .shrink: max(0, item.view?.intrinsicContentSize.width ?? 0)
            case .fixed(let w): w
            case .flex(let min): min
            }
        }
        let gaps = visible.enumerated().reduce(CGFloat(0)) { sum, pair in pair.offset == 0 ? sum : sum + (pair.element.gapBefore ?? gap) }
        var remaining = rect.width - widths.reduce(0, +) - gaps
        let flexIndices = visible.indices.filter { if case .flex = visible[$0].width { true } else { false } }
        if remaining > 0, !flexIndices.isEmpty {
            let share = remaining / CGFloat(flexIndices.count)
            for i in flexIndices { widths[i] += share }
            remaining = 0
        }
        if remaining < 0 {
            for i in visible.indices.reversed() where remaining < 0 {
                if case .shrink = visible[i].width {
                    let cut = min(widths[i], -remaining)
                    widths[i] -= cut
                    remaining += cut
                }
            }
        }
        var x = rect.minX
        for (i, item) in visible.enumerated() {
            if i > 0 { x += item.gapBefore ?? gap }
            let height = item.height ?? item.view?.intrinsicContentSize.height ?? rect.height
            let h = height <= 0 ? rect.height : min(height, max(rect.height, height))
            item.view?.frame = CGRect(x: round(x), y: round(rect.midY - h / 2), width: round(widths[i]), height: round(h))
            x += widths[i]
        }
    }
}

@MainActor
enum FlowLayout {
    /// Lays views left to right, wrapping to a new line when the next one does not fit (CSS
    /// `flex-wrap: wrap`). Every line is `lineHeight` tall; views are centered in it. Returns the
    /// total height. `apply: false` only measures.
    @discardableResult
    static func layout(_ views: [NSView], origin: CGPoint, width: CGFloat, gap: CGFloat, rowGap: CGFloat,
                       lineHeight: CGFloat, apply: Bool = true) -> CGFloat {
        let visible = views.filter { !$0.isHidden }
        guard !visible.isEmpty else { return 0 }
        var x: CGFloat = 0
        var line = 0
        for view in visible {
            let size = view.intrinsicContentSize
            let w = min(size.width, width)
            if x > 0, x + w > width + 0.5 {
                line += 1
                x = 0
            }
            if apply {
                let y = origin.y + CGFloat(line) * (lineHeight + rowGap)
                let h = size.height > 0 ? size.height : lineHeight
                view.frame = CGRect(x: round(origin.x + x), y: round(y + (lineHeight - h) / 2), width: round(w), height: round(h))
            }
            x += w + gap
        }
        return CGFloat(line + 1) * lineHeight + CGFloat(line) * rowGap
    }
}

extension NSView {
    /// Every readable string under this view in reading order: lines top to bottom (items whose
    /// vertical centers are within 6 pt form one line), each line left to right. Hidden views are
    /// skipped; buttons report their label as drawn. Tests and diagnostics compare this with the
    /// artboard's text.
    @MainActor
    func statusVisibleTexts() -> [String] {
        var items: [(text: String, frame: CGRect)] = []
        collectTexts(root: self, into: &items)
        let sorted = items.sorted { $0.frame.midY < $1.frame.midY }
        var lines: [[(text: String, frame: CGRect)]] = []
        for item in sorted {
            if let first = lines.last?.first, abs(item.frame.midY - first.frame.midY) <= 6 {
                lines[lines.count - 1].append(item)
            } else {
                lines.append([item])
            }
        }
        return lines.flatMap { line in line.sorted { $0.frame.minX < $1.frame.minX }.map(\.text) }
    }

    @MainActor
    private func collectTexts(root: NSView, into items: inout [(text: String, frame: CGRect)]) {
        guard !isHidden else { return }
        var text: String?
        if let shown = self as? StatusTextShowing {
            text = shown.displayedText
        } else if let button = self as? CoddButton {
            text = button.statusDrawnLabel
        }
        if let text, !text.isEmpty { items.append((text, convert(bounds, to: root))) }
        for sub in subviews { sub.collectTexts(root: root, into: &items) }
    }
}

extension CoddButton {
    /// The label as the button draws it (bracket buttons upper-case it).
    @MainActor
    var statusDrawnLabel: String {
        if case .bracket = style { return label.uppercased() }
        return label
    }
}
