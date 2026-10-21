import Foundation
import Testing
@testable import CoddNotes

@Suite struct HistoryTests {
    @Test func mergeWindowForcedAndRestore() async throws {
        let root = TempRoot()
        let clock = ManualClock(iso("2026-10-15T09:00:00+08:00"))
        let lib = makeLibrary(root, clock: clock)
        _ = try await lib.open()
        let doc = try await lib.create(NewNote(title: "版本", body: "# 版本\n\n第一版\n", ai: .append))
        let id = doc.metadata.id
        #expect(try await lib.history(of: id).count == 1)

        clock.advance(minutes: 1)
        _ = try await lib.save(id, body: "# 版本\n\n第二版\n", basedOn: nil)
        #expect(try await lib.history(of: id).count == 1)  // inside the 5-minute window

        clock.advance(minutes: 5)
        _ = try await lib.save(id, body: "# 版本\n\n第三版\n", basedOn: nil)
        var h = try await lib.history(of: id)
        #expect(h.count == 2)
        #expect(h[0].id.hasPrefix("20261015-010600-000-"))  // UTC name, newest first
        #expect(h[0].reason == nil)

        // An edit inside the window, then an AI append: the text before the append is snapshotted.
        clock.advance(minutes: 1)
        _ = try await lib.save(id, body: "# 版本\n\n第四版\n", basedOn: nil)
        #expect(try await lib.history(of: id).count == 2)
        _ = try await lib.appendFromAI(id, markdown: "AI 寫的", heading: nil, actor: AIActor(via: "mcp"))
        h = try await lib.history(of: id)
        #expect(h.count == 3 && h[0].reason == "ai-append")
        #expect(try await lib.snapshotText(h[0], of: id) == "# 版本\n\n第四版\n")
        // A forced snapshot of bytes identical to the newest one is skipped.
        #expect(try await lib.snapshot(id, reason: "condense") != nil)
        #expect(try await lib.snapshot(id, reason: "condense") == nil)

        let first = try #require(try await lib.history(of: id).last)
        #expect(try await lib.snapshotText(first, of: id) == "# 版本\n\n第一版\n")
        clock.advance(minutes: 1)
        _ = try await lib.save(id, body: "# 版本\n\n改壞了\n", basedOn: nil)
        let restored = try await lib.restoreSnapshot(first, of: id)
        #expect(restored.body == "# 版本\n\n第一版\n")
        #expect(restored.metadata.ai == .append)  // the current frontmatter stays
        h = try await lib.history(of: id)
        #expect(h[0].reason == "restore")
        await lib.close()
    }

    @Test func thinningSchedule() throws {
        let root = TempRoot()
        let writer = AtomicWriter(tempDirectory: root.notes.appendingPathComponent(".codd/tmp"))
        let store = HistoryStore(root: root.notes.appendingPathComponent(".codd/history"), writer: writer)
        let id = NoteID.of("thin-me")
        let now = iso("2026-10-15T12:00:00+08:00")
        // One snapshot every 6 hours for 100 days.
        for k in 0..<400 {
            let at = now.addingTimeInterval(-Double(k) * 6 * 3600)
            try store.take(id, data: Data("v\(k)".utf8), reason: nil, force: true, now: at)
        }
        #expect(store.list(id).count == 200)  // the cap at write time keeps the newest 200
        // Refill the old range so thinning has every age to work on.
        let store2 = HistoryStore(root: root.notes.appendingPathComponent(".codd/history2"), writer: writer)
        for k in stride(from: 399, through: 0, by: -1) {
            let at = now.addingTimeInterval(-Double(k) * 6 * 3600)
            let url = store2.folder(id).appendingPathComponent("\(ISODate.compactUTC(at))-\(String(format: "%08x", k)).md")
            try writer.write(Data("v\(k)".utf8), to: url, mode: 0o600)
        }
        #expect(store2.list(id).count == 400)
        let removed = store2.thin(id, now: now, calendar: LocalCalendar(timeZone: taipei))
        let kept = store2.list(id)
        let ages = kept.map { now.timeIntervalSince($0.takenAt) / 86_400 }
        #expect(ages.allSatisfy { $0 <= 90 })
        #expect(kept.filter { now.timeIntervalSince($0.takenAt) <= 48 * 3600 }.count == 9)   // all of the last 48 h
        #expect(kept.filter { let a = now.timeIntervalSince($0.takenAt); return a > 48 * 3600 && a <= 14 * 86_400 }.count == 48)
        // 14–90 days: one per local day.
        let old = kept.filter { now.timeIntervalSince($0.takenAt) > 14 * 86_400 }
        let days = Set(old.map { LocalCalendar(timeZone: taipei).startOfDay($0.takenAt) })
        #expect(days.count == old.count && old.count >= 75 && old.count <= 77)
        #expect(removed == 400 - kept.count)
    }

    @Test func largeFilesAreNotSnapshotted() throws {
        let root = TempRoot()
        let writer = AtomicWriter(tempDirectory: root.notes.appendingPathComponent(".codd/tmp"))
        let store = HistoryStore(root: root.notes.appendingPathComponent(".codd/history"), writer: writer)
        let big = Data(repeating: 0x61, count: 2 * 1024 * 1024 + 1)
        #expect(try store.take(.of("big-1"), data: big, reason: nil, force: true, now: Date()) == nil)
        #expect(store.list(.of("big-1")).isEmpty)
    }
}
