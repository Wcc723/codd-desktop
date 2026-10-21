import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// The page's keys belong to it only while it is the first responder and no field editor in its
/// window has marked text (注音 composing keeps space, ⌫, esc and ⌘A); no window is ever ordered
/// front by the page.
@Suite("Keyboard and windows", .serialized)
@MainActor
struct KeyboardTests {
    @Test func keysAreIgnoredWhileAFieldComposes() throws {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 200, height: 24))
        harness.window.contentView?.addSubview(field)
        #expect(harness.window.makeFirstResponder(field))
        let editor = try #require(harness.window.firstResponder as? NSTextView)
        editor.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(!harness.page.keyboardIsOurs)
        let before = harness.page.selection
        harness.space()
        harness.delete()
        harness.escape()
        #expect(!harness.page.performKeyEquivalent(with: harness.key("a", keyCode: 0, flags: .command)), "⌘A stays the field's")
        harness.page.selectAll(nil)
        #expect(harness.page.selection == before)
        #expect(harness.log.events.isEmpty)
        // The composition ends; the field is still the first responder, so the page still waits.
        editor.unmarkText()
        harness.commandA()
        #expect(harness.page.selection == before)
        // Back on the page: its keys work again.
        harness.focusPage()
        #expect(harness.page.keyboardIsOurs)
        harness.commandA()
        #expect(harness.page.selection.count == 8)
        harness.escape()
        #expect(harness.log.events.last == "back")
    }

    @Test func keysNeedThePageToBeFirstResponder() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        harness.window.makeFirstResponder(nil)
        harness.escape()
        harness.delete()
        harness.space()
        #expect(harness.log.events.isEmpty)
        #expect(harness.page.selection == CleanupSamples.selectedNotes)
    }

    @Test func modifiedKeysAreNotThePages() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        harness.focusPage()
        harness.press(" ", keyCode: 49, flags: .option)
        harness.press("\u{7F}", keyCode: 51, flags: .option)
        #expect(harness.log.events.isEmpty)
        #expect(harness.page.selection == CleanupSamples.selectedNotes)
    }

    @Test func noWindowIsOrderedFront() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        harness.focusPage()
        harness.click(harness.row("gear3d-perf-p4m2"))
        harness.commandA()
        harness.page.showToast("AI 存取為 OFF 的筆記不會交給 Claude")
        harness.update(CleanupSamples.sessions)
        harness.update(CleanupSamples.page(condense: .running(elapsed: "3s")))
        _ = harness.body.select.makeMenu()
        #expect(!harness.window.isVisible)
        #expect(NSApplication.shared.windows.allSatisfy { !$0.isVisible })
    }

    /// The package never activates the app or orders a window in (background runs, D39).
    @Test func sourcesNeverActivateOrOrderFront() throws {
        var sources = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { sources.deleteLastPathComponent() }
        sources.appendPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        let forbidden = ["orderFront", "makeKeyAndOrderFront", "orderFrontRegardless", ".activate(", "activateIgnoringOtherApps",
                         "runModal", "NSWorkspace", "NSPasteboard"]
        var checked = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for word in forbidden { #expect(!text.contains(word), "\(url.lastPathComponent) uses \(word)") }
            checked += 1
        }
        #expect(checked >= 8)
    }
}
