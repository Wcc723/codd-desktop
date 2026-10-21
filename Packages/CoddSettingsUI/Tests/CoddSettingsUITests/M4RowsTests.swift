import AppKit
import CoddPreferences
import CoddUI
import Testing
@testable import CoddSettingsUI

/// M4 (C9, D30, D33): Settings › 08 筆記本 & MCP, 09 清理 and 12 進階 are live. Each changed row's
/// enabled state, its binding round trip and its action; the scrollback mirror; the neutral state
/// an M3 caller (`SettingsInfo()`, the M3 argument lists) still gets.
@MainActor
@Suite struct NotebookRowsTests {
    @Test func headButtonOpensTheNotesFolder() throws {
        let harness = Harness()
        let notebook = harness.section(.notebook, as: NotebookSectionView.self)
        let open = try #require(notebook.openFolderButton)
        #expect(open.label == "開啟筆記本資料夾" && open.isEnabled)
        open.performClick(nil)
        #expect(harness.log.calls == ["openNotesFolder"])
        // The neutral facts disable it.
        harness.model.info.notebook = .unavailable
        harness.sync()
        #expect(!open.isEnabled)
        open.performClick(nil)
        #expect(harness.log.calls == ["openNotesFolder"])
        // No row keeps D17's `M4` chip.
        #expect(notebook.rowsByKey.values.allSatisfy { $0.milestone == nil })
    }

    @Test func locationOffersOnlyLocal() throws {
        var prefs = CoddPreferences.defaults
        prefs.notebook.location = .iCloud
        let harness = Harness(preferences: prefs)
        let notebook = harness.section(.notebook, as: NotebookSectionView.self)
        let location = try #require(notebook.control("notebook.location", as: SxSegmented.self))
        #expect(location.titles == ["Local", "iCloud Drive", "自訂…"])
        #expect(location.segmentChips == [1: "M5", 2: "M5"])
        #expect(location.disabledIndices == [1, 2])
        #expect(location.isSegmentEnabled(0) && !location.isSegmentEnabled(1) && !location.isSegmentEnabled(2))
        // A value stored by an earlier build is shown; LOCAL can be picked back, the others cannot.
        #expect(location.selectedIndex == 1)
        location.pick(2)
        #expect(harness.model.preferences.notebook.location == .iCloud && harness.log.changes.isEmpty)
        location.pick(0)
        #expect(harness.model.preferences.notebook.location == .local)
        #expect(harness.log.changes.count == 1)
        location.pick(1)
        #expect(harness.model.preferences.notebook.location == .local && harness.log.changes.count == 1)
        #expect(location.accessibilityHelp() == "iCloud Drive M5 提供，自訂… M5 提供")
        // The M5 chips widen their segments.
        let plain = SxSegmented(titles: location.titles, accessibilityLabel: "x")
        #expect(location.intrinsicContentSize.width > plain.intrinsicContentSize.width + 2 * ChipStyle.milestone.size(for: "M5").width)
    }

    @Test func locationHintShowsTheNotesFolder() throws {
        let harness = Harness()
        let notebook = harness.section(.notebook, as: NotebookSectionView.self)
        let row = try #require(notebook.rowsByKey["notebook.location"])
        #expect(row.hintText == "~/Library/Application Support/CODD/notes · 每則筆記是一個 .md 檔")
        harness.model.info.notebook.notesPath = "/tmp/codd-x/notes"
        harness.sync()
        #expect(row.hintText == "/tmp/codd-x/notes · 每則筆記是一個 .md 檔")
        harness.model.info.notebook = .unavailable
        harness.sync()
        #expect(row.hintText == "— · 每則筆記是一個 .md 檔")
    }

    static func path(_ key: String) -> WritableKeyPath<CoddPreferences.Notebook, Bool> {
        switch key {
        case "notebook.resizeImages": \.resizeImages
        case "notebook.keepOriginal": \.keepOriginal
        case "notebook.autoAttachMCP": \.autoAttachMCP
        default: \.aiCanWrite
        }
    }

    @Test(arguments: ["notebook.resizeImages", "notebook.keepOriginal", "notebook.autoAttachMCP", "notebook.aiCanWrite"])
    func switchesAreLiveAndRoundTrip(_ key: String) throws {
        let path = Self.path(key)
        let harness = Harness()
        let notebook = harness.section(.notebook)
        let toggle = try #require(notebook.control(key, as: SwitchToggle.self))
        #expect(toggle.isEnabled && notebook.rowsByKey[key]?.isDisabledRow == false)
        let before = harness.model.preferences.notebook[keyPath: path]
        #expect(toggle.isOn == before)
        toggle.simulateClick()
        #expect(harness.model.preferences.notebook[keyPath: path] == !before)
        #expect(harness.log.changes.count == 1)
        // A change made elsewhere comes back to the switch.
        harness.model.preferences.notebook[keyPath: path] = before
        harness.sync()
        #expect(toggle.isOn == before)
    }

    @Test func defaultAIAccessIsLive() throws {
        let harness = Harness()
        let access = try #require(harness.section(.notebook).control("notebook.defaultAIAccess", as: SxSegmented.self))
        #expect(access.isEnabled && access.disabledIndices.isEmpty && access.selectedIndex == 1)
        access.pick(2)
        #expect(harness.model.preferences.notebook.defaultAIAccess == .append)
        access.pick(0)
        #expect(harness.model.preferences.notebook.defaultAIAccess == .off)
        harness.model.preferences.notebook.defaultAIAccess = .read
        harness.sync()
        #expect(access.selectedIndex == 1)
        #expect(harness.log.changes.count == 2)
    }

    @Test func mcpGroupHeadFollowsTheServer() {
        let harness = Harness()
        let notebook = harness.section(.notebook, as: NotebookSectionView.self)
        #expect(notebook.mcpHeadRightText == "● 執行中 · 3 clients")
        harness.model.info.notebook.mcpClients = 1
        harness.sync()
        #expect(notebook.mcpHeadRightText == "● 執行中 · 1 clients")
        harness.model.info.notebook.mcpRunning = false
        harness.sync()
        #expect(notebook.mcpHeadRightText == "○ 未執行")
        harness.model.info.notebook = .unavailable
        harness.sync()
        #expect(notebook.mcpHeadRightText == "○ 未執行")
    }

    @Test func portIsReadOnlyAndTokenRotates() throws {
        let harness = Harness()
        let notebook = harness.section(.notebook, as: NotebookSectionView.self)
        let port = try #require(notebook.portBox)
        #expect(port.value == "47821")
        #expect(notebook.control("notebook.mcpPort", as: SxTextInput.self) == nil, "no editable port field (D33)")
        #expect(notebook.tokenText == "••••••••••••")
        let rotate = try #require(notebook.rotateButton)
        #expect(rotate.label == "輪替" && rotate.isEnabled)
        rotate.performClick(nil)
        #expect(harness.log.calls == ["rotateMCPToken"])
        // The stored M3 port is not what is shown: MCP shares the hook port.
        harness.model.preferences.notebook.mcpPort = 50000
        harness.model.info.notebook.port = 51234
        harness.model.info.notebook.canRotateToken = false
        harness.sync()
        #expect(port.value == "51234" && !rotate.isEnabled)
        harness.model.info.notebook = .unavailable
        harness.sync()
        #expect(port.value == "—" && notebook.tokenText == "—" && !rotate.isEnabled)
        #expect(harness.log.changes.isEmpty)
    }

    @Test func registrationsComeFromTheFacts() throws {
        let harness = Harness()
        let notebook = harness.section(.notebook, as: NotebookSectionView.self)
        let box = try #require(notebook.registrationsBox)
        #expect(box.shownRows.map(\.name) == ["Claude Code", "Codex", "Claude Desktop"])
        #expect(box.shownRows.map(\.isOn) == [true, false, false])
        #expect(box.shownRows.map(\.hint) == ["已註冊 · user scope", "未註冊", "未安裝"])
        let buttons = box.buttons
        #expect(buttons.map(\.label) == ["移除", "註冊", "安裝 .mcpb"])
        #expect(buttons.map(\.isEnabled) == [true, true, false])
        #expect(buttons.map { $0.accessibilityLabel() ?? "" } == ["從 Claude Code 移除 MCP", "註冊到 Codex", "安裝 .mcpb Claude Desktop"])
        #expect(box.chipsByID.keys.sorted() == ["claude-desktop"])
        buttons[0].performClick(nil)
        buttons[1].performClick(nil)
        buttons[2].performClick(nil)
        #expect(harness.log.calls == ["mcpRegistration claude-code", "mcpRegistration codex"])

        // Token rotated: Claude Code needs a new registration; an app-side disabled button keeps its tooltip.
        var rows = harness.model.info.notebook.registrations
        rows[0] = SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: "需要重新註冊（token 已輪替）", actionTitle: "註冊",
                                          accent: true)
        rows[1].actionEnabled = false
        rows[1].toolTip = "註冊在 I2b 接上"
        harness.model.info.notebook.registrations = rows
        harness.sync()
        #expect(box.shownRows.map(\.hint).first == "需要重新註冊（token 已輪替）")
        #expect(box.buttons.map(\.isEnabled) == [true, false, false])
        #expect(box.buttons[1].toolTip == "註冊在 I2b 接上")
        // Rebuilt rows replace their targets (nothing piles up) and the box keeps its height.
        #expect(box.frame.height == 3 * RegistrationsBox.rowHeight + 1)
        box.buttons[0].performClick(nil)
        #expect(harness.log.calls.last == "mcpRegistration claude-code")

        // Before the app sends registrations: the three apps with `—`, no buttons.
        harness.model.info.notebook = .unavailable
        harness.sync()
        #expect(box.shownRows.map(\.name) == ["Claude Code", "Codex", "Claude Desktop"])
        #expect(box.shownRows.allSatisfy { $0.hint == "—" && !$0.isOn })
        #expect(box.buttons.isEmpty && box.chipsByID.isEmpty)
        #expect(harness.log.changes.isEmpty)
    }

    @Test func registrationModelRules() {
        let future = SettingsMCPRegistration(id: "claude-desktop", name: "Claude Desktop", hint: "未安裝", actionTitle: "安裝 .mcpb", chip: "FUTURE")
        #expect(!future.isActionable, "a chip disables the button whatever actionEnabled says")
        #expect(!SettingsMCPRegistration(id: "x", name: "X", hint: "").isActionable, "no title, no button")
        #expect(SettingsMCPRegistration(id: "x", name: "X", hint: "", actionTitle: "註冊").isActionable)
        #expect(RegistrationsBox.accessibilityLabel(title: "移除", name: "Claude Code") == "從 Claude Code 移除 MCP")
    }
}

@MainActor
@Suite struct CleanupRowsTests {
    static let keys = ["cleanup.notesStaleDays", "cleanup.notesArchiveDays", "cleanup.scratchArchiveDays", "cleanup.trashPurgeDays",
                       "cleanup.tombstoneDays", "cleanup.exempt", "cleanup.sessionsStaleDays", "cleanup.sessionsArchiveDays",
                       "cleanup.scrollbackDeleteDays", "cleanup.resumeWarning", "cleanup.digest", "cleanup.condense"]

    @Test func everyRowIsEnabled() throws {
        let harness = Harness()
        let cleanup = harness.section(.cleanup, as: CleanupSectionView.self)
        for key in Self.keys {
            let row = try #require(cleanup.rowsByKey[key], "\(key)")
            #expect(!row.isDisabledRow && row.milestone == nil && row.alphaValue == 1, "\(key)")
            for control in row.controls {
                switch control {
                case let select as SelectButton: #expect(select.isEnabled, "\(key)")
                case let toggle as SwitchToggle: #expect(toggle.isEnabled, "\(key)")
                case let seg as SxSegmented: #expect(seg.isEnabled, "\(key)")
                default: break
                }
            }
        }
    }

    @Test func selectsAndSwitchesRoundTrip() throws {
        let harness = Harness()
        let cleanup = harness.section(.cleanup)
        try #require(cleanup.control("cleanup.notesStaleDays", as: SelectButton.self)).simulateChoose(4)
        #expect(harness.model.preferences.cleanup.notesStaleDays == nil)
        try #require(cleanup.control("cleanup.trashPurgeDays", as: SelectButton.self)).simulateChoose(1)
        #expect(harness.model.preferences.cleanup.trashPurgeDays == 7)
        try #require(cleanup.control("cleanup.tombstoneDays", as: SelectButton.self)).simulateChoose(2)
        #expect(harness.model.preferences.cleanup.tombstoneDays == nil)
        try #require(cleanup.control("cleanup.exempt", as: SwitchToggle.self)).simulateClick()
        #expect(harness.model.preferences.cleanup.exempt == false)
        try #require(cleanup.control("cleanup.digest", as: SxSegmented.self)).pick(3)
        #expect(harness.model.preferences.cleanup.digest == .off)
        try #require(cleanup.control("cleanup.sessionsArchiveDays", as: SelectButton.self)).simulateChoose(2)
        #expect(harness.model.preferences.cleanup.sessionsArchiveDays == 14)
        #expect(harness.log.changes.count == 6)
        // The lifecycle strip follows the NOTES selects.
        harness.sync()
        #expect((cleanup as? CleanupSectionView)?.strip?.texts == ["ACTIVE", "STALE —", "ARCHIVE 30d", "TRASH 只有你能丟", "PURGE 7d"])
    }

    @Test func headButtonOpensCleanup() throws {
        let harness = Harness()
        let cleanup = harness.section(.cleanup, as: CleanupSectionView.self)
        let head = try #require(cleanup.suggestions)
        #expect(head.label == "查看清理建議 · 15 →" && head.isEnabled)
        head.performClick(nil)
        #expect(harness.log.calls == ["openCleanup"])
        harness.model.info.cleanupCandidateCount = nil
        harness.sync()
        #expect(head.label == "查看清理建議 →")
        harness.model.info.canOpenCleanup = false
        harness.sync()
        #expect(!head.isEnabled)
        head.performClick(nil)
        #expect(harness.log.calls == ["openCleanup"])
        #expect(CleanupSectionView.suggestionsTitle(0) == "查看清理建議 · 0 →")
    }

    @Test func condenseAccountComesFromTheFacts() throws {
        let harness = Harness()
        let cleanup = harness.section(.cleanup, as: CleanupSectionView.self)
        let account = try #require(cleanup.accountSelect)
        #expect(account.titles == ["跟隨全域登入（#3 工作）", "#1 個人", "#2 藍鵲", "#3 工作"])
        // nil (never chosen) shows the first entry.
        #expect(harness.model.preferences.cleanup.condenseAccount == nil)
        #expect(account.currentTitle == "跟隨全域登入（#3 工作）" && account.isEnabled)
        account.simulateChoose(2)
        #expect(harness.model.preferences.cleanup.condenseAccount == "2")
        account.simulateChoose(0)
        #expect(harness.model.preferences.cleanup.condenseAccount == "follow")
        harness.model.preferences.cleanup.condenseAccount = "3"
        harness.sync()
        #expect(account.currentTitle == "#3 工作")
        // An account that is gone shows `—`; no accounts: `—` and disabled.
        harness.model.preferences.cleanup.condenseAccount = "9"
        harness.sync()
        #expect(account.currentTitle == "—")
        harness.model.info.condenseAccounts = []
        harness.sync()
        #expect(account.currentTitle == "—" && !account.isEnabled)
        #expect(harness.log.changes.count == 2)
    }

    @Test func condenseModelKeepsAnOutOfListValue() throws {
        var prefs = CoddPreferences.defaults
        prefs.cleanup.condenseModel = "haiku-5"
        let harness = Harness(preferences: prefs)
        let model = try #require(harness.section(.cleanup).control("cleanup.condenseModel", as: SelectButton.self))
        #expect(model.titles == ["sonnet-5.5", "opus-5.5"])
        #expect(model.currentTitle == "haiku-5")
        model.simulateChoose(1)
        #expect(harness.model.preferences.cleanup.condenseModel == "opus-5.5")
        #expect(model.currentTitle == "opus-5.5")
    }
}

@MainActor
@Suite struct AdvancedRowsTests {
    @Test func scrollbackMirrorsTheCleanupValue() throws {
        let harness = Harness()
        let advanced = try #require(harness.section(.advanced).control("advanced.scrollbackRetentionDays", as: SelectButton.self))
        let cleanup = try #require(harness.section(.cleanup).control("cleanup.scrollbackDeleteDays", as: SelectButton.self))
        #expect(advanced.titles == ["30 天", "7 天", "90 天"], "the frozen row keeps its three options")
        #expect(cleanup.titles == ["30 天", "7 天", "90 天", "永不"])
        #expect(advanced.isEnabled && advanced.currentTitle == "30 天")

        // 12 → 09.
        advanced.simulateChoose(2)
        #expect(harness.model.preferences.cleanup.scrollbackDeleteDays == 90)
        #expect(harness.model.preferences.advanced.scrollbackRetentionDays == 30, "the M3 leaf stays stored and unused (D30)")
        harness.sync()
        #expect(cleanup.currentTitle == "90 天")

        // 09 → 12, including 永不: the select's title, not a fourth option.
        cleanup.simulateChoose(3)
        #expect(harness.model.preferences.cleanup.scrollbackDeleteDays == nil)
        harness.sync()
        #expect(advanced.currentTitle == "永不" && advanced.displayTitle == "永不")
        #expect(advanced.titles.count == 3)
        cleanup.simulateChoose(1)
        harness.sync()
        #expect(advanced.currentTitle == "7 天" && advanced.displayTitle == nil)

        // Back from 永不 by picking in 12.
        harness.model.preferences.cleanup.scrollbackDeleteDays = nil
        harness.sync()
        #expect(advanced.currentTitle == "永不")
        advanced.simulateChoose(0)
        #expect(harness.model.preferences.cleanup.scrollbackDeleteDays == 30)
        harness.sync()
        #expect(cleanup.currentTitle == "30 天")
        #expect(harness.log.changes.count == 4)
        #expect(harness.log.changes.allSatisfy { $0.advanced == CoddPreferences.defaults.advanced })
    }

    @Test func rebuildIndexIsLiveWithItsLine() throws {
        let harness = Harness()
        let view = harness.section(.advanced, as: AdvancedSectionView.self)
        let rebuild = try #require(view.rebuildButton)
        let row = try #require(view.rowsByKey["advanced.rebuildIndex"])
        #expect(rebuild.label == "重建" && rebuild.isEnabled && !row.isDisabledRow)
        #expect(row.note("index") == "已重建 · 128 則 · 0.4 s")
        rebuild.performClick(nil)
        #expect(harness.log.calls == ["rebuildNotesIndex"])
        harness.model.info.notebook.rebuilding = true
        harness.model.info.notebook.indexLine = "重建中…"
        harness.sync()
        #expect(!rebuild.isEnabled && row.note("index") == "重建中…")
        rebuild.performClick(nil)
        #expect(harness.log.calls == ["rebuildNotesIndex"])
        harness.model.info.notebook.rebuilding = false
        harness.model.info.notebook.indexLine = nil
        harness.sync()
        #expect(rebuild.isEnabled && row.note("index") == nil)
        harness.model.info.notebook = .unavailable
        harness.sync()
        #expect(!rebuild.isEnabled)
        // Import stays FUTURE, logs M5.
        #expect(view.rowsByKey["advanced.import"]?.milestone == "FUTURE")
        #expect(view.rowsByKey["advanced.logs"]?.milestone == "M5")
    }
}

/// D40: the App builds `SettingsInfo(…)`, `SettingsInfo()` and `SettingsActions(…)` with M3's
/// argument lists; those still compile and give the neutral M4 state.
@MainActor
@Suite struct M3CallShapeTests {
    /// `App/Settings/SettingsInfoBuilder.swift`'s argument list (M3), every label in its order.
    static func m3Info() -> SettingsInfo {
        SettingsInfo(
            preferencesPath: "/tmp/codd-x/preferences.json", dataRootPath: "/tmp/codd-x", logPath: nil, savedAt: nil,
            saveProblem: nil, loginItemStatus: nil, hotkeyError: nil,
            profileNames: [], defaultProfileID: nil,
            groups: [], cswap: SettingsCswapInfo(), accounts: [],
            usageSources: [],
            hooks: SettingsHooksInfo(), cleanupPeriodDays: nil, rcCount: 0,
            rcTitles: [],
            versions: [], appVersion: "1.0.0",
            platformLine: "macOS · Apple Silicon", aliasRuleHint: AliasRule.hint, externalSessionCount: nil,
            waitingCount: 0, cleanupCandidateCount: nil,
            accountsUnavailable: nil)
    }

    /// `App/Settings/SettingsCoordinator.swift`'s `SettingsActions(…)` (M3), every label in its order.
    static func m3Actions() -> SettingsActions {
        SettingsActions(
            chooseProjectRoot: {}, recordHotkeyStarted: {}, recordHotkeyFinished: {}, tryHotkey: { _ in nil },
            sendTestNotification: {}, openHookDiff: {}, reinstallHooks: {}, uninstallHooks: {}, removeLegacy: {},
            addAccount: {}, showDataRoot: {}, resetAll: {}, copyDiagnostics: {}, openRemoteBoard: {},
            setAlias: { _, _ in }, restoreBackup: { _ in }, compareBackup: { _ in }, revealPath: { _ in },
            setDefaultProfile: { _ in }, resetSection: { _ in }, rereadAccounts: {})
    }

    @Test func m3ShapesGetTheNeutralState() {
        for info in [SettingsInfo(), Self.m3Info()] {
            #expect(info.notebook == .unavailable)
            #expect(info.condenseAccounts.isEmpty && !info.canOpenCleanup)
        }
        let unavailable = SettingsNotebookInfo.unavailable
        #expect(unavailable.notesPath.isEmpty && !unavailable.mcpRunning && unavailable.port == nil && unavailable.registrations.isEmpty)
        #expect(!unavailable.canOpenFolder && !unavailable.canRotateToken && !unavailable.rebuildEnabled)
        // The new closures default to doing nothing.
        let actions = Self.m3Actions()
        actions.openNotesFolder()
        actions.rotateMCPToken()
        actions.mcpRegistration("codex")
        actions.rebuildNotesIndex()
        actions.openCleanup()
    }

    @Test func m3CallerRendersTheM4RowsNeutral() throws {
        Harness.prepare()
        let model = SettingsModel(preferences: .defaults, info: Self.m3Info())
        let root = SettingsRootView(model: model, actions: Self.m3Actions(), profilesView: NSView())
        root.frame = NSRect(x: 0, y: 0, width: 1040, height: 720)
        for section in [SettingsSection.notebook, .cleanup, .advanced] {
            root.select(section)
            root.layoutSubtreeIfNeeded()
            #expect(paintedPixels(root) > 2_000, "\(section) looks blank")
        }
        let notebook = try #require(root.sectionView(.notebook) as? NotebookSectionView)
        #expect(notebook.portBox?.value == "—" && notebook.tokenText == "—")
        #expect(notebook.openFolderButton?.isEnabled == false && notebook.rotateButton?.isEnabled == false)
        #expect(notebook.registrationsBox?.buttons.isEmpty == true)
        #expect(notebook.mcpHeadRightText == "○ 未執行")
        let cleanup = try #require(root.sectionView(.cleanup) as? CleanupSectionView)
        #expect(cleanup.suggestions?.isEnabled == false && cleanup.suggestions?.label == "查看清理建議 →")
        #expect(cleanup.accountSelect?.currentTitle == "—" && cleanup.accountSelect?.isEnabled == false)
        let advanced = try #require(root.sectionView(.advanced) as? AdvancedSectionView)
        #expect(advanced.rebuildButton?.isEnabled == false)
        #expect(advanced.rowsByKey["advanced.rebuildIndex"]?.note("index") == nil)
    }
}

@MainActor
@Suite struct M4SearchTests {
    @Test(arguments: [("輪替", SettingsSection.notebook), ("Codex", .notebook), ("M5", .notebook), ("跟隨全域登入", .cleanup),
                      ("索引", .advanced), ("Application Support/CODD/notes", .notebook)])
    func searchFindsTheM4Rows(_ query: String, _ section: SettingsSection) {
        let harness = Harness()
        harness.root.setSearchQuery(query)
        #expect(harness.root.visibleSections.contains(section), "\(query): \(harness.root.visibleSections)")
    }

    @Test func searchMarksTheRegistrationsRow() {
        let harness = Harness()
        harness.root.setSearchQuery("Claude Desktop")
        #expect(harness.root.sectionView(.notebook).rowsByKey["notebook.registrations"]?.isSearchHit == true)
        harness.root.setSearchQuery("90 天")
        #expect(harness.root.sectionView(.advanced).rowsByKey["advanced.scrollbackRetentionDays"]?.isSearchHit == true)
    }
}
