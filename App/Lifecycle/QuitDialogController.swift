import AppKit
import CoddDialogsUI
import CoddUI

/// Dialog D (D18, StatusDialogs artboard D): what is still running when the user quits, and the
/// four ways out. A sheet on the main window while it shows, else its own centered window (the
/// status item's `結束` with the window closed). The app decides what each choice does.
@MainActor
final class QuitDialogController {
    private(set) var window: NSWindow?
    private(set) var view: QuitDialogView?
    private(set) var model: QuitModel?
    /// The last answer (the dump's `quitDialog.choice`), nil while open or before the first.
    private(set) var lastChoice: QuitChoice?
    private(set) var lastKeepNextTime = false
    var isShown: Bool { window != nil }

    /// The dialog's model: every live session counts as running (externals too, `13 個 session
    /// 執行中`), only CODD's can be stopped (`停止 CODD 啟動的 12 個 session…`); the rows are the
    /// NEEDS YOU sessions only, in the sidebar's NEEDS YOU order (artboard D; the panel scrolls
    /// past its visible rows and is hidden when nothing needs you). M3 review: other running
    /// sessions filled the box and NEEDS YOU came newest state first.
    static func model(store: any SessionStore, keepNextTime: Bool = false) -> QuitModel {
        let live = store.allSessions.filter { $0.state.isLive }
        let codd = live.filter { !$0.external }
        let needs = SidebarSnapshotBuilder.needsYou(store: store, filter: "").filter { $0.state.isLive }
        let rows = needs.map { row($0, store: store) }
        return QuitModel(running: live.count, needs: needs.count, rows: rows, stoppable: codd.count, keepNextTime: keepNextTime)
    }

    /// One `.srow.flat`: lamp, tag, title, pill, the state's duration, `group / project`.
    static func row(_ session: SessionVM, store: any SessionStore) -> DialogSessionRow {
        let style = StateStyle.of(session)
        let pill: String
        switch session.state {
        case .waiting:
            switch session.waitingReason {
            case .question?: pill = "Ask"
            case .plan?: pill = "Plan"
            default: pill = "Perm"
            }
        default: pill = style.pill
        }
        let project = store.project(session.projectID)
        let group = project.flatMap { store.group($0.groupID) }
        var location = [group.flatMap { $0.isUngrouped ? nil : $0.shortName }, project?.name].compactMap { $0 }.joined(separator: " / ")
        if session.state == .error, let reason = session.errorReason, !reason.isEmpty { location = reason.lowercased() + " · " + location }
        return DialogSessionRow(id: session.id, glyph: style.glyph, color: style.color, tag: session.tag?.color, title: session.title,
                                pill: pill, pillFilled: style.pillFill == .solid, since: session.stateSince, location: location)
    }

    /// Shows the dialog (a second call while it is open only brings it forward).
    func present(_ model: QuitModel, over main: NSWindow?, onChoice: @escaping (QuitChoice, Bool) -> Void) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        self.model = model
        lastChoice = nil
        let view = QuitDialogView(model: model) { [weak self] choice, keepNextTime in
            self?.answered(choice, keepNextTime: keepNextTime, onChoice: onChoice)
        }
        self.view = view
        if let main, main.isVisible, !main.isMiniaturized, main.attachedSheet == nil {
            window = DialogPresenter.presentSheet(view, on: main)
        } else {
            window = DialogPresenter.presentStandalone(view)
        }
    }

    /// Choice from code (DEBUG `-codd-quit-choice`, tests), the same path as a click.
    func choose(_ choice: QuitChoice, keepNextTime: Bool = false) {
        view?.choose(choice, keepNextTime: keepNextTime)
    }

    private func answered(_ choice: QuitChoice, keepNextTime: Bool, onChoice: (QuitChoice, Bool) -> Void) {
        lastChoice = choice
        lastKeepNextTime = keepNextTime
        dismiss()
        onChoice(choice, keepNextTime)
    }

    func dismiss() {
        if let window { DialogPresenter.dismiss(window) }
        window = nil
        view = nil
    }

    /// `stop-all`, `keep-running`, `menubar`, `cancel` (DEBUG flag and dump spelling).
    nonisolated static func name(_ choice: QuitChoice) -> String {
        switch choice {
        case .stopAllAndQuit: "stop-all"
        case .quitKeepingSessions: "keep-running"
        case .keepInMenuBar: "menubar"
        case .cancel: "cancel"
        }
    }

    nonisolated static func choice(named name: String) -> QuitChoice? {
        switch name.lowercased() {
        case "stop-all": .stopAllAndQuit
        case "keep-running": .quitKeepingSessions
        case "menubar": .keepInMenuBar
        case "cancel": .cancel
        default: nil
        }
    }
}
