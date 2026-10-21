import AppKit
import CoddUI
import Testing
@testable import CoddStatusUI

/// Model → view text for the SPEC §5 sample: every visible string of the Status artboard that
/// comes from the model or is static copy (with the C6 copy decisions).
@Suite("SPEC §5 sample text", .serialized)
@MainActor
struct SpecTextTests {
    @Test func relativeTimesMatchTheArtboard() {
        let now = StatusSamples.referenceNow
        let cards = StatusSamples.accountCards(now: now)
        let texts = cards.map { card in card.rows.map { $0.countdown.text(now: now) } }
        #expect(texts[0] == ["2h37m後", "1d12h後", "等待回報"])
        #expect(texts[1] == ["2h57m後", "3d01h後", "未使用"])
        #expect(texts[2] == ["第一則訊息後起算", "4d09h後", "等待回報"])
        #expect(cards.map { $0.source.text(now: now) } == ["cswap cache · 3m 前", "statusline · 12s 前", "cswap cache · 3m 前"])
        #expect(cards.map { $0.rows.map(\.reset) } == [["重置 13:19", "重置 10/16 週五 22:59", "快取未提供"],
                                                       ["重置 13:39", "重置 10/18 週日 12:00", "週額度 · 同 1w 重置"],
                                                       ["未開始", "重置 10/19 週一 20:00", "快取未提供"]])
        #expect(StatusClock.elapsed(now.addingTimeInterval(-180)).text(now: now) == "3m")
        #expect(StatusText.countdown(now.addingTimeInterval(-1)).text(now: now) == "已重置")
        #expect(StatusText("等待回報").ticks == false)
        #expect(StatusText.ago(now, prefix: "statusline · ").ticks)
    }

    @Test func sidebarText() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let texts = harness.sidebarTexts
        let expected = [
            "STATUS",
            "SECTIONS",
            "●", "HOST_", "主機", "cpu 23%",
            "▲", "ACCOUNTS", "帳號 · cswap", "1w 15%",
            "◆", "HOOKS", "狀態回報", "需更新",
            "●", "MCP", "本機 server", "3 clients",
            "◉", "REMOTE", "遠端連線", "1 rc",
            "◆ NEEDS YOU 3",
            "修正登入 API 401", "PERM", "3m · orb-toolkit-backend",
            "發票匯出 CSV", "ASK", "12m · Northstar invoice system",
            "場景載入優化", "ERROR", "1m · overloaded · Gear3D",
            "SESSIONS 13 live",
            "◆ WAITING 2", "▲ ERROR 1", "◇ DONE 1", "● BUSY 3", "◌ COMPACT 1", "○ IDLE 4", "$ SHELL 1", "✕ EXITED 1",
            "→ 開啟 SESSIONS",
            "REFRESH", "每 5 秒", "上次 10:42:07", "暫停",
        ]
        #expect(texts.missing(expected) == [])
        #expect(texts.containsInOrder(["SECTIONS", "HOST_", "ACCOUNTS", "HOOKS", "MCP", "REMOTE", "◆ NEEDS YOU 3", "SESSIONS 13 live",
                                       "→ 開啟 SESSIONS"]))
        // The ↻ head button.
        #expect(harness.sidebar.refreshButton.label == "↻")
    }

    @Test func pageHeaderAndHostText() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let texts = harness.pageTexts
        let expected = [
            "STATUS", "●LIVE", "↻ 立即更新", "UPDATED 10:42:07 · 每 5 秒",
            "HOST", "studio-mbp · 曲線為最近 10 分鐘", "● 正常",
            "CPU", "user + sys", "23%", "load 3.12 · 12 cores", "-10m", "peak 38%", "now",
            "MEM", "● pressure normal", "21.4/36G", "app 13.8G", "wired 4.3G", "compressed 3.3G",
            "DISK", "1T", "412Gfree", "已用 59% · Macintosh HD",
            "SWAP", "1.2G", "共 2G · 壓力正常",
            "BAT", "AC", "86%", "接上電源",
            "CLAUDE", "processes", "12", "11 CODD + 1 外部",
            "CODD APP", "RSS", "412MB", "event loop p99 3ms",
            "UPTIME", "3d4h", "開機於 10/12 06:42",
        ]
        #expect(texts.missing(expected) == [])
        #expect(texts.containsInOrder(["STATUS", "●LIVE", "↻ 立即更新", "UPDATED 10:42:07 · 每 5 秒", "HOST"]))
    }

    @Test func accountsText() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let texts = harness.pageTexts
        #expect(texts.containsInOrder(["ACCOUNTS", "cswap 0.26.0", "~/.claude-swap-backup", "依每週重置排序 · 越快重置越上面", "·",
                                       "3 個帳號 · 不顯示 email"]))
        // R7 order: #2, #3 (active), #1, then the add card.
        #expect(harness.page.accounts.orderedCards.map { $0.model?.slot } == ["#2", "#3", "#1"])
        #expect(harness.card("2").visibleTexts == [
            "#2", "藍鵲", "MAX 20X", "SWITCH", "● ok", "·", "cswap cache · 3m 前",
            "重置 13:19", "2h37m後", "重置 10/16 週五 22:59", "1d12h後", "快取未提供", "等待回報",
            "●", "1 個 session 固定（cswap run）",
        ])
        #expect(harness.card("3").visibleTexts == [
            "#3", "工作", "MAX 20X", "ACTIVE", "● ok", "·", "statusline · 12s 前",
            "重置 13:39", "2h57m後", "重置 10/18 週日 12:00", "3d01h後", "週額度 · 同 1w 重置", "未使用",
            "↗ 1w 用量超前預期 · 預估 10/17 18:00 用完",
            "●", "12 個 session 跟隨全域登入",
        ])
        #expect(harness.card("1").visibleTexts == [
            "#1", "個人", "MAX 20X", "SWITCH", "● ok", "·", "cswap cache · 3m 前",
            "未開始", "第一則訊息後起算", "重置 10/19 週一 20:00", "4d09h後", "快取未提供", "等待回報",
            "○", "0 個 session",
        ])
        // The quota bars (`.qrow`): key, value, tone.
        let bars = harness.page.accounts.orderedCards.map { $0.quotaBlocks.map { "\($0.bar.row.key) \($0.bar.row.valueText) \($0.bar.row.tone)" } }
        #expect(bars == [["5h 98% ok", "1w 46% warn", "Fable — muted"],
                         ["5h 91% ok", "1w 15% crit", "Fable 100% ok"],
                         ["5h 100% muted", "1w 100% ok", "Fable — muted"]])
        #expect(texts.containsInOrder(["+", "加入帳號", "cswap add · 用 claude /login 登入後擷取"]))
        #expect(texts.containsInOrder(["AUTO-SWITCH剩餘不足時自動切換", "OFF", "剩餘 ≤ 2%", "5h / 1w", "依排序第一個額度足夠的", "冷卻 300s",
                                       "設定", "// 用量只讀 statusline 與 cswap 快取，不另外打 API（避免 429）"]))
    }

    @Test func hooksText() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let texts = harness.page.hooks.card.visibleTexts
        let expected = [
            "~/.CLAUDEsettings.json", "◆ 1 項需要更新",
            "HOOKS", "● 14 / 14", "·", "每個 CODD session 自動注入", "◆ 舊版 CODD web hook · 10 個 event", "只移除舊版",
        ] + StatusSamples.legacyEvents + [
            "STATUSLINE", "● 已安裝", "CODD", "→", "hook-tap", "→", "statusline.sh",
            // The two-line path's center sits above the chip under the term.
            "STATUS DIR", "~/Github/codd-web/agent-sandbox/.claude/codd-status", "! 與預設不同",
            "最近收到資料", "●", "8s 前", "hook 事件與 statusline 都有回報",
            "FOREIGN HOOKS", "其他工具的項目 · CODD 不會改動",
            "hook-tap", "×11 events", "PermissionRequest 會阻擋 600s",
            "osascript", "通知", "×2 · Notification, Stop", "停用重複通知",
            "預覽變更", "更新", "套用前自動備份 settings.json", "解除安裝",
        ]
        #expect(texts.missing(expected) == [])
        #expect(texts.containsInOrder(expected))
        // A tool known only by its program shows the code once; osascript keeps its name.
        let rows = harness.page.hooks.card.foreignRows
        #expect(rows.map { $0.statusVisibleTexts() } == [["hook-tap", "×11 events", "PermissionRequest 會阻擋 600s"],
                                                          ["osascript", "通知", "×2 · Notification, Stop", "停用重複通知"]])
        #expect(rows.map { $0.accessibilityLabel() } == ["hook-tap ×11 events", "通知 osascript ×2 · Notification, Stop"])
        #expect(harness.pageTexts.contains("HOOKS & STATUSLINE"))
        #expect(harness.page.hooks.profileCards.count == 1)
        #expect(harness.page.hooks.profileCards[0].visibleTexts == [
            "cswap session profile #2", "→", "settings.json 連結自", "~/.claude", "（共用）", "● 已連結",
            "現場示範：連線 MCP 以 cswap run 使用 #2，hooks 與 statusline 跟主設定一起生效",
        ])
    }

    @Test func mcpAndRemoteText() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        let texts = harness.pageTexts
        // M4: the MCP card (its texts are checked in M4MCPCardTests); the D27 placeholder is gone.
        #expect(texts.containsInOrder(["MCP SERVER", "CODD"]))
        #expect(!texts.contains(MCPSectionView.note))
        #expect(harness.page.remote.visibleTexts == ["REMOTE", "◉", "1 個 session 已連 Remote Control（修正登入 API 401）",
                                                    "切帳號後手機需登入同一帳號", "Remote & Mobile 設定 →"])
        #expect(RemoteSectionView.text(RemoteModel(count: 0, titles: [])) == "沒有 session 連著 Remote Control")
        #expect(RemoteSectionView.text(RemoteModel(count: 2, titles: ["a", "b"])) == "2 個 session 已連 Remote Control（a、b）")
    }

    @Test func noEmojiInAnyVisibleString() {
        let harness = StatusHarness()
        defer { harness.tearDown() }
        for state in StatusSamples.State.allCases {
            harness.apply(StatusSamples.model(state))
            for text in harness.pageTexts + harness.sidebarTexts {
                let emoji = text.unicodeScalars.filter { $0.properties.isEmojiPresentation }
                #expect(emoji.isEmpty, "\(state): \(text)")
            }
        }
    }
}
