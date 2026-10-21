import AppKit
import CoddClaudeSettings
import CoddCore
import CoddDialogsUI
import CoddPreferences
import CoddSettingsUI
import CoddUI

/// M3 I3: what Settings changes in the running app (Dock, login item, hotkey, CRT, motion,
/// terminal font, NO HOOK grace, externals), the quit flow with dialog D (D18) and the close
/// button (D19), and Settings' facts and actions.
extension AppDelegate {
    // MARK: Preferences → consumers

    /// Every functional Settings row reaches its consumer here (also at launch, once the
    /// preferences were read). Each step is cheap when nothing changed.
    func applyLifecyclePreferences(_ value: CoddPreferences) {
        applyDockPolicy(showInDock: value.general.showInDock)
        loginItems.apply(value.general)
        if !hotkey.isSuspended { hotkey.apply(value.general) }
        mainWindow?.container.setCRT(value.appearance.crt)
        onboarding?.crt = value.appearance.crt
        let motion: Bool? = switch value.appearance.reduceMotion {
        case .system: nil
        case .on: true
        case .off: false
        }
        if UITicker.shared.motionOverride != motion { UITicker.shared.motionOverride = motion }
        applyInterfaceZoom(value.appearance)
        terminalHub?.setFontFamily(value.appearance.terminalFont)
        let size = Double(value.appearance.terminalFontSize)
        if appliedTerminalFontSize != size {
            // CODD has one terminal size (A− / A+ and ⌘+ / ⌘− move every terminal, through this
            // setting): the size a launch starts at, and a change moves them all.
            appliedTerminalFontSize = size
            let clamped = min(max(size, ShellState.fontSizeRange.lowerBound), ShellState.fontSizeRange.upperBound)
            if shell.terminalFontSize != clamped { shell.terminalFontSize = clamped }
        }
        if let holders = holderStore {
            let grace = TimeInterval(value.sessions.noHookWarningSeconds)
            if appliedNoHookGrace != grace, let engine = holders.hooks?.engine {
                appliedNoHookGrace = grace
                Task { await engine.setStartingGrace(grace) }
            }
            let externals = Self.externalDisplay(value.sessions)
            holders.setExternalDisplay(hidden: externals.hidden, filter: externals.filter)
        }
    }

    /// D21: only the standard data root may touch the system's login items; every other root
    /// (tests, throwaway roots, e2e) gets the no-op that says why.
    static func loginItemService(standardRoot: Bool) -> any LoginItemService {
        standardRoot ? SystemLoginItemService() : DisabledLoginItemService()
    }

    /// Settings › 工作階段 › 外部 session and 隱藏 SDK / Desktop session: `隱藏` removes every
    /// external; `偵測到的` (not built, the segment is disabled) shows them like `依專案`.
    nonisolated static func externalDisplay(_ sessions: CoddPreferences.Sessions) -> (hidden: Bool, filter: ExternalSessionFilter) {
        let hide = sessions.hideSDKAndDesktop
        return (sessions.externalDisplay == .hidden, ExternalSessionFilter(hideSDK: hide, hideDesktop: hide))
    }

    /// D20: `.accessory` without a Dock icon; a background launch never gets one.
    func applyDockPolicy(showInDock: Bool) {
        let policy = DockPolicy.policy(showInDock: showInDock, background: AppActivation.isBackground)
        guard policy != appliedPolicy else { return }
        appliedPolicy = policy
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        attention?.dockPolicyChanged()
        HolderSessionStore.printLog("dock policy=\(DockPolicy.name(policy)) showInDock=\(showInDock)")
    }

    /// D22: shows and brings up the main window; hides CODD when its main window is already key
    /// in front.
    func globalHotkeyPressed() {
        if NSApp.isActive, let window = mainWindow?.window, window.isKeyWindow, window.isVisible {
            NSApp.hide(nil)
        } else {
            showPrimaryWindow(reason: "hotkey")
        }
    }

    // MARK: Quit (D18, D19)

    /// Live CODD sessions (claude and shell; never externals): what dialog D can stop.
    var runningCODDSessions: [SessionVM] {
        sessionStore.allSessions.filter { $0.state.isLive && !$0.external }
    }

    /// Decides one quit request and starts what it needs (the dialog, stop all, closing the
    /// window). `.terminate` is left to the caller.
    func quitDecision(_ trigger: QuitTrigger) -> QuitDecision {
        let urgent = trigger == .system || trigger == .automation || trigger == .confirmed
        if quitDialog.isShown, !urgent {
            quitDialog.window?.makeKeyAndOrderFront(nil)
            return .ask
        }
        // `全部停止並結束` is already on its way out.
        if isStoppingAll, !urgent { return .stopAllThenTerminate }
        let running = runningCODDSessions.count
        let decision = QuitPolicy.decide(behavior: preferences.preferences.general.quitBehavior, trigger: trigger, running: running)
        lastQuit = (trigger, decision)
        HolderSessionStore.printLog("quit trigger=\(trigger.rawValue) decision=\(decision.rawValue) running=\(running)")
        switch decision {
        case .terminate: break
        case .closeWindow: mainWindow?.window?.close()
        case .ask: presentQuitDialog()
        case .stopAllThenTerminate: stopAllAndQuit()
        }
        #if DEBUG
        scheduleStateDump()
        #endif
        return decision
    }

    /// Dialog D over the main window (a sheet), or centered on its own when the window is closed.
    func presentQuitDialog() {
        let model = QuitDialogController.model(store: sessionStore, keepNextTime: preferences.preferences.general.quitBehavior == .keep)
        quitDialog.present(model, over: mainWindow?.window) { [weak self] choice, keepNextTime in
            self?.quitChosen(choice, keepNextTime: keepNextTime)
        }
        #if DEBUG
        if let name = realOptions.quitChoice, let choice = QuitDialogController.choice(named: name) {
            Task { @MainActor [weak self] in
                // Shown first (the dump and a snapshot see it), then answered like a click.
                try? await Task.sleep(for: .milliseconds(400))
                HolderSessionStore.printLog("debug quit-choice \(name)")
                self?.quitDialog.choose(choice)
            }
        }
        #endif
    }

    /// What dialog D's answer does. The checkbox sets 結束時 to 保留 for next time.
    func quitChosen(_ choice: QuitChoice, keepNextTime: Bool) {
        HolderSessionStore.printLog("quit choice=\(QuitDialogController.name(choice)) keepNextTime=\(keepNextTime)")
        if keepNextTime, choice != .cancel { preferences.update { $0.general.quitBehavior = .keep } }
        // CODD keeps running: a later quit asks about unsaved file tabs again.
        if choice == .cancel || choice == .keepInMenuBar { filesQuitApproved = nil }
        switch choice {
        case .stopAllAndQuit: stopAllAndQuit()
        case .quitKeepingSessions: terminateConfirmed()
        case .keepInMenuBar: mainWindow?.window?.close()
        case .cancel: break
        }
        #if DEBUG
        scheduleStateDump()
        #endif
    }

    /// `全部停止並結束`: SIGTERM to every live CODD session's holder and every shell tab's, then
    /// quit once their EXITs arrived or 3 s passed (externals are not touched).
    func stopAllAndQuit() {
        guard let holders = holderStore, !isStoppingAll else { return }
        isStoppingAll = true
        let hub = terminalHub
        Task { @MainActor [weak self] in
            let result = await QuitPolicy.stopAll(holders, hub: hub)
            HolderSessionStore.printLog("quit stop-all sessions=\(result.sessions) tabs=\(result.tabs) left=\(result.left)")
            self?.terminateConfirmed()
        }
    }

    /// Quits without asking again (dialog D answered).
    func terminateConfirmed() {
        pendingQuitTrigger = .confirmed
        NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
    }

    /// D19: with 關閉視窗時保留在選單列 OFF, closing the main window is a quit request (dialog D,
    /// 全部停止 or 保留 decide); true lets the window close as usual.
    func mainWindowShouldClose() -> Bool {
        guard holderStore != nil, !preferences.preferences.general.keepInMenuBarOnClose else { return true }
        quitApp(nil)
        return false
    }

    // MARK: Settings

    /// Settings' stores, facts and the app actions its buttons call.
    func settingsEnvironment(claudeSettings: @escaping @MainActor () -> ClaudeUserSettingsSummary) -> SettingsCoordinator.Environment {
        let holders = holderStore
        let cswap = cswapAccounts
        let root = holders?.root
        var env = SettingsCoordinator.Environment(preferences: preferences)
        env.store = sessionStore
        env.holders = holders
        env.accounts = accountStore
        env.cswap = cswap
        env.installer = self.claudeSettings
        env.profiles = profiles
        env.claudeSettings = claudeSettings
        env.loginItems = loginItems
        env.hotkey = hotkey
        env.versions = versionProbe
        env.autoSwitchWarning = { [weak self] in self?.autoSwitch?.backgroundWarning }
        env.accountsShown = { [weak self] shown in self?.autoSwitch?.scanDemand = shown }
        env.lastStatusLineAt = { [weak holders, weak cswap] in
            [holders?.hooks?.statistics?.lastStatusLineAt, cswap?.statusLine.lastAt].compactMap { $0 }.max()
        }
        env.hooksInjected = { [weak holders] in
            if case .listening = holders?.hooks?.status { return true }
            return false
        }
        env.statusDir = root.map { HolderSessionStore.abbreviate($0.url.appendingPathComponent("hooks").path) } ?? ""
        env.statusDirDiffers = root.map { $0 != .standard } ?? false
        env.dataRoot = root?.url
        env.mock = holders == nil
        env.addAccount = { [weak self] in self?.presentAddAccount() }
        env.cswapGuide = cswapGuideHandlers()
        env.presentHookDiff = { [weak self] action, window, readOnly in self?.presentHookDiff(action, on: window, readOnly: readOnly) }
        env.sendTestNotification = { [weak self] in self?.notifier?.sendTest() }
        env.log = { HolderSessionStore.printLog($0) }
        // M4 I2a / I2b: 筆記本 & MCP with the registrations and `[輪替]`.
        let notes = self.notes
        let mcp = mcpService
        let registration = mcpRegistration
        let accounts = accountStore
        env.notebook = { [weak holders] in
            SettingsInfoBuilder.notebook(notesPath: PathFormat.abbreviateHome(notes.notesRoot.path), mcp: mcp,
                                         hasMCPToken: holders?.hooks?.config?.mcpToken != nil,
                                         lastRebuild: notes.lastRebuild.map { ($0.count, $0.buildMs) }, rebuilding: notes.rebuilding,
                                         notesReady: notes.availability.isReady, registration: registration)
        }
        env.mcpRegistration = { [weak self] id, window in self?.mcpRegistrationPressed(id, on: window) }
        env.rotateMCPToken = { [weak self] window in self?.confirmRotateMCPToken(on: window) }
        env.condenseAccounts = { SettingsInfoBuilder.condenseAccounts(accounts) }
        env.refreshRegistrations = { await mcp?.refreshRegistrations() }
        env.openNotesFolder = { [weak self] in self?.revealNotesFolder() }
        env.rebuildNotesIndex = { Task { await notes.rebuildIndex() } }
        // M4 I4a: 清理's head button opens the Cleanup page (D31) with the candidates' count.
        env.openCleanup = { [weak self] in self?.openCleanup() }
        env.cleanupCount = { [weak holders] in holders?.cleanupSuggestions }
        // M5 D5: 關於 › 首次啟動設定 `[重新執行]`.
        env.openOnboarding = { [weak self] in self?.openOnboarding(reason: "reopen-settings") }
        env.openThirdPartyNotices = { [weak self] in self?.openThirdPartyNotices() }
        return env
    }

    /// 關於 › 第三方元件授權 `[開啟]`: Contents/Resources/THIRD-PARTY-NOTICES.md in the app that
    /// opens Markdown, else TextEdit (a fresh Mac may have no Markdown app), else shown in Finder.
    /// A user action only (D39).
    func openThirdPartyNotices() {
        guard !AppActivation.isBackground else {
            HolderSessionStore.printLog("about notices skipped (background run)")
            return
        }
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md") else {
            HolderSessionStore.printLog("about notices missing from the bundle")
            NSSound.beep()
            return
        }
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: url) != nil {
            workspace.open(url)
        } else if let textEdit = workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            workspace.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        } else {
            workspace.activateFileViewerSelecting([url])
        }
    }

    /// `[開啟筆記本資料夾]` (D33): the notes folder in Finder, on a user action only (D39: a
    /// background run never opens or reveals anything).
    func revealNotesFolder() {
        guard !AppActivation.isBackground else {
            HolderSessionStore.printLog("notes reveal-folder skipped (background run)")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([notes.notesRoot])
    }

    // MARK: Dump (§6)

    /// `preferences`: the stored values plus `effective`, what the running app applied from them
    /// (DEBUG overrides and the background mode included), so a run can check its consumers.
    var preferencesDump: [String: Any] {
        var object = preferences.dumpObject
        let ticker = UITicker.shared
        var effective: [String: Any] = [
            "dockPolicy": DockPolicy.name(NSApp.activationPolicy()),
            "crt": mainWindow?.container.crt.rawValue ?? NSNull(),
            "crtAlpha": mainWindow?.container.overlay.map { Double($0.lineAlpha) as Any } ?? 0.0,
            "reduceMotion": ticker.motionOverride.map { $0 ? "on" : "off" } ?? "system",
            "pulses": ticker.pulsesAllowed,
            "terminalFontSize": shell.terminalFontSize,
            // M4 interface zoom: the UI 字級 the windows are drawn at and its scale.
            "uiFontSize": UIZoom.fontSize,
            "uiScale": Double(UIZoom.scale),
            "hotkey": hotkey.registered.map { $0.spec as Any } ?? NSNull(),
            "quitBehavior": preferences.preferences.general.quitBehavior.rawValue,
            "keepInMenuBarOnClose": preferences.preferences.general.keepInMenuBarOnClose,
            "dockBadge": NSApp.dockTile.badgeLabel.map { $0 as Any } ?? NSNull(),
            "menuBarTitle": statusItem?.appearance?.title ?? "",
        ]
        if let hub = terminalHub { effective["terminalFont"] = hub.fontFamily }
        if let holders = holderStore {
            effective["staleAfterSeconds"] = holders.staleAfter.isFinite ? holders.staleAfter as Any : NSNull()
            effective["externalsHidden"] = holders.hidesExternals
            effective["hideSDK"] = holders.externalFilter.hideSDK
            effective["hideDesktop"] = holders.externalFilter.hideDesktop
            effective["noHookGraceSeconds"] = appliedNoHookGrace.map { $0 as Any } ?? NSNull()
        }
        object["effective"] = effective
        return object
    }

    /// `quitDialog`, `hotkey`, `dock`, `loginItem`, `settings`.
    var lifecycleDump: [String: Any] {
        let model = quitDialog.model
        var quit: [String: Any] = [
            "shown": quitDialog.isShown,
            "running": model?.running ?? runningCODDSessions.count,
            "stoppable": model?.stoppable ?? runningCODDSessions.count,
            "needs": model?.needs ?? sessionStore.allSessions.filter { $0.state.needsAttention }.count,
            "rows": model?.rows.map(\.id) ?? [],
            "choice": quitDialog.lastChoice.map { QuitDialogController.name($0) as Any } ?? NSNull(),
            "behavior": preferences.preferences.general.quitBehavior.rawValue,
        ]
        if let last = lastQuit {
            quit["trigger"] = last.trigger.rawValue
            quit["decision"] = last.decision.rawValue
        }
        let policy = NSApp.activationPolicy()
        var object: [String: Any] = [
            "quitDialog": quit,
            "hotkey": hotkey.dumpObject,
            "dock": ["policy": DockPolicy.name(policy),
                     "wanted": DockPolicy.name(DockPolicy.policy(showInDock: preferences.preferences.general.showInDock, background: false)),
                     "background": AppActivation.isBackground, "badge": NSApp.dockTile.badgeLabel as Any? ?? NSNull()],
            "loginItem": loginItems.dumpObject,
        ]
        if let settings { object["settings"] = settings.dumpObject }
        return object
    }
}
