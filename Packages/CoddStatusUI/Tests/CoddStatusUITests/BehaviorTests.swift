import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// Nav → scroll anchors, the 1 Hz tick, apply diffing and the ticker subscription.
@Suite("Navigation, ticking, diffing", .serialized)
@MainActor
struct BehaviorTests {
    @Test func navClickSelectsAndScrollsToTheAnchor() throws {
        // A short window so the page scrolls.
        let harness = StatusHarness(size: CGSize(width: 1440, height: 600))
        defer { harness.tearDown() }
        let page = harness.page
        var selected: [StatusSection] = []
        var visible: [StatusSection] = []
        harness.sidebar.onSelectSection = { section in
            selected.append(section)
            page.scroll(to: section)
        }
        page.onVisibleSectionChange = { visible.append($0) }
        #expect(harness.sidebar.selectedSection == .host)
        #expect(harness.sidebar.navItem(.host)?.isCurrent == true)

        let maxOffset = page.documentHeight - 600
        #expect(maxOffset > 0)
        for section in [StatusSection.accounts, .hooks, .mcp, .remote, .host] {
            try #require(harness.sidebar.navItem(section)).performClick(nil)
            let expected = section == .host ? 0 : min(maxOffset, page.anchor(of: section) - 28)
            #expect(abs(page.scrollOffset - expected) < 0.5, "\(section)")
            #expect(harness.sidebar.selectedSection == section)
            #expect(harness.sidebar.navItem(section)?.isCurrent == true)
            #expect(page.visibleSection() == section, "the clicked section stays until a scroll by hand (\(section))")
        }
        #expect(selected == [.accounts, .hooks, .mcp, .remote, .host])
        // Anchors follow the page order; HOOKS and MCP share their row.
        #expect(page.anchor(of: .host) < page.anchor(of: .accounts))
        #expect(page.anchor(of: .accounts) < page.anchor(of: .hooks))
        #expect(page.anchor(of: .hooks) == page.anchor(of: .mcp))
        #expect(page.anchor(of: .mcp) < page.anchor(of: .remote))
        // The scroll spy keeps each clicked section (M3 review: the next scroll event used to
        // switch the highlight back, and MCP could never be highlighted).
        // (MCP shares HOOKS' row, so its click does not scroll and reports nothing new.)
        #expect(visible == [.accounts, .hooks, .remote, .host])
        // Scrolling by hand takes over again: the section at the top line (HOOKS wins over MCP
        // on its row), and at the end of the page the last header on screen.
        page.scrollTo(offset: page.anchor(of: .hooks) - 28)
        #expect(page.visibleSection() == .hooks)
        page.scrollTo(offset: maxOffset)
        #expect(page.visibleSection() == .remote)
    }

    @Test func artboardGeometry() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let page = harness.page
        // `.sx-page{padding:28px 36px}`; sections 1148 wide at a 1220 page.
        #expect(page.host.frame.minX == 36 && page.host.frame.width == 1148)
        #expect(abs(page.host.frame.minY - 103.7) < 1)
        // Host grid: 1.45fr 1.45fr 1fr 1fr 1fr, gap 10.
        let cpu = page.host.cards[.cpu]!.frame, disk = page.host.cards[.disk]!.frame
        #expect(abs(cpu.width - 272.3) < 1 && abs(disk.width - 187.8) < 1)
        #expect(abs(cpu.height - 206) < 1 && abs(disk.height - 98) < 1)
        // Account cards: four 278 px columns, gap 12; the active card is compact (FB, the
        // artboard's was 285) and sets the row's height.
        let cards = page.accounts.orderedCards.map(\.frame)
        #expect(cards.map(\.width) == [278, 278, 278])
        #expect(cards.map(\.minX) == [0, 290, 580])
        #expect(cards[1].height < 250 && cards[1].height == page.accounts.card("3")?.preferredHeight(width: 278))
        #expect(Set(cards.map(\.height)).count == 1)
        #expect(page.accounts.addCard.frame.minX == 870)
        // Two columns 1.3fr / 1fr, gap 20.
        #expect(abs(page.hooks.frame.width - 638) < 1)
        #expect(abs(page.mcp.frame.minX - (36 + 638 + 20)) < 1)
        // Sidebar: 41 px nav items from y 88 inside the scroll area (52 px head).
        #expect(harness.sidebar.navItem(.host)?.frame.minY == 36)
        #expect(harness.sidebar.navItem(.host)?.frame.height == 41)
    }

    @Test func tickUpdatesOnlyTheRelativeTimes() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let page = harness.page
        let before = page.visibleTexts
        let cardCounts = page.accounts.orderedCards.map(\.configureCount)
        let sectionCounts = [page.host.configureCount, page.accounts.configureCount, page.hooks.configureCount]
        let header = page.headerConfigureCount

        let later = StatusSamples.referenceNow.addingTimeInterval(65)
        page.secondTick(now: later)
        harness.sidebar.secondTick(now: later)
        harness.settle()
        let after = page.visibleTexts

        // Exactly the ticking strings changed (+65 s: ages 3m → 4m, 12s → 1m, 8s → 1m; the 5h countdowns
        // lose a minute; the weekly ones stay on the same hour).
        let changed = Set(before).symmetricDifference(Set(after))
        #expect(changed == ["cswap cache · 3m 前", "cswap cache · 4m 前", "statusline · 12s 前", "statusline · 1m 前",
                            "2h37m後", "2h36m後", "2h57m後", "2h56m後", "8s 前", "1m 前"])
        #expect(after.contains("statusline · 1m 前"))
        #expect(after.contains("2h56m後"))
        #expect(after.contains("1m 前"))
        // Nothing was rebuilt.
        #expect(page.accounts.orderedCards.map(\.configureCount) == cardCounts)
        #expect([page.host.configureCount, page.accounts.configureCount, page.hooks.configureCount] == sectionCounts)
        #expect(page.headerConfigureCount == header)
        // NEEDS YOU durations tick too: 3m + 65 s = 4m.
        #expect(harness.sidebar.needsRows[0].line2Text == "4m · orb-toolkit-backend")
        #expect(harness.sidebarTexts.contains("上次 10:42:07"))
    }

    @Test func applyRebuildsOnlyWhatChanged() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let page = harness.page
        func counts() -> [Int] {
            [page.host.configureCount, page.accounts.configureCount, page.hooks.configureCount, page.headerConfigureCount]
                + page.accounts.orderedCards.map(\.configureCount)
                + HostCardModel.Kind.allCases.compactMap { page.host.cards[$0]?.configureCount }
        }
        let start = counts()
        harness.apply(StatusSamples.spec())
        #expect(counts() == start)

        // A new remote count touches nothing else.
        var model = StatusSamples.spec()
        model.remote = RemoteModel(count: 2, titles: ["修正登入 API 401", "打卡頁 RWD 調整"])
        harness.apply(model)
        #expect(counts() == start)
        #expect(page.remote.visibleTexts.contains("2 個 session 已連 Remote Control（修正登入 API 401、打卡頁 RWD 調整）"))

        // One card's number: only that card (and its section) is reconfigured.
        model.accounts.cards[1].rows[0].remaining = 90
        harness.apply(model)
        var expected = start
        expected[1] += 1
        expected[5] += 1
        #expect(counts() == expected)

        // A host value: only that card.
        model.host.cards[0].value = "31"
        harness.apply(model)
        expected[0] += 1
        expected[7] += 1
        #expect(counts() == expected)
        #expect(page.host.cards[.cpu]?.visibleTexts.contains("31%") == true)

        // A new refresh time: only the header line.
        model.updatedAt = model.updatedAt.addingTimeInterval(5)
        harness.apply(model)
        expected[3] += 1
        #expect(counts() == expected)
        #expect(page.metaText == "UPDATED 10:42:12 · 每 5 秒")
    }

    @Test func ticksOnlyInAWindow() {
        let harness = StatusHarness(inWindow: false)
        defer { harness.tearDown() }
        #expect(!harness.page.isTicking)
        #expect(!harness.sidebar.isTicking)
        let root = harness.page.superview!
        harness.window.contentView = root
        #expect(harness.page.isTicking)
        #expect(harness.sidebar.isTicking)
        harness.window.contentView = nil
        #expect(!harness.page.isTicking)
        #expect(!harness.sidebar.isTicking)
    }

    @Test func hostGridPlacement() {
        let full = HostSectionView.placement(StatusSamples.host().cards).map { "\($0.kind.rawValue)@\($0.column),\($0.row)" }
        #expect(full == ["cpu@0,0", "memory@1,0", "disk@2,0", "swap@3,0", "battery@4,0", "claude@2,1", "app@3,1", "uptime@4,1"])
        let noBattery = HostSectionView.placement(StatusSamples.host(battery: false).cards).map { "\($0.kind.rawValue)@\($0.column),\($0.row)" }
        #expect(noBattery == ["cpu@0,0", "memory@1,0", "disk@2,0", "swap@3,0", "claude@4,0", "app@2,1", "uptime@3,1"])
    }
}

@Suite("Narrow page", .serialized)
@MainActor
struct NarrowPageTests {
    @Test func narrowPageFallsBackWithoutOverlaps() {
        // The main pane at its 560 pt minimum.
        let harness = StatusHarness(size: CGSize(width: 220 + 560, height: 900))
        defer { harness.tearDown() }
        let page = harness.page
        let inner: CGFloat = 560 - 72
        // Columns stack: HOOKS, then MCP, then REMOTE, all full width.
        #expect(page.hooks.frame.width == inner && page.mcp.frame.width == inner && page.remote.frame.width == inner)
        #expect(page.hooks.frame.maxY < page.mcp.frame.minY && page.mcp.frame.maxY < page.remote.frame.minY)
        // Accounts (FB compact cards): as many columns as fit cards of their content's width, the
        // fewest that keep them at most 300; host: three equal columns.
        #expect(AccountsSectionView.columns(forWidth: inner, minimumCard: 260) == 1)
        #expect(AccountsSectionView.columns(forWidth: inner) == 2)
        #expect(AccountsSectionView.columns(forWidth: 700) == 3)
        #expect(AccountsSectionView.columns(forWidth: 1148) == 4)
        #expect(HostSectionView.columns(forWidth: inner) == HostSectionView.narrowColumns)
        let cards = page.accounts.orderedCards.map(\.frame) + [page.accounts.addCard.frame]
        for (i, a) in cards.enumerated() {
            for b in cards[(i + 1)...] { #expect(!a.intersects(b)) }
        }
        let hostFrames = Array(page.host.cards.values.map(\.frame))
        for (i, a) in hostFrames.enumerated() {
            for b in hostFrames[(i + 1)...] { #expect(!a.intersects(b)) }
            #expect(a.maxX <= inner + 0.5)
        }
        #expect(page.anchor(of: .hooks) < page.anchor(of: .mcp))
    }
}
