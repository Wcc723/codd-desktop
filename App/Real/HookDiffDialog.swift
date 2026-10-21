import AppKit
import CoddClaudeSettings
import CoddDialogsUI

/// Dialog B · Hook 差異 (D10): the plan of one installer action as a sheet on the main window.
/// `預覽變更` and `更新` both open it; the file is written only by `套用並備份`, then the backup is
/// recorded, a toast says where it went and the inspection is read again. A refused write (the
/// file changed since the preview, a backup that failed) shows its reason in the dialog and
/// writes nothing.
@MainActor
final class HookDiffDialog {
    let service: ClaudeSettingsService
    let action: InstallerAction
    /// Settings › backup `差異`: the restore's diff, shown only (`套用並備份` stays disabled).
    let readOnly: Bool
    /// Shown after a successful write (`已更新 ~/.claude/settings.json · 備份 …`).
    var onToast: ((String) -> Void)?
    /// The dialog closed (applied or cancelled).
    var onFinish: (() -> Void)?
    private(set) var plan: InstallerPlan?
    private(set) var model: HookDiffModel?
    private(set) var view: HookDiffDialogView?
    private(set) var sheet: NSWindow?
    private(set) var applied = false

    init(service: ClaudeSettingsService, action: InstallerAction, readOnly: Bool = false) {
        self.service = service
        self.action = action
        self.readOnly = readOnly
    }

    /// Plans (off the main actor) and shows the sheet on `window`.
    func present(on window: NSWindow) async {
        let model = await makeModel()
        let view = HookDiffDialogView(model: model, onApply: { [weak self] in self?.applyPressed() },
                                      onCancel: { [weak self] in self?.close() })
        self.view = view
        sheet = DialogPresenter.presentSheet(view, on: window)
    }

    /// The dialog's model for the current file (also without a window: tests, the dump).
    func makeModel() async -> HookDiffModel {
        let model: HookDiffModel
        switch await service.plan(action) {
        case .success(let plan):
            self.plan = plan
            let exists = plan.base != nil
            var built = ClaudeSettingsService.diffModel(plan, settingsURL: service.settingsURL, fileExists: exists)
            if readOnly {
                built.canApply = false
                built.backupPath = ""
                built.summary.append("// 只比較：關閉後不會寫入任何東西；要還原請按備份列的 還原")
            }
            model = built
        case .failure(let error):
            plan = nil
            model = ClaudeSettingsService.failedModel(error, settingsURL: service.settingsURL)
        }
        self.model = model
        return model
    }

    /// `套用並備份`: writes the plan the user saw.
    func applyPressed() {
        guard !readOnly, let plan, plan.changes, !service.isApplying, !applied else { return }
        Task { [weak self] in await self?.apply(plan) }
    }

    func apply(_ plan: InstallerPlan) async {
        switch await service.apply(plan) {
        case .success(let backup):
            applied = true
            onToast?(Self.successText(action: plan.action, path: service.displayPath, backup: backup?.lastPathComponent))
            close()
        case .failure(let error):
            var model = self.model ?? ClaudeSettingsService.failedModel(error, settingsURL: service.settingsURL)
            model.canApply = false
            model.error = ClaudeSettingsService.message(for: error)
            self.model = model
            view?.update(model)
        }
    }

    func close() {
        if let sheet { DialogPresenter.dismiss(sheet) }
        sheet = nil
        let finish = onFinish
        onFinish = nil
        finish?()
    }

    /// `已更新 ~/.claude/settings.json · 備份 settings.json.codd-bak-…` (D10), `已建立 …` for a new file.
    static func successText(action: InstallerAction, path: String, backup: String?) -> String {
        let verb: String
        if case .restore = action { verb = "已還原" } else { verb = backup == nil ? "已建立" : "已更新" }
        return "\(verb) \(path)" + (backup.map { " · 備份 \($0)" } ?? "")
    }
}
