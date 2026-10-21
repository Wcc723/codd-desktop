import AppKit
import CoddPreferences
import CoddUI

/// 09 CLEANUP 清理 (M4, D29–D32): the lifecycle strip, NOTES / SESSIONS columns and DIGEST, every
/// row live (the retention engine reads these values). Claude Code's `cleanupPeriodDays` is a
/// read-only chip; `查看清理建議 · n →` opens the Cleanup page; 交給 Claude 濃縮 picks the account
/// from `SettingsInfo.condenseAccounts` and the model.
final class CleanupSectionView: SettingsSectionView {
    private let periodChip = ChipView("", style: .chip(.plain))
    private(set) var suggestions: CoddButton?
    private(set) var strip: LifecycleStripView?
    private var digestRow: SxRow?
    private(set) var accountSelect: SelectButton?

    /// `查看清理建議 · 15 →`, or `查看清理建議 →` before the engine counted.
    static func suggestionsTitle(_ count: Int?) -> String { count.map { "查看清理建議 · \($0) →" } ?? "查看清理建議 →" }

    override func build() {
        let suggestions = button(Self.suggestionsTitle(nil), variant: .accent, accessibilityLabel: "查看清理建議") { [weak self] in
            self?.actions.openCleanup()
        }
        registerControl("cleanup.openCleanup", suggestions)
        self.suggestions = suggestions
        add(pageHead(lead: SxRich("什麼時候標示 stale、自動封存、清空垃圾桶。只有你能把東西丟進垃圾桶。"), actions: [suggestions]))
        bind { [weak suggestions] _, info in
            guard let suggestions else { return }
            let title = Self.suggestionsTitle(info.cleanupCandidateCount)
            if suggestions.label != title { suggestions.label = title }
            suggestions.isEnabled = info.canOpenCleanup
        }

        let strip = LifecycleStripView()
        self.strip = strip
        bind { [weak strip] prefs, _ in strip?.update(prefs.cleanup) }
        add(strip)

        let notes = sxGroup(groupHead("Notes", cjk: "筆記"), [SxCard([
            daysRow("cleanup.notesStaleDays", "標示 STALE", hint: "多久沒有活動就標示 stale", options: CoddPreferences.Cleanup.notesStaleOptions,
                    label: "筆記標示 STALE", path: \.notesStaleDays),
            daysRow("cleanup.notesArchiveDays", "自動封存", hint: "移到 ARCHIVE，隨時可還原", options: CoddPreferences.Cleanup.notesArchiveOptions,
                    label: "筆記自動封存", path: \.notesArchiveDays),
            daysRow("cleanup.scratchArchiveDays", "SCRATCH · 已送出 prompt", hint: "隨手記與送出後的 prompt 較快封存",
                    options: CoddPreferences.Cleanup.scratchArchiveOptions, label: "SCRATCH 與已送出 prompt 封存", path: \.scratchArchiveDays),
            row("cleanup.trashPurgeDays", "垃圾桶清除", hint: "超過時間才永久刪除",
                controls: [select("cleanup.trashPurgeDays", titles: CoddPreferences.Cleanup.trashPurgeOptions.map { OptionLabels.days($0) },
                                  values: CoddPreferences.Cleanup.trashPurgeOptions, width: 96, label: "垃圾桶清除",
                                  get: { $0.cleanup.trashPurgeDays }, set: { $0.cleanup.trashPurgeDays = $1 },
                                  unknownTitle: { OptionLabels.days($0) })],
                keywords: CoddPreferences.Cleanup.trashPurgeOptions.map { OptionLabels.days($0) }, inColumn: true),
            daysRow("cleanup.tombstoneDays", "Tombstone", hint: "舊的 codd:// 引用顯示「已刪除」", options: CoddPreferences.Cleanup.tombstoneOptions,
                    label: "Tombstone 保留", path: \.tombstoneDays, never: "永久"),
            row("cleanup.exempt", "豁免", hint: "釘選與使用中 session 的筆記",
                controls: [toggle("cleanup.exempt", label: "豁免釘選與使用中 session 的筆記", get: { $0.cleanup.exempt },
                                  set: { $0.cleanup.exempt = $1 })],
                inColumn: true),
        ])])
        bind { [weak self] _, info in
            let text = info.cleanupPeriodDays.map { "\($0) 天 · 唯讀" } ?? "30 天（預設）· 唯讀"
            self?.periodChipText = text
            self?.periodChip.set(text)
        }
        registerControl("cleanup.cleanupPeriodDays", periodChip)
        let sessions = sxGroup(groupHead("Sessions", cjk: "工作階段"), [SxCard([
            daysRow("cleanup.sessionsStaleDays", "標示 STALE", hint: "停止後多久在側欄變暗", options: CoddPreferences.Cleanup.sessionsStaleOptions,
                    label: "session 標示 STALE", path: \.sessionsStaleDays),
            daysRow("cleanup.sessionsArchiveDays", "自動封存", hint: "從側欄隱藏，對話紀錄保留", options: CoddPreferences.Cleanup.sessionsArchiveOptions,
                    label: "session 自動封存", path: \.sessionsArchiveDays),
            daysRow("cleanup.scrollbackDeleteDays", "終端機紀錄", hint: "封存後多久刪除終端機輸出",
                    options: CoddPreferences.Cleanup.scrollbackDeleteOptions, label: "終端機紀錄刪除", path: \.scrollbackDeleteDays),
            row("cleanup.cleanupPeriodDays", "cleanupPeriodDays", hint: "Claude Code 設定，超過就無法 resume", controls: [periodChip], inColumn: true),
            row("cleanup.resumeWarning", "resume 過期提醒", hint: "剩 5 天時在列上提醒",
                controls: [toggle("cleanup.resumeWarning", label: "resume 過期提醒", get: { $0.cleanup.resumeWarning },
                                  set: { $0.cleanup.resumeWarning = $1 })],
                inColumn: true),
        ])])
        add(TwoColumnView(left: notes, right: sessions))

        let digestTitles = ["每週", "雙週", "每月", "關"]
        let digest = row("cleanup.digest", SxRich("每週清理建議"), en: "Schedule", hint: Self.digestHint(nil),
                         controls: [segmented("cleanup.digest", titles: digestTitles, values: [CoddPreferences.Digest.weekly, .biweekly, .monthly, .off],
                                              label: "清理建議頻率", get: { $0.cleanup.digest }, set: { $0.cleanup.digest = $1 })],
                         keywords: digestTitles)
        digestRow = digest
        bind { [weak digest] _, info in digest?.setHint(Self.digestHint(info.cleanupCandidateCount)) }

        let account = SelectButton(titles: [], accessibilityLabel: "濃縮使用的帳號")
        account.widthAnchor.constraint(equalToConstant: 120).zoomed(120).isActive = true
        account.onSelect = { [weak self] index in
            guard let self else { return }
            let ids = self.model.info.condenseAccounts.map(\.id)
            guard ids.indices.contains(index) else { return }
            self.edit { $0.cleanup.condenseAccount = ids[index] }
        }
        bind { [weak account] prefs, info in
            guard let account else { return }
            let accounts = info.condenseAccounts
            let titles = accounts.map(\.title)
            // nil (never chosen) shows the first entry; a stored account that is gone shows `—`.
            let stored = prefs.cleanup.condenseAccount
            let index = stored.flatMap { id in accounts.firstIndex { $0.id == id } }
            if account.titles != titles || account.selectedIndex != (index ?? 0) { account.setItems(titles, selected: index ?? 0) }
            let display: String? = titles.isEmpty ? "—" : (index == nil && stored != nil ? "—" : nil)
            if account.displayTitle != display { account.displayTitle = display }
            account.isEnabled = !titles.isEmpty
        }
        registerControl("cleanup.condenseAccount", account)
        accountSelect = account
        let models = CoddPreferences.Cleanup.condenseModelOptions
        let condenseModel = select("cleanup.condenseModel", titles: models, values: models, width: 130, label: "濃縮使用的模型",
                                   get: { $0.cleanup.condenseModel }, set: { $0.cleanup.condenseModel = $1 })
        let condense = row("cleanup.condense", "交給 Claude 濃縮", en: "Condense", hint: "手動觸發；原稿只封存不刪除，摘要連回原稿。",
                           controls: [account, condenseModel], keywords: models + ["帳號", "模型", "跟隨全域登入"])
        add(sxGroup(groupHead("Digest", cjk: "清理建議"), [SxCard([digest, condense])]))
    }

    static func digestHint(_ count: Int?) -> SxRich {
        SxRich("週一 09:00 · 累積 5 項以上才提醒" + (count.map { " · 目前 \($0) 項。" } ?? "。"))
    }

    private func daysRow(_ key: String, _ title: String, hint: String, options: [Int?], label: String,
                         path: WritableKeyPath<CoddPreferences.Cleanup, Int?>, never: String = "永不") -> SxRow {
        row(key, title, hint: hint,
            controls: [select(key, titles: options.map { OptionLabels.days($0, never: never) }, values: options, width: 96, label: label,
                              get: { $0.cleanup[keyPath: path] }, set: { $0.cleanup[keyPath: path] = $1 },
                              unknownTitle: { OptionLabels.days($0, never: never) })],
            keywords: options.map { OptionLabels.days($0, never: never) }, inColumn: true)
    }

    private(set) var periodChipText = ""

    /// The condense account titles are found by the search too.
    override var factSearchText: String { model.info.condenseAccounts.map(\.title).joined(separator: " ") }
}

/// `.sx-life`: `ACTIVE → STALE 14d → ARCHIVE 30d → TRASH 只有你能丟 → PURGE 30d` on --bg with a
/// dashed border; the day counts follow the NOTES selects. A strip narrower than one line (small
/// window, zoom 20) wraps before a node (`→ PURGE 30d` starts the next line), never past its border.
final class LifecycleStripView: FlippedView {
    private(set) var texts: [String] = []
    private var heightConstraint: NSLayoutConstraint?
    /// How many lines the nodes take at the current width (tests).
    private(set) var lineCount = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        let height = heightAnchor.constraint(equalToConstant: Self.height(lines: 1))
        height.isActive = true
        heightConstraint = height
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("筆記生命週期")
        update(CoddPreferences.Cleanup())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var nodes: [(String, String?, String?)] = []

    func update(_ cleanup: CoddPreferences.Cleanup) {
        func days(_ value: Int?) -> String { value.map { "\($0)d" } ?? "—" }
        nodes = [("ACTIVE", nil, nil), ("STALE", days(cleanup.notesStaleDays), nil), ("ARCHIVE", days(cleanup.notesArchiveDays), nil),
                 ("TRASH", nil, "只有你能丟"), ("PURGE", days(cleanup.trashPurgeDays), nil)]
        texts = nodes.map { [$0.0, $0.1, $0.2].compactMap { $0 }.joined(separator: " ") }
        setAccessibilityValue(texts.joined(separator: " → "))
        needsLayout = true
        needsDisplay = true
    }

    /// 40 for one line (9 above and below a 22 pt box), 8 more between lines.
    static func height(lines: Int) -> CGFloat {
        xz(18) + CGFloat(lines) * xz(22) + CGFloat(max(0, lines - 1)) * xz(8)
    }

    private var arrow: NSAttributedString { TextStyle.mono(11, Palette.amberDim).string("→") }

    private func text(_ node: (String, String?, String?)) -> NSAttributedString {
        let label = TextStyle.mono(11, Palette.bone, tracking: 0.1)
        let text = NSMutableAttributedString(attributedString: label.string(node.0))
        if let value = node.1 { text.append(label.string(" ")); text.append(label.with(color: Palette.amber).string(value)) }
        if let note = node.2 {
            text.append(label.string(" "))
            text.append(TextStyle.mono(11, Palette.dimmer).string(note))
        }
        return text
    }

    /// Each node's box origin (line, x) and width for a strip `width` wide: a node (with the arrow
    /// before it) that would pass the right padding starts the next line.
    private func placements(width: CGFloat) -> [(line: Int, arrowX: CGFloat?, x: CGFloat, width: CGFloat)] {
        let left = xz(14), right = width - xz(14), gap = xz(8)
        let arrowWidth = Draw.width(arrow)
        var line = 0
        var x = left
        var out: [(Int, CGFloat?, CGFloat, CGFloat)] = []
        for (index, node) in nodes.enumerated() {
            let boxWidth = Draw.width(text(node)) + xz(16)
            var arrowX: CGFloat? = index > 0 ? x : nil
            var boxX = index > 0 ? x + arrowWidth + gap : x
            if index > 0, boxX + boxWidth > right, x > left {
                line += 1
                arrowX = left
                boxX = left + arrowWidth + gap
            }
            out.append((line, arrowX, boxX, boxWidth))
            x = boxX + boxWidth + gap
        }
        return out
    }

    override func layout() {
        super.layout()
        let lines = (placements(width: bounds.width).map(\.line).max() ?? 0) + 1
        if lines != lineCount || heightConstraint?.constant != Self.height(lines: lines) {
            lineCount = lines
            heightConstraint?.constant = Self.height(lines: lines)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.dashedRect(bounds, color: Palette.lineBright)
        for (node, place) in zip(nodes, placements(width: bounds.width)) {
            let mid = xz(9) + CGFloat(place.line) * (xz(22) + xz(8)) + xz(11)
            if let arrowX = place.arrowX { Draw.text(arrow, x: arrowX, centerY: mid) }
            let box = CGRect(x: place.x, y: round(mid - xz(11)), width: place.width, height: xz(22))
            Draw.fill(box, Palette.bgSoft)
            Draw.strokeRect(box, color: Palette.lineBright)
            Draw.text(text(node), x: place.x + xz(8), centerY: mid)
        }
    }
}
