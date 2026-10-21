import AppKit
import CoddOnboarding
import CoddUI
import Testing
@testable import CoddOnboardingUI

/// FB 「引導安裝 cswap」 on step 5 (帳號): the install guide while cswap is missing, the update
/// guide while it is too old, none while it works.
@MainActor
@Suite("FB cswap guide on step 5")
struct FBCswapGuideTests {
    @Test func theStepModelCarriesTheGuide() {
        let missing = AccountsStepModel.make(cswap: .missing, rows: [])
        #expect(missing.installGuide?.kind == .install)
        #expect(missing.installGuide?.commands == ["uv tool install claude-swap", "brew install uv",
                                                   "curl -LsSf https://astral.sh/uv/install.sh | sh"])
        let old = AccountsStepModel.make(cswap: .unsupported("0.24.1"), rows: [])
        #expect(old.installGuide?.commands == ["uv tool upgrade claude-swap"])
        #expect(AccountsStepModel.make(cswap: .loading, rows: []).installGuide == nil)
        #expect(AccountsStepModel.make(cswap: .unreadable("x"), rows: []).installGuide == nil)
    }

    @Test func theGuideShowsTheCommandsAndCallsTheApp() throws {
        let harness = Harness(OnboardingSamples.step(.accounts, variant: .cswapMissing))
        defer { harness.tearDown() }
        let guide = harness.view.accountsView.guide
        #expect(!guide.isHidden)
        #expect(harness.texts.missing(["uv tool install claude-swap", "brew install uv", OnboardingCswapGuide.uvHint,
                                       OnboardingCswapGuide(kind: .install).lead, OnboardingCswapGuide.note]) == [])
        // Every command has `複製`; the first also `在終端機執行`; `↻ 重新偵測` probes again.
        try #require(guide.rows.first?.run).button.performClick(nil)
        for row in guide.rows { row.copy.button.performClick(nil) }
        guide.redetect.button.performClick(nil)
        #expect(harness.recorder.events == ["run:uv tool install claude-swap", "copy:uv tool install claude-swap", "copy:brew install uv",
                                            "copy:curl -LsSf https://astral.sh/uv/install.sh | sh", "redetect"])
        #expect(harness.view.accountsView.keyViews.count == guide.buttons.count, "the guide's buttons are key views (no add button)")
    }

    @Test func theGuideStaysInsideItsBoxAtBothSizes() {
        for size in [Harness.artboardSize, OnboardingView.minimumContentSize] {
            let harness = Harness(OnboardingSamples.step(.accounts, variant: .cswapMissing), size: size)
            defer { harness.tearDown() }
            let guide = harness.view.accountsView.guide
            #expect(guide.frame.width > 0 && guide.frame.height > 0)
            for view in guide.subviews where !view.isHidden {
                #expect(view.frame.minX >= 0 && view.frame.maxX <= guide.bounds.width + 0.5, "\(size): \(type(of: view)) \(view.frame)")
                #expect(view.frame.minY >= 0 && view.frame.maxY <= guide.bounds.height + 0.5, "\(size): \(type(of: view)) \(view.frame)")
            }
            #expect(guide.frame.maxX <= harness.view.accountsView.bounds.width + 0.5)
        }
    }

    @Test func noGuideWhileCswapWorks() {
        let harness = Harness(OnboardingSamples.step(.accounts))
        defer { harness.tearDown() }
        #expect(harness.view.accountsView.guide.isHidden)
        #expect(harness.view.accountsView.keyViews == [harness.view.accountsView.add.button])
    }
}
