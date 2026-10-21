import AppKit
import CoddFiles
import CoddUI
import Testing
@testable import CoddFileEditorUI

@Suite("FileTreeView", .serialized)
@MainActor
struct FileTreeViewTests {
    private func make(_ model: FileTreeModelView = FileEditorSamples.tree()) -> Host<FileTreeView> {
        Host(FileTreeView(model: model), size: NSSize(width: FileTreeView.width, height: 900))
    }

    /// The center of row `id` in the list view's coordinates.
    private func point(of id: String, in tree: FileTreeView) throws -> CGPoint {
        let frame = try #require(tree.list.frame(ofRow: id))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @Test func theSampleRendersItsBadges() throws {
        let host = make()
        defer { host.tearDown() }
        let rep = try #require(host.render())
        #expect(rep.inkRatio() > 0.04)
        #expect(rep.contains(Palette.amber), "FILES, the M badges, the .cur border")
        #expect(rep.contains(FileEditorColors.tagPink), "the AI chips and AI 2")
        #expect(rep.contains(Palette.amberDim), "folder dots")
        #expect(rep.contains(Palette.bgLift), "the current row")
        #expect(host.view.list.placed.count == 2 + 4 + 24, "two section heads, 4 recent, 24 project rows")
    }

    @Test func clicksOpenTogglePreviewAndPin() throws {
        let host = make()
        defer { host.tearDown() }
        let tree = host.view
        let opened = Calls<(String, Bool)>()
        let toggled = Calls<String>()
        let sections = Calls<FileTreeSection>()
        tree.onOpen = { opened.append(($0, $1)) }
        tree.onToggle = { toggled.append($0) }
        tree.onToggleSection = { sections.append($0) }
        tree.list.click(at: try point(of: "src/main.js", in: tree), count: 1)
        tree.list.click(at: try point(of: "src/main.js", in: tree), count: 2)
        tree.list.click(at: try point(of: "src/router", in: tree), count: 1)
        tree.list.click(at: CGPoint(x: 40, y: tree.list.placed[0].frame.midY), count: 1)
        #expect(opened.values.map(\.0) == ["src/main.js", "src/main.js"])
        #expect(opened.values.map(\.1) == [true, false], "single click = preview, double = pinned")
        #expect(toggled.values == ["src/router"])
        #expect(sections.values == [.recent])
        // The note in RECENT opens with its own id.
        tree.list.click(at: try point(of: "note:rwd-punch-k7x2", in: tree), count: 1)
        #expect(opened.values.last?.0 == "note:rwd-punch-k7x2")
    }

    @Test func headButtons() {
        let host = make()
        defer { host.tearDown() }
        var collapsed = 0
        host.view.onCollapseAll = { collapsed += 1 }
        host.view.head.collapseButton.performClickAction()
        #expect(collapsed == 1)
        let newFile = host.view.head.newFileButton
        #expect(!newFile.isEnabled)
        #expect(newFile.toolTip == "新增檔案（之後提供）")
        newFile.performClickAction() // disabled: nothing happens, nothing crashes
    }

    @Test func notARepositoryAndCollapsedSections() throws {
        var model = FileEditorSamples.tree()
        model.git = nil
        model.recentCollapsed = true
        model.projectCollapsed = true
        let host = make(model)
        defer { host.tearDown() }
        #expect(host.view.list.placed.count == 2, "only the two heads")
        let rep = try #require(host.render())
        #expect(rep.inkRatio() > 0.01)
        model.recent = []
        model.projectCollapsed = false
        host.view.update(model)
        host.layout()
        #expect(host.view.list.placed.count == 1 + 24, "no RECENT head without recent files")
    }

    @Test func aHugeFolderRendersOnlyVisibleRowsAndTheMarker() throws {
        var model = FileEditorSamples.tree()
        model.rows = (0..<2_000).map { FileTreeRow(id: "big/f\($0).txt", name: "f\($0).txt", depth: 1) }
            + [FileTreeRow(id: "big/\u{2026}", name: "\u{2026}", kind: .overflow(count: 50), depth: 1)]
        let host = make(model)
        defer { host.tearDown() }
        let clock = ContinuousClock()
        let start = clock.now
        _ = host.render()
        #expect(clock.now - start < .seconds(1))
        #expect(host.view.list.contentHeight > 2_000 * 22)
        var opened: [String] = []
        host.view.onOpen = { id, _ in opened.append(id) }
        host.view.list.click(at: try point(of: "big/\u{2026}", in: host.view), count: 1)
        #expect(opened.isEmpty, "the marker is not a file")
    }

    @Test func rowsFromCoddFilesEntries() {
        let folder = FileTreeEntry(relativePath: "src", name: "src", isDirectory: true)
        let file = FileTreeEntry(relativePath: "src/.env.local", name: ".env.local", isDirectory: false, isHidden: true, isIgnored: true)
        let more = FileTreeEntry(relativePath: "src", name: "\u{2026}", isDirectory: false, isOverflow: true, overflowCount: 7)
        #expect(FileTreeRow(entry: folder, depth: 0, expanded: true).kind == .folder(expanded: true))
        let row = FileTreeRow(entry: file, depth: 1, modified: true)
        #expect(row.ext == "env" && row.ignored && row.modified && row.id == "src/.env.local")
        #expect(FileTreeRow(entry: more, depth: 1).kind == .overflow(count: 7))
        #expect(FileExt.label(for: "tailwind.config.js") == "js")
        #expect(FileExt.label(for: ".gitignore") == "git")
        #expect(FileExt.label(for: "Makefile") == "")
        #expect(FileExt.label(for: "index.html") == "html")
        #expect(FileExt.label(for: "notes.MARKDOWN") == "mark")
        #expect(FileTreeGitHead(status: GitRepoStatus(root: URL(fileURLWithPath: "/r"), branch: nil, detached: true, ahead: 1,
                                                      changes: ["a": .modified])) == FileTreeGitHead(branch: "(detached)", ahead: 1, modified: 1))
    }
}

@Suite("Filter field (IME)", .serialized)
@MainActor
struct FilterFieldTests {
    @Test func markedTextNeverReachesTheCallback() throws {
        let host = Host(FileTreeView(model: FileEditorSamples.tree()), size: NSSize(width: FileTreeView.width, height: 600))
        defer { host.tearDown() }
        let tree = host.view
        var filters: [String] = []
        tree.onFilter = { filters.append($0) }
        tree.focusFilter()
        let editor = try #require(host.window.firstResponder as? NSTextView)
        editor.insertText("pu", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(filters == ["pu"])
        // 注音 composes ㄉㄚˇ: nothing is reported while the syllable is marked.
        editor.setMarkedText("ㄉ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setMarkedText("ㄉㄚ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText() && tree.isComposingFilter)
        #expect(filters == ["pu"], "no callback with marked text")
        // A model update while composing never replaces the marked text.
        var model = tree.model
        model.filter = "other"
        tree.update(model)
        #expect(editor.hasMarkedText())
        // The syllable is committed as 打: one callback with the committed text.
        editor.insertText("打", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        #expect(filters == ["pu", "pu打"])
        // Commands reach the owner only outside a composition.
        var commands: [Selector] = []
        tree.onFilterCommand = { commands.append($0); return true }
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(commands == [#selector(NSResponder.insertNewline(_:))])
        editor.setMarkedText("ㄅ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(commands.count == 1, "⏎ while composing belongs to the input method")
        editor.unmarkText()
    }

    @Test func theModelSetsTheTextWhenNotComposing() {
        let host = Host(FileTreeView(model: FileEditorSamples.tree()), size: NSSize(width: FileTreeView.width, height: 600))
        defer { host.tearDown() }
        var filters: [String] = []
        host.view.onFilter = { filters.append($0) }
        var model = host.view.model
        model.filter = "punch"
        host.view.update(model)
        #expect(host.view.filterField.field.stringValue == "punch")
        #expect(filters.isEmpty, "a model change is not a user change")
    }
}
