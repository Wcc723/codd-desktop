import AppKit
import CoddPreferences
import CoddUI
import Testing
@testable import CoddSettingsUI

/// Every section draws every row title of the approved artboard (Settings.src.html), the nav
/// is numbered 01–13 with its group heads and tails, and each section renders.
@MainActor
@Suite struct SectionContentTests {
    static let expectedTitles: [SettingsSection: [String]] = [
        .general: ["登入時啟動", "顯示於 Dock", "關閉視窗時保留在選單列", "結束時", "全域快捷鍵", "預設專案根目錄", "語言"],
        .appearance: ["CRT 效果", "介面密度", "UI 字級", "終端機字型", "終端機字級", "原生玻璃側欄", "減少動態"],
        .sessions: ["預設啟動設定檔", "自動加上 --session-id", "NO HOOK 警示", "STALE 判定", "App 重開後恢復", "外部 session",
                    "隱藏 SDK / Desktop 來源"],
        .notifications: ["WAITING", "ERROR", "DONE", "EXITED 非 0", "勿擾時段", "依群組靜音", "Dock 徽章", "選單列圖示",
                         "Remote Control 手機推播"],
        .accounts: ["cswap 路徑", "隱藏 email", "切換前確認", "#2 藍鵲", "#3 工作", "#1 個人", "剩餘不足時自動切換", "門檻", "檢查", "切換到",
                    "冷卻", "都不足時"],
        .hooks: ["狀態目錄", "settings.json.codd-bak-20261012-091503", "settings.json.codd-bak-20261003-183020",
                 "settings.json.codd-bak-20260921-140812"],
        .notebook: ["位置", "圖片長邊壓到 2576px", "保留原檔", "Port 與 token", "註冊", "自動掛載 MCP", "新筆記預設 AI 存取", "AI 可寫入"],
        .cleanup: ["標示 STALE", "自動封存", "SCRATCH · 已送出 prompt", "垃圾桶清除", "Tombstone", "豁免", "終端機紀錄", "cleanupPeriodDays",
                   "resume 過期提醒", "每週清理建議", "交給 Claude 濃縮"],
        .shortcuts: ["跳到第 1–9 個 session", "切換到下一個 session", "快速切換", "開啟設定", "新增 session", "新增終端機", "下方終端機",
                     "Composer", "允許", "調整順序", "專注模式", "快速筆記", "叫出 CODD"],
        .remote: ["新 session 預設連 Remote Control", "需要操作時推播到手機", "在 Mac 前時不推播", "連線方式", "已配對裝置"],
        .advanced: ["資料庫", "紀錄檔", "終端機紀錄保留", "從 CODD Web 匯入", "重建筆記索引", "重設所有設定"],
        .about: ["更新頻道", "版本資訊", "首次啟動設定", "第三方元件授權"],
    ]

    static let expectedGroupHeads: [SettingsSection: [String]] = [
        .general: ["Startup", "Window", "Defaults"],
        .appearance: ["Preview", "Display", "Terminal", "System"],
        .sessions: ["Launch", "State", "External", "State source"],
        .notifications: ["Events", "Quiet", "Badges"],
        .accounts: ["cswap", "Aliases", "Auto-switch", "Preview", "Usage source"],
        .hooks: ["Status dir", "Components", "Events", "Backups"],
        .notebook: ["Storage", "MCP server", "AI access"],
        .cleanup: ["Notes", "Sessions", "Digest"],
        .remote: ["Remote Control", "自架遠端", "原生 iOS App"],
        .advanced: ["Data", "Maintenance", "Danger zone"],
        .about: ["Updates", "Legal"],
    ]

    @Test(arguments: SettingsSection.allCases.filter { $0 != .profiles })
    func everyArtboardRowTitleIsPresent(_ section: SettingsSection) {
        let harness = Harness()
        let view = harness.section(section)
        let titles = view.rowTitles
        for title in Self.expectedTitles[section] ?? [] {
            #expect(titles.contains(title), "\(section): missing row \(title) in \(titles)")
        }
        for head in Self.expectedGroupHeads[section] ?? [] {
            #expect(view.sectionSearchText.contains(head), "\(section): missing group head \(head)")
        }
        #expect(view.sectionSearchText.contains(section.pageTitle))
    }

    @Test func navIsNumberedWithGroupHeadsAndTails() {
        let harness = Harness()
        let sidebar = harness.root.sidebarView
        #expect(SettingsSection.allCases.map(\.number) == (1...13).map { $0 < 10 ? "0\($0)" : "\($0)" })
        #expect(SettingsSection.allCases.compactMap(\.navGroupHead) == ["App", "Workflow", "Integrations", "System"])
        #expect(SettingsSection.general.navGroupHead == "App" && SettingsSection.cleanup.navGroupHead == "System")
        #expect(sidebar.items[.hooks]?.tail == NavItemView.Tail(text: "◆ 更新", style: .warn))
        #expect(sidebar.items[.remote]?.tail == NavItemView.Tail(text: "FUTURE", style: .future))
        #expect(sidebar.items[.about]?.tail == NavItemView.Tail(text: "1.0.0", style: .plain))
        #expect(sidebar.items[.general]?.isOn == true)
        harness.root.select(.cleanup)
        #expect(sidebar.items[.cleanup]?.isOn == true && sidebar.items[.general]?.isOn == false)
        #expect(harness.root.selected == .cleanup)
        #expect(sidebar.footerText.hasPrefix("● 變更即時儲存 · "))
    }

    @Test func footerShowsTheSaveProblemInsteadOfSaved() {
        var info = SettingsSamples.info(now: Harness.now)
        info.saveProblem = "preferences.json 來自較新版本，唯讀"
        let harness = Harness(info: info)
        #expect(harness.root.sidebarView.footerText == "▲ preferences.json 來自較新版本，唯讀")
    }

    @Test func profilesSectionHostsTheInjectedView() {
        let injected = FlippedView()
        injected.translatesAutoresizingMaskIntoConstraints = false
        injected.heightAnchor.constraint(equalToConstant: 300).isActive = true
        let harness = Harness(profilesView: injected)
        let host = harness.section(.profiles, as: ProfilesHostSectionView.self)
        #expect(host.hostedView === injected)
        #expect(injected.isDescendant(of: harness.root))
        #expect(injected.frame.height == 300)
    }

    /// A page capped at 880 + padding must never shrink a wider Settings window (the sections'
    /// fill and the hosted M2 page stay below the window's own size priority).
    @Test func sectionsDoNotShrinkAWideWindow() {
        // The M2 profiles page's shape: a column ≤ 960 wide, filling at .defaultHigh.
        let profiles = FlippedView()
        let column = NSView()
        column.translatesAutoresizingMaskIntoConstraints = false
        profiles.addSubview(column)
        let fill = column.trailingAnchor.constraint(equalTo: profiles.trailingAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: profiles.leadingAnchor),
            column.topAnchor.constraint(equalTo: profiles.topAnchor),
            column.bottomAnchor.constraint(equalTo: profiles.bottomAnchor),
            column.heightAnchor.constraint(equalToConstant: 400),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 960),
            column.trailingAnchor.constraint(lessThanOrEqualTo: profiles.trailingAnchor),
            fill,
        ])
        let harness = Harness(profilesView: profiles)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = harness.root
        for section in [SettingsSection.general, .accounts, .profiles, .about] {
            harness.root.select(section)
            harness.root.layoutSubtreeIfNeeded()
            #expect(harness.root.frame.width == 1440, "\(section) shrank the window to \(harness.root.frame.width)")
        }
        window.contentView = nil
        window.close()
    }

    /// `.sx-sec` fills the content up to 880 + padding at every window size: no row (a `.path`
    /// line, a long hint) may pull a page down to its own text width.
    @Test(arguments: [CGFloat(1040), 1440])
    func everySectionFillsTheContentWidth(_ width: CGFloat) {
        let harness = Harness()
        harness.root.frame = NSRect(x: 0, y: 0, width: width, height: 900)
        let expected = min(880 + 80, width - 230)
        for section in SettingsSection.allCases where section != .profiles {
            let view = harness.section(section)
            #expect(view.column.frame.width == expected, "\(section) at \(width): column \(view.column.frame.width), expected \(expected)")
        }
        // Each row of ADVANCED keeps its zh name (the scrollback row lost it to a narrow page).
        let advanced = harness.section(.advanced)
        for key in ["advanced.database", "advanced.logs", "advanced.scrollbackRetentionDays"] {
            let label = advanced.rowsByKey[key]?.labelColumn
            #expect((label?.frame.width ?? 0) > 300, "\(key) label column \(label?.frame.width ?? 0)")
        }
    }

    @Test func later_milestoneRowsAreDimmedWithTheirChip() {
        let harness = Harness()
        let rows: [(SettingsSection, String, String)] = [
            (.general, "general.language", "M5"), (.appearance, "appearance.density", "M5"),
            (.appearance, "appearance.nativeVibrancy", "M5"), (.advanced, "advanced.logs", "M5"), (.advanced, "advanced.import", "FUTURE"),
            (.about, "about.updateChannel", "M5"),
        ]
        for (section, key, chip) in rows {
            let row = harness.section(section).rowsByKey[key]
            #expect(row?.milestone == chip, "\(key)")
            #expect(row?.alphaValue == 0.55, "\(key)")
        }
        // Functional rows are not dimmed (M4: the notebook, MCP, cleanup and maintenance rows too).
        for (section, key) in [(SettingsSection.general, "general.showInDock"), (.cleanup, "cleanup.resumeWarning"),
                               (.cleanup, "cleanup.cleanupPeriodDays"), (.appearance, "appearance.crt"),
                               (.appearance, "appearance.uiFontSize"),
                               (.notebook, "notebook.location"), (.notebook, "notebook.aiCanWrite"), (.cleanup, "cleanup.notesStaleDays"),
                               (.cleanup, "cleanup.digest"), (.advanced, "advanced.scrollbackRetentionDays"),
                               (.advanced, "advanced.rebuildIndex")] {
            #expect(harness.section(section).rowsByKey[key]?.isDisabledRow == false, "\(key)")
            #expect(harness.section(section).rowsByKey[key]?.alphaValue == 1, "\(key)")
        }
    }

    @Test func factsReachTheirRows() {
        let harness = Harness()
        let general = harness.section(.general, as: GeneralSectionView.self)
        #expect(general.recorder?.displayedText == "⌥ Space")
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        #expect(accounts.versionChipText == "● v0.26.0")
        #expect(accounts.usageLines.first?.contains("#3 工作") == true)
        #expect(accounts.usageLines.last == "// 不另外呼叫 usage API，避免被 429 擋下")
        #expect(accounts.aliases?.rowViews.map(\.accountID) == ["2", "3", "1"])
        let hooks = harness.section(.hooks, as: HooksSectionView.self)
        #expect(hooks.eventChipNames == SettingsHooksInfo.eventNames)
        #expect(hooks.foreignText == "外部 hooks 保持不動：hook-tap ×11 · osascript 通知 ×2")
        #expect(hooks.differsChipShown)
        #expect(hooks.componentRows.count == 3 && hooks.backupRows.count == 3)
        let cleanup = harness.section(.cleanup, as: CleanupSectionView.self)
        #expect(cleanup.periodChipText == "30 天 · 唯讀")
        #expect(cleanup.strip?.texts == ["ACTIVE", "STALE 14d", "ARCHIVE 30d", "TRASH 只有你能丟", "PURGE 30d"])
        let remote = harness.section(.remote, as: RemoteSectionView.self)
        #expect(remote.rcText.contains("1 個 session 已連 Remote Control") && remote.rcText.contains("修正登入 API 401"))
        let about = harness.section(.about, as: AboutSectionView.self)
        #expect(about.card?.versions.map(\.key) == ["App", "macOS", "Claude Code", "cswap", "libghostty"])
        let advanced = harness.section(.advanced, as: AdvancedSectionView.self)
        #expect(advanced.dataPathText == "~/Library/Application Support/CODD")
        let appearance = harness.section(.appearance, as: AppearanceSectionView.self)
        #expect(appearance.previewLabel == "UI 13px · TERM 13px · CRT OFF")
        let sessions = harness.section(.sessions, as: SessionsSectionView.self)
        #expect(sessions.rowsByKey["sessions.externalDisplay"]?.hintText?.contains("（目前 1 個）") == true)
    }

    @Test func versionChipStates() {
        for (cswap, text) in [(SettingsCswapInfo(pathOK: false), "▲ 找不到"),
                              (SettingsCswapInfo(pathOK: true, version: "0.25.1", versionOK: false), "▲ 需 ≥ 0.26"),
                              (SettingsCswapInfo(pathOK: true, version: "0.26.0", versionOK: true), "● v0.26.0")] {
            var info = SettingsSamples.info(now: Harness.now)
            info.cswap = cswap
            let accounts = Harness(info: info).section(.accounts, as: AccountsSectionView.self)
            #expect(accounts.versionChipText == text)
        }
    }

    @Test func emptyFactsStillRender() {
        let harness = Harness(info: SettingsInfo())
        // PROFILES hosts the app's view (an empty NSView here).
        for section in SettingsSection.allCases where section != .profiles {
            let view = harness.section(section)
            #expect(view.frame.height > 100, "\(section)")
        }
        let hooks = harness.section(.hooks, as: HooksSectionView.self)
        #expect(hooks.componentRows.isEmpty && hooks.eventChipNames.isEmpty)
    }

    @Test(arguments: SettingsSection.allCases)
    func sectionRendersPixels(_ section: SettingsSection) {
        let harness = Harness()
        harness.root.select(section)
        #expect(paintedPixels(harness.root) > 2_000, "\(section) looks blank")
    }
}

/// M3 review fixes in the HOOKS and NOTEBOOK sections.
@MainActor
@Suite struct SectionReviewFixTests {
    /// Each rebuild of the component rows (the Statusline chip's age changes) used to add button
    /// targets the section kept for the window's lifetime.
    @Test func rebuiltRowsDoNotPileUpButtonTargets() throws {
        let harness = Harness()
        let hooks = harness.section(.hooks, as: HooksSectionView.self)
        let before = hooks.targetCount
        let base = harness.model.info
        for age in 1...20 {
            var info = base
            info.hooks.components = info.hooks.components.map { component in
                var c = component
                if c.chip != nil { c.chip = "最近收到資料 \(age)s 前" }
                return c
            }
            info.hooks.components.append(SettingsHooksComponent(id: "extra", part: "X\(age)", status: "s", statusTone: .ok, hint: "h",
                                                                buttons: [.init(title: "更新", action: .update)]))
            harness.model.info = info
            harness.sync()
        }
        #expect(hooks.targetCount == before + 1, "the current rows' buttons only (one extra row with one button)")
        #expect(hooks.componentRows.count >= 2)
    }

    /// D17 (M3): the registrations box looked clickable inside its dimmed row. M4: the row is live
    /// and a box inside a disabled row still draws disabled with nothing pressable.
    @Test func registrationsInADisabledRowDrawDisabled() throws {
        let harness = Harness()
        let notebook = harness.section(.notebook, as: NotebookSectionView.self)
        let row = try #require(notebook.rowsByKey["notebook.registrations"])
        #expect(!row.isDisabledRow)
        let box = try #require(row.descendants(ofType: RegistrationsBox.self).first)
        #expect(!box.isDisabledLook)
        #expect(box.buttons.map(\.isEnabled) == [true, true, false])
        SxRow.disable(box)
        #expect(box.isDisabledLook)
        #expect(box.buttons.count == 3 && box.buttons.allSatisfy { !$0.isEnabled })
    }
}
