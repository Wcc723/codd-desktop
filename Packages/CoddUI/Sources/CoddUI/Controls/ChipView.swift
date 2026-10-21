import AppKit

/// A static chip / kbd / badge for stack layouts (draws a `ChipStyle`). VoiceOver: static text
/// reading the label.
public final class ChipView: NSView {
    private var chip: ChipStyle
    private var label: String

    public init(_ label: String, style: ChipStyle) {
        self.chip = style
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { chip.size(for: label) }

    /// The chip may be drawn narrower than its label, which then ends in `…`. Its compression
    /// resistance drops below the window's stay-put priority (500): a long chip (a command, a
    /// path) truncates instead of holding its row, and the window, wider than their minimum.
    public var truncates = false {
        didSet {
            guard truncates != oldValue else { return }
            setContentCompressionResistancePriority(truncates ? Self.truncatingCompression : .required, for: .horizontal)
            needsDisplay = true
        }
    }

    /// Below a label's (250), so in a row with labels the chip gives way first.
    public static let truncatingCompression = NSLayoutConstraint.Priority(240)

    public func set(_ label: String, style: ChipStyle? = nil) {
        if let style { chip = style }
        guard label != self.label || style != nil else { return }
        self.label = label
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        chip.draw(label, x: 0, centerY: bounds.midY, maxWidth: truncates ? bounds.width : .greatestFiniteMagnitude)
    }

    // MARK: Accessibility

    private var explicitAccessibilityLabel: String?

    /// The label unless a caller set a label (theirs wins, also after later changes).
    public override func accessibilityLabel() -> String? { explicitAccessibilityLabel ?? label }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }

    /// `.kbd` (`⌘K`).
    public static func kbd(_ label: String) -> ChipView {
        ChipView(label, style: ChipStyle(text: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg,
                                         height: 18, padding: 5))
    }
}
