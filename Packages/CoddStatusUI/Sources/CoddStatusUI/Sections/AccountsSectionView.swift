import AppKit
import CoddUI

/// ACCOUNTS: header (`cswap 0.26.0` `~/.claude-swap-backup` ┄┄ `依每週重置排序 · 越快重置越上面 · 3 個帳號
/// · 不顯示 email`), the cards in the given (R7) order on a grid with `+ 加入帳號` last, and the
/// AUTO-SWITCH row. Unchanged cards are not reconfigured.
///
/// FB 「Status 的 Account 小一點」/「縮放尺寸時，版型會跑掉」: the cards are compact and the grid takes
/// as many columns as fit cards at least as wide as their content (and at most 300 wide), so a
/// card's content always stays inside its frame; a header too narrow for the hints moves them to a
/// line of their own instead of running them over the rule. While cswap is missing (or too old)
/// the install guide follows the unavailable line.
final class AccountsSectionView: FlippedView {
    private let header = SectionHeaderRow(title: "Accounts")
    private let version = ChipLabel("", style: StatusChips.plain)
    private let root = ChipLabel("", style: StatusChips.path)
    private let sortHint = TextLine(AccountsSectionModel.sortHint, style: TextStyle.mono(11.5, Palette.dim, tracking: 0.02))
    private let dot = TextLine("·", style: StatusStyles.body(Palette.dimmer))
    private let countHint = TextLine(style: TextStyle.hint)
    private let unavailable = TextBlock(style: TextStyle.comment)
    let guide = CswapGuideView()
    private(set) var cards: [String: AccountCardView] = [:]
    private var order: [String] = []
    let addCard = AddAccountCardView()
    let autoSwitch = AutoSwitchRowView()
    private(set) var model: AccountsSectionModel?
    private(set) var configureCount = 0
    var actions = StatusPageActions()
    var guideActions = CswapGuideActions()
    /// The hints sit on their own line under the title (the header is too narrow for them).
    private(set) var hintsWrapped = false

    /// Cards are never narrower than this (nor than their content), nor wider than the maximum
    /// while more columns fit.
    static var minimumCardWidth: CGFloat { sz(220) }
    static var maximumCardWidth: CGFloat { sz(300) }
    static var gap: CGFloat { sz(12) }
    static var hintLineHeight: CGFloat { sz(16) }

    /// The columns for a grid `width` wide whose cards need `minimumCard`: the fewest that keep the
    /// cards at most ``maximumCardWidth``, but never more than fit cards of the minimum (at least 1).
    static func columns(forWidth width: CGFloat, minimumCard: CGFloat = 0) -> Int {
        let minimum = max(minimumCard, minimumCardWidth)
        let fit = max(1, Int(((width + gap) / (minimum + gap)).rounded(.down)))
        let wanted = max(1, Int(((width + gap) / (maximumCardWidth + gap)).rounded(.up)))
        return min(fit, wanted)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.setLeading([version, root])
        // The path gives way (ends in `…`) when even the header without the hints is too wide.
        header.shrinkingLeading = [ObjectIdentifier(root)]
        header.setTrailing([sortHint, dot, countHint])
        addSubview(header)
        addSubview(unavailable)
        guide.isHidden = true
        guide.onCopy = { [weak self] command in self?.guideActions.copy(command) }
        guide.onRun = { [weak self] command in self?.guideActions.runInTerminal(command) }
        // `↻ 立即更新` re-reads cswap's state and looks for the executable again (D1, D3).
        guide.onRedetect = { [weak self] in self?.actions.refresh() }
        addSubview(guide)
        addCard.onClick = { [weak self] in self?.actions.addAccount() }
        addSubview(addCard)
        autoSwitch.onToggle = { [weak self] in self?.toggleAutoSwitch() }
        autoSwitch.onSettings = { [weak self] in self?.actions.openAutoSwitch() }
        addSubview(autoSwitch)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("ACCOUNTS 帳號")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Turning ON asks first (the policy warning); turning OFF does not.
    private func toggleAutoSwitch() {
        guard model?.autoSwitch.on == false else {
            setAutoSwitch(false)
            return
        }
        actions.confirmAutoSwitch(window) { [weak self] confirmed in
            if confirmed { self?.setAutoSwitch(true) }
        }
    }

    /// The value the switch asked for: set as such when the app takes a value; else a toggle,
    /// and only while the page still shows the other state (it may have moved while the
    /// confirmation sheet was up, review ui-autoswitch-toggle-race).
    private func setAutoSwitch(_ on: Bool) {
        if let set = actions.setAutoSwitch {
            set(on)
            return
        }
        guard model?.autoSwitch.on != on else { return }
        actions.toggleAutoSwitch()
    }

    func configure(_ model: AccountsSectionModel, now: Date) {
        guard model != self.model else { return }
        configureCount += 1
        self.model = model
        version.isHidden = model.version == nil
        version.set(model.version ?? "")
        root.isHidden = model.rootPath == nil
        root.set(model.rootPath ?? "")
        countHint.set(model.countHint, style: TextStyle.hint)
        header.needsLayout = true
        unavailable.isHidden = model.unavailable == nil
        unavailable.set(model.unavailable ?? "")
        guide.isHidden = model.guide == nil
        if let kind = model.guide { guide.configure(kind) }

        let ids = model.cards.map(\.id)
        for (id, view) in cards where !ids.contains(id) {
            view.removeFromSuperview()
            cards[id] = nil
        }
        for (index, card) in model.cards.enumerated() {
            let view = cards[card.id] ?? {
                let made = AccountCardView()
                made.onSwitch = { [weak self] id in self?.actions.switchAccount(id) }
                addSubview(made)
                cards[card.id] = made
                return made
            }()
            view.configure(card, autoSwitch: model.autoSwitch, soonest: index == 0 && model.cards.count > 1, now: now)
        }
        order = ids
        addCard.isHidden = !model.canAdd
        autoSwitch.configure(model.autoSwitch)
        needsLayout = true
    }

    func tick(now: Date) {
        for view in cards.values { view.tick(now: now) }
    }

    // MARK: Layout

    private var gridItems: [NSView] {
        var items: [NSView] = order.compactMap { cards[$0] }
        if !addCard.isHidden { items.append(addCard) }
        return items
    }

    /// Whether the title, the chips, the rule's minimum and the hints fit on one line.
    func hintsFit(width: CGFloat) -> Bool {
        let gap = sz(10)
        var needed = header.title.intrinsicContentSize.width + gap + sz(24)
        for view in [version, root] where !view.isHidden { needed += view.intrinsicContentSize.width + gap }
        for view in [sortHint, dot, countHint] { needed += gap + view.intrinsicContentSize.width }
        return needed <= width
    }

    /// The widest card's content (the grid's minimum column).
    var minimumCardContentWidth: CGFloat { cards.values.map { $0.minimumWidth() }.max() ?? 0 }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let wrapped = !hintsFit(width: width)
        if apply {
            if wrapped != hintsWrapped {
                hintsWrapped = wrapped
                if wrapped {
                    header.setTrailing([])
                    for view in [sortHint, dot, countHint] { addSubview(view) }
                } else {
                    for view in [sortHint, dot, countHint] { view.removeFromSuperview() }
                    header.setTrailing([sortHint, dot, countHint])
                }
            }
            header.frame = CGRect(x: 0, y: 0, width: width, height: SectionHeaderRow.height)
            header.needsLayout = true
        }
        var y = SectionHeaderRow.height
        if wrapped {
            y += sz(4)
            if apply {
                // Left under the title; the sort hint gives way first (`…`), the count stays whole.
                RowLayout.layout([RowItem(sortHint, .shrink), RowItem(dot), RowItem(countHint)],
                                 in: CGRect(x: 0, y: y, width: width, height: Self.hintLineHeight), gap: sz(10))
            }
            y += Self.hintLineHeight
        }
        y += sz(10)
        if !unavailable.isHidden {
            let h = max(18, unavailable.height(forWidth: width))
            if apply { unavailable.frame = CGRect(x: 0, y: y, width: width, height: h) }
            y += h + sz(10)
        }
        if !guide.isHidden {
            let h = guide.height(forWidth: width)
            if apply { guide.frame = CGRect(x: 0, y: y, width: width, height: h) }
            y += h + sz(10)
        }
        let items = gridItems
        if !items.isEmpty {
            let columns = Self.columns(forWidth: width, minimumCard: minimumCardContentWidth)
            let columnWidth = floor((width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns))
            // Every grid row is as tall as its tallest card (CSS grid `align-items: stretch`).
            var index = 0
            while index < items.count {
                let row = Array(items[index..<min(items.count, index + columns)])
                let height = row.map { ($0 as? AccountCardView)?.preferredHeight(width: columnWidth) ?? AddAccountCardView.minHeight }.max() ?? 0
                if apply {
                    for (column, view) in row.enumerated() {
                        view.frame = CGRect(x: round(CGFloat(column) * (columnWidth + Self.gap)), y: y, width: columnWidth, height: height)
                    }
                }
                y += height + Self.gap
                index += columns
            }
            y += sz(10) - Self.gap
        }
        let autoHeight = autoSwitch.preferredHeight(width: width)
        if apply { autoSwitch.frame = CGRect(x: 0, y: y, width: width, height: autoHeight) }
        return y + autoHeight
    }

    func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, apply: true)
    }

    func card(_ id: String) -> AccountCardView? { cards[id] }
    var orderedCards: [AccountCardView] { order.compactMap { cards[$0] } }
    var unavailableText: String? { unavailable.isHidden ? nil : unavailable.displayedText }
    /// The header row and the hint views (tests).
    var headerRow: SectionHeaderRow { header }
    var hintViews: [NSView] { [sortHint, dot, countHint] }
}

// MARK: - Account card

/// One account (`.card.sx-acct`, `.hot` when active): `#2 藍鵲 [MAX 20X] [SWITCH]`, health ·
/// source, the quota rows each with its reset line (1w = sort key, brighter), the pace warning,
/// and who uses it at the bottom. Compact (FB): padding 10, head items 6 apart, rows 31, lines 5 apart.
final class AccountCardView: CardFrameView {
    /// The compact card's lengths (design px at the interface zoom).
    enum Metrics {
        static var padX: CGFloat { sz(10) }
        /// Between the head line's items.
        static var headGap: CGFloat { sz(6) }
        static var padTop: CGFloat { sz(10) }
        static var padBottom: CGFloat { sz(9) }
        static var headHeight: CGFloat { sz(22) }
        /// Head line → its dashed rule.
        static var headRuleGap: CGFloat { sz(5) }
        static var gap: CGFloat { sz(5) }
        static var lineHeight: CGFloat { sz(15) }
        /// The `who` line: its rule, 5, the 15 line.
        static var whoHeight: CGFloat { 1 + sz(5) + sz(15) }
        static var headRuleY: CGFloat { padTop + headHeight + headRuleGap }
        static var healthY: CGFloat { headRuleY + 1 + gap }
    }

    private let slot = TextLine(style: TextStyle(font: Typeface.display(14), color: Palette.amber, tracking: 0.02))
    private let alias = TextLine(style: TextStyle(font: Typeface.display(12), color: Palette.cream, tracking: 0.06, uppercase: true))
    private let plan = ChipLabel("", style: StatusChips.medium(.plain, uppercase: true))
    let button = CoddButton("Switch", style: .bracket(.accent, small: true))
    private let health = TextLine(style: TextStyle.mono(11, Palette.success))
    private let healthDot = TextLine("·", style: TextStyle.mono(11, Palette.dimmer))
    private let source = TextLine(style: TextStyle.mono(11, Palette.dim))
    /// `◌ 等待 Claude Code credential lock… 9s（1/3）` while switching, or the disabled reason.
    private let note = TextBlock(style: TextStyle.mono(11, Palette.amber), lineHeight: 1.35)
    private var quotaRows: [QuotaBlockView] = []
    private let pace = TextBlock(style: TextStyle.mono(11, Palette.amber), lineHeight: 1.35)
    /// `.card-h{border-bottom:1px dashed var(--line-bright)}`.
    private let headRule = RuleLine(color: Palette.lineBright)
    private let whoRule = RuleLine(color: Palette.line)
    private let whoGlyph = TextLine(style: TextStyle.mono(11, Palette.cyan))
    private let whoText = TextLine(style: TextStyle.mono(11, Palette.bone))
    private var buttonAction: ButtonAction?
    private(set) var model: AccountCardModel?
    private var autoSwitch: AutoSwitchModel?
    private var soonest = false
    private(set) var configureCount = 0
    var onSwitch: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        whoRule.atTop = true
        headRule.atTop = true
        for view: NSView in [headRule, slot, alias, plan, button, health, healthDot, source, note, pace, whoRule, whoGlyph, whoText] {
            addSubview(view)
        }
        buttonAction = button.onPress { [weak self] in
            guard let self, let model = self.model, case .switchable = model.button else { return }
            self.onSwitch?(model.id)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    /// `autoSwitch` places the threshold tick (only on the windows its rule checks).
    func configure(_ card: AccountCardModel, autoSwitch: AutoSwitchModel?, soonest: Bool, now: Date) {
        guard card != model || autoSwitch != self.autoSwitch || soonest != self.soonest else { return }
        configureCount += 1
        model = card
        self.autoSwitch = autoSwitch
        self.soonest = soonest
        hot = card.isActive
        slot.set(card.slot, style: TextStyle(font: Typeface.display(14), color: Palette.amber, tracking: 0.02))
        alias.set(card.alias, style: TextStyle(font: Typeface.display(12), color: Palette.cream, tracking: 0.06, uppercase: true))
        plan.isHidden = card.plan == nil
        plan.set(card.plan ?? "", style: StatusChips.medium(card.isActive ? .amber : .plain, uppercase: true))
        configureButton(card)
        health.set(card.health.text, style: TextStyle.mono(11, card.health.color))

        if quotaRows.count != card.rows.count {
            quotaRows.forEach { $0.removeFromSuperview() }
            quotaRows = card.rows.map { _ in QuotaBlockView() }
            quotaRows.forEach { addSubview($0) }
        }
        for (view, row) in zip(quotaRows, card.rows) {
            view.configure(row, threshold: autoSwitch?.threshold(for: row.window), now: now)
        }
        pace.isHidden = card.pace == nil
        pace.set(card.pace ?? "")
        whoGlyph.set(card.who.glyph.text, style: TextStyle.mono(11, card.who.glyph.color))
        whoText.set(card.who.text, style: TextStyle.mono(11, card.who.muted ? Palette.dim : Palette.bone))
        tick(now: now)
        needsLayout = true
    }

    private func configureButton(_ card: AccountCardModel) {
        switch card.button {
        case .active:
            button.label = "Active"
            button.style = .bracket(.normal, small: true)
            button.isEnabled = false
            button.setAccessibilityLabel("\(card.slot) \(card.alias) 使用中")
            button.toolTip = nil
            note.isHidden = true
        case .switchable:
            button.label = "Switch"
            button.style = .bracket(.accent, small: true)
            button.isEnabled = true
            button.setAccessibilityLabel("切換到 \(card.slot) \(card.alias)")
            button.toolTip = "切換到 \(card.slot) \(card.alias)"
            note.isHidden = true
        case .switching(let progress):
            button.label = "切換中…"
            button.style = .bracket(.accent, small: true)
            button.isEnabled = false
            button.setAccessibilityLabel("正在切換到 \(card.slot) \(card.alias)")
            button.toolTip = nil
            note.isHidden = progress == nil
            note.set(progress ?? "", style: TextStyle.mono(11, Palette.amber))
        case .disabled(let reason):
            button.label = "Switch"
            button.style = .bracket(.accent, small: true)
            button.isEnabled = false
            button.setAccessibilityLabel("無法切換到 \(card.slot) \(card.alias)：\(reason)")
            button.toolTip = reason
            note.isHidden = reason.isEmpty
            note.set(reason, style: TextStyle.mono(11, Palette.dimmer))
        }
    }

    /// Re-renders the ticking texts only (source age, countdowns, the spoken label).
    func tick(now: Date) {
        guard let model else { return }
        // A new age only re-places the health line (the rest of the card keeps its frames).
        if source.set(model.source.text(now: now), style: TextStyle.mono(11, Palette.dim)), bounds.width > 0 { layoutHealthLine() }
        for (view, row) in zip(quotaRows, model.rows) { view.tick(row, now: now) }
        var spoken = "帳號 \(model.slot) \(model.alias)"
        if model.isActive { spoken += "（使用中）" }
        if soonest, let key = model.rows.first(where: \.isSortKey) {
            spoken += " · 每週重置最快（\(key.countdown.text(now: now))）"
        }
        if accessibilityLabel() != spoken { setAccessibilityLabel(spoken) }
    }

    // MARK: Layout

    /// The narrowest card that shows every line whole: the head (slot, up to 72 of the alias, the
    /// plan, the button), the health line, every reset line and the `who` line; the pace and the
    /// switch note wrap.
    func minimumWidth() -> CGFloat {
        let gap = Metrics.headGap
        var head = slot.intrinsicContentSize.width + gap + button.intrinsicContentSize.width
        if !alias.displayedText.isEmpty { head += min(alias.intrinsicContentSize.width, sz(72)) + gap }
        if !plan.isHidden { head += plan.intrinsicContentSize.width + gap }
        let healthLine = health.intrinsicContentSize.width + sz(6) + healthDot.intrinsicContentSize.width + sz(6)
            + source.intrinsicContentSize.width
        let whoLine = whoGlyph.intrinsicContentSize.width + sz(6) + whoText.intrinsicContentSize.width
        let rows = quotaRows.map(\.minimumWidth).max() ?? 0
        return ceil(Metrics.padX * 2 + max(head, healthLine, whoLine, rows))
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        arrange(width: width, height: nil)
    }

    @discardableResult
    private func arrange(width: CGFloat, height: CGFloat?) -> CGFloat {
        let apply = height != nil
        let x = Metrics.padX
        let inner = max(0, width - Metrics.padX * 2)
        if apply {
            let center = Metrics.padTop + Metrics.headHeight / 2
            let buttonSize = button.intrinsicContentSize
            let buttonWidth = min(buttonSize.width, inner)
            button.frame = CGRect(x: x + inner - buttonWidth, y: round(center - Metrics.headHeight / 2), width: buttonWidth,
                                  height: Metrics.headHeight)
            var items: [RowItem] = [RowItem(slot, .shrink, height: sz(19)), RowItem(alias, .shrink, height: sz(17))]
            if !plan.isHidden { items.append(RowItem(plan, .shrink)) }
            RowLayout.layout(items, in: CGRect(x: x, y: Metrics.padTop, width: max(0, button.frame.minX - Metrics.headGap - x),
                                               height: Metrics.headHeight), gap: Metrics.headGap)
            headRule.frame = CGRect(x: x, y: Metrics.headRuleY, width: inner, height: 1)
            layoutHealthLine()
        }
        var y = Metrics.healthY + Metrics.lineHeight
        if !note.isHidden {
            y += sz(4)
            let h = max(Metrics.lineHeight, note.height(forWidth: inner))
            if apply { note.frame = CGRect(x: x, y: y, width: inner, height: h) }
            y += h
        }
        let indent = quotaRows.map { $0.fittingIndent(width: inner) }.min() ?? QuotaBlockView.resetIndent
        for block in quotaRows {
            y += Metrics.gap
            if apply {
                block.indent = indent
                block.frame = CGRect(x: x, y: y, width: inner, height: QuotaBlockView.height)
            }
            y += QuotaBlockView.height
        }
        if !pace.isHidden {
            y += Metrics.gap
            let h = pace.height(forWidth: inner)
            if apply { pace.frame = CGRect(x: x, y: y, width: inner, height: h) }
            y += h
        }
        // `.sx-who{margin-top:auto; border-top:1px dashed}`: pinned to the bottom.
        let natural = y + sz(6) + Metrics.whoHeight + Metrics.padBottom
        if let height {
            let whoTop = max(y + sz(6), height - Metrics.padBottom - Metrics.whoHeight)
            whoRule.frame = CGRect(x: x, y: whoTop, width: inner, height: 1)
            RowLayout.layout([RowItem(whoGlyph), RowItem(whoText, .shrink)],
                             in: CGRect(x: x, y: whoTop + 1 + sz(5), width: inner, height: Metrics.lineHeight), gap: sz(6))
        }
        return ceil(natural)
    }

    /// `● ok · cswap cache · 3m 前` under the head's rule.
    private func layoutHealthLine() {
        RowLayout.layout([RowItem(health, .shrink), RowItem(healthDot), RowItem(source, .shrink)],
                         in: CGRect(x: Metrics.padX, y: Metrics.healthY, width: max(0, bounds.width - Metrics.padX * 2), height: Metrics.lineHeight),
                         gap: sz(6))
    }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, height: bounds.height)
    }

    var visibleTexts: [String] { statusVisibleTexts() }
    var quotaBlocks: [QuotaBlockView] { quotaRows }
    var noteText: String? { note.isHidden ? nil : note.displayedText }
}

/// One quota window of a card (`.sx-q`): the `.qrow` (CoddUI `QuotaBarRowView`, key 34 px) and
/// the `.sx-rs` line under it (`重置 13:19 … 2h37m後`, 42 px in unless the card is too narrow, the
/// sort key brighter). 31 tall.
final class QuotaBlockView: FlippedView {
    static var height: CGFloat { sz(31) }
    static var barHeight: CGFloat { sz(15) }
    /// The reset line starts under the bar (`.qrow .k` 34 + gap 8).
    static var resetIndent: CGFloat { sz(42) }

    let bar = QuotaBarRowView(QuotaBarRow(key: "", remainingPercent: nil))
    /// The reset line's indent: the card gives its rows one (``fittingIndent(width:)`` of the
    /// tightest row), so the lines stay aligned with each other.
    var indent: CGFloat = QuotaBlockView.resetIndent { didSet { if indent != oldValue { needsLayout = true } } }
    private let reset = TextLine(style: TextStyle.mono(10.5, Palette.dim))
    private let countdown = TextLine(style: TextStyle.mono(10.5, Palette.dimmer))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        countdown.alignRight = true
        // CoddUI's bar redraws only when its row changes: a resize must redraw it too.
        bar.layerContentsRedrawPolicy = .duringViewResize
        for view in [bar, reset, countdown] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ row: AccountQuotaRow, threshold: Double?, now: Date) {
        bar.row = QuotaBarRow(key: row.key, remainingPercent: row.remaining, tone: row.tone, threshold: threshold, keyWidth: 34)
        reset.set(row.reset, style: TextStyle.mono(10.5, row.isSortKey ? Palette.bone : Palette.dim))
        tick(row, now: now)
        needsLayout = true
    }

    func tick(_ row: AccountQuotaRow, now: Date) {
        let style = row.isSortKey ? TextStyle.mono(10.5, Palette.cream, .semibold) : TextStyle.mono(10.5, Palette.dimmer)
        if countdown.set(row.countdown.text(now: now), style: style) { needsLayout = true }
    }

    /// The reset line whole (its indent gives way first) and the bar's key, 40 of bar and value.
    var minimumWidth: CGFloat {
        max(reset.textWidth + sz(8) + countdown.textWidth, sz(34) + sz(8) + sz(40) + sz(8) + sz(34))
    }

    override func layout() {
        super.layout()
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        let countdownWidth = min(countdown.textWidth, bounds.width)
        let left = max(0, min(indent, bounds.width - countdownWidth))
        let lineY = Self.barHeight + sz(1)
        countdown.frame = CGRect(x: bounds.width - countdownWidth, y: lineY, width: countdownWidth, height: sz(15))
        reset.frame = CGRect(x: left, y: lineY, width: max(0, countdown.frame.minX - sz(8) - left), height: sz(15))
    }

    /// Under the bar when there is room; a narrow card moves the text left before cutting it.
    func fittingIndent(width: CGFloat) -> CGFloat {
        max(0, min(Self.resetIndent, width - reset.textWidth - sz(8) - countdown.textWidth))
    }

    var resetText: String { reset.displayedText }
    var countdownText: String { countdown.displayedText }
    /// The reset text is drawn whole (tests).
    var showsWholeReset: Bool { reset.frame.width + 0.5 >= reset.textWidth }
}

// MARK: - Add account

/// `+ 加入帳號` (`.sx-add`): dashed card, centered `+`, title and the cswap hint.
final class AddAccountCardView: HoverControl {
    static var minHeight: CGFloat { sz(120) }

    private let plus = TextLine("+", style: TextStyle(font: Typeface.display(20), color: Palette.amberDim))
    private let title = TextLine(AccountsSectionModel.addTitle, style: TextStyle.caps(11.5, Palette.bone, tracking: 0.14))
    private let hint = TextBlock(AccountsSectionModel.addHint, style: TextStyle.hint)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        plus.alignCenter = true
        title.alignCenter = true
        hint.alignCenter = true
        for view in [plus, title, hint] { addSubview(view) }
        setAccessibilityLabel("加入帳號")
        setAccessibilityHelp(AccountsSectionModel.addHint)
    }

    override func hoverChanged() {
        title.set(AccountsSectionModel.addTitle, style: TextStyle.caps(11.5, isHovered ? Palette.amber : Palette.bone, tracking: 0.14))
    }

    override func layout() {
        super.layout()
        let inner = max(0, bounds.width - sz(24))
        let hintHeight = hint.height(forWidth: inner)
        let total = sz(20) + sz(5) + sz(17.3) + sz(5) + hintHeight
        var y = max(0, round((bounds.height - total) / 2))
        plus.frame = CGRect(x: sz(12), y: y, width: inner, height: sz(20))
        y += sz(20) + sz(5)
        title.frame = CGRect(x: sz(12), y: y, width: inner, height: sz(17.3))
        y += sz(17.3) + sz(5)
        hint.frame = CGRect(x: sz(12), y: y, width: inner, height: min(hintHeight, max(0, bounds.height - y)))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.dashedRect(bounds, color: isHovered ? Palette.amberDim : Palette.lineBright)
        if isHighlighted { Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06)) }
    }
}

// MARK: - Install guide

/// FB 「引導安裝 cswap」 (`.sx-info` look: dashed line-bright box on --bg-soft): `INSTALL cswap ·
/// claude-swap` and the project link, the lead, `[uv tool install claude-swap] [複製] [在終端機執行]`,
/// the uv lines with their `[複製]`, the note and `[↻ 重新偵測]`. Command rows wrap at narrow widths.
final class CswapGuideView: FlippedView {
    private let title = TextLine(runs: [])
    private let link = TextLine(style: TextStyle.hint)
    private let lead = TextBlock(style: TextStyle.mono(12, Palette.bone), lineHeight: 1.45)
    private let uvHint = TextLine(CswapInstallGuide.uvHint, style: TextStyle.hint)
    private let note = TextBlock(CswapInstallGuide.note, style: TextStyle.comment, lineHeight: 1.45)
    let redetect = CoddButton(CswapInstallGuide.redetectTitle, style: .bracket(.normal, small: true))
    private(set) var rows: [(command: String, chip: ChipLabel, copy: CoddButton, run: CoddButton?)] = []
    private var holders: [ButtonAction] = []
    private var redetectHolder: ButtonAction?
    private(set) var guide: CswapInstallGuide?
    var onCopy: ((String) -> Void)?
    var onRun: ((String) -> Void)?
    var onRedetect: (() -> Void)?

    static var padding: NSEdgeInsets { NSEdgeInsets(top: sz(11), left: sz(14), bottom: sz(11), right: sz(14)) }
    static var rowHeight: CGFloat { sz(24) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        link.set(CswapInstallGuide.projectURL.replacingOccurrences(of: "https://", with: ""), style: TextStyle.hint)
        link.alignRight = true
        redetect.setAccessibilityLabel("重新偵測 cswap")
        redetectHolder = redetect.onPress { [weak self] in self?.onRedetect?() }
        for view: NSView in [title, link, lead, uvHint, note, redetect] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("安裝 cswap")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ guide: CswapInstallGuide) {
        guard guide != self.guide else { return }
        self.guide = guide
        title.set(attributed: TextRuns.joined([(guide.label, TextStyle.caps(10.5, Palette.amber, tracking: 0.16), 8),
                                              ("cswap · claude-swap", TextStyle.mono(11.5, Palette.cream), 0)]))
        lead.set(guide.lead)
        uvHint.isHidden = guide.uvCommands.isEmpty
        for row in rows {
            row.chip.removeFromSuperview()
            row.copy.removeFromSuperview()
            row.run?.removeFromSuperview()
        }
        holders = []
        rows = guide.commands.enumerated().map { index, command in
            let chip = ChipLabel(command, style: StatusChips.code)
            chip.toolTip = command
            let copy = CoddButton(CswapInstallGuide.copyTitle, style: .bracket(.normal, small: true))
            copy.setAccessibilityLabel("複製 \(command)")
            holders.append(copy.onPress { [weak self, weak copy] in
                self?.onCopy?(command)
                copy.map { Self.flashCopied($0) }
            })
            var run: CoddButton?
            if index == 0 {
                let button = CoddButton(CswapInstallGuide.runTitle, style: .bracket(.accent, small: true))
                button.setAccessibilityLabel("在終端機打好 \(command)（按 Return 才會執行）")
                holders.append(button.onPress { [weak self] in self?.onRun?(command) })
                run = button
            }
            for view in [chip, copy, run].compactMap({ $0 }) { addSubview(view) }
            return (command, chip, copy, run)
        }
        needsLayout = true
        needsDisplay = true
    }

    /// `[複製]` reads `[已複製]` for a moment.
    private static func flashCopied(_ button: CoddButton) {
        button.label = CswapInstallGuide.copiedTitle
        Task { @MainActor [weak button] in
            try? await Task.sleep(for: .seconds(1.5))
            button?.label = CswapInstallGuide.copyTitle
        }
    }

    func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        let pad = Self.padding
        let x = pad.left
        let inner = max(0, width - pad.left - pad.right)
        var y = pad.top
        let lineHeight = sz(17)
        if apply {
            // The link gives way first on a narrow box.
            let linkWidth = min(link.textWidth, max(0, inner - title.textWidth - sz(16)))
            link.isHidden = linkWidth < sz(60)
            link.frame = CGRect(x: x + inner - linkWidth, y: y, width: linkWidth, height: lineHeight)
            title.frame = CGRect(x: x, y: y, width: link.isHidden ? inner : max(0, link.frame.minX - sz(16) - x), height: lineHeight)
        }
        y += lineHeight + sz(6)
        let leadHeight = max(lineHeight, lead.height(forWidth: inner))
        if apply { lead.frame = CGRect(x: x, y: y, width: inner, height: leadHeight) }
        y += leadHeight + sz(6)
        for (index, row) in rows.enumerated() {
            if index == 1, !uvHint.isHidden {
                y += sz(4)
                if apply { uvHint.frame = CGRect(x: x, y: y, width: inner, height: lineHeight) }
                y += lineHeight + sz(4)
            }
            let views: [NSView] = [row.chip, row.copy] + (row.run.map { [$0] } ?? [])
            y += FlowLayout.layout(views, origin: CGPoint(x: x, y: y), width: inner, gap: sz(8), rowGap: sz(4),
                                   lineHeight: Self.rowHeight, apply: apply) + sz(4)
        }
        y += sz(4)
        let noteWidth = max(0, inner - redetect.intrinsicContentSize.width - sz(12))
        let noteHeight = max(lineHeight, note.height(forWidth: noteWidth))
        if apply {
            note.frame = CGRect(x: x, y: y, width: noteWidth, height: noteHeight)
            let size = redetect.intrinsicContentSize
            redetect.frame = CGRect(x: x + inner - min(size.width, inner), y: y + round((noteHeight - Self.rowHeight) / 2),
                                    width: min(size.width, inner), height: Self.rowHeight)
        }
        y += max(noteHeight, Self.rowHeight)
        return ceil(y + pad.bottom)
    }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, apply: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.dashedRect(bounds, color: Palette.lineBright)
    }

    var commandTexts: [String] { rows.map(\.command) }
    var runButton: CoddButton? { rows.first?.run }
    var copyButtons: [CoddButton] { rows.map(\.copy) }
    var texts: [String] { statusVisibleTexts() }
}

// MARK: - Auto-switch row

/// `.sx-auto`: switch · `AUTO-SWITCH 剩餘不足時自動切換` · `[OFF]` · rule chips (dim dashed while
/// OFF) · `[設定]`, then the note, the policy warning (FB, amber) and the cswap warning on their
/// own lines, 38 px in.
final class AutoSwitchRowView: FlippedView {
    let toggle = SwitchToggle(label: "剩餘不足時自動切換")
    private let label = TextLine(runs: [])
    private let state = ChipLabel("off", style: StatusChips.caps(.plain))
    private var chips: [ChipLabel] = []
    let settingsButton = CoddButton("設定", style: .bracket(.normal, small: true))
    private let note = TextBlock(style: TextStyle.comment)
    /// FB 「自動切換帳號加上警語」: always shown.
    private let policy = TextBlock(AutoSwitchModel.policyLine, style: TextStyle.mono(11.5, Palette.amber), lineHeight: 1.45)
    private let warning = TextBlock(style: TextStyle.mono(12, Palette.amber))
    private var actionHolders: [ButtonAction] = []
    private(set) var model: AutoSwitchModel?
    var onToggle: (() -> Void)?
    var onSettings: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        // `.sx-al small{margin-left:6px}`.
        label.set(attributed: TextRuns.joined([("Auto-switch", TextStyle.caps(10.5, Palette.bone, tracking: 0.16), 6),
                                              ("剩餘不足時自動切換", TextStyle.mono(11.5, Palette.cream, tracking: 0.04), 0)]))
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.setAccessibilityHelp(AutoSwitchModel.policyWarning)
        actionHolders.append(settingsButton.onPress { [weak self] in self?.onSettings?() })
        settingsButton.setAccessibilityLabel("自動切換設定")
        for view: NSView in [toggle, label, state, settingsButton, note, policy, warning] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("AUTO-SWITCH 自動切換")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func toggled() {
        // The app decides (it may open Settings instead, and ON asks first); the switch shows the
        // model's state.
        toggle.isOn = model?.on ?? false
        onToggle?()
    }

    func configure(_ model: AutoSwitchModel) {
        guard model != self.model else { return }
        self.model = model
        toggle.isOn = model.on
        state.set(model.on ? "on" : "off", style: StatusChips.caps(model.on ? .ok : .plain))
        if chips.count != model.chips.count {
            chips.forEach { $0.removeFromSuperview() }
            chips = model.chips.map { _ in ChipLabel("", style: StatusChips.plain) }
            for chip in chips { addSubview(chip, positioned: .below, relativeTo: settingsButton) }
        }
        for (view, text) in zip(chips, model.chips) { view.set(text, style: model.on ? StatusChips.plain : StatusChips.dimDashed) }
        note.set(model.note)
        warning.isHidden = model.warning == nil
        warning.set(model.warning ?? "")
        needsLayout = true
    }

    private var flowViews: [NSView] { [toggle, label, state] + chips + [settingsButton] }

    func preferredHeight(width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        // `padding:6px 12px; column-gap:8px; row-gap:4px`, item lines 22 px (the small button).
        let inner = max(0, width - sz(26))
        var y: CGFloat = sz(7)
        y += FlowLayout.layout(flowViews, origin: CGPoint(x: sz(13), y: y), width: inner, gap: 8, rowGap: 4, lineHeight: 22, apply: apply)
        let noteWidth = max(0, inner - sz(38))
        y += sz(4)
        let noteHeight = max(18, note.height(forWidth: noteWidth))
        if apply { note.frame = CGRect(x: sz(13) + sz(38), y: y, width: noteWidth, height: noteHeight) }
        y += noteHeight
        y += sz(4)
        let policyHeight = max(18, policy.height(forWidth: noteWidth))
        if apply { policy.frame = CGRect(x: sz(13) + sz(38), y: y, width: noteWidth, height: policyHeight) }
        y += policyHeight
        if !warning.isHidden {
            y += sz(4)
            let h = max(18, warning.height(forWidth: noteWidth))
            if apply { warning.frame = CGRect(x: sz(13) + sz(38), y: y, width: noteWidth, height: h) }
            y += h
        }
        return y + sz(7)
    }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, apply: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.line)
    }

    var chipTexts: [String] { chips.map(\.displayedText) }
    var chipStyleIsDashed: Bool { chips.first.map { $0.isDashed } ?? false }
    var policyText: String { policy.displayedText }
    var policyFrame: CGRect { policy.frame }
}

extension ChipLabel {
    /// Whether the chip draws a dashed border (the auto-switch rule while OFF).
    var isDashed: Bool { style.dashed }
}
