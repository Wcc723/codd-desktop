import AppKit
import CoddUI
import Testing
@testable import CoddAnnotateUI

/// M5 D21: the ImageAnnotate screen (top bar, tool strip, canvas with its pins, the annotation
/// list and send options), built from the samples in an offscreen window, has no unlabeled
/// interactive element (CoddUI's `AccessibilityAudit`); the elements outside the key-view loop are
/// printed for the report, not failed. Pins are images with their description, and the canvas
/// takes ⏎ (add) and the arrows (move) so nothing needs the mouse.
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

    @Test func screenWithAndWithoutSelection() {
        for selection in [nil, 1] as [Int?] {
            let harness = AnnotateHarness(selection: selection)
            check(AccessibilityAudit.audit(window: harness.window, screen: "ANNOTATE selection \(selection.map(String.init) ?? "none")"))
            harness.tearDown()
        }
    }

    /// The parts on their own (the per-part counts of the report).
    @Test func partsOnTheirOwn() {
        let harness = AnnotateHarness(selection: 1)
        defer { harness.tearDown() }
        let parts: [(String, NSView)] = [("top bar", harness.view.topBar), ("tool strip", harness.view.toolStrip),
                                         ("list", harness.view.panel)]
        for (name, view) in parts {
            check(AccessibilityAudit.audit(view: view, screen: "ANNOTATE \(name)"))
        }
    }

    @Test func pinsAreDescribedImages() throws {
        let harness = AnnotateHarness(selection: 1)
        defer { harness.tearDown() }
        let pins = (harness.canvas.accessibilityChildren() ?? []).compactMap { $0 as? AnnotationPinElement }
        #expect(pins.map(\.n) == harness.items.map(\.n))
        let first = try #require(pins.first)
        #expect(first.accessibilityRole() == .image)
        let label = first.accessibilityLabel() ?? ""
        #expect(label.hasPrefix("標註 1 · "), "\(label)")
        #expect(label.contains(harness.items[0].coordinateText))
        #expect(first.isAccessibilitySelected())
        let second = try #require(pins.dropFirst().first)
        #expect(second.accessibilityPerformPress())
        #expect(harness.view.selection == second.n)
    }

    @Test func canvasAddsAndMovesWithoutTheMouse() throws {
        let harness = AnnotateHarness()
        defer { harness.tearDown() }
        harness.view.focusCanvas()
        let count = harness.items.count
        harness.press("p", keyCode: AnnotateHarness.keyP)
        harness.press("\r", keyCode: 36)
        #expect(harness.items.count == count + 1, "⏎ with the point tool adds one")
        let added = try #require(harness.items.last)
        #expect(harness.view.selection == added.n)
        harness.press("v", keyCode: AnnotateHarness.keyV)
        harness.press("\u{F703}", keyCode: 124)
        #expect(harness.view.document.item(added.n)?.x == added.x + 1, "→ moves the selection one pixel")
        harness.press("\u{F701}", keyCode: 125, flags: .shift)
        #expect(harness.view.document.item(added.n)?.y == added.y + 10, "⇧↓ moves ten")
    }
}
