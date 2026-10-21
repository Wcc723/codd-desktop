import AppKit
import CoddAnnotateUI
import CoddCore
import CoddHooks
import CoddNotebookUI
import CoddNotes
import CoddTextKit
import Foundation
import Testing
@testable import CODD

// M4 I1b: Annotate mode, the menus and metadata, COPY REF through a private pasteboard, archive /
// trash with UNDO, HISTORY compare and restore, the pickers, ⌘K NOTES and the menu rules. Temp
// folders only (the SPEC §5 notes are made-up design data); windows are never ordered on screen.

/// A settable clock the notes library reads (history snapshots need time to pass).
final class NotesTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }

    func advance(minutes: Double) { lock.withLock { value = value.addingTimeInterval(minutes * 60) } }
}

/// The whole NOTES area on a temp data root, in a window that is never shown. Menus and pickers
/// are drawn in place; pasteboard writes go to the private pasteboard (a background run's).
@MainActor
final class NotesAreaRig {
    static let mcpToken = String(repeating: "ab", count: 32)
    static let port = 47999

    let root: String
    let preferences = PreferencesService.inMemory()
    let clock: NotesTestClock
    let service: NotesService
    let editor: NoteEditorController
    let area: NotesAreaViewController
    let store = MockSessionStore()
    let shell = ShellState()
    let pasteboard = CoddPasteboard(isBackground: true, log: { _ in })
    let window: NSWindow
    private(set) var revealed: [URL] = []

    var notesDir: String { root + "/notes" }

    /// - Parameters:
    ///   - mock: seed the SPEC §5 notes (n1 with its image, annotations and HISTORY).
    ///   - files: extra note files written before the notebook opens (relative path → text).
    init(_ prefix: String, mock: Bool = false, files: [String: String] = [:]) async throws {
        root = try m3TempFolder(prefix)
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        if mock { await MockNotes.seed(into: folder) }
        try FileManager.default.createDirectory(atPath: root + "/notes", withIntermediateDirectories: true)
        for (path, text) in files { try text.write(toFile: root + "/notes/" + path, atomically: true, encoding: .utf8) }
        let clock = NotesTestClock(MockData.referenceDate)
        self.clock = clock
        service = NotesService(notesRoot: folder.appendingPathComponent("notes", isDirectory: true),
                               cacheFolder: folder.appendingPathComponent("cache", isDirectory: true), preferences: preferences,
                               trash: AppTrash(target: .folder(root + "/trash"), log: { _ in }), clock: { clock.now },
                               timeZone: MockNotes.timeZone, log: { _ in })
        editor = NoteEditorController(service: service, preferences: preferences)
        editor.autosaveDelay = .milliseconds(150)
        area = NotesAreaViewController(service: service, editor: editor, store: store, shell: shell, preferences: preferences,
                                       recentFiles: nil, pasteboard: pasteboard)
        area.refContext = { (Self.port, Self.mcpToken) }
        area.pickerPresenter = InlineMenuPresenter()
        area.chrome.menuPresenter = InlineMenuPresenter()
        // Deferred and never shown: the window has no backing store, so no display cycle runs (a
        // small, displayed test window trips AppKit's display-pass guard on C4's tall figures;
        // known issue in the report).
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1368, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = area.view
        area.view.frame = NSRect(x: 0, y: 0, width: 1368, height: 900)
        editor.revealFile = { [weak self] url in self?.revealed.append(url) }
        let editor = self.editor
        service.onExternalChange = { [weak editor] id in Task { await editor?.externalChange(id) } }
        await service.open()
        area.setActive(true)
        area.view.layoutSubtreeIfNeeded()
    }

    func tearDown() async {
        area.setActive(false)
        await editor.flush()
        await service.close()
        removeFolder()
    }

    func removeFolder() {
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func create(_ title: String, body: String? = nil, tags: [String] = []) async throws -> NoteDocument {
        try await service.create(NewNote(title: title, body: body, tags: tags))
    }

    /// Shows a note and waits for the editor and the info panel's facts.
    func show(_ id: NoteID) async {
        area.reveal(id)
        await m3Eventually("note \(id.rawValue) shown") { editor.noteID == id && !area.hasPendingRequests }
        await m3Eventually("its facts") { service.selected?.document.metadata.id == id }
    }

    func fileText(_ id: NoteID) async -> String {
        guard let document = try? await service.document(id) else { return "" }
        return (try? String(contentsOf: document.fileURL, encoding: .utf8)) ?? ""
    }

    var n1: NoteID { NoteID(rawValue: MockNotes.n1ID)! }
    static let n1Image = "assets/rwd-punch-k7x2/9f3a1c.png"
}

@Suite("M4 notebook features · Annotate", .serialized)
@MainActor
struct M4NotebookAnnotateTests {
    @Test func doneRewritesTheBlockAsOneUndoStepAndBurnsTheCopy() async throws {
        let rig = try await NotesAreaRig("codd-m4f-annotate", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        let before = rig.editor.text
        #expect(rig.editor.imagePaths == [NotesAreaRig.n1Image])
        #expect(await rig.area.annotate())
        #expect(rig.area.mode == .annotate && rig.area.rootView?.annotate != nil && rig.area.modeView?.isHidden == true)
        let session = try #require(rig.area.annotateSession)
        #expect(session.screen.document.items.count == 3 && session.screen.document.pixelSize == CGSize(width: 750, height: 1334))
        #expect(session.screen.header.crumbs == ["INBOX", "打卡頁 RWD 跑版紀錄"] && session.screen.header.fileName == "9f3a1c.png")
        #expect(session.screen.header.meta == ["assets/rwd-punch-k7x2/9f3a1c.png", "750×1334 px", "iPhone SE", "截圖 2026-10-15 09:32"])
        #expect(session.modeView.statusBar.modeTexts == ["標註模式", "3 個標註 · ● 已儲存 10:05"])
        let preview = try #require(session.screen.previewText?(session.screen.document))
        #expect(preview.contains("/cache/annotated/") && preview.contains("-9f3a1c.annotated.png")
                && preview.contains("annotations（原圖像素，左上為原點）:"))
        #expect(preview.contains("1 rect  x=20 y=1150 w=710 h=120"))
        #expect(session.screen.markdownSource?(session.screen.document).hasPrefix("```codd-annotations\n{\"v\":1,") == true)
        // A real edit on the screen: item 1 deleted with ⌫ on the canvas (the rest renumbered), then 完成.
        try Self.pressDelete(on: session.screen, in: rig.window)
        #expect(session.screen.document.items.count == 2 && session.screen.document.item(1)?.kind == .point)
        #expect(session.modeView.statusBar.modeTexts.last?.hasPrefix("2 個標註") == true)
        session.screen.done()
        await m3Eventually("back on the Notebook with the PNG") { rig.area.mode == .notebook && rig.area.lastAnnotate != nil }
        #expect(rig.area.rootView?.annotate == nil && rig.area.modeView?.isHidden == false)
        #expect(rig.editor.noteID == rig.n1, "the note stays selected")
        let block = try #require(rig.editor.annotations(of: NotesAreaRig.n1Image))
        #expect(block.items.map(\.type) == [.point, .arrow] && block.items.map(\.n) == [1, 2])
        #expect(!rig.editor.text.contains("上班打卡按鈕被底部導覽列蓋住"))
        let annotatedPNG = try #require(rig.area.lastAnnotate?.annotatedPNG)
        #expect(annotatedPNG.hasSuffix("-9f3a1c.annotated.png") && rig.area.lastAnnotate?.items == 2)
        // DERIVED: the burned-in copy is in the cache folder, never beside the asset.
        #expect(FileManager.default.fileExists(atPath: rig.root + "/cache/annotated/" + annotatedPNG))
        #expect(!FileManager.default.fileExists(atPath: rig.notesDir + "/assets/rwd-punch-k7x2/9f3a1c.annotated.png"))
        let disk = await rig.fileText(rig.n1)
        #expect(!disk.contains("上班打卡按鈕被底部導覽列蓋住") && disk.contains("\"type\":\"arrow\""), "the autosave wrote the block")
        // ONE undo step brings the whole old block back.
        let undo = try #require(rig.editor.editor.textViewForTesting.undoManager)
        #expect(undo.canUndo)
        undo.undo()
        #expect(rig.editor.text == before)
        #expect(!undo.canUndo, "the rewrite was a single step")
        await rig.tearDown()
    }

    @Test func cancelLeavesTheNoteUnchanged() async throws {
        let rig = try await NotesAreaRig("codd-m4f-cancel", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        let before = rig.editor.text
        let disk = await rig.fileText(rig.n1)
        #expect(await rig.area.annotate(NotesAreaRig.n1Image))
        let screen = try #require(rig.area.annotateSession?.screen)
        try Self.pressDelete(on: screen, in: rig.window)
        #expect(screen.document.items.count == 2)
        screen.cancel()
        #expect(rig.area.mode == .notebook && rig.area.annotateSession == nil)
        try await Task.sleep(for: .milliseconds(300))
        #expect(rig.editor.text == before && !rig.editor.isDirty)
        #expect(await rig.fileText(rig.n1) == disk)
        #expect(rig.area.lastAnnotate == nil)
        await rig.tearDown()
    }

    @Test func aNoteSwitchWhileAnnotatingKeepsTheEdits() async throws {
        let rig = try await NotesAreaRig("codd-m4f-switch", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        #expect(await rig.area.annotate(NotesAreaRig.n1Image))
        let screen = try #require(rig.area.annotateSession?.screen)
        try Self.pressDelete(on: screen, in: rig.window)
        // ⌘K / a link shows another note: the screen closes keeping its edits (like ⎋ / 完成).
        let other = try #require(rig.service.rows.first { $0.id != rig.n1 }?.id)
        rig.area.reveal(other)
        #expect(rig.area.mode == .notebook && rig.area.annotateSession == nil)
        await m3Eventually("the other note shows") { rig.editor.noteID == other && !rig.area.hasPendingRequests }
        await m3Eventually("n1 saved with the edit") { rig.area.lastAnnotate?.items == 2 }
        let disk = await rig.fileText(rig.n1)
        #expect(!disk.contains("上班打卡按鈕被底部導覽列蓋住") && disk.contains("\"type\":\"arrow\""))
        await rig.tearDown()
    }

    @Test func anImageWithoutABlockGetsOneAfterItsLine() async throws {
        let rig = try await NotesAreaRig("codd-m4f-insert")
        defer { rig.removeFolder() }
        let note = try await rig.create("貼圖測試", body: "# 貼圖測試\n\n前一段\n")
        await rig.show(note.metadata.id)
        let png = try M4NotebookCoreFlowTests.png(width: 400, height: 300)
        let ref = try #require(await rig.editor.paste(MarkdownPastedImage(data: png, typeIdentifier: "public.png")))
        await rig.editor.flush()
        #expect(rig.editor.annotations(of: ref.markdownPath) == nil)
        #expect(await rig.area.annotate(ref.markdownPath))
        let session = try #require(rig.area.annotateSession)
        #expect(session.screen.document.items.isEmpty && session.screen.document.pixelSize == CGSize(width: 400, height: 300))
        let document = AnnotationDocument(pixelSize: CGSize(width: 400, height: 300), items: [.rect(1, x: 10, y: 20, w: 100, h: 50, note: "這裡")])
        await rig.area.finishAnnotate(document)
        let blocks = FencedBlocks.find(info: "codd-annotations", in: rig.editor.text)
        #expect(blocks.count == 1 && blocks.first?.imagePath == ref.markdownPath)
        let decoded = try #require(ImageAnnotations.decode(blocks.first?.content ?? ""))
        #expect(decoded.image == ref.relativePath && decoded.items.first?.w == 100 && decoded.items.first?.note == "這裡")
        #expect(rig.area.lastAnnotate?.annotatedPNG?.hasSuffix(".annotated.png") == true)
        // Annotating again and removing every item takes the block out again.
        #expect(await rig.area.annotate(ref.markdownPath))
        await rig.area.finishAnnotate(AnnotationDocument(pixelSize: CGSize(width: 400, height: 300)))
        #expect(FencedBlocks.find(info: "codd-annotations", in: rig.editor.text).isEmpty)
        await rig.tearDown()
    }

    /// ⌫ on the canvas with item 1 selected, as the keyboard sends it.
    static func pressDelete(on screen: ImageAnnotateView, in window: NSWindow) throws {
        screen.selection = 1
        screen.focusCanvas()
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                                                  charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51))
        let responder = try #require(window.firstResponder)
        responder.keyDown(with: event)
    }

    @Test func aNoteWithoutImagesRefusesAnnotate() async throws {
        let rig = try await NotesAreaRig("codd-m4f-noimg")
        defer { rig.removeFolder() }
        let note = try await rig.create("沒有圖片", body: "# 沒有圖片\n\n只有字\n")
        await rig.show(note.metadata.id)
        #expect(await rig.area.annotate() == false)
        #expect(rig.area.mode == .notebook)
        #expect(rig.editor.documentView.toast?.accessibilityLabel() == "這則筆記沒有圖片")
        await rig.tearDown()
    }

    @Test func mappingKeepsUnknownKeysAndDropsAnEmptyBlock() throws {
        let json = """
        {"v":1,"image":"assets/a/x.png","size":[750,1334],"items":[{"n":1,"type":"rect","x":20,"y":30,"w":40,"h":50,"note":"a","mine":7},\
        {"n":2,"type":"text","x":5,"y":6,"note":"字","color":"cyan"}],"send":{"original":true,"annotated":true,"list":false,"keep":1},"top":"t"}
        """
        let annotations = try #require(ImageAnnotations.decode(json))
        let document = NoteAnnotateMapping.document(annotations, imageSize: .zero)
        #expect(document.pixelSize == CGSize(width: 750, height: 1334))
        #expect(document.items[1].kind == .text && document.items[1].color == .cyan)
        #expect(document.send == AnnotationSendOptions(original: true, annotated: true, list: false))
        let back = NoteAnnotateMapping.annotations(document, image: "assets/a/x.png", previous: annotations)
        #expect(back == annotations, "a round trip through the screen keeps every byte's meaning")
        var moved = document
        moved.items[0].x = 99
        let after = NoteAnnotateMapping.annotations(moved, image: "assets/a/x.png", previous: annotations)
        #expect(after.items[0].extra == annotations.items[0].extra, "a moved item keeps its unknown keys by its number")
        #expect(NoteAnnotateMapping.blockJSON(after) == after.encoded())
        let empty = NoteAnnotateMapping.annotations(AnnotationDocument(pixelSize: CGSize(width: 10, height: 10)), image: "x.png", previous: nil)
        #expect(NoteAnnotateMapping.blockJSON(empty) == nil)
        let header = NoteAnnotateMapping.header(listTitle: "Inbox", noteTitle: "n", path: "assets/a/x.png", pixelSize: CGSize(width: 750, height: 1334),
                                                alt: "截圖 2026-10-15 09:32 · iPhone SE")
        #expect(header.meta == ["assets/a/x.png", "750×1334 px", "iPhone SE", "截圖 2026-10-15 09:32"] && header.crumbs == ["INBOX", "n"])
        let root = URL(fileURLWithPath: "/tmp/notes", isDirectory: true)
        #expect(NoteAnnotateMapping.blockImagePath("../assets/a/x.png", resolved: URL(fileURLWithPath: "/tmp/notes/assets/a/x.png"),
                                                   notesRoot: root) == "assets/a/x.png")
    }
}

@Suite("M4 notebook features · menus, metadata, COPY REF, lifecycle", .serialized)
@MainActor
struct M4NotebookMetadataTests {
    static func item(_ id: String, in menu: NotebookMenuModel) -> NotebookMenuItem? {
        for entry in menu.entries {
            if case .item(let item) = entry, item.id == id { return item }
        }
        return nil
    }

    @Test func metadataChangesReachTheFileAndTheNextSaveDoesNotConflict() async throws {
        let rig = try await NotesAreaRig("codd-m4f-meta")
        defer { rig.removeFolder() }
        let note = try await rig.create("後設資料", body: "# 後設資料\n\n內文\n", tags: ["old"])
        let id = note.metadata.id
        await rig.show(id)
        // The AI menu through C7's menu (drawn in place).
        rig.area.chrome.openMenu(.ai)
        let menu = try #require(rig.area.chrome.menuView)
        menu.activate(id: "ai.append")
        await m3Eventually("ai append written") { rig.editor.document?.metadata.ai == .append }
        await rig.area.setScope("~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend")
        await rig.area.perform(.kind(.prompt))
        await rig.area.applyChange(.addTag("rwd"), label: "addTag")
        await rig.area.applyChange(.removeTag("old"), label: "removeTag")
        await rig.area.toggleLink(.session(id: "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"))
        await rig.area.togglePin()
        let text = await rig.fileText(id)
        #expect(text.contains("ai: append"))
        #expect(text.contains("scope: project"))
        #expect(text.contains("~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend"))
        #expect(text.contains("kind: prompt"))
        #expect(text.contains("tags: [rwd]"))
        #expect(text.contains("7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"))
        #expect(text.contains("pinned: true"))
        #expect(rig.area.lastAction?.ok == true && rig.area.lastAction?.kind == "pinned")
        // The chrome shows the new values.
        await m3Eventually("chrome follows") { rig.area.chrome.model.pinned && rig.area.chrome.model.kind == .prompt }
        #expect(rig.area.chrome.model.ai == .append && rig.area.chrome.model.scope?.title == "orb-toolkit-frontend")
        // The editor took the new hash: typing and saving writes, no conflict banner.
        rig.editor.editor.textViewForTesting.setSelectedRange(NSRange(location: (rig.editor.text as NSString).length, length: 0))
        rig.editor.editor.textViewForTesting.insertText("再加一行\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        await rig.editor.flush()
        #expect(rig.editor.diskConflict == nil && !rig.editor.isDirty)
        let saved = await rig.fileText(id)
        #expect(saved.contains("再加一行") && saved.contains("pinned: true"))
        // Unlinking through the picker's toggle.
        await rig.area.toggleLink(.session(id: "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"))
        #expect(rig.editor.document?.metadata.links.sessions.isEmpty == true)
        await rig.tearDown()
    }

    @Test func pickersListSessionsProjectsAndTags() async throws {
        let rig = try await NotesAreaRig("codd-m4f-pick", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        rig.area.presentLinkPicker()
        let picker = try #require(rig.area.linkPicker)
        #expect(!picker.model.sessions.isEmpty && picker.model.sessions.allSatisfy { !$0.id.isEmpty })
        #expect(picker.model.projects.contains { $0.name == "orb-toolkit-frontend" })
        #expect(picker.model.linked.contains(.project(id: MockNotes.frontend)))
        await rig.area.toggleLink(.project(id: MockNotes.gear))
        #expect(rig.editor.document?.metadata.links.projects.contains(MockNotes.gear) == true)
        #expect(rig.area.linkPicker?.model.linked.contains(.project(id: MockNotes.gear)) == true, "an open picker follows")
        rig.area.pickerPresenter.dismiss()
        #expect(rig.area.linkPicker == nil)
        await m3Eventually("chips allow tags") { rig.editor.chipsRow.model.allowsAddTag }
        rig.area.presentTagEditor()
        let tags = try #require(rig.area.tagEditor)
        #expect(tags.model.tags == ["rwd", "punch"])
        #expect(!tags.model.suggestions.contains("rwd"))
        tags.onAdd?("mobile")
        await m3Eventually("tag added") { rig.editor.document?.metadata.tags.contains("mobile") == true }
        await m3Eventually("editor follows") { rig.area.tagEditor?.model.tags.contains("mobile") == true }
        await rig.tearDown()
    }

    @Test func copyRefFormsGoThroughThePrivatePasteboard() async throws {
        let rig = try await NotesAreaRig("codd-m4f-ref", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        let refs = try #require(rig.area.chrome.model.refs)
        #expect(refs.uri == "codd://note/rwd-punch-k7x2" && refs.mention == "@codd:codd://note/rwd-punch-k7x2")
        #expect(refs.url == "http://127.0.0.1:47999/n/rwd-punch-k7x2.md?t=••••", "the chrome never shows the token")
        #expect(rig.area.chrome.model.copyRefDisabledReason == nil)
        let uri = await rig.area.copyReference(.uri)
        #expect(uri == "codd://note/rwd-punch-k7x2" && CoddPasteboard.privateString() == uri)
        #expect(rig.pasteboard.lastWrite?.target == .private, "D39: never the general pasteboard in a background run")
        #expect(await rig.area.copyReference(.mention) == "@codd:codd://note/rwd-punch-k7x2")
        let path = try #require(await rig.area.copyReference(.path))
        #expect(path.hasPrefix(rig.notesDir) && path.hasSuffix("2026-10-15-打卡頁-rwd-跑版紀錄.md"))
        let token = MCPAuth.noteURLToken(mcpToken: NotesAreaRig.mcpToken, noteID: "rwd-punch-k7x2")
        #expect(await rig.area.copyReference(.url) == "http://127.0.0.1:47999/n/rwd-punch-k7x2.md?t=\(token)")
        #expect(rig.area.lastCopyRef?.text == "http://127.0.0.1:47999/n/rwd-punch-k7x2.md?t=••••", "the dump masks it")
        let markdown = try #require(await rig.area.copyReference(.markdown))
        #expect(!markdown.hasPrefix("---") && markdown.contains(rig.notesDir + "/assets/rwd-punch-k7x2/9f3a1c.png"))
        #expect(rig.area.lastCopyRef?.text == "（全文 Markdown）" && rig.area.lastCopyRef?.chars == markdown.count)
        // DEBUG `-codd-notes-copy-ref`: the dump only, no pasteboard at all.
        let writes = rig.pasteboard.lastWrite
        #expect(await rig.area.copyReference(.uri, userAction: false) == "codd://note/rwd-punch-k7x2")
        #expect(rig.pasteboard.lastWrite == writes && rig.area.lastCopyRef?.target == "none")
        // An OFF note offers no URL (D15), in the menu and in the copy.
        await rig.area.applyChange(.ai(.off), label: "ai")
        await m3Eventually("chrome shows OFF") { rig.area.chrome.model.ai == .off }
        let menu = rig.area.chrome.menuModel(for: .copyRef)
        let urlItem = try #require(Self.item("ref.5", in: menu))
        #expect(!urlItem.isEnabled && urlItem.hint == "AI 存取為 OFF，不提供網址")
        #expect(Self.item("ref.1", in: menu)?.isEnabled == true)
        #expect(await rig.area.copyReference(.url) == nil)
        #expect(rig.area.lastCopyRef?.target == "refused")
        // ⋯ › 複製 ID.
        await rig.area.perform(.copyID)
        #expect(CoddPasteboard.privateString() == "rwd-punch-k7x2")
        // A note that is not on disk yet (D3): every form disabled, nothing copied.
        rig.area.newNote()
        await m3Eventually("draft") { rig.editor.draft != nil && !rig.area.hasPendingRequests }
        await m3Eventually("chrome unsaved") { rig.area.chrome.model.noteID == nil }
        let unsaved = rig.area.chrome.menuModel(for: .copyRef)
        for form in 1...5 { #expect(Self.item("ref.\(form)", in: unsaved)?.isEnabled == false) }
        #expect(rig.area.chrome.model.aiDisabledReason == NotebookCopy.unsavedReason)
        #expect(await rig.area.copyReference(.uri) == nil)
        await rig.tearDown()
    }

    @Test func sendMenuListsLiveSessionsWithTheirThreeActions() async throws {
        let rig = try await NotesAreaRig("codd-m4f-send", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        await m3Eventually("chrome") { rig.area.chrome.model.noteID == MockNotes.n1ID }
        #expect(rig.area.chrome.model.sendDisabledReason == nil)
        let menu = rig.area.chrome.menuModel(for: .send)
        let sessions = menu.entries.compactMap { entry -> NotebookMenuItem? in
            if case .item(let item) = entry, item.id.hasPrefix("session.") { return item }
            return nil
        }
        #expect(!sessions.isEmpty, "live CODD claude sessions")
        let actions = sessions.first?.submenu?.entries.compactMap { entry -> NotebookMenuItem? in
            if case .item(let item) = entry { return item }
            return nil
        } ?? []
        #expect(actions.count == 3 && actions.allSatisfy { $0.isEnabled && $0.disabledReason == nil }, "I2b wired them")
        await rig.tearDown()
    }

    @Test func trashAndArchiveUndoBringTheNoteBack() async throws {
        let rig = try await NotesAreaRig("codd-m4f-trash")
        defer { rig.removeFolder() }
        let first = try await rig.create("第一則", body: "# 第一則\n\nA\n")
        rig.clock.advance(minutes: 1)
        let second = try await rig.create("第二則", body: "# 第二則\n\nB\n")
        let id = second.metadata.id
        await rig.show(id)
        let path = second.fileURL.path
        await rig.area.trashShown()
        #expect(!FileManager.default.fileExists(atPath: path))
        let trashed = rig.notesDir + "/.codd/trash/" + second.relativePath
        #expect(FileManager.default.fileExists(atPath: trashed))
        #expect((try? String(contentsOfFile: trashed, encoding: .utf8))?.contains("trashed: ") == true)
        await m3Eventually("counts") { rig.service.counts.trash == 1 && rig.service.counts.inbox == 1 }
        await m3Eventually("the neighbour is shown") { rig.editor.noteID == first.metadata.id }
        let toast = try #require(rig.editor.documentView.toast)
        #expect(toast.accessibilityLabel() == "✕ 已移到垃圾桶 · 30 天後永久刪除" && toast.hasUndo)
        #expect(rig.area.lastAction?.kind == "trash" && rig.area.lastAction?.ok == true)
        toast.performUndo()
        await m3Eventually("restored") { FileManager.default.fileExists(atPath: path) && rig.service.counts.trash == 0 }
        await m3Eventually("shown again") { rig.editor.noteID == id }
        // 封存 → ARCHIVE, UNDO → back in INBOX.
        await rig.area.archiveShown()
        await m3Eventually("archived") { rig.service.counts.archive == 1 }
        #expect(await rig.fileText(id).contains("archivedBy: user"))
        let archiveToast = try #require(rig.editor.documentView.toast)
        #expect(archiveToast.accessibilityLabel() == "已封存")
        archiveToast.performUndo()
        await m3Eventually("unarchived") { rig.service.counts.archive == 0 && rig.service.counts.inbox == 2 }
        #expect(await !rig.fileText(id).contains("archivedBy"))
        await rig.tearDown()
    }

    @Test func anUnparsableFrontmatterIsRefusedWithAToast() async throws {
        let text = "---\nid: broken-fm1a\ntitle: 壞掉的\nmeta: {a: 1}\n---\n# 壞掉的\n\n內文\n"
        let rig = try await NotesAreaRig("codd-m4f-broken", files: ["2026-10-15-壞掉的.md": text])
        defer { rig.removeFolder() }
        let id = NoteID(rawValue: "broken-fm1a")!
        await rig.show(id)
        #expect(await rig.area.applyChange(.ai(.off), label: "ai") == false)
        #expect(rig.area.lastAction?.error == "這則筆記的 frontmatter 無法解析，請先手動修正")
        #expect(rig.editor.documentView.toast?.accessibilityLabel() == "這則筆記的 frontmatter 無法解析，請先手動修正")
        await rig.area.trashShown()
        #expect(rig.area.lastAction?.kind == "trash" && rig.area.lastAction?.ok == false)
        #expect(FileManager.default.fileExists(atPath: rig.notesDir + "/2026-10-15-壞掉的.md"), "nothing moved")
        #expect((try? String(contentsOfFile: rig.notesDir + "/2026-10-15-壞掉的.md", encoding: .utf8)) == text, "never rewritten")
        await rig.tearDown()
    }

    @Test func revealInFinderIsTheUsersChoiceOnly() async throws {
        let rig = try await NotesAreaRig("codd-m4f-reveal", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        await rig.area.perform(.revealInFinder)
        #expect(rig.revealed.map(\.lastPathComponent) == ["2026-10-15-打卡頁-rwd-跑版紀錄.md"])
        await rig.tearDown()
    }
}

@Suite("M4 notebook features · info panel and HISTORY", .serialized)
@MainActor
struct M4NotebookHistoryTests {
    @Test func compareShowsTheChangeAndRestoreSnapshotsFirst() async throws {
        let rig = try await NotesAreaRig("codd-m4f-history")
        defer { rig.removeFolder() }
        let note = try await rig.create("版本", body: "# 版本\n\n第一版\n")
        let id = note.metadata.id
        await rig.show(id)
        let view = rig.editor.editor.textViewForTesting
        rig.clock.advance(minutes: 10)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("第二版\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        await rig.editor.flush()
        // One minute later: saved, but too soon for another snapshot (D8: 5 minutes), so only the
        // restore's own snapshot keeps this text.
        rig.clock.advance(minutes: 1)
        view.insertText("第三版\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        await rig.editor.flush()
        let current = rig.editor.text
        let state = try #require(await rig.area.makeHistoryCompare())
        #expect(state.snapshots.count >= 2)
        #expect(state.toID == HistoryCompareState.currentID && state.texts[state.fromID] != current)
        let model = rig.area.historyModel(state)
        #expect(model.versions.first?.title == "目前的內容" && model.versions.count == state.snapshots.count + 1)
        #expect(model.restoreEnabled && model.lines.contains { $0.kind == .added && $0.text == "第三版" })
        #expect(model.summary.hasPrefix("−"))
        // The current version on the left has nothing to restore.
        var same = state
        same.fromID = HistoryCompareState.currentID
        #expect(!rig.area.historyModel(same).restoreEnabled)
        let old = try #require(state.texts[state.fromID])
        #expect(await rig.area.restoreVersion(state.fromID))
        #expect(rig.editor.text == old && !rig.editor.isDirty)
        let disk = try await rig.service.document(id)
        #expect(disk.body == old)
        let history = try await rig.service.history(of: id)
        let restoreSnapshot = try #require(history.first { $0.reason == "restore" }, "D8: the current text was snapshotted before the restore")
        #expect(try await rig.service.snapshotText(restoreSnapshot, of: id) == current)
        #expect(rig.editor.documentView.toast?.accessibilityLabel()?.hasPrefix("已還原") == true)
        // The restore is an undoable step of the editor (C4's external-text edit).
        let undo = try #require(rig.editor.editor.textViewForTesting.undoManager)
        #expect(undo.canUndo && undo.undoActionName == "外部變更")
        await rig.tearDown()
    }

    @Test func historyRowsSelectAndAssetsScrollToTheirImage() async throws {
        let rig = try await NotesAreaRig("codd-m4f-info", mock: true)
        defer { rig.removeFolder() }
        await rig.show(rig.n1)
        await m3Eventually("info") { rig.area.chrome.model.info != nil }
        let info = try #require(rig.area.chrome.model.info)
        #expect(info.actionsDisabledReason == nil)
        #expect(info.history.count == 3)
        let older = info.history[1].id
        rig.area.selectHistory(older)
        #expect(rig.area.chrome.model.info?.history[1].isSelected == true)
        #expect(rig.area.chrome.model.info?.history[0].isSelected == false, "the current row is never the selected one")
        let state = try #require(await rig.area.makeHistoryCompare())
        #expect(state.fromID == older)
        // ASSETS: the thumbnail scrolls the editor to the image line.
        rig.editor.editor.textViewForTesting.setSelectedRange(NSRange(location: 0, length: 0))
        rig.area.openAsset(NotesAreaRig.n1Image)
        let caret = rig.editor.editor.textViewForTesting.selectedRange().location
        let line = (rig.editor.text as NSString).substring(with: (rig.editor.text as NSString).lineRange(for: NSRange(location: caret, length: 0)))
        #expect(line.hasPrefix("![截圖 2026-10-15 09:32"))
        rig.area.openAsset("assets/rwd-punch-k7x2/2b7e04.png")
        #expect(rig.editor.documentView.toast?.accessibilityLabel() == "這張圖片沒有出現在內文裡")
        // RETENTION [釘選以保留].
        rig.area.chrome.infoPanel.onTogglePin?()
        await m3Eventually("pinned") { rig.editor.document?.metadata.pinned == true }
        await rig.tearDown()
    }
}

@Suite("M4 notebook features · ⌘K NOTES and menus")
@MainActor
struct M4NotebookPaletteMenuTests {
    private static let notes: [QuickSwitchModel.Input.Note] = [
        .init(id: "rwd-punch-k7x2", title: "打卡頁 RWD 跑版紀錄", tags: ["rwd", "punch"], kind: "note", time: "10:05"),
        .init(id: "prompt-401-b3m9", title: "給後端的 prompt：401 修正", tags: [], kind: "prompt", time: "10:02"),
        .init(id: "mcp-demo-r8q1", title: "MCP 示範腳本重點", tags: ["mcp"], kind: "note", time: "09:40"),
        .init(id: "v2-review-h4n6", title: "程式碼審查標準 v2", tags: ["review"], kind: "note", time: "09:12"),
        .init(id: "cjk-search-note", title: "注音輸入法筆記", tags: ["打卡"], kind: "scratch", time: "10/12"),
    ]

    @Test func notesRankByTitleThenTagsAndSitAfterSessions() {
        let input = QuickSwitchModel.Input.make(store: MockSessionStore(), shell: ShellState(), recent: [
            RecentProject(path: "/Users/x/Project/orb-toolkit-suite/打卡紀錄前端介面"),
        ], notes: Self.notes)
        let model = QuickSwitchModel.build(query: "打卡", input: input)
        #expect(model.groups.map(\.section) == [.sessions, .notes, .projects, .actions], "QuickSwitch artboard order")
        let notes = model.groups[1].rows
        #expect(notes.first?.item == .note("rwd-punch-k7x2"))
        #expect(notes.first?.spans == [TextSpan(location: 0, length: 2)], "打卡 drawn amber in the title")
        #expect(notes.first?.detail == "note · #rwd #punch" && notes.first?.shortcut == "10:05")
        #expect(notes.last?.item == .note("cjk-search-note") && notes.last?.spans == [], "a tag match counts half and highlights nothing")
        #expect(model.dumpRows.contains { $0["section"] as? String == "notes" })
        #expect(QuickSwitchModel.commandEnter(.note("rwd-punch-k7x2"), input: input) == .same)
        // At most five.
        var many = QuickSwitchModel.Input()
        many.notes = (1...9).map { .init(id: "n\($0)", title: "筆記 \($0)", tags: [], kind: "note", time: "10:0\($0)") }
        #expect(QuickSwitchModel.build(query: "筆記", input: many).groups.first?.rows.count == 5)
    }

    @Test func anEmptyQueryListsTheThreeNewestAfterTheSessions() {
        let input = QuickSwitchModel.Input.make(store: MockSessionStore(), shell: ShellState(), recent: [], notes: Self.notes)
        let model = QuickSwitchModel.build(query: "", input: input)
        #expect(model.groups.map(\.section) == [.sessions, .notes, .actions])
        #expect(model.groups[1].rows.map(\.item) == [.note("rwd-punch-k7x2"), .note("prompt-401-b3m9"), .note("mcp-demo-r8q1")])
        #expect(model.groups[1].rows[1].detail == "prompt", "no tags: the kind alone")
        // Without notes the M2 sections are unchanged.
        let none = QuickSwitchModel.build(query: "", input: QuickSwitchModel.Input.make(store: MockSessionStore(), shell: ShellState(), recent: []))
        #expect(none.groups.map(\.section) == [.sessions, .actions])
    }

    @Test func notesMenuItemsValidateByAreaModeAndComposition() {
        let notebook = MenuAreaRules(area: .notes, noteShown: true, notesReady: true, noteSaved: true, noteHasImage: true)
        #expect(notebook.isEnabled(#selector(AppDelegate.annotateImage(_:))) == true)
        #expect(notebook.isEnabled(#selector(AppDelegate.copyNoteReference(_:))) == true)
        #expect(notebook.isEnabled(#selector(AppDelegate.allowCurrentSession(_:))) == false, "⌘⏎ stays with the sessions area")
        var noImage = notebook
        noImage.noteHasImage = false
        #expect(noImage.isEnabled(#selector(AppDelegate.annotateImage(_:))) == false)
        var draft = notebook
        draft.noteSaved = false
        #expect(draft.isEnabled(#selector(AppDelegate.annotateImage(_:))) == false)
        #expect(draft.isEnabled(#selector(AppDelegate.copyNoteReference(_:))) == false)
        var composing = notebook
        composing.hasMarkedText = true
        #expect(composing.isEnabled(#selector(AppDelegate.copyNoteReference(_:))) == false)
        #expect(composing.isEnabled(#selector(AppDelegate.annotateImage(_:))) == false)
        var annotating = notebook
        annotating.notesMode = .annotate
        #expect(annotating.isEnabled(#selector(AppDelegate.annotateImage(_:))) == false)
        #expect(annotating.isEnabled(#selector(AppDelegate.toggleNoteSource(_:))) == false)
        #expect(annotating.isEnabled(#selector(AppDelegate.searchNotes(_:))) == false)
        #expect(annotating.isEnabled(#selector(AppDelegate.copyNoteReference(_:))) == true)
        let sessions = MenuAreaRules(area: .sessions, noteShown: true, notesReady: true, canAllow: true, noteSaved: true, noteHasImage: true)
        #expect(sessions.isEnabled(#selector(AppDelegate.annotateImage(_:))) == false)
        #expect(sessions.isEnabled(#selector(AppDelegate.copyNoteReference(_:))) == false)
        #expect(sessions.isEnabled(#selector(AppDelegate.allowCurrentSession(_:))) == true)
        #expect(sessions.isEnabled(#selector(AppDelegate.togglePinCurrentSession(_:))) == nil, "⌘P is the sessions area's own rule")
    }

    @Test func theNotesMenuHasAnnotateAndCopyReference() throws {
        let commands = StubCommands()
        let menu = MainMenuBuilder.build(commands: commands)
        let notes = try #require(menu.items.first { $0.title == "筆記" }?.submenu)
        let annotate = try #require(notes.items.first { $0.title == "標註模式" })
        #expect(annotate.keyEquivalent == "A" && annotate.keyEquivalentModifierMask == [.command, .shift])
        let copy = try #require(notes.items.first { $0.title == "複製引用" })
        #expect(copy.keyEquivalent == "C" && copy.keyEquivalentModifierMask == [.command, .shift])
        #expect(notes.items.map(\.title).filter { !$0.isEmpty } == ["快速筆記", "筆記本", "檔案", "清理建議", "原始碼", "標註模式", "複製引用", "搜尋筆記"])
    }

    @Test func i1bFlagsParse() {
        let options = RealModeOptions.parse(arguments: [
            "CODD", "-codd-notes-set", "rwd-punch-k7x2:ai=append", "-codd-notes-set", "rwd-punch-k7x2:tags=a,b",
            "-codd-notes-copy-ref", "rwd-punch-k7x2:5", "-codd-notes-annotate", "rwd-punch-k7x2:9f3a1c.png:/tmp/a.json",
            "-codd-notes-trash", "x-1a2b", "-codd-notes-archive", "y-1a2b", "-codd-notes-menu", "COPY-REF",
        ], environment: [:], home: "/Users/someone")
        #expect(options.notesSet == ["rwd-punch-k7x2:ai=append", "rwd-punch-k7x2:tags=a,b"])
        #expect(options.notesCopyRef == "rwd-punch-k7x2:5")
        #expect(options.notesAnnotate == "rwd-punch-k7x2:9f3a1c.png:/tmp/a.json")
        #expect(options.notesTrash == "x-1a2b" && options.notesArchive == "y-1a2b" && options.notesMenu == "copy-ref")
        #expect(options.releaseSubset.notesSet.isEmpty && options.releaseSubset.notesMenu == nil)
    }

    @Test func maskedReferenceTextsNeverCarryTheToken() {
        #expect(NoteReferenceSet.masked("http://127.0.0.1:1/n/a.md?t=0123456789abcdef01234567", kind: .url) == "http://127.0.0.1:1/n/a.md?t=••••")
        #expect(NoteReferenceSet.masked("codd://note/a", kind: .uri) == "codd://note/a")
        let set = NoteReferenceSet(id: NoteID(rawValue: "a-1b2c")!, fileURL: URL(fileURLWithPath: "/tmp/a.md"), port: nil, urlToken: nil, ai: .read)
        #expect(set.refusal(.url) != nil && set.refusal(.uri) == nil)
        #expect(set.displayTexts.url == "http://127.0.0.1:—/n/a-1b2c.md")
    }
}
