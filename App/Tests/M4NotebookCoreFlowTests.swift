import AppKit
import CoddNotebookUI
import CoddNotes
import CoddTextKit
import Foundation
import Testing
@testable import CODD

/// A notebook on a temp data root: the service opened, the editor in a window that is never
/// ordered on screen (first responder, as typing needs), every toast recorded. Notes are made up.
@MainActor
final class NotesRig {
    static let taipei = TimeZone(identifier: "Asia/Taipei")!

    let root: String
    let preferences = PreferencesService.inMemory()
    let service: NotesService
    let editor: NoteEditorController
    let window: NSWindow
    private(set) var toasts: [String] = []
    let trashLog = LockedLines()

    var notesDir: String { root + "/data/notes" }

    init(_ prefix: String, autosave: Duration = .milliseconds(300)) async throws {
        root = try m3TempFolder(prefix)
        let trashLog = self.trashLog
        service = NotesService(notesRoot: URL(fileURLWithPath: root + "/data/notes", isDirectory: true),
                               cacheFolder: URL(fileURLWithPath: root + "/data/cache", isDirectory: true), preferences: preferences,
                               trash: AppTrash(target: .folder(root + "/trash"), log: { trashLog.append($0) }),
                               timeZone: Self.taipei, log: { _ in })
        service.searchDebounce = .milliseconds(150)
        editor = NoteEditorController(service: service, preferences: preferences)
        editor.autosaveDelay = autosave
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable], backing: .buffered,
                          defer: false)
        window.isReleasedWhenClosed = false
        editor.documentView.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = editor.documentView
        editor.onToast = { [weak self] text in self?.toasts.append(text) }
        let editor = self.editor
        service.onExternalChange = { [weak editor] id in Task { await editor?.externalChange(id) } }
        service.flushEditor = { [weak editor] id in await editor?.flushForAI(id) }
        await service.open()
        window.layoutIfNeeded()
        window.makeFirstResponder(editor.editor.textViewForTesting)
    }

    /// Closes the notebook, then removes the temp folder (each test's last line).
    func tearDown() async {
        await service.close()
        removeFolder()
    }

    /// The window and the temp folder (also the `defer` of a test that stopped early).
    func removeFolder() {
        window.contentView = nil
        window.close()
        try? FileManager.default.removeItem(atPath: root)
    }

    var textView: NSTextView { editor.editor.textViewForTesting }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func caretToEnd() {
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }

    func markdownFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: notesDir)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    }

    func fileText(_ document: NoteDocument) -> String {
        (try? String(contentsOf: document.fileURL, encoding: .utf8)) ?? ""
    }

    @discardableResult
    func create(_ title: String, body: String? = nil, tags: [String] = [], sessions: [String] = []) async throws -> NoteDocument {
        try await service.create(NewNote(title: title, body: body, tags: tags, links: NoteLinks(sessions: sessions)))
    }
}

@Suite("M4 notebook core · service and editor", .serialized)
@MainActor
struct M4NotebookCoreFlowTests {
    @Test func opensCountsAndLinkedSessions() async throws {
        let rig = try await NotesRig("codd-m4-open")
        defer { rig.removeFolder() }
        #expect(rig.service.availability == .ready)
        #expect(rig.service.openReport?.rebuilt == true && rig.service.openReport?.reason == "missing")
        try await rig.create("打卡頁 RWD 跑版紀錄", tags: ["rwd"], sessions: ["7C1E9A04-5B3D-4F0E-9A52-3D6C1B2E8F10"])
        try await rig.create("第二則")
        try await rig.create("第三則", sessions: ["7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"])
        await rig.service.refreshNow()
        #expect(rig.service.counts.inbox == 3)
        #expect(rig.service.rows.count == 3)
        #expect(rig.service.linkedSessionCounts == ["7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10": 2])
        // Ids follow D3, every file is a dated name.
        #expect(rig.markdownFiles().allSatisfy { $0.range(of: #"^\d{4}-\d{2}-\d{2}-.+\.md$"#, options: .regularExpression) != nil })
        let dump = NotesDump.object(service: rig.service, editor: rig.editor, mode: .notebook)
        #expect((dump["counts"] as? [String: Any])?["inbox"] as? Int == 3)
        #expect((dump["list"] as? [String: Any])?["ids"] as? [String] == rig.service.rows.map(\.id.rawValue))
        await rig.tearDown()
    }

    @Test func aFailedOpenLeavesTheServiceUnavailable() async throws {
        let root = try m3TempFolder("codd-m4-unavail")
        defer { try? FileManager.default.removeItem(atPath: root) }
        // A file where the notes folder should be: the folder is unusable, nothing else breaks.
        FileManager.default.createFile(atPath: root + "/notes", contents: Data("x".utf8))
        let service = NotesService(notesRoot: URL(fileURLWithPath: root + "/notes", isDirectory: true),
                                   cacheFolder: URL(fileURLWithPath: root + "/cache", isDirectory: true), preferences: .inMemory(),
                                   trash: AppTrash(target: .folder(root + "/trash")), log: { _ in })
        await service.open()
        #expect(service.availability.reason != nil)
        let editor = NoteEditorController(service: service, preferences: .inMemory())
        editor.showUnavailable(service.availability.reason ?? "")
        #expect(editor.placeholder?.hasPrefix("// 筆記資料夾無法使用：") == true)
    }

    @Test func quickNoteWritesNothingUntilTypedThenTheD3File() async throws {
        let rig = try await NotesRig("codd-m4-quick")
        defer { rig.removeFolder() }
        let session = "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"
        let draft = NoteDraft.quick(now: rig.service.clock(), timeZone: NotesRig.taipei,
                                    links: NoteLinks(sessions: [session], projects: ["~/Project/orb-toolkit-frontend"]))
        await rig.editor.startDraft(draft)
        #expect(rig.editor.noteID == nil && rig.editor.draft == draft)
        #expect(rig.service.quickNote == NotesService.QuickNote(id: nil, kind: .scratch))
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.markdownFiles().isEmpty, "an untouched quick note leaves nothing behind")
        // Leaving it untouched and starting another draft still writes nothing.
        await rig.editor.flush()
        #expect(rig.markdownFiles().isEmpty)
        rig.caretToEnd()
        rig.type("先記下來")
        await m3Eventually("the note is created") { rig.editor.noteID != nil }
        let files = rig.markdownFiles()
        #expect(files.count == 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = NotesRig.taipei
        let p = calendar.dateComponents([.year, .month, .day], from: rig.service.clock())
        let expected = String(format: "%04d-%02d-%02d-隨手記-%d-%d.md", p.year!, p.month!, p.day!, p.month!, p.day!)
        #expect(files.first == expected)
        let document = try #require(rig.editor.document)
        #expect(document.metadata.kind == .scratch)
        #expect(document.metadata.links.sessions == [session])
        #expect(document.metadata.scope == .project, "created linked: project scope (D20)")
        #expect(rig.fileText(document).contains("先記下來"))
        #expect(rig.service.quickNote?.id == document.metadata.id)
        await rig.tearDown()
    }

    @Test func autosaveWaitsForTheLastChange() async throws {
        let rig = try await NotesRig("codd-m4-autosave", autosave: .milliseconds(400))
        defer { rig.removeFolder() }
        let note = try await rig.create("自動儲存")
        await rig.editor.show(note.metadata.id)
        rig.caretToEnd()
        rig.type("a")
        try await Task.sleep(for: .milliseconds(200))
        rig.type("b")
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.editor.saveCount == 0, "still inside the debounce window of the last change")
        #expect(rig.editor.saveState == .unsaved)
        await m3Eventually("one save after the last change") { rig.editor.saveCount == 1 }
        try await Task.sleep(for: .milliseconds(500))
        #expect(rig.editor.saveCount == 1)
        #expect(rig.fileText(note).hasSuffix("ab") || rig.fileText(note).contains("ab"))
        #expect(!rig.editor.isDirty)
        if case .saved = rig.editor.saveState {} else { Issue.record("saved state expected, got \(rig.editor.saveState)") }
        await rig.tearDown()
    }

    @Test func nothingIsSavedWhileAnInputMethodComposes() async throws {
        let rig = try await NotesRig("codd-m4-ime", autosave: .milliseconds(200))
        defer { rig.removeFolder() }
        let note = try await rig.create("注音")
        await rig.editor.show(note.metadata.id)
        rig.caretToEnd()
        rig.type("x")
        rig.textView.setMarkedText("ㄓ", selectedRange: NSRange(location: 1, length: 0),
                                   replacementRange: NSRange(location: NSNotFound, length: 0))
        let before = rig.fileText(note)
        try await Task.sleep(for: .milliseconds(700))
        #expect(rig.textView.hasMarkedText())
        #expect(rig.editor.saveCount == 0, "the autosave waits while marked text exists")
        #expect(rig.fileText(note) == before)
        await rig.editor.flush()
        #expect(rig.editor.saveCount == 0, "a flush never writes during a composition either")
        rig.textView.insertText("中", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!rig.textView.hasMarkedText())
        await m3Eventually("saved once the composition committed") { rig.editor.saveCount == 1 }
        #expect(rig.fileText(note).contains("x中"))
        #expect(!rig.fileText(note).contains("ㄓ"))
        await rig.tearDown()
    }

    @Test func searchFindsCJKTermsAndTagsAfterTheDebounce() async throws {
        let rig = try await NotesRig("codd-m4-search")
        defer { rig.removeFolder() }
        let n1 = try await rig.create("打卡頁 RWD 跑版紀錄", body: "# 打卡頁 RWD 跑版紀錄\n\niPhone SE 下打卡按鈕被蓋住。\n", tags: ["rwd", "punch"])
        let n2 = try await rig.create("注音輸入法筆記", body: "# 注音輸入法筆記\n\n這裡也提到打卡兩個字。\n")
        try await rig.create("無關", body: "# 無關\n\n別的內容。\n")
        let runs = rig.service.searchRuns
        rig.service.setSearchText("打")
        rig.service.setSearchText("打卡 ")
        rig.service.setSearchText("打卡")
        await m3Eventually("打卡 searched") { rig.service.search?.query == "打卡" }
        #expect(rig.service.searchRuns == runs + 1, "three keystrokes inside 150 ms run one search")
        #expect(Set(rig.service.search?.hits.map(\.summary.id) ?? []) == [n1.metadata.id, n2.metadata.id])
        #expect(rig.service.search?.hits.allSatisfy { !$0.highlights.isEmpty } == true, "both bodies show the term highlighted")
        rig.service.setSearchText("打卡頁")
        await m3Eventually("打卡頁 searched") { rig.service.search?.query == "打卡頁" }
        #expect(rig.service.search?.hits.map(\.summary.id) == [n1.metadata.id])
        rig.service.setSearchText("#rwd")
        await m3Eventually("#rwd searched") { rig.service.search?.query == "#rwd" }
        #expect(rig.service.search?.hits.map(\.summary.id) == [n1.metadata.id])
        rig.service.setSearchText("")
        #expect(rig.service.search == nil)
        await rig.tearDown()
    }

    @Test func pastedImagesLandInAssetsDownscaledWithTheToast() async throws {
        let rig = try await NotesRig("codd-m4-paste")
        defer { rig.removeFolder() }
        let note = try await rig.create("截圖")
        await rig.editor.show(note.metadata.id)
        rig.caretToEnd()
        rig.type("\n")
        let png = try Self.png(width: 4000, height: 3000)
        let ref = try #require(await rig.editor.paste(MarkdownPastedImage(data: png, typeIdentifier: "public.png")))
        #expect(ref.resized && max(ref.pixelSize.width, ref.pixelSize.height) == 2576)
        #expect(ref.relativePath.hasPrefix("assets/\(note.metadata.id.rawValue)/") && ref.relativePath.hasSuffix(".png"))
        #expect(FileManager.default.fileExists(atPath: rig.notesDir + "/" + ref.relativePath))
        #expect(rig.toasts.last == "已貼上圖片 → \(ref.relativePath) · 已縮小到 2576px")
        #expect(rig.editor.text.contains("](\(ref.markdownPath))"))
        #expect(rig.editor.text.contains("![截圖 "))
        #expect(rig.service.lastPaste?.resized == true && rig.service.lastPaste?.asset == ref.relativePath)
        await rig.editor.flush()
        #expect(rig.fileText(note).contains(ref.markdownPath))
        await rig.tearDown()
    }

    @Test func aPasteIntoADraftCreatesTheNoteFirst() async throws {
        let rig = try await NotesRig("codd-m4-paste-draft")
        defer { rig.removeFolder() }
        await rig.editor.startDraft(.note())
        let ref = try #require(await rig.editor.paste(MarkdownPastedImage(data: try Self.png(width: 64, height: 48), typeIdentifier: "public.png")))
        let id = try #require(rig.editor.noteID)
        #expect(ref.relativePath.hasPrefix("assets/\(id.rawValue)/") && !ref.resized)
        #expect(rig.markdownFiles().count == 1)
        #expect(rig.toasts.last == "已貼上圖片 → \(ref.relativePath)")
        await rig.tearDown()
    }

    @Test func externalEditsReloadACleanEditorAndBannerADirtyOne() async throws {
        let rig = try await NotesRig("codd-m4-external", autosave: .seconds(30))
        defer { rig.removeFolder() }
        let note = try await rig.create("外部修改", body: "# 外部修改\n\n第一行\n")
        await rig.editor.show(note.metadata.id)
        try await Task.sleep(for: .milliseconds(300))
        // Clean: reloaded in place.
        let handle = try FileHandle(forWritingTo: note.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("外面加的一行\n".utf8))
        try handle.close()
        await m3Eventually("the clean editor reloads", timeout: .seconds(10)) { rig.editor.text.contains("外面加的一行") }
        #expect(rig.editor.externalReloads == 1 && rig.editor.diskConflict == nil)
        #expect(!rig.editor.isDirty)
        // Dirty: the banner.
        rig.caretToEnd()
        rig.type("我的修改")
        #expect(rig.editor.isDirty)
        let current = try String(contentsOf: note.fileURL, encoding: .utf8)
        try (current + "又一行\n").write(to: note.fileURL, atomically: true, encoding: .utf8)
        await m3Eventually("the dirty editor shows the banner", timeout: .seconds(10)) { rig.editor.diskConflict != nil }
        #expect(rig.editor.documentView.showsBanner)
        #expect(rig.editor.documentView.banner.model.title == "磁碟上的筆記已變更")
        #expect(rig.editor.text.contains("我的修改") && !rig.editor.text.contains("又一行"), "unsaved text is never replaced")
        // 保留我的: the disk version goes into HISTORY, the buffer is written.
        await rig.editor.keepMine()
        #expect(rig.editor.diskConflict == nil && !rig.editor.documentView.showsBanner)
        let written = try String(contentsOf: note.fileURL, encoding: .utf8)
        #expect(written.contains("我的修改") && !written.contains("又一行"))
        let history = try await rig.service.library?.history(of: note.metadata.id) ?? []
        #expect(history.contains { $0.reason == "external" })
        await rig.tearDown()
    }

    @Test func aStaleBasedOnHashBecomesTheConflictBanner() async throws {
        let rig = try await NotesRig("codd-m4-conflict", autosave: .seconds(30))
        defer { rig.removeFolder() }
        let note = try await rig.create("衝突", body: "# 衝突\n\n原文\n")
        await rig.editor.show(note.metadata.id)
        // Another writer the watcher has not reported yet, then the user's save.
        rig.service.onExternalChange = nil
        try "---\nid: \(note.metadata.id.rawValue)\ntitle: 衝突\n---\n# 衝突\n\n別人的\n".write(to: note.fileURL, atomically: true, encoding: .utf8)
        rig.caretToEnd()
        rig.type("我的")
        await rig.editor.flush()
        #expect(rig.editor.diskConflict != nil, "basedOn differs: nothing written, the banner instead")
        #expect(try String(contentsOf: note.fileURL, encoding: .utf8).contains("別人的"))
        rig.editor.reloadFromDisk()
        #expect(rig.editor.text.contains("別人的") && rig.editor.diskConflict == nil)
        await rig.tearDown()
    }

    @Test func notesAreaShowsTheMockNotebook() async throws {
        let root = try m3TempFolder("codd-m4-mockarea")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let folder = URL(fileURLWithPath: root, isDirectory: true)
        await MockNotes.seed(into: folder)
        let preferences = PreferencesService.inMemory()
        let now = MockData.referenceDate
        let service = NotesService(notesRoot: folder.appendingPathComponent("notes", isDirectory: true),
                                   cacheFolder: folder.appendingPathComponent("cache", isDirectory: true), preferences: preferences,
                                   trash: AppTrash(target: .folder(root + "/trash")), clock: { now },
                                   timeZone: MockNotes.timeZone, log: { _ in })
        await service.open()
        let editor = NoteEditorController(service: service, preferences: preferences)
        let store = MockSessionStore()
        let shell = ShellState()
        let area = NotesAreaViewController(service: service, editor: editor, store: store, shell: shell, preferences: preferences, recentFiles: nil)
        area.view.frame = NSRect(x: 0, y: 0, width: 1368, height: 900)
        area.setActive(true)
        area.view.layoutSubtreeIfNeeded()
        await m3Eventually("n1 is shown") { editor.noteID?.rawValue == MockNotes.n1ID }
        await m3Eventually("its facts are loaded") { area.chrome.model.info != nil }
        // The SPEC §5 notes plus the Split artboard's `打卡頁 QA 清單` (I2b).
        #expect(service.counts.inbox == 8 && service.counts.pinned == 1 && service.counts.prompts == 2)
        #expect(area.lists.model.counts[.inbox] == 8)
        #expect(area.noteList.model.sections.first?.day == "Today · 10/15")
        #expect(area.noteList.model.rows.first?.title == "打卡頁 RWD 跑版紀錄")
        #expect(area.noteList.model.rows.first?.link == .session(title: "打卡頁 RWD 調整", state: .busy))
        let chrome = area.chrome.model
        #expect(chrome.crumb == "Inbox" && chrome.title == "打卡頁 RWD 跑版紀錄" && chrome.noteID == MockNotes.n1ID)
        #expect(chrome.scope?.title == "orb-toolkit-frontend" && chrome.ai == .read)
        #expect(chrome.info?.links.count == 2)
        #expect(chrome.info?.aiActivity.first == NoteAIActivityRow(kind: .read, who: "打卡頁 RWD 調整", time: "10:12"))
        #expect(chrome.info?.history.map(\.time) == ["10:05", "09:41", "昨天 18:20"])
        #expect(chrome.info?.history.map(\.label) == ["你 · 目前", "你", "建立"])
        #expect(chrome.info?.assetsSummary.hasPrefix("2 張") == true)
        #expect(chrome.footer?.target?.title == "打卡頁 RWD 調整", "D14: the first live linked session")
        // I1b: COPY REF is live; SEND TO SESSION opens with its three actions disabled until I2b.
        #expect(chrome.copyRefDisabledReason == nil && chrome.sendDisabledReason == nil)
        #expect(chrome.sendActionsDisabledReason == nil, "I2b: the three actions are live")
        #expect(editor.chipsRow.model.tags == ["rwd", "punch"] && editor.chipsRow.model.updated == "updated 10:05")
        #expect(editor.text.contains("```codd-annotations"))
        // The whole area renders offscreen (the snapshot smoke).
        let rep = try #require(area.view.bitmapImageRepForCachingDisplay(in: area.view.bounds))
        area.view.cacheDisplay(in: area.view.bounds, to: rep)
        #expect(rep.pixelsWide >= 1368)
        area.setActive(false)
        await service.close()
    }

    /// Numbers through the app's binding (debug build, printed): opening a 1 MiB note and a
    /// keystroke in its middle with the relayout and display it causes.
    @Test func aLargeNoteOpensAndTypesWithinBudget() async throws {
        let rig = try await NotesRig("codd-m4-perf", autosave: .seconds(30))
        defer { rig.removeFolder() }
        var body = "# 一兆位元組的筆記\n\n"
        var section = 0
        while body.utf8.count < 1_048_576 {
            section += 1
            body += "## 第 \(section) 節\n打卡頁 RWD 跑版紀錄：iPhone SE 下打卡按鈕被底部導覽列蓋住，橫向時表格溢出。**粗體** 與 `code`。\n"
            body += "- 項目一 \(section)\n- [ ] 待辦 \(section)\n\n"
        }
        let note = try await rig.create("一兆位元組的筆記", body: body)
        rig.window.setContentSize(NSSize(width: 900, height: 700))
        let open = ContinuousClock.now
        await rig.editor.show(note.metadata.id)
        rig.editor.editor.layoutSubtreeIfNeeded()
        rig.editor.documentView.displayIfNeeded()
        let openMs = NotesService.milliseconds(ContinuousClock.now - open)
        let view = rig.textView
        let middle = (view.string as NSString).length / 2
        view.setSelectedRange(NSRange(location: middle, length: 0))
        view.scrollRangeToVisible(NSRange(location: middle, length: 0))
        rig.editor.documentView.displayIfNeeded()
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            view.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
            rig.editor.documentView.layoutSubtreeIfNeeded()
            rig.editor.documentView.displayIfNeeded()
            samples.append(NotesService.milliseconds(ContinuousClock.now - start))
        }
        samples.sort()
        print(String(format: "PERF note open 1 MiB (%d bytes): %.1f ms; keystroke p50 %.2f ms p95 %.2f ms max %.2f ms",
                     body.utf8.count, openMs, samples[10], samples[18], samples[19]))
        #expect(openMs < 3000)
        #expect(samples[18] < 200)
        #expect(rig.editor.isDirty && rig.editor.saveCount == 0, "nothing saved before the autosave interval")
        await rig.tearDown()
    }

    static func png(width: Int, height: Int) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        return MockNotes.pngData(try #require(context.makeImage()))
    }
}
