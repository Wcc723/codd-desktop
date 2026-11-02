import AppKit
import CoddUI

/// Sidebar footer: host meters + usage. Collapsed = active account 5h/1w + reset line (on a
/// plan without 5h: its per-model weekly window, or 1w alone, and the 1w reset);
/// expanded (R2) = every account in R7 order as direct-switch rows (R3, UNDO toast). Without
/// cswap's accounts the toggle line carries the availability copy (D1 / D3) instead.
/// The expanded list scrolls inside the room the sidebar leaves it (its full height gives way
/// first, `accountListHeightPriority`), so the host meters and the toggle stay in view however many
/// accounts there are.
final class SidebarFooterView: PanelView, SecondTicking {
    private let store: any SessionStore
    private let accounts: any AccountStore
    private let shell: ShellState
    /// The D5 toast after a switch (text, UNDO or nil); the sidebar shows it over the list.
    var onToast: ((String, (@MainActor () -> Void)?) -> Void)?
    var onOpenAutoSwitchSettings: (() -> Void)?

    private let hostMeters = HostMetersView()
    private let toggle = FooterToggleView()
    private let fiveRow = QuotaRowView()
    private let weekRow = QuotaRowView()
    private let resetLeft = Label.make(style: TextStyle.mono(10, Palette.dimmer))
    private let resetRight = Label.make(style: TextStyle.mono(10, Palette.dimmer))
    private lazy var resetLine = hStack([resetLeft, spacer(), resetRight], spacing: 4)
    private let sortNote = Label.make("↓ 依每週重置排序 · 越快重置越上面", style: TextStyle.mono(10.5, Palette.dimmer))
    private let accountList = vStack([], spacing: 2, alignment: .width)
    private let accountScroll = NSScrollView()
    private let autoSwitchLabel = Label.make(style: TextStyle.mono(10.5, Palette.dim))
    private lazy var autoSwitchLink = CoddButton("開啟 →", style: .link, target: self, action: #selector(openAutoSwitch))
    private lazy var autoSwitchLine: NSView = hStack([autoSwitchLabel, autoSwitchLink, spacer()], spacing: 6)
    private let hint = WrappingLabel("", style: TextStyle.mono(10.5, Palette.dimmer))
    private var accountRows: [AccountRowView] = []
    private var loop: ObservationLoop?
    private var expanded = false
    private var activeID: AccountID?

    /// Real mode: D29's `· 示意資料，M3 接上 cswap` on the toggle line while the accounts are samples.
    private let realMode: Bool

    init(store: any SessionStore, accounts: any AccountStore, shell: ShellState, realMode: Bool = false) {
        self.store = store
        self.accounts = accounts
        self.shell = shell
        self.realMode = realMode
        super.init(fill: Palette.bg, edges: [.top], edgeColor: Palette.line, dashed: [.top])
        fiveRow.key = "5h"
        weekRow.key = "1w"
        toggle.target = self
        toggle.action = #selector(toggleExpanded)

        configureAccountScroll()
        let stack = vStack([hostMeters, toggle, fiveRow, weekRow, resetLine, sortNote, accountScroll, autoSwitchLine, hint],
                           spacing: 6, alignment: .width, edgeInsets: NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12))
        stack.setCustomSpacing(4, after: sortNote)
        stack.setCustomSpacing(8, after: hostMeters)
        addSubview(stack)
        stack.pinEdges(to: self)
        accountList.setHuggingPriority(.defaultHigh, for: .vertical)
        loop = ObservationLoop { [weak self] in self?.refresh() }
    }

    /// The account rows scroll in a clip view as tall as they are, unless the sidebar has less room:
    /// the full height is wanted below the window's own size (500, `windowSizeStayPut`) and below
    /// the session list's minimum (`SidebarViewController.listMinimumPriority`), so a short window
    /// shortens this list instead of growing past the screen or pushing the toggle out of view.
    private func configureAccountScroll() {
        accountScroll.drawsBackground = false
        accountScroll.hasVerticalScroller = true
        accountScroll.hasHorizontalScroller = false
        accountScroll.autohidesScrollers = true
        accountScroll.scrollerStyle = .overlay
        accountScroll.verticalScrollElasticity = .none
        accountList.translatesAutoresizingMaskIntoConstraints = false
        accountScroll.documentView = accountList
        let clip = accountScroll.contentView
        let full = accountScroll.heightAnchor.constraint(equalTo: accountList.heightAnchor)
        full.priority = Self.accountListHeightPriority
        NSLayoutConstraint.activate([
            accountList.topAnchor.constraint(equalTo: clip.topAnchor),
            accountList.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            accountList.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            accountScroll.heightAnchor.constraint(lessThanOrEqualTo: accountList.heightAnchor),
            full,
        ])
    }

    /// Below `SidebarViewController.listMinimumPriority`: the session list keeps its minimum first.
    static let accountListHeightPriority = NSLayoutConstraint.Priority(470)

    /// The expanded list's scroll view (tests).
    var accountListScrollView: NSScrollView { accountScroll }

    private func refresh() {
        let host = store.host
        hostMeters.meters = host.meters
        hostMeters.fallback = host.line
        expanded = shell.footerExpanded
        activeID = accounts.activeAccountID
        let ids = accounts.accounts.map(\.id)
        if accountRows.map(\.accountID) != ids { rebuildRows(ids) }
        let active = accounts.activeAccount
        let note = SampleAccountNote.applies(accounts, realMode: realMode) ? SampleAccountNote.text : accounts.availability.note
        toggle.configure(open: expanded, activeName: active?.displayName ?? "—", count: ids.count, note: note)
        // A plan without 5h (Ultra): its per-model weekly window (`Fable`) in the 5h row, else 1w alone.
        let first: QuotaSlot? = active.map(\.fiveHourSlot) ?? QuotaSlot(key: "5h", quota: .unknown, isFiveHour: true)
        fiveRow.key = first?.key ?? "5h"
        fiveRow.quota = first?.quota ?? .unknown
        weekRow.quota = active?.week ?? .unknown
        // One key column for the two rows, so a `Fable` bar starts where the 1w bar does.
        let keyWidth = QuotaRowRenderer.keyWidth([fiveRow.key, weekRow.key], compact: false)
        fiveRow.keyWidth = keyWidth
        weekRow.keyWidth = keyWidth
        let threshold = accounts.autoSwitch.enabled ? accounts.autoSwitch.thresholdPercent : nil
        fiveRow.threshold = first?.isFiveHour == true ? threshold : nil
        weekRow.threshold = threshold
        // R8: one-line auto-switch status; the rule itself lives in Settings › 帳號.
        let autoOn = accounts.autoSwitch.enabled
        Label.set(autoSwitchLabel, "自動切換  \(autoOn ? "ON" : "OFF")  ·", style: TextStyle.mono(10.5, Palette.dim))
        autoSwitchLink.label = autoOn ? "設定 →" : "開啟 →"
        autoSwitchLink.setAccessibilityLabel(autoOn ? "自動切換設定" : "開啟自動切換")
        // R2: 「點一下直接切換 · 12 個跟隨全域登入的 session 約 30 秒內套用」.
        let hintText = "點一下直接切換 · \(accounts.followingSessionCount) 個跟隨全域登入的 session 約 30 秒內套用"
        if hint.stringValue != hintText {
            hint.attributedStringValue = TextStyle.mono(10.5, Palette.dimmer).string(hintText, lineBreak: .byWordWrapping)
        }
        for view in [fiveRow, weekRow, resetLine] { view.isHidden = expanded }
        if first == nil { fiveRow.isHidden = true }
        for view in [sortNote, accountScroll, autoSwitchLine, hint] { view.isHidden = !expanded }
        updateResetLine(now: store.clock.now())
    }

    private func rebuildRows(_ ids: [AccountID]) {
        accountRows.forEach { $0.removeFromSuperview() }
        accountRows = ids.map { id in
            let row = AccountRowView(accountID: id, store: accounts, clock: store.clock, variant: .sidebar)
            row.onSwitch = { [weak self] id in self?.switchTo(id) }
            accountList.addArrangedSubview(row)
            return row
        }
    }

    /// A row click (also DEBUG `-codd-switch-account`): the D5 switch, then its toast.
    @discardableResult
    func switchTo(_ id: AccountID) -> Task<AccountSwitchOutcome, Never> {
        AccountSwitching.run(id, in: accounts) { [weak self] text, undo in self?.onToast?(text, undo) }
    }

    private func updateResetLine(now: Date) {
        let style = TextStyle.mono(10, Palette.dimmer)
        if let active = accounts.activeAccount, active.fiveHour == nil {
            // No 5h window on this plan: the weekly reset instead.
            let reset = active.week.resetsAt
            Label.set(resetLeft, "1w 重置 " + (reset.map { ClockFormat.resetLabel($0, now: now) } ?? "—"), style: style)
            Label.set(resetRight, reset.map { DurationFormat.countdown(to: $0, now: now) } ?? "", style: style)
            return
        }
        guard let active = accounts.activeAccount, let fiveHour = active.fiveHour, fiveHour.known else {
            Label.set(resetLeft, "5h 重置 —", style: style)
            Label.set(resetRight, "", style: style)
            return
        }
        if fiveHour.started, let reset = fiveHour.resetsAt {
            Label.set(resetLeft, "5h 重置 \(ClockFormat.hourMinute(reset))", style: style)
            Label.set(resetRight, DurationFormat.countdown(to: reset, now: now), style: style)
        } else {
            Label.set(resetLeft, "5h 未開始", style: style)
            Label.set(resetRight, "第一則訊息後起算", style: style)
        }
    }

    func secondTick(now: Date) { if !expanded { updateResetLine(now: now) } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { UITicker.shared.addSecond(self) } else { UITicker.shared.removeSecond(self) }
    }

    @objc private func toggleExpanded() { shell.footerExpanded.toggle() }
    @objc private func openAutoSwitch() { onOpenAutoSwitchSettings?() }
}

/// `▸ USAGE 剩餘 #3 工作 …… 全部帳號 3 ⌄` (`.sf-toggle`), drawn as a control (FB 2026-11: with the
/// list open the owner could not find how to close it): a tinted box (bg-raise, line-bright
/// border), an amber border and cream text on hover, the amber press fill while held (CoddButton's
/// hover and highlight). Open, the right end is the explicit `收合 ⌃` and the count moves next to
/// the label (`USAGE 剩餘 全部帳號 3`; the list itself marks the active account). A click acts on
/// mouse up inside, like a button. D29 adds `· 示意資料，M3 接上 cswap` under the label while the
/// account data is a placeholder in real mode (the 280 pt sidebar has no room for it on the same line).
final class FooterToggleView: KeyFocusControl {
    private var open = false
    private var activeName = ""
    private var count = 0
    private(set) var note: String?
    private var hovered = false
    private(set) var pressed = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(note == nil ? 24 : 38)) }

    static let collapseText = "收合"
    /// The right end: `收合` while open, `全部帳號 n` while closed (tests).
    var trailingText: String { open ? Self.collapseText : "全部帳號 \(count)" }

    func configure(open: Bool, activeName: String, count: Int, note: String? = nil) {
        guard open != self.open || activeName != self.activeName || count != self.count || note != self.note else { return }
        if note != self.note { invalidateIntrinsicContentSize() }
        self.open = open
        self.activeName = activeName
        self.count = count
        self.note = note
        // A long availability line is cut to the sidebar's width; the tooltip has all of it.
        toolTip = note ?? (open ? "收合帳號清單" : "展開所有帳號的用量")
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityLabel(open ? "收合全部帳號的用量" : "展開全部帳號的用量")
        setAccessibilityExpanded(open)
        setAccessibilityHelp("目前帳號 \(activeName)，共 \(count) 個帳號" + (note.map { "，\($0)" } ?? ""))
        needsDisplay = true
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
    override func mouseDown(with event: NSEvent) { setPressed(true) }
    override func mouseDragged(with event: NSEvent) { setPressed(isInside(event)) }
    override func mouseUp(with event: NSEvent) {
        let click = pressed && isInside(event)
        setPressed(false)
        if click { sendAction(action, to: target) }
    }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }

    private func isInside(_ event: NSEvent) -> Bool { bounds.contains(convert(event.locationInWindow, from: nil)) }

    private func setPressed(_ value: Bool) {
        guard pressed != value else { return }
        pressed = value
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let z = UIZoom.pt
        let hot = hovered || pressed
        Draw.fill(bounds, Palette.bgRaise)
        if pressed {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.16))
        } else if hovered {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06))
        }
        Draw.strokeRect(bounds, color: pressed ? Palette.amber : hovered ? Palette.amberDim : Palette.lineBright)

        let pad = z(8)
        let y = z(12)
        let color = hot ? Palette.cream : Palette.dim
        let left = pad + z(15)
        if let note {
            // dim, not dimmer: the box is bg-raise (dimmer is for the darkest backgrounds only).
            Draw.text(TextStyle.mono(10.5, Palette.dim).string(note), x: left, centerY: z(28), maxWidth: bounds.width - left - pad)
        }
        Draw.caret(open: open, at: CGPoint(x: pad - z(2), y: y), color: hot ? Palette.amber : Palette.dim)

        // The right end first: it never gives way. Open: `收合 ⌃` in the link colors.
        let chevron = z(8)
        var right = bounds.width - pad - chevron
        let label = TextStyle.caps(9.5, color, tracking: 0.18).string("Usage 剩餘")
        let labelEnd = left + Draw.width(label) + z(6)
        let number = TextStyle.mono(10.5, Palette.amberDim).string("\(count)")
        if open {
            let link = hot ? Palette.cream : Palette.amber
            Self.chevron(up: true, center: CGPoint(x: right + chevron / 2, y: y), color: link)
            let collapse = TextStyle.mono(10.5, link).string(Self.collapseText)
            right -= z(4) + Draw.width(collapse)
            Draw.text(collapse, x: right, centerY: y)
            Draw.text(label, x: left, centerY: y, maxWidth: max(0, right - z(8) - left))
            // `全部帳號 3` after the label; only the count where that does not fit before `收合`.
            let all = NSMutableAttributedString(attributedString: TextStyle.mono(10.5, color).string("全部帳號 "))
            all.append(number)
            let room = max(0, right - z(8) - labelEnd)
            Draw.text(Draw.width(all) <= room ? all : number, x: labelEnd, centerY: y, maxWidth: room)
        } else {
            Self.chevron(up: false, center: CGPoint(x: right + chevron / 2, y: y), color: hot ? Palette.amber : Palette.dim)
            right -= z(4) + Draw.width(number)
            Draw.text(number, x: right, centerY: y)
            // `全部帳號` gives way before the active account's name does.
            let all = TextStyle.mono(10.5, color).string("全部帳號 ")
            if right - Draw.width(all) - labelEnd >= z(48) {
                right -= Draw.width(all)
                Draw.text(all, x: right, centerY: y)
            }
            Draw.text(label, x: left, centerY: y, maxWidth: max(0, right - z(8) - left))
            Draw.text(TextStyle.mono(10.5, Palette.cyan).string(activeName), x: labelEnd, centerY: y, maxWidth: max(0, right - z(8) - labelEnd))
        }
    }

    /// `⌃` / `⌄` as two strokes (no glyph): open and close at the right end.
    private static func chevron(up: Bool, center c: CGPoint, color: NSColor) {
        let w = UIZoom.scaled(3.5)
        let h = UIZoom.scaled(2)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.x - w, y: up ? c.y + h : c.y - h))
        path.line(to: CGPoint(x: c.x, y: up ? c.y - h : c.y + h))
        path.line(to: CGPoint(x: c.x + w, y: up ? c.y + h : c.y - h))
        path.lineWidth = UIZoom.scaled(1.4)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }
}
