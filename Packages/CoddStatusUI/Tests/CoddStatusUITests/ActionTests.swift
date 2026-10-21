import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// Button enablement and the closures each control calls, per state.
@Suite("Buttons and actions", .serialized)
@MainActor
struct ActionTests {
    @Test func accountButtonsPerState() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let two = harness.card("2"), three = harness.card("3"), one = harness.card("1")
        #expect(two.button.label == "Switch" && two.button.isEnabled)
        #expect(three.button.label == "Active" && !three.button.isEnabled)
        #expect(one.button.label == "Switch" && one.button.isEnabled)
        two.button.performClick(nil)
        three.button.performClick(nil)
        one.button.performClick(nil)
        #expect(harness.log.events == ["switchAccount:2", "switchAccount:1"])

        // Switching to #2: its button says 切換中… with the progress line; #1 is disabled with a reason.
        harness.apply(StatusSamples.model(.switching))
        #expect(two.button.label == "切換中…" && !two.button.isEnabled)
        #expect(two.noteText == "◌ 等待 Claude Code credential lock… 9s（1/3）")
        #expect(one.button.label == "Switch" && !one.button.isEnabled)
        #expect(one.noteText == "另一個帳號切換中…")
        #expect(one.button.toolTip == "另一個帳號切換中…")
        #expect(three.noteText == nil)
        two.button.performClick(nil)
        one.button.performClick(nil)
        #expect(harness.log.events == ["switchAccount:2", "switchAccount:1"])
    }

    @Test func addCardAndAutoSwitchRow() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let accounts = harness.page.accounts
        #expect(!accounts.addCard.isHidden)
        accounts.addCard.performClick(nil)
        accounts.autoSwitch.settingsButton.performClick(nil)
        // The switch asks the app and keeps showing the model's state until a new model comes;
        // turning it ON asks for confirmation first (FB).
        #expect(!accounts.autoSwitch.toggle.isOn)
        _ = accounts.autoSwitch.toggle.accessibilityPerformPress()
        #expect(!accounts.autoSwitch.toggle.isOn)
        #expect(harness.log.events == ["addAccount", "openAutoSwitch", "confirmAutoSwitch", "toggleAutoSwitch"])

        harness.apply(StatusSamples.model(.accountsMissing))
        #expect(accounts.addCard.isHidden)
    }

    @Test func hooksButtonsFollowTheModel() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let card = harness.page.hooks.card
        for button in [card.previewButton, card.updateButton, card.uninstallButton, card.removeLegacyButton] {
            #expect(button.isEnabled && !button.isHidden)
            button.performClick(nil)
        }
        let osascript = card.foreignRows[1]
        #expect(card.foreignRows[0].disableButton.isHidden)
        #expect(!osascript.disableButton.isHidden && osascript.disableButton.isEnabled)
        osascript.disableButton.performClick(nil)
        #expect(harness.log.events == ["previewHooks", "update", "uninstall", "removeLegacy", "disableDuplicateNotifications"])

        var model = StatusSamples.spec()
        model.hooks.canPreview = false
        model.hooks.canUpdate = false
        model.hooks.canUninstall = false
        model.hooks.canRemoveLegacy = false
        model.hooks.canDisableDuplicates = false
        harness.apply(model)
        for button in [card.previewButton, card.updateButton, card.uninstallButton, card.removeLegacyButton, osascript.disableButton] {
            #expect(!button.isEnabled)
            button.performClick(nil)
        }
        #expect(harness.log.events.count == 5)

        // No CODD web leftovers: no legacy line and no `[只移除舊版]`.
        harness.apply(StatusSamples.model(.hooksClean))
        #expect(card.removeLegacyButton.isHidden)
        #expect(!card.visibleTexts.contains { $0.contains("舊版") })
    }

    @Test func endpointDetailsDisclosure() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let card = harness.page.hooks.card
        // The sample has no diagnostics: no toggle.
        #expect(card.detailsButton.isHidden)
        var model = StatusSamples.spec()
        model.hooks.details = ["STATE ● LISTENING · http://127.0.0.1:47821/hooks", "ACCEPTED 42", "REJECTED 1 · 403 ×1"]
        harness.apply(model)
        harness.page.layoutSubtreeIfNeeded()
        #expect(!card.detailsButton.isHidden && card.detailsButton.label == "▸ 詳細")
        #expect(card.detailsBlock.isHidden)
        let closed = card.preferredHeight(width: card.bounds.width)
        card.detailsButton.performClick(nil)
        #expect(card.detailsOpen && card.detailsButton.label == "▾ 詳細")
        #expect(!card.detailsBlock.isHidden)
        #expect(card.detailsBlock.displayedText.contains("REJECTED 1 · 403 ×1"))
        #expect(card.preferredHeight(width: card.bounds.width) > closed)
        // A new model keeps the disclosure open; the toggle is not one of the page's actions.
        model.hooks.details.append("LAST REJECTION —")
        harness.apply(model)
        #expect(card.detailsOpen && !card.detailsBlock.isHidden)
        #expect(card.detailsBlock.displayedText.hasSuffix("LAST REJECTION —"))
        #expect(harness.log.events.isEmpty)
        card.detailsButton.performClick(nil)
        #expect(card.detailsBlock.isHidden)
        #expect(card.preferredHeight(width: card.bounds.width) == closed)
    }

    @Test func sidebarAndPageControls() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        harness.sidebar.refreshButton.performClick(nil)
        harness.page.refreshButton.performClick(nil)
        #expect(harness.sidebar.pauseButton.label == "暫停")
        harness.sidebar.pauseButton.performClick(nil)
        harness.sidebar.goLive.performClick(nil)
        harness.sidebar.needsRows[0].performClick(nil)
        harness.sidebar.needsRows[2].performClick(nil)
        harness.page.remote.settingsLink.performClick(nil)
        #expect(harness.log.events == ["refresh", "refresh", "togglePause", "openSessions", "openSession:s1", "openSession:s3",
                                       "openRemoteSettings"])

        harness.apply(StatusSamples.model(.paused))
        #expect(harness.sidebar.pauseButton.label == "繼續")
        #expect(harness.sidebarTexts.contains("已暫停"))
        #expect(harness.page.metaText == "UPDATED 10:42:07 · 已暫停")
        #expect(harness.page.liveChipText == "○PAUSED")
        var offline = StatusSamples.spec()
        offline.live = false
        harness.apply(offline)
        #expect(harness.page.liveChipText == "○OFFLINE")
    }

    @Test func needsYouCollapsesAndHidesWhenEmpty() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        #expect(harness.sidebar.needsRows.count == 3)
        #expect(harness.sidebar.needsRows.allSatisfy { !$0.isHidden })
        var model = StatusSamples.spec()
        model.needsYou = []
        harness.apply(model)
        #expect(!harness.sidebarTexts.contains { $0.contains("NEEDS YOU") })
        #expect(!harness.sidebar.isTicking)
        harness.apply(StatusSamples.spec())
        #expect(harness.sidebarTexts.contains("◆ NEEDS YOU 3"))
        #expect(harness.sidebar.isTicking)
    }
}
