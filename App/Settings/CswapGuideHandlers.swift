import AppKit
import CoddStatusUI

/// FB 「引導安裝 cswap」: what the guide's buttons do in the app (STATUS › ACCOUNTS, 設定 › 帳號 and
/// onboarding step 5). `複製` writes through `CoddPasteboard` (D39: a background run writes the
/// private pasteboard); `在終端機執行` opens an ephemeral SHELL session `安裝 cswap` in `~` (D24's
/// mechanism, as dialog C's login terminal) with the command typed and NOT run: no Return is sent,
/// the user reads it and presses Return. The session goes when its shell exits. `重新偵測` is each
/// surface's own re-read (STATUS `↻`, Settings `重新讀取`, onboarding `↻ 重新偵測`).
@MainActor
struct CswapGuideHandlers {
    var copy: @MainActor (String) -> Void = { _ in }
    var openTerminal: @MainActor (String) -> Void = { _ in }

    /// Title of the terminal session.
    static let sessionTitle = "安裝 cswap"

    /// Every command a guide shows (the three surfaces show the same ones); only these are typed.
    static var commands: Set<String> {
        Set(CswapInstallGuide(kind: .install).commands + CswapInstallGuide(kind: .upgrade).commands)
    }

    /// What the shell is sent for `command`: the command itself, never a Return; nil for anything
    /// that is not one of the guide's commands.
    static func typing(for command: String) -> String? {
        guard commands.contains(command), !command.contains("\r"), !command.contains("\n") else { return nil }
        return command
    }
}

extension AppDelegate {
    /// The handlers on this app's pasteboard and holder store.
    func cswapGuideHandlers() -> CswapGuideHandlers {
        CswapGuideHandlers(copy: { [weak self] text in self?.copyCswapGuideText(text) },
                           openTerminal: { [weak self] command in self?.openCswapInstallTerminal(command) })
    }

    /// STATUS's guide buttons (CoddStatusUI's closure type).
    func cswapGuideActions() -> CswapGuideActions {
        CswapGuideActions(copy: { [weak self] text in self?.copyCswapGuideText(text) },
                          runInTerminal: { [weak self] command in self?.openCswapInstallTerminal(command) })
    }

    /// `[複製]`: a user action (D39).
    func copyCswapGuideText(_ text: String) {
        pasteboard.write(text, userAction: true)
    }

    /// `[在終端機執行]`: the main window shows an ephemeral SHELL session with `command` typed (not
    /// run). Returns its id; nil when refused (a toast says why) or in mock mode.
    @discardableResult
    func openCswapInstallTerminal(_ command: String) -> SessionID? {
        guard let typing = CswapGuideHandlers.typing(for: command) else {
            HolderSessionStore.printLog("cswap guide terminal refused: not a guide command")
            return nil
        }
        showMainWindow(nil)
        guard let holders = holderStore else {
            _ = mainWindow?.showToast("示範模式不會開啟終端機：請在終端機輸入 \(command)", undo: nil)
            return nil
        }
        guard let id = holders.createEphemeralShell(title: CswapGuideHandlers.sessionTitle, cwd: NSHomeDirectory(), typing: typing,
                                                    discardOnExit: true) else {
            _ = mainWindow?.showToast(holders.lastRefusal ?? "無法開啟終端機", undo: nil)
            return nil
        }
        mainWindow?.show(id)
        HolderSessionStore.printLog("cswap guide terminal session=\(id) typed (not run)")
        return id
    }
}
