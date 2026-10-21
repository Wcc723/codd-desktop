import AppKit
import Testing
@testable import CoddSettingsUI

/// Review fix of the fb round (ui-settings-guide-while-loading): while CODD is still looking for
/// cswap, 設定 › 帳號 says so instead of `▲ 找不到` and the INSTALL guide.
@MainActor
@Suite struct FBReviewSettingsFixTests {
    @Test func whileCswapIsBeingLocatedThereIsNoVerdictAndNoGuide() throws {
        #expect(SettingsCswapGuide.make(SettingsCswapInfo(pathOK: false, locating: true)) == nil)
        #expect(SettingsCswapGuide.make(SettingsCswapInfo(pathOK: false, locating: false))?.kind == .install)
        let harness = Harness()
        let accounts = harness.section(.accounts, as: AccountsSectionView.self)
        let group = try #require(accounts.guideGroup)
        harness.model.info.cswap = SettingsCswapInfo(pathOK: false, locating: true)
        harness.sync()
        #expect(group.isHidden && accounts.shownGuide == nil)
        #expect(accounts.versionChipText == "◌ 偵測中…")
        // The look answered: cswap is missing.
        harness.model.info.cswap = SettingsCswapInfo(pathOK: false)
        harness.sync()
        #expect(!group.isHidden && accounts.shownGuide?.kind == .install)
        #expect(accounts.versionChipText == "▲ 找不到")
    }
}
