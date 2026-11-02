import AppKit
import CoddUI

/// One account as a full-width, radio-like button: click switches directly (R3).
/// `.sidebar` = `.acrow` (footer list), `.menuBar` = `.mb-ac` (menu bar panel, R4).
/// The active account keeps its R7 place and is marked by the amber left bar + `✓ ACTIVE`.
/// While a switch runs (D5) the other rows say `切換中…` and ignore clicks; with auto-switch ON
/// the 5h / 1w bars carry the R8 threshold tick. On a plan without 5h (Ultra) the 5h place shows
/// the per-model weekly window (`Fable`), or the 1w row takes the whole width; the 5h place's key
/// column is the list's widest, so the bars line up from row to row. Full Keyboard Access reaches
/// every row (M5 D21): space / ⏎ switch like a click, ↑ ↓ step through the list.
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
    /// The 5h place: 5h, a per-model weekly window, or nil (1w alone).
    private var first: QuotaSlot? = QuotaSlot(key: "5h", quota: .unknown, isFiveHour: true)
    /// The 5h place's key column, shared by every row of the list (`Fable` in one widens all)
    /// where it leaves the bars room.
    private(set) var firstKeyWidth: CGFloat?
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
        first = account.fiveHourSlot
        firstKeyWidth = QuotaRowRenderer.keyWidth(store.accounts.compactMap { $0.fiveHourSlot?.key }, compact: true)
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
        var label = (isActive ? "目前帳號 " : "切換到 ") + "\(account.displayName)，\(account.spokenQuota)，\(weekCountdown(now))"
        if switching, !isActive { label += "，切換中" }
        setAccessibilityLabel(label)
        setAccessibilityValue(isActive)
        needsDisplay = true
    }

    private func weekCountdown(_ now: Date) -> String {
        week.resetsAt.map { "1w 重置 " + DurationFormat.countdown(to: $0, now: now) } ?? "1w 未知"
    }

    private func texts(now: Date) -> [String] {
        var five = ""
        if let first, first.isFiveHour {
            five = first.quota.started ? (first.quota.resetsAt.map { DurationFormat.countdown(to: $0, now: now) } ?? "") : "未開始"
        } else if let reset = first?.quota.resetsAt, abs(reset.timeIntervalSince(week.resetsAt ?? .distantPast)) > 120 {
            // A per-model window shows its own countdown only when it does not reset with 1w.
            five = DurationFormat.countdown(to: reset, now: now)
        }
        let wk = week.resetsAt.map { DurationFormat.countdown(to: $0, now: now) } ?? ""
        return [five, wk, weekCountdown(now), account?.sourceLine(now: now) ?? ""]
    }

    /// The 5h place and 1w side by side in `rect` (`gap` apart), or 1w across all of it (its bar
    /// starting where the other rows' 5h place bars do).
    private func drawQuotas(in rect: CGRect, gap: CGFloat, fiveTrailing: String?, weekTrailing: String?) {
        for part in quotaParts(in: rect, gap: gap, fiveTrailing: fiveTrailing, weekTrailing: weekTrailing) {
            QuotaRowRenderer.draw(key: part.key, quota: part.quota, trailing: part.trailing, trailingIsKey: part.key == "1w", compact: true,
                                  threshold: part.ticked ? threshold : nil, keyWidth: part.keyWidth, in: part.rect)
        }
    }

    private struct QuotaPart {
        var key: String
        var quota: QuotaWindow
        var trailing: String?
        var ticked: Bool
        var keyWidth: CGFloat?
        var rect: CGRect
    }

    private func quotaParts(in rect: CGRect, gap: CGFloat, fiveTrailing: String?, weekTrailing: String?) -> [QuotaPart] {
        let half = (rect.width - gap) / 2
        let firstRect = CGRect(x: rect.minX, y: rect.minY, width: half, height: rect.height)
        // The list's key column while it leaves the 5h place a bar (every row of a width decides
        // alike); in a narrower row each keeps its own, so a long name does not cost the 5h bars.
        let shared = firstKeyWidth.flatMap { width in
            QuotaRowRenderer.layout(key: "", quota: .unknown, trailing: nil, compact: true, keyWidth: width, in: firstRect).bar == nil
                ? nil : width
        }
        guard let first else {
            return [QuotaPart(key: "1w", quota: week, trailing: weekTrailing, ticked: true, keyWidth: shared, rect: rect)]
        }
        // A per-model window's empty countdown leaves its bar the room.
        let trailing = first.isFiveHour || fiveTrailing?.isEmpty == false ? fiveTrailing : nil
        return [QuotaPart(key: first.key, quota: first.quota, trailing: trailing, ticked: first.isFiveHour, keyWidth: shared,
                          rect: firstRect),
                QuotaPart(key: "1w", quota: week, trailing: weekTrailing, ticked: true, keyWidth: nil,
                          rect: CGRect(x: rect.minX + half + gap, y: rect.minY, width: half, height: rect.height))]
    }

    /// The quota line of each variant and the gap between its halves; the menu bar's rows carry
    /// the countdowns (`texts[0]`, `texts[1]`).
    private func quotaLine(_ texts: [String]) -> (rect: CGRect, gap: CGFloat, five: String?, week: String?) {
        let z = UIZoom.pt
        switch variant {
        case .sidebar: return (CGRect(x: z(8), y: z(23), width: bounds.width - z(6) - z(8), height: z(16)), z(8), nil, nil)
        case .menuBar: return (CGRect(x: z(10), y: z(29), width: bounds.width - z(8) - z(10), height: z(16)), z(12), texts[0], texts[1])
        }
    }

    /// Each quota row's key and layout as drawn now (tests).
    var quotaLayouts: [(key: String, layout: QuotaRowRenderer.Layout)] {
        let line = quotaLine(renderedTexts.count == 4 ? renderedTexts : ["", "", "", ""])
        let parts = quotaParts(in: line.rect, gap: line.gap, fiveTrailing: line.five, weekTrailing: line.week)
        return parts.map { part in
            (part.key, QuotaRowRenderer.layout(key: part.key, quota: part.quota, trailing: part.trailing, compact: true,
                                               keyWidth: part.keyWidth, in: part.rect))
        }
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

    /// The sidebar footer's list scrolls in a short window: a row reached by Tab comes into view.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { scrollToVisible(bounds) }
        return became
    }

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

        let quotas = quotaLine(texts)
        drawQuotas(in: quotas.rect, gap: quotas.gap, fiveTrailing: quotas.five, weekTrailing: quotas.week)

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

        let quotas = quotaLine(texts)
        drawQuotas(in: quotas.rect, gap: quotas.gap, fiveTrailing: quotas.five, weekTrailing: quotas.week)
    }
}
