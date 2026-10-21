import AppKit
import CoddUI

/// M5 D21: the main-menu items for actions that were only a click (the rail, the NOTES modes, the
/// pane's `✎ NOTES` pill, the sidebar's `+ 新增群組`, the menu bar panel's account rows and the
/// status item's pause), so Full Keyboard Access and VoiceOver reach every one. None has a key
/// equivalent: the SPEC §2 shortcuts stay as they are.
extension AppDelegate {
    // MARK: 顯示方式 › SESSIONS / NOTES / STATUS (SETTINGS is `showSettings`)

    @objc func showSessionsArea(_ sender: Any?) { showArea(.sessions) }
    @objc func showNotesArea(_ sender: Any?) { showArea(.notes) }
    @objc func showStatusArea(_ sender: Any?) { showArea(.status) }

    /// The rail's click: the main window on that area.
    private func showArea(_ area: RailArea) {
        showMainWindow(nil)
        shell.area = area
    }

    // MARK: 筆記 › 筆記本 / 檔案 / 清理建議

    @objc func showNotebookMode(_ sender: Any?) {
        showArea(.notes)
        notesArea?.showNotebookMode()
    }

    /// The shown session's project in the Files mode (the header's files button), else the Files
    /// mode as it was left.
    @objc func showFilesMode(_ sender: Any?) {
        if shell.area == .sessions, let id = shell.currentSessionID, sessionStore.session(id).map({ !$0.external }) == true {
            showMainWindow(nil)
            openFiles(for: id)
            return
        }
        showArea(.notes)
        notesArea?.showFilesMode()
    }

    @objc func showCleanupMode(_ sender: Any?) { openCleanup() }

    // MARK: Session › 筆記抽屜 / 新增群組… / 切換帳號

    @objc func toggleNotesDrawer(_ sender: Any?) { mainWindow?.pane.toggleNotesDrawer() }

    @objc func newGroup(_ sender: Any?) {
        showArea(.sessions)
        mainWindow?.sidebar.beginNewGroup()
    }

    /// The accounts in R7 order, ✓ on the active one; a pick runs the D5 switch (dialog A first
    /// while 切換前確認 is ON) with its toast. Then `自動切換設定…` (Settings › 帳號).
    @objc func fillAccountsMenu(_ menu: NSMenu) {
        menu.autoenablesItems = false
        for account in accountStore.accounts where !account.isPseudo {
            let id = account.id
            let item = ClosureMenuItem(title: Self.accountMenuTitle(account)) { [weak self] in self?.userSwitch(id) }
            item.state = id == accountStore.activeAccountID ? .on : .off
            item.isEnabled = !accountStore.isSwitching && id != accountStore.activeAccountID
            menu.addItem(item)
        }
        if let note = accountStore.availability.note, accountStore.accounts.allSatisfy(\.isPseudo) {
            let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let settings = ClosureMenuItem(title: "自動切換設定…") { [weak self] in self?.openSettings(section: "accounts") }
        menu.addItem(settings)
    }

    /// `#3 工作 · 5h 剩 91% · 1w 剩 15%` (aliases only, never an e-mail).
    static func accountMenuTitle(_ account: AccountVM) -> String {
        "\(account.displayName) · 5h 剩 \(account.fiveHour.valueText) · 1w 剩 \(account.week.valueText)"
    }

    // MARK: CODD › 暫停通知 1 小時 / 恢復通知

    @objc func togglePauseNotifications(_ sender: Any?) { statusItem?.togglePause() }

    /// Validation for the items above (nil: not one of them).
    func validateAccessibilityMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        switch menuItem.action {
        case #selector(showSessionsArea(_:)):
            menuItem.state = shell.area == .sessions ? .on : .off
            return true
        case #selector(showNotesArea(_:)):
            menuItem.state = shell.area == .notes ? .on : .off
            return true
        case #selector(showStatusArea(_:)):
            menuItem.state = shell.area == .status ? .on : .off
            return true
        case #selector(showNotebookMode(_:)):
            menuItem.state = shell.area == .notes && notesArea?.mode == .notebook ? .on : .off
            return notesArea != nil
        case #selector(showFilesMode(_:)):
            menuItem.state = shell.area == .notes && notesArea?.mode == .files ? .on : .off
            return notesArea?.filesMode != nil
        case #selector(showCleanupMode(_:)):
            menuItem.state = shell.area == .notes && notesArea?.mode == .cleanup ? .on : .off
            return notesArea?.cleanupMode != nil
        case #selector(toggleNotesDrawer(_:)):
            guard let pane = mainWindow?.pane, shell.area == .sessions, let id = shell.currentSessionID,
                  sessionStore.session(id).map({ !$0.external }) == true else {
                menuItem.state = .off
                return false
            }
            menuItem.state = pane.isNotesDrawerShown ? .on : .off
            return true
        case #selector(newGroup(_:)):
            return mainWindow != nil
        case #selector(togglePauseNotifications(_:)):
            let paused = statusItem?.isPaused ?? false
            menuItem.title = paused ? MainMenuBuilder.resumeNotificationsTitle : MainMenuBuilder.pauseNotificationsTitle
            return statusItem != nil
        default:
            return nil
        }
    }
}
