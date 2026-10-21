import AppKit
import CoddUI
import Testing
@testable import CoddNotebookUI

@MainActor
@Suite struct ListsTests {
    private func make(_ model: NotebookListsModel = NotebookSamples.lists) -> Host<NotebookListsView> {
        Host(NotebookListsView(model: model), size: CGSize(width: 220, height: 900))
    }

    @Test func artboardMetrics() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        #expect(NotebookListsView.preferredWidth == 220)
        #expect(view.frame.width == 220)
        #expect(host.frame(of: view.searchField) == CGRect(x: 8, y: 60, width: 204, height: 26))
        let inbox = try #require(view.smartRow(.inbox))
        #expect(inbox.frame.height == 28)
        #expect(inbox.frame.width == 208, "`.side-scroll{padding:8px 6px}`")
        #expect(view.smartRow(.trash)?.frame.height == 43, "TRASH is `.nb-li.two`")
        #expect(view.projectRows.allSatisfy { $0.frame.height == 24 })
        #expect(view.fileRows.allSatisfy { $0.frame.height == 24 })
        #expect(view.newButton.frame.height == 22)
        // Smart lists stack with the 1 px gap.
        let pinned = try #require(view.smartRow(.pinned))
        #expect(pinned.frame.minY == inbox.frame.maxY + 1)
    }

    @Test func showsTheArtboardTexts() {
        let host = make()
        defer { host.tearDown() }
        let texts = host.view.visibleTexts
        let expected = ["NOTEBOOK", "+ ⌘⇧N", "INBOX", "6", "PINNED", "2", "PROMPTS", "3", "STALE", "4", "ARCHIVE", "34", "TRASH",
                        "30 天後永久刪除", "BY PROJECT", "orb-toolkit-frontend", "orb-toolkit-backend", "MCP 整合範例", "Gear3D",
                        "LOCAL FILES", "最近 4", "punch.vue", "PunchButton.vue", "tailwind.config.js", "auth.spec.ts", "frontend",
                        "backend", "開啟資料夾…", "清理建議", "15", "→", NotebookSamples.notesPath, "● MCP codd", "3 clients"]
        #expect(texts.missing(expected).isEmpty, "missing \(texts.missing(expected))")
        #expect(texts.containsInOrder(["INBOX", "PINNED", "PROMPTS", "STALE", "ARCHIVE", "TRASH", "BY PROJECT", "LOCAL FILES"]))
        #expect(host.view.searchField.drawnTexts == ["/", "搜尋筆記、#標籤…", "⌘F"])
    }

    @Test func everyCallbackFires() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        var events: [String] = []
        let selected = Recorder<NotebookListID>()
        view.onNew = { events.append("new") }
        view.onSelect = { selected.append($0) }
        view.onOpenFile = { events.append("file \($0)") }
        view.onOpenFolder = { events.append("folder") }
        view.onOpenCleanup = { events.append("cleanup") }
        view.onToggleSection = { section, open in events.append("toggle \(section) \(open)") }
        view.newButton.performClick(nil)
        for list in NotebookSmartList.allCases { view.smartRow(list)?.performClick(nil) }
        view.projectRows.first?.performClick(nil)
        view.fileRows.first?.performClick(nil)
        view.openFolderButton.performClick(nil)
        view.footer.cleanup.performClick(nil)
        let header = try #require(view.notebookDescendants(ofType: SectionHeaderRow.self).first { $0.title == "By project" })
        header.performClick(nil)
        #expect(events.first == "new")
        #expect(selected.values == NotebookSmartList.allCases.map { .smart($0) } + [.project(NotebookSamples.frontend.id)])
        #expect(events.contains { $0.hasPrefix("file ") && $0.hasSuffix("punch.vue") })
        #expect(events.contains("folder"))
        #expect(events.contains("cleanup"))
        #expect(events.last == "toggle byProject false")
        host.settle()
        #expect(view.projectRows.allSatisfy { $0.isHidden }, "BY PROJECT collapsed")
        let files = try #require(view.notebookDescendants(ofType: SectionHeaderRow.self).first { $0.title == "Local files" })
        files.performClick(nil)
        host.settle()
        #expect(events.last == "toggle localFiles false")
        #expect(view.fileRows.allSatisfy { $0.isHidden } && view.openFolderButton.isHidden)
        files.performClick(nil)
        #expect(events.last == "toggle localFiles true")
    }

    @Test func selectionCleanupAndDisabledFiles() {
        var model = NotebookSamples.lists
        model.selected = .project(NotebookSamples.backend.id)
        model.cleanupCount = nil
        model.filesDisabledReason = "檔案編輯在 I3 接上"
        let host = make(model)
        defer { host.tearDown() }
        let view = host.view
        #expect(view.smartRow(.inbox)?.isSelected == false)
        #expect(view.projectRows.first { $0.project.id == NotebookSamples.backend.id }?.isSelected == true)
        #expect(view.footer.cleanup.isHidden, "清理建議 hidden when nil")
        #expect(!view.visibleTexts.contains("清理建議"))
        #expect(view.fileRows.allSatisfy { !$0.isEnabled && $0.toolTip == "檔案編輯在 I3 接上" })
        #expect(!view.openFolderButton.isEnabled)
        var opened = 0
        view.onOpenFile = { _ in opened += 1 }
        view.fileRows.first?.performClick(nil)
        #expect(opened == 0)
        // The footer shrinks without the cleanup line.
        #expect(view.footer.preferredHeight < ListsFooterView().preferredHeightWithCleanup)
    }

    @Test func updateKeepsTheTypedSearch() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        let editor = try Typing.focus(view.searchField, in: host.window)
        Typing.type("打卡", into: editor)
        var next = NotebookSamples.lists
        next.counts[.inbox] = 7
        next.searchText = ""
        view.update(next)
        #expect(view.searchText == "打卡", "the field keeps the text being edited")
        #expect(view.smartRow(.inbox)?.count == 7)
    }

    @Test func searchIsSilentWhileComposing() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        let searches = Recorder<String>()
        view.onSearch = { searches.append($0) }
        let editor = try Typing.focus(view.searchField, in: host.window)
        Typing.type("rwd ", into: editor)
        #expect(searches.values == ["rwd "])
        Typing.compose("ㄉㄚˇ", in: editor)
        #expect(editor.hasMarkedText())
        #expect(view.searchField.isComposing)
        #expect(searches.values == ["rwd "], "no onSearch while marked text exists")
        Typing.compose("ㄉㄚˇㄎ", in: editor)
        #expect(searches.count == 1)
        // The input method commits.
        Typing.type("打卡", into: editor)
        #expect(!editor.hasMarkedText())
        #expect(searches.values == ["rwd ", "rwd 打卡"])
        // ⏎ / ⎋ while composing belong to the input method.
        Typing.compose("ㄧ", in: editor)
        #expect(!Typing.command(#selector(NSResponder.cancelOperation(_:)), field: view.searchField, editor: editor),
                "⎋ during a composition belongs to the input method")
        #expect(!Typing.command(#selector(NSResponder.insertNewline(_:)), field: view.searchField, editor: editor))
        #expect(view.searchField.text.contains("ㄧ"))
        #expect(searches.count == 2)
        editor.unmarkText()
    }

    @Test func escapeClearsTheSearch() throws {
        let host = make()
        defer { host.tearDown() }
        let view = host.view
        let searches = Recorder<String>()
        view.onSearch = { searches.append($0) }
        let editor = try Typing.focus(view.searchField, in: host.window)
        Typing.type("#rwd", into: editor)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(view.searchText == "")
        #expect(searches.values == ["#rwd", ""])
    }
}

extension ListsFooterView {
    /// The footer height with the cleanup line (for comparisons).
    var preferredHeightWithCleanup: CGFloat {
        configure(NotebookSamples.lists)
        return preferredHeight
    }
}
