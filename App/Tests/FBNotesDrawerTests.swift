import AppKit
import CoddNotebookUI
import CoddNotes
import CoddTextKit
import Foundation
import Testing
@testable import CODD

// The session drawer edits its note in place (user feedback 2026-10-19: 「session 右側的 note 可編輯」): a
// card's title opens the note in the drawer's own editor with the Notebook's rules (autosave
// after the last committed change, never while composing, the D7 banner, image paste into the
// note's assets), the editor is saved when the user goes back, the drawer closes or another
// session shows, and the same note open in the Notebook and the drawer stays one text. The SPEC
// §5 mock notebook on a temp data root; windows are never ordered on screen; sends are recorded.

/// The NOTES area rig with the send path, plus the drawer in its own never-shown window, both
/// editors on the service's hooks as the app wires them.
@MainActor
final class DrawerRig {
    let send: SendRig
    let drawer: NotesDrawerController
    let window: NSWindow

    var notes: NotesAreaRig { send.notes }
    var n1: NoteID { notes.n1 }
    let qa = NoteID(rawValue: "punch-qa-m4n2")!

    init(_ prefix: String) async throws {
        send = try await SendRig(prefix)
        let notes = send.notes
        drawer = NotesDrawerController(notes: notes.service, store: notes.store, preferences: notes.preferences)
        drawer.editor.autosaveDelay = .milliseconds(150)
        NoteEditors([notes.editor, drawer.editor]).attach(to: notes.service)
        // Deferred: no backing store, no display pass (as the NOTES area rig's window).
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = drawer.view
        drawer.view.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
        drawer.view.layoutSubtreeIfNeeded()
    }

    /// Shows `session`'s drawer and opens `id` as its card's title does.
    func edit(_ id: NoteID, in session: SessionID = "s9") async {
        drawer.show(session)
        drawer.view.onEditNote?(id.rawValue)
        await m3Eventually("\(id.rawValue) in the drawer") {
            drawer.editor.noteID == id && drawer.view.model.editing?.id == id.rawValue && drawer.view.model.editing?.save != nil
        }
    }

    /// The editor's load / leave settled (the session change runs on the next main-actor turn).
    func settle() async {
        try? await Task.sleep(for: .milliseconds(50))
        await drawer.editorTask?.value
    }

    func fileText(_ id: NoteID) async -> String { await notes.fileText(id) }

    func tearDown() async {
        drawer.show(nil)
        await settle()
        await drawer.flushForLeaving()
        removeWindow()
        await send.tearDown()
    }

    func removeWindow() {
        window.contentView = nil
        window.close()
    }

    static func isSaved(_ state: NoteSaveState?) -> Bool {
        if case .saved? = state { return true }
        return false
    }
}

@Suite("FB notes drawer · editing in place", .serialized)
@MainActor
struct FBNotesDrawerTests {
    @Test func aCardTitleOpensTheNoteInTheDrawerAndItAutosaves() async throws {
        let rig = try await DrawerRig("codd-fb-drawer-edit")
        defer { rig.removeWindow(); rig.notes.removeFolder() }
        rig.drawer.show("s9")
        await m3Eventually("cards") { rig.drawer.view.model.cards.count == 2 }
        #expect(rig.drawer.view.onEditNote != nil, "the title edits in place (the Notebook is `[筆記本 ↗]`)")
        // Long enough to see `● 未儲存` before the write.
        rig.drawer.editor.autosaveDelay = .milliseconds(400)
        await rig.edit(rig.n1)
        let view = rig.drawer.view
        #expect(view.isEditing && view.model.editing?.title == "打卡頁 RWD 跑版紀錄")
        #expect(DrawerRig.isSaved(view.model.editing?.save))
        #expect(rig.drawer.editor.documentView.isDescendant(of: view), "the note editor fills the drawer")
        #expect(rig.drawer.editor.placement == .drawer && rig.drawer.editor.editor.titleAccessory == nil)
        #expect(rig.drawer.editor.text.hasPrefix("# 打卡頁 RWD 跑版紀錄"))
        // Autosave after the last committed change.
        rig.drawer.editor.type(" 抽屜裡加的")
        #expect(rig.drawer.editor.isDirty && rig.drawer.editor.saveCount == 0)
        await m3Eventually("unsaved shown") { view.model.editing?.save == .unsaved }
        await m3Eventually("autosaved") { rig.drawer.editor.saveCount == 1 }
        #expect(await rig.fileText(rig.n1).contains("抽屜裡加的"))
        await m3Eventually("saved shown") { DrawerRig.isSaved(view.model.editing?.save) }
        // Never while an input method composes; the committed text is saved once it ends.
        let textView = rig.drawer.editor.editor.textViewForTesting
        rig.drawer.editor.type("x")
        textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(for: .milliseconds(500))
        #expect(textView.hasMarkedText() && rig.drawer.editor.saveCount == 1, "nothing written while composing")
        await rig.drawer.editor.flush()
        #expect(rig.drawer.editor.saveCount == 1, "a flush waits for the composition too")
        textView.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        await m3Eventually("saved after the composition") { rig.drawer.editor.saveCount == 2 }
        let file = await rig.fileText(rig.n1)
        #expect(file.contains("x中") && !file.contains("ㄓ"))
        await rig.tearDown()
    }

    @Test func leavingSavesAtOnceAndEachSessionKeepsItsNote() async throws {
        let rig = try await DrawerRig("codd-fb-drawer-leave")
        defer { rig.removeWindow(); rig.notes.removeFolder() }
        rig.drawer.editor.autosaveDelay = .seconds(30)
        await rig.edit(rig.n1)
        // The drawer closes: written now, the editor emptied, the note remembered for s9.
        rig.drawer.editor.type(" 關抽屜前")
        rig.drawer.show(nil)
        await m3Eventually("flushed on close") { rig.drawer.editor.saveCount == 1 && rig.drawer.editor.noteID == nil }
        #expect(await rig.fileText(rig.n1).contains("關抽屜前"))
        #expect(!rig.drawer.view.isEditing && rig.drawer.editingBySession["s9"] == rig.n1)
        // Shown again: the note comes back.
        rig.drawer.show("s9")
        await m3Eventually("reopened") { rig.drawer.editor.noteID == rig.n1 && rig.drawer.view.isEditing }
        #expect(rig.drawer.editor.text.contains("關抽屜前"))
        // Another session: written now, that session shows its cards.
        rig.drawer.editor.type(" 換 session 前")
        rig.drawer.show("s6")
        await m3Eventually("flushed on switch") { rig.drawer.editor.saveCount == 2 && rig.drawer.editor.noteID == nil }
        #expect(await rig.fileText(rig.n1).contains("換 session 前"))
        #expect(!rig.drawer.view.isEditing)
        // Another note: the first is written before the second loads.
        await rig.edit(rig.n1)
        rig.drawer.editor.type(" 換筆記前")
        await rig.edit(rig.qa)
        #expect(rig.drawer.editor.saveCount == 3)
        #expect(await rig.fileText(rig.n1).contains("換筆記前"))
        #expect(rig.drawer.view.model.editing?.title == "打卡頁 QA 清單")
        // ‹ LINKED NOTES: written, the cards again, nothing remembered for s9.
        rig.drawer.editor.type(" 回卡片前")
        rig.drawer.view.onBack?()
        await m3Eventually("flushed on back") { rig.drawer.editor.saveCount == 4 && rig.drawer.editor.noteID == nil }
        #expect(await rig.fileText(rig.qa).contains("回卡片前"))
        #expect(!rig.drawer.view.isEditing && rig.drawer.editingBySession["s9"] == nil)
        // Quit: the app's flush writes the drawer's pending text too.
        await rig.edit(rig.n1)
        rig.drawer.editor.type(" 結束前")
        await rig.drawer.flushForLeaving()
        #expect(await rig.fileText(rig.n1).contains("結束前"))
        await rig.tearDown()
    }

    /// The same note in the Notebook and the drawer: a save in one is taken by the other (a clean
    /// editor reloads in place), and with text typed in both the later one gets the D7 banner
    /// instead of writing over the first.
    @Test func theSameNoteInTheNotebookAndTheDrawerStaysOneText() async throws {
        let rig = try await DrawerRig("codd-fb-drawer-two")
        defer { rig.removeWindow(); rig.notes.removeFolder() }
        await rig.notes.show(rig.n1)
        await rig.edit(rig.n1)
        let notebook = rig.notes.editor
        let drawer = rig.drawer.editor
        let notebookSaves = notebook.saveCount
        // The drawer writes: the Notebook's clean editor shows it.
        drawer.type(" 抽屜寫的")
        await m3Eventually("drawer saved") { drawer.saveCount == 1 }
        await m3Eventually("the Notebook follows") { notebook.text.contains("抽屜寫的") }
        #expect(notebook.peerReloads == 1 && notebook.diskConflict == nil && !notebook.isDirty)
        #expect(notebook.saveCount == notebookSaves, "taking a save is not a write")
        // The Notebook writes: the drawer shows it.
        notebook.type(" 筆記本寫的")
        await m3Eventually("Notebook saved") { notebook.saveCount == notebookSaves + 1 }
        await m3Eventually("the drawer follows") { drawer.text.contains("筆記本寫的") }
        #expect(drawer.peerReloads == 1 && drawer.diskConflict == nil && !drawer.isDirty)
        // Both typed: the first write lands, the other editor gets the banner and writes nothing.
        drawer.autosaveDelay = .seconds(30)
        notebook.autosaveDelay = .seconds(30)
        drawer.type("甲")
        notebook.type("乙")
        await drawer.flush()
        #expect(notebook.diskConflict != nil && notebook.documentView.showsBanner)
        #expect(notebook.documentView.banner.model.title == "磁碟上的筆記已變更")
        #expect(notebook.text.hasSuffix("乙") && !notebook.text.contains("甲"), "unsaved text is never replaced")
        await notebook.flush()
        #expect(notebook.saveCount == notebookSaves + 1, "the banner waits for the user: no second writer")
        var file = await rig.fileText(rig.n1)
        #expect(file.contains("甲") && !file.contains("乙"))
        // 保留我的: the Notebook's text is written (the drawer's version goes to HISTORY), the
        // clean drawer takes it.
        await notebook.keepMine()
        file = await rig.fileText(rig.n1)
        #expect(file.contains("乙") && !file.contains("甲"))
        await m3Eventually("the drawer takes 保留我的") { drawer.text.contains("乙") }
        #expect(!drawer.text.contains("甲") && drawer.diskConflict == nil)
        await rig.tearDown()
    }

    /// A frontmatter rewrite through the Notebook (a tag) leaves the drawer's hash behind: its next
    /// save goes over the new hash (the tag kept), never a banner for an unchanged body.
    @Test func aFrontmatterChangeInTheNotebookNeverBannersTheDrawer() async throws {
        let rig = try await DrawerRig("codd-fb-drawer-meta")
        defer { rig.removeWindow(); rig.notes.removeFolder() }
        await rig.notes.show(rig.n1)
        await rig.edit(rig.n1)
        #expect(await rig.notes.area.applyChange(.addTag("drawer"), label: "addTag"))
        rig.drawer.editor.type(" 標籤之後")
        await m3Eventually("saved over the new hash") { rig.drawer.editor.saveCount == 1 }
        #expect(rig.drawer.editor.diskConflict == nil && !rig.drawer.editor.documentView.showsBanner)
        let document = try await rig.notes.service.document(rig.n1)
        #expect(document.body.contains("標籤之後") && document.metadata.tags.contains("drawer"))
        await m3Eventually("the Notebook follows") { rig.notes.editor.text.contains("標籤之後") }
        await rig.tearDown()
    }

    /// 送出全文 from the drawer sends what was just typed there (the AI flush reaches the drawer's
    /// editor); an external edit reloads the clean drawer; a pasted image lands in the note's assets.
    @Test func sendsDiskChangesAndPastesReachTheDrawerEditor() async throws {
        let rig = try await DrawerRig("codd-fb-drawer-hooks")
        defer { rig.removeWindow(); rig.notes.removeFolder() }
        rig.drawer.editor.autosaveDelay = .seconds(30)
        await rig.edit(rig.n1)
        rig.drawer.editor.type(" 還沒存的一句")
        #expect(await rig.send.sending.perform(.submit, note: rig.n1, to: "s9") == .sent("s9"))
        let last = try #require(rig.send.sent.last)
        #expect(SendRig.text(last.input).contains("還沒存的一句"), "the drawer's text was written before the send read it")
        #expect(rig.drawer.editor.saveCount == 1 && !rig.drawer.editor.isDirty)
        // Another program appends: the clean drawer reloads in place.
        let url = try await rig.notes.service.document(rig.n1).fileURL
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("外面加的一行\n".utf8))
        try handle.close()
        await m3Eventually("the drawer reloads", timeout: .seconds(10)) { rig.drawer.editor.text.contains("外面加的一行") }
        #expect(rig.drawer.editor.externalReloads == 1 && rig.drawer.editor.diskConflict == nil)
        // An image pasted in the drawer: the note's assets, the Markdown at the caret, the toast here.
        let png = try M4NotebookCoreFlowTests.png(width: 64, height: 48)
        let ref = try #require(await rig.drawer.editor.paste(MarkdownPastedImage(data: png, typeIdentifier: "public.png")))
        #expect(ref.relativePath.hasPrefix("assets/\(rig.n1.rawValue)/"))
        #expect(rig.drawer.editor.text.contains("](\(ref.markdownPath))"))
        #expect(rig.drawer.editor.documentView.toast != nil, "the paste toast shows in the drawer")
        await rig.drawer.flushForLeaving()
        #expect(await rig.fileText(rig.n1).contains(ref.markdownPath))
        await rig.tearDown()
    }
}
