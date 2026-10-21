import AppKit
import CoddUI

/// HOOKS & STATUSLINE: the `~/.claude settings.json` card (part rows Hooks / Statusline / Status
/// dir / 最近收到資料, FOREIGN HOOKS, the installer buttons) and one small card per cswap session
/// profile in use.
final class HooksSectionView: FlippedView {
    private let header = SectionHeaderRow(title: "Hooks & Statusline")
    let card = HooksCardView()
    private(set) var profileCards: [ProfileCardView] = []
    private(set) var model: HooksCardModel?
    private(set) var configureCount = 0
    var actions = StatusPageActions() { didSet { card.actions = actions } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        addSubview(card)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("HOOKS & STATUSLINE")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ model: HooksCardModel, now: Date) {
        guard model != self.model else { return }
        configureCount += 1
        self.model = model
        card.configure(model, now: now)
        if profileCards.count != model.profiles.count {
            profileCards.forEach { $0.removeFromSuperview() }
            profileCards = model.profiles.map { _ in ProfileCardView() }
            profileCards.forEach { addSubview($0) }
        }
        for (view, profile) in zip(profileCards, model.profiles) { view.configure(profile, claudeDir: model.claudeDir) }
        needsLayout = true
    }

    func tick(now: Date) { card.tick(now: now) }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        if apply { header.frame = CGRect(x: 0, y: 0, width: width, height: SectionHeaderRow.height) }
        var y = SectionHeaderRow.height + sz(10)
        let h = card.preferredHeight(width: width)
        if apply { card.frame = CGRect(x: 0, y: y, width: width, height: h) }
        y += h
        for profile in profileCards {
            y += sz(10)
            let ph = profile.preferredHeight(width: width)
            if apply { profile.frame = CGRect(x: 0, y: y, width: width, height: ph) }
            y += ph
        }
        return y
    }

    func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, apply: true)
    }
}

// MARK: - Settings card

/// The `~/.claude` card (`article.card`): head `~/.CLAUDE settings.json … [◆ 1 項需要更新]`, the
/// part rows (`.sx-pr`, 118 px term column), FOREIGN HOOKS and the action buttons.
final class HooksCardView: CardFrameView {
    private let title = TextLine(runs: [])
    private let headChip = ChipLabel("", style: StatusChips.medium(.amber))
    private let headRule = RuleLine(color: Palette.lineBright)
    private let problem = TextBlock(style: TextStyle.mono(12, Palette.danger))
    let hooksPart = PartRowView(term: "Hooks")
    let statuslinePart = PartRowView(term: "Statusline")
    let statusDirPart = PartRowView(term: "Status dir")
    let receivedPart = PartRowView(term: "最近收到資料")

    // Hooks part
    private let hooksStatus = TextLine(style: StatusStyles.body(Palette.success))
    private let hooksDot = TextLine("·", style: StatusStyles.body(Palette.dimmer))
    private let hooksHint = TextLine("每個 CODD session 自動注入", style: TextStyle.hint)
    private let legacyText = TextLine(style: StatusStyles.body(Palette.amber))
    let removeLegacyButton = CoddButton("只移除舊版", style: .bracket(.normal, small: true))
    private var legacyChips: [ChipLabel] = []

    // Statusline part
    private let statuslineState = TextLine(style: StatusStyles.body(Palette.success))
    private var chainViews: [NSView] = []
    private let statuslineHint = TextBlock(style: TextStyle.hint)

    // Status dir part
    private let dirChip = ChipLabel("! 與預設不同", style: StatusChips.amber)
    private let dirPath = PathBoxView()

    // 最近收到資料 part
    private let receivedGlyph = TextLine(style: StatusStyles.body(Palette.success))
    private let receivedTime = TextLine(style: StatusStyles.body(Palette.cream))
    private let receivedHint = TextLine(style: TextStyle.hint)
    /// `▸ 詳細`: the endpoint diagnostics (M1's STATUS rows) under the row, closed by default.
    let detailsButton = CoddButton("▸ 詳細", style: .link)
    let detailsBlock = TextBlock(style: TextStyle.mono(11, Palette.dim), lineHeight: 1.5, breakAnywhere: true)
    /// The diagnostics are shown (view state: a new model keeps it).
    private(set) var detailsOpen = false

    // Foreign hooks
    private let foreignTitle = TextLine("Foreign hooks", style: TextStyle.caps(10, Palette.dim, tracking: 0.18))
    private let foreignHint = TextLine("其他工具的項目 · CODD 不會改動", style: TextStyle.hint)
    private let foreignRule = RuleLine(color: Palette.lineBright)
    private(set) var foreignRows: [ForeignRowView] = []
    private let foreignEmpty = TextLine("// 沒有其他工具的 hook", style: TextStyle.comment)

    // Actions
    let previewButton = CoddButton("預覽變更", style: .bracket(.normal, small: false))
    let updateButton = CoddButton("更新", style: .bracket(.primary, small: false))
    private let actionsHint = TextLine("套用前自動備份 settings.json", style: TextStyle.hint)
    let uninstallButton = CoddButton("解除安裝", style: .bracket(.danger, small: false))

    private var holders: [ButtonAction] = []
    private(set) var model: HooksCardModel?
    var actions = StatusPageActions()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view: NSView in [title, headChip, headRule, problem, hooksPart, statuslinePart, statusDirPart, receivedPart,
                             foreignTitle, foreignHint, foreignRule, foreignEmpty, previewButton, updateButton, actionsHint,
                             uninstallButton] {
            addSubview(view)
        }
        hooksPart.addContent([hooksStatus, hooksDot, hooksHint, legacyText, removeLegacyButton])
        statuslinePart.addContent([statuslineState, statuslineHint])
        statusDirPart.addTermAccessory(dirChip)
        statusDirPart.addContent([dirPath])
        receivedPart.addContent([receivedGlyph, receivedTime, receivedHint, detailsButton, detailsBlock])
        detailsBlock.isHidden = true
        detailsButton.setAccessibilityLabel("hook endpoint 詳細")
        holders.append(detailsButton.onPress { [weak self] in self?.toggleDetails() })
        holders.append(previewButton.onPress { [weak self] in self?.actions.previewHooks() })
        holders.append(updateButton.onPress { [weak self] in self?.actions.update() })
        holders.append(uninstallButton.onPress { [weak self] in self?.actions.uninstall() })
        holders.append(removeLegacyButton.onPress { [weak self] in self?.actions.removeLegacy() })
        previewButton.setAccessibilityLabel("預覽 settings.json 的變更")
        updateButton.setAccessibilityLabel("更新 hooks 與 statusline")
        uninstallButton.setAccessibilityLabel("解除安裝全域 statusline")
        removeLegacyButton.setAccessibilityLabel("只移除舊版 CODD web hook")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    func configure(_ model: HooksCardModel, now: Date) {
        self.model = model
        title.set(attributed: TextRuns.joined([(model.claudeDir, TextStyle.cardTitle, 8),
                                              (model.fileName, TextStyle.mono(11.5, Palette.dimmer, tracking: 0.04), 0)]))
        if model.pendingUpdates > 0 {
            headChip.set("◆ \(model.pendingUpdates) 項需要更新", style: StatusChips.medium(.amber))
        } else {
            headChip.set("● 正常", style: StatusChips.medium(.ok))
        }
        problem.isHidden = model.problem == nil
        problem.set(model.problem ?? "")

        // Hooks: injected count, then the CODD web leftovers with their events.
        let complete = model.hooksInjected >= model.hooksTotal
        hooksStatus.set("\(complete ? "●" : "◆") \(model.hooksInjected) / \(model.hooksTotal)",
                        style: StatusStyles.body(complete ? Palette.success : Palette.amber))
        legacyText.isHidden = model.legacy == nil
        removeLegacyButton.isHidden = model.legacy == nil
        removeLegacyButton.isEnabled = model.canRemoveLegacy
        if let legacy = model.legacy {
            legacyText.set(legacy.events.isEmpty ? "◆ 舊版 CODD web statusline" : "◆ 舊版 CODD web hook · \(legacy.events.count) 個 event",
                           style: StatusStyles.body(Palette.amber))
        }
        let events = model.legacy?.events ?? []
        if legacyChips.count != events.count {
            legacyChips.forEach { $0.removeFromSuperview() }
            legacyChips = events.map { _ in ChipLabel("", style: StatusChips.amber) }
            hooksPart.addContent(legacyChips)
        }
        for (chip, event) in zip(legacyChips, events) { chip.set(event, style: StatusChips.amber) }

        // Statusline: the global wrapper's state and its chain.
        let (stateText, stateColor, hint) = Self.statuslineCopy(model.statusline.state)
        statuslineState.set(stateText, style: StatusStyles.body(stateColor))
        statuslineHint.isHidden = hint == nil
        statuslineHint.set(hint ?? "")
        chainViews.forEach { $0.removeFromSuperview() }
        chainViews = []
        for (i, part) in model.statusline.chain.enumerated() {
            chainViews.append(ChainLinkView(part, arrow: i > 0))
        }
        statuslinePart.addContent(chainViews)

        // Status dir.
        dirChip.isHidden = !model.statusDirDiffers
        dirPath.set(model.statusDir)

        // Foreign hooks.
        if foreignRows.count != model.foreign.count {
            foreignRows.forEach { $0.removeFromSuperview() }
            foreignRows = model.foreign.map { _ in
                let row = ForeignRowView()
                row.onDisable = { [weak self] in self?.actions.disableDuplicateNotifications() }
                return row
            }
            foreignRows.forEach { addSubview($0) }
        }
        for (row, item) in zip(foreignRows, model.foreign) { row.configure(item, canDisable: model.canDisableDuplicates) }
        foreignEmpty.isHidden = !model.foreign.isEmpty

        detailsButton.isHidden = model.details.isEmpty
        detailsBlock.set(model.details.joined(separator: "\n"))
        detailsBlock.isHidden = model.details.isEmpty || !detailsOpen

        previewButton.isEnabled = model.canPreview
        updateButton.isEnabled = model.canUpdate
        uninstallButton.isEnabled = model.canUninstall
        setAccessibilityLabel("\(model.claudeDir) 設定")
        tick(now: now)
        needsLayout = true
    }

    /// The Statusline row's state line and hint per installer state (D10, D11).
    static func statuslineCopy(_ state: StatuslinePart.State) -> (String, NSColor, String?) {
        switch state {
        case .installed:
            ("● 已安裝", Palette.success, nil)
        case .outdated:
            ("◆ 需要更新", Palette.amber, "全域 statusline 指向舊的 CODD 位置，按 更新 重新安裝")
        case .legacyWeb:
            ("◆ 舊版 CODD web statusline", Palette.amber, "按 更新 換成 CODD Desktop 版，串接的 statusline 不變")
        case .notInstalled:
            ("○ 未安裝全域版", Palette.dim, "CODD 的 session 已自動注入；裝了全域版，其他 claude 的用量也會回報")
        case .undecodable:
            ("▲ 無法解析", Palette.danger, "statusLine 的串接內容無法解碼，CODD 不會改動它")
        }
    }

    /// `最近收到資料`: the age ticks; the hint says who reported.
    func tick(now: Date) {
        guard let model else { return }
        let received = model.lastReceived
        var changed = false
        if let at = received.at {
            changed = receivedGlyph.set("●", style: StatusStyles.body(Palette.success)) || changed
            changed = receivedTime.isHidden || changed
            receivedTime.isHidden = false
            changed = receivedTime.set(DurationFormat.ago(at, now: now), style: StatusStyles.body(Palette.cream)) || changed
        } else {
            changed = receivedGlyph.set("○", style: StatusStyles.body(Palette.dimmer)) || changed
            changed = !receivedTime.isHidden || changed
            receivedTime.isHidden = true
        }
        changed = receivedHint.set(Self.receivedHint(received), style: TextStyle.hint) || changed
        // The time's width changed: re-place that row only (at most once a second).
        if changed, bounds.width > 0 { layoutReceived(width: ddWidth(forCardWidth: bounds.width), apply: true) }
    }

    /// `▸ 詳細` / `▾ 詳細`: shows or hides the diagnostics and lays the page out again (the card
    /// grows by their lines).
    func toggleDetails() {
        detailsOpen.toggle()
        detailsButton.label = detailsOpen ? "▾ 詳細" : "▸ 詳細"
        detailsBlock.isHidden = !detailsOpen || (model?.details.isEmpty ?? true)
        var view: NSView? = self
        while let current = view {
            current.needsLayout = true
            view = current.superview
        }
    }

    static func receivedHint(_ received: LastReceived) -> String {
        switch (received.hooks, received.statusline) {
        case (true, true): "hook 事件與 statusline 都有回報"
        case (true, false): "只有 hook 事件回報，statusline 還沒有"
        case (false, true): "只有 statusline 回報，hook 事件還沒有"
        case (false, false): received.at == nil ? "還沒有收到資料" : "hook 事件與 statusline 都還沒有"
        }
    }

    // MARK: Layout

    func preferredHeight(width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        guard let model else { return 0 }
        // `.card{padding:16px 18px}`; head 27 + 12.
        let x: CGFloat = sz(19)
        let inner = width - sz(38)
        if apply {
            let chipSize = headChip.intrinsicContentSize
            headChip.frame = CGRect(x: x + inner - chipSize.width, y: sz(17), width: chipSize.width, height: sz(20))
            title.frame = CGRect(x: x, y: sz(17), width: max(0, headChip.frame.minX - sz(8) - x), height: sz(20))
            headRule.frame = CGRect(x: x, y: sz(17) + sz(26), width: inner, height: 1)
            headRule.atTop = true
        }
        var y: CGFloat = sz(17) + sz(27) + sz(12)
        if !problem.isHidden {
            let h = problem.height(forWidth: inner)
            if apply { problem.frame = CGRect(x: x, y: y, width: inner, height: h) }
            y += h + sz(8)
        }
        let ddWidth = ddWidth(forCardWidth: width)
        let parts: [(PartRowView, (CGFloat, Bool) -> CGFloat)] = [
            (hooksPart, { w, a in self.layoutHooks(width: w, apply: a) }),
            (statuslinePart, { w, a in self.layoutStatusline(width: w, apply: a) }),
            (statusDirPart, { w, a in self.layoutStatusDir(width: w, apply: a) }),
            (receivedPart, { w, a in self.layoutReceived(width: w, apply: a) }),
        ]
        for (i, (part, content)) in parts.enumerated() {
            let top: CGFloat = i == 0 ? 0 : sz(8)
            if apply { part.contentTop = top }
            let ddHeight = content(ddWidth, apply)
            let h = top + max(ddHeight, part.termHeight) + sz(8) + 1
            if apply { part.frame = CGRect(x: x, y: y, width: inner, height: h) }
            y += h
        }
        // `.sx-subh{margin-top:12px}` 17.3, then the list.
        y += sz(12)
        if apply {
            RowLayout.layout([RowItem(foreignTitle), RowItem(foreignHint, .shrink), RowItem(foreignRule, .flex(min: 24), height: 1)],
                             in: CGRect(x: x, y: y, width: inner, height: sz(17.3)), gap: 8)
        }
        y += sz(17.3)
        if model.foreign.isEmpty {
            if apply { foreignEmpty.frame = CGRect(x: x, y: y, width: inner, height: sz(30)) }
            y += sz(30)
        }
        for row in foreignRows {
            if apply { row.frame = CGRect(x: x, y: y, width: inner, height: ForeignRowView.height) }
            y += ForeignRowView.height
        }
        // `.sx-acts{margin-top:14px}`, 28 px buttons.
        y += sz(14)
        if apply {
            RowLayout.layout([RowItem(previewButton), RowItem(updateButton), RowItem(actionsHint, .shrink), .flex(), RowItem(uninstallButton)],
                             in: CGRect(x: x, y: y, width: inner, height: sz(28)), gap: 8)
        }
        y += sz(28)
        return y + sz(17)
    }

    /// The part rows' content column width (`grid-template-columns:118px 1fr; gap:12px`).
    private func ddWidth(forCardWidth width: CGFloat) -> CGFloat { width - sz(38) - PartRowView.termWidth - sz(12) }

    /// Hooks dd: `● 14 / 14 · 每個 CODD session 自動注入`, then the legacy line and its chips.
    private func layoutHooks(width: CGFloat, apply: Bool) -> CGFloat {
        let origin = hooksPart.contentOrigin
        var y: CGFloat = 0
        if apply {
            RowLayout.layout([RowItem(hooksStatus), RowItem(hooksDot), RowItem(hooksHint, .shrink)],
                             in: CGRect(x: origin, y: hooksPart.contentTop + y, width: width, height: sz(19.5)), gap: 8)
        }
        y += sz(19.5)
        if !legacyText.isHidden {
            y += sz(5)
            if apply {
                RowLayout.layout([RowItem(legacyText, .shrink), .flex(), RowItem(removeLegacyButton)],
                                 in: CGRect(x: origin, y: hooksPart.contentTop + y, width: width, height: sz(22)), gap: 8)
            }
            y += sz(22)
            if !legacyChips.isEmpty {
                y += sz(5)
                y += FlowLayout.layout(legacyChips, origin: CGPoint(x: origin, y: hooksPart.contentTop + y), width: width, gap: 8,
                                       rowGap: 5, lineHeight: 20, apply: apply)
            }
        }
        return y
    }

    /// Statusline dd: state + chain chips (wrapping), then the state's hint.
    private func layoutStatusline(width: CGFloat, apply: Bool) -> CGFloat {
        let origin = statuslinePart.contentOrigin
        let top = statuslinePart.contentTop
        // `.sx-chain{gap:5px}`; the first link carries 3 px more so the chain starts 8 px after the state.
        var y = FlowLayout.layout([statuslineState] + chainViews, origin: CGPoint(x: origin, y: top), width: width, gap: 5,
                                  rowGap: 5, lineHeight: 20, apply: apply)
        if !statuslineHint.isHidden {
            y += sz(5)
            let h = statuslineHint.height(forWidth: width)
            if apply { statuslineHint.frame = CGRect(x: origin, y: top + y, width: width, height: h) }
            y += h
        }
        return y
    }

    private func layoutStatusDir(width: CGFloat, apply: Bool) -> CGFloat {
        let h = dirPath.preferredHeight(width: width)
        if apply { dirPath.frame = CGRect(x: statusDirPart.contentOrigin, y: statusDirPart.contentTop, width: width, height: h) }
        return h
    }

    @discardableResult
    private func layoutReceived(width: CGFloat, apply: Bool) -> CGFloat {
        if apply {
            RowLayout.layout([RowItem(receivedGlyph), RowItem(receivedTime), RowItem(receivedHint, .shrink), .flex(),
                              RowItem(detailsButton)],
                             in: CGRect(x: receivedPart.contentOrigin, y: receivedPart.contentTop, width: width, height: sz(19.5)), gap: 8)
        }
        guard !detailsBlock.isHidden else { return sz(19.5) }
        let h = detailsBlock.height(forWidth: width)
        if apply {
            detailsBlock.frame = CGRect(x: receivedPart.contentOrigin, y: receivedPart.contentTop + sz(19.5) + sz(6), width: width, height: h)
        }
        return sz(19.5) + sz(6) + h
    }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, apply: true)
    }

    var visibleTexts: [String] { statusVisibleTexts() }
}

/// One `.sx-pr` part row: the term (10.5 caps .16em dim, optional chip under it) in a 118 px
/// column, the content to its right (laid out by the card), a dashed `--line` rule under it.
/// Content views are subviews of the row; the card positions them in row coordinates.
final class PartRowView: FlippedView {
    static var termWidth: CGFloat { sz(118) }

    private let term: TextLine
    private var accessory: NSView?
    private let rule = RuleLine(color: Palette.line)
    /// Top padding of this row's content (0 for the first row).
    var contentTop: CGFloat = sz(8) { didSet { needsLayout = true } }
    /// x of the content column.
    var contentOrigin: CGFloat { Self.termWidth + sz(12) }

    init(term: String) {
        self.term = TextLine(term, style: TextStyle.caps(10.5, Palette.dim, tracking: 0.16))
        super.init(frame: .zero)
        rule.atTop = true
        addSubview(self.term)
        addSubview(rule)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func addContent(_ views: [NSView]) { views.forEach { addSubview($0) } }

    func addTermAccessory(_ view: NSView) {
        accessory = view
        addSubview(view)
    }

    /// The term column's height (`dt{padding-top:2px; gap:4px}` with its chip).
    var termHeight: CGFloat {
        var h: CGFloat = sz(2) + sz(15.8)
        if let accessory, !accessory.isHidden { h += sz(4) + accessory.intrinsicContentSize.height }
        return h
    }

    override func layout() {
        super.layout()
        term.frame = CGRect(x: 0, y: contentTop + sz(2), width: Self.termWidth, height: sz(15.8))
        if let accessory {
            let size = accessory.intrinsicContentSize
            accessory.frame = CGRect(x: 0, y: contentTop + sz(2) + sz(15.8) + sz(4), width: min(size.width, Self.termWidth), height: size.height)
        }
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

/// One link of the status-line chain: `→ code` (an arrow never ends a line), the first link
/// without its arrow.
final class ChainLinkView: FlippedView {
    private let arrow: TextLine?
    private let chip: ChipLabel

    init(_ part: String, arrow: Bool) {
        self.arrow = arrow ? TextLine("→", style: StatusStyles.body(Palette.dimmer)) : nil
        chip = ChipLabel(part, style: StatusChips.code)
        super.init(frame: .zero)
        if let a = self.arrow { addSubview(a) }
        addSubview(chip)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var lead: CGFloat { arrow.map { $0.textWidth + sz(5) } ?? sz(3) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: lead + chip.intrinsicContentSize.width, height: sz(20))
    }

    override func layout() {
        super.layout()
        if let arrow { arrow.frame = CGRect(x: 0, y: 0, width: arrow.textWidth, height: bounds.height) }
        chip.frame = CGRect(x: lead, y: 0, width: chip.intrinsicContentSize.width, height: sz(20))
    }
}

/// The status dir `.path` box that wraps anywhere (`.sx-pathw`: line-height 1.55).
final class PathBoxView: FlippedView {
    private let text = TextBlock(style: TextStyle.mono(11.5, Palette.dim), lineHeight: 1.55, breakAnywhere: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        addSubview(text)
        text.setAccessibilityLabel("Status dir")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ path: String) { text.set(path) }

    func preferredHeight(width: CGFloat) -> CGFloat { text.height(forWidth: width - sz(18)) + sz(2) }

    override func layout() {
        super.layout()
        text.frame = CGRect(x: sz(9), y: 1, width: bounds.width - sz(18), height: bounds.height - sz(2))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.line)
    }
}

/// One FOREIGN HOOKS row (`.sx-fh li`, 30 px): `code` · name · `×n events` · warning chips, or
/// `[停用重複通知]` at the right for the duplicate notification handler. A tool named by its
/// program (`hook-tap`) shows only the code.
final class ForeignRowView: FlippedView {
    static var height: CGFloat { sz(30) }

    private let code = ChipLabel("", style: StatusChips.code)
    private let name = TextLine(style: StatusStyles.body(Palette.cream))
    private let hint = TextLine(style: TextStyle.hint)
    private var warnings: [ChipLabel] = []
    let disableButton = CoddButton("停用重複通知", style: .bracket(.normal, small: true))
    private let rule = RuleLine(color: Palette.line)
    private var holder: ButtonAction?
    var onDisable: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.atTop = true
        for view: NSView in [code, name, hint, disableButton, rule] { addSubview(view) }
        holder = disableButton.onPress { [weak self] in self?.onDisable?() }
        disableButton.setAccessibilityLabel("停用重複的 macOS 通知 hook")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `×11 events`, or `×2 · Notification, Stop` for up to three events.
    static func eventsHint(_ events: [String]) -> String {
        events.count <= 3 && !events.isEmpty ? "×\(events.count) · \(events.joined(separator: ", "))" : "×\(events.count) events"
    }

    func configure(_ row: ForeignHookRow, canDisable: Bool) {
        code.set(row.code)
        name.set(row.name, style: StatusStyles.body(Palette.cream))
        name.isHidden = row.name.isEmpty || row.name == row.code
        hint.set(Self.eventsHint(row.events), style: TextStyle.hint)
        if warnings.count != row.warnings.count {
            warnings.forEach { $0.removeFromSuperview() }
            warnings = row.warnings.map { _ in ChipLabel("", style: StatusChips.amber) }
            warnings.forEach { addSubview($0) }
        }
        for (chip, text) in zip(warnings, row.warnings) { chip.set(text, style: StatusChips.amber) }
        disableButton.isHidden = !row.duplicateNotifications
        disableButton.isEnabled = canDisable
        setAccessibilityLabel((name.isHidden ? "" : "\(row.name) ") + "\(row.code) \(Self.eventsHint(row.events))")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var items: [RowItem] = [RowItem(code), RowItem(name), RowItem(hint, .shrink)]
        items += warnings.map { RowItem($0, .shrink) }
        if !disableButton.isHidden { items += [.flex(), RowItem(disableButton)] }
        RowLayout.layout(items, in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1), gap: 10)
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }
}

// MARK: - Profile card

/// `cswap session profile #2 → settings.json 連結自 ~/.claude（共用） ● 已連結` and its hint
/// (`.card.sx-prof`). Not linked: `▲ 未連結` and `固定 #2 的 session 仍由 CODD 注入 hooks 與 statusline`.
final class ProfileCardView: CardFrameView {
    private let title = TextLine(style: TextStyle(font: Typeface.display(12), color: Palette.amber, tracking: 0.1))
    private let arrow = TextLine("→", style: StatusStyles.body(Palette.dimmer))
    private let lead = TextLine(style: StatusStyles.body(Palette.cream))
    private let code = ChipLabel("", style: StatusChips.code)
    private let tail = TextLine(style: StatusStyles.body(Palette.cream))
    private let state = TextLine(style: StatusStyles.body(Palette.success))
    private let hint = TextBlock(style: TextStyle.hint)
    private(set) var model: ProfileCardModel?
    /// The Claude directory as given; the chip shows it shortened in the middle to fit the card.
    private var fullCode: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [title, arrow, lead, code, tail, state, hint] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    func configure(_ profile: ProfileCardModel, claudeDir: String) {
        model = profile
        title.set("cswap session profile \(profile.slot)", style: TextStyle(font: Typeface.display(12), color: Palette.amber, tracking: 0.1))
        let copy = Self.copy(profile, claudeDir: claudeDir)
        lead.set(copy.lead, style: StatusStyles.body(Palette.cream))
        fullCode = copy.code
        code.isHidden = copy.code == nil
        code.set(copy.code ?? "")
        tail.set(copy.tail, style: StatusStyles.body(Palette.cream))
        state.set(copy.state, style: StatusStyles.body(copy.stateColor))
        hint.set(copy.hint)
        setAccessibilityLabel("cswap session profile \(profile.slot)")
        needsLayout = true
    }

    struct Copy: Equatable {
        var lead: String
        var code: String?
        var tail: String
        var state: String
        var stateColor: NSColor
        var hint: String
    }

    /// The card's texts per link state (Status artboard `.sx-prof`, plus the not-linked and
    /// unknown states of the C6 brief).
    static func copy(_ profile: ProfileCardModel, claudeDir: String) -> Copy {
        let slot = profile.slot
        switch profile.linked {
        case .some(true):
            let who = titles(profile.sessionTitles)
            return Copy(lead: "settings.json 連結自", code: claudeDir, tail: "（共用）", state: "● 已連結", stateColor: Palette.success,
                        hint: "\(who) 以 cswap run 使用 \(slot)，hooks 與 statusline 跟主設定一起生效")
        case .some(false):
            return Copy(lead: "settings.json 沒有連結", code: claudeDir, tail: "（獨立）", state: "▲ 未連結", stateColor: Palette.amber,
                        hint: "固定 \(slot) 的 session 仍由 CODD 注入 hooks 與 statusline")
        case .none:
            return Copy(lead: "settings.json 無法確認", code: nil, tail: "", state: "◌ 未知", stateColor: Palette.dim,
                        hint: "固定 \(slot) 的 session 仍由 CODD 注入 hooks 與 statusline")
        }
    }

    /// `現場示範：連線 MCP`, `a、b`, or `a、b 等 5 個 session`.
    static func titles(_ titles: [String]) -> String {
        guard !titles.isEmpty else { return "固定的 session" }
        if titles.count <= 2 { return titles.joined(separator: "、") }
        return titles.prefix(2).joined(separator: "、") + " 等 \(titles.count) 個 session"
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        // `.sx-prof{padding:12px 18px; gap:5px}`: line 19.5 + hint.
        1 + sz(12) + sz(19.5) + sz(5) + max(sz(17.3), hint.height(forWidth: width - sz(38))) + sz(12) + 1
    }

    /// `text` cut in the middle (`/priv…/home/.claude`) until `fits`, keeping more of the end (a
    /// path's last components say the most); nil when nothing does.
    static func middleTruncated(_ text: String, fits: (String) -> Bool) -> String? {
        if fits(text) { return text }
        let chars = Array(text)
        var keep = chars.count - 1
        while keep >= 2 {
            let head = max(1, keep / 3)
            let candidate = String(chars[..<head]) + "…" + String(chars[(chars.count - (keep - head))...])
            if fits(candidate) { return candidate }
            keep -= 1
        }
        return nil
    }

    override func layout() {
        super.layout()
        let x: CGFloat = sz(19)
        let inner = bounds.width - sz(38)
        // The line stays inside the card (M3 review: a long Claude dir pushed the path chip,
        // `（共用）` and the state past the card's border): the path is cut in the middle to
        // the room the other parts leave; the lead text and the state keep their width.
        if let fullCode {
            let others = [title, arrow, lead, tail, state].reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width }
            // Gaps: title→arrow→lead 8 each, lead→code 7, code→tail 0, tail→flex→state 8 each.
            let room = inner - others - 8 * 4 - sz(7)
            let fitted = Self.middleTruncated(fullCode) { code.style.size(for: $0).width <= room }
            code.isHidden = fitted == nil
            code.set(fitted ?? fullCode)
        }
        var items: [RowItem] = [RowItem(title), RowItem(arrow), RowItem(lead, .shrink)]
        if !code.isHidden { items.append(RowItem(code, gapBefore: 7)) }
        items += [RowItem(tail, gapBefore: 0), .flex(), RowItem(state)]
        RowLayout.layout(items, in: CGRect(x: x, y: sz(13), width: inner, height: sz(19.5)), gap: 8)
        hint.frame = CGRect(x: x, y: sz(13) + sz(19.5) + sz(5), width: inner, height: max(17.3, hint.height(forWidth: inner)))
    }

    var visibleTexts: [String] { statusVisibleTexts() }
}
