import AppKit
import CoddOnboarding
import CoddUI
import Testing
@testable import CoddOnboardingUI

@MainActor
@Suite("The artboard's texts (brand CODD, no node row, the fixed notes path, the D11 wording)")
struct TextTests {
    @Test("step 2 shows the artboard's texts")
    func step2() {
        let harness = Harness()
        defer { harness.tearDown() }
        let texts = harness.texts
        #expect(texts.missing([
            "CODD\n// first boot · 首次啟動設定",
            "偵測環境\nDETECT\n4 項正常 · 1 項待處理",
            "匯入專案\nIMPORT PROJECTS\n已選 9 / 187",
            "安裝 hooks\nHOOKS & STATUSLINE\n◆ 需要更新 · 舊版 4 個事件",
            "筆記本與 MCP\nNOTEBOOK & MCP\n~/…/CODD/notes · :47821",
            "帳號 (cswap)\nACCOUNTS\n偵測到 3 個帳號",
            "完成\nDONE\n開第一個 session",
            "第 3 步按下套用前，不會改動 ~/.claude/settings.json。每一步都能之後在 SETTINGS 調整。",
            "已在用 CODD Web？匯入它的設定 →",
            "1.0.0 (build 1) · macOS 27.0",
            "[ OK ] claude 2.1.302 ~/.local/bin/claude",
            "[ OK ] cswap 0.26.0 · 3 個帳號 ~/.local/bin/cswap",
            "[ .. ] hooks 需要更新（4 個事件） ~/.claude/settings.json · 舊版 CODD web：PreCompact / PostCompact / SubagentStart / SubagentStop",
            "[ OK ] ~/…/CODD 可寫入 ~/Library/Application Support/CODD · MCP 127.0.0.1:47821 可用",
            "[ .. ] projects waiting for operator_",
            "↻ 重新偵測",
            "STEP 02 / 06 · IMPORT PROJECTS",
            "匯入專案",
            "從 ~/.claude.json 找到 187 個專案（依最近使用排序）。只勾選你要的，CODD 不會一次全部匯入。",
            "依父資料夾建議分組",
            "依最近使用排序 · 群組可之後在側欄拖曳調整",
            "PROJECT PATH LAST USED ↓ TRANSCRIPTS GROUP",
            "// ~/.claude-worktrees/* 與 SDK 產生的專案預設隱藏",
            "顯示隱藏項目",
            "顯示 12 / 187",
            "載入更多 ↓",
            "← 上一步",
            "略過",
            "9 個專案 → 3 個群組 · 之後可用 ⌘N 或側欄加入更多",
            "下一步：安裝 hooks →",
            "⏎",
        ]) == [])
        #expect(!texts.contains { $0.contains("node") || $0.contains("~/.codd/notebook") || $0.contains("缺") })
        #expect(harness.view.boot.headerTexts == ["BOOT · 偵測環境", "4 OK · 1 待處理", "10:41:58 · 0.8s"])
        #expect(harness.view.importView.chipText == "已選 9")
        #expect(harness.view.importView.filter.field.placeholderAttributedString?.string == "篩選名稱或路徑…")
        let names = harness.rows.rowViews.map { ($0.candidate?.prefix ?? "") + ($0.candidate?.name ?? "") }
        #expect(names.first == "agent-lab-2026/原型試做")
        #expect(harness.rows.rowViews.map(\.lastUsed) == ["今天 10:34", "今天 10:12", "今天 08:50", "今天 08:21", "昨天 22:47", "昨天 18:05",
                                                          "10/13", "10/13", "10/11", "10/09", "10/02", "9/21"])
        #expect(harness.rows.rowViews.map(\.select.displayedText) == [
            "藍鵲 · 實驗室", "藍鵲 · 實驗室", "藍鵲 · 實驗室", "藍鵲 · 網站", "藍鵲 · 網站", "藍鵲 · 網站",
            "個人 · Github", "個人 · Github", "個人 · Github", "個人 · Github", "未分類", "個人 · Github",
        ])
        #expect(harness.rows.rowViews.map(\.isChecked) == [true, true, false, true, true, true, true, true, true, false, false, true])
    }

    @Test("the other steps' copy")
    func otherSteps() {
        let expectations: [(OnboardingViewModel, [String])] = [
            (OnboardingSamples.step(.detect), [
                "CODD 先看看這台 Mac：Claude Code、cswap、hooks 與資料夾。這一步只讀，不會改動任何檔案。",
                "~/.claude/settings.json 有舊版 CODD web 的 hooks：第 3 步可以預覽並移除。", "第 3 步 →", "4 項正常 · 1 項待處理",
                "[ .. ] detect waiting for operator_", "下一步：匯入專案 →",
            ]),
            (OnboardingSamples.step(.hooks), [
                "STEP 03 / 06 · HOOKS & STATUSLINE", "預覽變更", "◆ 1 項待處理", "下一步：筆記本與 MCP →",
                "按下 套用並備份 前不會寫入；寫入前會先備份成 settings.json.codd-bak-<時間>。", "[ OK ] projects 已匯入 9 個",
            ]),
            (OnboardingSamples.step(.notebook), [
                "~/Library/Application Support/CODD/notes", "在 Finder 中顯示", "註冊…", "複製設定…",
                "位置固定在 CODD 的資料夾，不另外搬動；更新 CODD 時保留。", "● MCP 運作中",
            ]),
            (OnboardingSamples.step(.accounts), ["+ 加入帳號", "3 個帳號", "下一步：完成 →"]),
            (OnboardingSamples.step(.accounts, variant: .cswapMissing), [
                "// 找不到 cswap", "沒有 cswap 也能使用 CODD：session 用目前登入的帳號。要管理多個帳號，安裝 cswap（0.26 以上）後按 ↻ 重新偵測。",
            ]),
            (OnboardingSamples.step(.done), [
                "[ OK ] projects 匯入 9 個專案 → 3 個群組", "[ -- ] hooks 略過", "[ OK ] notebook ~/…/CODD/notes", "[ OK ] accounts 3 個帳號",
                "允許通知", "按 ⌘N 開第一個 session", "開始使用 →", "[ OK ] ready", "完成\nDONE\n開第一個 session",
                "安裝 hooks\nHOOKS & STATUSLINE\n已略過 · 可在 SETTINGS 調整",
            ]),
            (OnboardingSamples.step(.done, variant: .notificationsGranted), ["● 已允許"]),
        ]
        for (model, expected) in expectations {
            let harness = Harness(model)
            defer { harness.tearDown() }
            #expect(harness.texts.missing(expected) == [], "step \(model.flow.current.rawValue)")
        }
    }

    @Test("the group menu's entries (suggestion and current marked)")
    func menuTexts() {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.view.openGroupMenu(for: OnboardingSamples.home + "/Github/mysite.github.io")
        harness.settle()
        let panel = harness.view.groupMenu.panel
        #expect(panel.items.map(\.displayedText) == ["藍鵲 · 實驗室", "藍鵲 · 網站", "個人 · Github 建議 ✓", "CODD", "未分類"])
        #expect(panel.newItem.displayedText == "+ 新群組… 命名後套用")
        #expect(panel.frame.width == 248)
        let select = harness.row("/Github/mysite.github.io")!.select
        let anchor = select.convert(select.bounds, to: harness.view)
        #expect(panel.frame.maxY == anchor.minY - 4)
        #expect(panel.frame.maxX == anchor.maxX)
        #expect(select.isOpen)
    }
}
