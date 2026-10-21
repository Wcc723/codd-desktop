import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

/// C4's accessories: the chips row (title accessory) and the annotation summary (image accessory).
@MainActor
@Suite struct AccessoryTests {
    @Test func chipsRowShowsTheMetaRow() {
        let host = Host(NoteChipsRowView(model: NotebookSamples.n1ChipsRow), size: CGSize(width: 524, height: 20))
        defer { host.tearDown() }
        let texts = host.view.visibleTexts
        #expect(texts == ["NOTE", "#rwd", "#punch", "打卡頁 RWD 調整", "orb-toolkit-frontend", "updated 10:05"], "\(texts)")
        #expect(host.view.height(for: 524) == 20, "one line at the artboard's width")
        #expect(host.view.height(for: 200) > 20, "wraps like `flex-wrap: wrap`")
        #expect(host.view.addChip.isHidden, "the + # affordance shows on hover only when there are tags")
        host.view.setPointerInside(true)
        #expect(!host.view.addChip.isHidden)
        var empty = NotebookSamples.n1ChipsRow
        empty.tags = []
        host.view.update(empty)
        host.view.setPointerInside(false)
        #expect(!host.view.addChip.isHidden, "always offered without tags")
    }

    @Test func chipsRowCallbacks() throws {
        let host = Host(NoteChipsRowView(model: NotebookSamples.n1ChipsRow), size: CGSize(width: 524, height: 20))
        defer { host.tearDown() }
        let view = host.view
        var events: [String] = []
        view.onTagClick = { events.append("tag \($0)") }
        view.onOpenSession = { events.append("session \($0)") }
        view.onOpenProject = { events.append("project \($0)") }
        view.onRemoveTag = { events.append("remove \($0)") }
        let chips = view.notebookDescendants(ofType: ChipControl.self).filter { $0 !== view.addChip }
        for chip in chips { chip.performClick(nil) }
        #expect(events == ["tag rwd", "tag punch", "session \(NotebookSamples.s9.id)", "project \(NotebookSamples.frontend.id)"])
        let tagMenu = try #require(chips[1].onRightClick?())
        #expect(tagMenu.items.map(\.title) == ["移除 #rwd"])
        let remove = try #require(tagMenu.items.first)
        _ = remove.target?.perform(remove.action)
        #expect(events.last == "remove rwd")
    }

    @Test func tagFieldAddsOnlyWithoutMarkedText() throws {
        let host = Host(NoteChipsRowView(model: NotebookSamples.n1ChipsRow), size: CGSize(width: 524, height: 20))
        defer { host.tearDown() }
        let view = host.view
        let added = Recorder<String>()
        view.onAddTag = { added.append($0) }
        view.addChip.isHidden = false
        view.addChip.performClick(nil)
        #expect(view.isEditingTag)
        #expect(!view.tagField.isHidden)
        let editor = try Typing.focus(view.tagField, in: host.window)
        Typing.type("#ux-", into: editor)
        Typing.compose("ㄕˋ", in: editor)
        #expect(!Typing.command(#selector(NSResponder.insertNewline(_:)), field: view.tagField, editor: editor),
                "⏎ commits the composition, it is not the field's")
        #expect(added.count == 0)
        Typing.type("試", into: editor)
        #expect(!editor.hasMarkedText())
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(added.values == ["ux-試"], "`#` stripped")
        #expect(view.tagField.text == "", "ready for the next tag")
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!view.isEditingTag)
    }

    @Test func annotationSummary() {
        let host = Host(ImageAnnotationSummaryView(model: NotebookSamples.n1Annotations), size: CGSize(width: 420, height: 300))
        defer { host.tearDown() }
        let view = host.view
        let texts = view.visibleTexts
        let expected = ["標註 3 · ⌘⇧A", "編輯標註", "1", "上班打卡按鈕被底部導覽列蓋住 → 改 position: sticky，底部留 env(safe-area-inset-bottom)",
                        "rect · x 20 y 1150 · 710×120", "2", "point · x 375 y 330", "3", "arrow · x 600 y 760 → x 700 y 1080",
                        "AI 會收到標註後的圖與座標清單"]
        #expect(texts.missing(expected).isEmpty, "missing \(texts.missing(expected)) in \(texts)")
        var edits = 0
        var items: [Int] = []
        view.onEdit = { edits += 1 }
        view.onSelectItem = { items.append($0) }
        view.editButton.performClick(nil)
        for item in view.notebookDescendants(ofType: AnnotationItemView.self) { item.performClick(nil) }
        #expect(edits == 1)
        #expect(items == [1, 2, 3])
        #expect(view.height(for: 420) > view.height(for: 900), "the notes wrap at narrow widths")
        #expect(view.intrinsicContentSize.height == view.height(for: 420))
    }
}

@MainActor
@Suite struct InfoPanelTests {
    private func make(_ model: NoteInfoPanelModel = NotebookSamples.n1Info) -> Host<NoteInfoPanelView> {
        Host(NoteInfoPanelView(model: model), size: CGSize(width: 240, height: 824))
    }

    @Test func showsTheFiveSections() {
        let host = make()
        defer { host.tearDown() }
        #expect(NoteInfoPanelView.preferredWidth == 240)
        let texts = host.view.visibleTexts
        let expected = ["LINKS", "2", "打卡頁 RWD 調整", "session", "orb-toolkit-frontend", "project", "+ 連結 session / 專案", "AI ACTIVITY",
                        "codd MCP", "讀取 打卡頁 RWD 調整 10:12", "附加 —", "AI 讀取不計入活動時間", "HISTORY", "3 版", "10:05", "你 · 目前",
                        "09:41", "你", "昨天 18:20", "建立", "比較", "ASSETS", "2 張 · 1.4 MB", "9f3a1c.png", "2b7e04.png", "RETENTION",
                        "最後活動", "37m 前", "標示 stale", "14 天後", "自動封存", "豁免 · session 使用中", "釘選以保留"]
        #expect(texts.missing(expected).isEmpty, "missing \(texts.missing(expected)) in \(texts)")
        #expect(texts.containsInOrder(["LINKS", "AI ACTIVITY", "HISTORY", "ASSETS", "RETENTION"]))
        #expect(host.view.contentHeight <= 824, "fits the artboard's body without scrolling")
        #expect(host.view.linkRows.allSatisfy { $0.frame.height == 17 })
        #expect(host.view.addLinkButton.frame.height == 24)
    }

    @Test func everyButtonCallsBack() {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        var events: [String] = []
        view.onOpenLink = { events.append("link \($0)") }
        view.onAddLink = { events.append("add") }
        view.onSelectHistory = { events.append("history \($0)") }
        view.onCompare = { events.append("compare") }
        view.onOpenAsset = { events.append("asset \($0)") }
        view.onTogglePin = { events.append("pin") }
        view.linkRows.forEach { $0.performClick(nil) }
        view.addLinkButton.performClick(nil)
        view.historyRows[1].performClick(nil)
        view.compareButton.performClick(nil)
        view.assetViews.forEach { $0.performClick(nil) }
        view.pinButton.performClick(nil)
        #expect(events == ["link session(id: \"\(NotebookSamples.s9.id)\")", "link project(id: \"\(NotebookSamples.frontend.id)\")", "add",
                           "history 20261015-094112-000-77b0d4e1", "compare", "asset 9f3a1c", "asset 2b7e04", "pin"])
    }

    @Test func pinnedAndDisabledStates() {
        var model = NotebookSamples.n1Info
        model.pinned = true
        model.actionsDisabledReason = "在 I1b 接上"
        let host = make(model)
        defer { host.tearDown() }
        let view = host.view
        #expect(view.pinButton.label == "取消釘選")
        let controls: [NSControl] = [view.compareButton, view.pinButton, view.addLinkButton]
        for button in controls {
            #expect(!button.isEnabled)
            #expect(button.toolTip == "在 I1b 接上")
        }
        var single = NotebookSamples.n1Info
        single.history = [single.history[0]]
        view.update(single)
        #expect(!view.compareButton.isEnabled, "nothing to compare with one version")
    }
}

@MainActor
@Suite struct StatusAndFooterTests {
    @Test func docStatusTexts() {
        let host = Host(NoteDocStatusView(model: NoteDocStatusModel(position: "Ln 14, Col 38", save: .saved("10:05"))),
                        size: CGSize(width: 608, height: 22))
        defer { host.tearDown() }
        let view = host.view
        #expect(view.visibleTexts.joined(separator: " ") == "LIVE PREVIEW · ⌘E 原始碼 Ln 14, Col 38 · Markdown · ● 已儲存 10:05")
        #expect(view.modeControl.frame.minX == 44, "`.nb-docstat{padding:0 14px 0 44px}`")
        view.update(NoteDocStatusModel(sourceMode: true, position: "Ln 1, Col 1", save: .unsaved))
        #expect(view.visibleTexts.joined(separator: " ") == "SOURCE · ⌘E 即時預覽 Ln 1, Col 1 · Markdown · ● 未儲存")
        view.update(NoteDocStatusModel(position: "Ln 2, Col 3", save: .saving))
        #expect(view.saveText == "◌ 儲存中…")
        var toggles = 0
        view.onToggleMode = { toggles += 1 }
        view.modeControl.performClick(nil)
        #expect(toggles == 1)
    }

    @Test func footerTextsAndCallbacks() throws {
        let footer = PromptFooterView(model: NotebookSamples.n1Footer)
        let presenter = RecordingPresenter()
        footer.menuPresenter = presenter
        let host = Host(footer, size: CGSize(width: 608, height: 41))
        defer { host.tearDown() }
        let texts = footer.visibleTexts
        #expect(texts.missing(["送到", "打卡頁 RWD 調整 ▾", "插入引用", "插入全文", "送出 ⌘⏎"]).isEmpty, "\(texts)")
        #expect(texts.contains { $0.hasPrefix("orb-toolkit-frontend") })
        var events: [String] = []
        footer.onInsertRef = { events.append("ref") }
        footer.onInsertFull = { events.append("full") }
        footer.onSend = { events.append("send") }
        footer.onTarget = { events.append("target \($0)") }
        footer.insertRefButton.performClick(nil)
        footer.insertFullButton.performClick(nil)
        footer.sendButton.performClick(nil)
        footer.targetPill.performClick(nil)
        let menu = try #require(presenter.current)
        #expect(menu.visibleItems.map(\.title) == NotebookSamples.liveSessions.map(\.title))
        #expect(menu.visibleItems.first?.isChecked == true)
        #expect(presenter.presented.last.map { $0.origin.y + menu.preferredSize.height } == footer.targetPill.frame.minY - 4,
                "opens upward")
        menu.handleKey(Keys.down)
        menu.handleKey(Keys.enter)
        #expect(events == ["ref", "full", "send", "target \(NotebookSamples.s1.id)"])
        #expect(footer.sendButton.frame.maxX == 596, "`padding-right:12px`")
        #expect(footer.sendButton.frame.height == 22)
    }

    @Test func footerDisabledStates() {
        let footer = PromptFooterView(model: PromptFooterModel(target: nil, targets: []))
        let host = Host(footer, size: CGSize(width: 608, height: 41))
        defer { host.tearDown() }
        #expect(!footer.targetPill.isEnabled)
        #expect(footer.visibleTexts.contains("沒有 session ▾"))
        for button in [footer.insertRefButton, footer.insertFullButton, footer.sendButton] {
            #expect(!button.isEnabled)
            #expect(button.toolTip == NotebookCopy.noTargetReason)
        }
        footer.update(PromptFooterModel(target: NotebookSamples.s1, targets: NotebookSamples.liveSessions,
                                        sendDisabledReason: "Claude 在等你確認 · 先用下方按鍵回答"))
        #expect(footer.insertRefButton.isEnabled && footer.insertFullButton.isEnabled)
        #expect(!footer.sendButton.isEnabled)
        #expect(footer.sendButton.toolTip == "Claude 在等你確認 · 先用下方按鍵回答")
    }
}
