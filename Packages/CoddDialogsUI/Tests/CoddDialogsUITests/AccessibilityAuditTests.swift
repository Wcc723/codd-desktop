import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

/// M5 D21: dialogs A–D in their sample states and the snippet dialog, in an offscreen window, have
/// no unlabeled interactive element (CoddUI's `AccessibilityAudit`); the elements outside the
/// key-view loop are printed for the report, not failed.
@MainActor
@Suite struct AccessibilityAuditTests {
    private let now = Date(timeIntervalSince1970: 1_792_032_127)

    private func audit<View: DialogContentView>(_ view: View, _ screen: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let harness = DialogHarness(view)
        defer { harness.tearDown() }
        let report = AccessibilityAudit.audit(window: harness.window, screen: screen)
        print("A11Y \(screen): interactive \(report.interactive), unlabeled \(report.unlabeled.count), outsideKeyLoop \(report.outsideKeyLoop.count)")
        for finding in report.outsideKeyLoop { print("A11Y   \(screen) outside key loop: \(finding.role) \(finding.path) \(finding.label ?? "")") }
        #expect(report.interactive > 0, "\(screen): nothing interactive found", sourceLocation: sourceLocation)
        #expect(report.unlabeled.isEmpty, "\(screen): \(report.unlabeled.map { "\($0.role) \($0.path)" })", sourceLocation: sourceLocation)
    }

    @Test func switchAccount() {
        audit(SwitchAccountDialogView(model: DialogSamples.switchAccount(now: now), onConfirm: { _ in }, onCancel: {}), "Dialog A switch account")
        audit(SwitchAccountDialogView(model: DialogSamples.switchAccountSwitching(now: now), onConfirm: { _ in }, onCancel: {}),
              "Dialog A switching")
        audit(SwitchAccountDialogView(model: DialogSamples.switchAccountFailed(now: now), onConfirm: { _ in }, onCancel: {}), "Dialog A failed")
    }

    @Test func hookDiff() {
        audit(HookDiffDialogView(model: DialogSamples.hookDiff(), onApply: {}, onCancel: {}), "Dialog B hook diff")
        audit(HookDiffDialogView(model: DialogSamples.hookDiffNoChanges(), onApply: {}, onCancel: {}), "Dialog B no changes")
        audit(HookDiffDialogView(model: DialogSamples.hookDiffError(), onApply: {}, onCancel: {}), "Dialog B error")
    }

    @Test func addAccount() {
        let models: [(String, AddAccountModel)] = [
            ("step 1", DialogSamples.addAccountStep1()), ("step 2", DialogSamples.addAccountStep2(now: now)),
            ("step 3", DialogSamples.addAccountStep3(now: now, alias: "工作室")), ("existing", DialogSamples.addAccountExisting(now: now)),
            ("failed", DialogSamples.addAccountFailed(now: now)),
        ]
        for (name, model) in models {
            audit(AddAccountDialogView(model: model, onOpenLoginTerminal: {}, onCapture: {}, onAdd: { _, _ in }, onAddToken: {}, onCancel: {}),
                  "Dialog C add account \(name)")
        }
    }

    @Test func quit() {
        audit(QuitDialogView(model: DialogSamples.quit(now: now), onChoice: { _, _ in }), "Dialog D quit")
        audit(QuitDialogView(model: DialogSamples.quitNoNeeds(), onChoice: { _, _ in }), "Dialog D quit, nothing waiting")
    }

    @Test func snippet() {
        let snippet = "[mcp_servers.codd]\nurl = \"http://127.0.0.1:47821/mcp\"\n"
        audit(SnippetDialogView(title: "註冊到 Codex", message: "把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）", snippet: snippet,
                                onCopy: {}, onClose: {}), "Dialog snippet")
    }
}
