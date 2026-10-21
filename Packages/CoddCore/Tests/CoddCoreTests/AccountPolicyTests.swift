import Foundation
import Testing
@testable import CoddCore

/// Helpers: build accounts relative to `referenceNow` (2026-10-15 10:42 +08:00).
private func hours(_ h: Double) -> Date { referenceNow.addingTimeInterval(h * 3600) }

private func account(
    _ n: Int, active: Bool = false, five: Double?, fiveReset: Date? = hours(3),
    week: Double?, weekReset: Date?, status: CswapUsageStatus = .ok, disabled: Bool = false
) -> Account {
    Account(number: n, alias: "a\(n)", isActive: active, isDisabled: disabled, usageStatus: status,
            fiveHour: five.map { QuotaWindow(usedPercent: $0, resetsAt: fiveReset) },
            weekly: week.map { QuotaWindow(usedPercent: $0, resetsAt: weekReset) })
}

/// SPEC §5 / §9 canonical accounts.
private var canonical: [Account] {
    get throws {
        let list = try JSONDecoder().decode(CswapListResponse.self, from: Fixtures.data("cswap", "list-canonical.json"))
        return Account.accounts(from: list)
    }
}

@Suite("Quota windows")
struct QuotaWindowTests {
    @Test func remainingIsHundredMinusUsedClampedAndRounded() {
        #expect(QuotaMath.remaining(usedPercent: 9) == 91)
        #expect(QuotaMath.remaining(usedPercent: 85.04) == 15)
        #expect(QuotaMath.remaining(usedPercent: 97.94) == 2.1)
        #expect(QuotaMath.remaining(usedPercent: 97.95) == 2) // 2.0499… rounds down, as Math.round does
        #expect(QuotaMath.remaining(usedPercent: 130) == 0)
        #expect(QuotaMath.remaining(usedPercent: -4) == 100)
    }

    @Test func resetPassedRollsTheWindowOver() {
        let w = QuotaWindow(usedPercent: 99, resetsAt: hours(-1))
        let s = w.status(at: referenceNow)
        #expect(s.resetPassed)
        #expect(s.remainingPercent == 100)
        #expect(s.usedPercent == 0)
        #expect(s.upcomingReset == nil)
    }

    @Test func notStartedFiveHourWindow() {
        let s = QuotaWindow(usedPercent: 0, resetsAt: nil).status(at: referenceNow)
        #expect(s.notStarted)
        #expect(s.remainingPercent == 100)
        #expect(!QuotaWindow(usedPercent: 3, resetsAt: nil).status(at: referenceNow).notStarted)
    }

    @Test func canonicalAccountsFromCswap() throws {
        let accounts = try canonical
        let a3 = try #require(accounts.first { $0.number == 3 })
        #expect(a3.displayName == "#3 工作")
        #expect(a3.isActive)
        #expect(a3.fiveHour?.status(at: referenceNow).remainingPercent == 91)
        #expect(a3.weekly?.status(at: referenceNow).remainingPercent == 15)
        #expect(a3.scoped.map(\.name) == ["Fable"])
        let a1 = try #require(accounts.first { $0.number == 1 })
        #expect(a1.usageIsLastGood)
        #expect(a1.fiveHour?.status(at: referenceNow).notStarted == true)
        #expect(Account(number: 9).displayName == "#9")
    }

    @Test func activeFlagFallsBackToActiveAccountNumber() {
        let list = CswapListResponse(activeAccountNumber: 2, accounts: [CswapAccount(number: 1), CswapAccount(number: 2)])
        #expect(Account.accounts(from: list).map(\.isActive) == [false, true])
    }
}

@Suite("Account ordering (R7)")
struct AccountOrderingTests {
    @Test func canonicalOrderIsSoonestWeeklyResetFirst() throws {
        let sorted = AccountOrdering.sorted(try canonical, now: referenceNow)
        #expect(sorted.map(\.number) == [2, 3, 1]) // SPEC §9 R7 canonical order
        #expect(sorted[1].isActive)                // active keeps its sorted place
    }

    @Test func activeIsNotPinnedToTop() {
        let a = [account(1, active: true, five: 0, week: 10, weekReset: hours(90)),
                 account(2, five: 0, week: 10, weekReset: hours(10))]
        #expect(AccountOrdering.sorted(a, now: referenceNow).map(\.number) == [2, 1])
    }

    @Test func unknownResetsSortLastThenByNumber() {
        let a = [
            account(5, five: 0, week: nil, weekReset: nil),             // no weekly window
            account(4, five: 0, week: 30, weekReset: nil),               // no reset time
            account(3, five: 0, week: 90, weekReset: hours(-2)),         // reset passed
            account(2, five: nil, week: nil, weekReset: nil),            // no usage at all
            account(1, five: 0, week: 20, weekReset: hours(48)),
            account(6, five: 0, week: 20, weekReset: hours(24)),
        ]
        #expect(AccountOrdering.sorted(a, now: referenceNow).map(\.number) == [6, 1, 2, 3, 4, 5])
    }

    @Test func tiesBreakByNumber() {
        let a = [account(3, five: 0, week: 1, weekReset: hours(5)), account(1, five: 0, week: 1, weekReset: hours(5))]
        #expect(AccountOrdering.sorted(a, now: referenceNow).map(\.number) == [1, 3])
    }
}

@Suite("Auto-switch policy (R8)")
struct AutoSwitchPolicyTests {
    let on = AutoSwitchSettings(isEnabled: true)

    func eval(_ accounts: [Account], _ settings: AutoSwitchSettings? = nil, last: Date? = nil) -> AutoSwitchDecision {
        AutoSwitchPolicy.evaluate(accounts: accounts, settings: settings ?? on, now: referenceNow, lastAutoSwitchAt: last)
    }

    @Test func defaultsMatchSpec() {
        let d = AutoSwitchSettings.default
        #expect(!d.isEnabled)
        #expect(d.thresholdPercent == 2)
        #expect(d.checkFiveHour && d.checkWeekly)
        #expect(d.cooldownSeconds == 300)
        #expect(AutoSwitchSettings(thresholdPercent: 50).effectiveThreshold == 20)
        #expect(AutoSwitchSettings(thresholdPercent: 0).effectiveThreshold == 1)
    }

    @Test func offByDefault() throws {
        #expect(AutoSwitchPolicy.evaluate(accounts: try canonical, settings: .default, now: referenceNow, lastAutoSwitchAt: nil) == .disabled)
    }

    @Test func canonicalDataNeedsNoSwitch() throws {
        #expect(eval(try canonical) == .activeAboveThreshold)
    }

    @Test func weeklyTriggerPicksFirstEligibleInR7Order() {
        let a = [
            account(3, active: true, five: 9, week: 98, weekReset: hours(73)),
            account(2, five: 2, week: 54, weekReset: hours(36)),
            account(1, five: 0, fiveReset: nil, week: 0, weekReset: hours(105)),
        ]
        #expect(eval(a) == .switchTo(accountNumber: 2, trigger: AutoSwitchTrigger(accountNumber: 3, window: .weekly, remainingPercent: 2)))
    }

    @Test func fiveHourTrigger() {
        let a = [account(1, active: true, five: 99, week: 10, weekReset: hours(50)),
                 account(2, five: 0, week: 0, weekReset: hours(60))]
        #expect(eval(a) == .switchTo(accountNumber: 2, trigger: AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)))
    }

    @Test func bothCrossedReportsTheLowerWindow() {
        let a = [account(1, active: true, five: 98.5, week: 99.5, weekReset: hours(50)),
                 account(2, five: 0, week: 0, weekReset: hours(60))]
        guard case .switchTo(_, let t) = eval(a) else { Issue.record("expected switch"); return }
        #expect(t.window == .weekly)
        #expect(t.remainingPercent == 0.5)
    }

    @Test func thresholdIsInclusiveForTriggerAndExclusiveForTarget() {
        let active = account(1, active: true, five: 0, week: 98, weekReset: hours(50)) // exactly 2 % left
        let borderline = account(2, five: 98, week: 0, weekReset: hours(10))          // 5h exactly 2 %
        let good = account(3, five: 97.9, week: 0, weekReset: hours(20))              // 2.1 %
        #expect(eval([active, borderline, good]) == .switchTo(accountNumber: 3, trigger: AutoSwitchTrigger(accountNumber: 1, window: .weekly, remainingPercent: 2)))
    }

    @Test func uncheckedWindowsDoNotTrigger() {
        let a = [account(1, active: true, five: 100, week: 10, weekReset: hours(50)),
                 account(2, five: 0, week: 0, weekReset: hours(60))]
        var s = on
        s.checkFiveHour = false
        #expect(eval(a, s) == .activeAboveThreshold)
        s.checkWeekly = false
        #expect(eval(a, s) == .activeAboveThreshold)
    }

    @Test func targetNeedsBothWindowsEvenIfOneIsUnchecked() {
        var s = on
        s.checkFiveHour = false
        let a = [account(1, active: true, five: 0, week: 99, weekReset: hours(50)),
                 account(2, five: 99, week: 0, weekReset: hours(10)),  // 5h exhausted → not eligible
                 account(3, five: 10, week: 10, weekReset: hours(30))]
        #expect(eval(a, s) == .switchTo(accountNumber: 3, trigger: AutoSwitchTrigger(accountNumber: 1, window: .weekly, remainingPercent: 1)))
    }

    @Test func fiveHourNotStartedTargetIsEligible() {
        let a = [account(1, active: true, five: 99, week: 50, weekReset: hours(50)),
                 account(2, five: 0, fiveReset: nil, week: 30, weekReset: hours(70))]
        #expect(eval(a) == .switchTo(accountNumber: 2, trigger: AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)))
    }

    @Test func missingWindowsMakeTargetsIneligible() {
        let a = [account(1, active: true, five: 99, week: 50, weekReset: hours(50)),
                 account(2, five: nil, week: 0, weekReset: hours(10)),
                 account(3, five: 0, week: nil, weekReset: nil),
                 account(4, five: nil, week: nil, weekReset: nil)]
        #expect(eval(a) == .noEligibleTarget(trigger: AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)))
    }

    @Test func activeWithMissingWindows() {
        let a = [account(1, active: true, five: nil, week: nil, weekReset: nil), account(2, five: 0, week: 0, weekReset: hours(5))]
        #expect(eval(a) == .activeUsageUnknown(accountNumber: 1))
        // Only the 5h window is known and fine; the weekly one is unknown → no trigger.
        let b = [account(1, active: true, five: 10, week: nil, weekReset: nil), account(2, five: 0, week: 0, weekReset: hours(5))]
        #expect(eval(b) == .activeAboveThreshold)
    }

    @Test func resetPassedOnActiveMeansNoTrigger() {
        let a = [account(1, active: true, five: 100, fiveReset: hours(-0.1), week: 100, weekReset: hours(-1)),
                 account(2, five: 0, week: 0, weekReset: hours(5))]
        #expect(eval(a) == .activeAboveThreshold)
    }

    @Test func resetPassedTargetIsEligibleButSortsLast() {
        let a = [account(1, active: true, five: 99, week: 50, weekReset: hours(50)),
                 account(2, five: 100, fiveReset: hours(-1), week: 100, weekReset: hours(-2)), // both rolled over
                 account(3, five: 99, week: 10, weekReset: hours(20))]                          // 5h exhausted
        #expect(eval(a) == .switchTo(accountNumber: 2, trigger: AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)))
    }

    @Test func disabledAndUnusableAccountsAreNeverTargets() {
        let a = [account(1, active: true, five: 99, week: 50, weekReset: hours(50)),
                 account(2, five: 0, week: 0, weekReset: hours(5), disabled: true),
                 account(3, five: 0, week: 0, weekReset: hours(6), status: .reloginRequired),
                 account(4, five: 0, week: 0, weekReset: hours(7), status: .noCredentials),
                 account(5, five: 0, week: 0, weekReset: hours(8), status: .unavailable)]
        #expect(eval(a) == .switchTo(accountNumber: 5, trigger: AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)))
    }

    @Test func noActiveAccount() {
        #expect(eval([account(1, five: 99, week: 99, weekReset: hours(1))]) == .noActiveAccount)
        #expect(eval([]) == .noActiveAccount)
    }

    @Test func cooldown() {
        let a = [account(1, active: true, five: 99, week: 50, weekReset: hours(50)), account(2, five: 0, week: 0, weekReset: hours(5))]
        let trigger = AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)
        let recent = referenceNow.addingTimeInterval(-299)
        #expect(eval(a, last: recent) == .coolingDown(until: recent.addingTimeInterval(300), trigger: trigger))
        #expect(eval(a, last: referenceNow.addingTimeInterval(-300)) == .switchTo(accountNumber: 2, trigger: trigger))
        // Cooldown only matters when a switch is due.
        let healthy = [account(1, active: true, five: 10, week: 10, weekReset: hours(50))]
        #expect(eval(healthy, last: recent) == .activeAboveThreshold)
    }

    @Test func customThreshold() {
        var s = on
        s.thresholdPercent = 10
        let a = [account(1, active: true, five: 91, week: 50, weekReset: hours(50)),
                 account(2, five: 89.5, week: 0, weekReset: hours(5)),
                 account(3, five: 80, week: 80, weekReset: hours(6))]
        #expect(eval(a, s) == .switchTo(accountNumber: 2, trigger: AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 9)))
    }

    @Test func previewMatchesSpecExample() throws {
        var s = on
        s.thresholdPercent = 2
        let rows = AutoSwitchPolicy.preview(accounts: try canonical, settings: s, now: referenceNow)
        #expect(rows.map(\.accountNumber) == [2, 3, 1])
        let r3 = try #require(rows.first { $0.accountNumber == 3 })
        #expect(r3.isActive)
        #expect(r3.lowerWindow == .weekly)
        #expect(r3.lowerRemainingPercent == 15)
        #expect(r3.marginPercent == 13) // 「1w 15% · 距切換 13%」
        #expect(!r3.isEligibleTarget)
        #expect(rows.first { $0.isNextTarget }?.accountNumber == 2) // 「下一個：#2 藍鵲」
        let r1 = try #require(rows.first { $0.accountNumber == 1 })
        #expect(r1.marginPercent == 98)
    }
}

@Suite("Auto-switch controller")
struct AutoSwitchControllerTests {
    let on = AutoSwitchSettings(isEnabled: true)
    let low = [account(1, active: true, five: 99, week: 50, weekReset: hours(50)), account(2, five: 0, week: 0, weekReset: hours(5))]
    let allLow = [account(1, active: true, five: 99, week: 50, weekReset: hours(50)), account(2, five: 99, week: 0, weekReset: hours(5))]

    @Test func switchStartsCooldown() {
        var c = AutoSwitchController()
        let t = AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)
        #expect(c.step(accounts: low, settings: on, now: referenceNow) == .switchAccount(to: 2, trigger: t))
        #expect(c.lastAutoSwitchAt == referenceNow)
        #expect(c.step(accounts: low, settings: on, now: referenceNow.addingTimeInterval(60)) == .none)
        #expect(c.step(accounts: low, settings: on, now: referenceNow.addingTimeInterval(301)) == .switchAccount(to: 2, trigger: t))
    }

    @Test func failedSwitchUndoesTheCooldown() {
        let earlier = referenceNow.addingTimeInterval(-3600)
        var c = AutoSwitchController(lastAutoSwitchAt: earlier)
        let t = AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)
        #expect(c.step(accounts: low, settings: on, now: referenceNow) == .switchAccount(to: 2, trigger: t))
        c.switchFailed() // e.g. ClaudeCodeLockTimeout
        #expect(c.lastAutoSwitchAt == earlier)
        #expect(c.step(accounts: low, settings: on, now: referenceNow.addingTimeInterval(60)) == .switchAccount(to: 2, trigger: t))
        // A successful switch keeps its cooldown.
        #expect(c.step(accounts: low, settings: on, now: referenceNow.addingTimeInterval(120)) == .none)
    }

    @Test func noTargetNotifiesOncePerEpisode() {
        var c = AutoSwitchController()
        let t = AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)
        #expect(c.step(accounts: allLow, settings: on, now: referenceNow) == .notifyNoEligibleTarget(trigger: t))
        #expect(c.step(accounts: allLow, settings: on, now: referenceNow.addingTimeInterval(60)) == .none)
        let healthy = [account(1, active: true, five: 10, week: 10, weekReset: hours(50))]
        #expect(c.step(accounts: healthy, settings: on, now: referenceNow.addingTimeInterval(120)) == .none)
        #expect(c.step(accounts: allLow, settings: on, now: referenceNow.addingTimeInterval(180)) == .notifyNoEligibleTarget(trigger: t))
    }

    @Test func disabledDoesNothing() {
        var c = AutoSwitchController()
        #expect(c.step(accounts: low, settings: .default, now: referenceNow) == .none)
        #expect(c.lastAutoSwitchAt == nil)
    }

    /// M3 review (e2e-3): a `cswap switch` that keeps failing was retried on every tick forever.
    @Test func aSwitchThatKeepsFailingBacksOff() {
        var c = AutoSwitchController()
        let t = AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)
        func at(_ s: Double) -> Date { referenceNow.addingTimeInterval(s) }
        #expect(c.step(accounts: low, settings: on, now: at(0)) == .switchAccount(to: 2, trigger: t))
        #expect(c.switchFailed(at: at(1), cooldownSeconds: 300) == 1, "the first failure: tell the user")
        #expect(c.step(accounts: low, settings: on, now: at(30)) == .switchAccount(to: 2, trigger: t), "one quick retry")
        #expect(c.switchFailed(at: at(31), cooldownSeconds: 300) == 2)
        #expect(c.retryNotBefore == at(331))
        #expect(c.step(accounts: low, settings: on, now: at(60)) == .none)
        #expect(c.waitReason(for: .switchTo(accountNumber: 2, trigger: t), now: at(60)) == "retry-wait")
        #expect(c.step(accounts: low, settings: on, now: at(331)) == .switchAccount(to: 2, trigger: t))
        c.switchFailed(at: at(332), cooldownSeconds: 300)
        #expect(c.retryNotBefore == at(932), "doubled")
        #expect(AutoSwitchController.retryDelay(afterFailures: 1, cooldownSeconds: 300) == nil)
        #expect(AutoSwitchController.retryDelay(afterFailures: 2, cooldownSeconds: 10) == 60, "at least a minute")
        #expect(AutoSwitchController.retryDelay(afterFailures: 30, cooldownSeconds: 300) == 3600, "at most an hour")
        // A success ends the episode; so does the trigger clearing.
        #expect(c.step(accounts: low, settings: on, now: at(932)) == .switchAccount(to: 2, trigger: t))
        c.switchSucceeded()
        #expect(c.consecutiveFailures == 0 && c.retryNotBefore == nil)
        var d = AutoSwitchController()
        _ = d.step(accounts: low, settings: on, now: at(0))
        d.switchFailed(at: at(1), cooldownSeconds: 300)
        d.switchFailed(at: at(2), cooldownSeconds: 300)
        let healthy = [account(1, active: true, five: 10, week: 10, weekReset: hours(50))]
        _ = d.step(accounts: healthy, settings: on, now: at(3))
        #expect(d.consecutiveFailures == 0 && d.retryNotBefore == nil)
    }

    /// M3 review (correctness-4): UNDO of an automatic switch used to hold only until the
    /// cooldown ended, then the same switch ran again.
    @Test func undoHoldsTheAccountUntilItsWindowResets() {
        var c = AutoSwitchController()
        func at(_ s: Double) -> Date { referenceNow.addingTimeInterval(s) }
        let t = AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)
        #expect(c.step(accounts: low, settings: on, now: at(0)) == .switchAccount(to: 2, trigger: t))
        c.switchSucceeded()
        // UNDO back to #1 (still at 1 %): held until #1's 5h reset in 3 h.
        c.undoAutoSwitch(back: 1, until: hours(3), settings: on, now: at(40))
        let switchedTo2 = [account(1, five: 99, week: 50, weekReset: hours(50)), account(2, active: true, five: 0, week: 0, weekReset: hours(5))]
        #expect(c.step(accounts: switchedTo2, settings: on, now: at(41)) == .none, "the switch back is still running")
        #expect(c.step(accounts: low, settings: on, now: at(301)) == .none, "the cooldown ended: still held")
        #expect(c.step(accounts: low, settings: on, now: at(3600)) == .none)
        #expect(c.waitReason(for: .switchTo(accountNumber: 2, trigger: t), now: at(3600)) == "held-by-undo")
        #expect(c.step(accounts: low, settings: on, now: hours(3)) == .switchAccount(to: 2, trigger: t), "the window reset passed")
        // An edit of the rule ends the hold.
        var e = AutoSwitchController()
        e.undoAutoSwitch(back: 1, until: hours(3), settings: on, now: at(0))
        #expect(e.step(accounts: low, settings: on, now: at(10)) == .none)
        var edited = on
        edited.thresholdPercent = 3
        #expect(e.step(accounts: low, settings: edited, now: at(20)) == .switchAccount(to: 2, trigger: AutoSwitchTrigger(accountNumber: 1, window: .fiveHour, remainingPercent: 1)))
        // The user switching away from the held account (after it was back) ends it too.
        var u = AutoSwitchController()
        u.undoAutoSwitch(back: 1, until: hours(3), settings: on, now: at(0))
        _ = u.step(accounts: low, settings: on, now: at(5))
        _ = u.step(accounts: switchedTo2, settings: on, now: at(10))
        #expect(u.hold == nil)
        // A switch back that never lands stops holding after two minutes.
        var f = AutoSwitchController()
        f.undoAutoSwitch(back: 1, until: hours(3), settings: on, now: at(0))
        _ = f.step(accounts: switchedTo2, settings: on, now: at(121))
        #expect(f.hold == nil)
    }
}
