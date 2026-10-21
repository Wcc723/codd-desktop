import AppKit
import CoddCore
import CoddHooks
import CoddPreferences
import CoddUI
import Foundation
import Testing
@testable import CODD

/// Regression tests for the M3 review fixes (docs/M3-REPORT.md §9): quota identities, the loading
/// queue, the empty cswap state, quota.json's save schedule, the suspected-login-change limit,
/// card health, auto-switch failures and UNDO, and the per-report rebuilds of Home and Settings.
@MainActor
@Suite("M3 review fixes: accounts and quota", .serialized)
struct M3ReviewAccountTests {
    /// `cswap swap a b`: the two records trade slot numbers (aliases with them). cswap's cache
    /// rows stay under the old numbers, so its identity guard drops both.
    private func swapSlots(_ state: FakeCswapState, _ a: Int, _ b: Int) throws {
        let url = state.root.appendingPathComponent("sequence.json")
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var records = try #require(object["accounts"] as? [String: Any])
        let first = records[String(a)], second = records[String(b)]
        records[String(a)] = second
        records[String(b)] = first
        object["accounts"] = records
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    private func quotaFile(_ f: AccountStoreFixture) -> [String: Any]? {
        (try? Data(contentsOf: URL(fileURLWithPath: f.folder + "/data/quota.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// correctness-1: after `cswap swap 2 3` the active login's reports went to #2 (its old slot)
    /// and the active #3 kept the other login's numbers.
    @Test func aSwapKeepsEachLoginsNumbersWithItsLogin() async throws {
        let f = try AccountStoreFixture("codd-rv-swap", active: 2)
        await f.store.start()
        let northReset = try #require(f.state.weeklyReset(2))
        f.store.ingest(f.report(key: "default", five: 20, fiveReset: f.clock.addingTimeInterval(3600), week: 45, weekReset: northReset))
        #expect(f.store.account("2")?.source == "statusline")
        #expect(f.store.account("3")?.week.remainingPercent == 15, "work's cache row")

        try swapSlots(f.state, 2, 3)
        await f.store.read(force: true)
        #expect(f.store.activeAccountID == "3", "the north login holds slot 3 now")
        #expect(f.store.account("3")?.week.remainingPercent == 55, "north's numbers moved with it")
        #expect(f.store.account("2")?.week.remainingPercent == 15, "work's moved to #2")

        f.clock = f.clock.addingTimeInterval(120)
        f.store.ingest(f.report(key: "default", five: 25, fiveReset: f.clock.addingTimeInterval(3600), week: 46, weekReset: northReset))
        #expect(f.store.statusLine.lastAccount == "3")
        #expect(f.store.account("3")?.week.remainingPercent == 54)
        #expect(f.store.account("2")?.week.remainingPercent == 15)
        #expect(!f.logs.values.contains { $0.contains("suggests a login change") })
        m3ExpectNoAccountLeak(f.exposedText, "store after the swap")
    }

    /// correctness-1 (b): a leftover entry of a removed account shared the active login's reset
    /// and took (then dropped) every report, so the active account never got numbers.
    @Test func aRemovedAccountsLeftoverEntryTakesNothing() async throws {
        let f = try AccountStoreFixture("codd-rv-leftover", quota: true)
        let reset = try #require(f.state.weeklyReset(3))
        let seeded: [String: Any] = ["v": 1, "accounts": [
            "5": ["weekly": ["usedPercent": 10, "resetsAt": JSDate.isoString(reset), "source": "statusline",
                             "capturedAt": JSDate.isoString(f.clock.addingTimeInterval(-600))]],
            "default": ["weekly": ["usedPercent": 7, "source": "statusline", "capturedAt": JSDate.isoString(f.clock.addingTimeInterval(-600))]],
        ]]
        try JSONSerialization.data(withJSONObject: seeded).write(to: URL(fileURLWithPath: f.folder + "/data/quota.json"))
        await f.store.start()
        f.store.ingest(f.report(key: "default", five: 30, fiveReset: f.clock.addingTimeInterval(3600), week: 50, weekReset: reset))
        #expect(f.store.statusLine.lastAccount == "3")
        #expect(f.store.statusLine.dropped == 0)
        #expect(f.store.account("3")?.week.remainingPercent == 50)
        f.store.flush()
        let entries = try #require(quotaFile(f)?["accounts"] as? [String: Any])
        #expect(entries["5"] == nil, "the removed account's entry is gone")
        #expect(entries["default"] == nil, "the D4 entry goes once cswap has accounts")
        #expect((entries["3"] as? [String: Any])?["identity"] is String)
    }

    /// correctness-3: reports during `.loading` landed on the D4 pseudo account.
    @Test func reportsWhileLoadingWaitForTheFirstRead() async throws {
        let f = try AccountStoreFixture("codd-rv-loading")
        f.store.ingest(f.report(key: "default", five: 10, fiveReset: f.clock.addingTimeInterval(3600), week: 60,
                                weekReset: f.state.weeklyReset(3)))
        #expect(f.store.statusLine.accepted == 1)
        #expect(f.store.accounts.isEmpty, "nothing attributed yet")
        await f.store.start()
        #expect(f.store.statusLine.lastAccount == "3")
        #expect(f.store.account("3")?.week.remainingPercent == 40)
        #expect(!f.store.accounts.contains { $0.isPseudo })
        #expect(!f.store.hasDefaultLoginEntry)
    }

    /// correctness-6: no sequence.json yet (cswap creates it on the first add) is "no accounts
    /// yet", not an unreadable state that blocks 加入帳號.
    @Test func noStateYetIsReadyWithoutAccounts() async throws {
        let f = try AccountStoreFixture("codd-rv-empty")
        try FileManager.default.removeItem(at: f.state.root.appendingPathComponent("sequence.json"))
        await f.store.start()
        #expect(f.store.availability == .ready)
        #expect(f.store.accounts.isEmpty)
        _ = await f.store.addCurrentLogin(slot: 1, alias: "studio")
        #expect(f.runner.calls.contains { $0.first == "add" }, "dialog C's add reaches cswap")
        f.store.ingest(f.report(key: "default", five: 10, fiveReset: f.clock.addingTimeInterval(3600), week: 20,
                                weekReset: f.clock.addingTimeInterval(86_400)))
        #expect(f.store.accounts.map(\.id) == ["default"], "the global login's numbers as the D4 row")
    }

    /// perf-2: steady reports restarted the 2 s debounce forever (written only at quit), and the
    /// D37 cooldown went through the same starved debounce.
    @Test func quotaJSONIsWrittenWhileReportsKeepComingAndTheCooldownAtOnce() async throws {
        let f = try AccountStoreFixture("codd-rv-save", quota: true) {
            $0.saveDelay = .milliseconds(300)
            $0.maxSaveDelay = .milliseconds(600)
        }
        await f.store.start()
        let url = URL(fileURLWithPath: f.folder + "/data/quota.json")
        await m3Eventually("first write", timeout: .seconds(3)) { FileManager.default.fileExists(atPath: url.path) }
        try FileManager.default.removeItem(at: url)
        let start = ContinuousClock.now
        var writtenAfter: Duration?
        for _ in 0..<15 {
            f.clock = f.clock.addingTimeInterval(1)
            f.store.ingest(f.report(key: "default", five: 10, fiveReset: f.clock.addingTimeInterval(3600), week: 60,
                                    weekReset: f.state.weeklyReset(3)))
            try await Task.sleep(for: .milliseconds(100))
            if writtenAfter == nil, FileManager.default.fileExists(atPath: url.path) { writtenAfter = ContinuousClock.now - start }
        }
        let after = try #require(writtenAfter, "written although a report came every 100 ms")
        #expect(after < .milliseconds(1200))

        let g = try AccountStoreFixture("codd-rv-cool", quota: true) {
            $0.saveDelay = .seconds(30)
            $0.maxSaveDelay = .seconds(60)
        }
        await g.store.start()
        g.store.lastAutoSwitchAt = g.clock
        await m3Eventually("cooldown written at once", timeout: .seconds(3)) {
            (self.quotaFile(g)?["autoSwitch"] as? [String: Any])?["lastAt"] as? String == JSDate.isoString(g.clock)
        }
    }

    /// perf-5: every report of a suspected login change logged a line and forced a full read.
    @Test func aSuspectedLoginChangeIsLoggedAndReadAtMostOnceInAWhile() async throws {
        let f = try AccountStoreFixture("codd-rv-suspect")
        await f.store.start()
        for _ in 0..<6 {
            f.clock = f.clock.addingTimeInterval(1)
            // #3 is active; the report carries #2's weekly reset (outside any switch grace).
            f.store.ingest(f.report(key: "default", week: 50, weekReset: f.state.weeklyReset(2)))
        }
        #expect(f.logs.values.filter { $0.contains("suggests a login change") }.count == 1)
    }

    /// spec-fidelity-2: a live status-line account read `◌ 舊資料 · statusline · 0s 前`.
    @Test func cardHealthFollowsTheNumbersItShows() async throws {
        let f = try AccountStoreFixture("codd-rv-health")
        f.clock = f.clock.addingTimeInterval(20 * 60)  // cswap's cache rows are 23–30 min old
        await f.store.start()
        #expect(f.store.account("3")?.health == .stale)
        f.store.ingest(f.report(key: "default", five: 10, fiveReset: f.clock.addingTimeInterval(3600), week: 85,
                                weekReset: f.state.weeklyReset(3)))
        #expect(f.store.account("3")?.health == .ok, "fresh status-line numbers")
        #expect(f.store.account("2")?.health == .stale, "still cswap's old numbers")
        f.clock = f.clock.addingTimeInterval(16 * 60)
        await f.store.read(force: true)
        #expect(f.store.account("3")?.health == .stale, "the status-line numbers aged too")
    }

    /// spec-fidelity-9: the pseudo row has numbers, so the note says what it shows.
    @Test func thePseudoNoteNoLongerPromisesNumbers() {
        #expect(AccountAvailability.pseudoNote == "// 找不到 cswap（設定 › 帳號）· 只顯示目前登入的用量")
        #expect(!AccountAvailability.pseudoNote.contains("後出現"))
    }
}

@MainActor
@Suite("M3 review fixes: auto-switch", .serialized)
struct M3ReviewAutoSwitchTests {
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
            $0.notifications.quietHours.enabled = false
        }
        return preferences
    }

    private func switchCalls(_ f: AccountStoreFixture) -> Int { f.runner.calls.filter { $0.first == "switch" }.count }

    /// e2e-3: a `cswap switch` that keeps failing ran on every tick, silently.
    @Test func aFailingSwitchIsNotifiedOnceAndBacksOff() async throws {
        var script = FakeCswapRunner.Script()
        script.failSwitch = true
        let f = try AccountStoreFixture("codd-rv-autofail", script: script)
        await f.store.start()
        let preferences = await enabledPreferences()
        let log = NotificationLog()
        let runner = runner(f, log: log, preferences: preferences)
        let toasts = Recorder<String>()
        runner.toast = { text, _ in toasts.append(text) }
        runner.start()
        f.store.ingest(f.report(key: "default", week: 99, weekReset: f.state.weeklyReset(3)))
        runner.evaluate()
        await m3Eventually("first failure") { runner.lastSwitchResult == "failed #3 -> #2" && !runner.isSwitchInFlight }
        #expect(log.entries.map(\.kind) == ["account-auto-switch-failed"])
        #expect(log.entries.first?.title == "自動切換到 #2 藍鵲 失敗")
        #expect(toasts.values.count == 1 && toasts.values[0].hasPrefix("[ERROR] 自動切換到 #2 藍鵲 失敗："))
        m3ExpectNoAccountLeak(toasts.values.joined(separator: "\n"), "failure toast")

        f.clock = f.clock.addingTimeInterval(30)
        runner.evaluate()
        await m3Eventually("second failure") { switchCalls(f) == 2 && !runner.isSwitchInFlight && !f.store.isSwitching }
        #expect(log.entries.count == 1, "notified once per episode")
        f.clock = f.clock.addingTimeInterval(30)
        runner.evaluate()
        #expect(runner.lastDecision == "retry-wait")
        #expect(switchCalls(f) == 2)
        #expect(runner.dumpObject["failures"] as? Int == 2)
        f.clock = f.clock.addingTimeInterval(300)
        f.runner.setScript { $0.failSwitch = false }
        runner.evaluate()
        await m3Eventually("switched after the wait") { f.store.activeAccountID == "2" }
        #expect(switchCalls(f) == 3)
        runner.stop()
    }

    /// correctness-4: UNDO of an automatic switch held only until the 300 s cooldown ended.
    @Test func undoHoldsTheAccountPastTheCooldown() async throws {
        let f = try AccountStoreFixture("codd-rv-autoundo")
        await f.store.start()
        let preferences = await enabledPreferences()
        let runner = runner(f, log: NotificationLog(), preferences: preferences)
        let toasts = Recorder<String>()
        runner.toast = { text, _ in toasts.append(text) }
        runner.start()
        f.store.ingest(f.report(key: "default", week: 99, weekReset: f.state.weeklyReset(3)))
        runner.evaluate()
        await m3Eventually("auto-switched") { f.store.activeAccountID == "2" && !runner.isSwitchInFlight }
        runner.undo(to: "3")
        await m3Eventually("back on #3") { f.store.activeAccountID == "3" && !f.store.isSwitching }
        #expect(toasts.values.last?.hasSuffix(" · 在 1w 重置前不再自動切走") == true)
        f.clock = f.clock.addingTimeInterval(301)
        runner.evaluate()
        #expect(runner.lastDecision == "held-by-undo")
        #expect(switchCalls(f) == 2, "switch 2, then UNDO's switch 3: nothing after the cooldown")
        #expect((runner.dumpObject["hold"] as? [String: Any])?["account"] as? Int == 3)
        runner.stop()
    }
}

@MainActor
@Suite("M3 review fixes: per-report rebuilds", .serialized)
struct M3ReviewRebuildTests {
    /// concurrency-perf-1: Home rebuilt every card on every status-line report.
    @Test func homeDoesNotRebuildOnEveryReport() async throws {
        let f = try AccountStoreFixture("codd-rv-home")
        await f.store.start()
        let page = HomePageView(store: MockSessionStore(shiftClock: false), accounts: f.store, shell: ShellState(), services: nil,
                                profiles: nil)
        let renders = Recorder<Int>()
        page.onModelChange = { renders.append(1) }
        page.setActive(true)
        // 1w at 10 % used is on pace: no projected exhaustion (it moves with each capture; shown
        // to the minute, so it changes the model about once a minute, not per report).
        let fiveReset = f.clock.addingTimeInterval(3600)
        f.store.ingest(f.report(key: "default", five: 10, fiveReset: fiveReset, week: 10, weekReset: f.state.weeklyReset(3)))
        try await Task.sleep(for: .milliseconds(150))
        let before = renders.values.count
        #expect(before >= 1)
        for _ in 0..<5 {
            f.clock = f.clock.addingTimeInterval(1)
            f.store.ingest(f.report(key: "default", five: 10, fiveReset: fiveReset, week: 10, weekReset: f.state.weeklyReset(3)))
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(f.store.account("3")?.sourceAt == f.clock, "the capture time did move")
        #expect(renders.values.count == before, "same numbers: no rebuild")
        // A new number still renders.
        f.clock = f.clock.addingTimeInterval(1)
        f.store.ingest(f.report(key: "default", five: 40, fiveReset: fiveReset, week: 10, weekReset: f.state.weeklyReset(3)))
        try await Task.sleep(for: .milliseconds(150))
        #expect(renders.values.count == before + 1)
        page.setActive(false)
    }

    /// concurrency-perf-1: Home kept observing and rendering with the main window closed.
    @Test func homeStopsWhileTheWindowIsAway() {
        let shell = ShellState()
        shell.currentSessionID = nil
        let pane = SessionPaneViewController(store: MockSessionStore(shiftClock: false), accounts: MockAccountStore(), shell: shell,
                                             surfaceFactory: FakeTerminalSurfaceFactory { _ in "" })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = pane.view
        window.layoutIfNeeded()
        defer { window.close() }
        #expect(!pane.homePage.isHidden && pane.homePage.isActive, "no session selected: Home")
        pane.isWindowVisible = false
        #expect(!pane.homePage.isActive, "the window went away: Home stops")
        pane.isWindowVisible = true
        #expect(pane.homePage.isActive)
    }

    /// concurrency-perf-3: an open Settings window rebuilt its facts on every report.
    @Test func settingsFactsIgnoreTheReportsAges() async throws {
        let f = try AccountStoreFixture("codd-rv-settings")
        await f.store.start()
        let coordinator = SettingsCoordinator(environment: .init(preferences: .inMemory(), accounts: f.store, cswap: f.store,
                                                                 lastStatusLineAt: { [unowned f] in f.store.statusLine.lastAt }))
        coordinator.setVisible(true)
        let fiveReset = f.clock.addingTimeInterval(3600)
        f.store.ingest(f.report(key: "default", five: 10, fiveReset: fiveReset, week: 10, weekReset: f.state.weeklyReset(3)))
        try await Task.sleep(for: .milliseconds(300))
        let before = coordinator.infoBuilds
        for _ in 0..<5 {
            f.clock = f.clock.addingTimeInterval(1)
            f.store.ingest(f.report(key: "default", five: 10, fiveReset: fiveReset, week: 10, weekReset: f.state.weeklyReset(3)))
            try await Task.sleep(for: .milliseconds(40))
        }
        #expect(coordinator.infoBuilds == before, "ages show at the 5 s tick, not per report")
        f.clock = f.clock.addingTimeInterval(1)
        f.store.ingest(f.report(key: "default", five: 50, fiveReset: fiveReset, week: 10, weekReset: f.state.weeklyReset(3)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(coordinator.infoBuilds > before, "a new number still rebuilds")
        coordinator.setVisible(false)
    }

    /// spec-fidelity-3: the USAGE note kept the width of its first, shorter text and ended in `…`.
    @Test func aSectionHeadLaysOutAgainWhenItsNoteGrows() {
        let head = HomeSectionHeadView(title: "Usage", zh: "剩餘")
        let note = HomeTextView()
        head.accessories = [note]
        head.frame = CGRect(x: 0, y: 0, width: 700, height: HomeSectionHeadView.height)
        note.text = TextStyle.mono(11, Palette.dim).string(HomeModel.usageSortNote)
        head.layoutSubtreeIfNeeded()
        let narrow = note.frame.width
        note.text = TextStyle.mono(11, Palette.dim).string(HomeModel.usageSortNote + " · cswap 0.26.0")
        #expect(head.needsLayout, "a new text asks the frame-based owner to lay out again")
        head.layoutSubtreeIfNeeded()
        #expect(note.frame.width > narrow)
        #expect(note.frame.width >= note.intrinsicContentSize.width - 0.5, "the whole note fits")
    }

    /// spec-fidelity-1: the ⌘N sheet's `.ns-quota` line under the account select.
    @Test func newSessionQuotaLineFollowsThePick() async throws {
        let accounts = MockAccountStore()
        let follow = try #require(NewSessionQuota.make(option: NewSessionAccountOption.followID, accounts: accounts))
        let active = try #require(accounts.activeAccount)
        #expect(follow.name == active.displayName)
        #expect(follow.text == "\(active.displayName) 5h \(active.fiveHour.valueText) 1w \(active.week.valueText) 剩餘")
        let other = try #require(accounts.accounts.first { $0.id != active.id })
        #expect(NewSessionQuota.make(option: other.id, accounts: accounts)?.name == other.displayName)
        #expect(NewSessionQuota.make(option: "nope", accounts: accounts) == nil)
        let line = NewSessionQuotaLineView()
        #expect(line.isHidden)
        line.quota = follow
        #expect(!line.isHidden && line.accessibilityLabel() == follow.text)
    }
}
