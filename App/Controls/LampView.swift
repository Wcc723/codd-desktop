import AppKit
import QuartzCore
import CoddUI

/// State lamp glyph (`.lamp`). The glyph is rendered once into a sublayer we own (AppKit
/// manages opacity/shadow of a view's backing layer, so we never touch those).
///
/// A waiting lamp pulses like helmet `codd-lamp` (1.1 s ease-in-out, opacity 1 → .3 with the
/// glow fading) through ONE committed `CAAnimationGroup` on that sublayer: the render server
/// runs it, the main thread does nothing per pulse, and hidden or off-screen lamps cost
/// nothing. Every lamp shares the same phase (begin time aligned to the period), so all
/// waiting lamps in the window pulse together. "Reduce motion" leaves the lamp lit.
final class LampView: NSView, PulseSubscriber {
    private var glyph = "●"
    private var color = Palette.bone
    private var fontSize: CGFloat = 11
    private var glows = false
    private var lampAlpha: CGFloat = 1
    private var pulses = false
    private var subscribed = false
    private let glyphLayer = CALayer()
    private var renderedKey = ""
    /// Supplies the "Reduce motion" preference. Tests inject their own; set it before the lamp
    /// enters a window.
    var ticker = UITicker.shared

    private static let pulseKey = "codd.lamp.pulse"
    /// helmet `@keyframes codd-lamp` duration.
    static let pulsePeriod: CFTimeInterval = 1.1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyphLayer.contentsGravity = .center
        glyphLayer.shadowOffset = .zero
        layer?.addSublayer(glyphLayer)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 12, height: 16) }
    override var wantsUpdateLayer: Bool { true }

    /// Applies a state style. Cheap when nothing changed.
    /// - Parameter animated: false for aggregate badges (they never pulse).
    func configure(_ style: StateStyle, size: CGFloat? = nil, animated: Bool = true) {
        glyph = style.glyph
        color = style.color
        fontSize = size ?? (style.pulses && animated ? 12 : 11)
        lampAlpha = style.lampAlpha
        glows = style.glows
        renderIfNeeded()
        pulses = animated && style.pulses
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

    /// True while the pulse animation is attached (tests).
    var isPulsing: Bool { glyphLayer.animation(forKey: Self.pulseKey) != nil }

    // MARK: Accessibility (M5 D21)

    /// What VoiceOver says for the lamp (`等待中 · 權限 · 3 分鐘`, SPEC §3): the glyph and its color
    /// are spoken as text. Nil leaves the lamp out of the accessibility tree: inside a row or a
    /// header that speaks the state itself the lamp is decoration. A closure, so the duration is
    /// current whenever VoiceOver asks.
    var spokenDescription: (@MainActor () -> String)?

    override func isAccessibilityElement() -> Bool { spokenDescription != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { spokenDescription == nil ? super.accessibilityRole() : .image }
    override func accessibilityLabel() -> String? { spokenDescription?() ?? super.accessibilityLabel() }

    /// Screen drawing goes through the sublayer (`updateLayer`); this only runs when the view is
    /// drawn into a bitmap (`cacheDisplay`, the sidebar's lifted drag image).
    override func draw(_ dirtyRect: NSRect) {
        let text = TextStyle.mono(fontSize, color.withAlphaComponent(lampAlpha)).string(glyph)
        let size = text.size()
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    // MARK: Rendering

    private func renderIfNeeded() {
        let scale = window?.backingScaleFactor ?? 2
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let key = "\(glyph)|\(color.description)|\(fontSize)|\(lampAlpha)|\(scale)|\(size.width)x\(size.height)"
        guard key != renderedKey else { return }
        renderedKey = key
        let text = TextStyle.mono(fontSize, color.withAlphaComponent(lampAlpha)).string(glyph)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.contents = GlyphImage.render(text, size: size, scale: scale)
        glyphLayer.contentsScale = scale
        glyphLayer.shadowColor = color.cgColor
        CATransaction.commit()
    }

    // MARK: Pulse

    func motionPreferenceChanged() { updatePulse() }

    /// Attaches / removes the pulse to match `pulses`, the window and "Reduce motion".
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
            // Lit model values: what Reduce motion shows, and the pulse's resting point.
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
        // Shared phase: start at the last multiple of the period in layer time.
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        group.beginTime = now - now.truncatingRemainder(dividingBy: pulsePeriod)
        return group
    }
}

/// Renders a short attributed string centered into a bitmap (for layer contents).
@MainActor
enum GlyphImage {
    static func render(_ text: NSAttributedString, size: CGSize, scale: CGFloat) -> CGImage? {
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
