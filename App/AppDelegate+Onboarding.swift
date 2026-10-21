import AppKit
import CoddClaudeSettings
import CoddCore
import CoddOnboarding
import CoddUI

/// M5 I2: the first-launch wizard (D5–D13). The gate decides once at launch, the window shows
/// instead of the main window, the facts are probed only while it shows, and every step's button
/// goes to the M3 / M4 surfaces that already do the work (dialog B, the registration dialog, the
/// Codex sheet, dialog C, the notes folder). It ends with `onboarding.json` and the main window.
extension AppDelegate: OnboardingHost {
    // MARK: Gate and opening (D5)

    /// Right after the instance lock in `applicationWillFinishLaunching`: the root's own files
    /// still say whether CODD ran here (nothing has written yet).
    func decideOnboarding() {
        let root = holderStore?.root
        onboardingLaunch = OnboardingLaunch.decide(realMode: holderStore != nil, root: root?.url, standardRoot: root == .standard,
                                                   mode: realOptions.onboarding, show: realOptions.show, step: realOptions.onboardingStep)
        if holderStore != nil || onboardingLaunch.show {
            HolderSessionStore.printLog("onboarding gate show=\(onboardingLaunch.show) reason=\(onboardingLaunch.reason) "
                                        + "step=\(onboardingLaunch.start.rawValue)")
        }
    }

    /// Opens the wizard (launch, Settings › 關於 `[重新執行]`, 說明 › 首次啟動設定…), or brings it
    /// forward when it is open. Live data in real mode, `OnboardingSamples` in mock mode.
    func openOnboarding(start: OnboardingStep = .detect, reason: String) {
        if let onboarding, onboarding.isOpen {
            onboarding.bringForward(reason: reason)
            return
        }
        let live = holderStore != nil
        let controller = OnboardingController(source: live ? .live : .mock, reason: reason, start: start, host: self,
                                              stateStore: holderStore.map { OnboardingStateStore(dataRoot: $0.root.url) })
        let presenter = OnboardingPresenter(controller: controller, host: self, log: { HolderSessionStore.printLog($0) })
        presenter.crt = preferences.preferences.appearance.crt
        presenter.onShown = { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            self.onboardingShown(presenter)
        }
        #if DEBUG
        presenter.onChange = { [weak self] in self?.scheduleStateDump() }
        #endif
        onboarding = presenter
        lastOnboarding = controller
        // Only a write after this point is the wizard's `已套用`.
        onboardingHooksBaseline = claudeSettings?.lastApplied?.at
        HolderSessionStore.printLog("onboarding open reason=\(reason) step=\(start.rawValue) source=\(live ? "live" : "mock")")
        Task { await presenter.open() }
    }

    /// D5: a show-window request, a Dock click, the status item's open action and the global
    /// hotkey bring the wizard forward while it is open; otherwise the main window.
    func showPrimaryWindow(reason: String) {
        if onboarding?.bringForward(reason: reason) == true { return }
        showMainWindow(nil)
    }

    /// 說明 › 首次啟動設定… (M5 D5).
    @objc func showOnboarding(_ sender: Any?) {
        openOnboarding(reason: "reopen-help")
    }

    private func onboardingShown(_ presenter: OnboardingPresenter) {
        if let accounts = cswapAccounts, presenter.controller.source == .live {
            // D13: dialog C (or cswap itself) changed the accounts while the wizard shows.
            let controller = presenter.controller
            onboardingLoops.append(ObservationLoop(track: { () -> (EnvironmentFacts.Cswap, [AccountsStepModel.Row]) in
                Self.onboardingAccounts(accounts)
            }, apply: { [weak controller] value in controller?.updateAccounts(value.0, rows: value.1) }))
        }
        #if DEBUG
        scheduleStateDump()
        if !onboardingActionsRan, !realOptions.onboardingActions.isEmpty {
            onboardingActionsRan = true
            Task { [weak self] in await self?.runOnboardingDebugActions(presenter) }
        }
        #endif
    }

    // MARK: OnboardingHost

    func onboardingProbe() async -> OnboardingProbeResult {
        let clock = ContinuousClock()
        let started = clock.now
        let checkedAt = Date()
        let home = NSHomeDirectory()
        guard let holders = holderStore else {
            // Mock mode draws the samples and never probes; a result keeps the type total.
            return OnboardingProbeResult(facts: OnboardingSamples.facts(), catalog: .empty, existingGroups: [], notesPath: "")
        }
        // The sessions first: the projects already in CODD, the groups and the hook endpoint.
        let deadline = clock.now + .seconds(10)
        while !holders.isLoaded, clock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        let standard = holders.root == .standard
        let claudeTask = Task { [weak self] () -> EnvironmentFacts.Claude in
            await self?.probeClaude(standardRoot: standard) ?? .missing
        }
        // cswap's first read (joins the one real mode started), the settings inspection and the
        // registration state, each the services' own (their I/O runs off the main actor).
        await cswapAccounts?.start()
        await claudeSettings?.refreshInspection(force: true)
        await mcpService?.refreshRegistrations()
        let rootPath = holders.root.path
        let claudeDir = URL(fileURLWithPath: holders.claudeDirectory.path, isDirectory: true)
        let existing = OnboardingFacts.projectPaths(sessionStore)
        let protected = OnboardingFacts.catalogIsProtected(standardRoot: standard, claudeDirectory: claudeDir.path)
        let (writable, catalog) = await Task.detached(priority: .userInitiated) { () -> (Bool, ProjectCatalog) in
            (OnboardingFacts.isWritable(rootPath),
             protected ? OnboardingFacts.protectedCatalog
                : ProjectCatalogReader.read(claudeDirectory: claudeDir, home: home, existingProjectPaths: existing))
        }.value
        if protected { HolderSessionStore.printLog("onboarding catalog skipped reason=protected-claude-dir") }
        let claude = await claudeTask.value
        let (cswap, rows) = cswapAccounts.map(Self.onboardingAccounts) ?? (.missing, [])
        let inspection = claudeSettings?.inspection ?? .unknown
        let settingsFile = claudeSettings?.settingsURL.path ?? holders.claudeSettingsURL.path
        let port = mcpService?.port
        let running = mcpService?.running ?? false
        let expectedSource = standard ? "~/.claude.json"
            : PathText.abbreviate(PathText.parent(PathText.standardize(claudeDir.path)) + "/.claude.json", home: home)
        let registration = onboardingRegistrationFacts()
        let listening = holders.hooks?.status.isListening ?? false
        let ms = Int(((clock.now - started) / .milliseconds(1)).rounded())
        let facts = EnvironmentFacts(claude: claude, cswap: cswap, hooks: OnboardingFacts.hooks(inspection, file: settingsFile),
                                     dataRoot: .init(path: rootPath, writable: writable, mcpEndpoint: port.map { "127.0.0.1:\($0)" },
                                                     mcpRunning: running),
                                     checkedAt: checkedAt, milliseconds: ms, projects: OnboardingFacts.projects(catalog, expectedSource: expectedSource))
        HolderSessionStore.printLog("onboarding probe ms=\(ms) claude=\(Self.dumpName(claude)) cswap=\(Self.dumpName(cswap)) "
                                    + "hooks=\(Self.dumpName(facts.hooks)) writable=\(writable) mcp=\(running) "
                                    + "candidates=\(catalog.candidates.count) already=\(catalog.alreadyInCODD)")
        return OnboardingProbeResult(facts: facts, catalog: catalog, existingGroups: OnboardingFacts.existingGroups(sessionStore),
                                     statusline: OnboardingFacts.statusline(inspection), foreign: OnboardingFacts.foreign(inspection),
                                     sessionHooksInstalled: listening ? 14 : 0, sessionHooksTotal: 14,
                                     webLeftovers: OnboardingFacts.webLeftovers(inspection),
                                     notesPath: PathText.abbreviate(notes.notesRoot.path, home: home),
                                     claudeCodeRegistered: registration.registered, claudeCodeReason: registration.reason,
                                     codexAvailable: registration.codex, accountRows: rows)
    }

    /// `claude --version` (D5, M3 D3 / D28): the DEBUG `-codd-claude-path` one on any root; on the
    /// standard root the user's claude found through the login shell's PATH (the launch-time
    /// VersionProbe misses one outside `~/.local/bin`). Any other root never searches the PATH.
    private func probeClaude(standardRoot: Bool) async -> EnvironmentFacts.Claude {
        let override = realOptions.claudePath
        let loginPATH = standardRoot && override == nil ? await LoginEnvironment.current()?["PATH"] : nil
        let path = Self.claudeExecutable(override: override, standardRoot: standardRoot, loginPATH: loginPATH)
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            HolderSessionStore.printLog("onboarding claude missing path=\(path.map(HolderSessionStore.abbreviate) ?? "-")")
            return .missing
        }
        // VersionProbe's rules: absolute path only, 5 s timeout, `exec claude path=… sub=--version`.
        let probe = VersionProbe(claudeExecutable: path, log: { HolderSessionStore.printLog($0) })
        await probe.refreshClaude()
        return OnboardingFacts.claude(path: path, isExecutable: true, version: probe.claudeVersion)
    }

    /// cswap's availability and its accounts (R7 order, aliases only).
    static func onboardingAccounts(_ accounts: CswapAccountStore) -> (EnvironmentFacts.Cswap, [AccountsStepModel.Row]) {
        let list = accounts.accounts.filter { !$0.isPseudo }
        let cswap = OnboardingFacts.cswap(base: accounts.baseAvailability, version: accounts.cswapVersion?.description,
                                          path: accounts.location.executable, accounts: list.count)
        let rows = accounts.baseAvailability.isReady ? OnboardingFacts.accountRows(list, activeID: accounts.activeAccountID, now: Date()) : []
        return (cswap, rows)
    }

    /// Step 4's CLAUDE CODE row: nil when this root cannot register (M4 D22: a test root without
    /// DEBUG `-codd-claude-json`), with its reason.
    func onboardingRegistrationFacts() -> (registered: Bool?, reason: String?, codex: Bool) {
        guard let registration = mcpRegistration else { return (nil, "mock 模式不會註冊", false) }
        let codex = registration.codexReason == nil
        if let reason = registration.target.disabledReason { return (nil, reason, codex) }
        switch mcpService?.claudeCode ?? .unknown {
        case .registered: return (true, nil, codex)
        case .notRegistered, .unknown: return (false, nil, codex)
        case .unavailable(let reason): return (nil, reason, codex)
        }
    }

    func onboardingExistingGroups() -> [ExistingGroup] {
        OnboardingFacts.existingGroups(sessionStore)
    }

    func onboardingApply(_ plan: ImportPlan) -> OnboardingImport.Outcome {
        let outcome = OnboardingImport.apply(plan, to: sessionStore)
        mainWindow?.sidebar.applyNow()
        #if DEBUG
        scheduleStateDump()
        #endif
        return outcome
    }

    func onboardingPreviewHooks(on window: NSWindow?) {
        onboardingHooksBaseline = claudeSettings?.lastApplied?.at
        presentHookDiff(.update, on: window)
    }

    /// Dialog B closed: step 3 follows what it wrote (the installer inspected the file again).
    func onboardingHooksDialogFinished() {
        guard let controller = onboarding?.controller, let service = claudeSettings else { return }
        let last = service.lastApplied
        let applied = last != nil && last?.at != onboardingHooksBaseline
        let inspection = service.inspection
        controller.updateHooks(OnboardingFacts.hooks(inspection, file: service.settingsURL.path), statusline: OnboardingFacts.statusline(inspection),
                               foreign: OnboardingFacts.foreign(inspection), webLeftovers: OnboardingFacts.webLeftovers(inspection),
                               applied: applied, backup: applied ? last?.backup : nil)
        onboardingHooksBaseline = last?.at
    }

    func onboardingRevealNotes() {
        revealNotesFolder()
    }

    func onboardingRegisterClaudeCode(on window: NSWindow?) {
        mcpRegistrationPressed("claude-code", on: window)
    }

    /// The registration dialog closed: step 4's rows again.
    func refreshOnboardingRegistration() {
        guard let controller = onboarding?.controller else { return }
        let facts = onboardingRegistrationFacts()
        controller.updateRegistration(registered: facts.registered, reason: facts.reason, codexAvailable: facts.codex)
    }

    func onboardingCopyCodexSnippet(on window: NSWindow?) {
        presentCodexSnippet(on: window)
    }

    func onboardingAddAccount() {
        presentAddAccount()
    }

    func onboardingRequestNotifications() async -> DoneStepModel.Notifications {
        guard let notifier else {
            // Mock mode posts nothing (and asks nothing).
            notificationLog.record(kind: "permission", title: SessionNotifier.permissionTitle, suppressed: true)
            return .suppressed
        }
        switch await notifier.requestAuthorizationNow() {
        case .granted: return .granted
        case .denied: return .denied
        case .suppressed: return .suppressed
        }
    }

    func onboardingEnded(firstProject: ProjectID?) {
        onboarding?.closeAfterEnding()
        onboarding = nil
        onboardingLoops.forEach { $0.cancel() }
        onboardingLoops.removeAll()
        showMainWindow(nil)
        if let firstProject { mainWindow?.sidebar.revealProjects([firstProject]) }
        #if DEBUG
        scheduleStateDump()
        #endif
    }

    func onboardingLog(_ line: String) {
        HolderSessionStore.printLog(line)
    }

    /// `applicationWillTerminate`: a window closing during the quit is not an ending (D7).
    func onboardingWillTerminate() {
        onboarding?.appWillTerminate()
        onboardingLoops.forEach { $0.cancel() }
        onboardingLoops.removeAll()
    }

    // MARK: Dump (§5)

    /// `onboarding {shown, reason, step, steps, boot, import, applied, hooks, notebook, accounts,
    /// notifications, completedAt, file}`: never an e-mail (aliases only), never a token.
    var onboardingDump: [String: Any] {
        guard let controller = onboarding?.controller ?? lastOnboarding else {
            return ["shown": false, "reason": onboardingLaunch.reason, "completedAt": NSNull(), "file": NSNull()]
        }
        var object: [String: Any] = [
            "shown": onboarding?.window?.isVisible == true,
            "reason": controller.reason,
            "source": controller.source == .mock ? "mock" : "live",
            "step": controller.flow.current.rawValue,
            "applied": ["projects": controller.importedProjects, "groups": controller.importedGroups],
            "notifications": controller.notifications.rawValue,
            "completedAt": controller.endedState.map { ISO8601DateFormatter().string(from: $0.completedAt) as Any } ?? NSNull(),
            "file": controller.savedFile.map { $0 as Any } ?? NSNull(),
            "probes": controller.probeCount,
        ]
        guard let model = controller.model else { return object }
        object["steps"] = OnboardingStep.allCases.map { step -> [String: Any] in
            let state = model.flow.progress[step] ?? .todo
            let detail = state == .skipped ? OnboardingViewModel.skippedDetail : (model.stepDetails[step] ?? "")
            return ["id": step.id, "state": state.rawValue, "detail": detail]
        }
        object["boot"] = model.boot.lines.map { ["tag": $0.tag.rawValue, "name": $0.name, "value": $0.value, "detail": $0.detail] }
        object["bootHeader"] = model.boot.header
        let step = model.importStep
        let catalog = step.catalog
        let visible = step.selection.visible(in: catalog)
        let iso = ISO8601DateFormatter()
        object["import"] = [
            "source": catalog.source.map { $0 as Any } ?? NSNull(),
            "problem": catalog.problem.map { $0 as Any } ?? NSNull(),
            "total": catalog.visibleTotal, "hidden": catalog.hiddenCount, "already": catalog.alreadyInCODD,
            "checked": step.checkedCount, "visible": visible.count, "filter": step.selection.filter,
            "showHidden": step.selection.showHidden, "summary": step.summary,
            "rows": catalog.candidates.prefix(200).map { candidate -> [String: Any] in
                ["path": candidate.path, "name": candidate.name, "prefix": candidate.prefix.map { $0 as Any } ?? NSNull(),
                 "lastUsed": candidate.lastUsed.map { iso.string(from: $0) as Any } ?? NSNull(), "transcripts": candidate.transcripts,
                 "hidden": candidate.hidden?.rawValue ?? "none", "checked": step.selection.checked.contains(candidate.path),
                 "group": step.selection.groupKey(for: candidate.path), "suggestion": step.suggestion[candidate.path] ?? GroupOption.ungroupedKey]
            },
            "options": step.options.map { option -> [String: Any] in
                let kind: String = switch option.kind {
                case .existing: "existing"
                case .new: "new"
                case .ungrouped: "ungrouped"
                }
                return ["key": option.key, "name": option.name, "color": option.color.map { $0 as Any } ?? NSNull(), "kind": kind]
            },
        ] as [String: Any]
        object["hooks"] = ["pending": model.hooks.pending, "applied": controller.hooksApplied,
                           "backup": controller.appliedBackup.map { $0 as Any } ?? NSNull(),
                           "rows": model.hooks.rows.map { "\($0.label) \($0.state)" }, "webLink": model.showsWebImportLink]
        object["notebook"] = ["path": model.notebook.notesPath, "mcp": model.notebook.mcpLine, "mcpRunning": model.notebook.mcpRunning,
                              "claudeCode": model.notebook.claudeCodeState, "canRegister": model.notebook.claudeCodeButton != nil,
                              "codex": model.notebook.codexAvailable]
        let availability: String = controller.probe.map { Self.dumpName($0.facts.cswap) } ?? (controller.source == .mock ? "mock" : "unknown")
        object["accounts"] = ["availability": availability, "note": model.accounts.availabilityNote.map { $0 as Any } ?? NSNull(),
                              "rows": model.accounts.rows.map { ["slot": $0.slot, "alias": $0.alias, "active": $0.active] as [String: Any] }]
        object["done"] = model.done.summary.map { "\($0.tag.label) \($0.name) \($0.value)" }
        object["versionLine"] = model.versionLine
        return object
    }

    static func dumpName(_ claude: EnvironmentFacts.Claude) -> String {
        switch claude {
        case .found: "found"
        case .missing: "missing"
        case .failed: "failed"
        }
    }

    static func dumpName(_ cswap: EnvironmentFacts.Cswap) -> String {
        switch cswap {
        case .ready: "ready"
        case .missing: "missing"
        case .unsupported: "unsupported"
        case .unreadable: "unreadable"
        case .loading: "loading"
        }
    }

    static func dumpName(_ hooks: EnvironmentFacts.Hooks) -> String {
        switch hooks {
        case .upToDate: "upToDate"
        case .legacy: "legacy"
        case .statuslineOutdated: "statuslineOutdated"
        case .unreadable: "unreadable"
        case .unknown: "unknown"
        }
    }

    #if DEBUG
    // MARK: DEBUG (§5)

    /// `-codd-snapshot` with the wizard open: `<stem>-onboarding.png`, and with
    /// `-codd-show onboarding:all` `<stem>-onboarding-<n>.png` for steps 1–6.
    func writeOnboardingSnapshots(stem: String) async {
        guard let presenter = onboarding, let window = presenter.window, let view = presenter.windowController?.onboardingView else { return }
        DebugHooks.write(window, to: URL(fileURLWithPath: stem + "-onboarding.png"))
        guard onboardingLaunch.snapshotsAllSteps else { return }
        for step in OnboardingStep.allCases {
            guard let model = presenter.controller.snapshotModel(for: step) else { continue }
            view.update(model)
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(120))
            DebugHooks.write(window, to: URL(fileURLWithPath: stem + "-onboarding-\(step.rawValue).png"))
        }
        if let model = presenter.controller.model { view.update(model) }
        HolderSessionStore.printLog("debug onboarding snapshots steps=\(OnboardingStep.allCases.count)")
    }

    /// `-codd-onboarding-actions`: each entry once the wizard shows, in order, as the button would.
    func runOnboardingDebugActions(_ presenter: OnboardingPresenter) async {
        for raw in realOptions.onboardingActions {
            let action = OnboardingDebugAction(raw)
            try? await Task.sleep(for: .milliseconds(150))
            let ok = await performOnboardingAction(action, presenter: presenter)
            let argument = action.argument.map { " arg=\($0)" } ?? ""
            HolderSessionStore.printLog("onboarding action=\(action.name) step=\(presenter.controller.flow.current.rawValue) ok=\(ok)\(argument)")
            scheduleStateDump()
        }
    }

    private func performOnboardingAction(_ action: OnboardingDebugAction, presenter: OnboardingPresenter) async -> Bool {
        let controller = presenter.controller
        guard !controller.hasEnded else { return false }
        let step = controller.importStep
        let selection = step.selection
        func path(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return nil }
            return HolderSessionStore.standardize(PathFormat.expandTilde(text))
        }
        switch action.name {
        case "redetect":
            await controller.redetect()
            return true
        case "next":
            controller.next()
            return true
        case "skip":
            controller.skip()
            return true
        case "back":
            let before = controller.flow.current
            controller.back()
            return controller.flow.current != before
        case "goto":
            guard let number = action.argument.flatMap(Int.init), let target = OnboardingStep(rawValue: number) else { return false }
            controller.go(to: target)
            return controller.flow.current == target
        case "filter":
            controller.importChanged(selection.filtering(action.argument ?? ""))
            return true
        case "check", "uncheck":
            guard let target = path(action.argument), step.catalog.candidate(target) != nil else { return false }
            controller.importChanged(selection.setting([target], checked: action.name == "check"))
            return true
        case "check-visible":
            controller.importChanged(selection.setting(selection.visible(in: step.catalog).map(\.path), checked: true))
            return true
        case "suggest":
            HolderSessionStore.printLog("onboarding suggest")
            controller.applySuggestions()
            return true
        case "group":
            guard let pair = action.pathAndValue, let target = path(pair.path), step.catalog.candidate(target) != nil,
                  step.options.contains(where: { $0.key == pair.value }) || selection.newGroups.contains(where: { $0.key == pair.value })
            else { return false }
            controller.importChanged(selection.assigning(pair.value, to: target))
            return true
        case "new-group":
            guard let pair = action.pathAndValue, let target = path(pair.path), step.catalog.candidate(target) != nil else { return false }
            let made = selection.addingGroup(named: pair.value, for: target, catalog: step.catalog, options: step.options)
            HolderSessionStore.printLog("onboarding new-group name=\(made.group.name) key=\(made.group.key)")
            controller.importChanged(made.selection)
            return true
        case "show-hidden":
            controller.importChanged(selection.togglingHidden())
            return true
        case "more":
            controller.importChanged(selection.loadingMore())
            return true
        case "hooks-preview":
            guard let service = claudeSettings else { return false }
            await service.refreshInspection(force: true)
            let plan = await service.plan(.update)
            HolderSessionStore.printLog("onboarding hooks-preview changes=\(plan.successValue?.changes ?? false) "
                                        + "+\(plan.successValue?.addedLines ?? 0) -\(plan.successValue?.removedLines ?? 0)")
            return plan.successValue != nil
        case "hooks-apply":
            guard let service = claudeSettings else { return false }
            let allowed = ClaudeSettingsService.isDebugApplyAllowed(target: service.settingsURL, claudeDirGiven: realOptions.claudeDir != nil,
                                                                     settingsGiven: realOptions.claudeSettings != nil)
            guard allowed.allowed else {
                HolderSessionStore.printLog("onboarding hooks-apply refused (\(allowed.reason))")
                return false
            }
            onboardingHooksBaseline = service.lastApplied?.at
            guard let plan = await service.plan(.update).successValue else { return false }
            let result = await service.apply(plan)
            service.flushIndex()
            onboardingHooksDialogFinished()
            return result.successValue != nil
        case "reveal-notes":
            onboardingRevealNotes()
            return true
        case "mcp-preview":
            guard let registration = mcpRegistration, registration.target.file != nil else {
                HolderSessionStore.printLog("onboarding mcp-preview refused (\(mcpRegistration?.target.disabledReason ?? "no registration"))")
                return false
            }
            let plan = await registration.plan(.register)
            return plan.successValue != nil
        case "notify":
            await controller.requestNotifications()
            return controller.notifications != .asking
        case "finish":
            controller.finish(.done)
            return controller.hasEnded
        case "close":
            presenter.window?.performClose(nil)
            return controller.hasEnded
        default:
            HolderSessionStore.printLog("onboarding action unknown=\(action.name)")
            return false
        }
    }
    #endif
}
