import AppKit
import CoddCore
import Darwin
import Foundation
import Testing
@testable import CODD
import CoddUI

/// M2 step I6: the ⌘N sheet's form (start modes, requests with the previewed id, the transcript
/// name, previews, destination, model titles, color keys), the project list (filtering, ordering,
/// suggestions, no transient projects), the resume picker over a fixture catalog in a temp Claude
/// directory (expiry, running CODD session and registry entry disabled), ⌘⏎ never reaching 允許
/// from the sheet or its list, and Settings › 啟動設定檔 (editor messages, 複製, 刪除 rules,
/// persistence through LaunchProfiles into profiles.json and the launcher). Temp folders only;
/// children are `cat`, never claude.

private func makeRoot(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    return CoddDataRoot(path: String(cString: created)).path
}

private func removeRoot(_ root: String) {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-KILL", "-f", root + "/"]
    try? pkill.run()
    pkill.waitUntilExit()
    try? FileManager.default.removeItem(atPath: root)
}

private func realpathOf(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
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

private func summary(_ id: String, title: String, source: TranscriptSummary.TitleSource = .custom, days: Double,
                     now: Date, branch: String? = "main", size: Int64 = 1024) -> TranscriptSummary {
    TranscriptSummary(id: id, path: "/x/\(id).jsonl", cwd: "/x", title: title, titleSource: source, gitBranch: branch,
                      lastActivity: now.addingTimeInterval(-days * 86_400), sizeBytes: size)
}

// MARK: - Form

@Suite("New session form (I6)")
struct NewSessionSheetFormTests {
    private static let id = UUID(uuidString: "7C1E9A04-5B6C-4D2E-9F10-2A3B4C5D6E7F")!

    private func form(_ path: String = "/w/app") -> NewSessionForm {
        var form = NewSessionForm()
        form.path = path
        form.sessionID = Self.id
        return form
    }

    @Test func startModesMapToRequestsWithThePreviewedID() {
        var form = form()
        #expect(form.request.claude.mode == .new)
        #expect(form.request.sessionID == Self.id)
        #expect(!form.request.claude.remoteControl)
        #expect(form.commandPreview() == "claude --session-id 7c1e9a04-…")
        #expect(form.commandPreview(abbreviated: false) == "claude --session-id 7c1e9a04-5b6c-4d2e-9f10-2a3b4c5d6e7f")

        form.setStart(.resume(nil))
        #expect(!form.isValid, "a resume needs a picked conversation")
        #expect(form.problem == "請先在清單裡選一段要接續的對話")
        #expect(form.request.claude.mode == .new)
        form.pick(summary("3f2a91c0-1b7e-4c55-a0d2-7e1f9b6c2a10", title: "refresh token 流程改寫", days: 2, now: Date()))
        #expect(form.isValid)
        #expect(form.request.claude.mode == .resume("3f2a91c0-1b7e-4c55-a0d2-7e1f9b6c2a10"))
        #expect(form.request.resumeTitle == "refresh token 流程改寫")
        #expect(form.request.sessionID == Self.id, "the CODD session still takes the previewed id")
        #expect(form.commandPreview() == "claude --resume 3f2a91c0-… -n \"refresh token 流程改寫\"")
        #expect(form.commandPreview(abbreviated: false) == "claude --resume 3f2a91c0-1b7e-4c55-a0d2-7e1f9b6c2a10 -n \"refresh token 流程改寫\"")

        form.setStart(.remoteControl)
        #expect(form.request.claude.remoteControl)
        #expect(form.request.claude.mode == .new)
        #expect(form.commandPreview() == "claude --session-id 7c1e9a04-… --remote-control")
        #expect(form.advancedSummary.rest == "env 0 個 · --remote-control 開")
        // A profile that already passes it gets no second flag.
        form.setProfile("claude-rc")
        #expect(form.commandPreview() == "claude --session-id 7c1e9a04-… --remote-control")
        #expect(form.request.claude.profileID == "claude-rc")
        #expect(NewSessionForm.Start(mode: "rc") == .remoteControl)
        #expect(NewSessionForm.Start(mode: "resume") == .resume(nil))
        #expect(NewSessionForm.Start(mode: "x") == nil)
    }

    @Test func theTranscriptTitleIsTheDefaultName() {
        var form = form()
        let now = Date()
        form.setStart(.resume(nil))
        form.pick(summary("a1", title: "第一段", days: 1, now: now))
        #expect(form.name == "第一段")
        #expect(form.nameFromTranscript)
        form.pick(summary("b2", title: "第二段", source: .ai, days: 1, now: now))
        #expect(form.name == "第二段", "another pick replaces a name that came from a transcript")
        form.pick(summary("c3", title: TranscriptCatalog.untitled, source: .none, days: 1, now: now))
        #expect(form.name.isEmpty, "（沒有標題）is never a name")
        #expect(form.request.resumeTitle == nil)
        form.setName("我自己的名字")
        form.pick(summary("a1", title: "第一段", days: 1, now: now))
        #expect(form.name == "我自己的名字", "a typed name stays")
        form.setName("")
        form.pick(summary("a1", title: "第一段", days: 1, now: now))
        #expect(form.name == "第一段")
        form.setStart(.new)
        #expect(form.name.isEmpty, "leaving resume drops the transcript's name")
    }

    @Test func previewFollowsModelPermissionAndProfiles() {
        var form = form()
        form.modelChoice = .opus
        form.permissionMode = "acceptEdits"
        form.setName("修正登入 API 401")
        #expect(form.commandPreview() == "claude --session-id 7c1e9a04-… --model opus --permission-mode acceptEdits -n \"修正登入 API 401\"")
        // claude-plan brings its mode; the seg shows it and `default` over it means no flag.
        form.setProfile("claude-plan")
        #expect(form.permissionMode == "plan")
        #expect(form.requestPermission == "plan")
        form.permissionMode = "default"
        #expect(form.requestPermission == "default")
        #expect(!form.commandPreview().contains("--permission-mode"))
        form.setProfile("claude-default")
        #expect(form.permissionMode == "default")
        #expect(form.requestPermission == nil)
        // A profile with extra flags and environment.
        var custom = LaunchProfile(id: "acct-2", name: "帳號 #2", kind: .claude, defaultModel: "sonnet", extraArguments: ["--verbose"],
                                   environment: ["CLAUDE_CONFIG_DIR": "/tmp/c2"])
        form.profiles.profiles.append(custom)
        form.setProfile("acct-2")
        form.modelChoice = .default
        #expect(form.commandPreview() == "claude --session-id 7c1e9a04-… --model sonnet -n \"修正登入 API 401\" --verbose")
        #expect(form.advancedSummary.profile == "帳號 #2")
        #expect(form.advancedSummary.rest == "env 1 個 · --remote-control 關")
        custom.extraArguments = []
        // Shell: the shell profile, no claude options.
        form.kind = .shell
        #expect(form.commandPreview() == "zsh -l")
        #expect(form.request.claude.profileID == nil)
    }

    @Test func modelTitlesShowTheDefaultModel() {
        var form = form()
        #expect(NewSessionForm.ModelChoice.allCases.map(form.modelTitle)
            == [NewSessionForm.followClaudeModelTitle, "opus", "sonnet", "haiku", "其他…"])
        // Claude Code's own `model` runs (no --model): the title stays, the tooltip names it.
        form.settingsModel = "opus"
        #expect(form.modelTitle(.default) == NewSessionForm.followClaudeModelTitle)
        #expect(form.defaultModelHint == "不傳 --model：Claude Code 目前設定的模型是 opus")
        #expect(form.requestModel == nil, "預設 passes no --model")
        form.profiles.profiles.append(LaunchProfile(id: "p", name: "p", kind: .claude, defaultModel: "haiku"))
        form.setProfile("p")
        #expect(form.modelTitle(.default) == "預設（啟動設定檔：haiku）", "the profile's own model runs first")
        form.modelChoice = .sonnet
        #expect(form.requestModel == "sonnet")
        form.modelChoice = .other
        form.customModel = "  "
        #expect(form.requestModel == nil)
        form.customModel = " claude-opus-5-5 "
        #expect(form.requestModel == "claude-opus-5-5")
    }

    @Test func destinationNamesGroupAndProject() {
        let known = [
            ProjectChoice(path: "/w/app", name: "orb-toolkit-backend", tag: .blue, isKnown: true, lastUsed: nil, groupID: "g",
                          groupName: "藍鵲 · 網站", live: 2),
            ProjectChoice(path: "/w/loose", name: "loose", tag: nil, isKnown: true, lastUsed: nil),
        ]
        #expect(form().destination(known: known) == NewSessionForm.Destination(tag: .blue, text: "藍鵲 · 網站 / orb-toolkit-backend"))
        #expect(form().destination(known: known)?.line == "建立後放在 ■ 藍鵲 · 網站 / orb-toolkit-backend")
        #expect(form("/w/loose/").destination(known: known)?.line == "建立後放在 未分類 / loose")
        var fresh = form("/w/new-folder")
        #expect(fresh.destination(known: known)?.line == "建立後放在 未分類 / new-folder")
        fresh.groupID = "g2"
        #expect(fresh.destination(known: known, groups: ["g2": (name: "個人 · Github", color: .green)])?.line
            == "建立後放在 ■ 個人 · Github / new-folder")
        #expect(form("").destination(known: known) == nil)
    }

    @Test func digitsPickColors() {
        #expect(NewSessionForm.color(forDigit: "1") == .some(.red))
        #expect(NewSessionForm.color(forDigit: "2") == .some(.blue))
        #expect(NewSessionForm.color(forDigit: "8") == .some(.cyan))
        #expect(NewSessionForm.color(forDigit: "0") == .some(nil))
        #expect(NewSessionForm.color(forDigit: "9") == nil)
        #expect(NewSessionForm.color(forDigit: "a") == nil)
        #expect(NewSessionForm.color(forDigit: "12") == nil)
    }

    @Test func commandStripColorsItsTokens() {
        #expect(CommandStripView.tokens("claude --resume 3f2a-… -n \"a b\" --name=\"-x y\"")
            == ["claude", "--resume", "3f2a-…", "-n", "\"a b\"", "--name=\"-x y\""])
        #expect(CommandStripView.tokens("claude -n \"say \\\"hi\\\" now\"") == ["claude", "-n", "\"say \\\"hi\\\" now\""])
    }
}

// MARK: - Project list

@MainActor
@Suite("New session project list (I6)")
struct ProjectDropdownTests {
    @Test func knownProjectsByActivityWithoutTransientOnes() throws {
        let store = MockSessionStore(shiftClock: false)
        let known = ProjectChoice.known(in: store)
        let backend = try #require(known.first { $0.name == "orb-toolkit-backend" })
        #expect(backend.groupName == "藍鵲 · 網站")
        #expect(backend.tag == .blue)
        #expect(backend.live > 0)
        #expect(backend.path.hasPrefix("/"), "mock ~ paths are expanded")
        // A transient project (an external's folder) is not CODD's: never offered.
        let line = try #require(store.groups.flatMap(\.projectIDs).compactMap { store.project($0) }.first { $0.name == "claude-line-test" })
        line.isTransient = true
        #expect(!ProjectChoice.known(in: store).contains { $0.name == "claude-line-test" })
        let model = ProjectDropdownModel.build(query: nil, known: ProjectChoice.known(in: store), recent: [], chosenPath: backend.path)
        #expect(model.recent.count == NewSessionForm.recentLimit)
        #expect(model.rows.last?.kind == .chooseFolder)
        #expect(model.rows.last?.detail == "⌘O")
        let dates = model.recent.compactMap { $0.choice?.lastUsed }
        #expect(dates == dates.sorted(by: >), "most recently active first")
    }

    @Test func typingFiltersAndRanksBothLists() {
        let now = Date()
        let known = [
            ProjectChoice(path: "/w/orb-toolkit-frontend", name: "orb-toolkit-frontend", tag: .blue, isKnown: true, lastUsed: now),
            ProjectChoice(path: "/w/orb-toolkit-backend", name: "orb-toolkit-backend", tag: .blue, isKnown: true,
                          lastUsed: now.addingTimeInterval(-60), live: 2),
            ProjectChoice(path: "/w/codd", name: "codd", tag: .purple, isKnown: true, lastUsed: now.addingTimeInterval(-30)),
        ]
        let recent = [RecentProject(path: "/w/orb-toolkit-backend", lastUsed: now), RecentProject(path: "/u/Github/backend-api", lastUsed: now),
                      RecentProject(path: "/u/Github/backend-api/", lastUsed: now), RecentProject(path: "/u/Github/zzz", lastUsed: now)]
        let all = ProjectDropdownModel.build(query: "", known: known, recent: recent, chosenPath: "/w/orb-toolkit-backend/")
        #expect(all.recent.compactMap(\.choice?.name) == ["orb-toolkit-frontend", "codd", "orb-toolkit-backend"])
        #expect(all.recent.first { $0.isChosen }?.choice?.name == "orb-toolkit-backend", "✓ on the chosen folder")
        #expect(all.recent.first { $0.isChosen }?.detail == "2 live")
        #expect(all.suggested.compactMap(\.choice?.path) == ["/u/Github/backend-api", "/u/Github/zzz"], "known and repeated folders dropped")
        let filtered = ProjectDropdownModel.build(query: "back", known: known, recent: recent, chosenPath: nil)
        #expect(filtered.recent.compactMap(\.choice?.name) == ["orb-toolkit-backend"])
        #expect(filtered.recent.first?.spans.isEmpty == false, "matched characters are marked")
        #expect(filtered.suggested.compactMap(\.choice?.name) == ["backend-api"])
        let none = ProjectDropdownModel.build(query: "qqqxxx", known: known, recent: recent, chosenPath: nil)
        #expect(none.recent.isEmpty && none.suggested.isEmpty)
        #expect(none.rows.count == 1, "選擇資料夾… stays")
        #expect(ProjectDropdownModel.parentText(NSHomeDirectory() + "/Github/x") == "~/Github")
        #expect(ProjectDropdownModel.parentText(NSHomeDirectory() + "/Project/north/orb-toolkit-suite/x") == "…/orb-toolkit-suite")
    }
}

// MARK: - Resume picker (D18)

/// A temp data root, Claude directory (settings.json, transcripts) and work folder, plus a store.
@MainActor
private final class PickerFixture {
    let path: String
    let root: CoddDataRoot
    let claude: ClaudeDirectory
    let work: String

    init() throws {
        path = try makeRoot("codd-i6")
        root = CoddDataRoot(path: path + "/r")
        claude = ClaudeDirectory(path: path + "/claude")
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: claude.path + "/projects", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: path + "/work", withIntermediateDirectories: true)
        work = realpathOf(path + "/work")
        try #"{"cleanupPeriodDays": 30, "model": "sonnet"}"#.write(toFile: claude.path + "/settings.json", atomically: true, encoding: .utf8)
    }

    /// `<claudeDir>/projects/<folder>/<id>.jsonl` with lines carrying `cwd`, its mtime `days` ago.
    func transcript(_ id: String, title: String, branch: String, days: Double) throws {
        let folder = claude.path + "/projects/" + TranscriptCatalog.folderName(for: work)
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"user","sessionId":"\#(id)","cwd":"\#(work)","gitBranch":"\#(branch)","timestamp":"2026-10-01T00:00:00.000Z","uuid":"u1","message":{"role":"user","content":"請幫忙"}}"#,
            #"{"type":"custom-title","customTitle":"\#(title)","sessionId":"\#(id)"}"#,
        ]
        let file = folder + "/" + id + ".jsonl"
        try (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-days * 86_400)], ofItemAtPath: file)
    }

    func fakeClaude() throws -> String {
        let file = path + "/fake-claude"
        try "#!/bin/sh\nexec /bin/cat\n".write(toFile: file, atomically: true, encoding: .utf8)
        chmod(file, 0o755)
        return file
    }

    func store() throws -> HolderSessionStore {
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"],
                                      claudePathOverride: try fakeClaude())
        launcher.coddHookPath = "/usr/bin/true"
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: claude, hooks: nil) { _ in }
        store.processAncestors = { _ in [1] }
        return store
    }

    deinit { removeRoot(path) }
}

@MainActor
@Suite("Resume picker (D18)", .serialized)
struct ResumePickerTests {
    @Test func rowsCarryExpiryAndRunningConversationsAreDisabled() {
        let now = Date()
        let items = [
            summary("a", title: "refresh token 流程改寫", days: 2, now: now, branch: "fix/refresh", size: 1_258_291),
            summary("b", title: "auth middleware 單元測試", days: 5, now: now, size: 655_360),
            summary("c", title: "CI 設定", days: 26.1, now: now, branch: nil, size: 300),
            summary("d", title: "快過期", days: 30.5, now: now),
        ]
        let rows = ResumePicker.rows(items, inUse: ["a"], cleanupPeriodDays: nil, now: now)
        #expect(rows.map(\.disabled) == [true, false, false, false])
        #expect(rows.map(\.expiresInDays) == [nil, nil, 4, 0])
        #expect(rows[2].expiryText == "! resume 4 天後過期")
        #expect(rows[3].expiryText == "! resume 即將過期")
        #expect(rows[0].detailText == "⎇ fix/refresh · 2d")
        #expect(rows[2].detailText == "26d")
        #expect(rows[0].sizeText == "1.2MB" && rows[1].sizeText == "640KB" && rows[2].sizeText == "300B")
        #expect(ResumePicker.firstEnabled(rows)?.id == "b")
        #expect(ResumePicker.rows(items, inUse: [], cleanupPeriodDays: 60, now: now).allSatisfy { $0.expiresInDays == nil })
        #expect(ResumePicker.headText(project: "orb-toolkit-backend", count: 4) == "orb-toolkit-backend · 4")
        let dump = ResumePicker.dump(rows, selected: "b")
        #expect(dump.count == 4)
        #expect(dump[1]["selected"] as? Bool == true && dump[0]["disabled"] as? Bool == true)
        #expect(dump[2]["expiresInDays"] as? Int == 4)
    }

    @Test func pickerOverAFixtureCatalogDisablesRunningSessionsAndRegistryEntries() async throws {
        let f = try PickerFixture()
        let a = UUID().uuidString.lowercased(), b = UUID().uuidString.lowercased()
        let c = UUID().uuidString.lowercased(), d = UUID().uuidString.lowercased()
        try f.transcript(a, title: "refresh token 流程改寫", branch: "fix/refresh", days: 2)
        try f.transcript(b, title: "auth middleware 單元測試", branch: "main", days: 5)
        try f.transcript(c, title: "登入頁錯誤訊息 i18n", branch: "feat/i18n", days: 12)
        try f.transcript(d, title: "CI 設定", branch: "main", days: 26.1)
        let store = try f.store()
        await store.start()
        let services = AppServices(store: store)
        await services.loadClaudeSettings()
        #expect(services.claudeSettings == ClaudeUserSettingsSummary(cleanupPeriodDays: 30, model: "sonnet"))
        // A running CODD session continues c; an external claude (registry) uses b.
        var request = NewSessionRequest(cwd: f.work, kind: .claude)
        request.claude.mode = .resume(c)
        let running = try #require(store.createSession(request))
        store.applyRegistry([ClaudeRegistryEntry(pid: 99_999, sessionId: b, cwd: f.work, startedAt: Date(), version: "2.1.300",
                                                 kind: "interactive", entrypoint: "cli", name: nil, status: "busy", waitingFor: nil,
                                                 statusTimestampMilliseconds: nil)])
        await eventually("both conversations in use") { services.inUseClaudeSessionIds.isSuperset(of: [b, c]) }

        var form = NewSessionForm()
        form.path = f.work
        form.start = .resume(nil)
        form.profiles = store.profiles.document
        form.settingsModel = services.claudeSettings.model
        let sources = NewSessionSources.real(holders: store, services: services, create: { _ in nil }, openProfileSettings: {})
        let sheet = NewSessionSheet(form: form, sources: sources, profiles: store.profiles, onClose: {})
        sheet.reloadPicker()
        await eventually("the picker's rows") { !sheet.pickerDump.isEmpty }
        let rows = sheet.pickerDump
        #expect(rows.map { $0["id"] as? String } == [a, b, c, d], "newest first")
        #expect(rows.map { $0["disabled"] as? Bool } == [false, true, true, false])
        #expect(rows.map { $0["expiresInDays"] as? Int } == [nil, nil, nil, 4])
        #expect(rows.map { $0["branch"] as? String } == ["fix/refresh", "main", "feat/i18n", "main"])
        #expect(rows.first?["selected"] as? Bool == true, "the first enabled row is preselected")
        #expect(sheet.form.resumeID == a)
        #expect(sheet.form.name == "refresh token 流程改寫")
        #expect(sheet.form.modelTitle(.default) == NewSessionForm.followClaudeModelTitle)
        #expect(sheet.form.defaultModelHint == "不傳 --model：Claude Code 目前設定的模型是 sonnet", "the settings model reached the sheet")
        let dump = sheet.dumpObject
        #expect(dump["start"] as? String == "resume")
        #expect(dump["command"] as? String == "claude --resume \(a.prefix(8))-… -n \"refresh token 流程改寫\"")
        #expect(dump["copyCommand"] as? String == "claude --resume \(a) -n \"refresh token 流程改寫\"")
        #expect(dump["destination"] as? String == "建立後放在 未分類 / work")
        // A running row cannot be picked; the next enabled one can.
        sheet.picker.moveSelection(by: 1)
        #expect(sheet.form.resumeID == d, "↓ skips the two running rows")
        sheet.close()
        // `stop` signals the holder: wait until it is spawned (under load the picker can be faster).
        await eventually("spawned") { store.runtimes[running]?.holderPid != nil }
        store.stop([running])
        await eventually("stopped") { !(store.session(running)?.state.isLive ?? true) }
        store.shutdown()
    }

    @Test func aFolderWithoutTranscriptsSaysSo() async throws {
        let f = try PickerFixture()
        let store = try f.store()
        await store.start()
        let services = AppServices(store: store)
        var form = NewSessionForm()
        form.path = f.work
        form.start = .resume(nil)
        let sheet = NewSessionSheet(form: form, sources: .real(holders: store, services: services, create: { _ in nil }, openProfileSettings: {}),
                                    profiles: store.profiles, onClose: {})
        sheet.reloadPicker()
        await eventually("the empty list") { sheet.pickerContent == .empty }
        #expect(sheet.dumpObject["picker"] as? String == "empty")
        #expect(!sheet.form.isValid)
        sheet.create()
        #expect(sheet.dumpObject["error"] as? String == "▲ 請先在清單裡選一段要接續的對話")
        sheet.close()
        store.shutdown()
    }
}

// MARK: - Keys

@MainActor
private final class AllowCounter: NSObject, CoddCommands {
    var allows = 0
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
    func toggleComposer(_ sender: Any?) {}
}

@MainActor
@Suite("New session keys (I6)", .serialized)
struct NewSessionKeyTests {
    private func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
    }

    private func mockSheet(created: Recorder<NewSessionRequest>, closed: Recorder<Bool> = Recorder()) -> (NewSessionSheet, NSWindow) {
        let store = MockSessionStore(shiftClock: false)
        var sources = NewSessionSources.mock(store: store, openProfileSettings: {})
        sources.create = { request in created.append(request); return "還不能開" }
        var form = NewSessionForm()
        form.path = PathFormat.expandTilde("~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend")
        let sheet = NewSessionSheet(form: form, sources: sources, profiles: LaunchProfiles.inMemory(), onClose: { closed.append(true) })
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        return (sheet, parent)
    }

    @Test func commandReturnInTheSheetAndItsListNeverReachesAllow() throws {
        let created = Recorder<NewSessionRequest>()
        let closed = Recorder<Bool>()
        let (sheet, parent) = mockSheet(created: created, closed: closed)
        sheet.present(on: parent)
        let window = try #require(sheet.window)
        let commands = AllowCounter()
        let menu = MainMenuBuilder.build(commands: commands)
        let event = try #require(key("\r", keyCode: 0x24, modifiers: .command, window: window))
        // AppKit's order: the key window first, the main menu only when nothing claimed it.
        let claimed = window.performKeyEquivalent(with: event)
        #expect(claimed)
        #expect(!(!claimed && menu.performKeyEquivalent(with: event)))
        #expect(commands.allows == 0, "⌘⏎ in the sheet never runs 允許")
        #expect(created.values.count == 1, "⌘⏎ pressed 建立")
        #expect(created.values.first?.cwd.hasSuffix("/orb-toolkit-backend") == true)

        sheet.openDropdownList()
        #expect(sheet.isDropdownOpen)
        #expect(sheet.dropdown.parent === window, "the list is a child window of the sheet")
        let inList = try #require(key("\r", keyCode: 0x24, modifiers: .command, window: sheet.dropdown))
        #expect(sheet.dropdown.performKeyEquivalent(with: inList))
        #expect(commands.allows == 0, "⌘⏎ sent to the list never runs 允許")
        #expect(created.values.count == 2)
        #expect(sheet.dumpObject["error"] as? String == "▲ 還不能開", "a refusal stays in the sheet")

        // esc: the list closes first, the sheet second.
        let esc = try #require(key("\u{1B}", keyCode: 0x35, modifiers: [], window: window))
        #expect(window.performKeyEquivalent(with: esc))
        #expect(!sheet.isDropdownOpen)
        #expect(sheet.dropdown.parent == nil)
        #expect(closed.values.isEmpty, "the first esc only closed the list")
        #expect(window.performKeyEquivalent(with: esc))
        #expect(closed.values == [true], "the second esc closed the sheet")
        // Outside the sheet the same chord is the menu's.
        #expect(menu.performKeyEquivalent(with: try #require(key("\r", keyCode: 0x24, modifiers: .command, window: parent))))
        #expect(commands.allows == 1)
        parent.close()
    }

    @Test func theListWalksWithArrowsAndPicksWithReturn() throws {
        let (sheet, parent) = mockSheet(created: Recorder())
        sheet.present(on: parent)
        _ = sheet.combobox.onCommand?(#selector(NSResponder.moveDown(_:)))
        #expect(sheet.isDropdownOpen, "↓ opens the list")
        let chosen = sheet.dropdown.list.highlighted
        #expect(sheet.dropdownModel.rows[chosen].isChosen, "it opens on the chosen project")
        _ = sheet.combobox.onCommand?(#selector(NSResponder.moveDown(_:)))
        let next = sheet.dropdownModel.rows[sheet.dropdown.list.highlighted]
        _ = sheet.combobox.onCommand?(#selector(NSResponder.insertNewline(_:)))
        #expect(!sheet.isDropdownOpen)
        #expect(sheet.form.resolvedPath == next.choice.map { HolderSessionStore.standardize($0.path) })
        #expect(sheet.combobox.text == next.choice?.name)
        // Typing filters.
        sheet.combobox.text = "invoice"
        sheet.combobox.onTextChange?("invoice")
        #expect(sheet.isDropdownOpen)
        #expect(sheet.dropdownModel.recent.first?.choice?.name == "Northstar invoice system")
        _ = sheet.combobox.onCommand?(#selector(NSResponder.cancelOperation(_:)))
        #expect(!sheet.isDropdownOpen)
        #expect(sheet.combobox.text == next.choice?.name, "esc restores the chosen name")
        // 1–8 pick colors when no text field has focus.
        let window = try #require(sheet.window)
        window.makeFirstResponder(nil)
        window.keyDown(with: try #require(key("3", keyCode: 0x14, modifiers: [], window: window)))
        #expect(sheet.form.tag == .green)
        sheet.close()
        parent.close()
    }
}

// MARK: - Settings › 啟動設定檔

@MainActor
@Suite("Launch profile settings (I6)", .serialized)
struct ProfileSettingsTests {
    @Test func editorMessagesAreOnePerIssue() {
        #expect(ProfileEditorForm.message(.emptyName) == "名稱不能空白")
        #expect(ProfileEditorForm.message(.duplicateName) == "已經有同名的設定檔")
        #expect(ProfileEditorForm.message(.reservedArgument("--resume=x")) == "--resume 由 CODD 管理，不能放在額外參數")
        #expect(ProfileEditorForm.message(.reservedArgument("-n")) == "-n 由 CODD 管理，不能放在額外參數")
        #expect(ProfileEditorForm.message(.invalidModel("-x")) == "模型「-x」不正確：要是一個字，不能以 - 開頭")
        #expect(ProfileEditorForm.message(.invalidPermissionMode("a b")) == "權限模式「a b」不正確")
        #expect(ProfileEditorForm.message(.blockedEnvironment("PATH")) == "PATH 由 CODD 或系統設定，不能放在環境變數")
        #expect(ProfileEditorForm.message(.invalidEnvironmentLine("oops")) == "看不懂這一行環境變數：oops（要寫成 KEY=VALUE）")
        #expect(ProfileEditorForm.message(.unbalancedQuotes) == "額外參數的引號沒有成對")
        #expect(ProfileEditorForm.message(.lastClaudeProfile) == "至少要保留一個 Claude 設定檔")
        #expect(ProfileEditorIssue.relativeShellPath("bin/zsh").message == "Shell 路徑要是絕對路徑（bin/zsh）")
    }

    @Test func editorValidatesWhatItBuilds() {
        let document = LaunchProfileDocument.seeded
        var form = ProfileEditorForm(profile: nil, document: document)
        #expect(form.name == "新設定檔")
        #expect(form.build(in: document).issues.isEmpty)
        form.name = "claude-plan"
        form.arguments = "--verbose --session-id x \"open"
        form.environment = "PATH=/evil\nCLAUDE_CONFIG_DIR=/tmp/c2\nno equals"
        let issues = form.build(in: document).issues
        #expect(issues.contains(.profile(.duplicateName)))
        #expect(issues.contains(.profile(.unbalancedQuotes)))
        #expect(issues.contains(.profile(.invalidEnvironmentLine("no equals"))))
        form.arguments = "--verbose --session-id x"
        form.environment = "PATH=/evil\nCLAUDE_CONFIG_DIR=/tmp/c2"
        let second = form.build(in: document).issues
        #expect(second.contains(.profile(.reservedArgument("--session-id"))))
        #expect(second.contains(.profile(.blockedEnvironment("PATH"))))
        #expect(second.map(\.message).contains("--session-id 由 CODD 管理，不能放在額外參數"))
        form.name = "帳號 #2"
        form.arguments = "--verbose \"--add-dir=/a b\""
        form.environment = "export CLAUDE_CONFIG_DIR=\"/Users/me/.claude-2\""
        form.model = " opus "
        form.permissionMode = "plan"
        let built = form.build(in: document)
        #expect(built.issues.isEmpty)
        #expect(built.profile.id == "profile", "no ASCII letters in the name: profile")
        #expect(built.profile.extraArguments == ["--verbose", "--add-dir=/a b"])
        #expect(built.profile.environment == ["CLAUDE_CONFIG_DIR": "/Users/me/.claude-2"])
        #expect(built.profile.defaultModel == "opus")
        #expect(built.profile.defaultPermissionMode == .plan)
        #expect(form.preview(in: document) == "claude --session-id 7c1e9a04-… --model opus --permission-mode plan --verbose \"--add-dir=/a b\"")
        #expect(ProfileEditorForm.newID(for: "Acct 2 (work)", in: document) == "acct-2-work")
        #expect(ProfileEditorForm.newID(for: "claude-plan", in: document) == "claude-plan-2")
        // The only claude profile cannot turn into a shell one; a shell needs an absolute path.
        let single = LaunchProfileDocument(profiles: [LaunchProfile.builtIn[0], LaunchProfile.builtIn[3]], defaultProfileId: "claude-default")
        var only = ProfileEditorForm(profile: single.profiles[0], document: single)
        only.kind = .shell
        only.shellPath = "bin/zsh"
        let shellIssues = only.build(in: single).issues
        #expect(shellIssues.contains(.profile(.lastClaudeProfile)))
        #expect(shellIssues.contains(.relativeShellPath("bin/zsh")))
    }

    @Test func rowsShowCommandsMetaAndTheDefaultPreview() {
        let model = ProfilesSettingsModel.build(document: .seeded, settingsModel: "opus", accountLabel: "跟隨全域", readOnly: false)
        #expect(model.rows.map(\.name) == ["claude-default", "claude-plan", "claude-rc", "zsh"])
        #expect(model.rows.map(\.command) == ["claude", "claude --permission-mode plan", "claude --remote-control", "zsh"])
        #expect(model.rows.map(\.isDefault) == [true, false, false, false])
        #expect(model.rows.map(\.glyph) == ["◆", "◆", "◆", "$"])
        #expect(model.rows[0].meta == "cwd 跟隨專案 · 帳號 跟隨全域 · 模型 預設（Claude Code：opus）")
        #expect(model.rows[3].meta == "cwd 跟隨專案 · 帳號 — · 模型 —")
        #expect(model.defaultName == "claude-default")
        // The launch passes no --model for a profile without one (Claude's own `model` runs), so
        // the preview shows none either (user feedback 2026-10-19 「不要選擇模型」).
        #expect(model.preview == "claude --session-id 7c1e9a04-… --permission-mode acceptEdits -n \"修正登入 API 401\"")
        let plain = ProfilesSettingsModel.build(document: .seeded, settingsModel: nil, accountLabel: "跟隨全域", readOnly: true)
        #expect(plain.rows[0].model == "預設（跟隨 Claude Code 設定）" && plain.rows[0].model == NewSessionForm.followClaudeModelTitle)
        #expect(plain.readOnly)
        #expect(plain.preview == "claude --session-id 7c1e9a04-… --permission-mode acceptEdits -n \"修正登入 API 401\"")
        // A profile that names a model on purpose: that one, in the column and as --model.
        var document = LaunchProfileDocument.seeded
        document.profiles[0].defaultModel = "haiku"
        let own = ProfilesSettingsModel.build(document: document, settingsModel: "opus", accountLabel: "跟隨全域", readOnly: false)
        #expect(own.rows[0].model == "haiku")
        #expect(own.preview == "claude --session-id 7c1e9a04-… --model haiku --permission-mode acceptEdits -n \"修正登入 API 401\"")
    }

    @Test func aNewerProfilesFileIsShownReadOnly() async throws {
        let path = try makeRoot("codd-i6ro")
        defer { removeRoot(path) }
        let file = URL(fileURLWithPath: path + "/profiles.json")
        try #"{"version": 99, "defaultProfileId": "x", "profiles": []}"#.write(to: file, atomically: true, encoding: .utf8)
        let profiles = LaunchProfiles(fileURL: file) { _ in }
        await profiles.load()
        #expect(profiles.isReadOnly)
        let settings = SettingsWindowController(profiles: profiles)
        await eventually("the read-only rows") { settings.profilesPage.model.readOnly && !settings.profilesPage.rowViews.isEmpty }
        #expect(settings.profilesPage.rowViews.allSatisfy { !$0.editButton.isEnabled && !$0.deleteButton.isEnabled && !$0.copyButton.isEnabled })
        let editor = ProfileEditorSheet(form: ProfileEditorForm(profile: nil, document: profiles.document), profiles: profiles, onClose: {})
        #expect(!editor.save(), "nothing is written over a newer file")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("\"version\": 99"))
    }

    @Test func editsPersistThroughLaunchProfilesIntoTheFileAndTheLauncher() async throws {
        let f = try PickerFixture()
        let store = try f.store()
        await store.start()
        let profiles = store.profiles
        // The editor sheet saves a new profile and makes it the default.
        var form = ProfileEditorForm(profile: nil, document: profiles.document)
        form.name = "acct-x"
        form.arguments = "--verbose"
        form.environment = "CLAUDE_CONFIG_DIR=/tmp/c2"
        form.makeDefault = true
        let editor = ProfileEditorSheet(form: form, profiles: profiles, onClose: {})
        #expect(editor.save())
        #expect(profiles.document.defaultProfileId == "acct-x")
        #expect(store.launcher?.defaultProfileID == "acct-x")
        #expect(store.launcher?.profiles.contains { $0.id == "acct-x" && $0.extraArguments == ["--verbose"] } == true)
        // A refused save keeps the sheet and names the problem.
        var bad = ProfileEditorForm(profile: nil, document: profiles.document)
        bad.name = "acct-x"
        let refused = ProfileEditorSheet(form: bad, profiles: profiles, onClose: {})
        #expect(!refused.save())
        #expect(refused.shownIssues == [.profile(.duplicateName)])
        // 複製 names the copy `<name> 複本`.
        let settings = SettingsWindowController(profiles: profiles, claudeSettings: { ClaudeUserSettingsSummary(model: "opus") })
        settings.profilesPage.duplicate("acct-x")
        #expect(profiles.document.profile(id: "acct-x-2")?.name == "acct-x 複本")
        settings.profilesPage.duplicate("acct-x")
        #expect(profiles.document.profile(id: "acct-x-3")?.name == "acct-x 複本 2")
        await eventually("the rows follow") { settings.profilesPage.rowViews.count == 7 }
        #expect(settings.profilesPage.rowViews.first { $0.row.id == "acct-x" }?.row.isDefault == true)
        // 刪除: the default falls back to the first claude profile; the last claude one stays.
        #expect(profiles.delete("acct-x") == nil)
        #expect(profiles.document.defaultProfileId == "claude-default")
        for id in ["acct-x-2", "acct-x-3", "claude-plan", "claude-rc"] { #expect(profiles.delete(id) == nil) }
        #expect(profiles.delete("claude-default") == .lastClaudeProfile)
        #expect(profiles.document.profiles.map(\.id) == ["claude-default", "zsh"])
        profiles.flush()
        let reread = try LaunchProfileStore(fileURL: URL(fileURLWithPath: f.root.path + "/profiles.json")).load()
        #expect(reread == profiles.document)
        #expect(store.launcher?.profiles.map(\.id) == ["claude-default", "zsh"])
        store.shutdown()
    }
}

// MARK: - M2 review round 1

@MainActor
@Suite("M2 review fixes: project list, launch profiles", .serialized)
struct M2ReviewNewSessionFixTests {
    /// Review spec-fidelity-1: 5 recents and 3 suggestions (SPEC §7.5), and `+ 選擇資料夾… ⌘O`
    /// pinned under the rows however many a query lists.
    @Test func theChooseFolderRowStaysVisibleUnderAnyNumberOfRows() throws {
        #expect(NewSessionForm.recentLimit == 5 && NewSessionForm.suggestionLimit == 3)
        let now = Date()
        let known = (0..<30).map { n in
            ProjectChoice(path: "/w/project-\(n)", name: "project-\(n)", tag: .blue, isKnown: true, lastUsed: now.addingTimeInterval(-Double(n)))
        }
        let recent = (0..<12).map { RecentProject(path: "/u/Github/suggested-\($0)", lastUsed: now) }
        let panel = ProjectDropdownPanel()
        defer { panel.close() }
        let screen = CGRect(x: 0, y: 0, width: 2000, height: 2000)
        let plain = ProjectDropdownModel.build(query: nil, known: known, recent: recent, chosenPath: nil)
        #expect(plain.recent.count == 5 && plain.suggested.count == 3)
        panel.list.show(plain, highlighted: 0)
        panel.place(under: CGRect(x: 100, y: 1000, width: 348, height: 40), screen: screen)
        #expect(panel.frame.height <= ProjectDropdownPanel.maxHeight)
        #expect(panel.list.contentHeight + ProjectDropdownListView.footerHeight + 2 <= ProjectDropdownPanel.maxHeight, "all of it fits")
        let filtered = ProjectDropdownModel.build(query: "project", known: known, recent: recent, chosenPath: nil)
        #expect(filtered.recent.count == 20)
        panel.list.show(filtered, highlighted: filtered.rows.count - 1)
        panel.place(under: CGRect(x: 100, y: 1000, width: 348, height: 40), screen: screen)
        panel.contentView?.layoutSubtreeIfNeeded()
        let footer = panel.list.footer
        #expect(panel.frame.height == ProjectDropdownPanel.maxHeight)
        #expect(footer.superview === panel.contentView, "outside the scroll view")
        #expect(footer.frame.height == ProjectDropdownListView.footerHeight)
        #expect(footer.frame.minY >= 0 && footer.frame.maxY <= panel.contentView?.bounds.height ?? 0)
        #expect(footer.highlighted == filtered.rows.count - 1, "the highlight reaches the footer")
        var picked: [Int] = []
        panel.list.onPick = { picked.append($0) }
        footer.onPick?(filtered.rows.count - 1)
        #expect(picked == [filtered.rows.count - 1])
    }

    /// Review correctness-4: an edit before profiles.json is read never saves the built-ins over
    /// it, and a file that could not be read is never replaced.
    @Test func profileEditsWaitForTheFileAndNeverReplaceAnUnreadableOne() async throws {
        let path = try makeRoot("codd-fix-profiles")
        defer { removeRoot(path) }
        let file = URL(fileURLWithPath: path + "/profiles.json")
        let custom = #"{"version":1,"defaultProfileId":"mine","profiles":[{"id":"mine","name":"我的","kind":"claude","extraArguments":["--verbose"]}]}"#
        try custom.write(to: file, atomically: true, encoding: .utf8)
        let profiles = LaunchProfiles(fileURL: file) { _ in }
        var problems: [String] = []
        profiles.onProblem = { message, _ in problems.append(message) }
        #expect(!profiles.canEdit)
        profiles.setDefault("claude-plan")
        #expect(profiles.upsert(LaunchProfile(id: "y", name: "y", kind: .claude)).isEmpty)
        #expect(profiles.duplicate("claude-default") == nil)
        profiles.flush()
        #expect(try String(contentsOf: file, encoding: .utf8) == custom, "nothing saved before the read")
        #expect(problems.allSatisfy { $0 == LaunchProfiles.notLoadedMessage } && problems.count == 3)
        await profiles.load()
        #expect(profiles.canEdit && profiles.document.defaultProfileId == "mine")

        // Unreadable (no permission): shown as the built-ins, read-only.
        let locked = URL(fileURLWithPath: path + "/locked.json")
        try custom.write(to: locked, atomically: true, encoding: .utf8)
        chmod(locked.path, 0o000)
        defer { chmod(locked.path, 0o600) }
        let unreadable = LaunchProfiles(fileURL: locked) { _ in }
        var lockedProblems: [String] = []
        unreadable.onProblem = { message, _ in lockedProblems.append(message) }
        await unreadable.load()
        #expect(unreadable.isReadOnly && !unreadable.canEdit)
        #expect(unreadable.editRefusal == LaunchProfiles.unreadableMessage)
        unreadable.setDefault("claude-plan")
        unreadable.flush()
        chmod(locked.path, 0o600)
        #expect(try String(contentsOf: locked, encoding: .utf8) == custom)
        #expect(lockedProblems == [LaunchProfiles.unreadableMessage, LaunchProfiles.unreadableMessage])
    }

    /// Review e2e-4: a hand-edited default profile LaunchBuilder would refuse is reported and
    /// skipped: new claude sessions run the built-in default instead of all failing.
    @Test func anUnlaunchableDefaultProfileIsReportedAndSkipped() async throws {
        let path = try makeRoot("codd-fix-badprofile")
        defer { removeRoot(path) }
        let file = URL(fileURLWithPath: path + "/profiles.json")
        try #"{"version":1,"defaultProfileId":"bad","profiles":[{"id":"bad","name":"bad","kind":"claude","extraArguments":["--settings","{}"]}]}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let profiles = LaunchProfiles(fileURL: file) { _ in }
        var problems: [String] = []
        profiles.onProblem = { message, _ in problems.append(message) }
        await profiles.load()
        #expect(profiles.document.defaultProfileId == "bad", "kept for the editor")
        #expect(profiles.document.unlaunchableProfiles.map(\.id) == ["bad"])
        #expect(profiles.document.claudeProfile(id: nil).id == LaunchProfileDocument.builtInDefaultId)
        #expect(profiles.document.claudeProfile(id: "bad").id == LaunchProfileDocument.builtInDefaultId)
        #expect(problems.count == 1 && problems[0].contains("「bad」") && problems[0].contains("claude-default"))
        var form = NewSessionForm()
        form.profiles = profiles.document
        form.path = "/tmp"
        #expect(!form.commandPreview().contains("--settings"), "the preview shows what runs")
    }
}
