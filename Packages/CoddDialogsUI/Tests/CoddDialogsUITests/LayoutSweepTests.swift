import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

/// M4 layout sweep: the dialogs follow the interface zoom (width included) and a sheet never
/// hangs below the screen.
@Suite("Dialog layout sweep", .serialized)
@MainActor
struct DialogLayoutSweepTests {
    @Test func theDialogWidthFollowsTheZoom() {
        TestFonts.register()
        let view = SwitchAccountDialogView(model: DialogSamples.switchAccount(now: Date()), onConfirm: { _ in }, onCancel: {})
        #expect(view.dialogWidth == SwitchAccountDialogView.width)
        UIZoom.withScale(20.0 / 13.0) {
            #expect(view.dialogWidth == UIZoom.pt(SwitchAccountDialogView.width))
            #expect(view.dialogWidth <= 1011, "inside the minimum main window at UI 20")
        }
    }

    @Test func aCappedSheetStaysBetweenTwoHundredFortyAndItsContent() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 150, width: 1011, height: 560), styleMask: [.titled],
                              backing: .buffered, defer: true)
        #expect(DialogPresenter.cappedHeight(100, under: window) <= 100)
        let tall = DialogPresenter.cappedHeight(20_000, under: window)
        #expect(tall >= 240 && tall < 20_000, "a sheet taller than any screen is capped")
    }
}
