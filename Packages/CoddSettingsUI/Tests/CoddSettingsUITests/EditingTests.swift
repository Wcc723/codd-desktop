import AppKit
import CoddPreferences
import CoddUI
import Testing
@testable import CoddSettingsUI

/// Each control kind writes its preference through `SettingsModel.onChange` (once per edit), the
/// head buttons reset only their section, disabled and locked rows ignore input.
@MainActor
@Suite struct EditingTests {
    // MARK: Switches, segments, selects

    @Test func switchesWriteTheirPreference() throws {
        let harness = Harness()
        let general = harness.section(.general)
        let dock = try #require(general.control("general.showInDock", as: SwitchToggle.self))
        #expect(dock.isOn)
        dock.simulateClick()
        #expect(harness.model.preferences.general.showInDock == false)
        #expect(harness.log.changes.count == 1)
        #expect(harness.log.changes.last?.general.showInDock == false)

        let notifications = harness.section(.notifications)
        let sound = try #require(notifications.control("notifications.done.sound", as: SwitchToggle.self))
        sound.simulateClick()
        #expect(harness.model.preferences.notifications.done.sound == true)
        let resume = try #require(harness.section(.cleanup).control("cleanup.resumeWarning", as: SwitchToggle.self))
        resume.simulateClick()
        #expect(harness.model.preferences.cleanup.resumeWarning == false)
        #expect(harness.log.changes.count == 3)
    }

    @Test func segmentsWriteTheirPreference() throws {
        let harness = Harness()
        let quit = try #require(harness.section(.general).control("general.quitBehavior", as: SxSegmented.self))
        #expect(quit.titles == ["詢問", "全部停止", "保留"])
        quit.pick(1)
        #expect(harness.model.preferences.general.quitBehavior == .stopAll)
        quit.pick(2)
        #expect(harness.model.preferences.general.quitBehavior == .keep)
        let crt = try #require(harness.section(.appearance).control("appearance.crt", as: SxSegmented.self))
        #expect(crt.selectedIndex == 2) // D15: OFF
        crt.pick(0)
        #expect(harness.model.preferences.appearance.crt == .full)
        let icon = try #require(harness.section(.notifications).control("notifications.menuBarIcon", as: SxSegmented.self))
        #expect(icon.titles == ["僅圖示", "圖示 + 數字"])
        icon.pick(1)
        #expect(harness.model.preferences.notifications.menuBarIcon == .iconAndCounts)
        let dock = try #require(harness.section(.notifications).control("notifications.dockBadge", as: SxSegmented.self))
        dock.pick(2)
        #expect(harness.model.preferences.notifications.dockBadge == .off)
        #expect(harness.log.changes.count == 5)
        // Picking the shown segment again changes nothing.
        dock.pick(2)
        #expect(harness.log.changes.count == 5)
    }

    @Test func selectsWriteTheirPreferenceInArtboardOrder() throws {
        let harness = Harness()
        let sessions = harness.section(.sessions)
        let stale = try #require(sessions.control("sessions.staleAfterSeconds", as: SelectButton.self))
        #expect(stale.titles == ["1 小時", "30 分鐘", "4 小時", "永不"])
        stale.simulateChoose(1)
        #expect(harness.model.preferences.sessions.staleAfterSeconds == 1800)
        stale.simulateChoose(3)
        #expect(harness.model.preferences.sessions.staleAfterSeconds == nil)
        let grace = try #require(sessions.control("sessions.noHookWarningSeconds", as: SelectButton.self))
        #expect(grace.titles == ["20 秒", "10 秒", "60 秒"])
        grace.simulateChoose(2)
        #expect(harness.model.preferences.sessions.noHookWarningSeconds == 60)
        let done = try #require(harness.section(.notifications).control("notifications.done.condition", as: SelectButton.self))
        #expect(done.titles == ["僅在未聚焦時", "一律通知"])
        done.simulateChoose(1)
        #expect(harness.model.preferences.notifications.done.condition == .always)
        let font = try #require(harness.section(.appearance).control("appearance.terminalFont", as: SelectButton.self))
        font.simulateChoose(2)
        #expect(harness.model.preferences.appearance.terminalFont == "Menlo")
        let motion = try #require(harness.section(.appearance).control("appearance.reduceMotion", as: SelectButton.self))
        #expect(motion.titles == ["跟隨系統", "開啟", "關閉"])
        motion.simulateChoose(1)
        #expect(harness.model.preferences.appearance.reduceMotion == .on)
        #expect(harness.log.changes.count == 6)
        // The select follows a change made elsewhere.
        harness.model.preferences.sessions.staleAfterSeconds = 14400
        harness.sync()
        #expect(stale.selectedIndex == 2)
    }

    /// M4 interface zoom: UI 字級 is a live select over 10–20 (13 = 預設), and it follows a change
    /// made elsewhere (⌘+ / ⌘− write the same preference).
    @Test func uiFontSizeIsALiveSelectThatFollowsTheShortcuts() throws {
        let harness = Harness()
        let select = try #require(harness.section(.appearance).control("appearance.uiFontSize", as: SelectButton.self))
        #expect(select.titles.count == 11)
        #expect(select.titles.first == "10 px" && select.titles.last == "20 px")
        #expect(select.titles[3] == "13 px（預設）")
        #expect(select.currentTitle == "13 px（預設）")
        #expect(harness.section(.appearance).rowsByKey["appearance.uiFontSize"]?.isDisabledRow == false)
        select.simulateChoose(5)
        #expect(harness.model.preferences.appearance.uiFontSize == 15)
        #expect(harness.model.preferences.appearance.terminalFontSize == 13, "the select moves only the UI size")
        harness.model.preferences.appearance = harness.model.preferences.appearance.zoomed(by: 1)
        harness.sync()
        #expect(select.currentTitle == "16 px")
        let stepper = try #require(harness.section(.appearance).control("appearance.terminalFontSize", as: SxStepper.self))
        #expect(stepper.value == "14")
    }

    @Test func defaultProfileGoesThroughTheAction() throws {
        let harness = Harness()
        let select = try #require(harness.section(.sessions, as: SessionsSectionView.self).profileSelect)
        #expect(select.titles.first == "claude-default · claude")
        #expect(select.selectedIndex == 0)
        select.simulateChoose(1)
        #expect(harness.log.calls == ["setDefaultProfile claude-plan"])
        #expect(harness.log.changes.isEmpty)
    }

    // MARK: Steppers, checkboxes, inputs

    @Test func steppersClampToTheirRange() throws {
        var prefs = CoddPreferences.defaults
        prefs.appearance.terminalFontSize = 28
        prefs.accounts.autoSwitch.thresholdPercent = 20
        let harness = Harness(preferences: prefs)
        let font = try #require(harness.section(.appearance).control("appearance.terminalFontSize", as: SxStepper.self))
        font.step(1)
        #expect(harness.model.preferences.appearance.terminalFontSize == 28)
        #expect(harness.log.changes.isEmpty)
        font.step(-1)
        #expect(harness.model.preferences.appearance.terminalFontSize == 27)
        for _ in 0..<30 { font.step(-1) }
        #expect(harness.model.preferences.appearance.terminalFontSize == 8)
        let threshold = try #require(harness.section(.accounts).control("accounts.autoSwitch.thresholdPercent", as: SxStepper.self))
        threshold.step(1)
        #expect(harness.model.preferences.accounts.autoSwitch.thresholdPercent == 20)
        for _ in 0..<30 { threshold.step(-1) }
        #expect(harness.model.preferences.accounts.autoSwitch.thresholdPercent == 1)
        harness.sync()
        #expect(threshold.value == "1 %")
        #expect(font.value == "8", "the terminal size's range is 8–28 since M4")
    }

    @Test func autoSwitchCheckboxesAndSwitch() throws {
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let five = try #require(accounts.fiveHourBox)
        #expect(five.isOn)
        five.toggle()
        #expect(harness.model.preferences.accounts.autoSwitch.checkFiveHour == false)
        try #require(accounts.weeklyBox).toggle()
        #expect(harness.model.preferences.accounts.autoSwitch.checkWeekly == false)
        #expect(!accounts.isPreviewShown)
        try #require(accounts.control("accounts.autoSwitch.enabled", as: SwitchToggle.self)).simulateClick()
        #expect(harness.model.preferences.accounts.autoSwitch.enabled)
        harness.sync()
        #expect(accounts.isPreviewShown)
        #expect(accounts.previewCard?.preview.note == "· 未勾選檢查視窗，不會切換")
    }

    @Test func cooldownTakesDigitsOnlyAndClamps() throws {
        let harness = Harness()
        let cooldown = try #require(harness.section(.accounts, as: AccountsSectionView.self).cooldown)
        cooldown.simulateEntry("45")
        #expect(harness.model.preferences.accounts.autoSwitch.cooldownSeconds == 60)
        #expect(cooldown.text == "60")
        cooldown.simulateEntry("9999")
        #expect(harness.model.preferences.accounts.autoSwitch.cooldownSeconds == 3600)
        cooldown.simulateEntry("120s")
        #expect(harness.model.preferences.accounts.autoSwitch.cooldownSeconds == 120)
        #expect(cooldown.text == "120")
        let before = harness.log.changes.count
        cooldown.simulateEntry("abc")
        #expect(harness.model.preferences.accounts.autoSwitch.cooldownSeconds == 120)
        #expect(cooldown.text == "120")
        #expect(harness.log.changes.count == before)
        #expect(DigitsField.filter("1a2b３") == "12")
        #expect(DigitsField.commit("99999999999", range: 60...3600) == 3600)
        #expect(DigitsField.commit("", range: 60...3600) == nil)
    }

    @Test func quietHoursAcceptOnlyHHmm() throws {
        let harness = Harness()
        let notifications = harness.section(.notifications, as: NotificationsSectionView.self)
        let start = try #require(notifications.startInput)
        let end = try #require(notifications.endInput)
        start.simulateEntry("7:30")
        #expect(harness.model.preferences.notifications.quietHours.start == "07:30")
        #expect(start.text == "07:30")
        #expect(notifications.timeHint == nil)
        end.simulateEntry("24:00")
        #expect(harness.model.preferences.notifications.quietHours.end == "08:00")
        #expect(end.isInvalid)
        #expect(notifications.timeHint == ClockTime.invalidHint)
        end.simulateEntry("ab:cd")
        #expect(end.isInvalid)
        end.simulateEntry("6:05")
        #expect(harness.model.preferences.notifications.quietHours.end == "06:05")
        #expect(notifications.timeHint == nil)
        #expect(harness.log.changes.count == 2)
        try #require(notifications.control("notifications.quietHours.enabled", as: SwitchToggle.self)).simulateClick()
        #expect(harness.model.preferences.notifications.quietHours.enabled == false)
        for (raw, expected) in [("23:59", "23:59"), ("0:00", "00:00"), (" 08:00 ", "08:00"), ("12:60", nil), ("123:00", nil),
                                ("12:5", nil), ("１２:００", nil), ("", nil)] as [(String, String?)] {
            #expect(ClockTime.normalize(raw) == expected, "\(raw)")
        }
    }

    @Test func muteChipsToggleGroupIDs() throws {
        let harness = Harness()
        let notifications = harness.section(.notifications, as: NotificationsSectionView.self)
        #expect(notifications.groupChips.map(\.name) == ["藍鵲 · 實驗室", "藍鵲 · 網站", "個人 · Github", "CODD", "未分類"])
        #expect(notifications.groupChips.allSatisfy { !$0.isOn }) // D15: none muted
        notifications.groupChips[1].toggle()
        #expect(harness.model.preferences.notifications.mutedGroupIDs == ["g-web"])
        notifications.groupChips[4].toggle()
        #expect(harness.model.preferences.notifications.mutedGroupIDs == ["g-web", "ungrouped"])
        notifications.groupChips[1].toggle()
        #expect(harness.model.preferences.notifications.mutedGroupIDs == ["ungrouped"])
    }

    @Test func projectRootAndCswapPathInputs() throws {
        let harness = Harness()
        let root = try #require(harness.section(.general, as: GeneralSectionView.self).projectRoot)
        root.simulateEntry("  ~/Code ")
        #expect(harness.model.preferences.general.projectRoot == "~/Code")
        #expect(root.text == "~/Code")
        root.simulateEntry("   ")
        #expect(harness.model.preferences.general.projectRoot == "~/Code")
        #expect(root.text == "~/Code")
        let path = try #require(harness.section(.accounts, as: AccountsSectionView.self).cswapPath)
        path.simulateEntry("/opt/cswap/bin/cswap")
        #expect(harness.model.preferences.accounts.cswapPath == "/opt/cswap/bin/cswap")
        path.simulateEntry("")
        #expect(harness.model.preferences.accounts.cswapPath == nil)
        #expect(harness.log.changes.count == 3)
    }

    // MARK: Aliases (D34)

    @Test func aliasesFollowCswapsRule() throws {
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let rows = try #require(accounts.aliases?.rowViews)
        let six = try #require(rows.first { $0.accountID == "2" })
        #expect(six.aliasInput.text == "藍鵲")
        six.aliasInput.simulateEntry("工作")
        #expect(harness.log.calls.isEmpty)
        #expect(six.showsAliasHint)
        #expect(six.aliasInput.text == "工作")
        // A refresh of the facts keeps the refused entry and its hint on screen.
        harness.sync()
        #expect(six.aliasInput.text == "工作" && six.showsAliasHint)
        six.aliasInput.simulateEntry(" Studio ")
        #expect(harness.log.calls == ["setAlias 2 studio"])
        #expect(six.aliasInput.text == "studio")
        #expect(!six.showsAliasHint)
        // The same alias again is not sent twice; an empty field unsets it.
        let work = try #require(rows.first { $0.accountID == "3" })
        work.aliasInput.simulateEntry("工作")
        #expect(harness.log.calls == ["setAlias 2 studio"])
        work.aliasInput.simulateEntry("")
        #expect(harness.log.calls == ["setAlias 2 studio", "setAlias 3 nil"])
        #expect(harness.log.changes.isEmpty)
    }

    @Test func aliasRuleTable() {
        let cases: [(String, String?)] = [("studio", "studio"), (" Studio ", "studio"), ("work-2.b_c", "work-2.b_c"), ("工作", nil),
                                          ("123", nil), ("-x", nil), ("a b", nil), ("a@b", nil), ("", nil), ("x1", "x1"),
                                          ("\u{3000}studio\u{85}", "studio"), ("\u{FEFF}studio", nil)]
        for (raw, expected) in cases { #expect(AliasRule.normalize(raw) == expected, "\(raw)") }
        #expect(SettingsInfo().aliasRuleHint == "別名只能用英文小寫、數字與 - _ .（cswap 規則）")
    }

    // MARK: Head buttons

    @Test(arguments: [SettingsSection.general, .appearance, .sessions])
    func resetPageRestoresOnlyItsSection(_ section: SettingsSection) throws {
        var prefs = CoddPreferences.defaults
        prefs.general.showInDock = false
        prefs.general.quitBehavior = .keep
        prefs.appearance.crt = .full
        prefs.appearance.terminalFontSize = 18
        prefs.sessions.staleAfterSeconds = 1800
        prefs.notifications.done.sound = true
        let harness = Harness(preferences: prefs)
        let view = harness.section(section)
        let reset = try #require(view.descendants(ofType: CoddButton.self).first { $0.label == "還原本頁預設" })
        reset.performClick(nil)
        let after = harness.model.preferences
        #expect(harness.log.changes.count == 1)
        #expect(harness.log.calls.contains("resetSection \(section.rawValue)"))
        #expect(after.notifications.done.sound == true)
        switch section {
        case .general:
            #expect(after.general == CoddPreferences.defaults.general)
            #expect(after.appearance == prefs.appearance && after.sessions == prefs.sessions)
        case .appearance:
            #expect(after.appearance == CoddPreferences.defaults.appearance)
            #expect(after.general == prefs.general && after.sessions == prefs.sessions)
        default:
            #expect(after.sessions == CoddPreferences.defaults.sessions)
            #expect(after.general == prefs.general && after.appearance == prefs.appearance)
        }
    }

    @Test func generalResetKeepsTheHotkeyWhenTheDefaultIsRefused() {
        var prefs = CoddPreferences.defaults
        prefs.general.hotkey = CoddPreferences.Hotkey(KeyCombo(string: "ctrl+option+cmd+f12")!)
        prefs.general.showInDock = false
        let harness = Harness(preferences: prefs)
        harness.log.tryHotkeyResult = "⌥ Space 已被其他 App 使用，請改用別的組合鍵"
        let general = harness.section(.general, as: GeneralSectionView.self)
        general.resetPage()
        #expect(harness.model.preferences.general.showInDock)
        #expect(KeyCombo(harness.model.preferences.general.hotkey) == KeyCombo(string: "ctrl+option+cmd+f12"))
        #expect(general.hotkeyNote == "⌥ Space 已被其他 App 使用，請改用別的組合鍵")
        #expect(harness.log.triedHotkeys == [.optionSpace])
    }

    @Test func headButtonsCallTheirActions() throws {
        let harness = Harness()
        func press(_ section: SettingsSection, _ label: String) throws {
            let button = try #require(harness.section(section).descendants(ofType: CoddButton.self).first { $0.label == label }, "\(label)")
            button.performClick(nil)
        }
        try press(.notifications, "傳送測試通知")
        try press(.accounts, "+ 加入帳號")
        try press(.hooks, "重新安裝")
        try press(.hooks, "解除安裝")
        try press(.hooks, "預覽變更")
        try press(.hooks, "只移除舊版")
        try press(.hooks, "差異")
        try press(.advanced, "重設所有設定")
        try press(.advanced, "在 Finder 顯示")
        try press(.about, "複製版本資訊")
        try press(.general, "選擇…")
        #expect(harness.log.calls == ["sendTestNotification", "addAccount", "reinstallHooks", "uninstallHooks", "openHookDiff", "removeLegacy",
                                      "compareBackup settings.json.codd-bak-20261012-091503", "resetAll", "showDataRoot", "copyDiagnostics",
                                      "chooseProjectRoot"])
        let link = try #require(harness.section(.remote).control("remote.board", as: SxLinkButton.self))
        link.click()
        #expect(harness.log.calls.last == "openRemoteBoard")
        let mobile = try #require(harness.section(.notifications).control("notifications.remoteLink", as: SxLinkButton.self))
        mobile.click()
        #expect(harness.root.selected == .remote)
        #expect(harness.log.changes.isEmpty)
    }

    /// D1: `重新讀取` exists only while cswap's state is unusable (it may run `cswap list`, which
    /// queries usage once), at the end of the alias card, with the reason.
    @Test func rereadAppearsOnlyWhileCswapStateIsUnavailable() throws {
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let aliases = try #require(accounts.aliases)
        let reread = try #require(accounts.control("accounts.reread", as: CoddButton.self))
        #expect(aliases.noticeText == nil && reread.isHidden)
        let height = aliases.intrinsicContentSize.height

        harness.model.info.accountsUnavailable = "sequence.json 無法解析"
        harness.sync()
        #expect(aliases.noticeText == "// 讀不到 cswap 狀態：sequence.json 無法解析 · 按 重新讀取 改用 cswap list（會查詢一次用量）")
        #expect(!reread.isHidden && reread.frame.width > 0)
        // M3 review: the notice wraps instead of cutting off `會查詢一次用量` (the D1 warning).
        let band = aliases.noticeBandHeight(width: aliases.bounds.width)
        #expect(band > AccountAliasesView.noticeHeight, "two lines at the default window width")
        #expect(aliases.intrinsicContentSize.height == height + band)
        #expect(aliases.noticeBandHeight(width: 4000) == AccountAliasesView.noticeHeight, "one line where it fits")
        reread.performClick(nil)
        #expect(harness.log.calls == ["rereadAccounts"])

        // No accounts and nothing wrong: the plain empty line, no button.
        harness.model.info.accountsUnavailable = nil
        harness.model.info.accounts = []
        harness.sync()
        #expect(aliases.noticeText == "// 尚未讀到 cswap 帳號" && reread.isHidden)
        #expect(aliases.intrinsicContentSize.height == AccountAliasesView.noticeHeight)
        #expect(harness.log.changes.isEmpty)
    }

    // MARK: Text fields leave nothing typed behind (M3 review)

    /// Typed text used to commit only on Return or a focus change the field noticed on the
    /// window's next update: closing the window, switching section or quitting dropped it.
    @Test func typedTextCommitsWhenTheSectionChangesOrEditingEnds() throws {
        let harness = Harness()
        let window = NSWindow(contentRect: harness.root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = harness.root
        defer { window.contentView = nil; window.close() }
        let notifications = harness.section(.notifications, as: NotificationsSectionView.self)
        let start = try #require(notifications.startInput)
        // Type into the real field editor, never press Return, then show another section.
        #expect(window.makeFirstResponder(start.input.field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.insertText("22:00", replacementRange: editor.selectedRange())
        #expect(start.isEditing)
        harness.root.select(.general)
        #expect(harness.model.preferences.notifications.quietHours.start == "22:00", "committed on the section change")

        // Ending editing (window close, quit) commits too.
        _ = harness.section(.notifications, as: NotificationsSectionView.self)
        #expect(window.makeFirstResponder(start.input.field))
        let editor2 = try #require(window.firstResponder as? NSTextView)
        editor2.selectAll(nil)
        editor2.insertText("21:30", replacementRange: editor2.selectedRange())
        harness.root.endEditing()
        #expect(harness.model.preferences.notifications.quietHours.start == "21:30", "committed when editing ends")
        #expect(!(window.firstResponder is NSTextView))
    }

    // MARK: Disabled and locked rows (D17)

    @Test func disabledRowsIgnoreInput() throws {
        let harness = Harness()
        try #require(harness.section(.general).control("general.language", as: SelectButton.self)).simulateChoose(1)
        try #require(harness.section(.appearance).control("appearance.density", as: SxSegmented.self)).pick(1)
        try #require(harness.section(.appearance).control("appearance.nativeVibrancy", as: SwitchToggle.self)).simulateClick()
        // M4: 位置's iCloud Drive / 自訂… are `M5` segments of a live row.
        try #require(harness.section(.notebook).control("notebook.location", as: SxSegmented.self)).pick(1)
        try #require(harness.section(.notebook).control("notebook.location", as: SxSegmented.self)).pick(2)
        try #require(harness.section(.about).control("about.updateChannel", as: SxSegmented.self)).pick(1)
        try #require(harness.section(.remote).control("remote.atStartup", as: SwitchToggle.self)).simulateClick()
        // `Detected 區` is the one segment of a working row that cannot be picked yet.
        let external = try #require(harness.section(.sessions).control("sessions.externalDisplay", as: SxSegmented.self))
        external.pick(1)
        #expect(external.selectedIndex == 0)
        #expect(harness.model.preferences == CoddPreferences.defaults)
        #expect(harness.log.changes.isEmpty)
        external.pick(2)
        #expect(harness.model.preferences.sessions.externalDisplay == .hidden)
    }

    @Test func lockedRowsStayOn() throws {
        let harness = Harness()
        for (section, key) in [(SettingsSection.sessions, "sessions.autoSessionId"), (.sessions, "sessions.restoreAsStopped"),
                               (.accounts, "accounts.hideEmail")] {
            let toggle = try #require(harness.section(section).control(key, as: SwitchToggle.self), "\(key)")
            #expect(toggle.isOn && !toggle.isEnabled, "\(key)")
            toggle.simulateClick()
            #expect(toggle.isOn, "\(key)")
        }
        #expect(harness.log.changes.isEmpty)
        let sessions = harness.section(.sessions)
        #expect(sessions.rowsByKey["sessions.autoSessionId"].map { $0.controls.contains { ($0 as? SxLabel)?.text == "CODD 需要它對應 hook" } } == true)
        #expect(sessions.rowsByKey["sessions.restoreAsStopped"].map { $0.controls.contains { ($0 as? SxLabel)?.text == "CODD 一律這樣做" } } == true)
        let accounts = harness.section(.accounts)
        #expect(accounts.rowsByKey["accounts.hideEmail"].map { $0.controls.contains { ($0 as? SxLabel)?.text == "CODD 永遠不顯示 email" } } == true)
    }

    @Test func loginItemStatusIsShownUnderTheRow() {
        var info = SettingsSamples.info(now: Harness.now)
        info.loginItemStatus = "請到 系統設定 › 一般 › 登入項目 允許"
        let harness = Harness(info: info)
        let general = harness.section(.general)
        #expect(general.rowsByKey["general.launchAtLogin"]?.note("status") == "請到 系統設定 › 一般 › 登入項目 允許")
        harness.model.info.loginItemStatus = "測試資料根目錄不會註冊登入項目"
        harness.sync()
        #expect(general.rowsByKey["general.launchAtLogin"]?.note("status") == "測試資料根目錄不會註冊登入項目")
        harness.model.info.loginItemStatus = nil
        harness.sync()
        #expect(general.rowsByKey["general.launchAtLogin"]?.note("status") == nil)
    }
}
