import AppKit

/// A checkbox in the two artboard looks:
/// - `.boxed` (Settings `.sx-cb`): a 26 px bordered button `[☐ 5 小時]`; dim text, amber on hover,
///   cream with an --amber-dim border when on; the 12 px box fills amber with a black `✓`;
/// - `.plain` (StatusDialogs `.sd-check`): a bare 14 px box and a 12.5 px bone title, plus an
///   optional dimmer 10.5 px hint after it (`AUTO-SWITCH 目前 OFF`); focus draws the amber outline.
///
/// An `NSControl`: clicking, Space (while focused) and VoiceOver's press toggle `isOn` and then send
/// `action` to `target`. Setting `isOn` from code sends nothing. Redraws only on change.
///
/// Keyboard focus (M5 D21) follows Full Keyboard Access; ⏎ is left to the window (a dialog's default
/// action). Keyboard focus draws the helmet focus style around `.boxed` and the artboard's
/// `.sd-check` outline (1 px amber, 2 px outside the box) around `.plain`; a click draws neither.
/// VoiceOver reads the title unless a caller set a label.
public final class CheckboxButton: NSControl, KeyboardFocusTracking {
    public enum Style: Sendable, Equatable {
        case boxed, plain
    }

    public let style: Style
    public var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }

    /// `NSControl` state view of `isOn` (`.on` / `.off`).
    public var state: NSControl.StateValue {
        get { isOn ? .on : .off }
        set { isOn = newValue == .on }
    }

    public var title: String {
        didSet {
            guard title != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// `.plain` only: the dim note after the title.
    public var hint: String? {
        didSet {
            guard hint != oldValue else { return }
            setAccessibilityHelp(hint)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    public private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var explicitAccessibilityLabel: String?

    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in self?.updateGlow() }
        return tracker
    }()

    public init(title: String, hint: String? = nil, style: Style = .boxed, isOn: Bool = false,
                target: AnyObject? = nil, action: Selector? = nil) {
        self.style = style
        self.title = title
        self.hint = hint
        self.isOn = isOn
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityHelp(hint)
        setAccessibilityValue(isOn ? 1 : 0)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4; needsDisplay = true; updateGlow() } }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var acceptsFirstResponder: Bool { KeyboardFocus.acceptsFocus(enabled: isEnabled, refuses: refusesFirstResponder) }
    public override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    public override func becomeFirstResponder() -> Bool {
        // makeFirstResponder never asks acceptsFirstResponder: refuse here, so code cannot focus
        // (and ring) a control while Full Keyboard Access is off.
        let accepted = acceptsFirstResponder && super.becomeFirstResponder()
        if accepted { focusTracker.becameFirstResponder() }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { focusTracker.resignedFirstResponder() }
        return accepted
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusTracker.viewDidMoveToWindow()
    }

    /// Keyboard focus in a key window (not a click): draws the focus style.
    private var isFocused: Bool { focusTracker.showsFocusRing && isEnabled }

    /// The boxed look glows like every focused control; `.sd-check` has only its outline.
    private func updateGlow() {
        shadow = isFocused && style == .boxed ? KeyboardFocus.ringGlow : nil
    }

    // MARK: Accessibility

    /// The title unless a caller set a label (theirs wins, also across title changes).
    public override func accessibilityLabel() -> String? { explicitAccessibilityLabel ?? title }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }

    // MARK: Styles

    private var titleStyle: TextStyle {
        switch style {
        case .boxed:
            let color = isOn ? Palette.cream : ((isHovered || isFocused) && isEnabled ? Palette.amber : Palette.dim)
            return TextStyle.mono(12, color)
        case .plain:
            return TextStyle.mono(12.5, Palette.bone)
        }
    }

    private var hintStyle: TextStyle { TextStyle.mono(10.5, Palette.dimmer) }
    /// `.sx-cb .box` 12 px / `.sd-box` 14 px.
    private var boxSize: CGFloat { UIZoom.pt(style == .boxed ? 12 : 14) }

    public override var intrinsicContentSize: NSSize {
        let titleWidth = Draw.width(titleStyle.string(title))
        switch style {
        case .boxed:
            // border 1 + padding 7 · box 12 · gap 6 · title · padding 9 + border 1
            let z = UIZoom.pt
            return NSSize(width: ceil(z(8) + boxSize + z(6) + titleWidth + z(10)), height: z(26))
        case .plain:
            var width = boxSize + UIZoom.pt(8) + titleWidth
            if let hint, !hint.isEmpty { width += UIZoom.pt(8) + Draw.width(hintStyle.string(hint)) }
            // The focus outline sits 2 px outside the box (`outline-offset:2px`).
            return NSSize(width: ceil(width), height: UIZoom.pt(20))
        }
    }

    /// The check box inside the control.
    public var boxRect: CGRect {
        let x: CGFloat = style == .boxed ? UIZoom.pt(8) : 0
        return CGRect(x: x, y: round((bounds.height - boxSize) / 2), width: boxSize, height: boxSize)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let box = boxRect
        switch style {
        case .boxed:
            Draw.fill(bounds, Palette.bg)
            Draw.strokeRect(bounds, color: isOn ? Palette.amberDim : Palette.lineBright)
            if isOn {
                Draw.fill(box, Palette.amber)
                drawCheck(in: box, size: 9)
            } else {
                Draw.strokeRect(box, color: Palette.dim)
            }
            Draw.text(titleStyle.string(title), x: box.maxX + UIZoom.pt(6), centerY: bounds.midY,
                      maxWidth: max(0, bounds.width - box.maxX - UIZoom.pt(6) - UIZoom.pt(10)))
            if isFocused { KeyboardFocus.drawRing(in: bounds) }
        case .plain:
            if isOn {
                Draw.fill(box, Palette.amber)
                drawCheck(in: box, size: 10)
            } else {
                Draw.fill(box, Palette.bg)
                Draw.strokeRect(box, color: Palette.lineBright)
            }
            if isFocused {
                Draw.strokeRect(box.insetBy(dx: -3, dy: -3), color: Palette.amber)
            }
            let gap = UIZoom.pt(8)
            var x = box.maxX + gap
            x += Draw.text(titleStyle.string(title), x: x, centerY: bounds.midY, maxWidth: max(0, bounds.width - x))
            if let hint, !hint.isEmpty {
                Draw.text(hintStyle.string(hint), x: x + gap, centerY: bounds.midY, maxWidth: max(0, bounds.width - x - gap))
            }
        }
    }

    private func drawCheck(in box: CGRect, size: CGFloat) {
        let mark = TextStyle.mono(size, .black).string("✓")
        Draw.text(mark, x: box.midX - Draw.width(mark) / 2, centerY: box.midY)
    }

    // MARK: Input

    /// Flips the box and sends the action (a click, Space or VoiceOver).
    public func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    public override func keyDown(with event: NSEvent) {
        if KeyboardFocus.key(of: event) == .space {
            focusTracker.noteKeyboardInteraction()
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { setHovered(true) }
    public override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ value: Bool) {
        guard isHovered != value else { return }
        isHovered = value
        if style == .boxed { needsDisplay = true }
    }
}
