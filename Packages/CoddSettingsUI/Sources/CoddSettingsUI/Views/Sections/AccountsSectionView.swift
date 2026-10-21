import AppKit
import CoddPreferences
import CoddUI

/// 06 ACCOUNTS 帳號: cswap path + version chip, the locked `隱藏 email`, 切換前確認, the alias
/// rows (D34 rule, committed through `setAlias`; D1's `重新讀取` while cswap's state is
/// unavailable), the R8 auto-switch group with its live preview, the usage sources (D1 / D7) and
/// the D13 warning.
final class AccountsSectionView: SettingsSectionView {
    private(set) var cswapPath: SxTextInput?
    private let versionChip = ChipView("", style: .chip(.plain))
    private(set) var aliases: AccountAliasesView?
    private var aliasesHead: SxGroupHead?
    private var autoHead: SxGroupHead?
    private var previewHead: SxGroupHead?
    private(set) var thresholdStepper: SxStepper?
    private(set) var fiveHourBox: SxCheckbox?
    private(set) var weeklyBox: SxCheckbox?
    private(set) var cooldown: SxTextInput?
    private(set) var previewCard: AutoSwitchPreviewView?
    private let previewOff = SxInfoBox()
    private let usageBox = SxInfoBox()
    private let warning = SxLabel("", style: TextStyle.mono(11.5, Palette.amber))
    private var tightRows: [SxRow] = []
    private var noneLeftRow: SxRow?
    /// FB: the cswap install / upgrade guide (shown while cswap is missing or too old).
    private(set) var guideGroup: NSStackView?
    private let guideBox = SxInfoBox()
    private var guideHead: SxGroupHead?
    private(set) var shownGuide: SettingsCswapGuide?
    private(set) var guideButtons: [CoddButton] = []
    private(set) var autoSwitchRow: SxRow?

    override func build() {
        let addButton = button("+ 加入帳號") { [weak self] in self?.actions.addAccount() }
        add(pageHead(lead: SxRich("cswap 管理的 Claude 帳號。介面只顯示 #編號 與別名，不顯示 email。"), actions: [addButton]))

        let path = SxTextInput(value: model.preferences.accounts.cswapPath ?? "", placeholder: model.info.cswap.defaultPath, width: 220,
                               accessibilityLabel: "cswap 路徑")
        path.onCommit = { [weak self] typed in
            let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.edit { $0.accounts.cswapPath = value.isEmpty ? nil : value }
            return .accept(value)
        }
        bind { [weak path] prefs, info in
            path?.setValue(prefs.accounts.cswapPath ?? "")
            path?.input.field.placeholderAttributedString = TextStyle.mono(12.5, Palette.dimmer).string(info.cswap.defaultPath)
        }
        registerControl("accounts.cswapPath", path)
        cswapPath = path
        bind { [weak self] _, info in self?.updateVersionChip(info.cswap) }
        let pathRow = row("accounts.cswapPath", "cswap 路徑", en: "cswap path", hint: "需 ≥ 0.26；切換帳號與用量快取都透過它。",
                          controls: [path, versionChip])
        let email = row("accounts.hideEmail", "隱藏 email", en: "Hide email", hint: "截圖、錄影或分享畫面時不會露出信箱。",
                        controls: [faint("CODD 永遠不顯示 email"), lockedToggle("accounts.hideEmail", label: "隱藏 email")])
        let confirm = row("accounts.confirmBeforeSwitch", "切換前確認", en: "Confirm before switching", hint: "關閉時，點帳號就直接切換，完成後可 UNDO。",
                          controls: [toggle("accounts.confirmBeforeSwitch", label: "切換前確認", get: { $0.accounts.confirmBeforeSwitch },
                                            set: { $0.accounts.confirmBeforeSwitch = $1 })])
        add(sxGroup(groupHead("cswap"), [SxCard([pathRow, email, confirm])]))
        add(cswapGuideGroup())

        let aliasHead = groupHead("Aliases", cjk: "帳號別名", right: "依每週重置排序 · 越快重置越上面")
        aliasesHead = aliasHead
        let aliasCard = AccountAliasesView()
        aliasCard.onCommit = { [weak self] id, typed in self?.commitAlias(id: id, typed: typed) ?? .revert }
        let reread = button("重新讀取", accessibilityLabel: "重新讀取 cswap 狀態") { [weak self] in self?.actions.rereadAccounts() }
        registerControl("accounts.reread", reread)
        aliasCard.rereadButton = reread
        aliases = aliasCard
        bind { [weak aliasCard, weak aliasHead] prefs, info in
            aliasHead?.count = "\(info.accounts.count)"
            let auto = prefs.accounts.autoSwitch
            aliasCard?.update(rows: info.accounts, aliasHint: info.aliasRuleHint,
                              threshold: auto.enabled ? Double(auto.thresholdPercent) : nil,
                              tickFiveHour: auto.enabled && auto.checkFiveHour, tickWeekly: auto.enabled && auto.checkWeekly,
                              unavailable: info.accountsUnavailable)
        }
        add(sxGroup(aliasHead, [aliasCard]))

        let left = sxGroup(autoSwitchHead(), [SxCard(autoSwitchRows())])
        let right = columnStack([previewGroup(), usageGroup()], spacing: 20)
        let columns = TwoColumnView(left: columnStack([left], spacing: 20), right: right)
        add(columns)
        warning.isHidden = true
        add(warning)
        bind { [weak self] _, info in
            guard let self else { return }
            let text = info.cswap.warning
            self.warning.isHidden = text == nil
            self.warning.set(SxRich(text ?? "").attributed(TextStyle.mono(11.5, Palette.amber), lineHeight: 17))
        }
    }

    // MARK: cswap

    private func updateVersionChip(_ cswap: SettingsCswapInfo) {
        let text: String
        let kind: ChipKind
        if cswap.locating {
            text = "◌ 偵測中…"
            kind = .plain
        } else if !cswap.pathOK {
            text = "▲ 找不到"
            kind = .bad
        } else if let version = cswap.version {
            text = cswap.versionOK ? "● v\(version)" : "▲ 需 ≥ 0.26"
            kind = cswap.versionOK ? .ok : .bad
        } else {
            text = "○ 版本未知"
            kind = .plain
        }
        versionChip.set(text, style: .chip(kind))
        versionChip.setAccessibilityLabel("cswap \(text)")
    }

    var versionChipText: String { versionChip.accessibilityLabel()?.replacingOccurrences(of: "cswap ", with: "") ?? "" }

    // MARK: Aliases

    /// D34: cswap's rule; an invalid alias is not sent (the row shows the hint), a valid one is
    /// sent lowercased and shown that way; an empty field unsets the alias.
    func commitAlias(id: String, typed: String) -> SxTextInput.Verdict {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let account = model.info.accounts.first(where: { $0.id == id }), account.canEditAlias else { return .revert }
        if trimmed.isEmpty {
            guard !account.alias.isEmpty else { return .revert }
            actions.setAlias(id, nil)
            return .accept("")
        }
        guard let alias = AliasRule.normalize(trimmed) else { return .reject }
        if alias != account.alias { actions.setAlias(id, alias) }
        return .accept(alias)
    }

    // MARK: Auto-switch

    private func autoSwitchHead() -> SxGroupHead {
        let head = groupHead("Auto-switch", cjk: "自動切換")
        autoHead = head
        bind { [weak head] prefs, _ in
            let auto = prefs.accounts.autoSwitch
            head?.setRight(auto.enabled ? "ON · 冷卻 \(auto.cooldownSeconds) s" : "OFF · 需手動開啟")
        }
        return head
    }

    private func autoSwitchRows() -> [NSView] {
        let enable = row("accounts.autoSwitch.enabled", "剩餘不足時自動切換", en: "Auto-switch",
                         hint: "由 CODD 依 statusline 與 cswap 快取判斷，以 cswap switch 切換（不另外查詢用量）· 已有 cswap menubar / auto 在跑時會提醒",
                         controls: [autoSwitchToggle()], keywords: ["使用條款", "風險", "警告"])
        // FB 「自動切換帳號加上警語」: always under the switch, in the amber of the other warnings.
        enable.setNote("policy", "! " + SettingsAutoSwitchRisk.warning)
        autoSwitchRow = enable
        let stepper = SxStepper(minus: "−", plus: "+", value: "\(model.preferences.accounts.autoSwitch.thresholdPercent) %",
                                accessibilityLabel: "自動切換門檻")
        stepper.onStep = { [weak self] delta in
            let range = CoddPreferences.AutoSwitch.thresholdRange
            self?.edit { $0.accounts.autoSwitch.thresholdPercent = min(range.upperBound, max(range.lowerBound, $0.accounts.autoSwitch.thresholdPercent + delta)) }
        }
        bind { [weak stepper] prefs, _ in stepper?.value = "\(prefs.accounts.autoSwitch.thresholdPercent) %" }
        registerControl("accounts.autoSwitch.thresholdPercent", stepper)
        thresholdStepper = stepper
        let threshold = row("accounts.autoSwitch.thresholdPercent", "門檻", en: "Threshold", hint: "1–20%，預設 2%",
                            controls: [faint("剩餘 ≤"), stepper], tight: true)
        let five = SxCheckbox(title: "5 小時")
        let week = SxCheckbox(title: "每週")
        five.onToggle = { [weak self] on in self?.edit { $0.accounts.autoSwitch.checkFiveHour = on } }
        week.onToggle = { [weak self] on in self?.edit { $0.accounts.autoSwitch.checkWeekly = on } }
        bind { [weak five, weak week] prefs, _ in
            five?.isOn = prefs.accounts.autoSwitch.checkFiveHour
            week?.isOn = prefs.accounts.autoSwitch.checkWeekly
        }
        registerControl("accounts.autoSwitch.checkFiveHour", five)
        registerControl("accounts.autoSwitch.checkWeekly", week)
        fiveHourBox = five
        weeklyBox = week
        let windows = row("accounts.autoSwitch.windows", "檢查", en: "Windows", hint: "任一個 ≤ 門檻就切換", controls: [five, week], tight: true,
                          keywords: ["5 小時", "每週"])
        let target = row("accounts.autoSwitch.target", "切換到", en: "Target", hint: "5h 與每週都高於門檻才算足夠",
                         controls: [chip("依排序第一個額度足夠的帳號")], tight: true)
        let cooldown = SxTextInput(value: "\(model.preferences.accounts.autoSwitch.cooldownSeconds)", width: 72, alignment: .right,
                                   accessibilityLabel: "自動切換冷卻秒數")
        cooldown.filter = DigitsField.filter
        cooldown.onCommit = { [weak self] typed in
            guard let value = DigitsField.commit(typed, range: CoddPreferences.AutoSwitch.cooldownRange) else { return .revert }
            self?.edit { $0.accounts.autoSwitch.cooldownSeconds = value }
            return .accept("\(value)")
        }
        bind { [weak cooldown] prefs, _ in cooldown?.setValue("\(prefs.accounts.autoSwitch.cooldownSeconds)") }
        registerControl("accounts.autoSwitch.cooldownSeconds", cooldown)
        self.cooldown = cooldown
        let cooldownRow = row("accounts.autoSwitch.cooldownSeconds", "冷卻", en: "Cooldown", hint: "兩次自動切換至少間隔",
                              controls: [cooldown, faint("s")], tight: true)
        let noneLeft = row("accounts.autoSwitch.noneLeft", "都不足時", en: "None left", hint: "通知「所有帳號都低於 2%」",
                           controls: [chip("不切換，通知我")], tight: true)
        noneLeftRow = noneLeft
        tightRows = [threshold, windows, target, cooldownRow, noneLeft]
        bind { [weak self] prefs, _ in
            guard let self else { return }
            let auto = prefs.accounts.autoSwitch
            for row in self.tightRows { row.alphaValue = auto.enabled ? 1 : 0.55 }
            self.noneLeftRow?.setHint(SxRich("通知「所有帳號都低於 \(auto.thresholdPercent)%」"))
        }
        return [enable] + tightRows
    }

    /// `.sw` for 剩餘不足時自動切換: OFF → ON asks first (``SettingsActions/confirmAutoSwitch``) and
    /// stays OFF unless confirmed; ON → OFF does not ask.
    private func autoSwitchToggle() -> SwitchToggle {
        let control = SwitchToggle(label: "剩餘不足時自動切換")
        control.setAccessibilityHelp(SettingsAutoSwitchRisk.warning)
        let handler = makeTarget { [weak self, weak control] in
            guard let self, let control else { return }
            guard control.isOn else {
                self.edit { $0.accounts.autoSwitch.enabled = false }
                return
            }
            control.isOn = false
            self.actions.confirmAutoSwitch(self.window) { [weak self, weak control] confirmed in
                guard confirmed, let self else { return }
                self.edit { $0.accounts.autoSwitch.enabled = true }
                control?.isOn = self.model.preferences.accounts.autoSwitch.enabled
            }
        }
        control.target = handler
        control.action = #selector(ClosureTarget.fire(_:))
        bind { [weak control] prefs, _ in control?.isOn = prefs.accounts.autoSwitch.enabled }
        registerControl("accounts.autoSwitch.enabled", control)
        return control
    }

    // MARK: cswap guide (FB)

    /// `INSTALL 安裝 cswap ┄┄ github.com/realiti4/claude-swap` and the `.sx-info` box: the lead, each
    /// command with `複製` (the first also `在終端機執行`), the uv hint, the note and `重新偵測`.
    private func cswapGuideGroup() -> NSStackView {
        let head = groupHead("Install", cjk: "安裝 cswap", right: SettingsCswapGuide.projectURL.replacingOccurrences(of: "https://", with: ""))
        guideHead = head
        let group = sxGroup(head, [guideBox])
        group.isHidden = true
        guideGroup = group
        sectionSearchText += " 安裝 cswap claude-swap uv"
        bind { [weak self] _, info in self?.updateGuide(SettingsCswapGuide.make(info.cswap)) }
        return group
    }

    private func updateGuide(_ guide: SettingsCswapGuide?) {
        guideGroup?.isHidden = guide == nil
        guard guide != shownGuide else { return }
        shownGuide = guide
        guideHead?.title = guide?.kind == .upgrade ? "Upgrade" : "Install"
        guideHead?.cjk = guide?.kind == .upgrade ? "更新 cswap" : "安裝 cswap"
        releaseTargets("cswapGuide")
        guideButtons = []
        guard let guide else {
            guideBox.set([])
            return
        }
        var lines: [NSView] = [SxLabel(guide.lead, style: TextStyle.mono(12, Palette.bone), lineHeight: 18)]
        for (index, command) in guide.commands.enumerated() {
            if index == 1 { lines.append(SxLabel(SettingsCswapGuide.uvHint, style: TextStyle.mono(11.5, Palette.dim), wraps: false)) }
            let chip = ChipView(command, style: .code)
            chip.truncates = true
            chip.toolTip = command
            chip.setAccessibilityLabel(command)
            let copy = button("複製", accessibilityLabel: "複製 \(command)", group: "cswapGuide") { [weak self] in self?.actions.copyText(command) }
            var items: [NSView] = [chip, copy]
            guideButtons.append(copy)
            if index == 0 {
                let run = button("在終端機執行", variant: .accent, accessibilityLabel: "在終端機打好 \(command)（按 Return 才會執行）",
                                 group: "cswapGuide") { [weak self] in self?.actions.openInstallTerminal(command) }
                items.append(run)
                guideButtons.append(run)
            }
            let flow = SxFlowView(items)
            flow.gap = 8
            lines.append(flow)
        }
        let redetect = button("↻ 重新偵測", accessibilityLabel: "重新偵測 cswap", group: "cswapGuide") { [weak self] in
            self?.actions.rereadAccounts()
        }
        guideButtons.append(redetect)
        let note = SxLabel("// " + SettingsCswapGuide.note, style: TextStyle.comment, lineHeight: 17)
        lines.append(hStack([note, redetect], spacing: 12))
        guideBox.set(lines)
    }

    /// The guide's texts as shown (tests).
    var guideTexts: [String] { guideBox.lineTexts }

    private func previewGroup() -> NSStackView {
        let head = groupHead("Preview", cjk: "即時預覽")
        previewHead = head
        let card = AutoSwitchPreviewView()
        previewCard = card
        previewOff.set([
            SxLabel("// 自動切換未開啟", style: TextStyle.comment, wraps: false),
            SxLabel("開啟後這裡即時列出各帳號（依每週重置排序）距切換還有多少 %，以及下一個會切到誰。", style: TextStyle.mono(11.5, Palette.dim),
                    lineHeight: 17),
        ])
        sectionSearchText += " 自動切換未開啟 距切換 下一個"
        bind { [weak self, weak head, weak card] prefs, _ in
            guard let self else { return }
            let auto = prefs.accounts.autoSwitch
            let windows = auto.checkFiveHour && auto.checkWeekly ? "5h / 1w" : (auto.checkFiveHour ? "5h" : (auto.checkWeekly ? "1w" : "未選視窗"))
            head?.setRight("剩餘 ≤ \(auto.thresholdPercent)% · \(windows) · 依排序")
            card?.isHidden = !auto.enabled
            self.previewOff.isHidden = auto.enabled
            card?.update(self.model.autoSwitchPreview, threshold: Double(auto.thresholdPercent))
        }
        return sxGroup(head, [card, previewOff])
    }

    private func usageGroup() -> NSStackView {
        bind { [weak self] _, info in self?.updateUsage(info.usageSources) }
        return sxGroup(groupHead("Usage source", cjk: "用量來源"), [usageBox])
    }

    private func updateUsage(_ sources: [SettingsUsageSource]) {
        var lines: [NSView] = sources.map { source in
            let live = source.glyph == "●"
            let text = SxRich([.color(source.glyph, live ? Palette.success : Palette.dimmer), .text("  "),
                               .color(source.accounts, live ? Palette.amber : Palette.cyan), .text("  \(source.source)  "),
                               .color("· \(source.age)", Palette.dimmer)])
            return SxLabel(text.attributed(TextStyle.mono(11.5, Palette.dim), lineBreak: .byTruncatingTail), wraps: false)
        }
        if sources.isEmpty { lines.append(SxLabel("○  尚無用量資料", style: TextStyle.mono(11.5, Palette.dimmer), wraps: false)) }
        lines.append(SxLabel("// 不另外呼叫 usage API，避免被 429 擋下", style: TextStyle.comment, wraps: false))
        usageBox.set(lines)
    }

    override var dynamicSearchables: [SxSearchable] { aliases?.rowViews ?? [] }

    var usageLines: [String] { usageBox.lineTexts }
    var warningText: String? { warning.isHidden ? nil : warning.text }
    var isPreviewShown: Bool { !(previewCard?.isHidden ?? true) }
}

/// `.sx-acol`: two equal columns 16 apart, top aligned; narrower than `stackWidth` (a small window
/// at a large interface zoom) the right column goes under the left one.
final class TwoColumnView: FlippedView {
    private var sideBySide: [NSLayoutConstraint] = []
    private var stacked: [NSLayoutConstraint] = []
    private(set) var isStacked = false
    /// Design points (read at the zoom).
    static let stackWidth: CGFloat = 520

    init(left: NSView, right: NSView, gap: CGFloat = 16) {
        super.init(frame: .zero)
        for view in [left, right] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor),
            left.topAnchor.constraint(equalTo: topAnchor),
            left.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            right.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Below the window's stay-put priority (500): two columns that cannot fit side by side
        // never hold the window wide; `setFrameSize` stacks them instead.
        let between = right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: xz(gap))
        let equal = right.widthAnchor.constraint(equalTo: left.widthAnchor)
        for constraint in [between, equal] { constraint.priority = .init(490) }
        sideBySide = [right.topAnchor.constraint(equalTo: topAnchor), between, equal]
        stacked = [
            left.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.leadingAnchor.constraint(equalTo: leadingAnchor),
            right.topAnchor.constraint(equalTo: left.bottomAnchor, constant: xz(gap)),
        ]
        NSLayoutConstraint.activate(sideBySide)
        // As tall as the taller column; the shorter one keeps its own height (`align-items:start`).
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow
        hug.isActive = true
        for view in [left, right] { view.setContentHuggingPriority(.required, for: .vertical) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let stack = newSize.width > 0 && newSize.width < xz(Self.stackWidth)
        guard stack != isStacked else { return }
        isStacked = stack
        NSLayoutConstraint.deactivate(stack ? sideBySide : stacked)
        NSLayoutConstraint.activate(stack ? stacked : sideBySide)
    }
}

/// A `.qrow` drawn with a value text override (`未開始`) and the R8 threshold tick.
@MainActor
enum SxQuota {
    static func draw(key: String, quota: SettingsQuota, threshold: Double?, in rect: CGRect, fontSize: CGFloat = 11,
                     keyWidth designKey: CGFloat = 22, valueWidth designValue: CGFloat = 34, gap designGap: CGFloat = 8) {
        // Design widths, laid out at the interface zoom.
        let keyWidth = xz(designKey), valueWidth = xz(designValue), gap = xz(designGap)
        Draw.text(TextStyle.mono(fontSize, Palette.dim).string(key), x: rect.minX, centerY: rect.midY, maxWidth: keyWidth)
        let muted = quota.text != nil && quota.tone == .muted
        let value = TextStyle.mono(fontSize, muted ? Palette.dimmer : quota.tone.color).string(quota.valueText)
        Draw.text(value, x: rect.maxX - Draw.width(value), centerY: rect.midY)
        let barX = rect.minX + keyWidth + gap
        let bar = CGRect(x: barX, y: round(rect.midY - xz(3.5)), width: max(xz(20), rect.maxX - valueWidth - gap - barX), height: xz(7))
        QuotaBarRowRenderer.drawBar(in: bar, remaining: quota.remaining, color: quota.tone.color, threshold: threshold)
    }
}

/// `.sx-card` of `.sx-arow`s: grid 34 | 120 | 70 | 120 | 120 | 112 | 1fr (gap 14, padding 8 / 16)
/// shared by every row so the columns line up. When the window is too narrow for the sessions
/// text, it moves to a second line under the reset column (the 1040 pt Settings window).
final class AccountAliasesView: FlippedView {
    var onCommit: ((String, String) -> SxTextInput.Verdict)?
    private(set) var rowViews: [AccountAliasRowView] = []
    /// Wraps: D1's copy ends with what `重新讀取` costs (`會查詢一次用量`), which a one-line notice
    /// cut off at the 860–1040 pt window widths (M3 review).
    private let empty = SxLabel("// 尚未讀到 cswap 帳號", style: TextStyle.comment, wraps: true)
    /// `重新讀取`, at the right of the notice while cswap's state is unavailable (set by the section).
    var rereadButton: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let rereadButton {
                rereadButton.translatesAutoresizingMaskIntoConstraints = true
                rereadButton.isHidden = unavailable == nil
                addSubview(rereadButton)
            }
            needsLayout = true
        }
    }
    private var rows: [SettingsAccountRow] = []
    private(set) var unavailable: String?
    private var laidOutWidth: CGFloat = -1
    private var noticeTop: CGFloat = 0
    /// The notice band's height for one line; more lines add their height.
    static var noticeHeight: CGFloat { xz(46) }

    /// The notice text's width in a card `width` wide (the reread button takes the right end).
    private func noticeLabelWidth(_ width: CGFloat) -> CGFloat {
        var right = width - xz(17)
        if let button = rereadButton, !button.isHidden { right -= button.intrinsicContentSize.width + 16 }
        return max(40, right - 17)
    }

    /// The band's height for the notice wrapped to `width`: at least ``noticeHeight``.
    func noticeBandHeight(width: CGFloat) -> CGFloat {
        let text = textHeight(width: noticeLabelWidth(width))
        let oneLine = textHeight(width: .greatestFiniteMagnitude)
        return Self.noticeHeight + max(0, text - oneLine)
    }

    private func textHeight(width: CGFloat) -> CGFloat {
        ceil(empty.cell?.cellSize(forBounds: CGRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 18)
    }

    /// The notice band (no accounts yet, or D1's unavailable copy) under the rows, if shown.
    private var showsNotice: Bool { rows.isEmpty || unavailable != nil }
    var noticeText: String? { showsNotice ? empty.text : nil }

    /// D1's unavailable copy, with `重新讀取` in place of STATUS's `↻ 立即更新`.
    static func unavailableNotice(_ reason: String) -> String {
        "// 讀不到 cswap 狀態：\(reason) · 按 重新讀取 改用 cswap list（會查詢一次用量）"
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        empty.translatesAutoresizingMaskIntoConstraints = true
        addSubview(empty)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(rows: [SettingsAccountRow], aliasHint: String, threshold: Double?, tickFiveHour: Bool, tickWeekly: Bool,
                unavailable: String? = nil) {
        self.unavailable = unavailable
        let notice = unavailable.map(Self.unavailableNotice) ?? "// 尚未讀到 cswap 帳號"
        empty.set(SxRich(notice).attributed(TextStyle.comment, lineBreak: .byWordWrapping))
        empty.setAccessibilityLabel(notice)
        rereadButton?.isHidden = unavailable == nil
        if rows.map(\.id) != self.rows.map(\.id) {
            for view in rowViews { view.removeFromSuperview() }
            rowViews = rows.map { row in
                let view = AccountAliasRowView(accountID: row.id)
                view.onCommit = { [weak self] id, typed in self?.onCommit?(id, typed) ?? .revert }
                addSubview(view)
                return view
            }
        }
        self.rows = rows
        for (view, row) in zip(rowViews, rows) {
            view.update(row, aliasHint: aliasHint, threshold: threshold, tickFiveHour: tickFiveHour, tickWeekly: tickWeekly)
        }
        empty.isHidden = !showsNotice
        laidOutWidth = -1
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    /// Column origins for `width` and whether the sessions text needs its own line.
    func columns(width: CGFloat) -> AccountAliasRowView.Columns {
        let sessions = rowViews.map(\.sessionsWidth).max() ?? 0
        return AccountAliasRowView.Columns.make(width: width, sessions: sessions)
    }

    override var intrinsicContentSize: NSSize {
        let width = laidOutWidth > 0 ? laidOutWidth : xz(880)
        let notice = showsNotice ? noticeBandHeight(width: width) : 0
        guard !rows.isEmpty else { return NSSize(width: NSView.noIntrinsicMetric, height: notice) }
        let columns = columns(width: width)
        return NSSize(width: NSView.noIntrinsicMetric, height: rowViews.reduce(2) { $0 + $1.height(columns) } + notice)
    }

    override func layout() {
        super.layout()
        let columns = columns(width: bounds.width)
        var y: CGFloat = 1
        for (index, view) in rowViews.enumerated() {
            let height = view.height(columns)
            view.frame = CGRect(x: 1, y: y, width: max(0, bounds.width - 2), height: height)
            view.showsSeparator = index > 0
            view.apply(columns)
            y += height
        }
        // The notice band: alone in an empty card, else after the rows (dashed rule above).
        let top = rows.isEmpty ? 0 : y
        if top != noticeTop {
            noticeTop = top
            needsDisplay = true
        }
        let band = noticeBandHeight(width: bounds.width)
        if let button = rereadButton, !button.isHidden {
            let size = button.intrinsicContentSize
            button.frame = CGRect(x: bounds.width - xz(17) - size.width, y: top + round((band - size.height) / 2),
                                  width: size.width, height: size.height)
        }
        let labelWidth = noticeLabelWidth(bounds.width)
        empty.preferredMaxLayoutWidth = labelWidth
        let emptyHeight = textHeight(width: labelWidth)
        empty.frame = CGRect(x: xz(17), y: top + round((band - emptyHeight) / 2), width: labelWidth, height: emptyHeight)
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        if showsNotice, !rows.isEmpty {
            Draw.dashedLine(from: CGPoint(x: 1, y: noticeTop), to: CGPoint(x: bounds.width - 1, y: noticeTop), color: Palette.lineBright)
        }
    }
}

/// One `.sx-arow`: slot, alias input, plan chip, 5h and 1w quota rows (threshold ticks while
/// auto-switch is ON), the 1w reset (the sort key) and the sessions text (`✓ ACTIVE` chip).
final class AccountAliasRowView: FlippedView, SxSearchable, SxSeparated, SxTitled {
    struct Columns: Equatable {
        var quotaWidth: CGFloat
        var sessionsOnSecondLine: Bool
        var width: CGFloat
        /// A narrow card (a small window at zoom 20): the quota rows and the reset go to a second
        /// line under the alias, the sessions text stays on the first line after the plan.
        var quotasOnSecondLine = false

        /// The columns for a card `width` wide whose widest sessions text is `sessions` (at the
        /// interface zoom): one line (quotas 96…120), the sessions text on a second line (quotas
        /// 96…120 too), or the quotas and the reset on a second line (60…120).
        static func make(width: CGFloat, sessions: CGFloat) -> Columns {
            let inner = width - xz(32)
            let gap = xz(14)
            let fixed = xz(34) + xz(120) + xz(70) + xz(112) + gap * 4
            // Single line: 2 quota columns (96…120) + the sessions text + their 3 gaps.
            let single = (inner - fixed - sessions - gap * 2) / 2
            if single >= xz(96) {
                return Columns(quotaWidth: min(xz(120), single), sessionsOnSecondLine: false, width: width)
            }
            // A quota row under 96 draws its value over its bar (5h + 98% + gaps take 72): the
            // quotas then go to the second line instead (the 860 pt window at UI 字級 13 too).
            let wrapped = (inner - fixed - gap) / 2
            if wrapped >= xz(96) {
                return Columns(quotaWidth: min(xz(120), wrapped), sessionsOnSecondLine: true, width: width)
            }
            // Second line, from the alias column: 5h, 1w, the reset.
            let second = (inner - xz(34) - gap - xz(112) - gap * 2) / 2
            return Columns(quotaWidth: min(xz(120), max(xz(60), second)), sessionsOnSecondLine: false, width: width,
                           quotasOnSecondLine: true)
        }
    }

    let accountID: String
    let aliasInput: SxTextInput
    var onCommit: ((String, String) -> SxTextInput.Verdict)?
    var isSearchHit = false { didSet { if isSearchHit != oldValue { needsDisplay = true } } }
    var showsSeparator = false { didSet { if showsSeparator != oldValue { needsDisplay = true } } }
    private(set) var row: SettingsAccountRow?
    private var aliasHint = AliasRule.hint
    private var threshold: Double?
    private var tickFiveHour = false
    private var tickWeekly = false
    private var columns = Columns(quotaWidth: xz(120), sessionsOnSecondLine: false, width: 0)
    private let activeChip = ChipView("✓ Active", style: .chip(.fill, caps: true, mini: true))
    private let planChip = ChipView("", style: .chip(.plain, caps: true, mini: true))

    var title: String { row.map { "\($0.slot) \($0.alias)" } ?? accountID }
    var searchText: String { row.map { "\($0.slot) \($0.alias) \($0.plan ?? "") \($0.sessions) 帳號別名 alias" } ?? "" }
    /// The inline D34 hint is showing.
    var showsAliasHint: Bool { aliasInput.isInvalid }

    init(accountID: String) {
        self.accountID = accountID
        aliasInput = SxTextInput(value: "", width: 120, accessibilityLabel: "#\(accountID) 帳號別名")
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for view in [aliasInput, planChip, activeChip] as [NSView] { addSubview(view) }
        aliasInput.onCommit = { [weak self] typed in
            guard let self else { return .revert }
            return self.onCommit?(self.accountID, typed) ?? .revert
        }
        aliasInput.onValidity = { [weak self] _ in
            self?.needsDisplay = true
            self?.superview?.invalidateIntrinsicContentSize()
            self?.superview?.needsLayout = true
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ row: SettingsAccountRow, aliasHint: String, threshold: Double?, tickFiveHour: Bool, tickWeekly: Bool) {
        self.row = row
        self.aliasHint = aliasHint
        self.threshold = threshold
        self.tickFiveHour = tickFiveHour
        self.tickWeekly = tickWeekly
        aliasInput.setValue(row.alias)
        aliasInput.isEnabled = row.canEditAlias
        aliasInput.alphaValue = row.canEditAlias ? 1 : 0.55
        aliasInput.input.field.setAccessibilityLabel("\(row.slot) 帳號別名")
        planChip.set(row.plan ?? "")
        planChip.isHidden = row.plan == nil
        activeChip.isHidden = !row.isActive
        needsDisplay = true
    }

    private var sessionsText: NSAttributedString { TextStyle.mono(11, Palette.dim).string(row?.sessions ?? "") }

    /// The sessions text's drawn width: whole, or cut (`…`) to leave the `✓ ACTIVE` chip its room
    /// in a narrow card.
    private var shownSessionsWidth: CGFloat {
        let left = columns.sessionsOnSecondLine ? xs.reset : xs.sessions
        let chip = row?.isActive == true ? activeChip.intrinsicContentSize.width + xz(8) : 0
        return min(Draw.width(sessionsText), max(0, bounds.width - xz(15) - left - chip))
    }

    /// The sessions column's natural width (chip included).
    var sessionsWidth: CGFloat {
        Draw.width(sessionsText) + (row?.isActive == true ? activeChip.intrinsicContentSize.width + xz(8) : 0)
    }

    func height(_ columns: Columns) -> CGFloat {
        var height: CGFloat = xz(46)
        if columns.sessionsOnSecondLine { height += xz(16) }
        if columns.quotasOnSecondLine { height += xz(30) }
        if aliasInput.isInvalid { height += xz(18) }
        return height
    }

    /// x origins of the columns.
    private var xs: (slot: CGFloat, alias: CGFloat, plan: CGFloat, five: CGFloat, week: CGFloat, reset: CGFloat, sessions: CGFloat) {
        let gap = xz(14)
        let slot: CGFloat = xz(15)
        let alias = slot + xz(34) + gap
        let plan = alias + xz(120) + gap
        let five = columns.quotasOnSecondLine ? alias : plan + xz(70) + gap
        let week = five + columns.quotaWidth + gap
        let reset = week + columns.quotaWidth + gap
        let sessions = columns.quotasOnSecondLine ? plan + xz(70) + gap : reset + xz(112) + gap
        return (slot, alias, plan, five, week, reset, sessions)
    }

    /// The vertical center of the quotas and the reset: the first line, or the second one.
    private var quotaLine: CGFloat { columns.quotasOnSecondLine ? xz(46) + xz(12) : xz(23) }

    func apply(_ columns: Columns) {
        self.columns = columns
        let x = xs
        let line = xz(23)
        aliasInput.frame = CGRect(x: x.alias, y: line - xz(15), width: xz(120), height: xz(30))
        let plan = planChip.intrinsicContentSize
        planChip.frame = CGRect(x: x.plan, y: round(line - plan.height / 2), width: plan.width, height: plan.height)
        let chip = activeChip.intrinsicContentSize
        let sessionsY = columns.sessionsOnSecondLine ? xz(46) + xz(4) : line
        let textWidth = shownSessionsWidth
        activeChip.frame = CGRect(x: bounds.width - xz(15) - textWidth - xz(8) - chip.width, y: round(sessionsY - chip.height / 2),
                                  width: chip.width, height: chip.height)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let row else { return }
        if row.isActive {
            Draw.fill(bounds, Palette.bgLift)
            Draw.fill(CGRect(x: 0, y: 0, width: xz(2), height: bounds.height), Palette.amber)
        }
        if isSearchHit {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06))
            Draw.strokeRect(bounds, color: Palette.amberDim)
        }
        if showsSeparator { Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.lineBright) }
        let x = xs
        let line: CGFloat = xz(23)
        let quotas = quotaLine
        var slot = TextStyle(font: Typeface.display(14), color: row.isActive ? Palette.amber : Palette.cyan)
        if row.isActive { slot.shadow = Draw.glow(Palette.amberGlow, radius: 8) }
        Draw.text(slot.string(row.slot), x: x.slot, centerY: line, maxWidth: xz(34))
        SxQuota.draw(key: "5h", quota: row.fiveHour, threshold: tickFiveHour ? threshold : nil,
                     in: CGRect(x: x.five, y: quotas - xz(8), width: columns.quotaWidth, height: xz(16)))
        SxQuota.draw(key: "1w", quota: row.weekly, threshold: tickWeekly ? threshold : nil,
                     in: CGRect(x: x.week, y: quotas - xz(8), width: columns.quotaWidth, height: xz(16)))
        let reset = NSMutableAttributedString(attributedString: TextStyle.mono(11, Palette.dim).string("1w 重置 "))
        reset.append(TextStyle.mono(11, Palette.cream).string(row.resetIn))
        Draw.text(reset, x: x.reset, centerY: quotas - xz(7), maxWidth: xz(112))
        Draw.text(TextStyle.mono(10.5, row.isActive ? Palette.dim : Palette.dimmer).string(row.resetAt), x: x.reset, centerY: quotas + xz(7),
                  maxWidth: xz(112))
        let sessions = sessionsText
        let sessionsY = columns.sessionsOnSecondLine ? xz(46) + xz(4) : line
        let width = shownSessionsWidth
        Draw.text(sessions, x: bounds.width - xz(15) - width, centerY: sessionsY, maxWidth: width)
        if aliasInput.isInvalid {
            let y = bounds.height - xz(12)
            Draw.text(TextStyle.mono(11, Palette.danger).string("▲ " + aliasHint), x: x.alias, centerY: y, maxWidth: bounds.width - x.alias - xz(15))
        }
    }
}

/// The R8 live preview: `.sx-pvrow`s (slot, alias, `1w 重置 …`, the distance, `✓ ACTIVE`,
/// `下一個`, two quota rows with threshold ticks) and the `.sx-pvf` footer.
final class AutoSwitchPreviewView: FlippedView {
    private(set) var preview = SettingsAutoSwitchPreview(rows: [], current: "—", next: "—", note: "")
    private var threshold: Double = 2
    static var rowHeight: CGFloat { xz(49) }
    static var footerHeight: CGFloat { xz(32) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("自動切換即時預覽")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ preview: SettingsAutoSwitchPreview, threshold: Double) {
        guard preview != self.preview || threshold != self.threshold else { return }
        let rowsChanged = preview.rows.count != self.preview.rows.count
        self.preview = preview
        self.threshold = threshold
        if rowsChanged { invalidateIntrinsicContentSize() }
        setAccessibilityValue(footerText)
        needsDisplay = true
    }

    var footerText: String { "目前 \(preview.current) · 下一個：\(preview.next) \(preview.note)".trimmingCharacters(in: .whitespaces) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(preview.rows.count) * Self.rowHeight + Self.footerHeight + xz(2))
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        var y: CGFloat = 1
        for (index, row) in preview.rows.enumerated() {
            let rect = CGRect(x: 1, y: y, width: bounds.width - 2, height: Self.rowHeight)
            drawRow(row, in: rect, separator: index > 0)
            y += Self.rowHeight
        }
        let footer = CGRect(x: 1, y: y, width: bounds.width - 2, height: Self.footerHeight)
        Draw.fill(footer, Palette.bg)
        if !preview.rows.isEmpty { Draw.dashedLine(from: CGPoint(x: footer.minX, y: footer.minY), to: CGPoint(x: footer.maxX, y: footer.minY), color: Palette.lineBright) }
        let text = NSMutableAttributedString()
        let base = TextStyle.mono(11.5, Palette.dim)
        text.append(base.string("目前 "))
        text.append(base.with(color: Palette.amber).string(preview.current))
        text.append(base.with(color: Palette.dimmer).string("  ·  "))
        text.append(base.string("下一個："))
        text.append(base.with(color: Palette.cyan).string(preview.next))
        if !preview.note.isEmpty { text.append(base.with(color: Palette.dimmer).string("  " + preview.note)) }
        Draw.text(text, x: footer.minX + xz(14), centerY: footer.midY, maxWidth: footer.width - xz(28))
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }

    private func drawRow(_ row: SettingsPreviewRow, in rect: CGRect, separator: Bool) {
        if row.isActive {
            Draw.fill(rect, Palette.bgLift)
            Draw.fill(CGRect(x: rect.minX, y: rect.minY, width: xz(2), height: rect.height), Palette.amber)
        }
        if separator { Draw.dashedLine(from: CGPoint(x: rect.minX, y: rect.minY), to: CGPoint(x: rect.maxX, y: rect.minY), color: Palette.lineBright) }
        let p1 = rect.minY + xz(6) + xz(8)
        var x = rect.minX + xz(14)
        var slot = TextStyle(font: Typeface.display(12.5), color: row.isActive ? Palette.amber : Palette.cyan)
        if row.isActive { slot.shadow = Draw.glow(Palette.amberGlow, radius: 8) }
        x += Draw.text(slot.string(row.slot), x: x, centerY: p1) + xz(8)
        x += Draw.text(TextStyle.mono(11, Palette.cream).string(row.alias), x: x, centerY: p1) + xz(8)
        let resetStart = x
        // Right side, from the right edge: `下一個`, `✓ ACTIVE`, the distance.
        var right = rect.maxX - xz(12)
        if row.isNext {
            let style = ChipStyle.chip(.cyan, mini: true)
            right -= style.size(for: "下一個").width
            style.draw("下一個", x: right, centerY: p1)
            right -= xz(8)
        }
        if row.isActive {
            let style = ChipStyle.chip(.fill, caps: true, mini: true)
            right -= style.size(for: "✓ Active").width
            style.draw("✓ Active", x: right, centerY: p1)
            right -= xz(8)
        }
        let distColor: NSColor = row.distanceTone == .crit ? Palette.danger : (row.distanceTone == .warn ? Palette.amber : Palette.bone)
        let dist = TextStyle.mono(11, distColor).string(row.distance)
        right -= Draw.width(dist)
        Draw.text(dist, x: max(resetStart, right), centerY: p1, maxWidth: rect.maxX - xz(12) - resetStart)
        Draw.text(TextStyle.mono(10.5, row.isActive ? Palette.dim : Palette.dimmer).string("1w 重置 \(row.resetIn)"), x: resetStart, centerY: p1,
                  maxWidth: max(0, right - xz(8) - resetStart))
        let q = rect.minY + xz(6) + xz(16) + xz(4) + xz(8)
        let width = (rect.width - xz(14) - xz(12) - xz(12)) / 2
        SxQuota.draw(key: "5h", quota: row.fiveHour, threshold: row.tickFiveHour ? threshold : nil,
                     in: CGRect(x: rect.minX + xz(14), y: q - xz(8), width: width, height: xz(16)), fontSize: 10.5)
        SxQuota.draw(key: "1w", quota: row.weekly, threshold: row.tickWeekly ? threshold : nil,
                     in: CGRect(x: rect.minX + xz(14) + width + xz(12), y: q - xz(8), width: width, height: xz(16)), fontSize: 10.5)
    }
}
