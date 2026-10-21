import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// Accessibility labels, the profile card states, the page states and a render smoke test.
@Suite("States and accessibility", .serialized)
@MainActor
struct StateTests {
    @Test func accessibilityLabels() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let page = harness.page
        #expect(harness.card("2").accessibilityLabel() == "帳號 #2 藍鵲 · 每週重置最快（1d12h後）")
        #expect(harness.card("3").accessibilityLabel() == "帳號 #3 工作（使用中）")
        #expect(harness.card("1").accessibilityLabel() == "帳號 #1 個人")
        #expect(harness.card("2").accessibilityRole() == .group)
        #expect(harness.card("2").button.accessibilityLabel() == "切換到 #2 藍鵲")
        #expect(harness.card("3").button.accessibilityLabel() == "#3 工作 使用中")
        #expect(page.accounts.addCard.accessibilityLabel() == "加入帳號")
        #expect(page.accounts.addCard.accessibilityRole() == .button)
        #expect(page.refreshButton.accessibilityLabel() == "立即更新")
        #expect(harness.sidebar.refreshButton.accessibilityLabel() == "立即更新")
        #expect(harness.sidebar.accessibilityLabel() == "狀態區段")
        #expect(harness.sidebar.pauseButton.accessibilityLabel() == "暫停自動更新")
        #expect(harness.sidebar.navItem(.accounts)?.accessibilityLabel() == "Accounts 帳號 · cswap 1w 15%")
        #expect(harness.sidebar.navItem(.host)?.accessibilityValue() as? String == "目前位置")
        #expect(harness.sidebar.needsRows[0].accessibilityLabel() == "修正登入 API 401 · Perm")
        #expect(page.hooks.card.accessibilityLabel() == "~/.claude 設定")
        #expect(page.hooks.card.updateButton.accessibilityLabel() == "更新 hooks 與 statusline")
        #expect(page.hooks.card.previewButton.accessibilityLabel() == "預覽 settings.json 的變更")
        #expect(page.hooks.card.uninstallButton.accessibilityLabel() == "解除安裝全域 statusline")
        #expect(page.hooks.card.removeLegacyButton.accessibilityLabel() == "只移除舊版 CODD web hook")
        #expect(page.hooks.profileCards[0].accessibilityLabel() == "cswap session profile #2")
        #expect(page.accounts.autoSwitch.toggle.accessibilityLabel() == "剩餘不足時自動切換")
        #expect(page.accounts.autoSwitch.settingsButton.accessibilityLabel() == "自動切換設定")
        #expect(page.host.cards[.memory]?.meterView.accessibilityLabel() == "記憶體 app 13.8G、wired 4.3G、compressed 3.3G，共 21.4G / 36G")
        #expect(page.host.cards[.cpu]?.accessibilityLabel() == "CPU 23% load 3.12 · 12 cores · user + sys")
        // The soonest-reset label ticks with its countdown.
        page.secondTick(now: StatusSamples.referenceNow.addingTimeInterval(3600))
        #expect(harness.card("2").accessibilityLabel() == "帳號 #2 藍鵲 · 每週重置最快（1d11h後）")
        // Switching / disabled buttons say why.
        harness.apply(StatusSamples.model(.switching))
        #expect(harness.card("2").button.accessibilityLabel() == "正在切換到 #2 藍鵲")
        #expect(harness.card("1").button.accessibilityLabel() == "無法切換到 #1 個人：另一個帳號切換中…")
    }

    @Test func profileCardStates() {
        let linked = ProfileCardView.copy(ProfileCardModel(slot: "#2", linked: true, sessionTitles: ["現場示範：連線 MCP"]), claudeDir: "~/.claude")
        #expect(linked.lead == "settings.json 連結自" && linked.code == "~/.claude" && linked.tail == "（共用）")
        #expect(linked.state == "● 已連結")
        #expect(linked.hint == "現場示範：連線 MCP 以 cswap run 使用 #2，hooks 與 statusline 跟主設定一起生效")
        let notLinked = ProfileCardView.copy(ProfileCardModel(slot: "#2", linked: false, sessionTitles: ["x"]), claudeDir: "~/.claude")
        #expect(notLinked.state == "▲ 未連結")
        #expect(notLinked.hint == "固定 #2 的 session 仍由 CODD 注入 hooks 與 statusline")
        let unknown = ProfileCardView.copy(ProfileCardModel(slot: "#1", linked: nil, sessionTitles: []), claudeDir: "~/.claude")
        #expect(unknown.state == "◌ 未知" && unknown.code == nil)
        #expect(ProfileCardView.titles(["a", "b"]) == "a、b")
        #expect(ProfileCardView.titles(["a", "b", "c", "d"]) == "a、b 等 4 個 session")

        let harness = StatusHarness(StatusSamples.model(.profileNotLinked))
        defer { harness.tearDown() }
        let cards = harness.page.hooks.profileCards
        #expect(cards.count == 2)
        #expect(cards[0].visibleTexts == ["cswap session profile #2", "→", "settings.json 沒有連結", "~/.claude", "（獨立）", "▲ 未連結",
                                          "固定 #2 的 session 仍由 CODD 注入 hooks 與 statusline"])
        #expect(cards[1].visibleTexts == ["cswap session profile #1", "→", "settings.json 無法確認", "◌ 未知",
                                          "固定 #1 的 session 仍由 CODD 注入 hooks 與 statusline"])
        // No pinned sessions: no profile card.
        harness.apply(StatusSamples.model(.hooksClean))
        #expect(harness.page.hooks.profileCards.isEmpty)
    }

    /// M3 review: a long Claude dir pushed the path chip, `（共用）` and the state past the card.
    @Test func aLongClaudeDirStaysInsideTheProfileCard() throws {
        let card = ProfileCardView()
        let long = "/private/var/folders/xx/xxxxxxxxxxxxxxxxxxxxxxxx0000gn/T/codd-m3e.AbCdEf/a/home/.claude"
        card.configure(ProfileCardModel(slot: "#2", linked: true, sessionTitles: ["x"]), claudeDir: long)
        card.frame = CGRect(x: 0, y: 0, width: 640, height: card.preferredHeight(width: 640))
        card.layoutSubtreeIfNeeded()
        // The first line's parts (the corner glyphs of the frame sit elsewhere).
        let line = card.subviews.filter { !$0.isHidden && $0.frame.width > 0 && abs($0.frame.midY - 23) < 6 }
        #expect(line.count == 6)
        #expect(line.allSatisfy { $0.frame.maxX <= card.bounds.width - 19 }, "every part inside the card")
        #expect(card.visibleTexts.contains("settings.json 連結自"), "the lead keeps its width")
        #expect(card.visibleTexts.contains("● 已連結") && card.visibleTexts.contains("（共用）"))
        let chip = try #require(card.visibleTexts.first { $0.contains("…") }, "cut in the middle")
        #expect(chip.hasPrefix("/p") && chip.hasSuffix(".claude") && chip.count < long.count, "\(chip)")
        #expect(ProfileCardView.middleTruncated("abcdef") { $0.count <= 4 } == "a…ef")
        #expect(ProfileCardView.middleTruncated("~/.claude") { _ in true } == "~/.claude")
        #expect(ProfileCardView.middleTruncated("abc") { _ in false } == nil)
    }

    @Test func accountsUnavailableCopies() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let cases: [(StatusSamples.State, String)] = [
            (.accountsMissing, "// 找不到 cswap（設定 › 帳號）"),
            (.accountsTooOld, "// cswap 0.25.1 太舊，需要 ≥ 0.26"),
            (.accountsUnreadable, "// 讀不到 cswap 狀態：cache/usage.json 版本不支援 · 按 ↻ 立即更新 改用 cswap list（會查詢一次用量）"),
        ]
        for (state, line) in cases {
            harness.apply(StatusSamples.model(state))
            #expect(harness.page.accounts.unavailableText == line)
            #expect(harness.page.accounts.orderedCards.isEmpty)
            #expect(harness.page.accounts.addCard.isHidden)
            #expect(harness.pageTexts.contains(line))
        }
        harness.apply(StatusSamples.model(.accountsMissing))
        #expect(!harness.pageTexts.contains { $0.hasPrefix("cswap 0.") })
        harness.apply(StatusSamples.spec())
        #expect(harness.page.accounts.unavailableText == nil)
        #expect(harness.page.accounts.orderedCards.count == 3)
    }

    @Test func autoSwitchOnDrawsThresholdTicks() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let auto = harness.page.accounts.autoSwitch
        let bars = { harness.page.accounts.orderedCards.flatMap { $0.quotaBlocks.map(\.bar.row.threshold) } }
        #expect(bars().allSatisfy { $0 == nil })
        #expect(auto.chipStyleIsDashed)
        #expect(!auto.toggle.isOn)
        harness.apply(StatusSamples.model(.autoSwitchOn))
        // M3 review: the tick goes on the 5h / 1w bars the rule checks, never on a scoped window.
        let windows = { harness.page.accounts.orderedCards.flatMap { $0.model?.rows.map(\.window) ?? [] } }
        #expect(bars().count == 9)
        #expect(zip(windows(), bars()).allSatisfy { window, tick in tick == (window == .scoped ? nil : 2) })
        #expect(windows().filter { $0 == .scoped }.count == 3)
        var weeklyOnly = StatusSamples.model(.autoSwitchOn)
        weeklyOnly.accounts.autoSwitch.checksFiveHour = false
        harness.apply(weeklyOnly)
        #expect(zip(windows(), bars()).allSatisfy { window, tick in tick == (window == .weekly ? 2 : nil) })
        harness.apply(StatusSamples.model(.autoSwitchOn))
        #expect(!auto.chipStyleIsDashed)
        #expect(auto.toggle.isOn)
        #expect(auto.chipTexts == ["剩餘 ≤ 2%", "5h / 1w", "依排序第一個額度足夠的", "冷卻 300s"])
        #expect(harness.pageTexts.contains("ON"))
        #expect(harness.pageTexts.contains("! cswap menubar 也在執行，兩邊可能同時切換"))
        // The tick sits at 2 % of each bar.
        let row = harness.card("3").quotaBlocks[0].bar
        let tick = QuotaBarRowRenderer.thresholdTickRect(for: row.row, in: row.bounds)
        let bar = QuotaBarRowRenderer.barRect(for: row.row, in: row.bounds)
        #expect(tick.map { abs($0.midX - (bar.minX + bar.width * 0.02)) <= 1 } == true)
        #expect(AutoSwitchModel.ruleChips(thresholdPercent: 5, fiveHour: false, weekly: true, cooldownSeconds: 120)
                == ["剩餘 ≤ 5%", "1w", "依排序第一個額度足夠的", "冷卻 120s"])
    }

    @Test func hooksStatesCopy() {
        let harness = StatusHarness(StatusSamples.model(.hooksClean))
        defer { harness.tearDown() }
        let texts = harness.page.hooks.card.visibleTexts
        #expect(texts.containsInOrder(["● 正常", "HOOKS", "● 14 / 14", "STATUSLINE", "○ 未安裝全域版", "hook-tap", "→", "statusline.sh",
                                       "CODD 的 session 已自動注入；裝了全域版，其他 claude 的用量也會回報", "STATUS DIR",
                                       "~/Library/Application Support/CODD/hooks", "最近收到資料", "●", "3s 前", "只有 hook 事件回報，statusline 還沒有"]))
        #expect(!texts.contains("! 與預設不同"))
        #expect(!harness.page.hooks.card.uninstallButton.isEnabled)
        harness.apply(StatusSamples.model(.hooksLegacyWeb))
        #expect(harness.page.hooks.card.visibleTexts.containsInOrder(["◆ 舊版 CODD web statusline", "codd-statusline.js", "→", "hook-tap"]))
        // The statusline copy table and the received hint.
        #expect(HooksCardView.statuslineCopy(.installed).0 == "● 已安裝")
        #expect(HooksCardView.statuslineCopy(.outdated).0 == "◆ 需要更新")
        #expect(HooksCardView.statuslineCopy(.undecodable).0 == "▲ 無法解析")
        #expect(HooksCardView.receivedHint(LastReceived(at: nil, hooks: false, statusline: false)) == "還沒有收到資料")
        #expect(HooksCardView.receivedHint(LastReceived(at: Date(), hooks: false, statusline: true)) == "只有 statusline 回報，hook 事件還沒有")
        #expect(ForeignRowView.eventsHint(["Notification", "Stop"]) == "×2 · Notification, Stop")
        #expect(ForeignRowView.eventsHint(Array(repeating: "E", count: 11)) == "×11 events")
        // No data yet: `○` and no time.
        var model = StatusSamples.spec()
        model.hooks.lastReceived = LastReceived(at: nil, hooks: false, statusline: false)
        model.hooks.foreign = []
        harness.apply(model)
        let none = harness.page.hooks.card.visibleTexts
        #expect(none.containsInOrder(["最近收到資料", "○", "還沒有收到資料"]))
        #expect(none.contains("// 沒有其他工具的 hook"))
    }

    @Test func noBatteryHidesTheCard() {
        let harness = StatusHarness(StatusSamples.model(.noBattery))
        defer { harness.tearDown() }
        #expect(harness.page.host.cards[.battery] == nil)
        #expect(!harness.pageTexts.contains("BAT"))
        #expect(harness.page.host.cards.count == 7)
        harness.apply(StatusSamples.spec())
        #expect(harness.page.host.cards[.battery] != nil)
        #expect(harness.pageTexts.containsInOrder(["BAT", "AC"]))
    }

    @Test func renderSmoke() throws {
        StatusHarness.registerFonts()
        let sidebar = StatusSidebarView(actions: StatusPageActions())
        let page = StatusPageView(actions: StatusPageActions())
        sidebar.now = { StatusSamples.referenceNow }
        page.now = { StatusSamples.referenceNow }
        let root = FlippedView(frame: CGRect(x: 0, y: 0, width: 1440, height: 1300))
        root.addSubview(sidebar)
        root.addSubview(page)
        sidebar.frame = CGRect(x: 0, y: 0, width: 220, height: 1300)
        page.frame = CGRect(x: 220, y: 0, width: 1220, height: 1300)
        let model = StatusSamples.spec()
        sidebar.apply(model)
        page.apply(model)
        let rep = try #require(ViewSnapshot.render(root, size: CGSize(width: 1440, height: 1300), scale: 1))
        #expect(rep.pixelsWide == 1440 && rep.pixelsHigh == 1300)
        // Not blank, and drawn where the artboard draws: the active card's amber-dim border, the
        // page title in amber.
        let sample = try #require(ViewSnapshot.render(page, size: CGSize(width: 1220, height: 1300), scale: 1))
        #expect(ViewSnapshot.pixelsDiffering(from: Palette.bg, in: sample, tolerance: 12) > 20_000)
        let border = try #require(ViewSnapshot.color(at: CGPoint(x: 36 + 290, y: 520), in: sample))
        #expect(abs(border.redComponent - Palette.amberDim.redComponent) < 0.08)
        #expect(abs(border.greenComponent - Palette.amberDim.greenComponent) < 0.08)
    }
}
