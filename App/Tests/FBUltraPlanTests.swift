import AppKit
import CoddCore
import CoddUI
import Foundation
import Testing
@testable import CODD

/// FB (2026-11): Anthropic's Ultra plan has no 5-hour limit, so Claude Code's status line and
/// cswap send the weekly window without `five_hour`. An account without one shows no 5h label,
/// bar, countdown or `未開始` anywhere: its per-model weekly window (`Fable`) takes the 5h place,
/// or 1w stands alone. The mock: #3 工作 MAX (5h), #2 藍鵲 ULTRA (Fable), #1 個人 ULTRA (1w only).
@MainActor
@Suite("Plans without a 5h window (FB Ultra)")
struct FBUltraPlanTests {
    func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    @Test func theAccountModelPutsTheScopedWindowInTheFiveHourPlace() throws {
        let accounts = MockAccountStore()
        let max = try #require(accounts.account("3")), north = try #require(accounts.account("2")), personal = try #require(accounts.account("1"))
        #expect(max.plan == "MAX" && north.plan == "ULTRA" && personal.plan == "ULTRA")
        #expect(max.fiveHourSlot == QuotaSlot(key: "5h", quota: max.fiveHour ?? .unknown, isFiveHour: true))
        #expect(north.fiveHour == nil && north.fiveHourSlot?.key == "Fable" && north.fiveHourSlot?.isFiveHour == false)
        #expect(personal.fiveHour == nil && personal.fiveHourSlot == nil)
        #expect(max.quotaSummary == "5h 剩 91% · 1w 剩 15%")
        #expect(north.quotaSummary == "Fable 剩 72% · 1w 剩 46%" && personal.quotaSummary == "1w 剩 100%")
        #expect(north.spokenQuota == "Fable 剩 72%，本週剩 46%" && personal.spokenQuota == "本週剩 100%")
        #expect(AppDelegate.accountMenuTitle(north) == "#2 藍鵲 · Fable 剩 72% · 1w 剩 46%")
        #expect(AppDelegate.accountMenuTitle(personal) == "#1 個人 · 1w 剩 100%")
    }

    @Test func accountRowsAndTheRailChipSayNoFiveHour() throws {
        let accounts = MockAccountStore()
        let clock = MockSessionStore(shiftClock: false).clock
        for variant in [AccountRowView.Variant.sidebar, .menuBar] {
            let north = AccountRowView(accountID: "2", store: accounts, clock: clock, variant: variant)
            let label = north.accessibilityLabel() ?? ""
            #expect(label.hasPrefix("切換到 #2 藍鵲，Fable 剩 72%，本週剩 46%，1w 重置 "), "\(label)")
            let personal = AccountRowView(accountID: "1", store: accounts, clock: clock, variant: variant)
            #expect(personal.accessibilityLabel()?.hasPrefix("切換到 #1 個人，本週剩 100%，1w 重置 ") == true)
            let max = AccountRowView(accountID: "3", store: accounts, clock: clock, variant: variant)
            #expect(max.accessibilityLabel()?.hasPrefix("目前帳號 #3 工作，5 小時剩 91%，本週剩 15%") == true)
        }
        let chip = RailAccountChip()
        chip.update(accounts.account("1"))
        #expect(chip.accessibilityLabel() == "目前帳號 #1 個人，本週剩 100%")
        chip.update(accounts.account("3"))
        #expect(chip.accessibilityLabel() == "目前帳號 #3 工作，5 小時剩 91%，本週剩 15%")
    }

    /// The expanded footer at the sidebar's minimum width: an unused `Fable` window (100 %) or a
    /// longer per-model name never runs its bar under the value; the 5h place's bars line up in
    /// every row (one key column for the list), the 1w-only row's bar too. A name too long for
    /// that (`Sonnet`) loses its own bar but not the Max row's 5h bar.
    @Test func aWideKeyNeverRunsTheBarUnderTheValue() throws {
        let accounts = MockAccountStore()
        let clock = MockSessionStore(shiftClock: false).clock
        let north = try #require(accounts.account("2"))
        for name in ["Fable", "Sonnet", "Opus"] {
            north.scoped = [ScopedQuota(name: name, remainingPercent: 100, resetsAt: north.week.resetsAt)]
            var firstBars: [CGFloat] = []
            for id in ["2", "3", "1"] {
                let row = AccountRowView(accountID: id, store: accounts, clock: clock, variant: .sidebar)
                row.frame = CGRect(x: 0, y: 0, width: Metrics.sidebarMinWidth - UIZoom.pt(24), height: row.intrinsicContentSize.height)
                let layouts = row.quotaLayouts
                for (key, layout) in layouts {
                    if let bar = layout.bar { #expect(bar.maxX < layout.valueX, "\(name): #\(id) \(key) \(bar) value at \(layout.valueX)") }
                }
                #expect(layouts.map(\.key) == (id == "1" ? ["1w"] : [id == "2" ? name : "5h", "1w"]))
                firstBars.append(layouts[0].layout.bar?.minX ?? -1)
            }
            let shown = firstBars.filter { $0 >= 0 }
            #expect(Set(shown).count <= 1, "\(name): \(firstBars)")
            #expect(firstBars[0] >= 0 || name != "Fable", "an unused Fable window keeps its bar at the minimum width")
            #expect(firstBars[1] >= 0, "\(name): the Max row keeps its 5h bar")
        }
    }

    @Test func theCollapsedFooterShowsTheScopedWindowOrTheWeekAlone() async throws {
        let accounts = MockAccountStore()
        let store = MockSessionStore(shiftClock: false)
        func rows(_ footer: SidebarFooterView) -> [String] {
            views(QuotaRowView.self, in: footer).filter { !$0.isHidden }.compactMap { $0.accessibilityLabel() }
        }
        func resetLine(_ footer: SidebarFooterView) -> [String] {
            views(NSTextField.self, in: footer).filter { !$0.isHidden && ($0.stringValue.contains("重置") || $0.stringValue.contains("未開始")) }
                .map(\.stringValue)
        }
        let max = SidebarFooterView(store: store, accounts: accounts, shell: ShellState())
        #expect(rows(max) == ["5h 剩 91%", "1w 剩 15%"])
        #expect(resetLine(max).first?.hasPrefix("5h 重置 ") == true)
        _ = await accounts.switchTo("2", reason: .user)
        let north = SidebarFooterView(store: store, accounts: accounts, shell: ShellState())
        #expect(rows(north) == ["Fable 剩 72%", "1w 剩 46%"])
        #expect(resetLine(north).first?.hasPrefix("1w 重置 ") == true)
        _ = await accounts.switchTo("1", reason: .user)
        let personal = SidebarFooterView(store: store, accounts: accounts, shell: ShellState())
        #expect(rows(personal) == ["1w 剩 100%"])
        #expect(!resetLine(personal).contains { $0.contains("5h") })
    }

    @Test func homeNewSessionDialogsAndOnboardingFollowTheSlot() throws {
        let accounts = MockAccountStore()
        var home = HomeModel()
        home.fillUsage(accounts)
        let rows = Dictionary(uniqueKeysWithValues: home.usage.map { ($0.slot, $0) })
        #expect(rows["#3"]?.fiveHour?.key == "5h" && rows["#2"]?.fiveHour?.key == "Fable" && rows["#1"]?.fiveHour == nil)
        let now = MockData.referenceDate
        let personal = try #require(rows["#1"])
        #expect(UsageListView.texts(personal, now: now)[2] == "", "no 5h reset or 未開始")
        #expect(UsageListView.rowHeight(personal) > 0)
        #expect(NewSessionQuota.make(option: "1", accounts: accounts)?.windows.map(\.key) == ["1w"])
        let north = SwitchDialogData.account(try #require(accounts.account("2")), isFrom: false, active: false, pinned: 1, calendar: .current)
        #expect(north.fiveHourKey == "Fable" && north.fiveHourRemaining == 72)
        let alone = SwitchDialogData.account(try #require(accounts.account("1")), isFrom: false, active: false, pinned: 0, calendar: .current)
        #expect(alone.fiveHourKey == nil && alone.fiveHourRemaining == nil)
        let steps = OnboardingFacts.accountRows(accounts.accounts, activeID: accounts.activeAccountID, now: now)
        #expect(steps.map(\.fiveHourKey) == ["Fable", "5h", nil])
    }

    /// The real store: a weekly report without 5h drops the old 5h window (the 10/31 one that showed
    /// as `5h 100%`), the dump says so, auto-switch sees it, and a newer 5h report brings it back.
    @Test func aWeeklyReportWithoutFiveHourHidesItInTheRealStore() async throws {
        let f = try AccountStoreFixture()
        let store = f.store!
        await store.start()
        store.ingest(f.report(key: "default", five: 9, fiveReset: f.clock.addingTimeInterval(10_000), week: 85,
                              weekReset: f.state.weeklyReset(3)))
        #expect(store.account("3")?.fiveHour?.remainingPercent == 91)
        f.clock = f.clock.addingTimeInterval(1)
        store.ingest(f.report(key: "default", week: 86, weekReset: f.state.weeklyReset(3)))
        let three = try #require(store.account("3"))
        #expect(three.fiveHour == nil && three.week.remainingPercent == 14)
        let dumped = store.dumpObject.accounts["order"] as? [[String: Any]]
        let entry = try #require(dumped?.first { $0["id"] as? String == "3" })
        #expect(entry["five"] is NSNull && entry["fiveAbsentAt"] is String)
        #expect(store.coreAccounts(now: f.clock).first { $0.number == 3 }?.fiveHourAbsent == true)
        // The other accounts keep cswap's 5h windows.
        #expect(store.account("2")?.fiveHour?.remainingPercent == 98)
        f.clock = f.clock.addingTimeInterval(1)
        store.ingest(f.report(key: "default", five: 20, fiveReset: f.clock.addingTimeInterval(9000), week: 87,
                              weekReset: f.state.weeklyReset(3)))
        #expect(store.account("3")?.fiveHour?.remainingPercent == 80)
    }
}
