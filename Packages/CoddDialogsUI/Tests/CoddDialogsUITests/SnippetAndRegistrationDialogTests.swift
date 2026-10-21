import AppKit
import CoddUI
import Testing
@testable import CoddDialogsUI

/// M4 I2b's additive parts: dialog B with the `~/.claude.json` registration's own title, footer
/// and empty line, and the snippet dialog (`註冊到 Codex`).
@Suite("M4 · registration dialog B and the snippet dialog", .serialized)
@MainActor
struct SnippetAndRegistrationDialogTests {
    @Test func dialogBTakesTheRegistrationsTexts() {
        let model = HookDiffModel(settingsPath: "~/.claude.json", summary: ["只會在 mcpServers 加入 codd，其他設定不變"],
                                  lines: [DiffLineModel(.added, newNumber: 12, text: "    \"codd\": {")], added: 1, removed: 0,
                                  backupPath: "~/.claude.json.codd-bak-20261018-101500", dialogTitle: "MCP 註冊 · 預覽變更",
                                  footerNote: "只動 mcpServers 裡的 codd，其他設定不碰")
        let harness = DialogHarness(HookDiffDialogView(model: model, onApply: {}, onCancel: {}))
        defer { harness.tearDown() }
        #expect(harness.view.title == "MCP 註冊 · 預覽變更")
        #expect(harness.view.questionText == "預覽 ~/.claude.json 變更")
        #expect(harness.view.footerNote == "只動 mcpServers 裡的 codd，其他設定不碰")
        #expect(harness.view.summaryTexts == ["只會在 mcpServers 加入 codd，其他設定不變"] && harness.view.applyButton.isEnabled)
        // The hooks' defaults are unchanged.
        let hooks = DialogHarness(HookDiffDialogView(model: DialogSamples.hookDiff(), onApply: {}, onCancel: {}))
        defer { hooks.tearDown() }
        #expect(hooks.view.title == "Hook diff · 預覽變更" && hooks.view.footerNote == "只動 hooks 與 statusLine，其他 key 不碰")
    }

    /// Review RV-3: the tighten-only registration plan has an empty diff but can be applied.
    @Test func anEmptyDiffAppliesOnlyWhenTheModelSaysSo() {
        func model(_ appliesWithoutDiff: Bool) -> HookDiffModel {
            HookDiffModel(settingsPath: "~/.claude.json", summary: ["mcpServers 已是最新，只把含 token 的檔案權限改成 0600"],
                          lines: [], added: 0, removed: 0, applyTitle: "收緊權限", dialogTitle: "MCP 註冊 · 預覽變更",
                          noChangesText: "// mcpServers 已是最新，只改檔案權限", appliesWithoutDiff: appliesWithoutDiff)
        }
        #expect(!model(false).canConfirm && model(true).canConfirm)
        let harness = DialogHarness(HookDiffDialogView(model: model(true), onApply: {}, onCancel: {}))
        defer { harness.tearDown() }
        #expect(harness.view.applyButton.isEnabled && harness.view.applyButton.label == "收緊權限")
    }

    @Test func snippetDialogCopiesAndCloses() {
        var copies = 0
        var closes = 0
        let snippet = "[mcp_servers.codd]\nurl = \"http://127.0.0.1:47821/mcp\"\nhttp_headers = { \"X-CODD-Token\" = \"made-up\" }\n"
        let harness = DialogHarness(SnippetDialogView(title: "註冊到 Codex", message: "把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）",
                                                      snippet: snippet, onCopy: { copies += 1 }, onClose: { closes += 1 }))
        defer { harness.tearDown() }
        let view = harness.view
        #expect(view.title == "註冊到 Codex" && view.dialogWidth == 560)
        #expect(view.messageText == "把下面這段加到 ~/.codex/config.toml（CODD 不會改這個檔案）")
        #expect(view.allButtonLabels().suffix(2) == ["關閉", "複製"])
        view.copyButton.performClick(nil)
        #expect(copies == 1)
        view.markCopied()
        #expect(view.copyTitle == "已複製")
        view.closeButton.performClick(nil)
        #expect(closes == 1)
    }
}
