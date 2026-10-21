import CoddCore
import CoddHolderClient
import CoddHooks
import Foundation

/// Starting, resuming, restarting and removing sessions.
extension HolderSessionStore {
    /// Starts a session (a new holder) for `request`: the project of its folder is created when
    /// new. Returns the session id, or nil when refused (still loading, no holder binary, the
    /// folder does not exist).
    @discardableResult
    func createSession(_ request: NewSessionRequest) -> SessionID? {
        // What `refuse` keeps is shown in the sheet: 繁體中文 (UI copy rule); the log line keeps
        // the technical cause.
        lastRefusal = nil
        guard isLoaded else {
            refuse("還在讀取 session，請稍候再試一次。", detail: "sessions are still loading")
            return nil
        }
        guard let launcher else {
            refuse("CODD.app 裡沒有 codd-holder，無法開始 session。請重新安裝 CODD。",
                   detail: "codd-holder is missing from the app bundle")
            return nil
        }
        let cwd = Self.standardize(request.cwd)
        guard Self.isFolder(cwd) else {
            refuse(Self.missingFolderMessage(cwd))
            return nil
        }
        let kind = request.kind
        // A model claude cannot take would leave a saved session that never launches (RESUME and
        // RESTART reuse it): refused before anything is written.
        if kind == .claude, !LaunchProfileEditing.isValidModel(request.claude.model) {
            refuse(NewSessionForm.invalidModelMessage(request.claude.model ?? ""), detail: "invalid model \(request.claude.model ?? "")")
            return nil
        }
        // Only a new conversation or one picked from the transcripts (D18) starts from a request;
        // RESTART belongs to an existing session.
        var resumeID: String?
        switch request.claude.mode {
        case .new:
            break
        case .resume(let claudeID):
            guard kind == .claude, Self.isValidClaudeSessionID(claudeID) else {
                refuse("無法接續這段對話：對話紀錄的 id 不正確。", detail: "resume request with an invalid id \(claudeID)")
                return nil
            }
            // One conversation, one CODD session (review correctness-2): a stopped session that
            // already has it resumes instead of getting a twin; a running claude keeps it.
            if let owner = sessionOwning(claudeID) {
                if archivedByID[owner.id] != nil {
                    refuse("這段對話屬於已封存的 session「\(owner.title)」，請先從封存還原它再接續。",
                           detail: "resume request for \(claudeID): archived session \(owner.id) has it")
                    return nil
                }
                guard !owner.state.isLive else {
                    refuse("這段對話正在 CODD 的 session「\(owner.title)」執行。", detail: "resume request for \(claudeID): \(owner.id) runs it")
                    return nil
                }
                if isConversationRunning(claudeID, except: owner.id) {
                    refuse(Self.conversationRunningMessage, detail: "resume request for \(claudeID): a live claude runs it")
                    return nil
                }
                log("resume request for \(claudeID): resuming its session \(owner.id)")
                resume(owner.id)
                return owner.id
            }
            if isConversationRunning(claudeID) {
                refuse(Self.conversationRunningMessage, detail: "resume request for \(claudeID): a live claude runs it")
                return nil
            }
            resumeID = claudeID
        case .restart:
            refuse("新的 session 不能用「重新開始」啟動。", detail: "restart mode in a new-session request")
            return nil
        }
        // D12: a pinned account needs a usable cswap session profile, checked before anything is
        // written (its path never reaches a message or a log).
        var pinnedDir: String?
        if kind == .claude, let n = request.claude.accountNumber {
            switch pinnedConfigDir(account: n, relaunch: false) {
            case .success(let dir): pinnedDir = dir
            case .failure(let refusal):
                refuse(refusal.message, detail: "pin to account #\(n) refused")
                return nil
            }
        }
        let uuid = chooseSessionID(request.sessionID)
        let id = LayoutMapping.id(uuid)
        guard let socket = root.socketPath(for: id) else {
            let error = HolderStartError.socketPathTooLong(root.runPath)
            refuse(error.userMessage, detail: error.description)
            return nil
        }
        // D6: a CODD session never lands in a project that is not saved.
        let existing = project(forPath: cwd)
        if let existing { promoteTransient(existing, into: request.groupID) }
        let project = existing ?? addProjectVM(path: cwd, groupID: request.groupID)
        guard let projectUUID = UUID(uuidString: project.id) else { return nil }
        let name = LaunchNames.clean(request.name)
        var options = request.claude
        options.mode = resumeID.map { .resume($0) } ?? .new
        options.name = name
        // D5: the record keeps the profile that actually runs (the default when none was named).
        let profileID: String
        switch kind {
        case .claude:
            profileID = profiles.document.claudeProfile(id: options.profileID).id
            options.profileID = profileID
        case .shell:
            profileID = profiles.document.shellProfile.id
        }
        // D12: CODD's own pin, else the account a launch profile's CLAUDE_CONFIG_DIR belongs to.
        var accountNumber: Int?
        if kind == .claude {
            if let pinnedDir, let n = request.claude.accountNumber {
                options.claudeConfigDir = pinnedDir
                accountNumber = n
            } else if let dir = launchProfileConfigDir(profileID) {
                accountNumber = accountForConfigDir?(dir)
            }
        }
        options.accountNumber = nil
        let coddCount = project.sessionIDs.filter { sessionsByID[$0] != nil }.count
        var record = LayoutSessionRecord(
            id: uuid, claudeSessionId: kind == .claude ? (resumeID ?? id) : nil, projectId: projectUUID,
            kind: kind == .claude ? .claude : .shell, titleOverride: name, color: LayoutMapping.color(request.tag), order: coddCount,
            createdAt: clock.now(), holderSocket: socket, launchProfileId: profileID,
            model: options.model, permissionMode: options.permissionMode, accountNumber: accountNumber)
        if resumeID != nil, name == nil, let title = JSText.nonBlankTrimmed(request.resumeTitle) { record.title = String(title.prefix(120)) }
        records[id] = record
        let fallback = kind == .shell ? Self.displayTitle(nil, argv: launcher.shellArgvOverride ?? []) : "claude"
        let session = SessionVM(id: id, projectID: project.id, kind: kind, title: record.displayTitle(fallback: fallback),
                                state: .starting, stateSince: clock.now())
        session.tag = request.tag
        session.claudeSessionID = record.claudeSessionId
        if kind == .shell { session.detail = Self.abbreviate(cwd) }
        runtimes[id] = HolderRuntime(directory: root.sessionDirectory(id), socketPath: socket, cwd: cwd)
        sessionsByID[id] = session
        applyAccount(to: session)
        if let accountNumber { log("pinned session=\(id) account=#\(accountNumber)") }
        insertCODDSession(id, in: project)
        transcriptsGeneration += 1
        scheduleLayoutSave()
        scheduleExternalRefresh()
        if let resumeID, record.titleOverride == nil, record.title == nil { adoptTranscriptTitle(id, claudeID: resumeID, cwd: cwd) }
        if kind == .claude, let engine = hooks?.engine {
            let registration = registration(id, uuid: uuid, process: .running(startedAt: clock.now()), fresh: true)
            Task { await engine.register(registration) }
        }
        launch(id, uuid: uuid, cwd: cwd, socketPath: socket, kind: kind, options: options, launcher: launcher, previousHolder: nil)
        return id
    }

    /// Starts a shell session in `cwd` (tests, DEBUG launch options, the menu bar).
    @discardableResult
    func spawnShell(in cwd: String) -> SessionID? {
        createSession(NewSessionRequest(cwd: cwd, kind: .shell))
    }

    /// RESUME: claude continues its conversation (`--resume` the latest Claude session id hooks
    /// reported); a shell starts again. Refused while another claude runs that conversation
    /// (Terminal.app, a twin CODD session): two processes would append to one transcript. Before
    /// the first registry snapshot it waits for it (at most 2 s).
    func resume(_ id: SessionID) {
        guard let session = sessionsByID[id], !session.state.isLive else { return }
        guard session.kind == .claude else { restart(id); return }
        guard registrySeen || hooks == nil else {
            Task { [weak self] in
                _ = await self?.waitForRegistry()
                self?.resumeChecked(id)
            }
            return
        }
        resumeChecked(id)
    }

    private func resumeChecked(_ id: SessionID) {
        guard let session = sessionsByID[id], !session.state.isLive, session.kind == .claude else { return }
        let claudeID = records[id]?.claudeSessionId ?? id
        if isConversationRunning(claudeID, except: id) {
            report(Self.conversationRunningMessage, detail: "resume session=\(id) refused: \(claudeID) is in use", sessionID: id)
            return
        }
        var options = launchOptions(id)
        options.mode = .resume(claudeID)
        switch relaunchConfigDir(for: id) {
        case .success(let dir): options.claudeConfigDir = dir
        case .failure(let refusal):
            report(refusal.message, detail: "resume session=\(id) refused: its pinned account's profile is not usable", sessionID: id)
            return
        }
        transcriptsGeneration += 1
        relaunch(id, options: options)
    }

    nonisolated static let conversationRunningMessage = "這段對話正在另一個 claude 執行（例如 Terminal.app 或另一個 session），不能再接續一次。"

    /// The CODD session (archived included) whose conversation is `claudeID` now.
    func sessionOwning(_ claudeID: String) -> SessionVM? {
        for (id, record) in records where record.kind == .claude && record.claudeSessionId == claudeID {
            if let session = sessionsByID[id] ?? archivedByID[id] { return session }
        }
        return (sessionsByID.values.map { $0 } + archivedByID.values.map { $0 })
            .first { $0.kind == .claude && $0.claudeSessionID == claudeID }
    }

    /// RESTART: claude starts a new conversation in the same CODD session; a shell starts again.
    /// A running process is ended first (the menu item says 新對話; the old holder holds the
    /// session directory's ring).
    func restart(_ id: SessionID) {
        guard let session = sessionsByID[id], session.state != .starting else { return }
        var options = launchOptions(id)
        if session.kind == .claude {
            switch relaunchConfigDir(for: id) {
            case .success(let dir): options.claudeConfigDir = dir
            case .failure(let refusal):
                report(refusal.message, detail: "restart session=\(id) refused: its pinned account's profile is not usable", sessionID: id)
                return
            }
            let fresh = UUID()
            options.mode = .restart(fresh)
            records[id]?.claudeSessionId = LayoutMapping.id(fresh)
            session.claudeSessionID = LayoutMapping.id(fresh)
            scheduleLayoutSave()
        }
        relaunch(id, options: options)
    }

    /// The options a session was first started with (a profile that is gone falls back to the
    /// default at launch).
    func launchOptions(_ id: SessionID) -> ClaudeLaunchOptions {
        let record = records[id]
        return ClaudeLaunchOptions(mode: .new, profileID: record?.launchProfileId, name: record?.titleOverride, model: record?.model,
                                   permissionMode: record?.permissionMode)
    }

    /// The ⌘N preview's id when it is free (no session, layout row, session directory or live
    /// claude has it), else a fresh one.
    func chooseSessionID(_ wanted: UUID?) -> UUID {
        guard let wanted else { return UUID() }
        let id = LayoutMapping.id(wanted)
        let taken = records[id] != nil || sessionsByID[id] != nil || archivedByID[id] != nil || externalByID[id] != nil
            || records.values.contains { $0.claudeSessionId == id } || inUseClaudeSessionIds.contains(id)
            || FileManager.default.fileExists(atPath: root.sessionDirectory(id))
        guard taken else { return wanted }
        log("session id \(id) is taken: using a new one")
        return UUID()
    }

    /// `[A-Za-z0-9-]{1,128}` without a leading `-` (LaunchBuilder's rule for `--resume`).
    nonisolated static func isValidClaudeSessionID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && !id.hasPrefix("-") && id.utf8.allSatisfy {
            $0 == 0x2D || (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
        }
    }

    /// A resumed conversation without a name takes its transcript's title (custom > AI > first
    /// prompt), read off the main actor; a title learned meanwhile is kept.
    private func adoptTranscriptTitle(_ id: SessionID, claudeID: String, cwd: String) {
        let catalog = transcriptCatalog(for: id)
        Task { [weak self] in
            let title = await Task.detached(priority: .utility) { () -> String? in
                // By id, not from the newest 50: an older conversation keeps its title too (review e2e-1).
                guard let summary = catalog.transcript(sessionId: claudeID, cwd: cwd), summary.titleSource != .none else {
                    return nil
                }
                return summary.title
            }.value
            guard let self, let title, var record = self.records[id], record.titleOverride == nil, record.title == nil else { return }
            record.title = String(title.prefix(120))
            self.records[id] = record
            (self.sessionsByID[id] ?? self.archivedByID[id])?.title = record.displayTitle(fallback: "claude")
            self.scheduleLayoutSave()
        }
    }

    /// A new holder in the session's own directory (the ring continues). The old holder, if it
    /// still lingers after its child's exit, is ended first: it holds the ring's lock.
    private func relaunch(_ id: SessionID, options: ClaudeLaunchOptions) {
        guard let launcher, let session = sessionsByID[id], let runtime = runtimes[id], let uuid = UUID(uuidString: id) else { return }
        // The holder would fail its chdir and the session end as `EXITED · code 126` with a
        // message about the program (review E2E-6); say what is wrong instead.
        guard Self.isFolder(runtime.cwd) else {
            // The session's own banner shows it (launchError).
            session.launchError = Self.missingFolderMessage(runtime.cwd)
            report(Self.missingFolderMessage(runtime.cwd), detail: "session \(id): cwd \(runtime.cwd) is gone", surface: false,
                   sessionID: id)
            return
        }
        stopRequested.remove(id)
        pendingStops.remove(id)
        transition(session, to: .starting)
        setUnreachable(session, since: nil)
        session.exitCode = nil
        session.launchError = nil
        session.startedAt = nil
        let previous = runtime.holderPid
        runtime.connection?.quiesce()
        runtimes[id]?.holderAlive = false
        runtimes[id]?.childExited = false
        if session.kind == .claude, let engine = hooks?.engine {
            var claudeID: String?
            switch options.mode {
            case .resume(let resumed): claudeID = resumed
            case .restart(let fresh): claudeID = LayoutMapping.id(fresh)
            case .new: claudeID = records[id]?.claudeSessionId
            }
            let now = clock.now()
            Task { await engine.claudeProcessStarted(uuid, pid: nil, startedAt: now, claudeSessionId: claudeID) }
        }
        launch(id, uuid: uuid, cwd: runtime.cwd, socketPath: runtime.socketPath, kind: session.kind, options: options,
               launcher: launcher, previousHolder: previous)
    }

    /// The terminal first (probe rule), then the login environment and the hook settings, then
    /// the holder (off the main actor: file I/O and up to 3 s waiting for its socket).
    func launch(_ id: SessionID, uuid: UUID, cwd: String, socketPath: String, kind: SessionKind,
                        options: ClaudeLaunchOptions, launcher: HolderLauncher, previousHolder: pid_t?) {
        prepareTerminal?(id)
        launchesInFlight.insert(id)
        Task { [weak self] in
            let login = await LoginEnvironment.current()
            guard let self else { return }
            var hookSetup: (settings: ClaudeHookSettings, token: String)?
            if kind == .claude, let hooks = self.hooks {
                // Without the embedded codd-hook only SessionStart is lost (the rest are http hooks).
                hookSetup = await hooks.launchSettings(coddHook: launcher.coddHookPath ?? "/usr/bin/true")
                // D8: CODD's status line with the user's own chained (D35, read now: RESUME and
                // RESTART pick up a changed one). Like hooks, never while the endpoint is not ours.
                if hookSetup != nil, let command = launcher.coddStatusLinePath {
                    let settings = self.claudeSettingsURL
                    let injection = await Task.detached(priority: .userInitiated) {
                        HolderLauncher.statusLineInjection(command: command, cwd: cwd, userSettings: settings)
                    }.value
                    hookSetup?.settings.statusLine = injection
                    self.log("statusline session=\(id) chain=\(injection.chainCommand == nil ? "no" : "yes") "
                             + "extras=\(injection.extras.keys.sorted().joined(separator: ",").nilIfEmpty ?? "-")")
                }
            }
            // D18: CODD's MCP server for this session (only with hooks and the M4 routes on the
            // endpoint: it lives on the hook port).
            var mcpConfig: MCPLaunchConfig?
            if kind == .claude, var setup = hookSetup {
                if self.autoAttachMCP, self.hooks?.routesInstalled == true {
                    let decision = await self.mcpDecision(id, uuid: uuid, cwd: cwd, options: options, setup: &setup.settings,
                                                          token: setup.token)
                    mcpConfig = decision.config
                    self.mcpSessionConfigs[id] = decision.record
                    hookSetup = setup
                } else {
                    self.mcpSessionConfigs[id] = nil
                }
            }
            let plan: HolderStartPlan
            do throws(HolderStartError) {
                switch kind {
                case .claude:
                    plan = try launcher.planClaude(sessionID: uuid, cwd: cwd, options: options, hooks: hookSetup, mcp: mcpConfig,
                                                   socketPath: socketPath, loginEnvironment: login, grid: self.terminalGrid?())
                case .shell:
                    plan = try launcher.plan(sessionID: uuid, cwd: cwd, socketPath: socketPath, loginEnvironment: login,
                                             grid: self.terminalGrid?())
                }
            } catch {
                self.launched(id, result: .failure(error), socketPath: socketPath, argv: [])
                return
            }
            let result = await Task.detached(priority: .userInitiated) { () async -> Result<pid_t, HolderStartError> in
                // Test seam (D20 regression test): holds the spawn without a sleep race.
                if let gate = launcher.beforeStart { await gate() }
                if let previousHolder { Self.terminateHolder(previousHolder, wait: true) }
                do throws(HolderStartError) {
                    return .success(try launcher.start(plan))
                } catch {
                    return .failure(error)
                }
            }.value
            self.launched(id, result: result, socketPath: socketPath, argv: plan.argv)
        }
    }

    /// D18 for one launch: the global config this session's claude reads (a pinned session's or
    /// a launch profile's `CLAUDE_CONFIG_DIR`, else `<claudeDir>/../.claude.json`; on a test data
    /// root never one inside the real home), the name, the prompt route and the allow rules. Logs
    /// the server name and whether a file was written, never a path of the global config.
    func mcpDecision(_ id: SessionID, uuid: UUID, cwd: String, options: ClaudeLaunchOptions, setup: inout ClaudeHookSettings,
                     token: String) async -> MCPSessionInjection.Decision {
        let configDir = options.claudeConfigDir ?? launchProfileConfigDir(options.profileID)
        let global = MCPSessionInjection.globalConfig(configDir: configDir, claudeDirectory: claudeDirectory)
        let readable = root == .standard || RealModeOptions.protectedPathReason(global.path) == nil
        let decision = await MCPSessionInjection.decide(sessionID: uuid, cwd: cwd, token: token, settings: &setup, globalConfig: global,
                                                        readsGlobalConfig: readable, directory: root.sessionDirectory(id), names: mcpNames)
        if let name = decision.record.serverName {
            log("mcp session=\(id) server=\(name) file=\(HolderLauncher.mcpConfigName) prompt=/hooks/prompt allow=\(setup.permissionsAllow.count)"
                + (readable ? "" : " global-config=skipped"))
        } else {
            log("mcp session=\(id) registered-by-user (no per-session file) prompt=/hooks/prompt")
        }
        return decision
    }

    private func launched(_ id: SessionID, result: Result<pid_t, HolderStartError>, socketPath: String, argv: [String]) {
        launchesInFlight.remove(id)
        guard let session = sessionsByID[id] ?? archivedByID[id] else {
            // Removed while it was starting.
            pendingStops.remove(id)
            if case .success(let pid) = result { Self.terminateHolder(pid) }
            return
        }
        switch result {
        case .success(let pid):
            runtimes[id]?.holderPid = pid
            runtimes[id]?.holderAlive = true
            session.startedAt = clock.now()
            session.launchError = nil
            log("spawned session=\(id) kind=\(session.kind == .claude ? "claude" : "shell") holderPid=\(pid) socket=\(socketPath) "
                + "argv0=\(argv.first ?? "-") resume=\(argv.firstIndex(of: "--resume").map { argv[$0 + 1] } ?? "-")")
            connect(id, freshSpawn: true)
            scheduleExternalRefresh()
            // D20: a stop asked for while it was STARTING goes through the normal path now (the
            // EXIT frame then drives STOPPED / EXITED as for any stop).
            if pendingStops.remove(id) != nil {
                log("stop applied-after-spawn session=\(id) holderPid=\(pid)")
                stop([id])
            }
        case .failure(let error):
            pendingStops.remove(id)
            session.launchError = error.userMessage
            if session.kind == .claude, let engine = hooks?.engine, let uuid = UUID(uuidString: id) {
                let registration = registration(id, uuid: uuid, process: .stopped, fresh: false)
                Task { await engine.register(registration) }
            }
            transition(session, to: session.kind == .claude ? .stopped : .exited)
            // The pane's launch-error banner shows it.
            report(error.userMessage, detail: "session \(id): \(error.description)", surface: false, sessionID: id)
            onStatesChanged?()
        }
    }

    // MARK: - Removing

    /// Removes sessions from CODD: a running one's holder is ended (the caller confirmed), its
    /// directory, hook record and tabs are deleted. Claude's own transcript stays in ~/.claude.
    func removeSessions(_ ids: [SessionID]) {
        for id in ids {
            guard let session = sessionsByID[id] ?? archivedByID[id] else { continue }
            let runtime = runtimes[id]
            let holderPid = session.state.isLive || (runtime?.holderAlive ?? false) ? runtime?.holderPid : nil
            // Before the runtime goes: the hub's eviction finds the connection through it.
            runtime?.connection?.detachEngine()
            runtime?.connection?.close()
            removeFromTree(id)
            pendingStops.remove(id)
            archivedByID[id] = nil
            records[id] = nil
            toolDetails[id] = nil
            persistedDetails[id] = nil
            runtimes[id] = nil
            ephemeral[id] = nil
            mcpSessionConfigs[id] = nil
            if let directory = runtime?.directory { onSessionDeleted?(id, directory) }
            if let engine = hooks?.engine, let uuid = UUID(uuidString: id) {
                Task { await engine.unregister(uuid, deletePersistedState: true) }
            }
            let directory = runtime?.directory
            let socket = runtime?.socketPath
            let sessions = root.sessionsPath + "/"
            let run = root.runPath + "/"
            log("removed session=\(id) holderPid=\(holderPid.map { String($0) } ?? "-")")
            Task.detached(priority: .utility) {
                if let holderPid { Self.terminateHolder(holderPid, wait: true) }
                let manager = FileManager.default
                if let directory, directory.hasPrefix(sessions) { try? manager.removeItem(atPath: directory) }
                if let socket, socket.hasPrefix(run) { try? manager.removeItem(atPath: socket) }
            }
        }
        scheduleLayoutSave()
    }

    /// 刪除對話紀錄… (D23). A claude session that is not running and whose conversation no live
    /// claude uses (`inUseClaudeSessionIds`): `<claudeDir>/projects/<folder>/<id>.jsonl` (only when
    /// its lines carry the session's folder) and its sibling `<id>/` folder, for the current Claude
    /// session id and the CODD id when they differ, go to the Trash through `trash` (off the main
    /// actor), then the session leaves CODD. A file that cannot be moved is a problem and the
    /// session stays. Never anything else: `TranscriptCatalog.files` returns no symlinks and
    /// nothing outside `<claudeDir>/projects`. A shell has no transcript: it just leaves.
    @discardableResult
    func deleteHistory(_ id: SessionID) async -> Bool {
        // The in-use check needs the registry (review e2e-3): before its first snapshot a claude
        // in Terminal.app using this conversation would be invisible.
        guard await waitForRegistry() else {
            report("還在讀取 claude 的 session 清單，請稍候再試一次。", detail: "delete-history session=\(id) refused: no registry snapshot yet",
                   sessionID: id)
            return false
        }
        guard let session = sessionsByID[id] ?? archivedByID[id] else { return false }
        let runtime = runtimes[id]
        guard !session.state.isLive, !(runtime?.holderAlive ?? false) else {
            log("delete-history session=\(id) refused: running")
            return false
        }
        guard session.kind == .claude else {
            log("delete-history session=\(id) files=0 (shell)")
            removeSessions([id])
            return true
        }
        let claudeID = records[id]?.claudeSessionId ?? session.claudeSessionID ?? id
        let ids = claudeID == id ? [id] : [claudeID, id]
        if let busy = ids.first(where: inUseClaudeSessionIds.contains) {
            report("這段對話正被另一個 claude 使用，不能刪除對話紀錄。", detail: "delete-history session=\(id) refused: \(busy) is in use",
                   sessionID: id)
            return false
        }
        guard let cwd = projectsByID[session.projectID]?.cwd ?? runtime?.cwd else { return false }
        let catalog = transcriptCatalog(for: id)
        let trash = self.trash
        let outcome = await Task.detached(priority: .userInitiated) { () -> (moved: Int, failed: [String]) in
            var seen = Set<String>()
            var moved = 0
            var failed: [String] = []
            for claude in ids {
                for url in catalog.files(sessionId: claude, cwd: cwd) where seen.insert(url.path).inserted {
                    do {
                        try trash(url)
                        moved += 1
                    } catch {
                        failed.append("\(url.lastPathComponent) (\(error.localizedDescription))")
                    }
                }
            }
            return (moved, failed)
        }.value
        guard outcome.failed.isEmpty else {
            report("無法把對話紀錄移到垃圾桶：\(outcome.failed.joined(separator: "、"))。session 保留在 CODD。",
                   detail: "delete-history session=\(id) failed: \(outcome.failed.joined(separator: ", "))", sessionID: id)
            return false
        }
        log("delete-history session=\(id) files=\(outcome.moved)")
        transcriptsGeneration += 1
        // It may have been removed while the files moved.
        if sessionsByID[id] != nil || archivedByID[id] != nil { removeSessions([id]) }
        return true
    }

    nonisolated static func isFolder(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    nonisolated static func missingFolderMessage(_ path: String) -> String {
        "找不到資料夾：\(abbreviate(path))。資料夾可能被移動或刪除了。"
    }

    /// SIGTERM to a holder (never to a pid that no longer runs a holder executable); `wait`
    /// blocks up to 3 s for it to exit (call off the main actor then).
    nonisolated static func terminateHolder(_ pid: pid_t, wait: Bool = false) {
        guard pid > 0, SessionDirectory.isHolderProcess(pid) else { return }
        kill(pid, SIGTERM)
        guard wait else { return }
        for _ in 0..<150 where kill(pid, 0) == 0 && SessionDirectory.isHolderProcess(pid) { usleep(20_000) }
    }
}

/// Session names typed by the user.
enum LaunchNames {
    /// Trimmed, control characters dropped, at most 120 characters; blank = nil.
    static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let scalars = name.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let trimmed = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(120))
    }
}

extension String {
    /// nil for an empty string (log formatting).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
