import AppKit
import CoddUI
import Testing
@testable import CoddCodeEditor

@Suite("Inline diff hunks", .serialized)
@MainActor
struct InlineDiffTests {
    static let pink = NSColor(hex: 0xFF7CB5)
    static let text = (1 ... 60).map { "line \($0)" }.joined(separator: "\n")

    static func header(_ range: String, removed: Int, added: Int) -> InlineDiffHeader {
        InlineDiffHeader(tagColor: pink, showAIChip: true, who: "打卡頁 RWD 調整 · 10:36", range: range, removed: removed, added: added, position: "1 / 2")
    }

    /// A: lines 10–11 (0-based) added over 3 removed lines; B: one line deleted before line 30.
    static let hunkA = InlineDiffHunk(id: 7, newLines: 10 ..< 12, deletedLines: ["old a", "old b", "old c"],
                                      header: header("@@ -11,3 +11,2 @@", removed: 3, added: 2))
    static let hunkB = InlineDiffHunk(id: 8, newLines: 30 ..< 30, deletedLines: ["gone"], header: header("@@ -31,1 +30,0 @@", removed: 1, added: 0))

    private func harness() -> EditorHarness {
        let harness = EditorHarness(width: 900, height: 600, text: Self.text, language: .plain)
        harness.editor.setInlineDiff([Self.hunkB, Self.hunkA])
        harness.settle()
        return harness
    }

    @Test func decorationsReserveHeightAboveTheirLines() throws {
        let harness = harness()
        defer { harness.tearDown() }
        let editor = harness.editor
        #expect(editor.inlineDiff.map(\.id) == [7, 8])
        let manager = editor.layoutManagerImpl
        let glyph = manager.glyphIndexForCharacter(at: editor.geometry.lines.start(of: 10))
        let decorated: CGFloat = 106
        #expect(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height == decorated)
        // Row tops: 4 pt padding, 20 pt rows, hunk A 86 pt above line 10, hunk B 46 pt above line 30.
        let expected: [Int: CGFloat] = [9: 184, 10: 290, 11: 310, 30: 736]
        for (line, top) in expected {
            let row = try #require(editor.textRowRect(line: line))
            #expect(row.minY == top, "line \(line)")
        }
        // The caret on a decorated line sits in its text row, not in the decoration.
        let point = try #require(editor.insertionPoint(at: editor.geometry.lines.start(of: 10)))
        let rowTop: CGFloat = 290
        #expect(point.baseline > rowTop)
    }

    @Test func hunkBarsFollowScrolling() throws {
        let harness = harness()
        defer { harness.tearDown() }
        let editor = harness.editor
        let frames = editor.hunkBarFramesForTesting
        let bar = try #require(frames[7])
        #expect(bar == NSRect(x: 0, y: 4 + 10 * 20, width: 900 - 14, height: 26))
        #expect(frames[8] == nil)
        editor.scroll(toY: 100)
        harness.settle()
        let scrolledTop: CGFloat = 104
        #expect(editor.hunkBarFramesForTesting[7]?.minY == scrolledTop)
        editor.scrollToHunk(8)
        harness.settle()
        let barB = try #require(editor.hunkBarFramesForTesting[8])
        #expect(barB.minY > CGFloat(100))
        #expect(barB.maxY < CGFloat(500))
        let barTop: CGFloat = 690
        #expect(barB.minY == barTop - editor.scrollView.contentView.bounds.minY)
    }

    @Test func hunkButtonsReportTheirAction() throws {
        let harness = harness()
        defer { harness.tearDown() }
        let bar = try #require(harness.editor.hunkBarViewsForTesting[7])
        #expect(bar.revertButton.label == "還原此段")
        #expect(bar.acceptButton.label == "接受")
        bar.revertButton.performClick(nil)
        bar.acceptButton.performClick(nil)
        #expect(harness.hunkActions.map(\.0) == [7, 7])
        #expect(harness.hunkActions.map(\.1) == [.revert, .accept])
        // The bar is above the text: clicks on it reach its buttons, elsewhere the overlay passes them on.
        let editor = harness.editor
        let buttonPoint = bar.convert(NSPoint(x: bar.revertButton.frame.midX, y: bar.revertButton.frame.midY), to: editor.overlay.superview)
        #expect(editor.overlay.hitTest(buttonPoint) === bar.revertButton)
        #expect(editor.overlay.hitTest(NSPoint(x: 300, y: 40)) == nil)
    }

    @Test func gutterNumbersSkipRemovedLines() {
        let harness = harness()
        defer { harness.tearDown() }
        let rows = harness.editor.gutterRowsForTesting()
        let around = rows.drop(while: { $0.number != 10 }).prefix(8)
        #expect(around.map(\.number) == [10, nil, nil, nil, nil, 11, 12, 13])
        #expect(around.map(\.marker) == [nil, nil, "−", "−", "−", "+", "+", nil])
        #expect(around.dropFirst().first?.kind == .hunkBar(hunk: 0))
        harness.editor.modifiedLineMarkers = [12: Self.pink, 10: Self.pink]
        let marked = harness.editor.gutterRowsForTesting()
        // A `.mod` bar shows outside a hunk's added lines only.
        #expect(marked.first(where: { $0.number == 13 })?.marker == "mod")
        #expect(marked.first(where: { $0.number == 11 })?.marker == "+")
    }

    @Test func hunksFollowEditsAndDropWhenInvalidated() {
        let harness = harness()
        defer { harness.tearDown() }
        let editor = harness.editor
        // A line inserted above both: they move down.
        editor.replaceLines(0 ..< 0, with: ["new first"], actionName: "x")
        harness.settle()
        #expect(editor.inlineDiff.map(\.newLines) == [11 ..< 13, 31 ..< 31])
        // Typing inside an added line keeps the hunk.
        harness.caret(at: editor.geometry.lines.start(of: 11) + 2)
        harness.type("x")
        #expect(editor.inlineDiff.map(\.newLines) == [11 ..< 13, 31 ..< 31])
        // Removing the hunk's first added line shrinks it.
        editor.replaceLines(11 ..< 12, with: [], actionName: "x")
        harness.settle()
        #expect(editor.inlineDiff.map(\.newLines) == [11 ..< 12, 30 ..< 30])
        // Removing the lines around a deletion point drops that hunk.
        editor.replaceLines(29 ..< 31, with: ["merged"], actionName: "x")
        harness.settle()
        #expect(editor.inlineDiff.map(\.id) == [7])
        #expect(editor.hunkBarViewsForTesting[8] == nil)
        let manager = editor.layoutManagerImpl
        let glyph = manager.glyphIndexForCharacter(at: editor.geometry.lines.start(of: 29))
        let plainRow: CGFloat = 20
        #expect(manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height == plainRow)
    }

    @Test func outOfRangeHunksAreDroppedAndTrailingDeletionsShowAtTheEnd() throws {
        let harness = EditorHarness(width: 900, height: 600, text: Self.text, language: .plain)
        defer { harness.tearDown() }
        let editor = harness.editor
        let beyond = InlineDiffHunk(id: 1, newLines: 58 ..< 70, deletedLines: [], header: Self.header("x", removed: 0, added: 12))
        let atEnd = InlineDiffHunk(id: 2, newLines: 60 ..< 60, deletedLines: ["tail 1", "tail 2"], header: Self.header("y", removed: 2, added: 0))
        editor.setInlineDiff([beyond, atEnd])
        harness.settle()
        #expect(editor.inlineDiff.map(\.id) == [2])
        let manager = editor.layoutManagerImpl
        let last = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
        let lastHeight: CGFloat = 86
        #expect(last.height == lastHeight)
        editor.scrollToHunk(2)
        harness.settle()
        let bar = try #require(editor.hunkBarFramesForTesting[2])
        let trailingTop: CGFloat = 1204
        #expect(bar.minY == trailingTop - editor.scrollView.contentView.bounds.minY)
        let rows = editor.gutterRowsForTesting()
        #expect(rows.suffix(4).map(\.number) == [60, nil, nil, nil])
    }

    @Test func revertingAHunkWithReplaceLines() throws {
        let harness = harness()
        defer { harness.tearDown() }
        let editor = harness.editor
        editor.onHunkAction = { id, action in
            guard action == .revert, let hunk = editor.inlineDiff.first(where: { $0.id == id }) else { return }
            editor.replaceLines(hunk.newLines, with: hunk.deletedLines, actionName: "還原此段")
        }
        try #require(editor.hunkBarViewsForTesting[7]).revertButton.performClick(nil)
        let lines = editor.text.components(separatedBy: "\n")
        #expect(Array(lines[10 ..< 13]) == ["old a", "old b", "old c"])
        #expect(lines.count == 61)
        #expect(editor.textView.undoManager?.undoActionName == "還原此段")
        editor.textView.undoManager?.undo()
        #expect(editor.text == Self.text)
    }

    // MARK: Rendering

    @Test func selectionStaysOutOfTheDecoration() throws {
        let harness = harness()
        defer { harness.tearDown() }
        let editor = harness.editor
        func pixel(_ rep: NSBitmapImageRep, _ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
            let c = ViewSnapshot.color(at: CGPoint(x: x, y: y), in: rep)!
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        let removedRow = 4 + 10 * 20 + 26 + 10.0
        let before = try #require(ViewSnapshot.render(editor, size: NSSize(width: 900, height: 600)))
        // Select lines 9–11 (across the hunk's decoration).
        let lines = editor.geometry.lines
        editor.textView.setSelectedRange(NSRange(location: lines.start(of: 8), length: lines.start(of: 12) - lines.start(of: 8)))
        let after = try #require(ViewSnapshot.render(editor, size: NSSize(width: 900, height: 600)))
        // The removed row and the hunk bar look the same; the selected text row does not.
        #expect(pixel(after, 300, removedRow) == pixel(before, 300, removedRow))
        #expect(pixel(after, 300, 4 + 10 * 20 + 13) == pixel(before, 300, 4 + 10 * 20 + 13))
        #expect(pixel(after, 30 + 62, 4 + 9 * 20 + 10) != pixel(before, 30 + 62, 4 + 9 * 20 + 10))
    }


    @Test func rendersTheArtboardLook() throws {
        let harness = harness()
        defer { harness.tearDown() }
        let editor = harness.editor
        editor.goTo(line: 11, column: 3)
        editor.showsInactiveCaret = true
        harness.settle()
        let rep = try #require(ViewSnapshot.render(editor, size: NSSize(width: 900, height: 600)))
        func color(_ x: CGFloat, _ y: CGFloat) -> (Int, Int, Int) {
            let c = ViewSnapshot.color(at: CGPoint(x: x, y: y), in: rep)!
            return (Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
        }
        func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), _ tolerance: Int = 3) -> Bool {
            abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
        }
        // Background #000 to the right of short lines.
        #expect(near(color(600, 4 + 5 * 20 + 10), (0, 0, 0)))
        // Removed rows (rgba(255,112,88,.085)) and added rows (rgba(124,255,154,.075)) over black, in the
        // text area and the gutter; the exact values pass through color management, so the check is
        // on the dominant channel and the brightness.
        let removedRow = 4 + 10 * 20 + 26 + 10.0
        for x in [CGFloat(600), 20] {
            let removed = color(x, removedRow)
            #expect(removed.0 > removed.1 && removed.0 > removed.2 && (15 ... 35).contains(removed.0), "removed \(removed)")
        }
        let addedRow = 4 + 11 * 20 + 86 + 10.0
        let added = color(600, addedRow)
        #expect(added.1 > added.0 && added.1 > added.2 && (12 ... 32).contains(added.1), "added \(added)")
        // The 2 pt bar in the hunk's tag color at the row's left edge.
        let bar = color(1, addedRow)
        #expect(bar.0 > 200 && bar.1 > 80 && bar.1 < 160 && bar.2 > 140, "bar \(bar)")
        // The overview ruler: #030303 with a 1 pt --line border.
        #expect(near(color(900 - 7, 590), (3, 3, 3), 4))
        // The caret: amber, 2 pt wide, on line 11 (0-based 10) after `li`.
        let point = try #require(editor.insertionPoint(at: editor.geometry.lines.start(of: 10) + 2))
        let caretX = editor.gutterWidth + point.x
        let caret = color(caretX, point.baseline - 4)
        #expect(caret.0 > 220 && caret.1 > 140 && caret.1 < 210 && caret.2 < 120, "caret \(caret)")
    }
}
