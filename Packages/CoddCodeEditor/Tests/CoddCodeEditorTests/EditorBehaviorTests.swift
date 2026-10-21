import AppKit
import CoddUI
import Testing
@testable import CoddCodeEditor

@Suite("Code editor view", .serialized)
@MainActor
struct EditorBehaviorTests {
    // MARK: TextKit 1 and setup

    @Test func runsOnTextKit1WithSubstitutionsOff() {
        let harness = EditorHarness(text: "let a = 1", language: .javascript)
        defer { harness.tearDown() }
        let textView = harness.textView
        #expect(textView.textLayoutManager == nil)
        #expect(textView.layoutManager is CodeLayoutManager)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isRichText)
        #expect(harness.editor.textViewForTesting === textView)
        // The artboard's metrics: 12.5 pt, 20 pt rows, 4 pt top padding.
        #expect(harness.editor.font.pointSize == CGFloat(12.5))
        let fragment = harness.editor.layoutManagerImpl.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        #expect(fragment.height == CGFloat(20))
        #expect(textView.textContainerOrigin == NSPoint(x: 4, y: 4))
    }

    @Test func highlightsAsTemporaryAttributesOnly() throws {
        let harness = EditorHarness(text: "const greeting = 'hi' // c", language: .javascript)
        defer { harness.tearDown() }
        let style = harness.editor.style
        #expect(harness.color(at: 0) == style.keyword)
        #expect(harness.color(at: 17) == style.string)
        #expect(harness.color(at: 22) == style.comment)
        #expect(harness.editor.layoutManagerImpl.temporaryAttribute(.coddOblique, atCharacterIndex: 22, effectiveRange: nil) != nil)
        // The text storage itself keeps one plain run.
        let storage = try #require(harness.textView.textStorage)
        var range = NSRange()
        _ = storage.attributes(at: 0, effectiveRange: &range)
        #expect(range.length == storage.length)
    }

    @Test func languageChangeRehighlights() {
        let harness = EditorHarness(text: "def run(): pass", language: .plain)
        defer { harness.tearDown() }
        #expect(harness.color(at: 0) == nil)
        harness.editor.language = .python
        #expect(harness.color(at: 0) == harness.editor.style.keyword)
    }

    @Test func plainModeHasNoHighlightingAndNoWrapping() {
        let long = String(repeating: "const x = 'a' ", count: 200)
        let harness = EditorHarness(width: 400, text: long, language: .javascript, readOnly: true, plainMode: true)
        defer { harness.tearDown() }
        #expect(harness.editor.plainMode)
        #expect(harness.color(at: 0) == nil)
        #expect(!harness.editor.effectiveWraps)
        #expect(harness.textView.frame.width > 400)
        #expect(!harness.textView.isEditable)
        harness.editor.wrapsLines = true
        #expect(!harness.editor.effectiveWraps)
        // Find works in plain mode.
        harness.editor.showFind(replace: false, query: "const")
        #expect(harness.finds.last?.total == 200)
    }

    // MARK: Text changes

    @Test func onTextChangeReportsCommittedUserEditsOnly() {
        let harness = EditorHarness(text: "a", language: .plain)
        defer { harness.tearDown() }
        #expect(harness.textChanges.isEmpty)
        harness.caret(at: 1)
        harness.type("b")
        #expect(harness.textChanges == ["ab"])
        harness.editor.load("new", language: .plain, readOnly: false, plainMode: false)
        harness.editor.applyExternalText("newer")
        #expect(harness.textChanges == ["ab"])
        #expect(harness.editor.text == "newer")
    }

    @Test func returnKeepsTheIndentation() {
        let harness = EditorHarness(text: "    let a = 1", language: .javascript)
        defer { harness.tearDown() }
        harness.caret(at: 13)
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.editor.text == "    let a = 1\n    ")
    }

    @Test func lineEndingsAreNormalized() {
        let harness = EditorHarness(text: "a\r\nb\rc", language: .plain)
        defer { harness.tearDown() }
        #expect(harness.editor.text == "a\nb\nc")
        harness.caret(at: 5)
        harness.type("\r\nd")
        #expect(harness.editor.text == "a\nb\nc\nd")
    }

    // MARK: IME

    @Test func markedTextIsNeverReportedNorRestyled() {
        let harness = EditorHarness(text: "let x = 1\nconst y", language: .javascript)
        defer { harness.tearDown() }
        harness.caret(at: 9)
        let passes = harness.editor.highlightPassCount
        let before = harness.color(at: 0)
        harness.compose("ㄓㄨˋ")
        #expect(harness.editor.isComposing)
        #expect(harness.textChanges.isEmpty)
        #expect(harness.editor.text == "let x = 1\nconst y")
        harness.compose("ㄓㄨˋㄧㄣ")
        harness.settle()
        #expect(harness.editor.highlightPassCount == passes)
        #expect(harness.color(at: 0) == before)
        harness.commit("注音")
        #expect(!harness.editor.isComposing)
        #expect(harness.textChanges == ["let x = 1注音\nconst y"])
        #expect(harness.editor.highlightPassCount > passes)
        // The line keeps its colors after the commit.
        #expect(harness.color(at: 0) == harness.editor.style.keyword)
    }

    @Test func externalTextWaitsForTheComposition() {
        let harness = EditorHarness(text: "abc", language: .plain)
        defer { harness.tearDown() }
        harness.caret(at: 3)
        harness.compose("ㄅ")
        harness.editor.applyExternalText("from disk")
        #expect(harness.editor.text == "abc")
        #expect(harness.editor.isComposing)
        harness.commit("八")
        #expect(harness.editor.text == "from disk")
        #expect(harness.textChanges == ["abc八"])
    }

    @Test func escapeAndFindShortcutsWaitForTheComposition() {
        let harness = EditorHarness(text: "sticky sticky", language: .plain)
        defer { harness.tearDown() }
        let command = harness.keyEvent("f", modifiers: .command, keyCode: 3)
        harness.compose("ㄘ")
        #expect(!harness.editor.performKeyEquivalent(with: command))
        #expect(!harness.editor.findVisible)
        harness.commit("")
        #expect(harness.editor.performKeyEquivalent(with: command))
        #expect(harness.editor.findVisible)
        harness.window.makeFirstResponder(harness.textView)
        harness.compose("ㄘ")
        harness.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(harness.editor.findVisible)
        harness.commit("")
        harness.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!harness.editor.findVisible)
    }

    @Test func replaceLinesWaitsForTheComposition() {
        let harness = EditorHarness(text: "a\nb", language: .plain)
        defer { harness.tearDown() }
        harness.caret(at: 1)
        harness.compose("ㄅ")
        harness.editor.replaceLines(1 ..< 2, with: ["B"], actionName: "還原此段")
        #expect(harness.editor.text == "a\nb")
        harness.commit("")
        #expect(harness.editor.text == "a\nB")
    }

    // MARK: Undo

    @Test func replaceLinesIsOneUndoableEdit() throws {
        let harness = EditorHarness(text: "a\nb\nc\nd", language: .plain)
        defer { harness.tearDown() }
        let undo = try #require(harness.textView.undoManager)
        harness.editor.replaceLines(1 ..< 3, with: ["X", "Y", "Z"], actionName: "還原此段")
        #expect(harness.editor.text == "a\nX\nY\nZ\nd")
        #expect(undo.undoActionName == "還原此段")
        #expect(harness.textChanges.last == "a\nX\nY\nZ\nd")
        undo.undo()
        #expect(harness.editor.text == "a\nb\nc\nd")
        undo.redo()
        #expect(harness.editor.text == "a\nX\nY\nZ\nd")
        undo.undo()
        // Insertion before a line, at the end, and removal of the last lines.
        harness.editor.replaceLines(1 ..< 1, with: ["new"], actionName: "x")
        #expect(harness.editor.text == "a\nnew\nb\nc\nd")
        harness.editor.replaceLines(5 ..< 5, with: ["end"], actionName: "x")
        #expect(harness.editor.text == "a\nnew\nb\nc\nd\nend")
        harness.editor.replaceLines(4 ..< 6, with: [], actionName: "x")
        #expect(harness.editor.text == "a\nnew\nb\nc")
        harness.editor.replaceLines(0 ..< 1, with: [], actionName: "x")
        #expect(harness.editor.text == "new\nb\nc")
        for _ in 0 ..< 4 { undo.undo() }
        #expect(harness.editor.text == "a\nb\nc\nd")
        // Out of range and read-only are ignored.
        harness.editor.replaceLines(3 ..< 9, with: ["?"], actionName: "x")
        harness.editor.readOnly = true
        harness.editor.replaceLines(0 ..< 1, with: ["?"], actionName: "x")
        #expect(harness.editor.text == "a\nb\nc\nd")
    }

    @Test func loadClearsUndo() throws {
        let harness = EditorHarness(text: "a", language: .plain)
        defer { harness.tearDown() }
        harness.caret(at: 1)
        harness.type("b")
        harness.editor.load("x", language: .plain, readOnly: false, plainMode: false)
        #expect(harness.textView.undoManager?.canUndo == false)
    }

    // MARK: Find and replace

    @Test func findCountsAndStepsFromTheCaret() {
        let text = (1 ... 7).map { "line \($0) sticky" }.joined(separator: "\n")
        let harness = EditorHarness(text: text, language: .plain)
        defer { harness.tearDown() }
        harness.caret(at: (text as NSString).range(of: "line 3").location)
        harness.editor.showFind(replace: false, query: "sticky")
        #expect(harness.finds.last?.current == 3)
        #expect(harness.finds.last?.total == 7)
        #expect(harness.editor.findWidget.countText == "3/7")
        harness.editor.findNext()
        #expect(harness.finds.last?.current == 4)
        #expect(harness.textView.selectedRange() == harness.editor.findMatches[3])
        harness.editor.findPrevious()
        harness.editor.findPrevious()
        #expect(harness.finds.last?.current == 2)
        // The current match is solid amber with black text.
        let current = harness.editor.findMatches[1].location
        #expect(harness.color(at: current) == harness.editor.style.currentHitText)
        harness.editor.hideFind()
        #expect(harness.color(at: current) == nil)
    }

    @Test func findFieldUsesTheIMESafeFieldEditor() throws {
        let harness = EditorHarness(text: "打卡 打卡頁 sticky", language: .plain)
        defer { harness.tearDown() }
        harness.editor.showFind(replace: false, query: "")
        let editor = try #require(harness.window.firstResponder as? FindFieldEditor)
        let before = harness.finds.count
        editor.setMarkedText("ㄉㄚˇ", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.finds.count == before)
        // Return while composing commits; it does not step.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(!editor.hasMarkedText())
        editor.string = ""
        editor.insertText("打卡", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.finds.last?.query == "打卡")
        #expect(harness.finds.last?.total == 2)
        // Return = next, Shift+Return = previous, Esc closes.
        let current = harness.finds.last?.current ?? 0
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.finds.last?.current == current % 2 + 1)
        harness.editor.findWidget.modifierFlagsProvider = { .shift }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.finds.last?.current == current)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!harness.editor.findVisible)
        #expect(harness.window.firstResponder === harness.textView)
    }

    @Test func invalidRegexShowsADash() {
        let harness = EditorHarness(text: "sticky", language: .plain)
        defer { harness.tearDown() }
        harness.editor.showFind(replace: false, query: "(st")
        harness.editor.findOptions = FindOptions(regex: true)
        #expect(harness.finds.last?.total == -1)
        #expect(harness.editor.findWidget.countText == "—")
        #expect(harness.editor.findWidget.isInvalid)
        harness.editor.findOptions = FindOptions()
        #expect(harness.editor.findWidget.countText == "0/0")
    }

    @Test func replaceAllIsOneUndoGroup() throws {
        let harness = EditorHarness(text: "fixed a\nfixed b\nkeep\nfixed c", language: .plain)
        defer { harness.tearDown() }
        let undo = try #require(harness.textView.undoManager)
        harness.editor.showFind(replace: true, query: "fixed")
        harness.editor.findWidget.replaceField.setText("sticky")
        harness.editor.replaceAll()
        #expect(harness.editor.text == "sticky a\nsticky b\nkeep\nsticky c")
        #expect(undo.undoActionName == "全部取代")
        #expect(harness.textChanges.last == "sticky a\nsticky b\nkeep\nsticky c")
        undo.undo()
        #expect(harness.editor.text == "fixed a\nfixed b\nkeep\nfixed c")
        // Regex groups in the template, one match at a time.
        harness.editor.findOptions = FindOptions(regex: true)
        harness.editor.findWidget.queryField.setText(#"fixed (\w)"#)
        harness.editor.findQueryChanged()
        harness.editor.findWidget.replaceField.setText("$1: fixed")
        harness.caret(at: 0)
        harness.editor.runFind(resetCurrent: true, reveal: false)
        harness.editor.replaceCurrent()
        #expect(harness.editor.text == "a: fixed\nfixed b\nkeep\nfixed c")
        #expect(undo.undoActionName == "取代")
    }

    @Test func readOnlyRefusesEditsButFinds() {
        let harness = EditorHarness(text: "sticky", language: .plain, readOnly: true)
        defer { harness.tearDown() }
        harness.caret(at: 0)
        harness.type("x")
        #expect(harness.editor.text == "sticky")
        harness.editor.showFind(replace: true, query: "sticky")
        #expect(!harness.editor.findWidget.replaceVisible)
        harness.editor.replaceAll()
        #expect(harness.editor.text == "sticky")
        #expect(harness.finds.last?.total == 1)
    }

    // MARK: Caret and external text

    @Test func goToAndCaretReports() {
        let harness = EditorHarness(text: (1 ... 60).map { "line \($0)" }.joined(separator: "\n"), language: .plain)
        defer { harness.tearDown() }
        harness.editor.goTo(line: 42, column: 3)
        #expect(harness.editor.caret == CodeCaret(line: 42, column: 3, selectionLength: 0))
        #expect(harness.carets.last == CodeCaret(line: 42, column: 3, selectionLength: 0))
        harness.editor.goTo(line: 999, column: 999)
        #expect(harness.editor.caret == CodeCaret(line: 60, column: 8, selectionLength: 0))
        harness.textView.setSelectedRange(NSRange(location: 0, length: 4))
        #expect(harness.carets.last == CodeCaret(line: 1, column: 1, selectionLength: 4))
    }

    @Test func applyExternalTextKeepsCaretAndScroll() {
        let text = (1 ... 200).map { "line \($0)" }.joined(separator: "\n")
        let harness = EditorHarness(height: 300, text: text, language: .plain)
        defer { harness.tearDown() }
        harness.editor.goTo(line: 120, column: 4)
        harness.settle()
        let origin = harness.editor.scrollView.contentView.bounds.origin
        harness.editor.applyExternalText("header\n" + text.replacingOccurrences(of: "line 150", with: "LINE 150"))
        #expect(harness.editor.caret.line == 120)
        #expect(harness.editor.caret.column == 4)
        #expect(harness.editor.scrollView.contentView.bounds.origin == origin)
        #expect(harness.textView.undoManager?.undoActionName == "重新載入")
    }

    @Test func fontSizeScalesTheRows() {
        let harness = EditorHarness(text: "a\nb", language: .plain)
        defer { harness.tearDown() }
        harness.editor.fontSize = 15
        harness.settle()
        #expect(harness.editor.lineHeight == CGFloat(24))
        let fragment = harness.editor.layoutManagerImpl.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        #expect(fragment.height == CGFloat(24))
    }
}
