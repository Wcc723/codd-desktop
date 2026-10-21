import AppKit
import CoddUI

/// The SPEC §5 Notebook sample (design data, made up) for the demo, the tests and the app's mock
/// mode: INBOX 6 · PINNED 2 · PROMPTS 3 · STALE 4 · ARCHIVE 34 · TRASH 3; BY PROJECT; LOCAL FILES
/// 4; the rows n1–n6; n1 in the editor chrome with its info panel; the s9 drawer. The notes path is
/// the real location (`<dataRoot>/notes`, user decision 2026-10-17), not the artboards'
/// design-time `~/.codd/notebook`.
public enum NotebookSamples {
    public static let notesPath = "~/Library/Application Support/CODD/notes"
    public static let n1ID = "rwd-punch-k7x2"
    public static let n1File = "2026-10-15-打卡頁-rwd-跑版紀錄.md"
    public static let port = 47821

    // MARK: Sessions and projects

    public static let s9 = NotebookSessionTarget(id: "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10", title: "打卡頁 RWD 調整", state: .busy,
                                                 detail: "orb-toolkit-frontend · busy 6m", tag: .pink)
    public static let s1 = NotebookSessionTarget(id: "3f8a2c10-7d4e-4b9a-8c21-5e6f7a8b9c01", title: "修正登入 API 401", state: .waiting,
                                                 detail: "orb-toolkit-backend · waiting 3m", tag: .red)
    public static let s7 = NotebookSessionTarget(id: "9b2d4e61-1a3c-4f5e-8d7b-2c4e6a8b0d12", title: "現場示範：連線 MCP", state: .busy,
                                                 detail: "MCP 整合範例 · busy 1m12s")
    public static let s6 = NotebookSessionTarget(id: "5e7f9a13-2b4d-4c6e-9f8a-1b3d5f7a9c23", title: "產生程式碼審查清單", state: .idle,
                                                 detail: "原型試做 · idle 2h")
    public static var liveSessions: [NotebookSessionTarget] { [s9, s1, s7, s6] }

    public static let frontend = NotebookScopeOption(id: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend",
                                                     title: "orb-toolkit-frontend", isProject: true, tag: .blue)
    public static let backend = NotebookScopeOption(id: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend",
                                                    title: "orb-toolkit-backend", isProject: true, tag: .blue)
    public static let mcpExamples = NotebookScopeOption(id: "~/Project/Northstar/lab/agent-lab-2026/整合範例/MCP", title: "MCP 整合範例",
                                                        isProject: true, tag: .orange)
    public static let gear3d = NotebookScopeOption(id: "~/Github/Gear3D", title: "Gear3D", isProject: true, tag: .green)

    // MARK: Lists column

    public static var lists: NotebookListsModel {
        NotebookListsModel(
            counts: [.inbox: 6, .pinned: 2, .prompts: 3, .stale: 4, .archive: 34, .trash: 3],
            selected: .smart(.inbox),
            projects: [
                NotebookProjectRow(id: frontend.id, name: frontend.title, tag: .blue, count: 2),
                NotebookProjectRow(id: backend.id, name: backend.title, tag: .blue, count: 1),
                NotebookProjectRow(id: mcpExamples.id, name: mcpExamples.title, tag: .orange, count: 1),
                NotebookProjectRow(id: gear3d.id, name: gear3d.title, tag: .green, count: 1),
            ],
            recentFiles: [
                NotebookFileRow(id: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend/src/pages/punch.vue",
                                name: "punch.vue", rootHint: "frontend"),
                NotebookFileRow(id: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend/src/components/PunchButton.vue",
                                name: "PunchButton.vue", rootHint: "frontend"),
                NotebookFileRow(id: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend/tailwind.config.js",
                                name: "tailwind.config.js", rootHint: "frontend"),
                NotebookFileRow(id: "~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend/test/auth.spec.ts",
                                name: "auth.spec.ts", rootHint: "backend"),
            ],
            cleanupCount: 15,
            notesPath: notesPath,
            mcp: NotebookMCPLine(running: true, clients: "3 clients"))
    }

    // MARK: Note list

    static let readOnlyActions = [
        NoteRowAction(id: "pin", title: "釘選"), NoteRowAction(id: "archive", title: "封存"),
        NoteRowAction(id: "trash", title: "移到垃圾桶", isDestructive: true),
    ]

    public static var n1Row: NoteListRow {
        NoteListRow(id: n1ID, title: "打卡頁 RWD 跑版紀錄", time: "10:05",
                    snippet: "iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。想請 AI 先重現，再把按鈕改成 sticky。",
                    kind: .note, link: .session(title: s9.title, state: .busy), ai: .read)
    }

    public static var noteRows: [NoteListRow] {
        [
            n1Row,
            NoteListRow(id: "backend-401-p3m9", title: "給後端的 prompt：401 修正條件", time: "已送出 10:02",
                        snippet: "token 過期先走 refresh，失敗才回 401 並帶 code: EXPIRED；補 auth.spec.ts 三種情境的測試。",
                        kind: .prompt, link: .session(title: s1.title, state: .waiting), ai: .read),
            NoteListRow(id: "mcp-demo-q2w8", title: "MCP 示範腳本重點", time: "09:40",
                        snippet: "開場先示範 claude mcp add，再連 codd server 讀筆記；示範前關掉通知，帳號切到 #2 藍鵲。",
                        kind: .note, link: .project(name: "MCP 整合範例", tag: .orange), ai: .read, pinned: true,
                        actions: [NoteRowAction(id: "unpin", title: "取消釘選"), NoteRowAction(id: "archive", title: "封存"),
                                  NoteRowAction(id: "trash", title: "移到垃圾桶", isDestructive: true)]),
            NoteListRow(id: "review-v2-h5k1", title: "程式碼審查標準 v2", time: "09:12",
                        snippet: "四個面向：需求理解、錯誤處理、驗證方式、文件。v1 的「程式碼風格」拿掉。",
                        kind: .note, link: .session(title: "產生程式碼審查清單", state: .idle), ai: .read),
            NoteListRow(id: "scratch-1015-z7c4", title: "隨手記 10/15", time: "08:47",
                        snippet: "#3 本週額度只剩 15%，重的工作先改用 #2 藍鵲；下午記得回頭看 Gear3D 那個卡住的 session。",
                        kind: .scratch, extra: "7d 後封存", ai: .off),
            NoteListRow(id: "keynote-ch3-r8t6", title: "keynote 第 3 章大綱", time: "21:30",
                        snippet: "3-1 為什麼要同時開多個 session · 3-2 NEEDS YOU 與狀態燈 · 3-3 筆記怎麼交給 AI。",
                        kind: .promptDraft, link: .session(title: "keynote 第 3 章", state: .idle), ai: .read),
        ]
    }

    public static var noteList: NoteListModel {
        let rows = noteRows
        return NoteListModel(title: "Inbox", count: "6", sort: .updated,
                             sections: [NoteListSection(day: "Today · 10/15", rows: Array(rows.prefix(5))),
                                        NoteListSection(day: "Yesterday", rows: [rows[5]])],
                             selectedID: n1ID, endComment: "// INBOX 6 則 · 已全部顯示", rowActions: readOnlyActions)
    }

    /// Search mode: `打卡` with highlighted ranges.
    public static var searchList: NoteListModel {
        var hit = n1Row
        hit.titleHighlights = [NSRange(location: 0, length: 2)]
        let snippet = hit.snippet as NSString
        hit.snippetHighlights = [snippet.range(of: "打卡")]
        let qa = NoteListRow(id: "punch-qa-m4n2", title: "打卡頁 QA 清單", time: "昨天 17:05",
                             snippet: "iPhone SE 直向：按鈕不被導覽列蓋住；iPhone SE 橫向：紀錄不需橫向捲動。",
                             titleHighlights: [NSRange(location: 0, length: 2)], kind: .note,
                             link: .session(title: s9.title, state: .busy), ai: .read)
        return NoteListModel(title: "Search", count: "2", showsSort: false, sections: [NoteListSection(day: nil, rows: [hit, qa])],
                             selectedID: n1ID, endComment: "// 打卡 · 2 則", emptyText: NotebookCopy.noMatchEmpty)
    }

    public static var emptyList: NoteListModel {
        NoteListModel(title: "Inbox", count: "0", sections: [], emptyText: NotebookCopy.noNotesEmpty)
    }

    // MARK: Editor chrome (n1)

    public static var n1Refs: NotebookRefTexts {
        NotebookRefTexts.standard(id: n1ID, path: "\(notesPath)/\(n1File)", port: port)
    }

    public static var n1Info: NoteInfoPanelModel {
        NoteInfoPanelModel(
            links: [.session(id: s9.id, title: s9.title, state: .busy), .project(id: frontend.id, name: frontend.title, tag: .blue)],
            aiActivity: [NoteAIActivityRow(kind: .read, who: s9.title, time: "10:12"), NoteAIActivityRow(kind: .append)],
            historyCount: "3 版",
            history: [NoteHistoryRow(id: "20261015-100544-000-3a9f1c2e", time: "10:05", label: "你 · 目前", isCurrent: true),
                      NoteHistoryRow(id: "20261015-094112-000-77b0d4e1", time: "09:41", label: "你", isSelected: true),
                      NoteHistoryRow(id: "20261014-182011-000-0c5e9a7b", time: "昨天 18:20", label: "建立")],
            assetsSummary: "2 張 · 1.4 MB",
            assets: [NoteAssetThumb(id: "9f3a1c", name: "9f3a1c.png", orientation: .portrait),
                     NoteAssetThumb(id: "2b7e04", name: "2b7e04.png", orientation: .landscape)],
            retention: [NoteRetentionRow(term: "最後活動", value: "37m 前"), NoteRetentionRow(term: "標示 stale", value: "14 天後"),
                        NoteRetentionRow(term: "自動封存", value: "豁免 · session 使用中", ok: true)],
            pinned: false)
    }

    public static var n1Footer: PromptFooterModel {
        PromptFooterModel(target: s9, targets: liveSessions)
    }

    public static var n1Chrome: NoteEditorChromeModel {
        NoteEditorChromeModel(
            crumb: "Inbox", title: "打卡頁 RWD 跑版紀錄", noteID: n1ID, ai: .read, scopeID: frontend.id,
            scopeOptions: [.global, frontend, backend, mcpExamples, gear3d], refs: n1Refs, kind: .note, pinned: false,
            sessions: liveSessions, info: n1Info,
            status: NoteDocStatusModel(position: "Ln 14, Col 38", save: .saved("10:05")), footer: n1Footer)
    }

    /// n1 with AI access OFF (the URL form disabled, D15).
    public static var n1ChromeOff: NoteEditorChromeModel {
        var model = n1Chrome
        model.ai = .off
        return model
    }

    /// A quick note that is not on disk yet (D3 / D15): `id —`, COPY REF and SEND disabled.
    public static var unsavedChrome: NoteEditorChromeModel {
        NoteEditorChromeModel(
            crumb: "Inbox", title: "隨手記 10/16", noteID: nil, ai: .read, scopeOptions: [.global, frontend], refs: nil, kind: .scratch,
            sessions: liveSessions, info: nil, status: NoteDocStatusModel(position: "Ln 1, Col 1", save: .unsaved),
            footer: PromptFooterModel(target: s9, targets: liveSessions, disabledReason: NotebookCopy.unsavedReason))
    }

    public static var n1ChipsRow: NoteChipsRowModel {
        NoteChipsRowModel(kind: .note, tags: ["rwd", "punch"], session: s9, project: frontend, updated: "updated 10:05")
    }

    public static var n1Annotations: ImageAnnotationSummaryModel {
        ImageAnnotationSummaryModel(items: [
            ImageAnnotationSummaryItem(number: 1, note: "上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)",
                                       coordinates: "rect · x 20 y 1150 · 710×120"),
            ImageAnnotationSummaryItem(number: 2, note: "時鐘數字在 SE 上太大，會擠到下方卡片 → 改 48px", coordinates: "point · x 375 y 330"),
            ImageAnnotationSummaryItem(number: 3, note: "打卡紀錄卡片離按鈕太近，間距加到 16px", coordinates: "arrow · x 600 y 760 → x 700 y 1080"),
        ])
    }

    // MARK: Drawer (s9)

    public static var drawerCards: [NotesDrawerCard] {
        [
            NotesDrawerCard(id: n1ID, kind: .note, title: "打卡頁 RWD 跑版紀錄", ai: .read,
                            images: [NotesDrawerImage(orientation: .portrait, caption: "直向"),
                                     NotesDrawerImage(orientation: .landscape, caption: "橫向")],
                            imageCaption: "截圖 2026-10-15 09:32 · iPhone SE", imageSummary: "2 張 · 1.4 MB",
                            tasks: [NotesDrawerTask("先重現（Chrome DevTools 375 寬）", done: true),
                                    NotesDrawerTask("按鈕改 `position: sticky`", done: false),
                                    NotesDrawerTask("表格改卡片式（<640px）", done: false)],
                            taskProgress: NotesDrawerTaskProgress(done: 1, total: 3),
                            tags: "#rwd #punch", updated: "更新 10:05", aiRead: "AI 讀取 10:12", isReferenced: true),
            NotesDrawerCard(id: "punch-qa-m4n2", kind: .note, title: "打卡頁 QA 清單", ai: .read,
                            tasks: [NotesDrawerTask("iPhone SE 直向：按鈕不被導覽列蓋住", done: false),
                                    NotesDrawerTask("iPhone SE 橫向：紀錄不需橫向捲動", done: false),
                                    NotesDrawerTask("iPad mini（768 寬）維持表格版面", done: true)],
                            taskProgress: NotesDrawerTaskProgress(done: 1, total: 3),
                            tags: "#qa #punch", updated: "更新 昨天 17:05"),
        ]
    }

    public static var drawerFiles: NotesDrawerFilesSection {
        NotesDrawerFilesSection(count: 3, files: [
            NotesDrawerFile(id: "src/pages/punch.vue", name: "punch.vue", aiChip: "AI 10:41", directory: "src/pages/"),
            NotesDrawerFile(id: "src/components/PunchButton.vue", name: "PunchButton.vue", aiChip: "AI", directory: "src/components/"),
            NotesDrawerFile(id: "tailwind.config.js", name: "tailwind.config.js", aiChip: nil, directory: "./"),
        ], aiTag: .pink)
    }

    public static var drawer: NotesDrawerModel {
        NotesDrawerModel(cards: drawerCards, files: drawerFiles, notesPath: notesPath)
    }

    public static var drawerWithoutFiles: NotesDrawerModel {
        NotesDrawerModel(cards: drawerCards, files: nil, notesPath: notesPath)
    }

    public static var emptyDrawer: NotesDrawerModel {
        NotesDrawerModel(cards: [], files: nil, notesPath: notesPath)
    }

    /// The s9 drawer editing n1 in place (its title opened it; saved 10:05).
    public static var drawerEditing: NotesDrawerModel {
        NotesDrawerModel(cards: drawerCards, files: drawerFiles, notesPath: notesPath,
                         editing: NotesDrawerEditing(id: n1ID, title: "打卡頁 RWD 跑版紀錄", save: .saved("10:05")))
    }

    // MARK: History compare (n1, 09:41 → 10:05)

    public static var historyCompare: HistoryCompareModel {
        typealias Line = DiffLinesView.Line
        let lines: [Line] = [
            Line(kind: .hunk, text: "@@ -6,9 +6,11 @@"),
            Line(kind: .context, oldNumber: 6, newNumber: 6, text: "## 問題"),
            Line(kind: .context, oldNumber: 7, newNumber: 7, text: "iPhone SE（375×667）下打卡按鈕被底部導覽列蓋住；橫向時表格溢出。"),
            Line(kind: .added, newNumber: 8, text: "- 影響頁面：`/punch`（打卡）與 `/punch/history`（打卡紀錄表格）"),
            Line(kind: .added, newNumber: 9, text: "- **Safari 底部工具列展開時**才會完全蓋住，收起後還露出上半截"),
            Line(kind: .context, oldNumber: 8, newNumber: 10, text: ""),
            Line(kind: .context, oldNumber: 9, newNumber: 11, text: "![截圖 2026-10-15 09:32 · iPhone SE](assets/rwd-punch-k7x2/9f3a1c.png)"),
            Line(kind: .elided, text: "…"),
            Line(kind: .hunk, text: "@@ -18,4 +20,7 @@"),
            Line(kind: .context, oldNumber: 18, newNumber: 20, text: "## 想請 AI 做的"),
            Line(kind: .removed, oldNumber: 19, text: "- [ ] 先重現（Chrome DevTools 375 寬）"),
            Line(kind: .added, newNumber: 21, text: "- [x] 先重現（Chrome DevTools 375 寬）"),
            Line(kind: .context, oldNumber: 20, newNumber: 22, text: "- [ ] 按鈕改 `position: sticky; bottom: env(safe-area-inset-bottom)`"),
            Line(kind: .added, newNumber: 23, text: "- [ ] 表格改卡片式（<640px）"),
            Line(kind: .added, newNumber: 24, text: "```css"),
            Line(kind: .added, newNumber: 25, text: "@media (max-width: 640px) { .punch-table { display: block; } }"),
            Line(kind: .added, newNumber: 26, text: "```"),
        ]
        return HistoryCompareModel(
            versions: [HistoryVersionOption(id: "20261015-100544-000-3a9f1c2e", title: "10:05 · 你 · 目前"),
                       HistoryVersionOption(id: "20261015-094112-000-77b0d4e1", title: "09:41 · 你"),
                       HistoryVersionOption(id: "20261014-182011-000-0c5e9a7b", title: "昨天 18:20 · 建立")],
            fromID: "20261015-094112-000-77b0d4e1", toID: "20261015-100544-000-3a9f1c2e", lines: lines, summary: "−1 +8")
    }

    // MARK: Pickers

    public static var linkPicker: LinkPickerModel {
        LinkPickerModel(
            sessions: [
                LinkPickerSession(id: s9.id, title: s9.title, state: .busy, project: "orb-toolkit-frontend"),
                LinkPickerSession(id: s1.id, title: s1.title, state: .waiting, project: "orb-toolkit-backend"),
                LinkPickerSession(id: s7.id, title: s7.title, state: .busy, project: "MCP 整合範例"),
                LinkPickerSession(id: s6.id, title: s6.title, state: .idle, project: "原型試做"),
            ],
            projects: [
                LinkPickerProject(id: frontend.id, name: frontend.title, tag: .blue),
                LinkPickerProject(id: backend.id, name: backend.title, tag: .blue),
                LinkPickerProject(id: mcpExamples.id, name: mcpExamples.title, tag: .orange),
                LinkPickerProject(id: gear3d.id, name: gear3d.title, tag: .green),
            ],
            linked: [.session(id: s9.id), .project(id: frontend.id)])
    }

    public static var tagEditor: TagEditorModel {
        TagEditorModel(tags: ["rwd", "punch"], suggestions: ["rwd", "punch", "qa", "mcp", "keynote", "review", "auth", "perf"])
    }
}
