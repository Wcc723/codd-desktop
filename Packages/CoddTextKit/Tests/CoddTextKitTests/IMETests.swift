import AppKit
import Testing
@testable import CoddTextKit

/// D11 IME rules: while marked text exists nothing is restyled, revealed / hidden, replaced or
/// reloaded, and `onTextChange` never fires; what was asked meanwhile runs at the commit.
@Suite("IME (注音) rules", .serialized)
@MainActor
struct IMETests {
    private func n1Harness() -> EditorHarness {
        let harness = EditorHarness()
        harness.editor.imageResolver = { path in
            path == MarkdownSamples.n1ImagePath ? MarkdownSamples.n1ImageInfo(image: nil) : nil
        }
        harness.load(MarkdownSamples.n1, caret: MarkdownSamples.n1CaretLocation)
        return harness
    }

    /// Attribute runs of the whole text except the marked range (whose own attributes are AppKit's).
    private func runsOutsideMarked(_ harness: EditorHarness) -> [String] {
        let length = harness.editor.storage.length
        let marked = harness.textView.markedRange()
        guard marked.location != NSNotFound else { return harness.attributeRuns(in: NSRange(location: 0, length: length)) }
        return harness.attributeRuns(in: NSRange(location: 0, length: marked.location))
            + ["MARKED"]
            + harness.attributeRuns(in: NSRange(location: NSMaxRange(marked), length: length - NSMaxRange(marked)))
    }

    private func hiddenMap(_ harness: EditorHarness, _ range: NSRange) -> [Bool] {
        (range.location ..< NSMaxRange(range)).map { harness.isHidden($0) }
    }

    @Test func restyleTriggersAndTimersChangeNothingWhileComposing() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        let safari = harness.location(of: "- **Safari")
        let lineRange = (harness.text as NSString).lineRange(for: NSRange(location: safari, length: 0))
        let before = harness.attributeRuns(in: lineRange)
        harness.compose("ㄓ")
        #expect(harness.editor.isComposing)
        let afterCompose = runsOutsideMarked(harness)
        let hiddenBefore = hiddenMap(harness, NSRange(location: lineRange.location, length: lineRange.length - 1))
        // Every restyle trigger the API has.
        harness.editor.mode = .source
        harness.editor.setFontScale(1.4)
        harness.editor.hiddenFenceInfoStrings = []
        harness.editor.reloadImage(path: nil)
        harness.editor.imageResolver = { _ in nil }
        harness.editor.applyExternalText("# 外部\n")
        harness.editor.replace(NSRange(location: 0, length: 1), with: "X", actionName: "改")
        harness.editor.insertAtCaret("插")
        harness.editor.insertImageMarkdown(alt: "截圖", path: "assets/x/aaaaaa.png")
        harness.editor.setFolded(true, headingAt: harness.location(of: "## 問題"))
        harness.settle()
        // Timers, main-queue blocks, background layout: a few run-loop passes.
        harness.endEvent(0.3)
        harness.settle()
        #expect(harness.editor.isComposing)
        #expect(runsOutsideMarked(harness) == afterCompose)
        // The composing line keeps its own attributes (outside the marked text) and hide state.
        #expect(hiddenMap(harness, NSRange(location: lineRange.location, length: lineRange.length - 1)) == hiddenBefore)
        #expect(harness.textChanges.isEmpty)
        #expect(harness.editor.text == MarkdownSamples.n1)
        #expect(harness.text.contains("ㄓ"))
        #expect(harness.editor.mode == .source)
        #expect(harness.editor.appliedMode == .livePreview)
        _ = before
    }

    @Test func onTextChangeNeverFiresWhileComposing() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        harness.compose("ㄓㄨ")
        harness.compose("ㄓㄨˋ")
        #expect(harness.textChanges.isEmpty)
        #expect(harness.editor.text == MarkdownSamples.n1)
        harness.type("注")
        #expect(!harness.editor.isComposing)
        #expect(harness.textChanges.count == 1)
        #expect(harness.textChanges.last?.contains("上半截注") == true)
        #expect(harness.editor.text == harness.text)
    }

    @Test func externalTextWaitsForTheCommitAndKeepsTheComposition() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        let external = MarkdownSamples.n1.replacingOccurrences(of: "## 想請 AI 做的", with: "## 想請 AI 做的（外部）")
        harness.editor.applyExternalText(external)
        #expect(!harness.text.contains("（外部）"), "deferred while composing")
        harness.type("注")
        #expect(harness.text.contains("（外部）"))
        #expect(harness.text.contains("上半截注"))
        #expect(harness.editor.text == harness.text)
        // The app hears the merged text once (it differs from what it passed).
        #expect(harness.textChanges.count == 1)
        #expect(harness.textChanges.last == harness.text)
    }

    @Test func externalTextAppliesAtUnmarkText() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        harness.editor.applyExternalText("# 新標題\n\n內容\n")
        #expect(harness.text.contains("ㄓ"))
        harness.textView.unmarkText()
        #expect(!harness.editor.isComposing)
        #expect(harness.text.hasPrefix("# 新標題"))
        // The composed text the user committed is kept.
        #expect(harness.text.contains("ㄓ"))
    }

    @Test func externalTextWithoutCompositionIsSilentAndUndoable() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.editor.applyExternalText(MarkdownSamples.n1 + "外部加一行\n")
        #expect(harness.text == MarkdownSamples.n1 + "外部加一行\n")
        #expect(harness.textChanges.isEmpty)
        harness.endEvent()
        harness.textView.ownUndoManager.undo()
        #expect(harness.text == MarkdownSamples.n1)
        #expect(harness.textChanges.count == 1)
    }

    @Test func loadWaitsWhileComposing() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        harness.editor.load("# 另一則\n", selection: nil)
        #expect(harness.text.contains("ㄓ"))
        harness.type("注")
        #expect(harness.text == "# 另一則\n")
        #expect(!harness.textView.ownUndoManager.canUndo)
    }

    @Test func settingsQueuedWhileComposingApplyAtTheCommit() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        harness.editor.mode = .source
        harness.editor.setFontScale(1.5)
        #expect(harness.editor.appliedMode == .livePreview)
        harness.type("注")
        harness.settle()
        #expect(harness.editor.appliedMode == .source)
        let font = harness.editor.storage.attribute(.font, at: harness.location(of: "Safari"), effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == MarkdownEditorStyle.notebook.sourceFont.pointSize * 1.5)
    }

    @Test func revealDoesNotChangeWhileComposingAndTheCommitRestyles() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        // Compose `**` marks around nothing yet: the line stays revealed and styled as it was.
        let safari = harness.location(of: "- **Safari")
        harness.compose("ㄅ")
        #expect(!harness.isHidden(safari + 2))
        harness.type("八")
        #expect(!harness.isHidden(safari + 2))
        // Leaving the line hides its marks again.
        harness.select(0)
        #expect(harness.isHidden(safari + 2))
    }

    @Test func commandReturnIsIgnoredWithMarkedText() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        #expect(harness.keyEquivalent("\r", keyCode: 36, modifiers: .command))
        #expect(harness.commandReturns == 0)
        #expect(harness.editor.isComposing)
        harness.type("注")
        #expect(harness.keyEquivalent("\r", keyCode: 36, modifiers: .command))
        #expect(harness.commandReturns == 1)
        // ⌘⏎ reaching insertNewline (a key binding) sends too, never a newline.
        let length = harness.text.count
        harness.pressReturn(.command)
        #expect(harness.commandReturns == 2)
        #expect(harness.text.count == length)
    }

    @Test func returnWithMarkedTextCommitsWithoutANewline() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        harness.pressReturn()
        #expect(!harness.editor.isComposing)
        #expect(harness.text.contains("上半截ㄓ\n\n![截圖"))
        // No list continuation happened.
        #expect(!harness.text.contains("上半截ㄓ\n- "))
    }

    @Test func wrapsTabsAndUndoIgnoreMarkedText() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        let text = harness.text
        #expect(harness.keyEquivalent("b", keyCode: 11, modifiers: .command))
        #expect(harness.keyEquivalent("i", keyCode: 34, modifiers: .command))
        harness.textView.insertTab(nil)
        harness.textView.insertBacktab(nil)
        harness.textView.undo(nil)
        harness.textView.paste(nil)
        #expect(harness.text == text)
        #expect(harness.editor.isComposing)
    }

    @Test func aCancelledCompositionFlushes() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        harness.editor.mode = .source
        harness.compose("")
        #expect(!harness.editor.isComposing)
        #expect(harness.editor.appliedMode == .source)
        #expect(harness.text == MarkdownSamples.n1)
        #expect(harness.textChanges.isEmpty)
    }

    @Test func markedTextIsDrawnAmberUnderlined() {
        let harness = EditorHarness()
        defer { harness.tearDown() }
        let attributes = harness.textView.markedTextAttributes ?? [:]
        #expect((attributes[.foregroundColor] as? NSColor) == MarkdownEditorStyle.notebook.markedText)
        #expect((attributes[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
    }

    @Test func theCandidateWindowSitsUnderTheTextLine() {
        let harness = n1Harness()
        defer { harness.tearDown() }
        // The title line's fragment also holds the chips row; the input rect is the text line only.
        harness.editor.titleAccessory = FixedAccessory(height: 40)
        harness.select(3)
        let line = harness.editor.textLineRect(forCharacterAt: 3)!
        let style = MarkdownEditorStyle.notebook
        #expect(abs(line.height - style.titleFont.pointSize * style.titleLineHeight) < 0.01)
        #expect(harness.fragment(at: 3).height > line.height + 40)
    }
}
