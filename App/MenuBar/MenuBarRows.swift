import AppKit
import CoddUI

/// Base for clickable, hoverable panel rows that show a ticking duration. Each row is one button
/// for VoiceOver (title, spoken state, duration) and a key-loop stop with Full Keyboard Access
/// (M5 D21): space / ⏎ open the session, ↑ ↓ step through the rows of the same list.
class PanelRowView: KeyFocusView, SecondTicking {
    let sessionID: SessionID
    let clock: DisplayClock
    var onOpen: ((SessionID) -> Void)?
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(sessionID: SessionID, clock: DisplayClock) {
        self.sessionID = sessionID
        self.clock = clock
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; hoverChanged() }
    override func mouseExited(with event: NSEvent) { isHovered = false; hoverChanged() }
    func hoverChanged() { needsDisplay = true }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?(sessionID) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onOpen?(sessionID); return true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { UITicker.shared.addSecond(self) } else { UITicker.shared.removeSecond(self) }
    }

    /// Text that changes over time (redraw only when it does).
    var tickText: String { "" }
    private var lastTickText = ""

    func secondTick(now: Date) {
        let text = tickText
        if text != lastTickText {
            lastTickText = text
            needsDisplay = true
        }
    }
}

/// NEEDS YOU row in the panel (3 lines): lamp · tag · title / `3m · group / project` /
/// `Bash: npm test -- auth.spec.ts`. Permission rows reveal `[前往] [1 允許]` on hover.
final class PanelNeedsRowView: PanelRowView {
    struct Model: Equatable {
        var state: SessionState
        var title: String
        var tag: TagColor?
        var stateSince: Date
        var location: String
        var detailLead: String
        var detail: String
        var pill: String
        var isPermission: Bool
    }

    private(set) var model: Model
    private let lamp = LampView()
    private let goButton = CoddButton("前往", style: .bracket(.normal, small: true))
    private let allowButton = CoddButton("1 允許", style: .bracket(.primary, small: true))
    var onAllow: ((SessionID) -> Void)?

    init(sessionID: SessionID, clock: DisplayClock, model: Model) {
        self.model = model
        super.init(sessionID: sessionID, clock: clock)
        lamp.configure(StateStyle.of(model.state))
        addSubview(lamp)
        for button in [goButton, allowButton] {
            button.isHidden = true
            button.target = self
            addSubview(button)
        }
        goButton.action = #selector(go)
        allowButton.action = #selector(allow)
        goButton.setAccessibilityLabel("前往 \(model.title)")
        allowButton.setAccessibilityLabel("允許 \(model.title)（回答 1）")
    }

    /// New content for the same session (the panel keeps the view, so hover survives).
    func update(_ newModel: Model) {
        guard newModel != model else { return }
        model = newModel
        lamp.configure(StateStyle.of(model.state))
        goButton.setAccessibilityLabel("前往 \(model.title)")
        allowButton.setAccessibilityLabel("允許 \(model.title)（回答 1）")
        hoverChanged()
    }

    /// `修正登入 API 401，等待中 · 3 分鐘，個人 · Github / backend，Bash: npm test -- auth.spec.ts` (M5 D21).
    static func spokenLabel(_ model: Model, now: Date) -> String {
        let state = [StateStyle.spokenName(model.state), SpokenDuration.text(now.timeIntervalSince(model.stateSince))].joined(separator: " · ")
        return [model.title, state, model.location, model.detailLead + model.detail].filter { !$0.isEmpty }.joined(separator: "，")
    }

    override func accessibilityLabel() -> String? { Self.spokenLabel(model, now: clock.now()) }

    // Lengths are design points at the interface zoom (the three lines grow with their text).
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(54)) }
    override var tickText: String { DurationFormat.compact(clock.now().timeIntervalSince(model.stateSince)) }

    override func layout() {
        super.layout()
        let z = UIZoom.pt
        lamp.frame = CGRect(x: z(10), y: z(5), width: z(12), height: z(16))
        let allowSize = allowButton.intrinsicContentSize
        let goSize = goButton.intrinsicContentSize
        allowButton.frame = CGRect(x: bounds.width - z(8) - allowSize.width, y: z(5), width: allowSize.width, height: allowSize.height)
        goButton.frame = CGRect(x: allowButton.frame.minX - z(4) - goSize.width, y: z(5), width: goSize.width, height: goSize.height)
    }

    override func hoverChanged() {
        super.hoverChanged()
        goButton.isHidden = !(isHovered && model.isPermission)
        allowButton.isHidden = !(isHovered && model.isPermission)
    }

    @objc private func go() { onOpen?(sessionID) }
    @objc private func allow() { onAllow?(sessionID) }

    override func draw(_ dirtyRect: NSRect) {
        let accent = model.state == .error ? Palette.danger : Palette.amber
        let strong: CGFloat = isHovered ? 0.17 : (model.state == .error ? 0.08 : 0.09)
        Draw.hGradient(bounds, from: accent.withAlphaComponent(strong), to: accent.withAlphaComponent(isHovered ? 0.05 : 0.02))
        Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), accent)
        if isHovered { Draw.strokeRect(bounds, color: accent.withAlphaComponent(0.22)) }

        let style = StateStyle.of(model.state)
        let z = UIZoom.pt
        let textX = z(29)
        var x = textX
        if let tag = model.tag {
            Draw.fill(CGRect(x: x, y: z(9), width: z(8), height: z(8)), tag.color)
            x += z(15)
        }
        var right = bounds.width - z(8)
        if !(isHovered && model.isPermission) {
            let pill = ChipStyle.statePill(style)
            right -= pill.size(for: model.pill).width
            pill.draw(model.pill, x: right, centerY: z(13))
            right -= z(8)
        } else {
            right = goButton.frame.minX - z(8)
        }
        Draw.text(TextStyle.mono(12.5, Palette.cream).string(model.title), x: x, centerY: z(13), maxWidth: right - x)

        let duration = DurationFormat.compact(clock.now().timeIntervalSince(model.stateSince))
        let l2 = NSMutableAttributedString(attributedString: TextStyle.mono(10.5, style.color).string(duration))
        l2.append(TextStyle.mono(10.5, Palette.dimmer).string(" · " + model.location))
        Draw.text(l2, x: textX, centerY: z(29), maxWidth: bounds.width - textX - z(8))

        let l3 = NSMutableAttributedString(attributedString: TextStyle.mono(11, Palette.cream, .semibold).string(model.detailLead))
        l3.append(TextStyle.mono(11, Palette.bone).string(model.detail))
        Draw.text(l3, x: textX, centerY: z(44), maxWidth: bounds.width - textX - z(8))
    }
}

/// Compact single-line row (READY / RUNNING): lamp · tag · title · [#2] · `Bash · 1m12s`.
final class PanelCompactRowView: PanelRowView {
    struct Model: Equatable {
        var state: SessionState
        var title: String
        var tag: TagColor?
        var stateSince: Date
        var startedAt: Date?
        var prefix: String
        var suffix: String
        var accountChip: String?
        var showsPill: Bool
        var tint: TagColor?
    }

    private(set) var model: Model
    private let height: CGFloat

    init(sessionID: SessionID, clock: DisplayClock, model: Model, height: CGFloat = 20) {
        self.model = model
        self.height = height
        super.init(sessionID: sessionID, clock: clock)
    }

    /// New content for the same session (the panel keeps the view, so hover survives).
    func update(_ newModel: Model) {
        guard newModel != model else { return }
        model = newModel
        needsDisplay = true
    }

    /// `CODD Desktop 設計稿，工作中 · Write · 2 分鐘，帳號 #2` (M5 D21).
    static func spokenLabel(_ model: Model, now: Date) -> String {
        var state = [StateStyle.spokenName(model.state)]
        if !model.prefix.isEmpty { state.append(model.prefix) }
        if model.state != .shell { state.append(SpokenDuration.text(now.timeIntervalSince(model.stateSince))) }
        var parts = [model.title, state.joined(separator: " · ")]
        if !model.suffix.isEmpty { parts.append(model.suffix) }
        if let chip = model.accountChip { parts.append("帳號 \(chip)") }
        return parts.joined(separator: "，")
    }

    override func accessibilityLabel() -> String? { Self.spokenLabel(model, now: clock.now()) }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(height)) }

    override var tickText: String { durationText }

    private var durationText: String {
        let now = clock.now()
        var parts: [String] = []
        if !model.prefix.isEmpty { parts.append(model.prefix) }
        if model.state == .shell, let up = model.startedAt {
            parts.append("up " + DurationFormat.compact(now.timeIntervalSince(up)))
        } else if model.state != .shell {
            parts.append(DurationFormat.compact(now.timeIntervalSince(model.stateSince)))
        }
        if !model.suffix.isEmpty { parts.append(model.suffix) }
        return parts.joined(separator: " · ")
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = StateStyle.of(model.state)
        if isHovered {
            if let tint = model.tint {
                Draw.fill(bounds, tint.color.withAlphaComponent(0.13))
                Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), tint.color.withAlphaComponent(0.45))
            } else {
                Draw.fill(bounds, Palette.bgRaise)
                Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), Palette.lineBright)
            }
        }
        if model.showsPill { Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), Palette.cyan) }
        let mid = bounds.midY
        let z = UIZoom.pt
        let left = z(model.showsPill ? 10 : 24)
        Draw.text(TextStyle.mono(11, style.color).string(style.glyph), x: left, centerY: mid)
        var x = left + z(19)
        if let tag = model.tag {
            Draw.fill(CGRect(x: x, y: mid - z(4), width: z(8), height: z(8)), tag.color)
            x += z(15)
        }
        var right = bounds.width - z(8)
        if model.showsPill {
            let pill = ChipStyle.statePill(style)
            right -= pill.size(for: style.pill).width
            pill.draw(style.pill, x: right, centerY: mid)
            right -= z(7)
        }
        let dur = TextStyle.mono(10.5, model.showsPill ? Palette.dim : style.color).string(durationText)
        right -= Draw.width(dur)
        Draw.text(dur, x: right, centerY: mid)
        right -= z(7)
        if let chip = model.accountChip {
            let chipStyle = ChipStyle.smallChip(Palette.cyan, border: Palette.cyan.withAlphaComponent(0.4))
            right -= chipStyle.size(for: chip).width
            chipStyle.draw(chip, x: right, centerY: mid)
            right -= z(7)
        }
        Draw.text(TextStyle.mono(model.showsPill ? 12.5 : 12, model.showsPill ? Palette.cream : Palette.bone).string(model.title),
                  x: x, centerY: mid, maxWidth: right - x)
    }
}

/// Tinted group block for the RUNNING list (R1 `.gblk` + compact header in the group color).
final class PanelGroupBlockView: PanelView {
    init(name: String, color: TagColor?, rows: [NSView]) {
        let tint = color?.color
        super.init(fill: tint?.withAlphaComponent(0.07), edges: [.top, .bottom, .left, .right],
                   edgeColor: tint?.withAlphaComponent(0.17) ?? Palette.lineBright, dashed: tint == nil ? [.top, .bottom] : [])
        let titleColor = tint?.mixed(with: Palette.cream, fraction: 0.62) ?? Palette.dim
        let header = Label.make(name, style: TextStyle.caps(9.5, titleColor, tracking: 0.16))
        let headerRow = hStack([header, spacer()], spacing: 4, edgeInsets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        headerRow.heightAnchor.constraint(equalToConstant: 16).zoomed(16).isActive = true
        let stack = vStack([headerRow] + rows, spacing: 0, alignment: .width, edgeInsets: NSEdgeInsets(top: 1, left: 1, bottom: 3, right: 1))
        addSubview(stack)
        stack.pinEdges(to: self)
    }
}
