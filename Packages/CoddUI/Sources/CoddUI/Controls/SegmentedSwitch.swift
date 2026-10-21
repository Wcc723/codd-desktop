import AppKit

/// Segmented control (`.seg`): square, caps, the selected segment filled amber. `raw` keeps the
/// titles as written (`.ns-raw`: permission modes such as `acceptEdits`); `selectedIndex` -1
/// selects none (a mode the segments do not list).
///
/// VoiceOver: a radio group whose children are one radio button per segment (title, value 0 / 1,
/// press selects). Keyboard (M5 D21, while Full Keyboard Access is on): ← / → select the previous /
/// next segment and send `action` (no wrap); Space selects the first segment when none is selected;
/// keyboard focus draws the helmet focus style around the control.
public final class SegmentedSwitch: NSControl, KeyboardFocusTracking {
    public private(set) var titles: [String]
    private let raw: Bool
    public var selectedIndex = 0 { didSet { if selectedIndex != oldValue { needsDisplay = true; updateAccessibility() } } }

    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in self?.updateGlow() }
        return tracker
    }()

    private var segmentElements: [SegmentElement] = []

    public init(titles: [String], raw: Bool = false) {
        self.titles = titles
        self.raw = raw
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        segmentElements = titles.indices.map { index in
            let element = SegmentElement()
            element.configure(control: self, index: index, title: titles[index])
            return element
        }
        setAccessibilityChildren(segmentElements)
        updateAccessibility()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
            needsDisplay = true
            updateGlow()
            for element in segmentElements { element.setAccessibilityEnabled(isEnabled) }
        }
    }

    private var style: TextStyle {
        raw ? TextStyle.mono(11, Palette.dim, tracking: 0.03) : TextStyle.caps(10.5, Palette.dim, tracking: 0.12)
    }

    private var onStyle: TextStyle {
        raw ? TextStyle.mono(11, .black, tracking: 0.03, .bold) : TextStyle.caps(10.5, .black, tracking: 0.12, .bold)
    }

    private var segmentWidths: [CGFloat] {
        titles.map { Draw.width(style.string($0)) + UIZoom.pt(20) }
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: segmentWidths.reduce(0, +) + CGFloat(max(0, titles.count - 1)) + 2, height: UIZoom.pt(26))
    }

    /// Segment `index`'s rectangle inside the control (between the borders and dividers).
    public func segmentRect(_ index: Int) -> CGRect {
        var x: CGFloat = 1
        for (i, w) in segmentWidths.enumerated() {
            if i == index { return CGRect(x: x, y: 1, width: w, height: max(0, bounds.height - 2)) }
            x += w + 1
        }
        return .zero
    }

    private func updateAccessibility() {
        setAccessibilityValue(titles.indices.contains(selectedIndex) ? titles[selectedIndex] : "")
        for element in segmentElements { element.setAccessibilityValue(element.index == selectedIndex ? 1 : 0) }
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.strokeRect(bounds, color: Palette.lineBright)
        var x: CGFloat = 1
        for (i, title) in titles.enumerated() {
            let w = segmentWidths[i]
            let rect = CGRect(x: x, y: 1, width: w, height: bounds.height - 2)
            let on = i == selectedIndex
            if on { Draw.fill(rect, Palette.amber) }
            let text = (on ? onStyle : style).string(title)
            Draw.text(text, x: rect.midX - Draw.width(text) / 2, centerY: rect.midY)
            if i < titles.count - 1 { Draw.fill(CGRect(x: rect.maxX, y: 1, width: 1, height: rect.height), Palette.lineBright) }
            x += w + 1
        }
        if focusTracker.showsFocusRing, isEnabled { KeyboardFocus.drawRing(in: bounds) }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        var x: CGFloat = 1
        for (i, w) in segmentWidths.enumerated() {
            if point.x >= x, point.x < x + w + 1 {
                select(i)
                return
            }
            x += w + 1
        }
    }

    /// Selects segment `index` as the user would (sends `action` when it changed). False when
    /// disabled, out of range or already selected.
    @discardableResult
    public func select(_ index: Int) -> Bool {
        guard isEnabled, titles.indices.contains(index), index != selectedIndex else { return false }
        selectedIndex = index
        sendAction(action, to: target)
        return true
    }

    // MARK: Keyboard focus

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

    public override func keyDown(with event: NSEvent) {
        guard isEnabled, !titles.isEmpty else { super.keyDown(with: event); return }
        let none = !titles.indices.contains(selectedIndex)
        switch KeyboardFocus.key(of: event) {
        case .left?:
            focusTracker.noteKeyboardInteraction()
            select(none ? 0 : selectedIndex - 1)
        case .right?:
            focusTracker.noteKeyboardInteraction()
            select(none ? 0 : selectedIndex + 1)
        case .space? where none:
            focusTracker.noteKeyboardInteraction()
            select(0)
        case .space?:
            focusTracker.noteKeyboardInteraction()
        default:
            super.keyDown(with: event)
        }
    }

    private func updateGlow() {
        shadow = focusTracker.showsFocusRing && isEnabled ? KeyboardFocus.ringGlow : nil
    }
}

/// VoiceOver element for one segment: a radio button that selects its segment when pressed.
/// Not main-actor isolated (NSAccessibilityElement is not); VoiceOver calls it on the main thread.
private final class SegmentElement: NSAccessibilityElement {
    private weak var control: SegmentedSwitch?
    private(set) var index = 0

    func configure(control: SegmentedSwitch, index: Int, title: String) {
        self.control = control
        self.index = index
        setAccessibilityParent(control)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityValue(0)
        // NSAccessibilityElement reports not-enabled by default (VoiceOver would say "dimmed").
        setAccessibilityEnabled(true)
    }

    /// Computed on demand from the control's current geometry (layout and zoom change it).
    override func accessibilityFrame() -> NSRect {
        let control = self.control
        let index = self.index
        return MainActor.assumeIsolated {
            guard let control else { return .zero }
            return NSAccessibility.screenRect(fromView: control, rect: control.segmentRect(index))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let control = self.control
        let index = self.index
        return MainActor.assumeIsolated {
            guard let control else { return false }
            return control.select(index) || control.selectedIndex == index
        }
    }
}
