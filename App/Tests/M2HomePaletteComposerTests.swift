import AppKit
import CoddComposer
import CoddCore
import CoddHooks
import Darwin
import Foundation
import Testing
@testable import CODD
import CoddUI

/// M2 step I4: the Home models (NEEDS YOU cards, LAUNCH, RECENTLY STOPPED, D29), the ⌘K quick
/// switch model and panel (D14, ⌘⏎ never reaches 允許), the composer (⌘L, drafts, send path, held
/// input, pasted images, panes.json) and the error banner's actions (D26). Temp folders only; the
/// real-store fixtures use a temp data root and Claude directory, children are `cat`.

private func makeTemp(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    return CoddDataRoot(path: String(cString: created)).path
}

private func removeTemp(_ path: String) {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-KILL", "-f", path + "/"]
    try? pkill.run()
    pkill.waitUntilExit()
    try? FileManager.default.removeItem(atPath: path)
}

private func realpathOf(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

@MainActor
private func settle(_ milliseconds: Int = 60) async {
    try? await Task.sleep(for: .milliseconds(milliseconds))
}

@MainActor
private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "timed out waiting for \(what)")
}

private func registryEntry(pid: Int, cwd: String, sessionId: String, status: String? = "busy", waitingFor: String? = nil) -> ClaudeRegistryEntry {
    ClaudeRegistryEntry(pid: pid, sessionId: sessionId, cwd: cwd, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        version: "2.1.300", kind: "interactive", entrypoint: "cli", name: "外部 claude", status: status,
                        waitingFor: waitingFor, statusTimestampMilliseconds: nil)
}

/// A temp data root, Claude directory and work folder, plus a real store on them.
@MainActor
private final class RealFixture {
    let path: String
    let root: CoddDataRoot
    let claude: ClaudeDirectory

    init() throws {
        path = try makeTemp("codd-i4")
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

    func store() throws -> HolderSessionStore {
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"])
        launcher.coddHookPath = "/usr/bin/true"
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: claude, hooks: nil) { _ in }
        store.processAncestors = { _ in [1] }
        return store
    }

    func seed(project: UUID, path cwd: String, sessions: [SessionRecord]) throws {
        let group = ProjectGroup(name: "CODD", color: .purple, order: 0)
        let row = Project(id: project, groupId: group.id, name: (cwd as NSString).lastPathComponent, path: cwd, order: 0)
        try LayoutStore(fileURL: root.layoutURL).save(Layout(groups: [group], projects: [row], sessions: sessions))
    }

    /// A transcript of `cwd` with id `id`, last modified `age` seconds ago.
    func transcript(_ id: String, cwd: String, title: String, age: TimeInterval) throws {
        let folder = claude.path + "/projects/" + TranscriptCatalog.folderName(for: cwd)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","sessionId":"\#(id)","cwd":"\#(cwd)","gitBranch":"main","timestamp":"2026-10-10T00:00:00.000Z","uuid":"u1","message":{"role":"user","content":"請修好登入"}}"#,
            #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(id)"}"#,
        ]
        let file = folder + "/" + id + ".jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file)
    }

    deinit { removeTemp(path) }
}

// MARK: - Home models

@MainActor
@Suite("Home models (I4)")
struct HomeModelTests {
    private func model(_ store: MockSessionStore, inputs: HomeModel.Inputs = .init()) -> HomeModel {
        var inputs = inputs
        inputs.sessionOrder = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "").sessionOrder
        return HomeModel.build(store: store, inputs: inputs, now: MockData.referenceDate)
    }

    @Test func needsYouCardsFollowTheArtboard() throws {
        let store = MockSessionStore(shiftClock: false)
        let home = model(store)
        #expect(home.counts == HomeModel.Counts(live: 13, needsYou: 3, working: 4, exited: 1))
        #expect(home.needsYou.map(\.id) == ["s1", "s2", "s3"])
        let s1 = home.needsYou[0]
        #expect(s1.head == "Waiting · Permission")
        #expect(s1.reason == .code("Bash: npm test -- auth.spec.ts", nil))
        #expect(s1.location == "藍鵲·網站 / orb-toolkit-backend")
        #expect(s1.canAllow)
        #expect(s1.number == 1)
        #expect(s1.meta == "opus-5.5 · ◉ rc")
        let s2 = home.needsYou[1]
        #expect(s2.head == "Waiting · Question")
        #expect(s2.reason == .quote("「CSV 要用 UTF-8 BOM 還是 Big5？」"))
        #expect(!s2.canAllow, "only permission waits get [1 允許]")
        let s3 = home.needsYou[2]
        #expect(s3.head == "Error · Overloaded")
        #expect(s3.reason == .code("API 529", "overloaded · 本輪未完成"))
        #expect(!s3.canAllow)
        #expect(home.done == HomeModel.DoneLine(count: 1, id: "s4", title: "第二版原型 · 審查流程", location: "藍鵲·實驗室 / 原型試做",
                                                since: try #require(store.session("s4")).stateSince))
    }

    @Test func externalsNeverOfferAllow() throws {
        let store = MockSessionStore(shiftClock: false)
        let s14 = try #require(store.session("s14"))
        s14.state = .waiting
        s14.waitingReason = .permission
        let card = try #require(model(store).needsYou.first { $0.id == "s14" })
        #expect(card.external)
        #expect(!card.canAllow, "D6: never [1 允許] for an external")
        #expect(card.meta == "外部啟動")
    }

    @Test func launchCardsByLatestActivityWithLamps() throws {
        let store = MockSessionStore(shiftClock: false)
        let home = model(store)
        #expect(home.launch.map(\.name) == ["原型試做", "orb-toolkit-backend", "MCP 整合範例", "Northstar invoice system",
                                            "orb-toolkit-frontend", "Gear3D"])
        #expect(home.launch[0].lamps.map(\.state) == [.done, .idle])
        #expect(home.launch[0].live == 2)
        #expect(home.launch[1].lamps.map(\.state) == [.waiting, .shell])
        #expect(home.launch[0].shortPath == "~/…/agent-lab-2026/原型試做")
        #expect(home.launch.allSatisfy { $0.known })
        #expect(HomeModel.launchedText(try #require(home.launch[0].lastActivity), now: MockData.referenceDate) == "啟動 10:04")
    }

    @Test func launchFillsWithClaudeJSONSuggestionsCODDDoesNotKnow() throws {
        let store = MockSessionStore(shiftClock: false)
        for group in store.groups {
            for id in group.projectIDs where id != "proto" && id != "backend" { store.removeProject(id) }
        }
        var inputs = HomeModel.Inputs()
        let backend = PathFormat.expandTilde(try #require(store.project("backend")).cwd)
        inputs.suggestions = [RecentProject(path: backend, lastUsed: nil), RecentProject(path: "/w/new-app", lastUsed: nil)]
        let home = model(store, inputs: inputs)
        #expect(home.launch.map(\.name) == ["原型試做", "orb-toolkit-backend", "new-app"])
        #expect(home.launch.map(\.known) == [true, true, false])
        #expect(home.launch[2].lamps.isEmpty)
    }

    @Test func recentlyStoppedMergesTranscriptsNoSessionUses() throws {
        let store = MockSessionStore(shiftClock: false)
        let backend = HolderSessionStore.standardize(try #require(store.project("backend")).cwd)
        let now = MockData.referenceDate
        func transcript(_ id: String, _ title: String, ageDays: Double) -> TranscriptSummary {
            TranscriptSummary(id: id, path: backend + "/\(id).jsonl", cwd: backend, title: title, titleSource: .custom,
                              gitBranch: "main", lastActivity: now.addingTimeInterval(-ageDays * 86_400), sizeBytes: 655_360)
        }
        var inputs = HomeModel.Inputs()
        inputs.transcripts = [backend: [transcript("used-by-codd", "CODD 的", ageDays: 0.5), transcript("live-elsewhere", "外部在跑", ageDays: 1),
                                        transcript("free", "可接續的", ageDays: 2)]]
        inputs.usedClaudeSessionIDs = ["used-by-codd", "live-elsewhere"]
        let home = model(store, inputs: inputs)
        #expect(home.stopped.map(\.id) == ["s12", "free"], "newest first; used ones left out")
        #expect(home.stopped[0].kind == .session)
        #expect(home.stopped[0].meta == ["個人·Github / UsageBar", "exited · code 0"])
        #expect(home.stopped[1].kind == .transcript)
        #expect(home.stopped[1].meta == ["orb-toolkit-backend", "⎇ main"])
        #expect(HomeModel.transcriptAge(home.stopped[1].date, now: now) == "2d")
        #expect(HomeModel.size(1_258_291) == "1.2MB")
        #expect(HomeModel.size(655_360) == "640KB")
        // At most six rows.
        inputs.transcripts = [backend: (0..<10).map { transcript("t\($0)", "對話 \($0)", ageDays: Double($0) + 1) }]
        inputs.usedClaudeSessionIDs = []
        #expect(model(store, inputs: inputs).stopped.count == 4, "three transcripts per project plus s12")
    }

    @Test func usageHeaderSaysSampleDataInRealModeOnly() throws {
        let store = MockSessionStore(shiftClock: false)
        var inputs = HomeModel.Inputs()
        inputs.realMode = true
        inputs.sampleAccounts = true
        inputs.accountSource = "cswap 0.26.0"
        #expect(model(store, inputs: inputs).usageHeader == "↓ 依每週重置排序 · 越快重置越上面 · 示意資料，M3 接上 cswap")
        inputs.realMode = false
        #expect(model(store, inputs: inputs).usageHeader == "↓ 依每週重置排序 · 越快重置越上面 · cswap 0.26.0")
        let accounts = MockAccountStore()
        #expect(accounts.isPlaceholder)
        #expect(SampleAccountNote.applies(accounts, realMode: true))
        #expect(!SampleAccountNote.applies(accounts, realMode: false))
        var home = model(store)
        home.fillUsage(accounts)
        #expect(home.usage.map(\.slot) == ["#2", "#3", "#1"], "R7: weekly reset first")
        #expect(home.usage.filter(\.active).map(\.slot) == ["#3"])
        let active = try #require(home.usage.first { $0.active })
        let texts = UsageListView.texts(active, now: MockData.referenceDate)
        #expect(texts[4].hasPrefix("1w 用量超前預期 · 預估 10/17 18:00 用完"))
    }

    @Test func footerToggleCarriesTheD29Note() {
        let footer = SidebarFooterView(store: MockSessionStore(shiftClock: false), accounts: MockAccountStore(), shell: ShellState(),
                                       realMode: true)
        let toggle = footer.descendant(ofType: FooterToggleView.self)
        #expect(toggle?.note == SampleAccountNote.text)
        let mock = SidebarFooterView(store: MockSessionStore(shiftClock: false), accounts: MockAccountStore(), shell: ShellState())
        #expect(mock.descendant(ofType: FooterToggleView.self)?.note == nil, "mock mode is the artboard")
    }

    @Test func homeExcludesTranscriptsOfCODDSessionsAndLiveClaudes() async throws {
        let f = try RealFixture()
        let work = try f.folder("work")
        let project = UUID()
        let mine = "aaaaaaaa-0000-4000-8000-000000000001"
        let live = "aaaaaaaa-0000-4000-8000-000000000002"
        let free = "aaaaaaaa-0000-4000-8000-000000000003"
        try f.seed(project: project, path: work, sessions: [
            SessionRecord(claudeSessionId: mine, projectId: project, kind: .claude, title: "mine", order: 0, createdAt: Date()),
        ])
        try f.transcript(mine, cwd: work, title: "CODD 的對話", age: 60)
        try f.transcript(live, cwd: work, title: "外部的對話", age: 120)
        try f.transcript(free, cwd: work, title: "可接續的對話", age: 3 * 86_400)
        let store = try f.store()
        await store.start()
        store.applyRegistry([registryEntry(pid: 900_401, cwd: work, sessionId: live)])
        let services = AppServices(store: store)
        var inputs = HomeModel.Inputs()
        inputs.sessionOrder = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "").sessionOrder
        inputs.usedClaudeSessionIDs = services.coddClaudeSessionIds.union(services.inUseClaudeSessionIds)
        for folder in HomeModel.transcriptFolders(store: store) {
            inputs.transcripts[folder] = await services.transcripts(for: folder, limit: HomeModel.transcriptsPerProject)
        }
        #expect(services.isTranscriptListCached(work, limit: 3))
        #expect(!services.isTranscriptListCached(work, limit: 50), "a longer list is read anew")
        let home = HomeModel.build(store: store, inputs: inputs, now: Date())
        #expect(home.stopped.map(\.title) == ["mine", "可接續的對話"])
        #expect(home.stopped.last?.kind == .transcript)
        #expect(home.stopped.last?.cwd == work)
        #expect(home.needsYou.isEmpty)
        #expect(home.launch.map(\.path) == [store.project(LayoutMapping.id(project))?.cwd ?? ""])
        store.shutdown()
    }
}

// MARK: - Quick switch

@MainActor
@Suite("Quick switch model (I4, D14)")
struct QuickSwitchModelTests {
    private func session(_ id: String, _ title: String, location: String, project: String = "p0", state: CODD.SessionState = .idle,
                         external: Bool = false) -> QuickSwitchModel.Input.Session {
        .init(id: id, title: title, location: location, groupColor: .blue, tag: nil, state: state, unreachable: false,
              since: Date(), number: nil, external: external, projectID: project, kind: .claude)
    }

    @Test func titleMatchesRankAboveLocationMatches() {
        var input = QuickSwitchModel.Input()
        input.sessions = [session("a", "deploy backend", location: "g / x"), session("b", "notes", location: "g / backend-api"),
                          session("c", "backend", location: "g / y"), session("d", "unrelated", location: "g / z")]
        let model = QuickSwitchModel.build(query: "backend", input: input)
        #expect(model.groups.first?.section == .sessions)
        #expect(model.groups.first?.rows.map(\.item) == [.session("c"), .session("a"), .session("b")])
        #expect(model.groups.first?.rows.first?.spans == [TextSpan(location: 0, length: 7)])
        #expect(model.groups.first?.rows.last?.spans == [], "a location match highlights nothing in the title")
    }

    @Test func sectionsAreLimited() {
        var input = QuickSwitchModel.Input()
        input.sessions = (0..<20).map { session("s\($0)", "alpha \($0)", location: "g / p") } + [session("n", "新增功能", location: "g / p")]
        input.projects = (0..<10).map { .init(id: "p\($0)", name: "alpha-proj-\($0)", path: "/w/alpha-proj-\($0)", groupName: "G",
                                              groupColor: nil, live: 0, transient: false) }
        input.currentSessionID = "s0"
        let model = QuickSwitchModel.build(query: "alpha", input: input)
        #expect(model.groups.map(\.section) == [.sessions, .projects, .actions])
        #expect(model.groups[0].rows.count == 8)
        #expect(model.groups[1].rows.count == 5)
        let actions = QuickSwitchModel.build(query: "新增", input: input).groups.last
        #expect(actions?.section == .actions)
        #expect(actions?.rows.count == 6)
        #expect(actions?.rows.prefix(2).map(\.title) == ["在 alpha-proj-0 新增 session", "在 alpha-proj-0 開啟終端機"],
                "contextual first, for the best session's project")
        // Nothing matched: no rows at all (no contextual actions either).
        #expect(QuickSwitchModel.build(query: "zzqqxxjj", input: input).count == 0)
    }

    @Test func emptyQueryListsNeedsYouThenRecentlyViewedThenCommonActions() throws {
        let store = MockSessionStore(shiftClock: false)
        let shell = ShellState()
        for id in ["s1", "s9", "s5"] { shell.currentSessionID = id }
        #expect(shell.viewedSessionIDs.prefix(3) == ["s5", "s9", "s1"])
        let input = QuickSwitchModel.Input.make(store: store, shell: shell, recent: [])
        let model = QuickSwitchModel.build(query: "", input: input)
        #expect(model.groups.map(\.section) == [.sessions, .actions], "no projects for an empty query")
        #expect(model.groups[0].rows.map(\.item) == ["s1", "s2", "s3", "s9", "s4", "s6", "s7", "s8"].map { .session($0) })
        #expect(model.groups[1].rows.map(\.title) == ["在 orb-toolkit-backend 新增 session", "在 orb-toolkit-backend 開啟終端機",
                                                     "新增 session…", "新增 Shell session…", "下方終端機", "Composer"])
        #expect(model.groups[1].rows.map(\.shortcut) == ["⌘N", "$ zsh", "⌘N", nil, "⌘J", "⌘L"])
        let s1 = model.groups[0].rows[0]
        #expect(s1.shortcut == "⌘1")
        #expect(s1.detail == "藍鵲·網站 / orb-toolkit-backend")
        #expect(s1.detailTag == .blue)
        #expect(s1.tag == .red)
        #expect(model.count == 14)
    }

    @Test func queryFindsTheArtboardRowsAndTheContext() throws {
        let store = MockSessionStore(shiftClock: false)
        let input = QuickSwitchModel.Input.make(store: store, shell: ShellState(), recent: [
            RecentProject(path: "/Users/x/orb-toolkit-suite/打卡紀錄前端介面", lastUsed: nil),
        ])
        let model = QuickSwitchModel.build(query: "打卡", input: input)
        #expect(model.groups.map(\.section) == [.sessions, .projects, .actions])
        let hit = model.groups[0].rows[0]
        #expect(hit.title == "打卡頁 RWD 調整")
        #expect(hit.spans == [TextSpan(location: 0, length: 2)])
        #expect(hit.state == .busy)
        #expect(hit.shortcut == nil || hit.shortcut?.hasPrefix("⌘") == true)
        let suggestion = model.groups[1].rows[0]
        #expect(suggestion.item == .suggestion("/Users/x/orb-toolkit-suite/打卡紀錄前端介面"))
        #expect(suggestion.prefix == "orb-toolkit-suite/")
        #expect(suggestion.detail == "未加入 · 來自 ~/.claude.json")
        #expect(suggestion.chip == "+ 加入")
        #expect(model.groups[2].rows.map(\.title) == ["在 orb-toolkit-frontend 新增 session", "在 orb-toolkit-frontend 開啟終端機"])
        // Another context (the highlighted row's project) replaces the contextual actions.
        let other = QuickSwitchModel.build(query: "打卡", input: input, context: "gear")
        #expect(other.groups.last?.rows.first?.title == "在 Gear3D 新增 session")
        #expect(other.dumpRows.first?["section"] as? String == "sessions")
    }

    @Test func commandEnterOpensThePanelExceptForExternals() throws {
        let store = MockSessionStore(shiftClock: false)
        let input = QuickSwitchModel.Input.make(store: store, shell: ShellState(), recent: [])
        #expect(QuickSwitchModel.commandEnter(.session("s1"), input: input) == .openWithPanel("s1"))
        #expect(QuickSwitchModel.commandEnter(.session("s14"), input: input) == .open("s14"), "an external only opens")
        #expect(QuickSwitchModel.commandEnter(.project("backend"), input: input) == .projectShell("backend"))
        #expect(QuickSwitchModel.commandEnter(.action(.composer), input: input) == .same)
        #expect(QuickSwitchModel.commandEnter(.suggestion("/w"), input: input) == .same)
    }

    @Test func realStoreExternalsAndTransientProjects() async throws {
        let f = try RealFixture()
        let work = try f.folder("work")
        let elsewhere = try f.folder("elsewhere")
        let project = UUID()
        try f.seed(project: project, path: work, sessions: [
            SessionRecord(claudeSessionId: "c-1", projectId: project, kind: .claude, title: "登入頁修正", order: 0, createdAt: Date()),
        ])
        let store = try f.store()
        await store.start()
        store.applyRegistry([registryEntry(pid: 900_501, cwd: elsewhere, sessionId: "ext-1", status: "waiting", waitingFor: "permission")])
        let input = QuickSwitchModel.Input.make(store: store, shell: ShellState(), recent: [RecentProject(path: work, lastUsed: nil)])
        #expect(input.suggestions.isEmpty, "a known folder is not a suggestion")
        let external = try #require(input.sessions.first { $0.external })
        #expect(input.sessions.first?.id == external.id, "NEEDS YOU first")
        let byFolder = QuickSwitchModel.build(query: "elsewhere", input: input)
        let projectRow = try #require(byFolder.groups.first { $0.section == .projects }?.rows.first)
        #expect(projectRow.detail.contains("外部"), "a transient project says so")
        #expect(QuickSwitchModel.commandEnter(.session(external.id), input: input) == .open(external.id))
        let mine = QuickSwitchModel.build(query: "登入", input: input)
        #expect(mine.groups.first?.rows.first?.title == "登入頁修正")
        store.shutdown()
    }
}

// MARK: - Palette panel

@MainActor
private final class RecordingCommands: NSObject, CoddCommands {
    var allows = 0
    var composers = 0
    func showSettings(_ sender: Any?) {}
    func showQuickSwitch(_ sender: Any?) {}
    func toggleSessionSidebar(_ sender: Any?) {}
    func selectSessionByNumber(_ sender: NSMenuItem) {}
    func selectNextSession(_ sender: Any?) {}
    func selectPreviousSession(_ sender: Any?) {}
    func allowCurrentSession(_ sender: Any?) { allows += 1 }
    func newShellTab(_ sender: Any?) {}
    func toggleBottomTerminal(_ sender: Any?) {}
    func showMainWindow(_ sender: Any?) {}
    func focusSidebarFilter(_ sender: Any?) {}
    func newSession(_ sender: Any?) {}
    func quitApp(_ sender: Any?) {}
    func togglePinCurrentSession(_ sender: Any?) {}
    func stopCurrentSession(_ sender: Any?) {}
    func toggleComposer(_ sender: Any?) { composers += 1 }
}

@MainActor
@Suite("Quick switch panel (I4)", .serialized)
struct QuickSwitchPanelTests {
    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }

    @Test func commandReturnInThePaletteNeverReachesAllow() async throws {
        let store = MockSessionStore(shiftClock: false)
        let shell = ShellState()
        shell.currentSessionID = "s1"
        var opened: [(SessionID, Bool)] = []
        let palette = CommandPaletteController(store: store, shell: shell,
                                               actions: QuickSwitchActions(openSession: { opened.append(($0, $1)) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        palette.show(over: window)
        #expect(palette.isShown)
        #expect(palette.model.rows.first?.item == .session("s1"))
        let commands = RecordingCommands()
        let menu = MainMenuBuilder.build(commands: commands)
        let event = try #require(key("\r", keyCode: 0x24, modifiers: .command, window: palette.panel))
        // AppKit's order: the key window's views first, the main menu only when nothing claimed it.
        let claimed = palette.panel.performKeyEquivalent(with: event)
        let reachedMenu = !claimed && menu.performKeyEquivalent(with: event)
        #expect(claimed)
        #expect(!reachedMenu)
        #expect(commands.allows == 0, "⌘⏎ in the palette never runs 允許")
        #expect(store.session("s1")?.state == .waiting, "the waiting session was not answered")
        #expect(opened.count == 1 && opened.first?.0 == "s1" && opened.first?.1 == true, "⌘⏎ opened it with its panel")
        #expect(!palette.isShown)
        // Outside the palette the same chord is the menu's.
        #expect(menu.performKeyEquivalent(with: try #require(key("\r", keyCode: 0x24, modifiers: .command, window: window))))
        #expect(commands.allows == 1)
        window.close()
    }

    @Test func escClosesAndTheFieldRanksAsYouType() async throws {
        let store = MockSessionStore(shiftClock: false)
        let palette = CommandPaletteController(store: store, shell: ShellState())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        palette.show(over: window)
        let start = ContinuousClock.now
        palette.setQuery("打卡")
        #expect(ContinuousClock.now - start < .milliseconds(100))
        #expect(palette.model.rows.first?.title == "打卡頁 RWD 調整")
        #expect(palette.list.contentHeight > QuickSwitchListView.emptyHeight)
        #expect(try #require(palette.lastShowDuration) < .milliseconds(150))
        palette.setQuery("zzqqxxjjnothing")
        #expect(palette.model.count == 0)
        let esc = try #require(key("\u{1B}", keyCode: 0x35, modifiers: [], window: palette.panel))
        #expect(palette.panel.performKeyEquivalent(with: esc))
        #expect(!palette.isShown)
        #expect(palette.dump["shown"] as? Bool == false)
        window.close()
    }
}

// MARK: - Composer

@MainActor
private final class PaneHarness {
    let store = MockSessionStore(shiftClock: false)
    let shell = ShellState()
    let pane: SessionPaneViewController
    let window: NSWindow

    init(current: SessionID = "s9", directory: (@MainActor (SessionID) -> String?)? = nil, retryDelay: TimeInterval = 60) {
        shell.currentSessionID = current
        pane = SessionPaneViewController(store: store, accounts: MockAccountStore(), shell: shell,
                                         surfaceFactory: FakeTerminalSurfaceFactory { _ in "<d>></d> mock" },
                                         composerDirectory: directory, autoRetryDelay: retryDelay)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        window.layoutIfNeeded()
    }

    var fake: FakeTerminalSurface { pane.surface as! FakeTerminalSurface }

    func type(_ text: String) {
        pane.composer.bar.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    deinit { MainActor.assumeIsolated { window.close() } }
}

@MainActor
@Suite("Composer (I4, D1–D4)", .serialized)
struct ComposerTests {
    @Test func commandLStateMachine() async throws {
        let h = PaneHarness()
        await settle()
        #expect(!h.pane.isComposerShown)
        h.pane.toggleComposer()  // hidden → shown and focused
        #expect(h.shell.pane(for: "s9").composerOpen)
        #expect(h.pane.isComposerShown)
        #expect(h.pane.composer.bar.hasFocus)
        h.pane.surface.focus()
        #expect(!h.pane.composer.bar.hasFocus)
        h.pane.toggleComposer()  // shown, focus elsewhere → focused
        #expect(h.pane.isComposerShown)
        #expect(h.pane.composer.bar.hasFocus)
        h.pane.toggleComposer()  // shown and focused → hidden, terminal focused
        #expect(!h.shell.pane(for: "s9").composerOpen)
        #expect(!h.pane.isComposerShown)
        #expect(h.pane.surface.hasFocus)
        h.pane.toggleComposer()
        h.pane.composer.bar.textView.onEscape?()  // Esc only moves the focus
        #expect(h.pane.isComposerShown)
        #expect(h.pane.surface.hasFocus)
        // The bar takes room under the terminal and the placeholder follows the target.
        #expect(h.pane.composer.bar.frame.height == h.pane.composer.bar.preferredHeight)
        #expect(h.pane.composer.bar.textView.placeholder == ComposerBarView.claudePlaceholder)
        #expect(h.pane.composer.bar.statusText == ComposerBarView.busyText, "s9 is busy")
        h.shell.selectFirstShellTab(in: "s9", kind: .claude)
        await settle()
        #expect(h.pane.composer.bar.textView.placeholder == ComposerBarView.shellPlaceholder)
    }

    @Test func draftsFollowTheSession() async throws {
        let h = PaneHarness()
        h.pane.toggleComposer()
        await settle()
        h.type("草稿 A")
        #expect(h.pane.composer.states.state("s9")?.draft == "草稿 A")
        h.shell.currentSessionID = "s5"
        await settle()
        #expect(h.pane.composer.bar.field.text == "")
        h.type("B")
        h.shell.currentSessionID = "s9"
        await settle()
        #expect(h.pane.composer.bar.field.text == "草稿 A")
        #expect(h.pane.composer.states.state("s5")?.draft == "B")
        #expect(h.pane.composerDump("s9")["draftLength"] as? Int == 4)
    }

    @Test func sendPathUsesPasteForMultiLineOnly() async throws {
        let h = PaneHarness()
        h.pane.toggleComposer()
        await settle()
        #expect(h.pane.composer.submit("單行 hello"))
        #expect(h.fake.sentInputs.last == .payload(bytes: Array("單行 hello".utf8), submit: true, paste: false))
        #expect(h.pane.composer.bar.field.text == "")
        #expect(h.pane.composer.submit("第一行\n第二行"))
        #expect(h.fake.sentInputs.last == .payload(bytes: Array("第一行\r第二行".utf8), submit: true, paste: true))
        #expect(h.fake.sentInputs.last?.pastes == true)
        #expect(h.pane.composer.states.state("s9")?.history.entries == ["單行 hello", "第一行\n第二行"])
        #expect(!h.pane.composer.submit("   "), "nothing to send")
        // ↑ recalls the history.
        #expect(h.pane.composer.bar.textView.onHistory?(.previous) == "第一行\n第二行")
        #expect(h.pane.composer.bar.textView.onHistory?(.previous) == "單行 hello")
        // A session that is not running: refused, the text kept, the bar says why.
        let stopped = PaneHarness(current: "s12")
        stopped.pane.toggleComposer()
        await settle()
        #expect(stopped.pane.composer.bar.statusText == ComposerBarView.notRunningText)
        #expect(!stopped.pane.composer.submit("hi"))
        #expect(stopped.fake.sentInputs.isEmpty)
        // Over 256 KiB: refused with the size.
        #expect(!h.pane.composer.submit(String(repeating: "a", count: ComposerEncoding.maxBytes + 1)))
        #expect(h.pane.composer.bar.statusText.hasPrefix("超過 256 KB"))
    }

    @Test func heldInputKeepsThePasteFlag() {
        let sink = PtySink()
        #expect(!sink.hold(Array("x".utf8), submit: true, paste: true), "not reconnecting: nothing is held")
        sink.holdInput(true)
        #expect(sink.hold(Array("第一行\r第二行".utf8), submit: true, paste: true))
        sink.write(Array("k".utf8))
        #expect(sink.heldInputs == [PtySink.HeldInput(bytes: Array("第一行\r第二行".utf8), submit: true, paste: true),
                                    PtySink.HeldInput(bytes: Array("k".utf8), submit: false, paste: false)])
        #expect(PtySink.heldInputLimit >= ComposerEncoding.maxBytes, "one composer send fits")
        #expect(TerminalInput.payload(bytes: [0x61], submit: true, paste: true).pastes)
        #expect(!TerminalInput.text("a", submit: true).pastes)
    }

    @Test func pastedImageIsSavedAsAPrivatePNGAndInsertedEscaped() async throws {
        let temp = try makeTemp("codd-i4 img")
        defer { removeTemp(temp) }
        let sessionDir = temp + "/sessions/s9"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let h = PaneHarness(directory: { _ in sessionDir })
        h.pane.toggleComposer()
        await settle()
        // The saved draft (none) is read first: a read finishing after the text below is set would
        // show the empty draft instead (the field text set here is not an edit), whatever the load.
        await h.pane.composer.states.load("s9")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        h.pane.composer.bar.field.text = "看 "
        #expect(h.pane.composer.bar.textView.onPasteImage?(.png(png)) == true)
        // Saved off the main actor; the path goes in once the file exists.
        await eventually("path inserted") { h.pane.composer.bar.field.text.count > 2 }
        let inserted = String(h.pane.composer.bar.field.text.dropFirst(2))
        let files = try FileManager.default.contentsOfDirectory(atPath: sessionDir + "/attachments")
        #expect(files.count == 1)
        let name = try #require(files.first)
        #expect(name.range(of: #"^\d{8}-\d{6}-[0-9a-f]{6}\.png$"#, options: .regularExpression) != nil, "\(name)")
        let path = sessionDir + "/attachments/" + name
        #expect(inserted == ComposerPaths.escaped(path))
        #expect(inserted.contains("codd-i4\\ img"), "a space is escaped like a Terminal.app drop")
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == png)
        let fileMode = try #require(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
        let dirMode = try #require(try FileManager.default.attributesOfItem(atPath: sessionDir + "/attachments")[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue & 0o777 == 0o600)
        #expect(dirMode.intValue & 0o777 == 0o700)
        // Without a session folder nothing is created.
        #expect(throws: ComposerStates.AttachmentError.self) {
            try ComposerStates.writeAttachment(png, sessionDirectory: temp + "/sessions/gone", now: Date())
        }
        #expect(!FileManager.default.fileExists(atPath: temp + "/sessions/gone"))
    }

    /// Post-M4: after Chinese text (no space) the path gets a space before it, so claude reads it
    /// as its own token; after a space nothing is added (the test above).
    @Test func pastedImageAfterAWordGetsASpaceBeforeItsPath() async throws {
        let temp = try makeTemp("codd-glued")
        defer { removeTemp(temp) }
        let sessionDir = temp + "/sessions/s9"
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let h = PaneHarness(directory: { _ in sessionDir })
        h.pane.toggleComposer()
        await settle()
        await h.pane.composer.states.load("s9")
        h.pane.composer.bar.field.text = "看這張"
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
        #expect(h.pane.composer.bar.textView.onPasteImage?(.png(png)) == true)
        await eventually("path inserted") { h.pane.composer.bar.field.text.count > 3 }
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: sessionDir + "/attachments").first)
        #expect(h.pane.composer.bar.field.text == "看這張 " + ComposerPaths.escaped(sessionDir + "/attachments/" + name))
    }

    /// Review concurrency-perf-3: a TIFF is converted and written off the main actor; the path
    /// arrives afterwards, in the draft of the session it was pasted into even after a switch.
    @Test func pastedTIFFIsConvertedOffTheMainActorAndFollowsItsSession() async throws {
        let temp = try makeTemp("codd-perf3")
        defer { removeTemp(temp) }
        for id in ["s9", "s5"] {
            try FileManager.default.createDirectory(atPath: temp + "/sessions/" + id, withIntermediateDirectories: true)
        }
        let h = PaneHarness(directory: { temp + "/sessions/" + $0 })
        h.pane.toggleComposer()
        await settle()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 48, bitsPerSample: 8,
                                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                   bytesPerRow: 0, bitsPerPixel: 0))
        let tiff = try #require(bitmap.tiffRepresentation)
        var saved: [SessionID] = []
        h.pane.composer.onAttachmentSaved = { saved.append($0) }
        #expect(h.pane.composer.bar.textView.onPasteImage?(.tiff(tiff)) == true)
        #expect(h.pane.composer.bar.field.text.isEmpty, "nothing is inserted before the file exists")
        h.shell.currentSessionID = "s5"  // switched while it saves
        await settle()
        await eventually("saved") { saved == ["s9"] }
        #expect(h.pane.composer.bar.field.text.isEmpty, "s5's field gets nothing")
        let draft = try #require(h.pane.composer.states.state("s9")?.draft)
        #expect(draft.contains("/attachments/") && draft.hasSuffix(".png"), "\(draft)")
        let files = try FileManager.default.contentsOfDirectory(atPath: temp + "/sessions/s9/attachments")
        let data = try Data(contentsOf: URL(fileURLWithPath: temp + "/sessions/s9/attachments/" + (files.first ?? "")))
        #expect(Array(data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "re-encoded as PNG")
        // Not an image: declined later with a beep, nothing inserted, no file.
        h.shell.currentSessionID = "s9"
        await settle()
        #expect(h.pane.composer.bar.textView.onPasteImage?(.tiff(Data([1, 2, 3]))) == true)
        await eventually("settled") { h.pane.composer.pendingAttachments == 0 }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temp + "/sessions/s9/attachments").count == 1)
    }

    /// Review security-data-1: while claude shows a permission / plan / question prompt the
    /// composer sends nothing (a `2…` would answer `always allow`, the Return the default).
    @Test func composerRefusesToAnswerAWaitingClaude() async throws {
        let h = PaneHarness(current: "s1")  // WAITING · PERMISSION
        h.pane.toggleComposer()
        await settle()
        #expect(h.pane.composer.bar.statusText == ComposerBarView.awaitingAnswerText)
        #expect(!h.pane.composer.bar.sendButton.isEnabled)
        #expect(h.pane.composer.bar.textView.isEditable, "the draft can still be typed")
        h.pane.composer.bar.field.text = "2 不要刪 db/"
        #expect(!h.pane.composer.submit("2 不要刪 db/"))
        #expect(h.fake.sentInputs.isEmpty)
        #expect(h.pane.composer.bar.field.text == "2 不要刪 db/", "kept")
        let s1 = try #require(h.store.session("s1"))
        s1.state = .busy
        s1.stateSince = Date()
        await settle()
        #expect(h.pane.composer.bar.statusText == ComposerBarView.busyText)
        #expect(h.pane.composer.submit("2 不要刪 db/"))
        #expect(h.fake.sentInputs.count == 1)
        // A prompt that appears between the last bind and Enter is checked at the send itself.
        s1.state = .waiting
        s1.waitingReason = .plan
        #expect(!h.pane.composer.submit("好，照做"))
        #expect(h.fake.sentInputs.count == 1)
        #expect(h.pane.composer.bar.statusText == ComposerBarView.awaitingAnswerText)
        // The shell tab of a waiting session is not claude's prompt: it sends.
        h.shell.selectFirstShellTab(in: "s1", kind: .claude)
        await settle()
        #expect(h.pane.composer.bar.statusText != ComposerBarView.awaitingAnswerText)
    }

    /// Review concurrency-perf-8: a session that left CODD leaves the composer's memory too.
    @Test func forgetDropsARemovedSessionsComposerState() async throws {
        let h = PaneHarness()
        h.pane.toggleComposer()
        await settle()
        h.type("草稿")
        #expect(h.pane.composer.states.loadedSessionIDs.contains("s9"))
        h.pane.composer.forget("s9")
        #expect(!h.pane.composer.states.loadedSessionIDs.contains("s9"))
        #expect(h.pane.composer.bar.field.text == "")
        h.pane.composer.states.setDraft("again", for: "s9")
        await settle()
        #expect(h.pane.composer.states.state("s9") == nil, "a forgotten session does not come back")
    }

    @Test func composerStateIsSavedAndReadBack() async throws {
        let temp = try makeTemp("codd-i4-state")
        defer { removeTemp(temp) }
        let states = ComposerStates(directory: { _ in temp }, saveDelay: .milliseconds(20))
        states.setDraft("早安", for: "a")  // before the read: queued, applied on top of it
        await states.load("a")
        #expect(states.state("a")?.draft == "早安")
        states.recordSent("第一則", for: "a")
        states.setDraft("下一則", for: "a")
        states.flush()
        let saved = ComposerStateFile.load(directory: temp)
        #expect(saved.draft == "下一則")
        #expect(saved.history.entries == ["第一則"])
        let mode = try #require(try FileManager.default.attributesOfItem(atPath: temp + "/composer.json")[.posixPermissions] as? NSNumber)
        #expect(mode.intValue & 0o777 == 0o600)
        let again = ComposerStates(directory: { _ in temp })
        #expect(await again.load("a") == saved)
    }

    @Test func panesFileKeepsComposerOpenAndReadsOldFiles() throws {
        var layout = PaneLayout()
        layout.composerOpen = true
        let data = try #require(PaneLayoutStore.encode(["s1": layout]))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"composerOpen\" : true"))
        #expect(text.contains("\"version\" : 1"))
        #expect(PaneLayoutStore.decode(data)?["s1"]?.composerOpen == true)
        let old = Data(#"{"version":1,"sessions":{"s1":{"tabs":[],"selected":"claude","panelOpen":false,"panelHeight":280}}}"#.utf8)
        #expect(PaneLayoutStore.decode(old)?["s1"]?.composerOpen == false, "an M1 file reads as closed")
    }

    @Test func optionsParseTheI4Flags() {
        let options = RealModeOptions.parse(arguments: [
            "CODD", "-codd-palette-query", "north", "-codd-composer-open", "YES",
            "-codd-composer-send", "hello 世界", "-codd-composer-send", #"第一行\n第二行\t縮排 \\n"#,
        ], environment: [:], home: "/Users/x")
        #expect(options.paletteQuery == "north")
        #expect(options.composerOpen)
        #expect(options.composerSend == ["hello 世界", "第一行\n第二行\t縮排 \\n"])
        #expect(options.releaseSubset.composerSend.isEmpty && options.releaseSubset.paletteQuery == nil)
    }
}

// MARK: - Error banner (D26)

@MainActor
@Suite("Error banner actions (I4, D26)", .serialized)
struct ErrorBannerActionTests {
    @Test func resendSendsTheLastPromptAsAPaste() async throws {
        let h = PaneHarness(current: "s3")
        let s3 = try #require(h.store.session("s3"))
        #expect(s3.resendPrompt != nil, "mock s3 draws the artboard's usable actions")
        s3.lastPrompt = nil
        s3.resendPrompt = nil
        await settle()
        let banner = h.pane.sessionBanner
        #expect(banner.actionButtons.map(\.label) == ["↻ 重送上一則", "⟲ 稍後自動重試"])
        #expect(banner.actionButtons.allSatisfy { !$0.isEnabled }, "no prompt known yet")
        #expect(banner.hintText == "沒有可重送的 prompt")
        #expect(!h.pane.resend("s3", why: "test"))
        s3.resendPrompt = "請再跑一次場景載入的效能測試"
        s3.lastPrompt = s3.resendPrompt
        await settle()
        #expect(banner.actionButtons.allSatisfy { $0.isEnabled })
        #expect(banner.hintText == "")
        #expect(h.pane.resend("s3", why: "test"))
        #expect(h.fake.sentInputs.last == .payload(bytes: Array("請再跑一次場景載入的效能測試".utf8), submit: true, paste: true))
    }

    /// Review correctness-1 / security-data-2: the display form (one line, at most 200
    /// characters) is never resent; the whole prompt goes out, its last clause included.
    @Test func resendNeverSendsTheShortenedDisplayForm() async throws {
        let h = PaneHarness(current: "s3")
        let s3 = try #require(h.store.session("s3"))
        let prompt = String(repeating: "請把 auth middleware 在 token 過期時的處理改寫，", count: 8)
            + "\n第二行\n但是絕對不要刪 backups/ 和 db/ 底下的任何檔案。"
        let display = try #require(HookPipeline.cleanPrompt(.string(prompt)))
        #expect(display.count == 200 && !display.contains("不要刪"))
        // Only the display form known (the hook's whole prompt was too long): nothing to resend.
        s3.lastPrompt = display
        s3.resendPrompt = nil
        await settle()
        #expect(h.pane.sessionBanner.actionButtons.allSatisfy { !$0.isEnabled })
        #expect(!h.pane.resend("s3", why: "test"))
        #expect(h.fake.sentInputs.isEmpty)
        s3.resendPrompt = HookPipeline.resendablePrompt(.string(prompt))
        await settle()
        #expect(h.pane.resend("s3", why: "test"))
        let expected = try ComposerEncoding.payload(for: prompt)
        #expect(h.fake.sentInputs.last == .payload(bytes: expected.bytes, submit: true, paste: true))
        #expect(String(decoding: expected.bytes, as: UTF8.self).contains("不要刪 backups/"))
        // More than one composer send: never resent in part.
        #expect(HookPipeline.resendablePrompt(.string(String(repeating: "a", count: ComposerEncoding.maxBytes + 1))) == nil)
        #expect(HookPipeline.resendablePrompt(.string(" \n ")) == nil)
        #expect(HookPipeline.resendablePrompt(.number(3)) == nil)
    }

    @Test func autoRetryCountsDownAndCancels() {
        final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let scheduler = AutoRetryScheduler(delay: 60, clock: { clock.now })
        let since = Date(timeIntervalSince1970: 1_799_999_000)
        #expect(scheduler.title(for: "s3", now: clock.now) == "⟲ 稍後自動重試")
        #expect(scheduler.toggle("s3", stateSince: since))
        #expect(scheduler.title(for: "s3", now: clock.now) == "⟲ 60s 後重試")
        clock.now = clock.now.addingTimeInterval(15)
        #expect(scheduler.title(for: "s3", now: clock.now) == "⟲ 45s 後重試")
        #expect(!scheduler.toggle("s3", stateSince: since), "a second click cancels")
        #expect(!scheduler.isArmed("s3"))
        #expect(scheduler.title(for: "s3", now: clock.now) == "⟲ 稍後自動重試")
    }

    @Test func autoRetryFiresOnceAndIsDroppedWhenTheSessionLeavesError() async throws {
        var failing = true
        var fired: [SessionID] = []
        let since = Date(timeIntervalSince1970: 1_799_999_000)
        let scheduler = AutoRetryScheduler(delay: 0.1)
        scheduler.isStillFailing = { _, armedSince in failing && armedSince == since }
        scheduler.onFire = { fired.append($0) }
        scheduler.toggle("s3", stateSince: since)
        await eventually("the resend fired") { fired == ["s3"] }
        #expect(!scheduler.isArmed("s3"), "one resend only")
        // Left ERROR before the time: dropped, never sent.
        scheduler.toggle("s3", stateSince: since)
        failing = false
        scheduler.dropStale()
        #expect(!scheduler.isArmed("s3"))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired == ["s3"])
        // A new failure (another stateSince) does not inherit an armed resend.
        failing = true
        scheduler.toggle("s3", stateSince: since.addingTimeInterval(-1))
        try await Task.sleep(for: .milliseconds(300))
        #expect(fired == ["s3"])
    }

    @Test func paneDropsTheArmedResendWhenTheSessionRecovers() async throws {
        let h = PaneHarness(current: "s3")
        await settle()
        let s3 = try #require(h.store.session("s3"))
        s3.lastPrompt = "重試"
        h.pane.autoRetry.toggle("s3", stateSince: s3.stateSince)
        #expect(h.pane.autoRetry.isArmed("s3"))
        s3.resendPrompt = "重試一次"  // an observed change: the banner draws again
        await settle()
        #expect(h.pane.sessionBanner.actionButtons.last?.label == "⟲ 60s 後重試")
        s3.state = .idle
        s3.stateSince = Date()
        await settle()
        #expect(!h.pane.autoRetry.isArmed("s3"), "leaving ERROR drops it")
    }
}

// MARK: - M2 review round 1

@MainActor
@Suite("M2 review fixes: header, Home counts, mock error banner", .serialized)
struct M2ReviewPaneFixTests {
    /// Review concurrency-perf-1: the 1 Hz tick redraws the chip / meta layers, never the
    /// header with its glowing title, unless the chip's width changed.
    @Test func aTickRedrawsOnlyTheTickingParts() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let header = SessionHeaderView()
        header.frame = NSRect(x: 0, y: 0, width: 900, height: 52)
        window.contentView = header
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = SessionHeaderModel(style: StateStyleKey(state: .shell), title: "打卡頁 RWD 調整", tag: .cyan, chipParts: ["$ SHELL", "zsh"],
                                       chipShowsDuration: false, stateSince: now, external: false, cwd: "/tmp/work", meta: [],
                                       startedAt: now.addingTimeInterval(-12), account: nil, accountPinned: false,
                                       remoteControl: false, notes: 0)
        header.update(model, now: now)
        window.layoutIfNeeded()
        let parts = header.tickingParts
        #expect(parts.allSatisfy { !$0.isHidden && $0.frame.width > 0 })
        #expect(parts[0].frame.minX > 37 + 17, "the chip sits after the tag and the title")
        #expect(parts[1].frame.maxX <= 900)
        header.tick(now: now.addingTimeInterval(1))  // `UP 13s`: the meta line only
        #expect(header.lastTickRedraw == [.meta], "the title is not redrawn")
        // A busy chip whose duration keeps its width: only the chip layer (UP changes too).
        var busy = model
        busy.style = StateStyleKey(state: .busy)
        busy.chipParts = ["● BUSY"]
        busy.chipShowsDuration = true
        busy.stateSince = now.addingTimeInterval(-15)
        busy.startedAt = nil
        header.update(busy, now: now)
        let chipX = parts[0].frame.minX
        header.tick(now: now.addingTimeInterval(1))  // 15s → 16s
        #expect(header.lastTickRedraw == [.chip])
        header.tick(now: now.addingTimeInterval(45))  // 16s → 1m (another width): laid out again
        #expect(header.lastTickRedraw == [.chip, .header])
        #expect(parts[0].frame.minX == chipX, "the title did not move")
        header.tick(now: now.addingTimeInterval(45.5))  // still `1m`
        #expect(header.lastTickRedraw == [])
    }

    /// Review spec-fidelity-6: `✕ n EXITED` counts exited sessions only, not STOPPED (`⟲`).
    @Test func homeMetaRuleCountsOnlyExitedSessions() {
        let now = Date()
        let sessions = [
            SessionVM(id: "a", projectID: "p", title: "a", state: .stopped, stateSince: now),
            SessionVM(id: "b", projectID: "p", title: "b", state: .stopped, stateSince: now),
            SessionVM(id: "c", projectID: "p", kind: .shell, title: "c", state: .exited, stateSince: now),
            SessionVM(id: "d", projectID: "p", title: "d", state: .busy, stateSince: now),
        ]
        let counts = SessionCounts(sessions: sessions)
        #expect(counts.exited == 1 && counts.stopped == 2 && counts.live == 1)
        let store = MockSessionStore(shiftClock: false)
        let model = HomeModel.build(store: store, inputs: HomeModel.Inputs(), now: now)
        #expect(model.counts.exited == 1)
    }

    /// Review spec-fidelity-5: mock s3's error banner offers both D26 actions (§7.1).
    @Test func mockErrorBannerOffersBothActions() async throws {
        let h = PaneHarness(current: "s3")
        await settle()
        let buttons = h.pane.sessionBanner.actionButtons
        #expect(buttons.map(\.label) == ["↻ 重送上一則", "⟲ 稍後自動重試"])
        #expect(buttons.allSatisfy { $0.isEnabled })
        #expect(h.pane.resend("s3", why: "test"))
        #expect(h.fake.sentInputs.last == .payload(bytes: Array("場景第一次載入要 6 秒，幫我找出瓶頸並優化".utf8), submit: true, paste: true))
    }
}
