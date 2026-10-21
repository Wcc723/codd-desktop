import AppKit
import CoddCore
import CoddHolderClient
import CoddHooks
import CoddPreferences
import CoddUI
import Darwin
import Foundation
import Testing
@testable import CODD

/// M3 I1b (wiring), the launch side: the per-session status line and its chain (D8, D35), the
/// holder environment of pinned sessions (§0, D12), pins through the store (create, RESUME, launch
/// profiles, transcripts), the codd-statusline copies (D8, D11), the menu bar (D23) and the
/// report path from the bundled CLI through the endpoint to the account store (D9). Temp folders
/// only; the children are `/bin/sh` + `cat`, never claude.

private func settingsArgument(_ argv: [String]) throws -> [String: Any] {
    let index = try #require(argv.firstIndex(of: "--settings"))
    let text = argv[index + 1]
    return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

private func decodeChain(_ value: String?) -> String? {
    value.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
}

@MainActor
@Suite("Status line and pinned launches (I1b)")
struct StatusLineLaunchTests {
    let folder: String
    let root: CoddDataRoot

    init() throws {
        folder = try m3TempFolder("codd-i1bl")
        root = CoddDataRoot(path: folder + "/r")
    }

    private func launcher() -> HolderLauncher {
        var launcher = HolderLauncher(holderExecutable: "/usr/bin/false", root: root, claudePathOverride: folder + "/fake-claude")
        launcher.coddStatusLinePath = root.path + "/bin/codd-statusline-0123456789ab"
        return launcher
    }

    private func write(_ json: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try json.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func plan(cwd: String, userSettings: String, options: ClaudeLaunchOptions = ClaudeLaunchOptions(),
                      login: [String: String]? = nil) throws -> HolderStartPlan {
        let launcher = launcher()
        let injection = HolderLauncher.statusLineInjection(command: try #require(launcher.coddStatusLinePath), cwd: cwd,
                                                           userSettings: URL(fileURLWithPath: userSettings))
        let hooks = ClaudeHookSettings(endpoint: HookEndpoint(port: 43_001), sessionStartCommand: "/usr/bin/true", statusLine: injection)
        return try launcher.planClaude(sessionID: UUID(), cwd: cwd, options: options, hooks: (hooks, "t0k3n"), loginEnvironment: login)
    }

    @Test func settingsCarryCODDsStatusLineAndTheUsersCommandIsChained() throws {
        defer { m3RemoveFolder(folder) }
        let user = folder + "/claude/settings.json"
        try write(#"{"statusLine":{"type":"command","command":"printf 'USER-SL-%s' ok","padding":2,"refreshInterval":5}}"#, to: user)
        let work = folder + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let plan = try plan(cwd: work, userSettings: user)
        let statusLine = try #require(try settingsArgument(plan.argv)["statusLine"] as? [String: Any])
        #expect(statusLine["type"] as? String == "command")
        #expect(statusLine["command"] as? String == "'" + root.path + "/bin/codd-statusline-0123456789ab'", "single-quoted for /bin/sh -c")
        #expect(statusLine["padding"] as? Int == 2 && statusLine["refreshInterval"] as? Int == 5, "the user's extras kept")
        // §0: the chain reaches the HOLDER environment (ShellEnvironment's), base64, never argv.
        #expect(decodeChain(plan.environment["CODD_STATUSLINE_CHAIN"]) == "printf 'USER-SL-%s' ok")
        #expect(!plan.argv.joined().contains("USER-SL"))
        #expect(plan.environment["CODD_HOOK_URL"] == "http://127.0.0.1:43001/hooks")
    }

    @Test func projectSettingsWinOverTheUsersD35() throws {
        defer { m3RemoveFolder(folder) }
        let user = folder + "/claude/settings.json"
        try write(#"{"statusLine":{"type":"command","command":"echo user"}}"#, to: user)
        let work = folder + "/work"
        try write(#"{"statusLine":{"type":"command","command":"echo project"}}"#, to: work + "/.claude/settings.json")
        #expect(decodeChain(try plan(cwd: work, userSettings: user).environment["CODD_STATUSLINE_CHAIN"]) == "echo project")
        try write(#"{"statusLine":{"type":"command","command":"echo local","padding":1}}"#, to: work + "/.claude/settings.local.json")
        let local = try plan(cwd: work, userSettings: user)
        #expect(decodeChain(local.environment["CODD_STATUSLINE_CHAIN"]) == "echo local")
        #expect((try settingsArgument(local.argv)["statusLine"] as? [String: Any])?["padding"] as? Int == 1)
    }

    @Test func noUserStatusLineMeansNoChain() throws {
        defer { m3RemoveFolder(folder) }
        let user = folder + "/claude/settings.json"
        try write(#"{"model":"opus"}"#, to: user)
        let work = folder + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let plan = try plan(cwd: work, userSettings: user)
        #expect(plan.environment["CODD_STATUSLINE_CHAIN"] == nil)
        #expect((try settingsArgument(plan.argv)["statusLine"] as? [String: Any])?["command"] != nil, "CODD's status line still reports")
        // A missing settings file is skipped like an empty one.
        #expect(try self.plan(cwd: work, userSettings: folder + "/nope.json").environment["CODD_STATUSLINE_CHAIN"] == nil)
    }

    @Test func aPinnedLaunchGetsTheProfileAndLosesTheAuthOverrides() throws {
        defer { m3RemoveFolder(folder) }
        let user = folder + "/claude/settings.json"
        try write("{}", to: user)
        let work = folder + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let login = ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk-test", "CLAUDE_CODE_OAUTH_TOKEN": "oauth-test",
                     "CLAUDE_CONFIG_DIR": "/elsewhere"]
        let plain = try plan(cwd: work, userSettings: user, login: login)
        #expect(plain.environment["ANTHROPIC_API_KEY"] == "sk-test", "an unpinned session keeps the login environment")
        var options = ClaudeLaunchOptions()
        let profile = folder + "/home/.claude-swap-backup/sessions/2-north_example.com"
        options.claudeConfigDir = profile
        let pinned = try plan(cwd: work, userSettings: user, options: options, login: login)
        #expect(pinned.environment["CLAUDE_CONFIG_DIR"] == profile, "the pin wins over the login environment")
        for name in LaunchBuilder.authOverrideNames { #expect(pinned.environment[name] == nil, "\(name) removed like cswap run") }
        #expect(!pinned.argv.joined().contains("example.com"), "the profile path stays out of argv")
        // A relative pin is refused without naming the path.
        options.claudeConfigDir = "relative/2-north_example.com"
        do {
            _ = try plan(cwd: work, userSettings: user, options: options)
            Issue.record("a relative CLAUDE_CONFIG_DIR is refused")
        } catch {
            let message = (error as? HolderStartError)?.userMessage ?? String(describing: error)
            #expect(!message.contains("example.com"))
        }
    }

    @Test func shellSessionsAreUntouched() throws {
        defer { m3RemoveFolder(folder) }
        let plan = try launcher().plan(sessionID: UUID(), cwd: "/tmp", loginEnvironment: ["PATH": "/usr/bin:/bin"])
        #expect(plan.environment["CODD_STATUSLINE_CHAIN"] == nil && plan.environment["CLAUDE_CONFIG_DIR"] == nil)
    }
}

// MARK: - Pins through the store (D12)

@MainActor
@Suite("Pinned sessions through the store (I1b)", .serialized)
final class PinnedSessionStoreTests {
    let folder: String
    let root: CoddDataRoot
    let claude: ClaudeDirectory
    let logs = Recorder<String>()
    let profile: String

    init() throws {
        folder = try m3TempFolder("codd-i1bp")
        root = CoddDataRoot(path: folder + "/r")
        claude = ClaudeDirectory(path: folder + "/claude")
        profile = folder + "/home/.claude-swap-backup/sessions/2-north_example.com"
        for dir in [root.path, claude.path + "/projects", profile + "/projects", folder + "/work", folder + "/env"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    deinit { m3RemoveFolder(folder) }

    /// A claude stand-in that writes its environment, then waits like a session.
    private func store() throws -> HolderSessionStore {
        let fake = folder + "/fake-claude"
        try "#!/bin/sh\nenv > '\(folder)/env/'\"$CODD_SESSION_ID\".txt\nexec /bin/cat\n".write(toFile: fake, atomically: true, encoding: .utf8)
        chmod(fake, 0o755)
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"],
                                      claudePathOverride: fake)
        launcher.coddHookPath = "/usr/bin/true"
        let logs = self.logs
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: claude, hooks: nil) { logs.append($0) }
        store.processAncestors = { _ in [1] }
        return store
    }

    private func environment(of id: SessionID) async -> String? {
        let file = folder + "/env/\(id).txt"
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOfFile: file, encoding: .utf8), text.contains("CODD_SESSION_ID") { return text }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    @Test func aPinRecordsTheAccountAndStartsInItsProfile() async throws {
        let store = try store()
        let resolution = Box(AccountPinResolution.usable(path: profile))
        store.accountPinning = { _, _ in resolution.value }
        store.accountProfilePath = { [profile] _ in profile }
        await store.start()
        store.setFollowingAccount("3")
        var request = NewSessionRequest(cwd: folder + "/work", kind: .claude)
        request.claude.accountNumber = 2
        let id = try #require(store.createSession(request))
        #expect(store.record(id)?.accountNumber == 2)
        let session = try #require(store.session(id))
        #expect(session.accountPinned && session.accountID == "2")
        let env = await environment(of: id)
        #expect(env?.contains("CLAUDE_CONFIG_DIR=\(profile)\n") == true)
        #expect(store.sessionAccountCounts.pinned[2] == 1 && store.sessionAccountCounts.following == 0)
        #expect(store.transcriptCatalog(for: id).projectsDirectory.path == profile + "/projects")
        // A following session shows the active account and follows a switch.
        let follower = try #require(store.createSession(NewSessionRequest(cwd: folder + "/work", kind: .claude)))
        #expect(store.session(follower)?.accountID == "3" && store.session(follower)?.accountPinned == false)
        store.setFollowingAccount("1")
        #expect(store.session(follower)?.accountID == "1" && store.session(id)?.accountID == "2")
        // A stale profile refuses a new pin before anything is written.
        resolution.value = .needsProfile
        let before = store.allSessions.count
        #expect(store.createSession(request) == nil)
        #expect(store.lastRefusal == "#2 的登入資料需要更新：先在終端機執行一次 cswap run 2")
        #expect(store.allSessions.count == before)
        m3ExpectNoAccountLeak(logs.values.joined(separator: "\n"), "the store's log")
        store.removeSessions(store.allSessions.map(\.id))
        store.shutdown()
    }

    @Test func resumeKeepsThePinAndAStaleProfileRefusesIt() async throws {
        let projectID = UUID()
        let ok = UUID(), stale = UUID()
        let group = ProjectGroup(name: "CODD", color: .purple, order: 0)
        try LayoutStore(fileURL: root.layoutURL).save(Layout(groups: [group], projects: [
            Project(id: projectID, groupId: group.id, name: "work", path: folder + "/work", order: 0),
        ], sessions: [
            SessionRecord(id: ok, claudeSessionId: "c-ok", projectId: projectID, kind: .claude, order: 0, createdAt: Date(), accountNumber: 2),
            SessionRecord(id: stale, claudeSessionId: "c-stale", projectId: projectID, kind: .claude, order: 1, createdAt: Date(),
                          accountNumber: 2),
        ]))
        let store = try store()
        let resolution = Box(AccountPinResolution.usable(path: profile))
        let relaunches = Recorder<Bool>()
        store.accountPinning = { _, relaunch in relaunches.append(relaunch); return resolution.value }
        await store.start()
        let okID = LayoutMapping.id(ok), staleID = LayoutMapping.id(stale)
        #expect(store.session(okID)?.state == .stopped && store.session(okID)?.accountPinned == true)
        store.resume(okID)
        let env = await environment(of: okID)
        #expect(env?.contains("CLAUDE_CONFIG_DIR=\(profile)\n") == true, "RESUME starts in the recorded account's profile")
        #expect(relaunches.values == [true])
        resolution.value = .needsProfile
        store.resume(staleID)
        #expect(store.problem?.message == "#2 的登入資料需要更新：先在終端機執行一次 cswap run 2")
        #expect(store.problem?.sessionID == staleID)
        #expect(store.session(staleID)?.state == .stopped, "nothing started")
        store.restart(staleID)
        #expect(store.session(staleID)?.state == .stopped)
        m3ExpectNoAccountLeak(logs.values.joined(separator: "\n"), "the store's log")
        store.removeSessions([okID, staleID])
        store.shutdown()
    }

    @Test func aLaunchProfilesOwnConfigDirRecordsItsAccount() async throws {
        let store = try store()
        store.accountForConfigDir = { [profile] dir in dir == profile ? 2 : nil }
        store.accountPinning = { _, _ in .notReady }
        await store.start()
        let issues = store.profiles.upsert(LaunchProfile(id: "claude-acct2", name: "claude-acct2", kind: .claude,
                                                         environment: ["CLAUDE_CONFIG_DIR": profile]))
        #expect(issues.isEmpty)
        var request = NewSessionRequest(cwd: folder + "/work", kind: .claude)
        request.claude.profileID = "claude-acct2"
        let id = try #require(store.createSession(request))
        #expect(store.record(id)?.accountNumber == 2)
        #expect(store.session(id)?.accountPinned == true)
        #expect(store.claudeConfigDirectory(for: id) == profile)
        #expect(store.transcriptCatalog(for: id).projectsDirectory.path == profile + "/projects")
        #expect(store.launchProfileRegistryDirectories.map(\.path) == [profile + "/sessions"])
        let env = await environment(of: id)
        #expect(env?.contains("CLAUDE_CONFIG_DIR=\(profile)\n") == true, "the profile's own variable")
        // Its RESUME needs no account store: the profile pins itself.
        #expect(store.relaunchConfigDir(for: id) == .success(nil))
        store.removeSessions([id])
        store.shutdown()
    }
}

// MARK: - codd-statusline copies (D8, D11)

@Suite("codd-statusline copies (I1b)", .serialized)
struct StatusLineBinaryTests {
    private func inode(_ path: String) -> UInt64? {
        var info = stat()
        return lstat(path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    @Test func hashedAndStableCopiesAreInstalledAndCollectedLikeCoddHook() throws {
        let folder = try m3TempFolder("codd-i1bb")
        defer { m3RemoveFolder(folder) }
        let root = CoddDataRoot(path: folder + "/r")
        let bundled = try #require(HolderLauncher.bundledCoddStatusLine, "CODD.app/Contents/MacOS/codd-statusline is missing")
        let installed = try #require(CoddStatusLineBinary.install(root: root) { _ in })
        #expect(installed.hasPrefix(root.path + "/bin/codd-statusline-"))
        #expect(HolderBinaryInstaller.isInstalledName((installed as NSString).lastPathComponent, prefix: CoddStatusLineBinary.namePrefix))
        let stable = root.path + "/bin/codd-statusline"
        #expect(FileManager.default.isExecutableFile(atPath: stable))
        #expect(FileManager.default.contents(atPath: stable) == FileManager.default.contents(atPath: bundled))
        let first = inode(stable)
        // Unchanged: left alone. Changed: replaced through a rename (a new inode, never in place).
        #expect(try CoddStatusLineBinary.installStable(bundled: bundled, root: root) == false)
        #expect(inode(stable) == first)
        try Data("junk".utf8).write(to: URL(fileURLWithPath: stable))
        #expect(try CoddStatusLineBinary.installStable(bundled: bundled, root: root))
        #expect(inode(stable) != first)
        #expect(FileManager.default.contents(atPath: stable) == FileManager.default.contents(atPath: bundled))
        // GC: an old copy no live session names goes; the named one, the current one and the stable copy stay.
        let old = root.path + "/bin/codd-statusline-aaaaaaaaaaaa", named = root.path + "/bin/codd-statusline-bbbbbbbbbbbb"
        for path in [old, named] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: path)
        }
        let argv = [["claude", "--settings", #"{"statusLine":{"command":"\#(named.replacingOccurrences(of: "/", with: "\\/"))"}}"#]]
        let removed = CoddStatusLineBinary.collectGarbage(root: root, current: installed, liveArgv: argv) { _ in }
        #expect(removed == [old])
        for path in [named, installed, stable] { #expect(FileManager.default.fileExists(atPath: path)) }
    }

    /// The launch writes the path single-quoted (M3 review fix): GC still finds it, also for a root
    /// with a `'` (`'\''` in the command, `'\\''` inside the `--settings` JSON).
    @Test func quotedCommandsStillCountAsReferenced() throws {
        let root = CoddDataRoot(path: "/r/co'dd data")
        let path = root.path + "/bin/codd-statusline-0123456789ab"
        let settings = try ClaudeHookSettings(endpoint: HookEndpoint(port: 43_001), sessionStartCommand: "/usr/bin/true",
                                              statusLine: StatusLineInjection(command: path)).settingsJSON()
        #expect(settings.contains(#"'\\''"#))
        #expect(CoddHookBinary.referencedPaths(in: [["claude", "--settings", settings]], root: root,
                                               namePrefix: CoddStatusLineBinary.namePrefix) == [path])
        let plain = CoddDataRoot(path: "/r/Application Support/CODD")
        let spaced = plain.path + "/bin/codd-statusline-aaaaaaaaaaaa"
        let json = try ClaudeHookSettings(endpoint: HookEndpoint(port: 43_001), sessionStartCommand: "/usr/bin/true",
                                          statusLine: StatusLineInjection(command: spaced)).settingsJSON()
        #expect(CoddHookBinary.referencedPaths(in: [["claude", "--settings", json]], root: plain,
                                               namePrefix: CoddStatusLineBinary.namePrefix) == [spaced])
    }
}

// MARK: - Menu bar (D23)

@MainActor
@Suite("Menu bar accounts and status item (I1b)")
struct MenuBarAccountsTests {
    @Test func atMostThreeRowsWithTheActiveOneAmongThem() {
        let ids = ["2", "3", "1", "4"]
        #expect(MenuBarPanelContent.visibleAccounts(ids, active: "3", expanded: false) == ["2", "3", "1"])
        #expect(MenuBarPanelContent.visibleAccounts(ids, active: "4", expanded: false) == ["2", "3", "4"], "R7 order kept")
        #expect(MenuBarPanelContent.visibleAccounts(ids, active: "4", expanded: true) == ids)
        #expect(MenuBarPanelContent.visibleAccounts(["2", "3"], active: nil, expanded: false) == ["2", "3"])
    }

    @Test func fourCswapAccountsShowThreeRowsAndTheExpander() async throws {
        let f = try AccountStoreFixture(count: 4, active: 4)
        await f.store.start()
        #expect(f.store.accounts.map(\.id) == ["2", "3", "1", "4"])
        let sessions = MockSessionStore(shiftClock: false)
        let content = MenuBarPanelContent.build(store: sessions, accounts: f.store, expanded: false)
        #expect(content.accountIDs == ["2", "3", "4"] && content.accountTotal == 4)
        #expect(f.store.account("4")?.plan == "MAX 5x" && f.store.account("4")?.alias == "")
        let shell = ShellState()
        let actions = MenuBarPanelActions(openSession: { _ in }, allow: { _ in }, openMain: {}, openSettings: { _ in },
                                          newSession: {}, quickNote: {})
        let view = MenuBarPanelView(store: sessions, accounts: f.store, actions: actions, shell: shell)
        view.activate()
        func buttons(_ v: NSView) -> [CoddButton] { ((v as? CoddButton).map { [$0] } ?? []) + v.subviews.flatMap(buttons) }
        func rows(_ v: NSView) -> [AccountRowView] { ((v as? AccountRowView).map { [$0] } ?? []) + v.subviews.flatMap(rows) }
        #expect(buttons(view).contains { $0.label == "▸ 全部帳號 4" })
        #expect(rows(view).map(\.accountID) == ["2", "3", "4"])
        shell.menuBarAccountsExpanded = true
        await m3Eventually("expanded") { rows(view).count == 4 }
        #expect(buttons(view).contains { $0.label == "▾ 全部帳號 4" })
        // R8 ticks while auto-switch is ON (the rows read the store's rule).
        var preferences = CoddPreferences.defaults
        preferences.accounts.autoSwitch.enabled = true
        f.store.apply(preferences: preferences)
        #expect(f.store.autoSwitch.enabled && f.store.autoSwitch.thresholdPercent == 2)
        try? await Task.sleep(for: .milliseconds(100)) // the rows redraw on the next main-actor turn
        if let dir = ProcessInfo.processInfo.environment["CODD_PARITY_DIR"] {
            // `TEST_RUNNER_CODD_PARITY_DIR=<dir> xcodebuild test …`: the panel on real (fake cswap) data.
            let panel = MenuBarPanel()
            panel.contentView = view
            view.layoutSubtreeIfNeeded()
            panel.setContentSize(NSSize(width: 380, height: view.fittingSize.height))
            view.layoutSubtreeIfNeeded()
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try M3ParitySnapshotTests.writePNG(view, to: URL(fileURLWithPath: dir).appendingPathComponent("menubar-panel-i1b.png"))
        }
        view.deactivate()
    }

    @Test func countsTitleAndPause() {
        #expect(StatusItemAppearance.countsTitle(waiting: 2, error: 1) == "◆2 ▲1")
        #expect(StatusItemAppearance.countsTitle(waiting: 0, error: 3) == "▲3")
        #expect(StatusItemAppearance.countsTitle(waiting: 0, error: 0) == "")
        var rules = CoddPreferencesTesting.notifications
        let now = Date()
        #expect(!SessionNotifier.isPaused(rules, now: now))
        rules.pausedUntil = now.addingTimeInterval(3600)
        #expect(SessionNotifier.isPaused(rules, now: now))
        #expect(!SessionNotifier.isPaused(rules, now: now.addingTimeInterval(3601)), "the hour ends by itself")
        #expect(BrandMark.statusImage(.normal, paused: true).accessibilityDescription == "CODD（通知已暫停）")
    }

    @Test func homeAndFooterSayWhyThereAreNoAccounts() async throws {
        var inputs = HomeModel.Inputs()
        inputs.realMode = true
        inputs.accountNote = AccountAvailability.noCswapNote
        inputs.accountSource = nil
        let model = HomeModel.build(store: MockSessionStore(shiftClock: false), inputs: inputs, now: Date())
        #expect(model.usageHeader == HomeModel.usageSortNote + " " + AccountAvailability.noCswapNote)
        let f = try AccountStoreFixture(debug: false)
        await f.store.start()
        let footer = SidebarFooterView(store: MockSessionStore(shiftClock: false), accounts: f.store, shell: ShellState(), realMode: true)
        func toggles(_ v: NSView) -> [FooterToggleView] { ((v as? FooterToggleView).map { [$0] } ?? []) + v.subviews.flatMap(toggles) }
        #expect(toggles(footer).first?.note == AccountAvailability.noCswapNote)
    }

    @Test func mockAccountsKeepTheArtboard() async {
        let accounts = MockAccountStore()
        #expect(accounts.accounts.map(\.id) == ["2", "3", "1"])
        #expect(accounts.availability == .ready && accounts.availability.note == nil)
        #expect(accounts.newSessionAccountOptions.map(\.title)
            == ["跟隨全域登入（#3 工作）", "固定 #3 工作", "固定 #2 藍鵲（cswap run）", "固定 #1 個人（cswap run）"])
        let content = MenuBarPanelContent.build(store: MockSessionStore(shiftClock: false), accounts: accounts)
        #expect(content.accountIDs == ["2", "3", "1"] && content.accountsNote == nil)
    }
}

/// A mutable value closures can share.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// The preference defaults the notification tests start from.
enum CoddPreferencesTesting {
    static var notifications: CoddPreferences.Notifications { CoddPreferences.defaults.notifications }
}

// MARK: - Reports end to end (D9)

@MainActor
@Suite("Status-line reports end to end (I1b)", .serialized)
struct StatusLineReportEndToEndTests {
    @Test func theCLIsReportReachesTheAccountItsConfigDirNames() async throws {
        let f = try AccountStoreFixture()
        let store = f.store!
        await store.start()
        let data = URL(fileURLWithPath: f.folder + "/data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let pipeline = HookPipeline(dataRoot: data, claudeDirectory: ClaudeDirectory(path: f.state.claudeDir.path), port: 0,
                                    portRange: HookPipeline.testPortRange) { _ in }
        pipeline.statusLineInterval = .milliseconds(200)
        pipeline.onStatusLine = { report in store.ingest(report) }
        await pipeline.start()
        await m3Eventually("listening") { pipeline.status.isListening }
        guard case .listening(let port) = pipeline.status, let token = pipeline.config?.token else {
            Issue.record("no endpoint")
            return
        }
        let reset3 = Int(try #require(f.state.weeklyReset(3)).timeIntervalSince1970)
        let reset2 = Int(try #require(f.state.weeklyReset(2)).timeIntervalSince1970)
        let five = Int(Date().timeIntervalSince1970) + 9000
        func stdin(_ used5: Double, _ used7: Double, reset: Int) -> String {
            #"{"session_id":"c-1","cwd":"/tmp","rate_limits":{"five_hour":{"used_percentage":\#(used5),"resets_at":\#(five)},"seven_day":{"used_percentage":\#(used7),"resets_at":\#(reset)}}}"#
        }
        let base = ["HOME": f.folder + "/home", "PATH": "/usr/bin:/bin", "CODD_HOOK_URL": "http://127.0.0.1:\(port)/hooks",
                    "CODD_HOOK_TOKEN": token, "CODD_SESSION_ID": UUID().uuidString.lowercased(),
                    "CODD_STATUSLINE_CHAIN": Data("cat >/dev/null; printf 'SL-%s' ok".utf8).base64EncodedString()]
        let stdinFile = f.folder + "/stdin.json"
        try stdin(12, 85, reset: reset3).write(toFile: stdinFile, atomically: true, encoding: .utf8)
        let first = try await runWithStdin(base, stdinFile)
        #expect(first.status == 0 && first.stdout == "SL-ok", "the chain's output reaches Claude unchanged")
        await m3Eventually("#3 from the default key") { store.account("3")?.fiveHour.remainingPercent == 88 }
        #expect(store.account("3")?.source == "statusline")
        // A pinned session's report (CLAUDE_CONFIG_DIR = the cswap profile) goes to #2.
        var pinned = base
        pinned["CLAUDE_CONFIG_DIR"] = f.state.profile(2).path
        try stdin(30, 54, reset: reset2).write(toFile: stdinFile, atomically: true, encoding: .utf8)
        let second = try await runWithStdin(pinned, stdinFile)
        #expect(second.status == 0)
        await m3Eventually("#2 from cswap-2") { store.account("2")?.fiveHour.remainingPercent == 70 }
        #expect(store.statusLine.lastKey == "cswap-2")
        await pipeline.refreshStatistics()
        #expect(pipeline.statistics?.statusLinesAccepted == 2)
        await pipeline.shutdown()
    }

    /// `/bin/sh -c '<binary> < <file>'`: stdin from a file, exactly the bytes Claude would pipe.
    private func runWithStdin(_ environment: [String: String], _ file: String) async throws -> (status: Int32, stdout: String) {
        let binary = try #require(HolderLauncher.bundledCoddStatusLine, "CODD.app/Contents/MacOS/codd-statusline is missing")
        let quoted = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let result = try await ProcessCommandRunner().run(CommandInvocation(
            executable: "/bin/sh", arguments: ["-c", "exec \(quoted(binary)) < \(quoted(file))"], environment: environment,
            timeout: .seconds(10)))
        return (result.status, result.stdoutText)
    }

    @Test func reportsOfOneKeyAreThrottledTheNewestWins() async throws {
        let throttle = StatusLineThrottle(interval: .milliseconds(300))
        let delivered = Recorder<Double>()
        func report(_ used: Double) -> StatusLineReport {
            StatusLineReport(sessionID: nil, claudeSessionId: nil, configKey: "default", fiveHour: StatusLineWindow(usedPercent: used, resetsAt: nil),
                             sevenDay: nil, hadRateLimits: true, receivedAt: Date())
        }
        for used in [1.0, 2.0, 3.0] {
            await throttle.offer(report(used)) { r in await MainActor.run { delivered.append(r.fiveHour?.usedPercent ?? -1) } }
        }
        #expect(delivered.values == [1], "the first goes at once, the rest wait")
        await m3Eventually("the newest after the interval") { delivered.values == [1, 3] }
        let other = StatusLineReport(sessionID: nil, claudeSessionId: nil, configKey: "cswap-2", fiveHour: nil, sevenDay: nil,
                                     hadRateLimits: false, receivedAt: Date())
        await throttle.offer(other) { r in await MainActor.run { delivered.append(r.configKey == "cswap-2" ? 99 : -1) } }
        #expect(delivered.values == [1, 3, 99], "another key is not held back")
    }
}

// MARK: - D3 paths and DEBUG flags

@Suite("cswap paths and the M3 DEBUG flags (I1b)")
struct CswapLocationAndFlagTests {
    @Test func d3ResolutionAndIsolation() {
        let exists: Set<String> = ["/opt/bin/cswap", "/h/.local/bin/cswap", "/fake/cswap", "/custom/cswap"]
        func resolve(standard: Bool, debugPath: String? = nil, debugRoot: String? = nil, preferred: String? = nil,
                     path: String? = "/usr/bin:/opt/bin") -> CswapLocation {
            CswapLocation.resolve(standardRoot: standard, debugPath: debugPath, debugRoot: debugRoot, preferredPath: preferred,
                                  loginPATH: path, home: "/h", isExecutable: { exists.contains($0) })
        }
        // A test data root without DEBUG flags: nothing, never the user's cswap or state.
        #expect(resolve(standard: false) == CswapLocation(executable: nil, root: nil))
        #expect(resolve(standard: false, debugPath: "/fake/cswap", debugRoot: "/tmp/s").executable == "/fake/cswap")
        #expect(resolve(standard: false, debugPath: "/fake/cswap", debugRoot: "/tmp/s").root?.path == "/tmp/s")
        // The standard root: the preference, else the login PATH, else ~/.local/bin/cswap.
        #expect(resolve(standard: true).executable == "/opt/bin/cswap")
        #expect(resolve(standard: true).root?.path == "/h/.claude-swap-backup")
        #expect(resolve(standard: true, path: "/usr/bin").executable == "/h/.local/bin/cswap")
        #expect(resolve(standard: true, preferred: "/custom/cswap").executable == "/custom/cswap")
        #expect(resolve(standard: true, preferred: "/missing/cswap").executable == nil, "a broken explicit path is not replaced")
        #expect(resolve(standard: true, debugPath: "/fake/cswap", debugRoot: "/tmp/s") == CswapLocation(
            executable: "/fake/cswap", root: URL(fileURLWithPath: "/tmp/s", isDirectory: true)), "DEBUG wins as a pair")
        // M3 review: one DEBUG flag alone never meets the user's real cswap or real state.
        #expect(resolve(standard: true, debugRoot: "/tmp/s") == CswapLocation(executable: nil, root: nil))
        #expect(resolve(standard: true, debugPath: "/fake/cswap") == CswapLocation(executable: nil, root: nil))
        #expect(resolve(standard: false, debugRoot: "/tmp/s") == CswapLocation(executable: nil, root: nil))
    }

    @Test func m3FlagsParseAndReleaseIgnoresThem() {
        let options = RealModeOptions.parse(arguments: [
            "CODD", "-codd-cswap-path", "~/x/cswap", "-codd-cswap-root", "/s/.claude-swap-backup", "-codd-claude-settings", "/c/settings.json",
            "-codd-switch-account", "2", "-codd-undo-switch", "YES", "-codd-new-claude-account", "2", "-codd-refresh-accounts",
        ], environment: [:], home: "/h")
        #expect(options.cswapPath == "/h/x/cswap" && options.cswapRoot == "/s/.claude-swap-backup")
        #expect(options.claudeSettings == "/c/settings.json")
        #expect(options.switchAccount == 2 && options.undoSwitch && options.newClaudeAccount == 2 && options.refreshAccounts)
        let release = options.releaseSubset
        #expect(release.cswapPath == nil && release.cswapRoot == nil && release.claudeSettings == nil && release.switchAccount == nil)
        #expect(RealModeOptions.parse(arguments: ["CODD", "-codd-switch-account", "0"], environment: [:], home: "/h").switchAccount == nil)
    }
}
