import AppKit

/// The composer's text area: a borderless scroll view around a `ComposerTextView` that grows from
/// `minLines` to `maxLines` lines and scrolls beyond. The owner sizes it to `preferredHeight`
/// (also its intrinsic height) and draws any border or button around it.
@MainActor
public final class ComposerField: NSView {
    public let textView: ComposerTextView
    private let scrollView: NSScrollView
    private var style: ComposerStyle = .standard

    /// Called with the new `preferredHeight` whenever it changes (typing, composing, width, style).
    public var onHeightChange: ((CGFloat) -> Void)?
    /// `clamp(lines, minLines, maxLines) × line height + top and bottom insets`.
    public private(set) var preferredHeight: CGFloat = 0

    override public init(frame frameRect: NSRect) {
        let size = NSSize(width: max(frameRect.width, 1), height: max(frameRect.height, 1))
        scrollView = OverlayScrollView(frame: NSRect(origin: .zero, size: size))
        textView = ComposerTextView(frame: NSRect(origin: .zero, size: size))
        super.init(frame: frameRect)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.documentView = textView
        addSubview(scrollView)
        textView.onLayoutChange = { [weak self] in self?.updatePreferredHeight() }
        apply(.standard)
    }

    public convenience init(style: ComposerStyle) {
        self.init(frame: NSRect(x: 0, y: 0, width: 480, height: 40))
        apply(style)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("ComposerField is built in code")
    }

    /// The text. Setting it is programmatic (restore a draft, clear after a send): no undo step,
    /// no `onTextChange`, caret at the end, any composition discarded.
    public var text: String {
        get { textView.string }
        set {
            textView.setText(newValue)
            updatePreferredHeight()
        }
    }

    public func apply(_ style: ComposerStyle) {
        self.style = style
        scrollView.backgroundColor = style.background
        textView.apply(style)
        needsLayout = true
        updatePreferredHeight()
    }

    /// Makes the text view first responder (⌘L).
    public func focus() {
        window?.makeFirstResponder(textView)
    }

    override public var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    override public func layout() {
        super.layout()
        let resized = scrollView.frame != bounds
        scrollView.frame = bounds
        let content = scrollView.contentSize
        textView.minSize = NSSize(width: 0, height: content.height)
        if textView.frame.width != content.width {
            textView.setFrameSize(NSSize(width: content.width, height: max(textView.frame.height, content.height)))
        }
        updatePreferredHeight()
        // Only after a resize: a layout pass must not undo the user's own scrolling.
        if resized {
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    private func updatePreferredHeight() {
        let lines = min(max(textView.visualLineCount, style.minLines), style.maxLines)
        let height = CGFloat(lines) * style.resolvedLineHeight + style.insets.top + style.insets.bottom
        guard height != preferredHeight else { return }
        preferredHeight = height
        invalidateIntrinsicContentSize()
        onHeightChange?(height)
    }
}

/// Always overlay scrollers, whatever the user's preference (AppKit sets it again when it changes).
/// A legacy scroller takes width: it would appear while the text is taller than the field, narrow
/// the wrap width, add a line, grow the field, hide and remove the line again, so the field would
/// oscillate between two heights.
private final class OverlayScrollView: NSScrollView {
    override var scrollerStyle: NSScroller.Style {
        get { super.scrollerStyle }
        set { super.scrollerStyle = .overlay }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollerStyle = .overlay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("built in code")
    }
}
