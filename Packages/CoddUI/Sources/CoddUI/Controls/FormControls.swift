import AppKit

/// The square box behind `.input` / `.select` (helmet: bg-soft, 1 px line-bright; focused: amber
/// border + 1 px amber inset + an 8 px amber glow). Disabled boxes draw at 55 % (Settings `.sx-dim`).
open class FieldBoxView: FlippedView {
    open var isFocused = false { didSet { if isFocused != oldValue { needsDisplay = true; updateGlow() } } }
    open var isDimmed = false { didSet { if isDimmed != oldValue { alphaValue = isDimmed ? 0.55 : 1 } } }
    open var fill: NSColor = Palette.bgSoft { didSet { needsDisplay = true } }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    open override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, fill)
        if isFocused {
            KeyboardFocus.drawRing(in: bounds)
        } else {
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
    }

    /// `0 0 8px var(--amber-glow)` as a layer shadow (the render server blurs it); the same token as
    /// every keyboard-focused control (``KeyboardFocus/ringGlow``).
    private func updateGlow() {
        shadow = isFocused ? KeyboardFocus.ringGlow : nil
    }
}

/// `.input`: one-line field in a `FieldBoxView` (12.5 cream, amber caret, padding 5 / 9). The
/// system field editor edits it, so input methods (注音) work. `onCommand` sees the field
/// editor's commands first (↑ ↓ ⏎ esc), after the input method.
public final class InputField: FieldBoxView, NSTextFieldDelegate {
    public let field = NSTextField()
    public var onChange: ((String) -> Void)?
    public var onFocusChange: ((Bool) -> Void)?
    /// Return true when the command was handled.
    public var onCommand: ((Selector) -> Bool)?
    private let fontSize: CGFloat

    public var text: String {
        get { field.stringValue }
        set { if field.stringValue != newValue { field.stringValue = newValue } }
    }

    /// The field editor composes (注音): its keys belong to the input method.
    public var isComposing: Bool { (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false }

    public init(placeholder: String, size: CGFloat = 12.5, accessibilityLabel: String? = nil) {
        fontSize = size
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typeface.mono(size)
        field.textColor = Palette.cream
        field.placeholderAttributedString = TextStyle.mono(size, Palette.dimmer).string(placeholder)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.lineBreakMode = .byClipping
        field.delegate = self
        field.setAccessibilityLabel(accessibilityLabel ?? placeholder)
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor).zoomed(9),
            field.trailingAnchor.constraint(equalTo: trailingAnchor).zoomed(-9),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 30).zoomed(30),
        ])
    }

    public var isEnabled: Bool {
        get { field.isEnabled }
        set { field.isEnabled = newValue; isDimmed = !newValue }
    }

    public func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    public func controlTextDidBeginEditing(_ obj: Notification) {
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.insertionPointColor = Palette.amber
    }

    /// Editing ended (`makeFirstResponder(nil)`, Tab, a window that closes): reported at once,
    /// even before the poll below saw the focus arrive. The poll runs on the window's next
    /// update, which a closing window or a field leaving its window never gets, so a typed value
    /// was lost there (M3 review). Owners treat `false` as "commit", which is idempotent.
    public func controlTextDidEndEditing(_ obj: Notification) {
        isFocused = false
        onFocusChange?(false)
    }

    /// The field editor is editing this field right now (also before the poll noticed).
    public var isEditingText: Bool { field.currentEditor() != nil }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        onCommand?(selector) ?? false
    }

    /// Focus follows the field editor (begin / end editing miss a click that only focuses).
    /// Only the window observation is dropped here: a blanket `removeObserver(self)` would also drop
    /// the NSControl delegate registration behind `controlTextDidChange` (onChange went silent once
    /// the field was in a window; fixed in M3 I1a).
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(responderMayHaveChanged), name: NSWindow.didUpdateNotification,
                                               object: window)
    }

    @objc private func responderMayHaveChanged() {
        let focused = (window?.firstResponder as? NSTextView).map { $0.delegate === field } ?? false
        guard focused != isFocused else { return }
        isFocused = focused
        if focused { (window?.firstResponder as? NSTextView)?.insertionPointColor = Palette.amber }
        onFocusChange?(focused)
    }

    public func focus() { window?.makeFirstResponder(field) }
}

/// `.select`: a box with the value and the amber chevron that opens a native menu under it.
/// `onSelect` gets the picked index. Disabled: drawn at 55 %, does nothing (D16 account select).
/// Keyboard (Full Keyboard Access): Space, ⏎, ↑ and ↓ open the menu; keyboard focus draws the
/// `.select:focus` look (the field box's focused border and glow).
public final class SelectButton: FieldBoxView, KeyboardFocusTracking, KeyboardFocusRefusing {
    public private(set) var titles: [String] = []
    public private(set) var selectedIndex = 0
    /// Per item: whether it can be picked (a disabled item is listed dimmed). Empty = all enabled.
    public private(set) var itemEnabled: [Bool] = []
    /// Per item: the menu item's tooltip (why it is disabled). Empty = none.
    public private(set) var itemToolTips: [String?] = []
    /// Shown instead of the selected title (a value that is not one of the items).
    public var displayTitle: String? { didSet { needsDisplay = true; setAccessibilityValue(currentTitle) } }
    public var onSelect: ((Int) -> Void)?
    public var isEnabled = true {
        didSet {
            isDimmed = !isEnabled
            needsDisplay = true
            setAccessibilityEnabled(isEnabled)
            focusTracker.onChange?()
        }
    }
    /// Keeps the select out of keyboard focus while enabled (a disabled form row).
    public var refusesFirstResponder = false

    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in
            guard let self else { return }
            self.isFocused = self.focusTracker.showsFocusRing && self.isEnabled
        }
        return tracker
    }()

    /// Tests: shows the menu instead of `NSMenu.popUp` (which runs a modal tracking loop).
    var menuPresenter: ((NSMenu) -> Void)?

    public init(titles: [String], selected: Int = 0, accessibilityLabel: String) {
        super.init(frame: .zero)
        focusRingType = .none
        setItems(titles, selected: selected)
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel(accessibilityLabel)
        // NSView reports not-enabled by default (VoiceOver would say "dimmed").
        setAccessibilityEnabled(true)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).zoomed(30).isActive = true
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
        switch KeyboardFocus.key(of: event) {
        case .space?, .return?, .up?, .down?:
            guard isEnabled else { break }
            focusTracker.noteKeyboardInteraction()
            showMenu()
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    public func setItems(_ titles: [String], selected: Int) {
        setItems(titles, selected: selected, enabled: [], toolTips: [])
    }

    /// `enabled` / `toolTips` per item (missing entries: enabled, no tooltip).
    public func setItems(_ titles: [String], selected: Int, enabled: [Bool], toolTips: [String?]) {
        self.titles = titles
        itemEnabled = enabled
        itemToolTips = toolTips
        selectedIndex = titles.indices.contains(selected) ? selected : 0
        setAccessibilityValue(currentTitle)
        needsDisplay = true
    }

    /// Whether item `index` can be picked.
    public func isItemEnabled(_ index: Int) -> Bool { itemEnabled.indices.contains(index) ? itemEnabled[index] : true }

    public var currentTitle: String { displayTitle ?? (titles.indices.contains(selectedIndex) ? titles[selectedIndex] : "") }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(30)) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let z = UIZoom.pt
        Draw.text(TextStyle.mono(12.5, Palette.cream).string(currentTitle), x: z(9), centerY: bounds.midY, maxWidth: bounds.width - z(9) - z(26))
        // helmet `.select`: two 5 px gradient triangles 13 / 8 px from the right edge make one
        // amber ▼ (10 × 5) centered 13 px in.
        let x = bounds.maxX - z(13)
        let y = bounds.midY
        let w = UIZoom.scaled(5)
        let h = UIZoom.scaled(2.5)
        let chevron = NSBezierPath()
        chevron.move(to: CGPoint(x: x - w, y: y - h))
        chevron.line(to: CGPoint(x: x + w, y: y - h))
        chevron.line(to: CGPoint(x: x, y: y + h))
        chevron.close()
        Palette.amber.setFill()
        chevron.fill()
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        showMenu()
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        showMenu()
        return true
    }

    public func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, title) in titles.enumerated() {
            let item = ClosureMenuItem(title: title) { [weak self] in
                guard let self else { return }
                self.selectedIndex = index
                self.displayTitle = nil
                self.setAccessibilityValue(self.currentTitle)
                self.needsDisplay = true
                self.onSelect?(index)
            }
            item.state = index == selectedIndex && displayTitle == nil ? .on : .off
            item.isEnabled = isItemEnabled(index)
            if itemToolTips.indices.contains(index) { item.toolTip = itemToolTips[index] }
            menu.addItem(item)
        }
        menu.minimumWidth = bounds.width
        if let menuPresenter { menuPresenter(menu); return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + UIZoom.pt(2)), in: self)
    }
}

/// `.ns-radio`: 24 pt row with `○` / `●` (amber with its glow when on), the label (bone, cream
/// when on) and a right-aligned hint. A click picks it. Keyboard (Full Keyboard Access): Space picks
/// it; ↑ ← / ↓ → pick the previous / next enabled row among its siblings (the rows of one
/// superview, in stack order) and move the focus there.
public final class RadioRowView: FlippedView, KeyboardFocusTracking, KeyboardFocusRefusing {
    public let title: String
    public let hint: String
    public var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; setAccessibilityValue(isOn ? 1 : 0) } } }
    public var onClick: (() -> Void)?
    public var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.4
            setAccessibilityEnabled(isEnabled)
            needsDisplay = true
            updateGlow()
        }
    }
    /// Keeps the row out of keyboard focus while enabled (a disabled form row).
    public var refusesFirstResponder = false

    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in self?.updateGlow() }
        return tracker
    }()

    private var explicitAccessibilityLabel: String?

    public init(title: String, hint: String) {
        self.title = title
        self.hint = hint
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(0)
        // NSView reports not-enabled by default (VoiceOver would say "dimmed").
        setAccessibilityEnabled(true)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 24).zoomed(24).isActive = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(24)) }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Accessibility

    /// `title（hint）` unless a caller set a label (theirs wins).
    public override func accessibilityLabel() -> String? {
        explicitAccessibilityLabel ?? (hint.isEmpty ? title : "\(title)（\(hint)）")
    }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
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
        guard isEnabled else { super.keyDown(with: event); return }
        switch KeyboardFocus.key(of: event) {
        case .space?:
            focusTracker.noteKeyboardInteraction()
            onClick?()
        case .up?, .left?:
            if !moveToSibling(by: -1) { super.keyDown(with: event) }
        case .down?, .right?:
            if !moveToSibling(by: 1) { super.keyDown(with: event) }
        default:
            super.keyDown(with: event)
        }
    }

    /// The enabled, visible radio rows next to this one (same superview, stack order).
    public var siblingRows: [RadioRowView] {
        guard let superview else { return [self] }
        let views = (superview as? NSStackView)?.arrangedSubviews ?? superview.subviews
        return views.compactMap { $0 as? RadioRowView }.filter { $0 === self || ($0.isEnabled && !$0.isHidden) }
    }

    /// Picks the row `offset` places away and focuses it (as keyboard focus). False at either end.
    @discardableResult
    public func moveToSibling(by offset: Int) -> Bool {
        let rows = siblingRows
        guard let index = rows.firstIndex(where: { $0 === self }), rows.indices.contains(index + offset) else { return false }
        let target = rows[index + offset]
        target.onClick?()
        if window?.firstResponder === self {
            KeyboardFocus.focusAsKeyboardNavigation(target)
        }
        return true
    }

    private func updateGlow() {
        shadow = focusTracker.showsFocusRing && isEnabled ? KeyboardFocus.ringGlow : nil
    }

    public override func draw(_ dirtyRect: NSRect) {
        let z = UIZoom.pt
        let mid = bounds.midY
        var glyph = TextStyle.mono(12.5, isOn ? Palette.amber : Palette.dimmer)
        if isOn { glyph.shadow = Draw.glow(Palette.amberGlow, radius: 6) }
        let mark = glyph.string(isOn ? "●" : "○")
        Draw.text(mark, x: (z(14) - Draw.width(mark)) / 2, centerY: mid)
        let hintText = TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02).string(hint)
        let hintWidth = Draw.width(hintText)
        Draw.text(hintText, x: bounds.width - hintWidth, centerY: mid)
        Draw.text(TextStyle.mono(12.5, isOn ? Palette.cream : Palette.bone).string(title), x: z(22), centerY: mid,
                  maxWidth: max(0, bounds.width - z(22) - hintWidth - z(8)))
        if focusTracker.showsFocusRing, isEnabled { KeyboardFocus.drawRing(in: bounds) }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onClick?()
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        onClick?()
        return true
    }
}

/// `.sw`: 30×16 switch (knob dimmer at the left; on: amber knob with its glow at the right).
/// VoiceOver: a checkbox (subrole switch) whose value reads 開 / 關. Keyboard (Full Keyboard
/// Access): Space flips it; ⏎ is left to the window (a dialog's default action).
public final class SwitchToggle: NSControl, KeyboardFocusTracking {
    public var isOn = false { didSet { if isOn != oldValue { needsDisplay = true; updateAccessibilityValue() } } }

    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in self?.updateGlow() }
        return tracker
    }()

    public init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityLabel(label)
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: UIZoom.pt(30), height: UIZoom.pt(16)) }
    public override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.4; needsDisplay = true; updateGlow() } }

    private func updateAccessibilityValue() {
        setAccessibilityValue(isOn ? 1 : 0)
        setAccessibilityValueDescription(isOn ? "開" : "關")
    }

    public override func draw(_ dirtyRect: NSRect) {
        let z = UIZoom.pt
        Draw.fill(bounds, isOn ? Palette.amber.withAlphaComponent(0.12) : Palette.bg)
        Draw.strokeRect(bounds, color: isOn ? Palette.amberDim : Palette.lineBright)
        let side = z(10)
        let knob = CGRect(x: isOn ? z(16) : z(2), y: z(2), width: side, height: side)
            .offsetBy(dx: 0, dy: (bounds.height - z(14)) / 2 - 1)
        Draw.fill(knob, isOn ? Palette.amber : Palette.dimmer)
        if focusTracker.showsFocusRing, isEnabled { KeyboardFocus.drawRing(in: bounds) }
    }

    /// Flips the switch and sends the action (a click, Space or VoiceOver).
    private func toggle() {
        isOn.toggle()
        sendAction(action, to: target)
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
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
        if KeyboardFocus.key(of: event) == .space, isEnabled {
            focusTracker.noteKeyboardInteraction()
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    private func updateGlow() {
        shadow = focusTracker.showsFocusRing && isEnabled ? KeyboardFocus.ringGlow : nil
    }
}

/// Multi-line `.input` (environment variables): a text view in a `FieldBoxView`, mono 12.
public final class TextAreaField: FieldBoxView, NSTextViewDelegate {
    public let scroll = NSScrollView()
    public let textView = NSTextView()
    public var onChange: ((String) -> Void)?

    public var text: String {
        get { textView.string }
        set { if textView.string != newValue { textView.string = newValue } }
    }

    public init(accessibilityLabel: String) {
        super.init(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = Typeface.mono(12)
        textView.textColor = Palette.cream
        textView.insertionPointColor = Palette.amber
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 5, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [.backgroundColor: Palette.amber, .foregroundColor: NSColor.black]
        textView.delegate = self
        textView.setAccessibilityLabel(accessibilityLabel)
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        addSubview(scroll)
        scroll.pinEdges(to: self, insets: NSEdgeInsets(top: 2, left: 3, bottom: 2, right: 3))
    }

    public func textDidChange(_ notification: Notification) { onChange?(textView.string) }
    public func textDidBeginEditing(_ notification: Notification) { isFocused = true }
    public func textDidEndEditing(_ notification: Notification) { isFocused = false }
}

/// 8 px color tag square (dashed outline for none).
public final class ColorSquareView: NSView {
    public var color: NSColor? { didSet { needsDisplay = true } }

    public init(color: NSColor?) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 8).isActive = true
        heightAnchor.constraint(equalToConstant: 8).isActive = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func draw(_ dirtyRect: NSRect) {
        if let color { Draw.fill(bounds, color) } else { Draw.dashedRect(bounds, color: Palette.dimmer) }
    }
}
