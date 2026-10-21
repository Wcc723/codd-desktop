import AppKit
import CoddOnboarding
import CoddSettingsUI
import CoddStatusUI
import Foundation
import Testing
@testable import CODD

// FB 「引導安裝 cswap」 and 「自動切換帳號加上警語」 on the app: STATUS, 設定 › 帳號 and onboarding
// step 5 show the same commands and the same warning; `在終端機執行` types only a guide command
// and never a Return; Settings' buttons reach the app's handlers. In-memory preferences only.
@MainActor
@Suite("FB accounts (app)")
struct FBAccountsAppTests {
    @Test func theThreeSurfacesShowTheSameCommands() {
        for (status, settings, onboarding) in [
            (CswapInstallGuide(kind: .install), SettingsCswapGuide(kind: .install), OnboardingCswapGuide(kind: .install)),
            (CswapInstallGuide(kind: .upgrade), SettingsCswapGuide(kind: .upgrade), OnboardingCswapGuide(kind: .upgrade)),
        ] {
            #expect(status.commands == settings.commands && settings.commands == onboarding.commands)
            #expect(status.lead == settings.lead && settings.lead == onboarding.lead)
        }
        #expect(CswapInstallGuide(kind: .install).command == "uv tool install claude-swap")
        #expect(CswapInstallGuide.uvCommands == ["brew install uv", "curl -LsSf https://astral.sh/uv/install.sh | sh"])
        #expect(CswapInstallGuide.projectURL == SettingsCswapGuide.projectURL && SettingsCswapGuide.projectURL == OnboardingCswapGuide.projectURL)
        #expect(CswapInstallGuide.uvHint == SettingsCswapGuide.uvHint && SettingsCswapGuide.uvHint == OnboardingCswapGuide.uvHint)
    }

    @Test func theWarningIsTheSameEverywhere() {
        let text = "Claude 官方不建議用多個帳號自動輪替來延長用量，可能違反 Anthropic 的使用條款；開啟前請自行評估風險。"
        #expect(AutoSwitchModel.policyWarning == text)
        #expect(SettingsAutoSwitchRisk.warning == text)
        #expect(AutoSwitchModel.policyLine == "! " + text)
        #expect(AutoSwitchConfirmation.title == SettingsAutoSwitchRisk.title)
    }

    @Test func theTerminalGetsOnlyAGuideCommandAndNoReturn() {
        for command in CswapInstallGuide(kind: .install).commands + CswapInstallGuide(kind: .upgrade).commands {
            let typing = CswapGuideHandlers.typing(for: command)
            #expect(typing == command, "typed as shown")
            #expect(typing?.contains("\r") == false && typing?.contains("\n") == false, "never run: no Return")
        }
        #expect(CswapGuideHandlers.typing(for: "uv tool install claude-swap\r") == nil)
        #expect(CswapGuideHandlers.typing(for: "rm -rf ~") == nil)
        #expect(CswapGuideHandlers.typing(for: "") == nil)
        #expect(CswapGuideHandlers.commands.count == 4)
    }

    @MainActor
    final class Calls {
        var copied: [String] = []
        var opened: [String] = []
    }

    @Test func settingsGuideButtonsReachTheAppHandlers() {
        let calls = Calls()
        var environment = SettingsCoordinator.Environment(preferences: .inMemory())
        environment.cswapGuide = CswapGuideHandlers(copy: { calls.copied.append($0) }, openTerminal: { calls.opened.append($0) })
        let coordinator = SettingsCoordinator(environment: environment)
        let actions = coordinator.makeActions()
        actions.copyText("brew install uv")
        actions.openInstallTerminal("uv tool install claude-swap")
        #expect(calls.copied == ["brew install uv"])
        #expect(calls.opened == ["uv tool install claude-swap"])
    }

    @Test func theSettingsGuideFollowsTheCswapFacts() {
        #expect(SettingsCswapGuide.make(SettingsCswapInfo(pathOK: false))?.kind == .install)
        #expect(SettingsCswapGuide.make(SettingsCswapInfo(pathOK: true, version: "0.25.1", versionOK: false))?.kind == .upgrade)
        #expect(SettingsCswapGuide.make(SettingsCswapInfo(pathOK: true, version: "0.26.0", versionOK: true)) == nil)
        // STATUS derives its guide from the D1 / D3 lines StatusPageData already writes.
        let status = StatusPageData.unavailableLine(.noCswap)
        let section = AccountsSectionModel(version: nil, rootPath: nil, countHint: "不顯示 email", cards: [], canAdd: false,
                                           unavailable: status, autoSwitch: AutoSwitchModel(on: false, chips: []))
        #expect(section.guide?.kind == .install)
        var old = section
        old.unavailable = StatusPageData.unavailableLine(.unsupported(version: "0.25.1"))
        #expect(old.guide?.kind == .upgrade)
        old.unavailable = StatusPageData.unavailableLine(.unreadable(reason: "x"))
        #expect(old.guide == nil)
    }
}
