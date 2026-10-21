import AppKit
import CoddUI

/// Sidebar footer: host one-liner + usage. Collapsed = active account 5h/1w + reset line;
/// expanded (R2) = every account in R7 order as direct-switch rows (R3, UNDO toast). Without
/// cswap's accounts the toggle line carries the availability copy (D1 / D3) instead.
final class SidebarFooterView: PanelView, SecondTicking {
    private let store: any SessionStore
    private let accounts: any AccountStore
    private let shell: ShellState
    /// The D5 toast after a switch (text, UNDO or nil); the sidebar shows it over the list.
    var onToast: ((String, (@MainActor () -> Void)?) -> Void)?
    var onOpenAutoSwitchSettings: (() -> Void)?

    private let hostValue = Label.make(style: TextStyle.mono(11, Palette.dim))
    private let toggle = FooterToggleView()
    private let fiveRow = QuotaRowView()
    private let weekRow = QuotaRowView()
    private let resetLeft = Label.make(style: TextStyle.mono(10, Palette.dimmer))
    private let resetRight = Label.make(style: TextStyle.mono(10, Palette.dimmer))
    private lazy var resetLine = hStack([resetLeft, spacer(), resetRight], spacing: 4)
    private let sortNote = Label.make("↓ 依每週重置排序 · 越快重置越上面", style: TextStyle.mono(10.5, Palette.dimmer))
    private let accountList = vStack([], spacing: 2, alignment: .width)
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

        let hostTitle = Label.make("Host", style: TextStyle.caps(9.5, Palette.dim, tracking: 0.18))
        let hostRow = hStack([hostTitle, spacer(), hostValue], spacing: 6)
        let stack = vStack([hostRow, toggle, fiveRow, weekRow, resetLine, sortNote, accountList, autoSwitchLine, hint],
                           spacing: 6, alignment: .width, edgeInsets: NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12))
        stack.setCustomSpacing(4, after: sortNote)
        addSubview(stack)
        stack.pinEdges(to: self)
        accountList.setHuggingPriority(.defaultHigh, for: .vertical)
        loop = ObservationLoop { [weak self] in self?.refresh() }
    }

    private func refresh() {
        Label.set(hostValue, store.host.line, style: TextStyle.mono(11, Palette.dim))
        expanded = shell.footerExpanded
        activeID = accounts.activeAccountID
        let ids = accounts.accounts.map(\.id)
        if accountRows.map(\.accountID) != ids { rebuildRows(ids) }
        let active = accounts.activeAccount
        let note = SampleAccountNote.applies(accounts, realMode: realMode) ? SampleAccountNote.text : accounts.availability.note
        toggle.configure(open: expanded, activeName: active?.displayName ?? "—", count: ids.count, note: note)
        fiveRow.quota = active?.fiveHour ?? .unknown
        weekRow.quota = active?.week ?? .unknown
        let threshold = accounts.autoSwitch.enabled ? accounts.autoSwitch.thresholdPercent : nil
        fiveRow.threshold = threshold
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
        for view in [sortNote, accountList, autoSwitchLine, hint] { view.isHidden = !expanded }
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
        guard let active = accounts.activeAccount, active.fiveHour.known else {
            Label.set(resetLeft, "5h 重置 —", style: style)
            Label.set(resetRight, "", style: style)
            return
        }
        if active.fiveHour.started, let reset = active.fiveHour.resetsAt {
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

/// `▸ USAGE 剩餘 · #3 工作 …… 全部帳號 3` (`.sf-toggle`).
/// D29 adds `· 示意資料，M3 接上 cswap` under the label while the account data is a placeholder in
/// real mode (the 280 pt sidebar has no room for it on the same line).
final class FooterToggleView: KeyFocusControl {
    private var open = false
    private var activeName = ""
    private var count = 0
    private(set) var note: String?
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: note == nil ? 20 : 34) }

    func configure(open: Bool, activeName: String, count: Int, note: String? = nil) {
        guard open != self.open || activeName != self.activeName || count != self.count || note != self.note else { return }
        if note != self.note { invalidateIntrinsicContentSize() }
        self.open = open
        self.activeName = activeName
        self.count = count
        self.note = note
        // A long availability line is cut to the sidebar's width; the tooltip has all of it.
        toolTip = note
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
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        let y: CGFloat = 10
        let color = hovered ? Palette.cream : Palette.dim
        if let note {
            Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(note), x: 16, centerY: 26, maxWidth: bounds.width - 16)
        }
        Draw.caret(open: open, at: CGPoint(x: 0, y: y), color: Palette.dimmer)
        var x: CGFloat = 16
        x += Draw.text(TextStyle.caps(9.5, color, tracking: 0.18).string("Usage 剩餘"), x: x, centerY: y) + 6
        Draw.text(TextStyle.mono(10.5, Palette.cyan).string(activeName), x: x, centerY: y)
        let n = TextStyle.mono(10.5, Palette.amberDim).string("\(count)")
        let label = TextStyle.mono(10.5, color).string("全部帳號 ")
        let right = bounds.width - Draw.width(n)
        Draw.text(n, x: right, centerY: y)
        Draw.text(label, x: right - Draw.width(label), centerY: y)
    }
}
