import AppKit
import CoddUI
import Testing

/// M4 layout sweep: which optional pieces of a row fit (`RowFit`), full-width stacks that change
/// their side padding, and the quota rows' widths at the interface zoom.
@Suite("Layout fit")
@MainActor
struct LayoutFitTests {
    init() { _ = TestSupport.prepare() }

    @Test func rowFitTakesPiecesInOrderUntilOneDoesNotFit() {
        #expect(RowFit.shownCount(available: 100, fixed: 40, costs: [20, 20, 20]) == 3)
        #expect(RowFit.shownCount(available: 99, fixed: 40, costs: [20, 20, 20]) == 2, "the last one no longer fits")
        #expect(RowFit.shownCount(available: 100.4, fixed: 40, costs: [20, 20, 20.8]) == 3, "half a point of slack")
        #expect(RowFit.shownCount(available: 30, fixed: 40, costs: [5]) == 0, "nothing beside an overfull fixed part")
        #expect(RowFit.shownCount(available: 100, fixed: 0, costs: []) == 0)
        // A later, smaller piece never shows without the earlier one (no gaps, no flicker).
        #expect(RowFit.shown(available: 75, fixed: 10, costs: [70, 5]) == [false, false])
        #expect(RowFit.shown(available: 85, fixed: 10, costs: [70, 5]) == [true, true])
        #expect(RowFit.optionalCompression.rawValue < 500, "below the window's stay-put priority")
        #expect(RowFit.optionalCompression.rawValue > NSLayoutConstraint.Priority.defaultLow.rawValue, "labels give way first")
    }

    @Test func fullWidthStacksMoveTheirViewsWithNewInsets() {
        let stack = columnStack([], spacing: 4, edgeInsets: NSEdgeInsets(top: 0, left: 40, bottom: 0, right: 40))
        let child = NSView()
        stack.addFullWidth(child)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.layoutSubtreeIfNeeded()
        #expect(child.frame.minX == 40 && child.frame.width == 320)
        stack.setFullWidthInsets(NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 20))
        stack.layoutSubtreeIfNeeded()
        #expect(child.frame.minX == 20 && child.frame.width == 360)
        #expect(stack.edgeInsets.left == 20 && stack.edgeInsets.right == 20)
    }

    @Test func quotaRowWidthsFollowTheZoom() {
        let row = QuotaBarRow(key: "5h", remainingPercent: 50)
        let design = QuotaBarRowRenderer.layout(for: row)
        #expect(design.keyWidth == 22 && design.valueWidth == 34 && design.gap == 8 && QuotaBarRowRenderer.barHeight == 7)
        UIZoom.withScale(20.0 / 13.0) {
            let zoomed = QuotaBarRowRenderer.layout(for: row)
            #expect(zoomed.keyWidth == UIZoom.pt(22) && zoomed.valueWidth == UIZoom.pt(34) && zoomed.gap == UIZoom.pt(8))
            #expect(zoomed.fontSize == 11, "a design size: Typeface zooms it")
            #expect(QuotaBarRowRenderer.barHeight == UIZoom.pt(7) && QuotaBarRowRenderer.height == UIZoom.pt(16))
            let custom = QuotaBarRowRenderer.layout(for: QuotaBarRow(key: "Fable", remainingPercent: nil, keyWidth: 34))
            #expect(custom.keyWidth == UIZoom.pt(34), "a row's own key width is a design width too")
        }
    }
}
