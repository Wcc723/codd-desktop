import AppKit
import Carbon.HIToolbox
import CoddClaudeSettings
import CoddCore
import CoddDialogsUI
import CoddPreferences
import CoddSettingsUI
import Darwin
import Foundation
import Testing
@testable import CODD

/// M3 I3, the parts with side effects kept inside the test: the global hotkey on the test combo
/// `⌃⌥⌘ F12` (never ⌥Space), the login item through fakes (the system's login items are never
/// touched), cswap aliases through the scripted runner, the externals' display on a real store, and
/// dialog D's `全部停止並結束` / `結束 · session 繼續執行` on real `codd-holder` processes running
/// `/bin/sh` (never claude).

// MARK: - Global hotkey (D22)

@MainActor
@Suite("Global hotkey (I3, D22)", .serialized)
struct M3HotkeyServiceTests {
    private static let combo = KeyCombo(string: "ctrl+option+cmd+f12")!

    private func general(_ combo: KeyCombo, enabled: Bool = true) -> CoddPreferences.General {
        var general = CoddPreferences.defaults.general
        general.hotkey = CoddPreferences.Hotkey(combo, enabled: enabled)
        return general
    }

    @Test func registersTheTestComboExclusivelyAndReportsAConflict() {
        let combo = Self.combo
        let service = HotkeyService(isAllowed: true)
        defer { service.hotkey.unregister() }
        service.apply(general(combo))
        #expect(service.registered == combo)
        #expect(service.error == nil)
        #expect(service.dumpObject["combo"] as? String == combo.spec)

        // A combo another holder has (here a second exclusive registration) is refused with the
        // D22 text; the first keeps it.
        let other = HotkeyService(isAllowed: true)
        defer { other.hotkey.unregister() }
        other.apply(general(combo))
        #expect(other.registered == nil)
        #expect(other.error == "⌃⌥⌘ F12 已被其他 App 使用，請改用別的組合鍵")
        #expect(other.tryCombo(combo) == "⌃⌥⌘ F12 已被其他 App 使用，請改用別的組合鍵", "the recorder keeps the previous combo")
        #expect(service.registered == combo)

        // The recorder releases the combo while it listens, then the preferences' combo is back.
        service.suspend()
        #expect(service.registered == nil && service.hotkey.registered == nil)
        service.resume(general(combo))
        #expect(service.registered == combo)

        // Switched off: released.
        service.apply(general(combo, enabled: false))
        #expect(service.registered == nil)
        #expect(service.hotkey.registered == nil)
    }

    @Test func aTestRootRegistersNothingAndModifierlessCombosAreRefused() {
        // D22: another data root without `-codd-global-hotkey YES` never takes a system-wide combo,
        // even with the default ⌥Space stored.
        let service = HotkeyService(isAllowed: HotkeyService.isAllowed(standardRoot: false, debugFlag: nil))
        service.apply(CoddPreferences.defaults.general)
        #expect(service.registered == nil)
        #expect(service.hotkey.registered == nil)
        #expect(service.error == nil)
        #expect(service.tryCombo(Self.combo) == nil, "accepted and stored, not registered")
        #expect(service.hotkey.registered == nil)
        let bare = KeyCombo(keyCode: UInt32(kVK_F12), modifiers: 0)
        #expect(service.tryCombo(bare) == GlobalHotkeyError.needsModifier(bare).message)
        // `-codd-hotkey` replaces the stored combo for the run (e2e: the test combo).
        let overridden = HotkeyService(isAllowed: false, override: Self.combo)
        #expect(overridden.wantedCombo(CoddPreferences.defaults.general) == Self.combo)
        #expect(overridden.wantedCombo(general(.optionSpace, enabled: false)) == nil, "off stays off")
    }
}

// MARK: - Login item (D21)

/// A login item service that never reaches the system.
@MainActor
private final class FakeLoginItemService: LoginItemService {
    var state: LoginItemState = .notRegistered
    var failure: (any Error)?
    private(set) var registers = 0
    private(set) var unregisters = 0

    func register() throws {
        registers += 1
        if let failure { throw failure }
        state = .enabled
    }

    func unregister() throws {
        unregisters += 1
        state = .notRegistered
    }
}

private struct RefusedError: LocalizedError {
    var errorDescription: String? { "Operation not permitted" }
}

@MainActor
@Suite("Login item (I3, D21)")
struct M3LoginItemTests {
    @Test func aTestDataRootNeverCallsTheSystem() {
        #expect(AppDelegate.loginItemService(standardRoot: false) is DisabledLoginItemService)
        let disabled = DisabledLoginItemService()
        let preferences = PreferencesService.inMemory()
        let controller = LoginItemController(service: disabled, preferences: preferences)
        controller.apply(preferences.preferences.general)
        preferences.update { $0.general.launchAtLogin = true }
        controller.apply(preferences.preferences.general)
        preferences.update { $0.general.launchAtLogin = false }
        controller.apply(preferences.preferences.general)
        #expect(disabled.calls == 0)
        #expect(controller.statusText == "測試資料根目錄不會註冊登入項目")
        #expect(controller.dumpObject["real"] as? Bool == false)
        #expect(controller.dumpObject["registered"] as? Bool == false)
    }

    @Test func onlyAChangeRegistersAndAFailureTurnsTheToggleBackOff() {
        let fake = FakeLoginItemService()
        let preferences = PreferencesService.inMemory(assignments: ["general.launchAtLogin=YES"])
        let controller = LoginItemController(service: fake, preferences: preferences)
        // Launch: the stored value is only remembered (a plain start never alters system state).
        controller.apply(preferences.preferences.general)
        #expect(fake.registers == 0 && fake.unregisters == 0)
        preferences.update { $0.general.launchAtLogin = false }
        controller.apply(preferences.preferences.general)
        #expect(fake.unregisters == 0, "nothing was registered")
        preferences.update { $0.general.launchAtLogin = true }
        controller.apply(preferences.preferences.general)
        #expect(fake.registers == 1)
        #expect(controller.registered)
        #expect(controller.statusText == nil)
        controller.apply(preferences.preferences.general)
        #expect(fake.registers == 1, "the same value again does nothing")
        preferences.update { $0.general.launchAtLogin = false }
        controller.apply(preferences.preferences.general)
        #expect(fake.unregisters == 1)

        // Ad-hoc signing refuses: the toggle returns to OFF and the row says why.
        fake.failure = RefusedError()
        preferences.update { $0.general.launchAtLogin = true }
        controller.apply(preferences.preferences.general)
        #expect(fake.registers == 2)
        #expect(!preferences.preferences.general.launchAtLogin)
        #expect(controller.statusText == "無法註冊登入項目：Operation not permitted")
        controller.apply(preferences.preferences.general)
        #expect(fake.registers == 2, "OFF was already applied")

        // Registered but not allowed yet.
        fake.state = .requiresApproval
        controller.refreshStatus()
        #expect(controller.statusText == "請到 系統設定 › 一般 › 登入項目 允許")
    }
}

// MARK: - Aliases (D34) and 重新讀取 (D1)

@MainActor
@Suite("Settings › 帳號 aliases (I3, D34)", .serialized)
struct M3AliasTests {
    @Test func cjkAliasesNeverReachCswapAndValidOnesAreNormalized() async throws {
        let fixture = try AccountStoreFixture("codd-i3-alias")
        await fixture.store.start()
        var env = SettingsCoordinator.Environment(preferences: .inMemory())
        env.cswap = fixture.store
        env.accounts = fixture.store
        let coordinator = SettingsCoordinator(environment: env)

        coordinator.setAlias("3", "工作")
        #expect(coordinator.aliasProblem == "別名只能用英文小寫、數字與 - _ .（cswap 規則）")
        #expect(coordinator.model.info.cswap.warning == coordinator.aliasProblem, "shown inline under the aliases")
        #expect(!fixture.runner.calls.contains { $0.first == "alias" }, "an invalid alias never runs cswap")

        coordinator.setAlias("3", "  Studio ")
        #expect(coordinator.aliasProblem == nil)
        await m3Eventually("cswap alias ran") { fixture.runner.calls.contains(["alias", "3", "studio"]) }
        coordinator.setAlias("2", nil)
        await m3Eventually("cswap alias --unset ran") { fixture.runner.calls.contains(["alias", "2", "--unset"]) }
        #expect(fixture.runner.calls.filter { $0.first == "alias" }.count == 2)
        m3ExpectNoAccountLeak(fixture.exposedText, "alias logs")
    }
}

// MARK: - Externals (Settings › 工作階段)

@MainActor
@Suite("External sessions display (I3)", .serialized)
final class M3ExternalDisplayTests {
    private let path: String

    init() throws { path = try m3TempFolder("codd-i3-ext") }
    deinit { m3RemoveFolder(path) }

    private func entry(pid: Int, sessionId: String, entrypoint: String, kind: String = "interactive") -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: pid, sessionId: sessionId, cwd: path, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            version: "2.1.300", kind: kind, entrypoint: entrypoint, name: "外部 claude", status: "waiting",
                            waitingFor: "permission")
    }

    @Test func hiddenRemovesExternalsAndTheFilterHidesSDKAndDesktop() async throws {
        #expect(AppDelegate.externalDisplay(CoddPreferences.defaults.sessions).hidden == false)
        var sessions = CoddPreferences.defaults.sessions
        sessions.externalDisplay = .hidden
        #expect(AppDelegate.externalDisplay(sessions).hidden)
        sessions.externalDisplay = .detected
        #expect(!AppDelegate.externalDisplay(sessions).hidden, "偵測到的 is not built: shown like 依專案")
        sessions.hideSDKAndDesktop = false
        #expect(AppDelegate.externalDisplay(sessions).filter == ExternalSessionFilter(hideSDK: false, hideDesktop: false))

        try FileManager.default.createDirectory(atPath: path + "/claude/projects", withIntermediateDirectories: true)
        let store = HolderSessionStore(root: CoddDataRoot(path: path + "/r"), launcher: nil,
                                       claudeDirectory: ClaudeDirectory(path: path + "/claude")) { _ in }
        store.processAncestors = { _ in [1] }
        await store.start()
        defer { store.shutdown() }
        store.applyRegistry([entry(pid: 900_601, sessionId: "ext-cli", entrypoint: "cli"),
                             entry(pid: 900_602, sessionId: "ext-sdk", entrypoint: "sdk-cli", kind: "sdk"),
                             entry(pid: 900_603, sessionId: "ext-desktop", entrypoint: "claude-desktop")])
        func externals() -> [SessionVM] { store.allSessions.filter(\.external) }
        #expect(externals().count == 1, "SDK and Desktop are hidden by default")
        #expect(store.allSessions.filter { $0.state.needsAttention }.count == 1)

        store.setExternalDisplay(hidden: false, filter: ExternalSessionFilter(hideSDK: false, hideDesktop: false))
        #expect(externals().count == 3)
        store.setExternalDisplay(hidden: true, filter: ExternalSessionFilter(hideSDK: false, hideDesktop: false))
        #expect(externals().isEmpty, "隱藏: gone from the sidebar, NEEDS YOU and the counts")
        #expect(store.allSessions.filter { $0.state.needsAttention }.isEmpty)
        #expect(store.detectedExternalCount == 3, "the hint still counts what the registry has")
        store.setExternalDisplay(hidden: false, filter: ExternalSessionFilter())
        #expect(externals().count == 1)
    }
}

// MARK: - Dialog D on real holders (D18)

@MainActor
@Suite("Dialog D on real holders (I3, D18)", .serialized)
final class M3QuitDialogHolderTests {
    private let path: String

    init() throws { path = try m3TempFolder("codd-i3-quit") }
    deinit { m3RemoveFolder(path) }

    private func store() async throws -> HolderSessionStore {
        let root = CoddDataRoot(path: path + "/r")
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"])
        launcher.coddHookPath = "/usr/bin/true"
        let store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: ClaudeDirectory(path: path + "/claude"),
                                       hooks: nil) { _ in }
        await store.start()
        return store
    }

    @Test func keepRunningLeavesTheHoldersAndStopAllEndsThem() async throws {
        try FileManager.default.createDirectory(atPath: path + "/work", withIntermediateDirectories: true)
        let first = try await store()
        let a = try #require(first.createSession(NewSessionRequest(cwd: path + "/work", kind: .shell)))
        let b = try #require(first.createSession(NewSessionRequest(cwd: path + "/work", kind: .shell)))
        await m3Eventually("both shells run", timeout: .seconds(10)) {
            first.session(a)?.state == .shell && first.session(b)?.state == .shell
        }
        let pids = try [a, b].map { try #require(first.runtime($0)?.holderPid) }
        let model = QuitDialogController.model(store: first)
        #expect(model.running == 2 && model.stoppable == 2 && model.needs == 0)
        #expect(model.rows.isEmpty, "nothing needs you: the NEEDS YOU box stays hidden")
        #expect(QuitPolicy.decide(behavior: .ask, trigger: .user, running: 2) == .ask)

        // `結束 · session 繼續執行`: the app quits (only its connections close), the holders stay.
        #expect(QuitPolicy.decide(behavior: .ask, trigger: .confirmed, running: 2) == .terminate)
        first.shutdown()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(pids.allSatisfy { kill($0, 0) == 0 }, "holders keep running after the quit")

        // The next launch adopts them; `全部停止並結束` ends every one of them within 3 s.
        let second = try await store()
        defer { second.shutdown() }
        await m3Eventually("adopted", timeout: .seconds(10)) {
            second.session(a)?.state.isLive == true && second.session(b)?.state.isLive == true
        }
        let result = await QuitPolicy.stopAll(second, hub: nil)
        #expect(result.sessions == 2)
        #expect(result.left == 0)
        #expect(second.stopRequested.isSuperset(of: [a, b]), "a stop by the user is never an EXITED notification")
        await m3Eventually("holders ended", timeout: .seconds(5)) { pids.allSatisfy { kill($0, 0) != 0 } }
        #expect(QuitDialogController.model(store: second).running == 0)
        #expect(QuitPolicy.decide(behavior: .ask, trigger: .user, running: 0) == .terminate, "nothing runs: nothing asks")
    }
}

// MARK: - Menu bar title, Dock badge (D23, D29)

@MainActor
@Suite("Menu bar icon mode (I3, D23)")
struct M3MenuBarAppearanceTests {
    @Test func theTitleOnlyInCountsModeAndThePausedLook() {
        let now = Date()
        let sessions = [
            SessionVM(id: "w1", projectID: "p", title: "w1", state: .waiting, stateSince: now),
            SessionVM(id: "w2", projectID: "p", title: "w2", state: .waiting, stateSince: now),
            SessionVM(id: "e", projectID: "p", title: "e", state: .error, stateSince: now),
            SessionVM(id: "b", projectID: "p", title: "b", state: .busy, stateSince: now),
        ]
        var rules = CoddPreferences.defaults.notifications
        var look = StatusItemAppearance.make(sessions: sessions, hooksInstalled: true, rules: rules, now: now)
        #expect(look == StatusItemAppearance(state: .attention, paused: false, title: ""), "僅圖示 (default)")
        rules.menuBarIcon = .iconAndCounts
        look = StatusItemAppearance.make(sessions: sessions, hooksInstalled: true, rules: rules, now: now)
        #expect(look.title == "◆2 ▲1")
        rules.pausedUntil = now.addingTimeInterval(3600)
        look = StatusItemAppearance.make(sessions: [], hooksInstalled: false, rules: rules, now: now)
        #expect(look == StatusItemAppearance(state: .noHook, paused: true, title: ""))
    }
}

// MARK: - HOOKS & STATUS backups (D10)

@MainActor
@Suite("Settings › HOOKS backups (I3, D10)", .serialized)
struct M3SettingsBackupTests {
    /// A legacy CODD web handler next to a foreign one, in JSON.stringify's 2-space layout.
    private static let original = """
    {
      "hooks": {
        "Stop": [
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "node /opt/codd/status-writer.js Stop"
              }
            ]
          },
          {
            "matcher": "",
            "hooks": [
              {
                "type": "command",
                "command": "/opt/hook-tap/bin/hook-tap stop"
              }
            ]
          }
        ]
      },
      "model": "opus"
    }

    """

    @Test func backupsAreListedWithTheirReasonAndRestoreRoundTrips() async throws {
        let folder = try m3TempFolder("codd-i3-bak")
        defer { m3RemoveFolder(folder) }
        try FileManager.default.createDirectory(atPath: folder + "/claude", withIntermediateDirectories: true)
        let settings = URL(fileURLWithPath: folder + "/claude/settings.json")
        try Data(Self.original.utf8).write(to: settings)
        let service = ClaudeSettingsService(settingsURL: settings, dataRoot: URL(fileURLWithPath: folder + "/data"), log: { _ in })

        let plan = try #require(await service.plan(.update).successValue)
        #expect(plan.changes)
        let backup = try #require(try await service.apply(plan).get())
        service.flushIndex()
        #expect(try Data(contentsOf: backup) == Data(Self.original.utf8), "the backup is the file as it was")
        #expect(try String(contentsOf: settings, encoding: .utf8).contains("hook-tap"), "foreign handlers stay")
        #expect(try !String(contentsOf: settings, encoding: .utf8).contains("status-writer.js"))

        // Settings lists it with the reason from the backups index; 還原 / 差異 open dialog B.
        let opened = Recorder<(InstallerAction, Bool)>()
        var env = SettingsCoordinator.Environment(preferences: .inMemory())
        env.installer = service
        env.presentHookDiff = { action, _, readOnly in opened.append((action, readOnly)) }
        let coordinator = SettingsCoordinator(environment: env)
        await coordinator.refreshSlowFacts()
        let row = try #require(coordinator.model.info.hooks.backups.first)
        #expect(coordinator.model.info.hooks.backups.count == 1)
        #expect(row.name == backup.lastPathComponent)
        #expect(row.hint.contains("更新 hooks 與 statusline"))
        let actions = coordinator.makeActions()
        actions.restoreBackup(row.id)
        actions.compareBackup(row.id)
        let shown = opened.values
        #expect(shown.count == 2)
        #expect(shown.first?.0 == .restore(backup) && shown.first?.1 == false)
        #expect(shown.last?.0 == .restore(backup) && shown.last?.1 == true, "差異 is read-only")
        #expect(service.backupURL(named: "../../etc/passwd") == nil, "only backups of this file are ever opened")

        // 還原: the file is the backup's bytes again (the current one is backed up first).
        let restore = try #require(await service.plan(.restore(backup)).successValue)
        #expect(restore.changes)
        _ = try await service.apply(restore).get()
        #expect(try Data(contentsOf: settings) == Data(Self.original.utf8))
        #expect(ClaudeSettingsInstaller.backups(of: settings).count == 2)
    }
}
