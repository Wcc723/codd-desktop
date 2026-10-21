import AppKit
import CoddClaudeSettings
import CoddCore
import CoddDialogsUI
import CoddHooks
import CoddPreferences
import Darwin
import Foundation
import Testing
@testable import CODD

/// M3 I2 flows on temp files and fakes only: the installer (D10) on a settings file made by the C9
/// fixture script, the `-codd-hooks-apply` guard, dialog A and C state machines with the scripted
/// cswap, the ephemeral login shell (D24) and the auto-switch runner with a manual clock (D13, D37).
/// Nothing here runs the real cswap or a claude, or touches `~`.

/// The repository (fixture scripts).
private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Runs a fixture script; returns its stdout.
@discardableResult
private func runScript(_ path: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [repoRoot.appendingPathComponent(path).path] + arguments
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(path) failed")
    return String(decoding: data, as: UTF8.self)
}

/// The handlers of one tool in a settings file (`hook-tap`, `osascript`), as JSON text per event.
private func handlers(_ url: URL, containing marker: String) throws -> [String: String] {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    let hooks = object?["hooks"] as? [String: Any] ?? [:]
    var found: [String: String] = [:]
    for (event, groups) in hooks {
        for group in groups as? [[String: Any]] ?? [] {
            let data = try JSONSerialization.data(withJSONObject: group, options: [.sortedKeys])
            let text = String(decoding: data, as: UTF8.self)
            if text.contains(marker) { found[event, default: ""] += text }
        }
    }
    return found
}

private func statusLineCommand(_ url: URL) throws -> String? {
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    return (object?["statusLine"] as? [String: Any])?["command"] as? String
}

@MainActor
@Suite("Installer (I2, D10)", .serialized)
struct InstallerFlowTests {
    @Test func previewApplyBackupIdempotentUninstallAndRefusal() async throws {
        let folder = try m3TempFolder("codd-i2-inst")
        defer { m3RemoveFolder(folder) }
        let claudeDir = folder + "/home/.claude"
        try FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        try runScript("scripts/m3-fixtures/make-claude-settings.sh", [claudeDir, "--legacy"])
        let settings = URL(fileURLWithPath: claudeDir + "/settings.json")
        let hookTapBefore = try handlers(settings, containing: "hook-tap")
        let osascriptBefore = try handlers(settings, containing: "osascript")
        #expect(hookTapBefore.count == 12 && osascriptBefore.count == 2)

        let service = ClaudeSettingsService(settingsURL: settings, dataRoot: URL(fileURLWithPath: folder + "/data"), log: { _ in })
        await service.refreshInspection()
        guard case .loaded(let inspection, true) = service.inspection else {
            Issue.record("inspection \(service.inspection)")
            return
        }
        #expect(inspection.legacyHookEvents.count == 10)
        guard case .coddWeb(let inner?) = inspection.statusLine else {
            Issue.record("statusLine \(inspection.statusLine)")
            return
        }
        #expect(inner == "printf 'USER-SL-%s' ok")

        // Preview (dialog B's model), then apply.
        let dialog = HookDiffDialog(service: service, action: .update)
        let model = await dialog.makeModel()
        let plan = try #require(dialog.plan)
        #expect(plan.changes && model.canConfirm)
        #expect(model.settingsPath == ClaudeSettingsService.questionPath(HolderSessionStore.abbreviate(settings.path)))
        #expect(model.settingsPath.hasSuffix("/.claude/settings.json") && model.settingsPath.count <= 44)
        #expect(ClaudeSettingsService.questionPath("~/.claude/settings.json") == "~/.claude/settings.json")
        #expect(model.backupPath.hasSuffix(plan.backupName))
        #expect(model.foreignKept.contains("hook-tap ×"))
        #expect(model.added == plan.addedLines && model.removed == plan.removedLines)
        #expect(model.chips.contains { $0.text == "− PreToolUse" && $0.kind == .removed })
        #expect(!model.lines.contains { $0.text.contains("hook-tap") && $0.kind != .elided }, "foreign handlers are elided")
        let toasts = Recorder<String>()
        dialog.onToast = { toasts.append($0) }
        await dialog.apply(plan)
        #expect(dialog.applied)
        let backups = ClaudeSettingsInstaller.backups(of: settings)
        #expect(backups.count == 1)
        #expect(toasts.values == ["已更新 \(HolderSessionStore.abbreviate(settings.path)) · 備份 \(backups[0].url.lastPathComponent)"])
        service.flushIndex()
        let index = ClaudeSettingsService.readIndex(service.backupsIndexURL)
        #expect(index.count == 1)
        #expect(index.first?["name"] as? String == backups[0].url.lastPathComponent)
        #expect(index.first?["reason"] as? String == "更新 hooks 與 statusline")
        let mode = try FileManager.default.attributesOfItem(atPath: service.backupsIndexURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Other tools' handlers are untouched; the status line is CODD Desktop's, chaining the user's.
        #expect(try handlers(settings, containing: "hook-tap") == hookTapBefore)
        #expect(try handlers(settings, containing: "osascript") == osascriptBefore)
        #expect(try handlers(settings, containing: "status-writer.js").isEmpty)
        let wrapper = try #require(try statusLineCommand(settings))
        let parsed = try #require(DesktopStatusLine.parse(wrapper))
        #expect(parsed.chain == "printf 'USER-SL-%s' ok")
        #expect(parsed.dataRoot == folder + "/data")
        guard case .loaded(let after, _) = service.inspection, case .coddDesktop(_, true) = after.statusLine else {
            Issue.record("inspection after apply \(service.inspection)")
            return
        }
        #expect(service.dumpObject["applied"] is [String: Any])

        // A second update changes nothing; uninstall gives the user's own status line back.
        let second = await service.plan(.update)
        #expect(second.successValue?.changes == false)
        let uninstall = try #require(await service.plan(.uninstall).successValue)
        #expect(await service.apply(uninstall).successValue != nil)
        #expect(try statusLineCommand(settings) == "printf 'USER-SL-%s' ok")
        #expect(ClaudeSettingsInstaller.backups(of: settings).count == 2)

        // Changed after the preview: refused, nothing written.
        let stale = try #require(await service.plan(.update).successValue)
        var text = try String(contentsOf: settings, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"alwaysThinkingEnabled\"", with: "\"alwaysThinkingEnabled2\"")
        try text.write(to: settings, atomically: false, encoding: .utf8)
        let refusedDialog = HookDiffDialog(service: service, action: .update)
        _ = await refusedDialog.makeModel()
        await refusedDialog.apply(stale)
        #expect(!refusedDialog.applied)
        #expect(refusedDialog.model?.error == "settings.json 在預覽後被改過，請重新預覽")
        #expect(refusedDialog.model?.canApply == false)
        #expect(try String(contentsOf: settings, encoding: .utf8) == text)
        #expect(ClaudeSettingsInstaller.backups(of: settings).count == 2)
    }

    @Test func invalidFileShowsTheReasonAndNothingToApply() async throws {
        let folder = try m3TempFolder("codd-i2-bad")
        defer { m3RemoveFolder(folder) }
        let settings = URL(fileURLWithPath: folder + "/settings.json")
        try Data("{\n  \"hooks\": {,\n}\n".utf8).write(to: settings)
        let service = ClaudeSettingsService(settingsURL: settings, dataRoot: URL(fileURLWithPath: folder + "/data"), log: { _ in })
        await service.refreshInspection()
        guard case .failed(let reason) = service.inspection else {
            Issue.record("expected a failed inspection")
            return
        }
        #expect(reason.contains("不是有效的 JSON（第 2 行"))
        let dialog = HookDiffDialog(service: service, action: .update)
        let model = await dialog.makeModel()
        #expect(!model.canConfirm && model.error?.contains("不是有效的 JSON") == true)
        #expect(dialog.plan == nil)
    }

    /// `-codd-hooks-apply`: path logic only, never a write into the (fake) real `~/.claude`.
    @Test func debugApplyGuard() throws {
        let folder = try m3TempFolder("codd-i2-guard")
        defer { m3RemoveFolder(folder) }
        let home = folder + "/home"
        let manager = FileManager.default
        try manager.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: URL(fileURLWithPath: home + "/.claude/settings.json"))
        try manager.createDirectory(atPath: folder + "/elsewhere", withIntermediateDirectories: true)
        let ownTarget = URL(fileURLWithPath: folder + "/elsewhere/settings.json")

        #expect(!ClaudeSettingsService.isDebugApplyAllowed(target: ownTarget, claudeDirGiven: false, settingsGiven: false, home: home).allowed)
        #expect(ClaudeSettingsService.isDebugApplyAllowed(target: ownTarget, claudeDirGiven: true, settingsGiven: false, home: home).allowed)
        #expect(ClaudeSettingsService.isDebugApplyAllowed(target: ownTarget, claudeDirGiven: false, settingsGiven: true, home: home).allowed)
        let real = URL(fileURLWithPath: home + "/.claude/settings.json")
        #expect(!ClaudeSettingsService.isDebugApplyAllowed(target: real, claudeDirGiven: true, settingsGiven: true, home: home).allowed)
        // A directory symlink into ~/.claude, and a file symlink to its settings.json.
        try manager.createSymbolicLink(atPath: folder + "/linkdir", withDestinationPath: home + "/.claude")
        let viaDirectory = URL(fileURLWithPath: folder + "/linkdir/settings.json")
        #expect(!ClaudeSettingsService.isDebugApplyAllowed(target: viaDirectory, claudeDirGiven: true, settingsGiven: true, home: home).allowed)
        try manager.createSymbolicLink(atPath: folder + "/elsewhere/link.json", withDestinationPath: home + "/.claude/settings.json")
        let viaFile = URL(fileURLWithPath: folder + "/elsewhere/link.json")
        #expect(!ClaudeSettingsService.isDebugApplyAllowed(target: viaFile, claudeDirGiven: true, settingsGiven: true, home: home).allowed)
        // A file that does not exist yet inside it.
        let missing = URL(fileURLWithPath: folder + "/linkdir/new/settings.json")
        #expect(!ClaudeSettingsService.isDebugApplyAllowed(target: missing, claudeDirGiven: true, settingsGiven: true, home: home).allowed)
        #expect(try String(contentsOf: real, encoding: .utf8) == "{}\n")
        #expect(ClaudeSettingsService.action(named: "remove-legacy") == .removeLegacy)
        #expect(ClaudeSettingsService.action(named: "disable-notifications") == .disableDuplicateNotifications)
        #expect(ClaudeSettingsService.action(named: "restore") == nil)
    }
}

@MainActor
@Suite("Dialog A (I2, D5)", .serialized)
struct SwitchDialogFlowTests {
    @Test func progressThenSuccessWithToast() async throws {
        var script = FakeCswapRunner.Script()
        script.lockFailures = 1
        script.switchDelay = .milliseconds(150)
        let fixture = try AccountStoreFixture("codd-i2-a", script: script)
        let store = fixture.store!
        await store.start()
        let model = try #require(SwitchDialogData.model(target: "2", accounts: store, pinnedTitles: ["現場示範"], autoSwitchOn: false,
                                                        calendar: StatusPageDataTests.taipei))
        #expect(model.from.name == "#3 工作" && model.to.name == "#2 藍鵲")
        #expect(model.from.chips == [.active] && model.from.resetsAt != nil && model.to.resetsAt == nil)
        #expect(model.from.reset.hasPrefix("1w 重置 ") && model.cswapVersion == "cswap 0.26.0")
        let flow = SwitchDialogFlow(target: "2", store: store, model: model)
        let toasts = Recorder<String>()
        flow.toast = { text, undo in toasts.append(text + (undo == nil ? "" : " +UNDO")) }
        let paused = Recorder<Bool>()
        flow.onPauseAutoSwitch = { paused.append(true) }
        await flow.run(pauseAutoSwitch: true)
        #expect(flow.attemptsShown == [1, 2])
        guard case .switched(_, "2", _)? = flow.outcome else {
            Issue.record("outcome \(String(describing: flow.outcome))")
            return
        }
        #expect(await flow.result == flow.outcome)
        #expect(store.activeAccountID == "2")
        #expect(paused.values == [true])
        #expect(toasts.values.count == 1 && toasts.values[0].hasPrefix("已切換到 #2 藍鵲 · ") && toasts.values[0].hasSuffix(" +UNDO"))
    }

    @Test func failureStaysOpenWithTheRedactedMessage() async throws {
        var script = FakeCswapRunner.Script()
        script.failSwitch = true
        let fixture = try AccountStoreFixture("codd-i2-af", script: script)
        let store = fixture.store!
        await store.start()
        let model = try #require(SwitchDialogData.model(target: "2", accounts: store, pinnedTitles: [], autoSwitchOn: true))
        let flow = SwitchDialogFlow(target: "2", store: store, model: model)
        await flow.run(pauseAutoSwitch: false)
        #expect(flow.outcome == nil, "a failed switch keeps the dialog for another try")
        let error = try #require(flow.model.error)
        m3ExpectNoAccountLeak(error, "dialog A error")
        #expect(flow.model.progress == nil && flow.model.canConfirm)
        fixture.runner.setScript { $0.failSwitch = false }
        await flow.run(pauseAutoSwitch: false)
        #expect(store.activeAccountID == "2")
        #expect(flow.outcome != nil)
    }

    @Test func confirmationOnlyWhileTheSettingIsOn() async throws {
        let fixture = try AccountStoreFixture("codd-i2-ac")
        let store = fixture.store!
        await store.start()
        let preferences = PreferencesService.inMemory()
        await preferences.load()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let controller = SwitchDialogController(preferences: preferences, window: { window })
        #expect(!controller.wantsConfirmation(for: "2", in: store))
        preferences.update { $0.accounts.confirmBeforeSwitch = true }
        #expect(controller.wantsConfirmation(for: "2", in: store))
        #expect(!controller.wantsConfirmation(for: "3", in: store), "the active account needs no switch")
        let flow = try #require(controller.makeFlow("2", in: store))
        flow.onPauseAutoSwitch?()
        #expect(preferences.preferences.accounts.autoSwitch.enabled == false)
        #expect(controller.current == nil)
    }
}

@MainActor
@Suite("Dialog C and ephemeral shells (I2, D24)", .serialized)
final class AddAccountFlowTests {
    private let rootPath: String

    init() throws {
        rootPath = try m3TempFolder("codd-i2-c")
    }

    deinit {
        m3RemoveFolder(rootPath)
    }

    /// A real store whose shells are `/bin/sh` reading one typed line into `typed.txt`, then `cat`.
    private func holders() async throws -> HolderSessionStore {
        let root = CoddDataRoot(path: rootPath + "/data")
        let executable = try #require(HolderBinary.install(root: root) { _ in }, "CODD.app/Contents/MacOS/codd-holder is missing")
        let argv = ["/bin/sh", "-c", "read line; printf '%s' \"$line\" > '\(rootPath)/typed.txt'; exec /bin/cat"]
        let launcher = HolderLauncher(holderExecutable: executable, root: root, shellArgvOverride: argv)
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: ClaudeDirectory(path: rootPath + "/claude")) { _ in }
        await store.start()
        return store
    }

    private func environment(_ fixture: AccountStoreFixture, _ holders: HolderSessionStore, toasts: Recorder<String>) -> AddAccountFlow.Environment {
        var env = AddAccountFlow.Environment(accounts: fixture.store, holders: holders, loginTyping: "echo LOGIN-TYPED\r", addTokenTyping: nil)
        env.home = rootPath
        env.toast = { toasts.append($0) }
        env.watchInterval = .milliseconds(50)
        env.now = { [unowned fixture] in fixture.clock }
        env.log = { _ in }
        return env
    }

    @Test func addCapturesTheLoginSwitchesBackAndDiscardsTheShell() async throws {
        let fixture = try AccountStoreFixture("codd-i2-cs")
        await fixture.store.start()
        let holders = try await holders()
        defer { holders.shutdown() }
        let toasts = Recorder<String>()
        let flow = AddAccountFlow(env: environment(fixture, holders, toasts: toasts))
        #expect(flow.model.slots.first == 4 && flow.model.previousActive == "#3 工作")
        await flow.start()

        flow.openLoginTerminal()
        let shell = try #require(flow.loginShell)
        #expect(holders.isEphemeral(shell))
        let directory = try #require(holders.runtime(shell)?.directory)
        #expect(FileManager.default.fileExists(atPath: directory + "/" + HolderSessionStore.ephemeralMarkerName))
        #expect(holders.session(shell)?.title == "加入帳號")
        #expect(!holders.currentLayout().sessions.contains { LayoutMapping.id($0.id) == shell }, "never in layout.json")
        // The login command is typed into the shell once it is up.
        await m3Eventually("typed", timeout: .seconds(10)) {
            (try? String(contentsOfFile: self.rootPath + "/typed.txt", encoding: .utf8)) == "echo LOGIN-TYPED"
        }

        // `claude /login` as a new account: step 1 is done once the identity changes.
        try fixture.state.setLoginIdentity(email: "new@example.com", organization: "org-4")
        await m3Eventually("step 1") { flow.model.step1Done != nil }
        await flow.capture()
        #expect(flow.model.detected == DetectedLogin.newAccount(plan: "MAX 5x"))

        // cswap's alias rule first: `工作室` never reaches cswap.
        await flow.add(alias: "工作室", slot: 4)
        #expect(flow.model.error == CswapAlias.hint)
        #expect(!fixture.runner.calls.contains { $0.first == "add" })

        await flow.add(alias: "Studio", slot: 4)
        let calls = fixture.runner.calls.filter { ["add", "switch"].contains($0.first ?? "") }
        #expect(calls == [["add", "--slot", "4", "--alias", "studio"], ["switch", "3", "--json"]])
        #expect(toasts.values == ["已加入 #4 studio · 已切回 #3 工作"])
        #expect(flow.finished && flow.ending == "added")
        #expect(fixture.store.activeAccountID == "3")
        #expect(fixture.store.account("4") != nil)
        #expect(!holders.isEphemeral(shell) && holders.session(shell) == nil)
        await m3Eventually("directory deleted", timeout: .seconds(10)) { !FileManager.default.fileExists(atPath: directory) }
        m3ExpectNoAccountLeak(fixture.exposedText, "add-account logs")
    }

    @Test func cancelAfterTheLoginChangedSwitchesBack() async throws {
        let fixture = try AccountStoreFixture("codd-i2-cc")
        await fixture.store.start()
        let holders = try await holders()
        defer { holders.shutdown() }
        let toasts = Recorder<String>()
        let flow = AddAccountFlow(env: environment(fixture, holders, toasts: toasts))
        await flow.start()
        flow.openLoginTerminal()
        let shell = try #require(flow.loginShell)
        try fixture.state.setLoginIdentity(email: "other@example.com", organization: "org-9")
        await flow.cancel()
        #expect(fixture.runner.calls.contains(["switch", "3", "--json"]))
        #expect(toasts.values == ["已取消加入 · 已切回 #3 工作"])
        #expect(flow.ending == "cancelled" && holders.session(shell) == nil)

        // Cancel without a login change: no switch.
        let quiet = AddAccountFlow(env: environment(fixture, holders, toasts: toasts))
        await quiet.start()
        let switches = fixture.runner.calls.filter { $0.first == "switch" }.count
        await quiet.cancel()
        #expect(fixture.runner.calls.filter { $0.first == "switch" }.count == switches)
        #expect(toasts.values.count == 1)
    }

    /// A crash mid-flow: the next launch ends the holder and deletes the directory, and the
    /// session never comes back (not adopted into the tree).
    @Test func leftoverEphemeralIsCleanedAtLaunch() async throws {
        let first = try await holders()
        let id = try #require(first.createEphemeralShell(title: "加入帳號", cwd: rootPath, typing: nil))
        await m3Eventually("running", timeout: .seconds(10)) { first.session(id)?.state == .shell }
        let directory = try #require(first.runtime(id)?.directory)
        let holderPid = try #require(first.runtime(id)?.holderPid)
        first.shutdown()  // the app went away; the holder keeps running

        // A marker directory whose holder never started.
        let orphan = rootPath + "/data/sessions/" + LayoutMapping.id(UUID())
        try FileManager.default.createDirectory(atPath: orphan, withIntermediateDirectories: true)
        try Data("1\n".utf8).write(to: URL(fileURLWithPath: orphan + "/" + HolderSessionStore.ephemeralMarkerName))

        let second = try await holders()
        defer { second.shutdown() }
        #expect(second.session(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory))
        #expect(!FileManager.default.fileExists(atPath: orphan))
        await m3Eventually("holder ended", timeout: .seconds(10)) { kill(holderPid, 0) != 0 }
    }
}

@MainActor
@Suite("Auto-switch (I2, D13, D37)", .serialized)
struct AutoSwitchRunnerTests {
    private func runner(_ fixture: AccountStoreFixture, log: NotificationLog, preferences: PreferencesService) -> AutoSwitchRunner {
        let notifier = AppNotifier(dispatcher: nil, allowedThisRun: false, rules: { preferences.preferences.notifications },
                                   decisions: log, now: { [unowned fixture] in fixture.clock })
        let runner = AutoSwitchRunner(accounts: fixture.store, preferences: preferences, notifier: notifier, tick: .seconds(3600),
                                      now: { [unowned fixture] in fixture.clock }, log: { _ in })
        runner.scan = { CswapBackgroundTools() }
        return runner
    }

    private func enabledPreferences() async -> PreferencesService {
        let preferences = PreferencesService.inMemory()
        await preferences.load()
        preferences.update {
            $0.accounts.autoSwitch.enabled = true
            // Quiet hours never matter here (the notifications are suppressed anyway).
            $0.notifications.quietHours.enabled = false
        }
        return preferences
    }

    private func waitIdle(_ runner: AutoSwitchRunner, _ fixture: AccountStoreFixture) async {
        await m3Eventually("switch settled") { !fixture.store.isSwitching && !runner.isSwitchInFlight }
    }

    @Test func switchesAtTheThresholdThenCoolsDownAcrossAReload() async throws {
        let fixture = try AccountStoreFixture("codd-i2-auto", quota: true)
        await fixture.store.start()
        let preferences = await enabledPreferences()
        let log = NotificationLog()
        let runner = runner(fixture, log: log, preferences: preferences)
        let toasts = Recorder<String>()
        runner.toast = { text, undo in toasts.append(text + (undo == nil ? "" : " +UNDO")) }
        runner.start()
        #expect(runner.lastDecision == "above-threshold")

        // #3 (active) reports 1 % left this week: the R7-first eligible account is #2.
        fixture.store.ingest(fixture.report(key: "default", five: 10, fiveReset: fixture.clock.addingTimeInterval(3600),
                                            week: 99, weekReset: fixture.state.weeklyReset(3)))
        runner.evaluate()
        await waitIdle(runner, fixture)
        #expect(fixture.runner.calls.filter { $0.first == "switch" } == [["switch", "2", "--json"]])
        #expect(fixture.store.activeAccountID == "2")
        #expect(runner.lastSwitchResult == "switched #3 -> #2")
        #expect(fixture.store.lastAutoSwitchAt == fixture.clock)
        #expect(toasts.values == ["↻ 已自動切換到 #2 藍鵲 · #3 工作 1w 剩 1% +UNDO"])
        #expect(log.entries.map(\.title) == ["↻ 已自動切換到 #2 藍鵲"])
        #expect(log.entries.allSatisfy { $0.suppressed }, "-codd-notifications NO style: recorded, not posted")

        // #2 is low too a minute later: the cooldown holds (no second switch).
        fixture.clock = fixture.clock.addingTimeInterval(60)
        fixture.store.ingest(fixture.report(key: "default", five: 10, fiveReset: fixture.clock.addingTimeInterval(3600),
                                            week: 99, weekReset: fixture.state.weeklyReset(2)))
        runner.evaluate()
        #expect(runner.lastDecision == "cooling-down")
        #expect(fixture.runner.calls.filter { $0.first == "switch" }.count == 1)

        // A relaunch inside the cooldown: quota.json carries it (D37).
        fixture.store.flush()
        let reloaded = CswapAccountStore(configuration: fixture.store.configuration, runner: fixture.runner,
                                         now: { [unowned fixture] in fixture.clock }, log: { _ in })
        await reloaded.start()
        #expect(reloaded.lastAutoSwitchAt == fixture.store.lastAutoSwitchAt)
        let notifier = AppNotifier(dispatcher: nil, allowedThisRun: false, rules: { preferences.preferences.notifications },
                                   decisions: NotificationLog(), now: { [unowned fixture] in fixture.clock })
        let relaunched = AutoSwitchRunner(accounts: reloaded, preferences: preferences, notifier: notifier, tick: .seconds(3600),
                                          now: { [unowned fixture] in fixture.clock }, log: { _ in })
        relaunched.scan = { CswapBackgroundTools() }
        relaunched.start()
        fixture.clock = fixture.clock.addingTimeInterval(60)
        relaunched.evaluate()
        #expect(relaunched.lastDecision == "cooling-down", "the relaunch keeps the 300 s cooldown")
        #expect(fixture.runner.calls.filter { $0.first == "switch" }.count == 1)
        relaunched.stop()
        reloaded.shutdown()
    }

    @Test func aFailedSwitchIsRetriedOnTheNextTick() async throws {
        var script = FakeCswapRunner.Script()
        script.failSwitch = true
        let fixture = try AccountStoreFixture("codd-i2-autof", script: script)
        await fixture.store.start()
        let preferences = await enabledPreferences()
        let runner = runner(fixture, log: NotificationLog(), preferences: preferences)
        runner.start()
        fixture.store.ingest(fixture.report(key: "default", week: 99, weekReset: fixture.state.weeklyReset(3)))
        runner.evaluate()
        await m3Eventually("failed") { runner.lastSwitchResult == "failed #3 -> #2" }
        #expect(fixture.store.lastAutoSwitchAt == nil, "a failed switch does not start the cooldown")
        fixture.runner.setScript { $0.failSwitch = false }
        fixture.clock = fixture.clock.addingTimeInterval(30)
        runner.evaluate()
        await waitIdle(runner, fixture)
        #expect(fixture.store.activeAccountID == "2")
        #expect(fixture.runner.calls.filter { $0.first == "switch" }.count == 2)
    }

    @Test func noEligibleAccountIsNotifiedOncePerEpisode() async throws {
        let fixture = try AccountStoreFixture("codd-i2-autonone")
        await fixture.store.start()
        let preferences = await enabledPreferences()
        let log = NotificationLog()
        let runner = runner(fixture, log: log, preferences: preferences)
        runner.start()
        // Every account below 2 % this week (cswap-<n> reports go to that account directly).
        for (key, n) in [("cswap-1", 1), ("cswap-2", 2), ("default", 3)] {
            fixture.store.ingest(fixture.report(key: key, five: 10, fiveReset: fixture.clock.addingTimeInterval(3600),
                                                week: 99.5, weekReset: fixture.state.weeklyReset(n)))
        }
        runner.evaluate()
        runner.evaluate()
        #expect(log.entries.map(\.title) == ["所有帳號都低於 2%"])
        #expect(log.entries.map(\.kind) == ["account-none-eligible"])
        #expect(log.entries.allSatisfy { $0.suppressed })
        #expect(fixture.runner.calls.allSatisfy { $0.first != "switch" })
        // The condition clears (#3 has room again), then comes back: notified again.
        fixture.clock = fixture.clock.addingTimeInterval(5)
        fixture.store.ingest(fixture.report(key: "default", five: 10, fiveReset: fixture.clock.addingTimeInterval(3600),
                                            week: 50, weekReset: fixture.state.weeklyReset(3)))
        runner.evaluate()
        #expect(runner.lastDecision == "above-threshold")
        fixture.clock = fixture.clock.addingTimeInterval(5)
        fixture.store.ingest(fixture.report(key: "default", five: 10, fiveReset: fixture.clock.addingTimeInterval(3600),
                                            week: 99.5, weekReset: fixture.state.weeklyReset(3)))
        runner.evaluate()
        #expect(log.entries.count == 2)
    }

    @Test func offDoesNothing() async throws {
        let fixture = try AccountStoreFixture("codd-i2-autooff")
        await fixture.store.start()
        let preferences = PreferencesService.inMemory()
        await preferences.load()
        let runner = runner(fixture, log: NotificationLog(), preferences: preferences)
        runner.start()
        fixture.store.ingest(fixture.report(key: "default", week: 99, weekReset: fixture.state.weeklyReset(3)))
        runner.evaluate()
        #expect(runner.lastDecision == "disabled")
        #expect(fixture.runner.calls.allSatisfy { $0.first != "switch" })
        #expect(runner.dumpObject["enabled"] as? Bool == false)
    }
}
