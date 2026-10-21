import AppKit

/// `.meter`: a 2 px track on --line-bright with a fill from the left. Three shapes from the Status
/// artboard: a single fraction (amber-dim, or a tone: `.meter.tone-ok`), stacked segments
/// (`.sx-stack`, the memory meter: app / wired / compressed, 6 px tall) and a split (`.sx-split`,
/// CODD vs external claude processes: amber-dim then bone at 50 %). Redraws only on change.
public final class MeterView: NSView {
    /// One stacked piece: its share of the whole track (0...1) and color.
    public struct Segment: Equatable, Sendable {
        public var fraction: Double
        public var color: NSColor

        public init(fraction: Double, color: NSColor) {
            self.fraction = fraction
            self.color = color
        }
    }

    public enum Content: Equatable, Sendable {
        /// One fill (`.meter b`).
        case fraction(Double, color: NSColor)
        /// Consecutive fills from the left (`.sx-stack b, b.w2, b.w3`).
        case stacked([Segment])
        /// Main share then the other share (`.sx-split b, b.x`).
        case split(main: Double, other: Double)
    }

    /// `.sx-stack` colors: amber-dim, bone at 55 %, cyan at 60 %.
    public static let stackColors: [NSColor] = [Palette.amberDim, Palette.bone.withAlphaComponent(0.55),
                                                Palette.cyan.withAlphaComponent(0.6)]

    /// `.sx-split b.x`: bone at 50 %.
    public static let splitOtherColor = Palette.bone.withAlphaComponent(0.5)

    public var content: Content { didSet { if content != oldValue { needsDisplay = true; updateAccessibility() } } }
    /// Track height: 2 (`.meter`), 6 for `.sx-stack`.
    public var barHeight: CGFloat { didSet { if barHeight != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// VoiceOver text (`記憶體 app 13.8G、wired 4.3G…`); the value is the filled share otherwise.
    public var accessibilityText: String? { didSet { updateAccessibility() } }

    public init(content: Content, barHeight: CGFloat = 2) {
        self.content = content
        self.barHeight = barHeight
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        updateAccessibility()
    }

    /// `.meter` with one fill: amber-dim, or the tone's color (`.meter.tone-ok`, `.tone-muted`).
    public convenience init(fraction: Double, tone: Tone? = nil) {
        self.init(content: .fraction(fraction, color: tone?.color ?? Palette.amberDim))
    }

    /// `.meter.sx-stack` (6 px).
    public convenience init(segments: [Segment], barHeight: CGFloat = 6) {
        self.init(content: .stacked(segments), barHeight: barHeight)
    }

    /// `.meter.sx-split`.
    public convenience init(main: Double, other: Double) {
        self.init(content: .split(main: main, other: other))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: barHeight) }

    /// The fills as (rect, color) inside `rect` (tests, custom drawing).
    public func fills(in rect: CGRect) -> [(rect: CGRect, color: NSColor)] {
        let pieces: [Segment]
        switch content {
        case .fraction(let value, let color): pieces = [Segment(fraction: value, color: color)]
        case .stacked(let segments): pieces = segments
        case .split(let main, let other):
            pieces = [Segment(fraction: main, color: Palette.amberDim), Segment(fraction: other, color: Self.splitOtherColor)]
        }
        var x = rect.minX
        var out: [(rect: CGRect, color: NSColor)] = []
        for piece in pieces {
            let share = piece.fraction.isFinite ? min(1, max(0, piece.fraction)) : 0
            let width = min(rect.maxX - x, rect.width * CGFloat(share))
            guard width > 0 else { continue }
            out.append((CGRect(x: x, y: rect.minY, width: width, height: rect.height), piece.color))
            x += width
        }
        return out
    }

    public override func draw(_ dirtyRect: NSRect) {
        let track = CGRect(x: 0, y: round((bounds.height - barHeight) / 2), width: bounds.width, height: barHeight)
        Draw.fill(track, Palette.lineBright)
        for fill in fills(in: track) { Draw.fill(fill.rect, fill.color) }
    }

    private var filledShare: Double {
        switch content {
        case .fraction(let value, _): value
        case .stacked(let segments): segments.reduce(0) { $0 + $1.fraction }
        case .split(let main, let other): main + other
        }
    }

    private func updateAccessibility() {
        setAccessibilityValue("\(Int((min(1, max(0, filledShare.isFinite ? filledShare : 0)) * 100).rounded()))%")
    }

    // MARK: Accessibility

    private var explicitAccessibilityLabel: String?

    /// ``accessibilityText`` (else `使用量`) unless a caller set a label (theirs wins, also after later changes).
    public override func accessibilityLabel() -> String? { explicitAccessibilityLabel ?? accessibilityText ?? "使用量" }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }
}
