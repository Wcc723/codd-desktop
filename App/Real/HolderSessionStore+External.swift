import CoddCore
import Darwin
import Foundation

/// A cached `realpath` answer (nil: the path did not resolve at `at`).
struct ResolvedPath: Sendable {
    var real: String?
    var at: Date
}

/// A shell tab's holder (`TerminalHub`): a claude started inside it is EXT `在 CODD shell 中`.
struct ShellTabHolder: Equatable, Sendable {
    var sessionID: SessionID
    var tabID: String
    var holderPid: Int
}

/// External sessions (D6, D27), transient projects, stale flags (D15), last prompts (D20) and
/// the transcripts in use (D18).
extension HolderSessionStore {
    // MARK: - Ownership

    /// What this CODD runs, so its own claude processes are never listed as external: the
    /// children of its claude holders, their current and initial Claude session ids, and the
    /// holders of its claude sessions and of its shells (sessions and tabs). A stopped session
    /// counts only while its holder may still run: its conversation resumed by hand in another
    /// terminal is a different process, shown as EXT.
    func ownedProcesses() -> OwnedClaudeProcesses {
        var owned = OwnedClaudeProcesses()
        for (id, session) in sessionsByID.merging(archivedByID, uniquingKeysWith: { a, _ in a }) {
            let runtime = runtimes[id]
            let alive = runtime?.holderAlive ?? false
            switch session.kind {
            case .claude:
                guard alive || session.state.isLive else { continue }
                if alive, !(runtime?.childExited ?? true), let pid = session.pid { owned.claudePids.insert(Int(pid)) }
                owned.claudeSessionIds.insert(id)
                if let current = records[id]?.claudeSessionId { owned.claudeSessionIds.insert(current) }
                if let current = session.claudeSessionID { owned.claudeSessionIds.insert(current) }
                if alive, let holder = runtime?.holderPid { owned.claudeHolderPids.insert(Int(holder)) }
            case .shell:
                if alive, let holder = runtime?.holderPid { owned.shellHolderPids.insert(Int(holder)) }
            }
        }
        for tab in shellTabHolders?() ?? [] { owned.shellHolderPids.insert(tab.holderPid) }
        return owned
    }

    /// Returns once the first registry snapshot was applied, or after `timeout`; true when it was.
    /// Without a hook pipeline no snapshot ever comes (tests apply entries themselves): true.
    func waitForRegistry(timeout: Duration = .seconds(2)) async -> Bool {
        if registrySeen || hooks == nil { return true }
        let token = UUID()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            registryWaiters[token] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.registryWaiters.removeValue(forKey: token)?.resume()
            }
        }
        return registrySeen
    }

    private func markRegistrySeen() {
        guard !registrySeen else { return }
        registrySeen = true
        let waiters = registryWaiters
        registryWaiters = [:]
        for waiter in waiters.values { waiter.resume() }
    }

    /// Whether Claude conversation `claudeID` runs right now in a claude other than CODD session
    /// `except` (a live CODD claude session, or any live registry entry: Terminal.app, a CODD
    /// shell, another CODD). RESUME, a picked transcript and 刪除對話紀錄 refuse such a
    /// conversation: two claudes appending to one transcript corrupt it (review correctness-2).
    func isConversationRunning(_ claudeID: String, except: SessionID? = nil) -> Bool {
        if registryEntries.contains(where: { $0.sessionId == claudeID }) { return true }
        for session in sessionsByID.values.map({ $0 }) + archivedByID.values.map({ $0 })
        where session.kind == .claude && session.id != except {
            guard session.state.isLive || (runtimes[session.id]?.holderAlive ?? false) else { continue }
            if session.claudeSessionID == claudeID || records[session.id]?.claudeSessionId == claudeID { return true }
        }
        return false
    }

    /// The menu's `刪除對話紀錄…` is disabled while another claude runs the session's conversation.
    func isConversationInUse(_ id: SessionID) -> Bool {
        guard let session = sessionsByID[id] ?? archivedByID[id], session.kind == .claude else { return false }
        let claudeID = records[id]?.claudeSessionId ?? session.claudeSessionID ?? id
        return isConversationRunning(claudeID, except: id) || (claudeID != id && isConversationRunning(id, except: id))
    }

    /// D18: conversations a live claude uses right now (a running CODD claude session's current
    /// Claude session id, and every live registry entry's): the resume picker shows them disabled
    /// and 刪除對話紀錄 refuses them.
    var inUseClaudeSessionIds: Set<String> {
        var ids = Set(registryEntries.compactMap(\.sessionId))
        for session in sessionsByID.values.map({ $0 }) + archivedByID.values.map({ $0 }) where session.kind == .claude {
            guard session.state.isLive || (runtimes[session.id]?.holderAlive ?? false) else { continue }
            if let claude = session.claudeSessionID { ids.insert(claude) }
        }
        return ids
    }

    // MARK: - Registry → externals

    /// Settings › 工作階段 (M3 I3): `hidden` removes every external at once and keeps new ones out;
    /// the SDK / Desktop filter applies to the next snapshot and to the current one right away.
    func setExternalDisplay(hidden: Bool, filter: ExternalSessionFilter) {
        guard hidden != hidesExternals || filter != externalFilter else { return }
        hidesExternals = hidden
        externalFilter = filter
        log("externals hidden=\(hidden) hideSDK=\(filter.hideSDK) hideDesktop=\(filter.hideDesktop)")
        applyRegistry(registryEntries)
    }

    /// Settings › 工作階段 › 外部 session hint (`目前 n 個`): the externals the registry has now,
    /// also while they are hidden.
    var detectedExternalCount: Int {
        guard hidesExternals else { return externalByID.count }
        return ExternalSessionDetector.detect(registryEntries.filter { !isCondenseRun($0) }, owned: ownedProcesses(), filter: externalFilter,
                                              ancestors: processAncestors).count
    }

    /// One registry snapshot (live entries, `HookPipeline.onRegistry`) → `externalByID`: new
    /// externals are added under the project of their folder (a transient one in 未分類 for a
    /// folder CODD does not know), changed ones updated, gone ones removed with any transient
    /// project they leave empty. Before the store is loaded the entries are only kept.
    func applyRegistry(_ entries: [ClaudeRegistryEntry]) {
        registryEntries = entries
        markRegistrySeen()
        guard isLoaded else { return }
        // D32: CODD's own condense `claude -p` (its pid while it runs, its run folder as cwd).
        let candidates = entries.filter { !isCondenseRun($0) }
        let detected = hidesExternals ? [] : ExternalSessionDetector.detect(candidates, owned: ownedProcesses(), filter: externalFilter,
                                                                            ancestors: processAncestors)
        let now = clock.now()
        var hosts: [Int: (session: SessionID, tab: String?)] = [:]
        if detected.contains(where: { $0.hostHolderPid != nil }) {
            for (id, runtime) in runtimes where runtime.holderAlive {
                guard let pid = runtime.holderPid, sessionsByID[id]?.kind == .shell || archivedByID[id]?.kind == .shell else { continue }
                hosts[Int(pid)] = (id, nil)
            }
            for tab in shellTabHolders?() ?? [] { hosts[tab.holderPid] = (tab.sessionID, tab.tabID) }
        }
        var changed = false
        var touched = Set<ProjectID>()
        var seen = Set<SessionID>()
        for external in detected {
            seen.insert(external.id)
            let host = external.hostHolderPid.flatMap { hosts[$0] }
            let info = ExternalInfo(pid: Int32(clamping: external.pid), kind: external.kind, entrypoint: external.entrypoint,
                                    claudeSessionID: external.claudeSessionId, version: external.version,
                                    hostSessionID: host?.session, hostTabID: host?.tab)
            let mapped = Self.appState(external.state)
            let since = external.stateSince ?? external.startedAt ?? now
            if let session = externalByID[external.id] {
                if projectsByID[session.projectID] == nil {
                    // Its project was removed: place it again.
                    let project = projectForExternal(cwd: external.cwd)
                    session.projectID = project.id
                    touched.insert(project.id)
                }
                if update(session, from: external, info: info, state: mapped.state, reason: mapped.reason, since: since) { changed = true }
                if externalRecords[external.id]?.startedAt != external.startedAt { touched.insert(session.projectID) }
            } else {
                let project = projectForExternal(cwd: external.cwd)
                let session = SessionVM(id: external.id, projectID: project.id, kind: .claude, title: external.name ?? "claude",
                                        state: mapped.state, stateSince: since)
                _ = update(session, from: external, info: info, state: mapped.state, reason: mapped.reason, since: since)
                externalByID[external.id] = session
                touched.insert(project.id)
                changed = true
                log("external added id=\(external.id) pid=\(external.pid) cwd=\(external.cwd) project=\(project.id) "
                    + "transient=\(project.isTransient) state=\(session.state.rawValue) host=\(host?.session ?? "-")")
            }
            externalRecords[external.id] = external
        }
        for (id, session) in externalByID where !seen.contains(id) {
            externalByID[id] = nil
            externalRecords[id] = nil
            touched.insert(session.projectID)
            changed = true
            log("external removed id=\(id)")
        }
        for projectID in touched {
            guard let project = projectsByID[projectID] else { continue }
            arrangeExternals(in: project)
            if project.isTransient, project.sessionIDs.isEmpty { removeTransient(project) }
        }
        if changed { onStatesChanged?() }
    }

    /// Copies the registry facts onto an external's view model (only what changed, so cells that
    /// read one property are not invalidated by another). Returns whether anything changed.
    private func update(_ session: SessionVM, from external: ExternalSession, info: ExternalInfo, state: SessionState,
                        reason: WaitingReason?, since: Date) -> Bool {
        var changed = false
        func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SessionVM, T>, _ value: T) {
            guard session[keyPath: keyPath] != value else { return }
            session[keyPath: keyPath] = value
            changed = true
        }
        let old = session.state
        set(\.title, external.name ?? "claude")
        set(\.state, state)
        set(\.stateSince, since)
        set(\.waitingReason, state == .waiting ? reason : nil)
        set(\.startedAt, external.startedAt)
        set(\.pid, Int32(clamping: external.pid))
        set(\.remoteControl, external.remoteControl)
        set(\.claudeSessionID, external.claudeSessionId)
        set(\.externalInfo, info)
        if old != state, externalByID[session.id] != nil {
            // Never `onTransition`: externals are not notified (D6); the log and the dump hear it.
            log("external state id=\(session.id) \(old.rawValue)->\(state.rawValue)")
        }
        if refreshStale(session, now: clock.now()) { changed = true }
        return changed
    }

    /// Externals after the CODD sessions of their project, by start time (unknown last), then pid.
    func arrangeExternals(in project: ProjectVM) {
        let codd = project.sessionIDs.filter { sessionsByID[$0] != nil }
        let externals = externalByID.values.filter { $0.projectID == project.id }.sorted { a, b in
            switch (a.startedAt, b.startedAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return (a.pid ?? 0, a.id) < (b.pid ?? 0, b.id)
            }
        }
        let arranged = codd + externals.map(\.id)
        if arranged != project.sessionIDs { project.sessionIDs = arranged }
    }

    /// The project of an external's folder (both sides symlink-resolved), else a new transient
    /// project at the end of 未分類.
    func projectForExternal(cwd: String) -> ProjectVM {
        if let project = project(forPath: cwd) { return project }
        let path = Self.standardize(cwd)
        let project = ProjectVM(id: LayoutMapping.id(UUID()), name: Self.projectName(cwd: path), cwd: path,
                                groupID: Self.ungroupedID, sessionIDs: [])
        project.isTransient = true
        projectsByID[project.id] = project
        let bucket = group(Self.ungroupedID) ?? groups.last
        bucket?.projectIDs.append(project.id)
        if let bucket, project.groupID != bucket.id { project.groupID = bucket.id }
        log("transient project=\(project.id) cwd=\(path)")
        return project
    }

    /// A transient project its last external left.
    private func removeTransient(_ project: ProjectVM) {
        for g in groups where g.projectIDs.contains(project.id) { g.projectIDs.removeAll { $0 == project.id } }
        projectsByID[project.id] = nil
        log("transient project removed=\(project.id)")
    }

    /// D6: a transient project becomes a saved one (a CODD session is created, adopted or added
    /// there, or the user picked `加入為專案`); it keeps its externals. With `groupID` (a ⌘N
    /// request for a new folder) it moves into that group, else it stays in 未分類 ahead of the
    /// remaining transient projects.
    @discardableResult
    func promoteTransient(_ project: ProjectVM, into groupID: GroupID? = nil) -> Bool {
        guard project.isTransient, let uuid = UUID(uuidString: project.id) else { return false }
        project.isTransient = false
        projectRecords[project.id] = Project(id: uuid, name: project.name, path: project.cwd, order: 0)
        if let groupID, let target = group(groupID), !target.isUngrouped {
            moveProjects([project.id], toGroup: groupID, atIndex: target.projectIDs.count)
        } else if let bucket = group(project.groupID) {
            bucket.projectIDs.removeAll { $0 == project.id }
            insertSavedProject(project.id, in: bucket)
        }
        log("promoted project=\(project.id) cwd=\(project.cwd)")
        scheduleLayoutSave()
        return true
    }

    /// `加入為專案` (sidebar).
    func promoteTransient(_ id: ProjectID) {
        guard let project = projectsByID[id] else { return }
        promoteTransient(project)
    }

    /// Saved projects come before the transient ones (which sit at the end of 未分類).
    func insertSavedProject(_ id: ProjectID, in group: GroupVM) {
        let index = group.projectIDs.firstIndex { projectsByID[$0]?.isTransient == true } ?? group.projectIDs.count
        group.projectIDs.insert(id, at: index)
    }

    /// Keeps the transient projects of `group` after its saved ones (order otherwise unchanged).
    func keepTransientLast(_ group: GroupVM) {
        let saved = group.projectIDs.filter { projectsByID[$0]?.isTransient != true }
        let transient = group.projectIDs.filter { projectsByID[$0]?.isTransient == true }
        if saved + transient != group.projectIDs { group.projectIDs = saved + transient }
    }

    /// A CODD session goes before the project's externals (`index` counts CODD sessions only).
    func insertCODDSession(_ id: SessionID, in project: ProjectVM, at index: Int? = nil) {
        let coddCount = project.sessionIDs.prefix { externalByID[$0] == nil }.count
        project.sessionIDs.insert(id, at: max(0, min(index ?? coddCount, coddCount)))
    }

    /// Re-runs the detector on the latest registry entries in the next main-actor turn (ownership
    /// changed: a holder or child pid became known, a session or tab started or ended).
    func scheduleExternalRefresh() {
        guard !externalRefreshScheduled else { return }
        externalRefreshScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.externalRefreshScheduled = false
            self.applyRegistry(self.registryEntries)
        }
    }

    /// `realpath` of a standardized path, cached. A path that does not resolve is returned as is;
    /// the failure is kept for `realpathRetry`, so a deleted project folder costs one syscall per
    /// half minute instead of one per lookup, and a folder created later is still picked up.
    func resolvedPath(_ path: String, now: Date = Date()) -> String {
        if let cached = realpathCache[path] {
            if let real = cached.real { return real }
            if now.timeIntervalSince(cached.at) < Self.realpathRetry { return path }
        }
        let real = Self.realpath(path)
        remember(path, real, at: now)
        return real ?? path
    }

    nonisolated static let realpathRetry: TimeInterval = 30

    nonisolated static func realpath(_ path: String) -> String? {
        guard let resolved = path.withCString({ Darwin.realpath($0, nil) }) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func remember(_ path: String, _ real: String?, at date: Date) {
        if realpathCache.count >= 1024 { realpathCache.removeAll() }
        realpathCache[path] = ResolvedPath(real: real, at: date)
    }

    /// Resolves the project folders not cached yet off the main actor (after the load and when a
    /// project is added), so `project(forPath:)` finds them resolved instead of calling realpath
    /// on the main actor, where a stalled network mount would hang the UI.
    func prewarmProjectPaths() {
        let now = Date()
        let wanted = Set(projectsByID.values.map { Self.standardize($0.cwd) }).filter { path in
            guard let cached = realpathCache[path] else { return true }
            return cached.real == nil && now.timeIntervalSince(cached.at) >= Self.realpathRetry
        }
        guard !wanted.isEmpty else { return }
        let previous = realpathPrewarm
        realpathPrewarm = Task { [weak self] in
            await previous?.value
            let resolved = await Task.detached(priority: .utility) { wanted.map { ($0, Self.realpath($0)) } }.value
            guard let self else { return }
            let at = Date()
            for (path, real) in resolved { self.remember(path, real, at: at) }
        }
    }

    // MARK: - Last prompt (D20)

    /// `UserPromptSubmit`'s prompt: the display form (cleaned by the pipeline) and the whole one
    /// for resends (D26), always both from the same event.
    func applyPrompt(_ prompt: String, full: String?, for uuid: UUID) {
        let id = LayoutMapping.id(uuid)
        guard let session = sessionsByID[id] ?? archivedByID[id] else { return }
        if session.resendPrompt != full { session.resendPrompt = full }
        guard session.lastPrompt != prompt else { return }
        session.lastPrompt = prompt
        onStatesChanged?()
    }

    // MARK: - Stale (D15)

    /// Recomputes every session's stale flag now and then every `staleInterval`.
    func startStaleTimer() {
        staleTask?.cancel()
        refreshStale()
        let interval = staleInterval
        staleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let store = self else { return }
                store.refreshStale()
            }
        }
    }

    /// Every session (CODD, archived and external) against `now`.
    func refreshStale(now: Date? = nil) {
        let now = now ?? clock.now()
        var changed = false
        for session in allSessions + archivedByID.values.map({ $0 }) where refreshStale(session, now: now) { changed = true }
        if changed { onStatesChanged?() }
    }

    /// IDLE for longer than `staleAfter`, or (M4 D30) stopped / exited and found stale by the last
    /// retention run. Returns whether the flag changed.
    @discardableResult
    func refreshStale(_ session: SessionVM, now: Date) -> Bool {
        let idleStale = session.state == .idle && now.timeIntervalSince(session.stateSince) > staleAfter
        let stale = idleStale || (!session.state.isLive && retentionStaleIDs.contains(session.id))
        guard session.isStale != stale else { return false }
        session.isStale = stale
        return true
    }

    // MARK: - D23 trash

    /// The macOS Trash (recoverable). Only used outside tests and `-codd-trash-dir` runs.
    nonisolated static func moveToSystemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Moves into `folder` instead of the Trash (tests, DEBUG `-codd-trash-dir`); a name that is
    /// taken gets ` 2`, ` 3`, … like the Trash does.
    nonisolated static func trash(into folder: String) -> @Sendable (URL) throws -> Void {
        { url in
            let manager = FileManager.default
            try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let name = url.lastPathComponent
            var target = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name)
            var n = 2
            while manager.fileExists(atPath: target.path) {
                target = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("\(name) \(n)")
                n += 1
            }
            try manager.moveItem(at: url, to: target)
        }
    }
}
