import AppKit
import CoddUI
import Testing
@testable import CoddAnnotateUI

/// Delete and renumbering, undo / redo of every operation, ⌘Z, colors, 完成 / 取消 / ⎋.
@Suite("Editing", .serialized)
@MainActor
struct EditingTests {
    @Test func deleteRenumbersSequentially() throws {
        let h = AnnotateHarness(selection: 2)
        defer { h.tearDown() }
        h.view.focusCanvas()
        h.press("\u{7F}", keyCode: AnnotateHarness.delete)
        #expect(h.items.map(\.n) == [1, 2])
        #expect(h.items.map(\.kind) == [.rect, .arrow])
        #expect(h.view.selection == nil)
        #expect(h.view.statusText == "標註模式 · 2 個標註")
        #expect(h.changes.count == 1)
        #expect(h.panel.rows.map(\.item.n) == [1, 2])
        h.view.undo()
        #expect(h.items == ImageAnnotateSamples.document.items)
        #expect(h.view.selection == 2, "undo brings the selection back")
        // [刪除] and ⌦ do the same.
        h.view.selection = 1
        try #require(h.expanded).deleteButton.performClick(nil)
        #expect(h.items.map(\.kind) == [.point, .arrow])
        #expect(h.items.map(\.n) == [1, 2])
        h.view.selection = 2
        h.view.focusCanvas()
        h.press("\u{F728}", keyCode: AnnotateHarness.forwardDelete)
        #expect(h.items.map(\.kind) == [.point])
        // Nothing selected: Del does nothing.
        h.press("\u{7F}", keyCode: AnnotateHarness.delete)
        #expect(h.items.count == 1)
    }

    @Test func everyOperationIsOneUndoStep() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        let start = h.view.document
        var states = [start]
        // create
        h.view.tool = .rect
        h.drag(h.at(100, 100), h.at(200, 200))
        states.append(h.view.document)
        // move
        h.view.tool = .select
        h.drag(h.at(150, 150), h.at(160, 160))
        states.append(h.view.document)
        // resize (item 4 selected)
        h.drag(h.at(220, 220), h.at(240, 240))
        states.append(h.view.document)
        // field edit
        h.type("5", in: .x)
        states.append(h.view.document)
        h.view.focusCanvas()
        // comment
        h.window.makeFirstResponder(h.commentView)
        h.commentView.insertText("新的框", replacementRange: NSRange(location: NSNotFound, length: 0))
        h.view.focusCanvas()
        states.append(h.view.document)
        // color
        h.view.pickColor(.cyan)
        states.append(h.view.document)
        // send option
        h.panel.sendAnnotated.toggle()
        states.append(h.view.document)
        // delete
        h.view.focusCanvas()
        h.press("\u{7F}", keyCode: AnnotateHarness.delete)
        states.append(h.view.document)
        #expect(Set(states.map { "\($0)" }).count == states.count, "each step changed the document")
        #expect(h.changes == Array(states.dropFirst()))
        for expected in states.reversed().dropFirst() {
            h.view.undo()
            #expect(h.view.document == expected)
        }
        #expect(h.view.undoManager?.canUndo == false)
        #expect(!h.view.topBar.undoButton.isEnabled && h.view.topBar.redoButton.isEnabled)
        for expected in states.dropFirst() {
            h.view.redo()
            #expect(h.view.document == expected)
        }
        #expect(h.view.topBar.undoButton.isEnabled && !h.view.topBar.redoButton.isEnabled)
        #expect(h.changes.count == (states.count - 1) * 3, "undo and redo report onChange too")
    }

    @Test func undoButtonsAndCommandZ() throws {
        let h = AnnotateHarness()
        defer { h.tearDown() }
        #expect(!h.view.topBar.undoButton.isEnabled && !h.view.topBar.redoButton.isEnabled)
        h.view.tool = .point
        h.click(h.at(50, 50))
        #expect(h.view.topBar.undoButton.isEnabled)
        h.view.topBar.undoButton.press()
        #expect(h.items.count == 3)
        #expect(h.view.topBar.redoButton.isEnabled)
        h.view.topBar.redoButton.press()
        #expect(h.items.count == 4)
        h.view.focusCanvas()
        #expect(h.view.performKeyEquivalent(with: h.key("z", keyCode: AnnotateHarness.keyZ, flags: .command)))
        #expect(h.items.count == 3)
        #expect(h.view.performKeyEquivalent(with: h.key("z", keyCode: AnnotateHarness.keyZ, flags: [.command, .shift])))
        #expect(h.items.count == 4)
        // While a field edits, ⌘Z is the field's own typing undo, never the document's.
        h.view.selection = 1
        let editor = h.focus(.x)
        editor.insertText("9", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = h.view.performKeyEquivalent(with: h.key("z", keyCode: AnnotateHarness.keyZ, flags: .command))
        #expect(h.items.count == 4)
        #expect(h.view.document.item(1)?.x == 20)
    }

    @Test func colorsApplyToNewItemsAndTheSelection() throws {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        let menu = h.view.colorMenu()
        #expect(menu.items.map(\.title) == ["琥珀", "青藍", "紅", "綠", "米白"])
        #expect(menu.items.first?.state == .on)
        let cyan = try #require(menu.items[1] as? ClosureMenuItem)
        _ = cyan.target?.perform(cyan.action, with: cyan)
        #expect(h.view.currentColor == .cyan)
        #expect(h.view.document.item(1)?.color == .cyan)
        #expect(h.view.toolStrip.colorButton.color == .cyan)
        #expect(h.view.toolStrip.colorButton.accessibilityLabel() == "標註顏色：青藍")
        h.view.tool = .point
        h.click(h.at(10, 10))
        #expect(h.items.last?.color == .cyan)
        h.view.undo()
        h.view.undo()
        #expect(h.view.document.item(1)?.color == .amber)
    }

    @Test func doneCancelAndEscape() {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        h.view.focusCanvas()
        h.press("\u{1B}", keyCode: AnnotateHarness.escape)
        #expect(h.view.selection == nil, "⎋ deselects first")
        #expect(h.done.isEmpty)
        h.press("\u{1B}", keyCode: AnnotateHarness.escape)
        #expect(h.done.count == 1, "⎋ with nothing selected is 完成")
        h.view.topBar.doneButton.performClick(nil)
        #expect(h.done.count == 2)
        #expect(h.done.last == h.view.document)
        h.view.topBar.cancelButton.performClick(nil)
        #expect(h.cancels == 1)
        #expect(h.changes.isEmpty)
    }

    @Test func escapeCancelsADragInProgress() {
        let h = AnnotateHarness(selection: 1)
        defer { h.tearDown() }
        h.view.focusCanvas()
        let from = h.at(375, 1210)
        h.canvas.mouseDown(with: h.mouse(.leftMouseDown, from))
        h.canvas.mouseDragged(with: h.mouse(.leftMouseDragged, CGPoint(x: from.x, y: from.y - 40)))
        #expect(h.view.document.item(1)?.y == 1070)
        h.press("\u{1B}", keyCode: AnnotateHarness.escape)
        #expect(h.view.document.item(1)?.y == 1150)
        #expect(h.view.selection == 1, "only the drag was cancelled")
        h.canvas.mouseUp(with: h.mouse(.leftMouseUp, CGPoint(x: from.x, y: from.y - 40)))
        #expect(h.changes.isEmpty)
        #expect(h.view.undoManager?.canUndo == false)
    }

    @Test func documentsAreNormalizedAtInit() {
        let image = AnnotateHarness.image
        let document = AnnotationDocument(pixelSize: .zero, items: [.point(7, x: 1, y: 2), .point(9, x: 3, y: 4)])
        AnnotateHarness.registerFonts()
        let view = ImageAnnotateView(image: image, document: document, header: ImageAnnotateSamples.header)
        #expect(view.document.pixelSize == CGSize(width: 750, height: 1334), "the image's size when none is given")
        #expect(view.document.items.map(\.n) == [1, 2])
        #expect(view.undoManager !== nil)
    }
}
