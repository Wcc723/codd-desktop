import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// M5 D21: the STATUS sidebar and every page section, in every sample state, have no unlabeled
/// interactive element (CoddUI's `AccessibilityAudit`); the elements outside the key-view loop are
/// printed for the report, not failed.
@MainActor
@Suite struct AccessibilityAuditTests {
    private func check(_ report: AccessibilityAudit.Report, sourceLocation: SourceLocation = #_sourceLocation) {
        print("A11Y \(report.screen): interactive \(report.interactive), unlabeled \(report.unlabeled.count), outsideKeyLoop \(report.outsideKeyLoop.count)")
        for finding in report.outsideKeyLoop {
            print("A11Y   \(report.screen) outside key loop: \(finding.role) \(finding.path) \(finding.label ?? "")")
        }
        #expect(report.unlabeled.isEmpty, "\(report.screen): \(report.unlabeled.map { "\($0.role) \($0.path)" })", sourceLocation: sourceLocation)
    }

    /// The whole window (sidebar + page) per state, with the key-loop check.
    @Test(arguments: StatusSamples.State.allCases)
    func everyState(_ state: StatusSamples.State) {
        let harness = StatusHarness(StatusSamples.model(state))
        defer { harness.tearDown() }
        let report = AccessibilityAudit.audit(window: harness.window, screen: "STATUS \(state.rawValue)")
        #expect(report.interactive > 0)
        check(report)
    }

    /// Each part on its own (the per-section counts of the report).
    @Test func sidebarAndEverySection() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let parts: [(String, NSView)] = [("sidebar", harness.sidebar), ("HOST", harness.page.host), ("ACCOUNTS", harness.page.accounts),
                                         ("HOOKS", harness.page.hooks), ("MCP", harness.page.mcp), ("REMOTE", harness.page.remote)]
        for (name, view) in parts {
            check(AccessibilityAudit.audit(view: view, screen: "STATUS \(name)"))
        }
    }

    /// D21 keyboard: the SECTIONS nav steps with ↑ ↓ and its items read as one selectable element.
    @Test func navStepsWithArrows() throws {
        let harness = StatusHarness()
        defer {
            KeyboardFocus.fullKeyboardAccessOverride = nil
            harness.tearDown()
        }
        KeyboardFocus.fullKeyboardAccessOverride = true
        let host = try #require(harness.sidebar.navItem(.host))
        let accounts = try #require(harness.sidebar.navItem(.accounts))
        #expect(host.isAccessibilitySelected())
        #expect(KeyboardFocus.focusAsKeyboardNavigation(host))
        host.keyDown(with: Self.key(125, "\u{F701}"))
        #expect(harness.window.firstResponder === accounts)
        var picked: [StatusSection] = []
        harness.sidebar.onSelectSection = { picked.append($0) }
        accounts.keyDown(with: Self.key(49, " "))
        #expect(picked == [.accounts], "space presses the focused item")
        #expect(harness.sidebar.selectedSection == .accounts)
        KeyboardFocus.fullKeyboardAccessOverride = false
        #expect(!accounts.acceptsFirstResponder, "no key view without Full Keyboard Access")
    }

    private static func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}
