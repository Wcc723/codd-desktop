import AppKit
import CoddCodeEditor
import CoddCore
import CoddFileEditorUI
import CoddFiles
import CoddHooks
import Foundation
import Testing
@testable import CODD

// M4 I3: the local file editor (D24–D27) over the C11 fixture repository — open facts, VS Code's
// preview tabs, disk changes with and without an AI touch (D25), 保留我的 and the save refusals,
// byte-identical saves, the never-a-write-without-⌘S rule, read-only git, the AI touches through
// the hook pipeline (D26), SHOW AI CHANGES (D27), the drawer's files rows, ⌘P and the 檔案 menu
// rules (D36). Temp folders only; git with an isolated config.

@Suite("M4 file editor · open, tabs, disk, save", .serialized)
@MainActor
struct M4FilesEditorTests {
    @Test func openShowsEncodingEndOfLineLanguageAndIndentation() async throws {
        let rig = try await FilesRig("codd-m4f-open")
        await rig.openRoot()
        let crlf = try await rig.open("src/legacy-crlf.js")
        #expect(crlf.state?.decoded.encoding == .utf8)
        #expect(crlf.state?.decoded.lineEnding == .crlf)
        #expect(crlf.language == .javascript)
        let bom = try await rig.open("src/bom.css")
        #expect(bom.state?.decoded.encoding == .utf8BOM)
        #expect(bom.language == .css)
        let big5 = try await rig.open("docs/big5.csv")
        #expect(big5.state?.decoded.encoding == .big5)
        let mixed = try await rig.open("src/mixed-eol.js")
        #expect(mixed.state?.decoded.mixedLineEndings == true)
        rig.service.select(mixed.id)
        let status = try #require(rig.service.statusModel())
        #expect(status.lineEnding == "CRLF*", "mixed endings show the majority with a star")
        let punch = try await rig.open("src/pages/punch.vue")
        #expect(punch.language == .vue)
        #expect(punch.state?.decoded.indentation == .spaces(2))
        rig.service.select(punch.id)
        #expect(rig.service.statusModel()?.language == "Vue")
        await m3Eventually("branch") { rig.service.statusModel()?.branch == "feat/punch-rwd" }
        rig.tearDown()
    }

    @Test func previewTabsAreReplacedAndPinnedLikeVSCode() async throws {
        let rig = try await FilesRig("codd-m4f-preview")
        let workspace = await rig.openRoot()
        let a = try await rig.open("index.html", preview: true)
        #expect(a.isPreview)
        let b = try await rig.open("vite.config.js", preview: true)
        #expect(workspace.tabs.map(\.id) == [b.id], "the next single click replaces the preview tab")
        rig.service.pin(b.id)
        let c = try await rig.open("package.json", preview: true)
        #expect(workspace.tabs.map(\.id) == [b.id, c.id], "a pinned tab stays")
        rig.type(" ", into: c)
        await m3Eventually("an edit pins") { !c.isPreview && c.isDirty }
        let d = try await rig.open("README.md", preview: true)
        #expect(workspace.tabs.count == 3 && workspace.tabs.last?.id == d.id, "a dirty tab is never replaced")
        // Opening an open file again only selects it; a double click pins it.
        _ = try await rig.open("README.md", preview: false)
        #expect(!d.isPreview)
        rig.tearDown()
    }

    @Test func aCleanTabReloadsInPlaceKeepingTheCaret() async throws {
        let rig = try await FilesRig("codd-m4f-clean")
        await rig.openRoot()
        let tab = try await rig.open("README.md")
        tab.editor?.goTo(line: 3, column: 2)
        let before = try rig.bytes("README.md")
        try rig.writeExternally("README.md", before + Data("新的一行\n".utf8))
        await m3Eventually("reloaded") { tab.state?.buffer.contains("新的一行") == true }
        #expect(!tab.isDirty)
        #expect(tab.state?.pendingDisk == nil, "no banner for a clean buffer")
        #expect(tab.editor?.text.contains("新的一行") == true)
        #expect(tab.caret.line == 3, "the caret stays")
        rig.tearDown()
    }

    @Test func aDirtyTabShowsTheBannerWithAndWithoutAnAITouch() async throws {
        let rig = try await FilesRig("codd-m4f-banner")
        await rig.openRoot()
        let plain = try await rig.open("README.md")
        rig.type("x", into: plain)
        await m3Eventually("dirty") { plain.isDirty }
        try rig.writeExternally("README.md", Data("# 外部改過\n".utf8))
        await m3Eventually("banner") { plain.state?.pendingDisk != nil }
        rig.service.select(plain.id)
        #expect(rig.service.bannerModel()?.title == "磁碟上的檔案已變更")
        #expect(rig.service.bannerModel()?.showsUnsaved == true)
        #expect(plain.state?.buffer.hasPrefix("x") == true, "the edits stay")

        // An AI session named the file within ±10 s: the banner says who (D25).
        let ai = try await rig.open("vite.config.js")
        rig.type("y", into: ai)
        await m3Eventually("dirty") { ai.isDirty }
        rig.touchLog.record([AITouch(path: rig.url("vite.config.js").path, session: "s9", tool: "Edit", at: Date())])
        try rig.writeExternally("vite.config.js", Data("export default {}\n".utf8))
        await m3Eventually("AI banner") { ai.state?.pendingDisk?.aiSession == "s9" }
        rig.service.select(ai.id)
        #expect(rig.service.bannerModel()?.title.hasPrefix("磁碟上的檔案已被 AI 變更（打卡頁 RWD 調整 · ") == true)
        #expect(ai.state?.aiBaseline?.session == "s9", "基準：AI 開始前 is kept")
        rig.tearDown()
    }

    @Test func aHookArrivingJustAfterTheChangeStillAttributesIt() async throws {
        let rig = try await FilesRig("codd-m4f-late")
        await rig.openRoot()
        let tab = try await rig.open("index.html")
        rig.type("z", into: tab)
        await m3Eventually("dirty") { tab.isDirty }
        try rig.writeExternally("index.html", Data("<!doctype html>\n".utf8))
        await m3Eventually("banner") { tab.state?.pendingDisk != nil }
        #expect(tab.state?.pendingDisk?.aiSession == nil)
        rig.service.handleTouches([AITouch(path: rig.url("index.html").path, session: "s9", tool: "Write", at: Date())])
        #expect(tab.state?.pendingDisk?.aiSession == "s9")
        rig.tearDown()
    }

    @Test func keepMineAllowsTheSaveTheBannerRefused() async throws {
        let rig = try await FilesRig("codd-m4f-keep")
        await rig.openRoot()
        let tab = try await rig.open("vite.config.js")
        rig.type("// mine\n", into: tab)
        await m3Eventually("dirty") { tab.isDirty }
        try rig.writeExternally("vite.config.js", Data("// theirs\n".utf8))
        await m3Eventually("banner") { tab.state?.pendingDisk != nil }
        #expect(await rig.service.save(tab) == false)
        #expect(rig.service.lastRefusal == FileEditorService.bannerFirstText)
        #expect(try rig.bytes("vite.config.js") == Data("// theirs\n".utf8), "the refused save wrote nothing")
        rig.service.keepMine(tab)
        #expect(tab.state?.pendingDisk == nil)
        #expect(await rig.service.save(tab))
        #expect(String(decoding: try rig.bytes("vite.config.js"), as: UTF8.self).hasPrefix("// mine"))
        rig.tearDown()
    }

    @Test func aSaveIsRefusedWhenTheDiskChangedSinceTheLoad() async throws {
        let rig = try await FilesRig("codd-m4f-changed")
        await rig.openRoot()
        let tab = try await rig.open("src/main.js")
        rig.type("// edit\n", into: tab)
        await m3Eventually("dirty") { tab.isDirty }
        // The watcher stops, so the save is the first to see the other program's write.
        tab.cancelTasks()
        try rig.writeExternally("src/main.js", Data("// other\n".utf8))
        #expect(await rig.service.save(tab) == false)
        #expect(rig.service.lastSave?.error == "changed-on-disk")
        #expect(try rig.bytes("src/main.js") == Data("// other\n".utf8))
        rig.tearDown()
    }

    @Test func savesAreByteIdenticalForCRLFBOMBig5AndMixedEndings() async throws {
        let rig = try await FilesRig("codd-m4f-bytes")
        await rig.openRoot()
        let cases: [(String, String, String)] = [
            ("src/legacy-crlf.js", "legacyPunch(type)", "legacyPunch(kind)"),
            ("src/bom.css", "#1d1d1d", "#222222"),
            ("docs/big5.csv", "1200", "1300"),
        ]
        for (path, old, new) in cases {
            let original = try rig.bytes(path)
            let tab = try await rig.open(path)
            let text = try #require(tab.state?.buffer)
            let lines = text.components(separatedBy: "\n")
            let index = try #require(lines.firstIndex { $0.contains(old) })
            tab.editor?.replaceLines(index..<(index + 1), with: [lines[index].replacingOccurrences(of: old, with: new)], actionName: "test")
            await m3Eventually("dirty \(path)") { tab.isDirty }
            #expect(await rig.service.save(tab), "save \(path)")
            let expected = try #require(Self.replacing(Data(old.utf8), with: Data(new.utf8), in: original))
            #expect(try rig.bytes(path) == expected, "\(path): only the edited bytes changed")
        }
        // Mixed endings: only the edited line changes; every other line keeps its terminator.
        let mixed = try rig.bytes("src/mixed-eol.js")
        let tab = try await rig.open("src/mixed-eol.js")
        tab.editor?.replaceLines(2..<3, with: ["export const b = 22"], actionName: "test")
        await m3Eventually("dirty mixed") { tab.isDirty }
        #expect(await rig.service.save(tab))
        let expected = try #require(Self.replacing(Data("export const b = 2\n".utf8), with: Data("export const b = 22\n".utf8), in: mixed))
        #expect(try rig.bytes("src/mixed-eol.js") == expected)
        rig.tearDown()
    }

    /// `data` with the first `old` replaced by `new` (nil when absent).
    static func replacing(_ old: Data, with new: Data, in data: Data) -> Data? {
        guard let range = data.range(of: old) else { return nil }
        var out = data
        out.replaceSubrange(range, with: new)
        return out
    }

    @Test func binaryLargeRefusedAndReadOnlyFiles() async throws {
        let rig = try await FilesRig("codd-m4f-kinds")
        await rig.openRoot()
        let binary = try await rig.open("assets/blob.bin")
        #expect(binary.failure == FileEditorService.binaryText)
        #expect(binary.editor == nil)
        let large = try await rig.open("big/large.txt")
        #expect(large.plainMode, "> 5 MiB: plain mode")
        #expect(large.isReadOnly)
        // > 50 MiB: refused before reading (a sparse file; nothing is read).
        let huge = rig.url("big/huge.log")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(51 * 1024 * 1024))
        try handle.close()
        #expect(await rig.service.open(huge, preview: false, root: rig.repo) == nil)
        #expect(rig.service.lastRefusal == FileEditorService.tooLargeText)
        // No write permission: read-only in the editor and ⌘S says so.
        let locked = rig.url("src/App.vue")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        let tab = try await rig.open("src/App.vue")
        #expect(tab.isReadOnly)
        #expect(await rig.service.save(tab) == false)
        #expect(rig.service.lastRefusal == FileEditorService.readOnlyText)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path)
        rig.tearDown()
    }

    @Test func nothingIsWrittenWithoutSave() async throws {
        let rig = try await FilesRig("codd-m4f-nowrite")
        await rig.openRoot()
        let path = rig.url("src/pages/punch.vue").path
        let before = rig.stamp(path)
        let tab = try await rig.open("src/pages/punch.vue", showAI: true)
        await m3Eventually("hunks") { !tab.hunks.isEmpty }
        rig.type("edit ", into: tab)
        await m3Eventually("dirty") { tab.isDirty }
        let runs = tab.diffRuns
        rig.service.hunkAction(tab, index: tab.hunks.count - 1, action: .revert)
        await rig.diff(tab, after: runs)
        rig.service.hunkAction(tab, index: 0, action: .accept)
        #expect(rig.service.requestClose(tab.id) == .needsConfirmation)
        await rig.service.close(tab.id, choice: .discard)
        #expect(rig.service.tab(tab.id) == nil)
        #expect(rig.stamp(path) == before, "edits, a revert, an accept and 不儲存 never touch the file")
        rig.tearDown()
    }

    @Test func gitReadsNeverRewriteTheIndex() async throws {
        let rig = try await FilesRig("codd-m4f-index")
        let index = rig.repo.path + "/.git/index"
        let before = rig.stamp(index)
        let workspace = await rig.openRoot()
        let tab = try await rig.open("src/pages/punch.vue", showAI: true)
        await m3Eventually("hunks") { !tab.hunks.isEmpty }
        rig.service.setFilter("punch")
        await m3Eventually("filter") { !workspace.filterResults.isEmpty }
        rig.service.refreshGit(workspace, ignored: true)
        await m3Eventually("second status") { workspace.gitRuns >= 2 }
        #expect(rig.stamp(index) == before, ".git/index unchanged by status, ignored, cat-file and ls-files")
        #expect(rig.logs.values.contains { $0.contains("exec git path=") && $0.contains("sub=status") })
        rig.tearDown()
    }
}

@Suite("M4 file editor · git, AI touches, SHOW AI CHANGES, drawer, menus", .serialized)
@MainActor
struct M4FilesAITests {
    @Test func theTreeShowsBranchBadgesDotsAndIgnoredRows() async throws {
        let rig = try await FilesRig("codd-m4f-tree")
        let workspace = await rig.openRoot()
        await m3Eventually("status") { workspace.status != nil && !workspace.ignored.isEmpty }
        rig.service.toggleFolder("src")
        await m3Eventually("src listed") { workspace.children["src"] != nil }
        let model = try #require(rig.service.treeModel())
        #expect(model.git?.branch == "feat/punch-rwd")
        #expect(model.git?.ahead == 2)
        #expect(model.git?.modified == 3)
        #expect(model.rows.first { $0.id == "node_modules" }?.ignored == true)
        #expect(model.rows.first { $0.id == ".env.local" }?.ignored == true)
        #expect(model.rows.first { $0.id == "src" }?.containsChanges == true)
        #expect(model.rows.first { $0.id == "tailwind.config.js" }?.modified == true)
        #expect(model.session?.title == "打卡頁 RWD 調整", "the root is s9's cwd")
        rig.tearDown()
    }

    @Test func aFolderOutsideGitSaysSo() async throws {
        let rig = try await FilesRig("codd-m4f-norepo", fixture: false)
        try Data("hello\n".utf8).write(to: rig.url("a.txt"))
        let workspace = rig.service.openRoot(rig.repo)
        await m3Eventually("git answered") { workspace.gitLoaded }
        #expect(!workspace.isRepo)
        #expect(rig.service.treeModel()?.git == nil, "the head shows // 不是 git 專案 and no badges")
        rig.tearDown()
    }

    @Test func postToolUseThroughThePipelineRecordsTouchesWithTheSessionColor() async throws {
        let rig = try await FilesRig("codd-m4f-pipeline")
        let data = URL(fileURLWithPath: rig.folder + "/pipeline-data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let claude = ClaudeDirectory(path: rig.folder + "/home/.claude")
        try FileManager.default.createDirectory(atPath: claude.path + "/sessions", withIntermediateDirectories: true)
        let pipeline = HookPipeline(dataRoot: data, claudeDirectory: claude, port: 0, portRange: HookPipeline.testPortRange) { _ in }
        var delivered: [AITouch] = []
        pipeline.onAITouch = { delivered += $0 }
        await pipeline.start()
        guard case .listening(let port) = pipeline.status, let token = pipeline.config?.token else {
            Issue.record("pipeline not listening")
            await pipeline.shutdown()
            rig.tearDown()
            return
        }
        let session = UUID()
        let payload: [String: Any] = ["hook_event_name": "PostToolUse", "session_id": "c-1", "cwd": rig.repo.path, "tool_name": "Edit",
                                      "tool_input": ["file_path": "src/pages/punch.vue", "old_string": "a", "new_string": "b"]]
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/hooks")))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-CODD-Token")
        request.setValue(session.uuidString.lowercased(), forHTTPHeaderField: "X-CODD-Session")
        _ = try await URLSession(configuration: .ephemeral).data(for: request)
        await m3Eventually("touch delivered") { !delivered.isEmpty }
        let touch = try #require(delivered.first)
        #expect(touch.path == rig.url("src/pages/punch.vue").path, "a relative path resolves against the payload cwd")
        #expect(touch.session == session.uuidString.lowercased())
        #expect(touch.tool == "Edit")
        #expect(pipeline.aiTouches.latest(for: touch.path) != nil, "recorded in files/ai-touches.json's log")
        await pipeline.shutdown()

        // The chips take the session's tag color (s9 is pink; no tag: a bone outline).
        let workspace = await rig.openRoot()
        rig.touchLog.record([AITouch(path: rig.url("tailwind.config.js").path, session: "s9", tool: "Edit", at: Date())])
        rig.service.handleTouches([AITouch(path: rig.url("tailwind.config.js").path, session: "s9", tool: "Edit", at: Date())])
        await m3Eventually("touches") { workspace.touches["tailwind.config.js"] != nil }
        let row = try #require(rig.service.treeModel()?.rows.first { $0.id == "tailwind.config.js" })
        #expect(row.ai?.color == TagColor.pink.color)
        #expect(rig.service.treeModel()?.aiCount == 1)
        #expect(HookPipeline.aiTouches(for: HookEvent(sessionID: session, payload: HookPayload(object: ["hook_event_name": .string("Stop")]),
                                                         receivedAt: Date())).isEmpty)
        rig.tearDown()
    }

    @Test func showAIChangesAgainstHEADRevertAcceptAndBaselines() async throws {
        let rig = try await FilesRig("codd-m4f-hunks")
        await rig.openRoot()
        let tab = try await rig.open("src/pages/punch.vue", showAI: true)
        await m3Eventually("hunks") { !tab.hunks.isEmpty }
        #expect(tab.hunks.count == 1)
        #expect(tab.hunks.first.map(LineDiff.unifiedHeader) == "@@ -40,2 +40,4 @@")
        #expect(tab.editor?.inlineDiff.count == 1)
        rig.service.select(tab.id)
        #expect(rig.service.toolbarModel()?.aiChangeCount == 1)
        // 還原此段: the buffer equals HEAD there (undoable, dirty, never written).
        let runs = tab.diffRuns
        rig.service.hunkAction(tab, index: 0, action: .revert)
        await rig.diff(tab, after: runs)
        #expect(tab.hunks.isEmpty)
        #expect(tab.isDirty)
        let head = try #require(String(data: rig.bytes("src/pages/punch.vue"), encoding: .utf8))
        #expect(tab.state?.buffer.contains("  position: fixed;\n  bottom: 0;") == true)
        #expect(!head.contains("  position: fixed;\n  bottom: 0;"), "the disk still has the AI's lines")
        // Undo brings the hunk back; 接受 hides it (a .mod bar stays) but keeps the count.
        tab.editor?.textViewForTesting.undoManager?.undo()
        await m3Eventually("hunk back") { tab.hunks.count == 1 }
        rig.service.hunkAction(tab, index: 0, action: .accept)
        #expect(tab.editor?.inlineDiff.isEmpty == true)
        #expect(tab.editor?.modifiedLineMarkers.isEmpty == false)
        #expect(tab.hunks.count == 1)
        // 基準：上次儲存: the buffer equals the loaded text.
        let saved = tab.diffRuns
        rig.service.setBaseline(tab, .saved)
        await rig.diff(tab, after: saved)
        #expect(tab.hunks.isEmpty)
        #expect(tab.accepted.isEmpty, "a baseline change shows accepted hunks again")
        rig.tearDown()
    }

    @Test func theDrawerListsTouchedFilesFirstThenGitChanges() async throws {
        let rig = try await FilesRig("codd-m4f-drawer")
        let now = Date()
        rig.touchLog.record([
            AITouch(path: rig.url("src/components/PunchButton.vue").path, session: "s9", tool: "Edit", at: now.addingTimeInterval(-120)),
            AITouch(path: rig.url("src/pages/punch.vue").path, session: "s9", tool: "Edit", at: now.addingTimeInterval(-60)),
            AITouch(path: rig.url("README.md").path, session: "s1", tool: "Edit", at: now),
        ])
        let section = try #require(await rig.service.drawerSection(for: "s9"))
        let names = section.files.map(\.name)
        #expect(Array(names.prefix(2)) == ["punch.vue", "PunchButton.vue"], "this session's touches, newest first")
        #expect(section.files[0].aiChip?.hasPrefix("AI ") == true)
        #expect(section.files[0].status == "M")
        #expect(section.files[0].directory == "src/pages/")
        let tailwind = try #require(section.files.first { $0.name == "tailwind.config.js" })
        #expect(tailwind.aiChip == nil, "a git-only change has no chip")
        #expect(tailwind.directory == "./")
        #expect(!names.contains("README.md"), "another session's touch is not this drawer's")
        #expect(section.count == section.files.count && section.files.count <= FileEditorService.drawerFileLimit)
        rig.tearDown()
    }

    @Test func commandPFiltersAndReturnOpens() async throws {
        let rig = try await FilesRig("codd-m4f-filter")
        let workspace = await rig.openRoot()
        rig.service.setFilter("punchvue")
        await m3Eventually("results") { !workspace.filterResults.isEmpty }
        #expect(workspace.filterResults.first == "src/pages/punch.vue")
        #expect(!workspace.filterResults.contains("node_modules/x/index.js"), "ignored files are not offered")
        #expect(rig.service.filterCommand(#selector(NSResponder.insertNewline(_:))))
        await m3Eventually("opened") { workspace.selectedTab?.title == "punch.vue" }
        #expect(workspace.filter.isEmpty)
        rig.tearDown()
    }

    @Test func fileMenuItemsValidateByModeAndNeverWhileComposing() {
        var rules = MenuAreaRules(area: .notes, notesMode: .files, fileTabShown: true, fileTabHasEditor: true)
        #expect(rules.isEnabled(#selector(AppDelegate.saveFile(_:))) == true)
        #expect(rules.isEnabled(#selector(AppDelegate.closeFileTab(_:))) == true)
        #expect(rules.isEnabled(#selector(AppDelegate.filterFiles(_:))) == true)
        #expect(rules.isEnabled(#selector(AppDelegate.findInFile(_:))) == true)
        #expect(rules.isEnabled(#selector(AppDelegate.searchNotes(_:))) == false, "⌘F: one owner at a time")
        #expect(rules.closeTabOwnsCommandW, "⌘W: 關閉分頁, the window's item steps aside")
        rules.fileComposing = true
        for action in [#selector(AppDelegate.saveFile(_:)), #selector(AppDelegate.closeFileTab(_:)), #selector(AppDelegate.filterFiles(_:)),
                       #selector(AppDelegate.findInFile(_:))] {
            #expect(rules.isEnabled(action) == false, "nothing while 注音 composes")
        }
        let sessions = MenuAreaRules(area: .sessions, fileTabShown: true, fileTabHasEditor: true)
        for action in [#selector(AppDelegate.saveFile(_:)), #selector(AppDelegate.closeFileTab(_:)), #selector(AppDelegate.filterFiles(_:)),
                       #selector(AppDelegate.findInFile(_:))] {
            #expect(sessions.isEnabled(action) == false, "the sessions area keeps ⌘S ⌘W ⌘P ⌘F")
        }
        #expect(!sessions.closeTabOwnsCommandW)
        let notebook = MenuAreaRules(area: .notes, notesReady: true, notesMode: .notebook, fileTabShown: true)
        #expect(notebook.isEnabled(#selector(AppDelegate.findInFile(_:))) == false)
        #expect(notebook.isEnabled(#selector(AppDelegate.searchNotes(_:))) == true)
        #expect(!notebook.closeTabOwnsCommandW)
        let empty = MenuAreaRules(area: .notes, notesMode: .files)
        #expect(empty.isEnabled(#selector(AppDelegate.closeFileTab(_:))) == false, "no tab: ⌘W closes the window")
        #expect(!empty.closeTabOwnsCommandW)
    }

    @Test func theFileMenuHasItsFourItems() {
        let menu = MainMenuBuilder.build(commands: StubCommands())
        let file = menu.items.first { $0.title == "檔案" }?.submenu
        let items = (file?.items ?? []).filter { !$0.isSeparatorItem }
        #expect(items.map(\.title) == ["儲存", "關閉分頁", "篩選檔案", "尋找"])
        #expect(items.map(\.keyEquivalent) == ["s", "w", "p", "f"])
    }
}
