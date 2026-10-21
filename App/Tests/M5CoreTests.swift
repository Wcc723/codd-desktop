import AppKit
import CoddClaudeSettings
import CoddComposer
import CoddCore
import CoddDataStore
import CoddFiles
import CoddHooks
import CoddNotes
import CoddPreferences
import CoddUI
import Darwin
import Foundation
import Testing
@testable import CODD

// M5 I1 (docs/M5-PLAN.md §4): identity (D1), the defaults copy and isolation (D2, D25), the login
// item hint (D4), the data preflight wiring and the never-stricter proof (D14), stop while
// STARTING (D20). Temp folders and temp UserDefaults suites only: never the real data root, never
// the app's own or the legacy defaults domain, never a claude.

/// A fresh short folder under `$TMPDIR`, symlinks resolved (socket paths must fit 104 bytes).
private func m5Folder(_ prefix: String) throws -> String { try m3TempFolder(prefix) }

/// Every regular file under `root` (relative path → bytes), `cache/VERSION` left out (the
/// preflight writes it when missing).
private func snapshot(_ root: String) -> [String: Data] {
    var files: [String: Data] = [:]
    guard let walker = FileManager.default.enumerator(atPath: root) else { return files }
    while let relative = walker.nextObject() as? String {
        var info = stat()
        guard lstat(root + "/" + relative, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, relative != DataInventory.cacheVersionPath,
              let data = FileManager.default.contents(atPath: root + "/" + relative) else { continue }
        files[relative] = data
    }
    return files
}

@MainActor
private func waitUntil(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "timed out waiting for \(what)")
}

// MARK: - Identity (D1)

@MainActor
@Suite("M5 identity (D1)")
struct M5IdentityTests {
    @Test func constantsAndDerivedNames() {
        #expect(CoddIdentity.bundleIdentifier == "app.codd.CODD")
        #expect(CoddIdentity.legacyBundleIdentifier == "app.fancycodd.CODD")
        #expect(CoddIdentity.allBundleIdentifiers == ["app.codd.CODD", "app.fancycodd.CODD"])
        #expect(CoddIdentity.showMainWindowNames.map(\.rawValue) == ["app.codd.CODD.showMainWindow", "app.fancycodd.CODD.showMainWindow"])
        #expect(CoddIdentity.label("layout") == "app.codd.layout")
        #expect(CoddPasteboard.privateName.rawValue == "app.codd.CODD.private")
        #expect(SidebarDrag.pasteboardType.rawValue == "app.codd.sidebar-node")
        #expect(UIZoom.didChangeNotification.rawValue == "app.codd.CoddUI.UIZoomDidChange")
        // The test host is the built CODD.app (project.yml: app.codd.CODD, MARKETING_VERSION = VERSION).
        #expect(Bundle.main.bundleIdentifier == CoddIdentity.bundleIdentifier)
        #expect(CoddIdentity.runningBundleIdentifier == CoddIdentity.bundleIdentifier)
        #expect(CoddIdentity.version == "1.0.0")
        #expect(Int(CoddIdentity.build) != nil)
        #expect(CoddIdentity.isCODD(bundleIdentifier: "app.codd.CODD") && CoddIdentity.isCODD(bundleIdentifier: "app.fancycodd.CODD"))
        #expect(!CoddIdentity.isCODD(bundleIdentifier: "com.apple.Terminal") && !CoddIdentity.isCODD(bundleIdentifier: nil))
    }

    /// The show-window request goes out under both names and a holder of the root hears both
    /// (a temp root: no other CODD observes it).
    @Test func showWindowRequestIsPostedAndObservedUnderBothNames() async throws {
        let root = try m5Folder("codd-m5w")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let heard = Recorder<Int>()
        let observers = ShowMainWindowRequest.observe(dataRoot: root) { heard.append(1) }
        defer { observers.forEach { DistributedNotificationCenter.default().removeObserver($0) } }
        #expect(observers.count == 2)
        ShowMainWindowRequest.post(dataRoot: root)
        await waitUntil("both requests", timeout: .seconds(3)) { heard.values.count >= 2 }
        #expect(heard.values.count == 2)
    }
}

// MARK: - Defaults (D2, D25)

@MainActor
@Suite("M5 defaults copy and isolation (D2, D25)", .serialized)
struct M5DefaultsTests {
    /// Temp domains only (never the app's or the legacy one): removed afterwards.
    private func domains() -> (old: String, new: String, defaults: UserDefaults) {
        let id = UUID().uuidString.lowercased()
        let suite = "codd-m5-test.\(id)"
        return ("codd-m5-test.old.\(id)", "codd-m5-test.new.\(id)", UserDefaults(suiteName: suite) ?? .standard)
    }

    @Test func copiesCODDKeysOnceReplacingWhatATestRunWrote() throws {
        let (old, new, defaults) = domains()
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        defaults.setPersistentDomain([
            "NSWindow Frame CODDMainWindow": "100 100 1440 900 0 0 1728 1079 ",
            "NSSplitView Subview Frames CODDMainSplit": ["0.000000, 0.000000, 56.000000, 900.000000, NO, NO"],
            "NSStatusItem Preferred Position CODDStatusItem": 412,
            "CODDNotificationsEnabled": true,
            "CODDMetricsPasses": 3, "CODDSelfTest": true, "CODDForceVisibleTimers": true,
            "NSNavLastRootDirectory": "~/Desktop",
        ], forName: old)
        // A test run wrote the new domain before the user's first launch: the copy replaces it.
        defaults.setPersistentDomain(["NSWindow Frame CODDMainWindow": "0 0 800 600 0 0 1728 1079 ", "Unrelated": 1], forName: new)
        var lines: [String] = []
        let outcome = DefaultsIsolation.migrateLegacyDefaults(applies: true, from: old, into: new, defaults: defaults) { lines.append($0) }
        guard case .migrated(let result) = outcome else {
            Issue.record("not migrated: \(outcome)")
            return
        }
        #expect(result.copied == ["CODDNotificationsEnabled", "NSSplitView Subview Frames CODDMainSplit",
                                  "NSStatusItem Preferred Position CODDStatusItem", "NSWindow Frame CODDMainWindow"])
        #expect(lines == ["defaults migrated from=\(old) keys=4"])
        #expect(outcome.legacyDefaultsMigrated == true && outcome.key == "migrated")
        let target = try #require(defaults.persistentDomain(forName: new))
        #expect(target["NSWindow Frame CODDMainWindow"] as? String == "100 100 1440 900 0 0 1728 1079 ")
        #expect(target["NSStatusItem Preferred Position CODDStatusItem"] as? Int == 412)
        #expect(target["CODDMetricsPasses"] == nil && target["CODDSelfTest"] == nil && target["CODDForceVisibleTimers"] == nil,
                "DEBUG tool keys never come over")
        #expect(target["NSNavLastRootDirectory"] == nil, "only CODD's own keys")
        #expect(target["Unrelated"] as? Int == 1)
        #expect(target[DefaultsDomainMigration.marker] as? String == old)
        // The old domain is only read.
        #expect(defaults.persistentDomain(forName: old)?["CODDMetricsPasses"] as? Int == 3)

        // Once the marker is there nothing is copied again, even when the old domain changes.
        defaults.setPersistentDomain(["NSWindow Frame CODDMainWindow": "changed"], forName: old)
        defaults.setPersistentDomain(target.merging(["NSWindow Frame CODDMainWindow": "moved by the user"]) { _, new in new }, forName: new)
        lines = []
        let again = DefaultsIsolation.migrateLegacyDefaults(applies: true, from: old, into: new, defaults: defaults) { lines.append($0) }
        #expect(again.key == "alreadyDone" && again.legacyDefaultsMigrated == true)
        #expect(lines == ["defaults migration skipped reason=alreadyDone"])
        #expect(defaults.persistentDomain(forName: new)?["NSWindow Frame CODDMainWindow"] as? String == "moved by the user")
    }

    @Test func otherRootsAndAMissingSourceWriteNothing() {
        let (old, new, defaults) = domains()
        defer {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
        defaults.setPersistentDomain(["NSWindow Frame CODDMainWindow": "x"], forName: old)
        var lines: [String] = []
        // Any root but the standard one (and mock mode): not read, not written, not even logged.
        let skipped = DefaultsIsolation.migrateLegacyDefaults(applies: false, from: old, into: new, defaults: defaults) { lines.append($0) }
        #expect(skipped == .notApplicable && skipped.legacyDefaultsMigrated == nil)
        #expect(lines.isEmpty)
        #expect(defaults.persistentDomain(forName: new) == nil)
        // A new user: no legacy domain, no marker (nothing else happens).
        defaults.removePersistentDomain(forName: old)
        let missing = DefaultsIsolation.migrateLegacyDefaults(applies: true, from: old, into: new, defaults: defaults) { lines.append($0) }
        #expect(missing.key == "sourceMissing" && missing.legacyDefaultsMigrated == false)
        #expect(lines == ["defaults migration skipped reason=sourceMissing"])
        #expect(defaults.persistentDomain(forName: new)?[DefaultsDomainMigration.marker] == nil)
        // A build that still runs under the legacy id has nothing to copy from.
        #expect(DefaultsIsolation.migrateLegacyDefaults(applies: true, from: old, into: old, defaults: defaults) { _ in } == .sameDomain)
    }

    /// D25: only real mode on the standard data root restores and saves the window frame, the
    /// split view and the status item position.
    @Test func autosaveIsForTheStandardRootInRealModeOnly() throws {
        #expect(DefaultsIsolation.autosavesLayout(realMode: true, root: .standard))
        #expect(DefaultsIsolation.autosavesLayout(realMode: true, root: CoddDataRoot(path: CoddDataRoot.standard.path + "/")),
                "the same folder spelled with a slash")
        let temp = try m5Folder("codd-m5d")
        defer { try? FileManager.default.removeItem(atPath: temp) }
        #expect(!DefaultsIsolation.autosavesLayout(realMode: true, root: CoddDataRoot(path: temp)))
        #expect(!DefaultsIsolation.autosavesLayout(realMode: false, root: nil), "mock mode")
        #expect(!DefaultsIsolation.autosavesLayout(realMode: false, root: .standard))
        // What the app derives its root from: `-codd-data-root` makes it a test root.
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-data-root", temp], environment: [:], home: NSHomeDirectory())
        #expect(!DefaultsIsolation.autosavesLayout(realMode: options.enabled, root: options.dataRoot.map(CoddDataRoot.init(path:)) ?? .standard))
        #expect(DefaultsIsolation.windowFrameName == "CODDMainWindow" && DefaultsIsolation.statusItemName == "CODDStatusItem")
    }
}

// MARK: - DEBUG flags (§5)

@Suite("M5 I1 flags")
struct M5FlagTests {
    @Test func forceRenderAndStopAfterCreateParseAndReleaseIgnoresThem() {
        let parsed = RealModeOptions.parse(arguments: ["CODD", "-codd-force-render", "YES", "-codd-stop-after-create", "-codd-data-root", "/r"],
                                           environment: [:], home: "/Users/tester")
        #expect(parsed.forceRender && parsed.stopAfterCreate && parsed.dataRoot == "/r")
        #expect(!RealModeOptions.parse(arguments: ["CODD", "-codd-force-render", "NO"], environment: [:], home: "/Users/tester").forceRender)
        #expect(!parsed.releaseSubset.forceRender && !parsed.releaseSubset.stopAfterCreate)
        #expect(LaunchTiming.launchToSidebarLine(milliseconds: 312.4, rows: 21) == "perf launch-to-sidebar ms=312 rows=21")
        #expect(LaunchTiming.processStart().map { $0 <= Date() } == true)
    }
}

// MARK: - Login item (D4)

@MainActor
private final class M5FakeLoginItemService: LoginItemService {
    var state: LoginItemState
    init(_ state: LoginItemState) { self.state = state }
    func register() throws { state = .enabled }
    func unregister() throws { state = .notRegistered }
}

@MainActor
@Suite("M5 login item hint (D4)")
struct M5LoginItemTests {
    @Test func onButNotRegisteredSaysTheIdentityChanged() {
        let preferences = PreferencesService.inMemory(assignments: ["general.launchAtLogin=YES"])
        let fake = M5FakeLoginItemService(.notRegistered)
        let controller = LoginItemController(service: fake, preferences: preferences)
        controller.apply(preferences.preferences.general)
        #expect(controller.statusText == "CODD 換了識別碼：請把「登入時啟動」關掉再打開一次")
        // Off, then on again: registered, the hint goes.
        preferences.update { $0.general.launchAtLogin = false }
        controller.apply(preferences.preferences.general)
        #expect(controller.statusText == nil)
        preferences.update { $0.general.launchAtLogin = true }
        controller.apply(preferences.preferences.general)
        #expect(fake.state == .enabled && controller.statusText == nil)
    }

    @Test func textPerState() {
        #expect(LoginItemController.text(for: .enabled, launchAtLogin: true) == nil)
        #expect(LoginItemController.text(for: .requiresApproval, launchAtLogin: true) == LoginItemController.approvalHint)
        #expect(LoginItemController.text(for: .notRegistered, launchAtLogin: true) == LoginItemController.identityChangedHint)
        #expect(LoginItemController.text(for: .notFound, launchAtLogin: true) == LoginItemController.identityChangedHint)
        #expect(LoginItemController.text(for: .notRegistered, launchAtLogin: false) == nil)
        #expect(LoginItemController.text(for: .notFound, launchAtLogin: false)?.hasPrefix("系統找不到這個 App") == true)
        // A test data root keeps its own reason, whatever the preference says.
        #expect(LoginItemController.text(for: .unavailable(DisabledLoginItemService.testRootMessage), launchAtLogin: true)
                == DisabledLoginItemService.testRootMessage)
        // Approval pending: the M3 hint, not the D4 one.
        let preferences = PreferencesService.inMemory(assignments: ["general.launchAtLogin=YES"])
        let controller = LoginItemController(service: M5FakeLoginItemService(.requiresApproval), preferences: preferences)
        controller.apply(preferences.preferences.general)
        #expect(controller.statusText == LoginItemController.approvalHint)
    }
}

// MARK: - Data preflight wiring (D14)

@MainActor
@Suite("M5 data preflight wiring (D14)", .serialized)
struct M5DataPreflightTests {
    private func store(_ root: String) -> HolderSessionStore {
        HolderSessionStore(root: CoddDataRoot(path: root), launcher: nil, claudeDirectory: ClaudeDirectory(path: root + "/claude")) { _ in }
    }

    private func sampleLayout(cwd: String) -> (Layout, sessionID: String) {
        let group = ProjectGroup(name: "藍鵲", color: .blue, order: 0)
        let project = Project(groupId: group.id, name: "orb-toolkit-backend", path: cwd, order: 0)
        let session = LayoutSessionRecord(projectId: project.id, kind: .shell, titleOverride: "修正登入 API 401", order: 0,
                                          createdAt: Date(timeIntervalSince1970: 1_792_000_000))
        return (Layout(groups: [group], projects: [project], sessions: [session]), session.id.uuidString.lowercased())
    }

    /// A newer layout.json is reported, its sessions are shown, and a save attempt leaves every byte.
    @Test func newerLayoutIsShownReadOnlyAndNeverSaved() async throws {
        let root = try m5Folder("codd-m5n")
        defer { m3RemoveFolder(root) }
        let url = URL(fileURLWithPath: root + "/layout.json")
        let (layout, sessionID) = sampleLayout(cwd: root)
        try LayoutStore(fileURL: url).save(layout)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["version"] = 99
        object["futureMember"] = ["kept": true]
        let newer = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try newer.write(to: url)

        let holders = store(root)
        let monitor = DataFilesMonitor { _ in }
        await monitor.runPreflight(root: holders.root.url) { holders.queueDataIssue($0) }
        #expect(monitor.report?.status(of: "layout.json") == .newer(99))
        #expect(monitor.issues.map(\.kind) == [.newer])
        #expect(holders.problem?.message.hasPrefix("layout.json 是較新版本的 CODD 寫的（v99）") == true)
        #expect(holders.problem?.revealPath == nil, "a newer file is not moved: nothing to reveal")

        await holders.start()
        #expect(holders.session(sessionID)?.title == "修正登入 API 401", "read as far as this version decodes it")
        #expect(holders.groups.contains { $0.name == "藍鵲" })
        #expect(holders.layoutSaver.isReadOnly)
        holders.renameSession(sessionID, to: "改過的名字")
        holders.flushLayout()
        try? await Task.sleep(for: LayoutSaver.delay + .milliseconds(200))
        #expect(try Data(contentsOf: url) == newer, "every byte unchanged")
        holders.shutdown()
    }

    @Test func corruptPreferencesAreMovedAsideAndBannered() async throws {
        let root = try m5Folder("codd-m5p")
        defer { m3RemoveFolder(root) }
        let planted = Data("{\"version\":1, oops".utf8)
        try planted.write(to: URL(fileURLWithPath: root + "/preferences.json"))
        let holders = store(root)
        let monitor = DataFilesMonitor { _ in }
        await monitor.runPreflight(root: holders.root.url) { holders.queueDataIssue($0) }
        guard case .corrupt(let movedTo?)? = monitor.report?.status(of: "preferences.json") else {
            Issue.record("not moved: \(String(describing: monitor.report?.status(of: "preferences.json")))")
            return
        }
        #expect(movedTo.hasPrefix("preferences.json.corrupt-"))
        #expect(!FileManager.default.fileExists(atPath: root + "/preferences.json"))
        #expect(FileManager.default.contents(atPath: root + "/" + movedTo) == planted, "moved, never deleted")
        let problem = try #require(holders.problem)
        #expect(problem.message == "preferences.json 無法讀取，已移到 \(movedTo)，改用預設值")
        #expect(problem.revealPath == root + "/" + movedTo && problem.queued && problem.sessionID == nil)
        // The banner offers the Finder reveal, which a background run (this test host) only logs.
        let banner = ProblemBannerView()
        banner.update(problem, now: Date())
        #expect(banner.actionButtons.map(\.title) == ["在 Finder 中顯示", "知道了"])
        if AppActivation.isBackground {
            // Logged and skipped (never a Finder window from a test); the banner stays.
            holders.revealProblemFile()
            #expect(holders.problem == problem)
        }
        let dump = monitor.dump(bannersShown: holders.queuedProblemsShown.count)
        #expect(dump["bannersShown"] as? Int == 1)
        #expect((dump["issues"] as? [[String: Any]])?.first?["aside"] as? String == movedTo)
    }

    @Test func aStringVersionIsReadByItsStoreAndNotMoved() async throws {
        let root = try m5Folder("codd-m5v")
        defer { m3RemoveFolder(root) }
        let planted = Data(#"{"version":"1","general":{"launchAtLogin":false}}"#.utf8)
        try planted.write(to: URL(fileURLWithPath: root + "/preferences.json"))
        let monitor = DataFilesMonitor { _ in }
        let holders = store(root)
        await monitor.runPreflight(root: holders.root.url) { holders.queueDataIssue($0) }
        #expect(monitor.report?.status(of: "preferences.json") == .current(1))
        #expect(monitor.issues.isEmpty && holders.problem == nil)
        #expect(FileManager.default.contents(atPath: root + "/preferences.json") == planted)
    }

    @Test func aCorruptHookRecordIsRemovedSilently() async throws {
        let root = try m5Folder("codd-m5h")
        defer { m3RemoveFolder(root) }
        let id = UUID().uuidString.lowercased()
        try FileManager.default.createDirectory(atPath: root + "/hooks", withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: URL(fileURLWithPath: root + "/hooks/\(id).json"))
        let holders = store(root)
        let monitor = DataFilesMonitor { _ in }
        await monitor.runPreflight(root: holders.root.url) { holders.queueDataIssue($0) }
        #expect(monitor.report?.status(of: "hooks/\(id).json") == .removed)
        #expect(!FileManager.default.fileExists(atPath: root + "/hooks/\(id).json"))
        #expect(monitor.issues.isEmpty && holders.problem == nil, "DERIVED data: no banner")
    }

    /// A layout.json the preflight reads as an object but LayoutStore's decoder rejects (a
    /// member holding 1e999, which no Swift number holds: the preflight's top-level scan skips over
    /// it, JSONValue.parse fails on it): the store moves it aside itself; the post-load sweep banners it.
    @Test func aStoresOwnMoveGetsItsBannerThroughTheSweep() async throws {
        let root = try m5Folder("codd-m5s")
        defer { m3RemoveFolder(root) }
        let planted = Data(#"{"version":1,"groups":[],"projects":[],"sessions":[],"note":1e999}"#.utf8)
        let url = URL(fileURLWithPath: root + "/layout.json")
        try planted.write(to: url)
        let launch = Date().addingTimeInterval(-1)
        let holders = store(root)
        let monitor = DataFilesMonitor { _ in }
        await monitor.runPreflight(root: holders.root.url) { holders.queueDataIssue($0) }
        #expect(monitor.report?.status(of: "layout.json") == .current(1), "never stricter than the store: it decides")
        #expect(holders.problem == nil)
        guard case .corrupt(let aside?) = LayoutSaver.load(url) else {
            Issue.record("LayoutStore did not move it aside")
            return
        }
        let added = await monitor.sweep(root: holders.root.url, since: launch) { holders.queueDataIssue($0) }
        let name = (aside as NSString).lastPathComponent
        #expect(added.map(\.file) == ["layout.json"] && added.first?.aside == name)
        #expect(holders.problem?.message == "layout.json 無法讀取，已移到 \(name)，改用預設值")
        #expect(FileManager.default.contents(atPath: aside) == planted)
        // A second sweep names nothing again.
        #expect(await monitor.sweep(root: holders.root.url, since: launch) { holders.queueDataIssue($0) }.isEmpty)
    }

    /// Banners wait their turn; a problem reported meanwhile puts the shown one back first.
    @Test func bannersAreQueuedOneAtATime() throws {
        let root = try m5Folder("codd-m5q")
        defer { m3RemoveFolder(root) }
        let holders = store(root)
        holders.queueDataIssue(DataIssue(file: "layout.json", kind: .newer, version: 2))
        holders.queueDataIssue(DataIssue(file: "panes.json", kind: .newer, version: 3))
        #expect(holders.problem?.message.hasPrefix("layout.json") == true && holders.problemQueue.count == 1)
        holders.report("讀不到 session 資料夾")
        #expect(holders.problem?.message == "讀不到 session 資料夾" && holders.problemQueue.count == 2)
        holders.dismissProblem()
        #expect(holders.problem?.message.hasPrefix("layout.json") == true)
        holders.dismissProblem()
        #expect(holders.problem?.message.hasPrefix("panes.json") == true)
        holders.dismissProblem()
        #expect(holders.problem == nil && holders.problemQueue.isEmpty)
        #expect(holders.queuedProblemsShown.count == 2, "each banner counts once")
    }
}

// MARK: - Never stricter than a store (D14 safety rule)

@MainActor
@Suite("M5 preflight never stricter than the stores (D14)", .serialized)
struct M5NeverStricterTests {
    /// Every real store writes its file on a temp root; the preflight then reads each one as
    /// current, and a run changes no byte.
    @Test func everyStoresOwnOutputScansCurrent() async throws {
        let folder = try m5Folder("codd-m5x")
        defer { m3RemoveFolder(folder) }
        let rootPath = folder + "/data"
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let sessionID = UUID().uuidString.lowercased()
        let sessionDirectory = rootPath + "/sessions/" + sessionID
        try FileManager.default.createDirectory(atPath: sessionDirectory, withIntermediateDirectories: true)
        let work = folder + "/work"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let now = Date()

        // CoddCore: layout.json, profiles.json, quota.json.
        let group = ProjectGroup(name: "藍鵲", order: 0)
        let project = Project(groupId: group.id, name: "work", path: work, order: 0)
        try LayoutStore(fileURL: root.appendingPathComponent("layout.json")).save(Layout(groups: [group], projects: [project]))
        try LaunchProfileStore(fileURL: root.appendingPathComponent(LaunchProfileStore.fileName)).save(.seeded)
        try QuotaStore(dataRoot: root).save(QuotaBook(lastAutoSwitchAt: now))
        // CoddPreferences: preferences.json.
        try PreferencesStore(url: root.appendingPathComponent(PreferencesStore.fileName)).save(CoddPreferences())
        // App: cleanup.json, panes.json, answer.json.
        CleanupStateStore(dataRoot: root).update { $0.retention.firstRunAt = now }
        let shell = ShellState()
        _ = shell.addShellTab(in: sessionID, kind: .claude)
        let panes = PaneLayoutStore(root: CoddDataRoot(path: rootPath), shell: shell)
        await panes.load()
        panes.flush()
        PendingAnswerFile.write(HookToolDetail(tool: "Bash", summary: "ls -la"), directory: sessionDirectory)
        PendingAnswerFile.flush()
        // CoddComposer: sessions/<id>/composer.json.
        var history = ComposerHistory()
        history.record("修正登入 API 401")
        try ComposerStateFile.save(ComposerState(draft: "打卡頁 RWD 調整", history: history), directory: sessionDirectory)
        // CoddFiles: files/recent.json, files/ai-touches.json.
        try FileManager.default.createDirectory(atPath: rootPath + "/files", withIntermediateDirectories: true)
        RecentFilesStore(file: root.appendingPathComponent("files/recent.json"))
            .record(URL(fileURLWithPath: work + "/a.txt"), root: URL(fileURLWithPath: work), source: "test", at: now)
        let touches = AITouchLog(file: root.appendingPathComponent("files/ai-touches.json"), clock: { now }, saveDelay: .milliseconds(1))
        touches.record([AITouch(path: work + "/a.txt", session: sessionID, tool: "Edit", at: now)])
        touches.flush()
        // CoddHooks: config.json (a test port, never bound), hooks/<id>.json (the engine's encoder).
        _ = try HookConfigStore(dataRoot: root, portRange: 43000...43999, isPortAvailable: { _ in true }).loadOrCreate()
        try FileManager.default.createDirectory(atPath: rootPath + "/hooks", withIntermediateDirectories: true)
        try JSONEncoder().encode(HookSessionState(terminalId: sessionID, sessionId: sessionID))
            .write(to: URL(fileURLWithPath: rootPath + "/hooks/\(sessionID).json"))
        // CoddClaudeSettings: claude-settings-backups.json through a registration on a temp file.
        let claudeJSON = URL(fileURLWithPath: folder + "/claude.json")
        try ClaudeJSONFixture.write(to: claudeJSON.path)
        let installer = ClaudeUserConfigMCPInstaller(file: claudeJSON, backupsIndex: root.appendingPathComponent("claude-settings-backups.json"),
                                                     lockWait: .milliseconds(300))
        let plan = try installer.plan(.register(name: "codd", url: "http://127.0.0.1:43001/mcp", token: "made-up-token"))
        _ = try installer.apply(plan)
        // CoddNotes: notes/.codd/notebook.json, state.json, tombstones.json.
        let trash = folder + "/trash"
        let library = NotesLibrary(root: root.appendingPathComponent("notes", isDirectory: true),
                                   indexURL: root.appendingPathComponent("cache/notes-index.sqlite"),
                                   annotatedFolder: root.appendingPathComponent("cache/annotated", isDirectory: true),
                                   policy: .defaults, defaultAccess: .read,
                                   trash: { url in
                                       try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
                                       try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: trash + "/" + UUID().uuidString))
                                   })
        _ = try await library.open()
        let kept = try await library.create(NewNote(title: "常用指令", body: "# 常用指令\n\nnpm run dev\n")).metadata.id
        await library.markOpened(kept, at: now)
        let gone = try await library.create(NewNote(title: "要刪的筆記", body: "# 要刪的筆記\n")).metadata.id
        try await library.trash([gone])
        try await library.purge([gone])
        await library.close()

        let expected = ["layout.json", "profiles.json", "quota.json", "preferences.json", "cleanup.json", "panes.json",
                        "sessions/\(sessionID)/answer.json", "sessions/\(sessionID)/composer.json", "files/recent.json",
                        "files/ai-touches.json", "config.json", "hooks/\(sessionID).json", "claude-settings-backups.json",
                        "notes/.codd/notebook.json", "notes/.codd/state.json", "notes/.codd/tombstones.json"]
        for path in expected { #expect(FileManager.default.fileExists(atPath: rootPath + "/" + path), "\(path) was not written") }

        let scan = DataPreflight(root: root).scan()
        for path in expected {
            guard case .current? = scan.status(of: path) else {
                Issue.record("\(path): \(String(describing: scan.status(of: path))) (its store wrote it)")
                continue
            }
        }
        for file in scan.files {
            switch file.status {
            case .current, .missing: break
            default: Issue.record("\(file.path): \(file.status)")
            }
        }
        #expect(scan.issues.isEmpty && !scan.cacheWiped)

        let before = snapshot(rootPath)
        let report = DataPreflight(root: root).run()
        #expect(report.issues.isEmpty && !report.cacheWiped)
        #expect(snapshot(rootPath) == before, "a run changes no byte of a store's own output")
        #expect(FileManager.default.fileExists(atPath: rootPath + "/" + DataInventory.cacheVersionPath), "a missing VERSION is written")
    }
}

// MARK: - panes.json from a newer CODD (D14)

@MainActor
@Suite("M5 panes.json newer guard (D14)", .serialized)
struct M5PaneLayoutGuardTests {
    @Test func aNewerFileIsReadAndNeverReplaced() async throws {
        let root = try m5Folder("codd-m5g")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let url = URL(fileURLWithPath: root + "/panes.json")
        let session = UUID().uuidString.lowercased()
        let tab = UUID().uuidString.lowercased()
        let newer = Data("""
        {"version":99,"future":{"x":1},"sessions":{"\(session)":{"tabs":[{"id":"\(tab)","number":1}],"selected":"\(tab)",
        "composerOpen":true,"later":"kept"}}}
        """.utf8)
        try newer.write(to: url)
        let shell = ShellState()
        let store = PaneLayoutStore(root: CoddDataRoot(path: root), shell: shell)
        await store.load()
        #expect(store.newerVersion == 99)
        #expect(shell.pane(for: session).tabs.map(\.id) == [tab] && shell.pane(for: session).composerOpen, "read as far as it decodes")
        _ = shell.addShellTab(in: session, kind: .claude)
        try? await Task.sleep(for: PaneLayoutStore.saveDelay + .milliseconds(200))
        store.flush()
        #expect(try Data(contentsOf: url) == newer, "never saved over")
    }

    /// Review correctness-2: a new data root gets no panes.json until a session has a layout worth
    /// keeping (OnboardingGate counts the file), not even at quit.
    @Test func aNewRootGetsNoEmptyFile() async throws {
        let root = try m5Folder("codd-m5e")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let url = URL(fileURLWithPath: root + "/panes.json")
        let shell = ShellState()
        let store = PaneLayoutStore(root: CoddDataRoot(path: root), shell: shell)
        await store.load()
        try? await Task.sleep(for: PaneLayoutStore.saveDelay + .milliseconds(200))
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        // A real layout is written; emptying it again writes the empty file (the tabs must go).
        let session = UUID().uuidString.lowercased()
        _ = shell.addShellTab(in: session, kind: .claude)
        store.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
        shell.panes[session] = nil
        store.flush()
        #expect(try Data(contentsOf: url) == PaneLayoutStore.encode([:]))
    }

    /// A store that loaded a current file still checks the version right before each write.
    @Test func aNewerFileThatAppearedLaterIsNotReplaced() async throws {
        let root = try m5Folder("codd-m5r")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let url = URL(fileURLWithPath: root + "/panes.json")
        let shell = ShellState()
        let session = UUID().uuidString.lowercased()
        let store = PaneLayoutStore(root: CoddDataRoot(path: root), shell: shell)
        await store.load()
        #expect(store.newerVersion == nil)
        let newer = Data(#"{"version":2,"sessions":{}}"#.utf8)
        try newer.write(to: url)
        _ = shell.addShellTab(in: session, kind: .claude)
        store.flush()
        #expect(try Data(contentsOf: url) == newer)
    }
}

// MARK: - Stop while STARTING (D20)

/// Holds a spawn until the test opens it (no sleep race).
private actor SpawnGate {
    private var isOpen = false
    private(set) var waiting = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        for continuation in continuations { continuation.resume() }
        continuations = []
    }
}

@MainActor
@Suite("M5 stop while STARTING (D20)", .serialized)
struct M5StopWhileStartingTests {
    @Test func aStopBeforeThePidExistsEndsTheSession() async throws {
        let root = try m5Folder("codd-m5t")
        defer { m3RemoveFolder(root) }
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        let gate = SpawnGate()
        var launcher = HolderLauncher(holderExecutable: holder, root: CoddDataRoot(path: root), shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"])
        launcher.beforeStart = { await gate.wait() }
        let logs = Recorder<String>()
        let holders = HolderSessionStore(root: CoddDataRoot(path: root), launcher: launcher,
                                         claudeDirectory: ClaudeDirectory(path: root + "/claude")) { logs.append($0) }
        await holders.start()
        let id = try #require(holders.spawnShell(in: root))
        // The spawn is held off the main actor: STARTING, no holder pid.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while await gate.waiting == 0, clock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(await gate.waiting == 1)
        #expect(holders.session(id)?.state == .starting && holders.runtime(id)?.holderPid == nil)
        holders.stop([id])
        #expect(holders.pendingStops.contains(id) && holders.stopRequested.contains(id))
        #expect(logs.values.contains("stop deferred session=\(id)"))
        holders.stop([id])
        #expect(logs.values.filter { $0 == "stop deferred session=\(id)" }.count == 1, "logged once")

        await gate.open()
        await waitUntil("EXITED", timeout: .seconds(10)) { holders.session(id)?.state == .exited }
        #expect(holders.pendingStops.isEmpty && holders.stopRequested.contains(id))
        let pid = try #require(holders.runtime(id)?.holderPid)
        #expect(logs.values.contains("stop applied-after-spawn session=\(id) holderPid=\(pid)"))
        await waitUntil("holder gone", timeout: .seconds(5)) { kill(pid, 0) != 0 }
        holders.shutdown()
    }
}
