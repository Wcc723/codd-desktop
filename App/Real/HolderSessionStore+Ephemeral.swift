import CoddHolderClient
import Foundation

/// A SHELL session that exists only for one task (dialog C's `claude /login`, `cswap add-token`,
/// D24): shown and selected like any session, never written to layout.json, and marked by a file
/// in its session directory so a crash mid-flow is cleaned up at the next launch.
struct EphemeralShell: Equatable, Sendable {
    /// Typed into the shell once it is up (bytes as given, `\r` = Return); nil after sending.
    var typing: String?
    /// The session goes (holder ended, directory deleted) as soon as its shell exits.
    var discardOnExit: Bool
    /// The transient project made for its folder (removed with it when nothing else is there).
    var createdProject: ProjectID?
}

extension HolderSessionStore {
    /// `<session dir>/codd-ephemeral`: this session must not survive a relaunch.
    nonisolated static let ephemeralMarkerName = "codd-ephemeral"
    /// The shell prints its prompt before the text arrives (it would sit in the PTY's input queue
    /// anyway; the pause only keeps the echo after the prompt).
    nonisolated static let ephemeralTypingDelay: Duration = .milliseconds(500)

    /// Starts an ephemeral SHELL session titled `title` in `cwd` (an existing project of that folder,
    /// else a transient one that is never saved) and types `typing` once its shell is up. Returns
    /// the session id, or nil when refused (`lastRefusal`).
    @discardableResult
    func createEphemeralShell(title: String, cwd: String, typing: String?, discardOnExit: Bool = false) -> SessionID? {
        lastRefusal = nil
        guard isLoaded else {
            refuse("還在讀取 session，請稍候再試一次。", detail: "ephemeral shell: sessions are still loading")
            return nil
        }
        guard let launcher else {
            refuse("CODD.app 裡沒有 codd-holder，無法開始 session。請重新安裝 CODD。", detail: "ephemeral shell: no codd-holder")
            return nil
        }
        let folder = Self.standardize(cwd)
        guard Self.isFolder(folder) else {
            refuse(Self.missingFolderMessage(folder))
            return nil
        }
        let uuid = UUID()
        let id = LayoutMapping.id(uuid)
        guard let socket = root.socketPath(for: id) else {
            let error = HolderStartError.socketPathTooLong(root.runPath)
            refuse(error.userMessage, detail: error.description)
            return nil
        }
        let directory = root.sessionDirectory(id)
        // The marker goes in before the holder exists: a crash right after the spawn still leaves
        // a directory the next launch recognises.
        do {
            try root.prepare()
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            guard FileManager.default.createFile(atPath: directory + "/" + Self.ephemeralMarkerName, contents: Data("1\n".utf8),
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            refuse("無法建立暫時的終端機：\(error.localizedDescription)", detail: "ephemeral shell marker: \(error)")
            return nil
        }
        let existing = project(forPath: folder)
        let project = existing ?? projectForExternal(cwd: folder)
        guard let projectUUID = UUID(uuidString: project.id) else { return nil }
        let record = LayoutSessionRecord(id: uuid, claudeSessionId: nil, projectId: projectUUID, kind: .shell, titleOverride: title,
                                         order: project.sessionIDs.count, createdAt: clock.now(), holderSocket: socket,
                                         launchProfileId: profiles.document.shellProfile.id)
        records[id] = record
        ephemeral[id] = EphemeralShell(typing: typing, discardOnExit: discardOnExit, createdProject: existing == nil ? project.id : nil)
        let session = SessionVM(id: id, projectID: project.id, kind: .shell, title: title, state: .starting, stateSince: clock.now())
        session.detail = Self.abbreviate(folder)
        runtimes[id] = HolderRuntime(directory: directory, socketPath: socket, cwd: folder)
        sessionsByID[id] = session
        insertCODDSession(id, in: project)
        scheduleExternalRefresh()
        log("ephemeral shell session=\(id) title=\(title) typing=\(typing == nil ? "no" : "yes")")
        launch(id, uuid: uuid, cwd: folder, socketPath: socket, kind: .shell, options: ClaudeLaunchOptions(), launcher: launcher,
               previousHolder: nil)
        return id
    }

    /// Whether `id` is an ephemeral session (never saved).
    func isEphemeral(_ id: SessionID) -> Bool { ephemeral[id] != nil }

    /// Ends an ephemeral session's holder, removes the session and deletes its directory (its
    /// terminal may have shown an e-mail, D24). Its transient project goes too when it is empty.
    func discardEphemeral(_ id: SessionID) {
        guard let info = ephemeral.removeValue(forKey: id) else { return }
        removeSessions([id])
        if let created = info.createdProject, let project = projectsByID[created], project.isTransient,
           project.sessionIDs.isEmpty {
            for group in groups where group.projectIDs.contains(created) { group.projectIDs.removeAll { $0 == created } }
            projectsByID[created] = nil
        }
        log("ephemeral shell discarded session=\(id)")
        onStatesChanged?()
    }

    /// The shell answered (WELCOME): type the pending text once.
    func ephemeralShellStarted(_ id: SessionID) {
        guard let text = ephemeral[id]?.typing else { return }
        ephemeral[id]?.typing = nil
        Task { [weak self] in
            try? await Task.sleep(for: Self.ephemeralTypingDelay)
            guard let self, self.ephemeral[id] != nil else { return }
            let sent = self.connection(for: id)?.send(Array(text.utf8)) ?? false
            self.log("ephemeral shell typed session=\(id) sent=\(sent)")
        }
    }

    /// An ephemeral shell that should go when it exits.
    func ephemeralShellExited(_ id: SessionID) {
        guard ephemeral[id]?.discardOnExit == true else { return }
        Task { @MainActor [weak self] in self?.discardEphemeral(id) }
    }

    /// Records layout.json may hold: every session's but the ephemeral ones.
    var persistentRecords: [SessionID: LayoutSessionRecord] {
        ephemeral.isEmpty ? records : records.filter { ephemeral[$0.key] == nil }
    }

    /// Launch, before discovery: holders of ephemeral sessions a previous run left behind (crash,
    /// force quit) are ended and their directories and sockets deleted. Blocking: off the main actor.
    nonisolated static func removeEphemeralLeftovers(_ holders: [DiscoveredHolder], root: CoddDataRoot,
                                                    log: @Sendable (String) -> Void) -> [DiscoveredHolder] {
        let manager = FileManager.default
        var kept: [DiscoveredHolder] = []
        var listed = Set<String>()
        for holder in holders {
            listed.insert(holder.directory)
            guard manager.fileExists(atPath: holder.directory + "/" + ephemeralMarkerName) else {
                kept.append(holder)
                continue
            }
            if holder.holderAlive, holder.meta.holderPid > 0 { terminateHolder(holder.meta.holderPid, wait: true) }
            removeEphemeralDirectory(holder.directory, socket: holder.meta.socket, root: root)
            log("ephemeral leftover removed session=\(holder.meta.session)")
        }
        // A directory whose holder never wrote its meta.json (the crash came right after the marker).
        if let names = try? manager.contentsOfDirectory(atPath: root.sessionsPath) {
            for name in names {
                let directory = root.sessionsPath + "/" + name
                guard !listed.contains(directory), manager.fileExists(atPath: directory + "/" + ephemeralMarkerName) else { continue }
                removeEphemeralDirectory(directory, socket: root.socketPath(for: name), root: root)
                log("ephemeral leftover removed session=\(name) (no holder)")
            }
        }
        return kept
    }

    private nonisolated static func removeEphemeralDirectory(_ directory: String, socket: String?, root: CoddDataRoot) {
        let manager = FileManager.default
        if directory.hasPrefix(root.sessionsPath + "/") { try? manager.removeItem(atPath: directory) }
        if let socket, socket.hasPrefix(root.runPath + "/") { try? manager.removeItem(atPath: socket) }
    }
}
