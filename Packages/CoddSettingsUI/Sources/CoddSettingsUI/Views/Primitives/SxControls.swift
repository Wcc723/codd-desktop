import AppKit
import CoddUI

/// `.seg` with per-segment disabling (SESSIONS › 外部 session's `Detected 區`, NOTEBOOK › 位置's
/// iCloud Drive / 自訂…): square, caps 10.5 / .12em, 26 pt, the selected segment filled amber,
/// hover amber. `raw` keeps the titles' case. Disabled segments draw at 40 % and ignore clicks;
/// a segment may carry a milestone chip after its title (`M5`, drawn at full strength because it
/// is the explanation).
final class SxSegmented: SxKeyView {
    let titles: [String]
    private let raw: Bool
    var selectedIndex: Int { didSet { if selectedIndex != oldValue { needsDisplay = true; updateAccessibility() } } }
    var disabledIndices: Set<Int> = [] { didSet { needsDisplay = true } }
    /// Milestone chips per segment index (`[1: "M5", 2: "M5"]`).
    var segmentChips: [Int: String] = [:] {
        didSet {
            guard segmentChips != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            updateAccessibility()
        }
    }
    var isEnabled = true { didSet { needsDisplay = true; updateAccessibility() } }
    var onSelect: ((Int) -> Void)?
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?
    /// One radio button per segment, so VoiceOver can read and pick each (D21).
    private var segmentElements: [SxSegmentElement] = []

    init(titles: [String], selected: Int = 0, raw: Bool = false, accessibilityLabel: String) {
        self.titles = titles
        self.raw = raw
        selectedIndex = selected
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func style(on: Bool, color: NSColor) -> TextStyle {
        if raw { return TextStyle.mono(10.5, color, tracking: 0.03, on ? .bold : .regular) }
        return TextStyle.caps(10.5, color, tracking: 0.12, on ? .bold : .regular)
    }

    private static var chipGap: CGFloat { xz(6) }

    private var widths: [CGFloat] {
        titles.enumerated().map { index, title in
            let chip = segmentChips[index].map { Self.chipGap + ChipStyle.milestone.size(for: $0).width } ?? 0
            return Draw.width(style(on: true, color: .black).string(title)) + xz(20) + chip
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: widths.reduce(0, +) + CGFloat(max(0, titles.count - 1)) + xz(2), height: xz(26))
    }

    func segmentRect(_ index: Int) -> CGRect {
        var x: CGFloat = 1
        for (i, w) in widths.enumerated() {
            if i == index { return CGRect(x: x, y: 1, width: w, height: bounds.height - 2) }
            x += w + 1
        }
        return .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.strokeRect(bounds, color: Palette.lineBright)
        for (i, title) in titles.enumerated() {
            let rect = segmentRect(i)
            let on = i == selectedIndex
            let off = disabledIndices.contains(i)
            if on { Draw.fill(rect, Palette.amber) }
            var color = on ? NSColor.black : (hovered == i && isEnabled && !off ? Palette.amber : Palette.dim)
            if off, !on { color = color.withAlphaComponent(0.4) }
            let text = style(on: on, color: color).string(title)
            if let chip = segmentChips[i] {
                let x = Draw.text(text, x: rect.minX + xz(10), centerY: rect.midY) + rect.minX + xz(10) + Self.chipGap
                ChipStyle.milestone.draw(chip, x: x, centerY: rect.midY)
            } else {
                Draw.text(text, x: rect.midX - Draw.width(text) / 2, centerY: rect.midY)
            }
            if i < titles.count - 1 { Draw.fill(CGRect(x: rect.maxX, y: 1, width: 1, height: rect.height), Palette.lineBright) }
        }
    }

    private func index(at point: CGPoint) -> Int? {
        titles.indices.first { segmentRect($0).insetBy(dx: -0.5, dy: -1).contains(point) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pick(index)
    }

    /// The click path: ignored when disabled (the whole control or that segment).
    func pick(_ index: Int) {
        guard isEnabled, titles.indices.contains(index), !disabledIndices.contains(index) else { return }
        guard index != selectedIndex else { return }
        selectedIndex = index
        onSelect?(index)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ value: Int?) {
        guard hovered != value else { return }
        hovered = value
        needsDisplay = true
    }

    private func updateAccessibility() {
        setAccessibilityEnabled(isEnabled)
        setAccessibilityValue(titles.indices.contains(selectedIndex) ? titles[selectedIndex] : "")
        let later = segmentChips.keys.sorted().compactMap { titles.indices.contains($0) ? "\(titles[$0]) \(segmentChips[$0] ?? "") 提供" : nil }
        setAccessibilityHelp(later.isEmpty ? nil : later.joined(separator: "，"))
    }

    /// Whether segment `index` can be picked.
    func isSegmentEnabled(_ index: Int) -> Bool { isEnabled && titles.indices.contains(index) && !disabledIndices.contains(index) }

    // MARK: Keyboard and VoiceOver (D21)

    override var acceptsKeyFocus: Bool { titles.indices.contains { isSegmentEnabled($0) } }

    /// ← → (and ↑ ↓) pick the previous / next segment that can be picked; space and ⏎ keep the
    /// current one.
    override func handleKey(_ event: NSEvent) -> Bool {
        if let step = Self.arrowStep(event) {
            var index = selectedIndex + step
            while titles.indices.contains(index), !isSegmentEnabled(index) { index += step }
            if titles.indices.contains(index) { pick(index) }
            return true
        }
        return KeyFocus.isPressKey(event)
    }

    override func accessibilityChildren() -> [Any]? {
        if segmentElements.count != titles.count {
            segmentElements = titles.indices.map { SxSegmentElement(owner: self, index: $0) }
        }
        return segmentElements
    }

    fileprivate func segmentLabel(_ index: Int) -> String {
        guard titles.indices.contains(index) else { return "" }
        return segmentChips[index].map { "\(titles[index])（\($0) 提供）" } ?? titles[index]
    }
}

/// A segment of `SxSegmented` as VoiceOver sees it: a radio button with the segment's title,
/// selected or not, pressable when the segment can be picked. Accessibility asks on the main
/// thread (NSAccessibilityElement's methods are not isolated, hence `assumeIsolated`).
final class SxSegmentElement: NSAccessibilityElement {
    private weak var owner: SxSegmented?
    let index: Int

    @MainActor
    init(owner: SxSegmented, index: Int) {
        self.owner = owner
        self.index = index
        super.init()
        setAccessibilityParent(owner)
        setAccessibilityRole(.radioButton)
    }

    // The owner (a main-actor view, so Sendable) and the index are read first; the closures
    // never capture the element itself.
    override func accessibilityLabel() -> String? {
        let owner = owner, index = index
        return MainActor.assumeIsolated { owner?.segmentLabel(index) }
    }

    override func accessibilityValue() -> Any? {
        let owner = owner, index = index
        let selected: Int? = MainActor.assumeIsolated { owner.map { $0.selectedIndex == index ? 1 : 0 } }
        return selected
    }

    override func isAccessibilityEnabled() -> Bool {
        let owner = owner, index = index
        return MainActor.assumeIsolated { owner?.isSegmentEnabled(index) ?? false }
    }

    override func accessibilityFrame() -> NSRect {
        let owner = owner, index = index
        return MainActor.assumeIsolated {
            guard let owner, let window = owner.window else { return .zero }
            return window.convertToScreen(owner.convert(owner.segmentRect(index), to: nil))
        }
    }

    override func accessibilityPerformPress() -> Bool {
        let owner = owner, index = index
        return MainActor.assumeIsolated {
            guard let owner, owner.isSegmentEnabled(index) else { return false }
            owner.pick(index)
            return true
        }
    }
}

/// `.sx-cb`: 26 pt box-and-label toggle (5 小時 / 每週). On: cream text, amber-dim border, the 12 pt
/// box filled amber with a black ✓.
final class SxCheckbox: SxKeyView {
    let title: String
    var isOn: Bool { didSet { if isOn != oldValue { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } } }
    var isEnabled = true
    var onToggle: ((Bool) -> Void)?
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(title: String, isOn: Bool = false) {
        self.title = title
        self.isOn = isOn
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(title)
        setAccessibilityValue(isOn ? 1 : 0)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(7 + xz(12) + xz(6) + Draw.width(TextStyle.mono(12, Palette.dim).string(title)) + xz(9) + xz(2)), height: xz(26))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: isOn ? Palette.amberDim : Palette.lineBright)
        let box = CGRect(x: xz(8), y: round((bounds.height - xz(12)) / 2), width: xz(12), height: xz(12))
        if isOn {
            Draw.fill(box, Palette.amber)
            let check = TextStyle.mono(9, .black, .bold).string("✓")
            Draw.text(check, x: box.midX - Draw.width(check) / 2, centerY: box.midY)
        } else {
            Draw.strokeRect(box, color: Palette.dim)
        }
        let color = hovered && isEnabled ? Palette.amber : (isOn ? Palette.cream : Palette.dim)
        Draw.text(TextStyle.mono(12, color).string(title), x: box.maxX + xz(6), centerY: bounds.midY)
    }

    override func mouseDown(with event: NSEvent) { toggle() }

    override var acceptsKeyFocus: Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }

    func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        onToggle?(isOn)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

/// `.sx-step`: `− value +` (or `A− 13 A+`) in one 26 pt box; the value cell has borders at both
/// sides (min 40 wide). `onStep(-1 / +1)`; the owner clamps and sets `value`.
final class SxStepper: SxKeyView {
    let minus: String
    let plus: String
    var value: String { didSet { if value != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityValue(value) } } }
    var isEnabled = true
    var onStep: ((Int) -> Void)?
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?

    init(minus: String, plus: String, value: String, accessibilityLabel: String) {
        self.minus = minus
        self.plus = plus
        self.value = value
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.incrementor)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(value)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var buttonStyle: TextStyle { TextStyle.mono(11.5, Palette.dim) }
    private var minusWidth: CGFloat { Draw.width(buttonStyle.string(minus)) + 18 }
    private var plusWidth: CGFloat { Draw.width(buttonStyle.string(plus)) + 18 }
    private var valueWidth: CGFloat { max(40, Draw.width(TextStyle.mono(12.5, Palette.cream).string(value)) + 16) }

    override var intrinsicContentSize: NSSize { NSSize(width: ceil(minusWidth + valueWidth + plusWidth + xz(2)), height: xz(26)) }

    private var minusRect: CGRect { CGRect(x: 1, y: 1, width: minusWidth, height: bounds.height - 2) }
    private var plusRect: CGRect { CGRect(x: bounds.width - 1 - plusWidth, y: 1, width: plusWidth, height: bounds.height - 2) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        let valueRect = CGRect(x: minusRect.maxX, y: 0, width: plusRect.minX - minusRect.maxX, height: bounds.height)
        Draw.fill(CGRect(x: valueRect.minX, y: 0, width: 1, height: bounds.height), Palette.lineBright)
        Draw.fill(CGRect(x: valueRect.maxX - 1, y: 0, width: 1, height: bounds.height), Palette.lineBright)
        for (index, (label, rect)) in [(minus, minusRect), (plus, plusRect)].enumerated() {
            let text = buttonStyle.with(color: hovered == index && isEnabled ? Palette.amber : Palette.dim).string(label)
            Draw.text(text, x: rect.midX - Draw.width(text) / 2, centerY: rect.midY)
        }
        let v = TextStyle.mono(12.5, Palette.cream).string(value)
        Draw.text(v, x: valueRect.midX - Draw.width(v) / 2, centerY: valueRect.midY)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if minusRect.contains(point) { step(-1) } else if plusRect.contains(point) { step(1) }
    }

    func step(_ delta: Int) {
        guard isEnabled else { return }
        onStep?(delta)
    }

    override func accessibilityPerformIncrement() -> Bool { guard isEnabled else { return false }; step(1); return true }
    override func accessibilityPerformDecrement() -> Bool { guard isEnabled else { return false }; step(-1); return true }

    override var acceptsKeyFocus: Bool { isEnabled }

    /// → ↑ step up, ← ↓ step down (D21).
    override func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return false }
        switch event.keyCode {
        case 124, 126: step(1)
        case 123, 125: step(-1)
        default: return KeyFocus.isPressKey(event)
        }
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let next: Int? = minusRect.contains(point) ? 0 : (plusRect.contains(point) ? 1 : nil)
        if next != hovered { hovered = next; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) { hovered = nil; needsDisplay = true }
}

/// A `.btn.sm` that cannot be pressed (later-milestone rows, D17): drawn at full strength so the
/// row's 55 % is the only dimming (`.sx-dim .btn[disabled]{opacity:1}`), no hover, no action.
final class SxStaticButton: NSView {
    enum Variant { case normal, accent }
    var label: String { didSet { if label != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true; setAccessibilityLabel(label) } } }
    let variant: Variant
    /// A later milestone's button (D17): drawn in the disabled colors, so it does not read as
    /// clickable next to the dimmed row it sits in (M3 review).
    var isDisabledLook = false { didSet { if isDisabledLook != oldValue { needsDisplay = true } } }

    init(_ label: String, variant: Variant = .normal, accessibilityLabel: String? = nil) {
        self.label = label
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel ?? label)
        setAccessibilityEnabled(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var style: TextStyle {
        let color = isDisabledLook ? Palette.dim : variant == .accent ? Palette.amber : Palette.cream
        return TextStyle(font: Typeface.mono(10.5, .medium), color: color, tracking: 0.08, uppercase: true)
    }

    override var intrinsicContentSize: NSSize {
        let body = Draw.width(style.string(label))
        let bracket = Draw.width(style.string("["))
        return NSSize(width: ceil(body + bracket * 2 + xz(14) + xz(8)), height: xz(22))
    }

    override func draw(_ dirtyRect: NSRect) {
        let border = variant == .accent && !isDisabledLook ? Palette.amberDim : Palette.lineBright
        let bracketColor = variant == .accent && !isDisabledLook ? Palette.amberDim : Palette.dim
        Draw.strokeRect(bounds, color: border)
        let open = style.with(color: bracketColor).string("[")
        let close = style.with(color: bracketColor).string("]")
        let body = style.string(label)
        let total = Draw.width(open) + xz(4) + Draw.width(body) + xz(4) + Draw.width(close)
        var x = (bounds.width - total) / 2
        x += Draw.text(open, x: x, centerY: bounds.midY) + xz(4)
        x += Draw.text(body, x: x, centerY: bounds.midY) + xz(4)
        Draw.text(close, x: x, centerY: bounds.midY)
    }
}

/// An `.input` that commits on ⏎ or when it loses focus (never mid-composition: the input method
/// takes ⏎ while 注音 is composing, and leaving the field commits the composed text first), and
/// reverts on ⎋. `onCommit` decides (and applies the edit): accept (show the stored form), reject (keep the typed
/// text and report it invalid until the next edit), or revert to the stored value.
final class SxTextInput: FlippedView {
    enum Verdict: Equatable {
        case accept(String)
        case reject
        case revert
    }

    let input: InputField
    var onCommit: ((String) -> Verdict)?
    /// Rewrites typed text as it changes (digits only); not applied while composing.
    var filter: ((String) -> String)?
    /// The typed text became invalid / valid again (the owner shows or hides its hint).
    var onValidity: ((Bool) -> Void)?
    private(set) var storedValue: String
    private(set) var isInvalid = false
    var isEnabled = true {
        didSet {
            input.isEnabled = isEnabled
            input.isDimmed = false
        }
    }

    init(value: String, placeholder: String = "", width: CGFloat, alignment: NSTextAlignment = .left, accessibilityLabel: String) {
        storedValue = value
        input = InputField(placeholder: placeholder, accessibilityLabel: accessibilityLabel)
        super.init(frame: .zero)
        input.text = value
        input.field.alignment = alignment
        input.translatesAutoresizingMaskIntoConstraints = false
        addSubview(input)
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: leadingAnchor),
            input.trailingAnchor.constraint(equalTo: trailingAnchor),
            input.topAnchor.constraint(equalTo: topAnchor),
            input.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30).zoomed(30),
        ])
        // `width` where the row has room; a wide field (a path) narrows down to 160 in a narrow
        // row (small window, zoom 20) instead of holding the Settings window wide.
        let preferred = widthAnchor.constraint(equalToConstant: width).zoomed(width)
        preferred.priority = NSLayoutConstraint.Priority(480)
        preferred.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: min(width, 160)).zoomed(min(width, 160)).isActive = true
        input.onCommand = { [weak self] selector in
            guard let self else { return false }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                self.commit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                self.revert()
                return true
            }
            return false
        }
        input.onFocusChange = { [weak self] focused in
            if !focused { self?.commit() }
        }
        input.onChange = { [weak self] text in
            guard let self else { return }
            if let filter = self.filter, !self.input.isComposing {
                let filtered = filter(text)
                if filtered != text { self.input.text = filtered }
            }
            if self.isInvalid { self.setInvalid(false) }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var text: String { input.text }
    var isEditing: Bool { input.isFocused || input.isEditingText }

    /// Leaving the window (the section is swapped out, the window closes) commits what was typed:
    /// editing is ended first, so the field editor lets go and the commit sees the final text.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window, let window, isEditing {
            if input.isEditingText { window.makeFirstResponder(nil) }
            commit()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// The stored value changed elsewhere: shown unless the user is typing or looking at a
    /// refused entry.
    func setValue(_ value: String) {
        storedValue = value
        guard !isEditing, !isInvalid else { return }
        input.text = value
    }

    func commit() {
        guard isEnabled else { return }
        let typed = input.text
        guard typed != storedValue || isInvalid else { return }
        switch onCommit?(typed) ?? .accept(typed) {
        case .accept(let shown):
            storedValue = shown
            input.text = shown
            setInvalid(false)
        case .reject:
            setInvalid(true)
        case .revert:
            input.text = storedValue
            setInvalid(false)
        }
    }

    func revert() {
        input.text = storedValue
        setInvalid(false)
    }

    /// Types `text` and presses ⏎ (tests; ignored when disabled like a real entry).
    func simulateEntry(_ text: String) {
        guard isEnabled else { return }
        input.text = filter.map { $0(text) } ?? text
        if isInvalid { setInvalid(false) }
        commit()
    }

    private func setInvalid(_ value: Bool) {
        guard isInvalid != value else { return }
        isInvalid = value
        onValidity?(!value)
    }
}

extension SwitchToggle {
    /// A click (ignored when disabled).
    func simulateClick() { _ = accessibilityPerformPress() }
}

extension SelectButton {
    /// Picks item `index` from the menu (ignored when disabled).
    func simulateChoose(_ index: Int) {
        guard isEnabled, titles.indices.contains(index) else { return }
        setItems(titles, selected: index)
        displayTitle = nil
        onSelect?(index)
    }
}

/// `.sx-link`: 12 px amber text with a dashed underline (3 pt below), cream on hover.
final class SxLinkButton: SxKeyView {
    let label: String
    var onClick: (() -> Void)?
    var isEnabled = true { didSet { needsDisplay = true } }
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(_ label: String, accessibilityLabel: String? = nil) {
        self.label = label
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.link)
        setAccessibilityLabel(accessibilityLabel ?? label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    private var text: NSAttributedString { TextStyle.mono(12, hovered && isEnabled ? Palette.cream : Palette.amber).string(label) }
    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(text), height: xz(20)) }

    override func draw(_ dirtyRect: NSRect) {
        let string = text
        let width = Draw.text(string, x: 0, centerY: bounds.midY - 1)
        let y = round(bounds.midY + Typeface.lineHeight(Typeface.mono(12)) / 2 - 1)
        Draw.dashedLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: width, y: y), color: hovered && isEnabled ? Palette.cream : Palette.amber)
    }

    override func mouseDown(with event: NSEvent) { click() }

    override var acceptsKeyFocus: Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        click()
        return true
    }

    func click() {
        guard isEnabled else { return }
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

/// `.sx-gchip`: a group's tag square and name; on (muted): amber-dim border, amber text, a 6 %
/// amber fill and the `靜音` suffix.
final class GroupChipView: SxKeyView {
    let groupID: String
    let name: String
    let color: NSColor?
    var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; invalidateIntrinsicContentSize(); setAccessibilityValue(isOn ? 1 : 0) } } }
    var isEnabled = true
    var onToggle: ((Bool) -> Void)?
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(groupID: String, name: String, color: NSColor?) {
        self.groupID = groupID
        self.name = name
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("靜音 \(name)")
        setAccessibilityValue(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var nameStyle: TextStyle { TextStyle.mono(11, isOn ? Palette.amber : (hovered ? Palette.cream : Palette.bone)) }
    private var suffix: NSAttributedString { TextStyle.mono(9.5, Palette.amberDim, tracking: 0.1).string("靜音") }

    override var intrinsicContentSize: NSSize {
        var width = xz(9) + xz(8) + xz(6) + Draw.width(nameStyle.string(name)) + xz(9)
        if isOn { width += 6 + Draw.width(suffix) }
        return NSSize(width: ceil(width), height: xz(24))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isOn { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06)) }
        Draw.strokeRect(bounds, color: isOn ? Palette.amberDim : (hovered ? Palette.dim : Palette.lineBright))
        let square = CGRect(x: xz(9), y: round(bounds.midY - xz(4)), width: xz(8), height: xz(8))
        if let color { Draw.fill(square, color) } else { Draw.dashedRect(square, color: Palette.dimmer, dash: [2, 1]) }
        var x = square.maxX + xz(6)
        x += Draw.text(nameStyle.string(name), x: x, centerY: bounds.midY)
        if isOn { Draw.text(suffix, x: x + xz(6), centerY: bounds.midY) }
    }

    override func mouseDown(with event: NSEvent) { toggle() }

    override var acceptsKeyFocus: Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }

    func toggle() {
        guard isEnabled else { return }
        isOn.toggle()
        onToggle?(isOn)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
}

/// A read-only value in the `.input` look (NOTEBOOK › Port 與 token: the hook server's port, which
/// MCP shares, D33): the field box with 12.5 cream text and no editing, so it reads like the
/// artboard's input without suggesting it can be changed.
final class SxValueBox: FieldBoxView {
    private(set) var value: String
    private let alignment: NSTextAlignment

    init(value: String, width: CGFloat, alignment: NSTextAlignment = .left, accessibilityLabel: String) {
        self.value = value
        self.alignment = alignment
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width).zoomed(width),
            heightAnchor.constraint(equalToConstant: 30).zoomed(30),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityValue(value)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ value: String) {
        guard value != self.value else { return }
        self.value = value
        setAccessibilityValue(value)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let text = TextStyle.mono(12.5, Palette.cream).string(value)
        let room = bounds.width - xz(18)
        let width = min(Draw.width(text), room)
        let x = alignment == .right ? bounds.width - xz(9) - width : xz(9)
        Draw.text(text, x: x, centerY: bounds.midY, maxWidth: room)
    }
}
