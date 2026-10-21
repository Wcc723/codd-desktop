import AppKit
import CoddClaudeSettings
import CoddCore
import CoddPreferences
import CoddSettingsUI
import CoddUI

/// Settings (M3 I3): the `SettingsModel` CoddSettingsUI draws, bound to `PreferencesService` (every
/// edit goes through `update`, saved 300 ms later, D14), the facts it shows (`SettingsInfo`, rebuilt
/// while the window is open) and what its buttons do (`SettingsActions`).
///
/// The facts are read only while the window shows: an observation loop over the stores plus a 5 s
/// tick for the ages (`12s 前`); `claude --version` runs once per opening (D28).
@MainActor
final class SettingsCoordinator {
    /// What the coordinator reads and the app-level actions it calls. Everything but the
    /// preferences is optional (tests and mock mode leave parts out).
    struct Environment {
        var preferences: PreferencesService
        var store: (any SessionStore)?
        var holders: HolderSessionStore?
        var accounts: (any AccountStore)?
        var cswap: CswapAccountStore?
        var installer: ClaudeSettingsService?
        var profiles: LaunchProfiles?
        var claudeSettings: @MainActor () -> ClaudeUserSettingsSummary = { ClaudeUserSettingsSummary() }
        var loginItems: LoginItemController?
        var hotkey: HotkeyService?
        var versions: VersionProbe?
        /// D13: `! cswap menubar 也在執行，兩邊可能同時切換`.
        var autoSwitchWarning: @MainActor () -> String? = { nil }
        /// Settings › 帳號 is showing (the cswap background-tool scan runs meanwhile, D13).
        var accountsShown: @MainActor (Bool) -> Void = { _ in }
        /// The last status-line report the endpoint took (the Statusline row's chip).
        var lastStatusLineAt: @MainActor () -> Date? = { nil }
        /// The hook endpoint is this app's (14 / 14 injected).
        var hooksInjected: @MainActor () -> Bool = { true }
        var statusDir = ""
        var statusDirDiffers = false
        var dataRoot: URL?
        /// Mock mode: the SPEC §5 sample facts.
        var mock = false
        // App actions.
        var addAccount: @MainActor () -> Void = {}
        /// Dialog B for an installer action over a window, read-only for a backup's `差異`.
        var presentHookDiff: @MainActor (InstallerAction, NSWindow?, Bool) -> Void = { _, _, _ in }
        var sendTestNotification: @MainActor () -> Void = {}
        var openPath: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
        var log: @MainActor (String) -> Void = { _ in }
        // M4 I2a: 筆記本 & MCP, 清理's account select and ADVANCED › 重建筆記索引.
        var notebook: @MainActor () -> SettingsNotebookInfo = { .unavailable }
        var condenseAccounts: @MainActor () -> [SettingsCondenseAccount] = { [] }
        /// Re-reads Claude Code's registration (off the main actor) for the 註冊 box.
        var refreshRegistrations: @MainActor () async -> Void = {}
        var openNotesFolder: @MainActor () -> Void = {}
        var rebuildNotesIndex: @MainActor () -> Void = {}
        // M4 I2b: 註冊 rows (D22) and `[輪替]` (D23), each over the Settings window.
        var mcpRegistration: @MainActor (String, NSWindow?) -> Void = { _, _ in }
        var rotateMCPToken: @MainActor (NSWindow?) -> Void = { _ in }
        // M4 I4a: 清理's head button `查看清理建議 · n →` (D31) and its count.
        var openCleanup: (@MainActor () -> Void)?
        var cleanupCount: @MainActor () -> Int? = { nil }
        /// M5 D5: 關於 › 首次啟動設定 `[重新執行]` (the onboarding window from step 1).
        var openOnboarding: @MainActor () -> Void = {}
        /// 關於 › 第三方元件授權 `[開啟]` (the bundled THIRD-PARTY-NOTICES.md).
        var openThirdPartyNotices: @MainActor () -> Void = {}
        /// FB: 帳號's cswap guide `複製` / `在終端機執行` (the app's pasteboard and holder store).
        var cswapGuide = CswapGuideHandlers()
    }

    let env: Environment
    let model: SettingsModel
    /// The settings window (folder panel, confirmations, dialog B).
    weak var window: NSWindow?
    /// Selects a section of the hosted page (`看規劃 → Remote 畫板`).
    var selectSection: (SettingsSection) -> Void = { _ in }
    private(set) var isVisible = false
    private var preferencesLoop: ObservationLoop?
    private var factsLoop: ObservationLoop?
    private var tick: Task<Void, Never>?
    private var backups: [SettingsBackupRow] = []
    /// The last alias refusal or cswap failure, shown in place of the facts' line (redacted, D31).
    private(set) var aliasProblem: String?
    /// How many facts rebuilds ran (tests).
    private(set) var infoBuilds = 0

    /// The service's value the page last showed: an edit writes only the sections that differ
    /// from it.
    private var shown: CoddPreferences

    init(environment: Environment) {
        env = environment
        let preferences = environment.preferences
        shown = preferences.preferences
        model = SettingsModel(preferences: preferences.preferences, info: SettingsInfo())
        model.onChange = { [weak self] next in self?.commit(next) }
        preferencesLoop = ObservationLoop(track: { preferences.preferences }, apply: { [weak self] value in
            guard let self else { return }
            self.shown = value
            if self.model.preferences != value { self.model.preferences = value }
        })
        model.info = makeInfo(now: Date())
    }

    /// An edit on the page (saved 300 ms later by the service, D14). Only the sections the edit
    /// changed are written, so a change made elsewhere since the page last synced (the menu bar's
    /// `暫停通知 1 小時`, a second window) is never overwritten by the page's older copy.
    func commit(_ next: CoddPreferences) {
        let base = shown
        shown = next
        env.preferences.update { prefs in
            func take<T: Equatable>(_ path: WritableKeyPath<CoddPreferences, T>) {
                if next[keyPath: path] != base[keyPath: path] { prefs[keyPath: path] = next[keyPath: path] }
            }
            take(\.general)
            take(\.appearance)
            take(\.sessions)
            take(\.accounts)
            take(\.notebook)
            take(\.cleanup)
            take(\.shortcuts)
            take(\.advanced)
            take(\.about)
            // The pause belongs to the menu bar: the page never edits it (its resets keep it).
            take(\.notifications.waiting)
            take(\.notifications.error)
            take(\.notifications.done)
            take(\.notifications.exitedNonZero)
            take(\.notifications.quietHours)
            take(\.notifications.mutedGroupIDs)
            take(\.notifications.dockBadge)
            take(\.notifications.menuBarIcon)
            take(\.notifications.pausedUntil)
        }
    }

    // MARK: Visibility

    /// The window came on screen (facts follow the stores, the versions are probed) or went away.
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        env.accountsShown(visible)
        guard visible else {
            factsLoop?.cancel()
            factsLoop = nil
            tick?.cancel()
            tick = nil
            return
        }
        // Tracks the discrete facts only (`tracked`: no capture times, no last-report age); the
        // full facts are built outside tracking. Status-line reports arrive about once a second
        // and every one used to rebuild the facts and re-apply every section (M3 review).
        factsLoop = ObservationLoop(track: { [weak self] () -> SettingsInfo? in self?.makeInfo(now: Date(), tracked: true) },
                                    apply: { [weak self] _ in self?.refreshInfo() })
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.refreshInfo()
            }
        }
        Task { [weak self] in await self?.refreshSlowFacts() }
    }

    /// Rebuilds the facts now.
    func refreshInfo() {
        let info = makeInfo(now: Date())
        if info != model.info { model.info = info }
    }

    /// Facts that need I/O off the main actor: the settings inspection, the backups, `claude --version`.
    func refreshSlowFacts() async {
        await env.installer?.refreshInspection()
        if let installer = env.installer {
            backups = await installer.backups().map { SettingsInfoBuilder.backupRow($0.backup, reason: $0.reason) }
        }
        refreshInfo()
        await env.refreshRegistrations()
        refreshInfo()
        await env.versions?.refreshClaude()
        refreshInfo()
    }

    // MARK: Facts

    /// `tracked`: the observation pass, which leaves out the values that move with every
    /// status-line report (they show at the 5 s tick).
    func makeInfo(now: Date, tracked: Bool = false) -> SettingsInfo {
        infoBuilds += 1
        let preferences = env.preferences
        if env.mock {
            var info = SettingsSamples.info(now: now)
            // The artboard's look: mock mode never registers anything, so no status line under the rows.
            info.savedAt = preferences.savedAt ?? info.savedAt
            info.hotkeyError = env.hotkey?.error
            info.groups = env.store.map(SettingsInfoBuilder.groups) ?? info.groups
            if let profiles = env.profiles {
                info.profileNames = SettingsInfoBuilder.profileNames(profiles.document)
                info.defaultProfileID = profiles.document.defaultProfileId
            }
            return info
        }
        var facts = SettingsFacts(now: now)
        let root = env.dataRoot.map { HolderSessionStore.abbreviate($0.path) } ?? "（記憶體）"
        facts.dataRootPath = root
        facts.preferencesPath = env.dataRoot.map { HolderSessionStore.abbreviate($0.appendingPathComponent(PreferencesStore.fileName).path) }
            ?? "（記憶體，不會儲存）"
        facts.savedAt = preferences.savedAt
        facts.saveProblem = preferences.saveProblem ?? (preferences.isReadOnly ? "preferences.json 是較新版本的 CODD 寫的，變更不會儲存" : nil)
        facts.loginItemStatus = env.loginItems?.statusText
        facts.hotkeyError = env.hotkey?.statusText
        if let profiles = env.profiles { facts.profiles = profiles.document }
        if let cswap = env.cswap {
            let version = cswap.cswapVersion
            // The placeholder names the cswap actually found (login PATH, ~/.local/bin, DEBUG path).
            // `locating`: the first look for cswap has not answered yet (the executable stays nil
            // until it does): no `▲ 找不到`, no install guide for a cswap that may well be there.
            facts.cswap = SettingsCswapInfo(pathOK: cswap.executablePath != nil, version: version?.description,
                                            versionOK: version?.isSupported ?? false, warning: aliasProblem ?? env.autoSwitchWarning(),
                                            defaultPath: cswap.executablePath.map(HolderSessionStore.abbreviate) ?? "~/.local/bin/cswap",
                                            locating: cswap.baseAvailability == .loading && cswap.executablePath == nil)
            facts.accountsReady = cswap.baseAvailability.isReady
            facts.coreAccounts = cswap.coreAccounts(now: now)
            if case .unreadable(let reason) = cswap.baseAvailability { facts.accountsUnavailable = reason }
        }
        if let installer = env.installer { facts.inspection = installer.inspection }
        facts.backups = backups
        facts.statusDir = env.statusDir
        facts.statusDirDiffers = env.statusDirDiffers
        facts.injected = env.hooksInjected()
        facts.includesAges = !tracked
        if !tracked { facts.lastStatusLineAt = env.lastStatusLineAt() }
        facts.cleanupPeriodDays = env.claudeSettings().cleanupPeriodDays
        facts.versions = VersionProbe.rows(claude: env.versions?.claudeVersion, cswap: env.cswap?.cswapVersion?.description)
        facts.externalCount = env.holders?.detectedExternalCount
        facts.notebook = env.notebook()
        facts.condenseAccounts = env.condenseAccounts()
        facts.cleanupCount = env.cleanupCount()
        facts.canOpenCleanup = env.openCleanup != nil
        return SettingsInfoBuilder.info(store: env.store, accounts: env.accounts, facts: facts)
    }

    // MARK: Actions

    func makeActions() -> SettingsActions {
        SettingsActions(
            chooseProjectRoot: { [weak self] in self?.chooseProjectRoot() },
            recordHotkeyStarted: { [weak self] in self?.env.hotkey?.suspend() },
            recordHotkeyFinished: { [weak self] in
                guard let self else { return }
                self.env.hotkey?.resume(self.env.preferences.preferences.general)
            },
            tryHotkey: { [weak self] combo in self?.env.hotkey?.tryCombo(combo) },
            sendTestNotification: { [weak self] in self?.env.sendTestNotification() },
            openHookDiff: { [weak self] in self?.hookDiff(.update) },
            reinstallHooks: { [weak self] in self?.hookDiff(.update) },
            uninstallHooks: { [weak self] in self?.hookDiff(.uninstall) },
            removeLegacy: { [weak self] in self?.hookDiff(.removeLegacy) },
            addAccount: { [weak self] in self?.env.addAccount() },
            showDataRoot: { [weak self] in
                guard let self, let root = self.env.dataRoot else { NSSound.beep(); return }
                self.env.openPath(root)
            },
            resetAll: { [weak self] in self?.confirmResetAll() },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
            openRemoteBoard: { [weak self] in self?.selectSection(.remote) },
            setAlias: { [weak self] id, alias in self?.setAlias(id, alias) },
            restoreBackup: { [weak self] name in self?.backupDialog(name, readOnly: false) },
            compareBackup: { [weak self] name in self?.backupDialog(name, readOnly: true) },
            revealPath: { [weak self] path in self?.env.openPath(URL(fileURLWithPath: PathFormat.expandTilde(path))) },
            setDefaultProfile: { [weak self] id in self?.env.profiles?.setDefault(id) },
            resetSection: { [weak self] section in self?.env.log("settings reset section=\(section.rawValue)") },
            rereadAccounts: { [weak self] in
                guard let cswap = self?.env.cswap else { return }
                Task { await cswap.refresh(userInitiated: true) }
            },
            openNotesFolder: { [weak self] in self?.env.openNotesFolder() },
            rotateMCPToken: { [weak self] in self?.env.rotateMCPToken(self?.window) },
            mcpRegistration: { [weak self] id in self?.env.mcpRegistration(id, self?.window) },
            rebuildNotesIndex: { [weak self] in self?.env.rebuildNotesIndex() },
            openCleanup: { [weak self] in self?.env.openCleanup?() },
            openOnboarding: { [weak self] in self?.env.openOnboarding() },
            openThirdPartyNotices: { [weak self] in self?.env.openThirdPartyNotices() },
            copyText: { [weak self] text in self?.env.cswapGuide.copy(text) },
            openInstallTerminal: { [weak self] command in self?.env.cswapGuide.openTerminal(command) },
            // FB: turning auto-switch ON asks first, over the Settings window.
            confirmAutoSwitch: { [weak self] window, done in SettingsAutoSwitchRisk.ask(on: window ?? self?.window, done: done) })
    }

    /// GENERAL › 預設專案根目錄 `選擇…`: a folder panel starting at the current root.
    func chooseProjectRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"
        panel.message = "新增專案、選擇資料夾時從這裡開始"
        panel.directoryURL = URL(fileURLWithPath: PathFormat.expandTilde(env.preferences.preferences.general.projectRoot), isDirectory: true)
        let apply: (URL) -> Void = { [weak self] url in
            let path = PathFormat.abbreviateHome(url.path)
            self?.model.update { $0.general.projectRoot = path }
        }
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            apply(url)
        }
    }

    private func hookDiff(_ action: InstallerAction) {
        env.presentHookDiff(action, window, false)
    }

    /// A backup row's `還原` (dialog B in restore mode, written on `還原`) or `差異` (read-only).
    private func backupDialog(_ name: String, readOnly: Bool) {
        guard let url = env.installer?.backupURL(named: name) else { NSSound.beep(); return }
        env.presentHookDiff(.restore(url), window, readOnly)
    }

    /// D34: cswap's own rule first (an invalid alias never reaches cswap and the hint shows), then
    /// `cswap alias N <name>` / `--unset`, then a fresh read. Failures show redacted (D31).
    func setAlias(_ id: String, _ alias: String?) {
        guard let cswap = env.cswap, let number = Int(id) else { return }
        var normalized: String?
        if let alias {
            guard let valid = CswapAlias.normalize(alias) else {
                aliasProblem = CswapAlias.hint
                refreshInfo()
                return
            }
            normalized = valid
        }
        aliasProblem = nil
        Task { [weak self] in
            let failure = await cswap.setAlias(normalized, account: number)
            guard let self else { return }
            self.aliasProblem = failure.map { "cswap alias 失敗：\($0)" }
            self.refreshInfo()
        }
    }

    /// ADVANCED `重設所有設定`: a confirmation, then every preference back to its default (saved);
    /// launch profiles, the layout and Claude's settings stay as they are.
    func confirmResetAll() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "重設所有設定？"
        alert.informativeText = "所有設定回到預設值並立即儲存。啟動設定檔、session 版面與 Claude 的 settings.json 不受影響。"
        alert.addButton(withTitle: "重設")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.resetAll()
        }
    }

    func resetAll() {
        // The menu bar pause is not a setting; it survives like in NOTIFICATIONS' reset.
        let paused = env.preferences.preferences.notifications.pausedUntil
        env.preferences.update { prefs in
            prefs = CoddPreferences.defaults
            prefs.notifications.pausedUntil = paused
        }
        env.log("settings reset all")
    }

    /// ABOUT `複製版本資訊`.
    func copyDiagnostics() {
        let rows = model.info.versions.map { (key: $0.key, value: $0.value) }
        let text = VersionProbe.diagnostics(rows, dataRoot: model.info.dataRootPath)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
