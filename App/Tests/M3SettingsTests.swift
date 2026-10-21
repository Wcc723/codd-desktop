import AppKit
import CoddClaudeSettings
import CoddCore
import CoddDialogsUI
import CoddHooks
import CoddPreferences
import CoddSettingsUI
import CoddTerminal
import CoddUI
import Foundation
import Testing
@testable import CODD

/// M3 I3, pure and in-memory parts: each functional Settings row reaches its consumer, the D18
/// quit table, the D29 notification matrix, the Settings facts for the SPEC §5 mock, `還原本頁預設`
/// and `重設所有設定`, and the D28 version probe's isolation. Nothing here registers a login item,
/// a global hotkey or runs a real program.

private func iso(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

/// A local-time date today at `hh:mm` (quiet hours are local time).
private func today(_ hour: Int, _ minute: Int, calendar: Calendar = .current) -> Date {
    calendar.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
}

// MARK: - Consumers

@MainActor
@Suite("Settings reach their consumers (I3)")
struct M3SettingsConsumerTests {
    @Test func dockPolicyFollowsShowInDockExceptInTheBackground() {
        #expect(DockPolicy.policy(showInDock: true, background: false) == .regular)
        #expect(DockPolicy.policy(showInDock: false, background: false) == .accessory)
        #expect(DockPolicy.policy(showInDock: true, background: true) == .accessory, "a background launch never gets a Dock icon")
        #expect(DockPolicy.name(.accessory) == "accessory")
    }

    @Test func crtSegmentSetsTheOverlayAlpha() {
        let container = MainContainerViewController(split: NSSplitViewController())
        _ = container.view
        #expect(container.overlay == nil, "D15: CRT is OFF by default, no overlay at all")
        container.setCRT(.subtle)
        let subtle = container.overlay
        #expect(subtle != nil)
        #expect(subtle?.lineAlpha == 0.03)
        #expect(subtle?.superview === container.view)
        container.setCRT(.full)
        #expect(container.overlay === subtle, "the same overlay, redrawn")
        #expect(container.overlay?.lineAlpha == 0.06)
        container.setCRT(.off)
        #expect(container.overlay == nil)
        #expect(subtle?.superview == nil)
        #expect(ScanlineOverlayView.alpha(for: .off) == 0)
    }

    @Test func reduceMotionOverridesTheSystemSetting() {
        let ticker = UITicker(windowIsVisible: { _ in true }, reduceMotion: { false })
        #expect(ticker.pulsesAllowed)
        ticker.motionOverride = true
        #expect(!ticker.pulsesAllowed, "減少動態 開: lamps stay lit")
        ticker.motionOverride = false
        #expect(ticker.pulsesAllowed)
        let reducing = UITicker(windowIsVisible: { _ in true }, reduceMotion: { true })
        #expect(!reducing.pulsesAllowed, "系統: the system setting")
        reducing.motionOverride = false
        #expect(reducing.pulsesAllowed, "關: always animate")
        // The lamp follows a change at once.
        let lamp = LampView()
        lamp.ticker = ticker
        ticker.motionOverride = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(lamp)
        lamp.configure(StateStyle.of(.waiting))
        #expect(lamp.isPulsing)
        ticker.motionOverride = true
        #expect(!lamp.isPulsing)
        lamp.removeFromSuperview()
    }

    @Test func terminalFontFamilyIsTheProcessConfiguration() {
        let menlo = CoddTerminalSetup.configuration(fontFamily: "Menlo")
        #expect(menlo.fontFamily == "Menlo")
        #expect(menlo.renderedGhosttyConfig.contains("font-family = Menlo"))
        #expect(menlo.keyEquivalents == CoddTerminalSetup.configuration.keyEquivalents, "only the family changes")
        #expect(CoddTerminalSetup.configuration(fontFamily: "  ").fontFamily == "JetBrains Mono")
        #expect(TerminalRuntime.diagnostics(for: CoddTerminalSetup.configuration(fontFamily: "SF Mono")).isEmpty)
    }

    @Test func noHookGraceAppliesToSessionsRegisteredAfterIt() async throws {
        let engine = SessionStateEngine(configuration: .init(dataRoot: nil, batchInterval: .milliseconds(10)))
        let started = Date().addingTimeInterval(-15)
        let before = UUID()
        let after = UUID()
        await engine.register(SessionRegistration(sessionID: before, kind: .claude, process: .running(startedAt: started),
                                                  freshClaudeProcess: true))
        // Settings › 工作階段 › NO HOOK 警告 10 s: a session 15 s old without hooks is `! NO HOOK`.
        await engine.setStartingGrace(10)
        #expect(await engine.currentStartingGrace == 10)
        await engine.register(SessionRegistration(sessionID: after, kind: .claude, process: .running(startedAt: started),
                                                  freshClaudeProcess: true))
        var states: [UUID: CoddCore.SessionState] = [:]
        let reader = Task {
            var seen: [UUID: CoddCore.SessionState] = [:]
            for await batch in engine.updates {
                for update in batch.updates { seen[update.sessionID] = update.state }
                if seen.count == 2 { break }
            }
            return seen
        }
        let timeout = Task { try? await Task.sleep(for: .seconds(3)); reader.cancel() }
        states = await reader.value
        timeout.cancel()
        #expect(states[before] == .starting, "registered under the 20 s default")
        #expect(states[after] == .unknown, "registered after the 10 s setting")
        // The resolver takes the grace too (mock and tests).
        let input = SessionStateResolver.Input(kind: .claude, process: .running(startedAt: started), activity: SessionActivity(state: .unknown),
                                               hasHadTurn: false, startingGrace: 60)
        #expect(SessionStateResolver.resolve(input, now: Date()) == .starting)
        await engine.setStartingGrace(0)
        #expect(await engine.currentStartingGrace == 10, "a zero grace is refused")
    }

    @Test func dockBadgeModes() {
        let now = Date()
        let sessions = [
            SessionVM(id: "w", projectID: "p", title: "w", state: .waiting, stateSince: now),
            SessionVM(id: "e", projectID: "p", title: "e", state: .error, stateSince: now),
            SessionVM(id: "b", projectID: "p", title: "b", state: .busy, stateSince: now),
            SessionVM(id: "x", projectID: "p", title: "x", state: .exited, stateSince: now),
        ]
        #expect(AttentionMonitor.label(sessions: sessions, mode: .waiting) == "2", "等待數 = waiting + error")
        #expect(AttentionMonitor.label(sessions: sessions, mode: .all) == "3", "全部 = every live session")
        #expect(AttentionMonitor.label(sessions: sessions, mode: .off) == nil)
        #expect(AttentionMonitor.label(sessions: [], mode: .waiting) == nil)
        // The monitor follows the preference live.
        let store = MockSessionStore()
        let preferences = PreferencesService.inMemory()
        var written: [String?] = []
        let monitor = AttentionMonitor(store: store, mode: { preferences.preferences.notifications.dockBadge }, write: { written.append($0) })
        let attention = store.allSessions.filter { $0.state.needsAttention }.count
        #expect(written.last == .some("\(attention)"))
        preferences.update { $0.notifications.dockBadge = .off }
        _ = monitor
        #expect(AttentionMonitor.label(sessions: store.allSessions, mode: preferences.preferences.notifications.dockBadge) == nil)
    }

    @Test func menuBarTitleOnlyInCountsMode() {
        #expect(StatusItemAppearance.countsTitle(waiting: 2, error: 1) == "◆2 ▲1")
        #expect(StatusItemAppearance.countsTitle(waiting: 0, error: 1) == "▲1")
        #expect(StatusItemAppearance.countsTitle(waiting: 0, error: 0).isEmpty)
    }

    @Test func staleThresholdFollowsThePreference() {
        var prefs = CoddPreferences.defaults
        #expect(PreferencesService.staleAfter(prefs, override: nil) == 3600)
        prefs.sessions.staleAfterSeconds = 1800
        #expect(PreferencesService.staleAfter(prefs, override: nil) == 1800)
        prefs.sessions.staleAfterSeconds = nil
        #expect(PreferencesService.staleAfter(prefs, override: nil) == .infinity)
        #expect(PreferencesService.staleAfter(prefs, override: 5) == 5, "DEBUG -codd-stale-after wins")
    }

    @Test func projectRootStartsFolderPanelsAndResumeWarningIsASwitch() throws {
        let folder = try m3TempFolder("codd-i3-root")
        defer { m3RemoveFolder(folder) }
        var prefs = CoddPreferences.defaults
        prefs.general.projectRoot = folder
        #expect(AppDelegate.projectRoot(prefs) == folder)
        prefs.general.projectRoot = folder + "/missing"
        #expect(AppDelegate.projectRoot(prefs) == nil, "a folder that does not exist is not a start")
        prefs.general.projectRoot = "~"
        #expect(AppDelegate.projectRoot(prefs) == NSHomeDirectory(), "~ is expanded")

        let now = Date()
        let old = TranscriptSummary(id: "c-1", path: folder + "/c-1.jsonl", cwd: folder, title: "舊對話", titleSource: .firstPrompt,
                                    lastActivity: now.addingTimeInterval(-28 * 86_400), sizeBytes: 100)
        let warned = ResumePicker.rows([old], inUse: [], cleanupPeriodDays: 30, now: now)
        #expect(warned.first?.expiresInDays != nil)
        let quiet = ResumePicker.rows([old], inUse: [], cleanupPeriodDays: 30, now: now, warnExpiry: false)
        #expect(quiet.first?.expiresInDays == nil, "接續前提醒 OFF: no expiry line")
    }
}

// MARK: - Quit (D18)

@MainActor
@Suite("Quit decision table (D18)")
struct M3QuitPolicyTests {
    @Test func theTable() {
        typealias B = CoddPreferences.QuitBehavior
        // 詢問 (default): asks only while CODD sessions run.
        #expect(QuitPolicy.decide(behavior: .ask, trigger: .user, running: 2) == .ask)
        #expect(QuitPolicy.decide(behavior: .ask, trigger: .user, running: 0) == .terminate)
        // 全部停止.
        #expect(QuitPolicy.decide(behavior: .stopAll, trigger: .user, running: 2) == .stopAllThenTerminate)
        #expect(QuitPolicy.decide(behavior: .stopAll, trigger: .user, running: 0) == .terminate)
        // 保留: ⌘Q closes the window; the status item's 結束 still asks (the way out).
        #expect(QuitPolicy.decide(behavior: .keep, trigger: .user, running: 2) == .closeWindow)
        #expect(QuitPolicy.decide(behavior: .keep, trigger: .user, running: 0) == .closeWindow)
        #expect(QuitPolicy.decide(behavior: .keep, trigger: .statusItem, running: 2) == .ask)
        #expect(QuitPolicy.decide(behavior: .stopAll, trigger: .statusItem, running: 2) == .ask)
        #expect(QuitPolicy.decide(behavior: .keep, trigger: .statusItem, running: 0) == .terminate)
        // Logout / restart / shutdown, -codd-quit-after and an answered dialog never ask.
        for behavior in [B.ask, .stopAll, .keep] {
            for trigger in [QuitTrigger.system, .automation, .confirmed] {
                #expect(QuitPolicy.decide(behavior: behavior, trigger: trigger, running: 5) == .terminate, "\(behavior) \(trigger)")
            }
        }
    }

    @Test func theAppleEventQuitReason() {
        func quitEvent(reason: String?) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(eventClass: QuitPolicy.fourCharCode("aevt"), eventID: QuitPolicy.fourCharCode("quit"),
                                               targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                               transactionID: AETransactionID(kAnyTransactionID))
            if let reason {
                event.setAttribute(NSAppleEventDescriptor(enumCode: QuitPolicy.fourCharCode(reason)), forKeyword: QuitPolicy.fourCharCode("why?"))
            }
            return event
        }
        for reason in ["logo", "rlgo", "rrst", "rest", "rsdn", "shut"] {
            #expect(QuitPolicy.isSystemQuit(quitEvent(reason: reason)), "\(reason)")
        }
        #expect(!QuitPolicy.isSystemQuit(quitEvent(reason: nil)), "the Dock's Quit has no reason")
        #expect(!QuitPolicy.isSystemQuit(nil), "⌘Q is no Apple event")
        let open = NSAppleEventDescriptor(eventClass: QuitPolicy.fourCharCode("aevt"), eventID: QuitPolicy.fourCharCode("oapp"),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        #expect(!QuitPolicy.isSystemQuit(open))
    }

    @Test func dialogDModelRowsAndChoiceNames() {
        let store = MockSessionStore()
        let model = QuitDialogController.model(store: store)
        let live = store.allSessions.filter { $0.state.isLive }
        #expect(model.running == live.count, "externals count as running")
        #expect(model.stoppable == live.filter { !$0.external }.count, "only CODD's can be stopped")
        #expect(model.needs == store.allSessions.filter { $0.state.needsAttention }.count)
        // Artboard D (M3 review): the NEEDS YOU sessions only, in the sidebar's NEEDS YOU order.
        #expect(model.rows.map(\.id) == SidebarSnapshotBuilder.needsYou(store: store, filter: "").map(\.id))
        #expect(model.rows.count == model.needs && model.needs > 0)
        #expect(model.rows.allSatisfy { store.session($0.id)?.state.needsAttention == true })
        if let waiting = model.rows.first(where: { store.session($0.id)?.state == .waiting }) {
            #expect(waiting.pillFilled)
            #expect(["Perm", "Ask", "Plan"].contains(waiting.pill))
        }
        for choice in [QuitChoice.stopAllAndQuit, .quitKeepingSessions, .keepInMenuBar, .cancel] {
            #expect(QuitDialogController.choice(named: QuitDialogController.name(choice)) == choice)
        }
        #expect(QuitDialogController.choice(named: "nope") == nil)
        #expect(QuitDialogController.model(store: store, keepNextTime: true).keepNextTime)
    }

    @Test func debugFlagsParse() {
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-quit-request", "2", "-codd-quit-choice", "keep-running",
                                                        "-codd-global-hotkey", "YES", "-codd-hotkey", "ctrl+option+cmd+f12"],
                                            environment: [:], home: "/Users/t")
        #expect(options.quitRequestSeconds == 2)
        #expect(options.quitChoice == "keep-running")
        #expect(options.globalHotkey == true)
        #expect(options.hotkeyCombo == "ctrl+option+cmd+f12")
        let none = RealModeOptions.parse(arguments: ["CODD", "-codd-quit-choice", "maybe", "-codd-global-hotkey", "NO"], environment: [:],
                                         home: "/Users/t")
        #expect(none.quitChoice == nil)
        #expect(none.globalHotkey == false)
        #expect(RealModeOptions.parse(arguments: ["CODD"], environment: [:], home: "/").globalHotkey == nil)
        #expect(options.releaseSubset.globalHotkey == nil, "DEBUG only")
        #expect(HotkeyService.isAllowed(standardRoot: true, debugFlag: nil))
        #expect(!HotkeyService.isAllowed(standardRoot: false, debugFlag: nil))
        #expect(HotkeyService.isAllowed(standardRoot: false, debugFlag: true))
        #expect(!HotkeyService.isAllowed(standardRoot: true, debugFlag: false))
    }
}

// MARK: - Notifications (D29)

@MainActor
@Suite("Notification matrix (D29)")
struct M3NotificationMatrixTests {
    @Test func eventsFromTransitions() {
        #expect(NotificationRules.event(from: .busy, to: .waiting, exitCode: nil) == .waiting)
        #expect(NotificationRules.event(from: .busy, to: .error, exitCode: nil) == .error)
        #expect(NotificationRules.event(from: .busy, to: .done, exitCode: nil) == .done, "DONE = a finish the user did not see")
        #expect(NotificationRules.event(from: .busy, to: .idle, exitCode: nil) == nil, "a finish in front of the user is IDLE: no banner")
        #expect(NotificationRules.event(from: .idle, to: .exited, exitCode: 1) == .exited)
        #expect(NotificationRules.event(from: .idle, to: .exited, exitCode: 0) == nil, "EXITED only with a non-zero code")
        #expect(NotificationRules.event(from: .idle, to: .exited, exitCode: nil) == nil)
        #expect(NotificationRules.event(from: .waiting, to: .waiting, exitCode: nil) == nil)
        #expect(NotificationRules.event(from: .idle, to: .busy, exitCode: nil) == nil)
    }

    @Test func conditionNotifySoundAndMute() {
        let rules = CoddPreferences.defaults.notifications
        let noon = today(12, 0)
        // WAITING: 一律通知 · sound on.
        var v = NotificationRules.decide(.waiting, rules: rules, viewing: true, muted: false, now: noon)
        #expect(v == .init(due: true, silenced: false, sound: true), "一律通知 notifies the session on screen too")
        // DONE: 僅在未聚焦時 · no sound.
        v = NotificationRules.decide(.done, rules: rules, viewing: true, muted: false, now: noon)
        #expect(!v.due, "僅在未聚焦時: not while it is on screen")
        v = NotificationRules.decide(.done, rules: rules, viewing: false, muted: false, now: noon)
        #expect(v == .init(due: true, silenced: false, sound: false))
        // EXITED: notify, no sound.
        #expect(NotificationRules.decide(.exited, rules: rules, viewing: false, muted: false, now: noon).sound == false)
        // Muted groups never notify.
        #expect(!NotificationRules.decide(.waiting, rules: rules, viewing: false, muted: true, now: noon).due)
        // The notify switch.
        var off = rules
        off.error.notify = false
        #expect(!NotificationRules.decide(.error, rules: off, viewing: false, muted: false, now: noon).due)
        off.error.notify = true
        off.error.sound = false
        #expect(NotificationRules.decide(.error, rules: off, viewing: false, muted: false, now: noon).sound == false)
        off.waiting.condition = .unfocusedOnly
        #expect(!NotificationRules.decide(.waiting, rules: off, viewing: true, muted: false, now: noon).due)
    }

    @Test func quietHoursAcrossMidnightAndThePause() {
        let rules = CoddPreferences.defaults.notifications   // 23:00–08:00, on
        #expect(NotificationRules.isQuiet(rules, now: today(23, 30)))
        #expect(NotificationRules.isQuiet(rules, now: today(7, 59)))
        #expect(!NotificationRules.isQuiet(rules, now: today(8, 0)), "the end is not quiet")
        #expect(NotificationRules.isQuiet(rules, now: today(23, 0)), "the start is")
        #expect(!NotificationRules.isQuiet(rules, now: today(12, 0)))
        var silenced = NotificationRules.decide(.waiting, rules: rules, viewing: false, muted: false, now: today(23, 30))
        #expect(silenced == .init(due: true, silenced: true, sound: false), "recorded, no banner, no sound")
        var off = rules
        off.quietHours.enabled = false
        #expect(!NotificationRules.isQuiet(off, now: today(23, 30)))
        var daytime = rules
        daytime.quietHours.start = "09:00"
        daytime.quietHours.end = "17:00"
        #expect(NotificationRules.isQuiet(daytime, now: today(12, 0)))
        #expect(!NotificationRules.isQuiet(daytime, now: today(17, 0)))
        var paused = rules
        paused.quietHours.enabled = false
        paused.pausedUntil = Date().addingTimeInterval(600)
        silenced = NotificationRules.decide(.error, rules: paused, viewing: false, muted: false, now: Date())
        #expect(silenced.silenced)
        paused.pausedUntil = Date().addingTimeInterval(-1)
        #expect(!NotificationRules.decide(.error, rules: paused, viewing: false, muted: false, now: Date()).silenced, "the hour is over")
    }

    @Test func theNotifierRecordsEveryDueDecision() {
        let store = MockSessionStore()
        let log = NotificationLog()
        var rules = CoddPreferences.defaults.notifications
        rules.quietHours.enabled = false
        var muted: Set<SessionID> = []
        var stopped: Set<SessionID> = []
        let notifier = SessionNotifier(store: store, allowedThisRun: false, rules: { rules }, isFocused: { _ in false },
                                       isMuted: { muted.contains($0.id) }, stoppedByUser: { stopped.contains($0) }, open: { _ in },
                                       decisions: log, quietPeriod: 0)
        let session = SessionVM(id: "s1", projectID: "p", title: "修正登入 API 401", state: .waiting, stateSince: Date())
        notifier.sessionChanged(session, from: .busy)
        session.state = .done
        notifier.sessionChanged(session, from: .busy)
        session.state = .exited
        session.exitCode = 1
        notifier.sessionChanged(session, from: .idle)
        session.exitCode = 0
        notifier.sessionChanged(session, from: .idle)
        stopped.insert("s1")
        session.exitCode = 143
        notifier.sessionChanged(session, from: .busy)
        muted.insert("s1")
        session.state = .error
        notifier.sessionChanged(session, from: .busy)
        #expect(log.entries.map(\.kind) == ["session-waiting", "session-done", "session-exited"],
                "EXITED 0, a stopped session and a muted group are not news")
        #expect(log.entries.allSatisfy { $0.suppressed }, "-codd-notifications NO: recorded, never posted")
        #expect(log.entries[1].title == "◇ 修正登入 API 401 完成")
        #expect(log.entries[2].title.hasPrefix("✕ 修正登入 API 401 已結束 · exit 1"))
        notifier.sendTest()
        #expect(log.entries.last?.kind == "test")
        #expect(log.entries.last?.title == "◆ 測試通知 · CODD")
        // Externals are never notified.
        let external = SessionVM(id: "ext-1", projectID: "p", title: "外部", state: .waiting, stateSince: Date())
        external.externalInfo = ExternalInfo(pid: 1)
        notifier.sessionChanged(external, from: .busy)
        #expect(log.entries.count == 4)
    }

    @Test func isEnabledCoversTheFourRows() {
        var rules = CoddPreferences.defaults.notifications
        for state in [SessionState.waiting, .error, .done, .exited] {
            #expect(SessionNotifier.isEnabled(for: state, rules: rules), "\(state)")
        }
        for state in SessionState.allCases where ![.waiting, .error, .done, .exited].contains(state) {
            #expect(!SessionNotifier.isEnabled(for: state, rules: rules), "\(state)")
        }
        rules.done.notify = false
        rules.exitedNonZero.notify = false
        #expect(!SessionNotifier.isEnabled(for: .done, rules: rules))
        #expect(!SessionNotifier.isEnabled(for: .exited, rules: rules))
    }
}

// MARK: - Settings model

@MainActor
@Suite("Settings facts and edits (I3)")
struct M3SettingsModelTests {
    @Test func theSpecMockMapsToTheArtboardTexts() {
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        // The SPEC §5 sample's clock (2026-10-15 10:42 Asia/Taipei).
        var facts = SettingsFacts(now: MockData.referenceDate)
        var taipei = Calendar(identifier: .gregorian)
        taipei.timeZone = TimeZone(identifier: "Asia/Taipei")!
        facts.calendar = taipei
        facts.accountsReady = true
        facts.inspection = .loaded(ClaudeSettingsInspection(
            legacyHookEvents: MockData.settingsInspection.legacyHookEvents, legacyHandlerCount: 10, foreign: MockData.settingsInspection.foreign,
            statusLine: .coddWeb(inner: "/Users/u/.hook-tap/bin/hook-tap statusline /Users/u/.hook-tap/statusline.sh"), duplicateNotificationHandlers: 2),
            exists: true)
        facts.lastStatusLineAt = MockData.ago(8)
        facts.cswap = SettingsCswapInfo(pathOK: true, version: "0.26.0", versionOK: true)
        let info = SettingsInfoBuilder.info(store: store, accounts: accounts, facts: facts)
        // ACCOUNTS: R7 order, the artboard's cells.
        #expect(info.accounts.map(\.slot) == ["#2", "#3", "#1"])
        let north = info.accounts[0]
        #expect(north.alias == "藍鵲")
        #expect(north.plan == "MAX 20x")
        #expect(north.fiveHour.valueText == "98%")
        #expect(north.weekly.valueText == "46%")
        #expect(north.resetIn == "1d12h後")
        #expect(north.sessions == "1 session 固定 · cswap run")
        #expect(info.accounts[1].isActive)
        #expect(info.accounts[1].sessions == "12 session")
        #expect(info.accounts[2].fiveHour.valueText == "未開始")
        #expect(info.accounts[2].sessions == "0 session")
        #expect(info.usageSources.map(\.glyph) == ["●", "○"])
        #expect(info.usageSources[0].accounts == "#3 工作")
        #expect(info.usageSources[0].source == "statusline 的 rate_limits")
        #expect(info.usageSources[0].age == "12s 前")
        #expect(info.usageSources[1].accounts == "#2 藍鵲 · #1 個人")
        #expect(info.usageSources[1].source == "cswap 快取")
        #expect(info.usageSources[1].age == "3m 前")
        #expect(info.aliasRuleHint == "別名只能用英文小寫、數字與 - _ .（cswap 規則）")
        // HOOKS & STATUS: the user's machine (D10).
        let parts = info.hooks.components
        #expect(parts.map(\.id) == ["hooks", "statusline", "legacy"])
        #expect(parts[0].status == "● 14 / 14 · 每個 CODD session 自動注入")
        #expect(parts[1].status == "◆ 需要更新")
        #expect(parts[1].hint.contains("（串接 hook-tap → statusline.sh）"))
        #expect(parts[1].chip == "最近收到資料 8s 前")
        #expect(parts[1].buttons.map(\.title) == ["預覽變更", "更新"])
        #expect(parts[2].status == "◆ 偵測到 CODD web hooks")
        #expect(parts[2].hint == "10 個事件上有 status-writer.js；CODD Desktop 不需要它們。")
        #expect(info.hooks.foreignSummary == "外部 hooks 保持不動：hook-tap ×11 · osascript 通知 ×2")
        #expect(info.hooks.navTail == "◆ 更新")
        #expect(info.hooks.events.count == 14)
        #expect(info.hooks.events.allSatisfy { $0.installed })
        #expect(!info.hooks.canUninstall)
        // Groups (依群組靜音), REMOTE, Dock hint.
        #expect(info.groups.last?.name == "未分類")
        #expect(info.groups.last?.color == nil)
        #expect(info.rcCount == store.allSessions.filter { $0.state.isLive && $0.remoteControl }.count)
        #expect(info.waitingCount == store.allSessions.filter { $0.state.needsAttention }.count)
        #expect(info.profileNames.first?.title == "claude-default · claude")
    }

    @Test func profileTitlesAndBackupRows() {
        let names = SettingsInfoBuilder.profileNames(LaunchProfileDocument.seeded)
        #expect(names.contains { $0.title.hasSuffix(" · shell") })
        #expect(names.contains { $0.title.contains("--permission-mode plan") })
        #expect(names.contains { $0.title.contains("--remote-control") })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        let backup = SettingsBackup(url: URL(fileURLWithPath: "/t/settings.json.codd-bak-20261012-091503"),
                                    date: iso("2026-10-12T01:15:03Z"), size: 4198)
        let row = SettingsInfoBuilder.backupRow(backup, reason: "安裝 statusline", calendar: calendar)
        #expect(row.name == "settings.json.codd-bak-20261012-091503")
        #expect(row.hint == "10/12 09:15 · 安裝 statusline · 4.1 KB")
        #expect(row.label == "10/12")
        #expect(SettingsInfoBuilder.size(812) == "812 B")
    }

    @Test func statusLineRowsForEveryD10State() {
        func row(_ state: StatusLineState) -> SettingsHooksComponent {
            SettingsInfoBuilder.statusLineRow(ClaudeSettingsInspection(legacyHookEvents: [], legacyHandlerCount: 0, foreign: [], statusLine: state,
                                                                      duplicateNotificationHandlers: 0), chip: nil)
        }
        #expect(row(.none).status == "○ 未安裝")
        #expect(row(.none).buttons.map(\.action) == [.previewChanges, .update])
        #expect(row(.user("printf hi")).status == "○ 未安裝")
        #expect(row(.coddDesktop(chain: nil, current: true)).status == "● 已安裝")
        #expect(row(.coddDesktop(chain: nil, current: true)).buttons.last?.action == .uninstall)
        #expect(row(.coddDesktop(chain: nil, current: false)).status == "◆ 需要更新")
        #expect(row(.undecodable).buttons.isEmpty)
    }

    @Test func editsSaveThroughThePreferencesAndResetPerSection() {
        let preferences = PreferencesService.inMemory()
        let coordinator = SettingsCoordinator(environment: .init(preferences: preferences))
        let model = coordinator.model
        model.update {
            $0.general.showInDock = false
            $0.appearance.crt = .full
            $0.sessions.noHookWarningSeconds = 60
            $0.notifications.done.sound = true
            $0.accounts.confirmBeforeSwitch = true
            $0.cleanup.resumeWarning = false
            $0.advanced.scrollbackRetentionDays = 90
        }
        #expect(preferences.preferences.general.showInDock == false, "an edit reaches the service (saved 300 ms later)")
        #expect(preferences.preferences.appearance.crt == .full)
        // The service's change comes back into the model (another window, a DEBUG assignment).
        preferences.update { $0.appearance.terminalFontSize = 16 }
        let sections: [(SettingsSection, (CoddPreferences) -> Bool)] = [
            (.general, { $0.general == CoddPreferences.defaults.general }),
            (.appearance, { $0.appearance == CoddPreferences.defaults.appearance }),
            (.sessions, { $0.sessions == CoddPreferences.defaults.sessions }),
            (.notifications, { $0.notifications == CoddPreferences.defaults.notifications }),
            (.accounts, { $0.accounts == CoddPreferences.defaults.accounts }),
            (.cleanup, { $0.cleanup == CoddPreferences.defaults.cleanup }),
            (.advanced, { $0.advanced == CoddPreferences.defaults.advanced }),
        ]
        for (section, isDefault) in sections {
            #expect(!isDefault(preferences.preferences), "\(section) was edited")
            model.resetSection(section)
            #expect(isDefault(preferences.preferences), "還原本頁預設 \(section)")
        }
        #expect(preferences.preferences == CoddPreferences.defaults)
    }

    /// The page writes only what it edited: a change made elsewhere before the page synced (the
    /// menu bar's pause, here in the same turn) survives an edit on the page.
    @Test func anEditNeverOverwritesANewerChangeMadeElsewhere() {
        let preferences = PreferencesService.inMemory()
        let coordinator = SettingsCoordinator(environment: .init(preferences: preferences))
        let pause = Date().addingTimeInterval(3600)
        preferences.update {
            $0.notifications.pausedUntil = pause
            $0.general.quitBehavior = .stopAll
        }
        // The page still shows the old copy (its observation loop runs on the next turn).
        #expect(coordinator.model.preferences.notifications.pausedUntil == nil)
        coordinator.model.update { $0.notifications.done.sound = true }
        coordinator.model.update { $0.appearance.crt = .subtle }
        #expect(preferences.preferences.notifications.pausedUntil == pause, "the pause survives")
        #expect(preferences.preferences.general.quitBehavior == .stopAll, "an untouched section survives")
        #expect(preferences.preferences.notifications.done.sound)
        #expect(preferences.preferences.appearance.crt == .subtle)
    }

    @Test func resetAllKeepsThePauseAndNothingElse() async {
        let preferences = PreferencesService.inMemory()
        let coordinator = SettingsCoordinator(environment: .init(preferences: preferences))
        let pause = Date().addingTimeInterval(1800)
        preferences.update {
            $0.general.quitBehavior = .keep
            $0.appearance.crt = .subtle
            $0.notifications.pausedUntil = pause
        }
        coordinator.resetAll()
        var expected = CoddPreferences.defaults
        expected.notifications.pausedUntil = pause
        #expect(preferences.preferences == expected)
        // The page's model follows the service on the observation loop's next turn.
        await m3Eventually("the page shows the defaults") { coordinator.model.preferences == expected }
    }

    @Test func theWindowHostsTheSettingsPageAtItsSize() throws {
        let preferences = PreferencesService.inMemory()
        let settings = SettingsWindowController(profiles: LaunchProfiles.inMemory(), preferences: preferences)
        let window = try #require(settings.window)
        #expect(window.contentView === settings.root)
        #expect(window.frame.size.width >= SettingsWindowController.size.width)
        #expect(window.minSize == SettingsWindowController.minimumSize)
        settings.select("notifications")
        #expect(settings.section == "notifications")
        settings.select("remote")
        #expect(settings.section == "remote")
        settings.select("nope")
        #expect(settings.section == "remote", "an unknown id keeps the section")
        settings.select("profiles")
        #expect(settings.root.selected == .profiles)
        // `看規劃 → Remote 畫板` selects REMOTE through the coordinator.
        settings.select("general")
        settings.coordinator.selectSection(.remote)
        #expect(settings.section == "remote")
        // The model is the preferences' (an edit through it saves).
        settings.coordinator.model.update { $0.notifications.waiting.notify = false }
        #expect(!preferences.preferences.notifications.waiting.notify)
    }
}

// MARK: - Version probe (D28, D3)

@MainActor
@Suite("Version probe isolation (D28)")
struct M3VersionProbeTests {
    final class CountingRunner: CommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var invocations: [CommandInvocation] = []
        let output: String
        init(output: String) { self.output = output }
        var calls: [CommandInvocation] { lock.withLock { invocations } }
        func run(_ invocation: CommandInvocation) async throws -> CommandResult {
            lock.withLock { invocations.append(invocation) }
            return CommandResult(status: 0, stdout: Data(output.utf8))
        }
    }

    @Test func aTestRootNeverRunsClaudeWithoutTheDebugPath() async {
        #expect(AppDelegate.claudeExecutable(override: nil, standardRoot: false) == nil, "D3: no claude on a test root")
        let runner = CountingRunner(output: "2.1.302 (Claude Code)\n")
        let probe = VersionProbe(claudeExecutable: AppDelegate.claudeExecutable(override: nil, standardRoot: false), runner: runner)
        await probe.refreshClaude()
        #expect(runner.calls.isEmpty)
        #expect(probe.claudeVersion == nil)
        #expect(VersionProbe.rows(claude: probe.claudeVersion, cswap: nil).first { $0.key == "Claude Code" }?.value == "—")
        // A relative name is never run (no PATH search).
        let relative = VersionProbe(claudeExecutable: "claude", runner: runner)
        await relative.refreshClaude()
        #expect(runner.calls.isEmpty)
    }

    @Test func theDebugPathIsRunOnceAndLogged() async {
        let runner = CountingRunner(output: "2.1.300 (Claude Code)\n")
        var lines: [String] = []
        let path = "/tmp/codd-i3/fake-claude"
        let probe = VersionProbe(claudeExecutable: AppDelegate.claudeExecutable(override: path, standardRoot: false), runner: runner,
                                 log: { lines.append($0) })
        await probe.refreshClaude()
        #expect(probe.claudeVersion == "2.1.300")
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.arguments == ["--version"])
        #expect(runner.calls.first?.executable == path)
        #expect(runner.calls.first?.timeout == .seconds(5))
        #expect(lines.contains("exec claude path=\(path) sub=--version"), "D38")
        #expect(VersionProbe.version(in: "claude-swap 0.26.0") == "0.26.0")
        #expect(VersionProbe.version(in: "no version") == nil)
        let rows = VersionProbe.rows(claude: probe.claudeVersion, cswap: "0.26.0")
        #expect(rows.map(\.key) == ["App", "macOS", "Claude Code", "cswap", "libghostty"])
        let text = VersionProbe.diagnostics(rows, dataRoot: "~/r")
        #expect(text.contains("Claude Code 2.1.300"))
        #expect(text.contains("cswap 0.26.0"))
    }
}
