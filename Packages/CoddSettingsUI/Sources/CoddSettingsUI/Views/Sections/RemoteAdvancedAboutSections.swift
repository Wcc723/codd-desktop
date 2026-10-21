import AppKit
import CoddPreferences
import CoddUI

/// 04 PROFILES 啟動設定檔: the app's M2 page (`ProfilesSettingsView`), hosted as it is. It brings
/// its own head, padding and editing; the search knows its static words only.
final class ProfilesHostSectionView: SettingsSectionView {
    private let hosted: NSView

    init(context: SectionContext, profilesView: NSView) {
        hosted = profilesView
        super.init(section: .profiles, context: context)
    }

    override func build() {
        // The hosted page has its own column; ours would fight it for the height.
        column.removeFromSuperview()
        hosted.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosted)
        // The hosted page caps its own width (880 + padding) with a fill constraint stronger than
        // the window's size; a required trailing pin would let that shrink the Settings window.
        // It may end short of our trailing edge instead.
        let fill = hosted.trailingAnchor.constraint(equalTo: trailingAnchor)
        fill.priority = NSLayoutConstraint.Priority(480)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosted.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            fill,
            hosted.topAnchor.constraint(equalTo: topAnchor),
            hosted.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        sectionSearchText += " Launch profiles 啟動方式 ⌘N 新增 session 時可選的啟動方式 --session-id New profile 複製 編輯 刪除 實際啟動指令 claude-default"
    }

    var hostedView: NSView { hosted }
}

/// 11 REMOTE 遠端 (FUTURE): the real Remote Control line, then the three phases drawn disabled
/// at 55 % exactly as the artboard (no preferences behind them yet).
final class RemoteSectionView: SettingsSectionView {
    private let rcLine = SxLabel("", style: TextStyle.mono(11.5, Palette.dim), wraps: false)

    override func build() {
        let link = SxLinkButton("看規劃 → Remote 畫板")
        link.onClick = { [weak self] in self?.actions.openRemoteBoard() }
        registerControl("remote.board", link)
        let future = ChipView("FUTURE", style: ChipStyle(text: TextStyle.caps(10, Palette.dim, tracking: 0.12), border: Palette.lineBright,
                                                         dashed: true, height: 16, padding: 6))
        add(pageHead(lead: SxRich("尚未實作。先列出規劃中的選項，讓你知道之後會放在哪裡。"), marks: [future], actions: [link]))

        let info = SxInfoBox()
        info.fill = Palette.bgSoft
        let hint = SxLabel("由 Claude Code 提供，現在就能用", style: SxStyle.hint, wraps: false)
        hint.setContentCompressionResistancePriority(.required, for: .horizontal)
        let line = hStack([rcLine, spacer(), hint], spacing: 10)
        info.set([line])
        bind { [weak self] _, info in self?.updateRC(count: info.rcCount, titles: info.rcTitles) }
        add(info)

        add(phase("Phase 0", "Remote Control", cjk: "Claude 官方 · 不需 Apple 開發者帳號", rows: [
            staticRow("remote.atStartup", "新 session 預設連 Remote Control", en: "remoteControlAtStartup", hint: "在 iPhone 的 Claude App 接手 Mac 上的 session。",
                      control: disabledSwitch("新 session 預設連 Remote Control")),
            staticRow("remote.inputNeeded", "需要操作時推播到手機", en: "inputNeededNotifEnabled", hint: "等待授權或回答時推到手機。",
                      control: disabledSwitch("需要操作時推播到手機")),
            staticRow("remote.presence", "在 Mac 前時不推播", en: "Presence file", hint: "偵測到你正在用這台 Mac 時，只在本機通知。",
                      control: disabledSwitch("在 Mac 前時不推播")),
        ]))
        let provider = SxSegmented(titles: ["Off", "Tailscale", "Cloudflare"], accessibilityLabel: "自架遠端連線方式")
        provider.isEnabled = false
        add(phase("Phase 1", "自架遠端", cjk: "Tailscale / Cloudflare Tunnel", rows: [
            staticRow("remote.provider", "連線方式", en: "Provider", hint: "CODD Web 介面當手機版（加入主畫面 + Web Push）。", control: provider),
        ]))
        add(phase("Phase 2", "原生 iOS App", cjk: "需 Apple Developer US$99/年", rows: [
            staticRow("remote.devices", "已配對裝置", en: "Paired devices", hint: "Live Activity、動態島與可操作通知。",
                      control: SxStaticButton("+ 配對新裝置")),
        ]))
    }

    private func updateRC(count: Int, titles: [String]) {
        let text: SxRich
        if count > 0 {
            text = SxRich([.color("◉", Palette.cyan), .text("  "), .color("\(count) 個 session 已連 Remote Control", Palette.cream),
                           .color(titles.isEmpty ? "" : "（\(titles.joined(separator: "、"))）", Palette.dimmer)])
        } else {
            text = SxRich([.color("○", Palette.dimmer), .text("  "), .color("目前沒有 session 連著 Remote Control", Palette.bone)])
        }
        rcLine.set(text.attributed(TextStyle.mono(11.5, Palette.dim), lineBreak: .byTruncatingTail))
    }

    var rcText: String { rcLine.text }

    private func disabledSwitch(_ label: String) -> SwitchToggle {
        let toggle = SwitchToggle(label: label)
        toggle.isEnabled = false
        toggle.alphaValue = 1
        return toggle
    }

    private func staticRow(_ key: String, _ name: String, en: String, hint: String, control: NSView) -> SxRow {
        let made = row(key, name, en: en, hint: hint, controls: [control])
        registerControl(key, control)
        return made
    }

    /// `.sx-grp.sx-dim`: the phase chip, title and note, a card; all at 55 %.
    private func phase(_ chip: String, _ title: String, cjk: String, rows: [SxRow]) -> NSView {
        let head = groupHead(title, cjk: cjk)
        head.leadingChip = chip
        let group = sxGroup(head, [SxCard(rows)])
        group.alphaValue = 0.55
        return group
    }
}

/// 12 ADVANCED 進階: data paths with `在 Finder 顯示`, logs (`M5`), 終端機紀錄保留 (the same value as
/// CLEANUP › 終端機紀錄, D30), import (`FUTURE`), 重建筆記索引 with its result line, and
/// `重設所有設定` (the app confirms).
final class AdvancedSectionView: SettingsSectionView {
    private let dataPath = SxPathLabel()
    private let logPath = SxPathLabel()
    private(set) var rebuildButton: CoddButton?

    /// The artboard's three options of 終端機紀錄保留 (frozen); CLEANUP's `永不` is shown as the
    /// select's title without becoming a fourth option here.
    static let scrollbackOptions: [Int?] = CoddPreferences.Advanced.scrollbackRetentionOptions.map { Optional($0) }

    override func build() {
        add(pageHead(lead: SxRich("資料位置與維護工具。")))
        let reveal = button("在 Finder 顯示", accessibilityLabel: "在 Finder 顯示資料根目錄") { [weak self] in self?.actions.showDataRoot() }
        registerControl("advanced.showDataRoot", reveal)
        let database = row("advanced.database", "資料庫", en: "Database", hint: "群組、顏色、排序、設定與 session 索引。", extra: [dataPath],
                           controls: [reveal], labelGap: 5)
        let logs = row("advanced.logs", "紀錄檔", en: "Logs", hint: "回報問題時附上這個檔案。", extra: [logPath],
                       controls: [SxStaticButton("開啟")], milestone: "M5", labelGap: 5)
        bind { [weak self] _, info in
            self?.dataPath.text = info.dataRootPath.isEmpty ? "—" : info.dataRootPath
            self?.logPath.text = info.logPath ?? "—"
        }
        // D30: the row edits `cleanup.scrollbackDeleteDays` (what the retention engine obeys);
        // `advanced.scrollbackRetentionDays` stays stored and unused. The key stays the row's own.
        let retention = Self.scrollbackOptions
        let scrollback = row("advanced.scrollbackRetentionDays", "終端機紀錄保留", en: "Scrollback retention", hint: "封存的 session 終端機輸出保留多久。",
                             controls: [select("advanced.scrollbackRetentionDays", titles: retention.map { OptionLabels.days($0) }, values: retention,
                                               width: 110, label: "終端機紀錄保留", get: { $0.cleanup.scrollbackDeleteDays },
                                               set: { $0.cleanup.scrollbackDeleteDays = $1 }, unknownTitle: { OptionLabels.days($0) })],
                             keywords: retention.map { OptionLabels.days($0) } + ["scrollback"])
        add(sxGroup(groupHead("Data", cjk: "資料位置"), [SxCard([database, logs, scrollback])]))

        let importRow = row("advanced.import", "從 CODD Web 匯入", en: "Import", hint: "匯入群組、顏色與 launch profiles；對話紀錄本來就在 ~/.claude。",
                            controls: [SxStaticButton("匯入")], milestone: "FUTURE")
        let rebuildButton = button("重建", accessibilityLabel: "重建筆記索引") { [weak self] in self?.actions.rebuildNotesIndex() }
        registerControl("advanced.rebuildIndex", rebuildButton)
        self.rebuildButton = rebuildButton
        let rebuild = row("advanced.rebuildIndex", "重建筆記索引", en: "Rebuild index", hint: "搜尋找不到筆記時使用；不會改動 .md 檔。",
                          controls: [rebuildButton], keywords: ["index", "索引"])
        bind { [weak rebuild, weak rebuildButton] _, info in
            let notebook = info.notebook
            rebuildButton?.isEnabled = notebook.rebuildEnabled
            rebuild?.setNote("index", notebook.indexLine, color: notebook.rebuilding ? Palette.amber : Palette.dim)
        }
        add(sxGroup(groupHead("Maintenance", cjk: "維護"), [SxCard([importRow, rebuild])]))

        let resetButton = button("重設所有設定", variant: .danger) { [weak self] in self?.actions.resetAll() }
        registerControl("advanced.resetAll", resetButton)
        let reset = row("advanced.resetAll", "重設所有設定", en: "Reset", hint: "只重設偏好設定；筆記、群組、對話紀錄與 hooks 不受影響。",
                        controls: [resetButton])
        let danger = groupHead("Danger zone", cjk: "危險區")
        danger.titleColor = Palette.danger
        add(sxGroup(danger, [SxCard([reset], danger: true)]))
    }

    var dataPathText: String { dataPath.text }
}

/// 13 ABOUT 關於 (D28): the brand card with the versions grid from `SettingsInfo.versions` (no
/// Electron / Node), the update channel and check (`M5`), `複製版本資訊`, (M5) 首次啟動設定
/// `重新執行`, which reopens the onboarding wizard, and the open-source release's 第三方元件授權
/// `開啟` with the unofficial-tool line.
final class AboutSectionView: SettingsSectionView {
    private(set) var card: AboutCardView?
    /// The line under the Legal card: CODD is not Anthropic's.
    static let disclaimer = "CODD 是個人開發的非官方工具，與 Anthropic 無關；Claude 與 Claude Code 是 Anthropic 的商標。"
    private(set) var disclaimerLabel: SxLabel?

    override func build() {
        add(pageHead(lead: SxRich("版本、更新與授權。")))
        let card = AboutCardView()
        self.card = card
        bind { [weak card] _, info in card?.update(version: info.appVersion, platform: info.platformLine, versions: info.versions) }
        add(card)

        let channelTitles = ["Stable", "Beta"]
        let channel = row("about.updateChannel", "更新頻道", en: "Update channel", hint: "BETA 會先拿到新功能，偶爾不穩定。",
                          controls: [segmented("about.updateChannel", titles: channelTitles, values: [CoddPreferences.UpdateChannel.stable, .beta],
                                               label: "更新頻道", get: { $0.about.updateChannel }, set: { $0.about.updateChannel = $1 }),
                                     SxStaticButton("檢查更新")],
                          milestone: "M5", keywords: channelTitles)
        let copy = button("複製版本資訊") { [weak self] in self?.actions.copyDiagnostics() }
        registerControl("about.copyDiagnostics", copy)
        let diagnostics = row("about.diagnostics", "版本資訊", en: "Diagnostics", hint: "回報問題時貼上：App、macOS、Claude Code、cswap 與 libghostty 版本。",
                              controls: [copy])
        // M5 §2.4 reopen point: the wizard reads live facts and writes nothing on its own.
        let rerun = button("重新執行", accessibilityLabel: "重新執行首次啟動設定") { [weak self] in self?.actions.openOnboarding() }
        registerControl("about.onboarding", rerun)
        let onboarding = row("about.onboarding", "首次啟動設定", en: "Onboarding",
                             hint: "重新看一次環境偵測、匯入專案、hooks、筆記本、帳號與通知；不會自動改動任何檔案。",
                             controls: [rerun], keywords: ["onboarding", "first boot", "精靈"])
        add(sxGroup(groupHead("Updates", cjk: "更新"), [SxCard([channel, diagnostics, onboarding])]))

        // The bundled THIRD-PARTY-NOTICES.md (MIT, BSD, MPL, LGPL, Unicode and OFL texts the release must carry).
        let open = button("開啟", accessibilityLabel: "開啟第三方元件授權") { [weak self] in self?.actions.openThirdPartyNotices() }
        registerControl("about.notices", open)
        let notices = row("about.notices", "第三方元件授權", en: "Licenses",
                          hint: "CODD 內附的開放原始碼元件與字型（libghostty、GRDB、JetBrains Mono 等）的著作權聲明與授權全文。",
                          controls: [open], keywords: ["license", "licenses", "notices", "open source", "授權", "開放原始碼"])
        let disclaimer = SxLabel(Self.disclaimer, style: SxStyle.hint, lineHeight: SxStyle.hintLineHeight)
        disclaimerLabel = disclaimer
        sectionSearchText += " " + Self.disclaimer
        add(sxGroup(groupHead("Legal", cjk: "授權"), [SxCard([notices]), disclaimer]))
    }
}

/// `.card` (ASCII corners) with `.sx-hero` (the 76 pt app icon, `CODD Desktop`, the version
/// chip, the platform hint, the tagline) and `.sx-vers` (one cell per version, dashed rules).
final class AboutCardView: FlippedView {
    private(set) var version = ""
    private(set) var platform = ""
    private(set) var versions: [SettingsVersion] = []
    private var heightConstraint: NSLayoutConstraint?
    /// The versions grid's columns: one row of cells, or (a narrow card: small window, zoom 20)
    /// fewer columns over more rows, so no value is cut (tests).
    private(set) var gridColumns = 0

    /// The card's height for `rows` rows of version cells (62 each).
    static func height(rows: Int) -> CGFloat { xz(6 + 16 + 4 + 76 + 18) + CGFloat(max(1, rows)) * xz(62) + xz(6) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        let height = heightAnchor.constraint(equalToConstant: Self.height(rows: 1))
        height.isActive = true
        heightConstraint = height
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("CODD Desktop")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(version: String, platform: String, versions: [SettingsVersion]) {
        guard version != self.version || platform != self.platform || versions != self.versions else { return }
        self.version = version
        self.platform = platform
        self.versions = versions
        setAccessibilityValue(versions.map { "\($0.key) \($0.value)" }.joined(separator: "，"))
        needsLayout = true
        needsDisplay = true
    }

    private static var keyStyle: TextStyle { TextStyle.caps(10, Palette.dim, tracking: 0.16) }
    private static var valueStyle: TextStyle { TextStyle(font: Typeface.display(17), color: Palette.cream) }

    /// The most columns (all the versions at most) whose cells fit every key and value whole.
    static func columns(width: CGFloat, versions: [SettingsVersion]) -> Int {
        guard !versions.isEmpty else { return 1 }
        let needed = versions.map { max(Draw.width(keyStyle.string($0.key)), Draw.width(valueStyle.string($0.value))) }.max() ?? 0
        var columns = versions.count
        while columns > 1, (width - 2) / CGFloat(columns) - xz(24) < needed { columns -= 1 }
        return columns
    }

    override func layout() {
        super.layout()
        let columns = Self.columns(width: bounds.width, versions: versions)
        let rows = Int((Double(max(1, versions.count)) / Double(columns)).rounded(.up))
        if columns != gridColumns || heightConstraint?.constant != Self.height(rows: rows) {
            gridColumns = columns
            heightConstraint?.constant = Self.height(rows: rows)
            needsDisplay = true
        }
    }

    /// The card's frame inside the view: 6 pt above and below stay free for the half of the
    /// ASCII corners that sits outside the border (`translateY(±50%)`).
    private var card: CGRect { CGRect(x: 0, y: xz(6), width: bounds.width, height: bounds.height - xz(12)) }

    override func draw(_ dirtyRect: NSRect) {
        let card = card
        Draw.fill(card, Palette.bgSoft)
        Draw.strokeRect(card, color: Palette.lineBright)
        // `.card::before` `┌─` / `::after` `─┘`: 11 px amber-dim on a --bg box (padding 0 4),
        // centered on the top-left / bottom-right border.
        let corner = TextStyle.mono(11, Palette.amberDim)
        let topLeft = corner.string("┌─")
        let topBox = CGRect(x: -1, y: card.minY - xz(6), width: Draw.width(topLeft) + xz(8), height: xz(12))
        Draw.fill(topBox, Palette.bg)
        Draw.text(topLeft, x: topBox.minX + xz(4), centerY: card.minY)
        let bottomRight = corner.string("─┘")
        let bottomBox = CGRect(x: card.maxX + 1 - Draw.width(bottomRight) - xz(8), y: card.maxY - xz(6), width: Draw.width(bottomRight) + xz(8), height: xz(12))
        Draw.fill(bottomBox, Palette.bg)
        Draw.text(bottomRight, x: bottomBox.minX + xz(4), centerY: card.maxY)
        let bounds = card

        // Hero.
        let icon = CGRect(x: xz(18) + xz(2), y: bounds.minY + xz(16) + xz(4), width: xz(76), height: xz(76))
        drawIcon(in: icon)
        let textX = icon.maxX + xz(20)
        var brand = TextStyle(font: Typeface.display(24), color: Palette.amber, tracking: 0.04)
        brand.shadow = Draw.glow(Palette.amberGlow, radius: 8)
        let brandText = brand.string("CODD")
        let line1 = icon.minY + xz(16)
        Draw.text(brandText, x: textX, centerY: line1)
        Draw.text(TextStyle(font: Typeface.display(15), color: Palette.bone).string("Desktop"), x: textX + Draw.width(brandText) + xz(10), centerY: line1 + xz(2))
        let line2 = line1 + xz(28)
        // A narrow card cuts the platform and the tagline with `…` at its padding.
        let textEnd = bounds.maxX - xz(16)
        let chipWidth = ChipStyle.chip(.amber).draw(version.isEmpty ? "—" : version, x: textX, centerY: line2)
        Draw.text(SxStyle.hint.string(platform), x: textX + chipWidth + xz(8), centerY: line2,
                  maxWidth: max(0, textEnd - textX - chipWidth - xz(8)))
        Draw.text(SxStyle.lead.string("在一台 Mac 上管理很多個 Claude Code session。"), x: textX, centerY: line2 + xz(25),
                  maxWidth: max(0, textEnd - textX))

        // Versions grid: dashed top rule, dashed column rules, `KEY` caps over the value.
        let columns = max(1, gridColumns > 0 ? gridColumns : Self.columns(width: bounds.width, versions: versions))
        let cell = (bounds.width - 2) / CGFloat(columns)
        for (index, item) in versions.enumerated() {
            let column = index % columns
            let top = icon.maxY + xz(18) + CGFloat(index / columns) * xz(62)
            let x = 1 + CGFloat(column) * cell
            if column == 0 {
                Draw.dashedLine(from: CGPoint(x: 1, y: top), to: CGPoint(x: bounds.width - 1, y: top), color: Palette.lineBright)
            }
            let gridTop = top
            if column > 0 {
                let path = NSBezierPath()
                path.move(to: CGPoint(x: round(x) + 0.5, y: gridTop))
                path.line(to: CGPoint(x: round(x) + 0.5, y: min(bounds.maxY - 1, gridTop + xz(62))))
                path.lineWidth = 1
                let dash: [CGFloat] = [3, 2]
                dash.withUnsafeBufferPointer { path.setLineDash($0.baseAddress, count: dash.count, phase: 0) }
                Palette.lineBright.setStroke()
                path.stroke()
            }
            Draw.text(Self.keyStyle.string(item.key), x: x + xz(16), centerY: gridTop + xz(12) + xz(8), maxWidth: cell - xz(24))
            Draw.text(Self.valueStyle.string(item.value), x: x + xz(16), centerY: gridTop + xz(12) + xz(15) + xz(3) + xz(12),
                      maxWidth: cell - xz(24))
        }
    }

    /// `.sx-icon`: black rounded square (radius 17), line-bright border, the amber brand mark with
    /// its glow, faint scanlines.
    private func drawIcon(in rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 17, yRadius: 17)
        NSGraphicsContext.saveGraphicsState()
        let glow = Draw.glow(Palette.amber.withAlphaComponent(0.12), radius: 28)
        glow.set()
        NSColor.black.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        var y = rect.minY
        while y < rect.maxY {
            Draw.fill(CGRect(x: rect.minX, y: y, width: rect.width, height: 1), NSColor(srgbRed: 1, green: 176 / 255, blue: 0, alpha: 0.07))
            y += xz(3)
        }
        NSGraphicsContext.restoreGraphicsState()
        Palette.lineBright.setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 17, yRadius: 17)
        border.lineWidth = 1
        border.stroke()
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(Palette.amber.withAlphaComponent(0.55), radius: 6).set()
        IconRenderer.draw(.brand, in: CGRect(x: rect.midX - xz(21), y: rect.midY - xz(21), width: xz(42), height: xz(42)), color: Palette.amber, flipped: true)
        NSGraphicsContext.restoreGraphicsState()
    }
}
