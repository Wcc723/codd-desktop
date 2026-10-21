import AppKit
import CoddClaudeSettings
import CoddCore
import CoddHost
import CoddPreferences
import CoddStatusUI
import CoddUI
import Foundation
import Testing
@testable import CODD

/// M3 I2: the STATUS page model from the stores (SPEC §5 mock → the Status artboard's texts), the
/// host one-liner, the ⌘K account actions, the notification routing and quiet hours.
@MainActor
@Suite("STATUS page data (I2)")
struct StatusPageDataTests {
    static var taipei: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
        return calendar
    }

    /// The mock stores mapped as the app maps them (`-codd-mock -codd-show status`).
    static func mockModel() -> (model: StatusPageModel, now: Date) {
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        let now = MockData.referenceDate
        var facts = StatusAccountFacts()
        facts.base = .ready
        facts.rootPath = "~/.claude-swap-backup"
        facts.profileShares = [2: true]
        let hooks = StatusHooksFacts(inspection: .loaded(MockData.settingsInspection, exists: true),
                                     statusDir: "~/Github/codd-web/agent-sandbox/.claude/codd-status",
                                     statusDirDiffers: true, lastHookAt: now.addingTimeInterval(-8), lastStatusLineAt: now.addingTimeInterval(-8))
        let host = StatusHostFacts(sample: MockData.hostSample(), history: MockData.hostHistory(), p99Milliseconds: 3,
                                   footprint: (physFootprint: 412 << 20, resident: 412 << 20))
        let inputs = StatusPageInputs(now: now, calendar: taipei, updatedAt: now, host: host, accounts: facts, hooks: hooks)
        return (StatusPageData.model(store: store, accounts: accounts, inputs: inputs), now)
    }

    @Test func accountsMatchTheArtboard() throws {
        let (model, now) = Self.mockModel()
        let accounts = model.accounts
        #expect(accounts.version == "cswap 0.26.0")
        #expect(accounts.rootPath == "~/.claude-swap-backup")
        #expect(AccountsSectionModel.sortHint == "依每週重置排序 · 越快重置越上面")
        #expect(accounts.countHint == "3 個帳號 · 不顯示 email")
        #expect(accounts.unavailable == nil && accounts.canAdd)
        // R7: the weekly reset decides (#2 first), the active #3 keeps its sorted place.
        #expect(accounts.cards.map(\.id) == ["2", "3", "1"])
        let two = accounts.cards[0], three = accounts.cards[1], one = accounts.cards[2]
        #expect(three.isActive && three.button == .active)
        #expect(two.button == .switchable && one.button == .switchable)
        #expect(three.source.text(now: now) == "statusline · 12s 前")
        #expect(two.source.text(now: now) == "cswap cache · 3m 前")
        #expect(three.pace == "↗ 1w 用量超前預期 · 預估 10/17 18:00 用完")
        #expect(two.pace == nil)
        #expect(three.who.text == "12 個 session 跟隨全域登入")
        #expect(two.who.text == "1 個 session 固定（cswap run）")
        #expect(one.who == .none)
        #expect(three.plan == "MAX 20x")
        // 5h, 1w and the per-model window (only #3 reported it: the others say so).
        #expect(three.rows.map(\.key) == ["5h", "1w", "Fable"])
        #expect(three.rows[0].remaining == 91 && three.rows[0].reset == "重置 13:39")
        #expect(three.rows[1].remaining == 15 && three.rows[1].tone == .crit && three.rows[1].isSortKey)
        #expect(three.rows[1].reset == "重置 10/18 週日 12:00")
        #expect(three.rows[1].countdown.text(now: now).hasPrefix("3d01h"))
        #expect(three.rows[2].reset == "週額度 · 同 1w 重置" && three.rows[2].countdown.text(now: now) == "未使用")
        #expect(two.rows[2].remaining == nil && two.rows[2].reset == "快取未提供" && two.rows[2].countdown.text(now: now) == "等待回報")
        #expect(one.rows[0].reset == "未開始" && one.rows[0].countdown.text(now: now) == "第一則訊息後起算")
        #expect(two.rows[1].reset == "重置 10/16 週五 22:59")
        // AUTO-SWITCH OFF: the rule as dim chips.
        #expect(!accounts.autoSwitch.on)
        #expect(accounts.autoSwitch.chips == ["剩餘 ≤ 2%", "5h / 1w", "依排序第一個額度足夠的", "冷卻 300s"])
        #expect(accounts.autoSwitch.note == AutoSwitchModel.defaultNote)
        #expect(accounts.autoSwitch.warning == nil)
    }

    @Test func sidebarAndHostMatchTheArtboard() {
        let (model, _) = Self.mockModel()
        #expect(model.nav.map(\.value) == ["cpu 23%", "1w 15%", "需更新", "M4", "1 rc"])
        #expect(model.nav[1].glyph == .bad)
        #expect(model.needsYou.map(\.id) == ["s1", "s2", "s3"])
        #expect(model.needsYou.map(\.pill) == ["Perm", "Ask", "Error"])
        #expect(model.needsYou[0].detail == "orb-toolkit-backend")
        #expect(model.needsYou[2].detail == "overloaded · Gear3D")
        #expect(model.needsYou[2].attention == .error)
        #expect(model.counts.map(\.label) == ["WAITING", "ERROR", "DONE", "BUSY", "COMPACT", "IDLE", "SHELL", "EXITED"])
        #expect(model.counts.map(\.count) == [2, 1, 1, 3, 1, 4, 1, 1])
        #expect(model.liveCount == 13)
        let cards = Dictionary(uniqueKeysWithValues: model.host.cards.map { ($0.kind, $0) })
        #expect(model.host.name == "studio-mbp" && model.host.healthy)
        #expect(cards[.cpu]?.value == "23" && cards[.cpu]?.sub == "load 3.12 · 12 cores")
        #expect(cards[.cpu]?.axis == ["-10m", "peak 38%", "now"])
        #expect(cards[.memory]?.value == "21.4" && cards[.memory]?.unit == "/36G")
        #expect(cards[.memory]?.legend.map(\.value) == ["13.8G", "4.3G", "3.3G"])
        #expect(cards[.disk]?.value == "412G" && cards[.disk]?.right == "1T")
        #expect(cards[.swap]?.value == "1.2G" && cards[.swap]?.sub == "共 2G · 壓力正常")
        #expect(cards[.battery]?.value == "86" && cards[.battery]?.sub == "接上電源")
        #expect(cards[.claude]?.value == "12" && cards[.claude]?.sub == "11 CODD + 1 外部")
        #expect(cards[.app]?.value == "412" && cards[.app]?.sub == "event loop p99 3ms")
        #expect(cards[.uptime]?.value == "3d4h" && cards[.uptime]?.sub == "開機於 10/12 06:42")
        #expect(model.remote == RemoteModel(count: 1, titles: ["修正登入 API 401"]))
    }

    @Test func hooksCardFromTheInspection() {
        let (model, _) = Self.mockModel()
        let hooks = model.hooks
        #expect(hooks.pendingUpdates == 1)
        #expect(hooks.legacy?.events.count == 10)
        #expect(hooks.statusline == StatuslinePart(state: .installed, chain: ["CODD", "hook-tap", "statusline.sh"]))
        #expect(hooks.foreign.map(\.code) == ["hook-tap", "osascript"])
        #expect(hooks.foreign[0].warnings == ["PermissionRequest 會阻擋 600s"])
        #expect(hooks.foreign[1].duplicateNotifications)
        #expect(hooks.canPreview && hooks.canUpdate && hooks.canUninstall && hooks.canRemoveLegacy && hooks.canDisableDuplicates)
        #expect(hooks.lastReceived.hooks && hooks.lastReceived.statusline)
        // The cswap session profile card: #2's pinned session, its settings.json shared.
        #expect(hooks.profiles == [ProfileCardModel(slot: "#2", linked: true, sessionTitles: ["現場示範：連線 MCP"])])

        // Other inspections: the web wrapper, a clean file, an unreadable one.
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        var facts = StatusHooksFacts(statusDir: "~/x", statusDirDiffers: false)
        facts.inspection = .loaded(ClaudeSettingsInspection(statusLine: .coddWeb(inner: "printf 'USER-SL-%s' ok")), exists: true)
        let web = StatusPageData.hooksCard(facts, store: store, accounts: accounts, facts: StatusAccountFacts())
        #expect(web.statusline.state == .legacyWeb && web.pendingUpdates == 1 && web.canRemoveLegacy && !web.canUninstall)
        facts.inspection = .loaded(ClaudeSettingsInspection(statusLine: .user("/usr/local/bin/my-line --x")), exists: true)
        let clean = StatusPageData.hooksCard(facts, store: store, accounts: accounts, facts: StatusAccountFacts())
        #expect(clean.statusline == StatuslinePart(state: .notInstalled, chain: ["my-line"]))
        #expect(clean.pendingUpdates == 0 && clean.legacy == nil && clean.canUpdate && !clean.canRemoveLegacy)
        facts.inspection = .failed("settings.json 不是有效的 JSON（第 3 行第 1 欄），CODD 不會改動它")
        let broken = StatusPageData.hooksCard(facts, store: store, accounts: accounts, facts: StatusAccountFacts())
        #expect(broken.problem?.hasPrefix("// 讀不到 settings.json：") == true)
        #expect(!broken.canPreview && !broken.canUpdate)
    }

    @Test func unavailableCopiesAndSwitchProgress() {
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        var facts = StatusAccountFacts()
        for (base, line) in [(AccountAvailability.noCswap, AccountsSectionModel.cswapMissing),
                             (.unsupported(version: "0.25.1"), AccountsSectionModel.cswapTooOld("0.25.1")),
                             (.unreadable(reason: "cache/usage.json 版本不支援"), AccountsSectionModel.stateUnreadable("cache/usage.json 版本不支援"))] {
            facts.base = base
            let section = StatusPageData.accountsSection(accounts, store: store, facts: facts, now: MockData.referenceDate,
                                                         calendar: StatusPageDataTests.taipei)
            #expect(section.unavailable == line)
            #expect(section.cards.isEmpty && !section.canAdd)
        }
        #expect(StatusPageData.chainChips("bash ~/.hook-tap/statusline.sh") == ["statusline.sh"])
        #expect(StatusPageData.chainChips("/opt/bin/hook-tap statusline ~/.hook-tap/statusline.sh") == ["hook-tap", "statusline.sh"])
        #expect(StatusPageData.chainChips(nil) == [])
    }

    @Test func autoSwitchOnShowsTheWarning() {
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        var facts = StatusAccountFacts()
        facts.base = .ready
        facts.autoSwitchOn = true
        facts.thresholdPercent = 5
        facts.cooldownSeconds = 600
        facts.backgroundWarning = AutoSwitchModel.menubarWarning
        let section = StatusPageData.accountsSection(accounts, store: store, facts: facts, now: MockData.referenceDate,
                                                     calendar: StatusPageDataTests.taipei)
        #expect(section.autoSwitch.on && section.autoSwitch.thresholdPercent == 5)
        #expect(section.autoSwitch.chips == ["剩餘 ≤ 5%", "5h / 1w", "依排序第一個額度足夠的", "冷卻 600s"])
        #expect(section.autoSwitch.warning == "! cswap menubar 也在執行，兩邊可能同時切換")
    }
}

@MainActor
@Suite("Host line, quick switch, notification rules (I2)")
struct StatusSmallPartsTests {
    @Test func hostLineFormat() {
        var sample = MockData.hostSample()
        #expect(HostLineService.line(sample) == "cpu 23% · mem 21/36G · bat 86%")
        sample.cpu = nil
        #expect(HostLineService.line(sample) == "mem 21/36G · bat 86%")
        sample.battery = nil
        #expect(HostLineService.line(sample) == "mem 21/36G")
    }

    @Test func hostLineSamplesOnlyWhileVisible() async {
        let lines = Recorder<String>()
        let service = HostLineService(interval: .seconds(3600)) { lines.append($0) }
        #expect(!service.isSampling)
        service.setVisible(true, for: "window")
        #expect(service.isSampling)
        await m3Eventually("first sample") { !lines.values.isEmpty }
        #expect(lines.values.first?.contains("mem ") == true)
        service.setVisible(true, for: "popover")
        service.setVisible(false, for: "window")
        #expect(service.isSampling, "the popover still shows it")
        service.setVisible(false, for: "popover")
        #expect(!service.isSampling)
    }

    @Test func quickSwitchOffersAccountSwitches() {
        let store = MockSessionStore()
        let shell = ShellState()
        let accounts = MockAccountStore()
        let input = QuickSwitchModel.Input.make(store: store, shell: shell, recent: [], accounts: accounts)
        // Every switchable account in R7 order, never the active one.
        #expect(input.accounts.map(\.id) == ["2", "1"])
        #expect(input.accounts.first?.quota == "5h 剩 98% · 1w 剩 46%")
        let empty = QuickSwitchModel.build(query: "", input: input)
        let row = empty.rows.first { if case .action(.switchAccount) = $0.item { true } else { false } }
        #expect(row?.title == "切換帳號到 #2 藍鵲")
        #expect(row?.shortcut == "5h 剩 98% · 1w 剩 46%")
        // QuickSwitch artboard: `打卡` still offers the R7-first account after the contextual actions.
        let typed = QuickSwitchModel.build(query: "打卡", input: input)
        let titles = typed.groups.first { $0.section == .actions }?.rows.map(\.title) ?? []
        #expect(titles.contains("切換帳號到 #2 藍鵲"))
        #expect(titles.firstIndex(of: "切換帳號到 #2 藍鵲") == 2)
        let named = QuickSwitchModel.build(query: "切換帳號 #1", input: input)
        #expect(named.rows.contains { $0.title == "切換帳號到 #1 個人" })
        // While a switch runs nothing is offered.
        let none = QuickSwitchModel.Input.make(store: store, shell: shell, recent: [], accounts: nil)
        #expect(none.accounts.isEmpty)
    }

    @Test func quietHoursAcrossMidnight() {
        var rules = CoddPreferences.Notifications()
        let calendar = StatusPageDataTests.taipei
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: hour, minute: minute)) ?? Date()
        }
        #expect(NotificationRules.isQuiet(rules, now: at(23, 30), calendar: calendar))
        #expect(NotificationRules.isQuiet(rules, now: at(7, 59), calendar: calendar))
        #expect(!NotificationRules.isQuiet(rules, now: at(8, 0), calendar: calendar))
        #expect(!NotificationRules.isQuiet(rules, now: at(12, 0), calendar: calendar))
        rules.quietHours = CoddPreferences.QuietHours(enabled: true, start: "09:00", end: "17:00")
        #expect(NotificationRules.isQuiet(rules, now: at(12, 0), calendar: calendar))
        #expect(!NotificationRules.isQuiet(rules, now: at(18, 0), calendar: calendar))
        rules.quietHours.enabled = false
        #expect(!NotificationRules.isQuiet(rules, now: at(12, 0), calendar: calendar))
        rules.pausedUntil = at(13, 0)
        #expect(NotificationRules.isPaused(rules, now: at(12, 0)))
        #expect(!NotificationRules.isPaused(rules, now: at(13, 1)))
    }

    /// D29: one delegate. Account responses reach AppNotifier through the session notifier's
    /// routing; AppNotifier has no delegate of its own and records every decision.
    @Test func oneNotificationDelegateRoutesByCategory() {
        let store = MockSessionStore()
        let opened = Recorder<SessionID>()
        let log = NotificationLog()
        let sessions = SessionNotifier(store: store, allowedThisRun: false, rules: { CoddPreferences.Notifications() },
                                       isFocused: { _ in false }, open: { opened.append($0) }, decisions: log)
        let accounts = AppNotifier(dispatcher: sessions, allowedThisRun: false, rules: { CoddPreferences.Notifications() },
                                   decisions: log)
        let undone = Recorder<AccountID>()
        accounts.onUndo = { undone.append($0) }
        sessions.route(category: SessionNotifier.accountCategoryID, action: SessionNotifier.undoActionID,
                       userInfo: [AppNotifier.undoAccountKey: "3"])
        sessions.route(category: SessionNotifier.accountCategoryID, action: SessionNotifier.okActionID,
                       userInfo: [AppNotifier.undoAccountKey: "3"])
        #expect(undone.values == ["3"])
        sessions.route(category: SessionNotifier.categoryID, action: SessionNotifier.laterActionID, userInfo: [SessionNotifier.sessionKey: "s1"])
        #expect(opened.values.isEmpty)
        sessions.route(category: SessionNotifier.categoryID, action: SessionNotifier.openActionID, userInfo: [SessionNotifier.sessionKey: "s1"])
        #expect(opened.values == ["s1"])
        // `-codd-notifications NO`: nothing posts, the decision is still recorded (titles only).
        #expect(!accounts.post(.noEligibleTarget, title: "所有帳號都低於 2%", body: "x"))
        #expect(log.entries.map(\.kind) == ["account-none-eligible"])
        #expect(log.entries.allSatisfy { $0.suppressed })
    }
}

@MainActor
@Suite("STATUS area (I2, D16, D32)", .serialized)
struct StatusAreaTests {
    private func controller(_ store: MockSessionStore, _ accounts: MockAccountStore) -> StatusController {
        StatusController(sources: .init(store: store, accounts: accounts, cswap: nil, hooks: nil, installer: nil,
                                        preferences: .inMemory(), statusDir: "", statusDirDiffers: false, mock: true))
    }

    /// A status line reporting every second must not rebuild the page every second: ages and quota
    /// wait for the 5 s refresh; session states, the active account and switches come at once.
    @Test func onlyDiscreteChangesRebuildBetweenRefreshes() async throws {
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        let status = controller(store, accounts)
        status.setActive(true)
        defer { status.setActive(false) }
        try? await Task.sleep(for: .milliseconds(200))
        let first = try #require(status.model)
        #expect(first.needsYou.count == 3)
        accounts.account("3")?.sourceAt = store.clock.now()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(status.model == first, "a new status-line age waits for the refresh")
        store.session("s5")?.state = .waiting
        await m3Eventually("NEEDS YOU follows the state") { status.model?.needsYou.count == 4 }
        _ = await accounts.switchTo("2", reason: .user)
        await m3Eventually("the active account follows") { status.model?.accounts.cards.first { $0.isActive }?.id == "2" }
        // Paused: nothing rebuilds until it resumes.
        status.togglePause()
        #expect(status.paused && status.model?.paused == true)
        store.session("s5")?.state = .busy
        try? await Task.sleep(for: .milliseconds(100))
        #expect(status.model?.needsYou.count == 4)
        status.togglePause()
        await m3Eventually("resumed") { status.model?.needsYou.count == 3 && status.model?.paused == false }
    }

    /// D16: the sidebar column shows the STATUS sidebar instead of the session sidebar, and toasts go
    /// over whichever is shown. (The split's width swap is checked on snapshots: a test window would
    /// write the app's autosaved frames into the user's defaults.)
    @Test func sidebarColumnSwapsAndHostsTheToast() {
        let store = MockSessionStore()
        let accounts = MockAccountStore()
        let shell = ShellState()
        let status = controller(store, accounts)
        let sidebar = SidebarViewController(env: SidebarEnvironment(store: store, accounts: accounts, shell: shell, realMode: false))
        let container = SidebarContainerViewController(sidebar: sidebar, statusSidebar: status.sidebarView)
        container.view.frame = NSRect(x: 0, y: 0, width: 280, height: 800)
        #expect(!container.showsStatus && status.sidebarView.isHidden && !sidebar.view.isHidden)
        container.showStatus(true)
        #expect(container.showsStatus && !status.sidebarView.isHidden && sidebar.view.isHidden)
        let toast = container.showToast("已更新 ~/.claude/settings.json · 備份 x", undo: nil)
        #expect(toast.superview === container.view && container.currentToast === toast)
        container.showStatus(false)
        #expect(!container.showsStatus && status.sidebarView.isHidden && !sidebar.view.isHidden)
        let sessionToast = container.showToast("已切換到 #2 藍鵲", undo: nil)
        #expect(sessionToast.superview === sidebar.view)
    }
}
