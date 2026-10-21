import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

@MainActor
@Suite struct DrawerTests {
    private func make(_ model: NotesDrawerModel = NotebookSamples.drawer) -> Host<NotesDrawerView> {
        Host(NotesDrawerView(model: model), size: CGSize(width: 300, height: 900))
    }

    @Test func artboardMetricsAndTexts() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        #expect(NotesDrawerView.preferredWidth == 300)
        #expect(view.closeButton.frame == CGRect(x: 300 - 6 - 24, y: 6, width: 24, height: 24))
        #expect(view.footer.frame.height == 28)
        #expect(view.newNoteButton.frame.height == 28)
        let n1 = try #require(view.card(NotebookSamples.n1ID))
        #expect(n1.frame.width == 275, "299 minus `.sp-pad-b{padding:10px 12px}`")
        let texts = view.visibleTexts
        let expected = ["SESSION PAD · 筆記", "✕", "LINKED NOTES", "2", "NOTE", "打卡頁 RWD 跑版紀錄", "READ", "直向", "橫向",
                        "截圖 2026-10-15 09:32 · iPhone SE", "2 張 · 1.4 MB", "[x] 先重現（Chrome DevTools 375 寬）",
                        "[ ] 按鈕改 position: sticky", "[ ] 表格改卡片式（<640px）", "#rwd #punch · 更新 10:05 · AI 讀取 10:12", "插入引用",
                        "送出全文", "打卡頁 QA 清單", "#qa #punch · 1/3 · 更新 昨天 17:05", "+ 新筆記（連結此 session）", "AI 改過的檔案 ·",
                        "3", "vs HEAD", "punch.vue", "M", "AI 10:41", "src/pages/", "PunchButton.vue", "AI", "src/components/",
                        "tailwind.config.js", "./", "差異", NotebookSamples.notesPath, "⌘⇧N", "快速筆記"]
        #expect(texts.missing(expected).isEmpty, "missing \(texts.missing(expected))")
        #expect(view.filesList?.diffButtons.count == 3)
    }

    @Test func taskProgressOnlyWithoutImages() {
        let cards = NotebookSamples.drawerCards
        #expect(cards[0].metaParts == ["#rwd #punch", "更新 10:05", "AI 讀取 10:12"], "the image card shows no progress")
        #expect(cards[1].metaParts == ["#qa #punch", "1/3", "更新 昨天 17:05"])
        var many = cards[0]
        many.images += [NotesDrawerImage(orientation: .portrait, caption: "三")]
        many.tasks += [NotesDrawerTask("第四", done: false)]
        let view = DrawerCardView(card: many, disabledReason: nil)
        #expect(!view.drawnTexts.contains("三"), "at most two thumbnails")
        #expect(!view.drawnTexts.contains("[ ] 第四"), "at most three tasks")
        // A long task wraps instead of being cut.
        var long = cards[1]
        long.tasks = [NotesDrawerTask("這是一個非常長的任務描述，會在抽屜卡片裡換行顯示而不是被截斷，因為抽屜很窄", done: false)]
        let wrapping = DrawerCardView(card: long, disabledReason: nil)
        #expect(wrapping.taskLines(long.tasks[0], width: 251) >= 2)
        #expect(wrapping.height(for: 275) > DrawerCardView(card: cards[1], disabledReason: nil).height(for: 275) - 17 * 2)
    }

    @Test func everyCallbackFires() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        var events: [String] = []
        view.onClose = { events.append("close") }
        view.onOpenNote = { events.append("open \($0)") }
        view.onInsertRef = { events.append("ref \($0)") }
        view.onSendFull = { events.append("send \($0)") }
        view.onNewNote = { events.append("new") }
        view.onOpenFile = { events.append("file \($0)") }
        view.onDiff = { events.append("diff \($0)") }
        view.onQuickNote = { events.append("quick") }
        view.closeButton.performClick(nil)
        let card = try #require(view.card(NotebookSamples.n1ID))
        card.titleLink.performClick(nil)
        card.insertRefButton.performClick(nil)
        card.sendFullButton.performClick(nil)
        view.newNoteButton.performClick(nil)
        let files = try #require(view.filesList)
        files.rows.first?.performClick(nil)
        files.diffButtons.forEach { $0.performClick(nil) }
        view.footer.performClick(nil)
        #expect(events == ["close", "open \(NotebookSamples.n1ID)", "ref \(NotebookSamples.n1ID)", "send \(NotebookSamples.n1ID)", "new",
                           "file src/pages/punch.vue", "diff src/pages/punch.vue", "diff src/components/PunchButton.vue",
                           "diff tailwind.config.js", "quick"])
    }

    @Test func withoutFilesAndEmpty() {
        let host = make(NotebookSamples.drawerWithoutFiles)
        defer { host.tearDown() }
        let view = host.view
        #expect(view.filesList == nil)
        #expect(!view.visibleTexts.contains("AI 改過的檔案 ·"))
        view.update(NotebookSamples.emptyDrawer)
        host.settle()
        #expect(view.isShowingEmptyState)
        #expect(view.visibleTexts.contains("// 還沒有連結這個 session 的筆記"))
        #expect(view.visibleTexts.contains("+ 新筆記（連結此 session）"))
        view.update(NotebookSamples.drawer)
        #expect(!view.isShowingEmptyState)
        #expect(view.filesList != nil)
    }

    /// A card's title opens the note in the drawer's editor when the app handles `onEditNote`
    /// (without it the title still opens the Notebook).
    @Test func aCardTitleEditsInPlaceWhenWired() throws {
        let host = make()
        defer { host.tearDown() }
        var events: [String] = []
        host.view.onOpenNote = { events.append("open \($0)") }
        host.view.onEditNote = { events.append("edit \($0)") }
        try #require(host.view.card(NotebookSamples.n1ID)).titleLink.performClick(nil)
        #expect(events == ["edit \(NotebookSamples.n1ID)"])
    }

    /// The editing layout: head 36, the bar 32 (`‹ LINKED NOTES 2`, `[筆記本 ↗]`), the document
    /// slot, the action row 40 (`[插入引用] [送出全文]`, the save state), the footer 28.
    @Test func editingInPlace() throws {
        let host = make(NotebookSamples.drawerEditing)
        defer { host.tearDown() }
        let view = host.view
        let document = FlippedView()
        view.documentView = document
        host.settle()
        #expect(view.isEditing && !view.isShowingCards)
        #expect(document.superview === view.documentSlot && document.frame == view.documentSlot.bounds)
        #expect(view.documentSlot.frame == CGRect(x: 1, y: 36 + 32, width: 299, height: 900 - 36 - 32 - 40 - 28))
        #expect(view.backControl.frame.minY >= 36 && view.backControl.frame.maxY <= 36 + 32)
        // `CGFloat(…)`: inside #expect a bare `300 - 10` is captured as an Int and compared as a
        // different type (always false), while the same `==` outside the macro is true.
        #expect(view.notebookButton.frame.maxX == CGFloat(300 - 10))
        #expect(view.editInsertRefButton.frame.minY == 900 - 28 - 40 + 9 && view.editInsertRefButton.frame.minX == 13)
        #expect(view.editSendFullButton.frame.minX == view.editInsertRefButton.frame.maxX + 6)
        let texts = view.visibleTexts
        let expected = ["SESSION PAD · 筆記", "✕", "‹", "LINKED NOTES", "2", "筆記本 ↗", "插入引用", "送出全文", "● 已儲存 10:05",
                        NotebookSamples.notesPath, "⌘⇧N", "快速筆記"]
        #expect(texts.missing(expected).isEmpty, "missing \(texts.missing(expected))")
        #expect(!texts.contains("+ 新筆記（連結此 session）") && !texts.contains("打卡頁 QA 清單"), "the cards hide under the editor")
        #expect(view.saveText == "● 已儲存 10:05")
        var events: [String] = []
        view.onBack = { events.append("back") }
        view.onOpenNote = { events.append("open \($0)") }
        view.onInsertRef = { events.append("ref \($0)") }
        view.onSendFull = { events.append("send \($0)") }
        view.backControl.performClick(nil)
        view.notebookButton.performClick(nil)
        view.onOpenInNotebook = { events.append("notebook \($0)") }
        view.notebookButton.performClick(nil)
        view.editInsertRefButton.performClick(nil)
        view.editSendFullButton.performClick(nil)
        let id = NotebookSamples.n1ID
        #expect(events == ["back", "open \(id)", "notebook \(id)", "ref \(id)", "send \(id)"])
    }

    /// The save state follows the model without rebuilding the cards; leaving shows them again.
    @Test func saveStateUpdatesInPlaceAndBackShowsTheCards() throws {
        let host = make(NotebookSamples.drawerEditing)
        defer { host.tearDown() }
        let view = host.view
        let cards = view.cardViews
        var model = NotebookSamples.drawerEditing
        model.editing?.save = .unsaved
        view.update(model)
        host.settle()
        #expect(view.saveText == "● 未儲存")
        #expect(view.cardViews.map(ObjectIdentifier.init) == cards.map(ObjectIdentifier.init), "only the editing part changed")
        model.editing?.save = .saving
        view.update(model)
        host.settle()
        #expect(view.saveText == "◌ 儲存中…")
        model.editing?.save = nil
        view.update(model)
        host.settle()
        #expect(view.saveText.isEmpty, "nothing while the note loads")
        // A narrow drawer keeps both buttons: the state loses its time, then goes, never cut.
        model.editing?.save = .saved("10/14 18:20")
        view.update(model)
        host.window.setContentSize(CGSize(width: 200, height: 900))
        host.settle()
        #expect(view.editSendFullButton.frame.maxX <= 200 && view.saveText.isEmpty)
        host.window.setContentSize(CGSize(width: 300, height: 900))
        host.settle()
        #expect(view.saveText.hasPrefix("● 已儲存"))
        model.editing?.save = .saved("10:05")
        view.update(model)
        host.settle()
        #expect(view.saveText == "● 已儲存 10:05")
        // Disabled actions carry the session's reason in the editor too.
        model.actionsDisabledReason = NotebookCopy.noTargetReason
        view.update(model)
        #expect(!view.editInsertRefButton.isEnabled && view.editSendFullButton.toolTip == NotebookCopy.noTargetReason)
        model.editing = nil
        view.update(model)
        host.settle()
        #expect(!view.isEditing && view.isShowingCards && view.documentSlot.isHidden)
        #expect(view.visibleTexts.contains("+ 新筆記（連結此 session）"))
    }

    @Test func disabledActionsKeepTheirReason() throws {
        var model = NotebookSamples.drawer
        model.actionsDisabledReason = NotebookCopy.noTargetReason
        let host = make(model)
        defer { host.tearDown() }
        let card = try #require(host.view.card(NotebookSamples.n1ID))
        #expect(!card.insertRefButton.isEnabled && card.insertRefButton.toolTip == NotebookCopy.noTargetReason)
        #expect(!card.sendFullButton.isEnabled)
        #expect(card.card.isReferenced)
    }
}

@MainActor
@Suite struct HistoryTests {
    @Test func compareSheet() {
        TestFonts.register()
        let view = HistoryCompareView(model: NotebookSamples.historyCompare)
        let host = Host(view, size: view.preferredSize)
        defer { host.tearDown() }
        let texts = view.visibleTexts
        #expect(texts.missing(["HISTORY · 比較版本", "✕", "→", "−1 +8", "還原前會先儲存目前的內容", "關閉", "還原這一版"]).isEmpty, "\(texts)")
        #expect(view.fromSelect.currentTitle == "09:41 · 你")
        #expect(view.toSelect.currentTitle == "10:05 · 你 · 目前")
        #expect(view.diff.lines == NotebookSamples.historyCompare.lines)
        #expect(view.preferredSize.width == 680)
        var events: [String] = []
        view.onSelectFrom = { events.append("from \($0)") }
        view.onSelectTo = { events.append("to \($0)") }
        view.onRestore = { events.append("restore") }
        view.onClose = { events.append("close") }
        view.fromSelect.onSelect?(2)
        view.toSelect.onSelect?(1)
        view.restoreButton.performClick(nil)
        view.closeButton.performClick(nil)
        view.frameView.closeButton.performClick(nil)
        view.cancelOperation(nil)
        #expect(events == ["from 20261014-182011-000-0c5e9a7b", "to 20261015-094112-000-77b0d4e1", "restore", "close", "close", "close"])
        var disabled = NotebookSamples.historyCompare
        disabled.restoreEnabled = false
        disabled.restoreDisabledReason = "這是目前的版本"
        view.update(disabled)
        #expect(!view.restoreButton.isEnabled)
        #expect(view.restoreButton.toolTip == "這是目前的版本")
    }
}

@MainActor
@Suite struct PickerTests {
    @Test func linkPickerFiltersAndPicks() throws {
        TestFonts.register()
        let picker = LinkPickerView(model: NotebookSamples.linkPicker)
        let host = Host(picker, size: picker.preferredSize)
        defer { host.tearDown() }
        #expect(picker.listModel.items.count == 8)
        #expect(picker.listModel.items.filter(\.isChecked).map(\.title) == ["打卡頁 RWD 調整", "orb-toolkit-frontend"])
        let picks = Recorder<NotebookLink>()
        picker.onPick = { picks.append($0) }
        var cancelled = 0
        picker.onCancel = { cancelled += 1 }
        let editor = try Typing.focus(picker.searchField, in: host.window)
        Typing.type("back", into: editor)
        #expect(picker.listModel.items.map(\.title) == ["修正登入 API 401", "orb-toolkit-backend"], "session by project, then the project")
        Typing.compose("ㄉ", in: editor)
        #expect(picker.query == "back", "no filtering while composing")
        #expect(!Typing.command(#selector(NSResponder.insertNewline(_:)), field: picker.searchField, editor: editor))
        #expect(!Typing.command(#selector(NSResponder.moveDown(_:)), field: picker.searchField, editor: editor))
        #expect(picks.count == 0)
        Typing.type("", into: editor)
        editor.selectAll(nil)
        Typing.type("整合", into: editor)
        #expect(picker.query == "整合")
        #expect(picker.listModel.items.map(\.title) == ["現場示範：連線 MCP", "MCP 整合範例"])
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(picks.values == [.project(id: NotebookSamples.mcpExamples.id)])
        editor.selectAll(nil)
        Typing.type("zzz", into: editor)
        #expect(picker.listModel.items.map(\.title) == [NotebookCopy.noMatchEmpty])
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(cancelled == 1)
        // A click on a session row links the session.
        editor.selectAll(nil)
        Typing.type("", into: editor)
        picker.layoutSubtreeIfNeeded()
        picker.list.layoutSubtreeIfNeeded()
        picker.list.row("session:\(NotebookSamples.s7.id)")?.performClick(nil)
        #expect(picks.last == .session(id: NotebookSamples.s7.id))
    }

    @Test func tagEditorAddsAndRemoves() throws {
        TestFonts.register()
        let editorView = TagEditorView(model: NotebookSamples.tagEditor)
        let host = Host(editorView, size: editorView.preferredSize)
        defer { host.tearDown() }
        #expect(editorView.suggestionsModel.items.map(\.title) == ["qa", "mcp", "keynote", "review", "auth", "perf"], "not the note's own tags")
        var events: [String] = []
        editorView.onAdd = { events.append("add \($0)") }
        editorView.onRemove = { events.append("remove \($0)") }
        editorView.onDone = { events.append("done") }
        let field = try Typing.focus(editorView.field, in: host.window)
        Typing.type("ke", into: field)
        #expect(editorView.suggestionsModel.items.map(\.title) == ["keynote"])
        Typing.compose("ㄐ", in: field)
        #expect(!Typing.command(#selector(NSResponder.insertNewline(_:)), field: editorView.field, editor: field))
        #expect(events.isEmpty, "⏎ during a composition belongs to the input method")
        Typing.type("鍵", into: field)
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(events == ["add ke鍵"])
        // Empty field: ⏎ takes the highlighted suggestion.
        field.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(events.last == "add qa")
        editorView.tagChips.first?.performClick(nil)
        #expect(events.last == "remove rwd")
        field.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(events.last == "done")
        #expect(TagEditorView.clean(" #new tag ") == "new-tag")
    }
}

/// Every view renders its sample (not blank) offscreen; no window is ever ordered in.
@MainActor
@Suite struct RenderTests {
    @Test func everyViewRenders() {
        TestFonts.register()
        let views: [(NSView, CGSize)] = [
            (NotebookListsView(model: NotebookSamples.lists), CGSize(width: 220, height: 900)),
            (NoteListView(model: NotebookSamples.noteList), CGSize(width: 300, height: 900)),
            (NoteEditorChromeView(model: NotebookSamples.n1Chrome), CGSize(width: 848, height: 876)),
            (NoteChipsRowView(model: NotebookSamples.n1ChipsRow), CGSize(width: 524, height: 20)),
            (ImageAnnotationSummaryView(model: NotebookSamples.n1Annotations), CGSize(width: 420, height: 300)),
            (NotesDrawerView(model: NotebookSamples.drawer), CGSize(width: 300, height: 900)),
            (HistoryCompareView(model: NotebookSamples.historyCompare), CGSize(width: 680, height: 560)),
            (LinkPickerView(model: NotebookSamples.linkPicker), CGSize(width: 340, height: 400)),
            (TagEditorView(model: NotebookSamples.tagEditor), CGSize(width: 300, height: 300)),
        ]
        let visibleBefore = NSApp.windows.filter(\.isVisible).count
        for (view, size) in views {
            guard let rep = ViewSnapshot.render(view, size: size, scale: 1) else {
                Issue.record("\(type(of: view)) did not render")
                continue
            }
            #expect(Pixels.differing(from: Palette.bg, in: rep) > 100, "\(type(of: view)) is blank")
        }
        #expect(NSApp.windows.filter(\.isVisible).count == visibleBefore)
    }
}
