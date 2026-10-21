import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// Every callback: back, settings, tabs, row actions, bulk actions (with the per-tab disabled
/// ones), the select's menu, and the hit-testing that routes clicks to them.
@Suite("Callbacks", .serialized)
@MainActor
struct ActionTests {
    @Test func backAndSettings() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        harness.click(harness.page.crumb.back)
        #expect(harness.log.events == ["back"])
        harness.page.policy.body.settingsButton.button.performClick(nil)
        #expect(harness.log.events == ["back", "settings"])
        // The crumb link is what a click on `← NOTEBOOK` hits.
        let back = harness.page.crumb.back
        let point = CGPoint(x: harness.frame(of: back).midX, y: harness.frame(of: back).midY)
        #expect(harness.hit(point) === back)
    }

    @Test func tabsCallBackForAnotherTabOnly() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let strip = harness.page.review.tabStrip
        harness.click(strip.tab(.notes))
        #expect(harness.log.events.isEmpty)
        harness.click(strip.tab(.sessions))
        #expect(harness.log.events == ["tab:sessions"])
        // The page shows the new tab once the app answers with its model.
        #expect(strip.tab(.notes).isOn)
        harness.update(CleanupSamples.sessions)
        #expect(strip.tab(.sessions).isOn && !strip.tab(.notes).isOn)
        #expect(harness.page.review.orderedRows.map(\.row.id) == CleanupSamples.sessionRows.map(\.id))
        #expect(harness.page.selection == ["s-usagebar", "s-gear3d"])
        #expect(harness.page.condense.isHidden)
        harness.click(strip.tab(.files))
        #expect(harness.log.events == ["tab:sessions", "tab:files"])
        let point = CGPoint(x: harness.frame(of: strip.tab(.files)).midX, y: harness.frame(of: strip.tab(.files)).midY)
        #expect(harness.hit(point) === strip.tab(.files))
    }

    @Test func rowActions() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let row = harness.row("auth-scope-q2w8")
        #expect(row.actionButtons.map(\.label) == ["保留 30 天", "封存"])
        row.actionButtons[0].performClick(nil)
        row.actionButtons[1].performClick(nil)
        #expect(harness.log.events == ["row:auth-scope-q2w8:保留 30 天", "row:auth-scope-q2w8:封存"])
        #expect(harness.page.selection == CleanupSamples.selectedNotes, "row buttons do not toggle the row")
        let button = row.actionButtons[1]
        let frame = harness.frame(of: button)
        #expect(harness.hit(CGPoint(x: frame.midX, y: frame.midY)) === button)
        let files = CleanupHarness(CleanupSamples.files)
        defer { files.tearDown() }
        files.row("f-ring-refresh").actionButtons[1].performClick(nil)
        #expect(files.log.events == ["row:f-ring-refresh:移到垃圾桶"])
    }

    @Test func bulkActionsOnNotes() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let buttons = harness.bulkButtons
        #expect(buttons.values.allSatisfy { $0.isEnabled })
        for action in CleanupBulkAction.all { buttons[action]?.performClick(nil) }
        #expect(harness.log.events == ["bulk:封存:5", "bulk:移到垃圾桶:5", "bulk:交給 Claude 濃縮…:5"])
        #expect(harness.log.bulks.allSatisfy { $0.1 == CleanupSamples.selectedNotes })
    }

    @Test func perTabDisabledBulkActions() {
        let sessions = CleanupHarness(CleanupSamples.sessions)
        defer { sessions.tearDown() }
        let buttons = sessions.bulkButtons
        #expect(buttons[CleanupBulkAction.archive]?.isEnabled == true)
        #expect(buttons[CleanupBulkAction.trash]?.isEnabled == false)
        #expect(buttons[CleanupBulkAction.condense]?.isEnabled == false)
        let files = CleanupHarness(CleanupSamples.files)
        defer { files.tearDown() }
        #expect(files.bulkButtons[CleanupBulkAction.trash]?.isEnabled == true)
        #expect(files.bulkButtons[CleanupBulkAction.condense]?.isEnabled == false)
        // Switching the same page from NOTES to SESSIONS disables them in place.
        let notes = CleanupHarness()
        defer { notes.tearDown() }
        notes.update(CleanupSamples.sessions)
        #expect(notes.bulkButtons[CleanupBulkAction.trash]?.isEnabled == false)
        notes.update(CleanupSamples.artboard)
        #expect(notes.bulkButtons[CleanupBulkAction.trash]?.isEnabled == true)
    }

    @Test func deleteArchivesTheSelection() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        harness.focusPage()
        harness.delete()
        #expect(harness.log.events == ["bulk:封存:5"])
        // Nothing selected: nothing to archive.
        harness.page.review.bulkBar.closeButton.performClick(nil)
        harness.delete()
        #expect(harness.log.events == ["bulk:封存:5", "selection:0"])
        // A tab whose 封存 is disabled ignores ⌫.
        var model = CleanupSamples.files
        model.bulkDisabled[.files] = [CleanupBulkAction.archive]
        harness.update(model)
        #expect(harness.page.selection == ["f-2b7e04"])
        harness.delete()
        #expect(harness.log.events.count == 2)
    }

    @Test func escapeGoesBack() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        harness.focusPage()
        harness.escape()
        #expect(harness.log.events == ["back"])
    }

    @Test func selectMenuHasTwoSections() throws {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let menu = harness.body.select.makeMenu()
        let titles = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        #expect(titles == ["帳號", "跟隨全域登入（#3 工作）", "#1 個人", "#2 藍鵲", "—", "模型", "sonnet-5.5", "opus-5.5"])
        #expect(menu.items[0].isSectionHeader && menu.items[5].isSectionHeader)
        #expect(menu.items.filter { $0.state == .on }.map(\.title) == ["#1 個人", "sonnet-5.5"])
        menu.performActionForItem(at: 1)
        menu.performActionForItem(at: 7)
        #expect(harness.log.events == ["account:follow", "model:opus-5.5"])
        // A disabled account is listed dimmed with its reason.
        var model = CleanupSamples.artboard
        model.condense?.accounts.append(CondenseAccountOption(id: "4", title: "#4 測試", enabled: false, hint: "沒有可用的 cswap 設定檔"))
        harness.update(model)
        let disabled = try #require(harness.body.select.makeMenu().items.first { $0.title == "#4 測試" })
        #expect(!disabled.isEnabled)
        #expect(disabled.toolTip == "沒有可用的 cswap 設定檔")
    }

    @Test func toastShowsAndUndoes() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        var undone = 0
        harness.page.showToast("✻ 已建立「摘要 · 10/15 清理（5 則）」· 5 則原稿已封存", undo: { undone += 1 })
        harness.settle()
        #expect(harness.page.visibleTexts.contains("✻ 已建立「摘要 · 10/15 清理（5 則）」· 5 則原稿已封存"))
        let toast = harness.page.subviews.compactMap { $0 as? ToastView }.first
        #expect(toast?.hasUndo == true)
        toast?.performUndo()
        #expect(undone == 1)
    }
}
