import AppKit
import Foundation
import CoddUI
import Testing
@testable import CODD

// Audit CODE-2: a ⌘-clicked terminal link opens only when it is a web or mail link, a file link
// is shown in Finder, any other scheme asks first with the full URL; the hovered link's real
// target (an OSC 8 hyperlink's included) shows in the slot's bottom-left corner.

private func url(_ string: String) throws -> URL { try #require(URL(string: string)) }

/// The local path a link is revealed at (nil: it is not revealed).
private func revealedPath(_ string: String) throws -> String? {
    guard case .reveal(let file) = TerminalLinkPolicy.action(for: try url(string)) else { return nil }
    #expect(file.isFileURL && (file.host ?? "").isEmpty)
    return file.path
}

@MainActor
@Suite("Terminal link policy")
struct TerminalLinkPolicyTests {
    @Test func webAndMailLinksOpenDirectly() throws {
        for link in ["http://example.com", "https://example.com/a?b=c#d", "HTTPS://EXAMPLE.COM", "mailto:someone@example.com"] {
            #expect(TerminalLinkPolicy.action(for: try url(link)) == .open, "\(link)")
        }
    }

    @Test func fileLinksAreRevealedAtTheirLocalPath() throws {
        #expect(try revealedPath("file:///tmp/evil-repo/setup.command") == "/tmp/evil-repo/setup.command")
        // The host part never reaches Finder; percent escapes and `..` are resolved.
        #expect(try revealedPath("FILE://server.local/tmp/a%20b/../c.txt") == "/tmp/c.txt")
        // An absolute path without a scheme (a detected path) is a file too.
        #expect(try revealedPath("/tmp/x.sh") == "/tmp/x.sh")
        #expect(try revealedPath("~/x.sh") == (NSHomeDirectory() as NSString).appendingPathComponent("x.sh"))
        // Nothing local to show.
        #expect(TerminalLinkPolicy.action(for: try url("file:")) == .ignore)
        #expect(TerminalLinkPolicy.action(for: try url("relative/path.txt")) == .ignore)
    }

    @Test func otherSchemesAskFirst() throws {
        for link in ["smb://server/share", "x-apple.systempreferences:com.apple.preference.security", "ssh://host",
                     "vscode://file/tmp/a", "javascript:alert(1)", "ftp://example.com", "tel:123"] {
            #expect(TerminalLinkPolicy.action(for: try url(link)) == .confirm, "\(link)")
        }
    }

    @Test func confirmationShowsTheFullURL() throws {
        let link = try url("smb://server.example/share/folder?x=1")
        let text = TerminalLinkPolicy.confirmation(link)
        #expect(text.message == "要開啟這個連結嗎？")
        #expect(text.info == "smb://server.example/share/folder?x=1")
    }
}

@MainActor
@Suite("Terminal link opener")
struct TerminalLinkOpenerTests {
    /// An opener whose steps only record; the confirm answer is given by the test.
    @MainActor
    final class Recorder {
        var opened: [URL] = []
        var revealed: [URL] = []
        var asked: [(url: URL, window: NSWindow?, answer: @MainActor (Bool) -> Void)] = []

        var opener: TerminalLinkOpener {
            TerminalLinkOpener(open: { self.opened.append($0) },
                               reveal: { self.revealed.append($0) },
                               confirm: { url, window, answer in self.asked.append((url, window, answer)) })
        }
    }

    @Test func eachSchemeTakesItsPath() throws {
        let recorder = Recorder()
        let opener = recorder.opener
        opener.handle(try url("https://example.com"), window: nil)
        opener.handle(try url("file:///tmp/setup.command"), window: nil)
        opener.handle(try url("relative.txt"), window: nil)
        #expect(recorder.opened == [try url("https://example.com")])
        #expect(recorder.revealed.map(\.path) == ["/tmp/setup.command"])
        #expect(recorder.asked.isEmpty)
    }

    @Test func anotherSchemeOpensOnlyWhenConfirmed() throws {
        let recorder = Recorder()
        let opener = recorder.opener
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let share = try url("smb://server/share")
        opener.handle(share, window: window)
        #expect(recorder.asked.count == 1 && recorder.asked.first?.url == share && recorder.asked.first?.window === window)
        recorder.asked.first?.answer(false)
        #expect(recorder.opened.isEmpty && recorder.revealed.isEmpty)

        opener.handle(share, window: window)
        recorder.asked.last?.answer(true)
        #expect(recorder.opened == [share] && recorder.revealed.isEmpty)
    }
}

@MainActor
@Suite("Terminal hover link")
struct TerminalHoverLinkTests {
    @Test func labelTextIsTheTargetWithHidingCharactersEncoded() {
        #expect(TerminalLinkPolicy.displayText(nil) == nil)
        #expect(TerminalLinkPolicy.displayText("") == nil)
        #expect(TerminalLinkPolicy.displayText("https://example.com/a b?q=中文") == "https://example.com/a b?q=中文")
        #expect(TerminalLinkPolicy.displayText("file:///tmp/evil-repo/setup.command") == "file:///tmp/evil-repo/setup.command")
        // A right-to-left override would show `moc.dmc` reversed; a newline or tab would split the
        // label; a zero-width space hides a character.
        #expect(TerminalLinkPolicy.displayText("https://example.com/\u{202E}dmc.moc") == "https://example.com/%E2%80%AEdmc.moc")
        #expect(TerminalLinkPolicy.displayText("https://a.example\nhttps://b.example\t") == "https://a.example%0Ahttps://b.example%09")
        #expect(TerminalLinkPolicy.displayText("https://exa\u{200B}mple.com") == "https://exa%E2%80%8Bmple.com")
        #expect(TerminalLinkPolicy.displayText("https://a.example/\u{2028}x") == "https://a.example/%E2%80%A8x")
    }

    @Test func bubbleShowsInTheBottomLeftCornerAndPassesTheMouseThrough() {
        let deck = TerminalDeckView()
        let slot = TerminalSlotView(deck: deck)
        // A flipped parent at the same origin: hit-test points read the same in both.
        let parent = FlippedView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        parent.addSubview(slot)
        slot.frame = parent.bounds
        let terminal = NSView()
        deck.show(terminal)
        #expect(deck.frame == slot.bounds && terminal.frame == slot.bounds)
        #expect(slot.linkText == nil)

        slot.showLink("file:///tmp/setup.command")
        #expect(slot.linkText == "file:///tmp/setup.command")
        let bubble = slot.subviews.last
        #expect(bubble !== deck && bubble?.isHidden == false)
        let frame = bubble?.frame ?? .zero
        #expect(frame.minX == TerminalSlotView.inset && frame.maxY == slot.bounds.height - TerminalSlotView.inset)
        #expect(frame.width > 0 && frame.width <= slot.bounds.width - 2 * TerminalSlotView.inset)
        // A ⌘-click on the link under the bubble reaches the terminal.
        #expect(slot.hitTest(NSPoint(x: frame.midX, y: frame.midY)) === terminal)

        // A long target stays inside the slot (truncated in the middle).
        slot.showLink("https://example.com/" + String(repeating: "a", count: 2000))
        #expect((bubble?.frame.width ?? 0) <= slot.bounds.width - 2 * TerminalSlotView.inset)

        slot.showLink(nil)
        #expect(slot.linkText == nil && bubble?.isHidden == true)
    }
}
