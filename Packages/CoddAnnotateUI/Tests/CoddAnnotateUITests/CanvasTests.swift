import AppKit
import CoddUI
import Testing
@testable import CoddAnnotateUI

/// Coordinate mapping, drawing each kind, ⇧ locks, clamping, selection, moves, handles.
@Suite("Canvas", .serialized)
@MainActor
struct CanvasTests {
    @Test func fitIsFiftyPercentOnTheArtboardStage() {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        #expect(h.view.stage.frame == CGRect(x: 48, y: 52, width: 940, height: 824))
        #expect(h.view.canvasScale == 0.5)
        #expect(h.mapping.imageRect.size == CGSize(width: 375, height: 667))
        #expect(h.canvas.displayedCaption == "原圖 750×1334 · 顯示 50% · 座標以原圖像素、左上為原點")
        // The frame (image + 8 pt padding + border) is centered with the caption under it.
        #expect(h.canvas.frameRect.size == CGSize(width: 393, height: 685))
        #expect(abs(h.canvas.frameRect.midX - 470) <= 1)
        #expect(h.canvas.frame.size == CGSize(width: 940, height: 824), "Fit never scrolls")
    }

    @Test func dragAtFiftyPercentGivesOriginalPixels() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        h.view.tool = .rect
        let origin = h.mapping.imageOrigin
        // View points (10, 575) → (365, 635) inside the image = pixels (20, 1150) → (730, 1270).
        h.drag(CGPoint(x: origin.x + 10, y: origin.y + 575), CGPoint(x: origin.x + 365, y: origin.y + 635))
        let item = try #require(h.items.last)
        #expect(item == .rect(4, x: 20, y: 1150, w: 710, h: 120))
        #expect(h.view.selection == 4)
        #expect(h.changes.count == 1)
        #expect(h.view.statusText == "標註模式 · 4 個標註")
    }

    @Test func dragAtOneHundredAndTwoHundredPercent() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        h.view.tool = .rect
        h.view.zoom = .actual
        #expect(h.view.canvasScale == 1)
        #expect(h.canvas.frame.height > h.view.stage.frame.height, "100 % scrolls")
        #expect(h.view.stage.canvas.displayedCaption.contains("顯示 100%"))
        var c = h.visibleCenterPixel
        var cx = c.x.rounded(), cy = c.y.rounded()
        h.drag(h.at(cx - 50, cy - 25), h.at(cx + 50, cy + 25))
        #expect(try #require(h.items.last) == .rect(4, x: Int(cx) - 50, y: Int(cy) - 25, w: 100, h: 50))

        h.view.zoom = .double
        #expect(h.view.canvasScale == 2)
        #expect(h.view.stage.canvas.displayedCaption.contains("顯示 200%"))
        c = h.visibleCenterPixel
        cx = c.x.rounded()
        cy = c.y.rounded()
        // 100 × 50 view points are 50 × 25 pixels at 200 %.
        let from = h.at(cx, cy)
        h.drag(from, CGPoint(x: from.x + 100, y: from.y + 50))
        #expect(try #require(h.items.last) == .rect(5, x: Int(cx), y: Int(cy), w: 50, h: 25))
        // Zooming keeps the visible center on (about) the same pixel.
        h.view.zoom = .fit
        #expect(h.view.canvasScale == 0.5)
    }

    @Test func pointByClickArrowByDragTextByClick() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        h.view.tool = .point
        h.click(h.at(375.4, 330))
        #expect(try #require(h.items.last) == .point(4, x: 375, y: 330))
        h.view.tool = .arrow
        h.drag(h.at(100, 100), h.at(300, 250))
        #expect(try #require(h.items.last) == .arrow(5, x: 100, y: 100, x2: 300, y2: 250))
        h.view.tool = .text
        h.click(h.at(40, 80))
        let editor = try #require(h.canvas.inlineEditor)
        #expect(h.window.firstResponder === editor.textView)
        editor.textView.insertText("這段文字直接畫在圖上", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(h.canvas.inlineEditor == nil)
        #expect(try #require(h.items.last) == .text(6, x: 40, y: 80, note: "這段文字直接畫在圖上"))
        #expect(h.window.firstResponder === h.canvas)
        #expect(h.changes.count == 3)
    }

    @Test func textFieldIsIMESafeAndEscapeCancels() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        h.view.tool = .text
        h.click(h.at(40, 80))
        var editor = try #require(h.canvas.inlineEditor)
        editor.textView.insertText("文", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.setMarkedText("ㄗ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        // ⏎ belongs to the input method while it composes: nothing is created.
        _ = editor.textView.delegate?.textView?(editor.textView, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(h.canvas.inlineEditor != nil)
        #expect(h.items.count == 3)
        editor.textView.insertText("字", replacementRange: editor.textView.markedRange())
        editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(try #require(h.items.last).note == "文字")

        h.click(h.at(200, 200))
        editor = try #require(h.canvas.inlineEditor)
        editor.textView.insertText("不要", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(h.canvas.inlineEditor == nil)
        #expect(h.items.count == 4)
        // A click without text creates nothing.
        h.click(h.at(300, 300))
        h.click(h.at(300, 300))
        #expect(h.items.count == 4)
    }

    @Test func shiftLocksSquaresAndFortyFiveDegrees() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        h.view.tool = .rect
        h.drag(h.at(100, 100), h.at(220, 160), shift: true)
        #expect(try #require(h.items.last) == .rect(4, x: 100, y: 100, w: 120, h: 120))
        h.view.tool = .arrow
        h.drag(h.at(100, 100), h.at(300, 260), shift: true)
        let arrow = try #require(h.items.last)
        #expect(arrow.endX - arrow.x == arrow.endY - arrow.y)
        #expect(arrow == .arrow(5, x: 100, y: 100, x2: 280, y2: 280))
    }

    @Test func everythingIsClampedToTheImage() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        h.view.tool = .rect
        h.drag(h.at(700, 1300), h.at(900, 1500))
        #expect(try #require(h.items.last) == .rect(4, x: 700, y: 1300, w: 50, h: 34))
        h.view.tool = .point
        h.click(h.at(-30, 500))
        #expect(try #require(h.items.last) == .point(5, x: 0, y: 500))
        // A drag shorter than 3 pt draws nothing.
        h.view.tool = .rect
        h.drag(h.at(100, 100), h.at(102, 101))
        #expect(h.items.count == 5)
        #expect(h.changes.count == 2)
    }

    @Test func clickSelectsTopmostAndEmptyDeselects() {
        var document = ImageAnnotateSamples.document
        document.items.append(.point(4, x: 100, y: 1200, note: "框裡的點"))
        let h = AnnotateHarness(document: document)
        defer { h.tearDown() }
        h.click(h.at(375, 330))
        #expect(h.view.selection == 2)
        h.click(h.at(375, 1210))
        #expect(h.view.selection == 1, "inside the box")
        h.click(h.at(100, 1200))
        #expect(h.view.selection == 4, "a point inside a box stays reachable")
        h.click(h.at(650, 920))
        #expect(h.view.selection == 3, "on the arrow's line")
        h.click(CGPoint(x: 20, y: 20))
        #expect(h.view.selection == nil)
        #expect(h.changes.isEmpty, "selecting is not an edit")
    }

    @Test func dragMovesTheItemAsOneStep() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let from = h.at(375, 1210)
        h.drag(from, CGPoint(x: from.x + 10, y: from.y - 20))
        #expect(try #require(h.view.document.item(1)) == .rect(1, x: 40, y: 1110, w: 710, h: 120, note: ImageAnnotateSamples.document.items[0].note))
        #expect(h.changes.count == 1, "onChange once, at the end of the drag")
        #expect(h.panel.term.displayedText.contains("x=40 y=1110"))
        #expect(h.expanded?.field(.x)?.displayedText == "40")
        h.view.undo()
        #expect(h.view.document.item(1)?.x == 20)
        // Moves stay inside the image.
        h.drag(h.at(375, 1210), h.at(-125, 1210))
        #expect(h.view.document.item(1)?.x == 0)
    }

    @Test func aJitteryClickIsNotAnEdit() {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let from = h.at(375, 1210)
        h.drag(from, CGPoint(x: from.x + 1, y: from.y + 1))
        h.drag(h.at(730, 1270), h.at(731, 1270))
        #expect(h.view.document == ImageAnnotateSamples.document)
        #expect(h.changes.isEmpty && h.view.undoManager?.canUndo == false)
    }

    @Test func cornerHandlesResize() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        h.drag(h.at(730, 1270), h.at(690, 1250))
        var item = try #require(h.view.document.item(1))
        #expect((item.x, item.y, item.width, item.height) == (20, 1150, 670, 100))
        h.view.undo()
        // ⇧ keeps 710 : 120.
        h.drag(h.at(730, 1270), h.at(375, 1210), shift: true)
        item = try #require(h.view.document.item(1))
        #expect((item.x, item.y, item.width, item.height) == (20, 1150, 355, 60))
        // The top-left handle moves that corner.
        h.drag(h.at(20, 1150), h.at(10, 1100))
        item = try #require(h.view.document.item(1))
        #expect((item.x, item.y, item.width, item.height) == (10, 1100, 365, 110))
    }

    @Test func arrowEndpointsMove() throws {
        let h = AnnotateHarness(selection: 3)
        defer { h.tearDown() }
        h.drag(h.at(700, 1080), h.at(650, 1000))
        var item = try #require(h.view.document.item(3))
        #expect((item.x, item.y, item.endX, item.endY) == (600, 760, 650, 1000))
        h.drag(h.at(600, 760), h.at(500, 700))
        item = try #require(h.view.document.item(3))
        #expect((item.x, item.y, item.endX, item.endY) == (500, 700, 650, 1000))
        #expect(h.changes.count == 2)
    }

    @Test func overlayIsDrawnWhereTheItemsAre() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let container = try #require(h.window.contentView)
        container.displayIfNeeded()
        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        // Pin 2 (centered on pixel 375, 330) is amber with a black number.
        let pin = h.canvas.convert(h.at(375, 330), to: container)
        let amber = try #require(ViewSnapshot.color(at: CGPoint(x: pin.x - 6, y: pin.y - 6), in: rep))
        #expect(amber.redComponent > 0.85 && amber.greenComponent > 0.6 && amber.blueComponent < amber.redComponent - 0.4)
        // The stage grid is #060606 away from the frame.
        let grid = try #require(ViewSnapshot.color(at: h.view.stage.convert(CGPoint(x: 30, y: 405), to: container), in: rep))
        #expect(grid.redComponent < 0.05)
        #expect(!h.window.isVisible)
    }
}
