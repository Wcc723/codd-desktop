import AppKit
import Testing
@testable import CoddComposer

/// The text view in an offscreen window, keys sent both as the commands AppKit derives from them
/// (`doCommand(by:)`) and as real key-down events through `interpretKeyEvents`.
@Suite("Composer text view", .serialized)
@MainActor
struct ComposerTextViewTests {
    // MARK: Enter

    @Test func enterSubmitsTheWholeText() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("修正登入 API 401")
        harness.pressReturn()
        #expect(harness.submitted == ["修正登入 API 401"])
        // The view does not clear itself; the owner decides.
        #expect(harness.textView.string == "修正登入 API 401")

        harness.set("第一行\n第二行", caret: 2)
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.submitted == ["修正登入 API 401", "第一行\n第二行"])
    }

    @Test func enterOnAnEmptyComposerStillReportsIt() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.pressReturn()
        #expect(harness.submitted == [""])
    }

    @Test func shiftEnterInsertsANewline() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("第一行")
        harness.pressReturn(.shift)
        #expect(harness.submitted.isEmpty)
        #expect(harness.textView.string == "第一行\n")
        harness.textView.insertText("第二行", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textView.string == "第一行\n第二行")
        // Through the command path too, with the modifiers the provider reports.
        harness.flags = .shift
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == "第一行\n第二行\n")
        #expect(harness.submitted.isEmpty)
    }

    @Test func optionEnterInsertsANewline() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("a")
        // AppKit maps Option+Return to insertNewlineIgnoringFieldEditor:.
        harness.pressReturn(.option)
        #expect(harness.textView.string == "a\n")
        // If it arrived as insertNewline: the Option flag still makes it a newline.
        harness.flags = .option
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.textView.string == "a\n\n")
        #expect(harness.submitted.isEmpty)
    }

    @Test func controlEnterInsertsALineFeedNotALineSeparator() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("a")
        harness.pressReturn(.control)
        #expect(harness.textView.string == "a\n")
        #expect(harness.submitted.isEmpty)
    }

    @Test func commandEnterIsLeftToTheMenu() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("a")
        harness.pressReturn(.command)
        harness.flags = .command
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.submitted.isEmpty)
        #expect(harness.textView.string == "a")
    }

    // MARK: Marked text (input methods)

    @Test func enterWhileComposingCommitsAndNeverSubmits() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }

        // Path 1: the command AppKit derives from Return.
        harness.set("修正")
        harness.compose("ㄉㄥ")
        #expect(harness.textView.hasMarkedText())
        harness.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.submitted.isEmpty)
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.textView.string == "修正ㄉㄥ")

        // Path 2: a real Return key-down routed through interpretKeyEvents.
        harness.set("修正")
        harness.compose("ㄉㄥ")
        harness.pressReturn()
        #expect(harness.submitted.isEmpty)
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.textView.string == "修正ㄉㄥ")

        // Path 3: the action sent directly (accessibility, a menu item).
        harness.set("修正")
        harness.compose("ㄉㄥ")
        harness.textView.insertNewline(nil)
        #expect(harness.submitted.isEmpty)
        #expect(harness.textView.string == "修正ㄉㄥ")

        // Shift held while composing changes nothing.
        harness.set("修正")
        harness.compose("ㄉㄥ")
        harness.pressReturn(.shift)
        #expect(harness.submitted.isEmpty)
        #expect(harness.textView.string == "修正ㄉㄥ")

        // Once committed, the next Return submits.
        harness.pressReturn()
        #expect(harness.submitted == ["修正ㄉㄥ"])
    }

    @Test func optionEnterWhileComposingKeepsTheComposition() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("a")
        harness.compose("ㄓㄨˋ")
        harness.pressReturn(.option)
        #expect(harness.textView.string == "aㄓㄨˋ")
        harness.compose("ㄧㄣ")
        harness.textView.doCommand(by: #selector(NSResponder.insertLineBreak(_:)))
        #expect(harness.textView.string == "aㄓㄨˋㄧㄣ")
        #expect(harness.submitted.isEmpty)
    }

    @Test func markedTextIsDrawnInTheMarkedColorWithAnUnderline() throws {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        let attributes = harness.textView.markedTextAttributes ?? [:]
        #expect((attributes[.foregroundColor] as? NSColor) == ComposerStyle.standard.markedTextColor)
        #expect((attributes[.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
        // AppKit applies them when drawing (not in the storage): amber pixels appear only while composing.
        harness.set("修正 ")
        #expect(try amberPixels(harness.textView) == 0)
        harness.compose("ㄓㄨˋ")
        let composing = try amberPixels(harness.textView)
        #expect(composing > 40)
        harness.pressReturn()
        #expect(harness.submitted.isEmpty)
        #expect(try amberPixels(harness.textView) == 0)
    }

    // MARK: Esc

    @Test func escapeWithoutMarkedTextAsksTheOwner() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("draft")
        harness.press("\u{1B}", keyCode: 53)
        #expect(harness.escapes == 1)
        harness.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(harness.escapes == 2)
        // NSTextView's completion key is Esc too.
        harness.textView.doCommand(by: #selector(NSResponder.complete(_:)))
        #expect(harness.escapes == 3)
        #expect(harness.textView.string == "draft")
    }

    @Test func escapeWhileComposingIsTheInputMethods() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("draft")
        harness.compose("ㄓ")
        harness.press("\u{1B}", keyCode: 53)
        harness.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(harness.escapes == 0)
        harness.textView.doCommand(by: #selector(NSResponder.complete(_:)))
        #expect(harness.escapes == 0)
        #expect(harness.textView.string.hasPrefix("draft"))
    }

    // MARK: History

    @Test func upOnTheFirstLineRecallsHistory() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "上一則\nprompt"
        harness.set("draft", caret: 2)
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.historyRequests == [.previous])
        #expect(harness.textView.string == "上一則\nprompt")
        #expect(harness.caret == ("上一則\nprompt" as NSString).length)
        #expect(harness.textChanges.last == "上一則\nprompt")
    }

    @Test func downOnTheLastLineRecallsHistory() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.next] = "newer"
        harness.set("one\ntwo", caret: 5)
        harness.press("\u{F701}", keyCode: 125)
        #expect(harness.historyRequests == [.next])
        #expect(harness.textView.string == "newer")
        #expect(harness.caret == 5)
    }

    @Test func upInsideMultiLineTextMovesTheCaret() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "should not appear"
        harness.historyAnswers[.next] = "should not appear"
        harness.set("one\ntwo\nthree", caret: 6) // inside "two"
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.historyRequests.isEmpty)
        #expect(harness.textView.string == "one\ntwo\nthree")
        #expect(harness.caret < 4) // now on the first line
        harness.set("one\ntwo\nthree", caret: 6)
        harness.press("\u{F701}", keyCode: 125)
        #expect(harness.historyRequests.isEmpty)
        #expect(harness.caret > 8) // now on the last line
    }

    @Test func caretAfterATrailingNewlineIsOnTheLastLine() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "older"
        harness.set("one\n")
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.historyRequests.isEmpty)
        #expect(harness.caret <= 3)
        harness.set("one\n")
        #expect(harness.textView.caretIsOnLastLine)
        #expect(!harness.textView.caretIsOnFirstLine)
    }

    @Test func aWrappedLineCountsAsVisualLines() {
        let harness = ComposerHarness(width: 160)
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "older"
        let long = String(repeating: "word ", count: 30)
        harness.set(long) // caret at the end: on the last visual line, not the first
        #expect(harness.textView.visualLineCount > 1)
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.historyRequests.isEmpty)
        #expect(harness.textView.string == long)
    }

    @Test func noAnswerLetsTheArrowMove() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("draft", caret: 3)
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.historyRequests == [.previous])
        #expect(harness.textView.string == "draft")
        #expect(harness.caret == 0) // NSTextView moves to the start on the first line
    }

    @Test func emptyComposerRecallsBothWays() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "older"
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.textView.string == "older")
        harness.set("")
        harness.historyAnswers[.next] = "newer"
        harness.press("\u{F701}", keyCode: 125)
        #expect(harness.textView.string == "newer")
    }

    @Test func noHistoryWhileComposing() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "older"
        harness.set("a")
        harness.compose("ㄓ")
        harness.textView.doCommand(by: #selector(NSResponder.moveUp(_:)))
        #expect(harness.historyRequests.isEmpty)
        #expect(harness.textView.string.hasPrefix("a"))
        #expect(harness.textView.string != "older")
    }

    @Test func aRecallIsOneUndoStep() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "older"
        harness.set("")
        harness.textView.insertText("mine", replacementRange: NSRange(location: NSNotFound, length: 0))
        endEvent() // undo groups close at the end of each event, as between two key presses
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.textView.string == "older")
        endEvent()
        harness.textView.undoManager?.undo()
        #expect(harness.textView.string == "mine")
    }

    @Test func theEditMenusUndoReachesTheComposer() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        let undoItem = NSMenuItem(title: "Undo", action: #selector(ComposerTextView.undo(_:)), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: #selector(ComposerTextView.redo(_:)), keyEquivalent: "Z")
        #expect(!harness.textView.validateUserInterfaceItem(undoItem))
        harness.textView.insertText("abc", replacementRange: NSRange(location: NSNotFound, length: 0))
        endEvent()
        #expect(harness.textView.validateUserInterfaceItem(undoItem))
        #expect(undoItem.title != "Undo") // "Undo Typing" in the user's language
        // What a nil-targeted menu item does: the first responder that answers, before the window.
        #expect(harness.textView.tryToPerform(#selector(ComposerTextView.undo(_:)), with: nil))
        #expect(harness.textView.string == "")
        #expect(harness.textView.validateUserInterfaceItem(redoItem))
        #expect(harness.textView.tryToPerform(#selector(ComposerTextView.redo(_:)), with: nil))
        #expect(harness.textView.string == "abc")
    }

    @Test func recalledCarriageReturnsBecomeLineFeeds() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.historyAnswers[.previous] = "a\r\nb\rc"
        harness.press("\u{F700}", keyCode: 126)
        #expect(harness.textView.string == "a\nb\nc")
    }

    /// Lets the run loop finish a pass, which closes the undo manager's event group.
    private func endEvent() {
        RunLoop.current.run(until: Date())
    }

    // MARK: Paste and drop

    @Test func pastesPlainText() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        harness.set("參考 ")
        board.pasteboard.setString("修正登入 API 401\r\n第二行", forType: .string)
        harness.textView.paste(from: board.pasteboard)
        #expect(harness.textView.string == "參考 修正登入 API 401\n第二行")
        #expect(harness.pastedImages.isEmpty)
        #expect(harness.textChanges.last == harness.textView.string)
    }

    @Test func pastedTextReplacesTheSelection() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        harness.set("abc")
        harness.textView.setSelectedRange(NSRange(location: 1, length: 1))
        board.pasteboard.setString("X", forType: .string)
        harness.textView.paste(from: board.pasteboard)
        #expect(harness.textView.string == "aXc")
    }

    @Test func textWinsOverAnImage() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        harness.imageAnswer = "/should/not/appear"
        board.pasteboard.declareTypes([.string, .png], owner: nil)
        board.pasteboard.setString("caption", forType: .string)
        board.pasteboard.setData(TestImages.bitmap().representation(using: .png, properties: [:])!, forType: .png)
        harness.textView.paste(from: board.pasteboard)
        #expect(harness.textView.string == "caption")
        #expect(harness.pastedImages.isEmpty)
    }

    @Test func pastedPNGGoesToTheOwnerAndTheAnswerIsInserted() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        let png = TestImages.bitmap().representation(using: .png, properties: [:])!
        board.pasteboard.setData(png, forType: .png)
        let path = #"/Users/a/Library/Application\ Support/CODD/sessions/s1/attachments/20261016-153000-a1b2c3.png"#
        harness.imageAnswer = path
        harness.set("看這張 ")
        harness.textView.paste(from: board.pasteboard)
        #expect(harness.pastedImages == [.png(png)])
        #expect(harness.textView.string == "看這張 " + path)
    }

    @Test func pastedTIFFIsConvertedToPNG() throws {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        board.pasteboard.setData(TestImages.bitmap(width: 3, height: 2).tiffRepresentation!, forType: .tiff)
        harness.imageAnswer = "/tmp/x.png"
        harness.textView.paste(from: board.pasteboard)
        let image = try #require(harness.pastedImages.first)
        guard case .tiff = image else {
            Issue.record("a TIFF is handed over unconverted (the owner converts it off the main actor)")
            return
        }
        let data = try #require(image.pngData())
        #expect(Array(data.prefix(8)) == TestImages.pngSignature)
        let decoded = try #require(NSBitmapImageRep(data: data))
        #expect(decoded.pixelsWide == 3 && decoded.pixelsHigh == 2)
        #expect(harness.textView.string == "/tmp/x.png")
    }

    /// Review concurrency-perf-3: the re-encode runs wherever the owner calls it (off main).
    @Test func tiffIsConvertedOffTheMainActor() async throws {
        let tiff = try #require(TestImages.bitmap(width: 5, height: 4).tiffRepresentation)
        let png = await Task.detached { ComposerPastedImage.tiff(tiff).pngData() }.value
        let data = try #require(png)
        #expect(Array(data.prefix(8)) == TestImages.pngSignature)
        #expect(NSBitmapImageRep(data: data)?.pixelsWide == 5)
        #expect(ComposerPastedImage.tiff(Data([1, 2, 3])).pngData() == nil)
        #expect(ComposerPastedImage.png(Data()).pngData() == nil)
    }

    @Test func declinedImageInsertsNothing() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        board.pasteboard.setData(TestImages.bitmap().representation(using: .png, properties: [:])!, forType: .png)
        harness.imageAnswer = nil
        harness.set("keep")
        harness.textView.paste(from: board.pasteboard)
        #expect(harness.pastedImages.count == 1)
        #expect(harness.textView.string == "keep")
        #expect(harness.textChanges.isEmpty)
    }

    @Test func droppedFilesAreInsertedAsEscapedPaths() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        board.pasteboard.writeObjects([
            URL(fileURLWithPath: "/Users/a/Library/Application Support/CODD/x.png") as NSURL,
            URL(fileURLWithPath: "/Users/a/專案 (2)/README.md") as NSURL,
        ])
        harness.set("看 ")
        #expect(harness.textView.readSelection(from: board.pasteboard, type: .fileURL))
        #expect(harness.textView.string
            == #"看 /Users/a/Library/Application\ Support/CODD/x.png /Users/a/專案\ \(2\)/README.md"#)
    }

    @Test func aDroppedFileWithALineBreakInItsNameInsertsNothing() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: "/tmp/x/photo\n./evil").absoluteString, forType: .fileURL)
        item.setString("photo\n./evil", forType: .string)
        board.pasteboard.writeObjects([item])
        harness.set("看 ")
        harness.textChanges = []
        #expect(harness.textView.readSelection(from: board.pasteboard, type: .fileURL), "handled: no fallback to the name")
        #expect(harness.textView.string == "看 ")
        harness.textView.paste(from: board.pasteboard)
        #expect(harness.textView.string == "看 ")
        #expect(harness.textChanges.isEmpty)
    }

    @Test func aCopiedFinderFilePastesItsPathNotItsName() {
        let harness = ComposerHarness()
        let board = PrivatePasteboard()
        defer { harness.tearDown(); board.release() }
        // Finder puts the file URL, the bare name as text and the icon as TIFF.
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: "/tmp/a b.txt").absoluteString, forType: .fileURL)
        item.setString("a b.txt", forType: .string)
        item.setData(TestImages.bitmap().tiffRepresentation!, forType: .tiff)
        board.pasteboard.writeObjects([item])
        harness.imageAnswer = "/should/not/appear"
        harness.textView.paste(from: board.pasteboard)
        #expect(harness.textView.string == #"/tmp/a\ b.txt"#)
        #expect(harness.pastedImages.isEmpty)
    }

    @Test func dragTypesIncludeFilesAndImages() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        let types = Set(harness.textView.acceptableDragTypes)
        #expect(types.isSuperset(of: [.fileURL, .string, .png, .tiff]))
    }

    // MARK: Key equivalents

    @Test func reservedCommandKeysAreNotConsumed() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("draft")
        let reserved: [(String, UInt16, NSEvent.ModifierFlags)] = [
            ("l", 37, .command), ("k", 40, .command), ("\r", 36, .command), ("j", 38, .command),
            ("t", 17, .command), ("p", 35, .command), (".", 47, .command), ("\\", 42, .command),
            ("n", 45, .command), (",", 43, .command), ("w", 13, .command),
        ] + (1 ... 9).map { (String($0), UInt16(17 + $0), NSEvent.ModifierFlags.command) }
        for (key, code, modifiers) in reserved {
            let event = harness.keyEvent(key, keyCode: code, modifiers: modifiers)
            #expect(!harness.textView.performKeyEquivalent(with: event), "⌘\(key) was consumed")
        }
        // Delivered as a key-down (no menu claimed it), ⌘L still types nothing.
        harness.press("l", keyCode: 37, modifiers: .command)
        #expect(harness.textView.string == "draft")
        #expect(harness.submitted.isEmpty)
    }

    @Test func standardEditingChordsAreTheOnlyOnesPassedOn() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        func isEditing(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            ComposerTextView.isStandardEditingEquivalent(harness.keyEvent(key, keyCode: 0, modifiers: modifiers))
        }
        #expect(isEditing("a", .command))
        #expect(isEditing("c", .command))
        #expect(isEditing("x", .command))
        #expect(isEditing("v", .command))
        #expect(isEditing("z", .command))
        #expect(isEditing("Z", [.command, .shift]))
        #expect(!isEditing("l", .command))
        #expect(!isEditing("v", [.command, .control]))
        #expect(!isEditing("a", []))
    }

    // MARK: Text system

    @Test func isAPlainTextViewWithoutSubstitutions() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        let view = harness.textView
        #expect(!view.isRichText)
        #expect(!view.importsGraphics)
        #expect(!view.allowsImageEditing)
        #expect(!view.isAutomaticQuoteSubstitutionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticTextReplacementEnabled)
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        #expect(!view.isAutomaticLinkDetectionEnabled)
        #expect(!view.isContinuousSpellCheckingEnabled)
        #expect(view.allowsUndo)
        #expect(!view.usesFindBar)
        #expect(view.textLayoutManager == nil) // TextKit 1
        #expect(view.insertionPointColor == ComposerStyle.standard.caretColor)
    }

    @Test func typedQuotesAndDashesStayAsTyped() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        for character in ["\"", "a", "'", "-", "-", " ", "x"] {
            harness.press(character, keyCode: 0)
        }
        #expect(harness.textView.string == "\"a'-- x")
        #expect(harness.textChanges.count == 7)
    }

    @Test func placeholderIsDrawnButIsNotText() throws {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        let view = harness.textView
        view.placeholder = ""
        let blank = try litPixels(view)
        view.placeholder = "給 Claude 的訊息（⌘L）"
        let shown = try litPixels(view)
        #expect(view.string.isEmpty)
        #expect(blank == 0)
        #expect(shown > 20)
        harness.set("x")
        harness.set("")
        #expect(try litPixels(view) == shown)
    }

    @Test func applyingAStyleRestylesExistingText() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("abc")
        var style = ComposerStyle.standard
        style.textColor = .red
        style.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        harness.field.apply(style)
        let storage = harness.textView.textStorage!
        #expect(storage.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == .red)
        #expect((storage.attribute(.font, at: 1, effectiveRange: nil) as? NSFont)?.pointSize == 16)
    }

    /// Orange-hued pixels (amber, also antialiased on black) in a render of `view`.
    private func amberPixels(_ view: NSView) throws -> Int {
        try countPixels(view) { $0.redComponent > $0.greenComponent + 0.12 && $0.greenComponent > $0.blueComponent + 0.15 }
    }

    /// Pixels brighter than the field background in a render of `view` (the caret is not drawn).
    private func litPixels(_ view: NSView) throws -> Int {
        try countPixels(view) { $0.redComponent + $0.greenComponent + $0.blueComponent > 0.3 }
    }

    private func countPixels(_ view: NSView, where matches: (NSColor) -> Bool) throws -> Int {
        view.display()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for x in 0 ..< rep.pixelsWide {
            for y in 0 ..< rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if matches(color) { count += 1 }
            }
        }
        return count
    }
}

/// Review e2e-2: marked text (an input method's composition) never reaches `onTextChange`, so a
/// saved draft never brings back half-typed 注音, and a programmatic text set (a session switch)
/// never reports the composition it ends.
@Suite("Composer text view: marked text and drafts", .serialized)
@MainActor
struct ComposerMarkedTextDraftTests {
    @Test func compositionIsNotReportedUntilCommitted() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("草稿")
        harness.textChanges = []
        harness.compose("ㄅ")
        harness.compose("ㄅㄚ")
        #expect(harness.textView.hasMarkedText())
        #expect(harness.textView.string == "草稿ㄅㄚ")
        #expect(harness.textView.committedText == "草稿")
        #expect(harness.textChanges.allSatisfy { $0 == "草稿" }, "\(harness.textChanges)")
        // The input method commits a candidate: now it is text.
        harness.textView.insertText("八", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.textChanges.last == "草稿八")
    }

    @Test func returnCommitsTheCompositionAndReportsIt() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("修正")
        harness.textChanges = []
        harness.compose("ㄉㄥ")
        harness.pressReturn()
        #expect(harness.submitted.isEmpty)
        #expect(harness.textChanges.last == "修正ㄉㄥ", "the committed text reaches the draft")
    }

    @Test func aProgrammaticSetNeverReportsTheCompositionItEnds() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.set("A 的草稿")
        harness.compose("ㄅㄚ")
        harness.textChanges = []
        // A session switch: the field shows another session's draft.
        harness.field.text = "B 的草稿"
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.textView.string == "B 的草稿")
        #expect(harness.textChanges.isEmpty, "\(harness.textChanges)")
    }
}
