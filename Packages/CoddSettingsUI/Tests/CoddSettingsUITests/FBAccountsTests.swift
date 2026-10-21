import AppKit
import CoddPreferences
import CoddUI
import Testing
@testable import CoddSettingsUI

/// FB 「引導安裝 cswap」 and 「自動切換帳號加上警語」 in 設定 › 帳號.
@MainActor
@Suite struct FBAccountsSettingsTests {
    // MARK: cswap guide

    @Test func theGuideShowsOnlyWhileCswapIsMissingOrTooOld() throws {
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let group = try #require(accounts.guideGroup)
        #expect(group.isHidden, "the sample's cswap 0.26.0 is fine")
        #expect(SettingsCswapGuide.make(SettingsCswapInfo(pathOK: true, version: nil)) == nil, "version unknown: no guide")

        harness.model.info.cswap = SettingsCswapInfo(pathOK: false)
        harness.sync()
        #expect(!group.isHidden)
        #expect(accounts.shownGuide?.commands == ["uv tool install claude-swap", "brew install uv",
                                                  "curl -LsSf https://astral.sh/uv/install.sh | sh"])
        #expect(accounts.guideTexts.first == SettingsCswapGuide(kind: .install).lead)
        #expect(accounts.guideTexts.contains(SettingsCswapGuide.uvHint))
        #expect(accounts.guideTexts.contains { $0.contains("按 Return 才會執行") })
        #expect(group.frame.maxX <= accounts.bounds.width + 0.5)

        harness.model.info.cswap = SettingsCswapInfo(pathOK: true, version: "0.25.1", versionOK: false)
        harness.sync()
        #expect(!group.isHidden)
        #expect(accounts.shownGuide?.commands == ["uv tool upgrade claude-swap"])

        harness.model.info.cswap = SettingsCswapInfo(pathOK: true, version: "0.26.0", versionOK: true)
        harness.sync()
        #expect(group.isHidden)
    }

    @Test func theGuideButtonsCallTheApp() throws {
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        harness.model.info.cswap = SettingsCswapInfo(pathOK: false)
        harness.sync()
        // `複製` per command, `在終端機執行` after the first, `重新偵測` last.
        #expect(accounts.guideButtons.map(\.label) == ["複製", "在終端機執行", "複製", "複製", "↻ 重新偵測"])
        for button in accounts.guideButtons { button.performClick(nil) }
        #expect(harness.log.calls == ["copyText uv tool install claude-swap", "openInstallTerminal uv tool install claude-swap",
                                      "copyText brew install uv", "copyText curl -LsSf https://astral.sh/uv/install.sh | sh",
                                      "rereadAccounts"])
        #expect(harness.log.changes.isEmpty, "nothing in the preferences changes")
        // A second build (cswap still missing) keeps one set of button targets.
        let targets = accounts.targetCount
        harness.model.info.cswap = SettingsCswapInfo(pathOK: true, version: "0.25.1", versionOK: false)
        harness.sync()
        harness.model.info.cswap = SettingsCswapInfo(pathOK: false)
        harness.sync()
        #expect(accounts.targetCount == targets)
    }

    // MARK: Policy warning

    @Test func theAutoSwitchRowCarriesTheWarning() throws {
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let row = try #require(accounts.autoSwitchRow)
        #expect(row.note("policy") == "! Claude 官方不建議用多個帳號自動輪替來延長用量，可能違反 Anthropic 的使用條款；開啟前請自行評估風險。")
        #expect(SettingsAutoSwitchRisk.warning == "Claude 官方不建議用多個帳號自動輪替來延長用量，可能違反 Anthropic 的使用條款；開啟前請自行評估風險。")
        harness.root.setSearchQuery("使用條款")
        #expect(accounts.rowsByKey["accounts.autoSwitch.enabled"]?.isSearchHit == true)
        harness.root.setSearchQuery("")
    }

    @Test func turningAutoSwitchOnAsksOnceAndOffDoesNot() throws {
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let toggle = try #require(accounts.control("accounts.autoSwitch.enabled", as: SwitchToggle.self))
        // Declined: stays OFF.
        harness.log.confirmAnswer = false
        toggle.simulateClick()
        #expect(harness.log.calls == ["confirmAutoSwitch"])
        #expect(!harness.model.preferences.accounts.autoSwitch.enabled)
        #expect(!toggle.isOn)
        // Confirmed: ON.
        harness.log.confirmAnswer = true
        toggle.simulateClick()
        #expect(harness.log.calls == ["confirmAutoSwitch", "confirmAutoSwitch"])
        #expect(harness.model.preferences.accounts.autoSwitch.enabled)
        #expect(toggle.isOn)
        // OFF without asking.
        toggle.simulateClick()
        #expect(harness.log.calls.count == 2)
        #expect(!harness.model.preferences.accounts.autoSwitch.enabled)
        // Unanswered (the sheet still open): the switch stays OFF meanwhile.
        harness.log.confirmAnswer = nil
        toggle.simulateClick()
        #expect(!toggle.isOn && !harness.model.preferences.accounts.autoSwitch.enabled)
    }
}
