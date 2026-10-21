import AppKit
import CoddUI

/// The Cleanup artboard's data (SPEC §5: `NOTES 8 · SESSIONS 5 · FILES 2`, the retention defaults)
/// and made-up SESSIONS / FILES rows in the D30 / D31 voice, for the app's mock mode, the demo and
/// the tests. Notes, sessions and files are design data, not anything from a real machine.
@MainActor
public enum CleanupSamples {
    /// Project tag colors (helmet `--t-*`).
    public enum Tag {
        public static let green = NSColor(hex: 0x4EC9B0)
        public static let blue = NSColor(hex: 0x5B8DEF)
        public static let orange = NSColor(hex: 0xFF9B4E)
        public static let purple = NSColor(hex: 0xB07CFF)
        public static let pink = NSColor(hex: 0xFF7CB5)
    }

    public static let meta = "每週一 09:00 · 15 項 · 上次 10/08"
    public static let counts: [CleanupTab: Int] = [.notes: 8, .sessions: 5, .files: 2]
    /// D31: SESSIONS have no 移到垃圾桶 and no condense; FILES no condense.
    public static let bulkDisabled: [CleanupTab: Set<String>] = [
        .sessions: [CleanupBulkAction.trash, CleanupBulkAction.condense],
        .files: [CleanupBulkAction.condense],
    ]

    // MARK: Pages

    /// The Cleanup artboard: 8 NOTES rows, 5 selected, the condense card in preview, the policy card.
    public static var artboard: CleanupPageModel {
        CleanupPageModel(meta: meta, counts: counts, tab: .notes, rows: noteRows, selected: selectedNotes,
                         condense: condense(.preview), policy: policy, bulkDisabled: bulkDisabled)
    }

    /// The artboard exactly as drawn: the card shows the summary with the idle `[✻ 產生摘要]` row.
    public static var artboardAsDrawn: CleanupPageModel {
        var model = artboard
        model.condense = condense(.idle)
        return model
    }

    /// SESSIONS tab (made up, D30): two selected, the card closed.
    public static var sessions: CleanupPageModel {
        CleanupPageModel(meta: meta, counts: counts, tab: .sessions, rows: sessionRows, selected: ["s-usagebar", "s-gear3d"],
                         policy: policy, bulkDisabled: bulkDisabled)
    }

    /// FILES tab (made up, D31): one selected, the card closed.
    public static var files: CleanupPageModel {
        CleanupPageModel(meta: meta, counts: counts, tab: .files, rows: fileRows, selected: ["f-2b7e04"], policy: policy,
                         bulkDisabled: bulkDisabled)
    }

    /// The artboard page with the card in `state` (`preview` nil for idle and running unless `withPreview`).
    public static func page(condense state: CondenseState, withPreview: Bool? = nil, disabledReason: String? = nil) -> CleanupPageModel {
        var model = artboard
        var card = condense(state)
        let showPreview = withPreview ?? (state == .preview)
        card.preview = showPreview ? summaryPreview : nil
        card.disabledReason = disabledReason
        model.condense = card
        return model
    }

    // MARK: NOTES

    public static let selectedNotes: Set<String> = ["keynote-ch2-a1b2", "review-v1-c3d4", "daily-log-e5f6", "pixel-town-g7h8", "remote-ctl-i9j0"]

    public static var noteRows: [CleanupRow] {
        [
            CleanupRow(id: "gear3d-perf-p4m2", title: "Gear3D 載入效能想法",
                       chips: [.kind("NOTE"), .project("Gear3D", color: Tag.green)],
                       why: "21 天未開啟", sub: "最後開啟 9/24", badge: "stale 21d", aiHint: .keep("AI 2d 前讀取 → 建議保留")),
            CleanupRow(id: "auth-scope-q2w8", title: "給後端的 prompt：auth 測試範圍",
                       chips: [.kind("PROMPT", tone: .amber), .project("orb-toolkit-backend", color: Tag.blue)],
                       why: "已送出 7 天", sub: "送到 auth middleware 單元測試", badge: "archives in 0d", badgeTone: .amber),
            CleanupRow(id: "scratch-1015-z9x1", title: "隨手記 10/15",
                       chips: [.kind("SCRATCH", dashed: true), .faint("未連結專案")],
                       why: "SCRATCH", sub: "快速筆記 7 天後自動封存", badge: "archives in 6d"),
            CleanupRow(id: "keynote-ch2-a1b2", title: "keynote 第 2 章大綱",
                       chips: [.kind("PROMPT", tone: .amber), .project("keynote-deck", color: Tag.green)],
                       why: "近似重複（與第 3 章 82% 相同）", sub: "對照「keynote 第 3 章大綱」", badge: "dup 82%", badgeTone: .cyan,
                       aiHint: .condense("✻ 適合濃縮")),
            CleanupRow(id: "review-v1-c3d4", title: "舊審查清單草稿",
                       chips: [.kind("NOTE"), .project("原型試做", color: Tag.orange)],
                       why: "30 天未動", sub: "已有「程式碼審查標準 v2」", badge: "stale 30d"),
            CleanupRow(id: "daily-log-e5f6", title: "每日工作日誌",
                       chips: [.kind("NOTE"), .faint("未連結專案")],
                       why: "長期筆記 · 9 段超過 30 天", sub: "9/01–9/12 的段落", badge: "9 段 > 30d",
                       aiHint: .condense("✻ 適合濃縮舊段落")),
            CleanupRow(id: "pixel-town-g7h8", title: "Pixel Town 對話樹草稿",
                       chips: [.kind("PROMPT · 草稿", tone: .amber, dashed: true), .project("pixel-town-demo", color: Tag.green)],
                       why: "草稿 18 天未動", sub: "從未送出", badge: "stale 18d"),
            CleanupRow(id: "remote-ctl-i9j0", title: "Remote Control 測試紀錄",
                       chips: [.kind("NOTE"), .project("codd-web", color: Tag.purple)],
                       why: "27 天無活動", sub: "3 天後自動封存", badge: "archives in 3d", aiHint: .read("AI 9d 前讀取")),
        ]
    }

    // MARK: SESSIONS (made up, D30 voice)

    public static var sessionRows: [CleanupRow] {
        [
            CleanupRow(id: "s-usagebar", title: "選單列額度顯示",
                       chips: [.kind("EXITED"), .project("UsageBar", color: Tag.green)],
                       why: "停止 5 天", sub: "最後畫面保留到 11/12", badge: "stale 5d"),
            CleanupRow(id: "s-ci", title: "CI 設定",
                       chips: [.kind("STOPPED"), .project("orb-toolkit-backend", color: Tag.blue)],
                       why: "停止 26 天 · 仍可 resume", sub: "Claude Code 30 天後清除對話紀錄", badge: "resume expires 4d", badgeTone: .amber),
            CleanupRow(id: "s-i18n", title: "登入頁錯誤訊息 i18n",
                       chips: [.kind("STOPPED"), .project("orb-toolkit-backend", color: Tag.blue)],
                       why: "停止 6 天", sub: "明天自動封存", badge: "archives in 1d", badgeTone: .amber),
            CleanupRow(id: "s-gear3d", title: "場景載入 profiling",
                       chips: [.kind("EXITED"), .project("Gear3D", color: Tag.green)],
                       why: "停止 4 天", sub: "最後畫面保留到 11/13", badge: "stale 4d"),
            CleanupRow(id: "s-mcp-rehearsal", title: "MCP 示範預演",
                       chips: [.kind("STOPPED"), .project("MCP 整合範例", color: Tag.orange)],
                       why: "對話紀錄已不存在", sub: "無法 resume · 只剩最後畫面", badge: "transcript gone"),
        ]
    }

    // MARK: FILES (made up, D31 voice)

    public static var fileRows: [CleanupRow] {
        let actions = [CleanupRowAction.keep, CleanupRowAction.trash]
        return [
            CleanupRow(id: "f-ring-refresh", title: "終端機紀錄 · 8.0 MB",
                       chips: [.kind("LOG"), .project("orb-toolkit-backend", color: Tag.blue)],
                       why: "封存 26 天", sub: "「refresh token 流程改寫」的終端機紀錄", badge: "deletes in 4d", badgeTone: .amber,
                       actions: actions),
            CleanupRow(id: "f-2b7e04", title: "未使用的圖片 · 2b7e04.png",
                       chips: [.kind("IMAGE"), .project("orb-toolkit-frontend", color: Tag.blue)],
                       why: "筆記與保留的版本都沒有引用", sub: "「打卡頁 RWD 跑版紀錄」· 412 KB", badge: "unused 12d", actions: actions),
        ]
    }

    // MARK: CONDENSE

    public static func condense(_ state: CondenseState) -> CondenseModel {
        CondenseModel(
            title: "濃縮 5 則 → 1 則摘要",
            sources: [
                CondenseSource(title: "keynote 第 2 章大綱", kind: "PROMPT", tagColor: Tag.green),
                CondenseSource(title: "舊審查清單草稿", kind: "NOTE", tagColor: Tag.orange),
                CondenseSource(title: "每日工作日誌（舊段落 9 段）", kind: "NOTE", tagColor: nil),
                CondenseSource(title: "Pixel Town 對話樹草稿", kind: "PROMPT", tagColor: Tag.green),
                CondenseSource(title: "Remote Control 測試紀錄", kind: "NOTE", tagColor: Tag.purple),
            ],
            accountTitle: "#1 個人 · sonnet-5.5",
            accounts: [
                CondenseAccountOption(id: "follow", title: "跟隨全域登入（#3 工作）"),
                CondenseAccountOption(id: "1", title: "#1 個人"),
                CondenseAccountOption(id: "2", title: "#2 藍鵲"),
            ],
            models: ["sonnet-5.5", "opus-5.5"],
            selectedAccountID: "1",
            selectedModel: "sonnet-5.5",
            accountHint: "#1 個人 5h 未開始 · 1w 剩 100% · 不佔用 #3 工作的額度",
            previewRef: "codd://note/cleanup-1015-q8m3",
            preview: summaryPreview,
            state: state)
    }

    /// The artboard's summary preview (`.nb-cl-prev`), as the app's Markdown renderer would give it.
    public static var summaryPreview: NSAttributedString {
        let out = NSMutableAttributedString()
        let body = TextStyle.mono(11, Palette.bone)
        func paragraph(_ text: NSAttributedString, lineHeight: CGFloat, before: CGFloat = 0, indent: CGFloat = 0,
                       block: NSTextBlock? = nil) -> NSAttributedString {
            // The newline belongs to the paragraph: its style (and the quote's text block) must
            // cover it, or the block ends after the first line.
            let line = NSMutableAttributedString(attributedString: text)
            line.append(NSAttributedString(string: "\n", attributes: text.length > 0 ? text.attributes(at: text.length - 1, effectiveRange: nil) : [:]))
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            style.paragraphSpacing = 3
            style.paragraphSpacingBefore = before
            style.headIndent = indent
            if indent > 0 {
                style.firstLineHeadIndent = 2
                style.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
            }
            if let block { style.textBlocks = [block] }
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            line.enumerateAttribute(.font, in: NSRange(location: 0, length: line.length)) { value, range, _ in
                guard let font = value as? NSFont else { return }
                line.addAttribute(.baselineOffset, value: max(0, (lineHeight - Typeface.lineHeight(font)) / 2), range: range)
            }
            return line
        }
        let h1 = TextStyle(font: Typeface.display(12.5), color: Palette.amber)
        let h2 = TextStyle(font: Typeface.display(11), color: Palette.amberDim)
        let quote = TextStyle.mono(10.5, Palette.dim)
        // A TextKit 1 text block lays out only with a width (100 %): the quote bar of `.q`.
        let quoteBlock = NSTextBlock()
        quoteBlock.setValue(100, type: .percentageValueType, for: .width)
        quoteBlock.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
        quoteBlock.setBorderColor(Palette.amberDim, for: .minX)
        quoteBlock.setWidth(7, type: .absoluteValueType, for: .padding, edge: .minX)
        let bullet = NSTextAttachment()
        let bulletColor = Palette.amberDim
        bullet.image = NSImage(size: CGSize(width: 4, height: 4), flipped: false) { rect in
            bulletColor.setFill()
            rect.fill()
            return true
        }
        bullet.bounds = CGRect(x: 0, y: 2.5, width: 4, height: 4)
        func item(_ text: String) -> NSAttributedString {
            let line = NSMutableAttributedString(attachment: bullet)
            line.append(body.string("\t" + text, lineBreak: .byWordWrapping))
            return paragraph(line, lineHeight: 16.5, indent: 12)
        }

        out.append(paragraph(h1.string("摘要 · 10/15 清理（5 則）"), lineHeight: 18.75))
        let q = NSMutableAttributedString(attributedString: quote.string("濃縮自 5 則筆記 · 2026-09-01 → 09-27 · 原稿在 ", lineBreak: .byWordWrapping))
        q.append(quote.with(color: Palette.cyan).string("ARCHIVE"))
        out.append(paragraph(q, lineHeight: 15.75, block: quoteBlock))
        out.append(paragraph(h2.string("keynote 第 2 章大綱"), lineHeight: 16.5, before: 4))
        out.append(item("重複的 3 節已併入第 3 章；保留「2-4 demo 順序」"))
        out.append(paragraph(h2.string("舊審查清單草稿"), lineHeight: 16.5, before: 4))
        out.append(item("v1 的「程式碼風格」在 v2 改成「驗證方式」"))
        out.append(paragraph(h2.string("每日工作日誌（9/01–9/12）"), lineHeight: 16.5, before: 4))
        out.append(item("9/03 改用 cswap 管理 3 個帳號"))
        out.append(item("9/09 hooks 改成 HTTP 回報狀態"))
        out.append(paragraph(h2.string("Pixel Town 對話樹草稿"), lineHeight: 16.5, before: 4))
        // No newline after the last paragraph.
        out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        return out
    }

    // MARK: POLICY

    /// SPEC §5 retention defaults as the artboard's lifecycle and rules.
    public static var policy: CleanupPolicyModel {
        CleanupPolicyModel(
            lifecycle: [
                CleanupPolicyStep(name: "Active", sub: "編輯、開啟、送出都算活動"),
                CleanupPolicyStep(name: "Stale", detail: "14d", sub: "變暗 · 仍可搜尋"),
                CleanupPolicyStep(name: "Archive", detail: "30d", sub: "MCP 預設不列出 · 可還原"),
                CleanupPolicyStep(name: "Trash", sub: "只有你能丟"),
                CleanupPolicyStep(name: "Purge", detail: "30d", sub: "tombstone 90 天"),
            ],
            rules: [
                CleanupPolicyRule(term: "Scratch", text: "7 天後封存 · 含已送出 prompt"),
                CleanupPolicyRule(term: "豁免", text: "釘選 · 使用中 session 的筆記"),
                CleanupPolicyRule(term: "提醒", text: "週一 09:00 · ≥5 項才提醒"),
                CleanupPolicyRule(term: "濃縮", text: "手動 · 原稿只封存不刪除"),
                CleanupPolicyRule(term: "Sessions", text: "停止 3 天 → stale · 7 天 → 封存"),
                CleanupPolicyRule(term: "Logs", text: "終端機紀錄封存 30 天後刪除"),
            ])
    }
}
