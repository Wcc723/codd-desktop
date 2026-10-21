import AppKit
import Testing
import UniformTypeIdentifiers
@testable import CoddTextKit

@Suite("Editing", .serialized)
@MainActor
struct EditingTests {
    // MARK: Return

    @Test func returnContinuesBulletsAndAnEmptyItemEndsTheList() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("- 第一項")
        harness.pressReturn()
        #expect(harness.text == "- 第一項\n- ")
        harness.type("第二項")
        harness.pressReturn()
        #expect(harness.text == "- 第一項\n- 第二項\n- ")
        // Return on the empty item removes its marker and leaves an empty line.
        harness.pressReturn()
        #expect(harness.text == "- 第一項\n- 第二項\n")
        #expect(harness.caret == (harness.text as NSString).length)
        harness.type("段落")
        #expect(MarkdownBlockParser.blocks(in: harness.text).last?.kind == .paragraph)
    }

    @Test func returnIncrementsOrderedItemsAndKeepsIndentAndMarker() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("9. nine")
        harness.pressReturn()
        #expect(harness.text == "9. nine\n10. ")
        harness.load("  * nested")
        harness.pressReturn()
        #expect(harness.text == "  * nested\n  * ")
        harness.load("3) paren")
        harness.pressReturn()
        #expect(harness.text == "3) paren\n4) ")
    }

    @Test func returnContinuesTasksAndQuotes() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("- [x] 先重現")
        harness.pressReturn()
        #expect(harness.text == "- [x] 先重現\n- [ ] ")
        harness.pressReturn()
        #expect(harness.text == "- [x] 先重現\n")
        harness.load("> 引用")
        harness.pressReturn()
        #expect(harness.text == "> 引用\n> ")
    }

    @Test func returnInCodeKeepsIndentationAndShiftReturnIsPlain() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("```js\nfunction a() {\n  return 1\n```", caret: ("```js\nfunction a() {\n  return 1" as NSString).length)
        harness.pressReturn()
        #expect(harness.text == "```js\nfunction a() {\n  return 1\n  \n```")
        harness.load("- item")
        harness.pressReturn(.shift)
        #expect(harness.text == "- item\n")
        harness.load("段落")
        harness.pressReturn()
        #expect(harness.text == "段落\n")
    }

    @Test func returnThroughTheKeyPathContinuesTheList() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("- a")
        harness.press("\r", keyCode: 36)
        #expect(harness.text == "- a\n- ")
    }

    // MARK: Tab

    @Test func tabIndentsAndShiftTabOutdentsListItems() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("- a\n- b", caret: 7)
        harness.textView.insertTab(nil)
        #expect(harness.text == "- a\n  - b")
        #expect(harness.caret == 9)
        harness.textView.insertBacktab(nil)
        #expect(harness.text == "- a\n- b")
        #expect(harness.caret == 7)
        // A selection over both lines indents both, one undo step.
        harness.select(0, length: 7)
        harness.textView.insertTab(nil)
        #expect(harness.text == "  - a\n  - b")
        harness.endEvent()
        harness.textView.ownUndoManager.undo()
        #expect(harness.text == "- a\n- b")
        // Outside a list Tab is a tab.
        harness.load("text")
        harness.textView.insertTab(nil)
        #expect(harness.text == "text\t")
    }

    // MARK: Tasks

    @Test func toggleingATaskIsOneUndoableEdit() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("# T\n\n- [ ] 按鈕改 sticky\n- [x] 先重現", caret: 1)
        let open = harness.editor.blocks.firstIndex { $0.kind == .task(indent: 0, done: false) }!
        harness.editor.toggleTask(at: open)
        #expect(harness.text == "# T\n\n- [x] 按鈕改 sticky\n- [x] 先重現")
        #expect(harness.textChanges.count == 1)
        #expect(harness.caret == 1, "the selection stays")
        harness.endEvent()
        harness.textView.ownUndoManager.undo()
        #expect(harness.text == "# T\n\n- [ ] 按鈕改 sticky\n- [x] 先重現")
        harness.endEvent()
        harness.textView.ownUndoManager.redo()
        #expect(harness.text == "# T\n\n- [x] 按鈕改 sticky\n- [x] 先重現")
        #expect(harness.textView.ownUndoManager.undoActionName == "切換待辦")
    }

    @Test func clickingATaskBoxTogglesIt() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("# T\n\n- [ ] 按鈕改 sticky", caret: 1)
        let box = harness.location(of: "[ ]")
        let line = harness.editor.textLineRect(forCharacterAt: box)!
        let glyph = harness.layoutManager.glyphIndexForCharacter(at: box + 1)
        let x = harness.layoutManager.location(forGlyphAt: glyph).x + harness.editor.style.padding.left + 2
        #expect(harness.editor.handleClick(at: NSPoint(x: x, y: line.midY), clickCount: 1, modifiers: []))
        #expect(harness.text == "# T\n\n- [x] 按鈕改 sticky")
        // A click on the text does not toggle.
        let textGlyph = harness.layoutManager.glyphIndexForCharacter(at: harness.location(of: "sticky"))
        let textX = harness.layoutManager.location(forGlyphAt: textGlyph).x + harness.editor.style.padding.left + 2
        #expect(!harness.editor.handleClick(at: NSPoint(x: textX, y: line.midY), clickCount: 1, modifiers: []))
    }

    // MARK: Wraps

    @Test func commandBAndICanWrapAndUnwrap() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("把 重要 標起來")
        harness.select(2, length: 2)
        #expect(harness.keyEquivalent("b", keyCode: 11, modifiers: .command))
        #expect(harness.text == "把 **重要** 標起來")
        #expect(harness.textView.selectedRange() == NSRange(location: 4, length: 2))
        harness.endEvent()
        #expect(harness.keyEquivalent("b", keyCode: 11, modifiers: .command))
        #expect(harness.text == "把 重要 標起來")
        #expect(harness.textView.selectedRange() == NSRange(location: 2, length: 2))
        #expect(harness.keyEquivalent("i", keyCode: 34, modifiers: .command))
        #expect(harness.text == "把 *重要* 標起來")
        // An empty selection inserts the pair with the caret inside.
        harness.load("x")
        #expect(harness.keyEquivalent("b", keyCode: 11, modifiers: .command))
        #expect(harness.text == "x****")
        #expect(harness.caret == 3)
        // Other chords are left to the menu.
        #expect(!harness.keyEquivalent("e", keyCode: 14, modifiers: .command))
        #expect(!harness.keyEquivalent("k", keyCode: 40, modifiers: .command))
    }

    // MARK: Paste

    @Test func pastedImageDataGoesToTheCallback() {
        let harness = EditorHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        harness.load("# T\n")
        let png = TestImages.png()
        board.pasteboard.setData(png, forType: .png)
        #expect(harness.editor.insertContents(of: board.pasteboard))
        #expect(harness.pastedImages.count == 1)
        #expect(harness.pastedImages.first?.data == png)
        #expect(harness.pastedImages.first?.typeIdentifier == UTType.png.identifier)
        #expect(harness.text == "# T\n", "the app inserts the markdown later")
        // Declined: nothing is inserted.
        harness.pasteAnswer = false
        #expect(!harness.editor.insertContents(of: board.pasteboard))
        #expect(harness.text == "# T\n")
    }

    @Test func pastedImageFilesGoToTheCallbackWithTheirURL() throws {
        let harness = EditorHarness()
        let board = PrivatePasteboard()
        let directory = try TempDirectory()
        defer { harness.tearDown(); board.release(); directory.remove() }
        let file = directory.url.appendingPathComponent("截圖.png")
        try TestImages.png().write(to: file)
        board.pasteboard.writeObjects([file as NSURL])
        harness.load("")
        #expect(harness.editor.insertContents(of: board.pasteboard))
        #expect(harness.pastedImages.first?.fileURL == file)
        #expect(harness.pastedImages.first?.suggestedName == "截圖.png")
        #expect(harness.pastedImages.first?.data == (try Data(contentsOf: file)))
        // Other files paste as their paths.
        let other = directory.url.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: other)
        board.pasteboard.clearContents()
        board.pasteboard.writeObjects([other as NSURL])
        #expect(harness.editor.insertContents(of: board.pasteboard))
        #expect(harness.text.hasSuffix("notes.txt"))
    }

    @Test func richTextPastesAsPlainTextWithLineFeeds() {
        let harness = EditorHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        harness.load("前 ")
        let rich = NSAttributedString(string: "粗體\r\n第二行", attributes: [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.red])
        let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
        board.pasteboard.declareTypes([.rtf, .string], owner: nil)
        board.pasteboard.setData(rtf, forType: .rtf)
        board.pasteboard.setString("粗體\r\n第二行", forType: .string)
        #expect(harness.editor.insertContents(of: board.pasteboard))
        #expect(harness.text == "前 粗體\n第二行")
        // The pasted text is styled as Markdown, not as the source's rich text.
        let color = harness.editor.storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor
        #expect(color != NSColor.red)
        #expect(harness.pastedImages.isEmpty)
        // Plain text.
        board.pasteboard.clearContents()
        board.pasteboard.setString("純文字", forType: .string)
        #expect(harness.editor.insertContents(of: board.pasteboard))
        #expect(harness.text.hasSuffix("純文字"))
    }

    // MARK: Image markdown

    @Test func imageMarkdownGoesOnItsOwnLineAtTheCaret() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("前段後段", caret: 2)
        harness.editor.insertImageMarkdown(alt: "截圖 2026-10-15 09:32", path: "assets/n/9f3a1c.png")
        #expect(harness.text == "前段\n![截圖 2026-10-15 09:32](assets/n/9f3a1c.png)\n後段")
        #expect(harness.caret == ("前段\n![截圖 2026-10-15 09:32](assets/n/9f3a1c.png)\n" as NSString).length)
        #expect(harness.textChanges.count == 1)
        #expect(harness.textView.ownUndoManager.undoActionName == "貼上圖片")
        // At a line start: no extra line feed before.
        harness.load("a\nb", caret: 2)
        harness.editor.insertImageMarkdown(alt: "x", path: "p.png")
        #expect(harness.text == "a\n![x](p.png)\nb")
    }

    @Test func imageMarkdownGoesToTheEndWhenTheNoteChangedSinceThePaste() {
        let harness = EditorHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        harness.load("第一行\n第二行", caret: 3)
        board.pasteboard.setData(TestImages.png(), forType: .png)
        #expect(harness.editor.insertContents(of: board.pasteboard))
        harness.type("改")
        harness.editor.insertImageMarkdown(alt: "x", path: "p.png")
        #expect(harness.text == "第一行改\n第二行\n![x](p.png)\n")
        // Without a change since the paste: at the caret.
        harness.load("一\n二", caret: 1)
        #expect(harness.editor.insertContents(of: board.pasteboard))
        harness.editor.insertImageMarkdown(alt: "y", path: "q.png")
        #expect(harness.text == "一\n![y](q.png)\n二")
        // No caret placed since the load: at the end.
        harness.editor.load("尾巴", selection: nil)
        harness.editor.insertImageMarkdown(alt: "z", path: "r.png")
        #expect(harness.text == "尾巴\n![z](r.png)\n")
    }

    @Test func insertAtCaretUsesTheEndWithoutACaret() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.editor.load("abc", selection: nil)
        harness.editor.insertAtCaret("XYZ")
        #expect(harness.text == "abcXYZ")
        harness.select(1)
        harness.editor.insertAtCaret("-")
        #expect(harness.text == "a-bcXYZ")
        #expect(harness.caret == 2)
    }

    // MARK: Replace, external text, load

    @Test func replaceIsOneUndoStepWithItsName() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        let block = "![x](p.png)\n```codd-annotations\n{\"v\":1,\"items\":[]}\n```\n"
        harness.load("# T\n\n" + block + "\n尾", caret: 1)
        let json = harness.location(of: "{\"v\":1,\"items\":[]}")
        harness.editor.replace(NSRange(location: json, length: 18), with: "{\"v\":1,\"items\":[{\"n\":1}]}", actionName: "編輯標註")
        #expect(harness.text.contains("{\"v\":1,\"items\":[{\"n\":1}]}"))
        #expect(harness.textChanges.count == 1)
        harness.endEvent()
        harness.editor.replace(NSRange(location: 0, length: 3), with: "# 新", actionName: "改標題")
        harness.endEvent()
        let undo = harness.textView.ownUndoManager
        #expect(undo.undoActionName == "改標題")
        undo.undo()
        #expect(harness.text.hasPrefix("# T"))
        #expect(harness.text.contains("[{\"n\":1}]"))
        #expect(undo.undoActionName == "編輯標註")
        undo.undo()
        #expect(harness.text == "# T\n\n" + block + "\n尾")
    }

    @Test func externalTextKeepsTheSelection() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("line1\nline2\nline3", caret: 14)
        harness.select(14, length: 2)
        harness.editor.applyExternalText("line0\nline1\nline2\nline3")
        #expect(harness.text == "line0\nline1\nline2\nline3")
        #expect(harness.textView.selectedRange() == NSRange(location: 20, length: 2))
        #expect(harness.textChanges.isEmpty)
        #expect(harness.editor.text == harness.text)
        // A change after the selection leaves it where it is.
        harness.editor.applyExternalText("line0\nline1\nline2\nline3\nline4")
        #expect(harness.textView.selectedRange() == NSRange(location: 20, length: 2))
    }

    @Test func loadClearsUndoAndReportsNothing() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("a")
        harness.type("b")
        harness.endEvent()
        #expect(harness.textView.ownUndoManager.canUndo)
        harness.textChanges = []
        harness.load("新的")
        #expect(!harness.textView.ownUndoManager.canUndo)
        #expect(harness.textChanges.isEmpty)
        #expect(harness.editor.text == "新的")
    }

    // MARK: Backspace, selection, caret

    @Test func backspaceAtAnItemsTextRemovesItsMarker() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("- 項目", caret: 2)
        harness.textView.deleteBackward(nil)
        #expect(harness.text == "項目")
        harness.load("- [ ] 待辦", caret: 6)
        harness.textView.deleteBackward(nil)
        #expect(harness.text == "待辦")
        // Elsewhere backspace deletes one character.
        harness.load("- 項目", caret: 4)
        harness.textView.deleteBackward(nil)
        #expect(harness.text == "- 項")
        // Source mode shows the marker, so backspace is plain.
        harness.editor.mode = .source
        harness.load("- 項目", caret: 2)
        harness.textView.deleteBackward(nil)
        #expect(harness.text == "-項目")
    }

    @Test func theCaretSkipsAHiddenListMarker() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("段落\n- 項目", caret: 0)
        harness.select(3)
        #expect(harness.caret == 5, "a caret at the line start goes to the item text")
        harness.select(4)
        // ← from the item text (5 → 4) continues to the end of the line above.
        harness.select(5)
        harness.select(4)
        #expect(harness.caret == 2)
    }

    @Test func caretReportsLineAndColumn() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load(MarkdownSamples.n1, caret: MarkdownSamples.n1CaretLocation)
        let caret = harness.carets.last
        #expect(caret?.line == 6)
        #expect(caret?.column == "- **Safari 底部工具列展開時**才會完全蓋住，收起後還露出上半截".count + 1)
        harness.select(harness.location(of: "  .punch-table") + 2, length: 3)
        #expect(harness.carets.last == MarkdownCaret(line: 20, column: 3, selectionLength: 3))
        // The empty line after the final line feed.
        harness.select((harness.text as NSString).length)
        #expect(harness.carets.last?.line == 23)
        #expect(harness.carets.last?.column == 1)
    }

    @Test func escapeOpensNoCompletionList() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("ab")
        harness.press("\u{1B}", keyCode: 53)
        harness.textView.complete(nil)
        #expect(harness.text == "ab")
        #expect(harness.textView.window?.firstResponder === harness.textView)
    }

    @Test func typingRestylesTheLine() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("段落")
        harness.select(0)
        harness.type("## ")
        harness.settle()
        let font = harness.editor.storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == MarkdownEditorStyle.notebook.heading2Font.pointSize)
        #expect(harness.editor.blocks.first?.kind == .heading(level: 2))
        #expect(harness.textChanges.last == "## 段落")
    }

    // MARK: Caret with text after it (the user's report: Return and typing jumped)

    /// Typing, Return and Backspace with lines after the caret keep the caret where the edit
    /// happened, in live preview and source mode (attributes set inside the edit used to widen
    /// it, and the caret went to the end of the restyled lines, often the end of the note).
    @Test func editsWithTextAfterTheCaretKeepTheCaretInPlace() {
        for mode in [MarkdownEditorMode.livePreview, .source] {
            let harness = EditorHarness()
            defer { harness.tearDown() }
            harness.editor.mode = mode
            let body = "# 問題\n\n前半後半\n下一行"
            harness.load(body, caret: harness.location(of: "後半", in: body))
            harness.pressReturn()
            #expect(harness.text == "# 問題\n\n前半\n後半\n下一行", "\(mode)")
            #expect(harness.caret == harness.location(of: "後半"), "\(mode)")
            harness.type("x")
            #expect(harness.text == "# 問題\n\n前半\nx後半\n下一行", "\(mode)")
            #expect(harness.caret == harness.location(of: "後半"), "\(mode)")
            harness.textView.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
            #expect(harness.caret == harness.location(of: "後半"), "\(mode)")

            let list = "- 項目前項目後\n下一行"
            harness.load(list, caret: harness.location(of: "項目後", in: list))
            harness.pressReturn()
            #expect(harness.text == "- 項目前\n- 項目後\n下一行", "\(mode)")
            #expect(harness.caret == harness.location(of: "項目後"), "\(mode)")
            harness.type("新")
            #expect(harness.text == "- 項目前\n- 新項目後\n下一行", "\(mode)")

            let blank = "- 第一項\n\n介面\n最後一行"
            harness.load(blank, caret: harness.location(of: "\n\n介面", in: blank) + 1)
            harness.pressReturn()
            #expect(harness.caret == harness.location(of: "\n介面") , "\(mode)")
            harness.type("段落")
            #expect(harness.text == "- 第一項\n\n段落\n介面\n最後一行", "\(mode)")
        }
    }

    /// The restyle after an edit still happens: a line typed into a heading gets the heading
    /// font, and undo restyles the line it restores.
    @Test func editsInTheMiddleAreRestyledAndUndoRestyles() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        harness.load("段落\n下一行", caret: 0)
        harness.type("## ")
        harness.settle()
        let heading = harness.editor.storage.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
        #expect(heading?.pointSize == MarkdownEditorStyle.notebook.heading2Font.pointSize)
        #expect(harness.caret == 3)
        harness.endEvent()
        harness.textView.undo(nil)
        harness.settle()
        #expect(harness.text == "段落\n下一行")
        let body = harness.editor.storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(body?.pointSize == MarkdownEditorStyle.notebook.bodyFont.pointSize)
    }

    /// Moving the caret across blank lines never moves the lines below (blank lines keep one
    /// height on and off the caret).
    @Test func caretMovesNeverShiftTheLinesBelow() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        let body = "# 問題\n\n## 操作\n- 第一項\n\n\n介面\n\n最後一行"
        harness.load(body, caret: harness.location(of: "最後一行", in: body))
        let probe = harness.location(of: "最後一行")
        let resting = harness.fragment(at: probe).minY
        for _ in 0 ..< 6 {
            harness.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
            harness.settle()
            #expect(abs(harness.fragment(at: probe).minY - resting) < 0.5, "caret \(harness.caret)")
        }
    }
}
