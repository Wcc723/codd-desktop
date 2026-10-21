import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// M4 (C9, D21–D23): STATUS › MCP SERVER from `StatusPageModel.mcp` — running with clients,
/// running without, stopped, the M3 placeholder for a nil model; the nav item; the buttons; the
/// per-section diffing; the M3 call shapes.
@Suite("MCP SERVER card", .serialized)
@MainActor
struct M4MCPCardTests {
    @Test func runningWithClientsMatchesTheArtboard() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let section = harness.page.mcp
        #expect(!section.showsPlaceholder && !section.card.isHidden)
        let texts = section.card.visibleTexts
        let expected = [
            "CODDMCP · ~/Library/Application Support/CODD/notes",
            "RUNNING", "127.0.0.1:47821", "·", "3 clients", "只接受本機連線",
            "●", "修正登入 API 401", "Claude Code", "連線 42m",
            "●", "打卡頁 RWD 調整", "Claude Code", "連線 1h18m",
            "●", "codex", "Codex CLI", "連線 12m",
            "REGISTRATIONS", "註冊到其他 app",
            "Claude Code", "user scope", "● 已註冊", "移除",
            "Codex", "~/.codex/config.toml", "○ 未註冊", "註冊",
            "Claude Desktop", "擴充功能", "○ 未安裝", "FUTURE", "安裝 .MCPB",
            "TOKEN", "••••", "client 連線時需附上", "輪替",
        ]
        #expect(texts.missing(expected) == [])
        #expect(texts.containsInOrder(expected), "\(texts)")
        #expect(section.visibleTexts.first == "MCP SERVER")
        #expect(section.card.runText == "RUNNING 127.0.0.1:47821 · 3 clients 只接受本機連線")
        #expect(section.card.noteText == nil && !section.card.showsNoClients)
        #expect(section.card.clientRows.count == 3 && section.card.registrationRows.count == 3)
        #expect(section.card.lamp.text == "●")
        // The card sits in the right column above REMOTE, which follows it 10 pt below.
        let page = harness.page
        #expect(abs(page.mcp.frame.minX - (36 + 638 + 20)) < 1)
        #expect(abs(page.remote.frame.minY - (page.mcp.frame.maxY + 10)) < 1)
        #expect(page.mcp.frame.height == page.mcp.height(forWidth: page.mcp.frame.width))
        // No row overlaps another inside the card.
        let rows = (section.card.clientRows as [NSView]) + section.card.registrationRows
        for (i, a) in rows.enumerated() {
            for b in rows[(i + 1)...] { #expect(!a.frame.intersects(b.frame)) }
            #expect(a.frame.maxY <= section.card.bounds.height - 17)
        }
    }

    @Test func runningWithoutClients() {
        let harness = StatusHarness(StatusSamples.model(.mcpNoClients))
        defer { harness.tearDown() }
        let card = harness.page.mcp.card
        #expect(card.runText == "RUNNING 127.0.0.1:47821 · 0 clients 只接受本機連線")
        #expect(card.showsNoClients && card.clientRows.isEmpty)
        #expect(card.visibleTexts.containsInOrder(["RUNNING", "// 沒有 client 連線", "REGISTRATIONS", "Claude Code", "◆ 需要重新註冊", "註冊"]))
        #expect(harness.sidebar.navItem(.mcp).map { Set($0.statusVisibleTexts()) } == Set(["●", "MCP", "本機 server", "0 clients"]))
    }

    @Test func stoppedShowsTheNote() {
        let harness = StatusHarness(StatusSamples.model(.mcpStopped))
        defer { harness.tearDown() }
        let card = harness.page.mcp.card
        #expect(card.runText == "STOPPED 127.0.0.1:47821")
        #expect(card.noteText == "// hook server 未執行，MCP 暫停")
        #expect(!card.showsNoClients, "the note explains why nobody is connected")
        #expect(card.lamp.text == "○")
        #expect(!card.visibleTexts.contains("只接受本機連線"))
        #expect(card.visibleTexts.containsInOrder(["STOPPED", "// hook server 未執行，MCP 暫停", "REGISTRATIONS", "TOKEN"]))
        #expect(harness.sidebar.navItem(.mcp).map { Set($0.statusVisibleTexts()) } == Set(["○", "MCP", "本機 server", "0 clients"]))
        // Stopped without a note: the empty comment comes back.
        var model = StatusSamples.model(.mcpStopped)
        model.mcp?.note = nil
        harness.apply(model)
        #expect(card.noteText == nil && card.showsNoClients)
    }

    @Test func nilKeepsThePlaceholder() {
        let harness = StatusHarness(StatusSamples.model(.mcpPlaceholder))
        defer { harness.tearDown() }
        let section = harness.page.mcp
        #expect(section.showsPlaceholder && section.card.isHidden)
        #expect(section.visibleTexts == ["MCP SERVER", MCPSectionView.note])
        #expect(section.frame.height == SectionHeaderRow.height + 10 + 52)
        // The model arrives later: the card replaces the placeholder and the page grows.
        let before = harness.page.mcp.frame.height
        harness.apply(StatusSamples.spec())
        #expect(!section.showsPlaceholder && !section.card.isHidden)
        #expect(section.frame.height > before)
        harness.apply(StatusSamples.model(.mcpPlaceholder))
        #expect(section.showsPlaceholder && section.frame.height == before)
    }

    @Test func navItemValue() {
        #expect(StatusNavItem.mcp(StatusSamples.mcp) == StatusNavItem(id: .mcp, glyph: .ok, value: "3 clients"))
        var stopped = StatusSamples.mcp
        stopped.running = false
        #expect(StatusNavItem.mcp(stopped) == StatusNavItem(id: .mcp, glyph: .off, value: "0 clients"))
        #expect(StatusNavItem.mcp(nil) == StatusNavItem(id: .mcp, glyph: .off, value: "—"))
        #expect(StatusNavItem.mcp(StatusSamples.mcp).subtitle == "本機 server")
        let harness = StatusHarness()
        defer { harness.tearDown() }
        #expect(harness.sidebar.navItem(.mcp).map { Set($0.statusVisibleTexts()) } == Set(["●", "MCP", "本機 server", "3 clients"]))
    }

    @Test func buttonsFireTheirActions() throws {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let card = harness.page.mcp.card
        let buttons = card.registrationRows.map(\.button)
        #expect(buttons.map(\.label) == ["移除", "註冊", "安裝 .mcpb"])
        #expect(buttons.map(\.isEnabled) == [true, true, false])
        #expect(buttons.map { $0.accessibilityLabel() ?? "" } == ["從 Claude Code 移除 MCP", "註冊到 Codex", "安裝 .mcpb 到 Claude Desktop"])
        for button in buttons { button.performClick(nil) }
        card.rotateButton.performClick(nil)
        #expect(harness.log.events == ["mcpRegistration:claude-code", "mcpRegistration:codex", "rotateMCPToken"])

        // The app disables what it has not wired yet (I2a: registration and rotation come in I2b).
        var model = StatusSamples.spec()
        model.mcp?.canRotateToken = false
        model.mcp?.registrations[0].actionEnabled = false
        model.mcp?.registrations[0].toolTip = "註冊在 I2b 接上"
        harness.apply(model)
        #expect(!card.rotateButton.isEnabled && !buttons[0].isEnabled)
        #expect(buttons[0].toolTip == "註冊在 I2b 接上")
        buttons[0].performClick(nil)
        card.rotateButton.performClick(nil)
        #expect(harness.log.events.count == 3)
        // `setActions` reaches the rows built earlier.
        let other = ActionLog()
        harness.page.setActions(other.actions)
        buttons[1].performClick(nil)
        #expect(other.events == ["mcpRegistration:codex"])
    }

    @Test func aClientCountChangeRebuildsOnlyTheMCPCard() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let page = harness.page
        func counts() -> [Int] {
            [page.host.configureCount, page.accounts.configureCount, page.hooks.configureCount, page.headerConfigureCount]
                + page.accounts.orderedCards.map(\.configureCount)
        }
        let start = counts()
        let mcpStart = page.mcp.configureCount
        harness.apply(StatusSamples.spec())
        #expect(counts() == start && page.mcp.configureCount == mcpStart)

        var model = StatusSamples.spec()
        model.mcp?.clientsCount = 4
        model.mcp?.clients.append(StatusMCPClient(id: "ext-x", title: "cursor", kind: "cursor-vscode", connectedFor: "連線 1m"))
        harness.apply(model)
        #expect(counts() == start)
        #expect(page.mcp.configureCount == mcpStart + 1)
        #expect(page.mcp.card.clientRows.count == 4)
        #expect(page.mcp.card.runText.contains("4 clients"))
        #expect(page.mcp.card.visibleTexts.containsInOrder(["codex", "cursor", "cursor-vscode", "連線 1m"]))
        // A connection age only: the same rows are reused.
        let rows = page.mcp.card.clientRows.map(ObjectIdentifier.init)
        model.mcp?.clients[0].connectedFor = "連線 43m"
        harness.apply(model)
        #expect(page.mcp.card.clientRows.map(ObjectIdentifier.init) == rows)
        #expect(page.mcp.card.visibleTexts.contains("連線 43m"))
        #expect(counts() == start)
    }

    @Test func registrationRules() {
        let future = StatusSamples.mcpRegistrations[2]
        #expect(!future.isActionable && future.chip == "FUTURE")
        #expect(StatusSamples.mcpRegistrations[0].isActionable && StatusSamples.mcpRegistrations[1].isActionable)
        #expect(MCPRegistrationRowView.accessibilityLabel(StatusMCPRegistration(id: "x", name: "X", hint: "", state: "", stateTone: .muted)) == "X")
        #expect(StatusMCPModel.clientsText(1) == "1 clients")
    }

    /// D40: `App/Real/StatusPageData.swift` builds `StatusPageModel(…)` and `App/Session/StatusArea.swift`
    /// `StatusPageActions(…)` with M3's argument lists; they still compile and keep the placeholder.
    @Test func m3CallShapesStillCompile() {
        let spec = StatusSamples.spec()
        let m3 = StatusPageModel(updatedAt: spec.updatedAt, refreshSeconds: 5, paused: false, live: true, nav: spec.nav,
                                 needsYou: spec.needsYou, counts: spec.counts, liveCount: 13, host: spec.host,
                                 accounts: spec.accounts, hooks: spec.hooks, remote: spec.remote)
        #expect(m3.mcp == nil)
        let actions = StatusPageActions(
            refresh: {}, togglePause: {}, openSessions: {}, openSession: { _ in }, switchAccount: { _ in }, addAccount: {},
            openAutoSwitch: {}, toggleAutoSwitch: {}, previewHooks: {}, update: {}, uninstall: {}, removeLegacy: {},
            disableDuplicateNotifications: {}, openRemoteSettings: {})
        actions.onMCPRegistration("codex")
        actions.onRotateMCPToken()
        let harness = StatusHarness(m3)
        defer { harness.tearDown() }
        #expect(harness.page.mcp.showsPlaceholder)
        #expect(harness.pageTexts.containsInOrder(["MCP SERVER", MCPSectionView.note]))
    }
}
