import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// M5 D21: the Cleanup page (tabs, table rows, bulk bar, CONDENSE in its four states and POLICY),
/// built from the samples in an offscreen window, has no unlabeled interactive element (CoddUI's
/// `AccessibilityAudit`); the elements outside the key-view loop are printed for the report, not
/// failed. Rows read as one element with the combined label and expose their selection.
@MainActor
@Suite struct AccessibilityAuditTests {
    private func check(_ report: AccessibilityAudit.Report, sourceLocation: SourceLocation = #_sourceLocation) {
        print("A11Y \(report.screen): interactive \(report.interactive), unlabeled \(report.unlabeled.count), outsideKeyLoop \(report.outsideKeyLoop.count)")
        for finding in report.outsideKeyLoop {
            print("A11Y   \(report.screen) outside key loop: \(finding.role) \(finding.path) \(finding.label ?? "")")
        }
        #expect(report.interactive > 0, "\(report.screen): nothing interactive found", sourceLocation: sourceLocation)
        #expect(report.unlabeled.isEmpty, "\(report.screen): \(report.unlabeled.map { "\($0.role) \($0.path)" })", sourceLocation: sourceLocation)
    }

    @Test func pageInEveryTabAndCondenseState() {
        let models: [(String, CleanupPageModel)] = [
            ("NOTES", CleanupSamples.artboard), ("NOTES as drawn", CleanupSamples.artboardAsDrawn),
            ("SESSIONS", CleanupSamples.sessions), ("FILES", CleanupSamples.files),
            ("CONDENSE idle", CleanupSamples.page(condense: .idle)),
            ("CONDENSE running", CleanupSamples.page(condense: .running(elapsed: "12s"))),
            ("CONDENSE preview", CleanupSamples.page(condense: .preview, withPreview: true)),
            ("CONDENSE failed", CleanupSamples.page(condense: .failed("claude -p 結束碼 1"))),
            ("CONDENSE disabled", CleanupSamples.page(condense: .idle, disabledReason: "沒有可用的帳號")),
        ]
        for (name, model) in models {
            let harness = CleanupHarness(model)
            check(AccessibilityAudit.audit(window: harness.window, screen: "CLEANUP \(name)"))
            harness.tearDown()
        }
    }

    /// The parts on their own (the per-part counts of the report).
    @Test func partsOnTheirOwn() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let review = harness.page.review
        let parts: [(String, NSView)] = [("tabs", review.tabStrip), ("table header", review.header), ("rows", review.rowsView),
                                         ("bulk bar", review.bulkBar), ("CONDENSE", harness.page.condense),
                                         ("POLICY", harness.page.policy)]
        for (name, view) in parts {
            check(AccessibilityAudit.audit(view: view, screen: "CLEANUP \(name)"))
        }
    }

    @Test func rowReadsAsOneSelectableElement() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let row = harness.row("gear3d-perf-p4m2")
        let label = row.accessibilityLabel() ?? ""
        #expect(label.hasPrefix("Gear3D 載入效能想法，"), "\(label)")
        #expect(label.contains(row.row.why) && label.contains(row.row.badge), "item, why (age) and status in one label: \(label)")
        #expect(row.accessibilityRole() == .row)
        #expect(row.isAccessibilitySelected() == row.isSelected)
        let selected = harness.row("keynote-ch2-a1b2")
        #expect(selected.isSelected && selected.isAccessibilitySelected())
        // The texts inside the row are not read a second time.
        let children = (row.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
        #expect(children.allSatisfy { $0 is CheckboxButton || $0 is CoddButton }, "\(children.map { type(of: $0) })")
    }

    /// D21 keyboard: ← → on a focused tab click the neighbouring tab; the crumb link presses on ⏎.
    @Test func tabsStepWithArrows() {
        let harness = CleanupHarness()
        defer {
            KeyboardFocus.fullKeyboardAccessOverride = nil
            harness.tearDown()
        }
        KeyboardFocus.fullKeyboardAccessOverride = true
        let notes = harness.page.review.tabStrip.tab(.notes)
        #expect(KeyboardFocus.focusAsKeyboardNavigation(notes))
        notes.keyDown(with: harness.key("\u{F703}", keyCode: 124))
        #expect(harness.log.events.contains("tab:sessions"))
        #expect(harness.window.firstResponder === harness.page.review.tabStrip.tab(.sessions))
        let back = harness.page.crumb.back
        #expect(KeyboardFocus.focusAsKeyboardNavigation(back))
        back.keyDown(with: harness.key("\r", keyCode: 36))
        #expect(harness.log.events.contains("back"))
        KeyboardFocus.fullKeyboardAccessOverride = false
        #expect(!notes.acceptsFirstResponder, "no key view without Full Keyboard Access")
    }
}
