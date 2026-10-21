import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// Selection by click, checkbox, space, ⌘A, the header box and `✕`; `已選 n / m`; the bulk bar's
/// visibility; how `update(_:)` adopts or keeps the selection.
@Suite("Selection", .serialized)
@MainActor
struct SelectionTests {
    func emptySelection(_ model: CleanupPageModel = CleanupSamples.artboard) -> CleanupPageModel {
        var model = model
        model.selected = []
        return model
    }

    @Test func artboardStartsWithFiveSelected() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        #expect(harness.page.selection == CleanupSamples.selectedNotes)
        #expect(harness.page.review.header.countLabel.displayedText == "已選 5 / 8")
        let selected = harness.page.review.orderedRows.filter(\.isSelected).map(\.row.id)
        #expect(Set(selected) == CleanupSamples.selectedNotes)
        #expect(harness.page.review.orderedRows.filter(\.isSelected).allSatisfy { $0.checkbox.isOn })
        #expect(!harness.page.review.bulkBar.isHidden)
        #expect(harness.page.review.bulkBar.countChip.displayedText == "已選 5")
    }

    @Test func clickingARowOrItsCheckboxToggles() {
        let harness = CleanupHarness(emptySelection())
        defer { harness.tearDown() }
        #expect(harness.page.review.bulkBar.isHidden, "no bulk bar without a selection")
        let row = harness.row("gear3d-perf-p4m2")
        harness.click(row)
        #expect(harness.page.selection == ["gear3d-perf-p4m2"])
        #expect(row.isSelected && row.checkbox.isOn)
        #expect(harness.page.focusedRowID == "gear3d-perf-p4m2")
        #expect(harness.page.review.header.countLabel.displayedText == "已選 1 / 8")
        #expect(!harness.page.review.bulkBar.isHidden)
        #expect(harness.page.review.bulkBar.countChip.displayedText == "已選 1")
        // The checkbox of another row.
        let other = harness.row("scratch-1015-z9x1")
        harness.click(other.checkbox)
        #expect(harness.page.selection == ["gear3d-perf-p4m2", "scratch-1015-z9x1"])
        #expect(other.checkbox.isOn)
        // Clicking again clears it.
        harness.click(row)
        #expect(harness.page.selection == ["scratch-1015-z9x1"])
        #expect(!row.checkbox.isOn)
        #expect(harness.log.selections == [["gear3d-perf-p4m2"], ["gear3d-perf-p4m2", "scratch-1015-z9x1"], ["scratch-1015-z9x1"]])
        // The click made the page the first responder (space works next).
        #expect(harness.window.firstResponder === harness.page)
    }

    @Test func spaceTogglesTheFocusedRowAndArrowsMoveIt() {
        let harness = CleanupHarness(emptySelection())
        defer { harness.tearDown() }
        harness.focusPage()
        // No focus yet: space takes the first row.
        harness.space()
        #expect(harness.page.selection == ["gear3d-perf-p4m2"])
        #expect(harness.row("gear3d-perf-p4m2").isFocused)
        harness.down()
        harness.down()
        #expect(harness.page.focusedRowID == "scratch-1015-z9x1")
        #expect(harness.row("scratch-1015-z9x1").isFocused && !harness.row("gear3d-perf-p4m2").isFocused)
        harness.space()
        #expect(harness.page.selection == ["gear3d-perf-p4m2", "scratch-1015-z9x1"])
        harness.space()
        #expect(harness.page.selection == ["gear3d-perf-p4m2"])
        harness.up()
        harness.up()
        harness.up()
        #expect(harness.page.focusedRowID == "gear3d-perf-p4m2", "clamped at the first row")
        // Losing the first responder hides the focus outline but keeps the row.
        harness.window.makeFirstResponder(nil)
        #expect(!harness.row("gear3d-perf-p4m2").isFocused)
        #expect(harness.page.focusedRowID == "gear3d-perf-p4m2")
    }

    @Test func commandASelectsEveryRowOfTheTab() {
        let harness = CleanupHarness(emptySelection())
        defer { harness.tearDown() }
        harness.focusPage()
        harness.commandA()
        #expect(harness.page.selection == Set(CleanupSamples.noteRows.map(\.id)))
        #expect(harness.page.review.header.countLabel.displayedText == "已選 8 / 8")
        #expect(harness.page.review.header.checkbox.isOn)
        #expect(harness.log.selections.count == 1)
        // Again: nothing changes, no second callback.
        harness.commandA()
        #expect(harness.log.selections.count == 1)
        // The menu's Select All (selectAll:) does the same.
        harness.page.review.bulkBar.closeButton.performClick(nil)
        #expect(harness.page.selection.isEmpty)
        harness.page.selectAll(nil)
        #expect(harness.page.selection.count == 8)
    }

    @Test func headerCheckboxSelectsAllThenNone() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let header = harness.page.review.header.checkbox
        #expect(!header.isOn, "5 of 8: the header box is off (artboard)")
        harness.click(header)
        #expect(harness.page.selection.count == 8 && header.isOn)
        harness.click(header)
        #expect(harness.page.selection.isEmpty && !header.isOn)
        #expect(harness.page.review.bulkBar.isHidden)
    }

    @Test func closeClearsTheSelection() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        harness.page.review.bulkBar.closeButton.performClick(nil)
        harness.settle()
        #expect(harness.page.selection.isEmpty)
        #expect(harness.log.selections == [[]])
        #expect(harness.page.review.bulkBar.isHidden)
        #expect(harness.page.review.header.countLabel.displayedText == "已選 0 / 8")
        #expect(harness.page.review.orderedRows.allSatisfy { !$0.isSelected && !$0.checkbox.isOn })
    }

    @Test func updateAdoptsAChangedSelectionAndKeepsItsOwnOtherwise() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        // The user deselects one row; the app sends a model whose `selected` did not change.
        harness.click(harness.row("keynote-ch2-a1b2"))
        #expect(harness.page.selection.count == 4)
        var model = CleanupSamples.artboard
        model.meta = "每週一 09:00 · 14 項 · 上次 10/08"
        harness.update(model)
        #expect(harness.page.selection.count == 4, "the page keeps its own selection")
        // The app sets a new selection: adopted.
        model.selected = ["gear3d-perf-p4m2"]
        harness.update(model)
        #expect(harness.page.selection == ["gear3d-perf-p4m2"])
        // Rows that go away leave the selection; the focus moves to a row that is still there.
        harness.click(harness.row("remote-ctl-i9j0"))
        #expect(harness.page.focusedRowID == "remote-ctl-i9j0")
        model.rows.removeLast()
        harness.update(model)
        #expect(harness.page.selection == ["gear3d-perf-p4m2"])
        #expect(harness.page.focusedRowID == "pixel-town-g7h8")
        #expect(harness.page.review.header.countLabel.displayedText == "已選 1 / 7")
        #expect(harness.page.review.rowViews["remote-ctl-i9j0"] == nil)
    }

    @Test func rowViewsAreReusedAcrossUpdates() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let before = harness.row("gear3d-perf-p4m2")
        var model = CleanupSamples.artboard
        model.rows[0].badge = "stale 22d"
        harness.update(model)
        let after = harness.row("gear3d-perf-p4m2")
        #expect(before === after)
        #expect(after.texts.contains("stale 22d"))
    }
}
