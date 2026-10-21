import AppKit
import CoddPreferences
import CoddUI
import Testing
@testable import CoddSettingsUI

@MainActor
@Suite struct SearchTests {
    @Test func searchFiltersTheNavAndMarksRows() throws {
        let harness = Harness()
        harness.root.setSearchQuery("crt")
        #expect(harness.root.visibleSections.contains(.appearance))
        #expect(!harness.root.visibleSections.contains(.general))
        let appearance = harness.root.sectionView(.appearance)
        #expect(appearance.rowsByKey["appearance.crt"]?.isSearchHit == true)
        #expect(appearance.rowsByKey["appearance.density"]?.isSearchHit == false)
        // Group heads hide with their items: WORKFLOW has no match for "crt".
        #expect(harness.root.sidebarView.items[.sessions]?.isHidden == true)
        harness.root.setSearchQuery("")
        #expect(harness.root.visibleSections == SettingsSection.allCases)
        #expect(appearance.rowsByKey["appearance.crt"]?.isSearchHit == false)
    }

    @Test(arguments: ["CRT", "ＣＲＴ", "Crt", "  crt  "])
    func searchIsCaseAndWidthInsensitive(_ query: String) {
        let harness = Harness()
        harness.root.setSearchQuery(query)
        #expect(harness.root.visibleSections.first == .appearance, "\(query)")
    }

    @Test func searchIsDiacriticInsensitive() {
        #expect(SettingsSearch.matches("Café", query: "cafe"))
        #expect(SettingsSearch.matches("cafe", query: "CAFÉ"))
        #expect(!SettingsSearch.matches("cafe", query: ""))
        let harness = Harness()
        harness.root.setSearchQuery("résumé")
        #expect(harness.root.visibleSections.contains(.cleanup))
        #expect(harness.root.sectionView(.cleanup).rowsByKey["cleanup.resumeWarning"]?.isSearchHit == true)
    }

    @Test func enterJumpsToTheFirstMatch() {
        let harness = Harness()
        harness.root.setSearchQuery("cswap")
        #expect(harness.root.visibleSections.first == .accounts)
        harness.root.submitSearch()
        #expect(harness.root.selected == .accounts)
        harness.root.setSearchQuery("zzzz-nothing")
        #expect(harness.root.visibleSections.isEmpty)
        harness.root.submitSearch()
        #expect(harness.root.selected == .accounts)
    }

    @Test func searchFindsFactRowsAndHighlightsThem() throws {
        let harness = Harness()
        harness.root.setSearchQuery("藍鵲")
        #expect(harness.root.visibleSections.contains(.accounts))
        #expect(harness.root.visibleSections.contains(.notifications)) // the 依群組靜音 chips
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let rows = try #require(accounts.aliases?.rowViews)
        #expect(rows.first { $0.accountID == "2" }?.isSearchHit == true)
        #expect(rows.first { $0.accountID == "3" }?.isSearchHit == false)
        harness.root.setSearchQuery("osascript")
        #expect(harness.root.visibleSections == [.hooks])
    }

    @Test func searchMatchesOptionTitlesAndSectionNames() {
        let harness = Harness()
        harness.root.setSearchQuery("全部停止")
        #expect(harness.root.visibleSections == [.general])
        harness.root.setSearchQuery("快捷鍵")
        #expect(harness.root.visibleSections.contains(.shortcuts) && harness.root.visibleSections.contains(.general))
        harness.root.setSearchQuery("New profile")
        #expect(harness.root.visibleSections == [.profiles])
    }
}

@MainActor
@Suite struct ModelTests {
    @Test func updateCallsOnChangeOnlyForRealChanges() {
        let model = SettingsModel()
        var calls = 0
        model.onChange = { _ in calls += 1 }
        model.update { $0.general.showInDock = true }
        #expect(calls == 0)
        model.update { $0.general.showInDock = false }
        #expect(calls == 1)
        model.preferences.general.showInDock = true
        #expect(calls == 1)
    }

    @Test func resetSectionTouchesOnlyThatSection() {
        var prefs = CoddPreferences.defaults
        prefs.notifications.waiting.sound = false
        prefs.notifications.pausedUntil = Date(timeIntervalSince1970: 1_800_000_000)
        prefs.cleanup.digest = .off
        prefs.general.hotkey = CoddPreferences.Hotkey(KeyCombo(string: "cmd+shift+k")!)
        let model = SettingsModel(preferences: prefs)
        var calls = 0
        model.onChange = { _ in calls += 1 }
        model.resetSection(.notifications)
        #expect(model.preferences.notifications.waiting.sound == true)
        #expect(model.preferences.notifications.pausedUntil == prefs.notifications.pausedUntil)
        #expect(model.preferences.cleanup.digest == .off)
        model.resetSection(.shortcuts)
        #expect(KeyCombo(model.preferences.general.hotkey) == .optionSpace)
        model.resetSection(.profiles)
        model.resetSection(.hooks)
        #expect(calls == 2)
    }

    @Test func autoSwitchPreviewMatchesTheArtboard() {
        var auto = CoddPreferences.AutoSwitch()
        auto.enabled = true
        let preview = SettingsAutoSwitchPreview.compute(accounts: SettingsSamples.accounts, autoSwitch: auto)
        #expect(preview.rows.map(\.distance) == ["1w 46% · 距切換 44%", "1w 15% · 距切換 13%", "5h 未開始 · 距切換 98%"])
        #expect(preview.rows.map(\.distanceTone) == [nil, .warn, nil])
        #expect(preview.rows.map(\.isNext) == [true, false, false])
        #expect(preview.current == "#3 工作" && preview.next == "#2 藍鵲" && preview.note == "")
        auto.thresholdPercent = 15
        let reached = SettingsAutoSwitchPreview.compute(accounts: SettingsSamples.accounts, autoSwitch: auto)
        #expect(reached.rows[1].distance == "1w 15% · 已達門檻" && reached.rows[1].distanceTone == .crit)
        #expect(reached.note == "· 已達門檻，會立即切換")
        auto.thresholdPercent = 20
        auto.checkWeekly = false
        let fiveOnly = SettingsAutoSwitchPreview.compute(accounts: SettingsSamples.accounts, autoSwitch: auto)
        #expect(fiveOnly.rows.map(\.distance) == ["5h 98% · 距切換 78%", "5h 91% · 距切換 71%", "5h 未開始 · 距切換 80%"])
        #expect(fiveOnly.rows.allSatisfy { $0.tickFiveHour && !$0.tickWeekly })
        auto.checkFiveHour = false
        let none = SettingsAutoSwitchPreview.compute(accounts: SettingsSamples.accounts, autoSwitch: auto)
        #expect(none.note == "· 未勾選檢查視窗，不會切換" && none.next == "—")
        #expect(none.rows.allSatisfy { $0.distance == "未檢查任何視窗" })
        var low = SettingsSamples.accounts
        for index in low.indices { low[index].weekly = SettingsQuota(remaining: 1) }
        auto = CoddPreferences.AutoSwitch(enabled: true)
        let exhausted = SettingsAutoSwitchPreview.compute(accounts: low, autoSwitch: auto)
        #expect(exhausted.note == "· 所有帳號都低於 2%，不切換" && exhausted.next == "—")
        // A relogin account is never a target; an unknown window never qualifies.
        var accounts = SettingsSamples.accounts
        accounts[0].isEligibleTarget = false
        accounts[2].weekly = SettingsQuota(remaining: nil)
        #expect(SettingsAutoSwitchPreview.compute(accounts: accounts, autoSwitch: auto).next == "—")
    }

    @Test func modelPreviewPrefersTheAppsRows() {
        let model = SettingsModel(info: SettingsSamples.info(now: Harness.now))
        #expect(model.autoSwitchPreview.next == "#2 藍鵲")
        let row = SettingsPreviewRow(id: "9", slot: "#9", alias: "x", resetIn: "1d", distance: "app",
                                     fiveHour: SettingsQuota(remaining: 50), weekly: SettingsQuota(remaining: 50))
        model.info.autoSwitchPreview = [row]
        model.info.autoSwitchNext = "#9 x"
        #expect(model.autoSwitchPreview.rows == [row] && model.autoSwitchPreview.next == "#9 x")
    }

    @Test func thresholdTicksFollowTheAutoSwitchPreferences() throws {
        var prefs = CoddPreferences.defaults
        prefs.accounts.autoSwitch.enabled = true
        prefs.accounts.autoSwitch.checkFiveHour = false
        let harness = Harness(preferences: prefs)
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let card = try #require(accounts.aliases)
        #expect(card.rowViews.count == 3)
        #expect(accounts.previewCard?.preview.rows.allSatisfy { !$0.tickFiveHour && $0.tickWeekly } == true)
        #expect(accounts.isPreviewShown)
    }
}
