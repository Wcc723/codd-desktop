import CoddCore
import CoddHooks
import Foundation
import Testing
@testable import CODD

/// M3 I1b (wiring): the real account store on a fake cswap state (D1–D7, D31), status-line
/// attribution (D6), switching with progress, failure and UNDO (D5). Temp folders and a scripted
/// cswap only: the real cswap, `~/.claude-swap-backup` and Anthropic are never touched.

// MARK: - Accounts from cswap's state

@MainActor
@Suite("Accounts from cswap's state (I1b)")
struct CswapAccountStoreTests {
    @Test func fakeStateGivesR7OrderActivePlansAndProfiles() async throws {
        let f = try AccountStoreFixture()
        let store = f.store!
        await store.start()
        #expect(store.availability == .ready)
        #expect(store.sourceLabel == "cswap 0.26.0")
        #expect(store.accounts.map(\.id) == ["2", "3", "1"], "R7: weekly reset, soonest first")
        #expect(store.activeAccountID == "3")
        #expect(store.accounts.map(\.plan) == ["MAX 20x", "MAX 20x", "MAX 20x"])
        #expect(store.accounts.map(\.alias) == ["藍鵲", "工作", "個人"])
        let two = try #require(store.account("2"))
        #expect(two.fiveHour.remainingPercent == 98 && two.week.remainingPercent == 46)
        #expect(two.source == "cswap cache" && two.hasSessionProfile && !two.profileStale)
        #expect(two.scoped.map(\.name) == ["Fable"])
        let one = try #require(store.account("1"))
        #expect(!one.fiveHour.started, "5h not started yet")
        #expect(!one.hasSessionProfile)
        #expect(store.account("3")?.week.remainingPercent == 15)
        // D1: nothing but `--version` at launch (no `cswap list`, which fetches usage).
        #expect(f.runner.calls == [["--version"]])
        #expect(f.logs.values.contains { $0.hasPrefix("exec cswap path=") && $0.hasSuffix("sub=--version") })
        m3ExpectNoAccountLeak(f.exposedText, "the store's log and dump")
    }

    @Test func aTestDataRootWithoutFlagsHasNoCswapAndRunsNothing() async throws {
        let f = try AccountStoreFixture(debug: false)
        let store = f.store!
        await store.start()
        #expect(store.availability == .noCswap)
        #expect(store.accounts.isEmpty)
        #expect(f.runner.calls.isEmpty, "D3: no cswap path on a non-standard root")
        #expect(store.availability.note == AccountAvailability.noCswapNote)
        // D4: the global login's status-line numbers make the pseudo account.
        store.ingest(f.report(key: "default", five: 20, fiveReset: f.clock.addingTimeInterval(3600), week: 40,
                              weekReset: f.clock.addingTimeInterval(86_400)))
        #expect(store.accounts.map(\.id) == ["default"])
        let pseudo = try #require(store.accounts.first)
        #expect(pseudo.isPseudo && pseudo.slot == "—" && pseudo.alias == "目前登入")
        #expect(pseudo.fiveHour.remainingPercent == 80 && pseudo.source == "statusline")
        #expect(store.activeAccountID == "default")
        // M3 review: the pseudo row already has numbers, so the note no longer says they will appear.
        if case .pseudo(let note) = store.availability { #expect(note == AccountAvailability.pseudoNote) } else {
            Issue.record("availability is pseudo")
        }
        if case .refused = await store.switchTo("default", reason: .user) {} else { Issue.record("the pseudo account is no switch target") }
        #expect(store.newSessionAccountOptions.count == 1, "no pin without cswap accounts")
    }

    @Test func listFallbackRunsOnlyOnAnExplicitRefreshOncePerTenMinutes() async throws {
        let list = #"""
        {"schemaVersion":1,"activeAccountNumber":3,"accounts":[
         {"number":2,"email":"north@example.com","alias":"藍鵲","organizationName":"north@example.com's Organization","active":false,
          "usageStatus":"ok","usage":{"five_hour":{"pct":2,"resetsAt":"2026-12-01T00:00:00+00:00"},"seven_day":{"pct":54}},
          "usageFetchedAt":"2026-10-17T00:00:00+00:00"},
         {"number":3,"email":"work@example.com","alias":"工作","organizationName":"work@example.com's Organization","active":true,
          "usageStatus":"ok","usage":{"five_hour":{"pct":9},"seven_day":{"pct":85}}}],
         "duplicateAccountWarnings":[{"email":"work@example.com","numbers":[3,5]}]}
        """#
        var script = FakeCswapRunner.Script()
        script.listJSON = list
        let f = try AccountStoreFixture(unsupported: true, script: script)
        let store = f.store!
        await store.start()
        guard case .unreadable(let reason) = store.availability else {
            Issue.record("unsupported sequence.json is unreadable, got \(store.availability)")
            return
        }
        #expect(store.availability.note == "// 讀不到 cswap 狀態：\(reason) · 按 ↻ 立即更新 改用 cswap list（會查詢一次用量）")
        #expect(f.runner.calls == [["--version"]], "never at launch")
        await store.refresh(userInitiated: false)
        #expect(!f.runner.calls.contains(["list", "--json"]), "never on a timer or a plain re-read")
        await store.refresh(userInitiated: true)
        #expect(f.runner.calls.filter { $0 == ["list", "--json"] }.count == 1)
        #expect(store.availability == .ready && store.usingListFallback)
        #expect(store.accounts.map(\.id).sorted() == ["2", "3"])
        #expect(store.activeAccountID == "3")
        f.clock = f.clock.addingTimeInterval(120)
        await store.refresh(userInitiated: true)
        #expect(f.runner.calls.filter { $0 == ["list", "--json"] }.count == 1, "at most once per 10 minutes")
        #expect(f.logs.values.contains("cswap list fallback"))
        m3ExpectNoAccountLeak(f.exposedText, "the fallback's log and dump (organizationName, warnings)")
        if case .needsProfile = store.pinResolution(2) { Issue.record("the list result has no profiles to pin") }
        #expect(store.pinResolution(2) == .notReady)
    }

    @Test func quotaBookIsSavedPrivatelyAndLoadedAgain() async throws {
        let f = try AccountStoreFixture(quota: true)
        let store = f.store!
        await store.start()
        store.ingest(f.report(key: "default", five: 9, fiveReset: f.clock.addingTimeInterval(9000), week: 85,
                              weekReset: f.state.weeklyReset(3)))
        store.lastAutoSwitchAt = f.clock
        store.flush()
        let url = URL(fileURLWithPath: f.folder + "/data/quota.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        let text = try String(contentsOf: url, encoding: .utf8)
        m3ExpectNoAccountLeak(text, "quota.json")
        let book = QuotaStore(url: url).load()
        #expect(book.entry(.number(3))?.weekly?.source == .statusline)
        #expect(book.entry(.number(2))?.weekly?.source == .cswap)
        #expect(book.lastAutoSwitchAt != nil, "D37")
    }

    @Test func staleProfileDisablesTheOptionAndActiveIsListedDisabled() async throws {
        let f = try AccountStoreFixture(profiles: [1, 2], stale: [1])
        let store = f.store!
        await store.start()
        let options = store.newSessionAccountOptions
        #expect(options.map(\.id) == ["follow", "3", "2", "1"])
        #expect(options[0].title == "跟隨全域登入（#3 工作）" && options[0].enabled)
        #expect(options[1].title == "固定 #3 工作" && !options[1].enabled)
        #expect(options[1].hint == "#3 工作 是目前的全域登入；cswap 不為它建立獨立設定目錄")
        #expect(options[2].title == "固定 #2 藍鵲（cswap run）" && options[2].enabled)
        #expect(options[3].title == "固定 #1 個人（cswap run）" && !options[3].enabled)
        #expect(options[3].hint == "#1 的登入資料需要更新：先在終端機執行一次 cswap run 1")
        #expect(store.pinResolution(2) == .usable(path: f.state.profile(2).path))
        #expect(store.pinResolution(1) == .needsProfile)
        #expect(store.pinResolution(3) == .active)
        #expect(store.pinResolution(3, relaunch: true) == .needsProfile, "no profile for #3 in the fixture")
        #expect(store.account(forConfigDir: f.state.profile(2).path) == 2)
        #expect(store.profileRegistryDirectories.map(\.lastPathComponent) == ["sessions", "sessions"])
        m3ExpectNoAccountLeak(f.exposedText, "the options and the dump")
    }

    @Test func noProfileHintNamesCswapRun() {
        let account = AccountVM(id: "1", slot: "#1", alias: "個人", plan: nil, fiveHour: .unknown, week: .unknown, source: "",
                                sourceAt: nil, sessionCount: 0)
        let options = AccountPinOptions.build(accounts: [account], activeID: nil)
        #expect(options.map(\.title) == ["跟隨全域登入", "固定 #1 個人（cswap run）"])
        #expect(options[1].hint == "先在終端機執行一次 cswap run 1" && !options[1].enabled)
    }
}

// MARK: - Attribution (D6)

@MainActor
@Suite("Status-line attribution (I1b)")
struct StatusLineAttributionTests {
    @Test func reportsGoToTheirAccounts() async throws {
        let f = try AccountStoreFixture()
        let store = f.store!
        await store.start()
        // default → the active #3.
        store.ingest(f.report(key: "default", five: 9, fiveReset: f.clock.addingTimeInterval(10_000), week: 85,
                              weekReset: f.state.weeklyReset(3)))
        let three = try #require(store.account("3"))
        #expect(three.source == "statusline" && three.fiveHour.remainingPercent == 91 && three.week.remainingPercent == 15)
        // cswap-2 → #2.
        f.clock = f.clock.addingTimeInterval(1)
        store.ingest(f.report(key: "cswap-2", five: 50, fiveReset: f.clock.addingTimeInterval(5000), week: 60,
                              weekReset: f.state.weeklyReset(2)))
        #expect(store.account("2")?.fiveHour.remainingPercent == 50)
        #expect(store.account("2")?.source == "statusline")
        #expect(store.statusLine.accepted == 2 && store.statusLine.dropped == 0)
        #expect(store.statusLine.lastKey == "cswap-2" && store.statusLine.lastAccount == "2")
        // An invalid key, a key of an unknown account, a report without numbers.
        store.ingest(f.report(key: "invalid", five: 1))
        store.ingest(f.report(key: "cswap-9", five: 1))
        store.ingest(f.report(key: "default"))
        #expect(store.statusLine.accepted == 5 && store.statusLine.dropped == 2)
        m3ExpectNoAccountLeak(f.exposedText, "the attribution logs")
    }

    @Test func insideTheSwitchGraceAMismatchedDefaultReportIsDropped() async throws {
        let f = try AccountStoreFixture()
        let store = f.store!
        await store.start()
        #expect(await store.switchTo("2", reason: .user) == .switched(from: "3", to: "2", following: 0))
        #expect(store.activeAccountID == "2")
        f.clock = f.clock.addingTimeInterval(10)
        // A claude still on #3's credentials reports #3's reset: it goes to #3 (the `from`).
        store.ingest(f.report(key: "default", five: 10, week: 86, weekReset: f.state.weeklyReset(3)))
        #expect(store.account("3")?.week.remainingPercent == 14)
        // A reset matching neither: dropped (better no number than a wrong one).
        store.ingest(f.report(key: "default", five: 10, week: 50, weekReset: f.clock.addingTimeInterval(6 * 86_400)))
        #expect(store.statusLine.dropped == 1)
        // After the grace: default → the new active #2.
        f.clock = f.clock.addingTimeInterval(QuotaAttribution.switchGrace + 1)
        store.ingest(f.report(key: "default", five: 40, week: 47, weekReset: f.state.weeklyReset(2)))
        #expect(store.account("2")?.fiveHour.remainingPercent == 60)
    }

    @Test func aCfgKeyOfAKnownProfileGoesToItsAccount() async throws {
        // A state root CODD's CLI does not recognise as cswap's: the profile path hashes to cfg-….
        let f = try AccountStoreFixture(rootName: "cswapstate")
        let store = f.store!
        await store.start()
        let key = AccountKey.from(claudeConfigDir: f.state.profile(2).path, home: f.folder + "/home").rawValue
        #expect(key.hasPrefix("cfg-"))
        store.ingest(f.report(key: key, five: 30, week: 55, weekReset: f.state.weeklyReset(2)))
        #expect(store.account("2")?.fiveHour.remainingPercent == 70)
        // Any other cfg key: dropped.
        store.ingest(f.report(key: "cfg-0123456789abcdef", five: 30))
        #expect(store.statusLine.dropped == 1)
    }

    @Test func aDefaultReportMatchingAnotherAccountReReadsTheState() async throws {
        let f = try AccountStoreFixture()
        let store = f.store!
        await store.start()
        // The global login changed outside CODD and cswap's files already say so, but CODD has
        // not read them yet; a report with #2's weekly reset arrives first.
        try f.state.setLogin(2)
        f.clock = f.clock.addingTimeInterval(600)
        store.ingest(f.report(key: "default", five: 20, week: 54, weekReset: f.state.weeklyReset(2)))
        #expect(store.account("2")?.source == "statusline", "it went to #2, not the active #3")
        #expect(f.logs.values.contains { $0.contains("suggests a login change") })
        await m3Eventually("the re-read") { store.activeAccountID == "2" }
        #expect(f.logs.values.contains { $0.contains("accounts active changed #3 -> #2 (detected)") })
    }
}

// MARK: - Switching (D5)

@MainActor
@Suite("Account switching (I1b)")
struct AccountSwitchingTests {
    @Test func switchSucceedsAndUndoSwitchesBackThroughTheToast() async throws {
        let f = try AccountStoreFixture()
        let store = f.store!
        await store.start()
        let toasts = Recorder<(String, (@MainActor () -> Void)?)>()
        let outcome = await AccountSwitching.run("2", in: store) { text, undo in toasts.append((text, undo)) }.value
        #expect(outcome == .switched(from: "3", to: "2", following: 0))
        #expect(store.activeAccountID == "2" && store.switchState == .idle)
        #expect(toasts.values.first?.0 == "已切換到 #2 藍鵲 · 0 個 session 約 30 秒內套用")
        let undo = try #require(toasts.values.first?.1, "the toast offers UNDO")
        undo()
        await m3Eventually("switched back") { store.activeAccountID == "3" && !store.isSwitching }
        #expect(f.runner.calls.filter { $0.first == "switch" } == [["switch", "2", "--json"], ["switch", "3", "--json"]])
        #expect(toasts.values.count == 2 && toasts.values[1].1 == nil, "UNDO's own toast has no UNDO")
        #expect(store.lastSwitch?.reason == .undo && store.lastSwitch?.outcome == "switched")
        m3ExpectNoAccountLeak(f.exposedText + toasts.values.map(\.0).joined(), "switch logs, dump and toasts")
    }

    @Test func lockTimeoutsAreRetriedWithProgress() async throws {
        var script = FakeCswapRunner.Script()
        script.lockFailures = 2
        script.switchDelay = .milliseconds(150)
        let f = try AccountStoreFixture(script: script)
        let store = f.store!
        await store.start()
        let task = Task { await store.switchTo("2", reason: .user) }
        var attempts = Set<Int>()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if case .switching(let to, _, let attempt, _) = store.switchState, to == "2" { attempts.insert(attempt) }
            if !store.isSwitching, !attempts.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let outcome = await task.value
        #expect(outcome == .switched(from: "3", to: "2", following: 0))
        #expect(attempts == [1, 2, 3], "progress （1/3） … （3/3）")
        #expect(f.runner.calls.filter { $0.first == "switch" }.count == 3)
    }

    @Test func failureIsRedactedAndOnlyOneSwitchRunsAtATime() async throws {
        var script = FakeCswapRunner.Script()
        script.failSwitch = true
        script.switchDelay = .milliseconds(100)
        let f = try AccountStoreFixture(script: script)
        let store = f.store!
        await store.start()
        let first = Task { await store.switchTo("2", reason: .user) }
        await m3Eventually("switching") { store.isSwitching }
        if case .refused = await store.switchTo("1", reason: .user) {} else { Issue.record("a second switch is refused") }
        let outcome = await first.value
        guard case .failed(let message) = outcome else {
            Issue.record("the switch fails, got \(outcome)")
            return
        }
        m3ExpectNoAccountLeak(message, "the failure message")
        #expect(message.contains("•••@•••"))
        #expect(AccountSwitching.failureText(message).hasPrefix("[ERROR] 切換失敗："))
        if case .failed(let shown, _) = store.switchState { #expect(shown == message) } else { Issue.record("failed state") }
        #expect(store.activeAccountID == "3")
        m3ExpectNoAccountLeak(f.exposedText, "the failure's log and dump")
    }

    @Test func unsupportedCswapKeepsTheAccountsUnavailable() async throws {
        var script = FakeCswapRunner.Script()
        script.version = "cswap 0.25.3"
        let f = try AccountStoreFixture(script: script)
        let store = f.store!
        await store.start()
        #expect(store.availability == .unsupported(version: "0.25.3"))
        #expect(store.availability.note == "// cswap 0.25.3 太舊，需要 ≥ 0.26")
        #expect(store.accounts.isEmpty)
        if case .refused = await store.switchTo("2", reason: .user) {} else { Issue.record("no switch without a supported cswap") }
        // An explicit ↻ looks for cswap again (the user updated it meanwhile).
        f.runner.setScript { $0.version = "cswap 0.26.1" }
        await store.refresh(userInitiated: true)
        #expect(store.availability == .ready && store.sourceLabel == "cswap 0.26.1")
        #expect(store.accounts.map(\.id) == ["2", "3", "1"])
    }
}
