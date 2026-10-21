import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

@MainActor
@Suite struct NoteListTests {
    private func make(_ model: NoteListModel = NotebookSamples.noteList) -> Host<NoteListView> {
        Host(NoteListView(model: model), size: CGSize(width: 300, height: 900))
    }

    @Test func artboardMetrics() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        #expect(NoteListView.preferredWidth == 300)
        let n1 = try #require(view.rowView(NotebookSamples.n1ID))
        #expect(n1.frame.width == 299, "the 1 px right border is the column's")
        #expect(n1.frame.height == 101, "`.nb-nrow` with a 2-line snippet: 9 + 18.75 + 5 + 2 × 17.825 + 5 + 17 + 10 + 1")
        #expect(n1.snippetLines(width: 299) == 2)
        // Head 52 + `TODAY · 10/15` separator 26.
        #expect(host.frame(of: n1).minY == 78)
        let rows = view.rowViews
        for (a, b) in zip(rows, rows.dropFirst()) where b.row.id != "keynote-ch3-r8t6" {
            #expect(b.frame.minY == a.frame.maxY, "rows stack without gaps")
        }
        let short = NoteListRowView(row: NoteListRow(id: "x", title: "短", time: "1:00", snippet: "一行"), actions: [])
        #expect(short.height(for: 299) == 84)
        let empty = NoteListRowView(row: NoteListRow(id: "y", title: "空", time: "1:00", snippet: ""), actions: [])
        #expect(empty.height(for: 299) == 61, "title, gap 5, chips")
    }

    @Test func showsTheRowsOfTheArtboard() {
        let host = make()
        defer { host.tearDown() }
        let texts = host.view.visibleTexts
        let expected = ["INBOX 6", "最近更新 ▾", "TODAY · 10/15", "打卡頁 RWD 跑版紀錄", "10:05", "NOTE", "打卡頁 RWD 調整", "READ",
                        "給後端的 prompt：401 修正條件", "已送出 10:02", "PROMPT", "修正登入 API 401", "MCP 示範腳本重點", "MCP 整合範例",
                        "程式碼審查標準 v2", "產生程式碼審查清單", "隨手記 10/15", "SCRATCH", "7d 後封存", "OFF", "YESTERDAY",
                        "keynote 第 3 章大綱", "PROMPT · 草稿", "keynote 第 3 章", "// INBOX 6 則 · 已全部顯示"]
        #expect(texts.missing(expected).isEmpty, "missing \(texts.missing(expected))")
        #expect(texts.containsInOrder(["打卡頁 RWD 跑版紀錄", "給後端的 prompt：401 修正條件", "MCP 示範腳本重點", "程式碼審查標準 v2",
                                       "隨手記 10/15", "YESTERDAY", "keynote 第 3 章大綱"]))
        #expect(host.view.rowView(NotebookSamples.n1ID)?.isSelected == true)
        #expect(host.view.rowView("mcp-demo-q2w8")?.row.pinned == true)
    }

    @Test func selectionOpenAndKeyboard() {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        let selected = Recorder<String>()
        let opened = Recorder<String>()
        view.onSelect = { selected.append($0) }
        view.onOpen = { opened.append($0) }
        view.rowView("review-v2-h5k1")?.performClick(nil)
        #expect(selected.last == "review-v2-h5k1")
        #expect(view.rowView("review-v2-h5k1")?.isSelected == true)
        #expect(view.rowView(NotebookSamples.n1ID)?.isSelected == false)
        #expect(view.handleKey(Keys.down))
        #expect(selected.last == "scratch-1015-z7c4")
        #expect(view.handleKey(Keys.up))
        #expect(view.handleKey(Keys.up))
        #expect(selected.last == "mcp-demo-q2w8")
        #expect(view.handleKey(Keys.enter))
        #expect(opened.values == ["mcp-demo-q2w8"])
        view.rowView("backend-401-p3m9")?.onDoubleClick?()
        #expect(opened.last == "backend-401-p3m9")
        // A model that confirms the selection keeps the rows (no rebuild).
        let before = view.rowViews.map(ObjectIdentifier.init)
        var model = NotebookSamples.noteList
        model.selectedID = "keynote-ch3-r8t6"
        view.update(model)
        #expect(view.rowViews.map(ObjectIdentifier.init) == before)
        #expect(view.rowView("keynote-ch3-r8t6")?.isSelected == true)
    }

    @Test func contextMenusComeFromTheModel() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        var actions: [String] = []
        view.onRowAction = { row, action in actions.append("\(row):\(action)") }
        let menu = try #require(view.rowView(NotebookSamples.n1ID)?.contextMenu())
        #expect(menu.items.map(\.title) == ["釘選", "封存", "移到垃圾桶"])
        let pinnedMenu = try #require(view.rowView("mcp-demo-q2w8")?.contextMenu())
        #expect(pinnedMenu.items.map(\.title) == ["取消釘選", "封存", "移到垃圾桶"], "a row's own actions win")
        let trash = try #require(menu.items.last)
        _ = trash.target?.perform(trash.action)
        #expect(actions == ["\(NotebookSamples.n1ID):trash"])
    }

    @Test func sortMenu() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        let presenter = RecordingPresenter()
        view.menuPresenter = presenter
        let sorts = Recorder<NoteListSort>()
        view.onSort = { sorts.append($0) }
        view.sortButton.performClick(nil)
        let menu = try #require(presenter.current)
        #expect(menu.visibleItems.map(\.title) == ["最近更新", "建立時間", "標題"])
        #expect(menu.visibleItems.first?.isChecked == true)
        #expect(view.sortButton.isOn)
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.enter)
        #expect(sorts.values == [.title])
        #expect(presenter.current == nil, "the menu closed")
        #expect(!view.sortButton.isOn)
    }

    @Test func searchModeAndEmptyStates() throws {
        let host = make(NotebookSamples.searchList)
        defer { host.tearDown() }
        let view = host.view
        #expect(view.sortButton.isHidden)
        #expect(view.visibleTexts.contains("SEARCH 2"))
        let hit = try #require(view.rowView(NotebookSamples.n1ID))
        #expect(hit.row.snippetHighlights == [(hit.row.snippet as NSString).range(of: "打卡")])
        #expect(hit.row.titleHighlights == [NSRange(location: 0, length: 2)])
        #expect(view.notebookDescendants(ofType: DaySeparatorView.self).isEmpty, "search results have no day separators")
        view.update(NotebookSamples.emptyList)
        host.settle()
        #expect(view.isShowingEmptyState)
        #expect(view.visibleTexts.contains("// 還沒有筆記 · ⌘⇧N 新增"))
        var noMatch = NotebookSamples.searchList
        noMatch.sections = []
        view.update(noMatch)
        #expect(view.visibleTexts.contains("// 找不到符合的筆記"))
        #expect(!view.handleKey(Keys.down), "no rows: keys are not used")
    }

    @Test func warningsAndStaleRows() {
        var model = NotebookSamples.noteList
        model.sections[0].rows[1].warnings = ["ID 重複", "frontmatter"]
        model.sections[0].rows[1].stale = true
        let host = make(model)
        defer { host.tearDown() }
        let row = host.view.rowView("backend-401-p3m9")
        #expect(row?.drawnTexts.contains("ID 重複") == true)
        #expect(row?.drawnTexts.contains("frontmatter") == true)
        #expect(row?.row.stale == true)
    }
}
