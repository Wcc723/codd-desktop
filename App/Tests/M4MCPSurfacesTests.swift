import CoddSettingsUI
import CoddStatusUI
import CoddUI
import Foundation
import Testing
@testable import CODD

/// I2a's surfaces: STATUS › MCP SERVER and its nav item, Settings › 筆記本 & MCP / 進階 › 重建筆記索引
/// and 清理's account select, with the registration buttons held back until I2b.
@Suite("M4 MCP · STATUS and Settings facts")
@MainActor
struct M4MCPSurfacesTests {
    @Test func settingsNotebookFactsAndTheIndexLine() {
        let info = SettingsInfoBuilder.notebook(notesPath: "~/data/notes", mcp: nil, hasMCPToken: true, lastRebuild: (128, 412),
                                                rebuilding: false, notesReady: true)
        #expect(info.notesPath == "~/data/notes" && info.tokenMasked == "••••••••••••")
        #expect(info.indexLine == "已重建 · 128 則 · 0.4 s" && info.rebuildEnabled && info.canOpenFolder)
        #expect(!info.canRotateToken, "no registration service, no rotation")
        #expect(info.registrations.map(\.id) == ["claude-code", "codex", "claude-desktop"])
        #expect(info.registrations.allSatisfy { !$0.isActionable }, "without a server the buttons say why")
        #expect(info.registrations[0].toolTip == SettingsInfoBuilder.noServer && info.registrations[2].chip == "FUTURE")
        let running = SettingsInfoBuilder.notebook(notesPath: "~/data/notes", mcp: nil, hasMCPToken: false, lastRebuild: nil,
                                                   rebuilding: true, notesReady: true)
        #expect(running.indexLine == "重建中…" && !running.rebuildEnabled && running.tokenMasked.isEmpty)
        let closed = SettingsInfoBuilder.notebook(notesPath: "~/data/notes", mcp: nil, hasMCPToken: true, lastRebuild: nil, rebuilding: false,
                                                  notesReady: false)
        #expect(!closed.rebuildEnabled && closed.indexLine == nil && !closed.mcpRunning && closed.port == nil)
    }

    @Test func registrationHintsFollowTheState() {
        let settings = MCPRegistrationRows.settings(.registered(tokenMatches: false))
        #expect(settings[0].hint == "需要重新註冊（token 已輪替）" && settings[0].isOn)
        #expect(MCPRegistrationRows.settings(.registered(tokenMatches: true))[0].hint == "已註冊 · user scope")
        #expect(MCPRegistrationRows.settings(.notRegistered)[0].hint == "未註冊")
        let status = MCPRegistrationRows.status(.registered(tokenMatches: false))
        #expect(status[0].state == "◆ 需要重新註冊" && status[0].stateTone == .warn)
        #expect(MCPRegistrationRows.status(.unknown)[0].state == "—")
    }

    @Test func condenseAccountsFollowTheGlobalLoginFirst() {
        let accounts = MockAccountStore()
        let rows = SettingsInfoBuilder.condenseAccounts(accounts)
        #expect(rows.first?.id == SettingsCondenseAccount.followID)
        #expect(rows.first?.title.hasPrefix("跟隨全域登入") == true)
        let numbers = rows.dropFirst().compactMap { Int($0.id) }
        #expect(!numbers.isEmpty && numbers == numbers.sorted())
        #expect(SettingsInfoBuilder.condenseAccounts(nil).isEmpty)
    }

    @Test func clientNamesAndEndpointsAreNormalized() {
        #expect(NotesMCPContext.clientKind("claude-code", session: false) == "Claude Code")
        #expect(NotesMCPContext.clientKind("codex-mcp-client", session: false) == "Codex CLI")
        #expect(NotesMCPContext.clientKind(nil, session: true) == "Claude Code")
        #expect(NotesMCPContext.clientKind("  ", session: false) == "external")
        #expect(NotesMCPContext.clientKind("my-agent", session: false) == "my-agent")
        #expect(MCPService.logSafe("evil\nREALHOLDERS forged line") == "evil_REALHOLDERS_forged_line")
        #expect(MCPService.logSafe(String(repeating: "x", count: 100)).count == 60)
        #expect(MCPService.sameEndpoint("http://LOCALHOST:43001/mcp/", "http://127.0.0.1:43001/mcp"))
        #expect(!MCPService.sameEndpoint("http://127.0.0.1:43002/mcp", "http://127.0.0.1:43001/mcp"))
        #expect(MCPPaths.isInside("/a/b/c", "/a/b") && MCPPaths.isInside("/a/b", "/a/b") && !MCPPaths.isInside("/a/bc", "/a/b"))
    }

    @Test func statusNavShowsTheClientsAndMockModeTheSample() {
        let sample = StatusSamples.mcp
        let item = StatusNavItem.mcp(sample)
        #expect(item.value == "3 clients")
        let stopped = StatusMCPModel(running: false, endpoint: "127.0.0.1:43001", clientsCount: 2, notesPath: "~/n",
                                     note: StatusPageData.mcpStoppedNote, canRotateToken: false)
        #expect(StatusNavItem.mcp(stopped).value == "0 clients")
        #expect(StatusPageData.mcpStoppedNote == "// hook server 未執行，MCP 暫停")
    }
}
