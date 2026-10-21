import AppKit
import CoddUI
import Testing
@testable import CoddCleanupUI

/// Every text of the Cleanup artboard (and of the condense states, D34) appears as drawn.
@Suite("Artboard copy", .serialized)
@MainActor
struct SpecTextTests {
    @Test func everyArtboardTextIsOnThePage() {
        let harness = CleanupHarness(CleanupSamples.artboardAsDrawn)
        defer { harness.tearDown() }
        let texts = harness.texts
        let expected = [
            // Head.
            "← NOTEBOOK", "/", "CLEANUP", "ESC", "返回筆記本", "CLEANUP · 清理建議", "每週一 09:00 · 15 項 · 上次 10/08",
            // Tabs and key hints.
            "NOTES_ 8", "SESSIONS 5", "FILES 2", "space", "勾選", "⌘A", "全選", "⌫", "封存",
            // Table header.
            "ITEM項目", "WHY原因", "STATUS", "AI", "已選 5 / 8",
            // Rows.
            "Gear3D 載入效能想法", "NOTE", "Gear3D", "21 天未開啟", "最後開啟 9/24", "stale 21d", "AI 2d 前讀取 → 建議保留",
            "給後端的 prompt：auth 測試範圍", "PROMPT", "orb-toolkit-backend", "已送出 7 天", "送到 auth middleware 單元測試", "archives in 0d",
            "隨手記 10/15", "SCRATCH", "未連結專案", "快速筆記 7 天後自動封存", "archives in 6d",
            "keynote 第 2 章大綱", "keynote-deck", "近似重複（與第 3 章 82% 相同）", "對照「keynote 第 3 章大綱」", "dup 82%", "適合濃縮",
            "舊審查清單草稿", "原型試做", "30 天未動", "已有「程式碼審查標準 v2」", "stale 30d",
            "每日工作日誌", "長期筆記 · 9 段超過 30 天", "9/01–9/12 的段落", "9 段 > 30d", "適合濃縮舊段落",
            "Pixel Town 對話樹草稿", "PROMPT · 草稿", "pixel-town-demo", "草稿 18 天未動", "從未送出", "stale 18d",
            "Remote Control 測試紀錄", "codd-web", "27 天無活動", "3 天後自動封存", "archives in 3d", "AI 9d 前讀取",
            "保留 30 天", "—", "✻",
            // Bulk bar.
            "已選 5", "移到垃圾桶", "✻ 交給 Claude 濃縮…", "封存可隨時還原 · 垃圾桶 30 天後清除", "✕",
            // CONDENSE.
            "✻ CONDENSE", "PREVIEW", "濃縮 5 則 → 1 則摘要", "帳號 / 模型 · ACCOUNT", "#1 個人 · sonnet-5.5",
            "#1 個人 5h 未開始 · 1w 剩 100% · 不佔用 #3 工作的額度", "摘要預覽", "codd://note/cleanup-1015-q8m3",
            "◇ 原稿會移到封存（不刪除），摘要連回原稿", "✻ 產生摘要", "claude -p · 掛載 codd MCP",
            // POLICY.
            "POLICY · 保留規則", "調整規則 → 設定", "ACTIVE", "編輯、開啟、送出都算活動", "STALE 14d", "變暗 · 仍可搜尋",
            "ARCHIVE 30d", "MCP 預設不列出 · 可還原", "TRASH", "只有你能丟", "PURGE 30d", "tombstone 90 天",
            "SCRATCH", "7 天後封存 · 含已送出 prompt", "豁免", "釘選 · 使用中 session 的筆記", "提醒", "週一 09:00 · ≥5 項才提醒",
            "濃縮", "手動 · 原稿只封存不刪除", "SESSIONS", "停止 3 天 → stale · 7 天 → 封存", "LOGS", "終端機紀錄封存 30 天後刪除",
        ]
        #expect(texts.missing(expected).isEmpty, "missing: \(texts.missing(expected))")
        let all = harness.allText
        for source in ["keynote 第 2 章大綱 PROMPT", "舊審查清單草稿 NOTE", "每日工作日誌（舊段落 9 段） NOTE", "Pixel Town 對話樹草稿 PROMPT",
                       "Remote Control 測試紀錄 NOTE"] {
            #expect(all.contains(source), "source \(source)")
        }
        for line in ["摘要 · 10/15 清理（5 則）", "濃縮自 5 則筆記 · 2026-09-01 → 09-27 · 原稿在 ARCHIVE", "重複的 3 節已併入第 3 章；保留「2-4 demo 順序」",
                     "v1 的「程式碼風格」在 v2 改成「驗證方式」", "每日工作日誌（9/01–9/12）", "9/03 改用 cswap 管理 3 個帳號",
                     "9/09 hooks 改成 HTTP 回報狀態"] {
            #expect(all.contains(line), "preview \(line)")
        }
        // Eight rows, each with its two actions.
        #expect(texts.filter { $0 == "保留 30 天" }.count == 8)
    }

    @Test func rowsKeepTheArtboardOrderAndChips() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let rows = harness.page.review.orderedRows
        #expect(rows.map(\.row.title) == CleanupSamples.noteRows.map(\.title))
        let first = rows[0].texts
        #expect(first.starts(with: ["Gear3D 載入效能想法", "NOTE", "Gear3D", "21 天未開啟", "最後開啟 9/24", "stale 21d"]), "\(first)")
        let draft = harness.row("pixel-town-g7h8")
        #expect(draft.texts.contains("PROMPT · 草稿"))
        // The status chips keep their artboard tones.
        let tones = CleanupSamples.noteRows.map(\.badgeTone)
        #expect(tones == [.plain, .amber, .plain, .cyan, .plain, .plain, .plain, .plain])
    }

    @Test func sessionsAndFilesTabs() {
        let sessions = CleanupHarness(CleanupSamples.sessions)
        defer { sessions.tearDown() }
        let texts = sessions.texts
        let expected = ["NOTES 8", "SESSIONS_ 5", "FILES 2", "已選 2 / 5", "選單列額度顯示", "停止 5 天", "最後畫面保留到 11/12", "stale 5d",
                        "resume expires 4d", "archives in 1d", "transcript gone", "已選 2"]
        #expect(texts.missing(expected).isEmpty, "missing: \(texts.missing(expected))")
        let files = CleanupHarness(CleanupSamples.files)
        defer { files.tearDown() }
        let fileTexts = files.texts
        let expectedFiles = ["FILES_ 2", "終端機紀錄 · 8.0 MB", "封存 26 天", "deletes in 4d", "未使用的圖片 · 2b7e04.png", "unused 12d",
                             "移到垃圾桶", "已選 1 / 2"]
        #expect(fileTexts.missing(expectedFiles).isEmpty, "missing: \(fileTexts.missing(expectedFiles))")
        #expect(files.row("f-2b7e04").row.actions == ["保留 30 天", "移到垃圾桶"])
    }

    @Test func emptyTabShowsTheComment() {
        var model = CleanupSamples.files
        model.rows = []
        model.selected = []
        let harness = CleanupHarness(model)
        defer { harness.tearDown() }
        #expect(harness.texts.contains(CleanupPageModel.defaultEmptyText))
        #expect(harness.texts.contains("已選 0 / 0"))
        #expect(harness.page.review.bulkBar.isHidden)
        #expect(!harness.page.review.header.checkbox.isEnabled)
    }

    @Test func accessibilityLabels() {
        let harness = CleanupHarness()
        defer { harness.tearDown() }
        let row = harness.row("gear3d-perf-p4m2")
        #expect(row.checkbox.accessibilityLabel() == "選取「Gear3D 載入效能想法」")
        #expect(harness.page.review.header.checkbox.accessibilityLabel() == "全選 8 個項目")
        #expect(harness.page.review.bulkBar.closeButton.accessibilityLabel() == "取消選取")
        #expect(harness.body.select.accessibilityLabel() == "濃縮使用的帳號與模型")
        #expect(harness.page.review.bulkBar.accessibilityLabel() == "批次動作")
    }
}
