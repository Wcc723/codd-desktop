import AppKit
import CoddClaudeSettings
import CoddCore
import CoddOnboarding
import CoddOnboardingUI
import CoddPreferences
import CoddUI
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import CODD

// M5 I2 (docs/M5-PLAN.md D5–D13, §2.3–§2.5): the onboarding gate, the facts mapping, claude's
// resolution, the import, onboarding.json, the reopen routing and points, the notification request
// and mock mode. Temp folders only: never the real data root, `~/.claude`, `~/.claude.json`, cswap
// or a claude (the "claude" here is a shell script that is never run).

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A fresh short folder under `$TMPDIR`, symlinks resolved.
private func onboardingFolder(_ prefix: String) throws -> String { try m3TempFolder(prefix) }

private func touch(_ path: String, _ contents: String = "{}") throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: URL(fileURLWithPath: path))
}

/// SHA-256 and mtime of a file (the import must change neither).
private struct FileFingerprint: Equatable {
    let digest: String
    let modified: Double

    init(_ path: String) {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var info = stat()
        modified = lstat(path, &info) == 0 ? Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9 : -1
    }
}

private func candidate(_ path: String, lastUsed: Date?, transcripts: Int = 1) -> ImportCandidate {
    ImportCandidate(path: path, name: PathText.lastComponent(path), prefix: nil, displayPath: path, lastUsed: lastUsed,
                    transcripts: transcripts, hidden: nil)
}

/// A probe result as the App would build it (claude found, cswap missing, hooks up to date).
private func probeResult(root: String, catalog: ProjectCatalog = .empty) -> OnboardingProbeResult {
    let facts = EnvironmentFacts(claude: .found(version: "2.1.302", path: "/opt/fake/claude"), cswap: .missing,
                                 hooks: .upToDate(file: root + "/claude/settings.json"),
                                 dataRoot: .init(path: root, writable: true, mcpEndpoint: "127.0.0.1:47821", mcpRunning: true),
                                 checkedAt: Date(), milliseconds: 12, projects: .found(count: catalog.visibleTotal, source: "~/.claude.json"))
    return OnboardingProbeResult(facts: facts, catalog: catalog, existingGroups: [], notesPath: root + "/notes",
                                 claudeCodeRegistered: nil, claudeCodeReason: "測試資料夾不會改動 ~/.claude.json", codexAvailable: false)
}

/// Records what the wizard asked; never touches the app.
@MainActor
private final class FakeOnboardingHost: OnboardingHost {
    var result: OnboardingProbeResult
    var applied: [ImportPlan] = []
    var ended: [ProjectID?] = []
    var logs: [String] = []
    var asked = 0
    weak var presenter: OnboardingPresenter?

    init(result: OnboardingProbeResult) { self.result = result }

    func onboardingProbe() async -> OnboardingProbeResult { result }
    func onboardingExistingGroups() -> [ExistingGroup] { [] }
    func onboardingApply(_ plan: ImportPlan) -> OnboardingImport.Outcome {
        applied.append(plan)
        return OnboardingImport.Outcome(projects: plan.additions.count, groups: plan.groupCount, firstProject: nil,
                                        paths: plan.additions.map(\.path))
    }
    func onboardingPreviewHooks(on window: NSWindow?) {}
    func onboardingRevealNotes() {}
    func onboardingRegisterClaudeCode(on window: NSWindow?) {}
    func onboardingCopyCodexSnippet(on window: NSWindow?) {}
    func onboardingAddAccount() {}
    func onboardingRequestNotifications() async -> DoneStepModel.Notifications {
        asked += 1
        return .suppressed
    }
    func onboardingEnded(firstProject: ProjectID?) {
        ended.append(firstProject)
        presenter?.closeAfterEnding()
    }
    func onboardingLog(_ line: String) { logs.append(line) }
}

// MARK: - Gate (D5)

@MainActor
@Suite("M5 onboarding gate (D5)")
struct M5OnboardingGateTests {
    @Test func aRootIsNewUntilAnyMarkerFileExists() throws {
        let root = try onboardingFolder("codd-m5og")
        defer { m3RemoveFolder(root) }
        let url = URL(fileURLWithPath: root, isDirectory: true)
        #expect(OnboardingGate.isNewDataRoot(url))
        // A session folder without meta.json (a crashed spawn) is not "used before".
        try FileManager.default.createDirectory(atPath: root + "/sessions/abc", withIntermediateDirectories: true)
        #expect(OnboardingGate.isNewDataRoot(url))
        for marker in ["layout.json", "panes.json", "onboarding.json", "sessions/abc/meta.json"] {
            try touch(root + "/" + marker)
            #expect(!OnboardingGate.isNewDataRoot(url), "\(marker)")
            try FileManager.default.removeItem(atPath: root + "/" + marker)
            #expect(OnboardingGate.isNewDataRoot(url))
        }
    }

    @Test func theLaunchDecisionPerRootAndFlag() {
        let root = URL(fileURLWithPath: "/tmp/codd-never-read", isDirectory: true)
        func decide(standard: Bool, new: Bool, mode: String? = nil, show: String? = nil, step: Int? = nil,
                    real: Bool = true) -> OnboardingLaunch {
            OnboardingLaunch.decide(realMode: real, root: root, standardRoot: standard, mode: mode, show: show, step: step, isNew: { _ in new })
        }
        #expect(decide(standard: true, new: true) == OnboardingLaunch(show: true, reason: "new-root", start: .detect))
        #expect(decide(standard: true, new: false) == OnboardingLaunch(show: false, reason: "existing-root", start: .detect))
        // Any other root never shows it by itself (no earlier e2e script sees it).
        #expect(decide(standard: false, new: true) == OnboardingLaunch(show: false, reason: "not-standard-root", start: .detect))
        #expect(decide(standard: false, new: true, mode: "auto").show)
        #expect(!decide(standard: false, new: false, mode: "auto").show)
        #expect(decide(standard: false, new: false, mode: "show") == OnboardingLaunch(show: true, reason: "flag-show", start: .detect))
        #expect(decide(standard: true, new: true, mode: "never") == OnboardingLaunch(show: false, reason: "flag-never", start: .detect))
        #expect(decide(standard: false, new: false, mode: "show", step: 4).start == .notebook)
        // `-codd-show onboarding[:<n>|:all]` in both modes; mock mode only this way.
        #expect(decide(standard: false, new: false, show: "onboarding") == OnboardingLaunch(show: true, reason: "show-flag", start: .detect))
        #expect(decide(standard: false, new: false, show: "onboarding:3", real: false)
            == OnboardingLaunch(show: true, reason: "mock-show", start: .hooks))
        #expect(decide(standard: false, new: false, show: "onboarding:all", real: false).snapshotsAllSteps)
        #expect(decide(standard: false, new: false, show: "onboarding:ALL", real: false).snapshotsAllSteps)
        #expect(decide(standard: false, new: true, mode: "show", real: false) == OnboardingLaunch(show: false, reason: "mock", start: .detect))
        #expect(!decide(standard: false, new: true, show: "status").show)
        #expect(OnboardingLaunch.flow(start: .accounts).state(of: .hooks) == .done)
    }

    @Test func theDebugFlagsParse() {
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-onboarding", "AUTO", "-codd-onboarding-step", "5",
                                                        "-codd-onboarding-actions", "suggest,next, skip,goto:3,check:/tmp/a b,group:/tmp/x=new:2",
                                                        "-codd-show", "onboarding:all"], environment: [:], home: "/Users/test")
        #expect(options.onboarding == "auto")
        #expect(options.onboardingStep == 5)
        #expect(options.onboardingActions == ["suggest", "next", "skip", "goto:3", "check:/tmp/a b", "group:/tmp/x=new:2"])
        #expect(options.show == "onboarding:all")
        let bad = RealModeOptions.parse(arguments: ["CODD", "-codd-onboarding", "maybe", "-codd-onboarding-step", "9"], environment: [:],
                                        home: "/Users/test")
        #expect(bad.onboarding == nil && bad.onboardingStep == nil)
        // Release keeps none of them (never automatic on a throwaway root).
        #expect(options.releaseSubset.onboarding == nil && options.releaseSubset.onboardingActions.isEmpty)
        let group = OnboardingDebugAction("group:/tmp/x=y=new:2")
        #expect(group.name == "group" && group.pathAndValue?.path == "/tmp/x=y" && group.pathAndValue?.value == "new:2")
        #expect(OnboardingDebugAction("GOTO:3") == OnboardingDebugAction("goto:3"))
    }
}

// MARK: - Facts (D11)

@MainActor
@Suite("M5 onboarding facts (D11)")
struct M5OnboardingFactsTests {
    @Test func claudeFacts() {
        #expect(OnboardingFacts.claude(path: nil, isExecutable: false, version: nil) == .missing)
        // The standard root's fallback is a bare `claude`: never run, so missing.
        #expect(OnboardingFacts.claude(path: "claude", isExecutable: true, version: "2.1.302") == .missing)
        #expect(OnboardingFacts.claude(path: "/nope/claude", isExecutable: false, version: nil) == .missing)
        #expect(OnboardingFacts.claude(path: "/opt/claude", isExecutable: true, version: nil) == .failed("--version 沒有回報版本"))
        #expect(OnboardingFacts.claude(path: "/opt/claude", isExecutable: true, version: "2.1.302") == .found(version: "2.1.302", path: "/opt/claude"))
    }

    /// Security review: a test data root never reads the user's `~/.claude.json` or transcripts.
    /// Paths only (nothing is read); `home` is a made-up folder standing in for the real one.
    @Test func theCatalogIsSkippedOnTestRootsWithTheUsersClaudeDirectory() {
        let home = "/Users/codd-test-home"
        #expect(OnboardingFacts.catalogIsProtected(standardRoot: false, claudeDirectory: home + "/.claude", home: home))
        #expect(OnboardingFacts.catalogIsProtected(standardRoot: false, claudeDirectory: home + "/elsewhere", home: home),
                "its .claude.json would be the user's ~/.claude.json")
        #expect(!OnboardingFacts.catalogIsProtected(standardRoot: true, claudeDirectory: home + "/.claude", home: home))
        #expect(!OnboardingFacts.catalogIsProtected(standardRoot: false, claudeDirectory: "/tmp/codd-x/home/.claude", home: home))
        #expect(OnboardingFacts.protectedCatalog.candidates.isEmpty && OnboardingFacts.protectedCatalog.problem != nil)
    }

    @Test func cswapFacts() {
        #expect(OnboardingFacts.cswap(base: .noCswap, version: nil, path: nil, accounts: 0) == .missing)
        #expect(OnboardingFacts.cswap(base: .loading, version: nil, path: nil, accounts: 0) == .loading)
        #expect(OnboardingFacts.cswap(base: .unsupported(version: "0.24.1"), version: "0.24.1", path: "/x/cswap", accounts: 0)
            == .unsupported("0.24.1"))
        #expect(OnboardingFacts.cswap(base: .unreadable(reason: "sequence.json 壞了"), version: "0.26.0", path: "/x/cswap", accounts: 0)
            == .unreadable("sequence.json 壞了"))
        #expect(OnboardingFacts.cswap(base: .ready, version: "0.26.0", path: "/x/cswap", accounts: 3)
            == .ready(version: "0.26.0", path: "/x/cswap", accounts: 3))
    }

    @Test func hooksFactsFollowTheInspection() {
        let file = "/tmp/h/.claude/settings.json"
        #expect(OnboardingFacts.hooks(.unknown, file: file) == .unknown)
        #expect(OnboardingFacts.hooks(.failed("不是 JSON"), file: file) == .unreadable("不是 JSON"))
        let legacy = ClaudeSettingsInspection(legacyHookEvents: ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"],
                                              legacyHandlerCount: 4,
                                              foreign: [ForeignHookTool(name: "hook-tap", code: "hook-tap", events: ["Stop", "Notification"])])
        let state = ClaudeSettingsService.InspectionState.loaded(legacy, exists: true)
        #expect(OnboardingFacts.hooks(state, file: file) == .legacy(events: ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"], file: file))
        #expect(OnboardingFacts.webLeftovers(state))
        #expect(OnboardingFacts.foreign(state) == [HooksStepModel.Foreign(command: "hook-tap", name: "hook-tap", count: 2)])
        // Only CODD web's status line is left: still legacy, never `0 個事件`.
        let web = ClaudeSettingsService.InspectionState.loaded(ClaudeSettingsInspection(statusLine: .coddWeb(inner: nil)), exists: true)
        #expect(OnboardingFacts.hooks(web, file: file) == .legacy(events: ["statusLine"], file: file))
        let outdated = ClaudeSettingsService.InspectionState.loaded(ClaudeSettingsInspection(statusLine: .coddDesktop(chain: nil, current: false)),
                                                                    exists: true)
        #expect(OnboardingFacts.hooks(outdated, file: file) == .statuslineOutdated(file: file))
        #expect(OnboardingFacts.statusline(outdated) == .outdated)
        let current = ClaudeSettingsService.InspectionState.loaded(ClaudeSettingsInspection(statusLine: .coddDesktop(chain: nil, current: true)),
                                                                   exists: true)
        #expect(OnboardingFacts.hooks(current, file: file) == .upToDate(file: file))
        #expect(OnboardingFacts.statusline(current) == .installed && !OnboardingFacts.webLeftovers(current))
        #expect(OnboardingFacts.statusline(.loaded(ClaudeSettingsInspection(), exists: false)) == .notInstalled)
    }

    /// The boot block for a Mac with neither claude nor cswap and CODD web leftovers.
    @Test func theBootBlockForMissingTools() {
        let facts = EnvironmentFacts(claude: .missing, cswap: .missing,
                                     hooks: .legacy(events: ["PreCompact", "PostCompact"], file: "/tmp/h/.claude/settings.json"),
                                     dataRoot: .init(path: "/tmp/r", writable: true, mcpEndpoint: "127.0.0.1:47821", mcpRunning: true),
                                     checkedAt: Date(), milliseconds: 800, projects: .missing(source: "~/.claude.json"))
        let report = EnvironmentReport.make(facts, step: .detect, imported: nil, timeZone: .current, home: "/Users/test")
        let lines = report.lines.map { "\($0.tag.label) \($0.name) \($0.value)" }
        #expect(lines.contains("[FAIL] claude 找不到"))
        #expect(lines.contains("[ .. ] cswap 沒有安裝"))
        #expect(lines.contains("[ .. ] hooks 需要更新（2 個事件）"))
        let items = DetectItem.items(for: facts, home: "/Users/test")
        #expect(items.map(\.target) == [nil, .accounts, .hooks])
        let accounts = AccountsStepModel.make(cswap: facts.cswap, rows: [])
        #expect(accounts.availabilityNote == "找不到 cswap" && !accounts.canAdd)
    }

    @Test func accountRowsAreAliasesInWeeklyResetOrder() {
        let now = Date()
        func vm(_ id: String, _ alias: String, resetIn hours: Double?, pseudo: Bool = false) -> AccountVM {
            let account = AccountVM(id: id, slot: pseudo ? "—" : "#\(id)", alias: alias, plan: "MAX 20x",
                                    fiveHour: QuotaWindow(remainingPercent: 90, resetsAt: nil),
                                    week: QuotaWindow(remainingPercent: 40, resetsAt: hours.map { now.addingTimeInterval($0 * 3600) }),
                                    source: "", sourceAt: nil, sessionCount: 0)
            account.isPseudo = pseudo
            return account
        }
        let rows = OnboardingFacts.accountRows([vm("1", "個人", resetIn: 105), vm("3", "工作", resetIn: 73), vm("2", "藍鵲", resetIn: 36),
                                                vm("x", "目前登入", resetIn: 1, pseudo: true)], activeID: "3", now: now)
        #expect(rows.map(\.slot) == ["#2", "#3", "#1"])
        #expect(rows.map(\.alias) == ["藍鵲", "工作", "個人"])
        #expect(rows.map(\.active) == [false, true, false])
        #expect(rows.allSatisfy { $0.weeklyReset.hasPrefix("1w 重置 ") && $0.weeklyReset.hasSuffix("後") })
        #expect(rows.first?.weeklyRemaining == 40 && rows.first?.fiveHourRemaining == 90)
        #expect(!rows.contains { $0.alias.contains("@") })
    }
}

// MARK: - claude resolution (D5, M3 D3 / D28)

@MainActor
@Suite("M5 onboarding claude resolution")
struct M5OnboardingClaudeTests {
    @Test func theLoginPathFindsAClaudeOutsideLocalBinOnTheStandardRootOnly() throws {
        let folder = try onboardingFolder("codd-m5oc")
        defer { m3RemoveFolder(folder) }
        let bin = folder + "/opt/tools/bin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        // A script that is never run (resolution only looks at the file).
        try touch(bin + "/claude", "#!/bin/sh\nexit 1\n")
        chmod(bin + "/claude", 0o755)
        let home = folder + "/home"
        let path = "/usr/bin:/bin:\(bin)"
        let found = AppDelegate.claudeExecutable(override: nil, standardRoot: true, loginPATH: path, home: home)
        #expect(found == bin + "/claude")
        #expect(OnboardingFacts.claude(path: found, isExecutable: FileManager.default.isExecutableFile(atPath: found ?? ""), version: nil)
            == .failed("--version 沒有回報版本"))
        // Not on the login PATH and no ~/.local/bin/claude: the bare name, which is never run.
        #expect(AppDelegate.claudeExecutable(override: nil, standardRoot: true, loginPATH: "/usr/bin", home: home) == "claude")
        // A throwaway or test root never searches the PATH for the user's claude.
        #expect(AppDelegate.claudeExecutable(override: nil, standardRoot: false, loginPATH: path, home: home) == nil)
        #expect(AppDelegate.claudeExecutable(override: "/fake/claude", standardRoot: false, loginPATH: path, home: home) == "/fake/claude")
    }
}

// MARK: - Import (D8, D9)

@MainActor
@Suite("M5 onboarding import (D8, D9)", .serialized)
struct M5OnboardingImportTests {
    /// The C1 fixture into a temp home, read, pre-checked and imported into a real store: exactly
    /// the plan (groups, colors, order), and `.claude.json` and the transcripts are untouched.
    @Test func theFixtureImportsExactlyThePlanAndWritesNothingOutsideTheSidebar() async throws {
        let folder = try onboardingFolder("codd-m5oi")
        defer { m3RemoveFolder(folder) }
        let home = folder + "/home"
        let claudeDir = home + "/.claude"
        let work = folder + "/work"
        try FileManager.default.createDirectory(atPath: claudeDir + "/projects", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent("scripts/m5-fixtures/make-import-fixture.sh").path, claudeDir, work]
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = NSTemporaryDirectory()
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let config = home + "/.claude.json"
        let transcripts = (FileManager.default.subpaths(atPath: claudeDir + "/projects") ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        #expect(!transcripts.isEmpty)
        let before = FileFingerprint(config)
        let transcriptsBefore = transcripts.map { FileFingerprint(claudeDir + "/projects/" + $0) }

        let catalog = ProjectCatalogReader.read(claudeDirectory: URL(fileURLWithPath: claudeDir, isDirectory: true), home: home,
                                                existingProjectPaths: [])
        #expect(catalog.problem == nil && catalog.candidates.count == 8)
        let step = ImportStepModel.initial(catalog: catalog, existing: [], now: Date(), timeZone: .current, home: home)
        let plan = step.with(step.selection.applyingSuggestions(step.suggestion)).plan
        #expect(plan.newGroups.map(\.name) == ["clients", "labs"])
        #expect(plan.newGroups.map(\.color) == ["red", "blue"])
        #expect(plan.additions.map(\.path) == ["clients/alpha-web", "labs/mcp", "clients/alpha-api", "solo-tool", "labs/x"].map { work + "/" + $0 })

        let rootPath = folder + "/root"
        let root = CoddDataRoot(path: rootPath)
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        let launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"])
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: ClaudeDirectory(path: claudeDir), hooks: nil) { _ in }
        await store.start()
        defer { store.shutdown() }
        let outcome = OnboardingImport.apply(plan, to: store)
        #expect(outcome.projects == 5 && outcome.groups == 2)
        let user = store.groups.filter { !$0.isUngrouped }
        #expect(user.map(\.name) == ["clients", "labs"])
        #expect(user.map(\.color) == [.red, .blue])
        func names(_ group: GroupVM?) -> [String] { group?.projectIDs.compactMap { store.project($0)?.name } ?? [] }
        #expect(names(user.first) == ["alpha-web", "alpha-api"])
        #expect(names(user.last) == ["mcp", "x"])
        #expect(names(store.groups.first { $0.isUngrouped }) == ["solo-tool"])
        #expect(outcome.firstProject.flatMap { store.project($0)?.name } == "alpha-web")
        // Nothing but the sidebar changed: the import source and the transcripts are as they were.
        #expect(FileFingerprint(config) == before)
        #expect(transcripts.map { FileFingerprint(claudeDir + "/projects/" + $0) } == transcriptsBefore)
        // A second read leaves the imported projects out (`另有 n 個已在側欄`).
        let again = ProjectCatalogReader.read(claudeDirectory: URL(fileURLWithPath: claudeDir, isDirectory: true), home: home,
                                              existingProjectPaths: OnboardingFacts.projectPaths(store))
        #expect(again.alreadyInCODD == 5 && again.candidates.count == 3)
    }

    @Test func nextImportsTheSelectionAndSkipImportsNothing() async throws {
        let root = try onboardingFolder("codd-m5on")
        defer { m3RemoveFolder(root) }
        let now = Date()
        let catalog = ProjectCatalog(source: "~/.claude.json",
                                     candidates: [candidate(root + "/w/a/one", lastUsed: now.addingTimeInterval(-60)),
                                                  candidate(root + "/w/a/two", lastUsed: now.addingTimeInterval(-120)),
                                                  candidate(root + "/w/solo", lastUsed: now.addingTimeInterval(-180))],
                                     alreadyInCODD: 0, problem: nil)
        for skipping in [true, false] {
            let host = FakeOnboardingHost(result: probeResult(root: root, catalog: catalog))
            let controller = OnboardingController(source: .live, reason: "test", start: .importProjects, host: host, stateStore: nil)
            await controller.start()
            #expect(controller.importStep.checkedCount == 3)
            if skipping {
                controller.skip()
                #expect(host.applied.isEmpty)
                #expect(controller.importHandled == .skipped && controller.importedProjects == 0)
                #expect(controller.flow.state(of: .importProjects) == .skipped)
            } else {
                let plan = controller.importStep.plan
                controller.next()
                #expect(host.applied == [plan])
                #expect(controller.importedProjects == 3 && controller.importedGroups == 1)
                // The imported rows leave the table, nothing stays checked: no second import.
                #expect(controller.importStep.catalog.candidates.isEmpty && controller.importStep.catalog.alreadyInCODD == 3)
                controller.back()
                controller.next()
                #expect(host.applied.count == 1)
            }
            #expect(controller.flow.current == .hooks)
        }
    }
}

// MARK: - onboarding.json (D7)

@MainActor
@Suite("M5 onboarding.json (D7)", .serialized)
struct M5OnboardingStateTests {
    @Test func finishWritesTheFileAndMockModeNever() async throws {
        let root = try onboardingFolder("codd-m5of")
        defer { m3RemoveFolder(root) }
        let store = OnboardingStateStore(dataRoot: URL(fileURLWithPath: root, isDirectory: true))
        let host = FakeOnboardingHost(result: probeResult(root: root))
        let controller = OnboardingController(source: .live, reason: "test", start: .detect, host: host, stateStore: store)
        await controller.start()
        controller.next()
        controller.skip()
        #expect(controller.flow.current == .hooks)
        controller.finish(.done)
        let saved = try #require(store.load())
        #expect(saved.v == 1 && saved.appVersion == CoddIdentity.version && saved.build == CoddIdentity.build)
        #expect(saved.steps["detect"] == .done && saved.steps["import"] == .skipped && saved.steps["hooks"] == .done)
        #expect(saved.steps["done"] == .todo && saved.notifications == .notAsked)
        #expect(saved.imported == .init(projects: 0, groups: 0))
        #expect(host.ended.count == 1)
        var info = stat()
        #expect(stat(store.url.path, &info) == 0 && (info.st_mode & 0o777) == 0o600)

        let mockRoot = try onboardingFolder("codd-m5om")
        defer { m3RemoveFolder(mockRoot) }
        let mock = OnboardingController(source: .mock, reason: "mock-show", start: .done, host: host, stateStore: nil)
        mock.finish(.done)
        #expect(mock.hasEnded && mock.savedFile == nil && mock.stateStore == nil)
        #expect(!FileManager.default.fileExists(atPath: mockRoot + "/onboarding.json"))
    }

    @Test func closingTheWindowEndsItButAQuitWritesNothing() async throws {
        for quitting in [false, true] {
            let root = try onboardingFolder("codd-m5ow")
            defer { m3RemoveFolder(root) }
            let store = OnboardingStateStore(dataRoot: URL(fileURLWithPath: root, isDirectory: true))
            let host = FakeOnboardingHost(result: probeResult(root: root))
            let controller = OnboardingController(source: .live, reason: "test", start: .detect, host: host, stateStore: store)
            let presenter = OnboardingPresenter(controller: controller, host: host) { _ in }
            host.presenter = presenter
            await presenter.open()
            let window = try #require(presenter.window)
            #expect(window.title == "首次啟動設定")
            #expect(window.contentMinSize == OnboardingView.minimumContentSize)
            #expect(window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent)
            if quitting { presenter.appWillTerminate() }
            window.close()
            if quitting {
                #expect(!controller.hasEnded && store.load() == nil, "⌘Q in the middle writes nothing")
            } else {
                #expect(controller.hasEnded && host.ended.count == 1)
                #expect(store.load()?.steps["detect"] == .skipped)
            }
        }
    }
}

// MARK: - Reopen (D5)

@MainActor
private final class OnboardingCommands: NSObject, CoddCommands {
    var onboarding = 0
    func showSettings(_ sender: Any?) {}
    func showQuickSwitch(_ sender: Any?) {}
    func toggleSessionSidebar(_ sender: Any?) {}
    func selectSessionByNumber(_ sender: NSMenuItem) {}
    func selectNextSession(_ sender: Any?) {}
    func selectPreviousSession(_ sender: Any?) {}
    func allowCurrentSession(_ sender: Any?) {}
    func newShellTab(_ sender: Any?) {}
    func toggleBottomTerminal(_ sender: Any?) {}
    func showMainWindow(_ sender: Any?) {}
    func focusSidebarFilter(_ sender: Any?) {}
    func newSession(_ sender: Any?) {}
    func quitApp(_ sender: Any?) {}
    func togglePinCurrentSession(_ sender: Any?) {}
    func stopCurrentSession(_ sender: Any?) {}
    func toggleComposer(_ sender: Any?) {}
    func showOnboarding(_ sender: Any?) { onboarding += 1 }
}

@MainActor
@Suite("M5 onboarding reopen (D5)", .serialized)
struct M5OnboardingReopenTests {
    @Test func reopenRequestsGoToTheWizardWhileItIsOpen() async throws {
        let host = FakeOnboardingHost(result: probeResult(root: "/tmp/codd-never-read"))
        let controller = OnboardingController(source: .mock, reason: "test", start: .detect, host: host, stateStore: nil)
        let presenter = OnboardingPresenter(controller: controller, host: host) { _ in }
        host.presenter = presenter
        #expect(presenter.isOpen, "open while the first probe runs too")
        // Review correctness-3: before the window exists the caller shows the main window instead.
        #expect(!presenter.bringForward(reason: "dock"), "no window yet")
        await presenter.open()
        let window = try #require(presenter.window)
        #expect(window.isVisible)
        #expect(presenter.bringForward(reason: "dock"))
        #expect(presenter.bringForward(reason: "show-window"))
        controller.finish(.done)
        #expect(host.ended.count == 1 && !window.isVisible)
        #expect(!presenter.bringForward(reason: "status-item"), "an ended wizard leaves the main window to the caller")
    }

    @Test func theHelpMenuItemAndTheSettingsRowOpenIt() throws {
        let windows = NSApp.windowsMenu
        let help = NSApp.helpMenu
        defer {
            NSApp.windowsMenu = windows
            NSApp.helpMenu = help
        }
        let commands = OnboardingCommands()
        let menu = MainMenuBuilder.build(commands: commands)
        let top = try #require(menu.items.first { $0.title == "說明" })
        #expect(top.submenu === NSApp.helpMenu)
        let item = try #require(top.submenu?.items.first { $0.title == MainMenuBuilder.onboardingItemTitle })
        #expect(item.title == "首次啟動設定…" && item.keyEquivalent.isEmpty)
        #expect(item.action == #selector(CoddCommands.showOnboarding(_:)))
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
        #expect(commands.onboarding == 1)

        var env = SettingsCoordinator.Environment(preferences: .inMemory())
        let opened = Recorder<Int>()
        env.openOnboarding = { opened.append(1) }
        // The actions hold the coordinator weakly (the App keeps it alive), so the test keeps it too.
        let coordinator = SettingsCoordinator(environment: env)
        coordinator.makeActions().openOnboarding()
        #expect(opened.values == [1])
        withExtendedLifetime(coordinator) {}
    }
}

// MARK: - Notifications (D3)

@MainActor
@Suite("M5 onboarding notification request (D3)")
struct M5OnboardingNotificationTests {
    @Test func aRunThatMayNotNotifyIsSuppressedWithoutTheNotificationCenter() async {
        for (allowed, background) in [(false, false), (true, true)] {
            let log = NotificationLog()
            let notifier = SessionNotifier(store: MockSessionStore(shiftClock: false), allowedThisRun: allowed,
                                           rules: { CoddPreferences().notifications }, isFocused: { _ in false }, open: { _ in },
                                           decisions: log)
            #expect(await notifier.requestAuthorizationNow(background: background) == .suppressed)
            #expect(!notifier.usesNotificationCenter)
            #expect(log.entries.map(\.kind) == ["permission"] && log.entries.first?.suppressed == true)
        }
    }

    @Test func theDoneStepShowsTheAnswer() async throws {
        let host = FakeOnboardingHost(result: probeResult(root: "/tmp/codd-never-read"))
        let controller = OnboardingController(source: .live, reason: "test", start: .done, host: host, stateStore: nil)
        await controller.start()
        await controller.requestNotifications()
        #expect(host.asked == 1 && controller.notifications == .suppressed)
        #expect(controller.model?.done.notifications == .suppressed)
    }
}

// MARK: - Mock mode (§5)

@MainActor
@Suite("M5 onboarding mock mode")
struct M5OnboardingMockTests {
    @Test func theMockModelIsTheArtboardSamples() {
        for step in OnboardingStep.allCases {
            let controller = OnboardingController(source: .mock, reason: "mock-show", start: step, host: nil, stateStore: nil)
            #expect(controller.model == OnboardingSamples.step(step), "step \(step.rawValue)")
            #expect(controller.snapshotModel(for: step) == OnboardingSamples.step(step))
        }
        #expect(OnboardingController(source: .mock, reason: "mock-show", start: .importProjects, host: nil, stateStore: nil).model
            == OnboardingSamples.artboard())
        // Navigation keeps drawing the samples of the step it is on.
        let controller = OnboardingController(source: .mock, reason: "mock-show", start: .detect, host: nil, stateStore: nil)
        controller.next()
        #expect(controller.model?.flow.current == .importProjects)
        #expect(controller.model?.importStep == OnboardingSamples.importModel())
    }
}
