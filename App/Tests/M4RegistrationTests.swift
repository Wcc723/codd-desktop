import CoddClaudeSettings
import CoddDialogsUI
import CoddHooks
import CoddNotes
import Foundation
import Testing
@testable import CODD

// M4 I2b: the Claude Code registration (D22) on temp `.claude.json` files through the I2a route
// rig (a real hook server on a test port, its own config.json), the guard for the real paths, the
// token rotation (D23) and the Codex snippet through a private pasteboard. Never the real
// `~/.claude.json`, never `~/.codex`, never a claude.

/// A made-up `.claude.json` in Claude's layout (`JSON.stringify(x, null, 2)`, no final newline),
/// with other members Claude rewrites and another user's server.
enum ClaudeJSONFixture {
    static let original = """
    {
      "numStartups": 41,
      "projects": {
        "/tmp/work": {
          "allowedTools": [],
          "mcpServers": {}
        }
      },
      "mcpServers": {
        "pencil": {
          "type": "stdio",
          "command": "pencil-mcp",
          "env": {
            "PENCIL_TOKEN": "made-up-secret-1"
          }
        }
      },
      "oauthAccount": {
        "displayName": "工作"
      }
    }
    """

    static func write(_ text: String = original, to path: String) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    static func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
}

@MainActor
final class RegistrationRig {
    let routes: MCPRouteRig
    let file: String
    let service: MCPRegistrationService

    init(_ prefix: String, write: Bool = true) async throws {
        routes = try await MCPRouteRig(prefix)
        file = routes.folder + "/claude.json"
        if write { try ClaudeJSONFixture.write(to: file) }
        service = MCPRegistrationService(target: .file(URL(fileURLWithPath: file)), backupsIndex: URL(fileURLWithPath: routes.folder + "/data/claude-settings-backups.json"),
                                         holders: routes.store, mcp: routes.mcp, log: { _ in })
        service.lockWait = .milliseconds(300)
        routes.mcp.registrationFile = URL(fileURLWithPath: file)
    }

    var url: String { "http://127.0.0.1:\(routes.port)/mcp" }

    func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: routes.folder)) ?? []).filter { $0.hasPrefix("claude.json.codd-bak-") }.sorted()
    }

    func close() async { await routes.close() }
}

@Suite("M4 registration (D22, D23)", .serialized)
@MainActor
struct M4RegistrationTests {
    @Test func planIsMaskedApplyBacksUpAndRemoveGivesTheOriginalBack() async throws {
        let rig = try await RegistrationRig("codd-m4r-apply")
        // CODE-3: a world-readable file gets the token only as 0600 (file and backup), and dialog B says so.
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.file)
        func mode(_ path: String) -> Int? { (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
        let token = rig.routes.mcpToken
        let plan = try #require(try? await rig.service.plan(.register).get())
        #expect(plan.summary == "只會在 mcpServers 加入 codd，其他設定不變" && !plan.upToDate)
        #expect(!plan.diff.contains { $0.text.contains(token) }, "the token is never shown")
        #expect(plan.diff.contains { $0.text.contains("\"X-CODD-Token\": \"••••\"") })
        #expect(!plan.diff.contains { $0.text.contains("made-up-secret-1") }, "other servers' secrets neither")
        let model = rig.service.diffModel(plan)
        #expect(model.dialogTitle == "MCP 註冊 · 預覽變更" && model.canConfirm
            && model.summary == [plan.summary, "檔案權限 0644 → 0600：內含 token，不讓其他帳號讀取（備份同樣 0600）"])
        #expect(model.footerNote == "只動 mcpServers 裡的 codd，其他設定不碰" && model.backupPath.hasSuffix(plan.backupName))
        #expect(rig.service.lastPlan?.added == plan.addedLines)
        // I4b: the dump carries the dialog's diff, masked the same way (the e2e's B8 checks it).
        let dumped = try #require(rig.service.lastPlan?.diff)
        #expect(dumped.count == plan.diff.count && dumped.contains { $0.hasPrefix("+ ") && $0.contains("\"X-CODD-Token\": \"••••\"") })
        #expect(!dumped.contains { $0.contains(token) } && !dumped.contains { $0.contains("made-up-secret-1") })

        let applied = try #require(try? await rig.service.apply(plan).get())
        #expect(applied.wrote && applied.backup != nil)
        #expect(rig.backups().count == 1, "the backup sits next to the file")
        #expect(ClaudeJSONFixture.read(rig.routes.folder + "/" + rig.backups()[0]) == ClaudeJSONFixture.original, "exactly the replaced bytes")
        #expect(mode(rig.file) == 0o600 && mode(rig.routes.folder + "/" + rig.backups()[0]) == 0o600)
        let written = ClaudeJSONFixture.read(rig.file)
        #expect(written.contains("\"codd\": {") && written.contains(rig.url) && written.contains(token))
        #expect(written.contains("\"numStartups\": 41") && written.contains("made-up-secret-1") && written.contains("\"displayName\": \"工作\""))
        #expect(!FileManager.default.fileExists(atPath: rig.file + ".lock"), "no lock dir left")
        #expect(rig.routes.mcp.claudeCode == .registered(tokenMatches: true))
        let rows = MCPRegistrationRows.status(rig.routes.mcp.claudeCode, claudeCodeReason: rig.service.claudeCodeReason)
        #expect(rows[0].state == "● 已註冊" && rows[0].actionTitle == "移除" && rows[0].isActionable)
        #expect(MCPRegistrationRows.claudeCodeKind(rig.routes.mcp.claudeCode) == .remove)
        let toast = rig.service.successText(.register, backup: applied.backup.map(\.lastPathComponent))
        #expect(toast.hasPrefix("已註冊到 Claude Code"))

        // 移除 the same way: the original bytes come back (the file already had mcpServers).
        let removal = try #require(try? await rig.service.plan(.remove).get())
        #expect(removal.summary == "只會從 mcpServers 移除 codd，其他設定不變")
        _ = try #require(try? await rig.service.apply(removal).get())
        #expect(ClaudeJSONFixture.read(rig.file) == ClaudeJSONFixture.original)
        #expect(rig.backups().count == 2 && rig.routes.mcp.claudeCode == .notRegistered)
        let index = ClaudeJSONFixture.read(rig.routes.folder + "/data/claude-settings-backups.json")
        #expect(index.contains("mcp-register") && index.contains("mcp-remove") && !index.contains(token))
        await rig.close()
    }

    @Test func dumpedDiffLinesKeepTheirKind() {
        let lines = MCPRegistrationService.diffText([
            DiffLine(kind: .hunk, text: "@@ -1,2 +1,3 @@  \"mcpServers\""),
            DiffLine(kind: .context, oldNumber: 1, newNumber: 1, text: "  \"mcpServers\": {"),
            DiffLine(kind: .added, newNumber: 2, text: "    \"codd\": {"),
            DiffLine(kind: .removed, oldNumber: 2, text: "  }"),
            DiffLine(kind: .elided, text: "…（保留既有 1 個 MCP server）"),
        ])
        #expect(lines == ["@@ -1,2 +1,3 @@  \"mcpServers\"", "    \"mcpServers\": {", "+     \"codd\": {", "-   }",
                          "…（保留既有 1 個 MCP server）"])
    }

    @Test func aChangeOutsideMcpServersSinceThePreviewIsRebased() async throws {
        let rig = try await RegistrationRig("codd-m4r-rebase")
        let plan = try #require(try? await rig.service.plan(.register).get())
        // Claude rewrites its counters while sessions run.
        try ClaudeJSONFixture.write(ClaudeJSONFixture.original.replacingOccurrences(of: "\"numStartups\": 41", with: "\"numStartups\": 42"),
                                    to: rig.file)
        let applied = try #require(try? await rig.service.apply(plan).get())
        #expect(applied.wrote)
        let written = ClaudeJSONFixture.read(rig.file)
        #expect(written.contains("\"numStartups\": 42") && written.contains("\"codd\": {"), "Claude's fresh bytes kept, the edit applied")
        await rig.close()
    }

    @Test func aChangeInsideMcpServersSinceThePreviewIsRefused() async throws {
        let rig = try await RegistrationRig("codd-m4r-changed")
        let plan = try #require(try? await rig.service.plan(.register).get())
        let changed = ClaudeJSONFixture.original.replacingOccurrences(of: "\"command\": \"pencil-mcp\"", with: "\"command\": \"pencil-mcp2\"")
        try ClaudeJSONFixture.write(changed, to: rig.file)
        let result = await rig.service.apply(plan)
        #expect(result.failureValue == .installer(.changedSinceRead))
        #expect(ClaudeJSONFixture.read(rig.file) == changed, "nothing written")
        #expect(rig.service.lastError == "~/.claude.json 的 mcpServers 在預覽後被改過，請重新預覽")
        #expect(rig.backups().isEmpty)
        await rig.close()
    }

    @Test func theStepsDebugFlagsParseAndStayOutOfRelease() {
        let o = RealModeOptions.parse(arguments: ["CODD", "-codd-notes-send", "rwd-punch-k7x2:submit", "-codd-mcp-rotate", "YES",
                                                  "-codd-claude-json", "~/x/claude.json", "-codd-mcp-register-plan", "Claude-Code",
                                                  "-codd-mcp-register-apply", "YES", "-codd-mcp-register-apply-delay", "1500",
                                                  "-codd-show", "split"], environment: [:], home: "/Users/test")
        #expect(o.notesSend == "rwd-punch-k7x2:submit" && o.mcpRotate && o.claudeJSON == "/Users/test/x/claude.json")
        #expect(o.mcpRegisterPlan == "claude-code" && o.mcpRegisterApply && o.mcpRegisterApplyDelayMilliseconds == 1500)
        #expect(o.showKeyword == "split")
        let bad = RealModeOptions.parse(arguments: ["CODD", "-codd-mcp-register-plan", "nope", "-codd-mcp-register-apply-delay", "99999"],
                                        environment: [:], home: "/Users/test")
        #expect(bad.mcpRegisterPlan == nil && bad.mcpRegisterApplyDelayMilliseconds == nil)
        #expect(o.releaseSubset.claudeJSON == nil && !o.releaseSubset.mcpRotate && o.releaseSubset.notesSend == nil)
    }

    @Test func refusalsAreTheBriefsTexts() {
        typealias S = MCPRegistrationService
        #expect(S.message(.installer(.lockBusy)) == "Claude Code 正在寫入 ~/.claude.json，請稍後再試")
        #expect(S.message(.installer(.missingFile)) == "找不到 ~/.claude.json，請先執行一次 claude")
        #expect(S.message(.installer(.changedSinceRead)) == "~/.claude.json 的 mcpServers 在預覽後被改過，請重新預覽")
        #expect(S.message(.installer(.staleLock("~/.claude.json.lock 看起來是殘留的鎖"))) == "~/.claude.json.lock 看起來是殘留的鎖")
        #expect(S.message(.unavailable(MCPRegistrationTarget.testRootReason)) == "測試資料根目錄不會寫入 ~/.claude.json")
    }

    @Test func aMissingFileIsAToastNotADialog() async throws {
        let rig = try await RegistrationRig("codd-m4r-missing", write: false)
        #expect(await rig.service.plan(.register).failureValue == .installer(.missingFile))
        #expect(!FileManager.default.fileExists(atPath: rig.file), "never created")
        await rig.close()
    }

    @Test func theRealHomesFilesAreRefusedBeforeReading() throws {
        let root = try m3TempFolder("codd-m4r-guard")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let home = root + "/home"
        try FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)
        let claude = ClaudeDirectory(path: home + "/.claude")
        func resolve(_ file: String?, standard: Bool = false) -> MCPRegistrationTarget {
            MCPRegistrationTarget.resolve(standardRoot: standard, claudeDirectory: claude, debugFile: file, home: home)
        }
        #expect(resolve(nil) == .disabled(MCPRegistrationTarget.testRootReason), "a test root writes nothing by itself")
        #expect(resolve(nil, standard: true).file?.path == home + "/.claude.json", "the standard root: ~/.claude.json")
        #expect(resolve(home + "/.claude.json").disabledReason != nil)
        #expect(resolve(home + "/.claude/../.claude.json").disabledReason != nil, "lexically")
        #expect(resolve(home + "/.claude-swap-backup/x.json").disabledReason != nil)
        #expect(resolve(home + "/.claude/settings.json").disabledReason != nil)
        // A link to the real file, and a dangling link into ~/.claude (its destination does not exist).
        try FileManager.default.createSymbolicLink(atPath: root + "/link.json", withDestinationPath: home + "/.claude.json")
        try FileManager.default.createSymbolicLink(atPath: root + "/dangling.json", withDestinationPath: home + "/.claude/none.json")
        #expect(resolve(root + "/link.json").disabledReason != nil)
        #expect(resolve(root + "/dangling.json").disabledReason != nil)
        #expect(resolve(root + "/claude.json").file?.lastPathComponent == "claude.json", "a temp file is fine")
        // The rows say why.
        let rows = MCPRegistrationRows.settings(.unknown, claudeCodeReason: MCPRegistrationTarget.testRootReason)
        #expect(!rows[0].isActionable && rows[0].hint == MCPRegistrationTarget.testRootReason && rows[0].toolTip == rows[0].hint)
    }

    @Test func aDisabledTargetPlansNothing() async throws {
        let rig = try await RegistrationRig("codd-m4r-disabled", write: false)
        let service = MCPRegistrationService(target: .disabled(MCPRegistrationTarget.testRootReason), backupsIndex: nil,
                                             holders: rig.routes.store, mcp: rig.routes.mcp, log: { _ in })
        #expect(service.claudeCodeReason == MCPRegistrationTarget.testRootReason)
        #expect(await service.plan(.register).failureValue == .unavailable(MCPRegistrationTarget.testRootReason))
        #expect(service.codexReason == nil, "Codex only needs the endpoint and the token")
        await rig.close()
    }

    @Test func rotationNeedsReregisteringAndKillsOldNoteURLs() async throws {
        let rig = try await RegistrationRig("codd-m4r-rotate")
        let old = rig.routes.mcpToken
        let hookToken = rig.routes.hookToken
        let note = try await rig.routes.note("網址筆記", "可以用 curl 讀")
        let plan = try #require(try? await rig.service.plan(.register).get())
        _ = try #require(try? await rig.service.apply(plan).get())
        #expect(rig.service.canRotate)
        #expect(await rig.service.rotateToken() == nil)
        let new = rig.routes.mcpToken
        #expect(new != old && HookConfig.isValidToken(new) && rig.routes.hookToken == hookToken, "the hook token stays")
        let onDisk = ClaudeJSONFixture.read(rig.routes.folder + "/data/config.json")
        #expect(onDisk.contains(new) && !onDisk.contains(old))
        #expect(rig.service.tokenRotatedAt != nil)
        #expect(rig.routes.mcp.claudeCode == .registered(tokenMatches: false), "D23: needs re-registering")
        #expect(MCPRegistrationRows.settings(rig.routes.mcp.claudeCode)[0].hint == "需要重新註冊（token 已輪替）")
        #expect(MCPRegistrationRows.status(rig.routes.mcp.claudeCode)[0].state == "◆ 需要重新註冊")
        #expect(MCPRegistrationRows.claudeCodeKind(rig.routes.mcp.claudeCode) == .register, "註冊 updates the token in place")
        // Old note URLs die at once, new ones answer; the per-session token is unchanged.
        let stale = try await rig.routes.send("GET", "/n/\(note.rawValue).md?t=\(MCPAuth.noteURLToken(mcpToken: old, noteID: note.rawValue))")
        #expect(stale.status == 404)
        let fresh = try await rig.routes.send("GET", "/n/\(note.rawValue).md?t=\(MCPAuth.noteURLToken(mcpToken: new, noteID: note.rawValue))")
        #expect(fresh.status == 200)
        let session = try await rig.routes.rpc("ping", headers: rig.routes.sessionHeaders)
        #expect(session.status == 200)
        // Re-register: only the token changes.
        let again = try #require(try? await rig.service.plan(.register).get())
        #expect(again.summary == "只會更新 mcpServers 裡 codd 的 token，其他設定不變")
        await rig.close()
    }

    /// Review RV-3: a file registered before CODE-3 (the current token in it, 0644) shows `收緊`, whose
    /// plan only makes it and the token-holding backups 0600; afterwards the row is `● 已註冊` again.
    @Test func aReadableRegisteredFileIsTightenedWithoutAWrite() async throws {
        let rig = try await RegistrationRig("codd-m4r-tighten", write: false)
        let fm = FileManager.default
        func mode(_ path: String) -> Int? { (try? fm.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
        let registered = ClaudeJSONFixture.original.replacingOccurrences(of: "    \"pencil\": {", with: """
                "codd": {
                  "type": "http",
                  "url": "\(rig.url)",
                  "headers": {
                    "X-CODD-Token": "\(rig.routes.mcpToken)"
                  }
                },
                "pencil": {
            """)
        try ClaudeJSONFixture.write(registered, to: rig.file)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: rig.file)
        let oldBackup = rig.routes.folder + "/claude.json.codd-bak-20261001-090000"
        try ClaudeJSONFixture.write(registered, to: oldBackup)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: oldBackup)
        await rig.routes.mcp.refreshRegistrations()
        #expect(rig.routes.mcp.claudeCode == .registered(tokenMatches: true) && rig.routes.mcp.claudeCodeExposed)
        let exposed = rig.routes.mcp.claudeCodeExposed
        let row = MCPRegistrationRows.status(rig.routes.mcp.claudeCode, exposed: exposed)[0]
        #expect(row.state == "◆ 權限過寬" && row.actionTitle == "收緊" && row.isActionable)
        #expect(MCPRegistrationRows.settings(rig.routes.mcp.claudeCode, exposed: exposed)[0].hint == "已註冊 · 檔案權限過寬，其他帳號讀得到 token")
        #expect(MCPRegistrationRows.claudeCodeKind(rig.routes.mcp.claudeCode, exposed: exposed) == .register)
        let plan = try #require(try? await rig.service.plan(.register).get())
        #expect(plan.modeOnly && !plan.upToDate)
        let model = rig.service.diffModel(plan)
        #expect(model.canConfirm && model.applyTitle == "收緊權限" && model.backupPath.isEmpty && !model.hasChanges)
        #expect(model.summary == ["mcpServers 已是最新，只把含 token 的檔案權限改成 0600",
                                  "檔案權限 0644 → 0600：內含 token，不讓其他帳號讀取（另有 1 個備份同樣改成 0600）"])
        let applied = try #require(try? await rig.service.apply(plan).get())
        #expect(!applied.wrote && applied.backup == nil && applied.tightened == 2)
        #expect(mode(rig.file) == 0o600 && mode(oldBackup) == 0o600 && ClaudeJSONFixture.read(rig.file) == registered)
        #expect(rig.backups() == ["claude.json.codd-bak-20261001-090000"], "no new backup")
        #expect(!rig.routes.mcp.claudeCodeExposed, "refreshed after the write")
        #expect(MCPRegistrationRows.status(rig.routes.mcp.claudeCode, exposed: rig.routes.mcp.claudeCodeExposed)[0].state == "● 已註冊")
        #expect(rig.service.successText(.register, backup: nil, modeOnly: true) == "已把含 token 的檔案改成 0600（\(rig.service.displayPath)）")
        await rig.close()
    }

    @Test func codexSnippetGoesThroughThePrivatePasteboard() async throws {
        let rig = try await RegistrationRig("codd-m4r-codex", write: false)
        let snippet = try #require(rig.service.codexSnippet())
        #expect(snippet == CodexMCPSnippet.toml(url: rig.url, token: rig.routes.mcpToken))
        #expect(snippet.hasPrefix("[mcp_servers.codd]\nurl = \"\(rig.url)\"\nhttp_headers = { \"X-CODD-Token\" = \""))
        let pasteboard = CoddPasteboard(isBackground: true, log: { _ in })
        #expect(pasteboard.write(snippet, userAction: true) == .private, "D39: a background run never writes the general pasteboard")
        #expect(CoddPasteboard.privateString() == snippet)
        let view = SnippetDialogView(title: MCPRegistrationService.codexTitle, message: MCPRegistrationService.codexMessage, snippet: snippet,
                                     onCopy: {}, onClose: {})
        #expect(view.title == "註冊到 Codex" && view.messageText == "把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）。"
            + "內含 token，存檔後執行 chmod 600 ~/.codex/config.toml，不讓其他帳號讀取", "review RV-3: the 0600 advice")
        #expect(view.copyTitle == "複製" && view.snippet == snippet)
        view.markCopied()
        #expect(view.copyTitle == "已複製")
        #expect(!FileManager.default.fileExists(atPath: rig.routes.folder + "/home/.codex"), "CODD never writes ~/.codex")
        await rig.close()
    }
}

extension Result {
    /// The failure, or nil (tests).
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
