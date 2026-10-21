import AppKit

/// Custom-drawn square button (native bordered buttons turn into capsules on Tahoe).
/// Covers `.btn` `[ LABEL ]`, `.icon-btn`, `.keybtn`, `.pillbtn`, `.tab`, links and `.addrow`.
///
/// Keyboard (M5 D21): focusable while Full Keyboard Access is on; Space and ⏎ press it; keyboard
/// focus draws the helmet focus style over the button (``KeyboardFocus``).
public final class CoddButton: NSButton, KeyboardFocusTracking {
    public enum Variant { case normal, primary, danger, accent }

    public enum Style {
        /// `[ LABEL ]`; `small` = `.btn.sm`.
        case bracket(Variant, small: Bool)
        /// 28×28 square with a stroke icon.
        case icon(Icon, size: CGFloat = 28)
        /// 28×28 square with a text glyph (`⋯`, `A−`, `✕`).
        case glyph(size: CGFloat = 28)
        /// Answer-bar key: amber key cap + label (`[1] Yes`).
        case key(cap: String, danger: Bool)
        /// `.pillbtn` with an optional amber count.
        case pill(count: String?)
        /// The bottom panel's `✕ ⌘J` (`.pillbtn.sp-close`: 22 px, 10.5 px dim caps).
        case smallPill
        /// Tab strip button with a state lamp glyph.
        case tab(lamp: String, lampColor: NSColor)
        /// Amber text link (`開啟 →`).
        case link
        /// Dashed full-width row (`+ 新增群組`).
        case addRow
        /// `.btn.sm.plain` without brackets: amber text, a border only while hovered
        /// (`清理已停止 (5)` on a group header, SidebarStates C `.ss-clean`).
        case plain
    }

    public var style: Style { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    public var label: String { didSet { if label != oldValue { title = label; invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// Bracket buttons: a dim shortcut after the label (`[前往 ⌘1]`, `[其他專案… ⌘N]`; `.btn .k`).
    public var trailing: String? { didSet { if trailing != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } } }
    /// `.on` state (icon button, pill, tab).
    public var isOn = false { didSet { if isOn != oldValue { needsDisplay = true } } }

    /// What a tab button draws after its label (Split artboard `.tab … <span class="lamp">`).
    public enum TabMark: Equatable, Sendable {
        /// D25: a foreground job runs in the shell (green `●`, `.lamp.st-busy`).
        case running
        /// D12: the PTY rang its bell while it was not on screen (amber `◆`).
        case bell
    }

    /// Tab buttons only: marks after the label, in order.
    public var tabMarks: [TabMark] = [] {
        didSet { if tabMarks != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    public private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    public private(set) lazy var focusTracker: KeyboardFocusTracker = {
        let tracker = KeyboardFocusTracker(view: self)
        tracker.onChange = { [weak self] in self?.updateGlow() }
        return tracker
    }()

    public init(_ label: String, style: Style, target: AnyObject? = nil, action: Selector? = nil) {
        self.style = style
        self.label = label
        super.init(frame: .zero)
        title = label
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        focusRingType = .none
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override var isHighlighted: Bool { didSet { needsDisplay = true } }
    public override var isEnabled: Bool { didSet { needsDisplay = true; updateGlow() } }

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

    /// Space and ⏎ press the button (other keys go up the responder chain: digits, esc, arrows).
    public override func keyDown(with event: NSEvent) {
        switch KeyboardFocus.key(of: event) {
        case .space?, .return?:
            guard isEnabled else { break }
            focusTracker.noteKeyboardInteraction()
            performClick(nil)
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    /// VoiceOver's press: NSButton's own implementation clicks a custom-drawn button but reports
    /// failure, so VoiceOver would announce an error after the action ran.
    public override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    /// NSButton may press on Space's key-up; ``keyDown(with:)`` pressed already.
    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 0x31 || event.charactersIgnoringModifiers == " " { return }
        super.keyUp(with: event)
    }

    // MARK: Hover

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) { setHovered(true) }
    public override func mouseExited(with event: NSEvent) { setHovered(false) }

    private func setHovered(_ value: Bool) {
        guard isHovered != value else { return }
        isHovered = value
        needsDisplay = true
        updateGlow()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isHovered { isHovered = false; updateGlow() }
        focusTracker.viewDidMoveToWindow()
    }

    /// Amber glow on hover (`box-shadow: 0 0 16px var(--amber-glow)`): a layer shadow, so the
    /// render server blurs it; no per-frame work. Keyboard focus shows the focus glow instead.
    private func updateGlow() {
        if focusTracker.showsFocusRing, isEnabled {
            shadow = KeyboardFocus.ringGlow
            return
        }
        let glow: Bool
        switch style {
        case .bracket(let v, _): glow = isHovered && isEnabled && (v == .normal || v == .accent)
        case .key, .plain: glow = isHovered && isEnabled
        default: glow = false
        }
        if glow {
            let shadow = NSShadow()
            shadow.shadowColor = Palette.amber.withAlphaComponent(0.4)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = .zero
            self.shadow = shadow
        } else if shadow != nil {
            shadow = nil
        }
    }

    // MARK: Size

    /// Sizes are design points at the current zoom (``UIZoom/pt(_:)``), measured from the text.
    public override var intrinsicContentSize: NSSize {
        let z = UIZoom.pt
        switch style {
        case .bracket(_, let small):
            var text = Draw.width(bracketText(small: small).string(label))
            if let trailing { text += z(4) + Draw.width(trailingText(small: small).string(trailing)) }
            let bracket = Draw.width(bracketText(small: small).string("["))
            return NSSize(width: ceil(text + bracket * 2 + z(small ? 7 : 10) * 2 + z(small ? 8 : 12)), height: z(small ? 22 : 28))
        case .icon(_, let size), .glyph(let size):
            return NSSize(width: z(size), height: z(size))
        case .key(let cap, _):
            let capWidth = Draw.width(keyCapText.string(cap)) + z(8)
            return NSSize(width: ceil(capWidth + z(6) + Draw.width(keyLabelText.string(label)) + z(20)), height: z(28))
        case .pill(let count):
            var width = Draw.width(pillText.string(label)) + z(16)
            if let count { width += z(6) + Draw.width(TextStyle.mono(11, Palette.amber).string(count)) }
            return NSSize(width: ceil(width), height: z(24))
        case .tab(let lamp, _):
            let lampWidth = lamp.isEmpty ? 0 : Draw.width(TextStyle.mono(11, Palette.dim).string(lamp)) + z(7)
            let marks = CGFloat(tabMarks.count) * (z(7) + z(Self.markWidth))
            return NSSize(width: ceil(z(14) + lampWidth + Draw.width(tabText.string(label + "_")) + marks + z(14)),
                          height: Metrics.tabStripHeight)
        case .smallPill:
            return NSSize(width: ceil(Draw.width(smallPillText.string(label)) + z(14)), height: z(22))
        case .link:
            return NSSize(width: Draw.width(linkText.string(label)), height: z(16))
        case .addRow:
            return NSSize(width: NSView.noIntrinsicMetric, height: z(28))
        case .plain:
            return NSSize(width: ceil(Draw.width(plainText.string(label)) + z(12)), height: z(22))
        }
    }

    // MARK: Text styles

    fileprivate func bracketText(small: Bool) -> TextStyle {
        TextStyle(font: Typeface.mono(small ? 10.5 : 11.5, .medium), color: Palette.cream, tracking: 0.08, uppercase: true)
    }
    /// `.btn .k`: the shortcut keeps its case and spacing, in --dim.
    fileprivate func trailingText(small: Bool) -> TextStyle { TextStyle.mono(small ? 10.5 : 11.5, Palette.dim) }
    fileprivate var keyCapText: TextStyle { TextStyle.mono(10.5, .black, .bold) }
    fileprivate var keyLabelText: TextStyle { TextStyle(font: Typeface.mono(11.5), color: Palette.cream, tracking: 0.04) }
    fileprivate var pillText: TextStyle { TextStyle.caps(11, Palette.bone, tracking: 0.08) }
    fileprivate var smallPillText: TextStyle { TextStyle.caps(10.5, Palette.dim, tracking: 0.08) }
    fileprivate var tabText: TextStyle { TextStyle.caps(10.5, Palette.dim, tracking: 0.12) }
    fileprivate var linkText: TextStyle { TextStyle.mono(10.5, Palette.amber) }
    fileprivate var plainText: TextStyle {
        TextStyle(font: Typeface.mono(10.5, .medium), color: Palette.amber, tracking: 0.04, uppercase: true)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        NSGraphicsContext.current?.cgContext.setAlpha(alpha)
        let hot = isHovered && isEnabled
        switch style {
        case .bracket(let variant, let small): drawBracket(variant: variant, small: small, hot: hot)
        case .icon(let icon, let size): drawIconButton(hot: hot) { color in
            // `.icon-btn svg` 16 px; the 24 px `.sp-ib` variant draws 14 px.
            let s: CGFloat = UIZoom.pt(size <= 24 ? 14 : 16)
            IconRenderer.draw(icon, in: CGRect(x: (bounds.width - s) / 2, y: (bounds.height - s) / 2, width: s, height: s),
                              color: color, flipped: true)
        }
        case .glyph(let size): drawIconButton(hot: hot) { color in
            // `.icon-btn` 14 px; the 22 px `.ss-gib` variant uses 13 px.
            let text = TextStyle.mono(label.count > 1 ? 11 : (size <= 22 ? 13 : 14), color).string(label)
            Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
        }
        case .key(let cap, let danger): drawKey(cap: cap, danger: danger, hot: hot)
        case .pill(let count): drawPill(count: count, hot: hot)
        case .smallPill:
            Draw.strokeRect(bounds, color: hot ? Palette.amberDim : Palette.lineBright)
            if isHighlighted { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.1)) }
            let text = smallPillText.with(color: hot ? Palette.amber : Palette.dim).string(label)
            Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
        case .tab(let lamp, let lampColor): drawTab(lamp: lamp, lampColor: lampColor, hot: hot)
        case .link:
            Draw.text(linkText.with(color: hot ? Palette.cream : Palette.amber).string(label), x: 0, centerY: bounds.midY)
        case .addRow:
            let color = hot ? Palette.amber : Palette.dim
            Draw.dashedRect(bounds, color: hot ? Palette.amberDim : Palette.lineBright)
            Draw.text(TextStyle.caps(11, color, tracking: 0.1).string(label), x: UIZoom.pt(8), centerY: bounds.midY)
        case .plain:
            if hot { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06)); Draw.strokeRect(bounds, color: Palette.amber) }
            if isHighlighted { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.12)) }
            Draw.text(plainText.string(label), x: UIZoom.pt(6), centerY: bounds.midY)
        }
        if focusTracker.showsFocusRing, isEnabled { KeyboardFocus.drawRing(in: bounds) }
    }

    private func drawBracket(variant: Variant, small: Bool, hot: Bool) {
        var border = Palette.lineBright
        var text = Palette.cream
        var brackets = Palette.dim
        var fill: NSColor?
        switch variant {
        case .normal:
            if hot { border = Palette.amber; text = Palette.amber; brackets = Palette.amber; fill = Palette.amber.withAlphaComponent(0.06) }
        case .primary:
            fill = hot ? Palette.cream : Palette.amber
            border = fill ?? Palette.amber
            text = .black
            brackets = .black
        case .danger:
            border = Palette.danger
            text = hot ? .black : Palette.danger
            brackets = text
            if hot { fill = Palette.danger }
        case .accent:
            border = hot ? Palette.amber : Palette.amberDim
            text = Palette.amber
            brackets = hot ? Palette.amber : Palette.amberDim
            if hot { fill = Palette.amber.withAlphaComponent(0.06) }
        }
        if isHighlighted, fill == nil { fill = Palette.amber.withAlphaComponent(0.12) }
        if let fill { Draw.fill(bounds, fill) }
        Draw.strokeRect(bounds, color: border)
        let style = bracketText(small: small)
        let open = style.with(color: brackets).string("[")
        let close = style.with(color: brackets).string("]")
        let body = style.with(color: text).string(label)
        let extra = trailing.map { trailingText(small: small).with(color: variant == .primary ? .black : Palette.dim).string($0) }
        let gap = UIZoom.pt(small ? 4 : 6)
        let space = UIZoom.pt(4)
        let total = Draw.width(open) + gap + Draw.width(body) + (extra.map { space + Draw.width($0) } ?? 0) + gap + Draw.width(close)
        var x = (bounds.width - total) / 2
        x += Draw.text(open, x: x, centerY: bounds.midY) + gap
        x += Draw.text(body, x: x, centerY: bounds.midY)
        if let extra { x += space + Draw.text(extra, x: x + space, centerY: bounds.midY) }
        Draw.text(close, x: x + gap, centerY: bounds.midY)
    }

    private func drawIconButton(hot: Bool, content: (NSColor) -> Void) {
        let color = (hot || isOn) ? Palette.amber : Palette.dim
        if isOn {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.08))
            Draw.strokeRect(bounds, color: Palette.amberDim)
        } else if hot {
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
        if isHighlighted { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.1)) }
        content(color)
    }

    private func drawKey(cap: String, danger: Bool, hot: Bool) {
        Draw.fill(bounds, Palette.bg)
        let accent = danger ? Palette.danger : Palette.amber
        let border = hot ? accent : (danger ? Palette.danger.withAlphaComponent(0.45) : Palette.lineBright)
        if hot || isHighlighted { Draw.fill(bounds, accent.withAlphaComponent(isHighlighted ? 0.16 : 0.07)) }
        Draw.strokeRect(bounds, color: border)
        let z = UIZoom.pt
        let capString = keyCapText.string(cap)
        let capWidth = Draw.width(capString) + z(8)
        let capRect = CGRect(x: z(10), y: (bounds.height - z(15)) / 2, width: capWidth, height: z(15))
        Draw.fill(capRect, accent)
        Draw.text(capString, x: capRect.minX + z(4), centerY: capRect.midY)
        let labelColor = danger ? Palette.danger : (hot ? Palette.amber : Palette.cream)
        Draw.text(keyLabelText.with(color: labelColor).string(label), x: capRect.maxX + z(6), centerY: bounds.midY)
    }

    private func drawPill(count: String?, hot: Bool) {
        let active = hot || isOn
        Draw.strokeRect(bounds, color: active ? Palette.amberDim : Palette.lineBright)
        var x = UIZoom.pt(8)
        x += Draw.text(pillText.with(color: active ? Palette.amber : Palette.bone).string(label), x: x, centerY: bounds.midY)
        if let count {
            Draw.text(TextStyle.mono(11, Palette.amber).string(count), x: x + UIZoom.pt(6), centerY: bounds.midY)
        }
    }

    private func drawTab(lamp: String, lampColor: NSColor, hot: Bool) {
        if isOn {
            Draw.fill(bounds, Palette.bg)
            Draw.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 2), Palette.amber)
        }
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        let z = UIZoom.pt
        var x = z(14)
        if !lamp.isEmpty {
            x += Draw.text(TextStyle.mono(11, lampColor).string(lamp), x: x, centerY: bounds.midY) + z(7)
        }
        let color = isOn ? Palette.amber : (hot ? Palette.cream : Palette.dim)
        // Static `_` cursor on the active tab (no blink: lamps are the only animation).
        x += Draw.text(tabText.with(color: color).string(isOn ? label + "_" : label), x: x, centerY: bounds.midY)
        let markWidth = z(Self.markWidth)
        for mark in tabMarks {
            x += z(7)
            let glyph: NSAttributedString
            switch mark {
            case .running:
                // `.lamp.st-busy`: success green with `text-shadow: 0 0 6px rgba(124,255,154,.55)`.
                let glow = NSShadow()
                glow.shadowColor = Palette.success.withAlphaComponent(0.55)
                glow.shadowBlurRadius = 6
                glow.shadowOffset = .zero
                let attributed = NSMutableAttributedString(attributedString: TextStyle.mono(11, Palette.success).string("●"))
                attributed.addAttribute(.shadow, value: glow, range: NSRange(location: 0, length: attributed.length))
                glyph = attributed
            case .bell:
                glyph = TextStyle.mono(11, Palette.amber).string("◆")
            }
            Draw.text(glyph, x: x + (markWidth - Draw.width(glyph)) / 2, centerY: bounds.midY)
            x += markWidth
        }
    }

    /// `.lamp{width:12px}` (design points).
    public static let markWidth: CGFloat = 12

    /// A `.btn.sm` (`[+ 加入]`) drawn into `rect` by a custom-drawn list that handles its own clicks.
    public static func drawSmallBracket(_ label: String, in rect: CGRect) {
        let style = TextStyle(font: Typeface.mono(10.5, .medium), color: Palette.cream, tracking: 0.08, uppercase: true)
        Draw.strokeRect(rect, color: Palette.lineBright)
        let open = style.with(color: Palette.dim).string("[")
        let close = style.with(color: Palette.dim).string("]")
        let body = style.string(label)
        let gap = UIZoom.pt(4)
        let total = Draw.width(open) + gap + Draw.width(body) + gap + Draw.width(close)
        var x = rect.minX + (rect.width - total) / 2
        x += Draw.text(open, x: x, centerY: rect.midY) + gap
        x += Draw.text(body, x: x, centerY: rect.midY) + gap
        Draw.text(close, x: x, centerY: rect.midY)
    }
}
