import AppKit
import CoddFiles
import CoddNotes
import Foundation
import Testing
@testable import CODD

/// M4 fix round 1: the confirmed review problems, each with its regression. Temp folders only;
/// no window is ever ordered in, nothing is posted, no process outside the temp folder runs.
@Suite("M4 fix round 1 · notebook editor and AI writes", .serialized)
@MainActor
struct M4FixNotebookTests {
    /// correctness-1: an AI append to the note on screen reaches the editor, and the next autosave
    /// writes on top of it (no false `磁碟上的筆記已變更` for CODD's own write).
    @Test func anAIAppendReachesTheOpenEditor() async throws {
        let rig = try await NotesRig("codd-m4fix-aiappend")
        defer { rig.removeFolder() }
        let editor = rig.editor
        rig.service.onAIWrite = { [weak editor] document in editor?.aiWrote(document) }
        let note = try await rig.service.create(NewNote(title: "AI 附加", body: "# AI 附加\n\n原本的內容\n", ai: .append))
        let id = note.metadata.id
        await rig.editor.show(id)
        let library = try #require(rig.service.library)
        _ = try await library.appendFromAI(id, markdown: "AI 寫的一行", heading: nil,
                                           actor: AIActor(client: "Claude Code", sessionTitle: "打卡頁 RWD 調整", via: "mcp"))
        await m3Eventually("the editor shows the append") { rig.editor.text.contains("AI 寫的一行") }
        #expect(rig.editor.diskConflict == nil && !rig.editor.isDirty)
        rig.caretToEnd()
        rig.type("我接著寫")
        await rig.editor.flush()
        #expect(rig.editor.diskConflict == nil, "no conflict banner for CODD's own write")
        let file = rig.fileText(note)
        #expect(file.contains("AI 寫的一行") && file.contains("我接著寫") && file.contains("codd:ai-append"))
        await rig.tearDown()
    }

    /// correctness-3: leaving a note while the disk-change banner holds its text back keeps the
    /// text in HISTORY (`未儲存的編輯`) instead of dropping it.
    @Test func leavingANoteWithTheBannerKeepsTheBufferInHistory() async throws {
        let rig = try await NotesRig("codd-m4fix-leave", autosave: .seconds(30))
        defer { rig.removeFolder() }
        let first = try await rig.create("第一則", body: "# 第一則\n\n原文\n")
        let second = try await rig.create("第二則", body: "# 第二則\n\n別的\n")
        await rig.editor.show(first.metadata.id)
        rig.caretToEnd()
        rig.type("還沒存的段落")
        let current = try String(contentsOf: first.fileURL, encoding: .utf8)
        try (current + "外面加的\n").write(to: first.fileURL, atomically: true, encoding: .utf8)
        await m3Eventually("the banner", timeout: .seconds(10)) { rig.editor.diskConflict != nil }
        await rig.editor.show(second.metadata.id)
        #expect(rig.editor.noteID == second.metadata.id)
        #expect(rig.editor.unsavedKept == 1 && rig.toasts.last == "未儲存的編輯已存到 HISTORY")
        let history = try await rig.service.history(of: first.metadata.id)
        let kept = try #require(history.first { $0.reason == "unsaved" })
        #expect(try await rig.service.snapshotText(kept, of: first.metadata.id).contains("還沒存的段落"))
        #expect(NotebookPresenter.historyLabel(kept, isOldest: false) == "未儲存的編輯")
        #expect(!(try String(contentsOf: first.fileURL, encoding: .utf8)).contains("還沒存的段落"), "the file itself is not overwritten")
        // A clean switch keeps nothing extra.
        await rig.editor.show(first.metadata.id)
        #expect(rig.editor.unsavedKept == 1)
        await rig.tearDown()
    }
}

@Suite("M4 fix round 1 · file editor saves and quit", .serialized)
@MainActor
struct M4FixFilesTests {
    /// correctness-2: two ⌘S in a row on one tab both succeed (the second starts from the first
    /// one's fingerprint) instead of refusing CODD's own write as a change on disk.
    @Test func backToBackSavesNeverRefuseTheirOwnWrite() async throws {
        let rig = try await FilesRig("codd-m4fix-save2")
        await rig.openRoot()
        let tab = try await rig.open("README.md")
        rig.type("x", into: tab)
        await m3Eventually("dirty") { tab.isDirty }
        let first = Task { await rig.service.save(tab) }
        let second = Task { await rig.service.save(tab) }
        let firstSaved = await first.value
        let secondSaved = await second.value
        #expect(firstSaved && secondSaved)
        #expect(rig.service.lastRefusal == nil && !tab.isDirty && tab.state?.pendingDisk == nil)
        #expect(try String(data: rig.bytes("README.md"), encoding: .utf8)?.hasPrefix("x") == true)
        rig.tearDown()
    }

    /// correctness-4: a quit that cannot ask keeps every unsaved buffer as a copy (the file
    /// itself untouched); ⌘Q asks first; texts for one and several files.
    @Test func aQuitThatCannotAskKeepsUnsavedCopies() async throws {
        let rig = try await FilesRig("codd-m4fix-quit")
        await rig.openRoot()
        let readme = try await rig.open("README.md")
        let before = try rig.bytes("README.md")
        rig.type("未存", into: readme)
        await m3Eventually("dirty") { readme.isDirty }
        #expect(rig.service.dirtyTabs.map(\.id) == [readme.id])
        let folder = URL(fileURLWithPath: rig.folder + "/data/files/unsaved", isDirectory: true)
        let copies = rig.service.preserveDirtyTabs(in: folder, tabs: rig.service.dirtyTabs)
        let copy = try #require(copies.first)
        #expect(copies.count == 1 && copy.lastPathComponent == "README.md")
        #expect(try Data(contentsOf: copy) == (try readme.state?.encodedBuffer()), "the buffer in the file's own encoding")
        #expect(try rig.bytes("README.md") == before, "never written over the file")
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // A second copy with the same name in the same second gets a number.
        let again = rig.service.preserveDirtyTabs(in: folder, tabs: [readme, readme])
        #expect(again.map(\.lastPathComponent) == ["README.md", "README 2.md"])

        #expect(AppDelegate.filesQuitStep(.user, unsaved: 1) == .ask)
        #expect(AppDelegate.filesQuitStep(.statusItem, unsaved: 2) == .ask)
        #expect(AppDelegate.filesQuitStep(.system, unsaved: 1) == .keepCopies)
        #expect(AppDelegate.filesQuitStep(.automation, unsaved: 1) == .keepCopies)
        #expect(AppDelegate.filesQuitStep(.confirmed, unsaved: 1) == .keepCopies)
        #expect(AppDelegate.filesQuitStep(.user, unsaved: 0) == .proceed)
        #expect(AppDelegate.filesQuitTexts(["punch.vue"]) == ("儲存「punch.vue」的變更？", "不儲存的話，這次的修改會遺失。", "儲存"))
        #expect(AppDelegate.filesQuitTexts(["a.js", "b.css", "c.vue"]) == ("3 個檔案有未儲存的變更", "不儲存的話，這些修改會遺失。", "儲存全部"))
        rig.tearDown()
    }

    /// security-data-4: git on a non-standard data root runs with no global or system config.
    @Test func gitOnATestRootIgnoresTheUsersGitConfig() {
        let isolated = AppDelegate.gitEnvironment(standardRoot: false)
        #expect(isolated == ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"])
        #expect(AppDelegate.gitEnvironment(standardRoot: true).isEmpty)
        let env = GitReader(environment: isolated, log: { _ in }).runEnvironment(base: ["GIT_CONFIG_GLOBAL": "/Users/x/.gitconfig", "PATH": "/usr/bin"])
        #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null" && env["GIT_CONFIG_NOSYSTEM"] == "1" && env["PATH"] == "/usr/bin")
    }
}

@Suite("M4 fix round 1 · cleanup", .serialized)
@MainActor
struct M4FixCleanupTests {
    /// correctness-5: 移到垃圾桶 on a ring row whose session was unarchived since the candidates
    /// were read keeps the ring and its log.
    @Test func aRingOfAnUnarchivedSessionIsNeverTrashed() async throws {
        let rig = try await CleanupRig("codd-m4fix-ring")
        defer { rig.tearDown() }
        try rig.graceOver()
        let id = try rig.session("快刪了", since: rig.days(-60), archivedAt: rig.days(-26), ringBytes: 1024)
        await rig.retention.run(reason: "test")
        let rows = rig.retention.candidates.files.map(\.id)
        #expect(rows.count == 1 && rows.first?.hasPrefix("ring:") == true)
        rig.store.unarchive([id])
        #expect(rig.store.archivedByID[id] == nil)
        #expect(await rig.retention.trashFiles(rows) == 0)
        #expect(!rig.trashed.contains("ring"))
        #expect(FileManager.default.fileExists(atPath: rig.root.sessionDirectory(id) + "/ring"))
        #expect(rig.logs.values.contains { $0.hasPrefix("retention ring kept session=") })
    }
}
