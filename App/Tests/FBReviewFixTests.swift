import AppKit
import CoddNotes
import CoddSettingsUI
import CoddUI
import Foundation
import Testing
@testable import CODD

// Review fixes of the fb round (user feedback 2026-10-19): each confirmed problem with its regression.
// Temp data roots only; windows are never ordered on screen; no claude, no cswap, no `~`.

/// The texts of every note linked to `session` (the drawer's recovery notes keep the links).
@MainActor
private func linkedBodies(_ service: NotesService, _ session: SessionID) async throws -> [String] {
    var out: [String] = []
    for summary in try await service.summaries(linkedToSession: session) {
        if let document = try? await service.document(summary.id) { out.append(document.body) }
    }
    return out
}

/// `chmod -R` on a temp folder (the read-only notebook of the refused-leave test).
private func setWritable(_ path: String, _ writable: Bool) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/chmod")
    process.arguments = ["-R", writable ? "u+w" : "a-w", path]
    try? process.run()
    process.waitUntilExit()
}

@Suite("FB review fixes · the drawer editor never drops text or hides its message", .serialized)
@MainActor
struct FBReviewDrawerTests {
    /// data-1: the note's file vanished outside CODD while the drawer held unsaved text; another
    /// session shows. The save fails and HISTORY cannot take the text (the note is gone), so it
    /// becomes a new note with the same links, and the message reaches the main window (the
    /// drawer's document is hidden by then).
    @Test func aFailedSaveOnLeavingKeepsTheTextAsANewNoteAndSaysSoOnScreen() async throws {
        let rig = try await DrawerRig("codd-fbfix-gone")
        defer { rig.removeWindow(); rig.notes.removeFolder() }
        var elsewhere: [String] = []
        rig.drawer.onToastElsewhere = { elsewhere.append($0) }
        rig.drawer.editor.autosaveDelay = .seconds(30)
        await rig.edit(rig.n1)
        // While the document shows, its own toasts stay in it.
        rig.drawer.editor.onToast?("抽屜裡的訊息")
        #expect(elsewhere.isEmpty && rig.drawer.editor.documentView.toast?.superview != nil)
        rig.drawer.editor.type(" 檔案消失前打的字")
        let file = try #require(rig.drawer.editor.document?.fileURL)
        try FileManager.default.removeItem(at: file)
        rig.drawer.show("s6")
        await m3Eventually("left the note") { rig.drawer.editor.noteID == nil && rig.drawer.editor.unsavedKept == 1 }
        await rig.settle()
        #expect(elsewhere.last == NoteEditorController.keptAsCopyText("打卡頁 RWD 跑版紀錄"), "\(elsewhere)")
        #expect(!rig.drawer.view.isEditing)
        let bodies = try await linkedBodies(rig.notes.service, "s9")
        #expect(bodies.contains { $0.contains("檔案消失前打的字") }, "the text lives on in a note linked to s9")
        await rig.tearDown()
    }

    /// data-1: nothing can take the text (the notebook folder is read-only): the leave is refused,
    /// the note and its text stay open in the drawer, and it saves once the folder works again.
    @Test func whenNothingCanTakeTheTextTheNoteStaysOpenInTheDrawer() async throws {
        let rig = try await DrawerRig("codd-fbfix-readonly")
        let notesDir = rig.notes.service.notesRoot.path
        defer {
            setWritable(notesDir, true)
            rig.removeWindow()
            rig.notes.removeFolder()
        }
        var elsewhere: [String] = []
        rig.drawer.onToastElsewhere = { elsewhere.append($0) }
        rig.drawer.editor.autosaveDelay = .seconds(30)
        await rig.edit(rig.n1)
        rig.drawer.editor.type(" 唯讀時打的字")
        setWritable(notesDir, false)
        rig.drawer.view.onBack?()
        await m3Eventually("the leave refused") { rig.drawer.editor.leavesRefused == 1 && rig.drawer.view.isEditing }
        await rig.settle()
        #expect(rig.drawer.editor.noteID == rig.n1 && rig.drawer.editor.text.contains("唯讀時打的字"))
        #expect(rig.drawer.editingID == rig.n1 && rig.drawer.editingBySession["s9"] == rig.n1)
        #expect(elsewhere.contains { $0.hasPrefix("無法保存未儲存的編輯") && $0.hasSuffix("內容仍留在編輯器") }, "\(elsewhere)")
        // The folder works again: the next leave writes the text.
        setWritable(notesDir, true)
        rig.drawer.view.onBack?()
        await m3Eventually("saved on leaving") { rig.drawer.editor.noteID == nil }
        await rig.settle()
        #expect(await rig.fileText(rig.n1).contains("唯讀時打的字"))
        await rig.tearDown()
    }
}

@Suite("FB review fixes · the Notebook editor keeps text a failed save left", .serialized)
@MainActor
struct FBReviewNotebookEditorTests {
    /// data-1 (the Notebook's half): a save that threw used to leave the text unsaved, and the
    /// next note's load replaced it without a snapshot.
    @Test func switchingNotesAfterAFailedSaveKeepsTheText() async throws {
        let rig = try await NotesRig("codd-fbfix-nb", autosave: .seconds(30))
        defer { rig.removeFolder() }
        let first = try await rig.create("第一則", body: "# 第一則\n\n原文\n")
        let second = try await rig.create("第二則", body: "# 第二則\n\n別的\n")
        await rig.editor.show(first.metadata.id)
        rig.caretToEnd()
        rig.type("存不進去的段落")
        try FileManager.default.removeItem(at: first.fileURL)
        await rig.editor.show(second.metadata.id)
        #expect(rig.editor.noteID == second.metadata.id)
        #expect(rig.editor.unsavedKept == 1 && rig.toasts.last == NoteEditorController.keptAsCopyText("第一則"), "\(rig.toasts)")
        #expect(rig.service.selectedID == second.metadata.id, "the copy is made on the side: the selection stays")
        await rig.service.refreshNow()
        var found = false
        for summary in rig.service.activeNotes where summary.id != second.metadata.id {
            if let document = try? await rig.service.document(summary.id), document.body.contains("存不進去的段落") { found = true }
        }
        #expect(found, "the text is in a new note")
        await rig.tearDown()
    }
}

@Suite("FB review fixes · toasts CODD shows on its own wait for an UNDO")
@MainActor
struct FBReviewPoliteToastTests {
    /// data-2: an AI's `notes_create` toast (and the drawer's off-screen messages) never take away
    /// a toast the user may still undo: they wait until it is gone.
    @Test func aToastWaitsWhileTheUserMayStillUndo() async throws {
        let host = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let undo = ToastView(text: "已封存", undo: {})
        host.addSubview(undo)
        var shown = 0
        let current: @MainActor () -> ToastView? = { host.subviews.compactMap { $0 as? ToastView }.last }
        let task = PoliteToast.whenFree(current: current, interval: .milliseconds(20)) { shown += 1 }
        #expect(task != nil && shown == 0)
        try await Task.sleep(for: .milliseconds(120))
        #expect(shown == 0, "the UNDO toast is still up")
        undo.removeFromSuperview()
        await task?.value
        #expect(shown == 1)
        // A countdown protects too; a plain toast, CODD's own and one off screen do not.
        let countdown = ToastView(text: "封存 session", undo: nil, countdown: 5)
        host.addSubview(countdown)
        #expect(PoliteToast.isProtected(countdown))
        countdown.removeFromSuperview()
        let plain = ToastView(text: "已複製", undo: nil)
        host.addSubview(plain)
        #expect(!PoliteToast.isProtected(plain))
        let own = ToastView(text: "Claude 建立了筆記：x", undo: {})
        host.addSubview(own)
        PoliteToast.mark(own)
        #expect(!PoliteToast.isProtected(own), "the next AI toast may replace an AI toast")
        #expect(!PoliteToast.isProtected(ToastView(text: "x", undo: {})), "not on screen")
        var now = 0
        #expect(PoliteToast.whenFree(current: current) { now += 1 } == nil && now == 1, "nothing to wait for: at once")
    }
}

@Suite("FB review fixes · Settings while cswap is still being located")
@MainActor
struct FBReviewSettingsCswapTests {
    /// ui-settings-guide-while-loading: before the first look for cswap answers, Settings › 帳號
    /// shows no install guide (STATUS shows its loading line then); after it, the facts decide.
    @Test func noInstallGuideBeforeCswapWasLookedFor() async throws {
        let fixture = try AccountStoreFixture("codd-fbfix-locate")
        var environment = SettingsCoordinator.Environment(preferences: .inMemory())
        environment.cswap = fixture.store
        let coordinator = SettingsCoordinator(environment: environment)
        let before = coordinator.makeInfo(now: fixture.clock).cswap
        #expect(before.locating && !before.pathOK)
        #expect(SettingsCswapGuide.make(before) == nil, "no INSTALL guide for a cswap that may well be there")
        await fixture.store.start()
        let after = coordinator.makeInfo(now: fixture.clock).cswap
        #expect(!after.locating && after.pathOK)
        #expect(SettingsCswapGuide.make(after) == nil)
        // A data root without cswap: the look answers `noCswap`, and the guide shows.
        let missing = try AccountStoreFixture("codd-fbfix-nocswap", debug: false)
        var missingEnvironment = SettingsCoordinator.Environment(preferences: .inMemory())
        missingEnvironment.cswap = missing.store
        let missingCoordinator = SettingsCoordinator(environment: missingEnvironment)
        await missing.store.start()
        let none = missingCoordinator.makeInfo(now: missing.clock).cswap
        #expect(!none.locating && !none.pathOK)
        #expect(SettingsCswapGuide.make(none)?.kind == .install)
    }
}
