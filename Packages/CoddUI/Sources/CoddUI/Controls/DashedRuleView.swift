import AppKit

/// 1 px dashed horizontal rule that fills the available width.
public final class DashedRuleView: NSView {
    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 1) }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.dashedLine(from: CGPoint(x: 0, y: 0), to: CGPoint(x: bounds.width, y: 0), color: color)
    }

    // MARK: M3 additions (additive: the defaults draw exactly what the app's rule drew)

    /// Dash color. `Palette.line` (the app's rule); `.sx-rule` / `.sx-gh::after` use `Palette.lineBright`.
    public var color: NSColor = Palette.line { didSet { if color != oldValue { needsDisplay = true } } }

    /// A rule in `color`, at least `minimumWidth` wide (`.sx-rule{min-width:24px}`).
    public convenience init(color: NSColor, minimumWidth: CGFloat = 0) {
        self.init(frame: .zero)
        self.color = color
        self.minimumWidth = minimumWidth
    }

    /// Smallest width Auto Layout may give the rule (0: none). Installs one `>=` constraint.
    public var minimumWidth: CGFloat = 0 {
        didSet {
            guard minimumWidth != oldValue else { return }
            minimumWidthConstraint?.isActive = false
            minimumWidthConstraint = nil
            guard minimumWidth > 0 else { return }
            let constraint = widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth)
            constraint.isActive = true
            minimumWidthConstraint = constraint
        }
    }

    private var minimumWidthConstraint: NSLayoutConstraint?
}
