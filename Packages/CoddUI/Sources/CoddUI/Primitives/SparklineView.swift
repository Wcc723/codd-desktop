import AppKit

/// `.spark`: a polyline across the whole box (`preserveAspectRatio="none"`, 1.25 px non-scaling
/// amber-dim stroke), optionally with a dashed baseline (`.sx-base`: 1 px --line-bright, 3 / 3) and
/// the Status host card's dashed bottom rule (`.sx-m .spark{border-bottom:1px dashed var(--line)}`).
/// Values are 0...1 (1 = top) or auto-scaled to their own min...max. Redraws only on change.
public final class SparklineView: NSView {
    public enum Scale: Equatable, Sendable {
        /// Values are already 0...1.
        case unit
        /// The values' own min...max fills the height (a flat series sits in the middle).
        case auto
        /// A fixed range mapped to the height (values outside are clamped).
        case fixed(ClosedRange<Double>)
    }

    public var values: [Double] { didSet { if values != oldValue { needsDisplay = true } } }
    public var scale: Scale { didSet { if scale != oldValue { needsDisplay = true } } }
    /// Baseline in the values' space (the CPU card's 10-minute average), nil = none.
    public var baseline: Double? { didSet { if baseline != oldValue { needsDisplay = true } } }
    public var strokeColor: NSColor = Palette.amberDim { didSet { needsDisplay = true } }
    public var lineWidth: CGFloat = 1.25 { didSet { if lineWidth != oldValue { needsDisplay = true } } }
    /// The 1 px dashed --line rule under the plot (the plot area ends above it).
    public var showsBottomRule = false { didSet { if showsBottomRule != oldValue { needsDisplay = true } } }

    public init(values: [Double] = [], scale: Scale = .unit, baseline: Double? = nil, accessibilityLabel: String? = nil) {
        self.values = values
        self.scale = scale
        self.baseline = baseline
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Decorative in the artboard (`aria-hidden`); an element only when it has something to say.
        setAccessibilityElement(accessibilityLabel != nil)
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilityLabel)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    /// `.spark{height:28px}` (the Status cards stretch it, `min-height:26px`).
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(28)) }

    /// The plot rectangle: the bounds, minus the bottom rule's pixel when it is shown.
    public var plotRect: CGRect {
        showsBottomRule ? CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 1)) : bounds
    }

    /// 0...1 (1 = top) for a value under the current scale.
    public func normalized(_ value: Double) -> Double {
        let range: ClosedRange<Double>
        switch scale {
        case .unit: range = 0...1
        case .fixed(let fixed): range = fixed
        case .auto:
            let finite = values.filter(\.isFinite)
            guard let low = finite.min(), let high = finite.max() else { return 0.5 }
            if high - low < .ulpOfOne { return 0.5 }
            range = low...high
        }
        guard value.isFinite, range.upperBound > range.lowerBound else { return 0.5 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }

    /// Polyline points in `rect` (flipped: y grows down), evenly spaced from the left to the right edge.
    public func points(in rect: CGRect) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let step = values.count > 1 ? rect.width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            CGPoint(x: rect.minX + CGFloat(index) * step, y: rect.minY + CGFloat(1 - normalized(value)) * rect.height)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let plot = plotRect
        if showsBottomRule {
            Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.line)
        }
        if let baseline {
            let y = plot.minY + CGFloat(1 - normalized(baseline)) * plot.height
            let path = NSBezierPath()
            path.move(to: CGPoint(x: plot.minX, y: y))
            path.line(to: CGPoint(x: plot.maxX, y: y))
            path.lineWidth = 1
            let dash: [CGFloat] = [3, 3]
            dash.withUnsafeBufferPointer { path.setLineDash($0.baseAddress, count: dash.count, phase: 0) }
            Palette.lineBright.setStroke()
            path.stroke()
        }
        var points = points(in: plot)
        guard !points.isEmpty else { return }
        if points.count == 1 { points.append(CGPoint(x: plot.maxX, y: points[0].y)) }
        let line = NSBezierPath()
        line.move(to: points[0])
        for point in points.dropFirst() { line.line(to: point) }
        line.lineWidth = lineWidth
        strokeColor.setStroke()
        line.stroke()
    }
}
