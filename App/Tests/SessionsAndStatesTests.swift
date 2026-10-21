import CoddCore
import CoddHooks
import Darwin
import Foundation
import Testing
@testable import CODD

/// A temporary directory removed with the value (short `$TMPDIR` path: socket paths stay small).
private final class TempDir: Sendable {
    let path: String

    init(_ prefix: String = "codd-s") throws {
        var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
        let created = try #require(mkdtemp(&template))
        path = CoddDataRoot(path: String(cString: created)).path
    }

    deinit { try? FileManager.default.removeItem(atPath: path) }

    func folder(_ name: String) throws -> String {
        let dir = path + "/" + name
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }
}

@Suite("New session form")
struct NewSessionFormTests {
    @Test func requestCarriesKindNameTagAndClaudeOptions() {
        var form = NewSessionForm()
        form.path = "/Users/tester/Github/app/"
        form.setName("  修正\u{7}登入  ")
        form.tag = .pink
        form.permissionMode = "acceptEdits"
        form.modelChoice = .other
        form.customModel = " opus-5.5 "
        form.groupID = "g1"
        let request = form.request
        #expect(request.cwd == "/Users/tester/Github/app")
        #expect(request.kind == .claude)
        #expect(request.name == "修正登入")
        #expect(request.tag == .pink)
        #expect(request.groupID == "g1")
        #expect(request.sessionID == form.sessionID)
        #expect(request.claude.permissionMode == "acceptEdits")
        #expect(request.claude.model == "opus-5.5")
        let id = form.sessionID.uuidString.lowercased()
        #expect(form.commandPreview() == "claude --session-id \(id.prefix(8))-… --model opus-5.5 --permission-mode acceptEdits -n \"修正登入\"")
    }

    @Test func shellIgnoresClaudeOnlyOptionsAndBlankIsInvalid() {
        var form = NewSessionForm()
        #expect(!form.isValid)
        form.path = "   "
        #expect(!form.isValid)
        form.path = "relative/dir"
        #expect(!form.isValid)
        form.path = "~"
        #expect(form.isValid)
        #expect(form.resolvedPath == NSHomeDirectory())
        form.kind = .shell
        form.permissionMode = "plan"
        form.modelChoice = .opus
        #expect(form.request.claude.permissionMode == nil)
        #expect(form.request.claude.model == nil)
        #expect(form.commandPreview() == "zsh -l")
    }

    @Test func dropdownListsKnownProjectsFirstAndSuggestsOnlyNewFolders() {
        let now = Date()
        let known = [
            ProjectChoice(path: "/p/old", name: "old", tag: .red, isKnown: true, lastUsed: now.addingTimeInterval(-500)),
            ProjectChoice(path: "/p/new", name: "new", tag: nil, isKnown: true, lastUsed: now),
            ProjectChoice(path: "/p/never", name: "never", tag: nil, isKnown: true, lastUsed: nil),
        ]
        let recent = [RecentProject(path: "/p/new/", lastUsed: now), RecentProject(path: "/q/fresh", lastUsed: now)]
        let lists = ProjectDropdownModel.build(query: nil, known: known, recent: recent, chosenPath: nil)
        #expect(lists.recent.compactMap(\.choice?.name) == ["new", "old", "never"])
        #expect(lists.suggested.compactMap(\.choice?.path) == ["/q/fresh"])
        #expect(lists.suggested.allSatisfy { $0.choice?.isKnown == false })
    }
}

@Suite("Recent projects (.claude.json)")
struct RecentProjectsTests {
    @Test func transcriptFolderNameMatchesClaudeCode() {
        #expect(RecentProjectsReader.transcriptFolderName(for: "/Users/a/My Proj_1") == "-Users-a-My-Proj-1")
        // Every UTF-16 unit outside [A-Za-z0-9] becomes one `-` (JavaScript `replace`).
        #expect(RecentProjectsReader.transcriptFolderName(for: "/x/整合") == "-x---")
    }

    @Test func readsExistingFoldersNewestFirstFromTheParentClaudeJSON() throws {
        let temp = try TempDir()
        let a = try temp.folder("work/a")
        let b = try temp.folder("work/b")
        let claude = try temp.folder("claude")
        let transcripts = try temp.folder("claude/projects")
        for (path, age) in [(a, 3600.0), (b, 60.0)] {
            let dir = transcripts + "/" + RecentProjectsReader.transcriptFolderName(for: path)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: dir)
        }
        let object: [String: Any] = ["projects": [a: [:], b: [:], "/does/not/exist": [:], "relative": [:],
                                                  temp.path + "/.claude-worktrees/x": [:]]]
        try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: temp.path + "/.claude.json"))
        let projects = RecentProjectsReader.read(ClaudeDirectory(path: claude + "/"))
        #expect(projects.map(\.path) == [b, a])
        #expect(projects.first?.name == "b")
        #expect(RecentProjectsReader.read(ClaudeDirectory(path: temp.path + "/no/such/claude")).isEmpty)
    }
}

@Suite("Layout mapping")
@MainActor
struct LayoutMappingTests {
    @Test func roundTripKeepsOrderColorsPinsCollapseArchiveAndViewed() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let g1 = ProjectGroup(name: "藍鵲 · 網站", color: .blue, order: 0)
        let g2 = ProjectGroup(name: "CODD", color: .purple, order: 1, collapsed: true)
        let p1 = Project(groupId: g1.id, name: "backend", path: "/w/backend", order: 0, collapsed: true)
        let p2 = Project(groupId: g2.id, name: "app", path: "/w/app", order: 0)
        let p3 = Project(groupId: UUID(), name: "lost", path: "/w/lost", order: 0)
        let s1 = SessionRecord(claudeSessionId: "c1", projectId: p1.id, kind: .claude, title: "learned", titleOverride: "mine",
                               color: .red, pinned: true, order: 1, createdAt: now, lastViewedAt: now)
        let s2 = SessionRecord(projectId: p1.id, kind: .shell, order: 0, createdAt: now)
        let s3 = SessionRecord(projectId: p2.id, kind: .claude, order: 0, createdAt: now, archivedAt: now)
        let layout = Layout(groups: [g2, g1], projects: [p1, p2, p3], sessions: [s1, s2, s3])

        let model = LayoutMapping.model(from: layout)
        #expect(model.groups.map(\.name) == ["藍鵲 · 網站", "CODD", "未分類"])
        #expect(model.groups[0].shortName == "藍鵲·網站")
        #expect(model.groups[1].isCollapsed)
        #expect(model.groups.last?.isUngrouped == true)
        // A project whose group is gone lands in the ungrouped bucket.
        #expect(model.groups.last?.projectIDs == [LayoutMapping.id(p3.id)])
        let backend = try #require(model.projects[LayoutMapping.id(p1.id)])
        #expect(backend.sessionIDs == [LayoutMapping.id(s2.id), LayoutMapping.id(s1.id)])
        #expect(backend.isCollapsed)
        let first = try #require(model.sessions[LayoutMapping.id(s1.id)])
        #expect(first.title == "mine")
        #expect(first.tag == .red)
        #expect(first.isPinned)
        #expect(first.state == .stopped)
        #expect(first.claudeSessionID == "c1")
        #expect(model.sessions[LayoutMapping.id(s2.id)]?.state == .exited)
        #expect(model.archived[LayoutMapping.id(s3.id)] != nil)
        #expect(model.pinned == [LayoutMapping.id(s1.id)])

        let back = LayoutMapping.layout(groups: model.groups, projects: model.projects, sessions: model.sessions,
                                        archived: model.archived, records: model.records, projectRecords: model.projectRecords, now: now)
        #expect(back.orderedGroups.map(\.id) == [g1.id, g2.id])
        #expect(back.groups.first { $0.id == g2.id }?.collapsed == true)
        #expect(back.projects.first { $0.id == p3.id }?.groupId == nil)
        #expect(back.projects.first { $0.id == p1.id }?.collapsed == true)
        let row = try #require(back.sessions.first { $0.id == s1.id })
        #expect(row.order == 1)
        #expect(row.color == .red)
        #expect(row.pinned)
        #expect(row.lastViewedAt == now)
        #expect(row.claudeSessionId == "c1")
        #expect(row.lastState == .stopped)
        #expect(back.sessions.first { $0.id == s3.id }?.archivedAt == now)
        // Stable: mapping the result again changes nothing.
        let again = LayoutMapping.model(from: back)
        #expect(again.groups.map(\.id) == model.groups.map(\.id))
    }
}

@Suite("codd-hook copies")
struct CoddHookBinaryTests {
    @Test func referencedPathsAreReadFromTheSettingsArgument() {
        let root = CoddDataRoot(path: "/r/data")
        let plain = "{\"command\":\"/r/data/bin/codd-hook-0123456789ab\",\"type\":\"command\"}"
        let escaped = "{\"command\":\"\\/r\\/data\\/bin\\/codd-hook-aaaaaaaaaaaa\"}"
        let argvs = [["claude", "--settings", plain], ["claude", "--settings", escaped],
                     ["claude", "--settings", "{\"command\":\"/other/bin/codd-hook-bbbbbbbbbbbb\"}"],
                     ["claude", "/r/data/bin/codd-hook-XYZ"], ["zsh", "-l"]]
        #expect(CoddHookBinary.referencedPaths(in: argvs, root: root)
            == ["/r/data/bin/codd-hook-0123456789ab", "/r/data/bin/codd-hook-aaaaaaaaaaaa"])
    }
}

@Suite("Notifications rule")
@MainActor
struct NotificationRuleTests {
    @Test func onlyIntoWaitingOrErrorWhileNotFocused() {
        #expect(SessionNotifier.shouldNotify(from: .busy, to: .waiting, focused: false, enabled: true))
        #expect(SessionNotifier.shouldNotify(from: .busy, to: .error, focused: false, enabled: true))
        #expect(!SessionNotifier.shouldNotify(from: .busy, to: .waiting, focused: true, enabled: true))
        #expect(!SessionNotifier.shouldNotify(from: .busy, to: .waiting, focused: false, enabled: false))
        #expect(!SessionNotifier.shouldNotify(from: .waiting, to: .waiting, focused: false, enabled: true))
        for state in [CODD.SessionState.busy, .idle, .done, .exited, .stopped, .starting] {
            #expect(!SessionNotifier.shouldNotify(from: .waiting, to: state, focused: false, enabled: true))
        }
    }

    @Test func bannerTextNamesTheSessionAndWhatItNeeds() {
        let session = SessionVM(id: "s", projectID: "p", title: "修正登入 API 401", state: .waiting, stateSince: Date())
        session.waitingReason = .permission
        session.tool = "Bash"
        session.detail = "npm test -- auth.spec.ts"
        let waiting = SessionNotifier.content(for: session, projectName: "orb-toolkit-backend")
        #expect(waiting.title == "◆ 修正登入 API 401 需要授權")
        #expect(waiting.body == "orb-toolkit-backend · Bash: npm test -- auth.spec.ts")
        session.state = .error
        session.errorReason = "OVERLOADED"
        #expect(SessionNotifier.content(for: session, projectName: nil).title == "▲ 修正登入 API 401 失敗 · API 過載（529 overloaded）")
    }
}

@Suite("Hook tool detail")
struct HookToolDetailTests {
    private func payload(_ object: [String: JSONValue]) -> HookPayload { HookPayload(object: object) }

    @Test func permissionRequestSummarizesTheCommand() {
        let update = HookToolDetail.update(for: payload([
            "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": .object(["command": "npm   test\n-- auth.spec.ts"]),
        ]))
        #expect(update == .set(HookToolDetail(tool: "Bash", summary: "npm test -- auth.spec.ts")))
        let edit = HookToolDetail.update(for: payload([
            "hook_event_name": "PreToolUse", "tool_name": "Edit", "cwd": "/w/app",
            "tool_input": .object(["file_path": "/w/app/src/a.ts"]),
        ]))
        #expect(edit == .set(HookToolDetail(tool: "Edit", summary: "src/a.ts")))
    }

    @Test func askUserQuestionKeepsQuestionAndOptions() {
        let update = HookToolDetail.update(for: payload([
            "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
            "tool_input": .object(["questions": .array([.object([
                "question": "CSV 要用哪種編碼？",
                "options": .array([.object(["label": "UTF-8 with BOM"]), .object(["label": "Big5"])]),
            ])])]),
        ]))
        #expect(update == .set(HookToolDetail(tool: "AskUserQuestion", summary: "CSV 要用哪種編碼？", question: "CSV 要用哪種編碼？",
                                              options: ["UTF-8 with BOM", "Big5"])))
    }

    @Test func turnBoundariesClearAndOtherEventsKeep() {
        for event in ["Stop", "UserPromptSubmit", "PostToolUse", "SessionStart"] {
            #expect(HookToolDetail.update(for: payload(["hook_event_name": .string(event)])) == .clear, "\(event)")
        }
        #expect(HookToolDetail.update(for: payload(["hook_event_name": "Notification"])) == nil)
        #expect(HookToolDetail.update(for: payload(["hook_event_name": "PreToolUse"])) == nil)
    }
}

/// The real store driven by engine batches (no hook server, no claude): a layout in a temporary
/// data root, holders spawned only where a test says so.
@MainActor
@Suite("Store: hook states and persisted layout", .serialized)
final class HookStateStoreTests {
    private let temp: TempDir
    private let root: CoddDataRoot

    init() throws {
        temp = try TempDir("codd-st")
        root = CoddDataRoot(path: temp.path)
    }

    deinit {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", temp.path + "/"]
        try? pkill.run()
        pkill.waitUntilExit()
    }

    private func launcher() throws -> HolderLauncher {
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        return HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"])
    }

    private func store() throws -> HolderSessionStore {
        try HolderSessionStore(root: root, launcher: launcher()) { _ in }
    }

    /// One claude session (never started in this run) in a grouped project.
    private func seedLayout(viewedAt: Date? = nil) throws -> (session: UUID, project: UUID) {
        let group = ProjectGroup(name: "CODD", color: .purple, order: 0)
        let project = Project(groupId: group.id, name: "app", path: try temp.folder("work"), order: 0)
        let session = SessionRecord(claudeSessionId: "claude-1", projectId: project.id, kind: .claude, title: "fix login", order: 0,
                                    createdAt: Date(timeIntervalSinceNow: -600), lastViewedAt: viewedAt)
        try LayoutStore(fileURL: root.layoutURL).save(Layout(groups: [group], projects: [project], sessions: [session]))
        return (session.id, project.id)
    }

    private func update(_ id: UUID, _ state: CoddCore.SessionState, since: Date = Date(), hookSession: String? = nil,
                        title: String? = nil) -> SessionStateUpdate {
        let activity = SessionActivity(state: .idle, since: JSDate.isoString(since))
        let hook = HookSessionState(sessionId: hookSession, customTitle: title)
        return SessionStateUpdate(sessionID: id, state: state, activity: activity, hook: hook, hookSeen: true, title: nil, registry: nil)
    }

    @Test func goneClaudeSessionIsStoppedAndBatchesDriveItsState() async throws {
        let seeded = try seedLayout()
        let store = try store()
        var transitions: [(String, CODD.SessionState, CODD.SessionState)] = []
        store.onTransition = { session, old in transitions.append((session.id, old, session.state)) }
        await store.start()
        let id = LayoutMapping.id(seeded.session)
        let session = try #require(store.session(id))
        #expect(session.state == .stopped)
        #expect(session.kind == .claude)
        #expect(session.title == "fix login")
        #expect(session.claudeSessionID == "claude-1")
        #expect(store.groups.map(\.name) == ["CODD", "未分類"])

        store.applyDetail(.set(HookToolDetail(tool: "Bash", summary: "npm test")), for: seeded.session)
        store.apply(SessionStateBatch(updates: [update(seeded.session, .waiting(.permission), hookSession: "claude-2",
                                                       title: "Fix the login bug")], removed: []))
        #expect(session.state == .waiting)
        #expect(session.waitingReason == .permission)
        #expect(session.tool == "Bash")
        #expect(session.detail == "npm test")
        #expect(session.claudeSessionID == "claude-2", "RESUME follows the latest Claude session id")
        #expect(store.record(id)?.claudeSessionId == "claude-2")
        #expect(session.title == "Fix the login bug")
        #expect(transitions.last.map { "\($0.1)->\($0.2)" } == "stopped->waiting")

        store.apply(SessionStateBatch(updates: [update(seeded.session, .error(.overloaded))], removed: []))
        #expect(session.state == .error)
        #expect(session.errorReason == "OVERLOADED")
        #expect(session.tool == nil)

        // Finished while the user looks at it: IDLE, and the viewing time is remembered.
        store.isViewing = { $0 == id }
        let finished = Date()
        store.apply(SessionStateBatch(updates: [update(seeded.session, .done, since: finished)], removed: []))
        #expect(session.state == .idle)
        #expect((store.record(id)?.lastViewedAt ?? .distantPast) >= finished.addingTimeInterval(-1))
        store.isViewing = nil
        store.apply(SessionStateBatch(updates: [update(seeded.session, .done)], removed: []))
        #expect(session.state == .done)
        store.shutdown()
    }

    @Test func layoutIntentsPersistAcrossLaunches() async throws {
        let seeded = try seedLayout()
        let first = try store()
        await first.start()
        let other = try temp.folder("other")
        let group = first.addGroup(name: " 藍鵲 · 實驗室 ", color: .orange)
        let project = try #require(first.addProject(path: other + "/", groupID: group))
        #expect(first.addProject(path: other, groupID: nil) == project, "a folder is one project")
        #expect(first.addProject(path: temp.path + "/missing", groupID: nil) == nil)
        first.renameProject(project, to: "研發")
        first.setCollapsed(true, project: project)
        first.moveGroups([group], toIndex: 0)
        let sessionID = LayoutMapping.id(seeded.session)
        first.setTag(.green, sessions: [sessionID])
        first.setPinned(true, sessions: [sessionID])
        first.renameSession(sessionID, to: "改名")
        first.flushLayout()

        let second = try store()
        await second.start()
        #expect(second.groups.map(\.name) == ["藍鵲 · 實驗室", "CODD", "未分類"])
        #expect(second.group(group)?.color == .orange)
        #expect(second.group(group)?.projectIDs == [project])
        #expect(second.project(project)?.name == "研發")
        #expect(second.project(project)?.isCollapsed == true)
        #expect(second.session(sessionID)?.tag == .green)
        #expect(second.session(sessionID)?.title == "改名")
        #expect(second.pinnedSessionIDs == [sessionID])
        first.shutdown()
        second.shutdown()
    }

    @Test func removingARunningSessionEndsItsHolderAndForgetsIt() async throws {
        let store = try store()
        await store.start()
        let work = try temp.folder("shell")
        let id = try #require(store.createSession(NewSessionRequest(cwd: work, kind: .shell, tag: .cyan)))
        let deadline = ContinuousClock.now + .seconds(5)
        while store.session(id)?.state != .shell, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(store.session(id)?.state == .shell)
        #expect(store.session(id)?.tag == .cyan)
        let holder = try #require(store.runtime(id)?.holderPid)
        let projectID = try #require(store.session(id)?.projectID)
        store.removeProject(projectID)
        #expect(store.session(id) == nil)
        #expect(store.project(projectID) == nil)
        let gone = ContinuousClock.now + .seconds(5)
        while kill(holder, 0) == 0, ContinuousClock.now < gone { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(kill(holder, 0) != 0, "the holder was ended")
        while FileManager.default.fileExists(atPath: root.sessionDirectory(id)), ContinuousClock.now < gone {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: root.sessionDirectory(id)))
        store.flushLayout()
        let saved = try LayoutStore(fileURL: root.layoutURL).load()
        #expect(saved.sessions.isEmpty)
        #expect(saved.projects.isEmpty)
        store.shutdown()
    }

    @Test func missingClaudeIsAClearErrorOnTheSession() async throws {
        var launcher = try launcher()
        launcher.claudePathOverride = nil
        // Nothing is executable: `claude` is on neither the PATH nor ~/.local/bin.
        launcher.isExecutable = { _ in false }
        let work = try temp.folder("c")
        do {
            _ = try launcher.planClaude(sessionID: UUID(), cwd: work, options: ClaudeLaunchOptions(), hooks: nil,
                                        loginEnvironment: ["PATH": "/nonexistent"])
            Issue.record("claude resolved although nothing is executable")
        } catch {
            #expect(error == .claudeNotFound("/nonexistent"))
            #expect(error.userMessage.contains("找不到 claude"))
        }

        // Through the store: the session stops with the message the pane shows as its banner.
        let store = HolderSessionStore(root: root, launcher: launcher) { _ in }
        await store.start()
        let id = try #require(store.createSession(NewSessionRequest(cwd: work, kind: .claude)))
        let deadline = ContinuousClock.now + .seconds(10)
        while store.session(id)?.launchError == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(store.session(id)?.state == .stopped)
        #expect(store.session(id)?.launchError?.contains("找不到 claude") == true)
        store.shutdown()
    }

    @Test func stateDumpListsSessionsAndHooks() async throws {
        let seeded = try seedLayout()
        let store = try store()
        await store.start()
        let object = StateDump.object(store: store, dockBadge: "1")
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        #expect(sessions.first?["id"] as? String == LayoutMapping.id(seeded.session))
        #expect(sessions.first?["state"] as? String == "stopped")
        #expect(sessions.first?["claudeSessionId"] as? String == "claude-1")
        #expect((object["hooks"] as? [String: Any])?["status"] as? String == "disabled")
        #expect(object["dockBadge"] as? String == "1")
        store.shutdown()
    }
}
