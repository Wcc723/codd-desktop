import AppKit

/// Settings `.sx-row`: the label column (`.sx-lab`: the 13 px cream name, its small EN caps label,
/// optional chips, optional detail views, then the 11.5 px dimmer hint that wraps) on the left, the
/// controls (`.sx-ctl`, gap 8) on the right, 24 px between them, `padding: 9px 16px`, at least
/// 52 px; `.tight` is `6px 16px`, at least 42 px. Rows are separated by 1 px dashed --line-bright
/// lines.
///
/// CSS gives every row a top border and pulls it up by 1 px (`margin-top:-1px`), so neighbours
/// share the line and the card clips the first one. Here each row draws the line on its bottom
/// pixel instead and is 1 px shorter (51 / 41): a stack of rows has exactly the artboard's
/// positions; turn `showsSeparator` off on the last row of a card.
///
/// Disabled (D17 later-milestone rows): drawn at 55 % (`.sx-dim`), with an optional milestone chip
/// (`M4`) after the name; clicks, keyboard focus and VoiceOver actions do not reach the controls.
/// Leave the controls themselves enabled (`.sx-dim .btn[disabled]{opacity:1}`: no double dimming).
/// Controls get at least `.defaultHigh` horizontal hugging so they keep their intrinsic width.
public final class FormRowView: FlippedView {
    public enum Variant: Sendable, Equatable {
        case regular, tight
    }

    public let variant: Variant
    public var name: String { didSet { if name != oldValue { updateLabels() } } }
    /// `.sx-en` (`UI font size`), uppercased.
    public var english: String? { didSet { if english != oldValue { updateLabels() } } }
    public var hint: String? { didSet { if hint != oldValue { updateLabels() } } }
    /// Later-milestone chip after the name (`M4`, `M5`, `FUTURE`).
    public var milestone: String? { didSet { if milestone != oldValue { rebuildNameLine() } } }
    public var isEnabled = true { didSet { if isEnabled != oldValue { applyEnabled() } } }
    /// The dashed line on the bottom pixel.
    public var showsSeparator = true { didSet { if showsSeparator != oldValue { needsDisplay = true } } }
    public private(set) var nameAccessories: [NSView]
    public private(set) var detailViews: [NSView]
    public private(set) var controls: [NSView]

    /// The wrapping hint (tests).
    public let hintLabel = WrappingLabel("", style: TextStyle.hint)

    private let nameLabel = Label.make(style: TextStyle.mono(13, Palette.cream))
    private let englishLabel = Label.make(style: TextStyle.caps(10.5, Palette.dimmer, tracking: 0.14))
    private let nameLine = hStack([], spacing: 8)
    private let labelColumn = vStack([], spacing: 2)
    private let controlStack = hStack([], spacing: 8)
    private var savedRefusal: [ObjectIdentifier: Bool] = [:]

    /// Row heights without the shared separator pixel (`.sx-row{min-height:52px}` − 1, `.tight` 42 − 1).
    public static func minimumHeight(_ variant: Variant) -> CGFloat { variant == .regular ? 51 : 41 }
    /// `.sx-lab .hint{line-height:1.45}` of 11.5 px.
    public static let hintLineHeight: CGFloat = 16.5

    public init(name: String, english: String? = nil, hint: String? = nil, variant: Variant = .regular,
                controls: [NSView] = [], nameAccessories: [NSView] = [], detailViews: [NSView] = [], milestone: String? = nil) {
        self.variant = variant
        self.name = name
        self.english = english
        self.hint = hint
        self.controls = controls
        self.nameAccessories = nameAccessories
        self.detailViews = detailViews
        self.milestone = milestone
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        hintLabel.maximumNumberOfLines = 0
        // The hint is what widens when the row has room (it wraps to the column width).
        hintLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        labelColumn.translatesAutoresizingMaskIntoConstraints = false
        controlStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelColumn)
        addSubview(controlStack)
        let padding: CGFloat = variant == .regular ? 9 : 6
        let collapse = heightAnchor.constraint(equalToConstant: 0)
        collapse.priority = .init(1)
        NSLayoutConstraint.activate([
            labelColumn.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(16),
            labelColumn.trailingAnchor.constraint(equalTo: controlStack.leadingAnchor).zoomed(-24),
            controlStack.trailingAnchor.constraint(equalTo: trailingAnchor).zoomed(-16),
            labelColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
            controlStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor).zoomed(padding),
            controlStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor).zoomed(padding),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumHeight(variant)).zoomed(Self.minimumHeight(variant)),
            collapse,
        ])
        // The label column takes every point the controls leave (`minmax(0,1fr) auto`): the control
        // stack hugs its views (NSStackView's own hugging, not content hugging), the column does not.
        labelColumn.setHuggingPriority(.init(1), for: .horizontal)
        controlStack.setHuggingPriority(.required, for: .horizontal)
        controlStack.setClippingResistancePriority(.required, for: .horizontal)
        // The name line keeps its labels together at the left (`.sx-name` is a flex row).
        nameLine.setHuggingPriority(.required, for: .horizontal)
        for label in [nameLabel, englishLabel] { label.setContentHuggingPriority(.defaultHigh, for: .horizontal) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        rebuildNameLine()
        rebuildColumn()
        rebuildControls()
        updateLabels()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func setControls(_ views: [NSView]) {
        restoreRefusal()
        controls = views
        rebuildControls()
        applyEnabled()
    }

    /// Chips after the EN label (`實驗`, `! 與預設不同`).
    public func setNameAccessories(_ views: [NSView]) {
        nameAccessories = views
        rebuildNameLine()
    }

    /// Views between the name line and the hint (the status directory's path).
    public func setDetailViews(_ views: [NSView]) {
        detailViews = views
        rebuildColumn()
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard showsSeparator else { return }
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.lineBright)
    }

    /// Disabled rows swallow clicks (the controls never see them).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }

    public override func accessibilityChildren() -> [Any]? {
        isEnabled ? super.accessibilityChildren() : []
    }

    // MARK: Building

    private func rebuildNameLine() {
        for view in nameLine.arrangedSubviews { nameLine.removeArrangedSubview(view); view.removeFromSuperview() }
        var views: [NSView] = [nameLabel]
        if let english, !english.isEmpty { views.append(englishLabel) }
        views += nameAccessories
        if let milestone, !milestone.isEmpty { views.append(ChipView(milestone, style: .milestone)) }
        for view in views { nameLine.addArrangedSubview(view) }
        updateAccessibility()
    }

    private func rebuildColumn() {
        for view in labelColumn.arrangedSubviews { labelColumn.removeArrangedSubview(view); view.removeFromSuperview() }
        labelColumn.addArrangedSubview(nameLine)
        for view in detailViews { labelColumn.addFullWidth(view) }
        labelColumn.addFullWidth(hintLabel)
        hintLabel.isHidden = (hint ?? "").isEmpty
    }

    private func rebuildControls() {
        for view in controlStack.arrangedSubviews { controlStack.removeArrangedSubview(view); view.removeFromSuperview() }
        for view in controls {
            // `.sx-ctl` is the grid's `auto` column: controls keep their own width and the label
            // column takes the rest (a control without an intrinsic width needs a width constraint).
            if let stack = view as? NSStackView {
                if stack.huggingPriority(for: .horizontal) < .defaultHigh { stack.setHuggingPriority(.defaultHigh, for: .horizontal) }
            } else if view.contentHuggingPriority(for: .horizontal) < .defaultHigh {
                view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            }
            controlStack.addArrangedSubview(view)
        }
    }

    private func updateLabels() {
        Label.set(nameLabel, name, style: TextStyle.mono(13, Palette.cream))
        Label.set(englishLabel, english ?? "", style: TextStyle.caps(10.5, Palette.dimmer, tracking: 0.14))
        let hintText = TextStyle.hint.string(hint ?? "", lineHeight: Self.hintLineHeight)
        if hintLabel.attributedStringValue != hintText { hintLabel.attributedStringValue = hintText }
        hintLabel.isHidden = (hint ?? "").isEmpty
        if (english ?? "").isEmpty != !nameLine.arrangedSubviews.contains(englishLabel) { rebuildNameLine() }
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityHelp(hint)
        setAccessibilityEnabled(isEnabled)
    }

    private var explicitAccessibilityLabel: String?

    /// `name english （milestone）` unless a caller set a label (theirs wins, also after later changes).
    public override func accessibilityLabel() -> String? {
        explicitAccessibilityLabel
            ?? [name, english, milestone.map { "（\($0)）" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }

    // MARK: Enabled state

    private func applyEnabled() {
        alphaValue = isEnabled ? 1 : 0.55
        if isEnabled { restoreRefusal() } else { refuseFocus(in: controlStack) }
        updateAccessibility()
    }

    /// Keeps Tab focus out of a disabled row's controls without disabling (and double-dimming) them:
    /// every NSControl and every other ``KeyboardFocusRefusing`` view (SelectButton, RadioRowView).
    private func refuseFocus(in view: NSView) {
        for sub in view.subviews {
            if let control = sub as? any KeyboardFocusRefusing, savedRefusal[ObjectIdentifier(control)] == nil {
                savedRefusal[ObjectIdentifier(control)] = control.refusesFirstResponder
                control.refusesFirstResponder = true
            }
            refuseFocus(in: sub)
        }
    }

    private func restoreRefusal() {
        guard !savedRefusal.isEmpty else { return }
        func walk(_ view: NSView) {
            for sub in view.subviews {
                if let control = sub as? any KeyboardFocusRefusing, let saved = savedRefusal[ObjectIdentifier(control)] {
                    control.refusesFirstResponder = saved
                }
                walk(sub)
            }
        }
        walk(controlStack)
        savedRefusal.removeAll()
    }
}
