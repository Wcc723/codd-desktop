import AppKit

/// What the page asks the app to do (buttons that are not a plain preference edit). Every
/// closure runs on the main actor and defaults to doing nothing, so demos and tests set only
/// what they need.
@MainActor
public struct SettingsActions {
    /// GENERAL › 預設專案根目錄 `選擇…` (the app shows a folder panel, then edits
    /// `general.projectRoot` through `SettingsModel.update`).
    public var chooseProjectRoot: () -> Void
    /// A hotkey recorder started (the app suspends the registered global hotkey, so the current
    /// combo can be pressed again).
    public var recordHotkeyStarted: () -> Void
    /// The recorder finished (recorded or cancelled): the app re-registers whatever
    /// `general.hotkey` now says.
    public var recordHotkeyFinished: () -> Void
    /// Asked before a new combo is stored (recorder, SHORTCUTS `還原預設`): nil accepts it, a
    /// message refuses it (D22: shown under the row, the previous combo kept). The app tries
    /// the exclusive registration here.
    public var tryHotkey: (KeyCombo) -> String?
    /// NOTIFICATIONS `傳送測試通知`.
    public var sendTestNotification: () -> Void
    /// HOOKS `預覽變更` (dialog B).
    public var openHookDiff: () -> Void
    /// HOOKS `重新安裝` / a component's `更新`.
    public var reinstallHooks: () -> Void
    /// HOOKS `解除安裝`.
    public var uninstallHooks: () -> Void
    /// HOOKS Legacy `只移除舊版`.
    public var removeLegacy: () -> Void
    /// ACCOUNTS `+ 加入帳號` (dialog C).
    public var addAccount: () -> Void
    /// ADVANCED 資料庫 `在 Finder 顯示`.
    public var showDataRoot: () -> Void
    /// ADVANCED `重設所有設定` (the app confirms, then replaces the preferences).
    public var resetAll: () -> Void
    /// ABOUT `複製版本資訊`.
    public var copyDiagnostics: () -> Void
    /// REMOTE `看規劃 → Remote 畫板`.
    public var openRemoteBoard: () -> Void
    /// ACCOUNTS alias committed (account id, cswap-normalized alias; nil = `cswap alias N --unset`).
    public var setAlias: (String, String?) -> Void
    /// HOOKS backup `還原`.
    public var restoreBackup: (String) -> Void
    /// HOOKS backup `差異` (dialog B in restore mode).
    public var compareBackup: (String) -> Void
    /// `在 Finder 顯示` for a shown path (HOOKS status dir).
    public var revealPath: (String) -> Void
    /// SESSIONS › 預設啟動設定檔 (the default lives in profiles.json, not in the preferences).
    public var setDefaultProfile: (String) -> Void
    /// A section's head button `還原本頁預設` ran (after `SettingsModel.resetSection`).
    public var resetSection: (SettingsSection) -> Void
    /// ACCOUNTS `重新讀取` (shown only while `SettingsInfo.accountsUnavailable` is set): re-read
    /// cswap's state, falling back to `cswap list` at most once per 10 minutes (D1).
    public var rereadAccounts: () -> Void
    /// NOTEBOOK & MCP `開啟筆記本資料夾` (the app reveals `<dataRoot>/notes`; a user action, D39).
    public var openNotesFolder: () -> Void
    /// NOTEBOOK & MCP `輪替` (the app confirms, then replaces the external MCP token, D23).
    public var rotateMCPToken: () -> Void
    /// A 註冊 row's button (`SettingsMCPRegistration.id`: `claude-code`, `codex`, `claude-desktop`).
    public var mcpRegistration: (String) -> Void
    /// ADVANCED `重建` (rebuilds the derived notes index; the `.md` files are not touched).
    public var rebuildNotesIndex: () -> Void
    /// CLEANUP head `查看清理建議 · n →` (the NOTES area's Cleanup page).
    public var openCleanup: () -> Void
    /// ABOUT 首次啟動設定 `重新執行` (M5 §2.4: the app reopens the onboarding window at step 1 with
    /// live data; nothing is changed until the user applies a step).
    public var openOnboarding: () -> Void
    /// ABOUT 第三方元件授權 `開啟` (the app opens its bundled THIRD-PARTY-NOTICES.md).
    public var openThirdPartyNotices: () -> Void
    /// FB: ACCOUNTS cswap guide `複製` (the app writes the pasteboard, D39).
    public var copyText: (String) -> Void
    /// FB: ACCOUNTS cswap guide `在終端機執行`: a terminal with the command typed, not run.
    public var openInstallTerminal: (String) -> Void
    /// FB: asked before 剩餘不足時自動切換 turns ON (the page's window, then the answer); the
    /// preference changes only on a yes. Defaults to ``SettingsAutoSwitchRisk/ask(on:done:)``.
    public var confirmAutoSwitch: (NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void

    public init(chooseProjectRoot: @escaping () -> Void = {}, recordHotkeyStarted: @escaping () -> Void = {},
                recordHotkeyFinished: @escaping () -> Void = {}, tryHotkey: @escaping (KeyCombo) -> String? = { _ in nil },
                sendTestNotification: @escaping () -> Void = {}, openHookDiff: @escaping () -> Void = {},
                reinstallHooks: @escaping () -> Void = {}, uninstallHooks: @escaping () -> Void = {},
                removeLegacy: @escaping () -> Void = {}, addAccount: @escaping () -> Void = {},
                showDataRoot: @escaping () -> Void = {}, resetAll: @escaping () -> Void = {},
                copyDiagnostics: @escaping () -> Void = {}, openRemoteBoard: @escaping () -> Void = {},
                setAlias: @escaping (String, String?) -> Void = { _, _ in }, restoreBackup: @escaping (String) -> Void = { _ in },
                compareBackup: @escaping (String) -> Void = { _ in }, revealPath: @escaping (String) -> Void = { _ in },
                setDefaultProfile: @escaping (String) -> Void = { _ in },
                resetSection: @escaping (SettingsSection) -> Void = { _ in }, rereadAccounts: @escaping () -> Void = {},
                openNotesFolder: @escaping () -> Void = {}, rotateMCPToken: @escaping () -> Void = {},
                mcpRegistration: @escaping (String) -> Void = { _ in }, rebuildNotesIndex: @escaping () -> Void = {},
                openCleanup: @escaping () -> Void = {}, openOnboarding: @escaping () -> Void = {},
                openThirdPartyNotices: @escaping () -> Void = {},
                copyText: @escaping (String) -> Void = { _ in }, openInstallTerminal: @escaping (String) -> Void = { _ in },
                confirmAutoSwitch: @escaping (NSWindow?, @escaping @MainActor (Bool) -> Void) -> Void = { window, done in
                    SettingsAutoSwitchRisk.ask(on: window, done: done)
                }) {
        self.chooseProjectRoot = chooseProjectRoot
        self.recordHotkeyStarted = recordHotkeyStarted
        self.recordHotkeyFinished = recordHotkeyFinished
        self.tryHotkey = tryHotkey
        self.sendTestNotification = sendTestNotification
        self.openHookDiff = openHookDiff
        self.reinstallHooks = reinstallHooks
        self.uninstallHooks = uninstallHooks
        self.removeLegacy = removeLegacy
        self.addAccount = addAccount
        self.showDataRoot = showDataRoot
        self.resetAll = resetAll
        self.copyDiagnostics = copyDiagnostics
        self.openRemoteBoard = openRemoteBoard
        self.setAlias = setAlias
        self.restoreBackup = restoreBackup
        self.compareBackup = compareBackup
        self.revealPath = revealPath
        self.setDefaultProfile = setDefaultProfile
        self.resetSection = resetSection
        self.rereadAccounts = rereadAccounts
        self.openNotesFolder = openNotesFolder
        self.rotateMCPToken = rotateMCPToken
        self.mcpRegistration = mcpRegistration
        self.rebuildNotesIndex = rebuildNotesIndex
        self.openCleanup = openCleanup
        self.openOnboarding = openOnboarding
        self.openThirdPartyNotices = openThirdPartyNotices
        self.copyText = copyText
        self.openInstallTerminal = openInstallTerminal
        self.confirmAutoSwitch = confirmAutoSwitch
    }
}
