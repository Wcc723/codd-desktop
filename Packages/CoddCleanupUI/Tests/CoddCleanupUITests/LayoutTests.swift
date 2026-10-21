import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// Geometry against the Cleanup artboard measured in Chrome at 1440 × 900 (the page is the
/// 1368 × 876 main area): padding 18 / 36, the 928 + 24 + 344 grid, the table columns, row heights,
/// the bulk bar and the POLICY card under both.
@Suite("Artboard geometry", .serialized)
@MainActor
struct LayoutTests {
    @Test func gridMatchesTheArtboard() {
        let harness = CleanupHarness(CleanupSamples.artboardAsDrawn)
        defer { harness.tearDown() }
        let page = harness.page
        #expect(page.crumb.frame == CGRect(x: 36, y: 18, width: 1296, height: 18))
        #expect(abs(page.titleLine.frame.minY - 44) < 1)
        #expect(abs(page.metaRule.frame.minY - 83.19) < 1)
        // `.nb-cl-grid` at 117.69: the table 928 wide, the card 344 at 988.
        #expect(page.review.frame.minX == 36 && page.review.frame.width == 928)
        #expect(abs(page.review.frame.minY - 117.69) < 1)
        #expect(page.condense.frame.minX == 988 && page.condense.frame.width == 344)
        #expect(page.condense.frame.minY == page.review.frame.minY)
        // The grid row stretches both to the card (the artboard's 688).
        #expect(page.condense.frame.height == page.review.frame.height)
        #expect(abs(page.condense.frame.height - 688) < 8, "card \(page.condense.frame.height)")
        // POLICY spans both columns, 20 below.
        #expect(page.policy.frame.minX == 36 && page.policy.frame.width == 1296)
        #expect(page.policy.frame.minY == page.review.frame.maxY + 20)
        #expect(abs(page.policy.frame.height - 134.75) < 4, "policy \(page.policy.frame.height)")
    }

    @Test func tableColumnsTabsAndRows() {
        let harness = CleanupHarness(CleanupSamples.artboardAsDrawn)
        defer { harness.tearDown() }
        let review = harness.page.review
        #expect(review.columns.widths == [36, 226, 184, 128, 156, 196])
        #expect(review.tabStrip.frame == CGRect(x: 1, y: 1, width: 926, height: 30))
        #expect(review.header.frame == CGRect(x: 1, y: 31, width: 926, height: 30))
        // Tabs `NOTES_ 8` 89.7, `SESSIONS 5` 102.8, `FILES 2` 80.1 (Chrome).
        let tabWidths = review.tabStrip.tabs.map(\.frame.width)
        for (width, expected) in zip(tabWidths, [89.69, 102.8, 80.13]) { #expect(abs(width - expected) < 5, "tab \(width)") }
        // Rows 52.75 · 62.83 (two-line sub) · 52.75 · 65 (two-line why) · 52.75 × 4.
        let heights = review.orderedRows.map(\.frame.height)
        let expected: [CGFloat] = [52.75, 62.83, 52.75, 65, 52.75, 52.75, 52.75, 52.75]
        #expect(heights.count == 8)
        for (height, want) in zip(heights, expected) { #expect(abs(height - want) < 1.5, "row \(height) vs \(want)") }
        #expect(review.rowsView.frame.minY == 61)
        // Cells: the title at the ITEM content box (73 + 8 inside the panel), the actions right-aligned.
        let first = review.orderedRows[0]
        #expect(first.checkbox.frame.minX == 14)
        #expect(first.actionButtons.count == 2)
        #expect(abs(first.actionButtons[1].frame.maxX - (926 - 8)) < 0.5)
        // The bulk bar: 47 px at the panel's bottom (inside the border).
        #expect(!review.bulkBar.isHidden)
        #expect(review.bulkBar.frame.height == 47)
        #expect(review.bulkBar.frame.maxY == review.bounds.height - 1)
    }

    @Test func condenseCardBodyFollowsTheArtboard() {
        let harness = CleanupHarness(CleanupSamples.artboardAsDrawn)
        defer { harness.tearDown() }
        let body = harness.body
        // Content box 306 wide at 18 + 1 inside the card.
        #expect(body.frame.width == 306)
        #expect(body.sources.frame.height == 102)
        #expect(abs(body.sources.frame.minY - (202.19 - 117.69 - 17)) < 1.5)
        #expect(body.select.frame.height == 30)
        // The preview at its natural 263.75 (Chrome), the note 33.25, then the 28 px go row.
        #expect(abs(body.previewBox.frame.height - 263.75) < 2, "preview \(body.previewBox.frame.height)")
        #expect(abs(body.note.frame.height - 33.25) < 1)
        #expect(body.generate.button.frame.height == 28)
        #expect(abs(body.generate.button.frame.maxY - body.bounds.height) < 1)
    }

    @Test func withoutCondenseTheTableTakesTheFullWidth() {
        let harness = CleanupHarness(CleanupSamples.sessions)
        defer { harness.tearDown() }
        let page = harness.page
        #expect(page.condense.isHidden)
        #expect(page.review.frame.width == 1296)
        let columns = page.review.columns.widths
        #expect(columns.reduce(0, +) == 1294)
        #expect(columns[0] == 36 && columns[5] == 196)
        // `resume expires 4d` widens STATUS past 128.
        #expect(columns[3] > 128)
        #expect(columns[1] > 226 && columns[2] > 184 && columns[4] > 156)
        #expect(page.policy.frame.minY == page.review.frame.maxY + 20)
    }

    @Test func narrowPagesStackTheCard() {
        let harness = CleanupHarness(CleanupSamples.artboard, size: CGSize(width: 1000, height: 876))
        defer { harness.tearDown() }
        let page = harness.page
        #expect(page.review.frame.width == 928)
        #expect(page.condense.frame.minX == 36 && page.condense.frame.width == 928)
        #expect(page.condense.frame.minY == page.review.frame.maxY + 20)
        #expect(page.policy.frame.minY == page.condense.frame.maxY + 20)
    }

    @Test func pageScrollsAndTheBulkBarSticks() {
        var model = CleanupSamples.artboard
        model.rows = (0..<30).map { index in
            CleanupRow(id: "n\(index)", title: "筆記 \(index)", chips: [.kind("NOTE")], why: "\(20 + index) 天未開啟",
                       sub: "最後開啟 9/\(index % 28 + 1)", badge: "stale \(20 + index)d")
        }
        model.selected = ["n0", "n1"]
        let harness = CleanupHarness(model, size: CGSize(width: 1368, height: 600))
        defer { harness.tearDown() }
        let page = harness.page
        let review = page.review
        #expect(page.documentHeight > 600)
        // At the top the table runs below the visible area: the bar sits at the visible bottom.
        page.scroll(toOffset: 0)
        harness.settle()
        let barBottom = review.convert(review.bulkBar.frame, to: page.document).maxY
        #expect(abs(barBottom - 600) < 1, "bar bottom \(barBottom)")
        // Scrolled to the end, it is back at the panel's bottom.
        page.scroll(toOffset: 100_000)
        harness.settle()
        #expect(review.bulkBar.frame.maxY == review.bounds.height - 1)
        #expect(page.scrollOffset > 0)
    }

    @Test func snapshotIsDrawnWithTheFade() throws {
        CleanupHarness.registerFonts()
        let page = CleanupPageView(model: CleanupSamples.artboardAsDrawn)
        let rep = try #require(ViewSnapshot.render(page, size: CleanupHarness.size, scale: 1))
        #expect(ViewSnapshot.pixelsDiffering(from: Palette.bg, in: rep) > 50_000)
        // The preview box's last 28 % fades into the card (--bg-soft), its top is #000.
        let box = page.condense.body.previewBox
        let frame = box.convert(box.bounds, to: page.document)
        let top = try #require(ViewSnapshot.color(at: CGPoint(x: frame.minX + 4, y: frame.minY + 4), in: rep))
        let bottom = try #require(ViewSnapshot.color(at: CGPoint(x: frame.minX + 4, y: frame.maxY - 2), in: rep))
        #expect(top.redComponent < 0.01)
        #expect(abs(bottom.redComponent - Palette.bgSoft.redComponent) < 0.02)
    }
}
