import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

@Suite("Presenter", .serialized)
@MainActor
struct PresenterTests {
    private func parentWindow() -> NSWindow {
        TestFonts.register()
        let window = NSWindow(contentRect: NSRect(x: 200, y: 150, width: 1200, height: 800), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func addAccountView(cancelled: Recorder<Bool> = Recorder()) -> AddAccountDialogView {
        AddAccountDialogView(model: DialogSamples.addAccountStep3(now: Date(), alias: "studio"), onOpenLoginTerminal: {}, onCapture: {},
                             onAdd: { _, _ in }, onAddToken: {}, onCancel: { cancelled.append(true) })
    }

    @Test func presentPanelAttachesAChildWindowAtTheParentsRightEdge() throws {
        let parent = parentWindow()
        defer { parent.close() }
        let view = addAccountView()
        let panel = DialogPresenter.presentPanel(view, over: parent)
        #expect(panel.parent === parent)
        #expect(parent.childWindows?.contains { $0 === panel } == true)
        #expect(panel.contentView === view)
        // D24: 24 pt inside the right edge, 80 pt below the top.
        #expect(panel.frame.maxX == parent.frame.maxX - 24)
        #expect(panel.frame.maxY == parent.frame.maxY - 80)
        #expect(panel.frame.width == AddAccountDialogView.width)
        #expect(panel.frame.height >= 400)
        // Above its parent only: same level, not a floating panel, stays when the app deactivates.
        #expect(panel.level == parent.level)
        #expect(!panel.isFloatingPanel)
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.becomesKeyOnlyIfNeeded)
        #expect(!panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey && !panel.canBecomeMain)

        // Clicking into the parent makes it key; the panel does not take focus back.
        parent.makeKeyAndOrderFront(nil)
        #expect(!panel.isKeyWindow)
        #expect(panel.parent === parent, "still attached")

        DialogPresenter.dismiss(panel)
        #expect(parent.childWindows?.contains { $0 === panel } != true)
        #expect(panel.parent == nil)
    }

    @Test func thePanelStaysInsideAShortParent() {
        let origin = DialogPresenter.panelOrigin(size: NSSize(width: 560, height: 600), parentFrame: NSRect(x: 0, y: 0, width: 900, height: 640))
        #expect(origin.x == CGFloat(900 - 24 - 560))
        #expect(origin.y == 0, "would start 40 pt below the parent: clamped to its bottom")
        let tall = DialogPresenter.panelOrigin(size: NSSize(width: 560, height: 500), parentFrame: NSRect(x: 100, y: 100, width: 1200, height: 800))
        #expect(tall == NSPoint(x: CGFloat(100 + 1200 - 24 - 560), y: CGFloat(100 + 800 - 80 - 500)))
    }

    @Test func thePanelDragsByItsHeaderButNotByTheCloseButton() throws {
        let parent = parentWindow()
        defer { parent.close() }
        let panel = try #require(DialogPresenter.presentPanel(addAccountView(), over: parent) as? DialogPanel)
        defer { DialogPresenter.dismiss(panel) }
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = panel.frame.height
        func mouseDown(at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        #expect(panel.dragRegionHeight >= 50)
        #expect(panel.isInDragRegion(mouseDown(at: NSPoint(x: 200, y: height - 20))), "the title band")
        #expect(!panel.isInDragRegion(mouseDown(at: NSPoint(x: 200, y: height - 120))), "the body")
        let close = try #require((panel.contentView as? DialogContentView)?.frameCloseButton)
        let closeCenter = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
        #expect(!panel.isInDragRegion(mouseDown(at: closeCenter)), "✕ stays a button")
    }

    @Test func escapeInThePanelCancels() throws {
        let parent = parentWindow()
        defer { parent.close() }
        let cancelled = Recorder<Bool>()
        let panel = DialogPresenter.presentPanel(addAccountView(cancelled: cancelled), over: parent)
        defer { DialogPresenter.dismiss(panel) }
        let esc = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                windowNumber: panel.windowNumber, context: nil, characters: "\u{1B}",
                                                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 0x35))
        #expect(panel.performKeyEquivalent(with: esc))
        panel.cancelOperation(nil)
        panel.performClose(nil)
        #expect(cancelled.count == 3, "⎋, cancelOperation and ⌘W all go through onCancel")
        #expect(panel.isVisible || panel.parent === parent, "the app closes it, not the panel itself")
    }

    @Test func presentSheetBeginsASheetOnTheWindow() throws {
        let parent = parentWindow()
        defer { parent.close() }
        let cancelled = Recorder<Bool>()
        let view = QuitDialogView(model: DialogSamples.quit(now: Date())) { choice, _ in if choice == .cancel { cancelled.append(true) } }
        let sheet = DialogPresenter.presentSheet(view, on: parent)
        #expect(sheet.contentView === view)
        #expect(sheet.sheetParent === parent)
        #expect(sheet.frame.width == QuitDialogView.width)
        sheet.cancelOperation(nil)
        sheet.performClose(nil)
        #expect(cancelled.count == 2)
        DialogPresenter.dismiss(sheet)
        #expect(parent.attachedSheet == nil)
        #expect(sheet.sheetParent == nil)
    }

    @Test func presentStandaloneShowsTheDialogInItsOwnWindow() {
        TestFonts.register()
        let choices = Recorder<QuitChoice>()
        let view = QuitDialogView(model: DialogSamples.quitNoNeeds()) { choice, _ in choices.append(choice) }
        let window = DialogPresenter.presentStandalone(view)
        #expect(window.contentView === view)
        #expect(window.sheetParent == nil && window.parent == nil)
        #expect(window.frame.width == QuitDialogView.width)
        window.performClose(nil)
        #expect(choices.values == [.cancel], "⌘W / the close command is the dialog's cancel")
        DialogPresenter.dismiss(window)
        #expect(!window.isVisible)
    }

    @Test func aSheetGrowsWhenTheProgressLineAppears() {
        let parent = parentWindow()
        defer { parent.close() }
        let view = SwitchAccountDialogView(model: DialogSamples.switchAccount(now: Date()), onConfirm: { _ in }, onCancel: {})
        let sheet = DialogPresenter.presentSheet(view, on: parent)
        defer { DialogPresenter.dismiss(sheet) }
        let before = sheet.frame.height
        view.update(DialogSamples.switchAccountSwitching(now: Date()))
        #expect(sheet.frame.height > before)
        #expect(abs(sheet.contentLayoutRect.height - view.fittingSize.height) < 1)
    }
}
