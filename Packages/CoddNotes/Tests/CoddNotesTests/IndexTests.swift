import Foundation
import GRDB
import Testing
@testable import CoddNotes

@Suite struct IndexTests {
    func seed(_ root: TempRoot) {
        root.write("2026-10-15-打卡頁-rwd-跑版紀錄.md", specNote1())
        root.write("sub/folder/deep.md", "---\nid: deep-note\ntitle: 子資料夾\n---\n# 子資料夾\n\n在子資料夾裡\n")
        root.write(".hidden/secret.md", "---\nid: hidden-note\n---\n# hidden\n")
        root.write("assets/rwd-punch-k7x2/readme.md", "# not a note\n")
        root.write("plain.md", "# 沒有 frontmatter\n")
        root.write("notes.txt", "not markdown")
    }

    @Test func buildIndexesNotesOnly() async throws {
        let root = TempRoot()
        seed(root)
        let lib = makeLibrary(root)
        let report = try await lib.open()
        #expect(report.rebuilt && report.count == 3)
        let ids = Set(try await lib.list(.inbox, sort: .updated, limit: 50).map(\.id.rawValue))
        #expect(ids.contains("rwd-punch-k7x2") && ids.contains("deep-note"))
        #expect(!ids.contains("hidden-note"))
        #expect(ids.contains(NoteNaming.derivedID(relativePath: "plain.md").rawValue))
        let deep = try await lib.document(.of("deep-note"))
        #expect(deep.relativePath == "sub/folder/deep.md")
        await lib.close()

        // Reopen without changes: no rebuild.
        let again = makeLibrary(root)
        let r2 = try await again.open()
        #expect(!r2.rebuilt && r2.reason == nil && r2.count == 3)
        await again.close()
    }

    @Test func outOfDateFilesAreUpdatedAtOpen() async throws {
        let root = TempRoot()
        seed(root)
        let lib = makeLibrary(root)
        _ = try await lib.open()
        await lib.close()
        // While CODD is away: edit one, add one, delete one, rename one.
        root.write("sub/folder/deep.md", "---\nid: deep-note\ntitle: 子資料夾\n---\n# 子資料夾改名\n\n新的內容 注音輸入法\n")
        root.write("new.md", "---\nid: new-note\n---\n# 新筆記\n")
        try FileManager.default.removeItem(at: root.notes.appendingPathComponent("plain.md"))
        try FileManager.default.moveItem(at: root.notes.appendingPathComponent("2026-10-15-打卡頁-rwd-跑版紀錄.md"),
                                         to: root.notes.appendingPathComponent("renamed.md"))
        let again = makeLibrary(root)
        let r = try await again.open()
        #expect(!r.rebuilt && r.count == 3)
        #expect(try await again.summary(.of("deep-note")).metadata.title == "子資料夾改名")
        #expect(try await again.document(.of("rwd-punch-k7x2")).relativePath == "renamed.md")
        #expect(try await again.search(NoteQuery(text: "注音輸")).map(\.summary.id.rawValue) == ["deep-note"])
        await #expect(throws: NotesError.notFound(NoteNaming.derivedID(relativePath: "plain.md"))) {
            _ = try await again.document(NoteNaming.derivedID(relativePath: "plain.md"))
        }
        await again.close()
    }

    @Test func rebuildAfterDeleteCorruptVersionRoot() async throws {
        let root = TempRoot()
        seed(root)
        var lib = makeLibrary(root)
        _ = try await lib.open()
        await lib.close()

        try FileManager.default.removeItem(at: root.index)
        lib = makeLibrary(root)
        var r = try await lib.open()
        #expect(r.rebuilt && r.reason == "missing" && r.count == 3)
        await lib.close()

        // Garbage bytes.
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: root.index.path + suffix) }
        try Data(repeating: 0x5A, count: 8192).write(to: root.index)
        lib = makeLibrary(root)
        r = try await lib.open()
        #expect(r.rebuilt && r.reason == "corrupt" && r.count == 3)
        await lib.close()

        // Another schema version.
        let q = try DatabaseQueue(path: root.index.path)
        try await q.write { db in try db.execute(sql: "PRAGMA user_version = 99") }
        try q.close()
        lib = makeLibrary(root)
        r = try await lib.open()
        #expect(r.rebuilt && r.reason == "version" && r.count == 3)
        #expect(try await lib.search(NoteQuery(text: "打卡頁")).count == 1)

        // Requested rebuild.
        let rr = try await lib.rebuildIndex()
        #expect(rr.rebuilt && rr.reason == "requested" && rr.count == 3)
        await lib.close()

        // The same index file used for another notes root.
        let other = TempRoot()
        other.write("x.md", "---\nid: other-root\n---\n# other\n")
        let foreign = NotesLibrary(root: other.notes, indexURL: root.index, annotatedFolder: other.annotated, policy: .defaults, defaultAccess: .read,
                                   trash: { _ in }, timeZone: taipei)
        r = try await foreign.open()
        #expect(r.rebuilt && r.reason == "root" && r.count == 1)
        await foreign.close()
        withExtendedLifetime(other) {}
    }

    @Test func duplicateIDs() async throws {
        let root = TempRoot()
        root.write("a.md", "---\nid: same-id\n---\n# 原本的\n")
        // Make the copy clearly newer by birth time.
        try await Task.sleep(for: .milliseconds(20))
        root.write("b.md", "---\nid: same-id\n---\n# 同步衝突的複本\n")
        let lib = makeLibrary(root)
        let r = try await lib.open()
        #expect(r.count == 2)
        #expect(r.warnings.contains { $0.contains("ID 重複") })
        let original = try await lib.document(.of("same-id"))
        #expect(original.relativePath == "a.md" && !original.flags.contains(.duplicateID))
        let dup = try await lib.document(.of("same-id-dup1"))
        #expect(dup.relativePath == "b.md" && dup.flags.contains(.duplicateID))
        // The dup id is written at its next save, and the flag goes away.
        _ = try await lib.save(.of("same-id-dup1"), body: dup.body + "編輯\n", basedOn: dup.contentHash)
        #expect(root.read("b.md").hasPrefix("---\nid: same-id-dup1\n"))
        #expect(try await lib.document(.of("same-id-dup1")).flags.isEmpty)
        await lib.close()
    }

    @Test func schemaAndFTSDirect() async throws {
        let root = TempRoot()
        seed(root)
        let lib = makeLibrary(root)
        _ = try await lib.open()
        await lib.close()
        let q = try DatabaseQueue(path: root.index.path)
        try await q.read { db in
            #expect(try Int.fetchOne(db, sql: "PRAGMA user_version") == 1)
            #expect(try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"])
            // The contentless table answers MATCH but stores no text.
            let n = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes_fts WHERE notes_fts MATCH '\"跑版紀\"'")
            #expect(n == 1)
            let tags = try String.fetchAll(db, sql: "SELECT tag FROM note_tags ORDER BY tag")
            #expect(tags == ["punch", "rwd"])
            let links = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM note_links WHERE type = 'project'")
            #expect(links == 1)
        }
        try q.close()
    }
}

@Suite(.serialized) struct WatcherTests {
    @Test func externalCreateEditDeleteRename() async throws {
        let root = TempRoot()
        root.write("keep.md", "---\nid: keep-note\n---\n# 留著\n")
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let changes = ChangeCollector(lib)
        defer { changes.cancel() }

        // Create.
        root.write("dropped.md", "---\nid: dropped-note\n---\n# 外部新增\n\n打卡\n")
        #expect(await waitUntil { changes.externalIDs().contains(.of("dropped-note")) })
        #expect(try await lib.summary(.of("dropped-note")).metadata.title == "外部新增")

        // Edit.
        root.write("keep.md", "---\nid: keep-note\n---\n# 留著但改了\n")
        #expect(await waitUntil { (try? await lib.summary(.of("keep-note")).metadata.title) == "留著但改了" })
        #expect(await waitUntil { changes.externalIDs().contains(.of("keep-note")) })
        #expect(await lib.externalEventCount >= 2)

        // Rename keeps the id.
        try FileManager.default.moveItem(at: root.notes.appendingPathComponent("dropped.md"),
                                         to: root.notes.appendingPathComponent("moved.md"))
        #expect(await waitUntil { (try? await lib.document(.of("dropped-note")).relativePath) == "moved.md" })

        // Delete.
        try FileManager.default.removeItem(at: root.notes.appendingPathComponent("moved.md"))
        #expect(await waitUntil { changes.removedIDs().contains(.of("dropped-note")) })
        #expect(await waitUntil { (try? await lib.counts().inbox) == 1 })

        // A new sub-folder with a note.
        root.write("new-folder/inside.md", "---\nid: inside-note\n---\n# 裡面\n")
        #expect(await waitUntil { (try? await lib.summary(.of("inside-note"))) != nil })

        // Dot-folders are ignored.
        root.write(".obsidian/x.md", "---\nid: obsidian-x\n---\n# no\n")
        try await Task.sleep(for: .milliseconds(600))
        #expect((try? await lib.summary(.of("obsidian-x"))) == nil)
        await lib.close()
    }

    @Test func ownWritesAreNotExternal() async throws {
        let root = TempRoot()
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let changes = ChangeCollector(lib)
        defer { changes.cancel() }
        let doc = try await lib.create(NewNote(title: "自己寫的", body: "# 自己寫的\n"))
        _ = try await lib.save(doc.metadata.id, body: "# 自己寫的\n\n多一行\n", basedOn: doc.contentHash)
        _ = try await lib.update(doc.metadata.id, .pinned(true))
        // Give FSEvents time to deliver everything.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(changes.externalIDs().isEmpty)
        #expect(changes.changedIDs().contains(doc.metadata.id))
        #expect(await lib.externalEventCount == 0)
        // Then an outside edit of the same file is external.
        let text = root.read(doc.relativePath) + "外部加的\n"
        root.write(doc.relativePath, text)
        #expect(await waitUntil { changes.externalIDs().contains(doc.metadata.id) })
        await lib.close()
    }

    @Test func assetChangesUpdateCounts() async throws {
        let root = TempRoot()
        root.write("n.md", "---\nid: img-note\n---\n# 圖\n")
        let lib = makeLibrary(root)
        _ = try await lib.open()
        let dir = root.notes.appendingPathComponent("assets/img-note")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try makeImage(width: 40, height: 30).write(to: dir.appendingPathComponent("abc123.png"))
        #expect(await waitUntil { (try? await lib.summary(.of("img-note")).assetCount) == 1 })
        await lib.close()
    }
}
