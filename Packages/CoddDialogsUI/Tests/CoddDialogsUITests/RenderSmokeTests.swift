import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

/// Each dialog draws something: ink on the frame, the amber-dim border, and per dialog a color
/// only it uses (the to-card's cyan slot, the diff's added tint, the current step's amber, the
/// danger choice).
@Suite("Render smoke", .serialized)
@MainActor
struct RenderSmokeTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func check<View: DialogContentView>(_ view: View, expecting color: NSColor, _ name: String) throws {
        let harness = DialogHarness(view)
        defer { harness.tearDown() }
        let rep = try #require(harness.render(), "\(name) renders")
        #expect(rep.pixelsWide >= Int(view.dialogWidth), "\(name) width")
        #expect(rep.inkRatio() > 0.03, "\(name) is not blank")
        #expect(rep.contains(Palette.amberDim), "\(name) has the amber-dim frame")
        #expect(rep.contains(color), "\(name) draws its own content")
    }

    @Test func switchAccount() throws {
        try check(SwitchAccountDialogView(model: DialogSamples.switchAccountSwitching(now: now), onConfirm: { _ in }, onCancel: {}),
                  expecting: Palette.cyan, "A")
    }

    @Test func hookDiff() throws {
        try check(HookDiffDialogView(model: DialogSamples.hookDiff(), onApply: {}, onCancel: {}), expecting: Palette.termAddText, "B")
    }

    @Test func addAccount() throws {
        try check(AddAccountDialogView(model: DialogSamples.addAccountStep3(now: now, alias: "工作室"), onOpenLoginTerminal: {}, onCapture: {},
                                       onAdd: { _, _ in }, onAddToken: {}, onCancel: {}), expecting: Palette.danger, "C")
    }

    @Test func quit() throws {
        try check(QuitDialogView(model: DialogSamples.quit(now: now), onChoice: { _, _ in }), expecting: Palette.danger, "D")
    }

    @Test func heightsFollowTheContent() {
        let idle = DialogHarness(SwitchAccountDialogView(model: DialogSamples.switchAccount(now: now), onConfirm: { _ in }, onCancel: {}))
        defer { idle.tearDown() }
        let failed = DialogHarness(SwitchAccountDialogView(model: DialogSamples.switchAccountFailed(now: now), onConfirm: { _ in }, onCancel: {}))
        defer { failed.tearDown() }
        #expect(failed.view.fittingSize.height > idle.view.fittingSize.height, "the error line adds height")
        let noNeeds = DialogHarness(QuitDialogView(model: DialogSamples.quitNoNeeds(), onChoice: { _, _ in }))
        defer { noNeeds.tearDown() }
        let needs = DialogHarness(QuitDialogView(model: DialogSamples.quit(now: now), onChoice: { _, _ in }))
        defer { needs.tearDown() }
        #expect(needs.view.fittingSize.height - noNeeds.view.fittingSize.height >= 3 * DialogSessionRowView.height)
    }
}
