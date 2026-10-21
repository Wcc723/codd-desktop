import AppKit
import CoddUI

/// One account as a full-width, radio-like button: click switches directly (R3).
/// `.sidebar` = `.acrow` (footer list), `.menuBar` = `.mb-ac` (menu bar panel, R4).
/// The active account keeps its R7 place and is marked by the amber left bar + `✓ ACTIVE`.
/// While a switch runs (D5) the other rows say `切換中…` and ignore clicks; with auto-switch ON
/// the bars carry the R8 threshold tick. Full Keyboard Access reaches every row (M5 D21): space /
/// ⏎ switch like a click, ↑ ↓ step through the list.
final class AccountRowView: KeyFocusView, SecondTicking {
    enum Variant { case sidebar, menuBar }

    let accountID: AccountID
    private let variant: Variant
    private weak var store: (any AccountStore)?
    private let clock: DisplayClock
    var onSwitch: ((AccountID) -> Void)?

    private var loop: ObservationLoop?
    private var isActive = false
    private var slot = ""
    private var alias = ""
    private var plan: String?
    private var fiveHour = QuotaWindow.unknown
    private var week = QuotaWindow.unknown
    private weak var account: AccountVM?
    /// A switch runs (D5): `切換中…` on every row but the active one, clicks ignored.
    private var switching = false
    /// The switch goes to this row (its attempt counter once cswap retries).
    private var switchAttempt: Int?
    /// R8: the threshold tick while auto-switch is ON.
    private var threshold: Int?
    private var isHovered = false
    private var trackingArea: NSTrackingArea?
    private var renderedTexts: [String] = []

    init(accountID: AccountID, store: any AccountStore, clock: DisplayClock, variant: Variant) {
        self.accountID = accountID
        self.store = store
        self.clock = clock
        self.variant = variant
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.radioButton)
        loop = ObservationLoop { [weak self] in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(variant == .sidebar ? 62 : 52))
    }

    private func refresh() {
        guard let store, let account = store.account(accountID) else { return }
        self.account = account
        isActive = store.activeAccountID == accountID
        slot = account.slot
        alias = account.alias
        plan = account.plan
        fiveHour = account.fiveHour
        week = account.week
        switch store.switchState {
        case .switching(let to, _, let attempt, _):
            switching = true
            switchAttempt = to == accountID ? attempt : nil
        default:
            switching = false
            switchAttempt = nil
        }
        threshold = store.autoSwitch.enabled ? store.autoSwitch.thresholdPercent : nil
        let now = clock.now()
        renderedTexts = texts(now: now)
        var label = (isActive ? "目前帳號 " : "切換到 ") + "\(account.displayName)，5 小時剩 \(fiveHour.valueText)，本週剩 \(week.valueText)，\(weekCountdown(now))"
        if switching, !isActive { label += "，切換中" }
        setAccessibilityLabel(label)
        setAccessibilityValue(isActive)
        needsDisplay = true
    }

    private func weekCountdown(_ now: Date) -> String {
        week.resetsAt.map { "1w 重置 " + DurationFormat.countdown(to: $0, now: now) } ?? "1w 未知"
    }

    private func texts(now: Date) -> [String] {
        let five = fiveHour.started ? (fiveHour.resetsAt.map { DurationFormat.countdown(to: $0, now: now) } ?? "") : "未開始"
        let wk = week.resetsAt.map { DurationFormat.countdown(to: $0, now: now) } ?? ""
        return [five, wk, weekCountdown(now), account?.sourceLine(now: now) ?? ""]
    }

    // MARK: Ticking + hover

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { UITicker.shared.addSecond(self) } else { UITicker.shared.removeSecond(self) }
    }

    func secondTick(now: Date) {
        let fresh = texts(now: now)
        if fresh != renderedTexts { renderedTexts = fresh; needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseUp(with event: NSEvent) {
        guard !isActive, !switching, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onSwitch?(accountID)
    }

    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard !isActive, !switching else { return false }
        onSwitch?(accountID)
        return true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            Draw.fill(bounds, Palette.bgLift)
            Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), Palette.amber)
        } else if isHovered {
            Draw.fill(bounds, variant == .sidebar ? Palette.bgSoft : Palette.bgRaise)
            Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), Palette.lineBright)
        }
        let texts = renderedTexts.count == 4 ? renderedTexts : ["", "", "", ""]
        switch variant {
        case .sidebar: drawSidebar(texts)
        case .menuBar: drawMenuBar(texts)
        }
    }

    private var goText: NSAttributedString {
        if isActive { return TextStyle.caps(10, Palette.amber, tracking: 0.06, .bold).string("✓ Active") }
        if switching {
            let attempt = switchAttempt.map { $0 > 1 ? "（\($0)/3）" : "" } ?? ""
            return TextStyle.mono(10, switchAttempt == nil ? Palette.dimmer : Palette.amber).string("切換中…" + attempt)
        }
        return TextStyle.mono(10, isHovered ? Palette.amber : Palette.dimmer).string("切換 →")
    }

    private func drawSidebar(_ texts: [String]) {
        let z = UIZoom.pt
        let left = z(8)
        let right = bounds.width - z(6)
        let go = goText
        var x = left
        x += Draw.text(TextStyle(font: Typeface.display(11), color: isActive ? Palette.amber : Palette.cyan).string(slot), x: x, centerY: z(13))
            + z(6)
        x += Draw.text(TextStyle.mono(11, Palette.bone).string(alias), x: x, centerY: z(13), maxWidth: max(0, right - Draw.width(go) - z(6) - x))
            + z(6)
        if let plan {
            Draw.text(TextStyle(font: Typeface.mono(10), color: Palette.dim, tracking: 0.04).string(plan), x: x, centerY: z(13),
                      maxWidth: max(0, right - Draw.width(go) - z(6) - x))
        }
        Draw.text(go, x: right - Draw.width(go), centerY: z(13))

        let half = (right - left - z(8)) / 2
        QuotaRowRenderer.draw(key: "5h", quota: fiveHour, trailing: nil, compact: true, threshold: threshold,
                              in: CGRect(x: left, y: z(23), width: half, height: z(16)))
        QuotaRowRenderer.draw(key: "1w", quota: week, trailing: nil, compact: true, threshold: threshold,
                              in: CGRect(x: left + half + z(8), y: z(23), width: half, height: z(16)))

        let line = NSMutableAttributedString(attributedString: TextStyle.mono(10, Palette.bone).string(texts[2]))
        line.append(TextStyle.mono(10, Palette.dim).string(" · " + texts[3]))
        Draw.text(line, x: left, centerY: z(49), maxWidth: right - left)
    }

    private func drawMenuBar(_ texts: [String]) {
        let z = UIZoom.pt
        let left = z(10)
        let right = bounds.width - z(8)
        var x = left
        x += Draw.text(TextStyle(font: Typeface.display(12.5), color: isActive ? Palette.amber : Palette.cream).string(slot), x: x,
                       centerY: z(15)) + z(6)
        x += Draw.text(TextStyle.mono(12, Palette.cream).string(alias), x: x, centerY: z(15)) + z(6)
        if let plan {
            let planChip = ChipStyle(text: TextStyle.mono(10, Palette.bone), border: Palette.lineBright, fill: nil, height: 16, padding: 5)
            x += planChip.draw(plan, x: x, centerY: z(15)) + z(8)
        }
        var r = right
        if isActive || isHovered || switching {
            let go = goText
            r -= Draw.width(go)
            Draw.text(go, x: r, centerY: z(15))
            r -= z(8)
        }
        // The source line truncates (from the left edge of its room) rather than running under the plan chip.
        let src = TextStyle.mono(10.5, Palette.dim).string(texts[3])
        let srcWidth = min(Draw.width(src), max(0, r - x))
        Draw.text(src, x: r - srcWidth, centerY: z(15), maxWidth: srcWidth)

        let half = (right - left - z(12)) / 2
        QuotaRowRenderer.draw(key: "5h", quota: fiveHour, trailing: texts[0], compact: true, threshold: threshold,
                              in: CGRect(x: left, y: z(29), width: half, height: z(16)))
        QuotaRowRenderer.draw(key: "1w", quota: week, trailing: texts[1], trailingIsKey: true, compact: true, threshold: threshold,
                              in: CGRect(x: left + half + z(12), y: z(29), width: half, height: z(16)))
    }
}
