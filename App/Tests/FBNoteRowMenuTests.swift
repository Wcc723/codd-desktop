import Foundation
import Testing
import CoddNotes
import CoddNotebookUI
@testable import CODD

/// The user's note 2026-10-20 「Note 列表可以右鍵 -> 刪除文章」: every list row has the ⋯ menu's
/// pin and lifecycle items, and they act on that row even when another note is shown.
@Suite("FB notebook · the list row's right-click menu", .serialized)
@MainActor
struct FBNoteRowMenuTests {
    @Test func theMenuFollowsTheNotesState() {
        var m = NoteMetadata(id: NoteID(rawValue: "row-menu-1a")!, title: "列", created: .now, updated: .now)
        #expect(NotebookPresenter.rowActions(m).map(\.id) == ["pin", "archive", "trash"])
        #expect(NotebookPresenter.rowActions(m).last?.isDestructive == true)
        m.pinned = true
        #expect(NotebookPresenter.rowActions(m).first?.title == "取消釘選")
        m.state = .archived(at: .now, by: .user)
        #expect(NotebookPresenter.rowActions(m).map(\.id) == ["unarchive", "trash"])
        m.state = .trashed(at: .now)
        #expect(NotebookPresenter.rowActions(m).map(\.id) == ["restore"])
    }

    @Test func trashingAnotherRowKeepsTheShownNoteAndUndoBringsItBack() async throws {
        let rig = try await NotesAreaRig("codd-fb-rowmenu")
        defer { rig.removeFolder() }
        let other = try await rig.create("別則", body: "# 別則\n\nA\n")
        rig.clock.advance(minutes: 1)
        let shown = try await rig.create("顯示中", body: "# 顯示中\n\nB\n")
        await rig.show(shown.metadata.id)
        let path = other.fileURL.path
        await rig.area.rowAction(other.metadata.id, "trash")
        #expect(!FileManager.default.fileExists(atPath: path))
        await m3Eventually("counts") { rig.service.counts.trash == 1 && rig.service.counts.inbox == 1 }
        #expect(rig.editor.noteID == shown.metadata.id, "the shown note stays")
        let toast = try #require(rig.editor.documentView.toast)
        #expect(toast.accessibilityLabel() == "✕ 已移到垃圾桶 · 30 天後永久刪除" && toast.hasUndo)
        toast.performUndo()
        await m3Eventually("restored") { FileManager.default.fileExists(atPath: path) && rig.service.counts.trash == 0 }
        #expect(rig.editor.noteID == shown.metadata.id, "undo does not switch notes")
        // 釘選 from the row, then the shown note's own row goes through the ⋯ path.
        await rig.area.rowAction(other.metadata.id, "pin")
        #expect(await rig.fileText(other.metadata.id).contains("pinned: true"))
        await rig.area.rowAction(shown.metadata.id, "archive")
        await m3Eventually("archived") { rig.service.counts.archive == 1 }
        #expect(rig.area.lastAction?.kind == "archive" && rig.area.lastAction?.ok == true)
        await rig.tearDown()
    }
}
