import AppKit

/// Settings `.sx-step`: `[ − | 2 % | + ]`, 26 px, --bg with 1 px --line-bright borders; the buttons
/// are 11.5 px dim (amber on hover), the value cell cream and at least 40 px wide. The value stays
/// within `minValue...maxValue` in `increment` steps; `format` turns it into the cell text (`2 %`,
/// `13`). A click on − / +, ↑ ↓ ← → while focused and VoiceOver's increment / decrement change the
/// value and send `action`; nothing is sent when the value is already at a bound. Setting `value`
/// from code clamps it and sends nothing.
///
/// Keyboard focus (M5 D21) follows Full Keyboard Access and draws the helmet focus style around the
/// control (keyboard focus only; a click draws nothing).
public final class StepperControl: NSControl, KeyboardFocusTracking {
    public var value: Double {
        didSet {
            let clamped = clamp(value)
            if clamped != value { value = clamped; return }
            guard value != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            updateAccessibility()
        }
    }

    public var minValue: Double { didSet { value = clamp(value) } }
    public var maxValue: Double { didSet { value = clamp(value) } }
    public var increment: Double
    public var format: (Double) -> String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; updateAccessibility() } }
    /// `−` / `+` (`A−` / `A+` for the terminal font size).
    public let decrementTitle: String
    public let incrementTitle: String

    private enum Part { case decrement, increment }
    private var hovered: Part?
    private var trackingArea: NSTrackingArea?
    private let decrementButton = StepperPartElement()
    private let incrementButton = StepperPartElement()

    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in self?.updateGlow() }
        return tracker
    }()

    /// - Parameters:
    ///   - accessibilityLabel: the group's label (`自動切換門檻`).
    ///   - decrementLabel / incrementLabel: the buttons' labels (`門檻減 1%`, `門檻加 1%`).
    public init(value: Double, minValue: Double, maxValue: Double, increment: Double = 1,
                format: @escaping (Double) -> String = StepperControl.integerFormat,
                decrementTitle: String = "−", incrementTitle: String = "+",
                accessibilityLabel: String, decrementLabel: String? = nil, incrementLabel: String? = nil) {
        self.minValue = min(minValue, maxValue)
        self.maxValue = max(minValue, maxValue)
        self.increment = increment
        self.format = format
        self.decrementTitle = decrementTitle
        self.incrementTitle = incrementTitle
        self.value = min(max(minValue, maxValue), max(min(minValue, maxValue), value))
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.incrementor)
        setAccessibilityLabel(accessibilityLabel)
        decrementButton.configure(stepper: self, steps: -1, label: decrementLabel ?? decrementTitle)
        incrementButton.configure(stepper: self, steps: 1, label: incrementLabel ?? incrementTitle)
        setAccessibilityChildren([decrementButton, incrementButton])
        updateAccessibility()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `13`, `2` (whole numbers without a fraction).
    public static let integerFormat: (Double) -> String = { value in
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

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

    private func updateGlow() {
        shadow = isFocused ? KeyboardFocus.ringGlow : nil
    }

    // MARK: Geometry

    private var buttonStyle: TextStyle { TextStyle.mono(11.5, Palette.dim) }
    private var valueStyle: TextStyle { TextStyle.mono(13, Palette.cream) }

    /// The formatted value (`2 %`).
    public var valueText: String { format(value) }

    private var decrementWidth: CGFloat { ceil(Draw.width(buttonStyle.string(decrementTitle)) + UIZoom.pt(18)) }
    private var incrementWidth: CGFloat { ceil(Draw.width(buttonStyle.string(incrementTitle)) + UIZoom.pt(18)) }
    /// `.v{min-width:40px;padding:0 8px;border-left/right:1px}` (border-box).
    private var valueWidth: CGFloat { max(UIZoom.pt(40), ceil(Draw.width(valueStyle.string(valueText)) + UIZoom.pt(18))) }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: 1 + decrementWidth + valueWidth + incrementWidth + 1, height: UIZoom.pt(26))
    }

    /// The − button, the value cell and the + button inside the control.
    public var partRects: (decrement: CGRect, value: CGRect, increment: CGRect) {
        let minus = CGRect(x: 1, y: 1, width: decrementWidth, height: bounds.height - 2)
        let cell = CGRect(x: minus.maxX, y: 1, width: valueWidth, height: bounds.height - 2)
        let plus = CGRect(x: cell.maxX, y: 1, width: max(0, bounds.width - 1 - cell.maxX), height: bounds.height - 2)
        return (minus, cell, plus)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let parts = partRects
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        Draw.fill(CGRect(x: parts.value.minX, y: 1, width: 1, height: parts.value.height), Palette.lineBright)
        Draw.fill(CGRect(x: parts.value.maxX - 1, y: 1, width: 1, height: parts.value.height), Palette.lineBright)
        for (part, title, rect) in [(Part.decrement, decrementTitle, parts.decrement), (.increment, incrementTitle, parts.increment)] {
            let text = buttonStyle.with(color: hovered == part && isEnabled ? Palette.amber : Palette.dim).string(title)
            Draw.text(text, x: rect.midX - Draw.width(text) / 2, centerY: rect.midY)
        }
        let value = valueStyle.string(valueText)
        Draw.text(value, x: parts.value.midX - Draw.width(value) / 2, centerY: parts.value.midY)
        if isFocused { KeyboardFocus.drawRing(in: bounds) }
    }

    public override func layout() {
        super.layout()
        updatePartFrames()
    }

    private func updatePartFrames() {
        let parts = partRects
        decrementButton.setAccessibilityFrameInParentSpace(parts.decrement)
        incrementButton.setAccessibilityFrameInParentSpace(parts.increment)
    }

    /// Keyboard focus in a key window (not a click): draws the focus style.
    private var isFocused: Bool { focusTracker.showsFocusRing && isEnabled }

    // MARK: Stepping

    /// Moves `steps` increments and sends the action. False when the value did not change.
    @discardableResult
    public func step(by steps: Int) -> Bool {
        guard isEnabled else { return false }
        let old = value
        value = clamp(value + Double(steps) * increment)
        guard value != old else { return false }
        sendAction(action, to: target)
        return true
    }

    private func clamp(_ candidate: Double) -> Double {
        guard candidate.isFinite else { return minValue }
        return min(maxValue, max(minValue, candidate))
    }

    private func part(at point: CGPoint) -> Part? {
        let parts = partRects
        if parts.decrement.contains(point) { return .decrement }
        if parts.increment.contains(point) { return .increment }
        return nil
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        switch part(at: convert(event.locationInWindow, from: nil)) {
        case .decrement: step(by: -1)
        case .increment: step(by: 1)
        case nil: break
        }
    }

    public override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(of: event) {
        case .up?, .right?:
            focusTracker.noteKeyboardInteraction()
            step(by: 1)
        case .down?, .left?:
            focusTracker.noteKeyboardInteraction()
            step(by: -1)
        default:
            super.keyDown(with: event)
        }
    }

    public override func accessibilityPerformIncrement() -> Bool { step(by: 1) }
    public override func accessibilityPerformDecrement() -> Bool { step(by: -1) }

    private func updateAccessibility() {
        setAccessibilityValue(valueText)
        updatePartFrames()
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) { setHovered(part(at: convert(event.locationInWindow, from: nil))) }
    public override func mouseEntered(with event: NSEvent) { setHovered(part(at: convert(event.locationInWindow, from: nil))) }
    public override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ part: Part?) {
        guard hovered != part else { return }
        hovered = part
        needsDisplay = true
    }
}

/// VoiceOver element for one stepper button (`門檻減 1%`): a button that steps the stepper when pressed.
/// Not main-actor isolated (NSAccessibilityElement is not); VoiceOver calls it on the main thread.
private final class StepperPartElement: NSAccessibilityElement {
    private weak var stepper: StepperControl?
    private var steps = 0

    func configure(stepper: StepperControl, steps: Int, label: String) {
        self.stepper = stepper
        self.steps = steps
        setAccessibilityParent(stepper)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        // NSAccessibilityElement reports not-enabled by default (VoiceOver would say "dimmed").
        setAccessibilityEnabled(true)
    }

    override func accessibilityPerformPress() -> Bool {
        let stepper = self.stepper
        let steps = self.steps
        return MainActor.assumeIsolated { stepper?.step(by: steps) ?? false }
    }
}
