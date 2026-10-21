import AppKit
import CoddClaudeSettings
import CoddCore
import CoddDialogsUI
import CoddHooks
import CoddOnboarding
import CoddPreferences
import CoddSettingsUI
import CoddStatusUI
import CoddTerminal
import CoddUI

/// App entry: builds the stores, the main window, the menu bar item and the Dock badge, and
/// implements the main-menu commands. The pane talks to terminals through `TerminalSurface` and
/// the stores are protocols.
///
/// Real mode is the default (`HolderSessionStore`: codd-holder processes running claude or a
/// shell, streamed into libghostty terminals by `TerminalHub`, states from the app-hosted hook
/// endpoint). `-codd-mock` (and the DEBUG mock tools) use `MockSessionStore` with the SPEC §5
/// data instead; see `RealModeOptions`.
///
/// One CODD per data root (D9): real mode takes `<dataRoot>/codd.lock` in
/// `applicationWillFinishLaunching`, before anything reads or writes the data root (`init` and the
/// store, hub and services initializers touch nothing on disk). A second instance asks the first
/// to show its window and exits. Closing the main window keeps CODD running (menu bar item, Dock
/// icon, hook endpoint, holders); the terminals stop rendering until it is shown again (D10).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, CoddCommands, NSMenuItemValidation {
    let realOptions: RealModeOptions
    let sessionStore: any SessionStore
    /// The same object as `sessionStore` in real mode, else nil.
    let holderStore: HolderSessionStore?
    /// Real mode's terminals, else nil (mock mode draws transcripts).
    let terminalHub: TerminalHub?
    /// Real mode's extras for the home / status pages and the new-session sheet.
    let services: AppServices?
    /// Real mode: cswap's accounts and the quota book (M3 I1b); mock mode: the SPEC §5 samples.
    let accountStore: any AccountStore
    /// The same object as `accountStore` in real mode, else nil.
    let cswapAccounts: CswapAccountStore?
    /// D5: the data root's launch profiles in real mode, an in-memory set in mock mode.
    let profiles: LaunchProfiles
    /// M3 D14: `<dataRoot>/preferences.json` in real mode (read in `startRealMode`), in memory in
    /// mock mode.
    let preferences: PreferencesService
    let shell: ShellState
    /// D10: the Claude user settings installer (real mode; the store's settings path).
    let claudeSettings: ClaudeSettingsService?
    /// D29: every notification decision of the run (the dump's `notifications`).
    let notificationLog = NotificationLog()
    /// D13: CODD's auto-switch (real mode, after the accounts' first read).
    private(set) var autoSwitch: AutoSwitchRunner?
    private(set) var appNotifier: AppNotifier?
    /// D36: the footer host line (real mode).
    var hostLine: HostLineService?
    /// The STATUS area (D16): its sidebar and page.
    private(set) var statusController: StatusController?
    /// D5 dialog A for user switches while 切換前確認 is ON.
    private(set) var switchDialogs: SwitchDialogController?
    /// D24 dialog C while it is open.
    private(set) var addAccountFlow: AddAccountFlow?
    /// D10 dialog B while it is open.
    private(set) var hookDialog: HookDiffDialog?
    private var paneLayouts: PaneLayoutStore?
    // MARK: Notebook (M4 I1a)

    /// D38: the one trash every automatic M4 move (and 刪除對話紀錄) goes through.
    let appTrash: AppTrash
    /// The notebook (`<dataRoot>/notes`; mock mode: a temporary folder, D35).
    let notes: NotesService
    /// The note editor binding (the NOTES area hosts its view; it outlives area switches).
    let noteEditor: NoteEditorController
    /// D39: every pasteboard write.
    let pasteboard = CoddPasteboard()
    /// The NOTES area (D12), built with the main window.
    private(set) var notesArea: NotesAreaViewController?
    /// Mock mode's temporary notebook folder (removed at quit).
    let mockNotesFolder: URL?
    /// Mock mode's made-up external MCP token (COPY REF form 5 copies a working-looking URL; D35).
    let mockMCPToken = MCPAuth.makeToken()
    /// M4 I2a: CODD's MCP server on the hook port (real mode only; mock mode never serves it, D35).
    let mcpService: MCPService?
    /// M4 I2b: Claude Code / Codex registrations and the token rotation (real mode only).
    let mcpRegistration: MCPRegistrationService?
    /// M4 I2b (D14): notes to sessions (footer, SEND TO SESSION, ⌘⏎, the drawer).
    let noteSending: NoteSending
    /// M4 I2b: the session pane's `✎ NOTES` drawer.
    let notesDrawer: NotesDrawerController
    /// Dialog B for a registration while it is open.
    var registrationDialog: MCPRegistrationDialog?
    /// The `註冊到 Codex` sheet while it is open.
    var codexSheet: (window: NSWindow, view: SnippetDialogView)?
    /// M4 I3: the local file editor (Files mode workspaces, tabs, read-only git, AI touches).
    let files: FileEditorService
    /// M4 I3: the NOTES area's Files mode (built with the area).
    var filesMode: FilesModeController?
    /// D24 quit: the `n 個檔案有未儲存的變更` sheet while it asks.
    var filesQuitSheet: NSWindow?
    /// D24 quit: the buffers `不儲存` let go (tab id → buffer), for this quit request only.
    var filesQuitApproved: [String: String]?
    /// M4 I4a: the retention engine and the Cleanup page's candidates (real mode only, D29–D31).
    let retention: RetentionService?
    /// M4 I4a: `交給 Claude 濃縮` (D32, real mode only).
    let condense: CondenseRunner?
    /// M4 I4a: the NOTES area's Cleanup mode (built with the area).
    var cleanupMode: CleanupController?
    var notesLoops: [ObservationLoop] = []
    private(set) var mainWindow: MainWindowController?
    private(set) var statusItem: StatusItemController?
    var attention: AttentionMonitor?
    var notifier: SessionNotifier?
    private(set) var palette: CommandPaletteController?
    var settings: SettingsWindowController?
    private(set) var newSessionSheet: NewSessionSheet?
    var isTerminating = false

    // MARK: Lifecycle (M3 I3)

    /// D21: the login item toggle (the real `SMAppService` on the standard data root only).
    let loginItems: LoginItemController
    /// D22: the global hotkey (registers only on the standard data root, or with DEBUG flags).
    let hotkey: HotkeyService
    /// D28: `claude --version` for Settings › 關於.
    let versionProbe: VersionProbe
    /// D18: dialog D.
    let quitDialog = QuitDialogController()
    /// The next `applicationShouldTerminate` comes from here (nil: ⌘Q, the Dock, the system).
    var pendingQuitTrigger: QuitTrigger?
    /// The last request and what was done with it (the dump's `quitDialog`).
    var lastQuit: (trigger: QuitTrigger, decision: QuitDecision)?
    /// `全部停止並結束` is waiting for the EXITs.
    var isStoppingAll = false
    /// The terminal size Settings asked for last (A− / A+ and ⌘+ / ⌘− go through Settings too).
    var appliedTerminalFontSize: Double?
    /// ⌘+ / ⌘− / ⌘0 steps taken this run (the dump's `zoom.steps`).
    var zoomSteps = 0
    /// The activation policy applied (D20).
    var appliedPolicy: NSApplication.ActivationPolicy?
    /// The NO HOOK grace handed to the hook engine last (new sessions use it).
    var appliedNoHookGrace: TimeInterval?
    // MARK: Identity and data (M5 I1)

    /// D25: this run restores and saves the main window frame, the split view and the status
    /// item position (real mode on the standard data root only; tests and agents never do).
    let autosavesLayout: Bool
    /// D2: what this launch did about the legacy defaults domain (the dump's `bundle`).
    private(set) var legacyDefaults: DefaultsIsolation.Outcome = .notApplicable
    /// D14: the launch's data preflight and the post-load aside sweep (real mode).
    let dataFiles = DataFilesMonitor()
    /// D16: `perf launch-to-sidebar` was logged.
    var launchToSidebarLogged = false
    /// When the delegate was made (the aside sweep's fallback when the kernel's start is unknown).
    let launchDate = Date()
    // MARK: Onboarding (M5 I2)

    /// D5: whether the wizard opens at launch (decided right after the instance lock).
    var onboardingLaunch = OnboardingLaunch.none
    /// The open wizard (nil when none is open).
    var onboarding: OnboardingPresenter?
    /// The last wizard of this run, kept for the dump after it ended.
    var lastOnboarding: OnboardingController?
    /// While the wizard shows: the accounts into step 5 (D13).
    var onboardingLoops: [ObservationLoop] = []
    /// The installer's last write when dialog B opened from step 3 (a newer one is `已套用`).
    var onboardingHooksBaseline: Date?
    #if DEBUG
    /// `-codd-onboarding-actions` ran (once, for the wizard the launch opened).
    var onboardingActionsRan = false
    #endif

    /// Held for the app's life in real mode (released by the kernel when the process ends).
    private(set) var instanceLock: InstanceLock?
    private var showWindowObservers: [NSObjectProtocol] = []
    /// Applies preference changes to their consumers (stale threshold) while CODD runs.
    private var preferencesLoop: ObservationLoop?
    /// Real mode: the active account into the session store, the pinned profiles' registries
    /// into the watcher (D12).
    private var accountLoops: [ObservationLoop] = []
    #if DEBUG
    private var stateDumpTask: Task<Void, Never>?
    private var lastStateDumpAt: ContinuousClock.Instant?
    private var autoAnswered = false
    /// How often the menu's 允許 ⌘⏎ ran (the shortcut matrix proves the palette keeps ⌘⏎ from it).
    private(set) var allowInvocations = 0
    /// How often ⌘E / ⌘F acted (the matrix proves they never act outside NOTES).
    var notesCommandRuns = 0
    /// The launch's sessions are in: real mode's holders started, the DEBUG launch sessions
    /// (`-codd-new-claude`, …) created and the first session shown; mock mode at once. The notes
    /// DEBUG flags wait for it, or they race the store (a file opened before its project exists
    /// gets its own folder as root; the session shown afterwards takes the area away again).
    var launchSessionsReady = false
    /// `-codd-dump-state`: tab labels, lamps, bells and the panes rewrite the dump (`pane`).
    private var paneDumpLoop: ObservationLoop?
    /// The dump's `mcp` / `promptExpansion` follow the MCP server (clients, tools, expansions).
    private var mcpDumpLoop: ObservationLoop?
    /// The ⌘N sheet's dump entries when ⌘Q (or `-codd-quit-after`) closed it.
    private var sheetDumpAtQuit: (sheet: [String: Any], picker: [[String: Any]])?
    #endif

    override init() {
        let options = RealModeOptions.current
        realOptions = options
        // D17 (DEBUG `-codd-force-render`; Release never sets it): before any engine exists.
        TerminalEngine.rendersWhileWindowOccludedByDefault = options.forceRender
        let shellState = ShellState()
        shell = shellState
        if options.enabled {
            let store = HolderSessionStore.make(options: options)
            holderStore = store
            sessionStore = store
            let hub = TerminalHub(store: store, shell: shellState)
            hub.forceRender = options.forceRender
            terminalHub = hub
            let appServices = AppServices(store: store)
            services = appServices
            profiles = store.profiles
            // The M1 / M2 UserDefaults switch is migrated on the standard data root only, so a test
            // or throwaway root never depends on the user's own settings (like D3's isolation).
            preferences = PreferencesService(url: store.root.url.appendingPathComponent(PreferencesStore.fileName),
                                             legacyDefaults: store.root == .standard ? .standard : nil,
                                             assignments: options.setPrefs, log: { HolderSessionStore.printLog($0) })
            // D3: only the standard data root finds cswap and its state by itself; DEBUG flags name
            // a fake one (a Release build never has them). Touches nothing on disk until start().
            let accounts = CswapAccountStore(configuration: .init(
                isStandardRoot: store.root == .standard, debugCswapPath: options.cswapPath, debugCswapRoot: options.cswapRoot,
                claudeDirectory: URL(fileURLWithPath: store.claudeDirectory.path, isDirectory: true),
                claudeSettingsURL: store.claudeSettingsURL,
                quotaURL: store.root.url.appendingPathComponent(QuotaStore.fileName)))
            cswapAccounts = accounts
            accountStore = accounts
            appServices.accounts = accounts
            claudeSettings = ClaudeSettingsService(settingsURL: store.claudeSettingsURL, dataRoot: store.root.url)
            let standard = store.root == .standard
            // D21: a login item is lasting system state; any other data root never registers one.
            loginItems = LoginItemController(service: Self.loginItemService(standardRoot: standard),
                                             preferences: preferences, log: { HolderSessionStore.printLog($0) })
            hotkey = HotkeyService(isAllowed: HotkeyService.isAllowed(standardRoot: standard, debugFlag: options.globalHotkey),
                                   override: options.hotkeyCombo.flatMap(KeyCombo.init(string:)), log: { HolderSessionStore.printLog($0) })
            // D28 / D3: the DEBUG claude on any root; the user's claude on the standard root only.
            versionProbe = VersionProbe(claudeExecutable: Self.claudeExecutable(override: options.claudePath, standardRoot: standard),
                                        log: { HolderSessionStore.printLog($0) })
            // D38: the macOS Trash on the standard root only; `-codd-trash-dir` or `<dataRoot>/trash/` elsewhere.
            appTrash = AppTrash(target: AppTrash.target(dataRoot: store.root, trashDir: options.trashDir),
                                log: { HolderSessionStore.printLog($0) })
            store.trash = appTrash.function
            let locations = NotesService.locations(dataRoot: store.root)
            mockNotesFolder = nil
            notes = NotesService(notesRoot: locations.notes, cacheFolder: locations.cache, legacyIndexURL: locations.legacyIndex,
                                 preferences: preferences, trash: appTrash, clock: Self.notesClock(start: options.now))
        } else {
            holderStore = nil
            sessionStore = MockSessionStore()
            terminalHub = nil
            services = nil
            profiles = LaunchProfiles.inMemory()
            preferences = .inMemory(assignments: options.setPrefs)
            cswapAccounts = nil
            accountStore = MockAccountStore()
            claudeSettings = nil
            loginItems = LoginItemController(service: DisabledLoginItemService(reason: "mock 模式不會註冊登入項目"), preferences: preferences)
            hotkey = HotkeyService(isAllowed: options.globalHotkey ?? false, override: options.hotkeyCombo.flatMap(KeyCombo.init(string:)))
            versionProbe = VersionProbe(claudeExecutable: nil)
            // D35: a temporary notebook seeded with the SPEC §5 notes, on the mock clock (10/15 10:42).
            let folder = MockNotes.folder()
            mockNotesFolder = folder
            appTrash = AppTrash(target: .folder(folder.appendingPathComponent("trash").path), log: { HolderSessionStore.printLog($0) })
            let displayClock = sessionStore.clock
            notes = NotesService(notesRoot: folder.appendingPathComponent("notes", isDirectory: true),
                                 cacheFolder: folder.appendingPathComponent("cache", isDirectory: true), preferences: preferences,
                                 trash: appTrash, clock: { displayClock.now() }, timeZone: MockNotes.timeZone)
        }
        noteEditor = NoteEditorController(service: notes, preferences: preferences)
        let notesService = notes
        let mcp = holderStore.map { MCPService(holders: $0, notes: notesService) }
        mcpService = mcp
        holderStore?.mcp = mcp
        // D22 / D37: `~/.claude.json` on the standard data root only; elsewhere DEBUG -codd-claude-json (guarded).
        let registration = holderStore.map { holders in
            MCPRegistrationService(target: .resolve(standardRoot: holders.root == .standard, claudeDirectory: holders.claudeDirectory,
                                                    debugFile: options.claudeJSON),
                                   backupsIndex: holders.root.url.appendingPathComponent(ClaudeSettingsService.backupsIndexName),
                                   holders: holders, mcp: mcp)
        }
        registration?.applyDelayMilliseconds = options.mcpRegisterApplyDelayMilliseconds ?? 0
        mcp?.registrationFile = registration?.target.file
        mcpRegistration = registration
        noteSending = NoteSending(notes: notesService, store: sessionStore, shell: shellState)
        notesDrawer = NotesDrawerController(notes: notesService, store: sessionStore, preferences: preferences)
        files = Self.makeFileEditor(holders: holderStore, mockFolder: mockNotesFolder, store: sessionStore, notes: notesService)
        if let holders = holderStore {
            retention = RetentionService(holders: holders, notes: notesService, preferences: preferences, trash: appTrash,
                                         state: CleanupStateStore(dataRoot: holders.root.url, log: { HolderSessionStore.printLog($0) }),
                                         recentFiles: files.recentStore, clock: notesService.clock, timeZone: notesService.timeZone)
            condense = CondenseRunner(notes: notesService, holders: holders, mcp: mcp, clock: notesService.clock,
                                      timeZone: notesService.timeZone)
        } else {
            retention = nil
            condense = nil
        }
        autosavesLayout = DefaultsIsolation.autosavesLayout(realMode: options.enabled, root: holderStore?.root)
        super.init()
    }

    /// The notes clock: `Date`, or DEBUG `-codd-now` (a running clock that starts at that instant).
    nonisolated static func notesClock(start: Date?) -> @Sendable () -> Date {
        guard let start else { return { Date() } }
        let launched = Date()
        return { start.addingTimeInterval(Date().timeIntervalSince(launched)) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        if let holders = holderStore {
            takeInstanceLock(root: holders.root)
            // D2: one CODD per root holds the lock now; before any window or the status item reads
            // the domain. The standard data root only: any other root never reads the user's domains.
            legacyDefaults = DefaultsIsolation.migrateLegacyDefaults(applies: holders.root == .standard,
                                                                     into: CoddIdentity.runningBundleIdentifier,
                                                                     log: { HolderSessionStore.printLog($0) })
        }
        // D5: before anything writes the data root (its files still say whether CODD ran here).
        decideOnboarding()
        Typeface.registerBundledFontsIfNeeded()
        NSApp.mainMenu = MainMenuBuilder.build(commands: self)
    }

    // MARK: Single instance (D9, D28)

    /// Locks the data root or hands over to the CODD that has it (and exits). Runs before the
    /// window, the store, the hook config, the binary install or any holder connection.
    private func takeInstanceLock(root: CoddDataRoot) {
        switch InstanceLock.acquire(dataRoot: root.path) {
        case .acquired(let lock):
            instanceLock = lock
            showWindowObservers = ShowMainWindowRequest.observe(dataRoot: root.path) { [weak self] in
                HolderSessionStore.printLog("show-window requested")
                // D5: the wizard comes forward instead while it is open.
                self?.showPrimaryWindow(reason: "show-window")
            }
        case .heldByAnother(let owner):
            Self.handOver(to: owner, root: root.path)
        case .failed(let reason):
            // Without the lock two instances could fight over the holders; never run unlocked.
            HolderSessionStore.printLog("error instance lock: \(reason)")
            Self.exitWithAlert(message: "無法鎖定資料夾", detail: "\(HolderSessionStore.abbreviate(root.path))：\(reason)")
        }
    }

    /// Another CODD runs on this data root: bring it forward and leave without a window.
    private static func handOver(to owner: InstanceLockOwner?, root: String) {
        let pid = owner?.pid
        if let pid, let other = NSRunningApplication(processIdentifier: pid) {
            ShowMainWindowRequest.post(dataRoot: root)
            if !AppActivation.isBackground { other.activate(from: NSRunningApplication.current, options: []) }
            HolderSessionStore.printLog("another-instance pid=\(pid) root=\(root)")
            exit(0)
        }
        HolderSessionStore.printLog("another-instance pid=\(pid.map { String($0) } ?? "?") root=\(root) (not found)")
        let where_ = HolderSessionStore.abbreviate(root) + (pid.map { "（pid \($0)）" } ?? "")
        exitWithAlert(message: "另一個 CODD 正在使用這個資料夾",
                      detail: "\(where_)。請切換到那個 CODD，或用 -codd-data-root 指定別的資料夾。")
    }

    private static func exitWithAlert(message: String, detail: String) -> Never {
        // A background run has nobody to read a modal alert, which would only hang it.
        guard !AppActivation.isBackground else {
            HolderSessionStore.printLog("exit alert: \(message) \(detail)")
            exit(0)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "結束")
        NSApp.activate()
        alert.runModal()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UITicker.shared.clock = sessionStore.clock
        #if DEBUG
        if let on = realOptions.fullKeyboardAccess {
            // M5 D21: the custom controls behave as with System Settings › 鍵盤導覽 on (or off).
            KeyboardFocus.fullKeyboardAccessOverride = on
            HolderSessionStore.printLog("debug full-keyboard-access \(on ? "on" : "off")")
        }
        if realOptions.forceRender {
            // D17: the 1 Hz labels keep ticking in a covered window too (measurements only).
            UITicker.forceVisible = true
            HolderSessionStore.printLog("debug force-render terminals=\(terminalHub != nil) timers=visible")
        }
        #endif
        // The Dock shows the bundle icon (App/AppIcon.icon, every appearance); nothing overrides it.
        // M4 interface zoom: the stored UI 字級 before the first view is built (mock mode's
        // preferences are in memory already; real mode peeks at the file, read in full later).
        let launchFontSize = holderStore == nil ? preferences.preferences.appearance.uiFontSize
            : Self.launchUIFontSize(file: preferences.store?.url, assignments: realOptions.setPrefs)
        if UIZoom.apply(fontSize: launchFontSize) {
            HolderSessionStore.printLog("zoom launch ui=\(UIZoom.fontSize)")
        }

        let store = sessionStore
        let factory: TerminalSurfaceFactory = terminalHub ?? FakeTerminalSurfaceFactory { target in
            Self.mockContent(store: store, target: target)
        }
        let status = makeStatusController()
        statusController = status
        let notesArea = makeNotesArea()
        self.notesArea = notesArea
        // DEBUG layout sweep: a run that sets the window or sidebar size never saves (or restores) them;
        // D25: neither does any run off the standard data root or in mock mode.
        let sweep = realOptions.windowSize != nil || realOptions.sidebarWidth != nil
        let window = MainWindowController(store: sessionStore, accounts: accountStore, shell: shell, surfaceFactory: factory,
                                          services: services, profiles: profiles, status: status, notes: notesArea,
                                          savesFrame: autosavesLayout && !sweep)
        if let size = RealModeOptions.layoutSize(realOptions.windowSize, minimum: MainWindowController.minimumSize) {
            window.window?.setContentSize(size)
        }
        window.onOpenSettings = { [weak self] section in self?.openSettings(section: section) }
        window.onQuickSwitch = { [weak self] in self?.showQuickSwitch(nil) }
        if holderStore != nil {
            window.onNewSession = { [weak self] form in self?.presentNewSession(form) }
            window.onAddProject = { [weak self] in self?.chooseProjectFolder() }
            // fb: a project row's `+` starts a claude session right away and shows it.
            window.sidebar.onStartSession = { [weak self] request in self?.launch(request) }
        }
        window.onVisibilityChange = { [weak self] visible in self?.mainWindowVisibilityChanged(visible) }
        // D19: with 關閉視窗時保留在選單列 OFF the close button runs the ⌘Q flow.
        window.shouldClose = { [weak self] in self?.mainWindowShouldClose() ?? true }
        #if DEBUG
        window.pane.onDumpNeeded = { [weak self] in self?.scheduleStateDump() }
        #endif
        window.pane.onTerminalFontStep = { [weak self] delta in self?.stepTerminalFont(delta) }
        mainWindow = window
        wireSending(window)
        wireFiles(window)
        // D6: while the wizard opens at launch, the main window is built but shown only when it ends.
        if !onboardingLaunch.show { window.showWindow(nil) }
        applySidebarLaunchOptions(window.sidebar)
        applyLayoutSweepOptions(window)

        statusItem = StatusItemController(store: sessionStore, accounts: accountStore, actions: panelActions(), shell: shell,
                                          preferences: preferences,
                                          autosaveName: autosavesLayout ? DefaultsIsolation.statusItemName : nil)
        statusItem?.onToast = { [weak self] text, undo in self?.mainWindow?.showToast(text, undo: undo) }
        statusItem?.onPanelVisibilityChange = { [weak self] visible in self?.hostLine?.setVisible(visible, for: "popover") }
        // D5: every user switch asks first while 設定 › 帳號 › 切換前確認 is ON.
        let dialogs = SwitchDialogController(preferences: preferences, window: { [weak self] in self?.mainWindow?.window })
        dialogs.pinnedTitles = { [weak self] in
            (self?.sessionStore.allSessions ?? []).filter { $0.accountPinned && $0.state.isLive && !$0.external }.map(\.title).sorted()
        }
        dialogs.beforePresenting = { [weak self] in
            self?.statusItem?.closePanel()
            self?.showMainWindow(nil)
        }
        switchDialogs = dialogs
        AccountSwitching.confirmation = dialogs
        let preferences = self.preferences
        // The badge, and the live Dock tile (post-M4: blink, then lit while a session needs the user).
        attention = AttentionMonitor(store: sessionStore, mode: { preferences.preferences.notifications.dockBadge },
                                     tile: .live(store: sessionStore, preferences: preferences))
        hotkey.action = { [weak self] in self?.globalHotkeyPressed() }
        // Mock mode's preferences are in memory (loaded already); real mode applies them after the read.
        if holderStore == nil {
            #if DEBUG
            launchSessionsReady = true
            #endif
            observePreferences()
            startNotes()
            // D16: mock mode's sidebar is loaded at once; the first turn after the window showed.
            DispatchQueue.main.async { [weak self] in self?.logLaunchToSidebar() }
        }
        NSApp.activate()

        // Build the ⌘K panel ahead of time (after the first frame) so it opens instantly.
        DispatchQueue.main.async { [weak self] in self?.preparePalette() }
        if let holders = holderStore, let hub = terminalHub { startRealMode(holders, hub: hub) }
        // D5 / D6: real mode starts as usual behind the wizard, so its probes read live state. The
        // hidden main window's terminals do not draw until it shows (its first showing un-occludes them).
        if onboardingLaunch.show {
            terminalHub?.setWindowOccluded(true)
            openOnboarding(start: onboardingLaunch.start, reason: onboardingLaunch.reason)
        }
        if let seconds = realOptions.quitAfterSeconds {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                #if DEBUG
                if let path = self?.realOptions.snapshotPath, let window = self?.mainWindow?.window {
                    // Child panels (hover card, new-group color popover) are drawn in place.
                    DebugHooks.write(window, to: URL(fileURLWithPath: path), includingChildren: true)
                    if self?.realOptions.windowSize != nil { DebugHooks.logLayout(window, name: "main") }
                    let stem = (path as NSString).deletingPathExtension
                    if let sheet = window.attachedSheet {
                        // The ⌘N sheet with its open project list drawn over it, and the list alone.
                        DebugHooks.write(sheet, to: URL(fileURLWithPath: stem + "-sheet.png"), includingChildren: true)
                        if let dropdown = self?.newSessionSheet?.dropdown, dropdown.isVisible {
                            DebugHooks.write(dropdown, to: URL(fileURLWithPath: stem + "-dropdown.png"))
                        }
                    }
                    if let panel = self?.addAccountFlow?.panel ?? self?.mockPanel, panel.isVisible {
                        DebugHooks.write(panel, to: URL(fileURLWithPath: stem + "-panel.png"))
                    }
                    if let settings = self?.settings?.window, settings.isVisible {
                        DebugHooks.write(settings, to: URL(fileURLWithPath: stem + "-settings.png"))
                        if let sheet = settings.attachedSheet {
                            DebugHooks.write(sheet, to: URL(fileURLWithPath: stem + "-settings-sheet.png"))
                        }
                        if self?.realOptions.settingsAll == true, let controller = self?.settings {
                            await DebugHooks.writeSettingsSections(controller, stem: stem)
                        }
                    }
                    if self?.realOptions.show == "menubar", let panel = await self?.statusItem?.debugLaidOutPanel() {
                        DebugHooks.write(panel, to: URL(fileURLWithPath: stem + "-menubar.png"))
                    }
                }
                if let path = self?.realOptions.snapshotPath {
                    await self?.writeOnboardingSnapshots(stem: (path as NSString).deletingPathExtension)
                }
                if let path = self?.realOptions.dumpTerminalPath { self?.dumpTerminals(to: path) }
                #endif
                // A script's quit never waits for dialog D (D18).
                self?.pendingQuitTrigger = .automation
                self?.quitApp(nil)
            }
        }
        #if DEBUG
        if let seconds = realOptions.quitRequestSeconds {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                HolderSessionStore.printLog("debug quit-request")
                self?.quitApp(nil)
            }
        }
        #endif
        #if DEBUG
        DebugHooks.run(app: self)
        if holderStore == nil {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                await self?.runSidebarDebugActions()
                // M5 D21: the accessibility pass runs last and ends the run itself.
                if let path = self?.realOptions.a11yAuditPath { await self?.runAccessibilityAudit(path) }
            }
        } else if realOptions.a11yAuditPath != nil {
            HolderSessionStore.printLog("A11Y refused: -codd-a11y-audit runs in mock mode only")
        }
        #endif
    }

    /// `-codd-window-size` / `-codd-sidebar-width` (layout sweep; Release never sets them): once the
    /// window is on screen and laid out, it is sized again the way a user's resize would (the
    /// launch size went in before the split's first layout), then the sidebar is set.
    private func applyLayoutSweepOptions(_ window: MainWindowController) {
        guard realOptions.windowSize != nil || realOptions.sidebarWidth != nil else { return }
        Task { @MainActor [weak self, weak window] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, let window, let nsWindow = window.window else { return }
            if let size = RealModeOptions.layoutSize(self.realOptions.windowSize, minimum: MainWindowController.minimumSize) {
                nsWindow.setContentSize(size)
                nsWindow.contentView?.layoutSubtreeIfNeeded()
            }
            #if DEBUG
            // `-codd-zoom` with `-codd-window-size`: the zoom steps run here, after the window got
            // its size, so a sweep sees a live zoom (13 → 20 grows a minimum window, refreshes
            // every view in place) instead of a launch at that zoom.
            if !self.realOptions.zoomSteps.isEmpty, self.realOptions.windowSize != nil {
                var appearance = self.preferences.preferences.appearance
                for step in self.realOptions.zoomSteps {
                    switch step {
                    case "in", "+": appearance = appearance.zoomed(by: 1)
                    case "out", "-": appearance = appearance.zoomed(by: -1)
                    case "reset", "0": appearance = appearance.zoomReset()
                    default: break
                    }
                }
                self.applyInterfaceZoom(appearance)
                try? await Task.sleep(for: .milliseconds(300))
                nsWindow.contentView?.layoutSubtreeIfNeeded()
            }
            #endif
            if let value = self.realOptions.sidebarWidth {
                let width: CGFloat? = switch value {
                case "collapsed": nil
                case "min": Metrics.sidebarMinWidth
                case "max": Metrics.sidebarMaxWidth
                default: Double(value).map { CGFloat($0) } ?? Metrics.sidebarWidth
                }
                window.split.setSessionSidebar(width: width)
                nsWindow.contentView?.layoutSubtreeIfNeeded()
            }
            HolderSessionStore.printLog("debug layout-sweep size=\(self.realOptions.windowSize ?? "-") sidebar=\(self.realOptions.sidebarWidth ?? "-") "
                                        + "sidebarWidth=\(window.split.sidebarContainer.view.frame.width) pane=\(window.pane.view.frame.width) "
                                        + "window=\(nsWindow.contentView?.frame.width ?? 0)")
        }
    }

    /// `-codd-sidebar-mode` / `-codd-sidebar-filter` (every build parses them; Release never sets them).
    private func applySidebarLaunchOptions(_ sidebar: SidebarViewController) {
        _ = sidebar.view
        if let mode = realOptions.sidebarMode { sidebar.setMode(mode) }
        if let filter = realOptions.sidebarFilter { sidebar.setFilter(filter) }
        #if DEBUG
        sidebar.onSnapshotChanged = { [weak self] in self?.scheduleStateDump() }
        #endif
    }

    /// D18: the quit request is decided first (`QuitPolicy`: dialog D, stop all, keep in the
    /// menu bar, or quit now). Quitting then writes the hook records and releases the port
    /// (bounded: a stuck flush never blocks the quit for more than 2 s).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let holders = holderStore, !isTerminating else { return .terminateNow }
        let trigger = pendingQuitTrigger ?? (QuitPolicy.isSystemQuit(NSAppleEventManager.shared().currentAppleEvent) ? .system : .user)
        pendingQuitTrigger = nil
        // D24: unsaved file tabs first (asked, or kept as copies when nothing may ask).
        guard filesAllowQuit(trigger) else { return .terminateCancel }
        let decision = quitDecision(trigger)
        if decision == .closeWindow { filesQuitApproved = nil }
        guard decision == .terminate else { return .terminateCancel }
        quitDialog.dismiss()
        return beginTerminate(holders)
    }

    /// The flush path of an accepted quit (holders keep running).
    private func beginTerminate(_ holders: HolderSessionStore) -> NSApplication.TerminateReply {
        isTerminating = true
        Task { @MainActor [weak self] in
            #if DEBUG
            await holders.hooks?.refreshStatistics()
            self?.writeStateDump()
            #endif
            await self?.flushNotes()
            await holders.shutdownHooks()
            self?.replyToTerminate()
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.replyToTerminate()
        }
        return .terminateLater
    }

    private var repliedToTerminate = false

    /// The first of "hooks flushed" and the 2 s bound lets the quit continue.
    private func replyToTerminate() {
        guard !repliedToTerminate else { return }
        repliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// Holders outlive the app: only the connections close here (tab layout and composer drafts
    /// saved first).
    func applicationWillTerminate(_ notification: Notification) {
        // D7: ⌘Q in the middle of the wizard writes nothing.
        onboardingWillTerminate()
        hotkey.hotkey.unregister()
        autoSwitch?.stop()
        hostLine?.stop()
        statusController?.setActive(false)
        claudeSettings?.flushIndex()
        // A Settings field being typed in commits before the flush (⌘Q from the Settings window).
        settings?.endEditing()
        preferences.flush()
        cswapAccounts?.shutdown()
        paneLayouts?.flush()
        mainWindow?.pane.composer.states.flush()
        terminalHub?.shutdown()
        holderStore?.shutdown()
        // D24: a file is never written at quit (only ⌘S writes; unsaved buffers were asked about
        // or kept as copies in applicationShouldTerminate); the watchers stop and the AI touches
        // still waiting for their debounced write land now.
        files.shutdown()
        holderStore?.hooks?.aiTouches.flush()
        // D32: a condense child never outlives CODD; the retention tick stops.
        condense?.shutdown()
        retention?.stop()
        removeMockNotes()
    }

    /// D10: closing the main window keeps CODD (menu bar item, Dock icon, hook endpoint, holders).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Closed or miniaturized: terminals stop rendering (they keep parsing) until it is back.
    func mainWindowVisibilityChanged(_ visible: Bool) {
        terminalHub?.setWindowOccluded(!visible)
        hostLine?.setVisible(visible, for: "window")
        #if DEBUG
        scheduleStateDump()
        #endif
    }

    private var isMainWindowVisible: Bool {
        guard let window = mainWindow?.window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // D5: a Dock click brings the wizard forward while it is open.
        if onboarding?.bringForward(reason: "dock") == true { return true }
        if !flag { showMainWindow(nil) }
        return true
    }

    // MARK: Wiring

    private static func mockContent(store: any SessionStore, target: TerminalTarget) -> String {
        guard let session = store.session(target.sessionID) else { return "" }
        switch target.tab {
        case .claude:
            return MockTranscripts.primary(for: session.id)
        case .shell:
            guard let project = store.project(session.projectID) else { return "" }
            return MockShellTranscripts.zshTab(projectID: project.id, cwd: project.cwd)
        }
    }

    private func panelActions() -> MenuBarPanelActions {
        MenuBarPanelActions(
            openSession: { [weak self] id in self?.openFromMenuBar(id) },
            allow: { [weak self] id in self?.sessionStore.answer(id, key: "1") },
            openMain: { [weak self] in self?.statusItem?.closePanel(); self?.showPrimaryWindow(reason: "status-item") },
            openSettings: { [weak self] section in self?.statusItem?.closePanel(); self?.openSettings(section: section) },
            newSession: { [weak self] in
                guard let self, self.holderStore != nil else { NSSound.beep(); return }
                self.statusItem?.closePanel()
                self.showMainWindow(nil)
                self.presentNewSession(NewSessionForm())
            },
            quickNote: { [weak self] in
                self?.statusItem?.closePanel()
                self?.startQuickNote()
            },
            openCleanup: { [weak self] in self?.openCleanup() })
    }

    /// The session the user is looking at: current in the sessions area of the visible main
    /// window, with CODD active. Such a session never turns DONE and is never notified. A
    /// background run (`AppActivation`) is never active and its window sits behind other apps,
    /// so it counts an open window as seen: DONE and notifications behave as in a foreground run.
    private func isViewing(_ id: SessionID) -> Bool {
        let background = AppActivation.isBackground
        guard NSApp.isActive || background, shell.area == .sessions, shell.currentSessionID == id,
              let window = mainWindow?.window, window.isVisible, !window.isMiniaturized else { return false }
        return background || window.occlusionState.contains(.visible)
    }

    /// Real mode: pane layouts, then sessions (installing the holder and codd-hook binaries
    /// first, starting the hook endpoint), then the shell tabs' holders, then the requested
    /// spawns and debug actions.
    private func startRealMode(_ holders: HolderSessionStore, hub: TerminalHub) {
        let options = realOptions
        // M4 I2a: the MCP, prompt and note URL routes go onto the hook server before it binds.
        mcpService?.start()
        wireMCPNoteCreatedToast()
        LoginEnvironment.isEnabled = options.captureLoginEnvironment
        LoginEnvironment.warmUp()
        let panes = PaneLayoutStore(root: holders.root, shell: shell)
        paneLayouts = panes
        holders.shellCurrentSession = { [weak self] in self?.shell.currentSessionID }
        hub.onSessionDeleted = { [weak self] id in self?.mainWindow?.pane.composer.forget(id) }
        holders.isViewing = { [weak self] id in self?.isViewing(id) ?? false }
        let preferences = self.preferences
        let notifier = SessionNotifier(store: holders, allowedThisRun: options.notifications,
                                       rules: { preferences.preferences.notifications },
                                       isFocused: { [weak self] id in self?.isViewing(id) ?? false },
                                       isMuted: { [weak holders] session in
                                           guard let group = holders?.project(session.projectID)?.groupID else { return false }
                                           return preferences.preferences.notifications.mutedGroupIDs.contains(group)
                                       },
                                       stoppedByUser: { [weak holders] id in holders?.stopRequested.contains(id) ?? false },
                                       open: { [weak self] id in self?.showMainWindow(nil); self?.mainWindow?.show(id) },
                                       decisions: notificationLog, log: { HolderSessionStore.printLog($0) })
        self.notifier = notifier
        // D29: account notifications go through the session notifier (the one delegate).
        appNotifier = AppNotifier(dispatcher: notifier, allowedThisRun: options.notifications,
                                  rules: { preferences.preferences.notifications }, decisions: notificationLog,
                                  log: { HolderSessionStore.printLog($0) })
        wireRetention()
        // D36: the host one-liner while the window or the popover shows.
        let hostLine = HostLineService { [weak holders] line in holders?.hostLine = line }
        self.hostLine = hostLine
        hostLine.setVisible(isMainWindowVisible, for: "window")
        #if DEBUG
        holders.onTransition = { [weak self, weak notifier] session, old in
            notifier?.sessionChanged(session, from: old)
            self?.sessionTransitioned(session)
        }
        #else
        holders.onTransition = { [weak notifier] session, old in notifier?.sessionChanged(session, from: old) }
        #endif
        services?.showNewSession = { [weak self] form in self?.presentNewSession(form) }
        services?.launch = { [weak self] request in self?.launch(request) }
        #if DEBUG
        holders.onStatesChanged = { [weak self] in self?.scheduleStateDump() }
        if options.dumpStatePath != nil {
            let shell = self.shell
            paneDumpLoop = ObservationLoop(track: { (shell.panes, shell.tabTitles, shell.bells, shell.runningTabs) },
                                           apply: { [weak self] _ in self?.scheduleStateDump() })
            if let mcp = mcpService {
                mcpDumpLoop = ObservationLoop(track: { () -> String in
                    "\(mcp.running)|\(mcp.clients.map(\.key))|\(mcp.toolCalls)|\(mcp.expansion.count)|\(mcp.expansion.late)|"
                        + MCPService.registrationName(mcp.claudeCode)
                }, apply: { [weak self] _ in self?.scheduleStateDump() })
            }
        }
        #endif
        // DEBUG flags (a Release build never sets them: `RealModeOptions.releaseSubset`).
        if let seconds = options.staleAfterSeconds {
            holders.staleAfter = seconds
            // A short limit is rechecked as often (a check every 60 s would never show it in a short run).
            holders.staleInterval = .milliseconds(Int(min(60, max(1, seconds)) * 1000))
        }
        if let accounts = cswapAccounts { wireAccounts(accounts, holders: holders) }
        // D16: the rows are on screen once the store installed the loaded layout (the claude
        // registrations and the hook endpoint come after it and are not part of the sidebar).
        holders.onLoaded = { [weak self] in self?.logLaunchToSidebar() }
        Task { [weak self] in
            // M5 D14: the data preflight before any store reads its file (off the main actor).
            await self?.runDataPreflight(holders)
            // Preferences first (a few ms, off the main actor): the stale threshold applies from
            // the first discovered session on.
            await preferences.load()
            self?.observePreferences()
            #if DEBUG
            // (With `-codd-window-size` the layout sweep runs them once the window has its size.)
            if self?.realOptions.windowSize == nil { self?.runZoomDebugActions() }
            #endif
            // The notebook opens in parallel with the sessions (its index builds inside its actor).
            self?.startNotes()
            // Accounts in parallel with the sessions (cswap --version and a state read), awaited
            // before the launch options so a DEBUG pin finds them.
            let accountsReady = Task { await self?.cswapAccounts?.start() }
            await panes.load()
            await holders.start()
            // D16: logged by `onLoaded` already; this covers a start that never loaded (a no-op otherwise).
            self?.logLaunchToSidebar()
            // D29 / D30: the first retention run once the notebook is open and the sessions are known.
            let retentionStart = self?.retention.map { retention in Task { await retention.start() } }
            panes.prune(keeping: Set(holders.sessionDirectories.keys))
            // Post-M4: composer images 24 h after their last send, every session folder (off main).
            self?.mainWindow?.pane.composer.states.sweepAttachments(in: holders.sessionDirectories)
            await hub.discoverTabs()
            await self?.services?.loadClaudeSettings()
            await accountsReady.value
            self?.startAutoSwitch()
            // D14: the stores' own `.corrupt-<ms>` moves of this launch, once every store loaded.
            Task { [weak self] in
                await self?.notes.open()
                await retentionStart?.value
                await self?.sweepAsideFiles(holders)
            }
            var spawned: SessionID?
            if let cwd = options.spawnShellCwd {
                for _ in 0..<options.spawnCount {
                    let id = holders.spawnShell(in: cwd)
                    // D20 (DEBUG): stopped in the same turn, before its holder can exist.
                    if options.stopAfterCreate, let id { holders.stop([id]) }
                    spawned = id ?? spawned
                }
            }
            if let cwd = options.newClaudeCwd {
                var request = NewSessionRequest(cwd: cwd, kind: .claude)
                request.claude.profileID = options.newProfile
                // D12: the same pin the ⌘N select sets (createSession checks the profile).
                request.claude.accountNumber = options.newClaudeAccount
                if let resume = options.resumeTranscript {
                    // The in-use check needs the registry's first snapshot (it comes right after start).
                    _ = await holders.waitForRegistry()
                    request.claude.mode = .resume(resume)
                }
                if let id = holders.createSession(request) {
                    spawned = id
                    // D20 (DEBUG): stopped in the same turn, before its holder can exist.
                    if options.stopAfterCreate { holders.stop([id]) }
                } else if let refusal = holders.lastRefusal {
                    // The ⌘N sheet shows this inline; without a sheet the log carries the same text.
                    HolderSessionStore.printLog("debug new-claude refused: \(refusal)")
                }
            }
            if options.resumeStopped {
                for session in holders.allSessions where session.kind == .claude && session.state == .stopped {
                    holders.resume(session.id)
                    spawned = spawned ?? session.id
                }
            }
            guard let self else { return }
            if let id = options.selectSession, id.hasPrefix("ext-") {
                // Externals come with the first registry snapshot, shortly after the hooks start.
                let deadline = ContinuousClock.now + .seconds(3)
                while holders.session(id) == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            }
            if let id = options.selectSession, holders.session(id) != nil {
                self.mainWindow?.show(id)
            } else if let spawned {
                self.mainWindow?.show(spawned)
            } else {
                self.selectFirstSessionIfNone()
            }
            #if DEBUG
            self.launchSessionsReady = true
            self.scheduleStateDump()
            await self.runDebugActions(hub: hub)
            await self.runSidebarDebugActions()
            await self.runAccountDebugActions()
            #endif
        }
    }

    /// The account store and the session store in both directions: following sessions show the
    /// active account, pins resolve to cswap profiles (D12), status-line reports reach the book
    /// (D9), the pinned profiles' registries are watched.
    private func wireAccounts(_ accounts: CswapAccountStore, holders: HolderSessionStore) {
        accounts.sessionCounts = { [weak holders] in holders?.sessionAccountCounts ?? (following: 0, pinned: [:]) }
        holders.accountPinning = { [weak accounts] number, relaunch in accounts?.pinResolution(number, relaunch: relaunch) ?? .notReady }
        holders.accountProfilePath = { [weak accounts] number in accounts?.profilePath(number) }
        holders.accountForConfigDir = { [weak accounts] dir in accounts?.account(forConfigDir: dir) }
        holders.hooks?.onStatusLine = { [weak accounts] report in accounts?.ingest(report) }
        accountLoops.append(ObservationLoop(track: { accounts.activeAccountID }, apply: { [weak holders] id in
            holders?.setFollowingAccount(id)
        }))
        accountLoops.append(ObservationLoop(track: { () -> [URL] in
            // Sessions added or removed may bring a launch profile's own config directory.
            _ = holders.sessionsByID.count
            return accounts.profileRegistryDirectories + holders.launchProfileRegistryDirectories
        }, apply: { [weak holders] directories in holders?.hooks?.setExtraRegistryDirectories(directories) }))
        #if DEBUG
        if realOptions.dumpStatePath != nil {
            // The `accounts` / `menuBar` keys follow switches and reports.
            accountLoops.append(ObservationLoop(track: { [weak self] () -> Int in
                guard let self else { return 0 }
                _ = MenuBarPanelContent.build(store: self.sessionStore, accounts: accounts, expanded: self.shell.menuBarAccountsExpanded)
                _ = accounts.switchState
                _ = accounts.statusLine
                return accounts.accounts.count
            }, apply: { [weak self] _ in self?.scheduleStateDump() }))
        }
        #endif
    }

    /// D13: the auto-switch runner, once the accounts (and quota.json's cooldown) are read.
    private func startAutoSwitch() {
        guard autoSwitch == nil, let accounts = cswapAccounts, let notifier = appNotifier else { return }
        let tick = realOptions.autoSwitchTickSeconds.map { Duration.milliseconds(Int($0 * 1000)) } ?? .seconds(30)
        let runner = AutoSwitchRunner(accounts: accounts, preferences: preferences, notifier: notifier, tick: tick)
        runner.toast = { [weak self] text, undo in self?.mainWindow?.showToast(text, undo: undo) }
        autoSwitch = runner
        statusController?.autoSwitch = runner
        runner.start()
        #if DEBUG
        if realOptions.dumpStatePath != nil {
            accountLoops.append(ObservationLoop(track: { () -> String in runner.lastDecision }, apply: { [weak self] _ in
                self?.scheduleStateDump()
            }))
        }
        #endif
    }

    /// Pushes the preferences' consumers' values now and whenever the preferences change.
    private func observePreferences() {
        guard preferencesLoop == nil else { return }
        let preferences = self.preferences
        preferencesLoop = ObservationLoop(track: { preferences.preferences }, apply: { [weak self] value in
            self?.applyPreferences(value)
        })
    }

    private func applyPreferences(_ value: CoddPreferences) {
        cswapAccounts?.apply(preferences: value)
        notes.apply(preferences: value)
        mcpService?.apply(preferences: value)
        retention?.apply(preferences: value)
        if let holders = holderStore {
            let staleAfter = PreferencesService.staleAfter(value, override: realOptions.staleAfterSeconds)
            if holders.staleAfter != staleAfter {
                holders.staleAfter = staleAfter
                holders.refreshStale()
            }
        }
        applyLifecyclePreferences(value)
        #if DEBUG
        scheduleStateDump()
        #endif
    }

    // MARK: STATUS, installer, account dialogs (M3 I2)

    /// The STATUS area on this mode's stores (mock mode: the SPEC §5 sample through the same mapping).
    private func makeStatusController() -> StatusController {
        let root = holderStore?.root
        let statusDir = root.map { HolderSessionStore.abbreviate($0.url.appendingPathComponent("hooks").path) } ?? ""
        var sources = StatusController.Sources(store: sessionStore, accounts: accountStore, cswap: cswapAccounts, hooks: holderStore?.hooks,
                                               installer: claudeSettings, preferences: preferences, statusDir: statusDir,
                                               statusDirDiffers: root.map { $0 != .standard } ?? false, mock: holderStore == nil)
        sources.mcp = mcpService
        sources.registration = mcpRegistration
        sources.notesPath = PathFormat.abbreviateHome(notes.notesRoot.path)
        let status = StatusController(sources: sources)
        status.actions = StatusController.Actions(
            openSession: { [weak self] id in self?.mainWindow?.show(id) },
            openSessions: { [weak self] in self?.shell.area = .sessions },
            switchAccount: { [weak self] id in self?.userSwitch(id) },
            addAccount: { [weak self] in self?.presentAddAccount() },
            openSettings: { [weak self] section in self?.openSettings(section: section) },
            installer: { [weak self] action in self?.presentHookDiff(action) },
            mcpRegistration: { [weak self] id in self?.mcpRegistrationPressed(id, on: nil) },
            rotateMCPToken: { [weak self] in self?.confirmRotateMCPToken(on: nil) })
        status.pageView.cswapGuideActions = cswapGuideActions()
        return status
    }

    /// A user switch (STATUS, ⌘K): dialog A first when 切換前確認 is ON, then the D5 toast.
    @discardableResult
    func userSwitch(_ id: AccountID) -> Task<AccountSwitchOutcome, Never> {
        AccountSwitching.run(id, in: accountStore) { [weak self] text, undo in self?.mainWindow?.showToast(text, undo: undo) }
    }

    /// Dialog B for `action` (D10): the plan, then `套用並備份` writes it. Mock mode shows the
    /// SPEC §5 sample (nothing to write).
    /// From Settings the sheet goes on the Settings window (`on:`); a backup's `差異` is read-only.
    func presentHookDiff(_ action: InstallerAction, on target: NSWindow? = nil, readOnly: Bool = false) {
        guard hookDialog == nil else { return }
        if target == nil { showMainWindow(nil) }
        guard let window = target ?? mainWindow?.window else { return }
        guard let service = claudeSettings else {
            // Mock mode: the SPEC sample, closed by ⎋ / ✕ / 取消 / 套用 (nothing to write), one at a time.
            guard mockSheet == nil else { return }
            let close = { [weak self] in
                if let sheet = self?.mockSheet { DialogPresenter.dismiss(sheet) }
                self?.mockSheet = nil
            }
            let view = HookDiffDialogView(model: DialogSamples.hookDiff(), onApply: close, onCancel: close)
            mockSheet = DialogPresenter.presentSheet(view, on: window)
            return
        }
        let dialog = HookDiffDialog(service: service, action: action, readOnly: readOnly)
        dialog.onToast = { [weak self] text in self?.mainWindow?.showToast(text, undo: nil) }
        dialog.onFinish = { [weak self] in
            self?.hookDialog = nil
            self?.statusController?.rebuild()
            if let coordinator = self?.settings?.coordinator { Task { await coordinator.refreshSlowFacts() } }
            // M5 D11: step 3 shows what the dialog wrote.
            self?.onboardingHooksDialogFinished()
        }
        hookDialog = dialog
        Task { await dialog.present(on: window) }
    }

    /// Mock mode's sample dialog B (closed by its own buttons or the quit).
    private(set) var mockSheet: NSWindow?

    /// Dialog C (D24): a child panel at the main window's right edge.
    func presentAddAccount() {
        guard addAccountFlow == nil else { return }
        showMainWindow(nil)
        guard let window = mainWindow?.window else { return }
        guard let accounts = cswapAccounts, let holders = holderStore else {
            // Mock mode: the panel with the SPEC §5 sample, nothing behind it.
            let view = AddAccountDialogView(model: DialogSamples.addAccountStep1(), onOpenLoginTerminal: {}, onCapture: {},
                                            onAdd: { _, _ in }, onAddToken: {}, onCancel: { [weak self] in
                                                if let panel = self?.mockPanel { DialogPresenter.dismiss(panel) }
                                                self?.mockPanel = nil
                                            })
            mockPanel = DialogPresenter.presentPanel(view, over: window)
            return
        }
        guard accounts.availability.isReady else {
            // The note is the footer's comment line: its `// ` prefix does not belong in a toast.
            let note = accounts.availability.note.map { $0.hasPrefix("// ") ? String($0.dropFirst(3)) : $0 }
            mainWindow?.showToast("cswap 還不能用：\(note ?? "帳號還在讀取")", undo: nil)
            return
        }
        let flow = AddAccountFlow(env: addAccountEnvironment(accounts: accounts, holders: holders))
        flow.onFinish = { [weak self] in
            self?.addAccountFlow = nil
            self?.statusController?.rebuild()
        }
        addAccountFlow = flow
        flow.present(over: window)
        Task { await flow.start() }
    }

    private var mockPanel: NSWindow?

    #if DEBUG
    /// Mock mode's dialog C panel (the a11y pass audits it).
    var debugMockPanel: NSWindow? { mockPanel }

    /// The a11y pass: mock mode's sample dialogs B and C go again, as their own buttons would.
    func debugDismissMockDialogs() {
        if let sheet = mockSheet { DialogPresenter.dismiss(sheet) }
        mockSheet = nil
        if let panel = mockPanel { DialogPresenter.dismiss(panel) }
        mockPanel = nil
    }
    #endif

    private func addAccountEnvironment(accounts: CswapAccountStore, holders: HolderSessionStore) -> AddAccountFlow.Environment {
        let login = Self.claudeExecutable(override: realOptions.claudePath, standardRoot: holders.root == .standard)
        return AddAccountFlow.Environment(
            accounts: accounts, holders: holders,
            loginTyping: login.map { Self.shellQuoted($0) + " /login\r" },
            addTokenTyping: accounts.executablePath.map { Self.shellQuoted($0) + " add-token\r" },
            showSession: { [weak self] id in self?.mainWindow?.show(id) },
            toast: { [weak self] text in self?.mainWindow?.showToast(text, undo: nil) })
    }

    /// `'<path>'` for a POSIX shell.
    nonisolated static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The claude dialog C types `/login` for: the DEBUG `-codd-claude-path` executable, else (the
    /// standard data root only, D3) `claude` on the login PATH or `~/.local/bin/claude`. A test root
    /// without the flag gets nil: CODD never starts a real claude there.
    nonisolated static func claudeExecutable(override: String?, standardRoot: Bool, loginPATH: String? = nil,
                                             home: String = NSHomeDirectory(),
                                             isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        if let override { return override }
        guard standardRoot else { return nil }
        for dir in (loginPATH ?? "").split(separator: ":") where dir.hasPrefix("/") {
            let candidate = dir.hasSuffix("/") ? "\(dir)claude" : "\(dir)/claude"
            if isExecutable(candidate) { return candidate }
        }
        let fallback = home + "/.local/bin/claude"
        return isExecutable(fallback) ? fallback : "claude"
    }

    // MARK: New sessions

    /// ⌘N: the sheet on the main window (one at a time). The form arrives with what the caller
    /// knows (folder, kind, start, group); the profiles, Claude's own model and a default folder
    /// (a group's most recent project for its `+`, else the shown session's, else the most
    /// recently active project) are filled in here. Mock mode
    /// draws it with the SPEC §5 data (DEBUG `-codd-show new-session`), nothing starts there.
    func presentNewSession(_ form: NewSessionForm, openDropdown: Bool = false) {
        if newSessionSheet != nil { return }
        showMainWindow(nil)
        guard let window = mainWindow?.window else { return }
        let sources = newSessionSources()
        var initial = form
        initial.profiles = profiles.document
        initial.settingsModel = sources.claudeSettings().model
        initial.setProfile(initial.profileID)
        if initial.path.isEmpty {
            let recent = ProjectDropdownModel.build(query: nil, known: sources.knownProjects(), recent: [], chosenPath: nil).recent
                .compactMap(\.choice)
            if let group = initial.groupID {
                // A group's `+`: its most recently active project (none: the user picks a folder).
                initial.path = recent.first { $0.groupID == group }?.path ?? ""
            } else if let id = shell.currentSessionID, let session = sessionStore.session(id),
                      let project = sessionStore.project(session.projectID), !project.isTransient {
                initial.path = HolderSessionStore.standardize(project.cwd)
            } else if let first = recent.first {
                initial.path = first.path
            }
        }
        let sheet = NewSessionSheet(form: initial, sources: sources, profiles: profiles,
                                    onClose: { [weak self] in self?.newSessionSheet = nil; self?.newSessionChanged() })
        sheet.onChange = { [weak self] in self?.newSessionChanged() }
        newSessionSheet = sheet
        services?.reloadRecentProjects()
        sheet.present(on: window, openDropdown: openDropdown)
    }

    /// The sheet's data: the real store and AppServices, or the mock store with the SPEC §5
    /// transcripts and `.claude.json` folders.
    private func newSessionSources() -> NewSessionSources {
        let openProfiles: @MainActor () -> Void = { [weak self] in self?.openSettings(section: "profiles") }
        var sources: NewSessionSources
        if let holders = holderStore, let services {
            sources = .real(holders: holders, services: services, accounts: accountStore, create: { [weak self] request in
                guard let self else { return "CODD 正在結束" }
                return self.launch(request)
            }, openProfileSettings: openProfiles)
        } else {
            sources = .mock(store: sessionStore, accounts: accountStore, openProfileSettings: openProfiles)
        }
        let preferences = self.preferences
        sources.projectRoot = { Self.projectRoot(preferences.preferences) }
        sources.resumeWarning = { preferences.preferences.cleanup.resumeWarning }
        return sources
    }

    /// Settings › 一般 › 預設專案根目錄 with `~` expanded, when it is a folder (folder panels start there).
    static func projectRoot(_ preferences: CoddPreferences) -> String? {
        let path = PathFormat.expandTilde(preferences.general.projectRoot)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return path
    }

    /// The sheet changed or closed (state dump).
    private func newSessionChanged() {
        #if DEBUG
        scheduleStateDump()
        #endif
    }

    /// Starts a session and shows it. Returns the reason when it was refused.
    private func launch(_ request: NewSessionRequest) -> String? {
        guard let holders = holderStore else { return "mock 模式不能開 session" }
        guard let id = holders.createSession(request) else { return holders.lastRefusal ?? "無法開始 session" }
        mainWindow?.show(id)
        return nil
    }

    /// `+ New ▾` › 加入專案資料夾…: a folder picker, then the project shows up (no session). The
    /// same path as folders dropped from Finder (`SidebarViewController.addFolders`): a folder that
    /// already is a project is revealed and selected instead of added again.
    private func chooseProjectFolder() {
        guard holderStore != nil, let main = mainWindow, let window = main.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "加入"
        panel.message = "選擇要加入 CODD 的專案資料夾"
        if let root = Self.projectRoot(preferences.preferences) { panel.directoryURL = URL(fileURLWithPath: root, isDirectory: true) }
        panel.beginSheetModal(for: window) { [weak main] response in
            guard response == .OK else { return }
            main?.sidebar.addFolders(panel.urls.map(\.path), toGroup: nil, atIndex: nil)
        }
    }

    #if DEBUG
    /// `-codd-open-zsh-tab`, `-codd-open-panel`, `-codd-send-input`, `-codd-send-panel-input`,
    /// `-codd-close-main-window`.
    private func runDebugActions(hub: TerminalHub) async {
        if realOptions.closeMainWindow {
            mainWindow?.window?.close()
            HolderSessionStore.printLog("debug closed the main window")
        }
        if let id = realOptions.deleteHistory, let holders = holderStore {
            let done = await holders.deleteHistory(id)
            HolderSessionStore.printLog("debug delete-history session=\(id) done=\(done)")
        }
        if let cwd = realOptions.listTranscripts, let services {
            for _ in 0..<2 {
                let cached = services.isTranscriptListCached(cwd)
                let start = ContinuousClock.now
                let items = await services.transcripts(for: cwd)
                HolderSessionStore.printLog(String(format: "transcripts cwd=%@ count=%d ms=%.2f cache=%@", cwd, items.count,
                                                   TerminalHub.milliseconds(ContinuousClock.now - start), cached ? "hit" : "miss"))
            }
        }
        switch realOptions.show {
        case "status"?: await showStatusDebug()
        case "new-session"?, "settings-profiles"?, "settings-notebook"?, "settings-cleanup"?: await runSheetDebugActions()
        case "home"?: shell.currentSessionID = nil
        default: await runDialogDebugActions()
        }
        await runComposerDebugActions(hub: hub)
        guard let pane = mainWindow?.pane else { return }
        if realOptions.openZshTab { pane.openShellTab() }
        applyPanelDebugOptions(pane)
        for (slot, text) in [(TerminalSlot.main, realOptions.sendInput), (.panel, realOptions.sendPanelInput)] {
            guard let text else { continue }
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(10)
            while !hub.isStreaming(slot), clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            // Let the shell print its prompt before the line arrives.
            try? await Task.sleep(for: .milliseconds(300))
            let surface = slot == .main ? pane.surface : pane.panelSurface
            surface.send(.text(text, submit: true))
            HolderSessionStore.printLog("debug input slot=\(slot) streaming=\(hub.isStreaming(slot)) bytes=\(text.utf8.count)")
        }
        selectPanelTabDebugOption(pane)
    }

    /// `-codd-open-panel`, `-codd-panel-tabs <n>`, `-codd-maximize-panel` (real and mock mode).
    private func applyPanelDebugOptions(_ pane: SessionPaneViewController) {
        guard realOptions.openPanel, let id = shell.currentSessionID else { return }
        if !shell.pane(for: id).panelOpen { pane.toggleBottomTerminal() }
        if let wanted = realOptions.panelTabs {
            for _ in 0..<8 where shell.pane(for: id).panelTabs.count < wanted { pane.newPanelTab() }
        }
        if realOptions.maximizePanel, !shell.pane(for: id).isPanelMaximized { pane.toggleMaximizePanel() }
        let layout = shell.pane(for: id)
        HolderSessionStore.printLog("debug panel open=\(layout.panelOpen) tabs=\(layout.panelTabs.count) maximized=\(layout.isPanelMaximized)")
    }

    /// `-codd-panel-select <n>`: the n-th panel tab is shown (after the panel input went out).
    private func selectPanelTabDebugOption(_ pane: SessionPaneViewController) {
        guard let number = realOptions.panelSelect, let id = shell.currentSessionID else { return }
        let tabs = shell.pane(for: id).panelTabs
        guard tabs.indices.contains(number - 1) else { return }
        pane.selectPanelTab(tabs[number - 1].id)
        HolderSessionStore.printLog("debug panel select=\(number) tab=\(tabs[number - 1].id)")
    }

    /// `-codd-hover-card`, `-codd-new-group`, `-codd-group-hover`, `-codd-shortcut-matrix` (sidebar
    /// checks; real and mock mode).
    private func runSidebarDebugActions() async {
        guard let main = mainWindow, let window = main.window else { return }
        let sidebar = main.sidebar
        if let id = realOptions.groupHover {
            sidebar.applyNow()
            let row = sidebar.outline.row(forItem: sidebar.item(for: .group(id)))
            if row >= 0 { sidebar.outline.scrollRowToVisible(row) }
            if row >= 0, let rowView = sidebar.outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView {
                rowView.isHovered = true
                HolderSessionStore.printLog("debug group-hover group=\(id) row=\(row)")
            } else {
                HolderSessionStore.printLog("debug group-hover group=\(id) not shown")
            }
        }
        if let spec = realOptions.dragPreview {
            let parts = spec.split(separator: ",").map(String.init)
            if parts.count == 2 {
                sidebar.previewDrag(project: parts[0], over: parts[1])
                HolderSessionStore.printLog("debug drag-preview project=\(parts[0]) group=\(parts[1]) line=\(!sidebar.dropLine.isHidden)")
            }
        }
        // M4 sidebar-dnd: the drag self-test and the e2e's Finder folder drop (real mode).
        if realOptions.sidebarDragTest { await SidebarDragSelfTest(app: self).run() }
        if !realOptions.dropFolders.isEmpty {
            let refused = realOptions.dropFolders.compactMap { path in RealModeOptions.protectedPathReason(path).map { "\(path) (\($0))" } }
            if refused.isEmpty {
                // The launch's first session was just shown; the sidebar reveals it from an
                // observation callback on a later turn, which would replace the drop's selection.
                // A user's drop always comes after that settled.
                try? await Task.sleep(for: .milliseconds(150))
                SidebarFolderDropHook.run(app: self, paths: realOptions.dropFolders, group: realOptions.dropFoldersGroup,
                                          index: realOptions.dropFoldersIndex)
            } else {
                HolderSessionStore.printLog("debug drop-folders refused: \(refused.joined(separator: ", "))")
            }
        }
        if let name = realOptions.newGroupName {
            sidebar.beginNewGroup()
            sidebar.newGroupEditor?.name = name
            sidebar.newGroupCell?.field.stringValue = name
            sidebar.toggleNewGroupColorPopover()
            HolderSessionStore.printLog("debug new-group name=\(name) popover=\(sidebar.colorPopover?.isVisible == true)")
        }
        if let wanted = realOptions.hoverCard, let id = wanted == "current" ? shell.currentSessionID : wanted {
            // Externals arrive with the first registry snapshot.
            let deadline = ContinuousClock.now + .seconds(3)
            while sessionStore.session(id) == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            sidebar.applyNow()
            var node = NodeKind.session(id, .tree)
            if !sidebar.snapshot.contains(node), let mirror = sidebar.snapshot.allNodes().map(\.node).first(where: { $0.sessionID == id }) {
                node = mirror
            }
            let row = sidebar.outline.row(forItem: sidebar.item(for: node))
            if row >= 0 {
                sidebar.outline.scrollRowToVisible(row)
                window.makeKeyAndOrderFront(nil)
                sidebar.hoverCard.show(node, row: row, force: true)
                let ms = sidebar.hoverCard.lastShowDuration.map { TerminalHub.milliseconds($0) } ?? -1
                HolderSessionStore.printLog(String(format: "debug hover-card session=%@ shown=%@ showMs=%.2f", id,
                                                   sidebar.hoverCard.isShown ? "true" : "false", ms))
            } else {
                HolderSessionStore.printLog("debug hover-card session=\(id) no row")
            }
            scheduleStateDump()
        }
        if holderStore == nil {
            // Mock mode's `-codd-show home` (real mode handles it with its other debug actions).
            if realOptions.show == "home" { shell.currentSessionID = nil }
            if realOptions.show == "status" { await showStatusDebug() }
            await runDialogDebugActions()
            if ["new-session", "settings-profiles", "settings-notebook", "settings-cleanup"].contains(realOptions.show) {
                await runSheetDebugActions()
            }
            await runComposerDebugActions(hub: nil)
            applyPanelDebugOptions(main.pane)
            selectPanelTabDebugOption(main.pane)
        }
        if let query = realOptions.paletteQuery {
            try? await Task.sleep(for: .milliseconds(200))
            showQuickSwitch(nil)
            palette?.setQuery(query)
            HolderSessionStore.printLog("debug palette query=\(query) rows=\(palette?.model.count ?? 0)")
        }
        if realOptions.shortcutMatrix {
            await ShortcutMatrix(app: self).run()
        }
    }

    /// `-codd-show new-session` (with `-codd-new-session-path`, `-codd-new-session-start`,
    /// `-codd-new-session-kind`, `-codd-open-project-dropdown`, `-codd-new-session-create`) and
    /// `-codd-show settings-profiles` (with `-codd-edit-profile`).
    private func runSheetDebugActions() async {
        if realOptions.show == "settings-notebook" {
            // M4 I2a: 筆記本 & MCP with the live MCP facts (the registration read comes a moment later).
            openSettings(section: "notebook")
            try? await Task.sleep(for: .milliseconds(400))
            settings?.coordinator.refreshInfo()
            HolderSessionStore.printLog("debug settings section=notebook mcp=\(mcpService?.running ?? false)")
            return
        }
        if realOptions.show == "settings-cleanup" {
            // M4 I4a: 清理 with the head button `查看清理建議 · n →` and the condense selects.
            if let retention { await retention.start() }
            openSettings(section: "cleanup")
            try? await Task.sleep(for: .milliseconds(300))
            settings?.coordinator.refreshInfo()
            HolderSessionStore.printLog("debug settings section=cleanup count=\(holderStore?.cleanupSuggestions ?? -1)")
            return
        }
        if realOptions.show == "settings-profiles" {
            openSettings(section: "profiles")
            if let id = realOptions.editProfile { settings?.debugEditProfile(id == "new" ? nil : id) }
            HolderSessionStore.printLog("debug settings section=profiles editor=\(realOptions.editProfile ?? "none")")
            return
        }
        var form = NewSessionForm()
        if let path = realOptions.newSessionPath { form.path = path }
        if let start = realOptions.newSessionStart.flatMap(NewSessionForm.Start.init(mode:)) { form.start = start }
        if realOptions.newSessionKind == "shell" { form.kind = .shell }
        form.advancedOpen = realOptions.newSessionAdvanced
        presentNewSession(form, openDropdown: realOptions.openProjectDropdown)
        guard let sheet = newSessionSheet else { return }
        HolderSessionStore.printLog("debug new-session path=\(sheet.form.resolvedPath) start=\(sheet.form.start.mode) "
                                    + "dropdown=\(sheet.isDropdownOpen)")
        guard realOptions.newSessionCreate else { return }
        let deadline = ContinuousClock.now + .seconds(5)
        while sheet.form.start.isResume, sheet.form.resumeID == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let command = sheet.form.commandPreview(abbreviated: false)
        sheet.create()
        HolderSessionStore.printLog("debug new-session create command=\(command) closed=\(newSessionSheet == nil)")
    }

    /// `-codd-composer-open`, `-codd-composer-send` (each text once the shown terminal streams and
    /// its claude is past STARTING, a second apart so each turn ends first).
    private func runComposerDebugActions(hub: TerminalHub?) async {
        guard let pane = mainWindow?.pane else { return }
        if realOptions.composerOpen, !pane.isComposerShown {
            pane.toggleComposer()
            HolderSessionStore.printLog("debug composer open=\(pane.isComposerShown)")
        }
        guard !realOptions.composerSend.isEmpty, let id = shell.currentSessionID else { return }
        if let hub {
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(10)
            while !hub.isStreaming(.main), clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            while sessionStore.session(id)?.state == .starting, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            // Let the child switch on bracketed paste and raw mode before the first send.
            try? await Task.sleep(for: .milliseconds(800))
        }
        for text in realOptions.composerSend {
            let sent = pane.debugComposerSend(text)
            HolderSessionStore.printLog("debug composer-send session=\(id) chars=\(text.count) sent=\(sent)")
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// `-codd-auto-answer <key>`: the shown claude session started WAITING; press the key once,
    /// the way the answer bar does.
    private func sessionTransitioned(_ session: SessionVM) {
        guard let key = realOptions.autoAnswer, !autoAnswered, session.state == .waiting, session.kind == .claude,
              shell.currentSessionID == session.id else { return }
        autoAnswered = true
        let id = session.id
        Task { @MainActor [weak self] in
            // Let the TUI draw its prompt before the key arrives (and scripts see WAITING).
            try? await Task.sleep(for: .seconds(1))
            guard let self, self.holderStore?.session(id)?.state == .waiting else { return }
            self.mainWindow?.pane.answer(key)
            HolderSessionStore.printLog("debug auto-answer session=\(id) key=\(key)")
        }
    }

    /// `-codd-dump-state`: coalesced (one write per 100 ms burst) and at most one write per
    /// 500 ms: status-line reports arrive several times a second, and a dump on each of them
    /// made the e2e's CPU figures the dump's rather than the app's (M3 review).
    func scheduleStateDump() {
        guard realOptions.dumpStatePath != nil, stateDumpTask == nil else { return }
        let since = lastStateDumpAt.map { ContinuousClock.now - $0 } ?? .seconds(1)
        let delay = max(.milliseconds(100), .milliseconds(500) - since)
        stateDumpTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            await self?.holderStore?.hooks?.refreshStatistics()
            self?.stateDumpTask = nil
            self?.lastStateDumpAt = .now
            self?.writeStateDump()
        }
    }

    private func writeStateDump() {
        guard let path = realOptions.dumpStatePath, let holders = holderStore else { return }
        let instance = StateDump.Instance(pid: getpid(), lockPath: instanceLock?.path)
        let pane = mainWindow?.pane
        StateDump.write(StateDump.object(store: holders, dockBadge: NSApp.dockTile.badgeLabel, hub: terminalHub,
                                         windowVisible: isMainWindowVisible, instance: instance, services: services,
                                         sidebar: mainWindow?.sidebar.dumpObject(),
                                         composer: pane.map { pane in { pane.composerDump($0) } },
                                         palette: palette?.dump, home: pane?.homeDump,
                                         newSession: newSessionSheet?.dumpObject ?? sheetDumpAtQuit?.sheet,
                                         resumePicker: newSessionSheet?.pickerDump ?? sheetDumpAtQuit?.picker,
                                         pane: pane?.paneDump(holderPid: { [weak self] in self?.terminalHub?.tabHolderPid($0) }),
                                         preferences: preferencesDump, accounts: cswapAccounts?.dumpObject,
                                         accountOptions: accountStore.newSessionAccountOptions, menuBar: menuBarDump,
                                         extra: m3StatusDump.merging(m4Dump) { _, new in new }
                                             .merging(["bundle": bundleDump, "dataFiles": dataFilesDump,
                                                       "onboarding": onboardingDump]) { _, new in new }), to: path)
    }

    /// The M4 dump keys (§6): `notes`, (I2a) `mcp` and `promptExpansion`, (I2b) `registration`
    /// (never a token).
    private var m4Dump: [String: Any] {
        var extra: [String: Any] = ["notes": notesDump, "files": filesDump, "zoom": zoomDump]
        if let mcpService {
            extra["mcp"] = mcpService.dumpObject
            extra["promptExpansion"] = mcpService.expansionDump
        }
        if let registrationDump { extra["registration"] = registrationDump }
        if let retention { extra["retention"] = retention.retentionDump }
        if let cleanupMode { extra["cleanup"] = cleanupMode.dumpObject }
        return extra
    }

    /// The I2 / I3 dump keys (§6): `installer`, `status`, `autoSwitch`, `notifications`, `dialogs`,
    /// `quitDialog`, `hotkey`, `dock`, `loginItem`, `settings`.
    private var m3StatusDump: [String: Any] {
        var extra: [String: Any] = ["notifications": notificationLog.dumpObject]
        extra.merge(lifecycleDump) { _, new in new }
        if let claudeSettings { extra["installer"] = claudeSettings.dumpObject }
        if let statusController { extra["status"] = statusController.dumpObject }
        if let autoSwitch { extra["autoSwitch"] = autoSwitch.dumpObject }
        var shown: Any = NSNull()
        if switchDialogs?.current != nil { shown = "switch" }
        if hookDialog != nil { shown = "hooks" }
        if addAccountFlow != nil { shown = "add" }
        var dialogs: [String: Any] = ["shown": shown]
        if let flow = addAccountFlow {
            dialogs["addAccount"] = ["step": flow.model.currentStep, "busy": flow.model.busy,
                                     "error": flow.model.error.map { $0 as Any } ?? NSNull(),
                                     "loginShell": flow.loginShell.map { $0 as Any } ?? NSNull()]
        }
        extra["dialogs"] = dialogs
        return extra
    }

    /// `menuBar {accounts, total, expanded, title, paused, icon}` (D23): the panel's ACCOUNTS rows as
    /// built and the status item's look.
    private var menuBarDump: [String: Any] {
        let content = MenuBarPanelContent.build(store: sessionStore, accounts: accountStore, expanded: shell.menuBarAccountsExpanded)
        let look = statusItem?.appearance
        return ["accounts": content.accountIDs, "total": content.accountTotal, "expanded": content.accountsExpanded,
                "note": content.accountsNote.map { $0 as Any } ?? NSNull(), "title": look?.title ?? "",
                "paused": look?.paused ?? false, "icon": look.map { "\($0.state)" } ?? "normal"]
    }

    /// `-codd-show status` with `-codd-status-section` / `-codd-status-details`.
    private func showStatusDebug() async {
        shell.area = .status
        guard let status = statusController else { return }
        // The first refresh (HOST sample, settings inspection) lands within a moment.
        try? await Task.sleep(for: .milliseconds(400))
        if realOptions.statusDetails { status.pageView.toggleEndpointDetails() }
        if let name = realOptions.statusSection, let section = StatusSection(rawValue: name) {
            status.pageView.layoutSubtreeIfNeeded()
            status.pageView.scroll(to: section)
        }
        HolderSessionStore.printLog("debug status shown=\(status.isActive) section=\(realOptions.statusSection ?? "host")")
    }

    /// `-codd-show dialog-switch|dialog-hooks|dialog-add` (real and mock mode).
    private func runDialogDebugActions() async {
        switch realOptions.show {
        case "dialog-switch"?:
            guard let target = accountStore.accounts.first(where: { $0.id != accountStore.activeAccountID && !$0.isPseudo }) else {
                HolderSessionStore.printLog("debug dialog-switch: no account to switch to")
                return
            }
            showMainWindow(nil)
            switchDialogs?.show(target.id, in: accountStore)
            HolderSessionStore.printLog("debug dialog-switch to=\(target.id) shown=\(switchDialogs?.current?.sheet != nil)")
        case "dialog-hooks"?:
            presentHookDiff(.update)
            try? await Task.sleep(for: .milliseconds(300))
            HolderSessionStore.printLog("debug dialog-hooks shown=\(mainWindow?.window?.attachedSheet != nil)")
        case "dialog-add"?:
            presentAddAccount()
            try? await Task.sleep(for: .milliseconds(300))
            HolderSessionStore.printLog("debug dialog-add shown=\((addAccountFlow?.panel ?? mockPanel)?.isVisible == true)")
        case "dialog-quit"?:
            showMainWindow(nil)
            presentQuitDialog()
            HolderSessionStore.printLog("debug dialog-quit shown=\(quitDialog.isShown) running=\(quitDialog.model?.running ?? 0)")
        case let name? where name.hasPrefix("settings-") && name != "settings-profiles":
            let section = String(name.dropFirst("settings-".count))
            openSettings(section: section)
            // Its facts (inspection, backups, versions) come in off the main actor.
            await settings?.coordinator.refreshSlowFacts()
            HolderSessionStore.printLog("debug settings section=\(settings?.section ?? "-") shown=\(settings?.window?.isVisible == true)")
        default:
            break
        }
    }

    /// `-codd-hooks-plan <action>` (the plan into the dump) and `-codd-hooks-apply YES` (written
    /// without the dialog, only for a target the run named that is not inside the real ~/.claude).
    private func runInstallerDebugActions() async {
        guard let service = claudeSettings, let name = realOptions.hooksPlan, let action = ClaudeSettingsService.action(named: name) else {
            return
        }
        // The isolation guard runs before the plan: a refused target is never even read.
        if realOptions.hooksApply {
            let guardResult = ClaudeSettingsService.isDebugApplyAllowed(target: service.settingsURL,
                                                                       claudeDirGiven: realOptions.claudeDir != nil,
                                                                       settingsGiven: realOptions.claudeSettings != nil)
            guard guardResult.allowed else {
                HolderSessionStore.printLog("installer apply refused (\(guardResult.reason))")
                scheduleStateDump()
                return
            }
        }
        // The dump then shows the inspection the plan was built on (as STATUS would).
        await service.refreshInspection(force: true)
        let result = await service.plan(action)
        HolderSessionStore.printLog("debug hooks-plan action=\(name) changes=\(result.successValue?.changes ?? false)")
        guard realOptions.hooksApply, let plan = result.successValue else {
            scheduleStateDump()
            return
        }
        if let delay = realOptions.hooksApplyDelayMilliseconds, delay > 0 {
            HolderSessionStore.printLog("debug hooks-apply waiting ms=\(delay)")
            try? await Task.sleep(for: .milliseconds(delay))
        }
        switch await service.apply(plan) {
        case .success(let backup): HolderSessionStore.printLog("debug hooks-apply backup=\(backup?.lastPathComponent ?? "-")")
        case .failure(let error): HolderSessionStore.printLog("debug hooks-apply failed (\(ClaudeSettingsService.errorKind(error)))")
        }
        service.flushIndex()
        scheduleStateDump()
    }

    /// `-codd-add-account <alias>`: dialog C's three steps without clicks (D24).
    private func runAddAccountDebugAction() async {
        guard let alias = realOptions.addAccount else { return }
        presentAddAccount()
        guard let flow = addAccountFlow else {
            HolderSessionStore.printLog("debug add-account not started")
            return
        }
        await flow.start()
        flow.openLoginTerminal()
        let deadline = ContinuousClock.now + .seconds(15)
        while flow.model.step1Done == nil, !flow.finished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
            await flow.checkLogin()
        }
        HolderSessionStore.printLog("debug add-account login changed=\(flow.model.step1Done != nil)")
        await flow.capture()
        let slot = flow.model.slot
        await flow.add(alias: alias, slot: slot)
        if !flow.finished {
            HolderSessionStore.printLog("debug add-account refused error=\(flow.model.error ?? "-")")
            await flow.cancel()
        }
        HolderSessionStore.printLog("debug add-account alias-ok=\(CswapAlias.normalize(alias) != nil) slot=#\(slot) ending=\(flow.ending ?? "-")")
        scheduleStateDump()
    }

    /// `-codd-switch-account <n>` (a click on the footer row, toast included), `-codd-undo-switch YES`
    /// (the toast's UNDO once the switch succeeded), `-codd-refresh-accounts YES` (one explicit
    /// `↻ 立即更新`). They run after the first account read.
    private func runAccountDebugActions() async {
        guard let accounts = cswapAccounts else { return }
        await accounts.start()
        await runInstallerDebugActions()
        await runAddAccountDebugAction()
        if realOptions.refreshAccounts {
            await accounts.refresh(userInitiated: true)
            HolderSessionStore.printLog("debug refresh-accounts availability=\(accounts.availability.key) fallback=\(accounts.usingListFallback)")
        }
        guard let number = realOptions.switchAccount, let sidebar = mainWindow?.sidebar else { return }
        let outcome = await sidebar.footer.switchTo(String(number)).value
        HolderSessionStore.printLog("debug switch-account to=#\(number) outcome=\(outcome)")
        guard realOptions.undoSwitch, case .switched = outcome else { return }
        try? await Task.sleep(for: .milliseconds(500))
        let toast = sidebar.currentToast
        let hadUndo = toast?.hasUndo ?? false
        toast?.performUndo()
        HolderSessionStore.printLog("debug undo-switch pressed=\(hadUndo)")
        // UNDO runs the switch back on its own task: wait for it to settle for the dump.
        let deadline = ContinuousClock.now + .seconds(10)
        while accounts.isSwitching || accounts.activeAccountID == String(number), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        HolderSessionStore.printLog("debug undo-switch active=\(accounts.activeAccountID.map { "#" + $0 } ?? "-")")
        scheduleStateDump()
    }

    /// `-codd-dump-terminal`: the visible terminals' viewport text, for scripts.
    private func dumpTerminals(to path: String) {
        guard let hub = terminalHub else { return }
        var text = ""
        for slot in TerminalSlot.allCases {
            guard let viewport = hub.viewportText(slot) else { continue }
            text += "=== \(slot == .main ? "MAIN" : "PANEL") ===\n" + viewport + "\n"
        }
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            HolderSessionStore.printLog("dumped terminals to \(path) bytes=\(text.utf8.count)")
        } catch {
            HolderSessionStore.printLog("error cannot dump terminals to \(path): \(error)")
        }
    }
    #endif

    /// Real mode discovers sessions after the window picked its first one (there was none).
    private func selectFirstSessionIfNone() {
        guard shell.currentSessionID == nil, let main = mainWindow,
              let first = SidebarSnapshotBuilder.build(store: sessionStore, mode: .tree, filter: "").sessionOrder.first
        else { return }
        main.show(first)
    }

    private func openFromMenuBar(_ id: SessionID) {
        statusItem?.closePanel()
        showMainWindow(nil)
        mainWindow?.show(id)
    }

    private func preparePalette() {
        guard palette == nil else { return }
        // Mock mode has no services: the ⌘N sheet's `.claude.json` sample stands in (QuickSwitch
        // artboard: `未加入 · 來自 ~/.claude.json [+ 加入]`, review spec-fidelity-4).
        let mock = holderStore == nil
        let controller = CommandPaletteController(store: sessionStore, shell: shell, recentProjects: { [weak self] in
            mock ? MockData.claudeJsonProjects : self?.services?.recentProjects ?? []
        }, accounts: accountStore)
        controller.actions = QuickSwitchActions(
            openSession: { [weak self] id, withPanel in self?.openFromPalette(id, withPanel: withPanel) },
            openProject: { [weak self] id, shell in self?.openProject(id, shell: shell) },
            addSuggestion: { [weak self] path in self?.addSuggestedProject(path) },
            perform: { [weak self] action in self?.performPaletteAction(action) },
            openNote: { [weak self] id in self?.openNoteFromPalette(id) })
        controller.notes = { [weak self] in self?.paletteNotes() ?? [] }
        #if DEBUG
        controller.onChange = { [weak self] in self?.scheduleStateDump() }
        #endif
        palette = controller
        services?.reloadRecentProjects()
    }

    // MARK: Quick switch (D14)

    /// ⏎ on a session; ⌘⏎ also opens its ⌘J panel (an external only opens).
    func openFromPalette(_ id: SessionID, withPanel: Bool) {
        guard let main = mainWindow, sessionStore.session(id) != nil else { NSSound.beep(); return }
        main.show(id)
        guard withPanel, let session = sessionStore.session(id), !session.external else { return }
        if shell.pane(for: id).panelOpen { main.pane.panelSurface.focus() } else { main.pane.toggleBottomTerminal() }
    }

    /// ⏎ on a project: its most recently active session (⌘N for its folder when it has none);
    /// ⌘⏎: its running shell session, started when it has none.
    func openProject(_ id: ProjectID, shell wantsShell: Bool) {
        guard let project = sessionStore.project(id), let main = mainWindow else { NSSound.beep(); return }
        let sessions = project.sessionIDs.compactMap { sessionStore.session($0) }
        let cwd = PathFormat.expandTilde(project.cwd)
        if wantsShell {
            if let running = sessions.first(where: { $0.kind == .shell && $0.state.isLive && !$0.external }) {
                main.show(running.id)
            } else if let problem = launch(NewSessionRequest(cwd: cwd, kind: .shell)) {
                reportLaunchProblem(problem)
            }
            return
        }
        let coddSessions = sessions.filter { !$0.external }
        if let latest = (coddSessions.isEmpty ? sessions : coddSessions).max(by: { $0.stateSince < $1.stateSince }) {
            main.show(latest.id)
        } else {
            var form = NewSessionForm()
            form.path = cwd
            presentNewSession(form)
        }
    }

    /// `+ 加入`: the `.claude.json` folder becomes a project (ungrouped) and the sidebar shows it.
    func addSuggestedProject(_ path: String) {
        guard let holders = holderStore, let id = holders.addProject(path: path, groupID: nil), let main = mainWindow else {
            NSSound.beep()
            return
        }
        showMainWindow(nil)
        let sidebar = main.sidebar
        sidebar.applyNow()
        let row = sidebar.outline.row(forItem: sidebar.item(for: .project(id)))
        if row >= 0 { sidebar.outline.scrollRowToVisible(row) }
        HolderSessionStore.printLog("palette added project=\(id) path=\(path)")
    }

    func performPaletteAction(_ action: QuickSwitchModel.Action) {
        guard let main = mainWindow else { return }
        switch action {
        case .newSessionIn(let path, _):
            var form = NewSessionForm()
            form.path = PathFormat.expandTilde(path)
            presentNewSession(form)
        case .openTerminalIn(let path, _):
            if let problem = launch(NewSessionRequest(cwd: PathFormat.expandTilde(path), kind: .shell)) { reportLaunchProblem(problem) }
        case .newSession:
            presentNewSession(NewSessionForm())
        case .newShellSession:
            var form = NewSessionForm()
            form.kind = .shell
            presentNewSession(form)
        case .resumeConversation:
            var form = NewSessionForm()
            form.start = .resume(nil)
            presentNewSession(form)
        case .addProjectFolder:
            if holderStore == nil { NSSound.beep() } else { chooseProjectFolder() }
        case .newGroup:
            main.sidebar.beginNewGroup()
        case .toggleSidebar:
            main.toggleSidebar()
        case .bottomTerminal:
            main.pane.toggleBottomTerminal()
        case .composer:
            main.pane.toggleComposer()
        case .newShellTab:
            main.pane.newShellTab()
        case .status:
            shell.area = .status
        case .settings:
            openSettings(section: nil)
        case .switchAccount(let id, _, _):
            userSwitch(id)
        }
    }

    private func reportLaunchProblem(_ problem: String) {
        NSSound.beep()
        guard let window = mainWindow?.window else { return }
        let alert = NSAlert()
        alert.messageText = "無法開始 session"
        alert.informativeText = problem
        alert.beginSheetModal(for: window)
    }

    func openSettings(section: String?) {
        let start = ContinuousClock.now
        let first = settings == nil
        let controller = settings ?? makeSettings()
        settings = controller
        // DEBUG layout sweep: the size Settings opens at (`min`: its minimum).
        if first, let size = RealModeOptions.layoutSize(realOptions.settingsSize, minimum: SettingsWindowController.minimumSize) {
            controller.window?.setContentSize(size)
        }
        controller.show(section: section)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        HolderSessionStore.printLog(String(format: "SETTINGS shown ms=%.2f first=%@ section=%@",
                                           TerminalHub.milliseconds(ContinuousClock.now - start), first ? "yes" : "no", section ?? "-"))
    }

    /// Settings with the launch profiles (D5) and Claude's own model (D30); mock mode draws the
    /// SPEC §5 data (`跟隨全域（#3 工作）`, `預設 (opus-5.5)`).
    private func makeSettings() -> SettingsWindowController {
        // `跟隨全域（#3 工作）`: the global login a following profile runs on (it follows a switch).
        let accounts = accountStore
        let accountLabel: @MainActor () -> String = { "跟隨全域" + (accounts.activeAccount.map { "（\($0.displayName)）" } ?? "") }
        let services = self.services
        let claudeSettings: @MainActor () -> ClaudeUserSettingsSummary
        if let services {
            claudeSettings = { services.claudeSettings }
        } else {
            claudeSettings = { MockData.claudeSettings }
        }
        let coordinator = SettingsCoordinator(environment: settingsEnvironment(claudeSettings: claudeSettings))
        return SettingsWindowController(profiles: profiles, claudeSettings: claudeSettings, accountLabel: accountLabel,
                                        preferences: preferences, coordinator: coordinator)
    }

    // MARK: CoddCommands

    @objc func showSettings(_ sender: Any?) { openSettings(section: nil) }

    @objc func showQuickSwitch(_ sender: Any?) {
        preparePalette()
        guard let window = mainWindow?.window else { return }
        if !window.isVisible { showMainWindow(nil) }
        palette?.toggle(over: window)
    }

    @objc func newSession(_ sender: Any?) { presentNewSession(NewSessionForm()) }

    /// AppKit ignores `terminate:` while a sheet is attached (the ⌘N sheet, a confirmation), so
    /// those end first. The terminate itself is deferred out of the current main-actor job: a
    /// `terminateLater` reply waits in a nested run loop that cannot run main-actor work while a
    /// job is on the stack.
    ///
    /// D18: the status item's `結束` is told apart (it always asks while sessions run); while
    /// dialog D is open another ⌘Q only brings it forward.
    @objc func quitApp(_ sender: Any?) {
        if (sender as? NSMenuItem)?.identifier?.rawValue == StatusItemController.quitItemID, pendingQuitTrigger == nil {
            pendingQuitTrigger = .statusItem
        }
        if quitDialog.isShown, pendingQuitTrigger != .automation {
            pendingQuitTrigger = nil
            quitDialog.window?.makeKeyAndOrderFront(nil)
            return
        }
        #if DEBUG
        // The quit closes the sheet before the last state dump: keep what it showed.
        if let sheet = newSessionSheet { sheetDumpAtQuit = (sheet.dumpObject, sheet.pickerDump) }
        #endif
        newSessionSheet?.close()
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
        }
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }
    @objc func toggleSessionSidebar(_ sender: Any?) { mainWindow?.toggleSidebar() }
    @objc func selectSessionByNumber(_ sender: NSMenuItem) { mainWindow?.selectSession(number: sender.tag) }
    @objc func selectNextSession(_ sender: Any?) { mainWindow?.cycleSession(forward: true) }
    @objc func selectPreviousSession(_ sender: Any?) { mainWindow?.cycleSession(forward: false) }
    @objc func allowCurrentSession(_ sender: Any?) {
        #if DEBUG
        allowInvocations += 1
        #endif
        _ = mainWindow?.pane.allowCurrent()
    }
    @objc func newShellTab(_ sender: Any?) { mainWindow?.pane.newShellTab() }
    @objc func toggleBottomTerminal(_ sender: Any?) { mainWindow?.pane.toggleBottomTerminal() }
    @objc func toggleComposer(_ sender: Any?) { mainWindow?.pane.toggleComposer() }
    @objc func focusSidebarFilter(_ sender: Any?) { mainWindow?.sidebar.focusFilter() }

    /// The session on screen when it is one CODD can act on (not an external).
    private var currentCODDSession: SessionVM? {
        guard shell.area == .sessions, let id = shell.currentSessionID, let session = sessionStore.session(id), !session.external
        else { return nil }
        return session
    }

    @objc func togglePinCurrentSession(_ sender: Any?) {
        guard let session = currentCODDSession else { NSSound.beep(); return }
        sessionStore.setPinned(!session.isPinned, sessions: [session.id])
    }

    @objc func stopCurrentSession(_ sender: Any?) {
        guard let session = currentCODDSession, session.state.isLive else { NSSound.beep(); return }
        showMainWindow(nil)
        mainWindow?.sidebar.confirmStop([session.id])
    }

    @objc func showMainWindow(_ sender: Any?) {
        mainWindow?.showWindow(nil)
        mainWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let notes = validateNotesMenuItem(menuItem) { return notes }
        if let zoom = validateZoomMenuItem(menuItem) { return zoom }
        if let a11y = validateAccessibilityMenuItem(menuItem) { return a11y }
        switch menuItem.action {
        case #selector(allowCurrentSession(_:)):
            return mainWindow?.pane.canAllowCurrent ?? false
        case #selector(selectSessionByNumber(_:)):
            return menuItem.tag <= (mainWindow?.sidebar.snapshot.sessionOrder.count ?? 0)
        case #selector(newSession(_:)):
            return holderStore != nil
        case #selector(togglePinCurrentSession(_:)):
            let session = currentCODDSession
            menuItem.title = session?.isPinned == true ? "取消釘選" : "釘選"
            return session != nil
        case #selector(stopCurrentSession(_:)):
            return currentCODDSession?.state.isLive == true
        case #selector(toggleComposer(_:)):
            return currentCODDSession != nil
        default:
            return true
        }
    }
}
