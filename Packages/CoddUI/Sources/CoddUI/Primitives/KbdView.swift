import AppKit

/// A key cap label: helmet `.kbd` (`⌘Q` in a dialog header: 18 px, 10.5 px dim on --bg, 1 px
/// --line-bright, `padding: 0 5px`), Settings `.sx-kbd` (shortcut table: 22 px, 11.5 px cream,
/// `padding: 0 8px`) and `.sx-hk` (the recorded global hotkey: 24 px, 12 px cream, --amber-dim
/// border, `padding: 0 9px`). Static; redraws only when the text changes.
public final class KbdView: NSView {
    public enum Size: Sendable, Equatable {
        case regular, large, hotkey
    }

    public let size: Size
    public var text: String {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public init(_ text: String, size: Size = .regular) {
        self.text = text
        self.size = size
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

    /// The chip style of `size` (the border is inside the width, so padding = CSS padding + 1).
    public static func style(_ size: Size) -> ChipStyle {
        switch size {
        case .regular:
            ChipStyle(text: TextStyle.mono(10.5, Palette.dim), border: Palette.lineBright, fill: Palette.bg, height: 18, padding: 6)
        case .large:
            ChipStyle(text: TextStyle.mono(11.5, Palette.cream), border: Palette.lineBright, fill: Palette.bg, height: 22, padding: 9)
        case .hotkey:
            ChipStyle(text: TextStyle.mono(12, Palette.cream), border: Palette.amberDim, fill: Palette.bg, height: 24, padding: 10)
        }
    }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { Self.style(size).size(for: text) }

    // MARK: Accessibility

    private var explicitAccessibilityLabel: String?

    /// The key text unless a caller set a label (theirs wins, also after later changes).
    public override func accessibilityLabel() -> String? { explicitAccessibilityLabel ?? text }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Self.style(size).draw(text, x: 0, centerY: bounds.midY)
    }
}
