import Foundation
import Testing
@testable import CoddNotes

@Suite struct StorageTests {
    @Test func openCreatesLayout() async throws {
        let root = TempRoot()
        let lib = makeLibrary(root)
        let report = try await lib.open()
        #expect(report.rebuilt && report.reason == "missing" && report.count == 0)
        #expect(root.exists(".codd/notebook.json"))
        #expect(root.read(".codd/notebook.json").hasPrefix("{\"v\":1,\"createdAt\":\"2026-10-15T10:05:44+08:00\"}"))
        let attrs = try FileManager.default.attributesOfItem(atPath: root.notes.appendingPathComponent(".codd").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(FileManager.default.fileExists(atPath: root.index.path))
        let values = try root.index.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let notesValues = try root.notes.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(notesValues.isExcludedFromBackup != true)
        await lib.close()
    }

    @Test func createWritesD3NameAndFrontmatter() async throws {
        let root = TempRoot()
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let doc = try await lib.create(NewNote(
            title: "打卡頁 RWD 跑版紀錄", body: "# 打卡頁 RWD 跑版紀錄\n\n## 問題\n內容\n", tags: ["rwd", "punch"],
            links: NoteLinks(sessions: ["7C1E9A04-5B3D-4F0E-9A52-3D6C1B2E8F10"], projects: [NSHomeDirectory() + "/Project/x"])))
        #expect(doc.relativePath == "2026-10-15-打卡頁-rwd-跑版紀錄.md")
        #expect(doc.metadata.id.rawValue.hasPrefix("rwd-punch-"))
        #expect(doc.metadata.ai == .read)
        #expect(doc.metadata.scope == .project)
        #expect(doc.metadata.links.sessions == ["7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10"])
        #expect(doc.metadata.links.projects == ["~/Project/x"])
        let text = root.read(doc.relativePath)
        #expect(text == """
            ---
            id: \(doc.metadata.id.rawValue)
            title: 打卡頁 RWD 跑版紀錄
            kind: note
            tags: [rwd, punch]
            sessions: [7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10]
            projects: [~/Project/x]
            ai: read
            scope: project
            pinned: false
            status: active
            created: 2026-10-15T10:05:44+08:00
            updated: 2026-10-15T10:05:44+08:00
            ---
            # 打卡頁 RWD 跑版紀錄

            ## 問題
            內容

            """)
        let mode = try FileManager.default.attributesOfItem(atPath: doc.fileURL.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // Nothing left in the temp folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.notes.appendingPathComponent(".codd/tmp").path).isEmpty)
        // A second note with the same title gets `-2`, a global scope without links.
        let second = try await lib.create(NewNote(title: "打卡頁 RWD 跑版紀錄"))
        #expect(second.relativePath == "2026-10-15-打卡頁-rwd-跑版紀錄-2.md")
        #expect(second.metadata.scope == .global)
        #expect(second.body == "# 打卡頁 RWD 跑版紀錄\n")
        await lib.close()
    }

    @Test func saveConflictAndTitleMirror() async throws {
        let root = TempRoot()
        let clock = ManualClock(iso("2026-10-15T10:05:44+08:00"))
        let lib = makeLibrary(root, clock: clock)
        _ = try await lib.open()
        let doc = try await lib.create(NewNote(title: "第一版", body: "# 第一版\n\n文字\n"))
        clock.advance(minutes: 1)
        guard case .saved(let saved) = try await lib.save(doc.metadata.id, body: "# 第二版\n\n新的文字\n", basedOn: doc.contentHash) else {
            Issue.record("expected saved")
            return
        }
        #expect(saved.metadata.title == "第二版")
        let text = root.read(doc.relativePath)
        #expect(text.contains("title: 第二版\n"))
        #expect(text.contains("updated: 2026-10-15T10:06:44+08:00\n"))
        #expect(text.contains("created: 2026-10-15T10:05:44+08:00\n"))
        // A stale `basedOn` is a conflict and writes nothing.
        let outcome = try await lib.save(doc.metadata.id, body: "# 不該寫入\n", basedOn: doc.contentHash)
        guard case .conflict(let disk) = outcome else {
            Issue.record("expected conflict")
            return
        }
        #expect(disk.body == "# 第二版\n\n新的文字\n")
        #expect(root.read(doc.relativePath) == text)
        // nil basedOn always saves.
        guard case .saved = try await lib.save(doc.metadata.id, body: "# 第二版\n\n第三\n", basedOn: nil) else {
            Issue.record("expected saved")
            return
        }
        await lib.close()
    }

    @Test func crlfAndNoFrontmatterAndUnparsable() async throws {
        let root = TempRoot()
        root.write("crlf.md", "---\r\nid: crlf-note\r\ntitle: CRLF\r\n---\r\n# CRLF\r\n\r\nline\r\n")
        root.write("plain.md", "# 丟進來的檔案\n\n沒有 frontmatter\n")
        root.write("broken.md", "---\nid: broken-1\nnested:\n  a: b\n---\n# 壞掉\n\nbody\n")
        let lib = makeLibrary(root)
        _ = try await lib.open()
        // CRLF body comes LF, goes back CRLF; untouched lines stay.
        let crlf = try await lib.document(.of("crlf-note"))
        #expect(crlf.body == "# CRLF\n\nline\n")
        #expect(crlf.lineEnding == .crlf)
        _ = try await lib.save(.of("crlf-note"), body: "# CRLF\n\nline\nmore\n", basedOn: crlf.contentHash)
        let crlfText = root.read("crlf.md")
        #expect(crlfText.hasPrefix("---\r\nid: crlf-note\r\ntitle: CRLF\r\n"))
        #expect(crlfText.hasSuffix("---\r\n# CRLF\r\n\r\nline\r\nmore\r\n"))
        #expect(!crlfText.replacingOccurrences(of: "\r\n", with: "").contains("\n"))

        // No frontmatter: a derived id, written at the first save.
        let plainID = NoteNaming.derivedID(relativePath: "plain.md")
        let plain = try await lib.document(plainID)
        #expect(plain.flags.contains(.noFrontmatter))
        #expect(plain.metadata.title == "丟進來的檔案")
        _ = try await lib.save(plainID, body: plain.body + "加一行\n", basedOn: plain.contentHash)
        let written = root.read("plain.md")
        #expect(written.hasPrefix("---\nid: \(plainID.rawValue)\ntitle: 丟進來的檔案\n"))
        #expect(written.hasSuffix("---\n# 丟進來的檔案\n\n沒有 frontmatter\n加一行\n"))
        #expect(try await lib.document(plainID).flags.isEmpty)

        // Unparsable: metadata edits refused, body saves keep the frontmatter text.
        let broken = try await lib.document(.of("broken-1"))
        #expect(broken.flags.contains(.unparsableFrontmatter))
        await #expect(throws: NotesError.unparsableFrontmatter(.of("broken-1"))) { try await lib.update(.of("broken-1"), .pinned(true)) }
        await #expect(throws: NotesError.unparsableFrontmatter(.of("broken-1"))) { try await lib.archive([.of("broken-1")], by: .user) }
        await #expect(throws: NotesError.unparsableFrontmatter(.of("broken-1"))) { try await lib.trash([.of("broken-1")]) }
        _ = try await lib.save(.of("broken-1"), body: "# 壞掉\n\nnew body\n", basedOn: nil)
        #expect(root.read("broken.md") == "---\nid: broken-1\nnested:\n  a: b\n---\n# 壞掉\n\nnew body\n")
        await lib.close()
    }

    @Test func metadataChanges() async throws {
        let root = TempRoot()
        root.write("2026-10-15-打卡頁-rwd-跑版紀錄.md", specNote1())
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let id = NoteID.of("rwd-punch-k7x2")
        let before = root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md")
        var doc = try await lib.update(id, .ai(.append))
        #expect(doc.metadata.ai == .append)
        let after = root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md")
        #expect(after == before.replacingOccurrences(of: "ai: read\n", with: "ai: append\n"))
        doc = try await lib.update(id, .addTag("#CSS"))
        #expect(doc.metadata.tags == ["rwd", "punch", "CSS"])
        doc = try await lib.update(id, .removeTag("punch"))
        #expect(doc.metadata.tags == ["rwd", "CSS"])
        doc = try await lib.update(id, .kind(.prompt))
        #expect(doc.metadata.kind == .prompt && doc.metadata.isPromptDraft)
        doc = try await lib.update(id, .markSent(at: iso("2026-10-15T10:02:00+08:00"), to: "7C1E9A04-5B3D-4F0E-9A52-3D6C1B2E8F10"))
        #expect(doc.metadata.sentAt == iso("2026-10-15T10:02:00+08:00") && !doc.metadata.isPromptDraft)
        #expect(doc.metadata.sentTo == "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10")
        doc = try await lib.update(id, .pinned(true))
        #expect(doc.metadata.pinned)
        #expect(root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md").contains("pinned: true\n"))
        doc = try await lib.update(id, .linkSession("ABC"))
        #expect(doc.metadata.links.sessions.last == "abc")
        doc = try await lib.update(id, .unlinkSession("abc"))
        #expect(!doc.metadata.links.sessions.contains("abc"))
        doc = try await lib.update(id, .scope(.project, primaryProject: "~/Github/Gear3D"))
        #expect(doc.metadata.links.projects.first == "~/Github/Gear3D")
        #expect(doc.metadata.primaryProject == "~/Github/Gear3D")
        doc = try await lib.update(id, .unlinkProject("~/Github/Gear3D"))
        #expect(doc.metadata.links.projects == ["~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend"])
        doc = try await lib.update(id, .scope(.global, primaryProject: nil))
        #expect(doc.metadata.scope == .global)
        // The body never changed.
        #expect(doc.body == Frontmatter.split(specNote1()).body)
        await lib.close()
    }

    @Test func archiveTrashRestorePurgeAndResolve() async throws {
        let root = TempRoot()
        let clock = ManualClock(iso("2026-10-15T10:05:44+08:00"))
        let trash = TrashRecorder(folder: root.trash)
        let lib = makeLibrary(root, clock: clock, trash: trash)
        root.write("2026-10-15-打卡頁-rwd-跑版紀錄.md", specNote1())
        try FileManager.default.createDirectory(at: root.notes.appendingPathComponent("assets/rwd-punch-k7x2"), withIntermediateDirectories: true)
        try makeImage(width: 75, height: 133).write(to: root.notes.appendingPathComponent("assets/rwd-punch-k7x2/9f3a1c.png"))
        _ = try await lib.open()
        let id = NoteID.of("rwd-punch-k7x2")

        try await lib.archive([id], by: .user)
        var text = root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md")
        #expect(text.contains("status: archived\n") && text.contains("archived: 2026-10-15T10:05:44+08:00\n") && text.contains("archivedBy: user\n"))
        if case .note(let s) = await lib.resolve("codd://note/rwd-punch-k7x2") {
            #expect(s.metadata.state == .archived(at: iso("2026-10-15T10:05:44+08:00"), by: .user))
        } else {
            Issue.record("expected a note")
        }
        #expect(try await lib.counts().archive == 1)
        try await lib.unarchive([id])
        text = root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md")
        #expect(text.contains("status: active\n") && !text.contains("archivedBy"))

        try await lib.trash([id])
        #expect(!root.exists("2026-10-15-打卡頁-rwd-跑版紀錄.md"))
        #expect(root.exists(".codd/trash/2026-10-15-打卡頁-rwd-跑版紀錄.md"))
        #expect(root.exists(".codd/trash/assets/rwd-punch-k7x2/9f3a1c.png"))
        #expect(!root.exists("assets/rwd-punch-k7x2"))
        #expect(root.read(".codd/trash/2026-10-15-打卡頁-rwd-跑版紀錄.md").contains("trashed: 2026-10-15T10:05:44+08:00\n"))
        guard case .trashed(_, let purgeAt) = await lib.resolve("rwd-punch-k7x2") else {
            Issue.record("expected trashed")
            return
        }
        #expect(purgeAt == iso("2026-11-14T10:05:44+08:00"))
        let counts = try await lib.counts()
        #expect(counts.trash == 1 && counts.inbox == 0)
        #expect(try await lib.history(of: id).contains { $0.reason == "trash" })
        await #expect(throws: NotesError.trashed(id, purgeAt: purgeAt)) {
            _ = try await lib.save(id, body: "x", basedOn: nil)
        }

        try await lib.restore([id])
        #expect(root.exists("2026-10-15-打卡頁-rwd-跑版紀錄.md"))
        #expect(root.exists("assets/rwd-punch-k7x2/9f3a1c.png"))
        #expect(!root.read("2026-10-15-打卡頁-rwd-跑版紀錄.md").contains("trashed:"))
        if case .note = await lib.resolve("[[note:rwd-punch-k7x2]]") {} else { Issue.record("expected restored") }

        // Trash again, 31 days later the retention purges it through the trash function.
        try await lib.trash([id])
        clock.advance(days: 31)
        let report = await lib.runRetention(liveSessions: [])
        #expect(report.purged == [id])
        let moved = trash.items.map { URL(fileURLWithPath: $0).lastPathComponent }
        #expect(moved.contains("2026-10-15-打卡頁-rwd-跑版紀錄.md"))
        #expect(moved.contains("rwd-punch-k7x2"))  // the assets folder and the history folder
        #expect(trash.items.contains { $0.hasSuffix(".codd/history/rwd-punch-k7x2") })
        #expect(trash.items.contains { $0.hasSuffix(".codd/trash/assets/rwd-punch-k7x2") })
        #expect(!root.exists(".codd/trash/2026-10-15-打卡頁-rwd-跑版紀錄.md"))
        guard case .purged(let t) = await lib.resolve("codd://note/rwd-punch-k7x2") else {
            Issue.record("expected purged")
            return
        }
        #expect(t.title == "打卡頁 RWD 跑版紀錄")
        #expect(root.read(".codd/tombstones.json").contains("\"id\":\"rwd-punch-k7x2\""))
        await #expect(throws: NotesError.purged(id)) { _ = try await lib.document(id) }
        if case .unknown("zz-top") = await lib.resolve("codd://note/zz-top") {} else { Issue.record("expected unknown") }
        if case .unknown = await lib.resolve("not a ref") {} else { Issue.record("expected unknown") }
        // A tombstoned id is never handed out again.
        #expect(await lib.idTaken(id))
        // Tombstones expire after tombstoneDays (90).
        clock.advance(days: 91)
        _ = await lib.runRetention(liveSessions: [])
        if case .unknown = await lib.resolve("rwd-punch-k7x2") {} else { Issue.record("tombstone should have expired") }
        await lib.close()
    }

    @Test func condenseSummaryShape() async throws {
        let root = TempRoot()
        root.write("a.md", "---\nid: src-a\n---\n# A\n")
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let summary = try await lib.create(NewNote(
            title: "摘要 · 10/15 清理（1 則）", body: "# 摘要 · 10/15 清理（1 則）\n\n濃縮自\n- codd://note/src-a\n",
            idPrefix: "cleanup-1015", condensedFrom: [.of("src-a")]))
        #expect(summary.metadata.id.rawValue.hasPrefix("cleanup-1015-") && summary.metadata.id.rawValue.count == 17)
        #expect(summary.metadata.condensedFrom == [.of("src-a")])
        #expect(root.read(summary.relativePath).contains("condensedFrom: [src-a]\n"))
        try await lib.archive([.of("src-a")], by: .condense)
        let src = try await lib.update(.of("src-a"), .condensedInto(summary.metadata.id))
        #expect(src.metadata.condensedInto == summary.metadata.id)
        #expect(src.metadata.state == .archived(at: iso("2026-10-15T10:05:44+08:00"), by: .condense))
        #expect(NoteNaming.makeID(prefix: "Bad Prefix!", taken: { _ in false }).rawValue.hasPrefix("note-"))
        await lib.close()
    }

    @Test func saveKeepsModeAndExtendedAttributes() async throws {
        let root = TempRoot()
        root.write("tagged.md", "---\nid: tagged-note\n---\n# 有標籤\n")
        let u = root.notes.appendingPathComponent("tagged.md")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: u.path)
        FileFacts.setXattr("com.example.codd-test", "kept", on: u)
        let lib = makeLibrary(root)
        _ = try await lib.open()
        _ = try await lib.save(.of("tagged-note"), body: "# 有標籤\n\n新內容\n", basedOn: nil)
        #expect(FileFacts.xattr("com.example.codd-test", of: u) == "kept")
        #expect((try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue == 0o644)
        await lib.close()
    }

    @Test func changesCoalesceNewestWins() async throws {
        let ch = ChangeChannel()
        ch.yield(.changed([.of("a-1"), .of("b-1")]))
        ch.yield(.activity(.of("a-1")))
        ch.yield(.external([.of("a-1")]))
        ch.yield(.activity(.of("a-1")))
        ch.yield(.indexRebuilt(count: 1))
        ch.yield(.indexRebuilt(count: 2))
        #expect(await ch.next() == .changed([.of("b-1")]))
        #expect(await ch.next() == .external([.of("a-1")]))
        #expect(await ch.next() == .activity(.of("a-1")))
        #expect(await ch.next() == .indexRebuilt(count: 2))
        ch.finish()
        #expect(await ch.next() == nil)
    }

    @Test func stateFilesFormat() async throws {
        let root = TempRoot()
        let lib = makeLibrary(root)
        root.write("n.md", "---\nid: n-1\n---\n# N\n")
        _ = try await lib.open()
        await lib.markOpened(.of("n-1"), at: iso("2026-10-15T10:00:00+08:00"))
        await lib.keep(.of("n-1"), until: iso("2026-11-14T10:00:00+08:00"))
        await lib.recordActivity(NoteActivityEvent(at: iso("2026-10-15T10:12:00+08:00"), note: .of("n-1"), action: "read",
                                                   client: "Claude Code", session: "7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10",
                                                   sessionTitle: "打卡頁 RWD 調整", via: "mcp"))
        await lib.close()
        #expect(root.read(".codd/state.json") == """
            {"v":1,"notes":{"n-1":{"lastOpenedAt":"2026-10-15T10:00:00+08:00","openCount":1,"lastUserActivityAt":"2026-10-15T10:00:00+08:00","keepUntil":"2026-11-14T10:00:00+08:00"}}}

            """)
        #expect(root.read(".codd/activity.jsonl") == """
            {"v":1,"at":"2026-10-15T10:12:00+08:00","note":"n-1","action":"read","client":"Claude Code","session":"7c1e9a04-5b3d-4f0e-9a52-3d6c1b2e8f10","sessionTitle":"打卡頁 RWD 調整","via":"mcp"}

            """)
        // Reopened: state and activity are back.
        let again = makeLibrary(root)
        _ = try await again.open()
        #expect(await again.activity(of: .of("n-1"), limit: 5).first?.sessionTitle == "打卡頁 RWD 調整")
        let s = try await again.summary(.of("n-1"))
        #expect(s.exempt == .kept)
        await again.close()
        // A corrupt state file is moved aside.
        try Data("{oops".utf8).write(to: root.notes.appendingPathComponent(".codd/state.json"))
        let third = makeLibrary(root)
        _ = try await third.open()
        let names = try FileManager.default.contentsOfDirectory(atPath: root.notes.appendingPathComponent(".codd").path)
        #expect(names.contains { $0.hasPrefix("state.json.corrupt-") })
        await third.close()
    }
}
