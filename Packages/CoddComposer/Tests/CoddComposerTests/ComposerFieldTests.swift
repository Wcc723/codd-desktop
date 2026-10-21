import AppKit
import Testing
@testable import CoddComposer

@Suite("Composer field", .serialized)
@MainActor
struct ComposerFieldTests {
    private func height(lines: Int, _ style: ComposerStyle = .standard) -> CGFloat {
        CGFloat(lines) * style.resolvedLineHeight + style.insets.top + style.insets.bottom
    }

    @Test func standardLineHeightIsTheArtboards() {
        // helmet .composer .ta: 12.5 px, line-height 1.5, padding 8px 10px.
        let style = ComposerStyle.standard
        #expect(style.resolvedLineHeight == 19)
        #expect(style.insets.top == 8 && style.insets.bottom == 8)
        #expect(style.insets.left == 10 && style.insets.right == 10)
        #expect(style.minLines == 1 && style.maxLines == 8)
        #expect(style.font.pointSize == 12.5)
    }

    @Test func growsFromOneToEightLinesThenScrolls() {
        let harness = ComposerHarness(width: 360)
        defer { harness.tearDown() }
        let field = harness.field
        #expect(field.preferredHeight == height(lines: 1))
        #expect(field.intrinsicContentSize.height == height(lines: 1))

        var text = "line 1"
        for lines in 2 ... 8 {
            text += "\nline \(lines)"
            harness.set(text)
            #expect(field.preferredHeight == height(lines: lines), "\(lines) lines")
        }
        #expect(harness.heights == (2 ... 8).map { height(lines: $0) })

        // Beyond eight lines the field stays put and the text scrolls.
        for lines in 9 ... 12 {
            text += "\nline \(lines)"
            harness.set(text)
        }
        #expect(field.preferredHeight == height(lines: 8))
        #expect(harness.heights.count == 7)
        harness.settle()
        let scrollView = try! #require(field.textView.enclosingScrollView)
        #expect(field.frame.height == height(lines: 8))
        #expect(field.textView.frame.height >= height(lines: 12) - 0.5)
        #expect(field.textView.frame.height > scrollView.contentSize.height)
        // The caret (at the end) is scrolled into view.
        #expect(scrollView.contentView.bounds.origin.y > 0)

        // And shrinks back.
        harness.set("one line again")
        #expect(field.preferredHeight == height(lines: 1))
        #expect(harness.heights.last == height(lines: 1))
    }

    @Test func typingNewlinesGrowsTheField() {
        let harness = ComposerHarness(width: 360)
        defer { harness.tearDown() }
        harness.press("a", keyCode: 0)
        harness.pressReturn(.shift)
        harness.press("b", keyCode: 11)
        #expect(harness.field.preferredHeight == height(lines: 2))
        harness.pressReturn(.shift)
        #expect(harness.field.preferredHeight == height(lines: 3))
        #expect(harness.textView.string == "a\nb\n")
    }

    @Test func softWrappedLinesCount() {
        let harness = ComposerHarness(width: 200)
        defer { harness.tearDown() }
        harness.set(String(repeating: "修正登入 API 401 ", count: 6))
        let lines = harness.textView.visualLineCount
        #expect(lines > 1)
        #expect(harness.field.preferredHeight == height(lines: min(lines, 8)),
                "lines \(lines) field \(harness.field.frame) text view \(harness.textView.frame) container \(harness.textView.textContainer?.size ?? .zero) scroll \(harness.textView.enclosingScrollView?.contentSize ?? .zero) heights \(harness.heights)")
    }

    @Test func compositionCountsTowardsTheHeight() {
        let harness = ComposerHarness(width: 360)
        defer { harness.tearDown() }
        harness.set("a\n")
        harness.compose("ㄓㄨˋ")
        #expect(harness.field.preferredHeight == height(lines: 2))
    }

    @Test func scrollersStayOverlayWhateverThePreference() throws {
        let harness = ComposerHarness(width: 200)
        defer { harness.tearDown() }
        let scrollView = try #require(harness.textView.enclosingScrollView)
        #expect(scrollView.scrollerStyle == .overlay)
        // What AppKit does when the user's preference (or the attached mouse) changes.
        scrollView.scrollerStyle = .legacy
        #expect(scrollView.scrollerStyle == .overlay)
        harness.set(String(repeating: "修正登入 API 401 ", count: 6))
        let settled = harness.field.preferredHeight
        harness.settle()
        harness.settle()
        #expect(harness.field.preferredHeight == settled)
        #expect(Set(harness.heights).count == harness.heights.count, "oscillated: \(harness.heights)")
    }

    @Test func minLinesIsTheFloor() {
        var style = ComposerStyle.standard
        style.minLines = 3
        style.maxLines = 4
        let harness = ComposerHarness(width: 360, style: style)
        defer { harness.tearDown() }
        #expect(harness.field.preferredHeight == height(lines: 3, style))
        harness.set("1\n2\n3\n4\n5\n6")
        #expect(harness.field.preferredHeight == height(lines: 4, style))
    }

    @Test func lineCountsClampInTheInitializer() {
        let style = ComposerStyle(
            font: .systemFont(ofSize: 12), textColor: .white, placeholderColor: .gray, caretColor: .orange,
            markedTextColor: .orange, background: .black, insets: NSEdgeInsets(), minLines: 0, maxLines: -2
        )
        #expect(style.minLines == 1)
        #expect(style.maxLines == 1)
        #expect(style.resolvedLineHeight > 0)
    }

    @Test func settingTextIsProgrammatic() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.textView.insertText("typed", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.textChanges == ["typed"])
        #expect(harness.textView.undoManager?.canUndo == true)
        harness.field.text = "restored\r\ndraft"
        #expect(harness.field.text == "restored\ndraft")
        #expect(harness.textChanges == ["typed"])
        #expect(harness.caret == ("restored\ndraft" as NSString).length)
        #expect(harness.textView.undoManager?.canUndo == false)
    }

    @Test func settingTextEndsAComposition() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        harness.compose("ㄓ")
        harness.field.text = ""
        #expect(!harness.textView.hasMarkedText())
        #expect(harness.field.text == "")
    }

    @Test func asymmetricInsetsPlaceTheText() {
        var style = ComposerStyle.standard
        style.insets = NSEdgeInsets(top: 4, left: 20, bottom: 12, right: 6)
        let harness = ComposerHarness(width: 300, style: style)
        defer { harness.tearDown() }
        #expect(harness.textView.textContainerOrigin == NSPoint(x: 20, y: 4))
        #expect(harness.field.preferredHeight == height(lines: 1, style))
        // The container is the view's width minus both side insets.
        harness.settle()
        let width = harness.textView.textContainer?.size.width ?? 0
        #expect(abs(width - (harness.textView.frame.width - 26)) < 0.5)
    }

    @Test func focusMakesTheTextViewFirstResponder() {
        let harness = ComposerHarness()
        defer { harness.tearDown() }
        var focus: [Bool] = []
        harness.textView.onFocusChange = { focus.append($0) }
        harness.window.makeFirstResponder(nil)
        #expect(focus == [false])
        harness.field.focus()
        #expect(harness.window.firstResponder === harness.textView)
        #expect(focus == [false, true])
    }
}
