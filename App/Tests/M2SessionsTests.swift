import AppKit
import CoddCore
import CoddHooks
import Darwin
import Foundation
import Testing
@testable import CODD

/// M2 step I2: external sessions (D6, D27) and transient projects, stale (D15), launch profiles and
/// the launch plumbing (D5, D22, resume, pre-chosen ids), transcripts and last prompts (D18, D20),
/// unarchive (D19), 刪除對話紀錄 to an injected trash folder (D23), the state dump keys. Temp data
/// roots and temp Claude directories only (never `.standard`); children are `cat`, never claude.

/// A fresh, normalized `$TMPDIR` folder (short: socket paths must fit 104 bytes).
private func makeRoot(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    return CoddDataRoot(path: String(cString: created)).path
}

/// Kills every process whose command line names `root`, then removes the folder.
private func removeRoot(_ root: String) {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-KILL", "-f", root + "/"]
    try? pkill.run()
    pkill.waitUntilExit()
    try? FileManager.default.removeItem(atPath: root)
}

@MainActor
private func eventually(_ what: String, timeout: Duration = .seconds(8), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "timed out waiting for \(what)")
}

private func realpathOf(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A registry entry as `RegistryWatcher` delivers it (already filtered by liveness).
private func entry(pid: Int, cwd: String, sessionId: String? = nil, status: String? = "idle", waitingFor: String? = nil,
                   startedAt: Date? = Date(timeIntervalSince1970: 1_800_000_000), name: String? = "外部 claude",
                   kind: String? = "interactive", entrypoint: String? = "cli", statusAt: Date? = nil) -> ClaudeRegistryEntry {
    ClaudeRegistryEntry(pid: pid, sessionId: sessionId ?? UUID().uuidString.lowercased(), cwd: cwd, startedAt: startedAt,
                        version: "2.1.300", kind: kind, entrypoint: entrypoint, name: name, status: status, waitingFor: waitingFor,
                        statusTimestampMilliseconds: statusAt.map { Int64($0.timeIntervalSince1970 * 1000) })
}

/// One temp data root, Claude directory and work folder per test, plus a store on them.
@MainActor
private final class Fixture {
    let path: String
    let root: CoddDataRoot
    let claude: ClaudeDirectory
    let logs = Recorder<String>()

    init(_ prefix: String = "codd-i2") throws {
        path = try makeRoot(prefix)
        root = CoddDataRoot(path: path + "/r")
        claude = ClaudeDirectory(path: path + "/claude")
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: claude.path + "/projects", withIntermediateDirectories: true)
    }

    func folder(_ name: String) throws -> String {
        let dir = path + "/" + name
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return realpathOf(dir)
    }

    /// `#!/bin/sh` + `exec cat`: what the holder runs instead of claude (arguments ignored).
    func fakeClaude() throws -> String {
        let file = path + "/fake-claude"
        try "#!/bin/sh\nexec /bin/cat\n".write(toFile: file, atomically: true, encoding: .utf8)
        chmod(file, 0o755)
        return file
    }

    func launcher(claudePath: String? = nil, shellArgv: [String]? = ["/bin/sh", "-c", "exec /bin/cat"]) throws -> HolderLauncher {
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: shellArgv, claudePathOverride: claudePath)
        launcher.coddHookPath = "/usr/bin/true"
        return launcher
    }

    func store(launcher: HolderLauncher? = nil, hooks: HookPipeline? = nil) throws -> HolderSessionStore {
        let logs = self.logs
        let store = HolderSessionStore(root: root, launcher: try launcher ?? self.launcher(), claudeDirectory: claude, hooks: hooks) {
            logs.append($0)
        }
        store.processAncestors = { _ in [1] }
        return store
    }

    /// layout.json with one group, a project per folder and the given session rows.
    @discardableResult
    func seed(projects: [(id: UUID, path: String)], sessions: [SessionRecord]) throws -> ProjectGroup {
        let group = ProjectGroup(name: "CODD", color: .purple, order: 0)
        let rows = projects.enumerated().map { Project(id: $0.element.id, groupId: group.id, name: ($0.element.path as NSString).lastPathComponent,
                                                       path: $0.element.path, order: $0.offset) }
        try LayoutStore(fileURL: root.layoutURL).save(Layout(groups: [group], projects: rows, sessions: sessions))
        return group
    }

    /// `<claudeDir>/projects/<folder of cwd>/<id>.jsonl` with lines that carry `cwd`.
    @discardableResult
    func transcript(_ id: String, cwd: String, title: String? = nil, lastPrompt: String? = nil, sibling: Bool = false) throws -> String {
        let folder = claude.path + "/projects/" + TranscriptCatalog.folderName(for: cwd)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var lines = [
            #"{"type":"user","sessionId":"\#(id)","cwd":"\#(cwd)","gitBranch":"main","timestamp":"2026-10-10T00:00:00.000Z","uuid":"u1","message":{"role":"user","content":"請修好登入"}}"#,
            #"{"type":"assistant","sessionId":"\#(id)","cwd":"\#(cwd)","timestamp":"2026-10-10T00:00:05.000Z","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"好"}]}}"#,
        ]
        if let title { lines.append(#"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(id)"}"#) }
        if let lastPrompt { lines.append(#"{"type":"last-prompt","lastPrompt":"\#(lastPrompt)","sessionId":"\#(id)"}"#) }
        let file = folder + "/" + id + ".jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        if sibling {
            try FileManager.default.createDirectory(atPath: folder + "/" + id + "/subagents", withIntermediateDirectories: true)
            try "{}\n".write(toFile: folder + "/" + id + "/subagents/agent-1.jsonl", atomically: true, encoding: .utf8)
        }
        return file
    }

    deinit {
        removeRoot(path)
    }
}

// MARK: - External sessions (D6)

@MainActor
@Suite("External sessions (D6)", .serialized)
struct ExternalSessionsTests {
    @Test func externalShowsUnderTheProjectOfItsFolderThroughASymlink() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let link = f.path + "/link"
        #expect(symlink(work, link) == 0)
        let projectID = UUID()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(claudeSessionId: "c-1", projectId: projectID, kind: .claude, title: "mine", order: 0, createdAt: Date()),
        ])
        let store = try f.store()
        await store.start()
        let since = Date(timeIntervalSince1970: 1_800_000_100)
        store.applyRegistry([entry(pid: 900_001, cwd: link, sessionId: "ext-claude-1", status: "busy", statusAt: since)])
        let id = ExternalSession.id(pid: 900_001, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let session = try #require(store.session(id))
        #expect(session.external)
        #expect(session.kind == .claude)
        #expect(session.title == "外部 claude")
        #expect(session.state == .busy)
        #expect(session.stateSince == since)
        #expect(session.pid == 900_001)
        #expect(session.claudeSessionID == "ext-claude-1")
        #expect(session.externalInfo?.entrypoint == "cli")
        #expect(session.externalInfo?.rowLabel == "外部啟動")
        let project = try #require(store.project(LayoutMapping.id(projectID)))
        #expect(session.projectID == project.id)
        #expect(project.sessionIDs.last == id, "externals after the CODD sessions")
        #expect(project.sessionIDs.count == 2)
        #expect(store.allSessions.count == 2)
        #expect(store.sessionsByID[id] == nil, "never in the CODD table")

        // A /clear in it changes the Claude id, not the row; a background worker says so.
        store.applyRegistry([entry(pid: 900_001, cwd: link, sessionId: "ext-claude-2", status: "idle", kind: "daemon-worker")])
        #expect(store.session(id) === session)
        #expect(session.claudeSessionID == "ext-claude-2")
        #expect(session.externalInfo?.rowLabel == "外部啟動 · bg")
        store.flushLayout()
        let saved = try LayoutStore(fileURL: f.root.layoutURL).load()
        #expect(saved.sessions.map { LayoutMapping.id($0.id) }.allSatisfy { !$0.hasPrefix("ext-") })
        #expect(saved.sessions.count == 1)
        store.shutdown()
    }

    @Test func unknownFolderGetsATransientProjectThatLeavesWithItsLastExternal() async throws {
        let f = try Fixture()
        let other = try f.folder("other")
        let store = try f.store()
        await store.start()
        #expect(store.isEmpty)
        store.applyRegistry([entry(pid: 900_010, cwd: other), entry(pid: 900_011, cwd: other, startedAt: Date(timeIntervalSince1970: 1_800_000_500))])
        let ungrouped = try #require(store.group(LayoutMapping.ungroupedID))
        #expect(ungrouped.projectIDs.count == 1)
        let transient = try #require(store.project(ungrouped.projectIDs[0]))
        #expect(transient.isTransient)
        #expect(transient.cwd == HolderSessionStore.standardize(other), "standardized like every project folder")
        #expect(transient.sessionIDs.count == 2)
        #expect(transient.sessionIDs.first?.hasPrefix("ext-900010-") == true, "by start time")
        #expect(store.isEmpty, "a transient project is not CODD's")
        #expect(AppServices(store: store).knownProjectChoices().isEmpty)
        #expect(store.currentLayout().projects.isEmpty)
        #expect(store.currentLayout().sessions.isEmpty)

        store.applyRegistry([entry(pid: 900_011, cwd: other, startedAt: Date(timeIntervalSince1970: 1_800_000_500))])
        #expect(transient.sessionIDs.count == 1)
        store.applyRegistry([])
        #expect(store.project(transient.id) == nil)
        #expect(ungrouped.projectIDs.isEmpty)
        #expect(store.allSessions.isEmpty)
        store.shutdown()
    }

    @Test func aCODDSessionInATransientFolderPromotesIt() async throws {
        let f = try Fixture()
        let other = try f.folder("other")
        let store = try f.store()
        await store.start()
        store.applyRegistry([entry(pid: 900_020, cwd: other)])
        let projectID = try #require(store.group(LayoutMapping.ungroupedID)?.projectIDs.first)
        let shellID = try #require(store.createSession(NewSessionRequest(cwd: other, kind: .shell)))
        let project = try #require(store.project(projectID))
        #expect(!project.isTransient)
        #expect(store.session(shellID)?.projectID == projectID)
        #expect(project.sessionIDs.first == shellID, "the CODD session goes before the external")
        #expect(project.sessionIDs.count == 2)
        let layout = store.currentLayout()
        #expect(layout.projects.map { LayoutMapping.id($0.id) } == [projectID])
        #expect(layout.sessions.map { LayoutMapping.id($0.id) } == [shellID])

        // `加入為專案` and addProject(path:) promote the same way.
        let more = try f.folder("more")
        store.applyRegistry([entry(pid: 900_020, cwd: other), entry(pid: 900_021, cwd: more)])
        let transient = try #require(store.groups.flatMap(\.projectIDs).compactMap { store.project($0) }.first { $0.isTransient })
        store.promoteTransient(transient.id)
        #expect(!transient.isTransient)
        #expect(transient.sessionIDs.count == 1, "it keeps its external")
        let third = try f.folder("third")
        store.applyRegistry([entry(pid: 900_020, cwd: other), entry(pid: 900_021, cwd: more), entry(pid: 900_022, cwd: third)])
        let thirdProject = try #require(store.project(forPath: third))
        #expect(thirdProject.isTransient)
        #expect(store.addProject(path: third, groupID: nil) == thirdProject.id)
        #expect(!thirdProject.isTransient)
        #expect(Set(store.currentLayout().projects.map { LayoutMapping.id($0.id) }) == [projectID, transient.id, thirdProject.id])
        store.stop([shellID])
        store.shutdown()
    }

    @Test func ownClaudeProcessesAreNeverExternal() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let sessionUUID = UUID()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: sessionUUID, claudeSessionId: "current-claude", projectId: projectID, kind: .claude, order: 0, createdAt: Date()),
        ])
        let store = try f.store()
        await store.start()
        let id = LayoutMapping.id(sessionUUID)
        let session = try #require(store.session(id))
        // As after WELCOME: holder 4242 runs child 5555.
        store.runtimes[id]?.holderAlive = true
        store.runtimes[id]?.holderPid = 4242
        store.runtimes[id]?.childExited = false
        session.pid = 5555
        store.transition(session, to: .busy)
        store.processAncestors = { pid in pid == 7777 ? [4242, 1] : [1] }
        store.applyRegistry([
            entry(pid: 5555, cwd: work),                                     // its child, by pid
            entry(pid: 6666, cwd: work, sessionId: "current-claude"),        // its conversation
            entry(pid: 6667, cwd: work, sessionId: id),                      // its initial id (--session-id)
            entry(pid: 7777, cwd: work),                                     // below its holder (before WELCOME)
            entry(pid: 8888, cwd: work, entrypoint: "sdk-cli"),              // SDK: hidden
            entry(pid: 8889, cwd: work, entrypoint: "claude-desktop"),       // desktop app: hidden
            entry(pid: 9999, cwd: work),                                     // someone else's
        ])
        #expect(store.externalByID.values.map(\.pid) == [9999])

        // Stopped, its conversation resumed by hand elsewhere is another process: external.
        store.runtimes[id]?.holderAlive = false
        store.transition(session, to: .stopped)
        store.applyRegistry([entry(pid: 6666, cwd: work, sessionId: "current-claude")])
        #expect(store.externalByID.values.map(\.pid) == [6666])
        #expect(store.inUseClaudeSessionIds.contains("current-claude"))
        store.shutdown()
    }

    @Test func aClaudeStartedInACODDShellNamesThatShell() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let shellUUID = UUID()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: shellUUID, projectId: projectID, kind: .shell, title: "dev server", order: 0, createdAt: Date()),
        ])
        let store = try f.store()
        await store.start()
        let shellID = LayoutMapping.id(shellUUID)
        store.runtimes[shellID]?.holderAlive = true
        store.runtimes[shellID]?.holderPid = 6000
        store.shellTabHolders = { [ShellTabHolder(sessionID: shellID, tabID: "tab-1", holderPid: 6100)] }
        store.processAncestors = { pid in
            switch pid {
            case 9001: [9000, 6000, 1]
            case 9002: [6100, 1]
            default: [1]
            }
        }
        store.applyRegistry([entry(pid: 9001, cwd: work), entry(pid: 9002, cwd: work, startedAt: Date(timeIntervalSince1970: 1_800_000_900)),
                             entry(pid: 9003, cwd: work, startedAt: nil)])
        let inShell = try #require(store.externalByID.values.first { $0.pid == 9001 })
        #expect(inShell.externalInfo?.hostSessionID == shellID)
        #expect(inShell.externalInfo?.hostTabID == nil)
        #expect(inShell.externalInfo?.rowLabel == "在 CODD shell 中")
        let inTab = try #require(store.externalByID.values.first { $0.pid == 9002 })
        #expect(inTab.externalInfo?.hostSessionID == shellID)
        #expect(inTab.externalInfo?.hostTabID == "tab-1")
        let outside = try #require(store.externalByID.values.first { $0.pid == 9003 })
        #expect(outside.externalInfo?.hostSessionID == nil)
        #expect(outside.id == "ext-9003", "D27 without startedAt")
        let project = try #require(store.project(LayoutMapping.id(projectID)))
        #expect(project.sessionIDs == [shellID, inShell.id, inTab.id, outside.id])
        store.shutdown()
    }

    @Test func externalsCountButAreNeverNotifiedAnsweredArchivedStoppedOrMoved() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let mine = UUID()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: mine, claudeSessionId: "c", projectId: projectID, kind: .claude, title: "mine", order: 0, createdAt: Date()),
        ])
        let store = try f.store()
        var transitions: [SessionID] = []
        store.onTransition = { session, _ in transitions.append(session.id) }
        await store.start()
        transitions.removeAll()
        store.applyRegistry([entry(pid: 9100, cwd: work, status: "busy")])
        let external = try #require(store.externalByID.values.first)
        store.applyRegistry([entry(pid: 9100, cwd: work, status: "waiting", waitingFor: "permission prompt")])
        #expect(external.state == .waiting)
        #expect(external.waitingReason == .permission)
        #expect(transitions.isEmpty, "externals never reach onTransition (no notifications)")
        #expect(!SessionNotifier.shouldNotify(from: .busy, to: .waiting, focused: false, enabled: true, external: true))
        #expect(SessionNotifier.shouldNotify(from: .busy, to: .waiting, focused: false, enabled: true, external: false))

        let counts = SessionCounts(sessions: store.allSessions)
        #expect(counts.waiting == 1)
        #expect(counts.attention == 1)
        #expect(counts.live == 1)
        let snapshot = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        #expect(snapshot.childrenOf(.section(.needsYou)) == [.session(external.id, .needs)])

        let panel = MenuBarPanelContent.build(store: store, accounts: MockAccountStore())
        let row = try #require(panel.needs.first { $0.id == external.id })
        #expect(!row.model.isPermission, "no [1 允許] for an external")

        let mineID = LayoutMapping.id(mine)
        store.answer(external.id, key: "1")
        #expect(external.state == .waiting)
        _ = store.archive([external.id])
        #expect(store.archivedSession(external.id) == nil)
        #expect(store.project(LayoutMapping.id(projectID))?.sessionIDs == [mineID, external.id])
        store.stop([external.id])
        #expect(external.state == .waiting)
        store.moveSessions([external.id], toIndex: 0, inProject: LayoutMapping.id(projectID))
        store.moveSessions([mineID], toIndex: 2, inProject: LayoutMapping.id(projectID))
        #expect(store.project(LayoutMapping.id(projectID))?.sessionIDs == [mineID, external.id])
        #expect(!(await store.deleteHistory(external.id)))
        #expect(SidebarViewController.archivable([mineID, external.id, mineID], in: store) == [mineID])
        #expect(SidebarViewController.archiveToastText(count: 1) == "✕ 1 個 session 已封存")
        store.shutdown()
    }

    @Test func dropsAreClampedToTheCODDRows() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let (a, b) = (UUID(), UUID())
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: a, projectId: projectID, kind: .claude, title: "a", order: 0, createdAt: Date()),
            SessionRecord(id: b, projectId: projectID, kind: .claude, title: "b", order: 1, createdAt: Date()),
        ])
        let store = try f.store()
        await store.start()
        store.applyRegistry([entry(pid: 9200, cwd: work)])
        let external = try #require(store.externalByID.values.first)
        let snapshot = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        let project = NodeKind.project(LayoutMapping.id(projectID))
        #expect(snapshot.childrenOf(project).count == 3)
        let dragged = [NodeKind.session(LayoutMapping.id(a), .tree)]
        let below = DropPlanner.plan(dragged: dragged, parent: project, index: 3, snapshot: snapshot, store: store)
        #expect(below?.childIndex == 2)
        #expect(below?.target == .sessions(project: LayoutMapping.id(projectID), index: 2))
        let onExternal = DropPlanner.plan(dragged: dragged, parent: .session(external.id, .tree), index: -1, snapshot: snapshot, store: store)
        #expect(onExternal?.childIndex == 2)
        #expect(DropPlanner.plan(dragged: [.session(external.id, .tree)], parent: project, index: 0, snapshot: snapshot, store: store) == nil)
        store.shutdown()
    }

    /// The measurement for the report: 20 entries over 5 folders (3 unknown), ancestry injected.
    @Test func applyRegistryWithTwentyEntriesIsCheap() async throws {
        let f = try Fixture()
        let folders = try (0..<5).map { try f.folder("w\($0)") }
        let projectID = UUID()
        try f.seed(projects: [(projectID, folders[0]), (UUID(), folders[1])], sessions: [])
        let store = try f.store()
        await store.start()
        let entries = (0..<20).map { i in
            entry(pid: 30_000 + i, cwd: folders[i % 5], status: i % 3 == 0 ? "busy" : "idle",
                  startedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(i)))
        }
        let clock = ContinuousClock()
        var start = clock.now
        store.applyRegistry(entries)
        let cold = clock.now - start
        let changed = entries.enumerated().map { i, e in
            var e = e
            e.status = i % 2 == 0 ? "waiting" : "busy"
            return e
        }
        start = clock.now
        store.applyRegistry(changed)
        let warm = clock.now - start
        #expect(store.externalByID.count == 20)
        #expect(store.groups.flatMap(\.projectIDs).compactMap { store.project($0) }.filter(\.isTransient).count == 3)
        print(String(format: "MEASURE applyRegistry 20 entries: first %.3f ms (5 projects, 3 transient), update %.3f ms",
                     TerminalHub.milliseconds(cold), TerminalHub.milliseconds(warm)))
        #expect(cold < .milliseconds(50))
        store.shutdown()
    }
}

// MARK: - Stale (D15)

@MainActor
@Suite("Stale sessions (D15)", .serialized)
struct StaleTests {
    @Test func idleLongerThanTheLimitIsStale() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let mine = UUID()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: mine, projectId: projectID, kind: .claude, order: 0, createdAt: Date()),
        ])
        let store = try f.store()
        store.staleAfter = 3600
        await store.start()
        let session = try #require(store.session(LayoutMapping.id(mine)))
        let now = Date()
        store.transition(session, to: .idle, since: now.addingTimeInterval(-3000))
        #expect(!session.isStale)
        store.refreshStale(now: now.addingTimeInterval(700))
        #expect(session.isStale)
        store.transition(session, to: .busy)
        #expect(!session.isStale, "a transition recomputes it")

        store.applyRegistry([entry(pid: 9300, cwd: work, status: "idle", statusAt: now.addingTimeInterval(-7200))])
        let external = try #require(store.externalByID.values.first)
        #expect(external.isStale, "externals too")

        // The timer: a short interval and limit in place of 60 s / 1 h.
        store.staleAfter = 0.2
        store.staleInterval = .milliseconds(50)
        store.transition(session, to: .idle)
        store.startStaleTimer()
        await eventually("stale by the timer", timeout: .seconds(3)) { session.isStale }
        store.shutdown()
    }
}

// MARK: - Launch profiles and launch plumbing (D5, D22)

@MainActor
@Suite("Launch profiles and launches (D5)", .serialized)
struct LaunchProfilesTests {
    @Test func firstStartSeedsProfilesJSONAndPushesItIntoTheLauncher() async throws {
        let f = try Fixture()
        let store = try f.store()
        await store.start()
        let file = f.root.path + "/profiles.json"
        #expect(FileManager.default.fileExists(atPath: file))
        #expect((try? FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int) == 0o600)
        #expect(try LaunchProfileStore(fileURL: URL(fileURLWithPath: file)).load() == .seeded)
        #expect(store.profiles.document == .seeded)
        #expect(store.profiles.claudeProfiles.map(\.id) == ["claude-default", "claude-plan", "claude-rc"])
        #expect(store.profiles.shellProfiles.map(\.id) == ["zsh"])
        #expect(store.launcher?.profiles == LaunchProfile.builtIn)
        #expect(f.logs.values.contains("profiles seeded count=4"))
        store.shutdown()
    }

    @Test func aCorruptFileIsMovedAsideAndANewerOneIsReadOnly() async throws {
        let f = try Fixture()
        let file = f.root.path + "/profiles.json"
        try "{ not json".write(toFile: file, atomically: true, encoding: .utf8)
        let first = LaunchProfiles(root: f.root) { f.logs.append($0) }
        await first.load()
        #expect(first.document == .seeded)
        #expect(try LaunchProfileStore(fileURL: URL(fileURLWithPath: file)).load() == .seeded)
        let aside = try FileManager.default.contentsOfDirectory(atPath: f.root.path).filter { $0.hasPrefix("profiles.json.corrupt-") }
        #expect(aside.count == 1)

        try #"{"version": 9, "defaultProfileId": "x", "profiles": []}"#.write(toFile: file, atomically: true, encoding: .utf8)
        let newer = LaunchProfiles(root: f.root) { f.logs.append($0) }
        var problems: [String] = []
        newer.onProblem = { message, _ in problems.append(message) }
        await newer.load()
        #expect(newer.isReadOnly)
        #expect(newer.document == .seeded)
        #expect(newer.upsert(LaunchProfile(id: "y", name: "y", kind: .claude)).isEmpty)
        #expect(newer.document.profile(id: "y") == nil, "refused")
        #expect(problems == [LaunchProfiles.readOnlyMessage])
        newer.flush()
        #expect(try String(contentsOfFile: file, encoding: .utf8).contains("\"version\": 9"), "never overwritten")
    }

    @Test func aCustomProfileReachesTheClaudeArgvAndEnvironmentAndIsSaved() async throws {
        let f = try Fixture()
        let store = try f.store(launcher: f.launcher(claudePath: try f.fakeClaude()))
        await store.start()
        let custom = LaunchProfile(id: "acct-x", name: "帳號 X", kind: .claude, defaultModel: "opus", extraArguments: ["--verbose"],
                                   environment: ["FAKE_REGISTRY_DIR": f.claude.path + "/sessions"])
        #expect(store.profiles.upsert(custom).isEmpty)
        let blocked = LaunchProfile(id: "bad", name: "bad", kind: .claude, environment: ["PATH": "/evil"])
        #expect(store.profiles.upsert(blocked) == [.blockedEnvironment("PATH")])
        var options = ClaudeLaunchOptions()
        options.profileID = "acct-x"
        let plan = try #require(store.launcher).planClaude(sessionID: UUID(), cwd: "/tmp", options: options, hooks: nil)
        #expect(plan.argv.contains("--verbose"))
        #expect(plan.argv.firstIndex(of: "--model").map { plan.argv[$0 + 1] } == "opus")
        #expect(plan.environment["FAKE_REGISTRY_DIR"] == f.claude.path + "/sessions")
        store.profiles.flush()
        let reread = try LaunchProfileStore(fileURL: URL(fileURLWithPath: f.root.path + "/profiles.json")).load()
        #expect(reread.profile(id: "acct-x") == custom)
        #expect(reread.profile(id: "bad") == nil)
        #expect(store.profiles.duplicate("acct-x") == "acct-x-2")
        #expect(store.profiles.document.profile(id: "acct-x-2")?.name == "帳號 X 複本")
        #expect(store.profiles.delete("acct-x-2") == nil)
        store.shutdown()
    }

    @Test func shellSessionsAndTabsUseTheFirstShellProfile() throws {
        let f = try Fixture()
        var launcher = try f.launcher(shellArgv: nil)
        launcher.profiles = LaunchProfile.builtIn.map { profile in
            guard profile.kind == .shell else { return profile }
            var shell = profile
            shell.shellPath = "/bin/sh"
            shell.environment = ["SHELL_PROFILE_VAR": "1", "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib"]
            return shell
        }
        let plan = try launcher.plan(sessionID: UUID(), cwd: "/tmp")
        #expect(plan.argv == ["/bin/sh", "-l"])
        #expect(plan.environment["SHELL_PROFILE_VAR"] == "1")
        #expect(plan.environment["DYLD_INSERT_LIBRARIES"] == nil, "blocked names are dropped as for claude")
        // -codd-shell-argv still wins.
        launcher.shellArgvOverride = ["/bin/zsh", "-f"]
        #expect(try launcher.plan(sessionID: UUID(), cwd: "/tmp").argv == ["/bin/zsh", "-f"])
    }

    @Test func aMissingProfileFallsBackToTheDefaultAndRemoteControlIsAddedOnce() throws {
        let f = try Fixture()
        var launcher = try f.launcher(claudePath: "/usr/bin/true")
        var options = ClaudeLaunchOptions()
        options.profileID = "gone"
        #expect(try !launcher.planClaude(sessionID: UUID(), cwd: "/tmp", options: options, hooks: nil).argv.contains("--permission-mode"))
        launcher.defaultProfileID = "claude-plan"
        let fallback = try launcher.planClaude(sessionID: UUID(), cwd: "/tmp", options: options, hooks: nil).argv
        #expect(fallback.firstIndex(of: "--permission-mode").map { fallback[$0 + 1] } == "plan")
        launcher.defaultProfileID = "zsh"   // a shell default: claude sessions take the first claude profile
        #expect(try !launcher.planClaude(sessionID: UUID(), cwd: "/tmp", options: options, hooks: nil).argv.contains("--permission-mode"))

        options.remoteControl = true
        for profile in ["claude-default", "claude-rc"] {
            options.profileID = profile
            let argv = try launcher.planClaude(sessionID: UUID(), cwd: "/tmp", options: options, hooks: nil).argv
            #expect(argv.filter { $0 == "--remote-control" }.count == 1, "\(profile): \(argv)")
            #expect(argv.last == "--remote-control")
        }
    }

    @Test func aResumeRequestStartsClaudeResumeAndKeepsTheConversation() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let conversation = UUID().uuidString.lowercased()
        try f.transcript(conversation, cwd: work, title: "refresh token 流程改寫")
        let store = try f.store(launcher: f.launcher(claudePath: try f.fakeClaude()))
        await store.start()
        var request = NewSessionRequest(cwd: work, kind: .claude)
        request.claude.mode = .resume(conversation)
        request.claude.profileID = "claude-plan"
        let id = try #require(store.createSession(request))
        #expect(id != conversation, "a new CODD session continues the conversation")
        #expect(store.record(id)?.claudeSessionId == conversation)
        #expect(store.session(id)?.claudeSessionID == conversation)
        #expect(store.record(id)?.launchProfileId == "claude-plan")
        await eventually("spawned with --resume") { f.logs.values.contains { $0.hasPrefix("spawned session=\(id) ") && $0.hasSuffix("resume=\(conversation)") } }
        await eventually("title from the transcript") { store.session(id)?.title == "refresh token 流程改寫" }
        #expect(store.inUseClaudeSessionIds.contains(conversation))
        var options = store.launchOptions(id)
        options.mode = .resume(conversation)
        let argv = try #require(store.launcher).planClaude(sessionID: UUID(uuidString: id)!, cwd: work, options: options, hooks: nil).argv
        #expect(argv.firstIndex(of: "--resume").map { argv[$0 + 1] } == conversation)
        #expect(!argv.contains("--session-id"))

        var restart = NewSessionRequest(cwd: work, kind: .claude)
        restart.claude.mode = .restart(UUID())
        #expect(store.createSession(restart) == nil)
        #expect(store.lastRefusal != nil)
        var invalid = NewSessionRequest(cwd: work, kind: .claude)
        invalid.claude.mode = .resume("-rf")
        #expect(store.createSession(invalid) == nil)
        store.stop([id])
        await eventually("stopped") { !(store.session(id)?.state.isLive ?? true) }
        store.shutdown()
    }

    @Test func thePreviewedSessionIDIsUsedWhenFree() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let store = try f.store(launcher: f.launcher(claudePath: try f.fakeClaude()))
        await store.start()
        let chosen = UUID()
        var request = NewSessionRequest(cwd: work, kind: .claude)
        request.sessionID = chosen
        let first = try #require(store.createSession(request))
        #expect(first == LayoutMapping.id(chosen))
        #expect(store.record(first)?.claudeSessionId == first, "--session-id = the previewed id")
        let second = try #require(store.createSession(request))
        #expect(second != first, "a taken id is never reused")
        // A folder with that name under sessions/ also counts as taken.
        let squatter = UUID()
        try FileManager.default.createDirectory(atPath: f.root.sessionDirectory(LayoutMapping.id(squatter)), withIntermediateDirectories: true)
        var shell = NewSessionRequest(cwd: work, kind: .shell)
        shell.sessionID = squatter
        let third = try #require(store.createSession(shell))
        #expect(third != LayoutMapping.id(squatter))
        store.stop([first, second, third])
        store.shutdown()
    }
}

// MARK: - Last prompt (D20), transcripts (D18)

@MainActor
@Suite("Last prompt and transcripts (D18, D20)", .serialized)
struct TranscriptServiceTests {
    @Test func userPromptSubmitSetsTheLastPrompt() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let sessionUUID = UUID()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: sessionUUID, claudeSessionId: "c-1", projectId: projectID, kind: .claude, order: 0, createdAt: Date()),
        ])
        let pipeline = HookPipeline(dataRoot: f.root.url, claudeDirectory: f.claude, port: 0, portRange: HookPipeline.testPortRange) { _ in }
        let store = try f.store(hooks: pipeline)
        await store.start()
        await eventually("listening") { pipeline.status.isListening }
        guard case .listening(let port) = pipeline.status, let token = pipeline.config?.token else {
            Issue.record("no endpoint")
            return
        }
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/hooks")))
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "X-CODD-Token")
        request.setValue(sessionUUID.uuidString.lowercased(), forHTTPHeaderField: "X-CODD-Session")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["hook_event_name": "UserPromptSubmit", "session_id": "c-1", "cwd": work,
                                   "prompt": "第一行\n第二行\t  結尾  "]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)
        let session = try #require(store.session(LayoutMapping.id(sessionUUID)))
        await eventually("lastPrompt") { session.lastPrompt == "第一行 第二行 結尾" }
        #expect(session.resendPrompt == "第一行\n第二行\t  結尾  ", "the whole prompt for D26 resends")
        let services = AppServices(store: store)
        #expect(await services.lastPrompt(for: session.id) == "第一行 第二行 結尾")
        #expect(HookPipeline.cleanPrompt(.string(String(repeating: "字", count: 300)))?.count == 200)
        #expect(HookPipeline.cleanPrompt(.string(" \n ")) == nil)
        await pipeline.shutdown()
        store.shutdown()
    }

    @Test func transcriptsAreCachedForTenSecondsAndAfterALaunchReadAgain() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        for i in 0..<6 { try f.transcript(UUID().uuidString.lowercased(), cwd: work, title: "對話 \(i)", lastPrompt: "最後 \(i)") }
        let store = try f.store()
        await store.start()
        let services = AppServices(store: store)
        let clock = ContinuousClock()
        var start = clock.now
        let cold = await services.transcripts(for: work)
        let coldTime = clock.now - start
        #expect(cold.count == 6)
        #expect(services.isTranscriptListCached(work))
        start = clock.now
        let warm = await services.transcripts(for: work)
        let warmTime = clock.now - start
        #expect(warm == cold)
        print(String(format: "MEASURE transcripts(for:) 6 files: cold %.3f ms, cached %.3f ms",
                     TerminalHub.milliseconds(coldTime), TerminalHub.milliseconds(warmTime)))
        store.transcriptsGeneration += 1
        #expect(!services.isTranscriptListCached(work), "a launch invalidates the cache")
        // The settings summary: read once, never written.
        try #"{"cleanupPeriodDays": 14, "model": "opus"}"#.write(toFile: f.claude.path + "/settings.json", atomically: true, encoding: .utf8)
        await services.loadClaudeSettings()
        #expect(services.claudeSettings == ClaudeUserSettingsSummary(cleanupPeriodDays: 14, model: "opus"))
        let dump = StateDump.object(store: store, dockBadge: nil, services: services)
        #expect(dump["cleanupPeriodDays"] as? Int == 14)
        #expect(dump["claudeModel"] as? String == "opus")
        store.shutdown()
    }
}

// MARK: - Archive (D19) and 刪除對話紀錄 (D23)

@MainActor
@Suite("Unarchive and delete history (D19, D23)", .serialized)
struct ArchiveAndDeleteTests {
    @Test func unarchivePutsSessionsBackAfterTheCODDRowsAndIsSaved() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let (a, b) = (UUID(), UUID())
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: a, projectId: projectID, kind: .claude, title: "a", pinned: true, order: 0, createdAt: Date()),
            SessionRecord(id: b, projectId: projectID, kind: .claude, title: "b", order: 1, createdAt: Date()),
        ])
        let store = try f.store()
        await store.start()
        store.applyRegistry([entry(pid: 9400, cwd: work)])
        let (aid, bid) = (LayoutMapping.id(a), LayoutMapping.id(b))
        let project = try #require(store.project(LayoutMapping.id(projectID)))
        _ = store.archive([aid])
        #expect(project.archivedCount == 1)
        #expect(store.archivedSessions(inProject: project.id).map(\.id) == [aid])
        #expect(store.pinnedSessionIDs.isEmpty)
        store.unarchive([aid])
        #expect(project.archivedCount == 0)
        let external = try #require(store.externalByID.keys.first)
        #expect(project.sessionIDs == [bid, aid, external])
        #expect(store.pinnedSessionIDs == [aid], "a pinned session comes back pinned")
        #expect(store.archivedSessions(inProject: project.id).isEmpty)
        store.flushLayout()
        let saved = try LayoutStore(fileURL: f.root.layoutURL).load()
        #expect(saved.sessions.allSatisfy { $0.archivedAt == nil })
        #expect(saved.sessions(inProject: projectID).map(\.id) == [b, a])
        store.shutdown()
    }

    @Test func deleteHistoryMovesExactlyTheConversationFilesToTheTrash() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let neighbour = try f.folder("work-other")
        let projectID = UUID()
        let sessionUUID = UUID()
        let id = LayoutMapping.id(sessionUUID)
        let current = UUID().uuidString.lowercased()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: sessionUUID, claudeSessionId: current, projectId: projectID, kind: .claude, title: "登入", order: 0,
                          createdAt: Date()),
        ])
        let currentFile = try f.transcript(current, cwd: work, sibling: true)
        let initialFile = try f.transcript(id, cwd: work)                     // before a /clear
        let unrelated = try f.transcript(UUID().uuidString.lowercased(), cwd: work)
        let otherCwd = try f.transcript(UUID().uuidString.lowercased(), cwd: neighbour)
        let trash = f.path + "/trash"
        let store = try f.store()
        store.trash = HolderSessionStore.trash(into: trash)
        await store.start()
        #expect(await store.deleteHistory(id))
        let trashed = Set((try? FileManager.default.contentsOfDirectory(atPath: trash)) ?? [])
        #expect(trashed == ["\(current).jsonl", current, "\(id).jsonl"])
        #expect(FileManager.default.fileExists(atPath: trash + "/\(current)/subagents/agent-1.jsonl"))
        #expect(!FileManager.default.fileExists(atPath: currentFile))
        #expect(!FileManager.default.fileExists(atPath: initialFile))
        #expect(FileManager.default.fileExists(atPath: unrelated))
        #expect(FileManager.default.fileExists(atPath: otherCwd))
        #expect(store.session(id) == nil)
        #expect(f.logs.values.contains("delete-history session=\(id) files=3"))
        store.flushLayout()
        #expect(try LayoutStore(fileURL: f.root.layoutURL).load().sessions.isEmpty)
        store.shutdown()
    }

    @Test func deleteHistoryRefusesARunningSessionAndAConversationInUse() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let projectID = UUID()
        let sessionUUID = UUID()
        let id = LayoutMapping.id(sessionUUID)
        let current = UUID().uuidString.lowercased()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: sessionUUID, claudeSessionId: current, projectId: projectID, kind: .claude, order: 0, createdAt: Date()),
        ])
        let file = try f.transcript(current, cwd: work)
        let trash = f.path + "/trash"
        let store = try f.store()
        store.trash = HolderSessionStore.trash(into: trash)
        await store.start()
        let session = try #require(store.session(id))
        store.transition(session, to: .idle)
        #expect(!(await store.deleteHistory(id)), "running")
        store.transition(session, to: .stopped)
        // Resumed by hand in another terminal: the registry says it is in use.
        store.applyRegistry([entry(pid: 9500, cwd: work, sessionId: current)])
        #expect(!(await store.deleteHistory(id)), "in use by a live claude")
        #expect(store.problem?.sessionID == id)
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: trash))
        #expect(store.session(id) != nil)
        // A file that cannot be moved keeps the session.
        store.applyRegistry([])
        store.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        #expect(!(await store.deleteHistory(id)))
        #expect(store.session(id) != nil)
        #expect(store.problem?.message.contains("無法把對話紀錄移到垃圾桶") == true)
        store.shutdown()
    }
}

// MARK: - State dump, mock, options, UI pieces

@MainActor
@Suite("Sessions data: dump, mock, options and UI (I2)", .serialized)
struct SessionsDataSurfaceTests {
    @Test func stateDumpCarriesTheI2Keys() async throws {
        let f = try Fixture()
        let work = try f.folder("work")
        let other = try f.folder("other")
        let projectID = UUID()
        let (a, b) = (UUID(), UUID())
        let group = try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: a, projectId: projectID, kind: .claude, title: "a", color: .red, pinned: true, order: 0, createdAt: Date()),
            SessionRecord(id: b, projectId: projectID, kind: .claude, title: "b", order: 1, createdAt: Date(), archivedAt: Date()),
        ])
        let store = try f.store()
        await store.start()
        store.applyRegistry([entry(pid: 9600, cwd: other)])
        let dump = StateDump.object(store: store, dockBadge: nil)
        let sessions = try #require(dump["sessions"] as? [[String: Any]])
        let ext = try #require(sessions.first { ($0["id"] as? String)?.hasPrefix("ext-9600-") == true })
        #expect(ext["external"] as? Bool == true)
        #expect(ext["externalPid"] as? Int == 9600)
        #expect(ext["hostSession"] is NSNull)
        let mine = try #require(sessions.first { $0["id"] as? String == LayoutMapping.id(a) })
        #expect(mine["external"] as? Bool == false)
        #expect(mine["tag"] as? String == "red")
        #expect(mine["pinned"] as? Bool == true)
        #expect(mine["stale"] as? Bool == false)
        #expect(mine["lastPrompt"] is NSNull)
        let projects = try #require(dump["projects"] as? [[String: Any]])
        #expect(projects.count == 2)
        #expect(projects.first?["group"] as? String == LayoutMapping.id(group.id))
        #expect(projects.last?["transient"] as? Bool == true)
        #expect(projects.first?["archivedCount"] as? Int == 1)
        let groups = try #require(dump["groupsInfo"] as? [[String: Any]])
        #expect(groups.first?["color"] as? String == "purple")
        #expect(dump["pinned"] as? [String] == [LayoutMapping.id(a)])
        #expect(dump["archived"] as? [String] == [LayoutMapping.id(b)])
        #expect((dump["profiles"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["claude-default", "claude-plan", "claude-rc", "zsh"])
        #expect(dump["defaultProfile"] as? String == "claude-default")
        #expect(dump["cleanupPeriodDays"] is NSNull)
        #expect(dump["groups"] as? [String] == ["CODD", "未分類"], "the M1 key is unchanged")
        store.shutdown()
    }

    @Test func mockExternalIsReadOnlyEverywhere() async throws {
        let store = MockSessionStore(shiftClock: false)
        let s14 = try #require(store.session("s14"))
        #expect(s14.external)
        #expect(s14.externalInfo?.pid == 48211)
        store.stop(["s14"])
        #expect(s14.state == .idle)
        _ = store.archive(["s14"])
        #expect(store.session("s14") != nil)
        #expect(!(await store.deleteHistory("s14")))
        // Mock unarchive round trip.
        _ = store.archive(["s6"])
        #expect(store.archivedSessions(inProject: "proto").map(\.id) == ["s6"])
        store.unarchive(["s6"])
        #expect(store.session("s6") != nil)
        #expect(store.archivedSessions(inProject: "proto").isEmpty)

        let shell = ShellState()
        let pane = SessionPaneViewController(store: store, accounts: MockAccountStore(), shell: shell,
                                             surfaceFactory: FakeTerminalSurfaceFactory { _ in "" })
        _ = pane.view
        #expect(pane.readOnlyContent(s14).lines == ["// 這個 session 在 CODD 外面執行（pid 48211 · cli）· CODD 只讀取狀態，不能在這裡輸入"])
        #expect(pane.readOnlyContent(s14).action == nil)
        shell.currentSessionID = "s14"
        #expect(!pane.canAllowCurrent)
    }

    @Test func externalAndTransientMenusOfferOnlyWhatAppliesToThem() throws {
        let h = SidebarHarness()
        h.controller.applyNow()
        let row = h.controller.outline.row(forItem: h.controller.item(for: .session("s14", .tree)))
        #expect(row >= 0)
        let menu = try #require(h.controller.contextMenu(forRow: row))
        #expect(menu.items.map(\.title) == ["Session · LINE bot 測試", "複製 session ID", "$  複製 resume 指令", "↗  在 Terminal.app 開啟"])
        #expect(h.controller.outlineView(h.controller.outline, pasteboardWriterForItem: h.controller.item(for: .session("s14", .tree))) == nil)
        #expect(h.controller.outlineView(h.controller.outline, pasteboardWriterForItem: h.controller.item(for: .session("s13", .tree))) != nil)
    }

    @Test func optionsParseTheI2Flags() {
        let options = RealModeOptions.parse(arguments: [
            "CODD", "-codd-new-claude", "/w", "-codd-new-profile", "acct-2", "-codd-resume-transcript", "3F2A91C0-0000-0000-0000-000000000000",
            "-codd-stale-after", "5", "-codd-trash-dir", "~/t", "-codd-delete-history", "ABC", "-codd-list-transcripts", "/w",
        ], environment: [:], home: "/Users/x")
        #expect(options.newClaudeCwd == "/w")
        #expect(options.newProfile == "acct-2")
        #expect(options.resumeTranscript == "3F2A91C0-0000-0000-0000-000000000000")
        #expect(options.staleAfterSeconds == 5)
        #expect(options.trashDir == "/Users/x/t")
        #expect(options.deleteHistory == "abc")
        #expect(options.listTranscripts == "/w")
        let release = options.releaseSubset
        #expect(release.trashDir == nil && release.deleteHistory == nil && release.staleAfterSeconds == nil && release.newProfile == nil)
    }
}

// MARK: - M2 review round 1

@MainActor
@Suite("M2 review fixes: resume, registry, resend, realpath", .serialized)
struct M2ReviewSessionFixTests {
    /// Review correctness-2: two claudes never `--resume` one conversation.
    @Test func resumeRefusesAConversationAnotherClaudeRunsAndAPickedTranscriptResumesItsSession() async throws {
        let f = try Fixture("codd-fix-resume")
        let work = try f.folder("work")
        let projectID = UUID()
        let sessionUUID = UUID()
        let id = LayoutMapping.id(sessionUUID)
        let conversation = UUID().uuidString.lowercased()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: sessionUUID, claudeSessionId: conversation, projectId: projectID, kind: .claude, title: "登入",
                          order: 0, createdAt: Date()),
        ])
        try f.transcript(conversation, cwd: work, title: "登入")
        let store = try f.store(launcher: f.launcher(claudePath: try f.fakeClaude()))
        await store.start()
        #expect(store.session(id)?.state == .stopped)
        // Resumed by hand in Terminal.app: RESUME in CODD is refused.
        store.applyRegistry([entry(pid: 9600, cwd: work, sessionId: conversation)])
        #expect(store.isConversationInUse(id))
        store.resume(id)
        #expect(store.session(id)?.state == .stopped, "no second claude")
        #expect(store.problem?.message == HolderSessionStore.conversationRunningMessage)
        var request = NewSessionRequest(cwd: work, kind: .claude)
        request.claude.mode = .resume(conversation)
        #expect(store.createSession(request) == nil, "the picker cannot start it either")
        #expect(store.lastRefusal == HolderSessionStore.conversationRunningMessage)
        // Gone from the registry: a picked transcript of a stopped CODD session resumes that session.
        store.applyRegistry([])
        #expect(!store.isConversationInUse(id))
        let sessions = store.allSessions.count
        #expect(store.createSession(request) == id, "no twin session")
        #expect(store.allSessions.count == sessions)
        await eventually("resumed") { f.logs.values.contains { $0.hasPrefix("spawned session=\(id) ") && $0.hasSuffix("resume=\(conversation)") } }
        #expect(store.createSession(request) == nil, "running: refused")
        #expect(store.lastRefusal?.contains("正在 CODD 的 session") == true)
        store.stop([id])
        await eventually("stopped") { !(store.session(id)?.state.isLive ?? true) }
        store.shutdown()
    }

    /// Review correctness-3: a typed model claude cannot take never becomes a saved session.
    @Test func anInvalidModelIsRefusedBeforeTheSessionIsSaved() async throws {
        let f = try Fixture("codd-fix-model")
        let work = try f.folder("work")
        let store = try f.store(launcher: f.launcher(claudePath: try f.fakeClaude()))
        await store.start()
        var request = NewSessionRequest(cwd: work, kind: .claude)
        request.claude.model = "opus 4"
        #expect(store.createSession(request) == nil)
        #expect(store.lastRefusal == NewSessionForm.invalidModelMessage("opus 4"))
        #expect(store.allSessions.isEmpty && store.records.isEmpty)
        var form = NewSessionForm()
        form.path = work
        form.modelChoice = .other
        for bad in ["opus 4", "-x", "a\tb"] {
            form.customModel = bad
            #expect(form.problem == NewSessionForm.invalidModelMessage(bad), "\(bad)")
        }
        for good in ["claude-opus-4-5", "  sonnet  ", ""] {
            form.customModel = good
            #expect(form.problem == nil, "\(good)")
        }
        store.shutdown()
    }

    /// Review e2e-3: the in-use checks wait for the registry's first snapshot.
    @Test func inUseChecksWaitForTheFirstRegistrySnapshot() async throws {
        let f = try Fixture("codd-fix-registry")
        let work = try f.folder("work")
        let projectID = UUID()
        let sessionUUID = UUID()
        let id = LayoutMapping.id(sessionUUID)
        let conversation = UUID().uuidString.lowercased()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: sessionUUID, claudeSessionId: conversation, projectId: projectID, kind: .claude, order: 0, createdAt: Date()),
        ])
        let file = try f.transcript(conversation, cwd: work)
        let pipeline = HookPipeline(dataRoot: f.root.url, claudeDirectory: f.claude, port: 0, portRange: HookPipeline.testPortRange) { _ in }
        let store = try f.store(hooks: pipeline)
        let trash = f.path + "/trash"
        store.trash = HolderSessionStore.trash(into: trash)
        await store.start()
        await eventually("first snapshot") { store.registrySeen }
        // As if it had not come yet: nothing is trashed on an empty guess.
        store.registrySeen = false
        let started = ContinuousClock.now
        #expect(!(await store.deleteHistory(id)))
        #expect(ContinuousClock.now - started >= .seconds(1.5), "it waited")
        #expect(store.problem?.message == "還在讀取 claude 的 session 清單，請稍候再試一次。")
        #expect(FileManager.default.fileExists(atPath: file))
        // A snapshot that arrives while waiting answers the waiter at once.
        let waiting = Task { await store.waitForRegistry(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        store.applyRegistry([entry(pid: 9700, cwd: work, sessionId: conversation)])
        #expect(await waiting.value)
        #expect(!(await store.deleteHistory(id)), "in use by the external claude")
        #expect(FileManager.default.fileExists(atPath: file))
        await pipeline.shutdown()
        store.shutdown()
    }

    /// Review correctness-1 / security-data-2: after a relaunch the resend comes from the
    /// transcript, whole; the hook's whole prompt wins once there is one.
    @Test func resendPromptFallsBackToTheWholeTranscriptPrompt() async throws {
        let f = try Fixture("codd-fix-resend")
        let work = try f.folder("work")
        let projectID = UUID()
        let sessionUUID = UUID()
        let id = LayoutMapping.id(sessionUUID)
        let conversation = UUID().uuidString.lowercased()
        try f.seed(projects: [(projectID, work)], sessions: [
            SessionRecord(id: sessionUUID, claudeSessionId: conversation, projectId: projectID, kind: .claude, order: 0, createdAt: Date()),
        ])
        let prompt = String(repeating: "把 token 過期的處理改寫，", count: 30) + "\n但是絕對不要刪 backups/ 和 db/ 底下的任何檔案。"
        let folder = f.claude.path + "/projects/" + TranscriptCatalog.folderName(for: work)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let lines: [[String: Any]] = [
            ["type": "user", "sessionId": conversation, "cwd": work, "message": ["role": "user", "content": "舊的"]],
            ["type": "user", "sessionId": conversation, "cwd": work, "message": ["role": "user", "content": prompt]],
            ["type": "last-prompt", "lastPrompt": String(prompt.prefix(100)), "sessionId": conversation],
        ]
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
        try (text + "\n").write(toFile: folder + "/" + conversation + ".jsonl", atomically: true, encoding: .utf8)
        let store = try f.store()
        await store.start()
        let services = AppServices(store: store)
        #expect(await services.resendPrompt(for: id) == prompt)
        #expect((await services.lastPrompt(for: id))?.count ?? 0 <= 200, "the hover card keeps the short form")
        store.applyPrompt("短", full: "短的完整版\n第二行", for: sessionUUID)
        #expect(await services.resendPrompt(for: id) == "短的完整版\n第二行")
        store.shutdown()
    }

    /// Review concurrency-perf-5: a project folder that does not resolve is not resolved again on
    /// every lookup, and project folders are resolved off the main actor after the load.
    @Test func projectLookupCachesFoldersThatDoNotResolve() async throws {
        let f = try Fixture("codd-fix-realpath")
        let work = try f.folder("work")
        let gone = try f.folder("gone")
        try f.seed(projects: [(UUID(), work), (UUID(), gone)], sessions: [])
        let store = try f.store()
        await store.start()
        await eventually("prewarmed") { store.realpathCache[HolderSessionStore.standardize(work)]?.real != nil }
        try FileManager.default.removeItem(atPath: gone)
        store.realpathCache = [:]
        _ = store.project(forPath: f.path + "/elsewhere")
        let key = HolderSessionStore.standardize(gone)
        let first = try #require(store.realpathCache[key])
        #expect(first.real == nil)
        _ = store.project(forPath: f.path + "/elsewhere-2")
        #expect(store.realpathCache[key]?.at == first.at, "not tried again within realpathRetry")
        _ = store.resolvedPath(key, now: first.at.addingTimeInterval(HolderSessionStore.realpathRetry + 1))
        #expect(store.realpathCache[key]?.at != first.at, "tried again later (a folder may come back)")
        #expect(store.project(forPath: work)?.cwd == work)
        store.shutdown()
    }
}
