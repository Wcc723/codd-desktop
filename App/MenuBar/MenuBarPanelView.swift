import AppKit
import CoddUI

/// Actions the panel asks the app to perform.
@MainActor
struct MenuBarPanelActions {
    var openSession: (SessionID) -> Void
    var allow: (SessionID) -> Void
    var openMain: () -> Void
    var openSettings: (String?) -> Void
    var newSession: () -> Void
    var quickNote: () -> Void
    /// M4 D31: the footer's `清理建議 n →` (the Cleanup page; M3 opened Settings › 清理).
    var openCleanup: (() -> Void)? = nil
}

/// Menu bar dropdown content (MenuBar artboard, R4 order): header · ACCOUNTS (direct switch,
/// R7 order, `自動切換 OFF · 開啟 →`) · NEEDS YOU · READY · RUNNING (tinted group blocks) · footer.
/// It observes the stores only while the panel is open (see `MenuBarPanelContent` for how
/// changes are applied).
final class MenuBarPanelView: FlippedView {
    private let store: any SessionStore
    private let accounts: any AccountStore
    private let actions: MenuBarPanelActions
    /// `ShellState.menuBarAccountsExpanded` (D23 `▸ 全部帳號 n`).
    private let shell: ShellState
    var onLayoutChange: (() -> Void)?

    private let body = vStack([], spacing: 3, alignment: .width, edgeInsets: NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6))
    private let liveChip = ChipView("", style: ChipStyle(text: TextStyle.mono(10.5, Palette.bone), border: Palette.lineBright, fill: nil,
                                                         height: 18, padding: 6))
    private let hostLine = Label.make(style: TextStyle.mono(11, Palette.dim))
    private let cleanupLink = CoddButton("清理建議 →", style: .link)
    private let autoSwitchLabel = Label.make(style: TextStyle.mono(10.5, Palette.dim))
    private lazy var autoSwitchLink = CoddButton("開啟 →", style: .link, target: self, action: #selector(openAccounts))
    private var loop: ObservationLoop?
    /// What the body currently shows, and its row views by session (for in-place updates).
    private var shown: MenuBarPanelContent?
    private var needsRows: [SessionID: PanelNeedsRowView] = [:]
    private var compactRows: [SessionID: PanelCompactRowView] = [:]
    private var moreLabel: NSTextField?

    init(store: any SessionStore, accounts: any AccountStore, actions: MenuBarPanelActions, shell: ShellState = ShellState()) {
        self.store = store
        self.accounts = accounts
        self.actions = actions
        self.shell = shell
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let root = vStack([makeHeader(), body, makeFooter()], spacing: 0, alignment: .width)
        addSubview(root)
        root.pinEdges(to: self)
        widthAnchor.constraint(equalToConstant: 380).zoomed(380).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Starts observing (panel opened). The tracked read only computes values; views are
    /// built outside tracking, so the account rows' own loops never widen what the panel
    /// observes.
    func activate() {
        guard loop == nil else { return }
        loop = ObservationLoop(track: { [weak self] () -> MenuBarPanelContent? in
            guard let self else { return nil }
            return MenuBarPanelContent.build(store: self.store, accounts: self.accounts, expanded: self.shell.menuBarAccountsExpanded)
        }, apply: { [weak self] content in
            if let content { self?.apply(content) }
        })
    }

    /// Stops observing (panel closed). The next `activate()` rebuilds from scratch.
    func deactivate() {
        loop?.cancel()
        loop = nil
        shown = nil
    }

    /// Row view currently showing a NEEDS YOU session (tests).
    func needsRowView(_ id: SessionID) -> PanelNeedsRowView? { needsRows[id] }
    /// Row view currently showing a READY / RUNNING session (tests).
    func compactRowView(_ id: SessionID) -> PanelCompactRowView? { compactRows[id] }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.amberDim)
    }

    // MARK: Header / footer

    private func makeHeader() -> NSView {
        let mark = BrandMarkView()
        let brand = Label.make("CODD", style: TextStyle(font: Typeface.display(15), color: Palette.amber, tracking: 0.04,
                                                             shadow: SidebarHeaderView.glow(radius: 8)))
        let new = CoddButton("新增 session ⌘N", style: .icon(.plus), target: self, action: #selector(newSession))
        let window = CoddButton("開啟主視窗", style: .icon(.window), target: self, action: #selector(openMain))
        let settings = CoddButton("設定 ⌘,", style: .icon(.settings), target: self, action: #selector(openSettings))
        for b in [new, window, settings] { b.setAccessibilityLabel(b.label) }
        let row = hStack([mark, brand, liveChip, spacer(), new, window, settings], spacing: 8,
                         edgeInsets: NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 6))
        let header = PanelView(edges: [.bottom], edgeColor: Palette.lineBright, dashed: [.bottom])
        header.addSubview(row)
        row.pinEdges(to: header)
        header.heightAnchor.constraint(equalToConstant: 40).zoomed(40).isActive = true
        return header
    }

    private func makeFooter() -> NSView {
        cleanupLink.target = self
        cleanupLink.action = #selector(openCleanup)
        let hostTitle = Label.make("Host", style: TextStyle.caps(9.5, Palette.dim, tracking: 0.18))
        let line1 = hStack([hostTitle, hostLine, spacer(), cleanupLink], spacing: 8)
        let note = CoddButton("Quick note ⌘⇧N", style: .bracket(.normal, small: true), target: self, action: #selector(quickNote))
        let open = CoddButton("Open CODD", style: .bracket(.primary, small: true), target: self, action: #selector(openMain))
        let line2 = hStack([note, spacer(), open], spacing: 8)
        let stack = vStack([line1, line2], spacing: 6, alignment: .width, edgeInsets: NSEdgeInsets(top: 7, left: 12, bottom: 8, right: 12))
        let footer = PanelView(edges: [.top], edgeColor: Palette.lineBright, dashed: [.top])
        footer.addSubview(stack)
        stack.pinEdges(to: footer)
        return footer
    }

    // MARK: Body

    /// Applies freshly computed content: rows are updated in place when the layout is the
    /// same, the body is rebuilt only when sections, rows or accounts change.
    private func apply(_ content: MenuBarPanelContent) {
        liveChip.set("\(content.live) live")
        Label.set(hostLine, content.hostLine, style: TextStyle.mono(11, Palette.dim))
        cleanupLink.label = "清理建議 \(content.cleanupSuggestions) →"
        if let shown, shown.layout == content.layout {
            updateInPlace(content)
        } else {
            rebuild(content)
            onLayoutChange?()
        }
        shown = content
    }

    private func updateInPlace(_ content: MenuBarPanelContent) {
        setAutoSwitch(content.autoSwitchOn)
        for row in content.needs { needsRows[row.id]?.update(row.model) }
        for row in content.ready { compactRows[row.id]?.update(row.model) }
        for block in content.running { for row in block.rows { compactRows[row.id]?.update(row.model) } }
        if let more = content.more { moreLabel?.attributedStringValue = Self.moreText(more) }
    }

    private func rebuild(_ content: MenuBarPanelContent) {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        needsRows = [:]
        compactRows = [:]
        moreLabel = nil
        addAccounts(content)
        if !content.needs.isEmpty { addNeeds(content.needs) }
        if !content.ready.isEmpty { addReady(content.ready) }
        addRunning(content)
    }

    private func sectionHeader(_ title: String, count: Int?, badge: Bool = false, color: NSColor = Palette.dim,
                               note: String? = nil) -> NSView {
        let head = Label.make(title, style: TextStyle.caps(10, color, tracking: 0.18))
        // M5 D21: `◆ Needs you` is spoken without its glyph, with its count (`NEEDS YOU，3 個`).
        let words = title.first.map { $0.isLetter } == false ? String(title.drop { !$0.isLetter }) : title
        head.setAccessibilityLabel(words.uppercased() + (count.map { "，\($0) 個" } ?? ""))
        var views: [NSView] = [head]
        if let count {
            views.append(badge ? ChipView("\(count)", style: .badge)
                               : Label.make("\(count)", style: TextStyle.mono(10, Palette.amberDim)))
        }
        views.append(DashedRuleView())
        if let note { views.append(Label.make(note, style: TextStyle.mono(10.5, Palette.dimmer))) }
        return hStack(views, spacing: 6, edgeInsets: NSEdgeInsets(top: 4, left: 8, bottom: 2, right: 8))
    }

    private func addAccounts(_ content: MenuBarPanelContent) {
        body.addArrangedSubview(sectionHeader("Accounts", count: content.accountTotal, note: "依每週重置 · 剩餘"))
        let list = vStack([], spacing: 0, alignment: .width)
        for (i, id) in content.accountIDs.enumerated() {
            if i > 0 { list.addArrangedSubview(DashedRuleView()) }
            let row = AccountRowView(accountID: id, store: accounts, clock: store.clock, variant: .menuBar)
            row.onSwitch = { [weak self] id in self?.switchAccount(id) }
            list.addArrangedSubview(row)
        }
        body.addArrangedSubview(list)
        if content.accountTotal > MenuBarPanelContent.accountLimit {
            // D23: `▸ 全部帳號 n` expands the rest (`▾` collapses them again).
            let expander = CoddButton("\(content.accountsExpanded ? "▾" : "▸") 全部帳號 \(content.accountTotal)", style: .link,
                                      target: self, action: #selector(toggleAccounts))
            expander.setAccessibilityLabel(content.accountsExpanded ? "收合帳號清單" : "展開全部 \(content.accountTotal) 個帳號")
            body.addArrangedSubview(hStack([expander, spacer()], spacing: 6, edgeInsets: NSEdgeInsets(top: 2, left: 12, bottom: 0, right: 10)))
        }
        if let note = content.accountsNote {
            let label = WrappingLabel(note, style: TextStyle.mono(10.5, Palette.dimmer))
            body.addArrangedSubview(hStack([label], spacing: 0, edgeInsets: NSEdgeInsets(top: 4, left: 12, bottom: 2, right: 10)))
        }
        let hint = Label.make("點一下直接切換", style: TextStyle.mono(10.5, Palette.dim))
        setAutoSwitch(content.autoSwitchOn)
        body.addArrangedSubview(hStack([hint, spacer(), autoSwitchLabel, autoSwitchLink], spacing: 6,
                                       edgeInsets: NSEdgeInsets(top: 3, left: 12, bottom: 4, right: 10)))
    }

    /// R8 one-liner: `自動切換 OFF · 開啟 →`.
    private func setAutoSwitch(_ on: Bool) {
        Label.set(autoSwitchLabel, "自動切換  \(on ? "ON" : "OFF")  ·", style: TextStyle.mono(10.5, Palette.dim))
        autoSwitchLink.label = on ? "設定 →" : "開啟 →"
    }

    private func addNeeds(_ rows: [MenuBarPanelContent.Row<PanelNeedsRowView.Model>]) {
        let box = PanelView(fill: Palette.amber.withAlphaComponent(0.035), edges: [.top, .bottom, .left, .right],
                            edgeColor: Palette.amber.withAlphaComponent(0.28))
        let stack = vStack([sectionHeader("◆ Needs you", count: rows.count, badge: true, color: Palette.amber)], spacing: 1,
                           alignment: .width, edgeInsets: NSEdgeInsets(top: 0, left: 0, bottom: 2, right: 0))
        for item in rows {
            let row = PanelNeedsRowView(sessionID: item.id, clock: store.clock, model: item.model)
            row.onOpen = { [actions] id in actions.openSession(id) }
            row.onAllow = { [actions] id in actions.allow(id) }
            needsRows[item.id] = row
            stack.addArrangedSubview(row)
        }
        box.addSubview(stack)
        stack.pinEdges(to: box)
        body.addArrangedSubview(box)
    }

    private func addReady(_ rows: [MenuBarPanelContent.Row<PanelCompactRowView.Model>]) {
        body.addArrangedSubview(sectionHeader("◇ Ready", count: rows.count))
        for item in rows {
            let row = PanelCompactRowView(sessionID: item.id, clock: store.clock, model: item.model, height: 26)
            row.onOpen = { [actions] id in actions.openSession(id) }
            compactRows[item.id] = row
            body.addArrangedSubview(row)
        }
    }

    private func addRunning(_ content: MenuBarPanelContent) {
        body.addArrangedSubview(sectionHeader("Running", count: content.runningCount))
        for block in content.running {
            let rows: [NSView] = block.rows.map { item in
                let row = PanelCompactRowView(sessionID: item.id, clock: store.clock, model: item.model)
                row.onOpen = { [actions] id in actions.openSession(id) }
                compactRows[item.id] = row
                return row
            }
            body.addArrangedSubview(PanelGroupBlockView(name: block.name, color: block.color, rows: rows))
        }
        guard let more = content.more else { return }
        let label = NSTextField(labelWithAttributedString: Self.moreText(more))
        moreLabel = label
        body.addArrangedSubview(hStack([label, spacer()], spacing: 4, edgeInsets: NSEdgeInsets(top: 4, left: 24, bottom: 2, right: 8)))
    }

    private static func moreText(_ more: MenuBarPanelContent.More) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: TextStyle.mono(11, Palette.dim).string("+\(more.hidden) more"))
        if more.busy > 0 {
            text.append(TextStyle.mono(11, Palette.dimmer).string(" · "))
            text.append(TextStyle.mono(11, Palette.success).string("● \(more.busy)"))
        }
        if more.idle > 0 {
            text.append(TextStyle.mono(11, Palette.dimmer).string(" · "))
            text.append(TextStyle.mono(11, Palette.cyan).string("○ \(more.idle)"))
            text.append(TextStyle.mono(11, Palette.dim).string(" idle"))
        }
        return text
    }

    // MARK: Actions

    /// A row click: the D5 switch; its toast (with UNDO, or the redacted failure) shows in the panel.
    private func switchAccount(_ id: AccountID) {
        AccountSwitching.run(id, in: accounts) { [weak self] text, undo in self?.showToast(text, undo: undo) }
    }

    @objc private func toggleAccounts() { shell.menuBarAccountsExpanded.toggle() }

    /// The toast on screen (tests).
    var currentToast: ToastView? { subviews.compactMap { $0 as? ToastView }.last }

    private func showToast(_ text: String, undo: (@MainActor () -> Void)?) {
        subviews.compactMap { $0 as? ToastView }.forEach { $0.removeFromSuperview() } // one toast at a time
        let toast = ToastView(text: text, undo: undo)
        toast.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toast)
        NSLayoutConstraint.activate([
            toast.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toast.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            toast.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -64),
        ])
        toast.dismiss(after: 6)
    }

    @objc private func newSession() { actions.newSession() }
    @objc private func openMain() { actions.openMain() }
    @objc private func openSettings() { actions.openSettings(nil) }
    @objc private func openAccounts() { actions.openSettings("accounts") }
    @objc private func openCleanup() {
        if let open = actions.openCleanup { open() } else { actions.openSettings("cleanup") }
    }
    @objc private func quickNote() { actions.quickNote() }
}

/// Amber brand mark with glow (panel header).
final class BrandMarkView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 16, height: 16) }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = Palette.amberGlow
        glow.shadowBlurRadius = 4
        glow.shadowOffset = .zero
        glow.set()
        BrandMark.draw(in: bounds, outline: Palette.amber, core: Palette.amber)
        NSGraphicsContext.restoreGraphicsState()
    }
}
