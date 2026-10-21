import Foundation
import Testing
@testable import CoddNotes

@Suite struct RetentionTests {
    static let now = iso("2026-10-15T10:00:00+08:00")
    static let live = "11111111-2222-3333-4444-555555555555"

    static func ago(_ days: Double) -> String {
        ISODate.format(now.addingTimeInterval(-days * 86_400), timeZone: taipei)
    }

    static func note(_ id: String, days: Double, extra: String = "", title: String? = nil, body: String = "內容\n") -> String {
        "---\nid: \(id)\n\(extra)created: \(ago(days))\nupdated: \(ago(days))\n---\n# \(title ?? id)\n\n\(body)"
    }

    func fixture(policy: RetentionPolicy = .defaults) async throws -> (TempRoot, NotesLibrary, ManualClock, TrashRecorder) {
        let root = TempRoot()
        root.write("fresh.md", Self.note("fresh", days: 1, extra: "projects: [~/Github/Gear3D]\n"))
        root.write("stale21.md", Self.note("stale21", days: 21, extra: "projects: [~/Github/Gear3D]\n"))
        root.write("due30.md", Self.note("due30", days: 30))
        root.write("scratch8.md", Self.note("scratch8", days: 8, extra: "kind: scratch\n"))
        root.write("scratch3.md", Self.note("scratch3", days: 3, extra: "kind: scratch\n"))
        root.write("sent8.md", Self.note("sent8", days: 10, extra: "kind: prompt\nsent: \(Self.ago(8))\n"))
        root.write("draft18.md", Self.note("draft18", days: 18, extra: "kind: prompt\n"))
        root.write("pinned40.md", Self.note("pinned40", days: 40, extra: "pinned: true\n"))
        root.write("linked40.md", Self.note("linked40", days: 40, extra: "sessions: [\(Self.live)]\n"))
        root.write("read40.md", Self.note("read40", days: 40))
        root.write("kept40.md", Self.note("kept40", days: 40))
        root.write(".codd/trash/old-trash.md", Self.note("trashed31", days: 50, extra: "trashed: \(Self.ago(31))\n"))
        root.write(".codd/trash/new-trash.md", Self.note("trashed10", days: 50, extra: "trashed: \(Self.ago(10))\n"))
        let clock = ManualClock(Self.now)
        let trash = TrashRecorder(folder: root.trash)
        let lib = makeLibrary(root, clock: clock, policy: policy, trash: trash)
        _ = try await lib.open()
        await lib.recordActivity(NoteActivityEvent(at: Self.now.addingTimeInterval(-3600), note: .of("read40"), action: "read",
                                                   client: "Claude Code", session: Self.live, via: "mcp"))
        await lib.keep(.of("kept40"), until: Self.now.addingTimeInterval(10 * 86_400))
        return (root, lib, clock, trash)
    }

    @Test func countsAndSmartLists() async throws {
        let (_, lib, _, _) = try await fixture()
        await lib.setLiveSessions([Self.live])
        let c = try await lib.counts()
        #expect(c.inbox == 11 && c.pinned == 1 && c.prompts == 2 && c.archive == 0 && c.trash == 2)
        #expect(c.stale == 3)
        #expect(c.byProject == ["~/Github/Gear3D": 2])
        let stale = Set(try await lib.list(.stale, sort: .updated, limit: 50).map(\.id.rawValue))
        #expect(stale == ["stale21", "due30", "draft18"])
        #expect(try await lib.list(.pinned, sort: .updated, limit: 50).map(\.id.rawValue) == ["pinned40"])
        #expect(Set(try await lib.list(.prompts, sort: .updated, limit: 50).map(\.id.rawValue)) == ["sent8", "draft18"])
        #expect(try await lib.list(.project("~/Github/Gear3D"), sort: .updated, limit: 50).map(\.id.rawValue) == ["fresh", "stale21"])
        #expect(Set(try await lib.list(.trash, sort: .updated, limit: 50).map(\.id.rawValue)) == ["trashed31", "trashed10"])
        let inbox = try await lib.list(.inbox, sort: .updated, limit: 3)
        #expect(inbox.map(\.id.rawValue) == ["fresh", "scratch3", "scratch8"])
        #expect(try await lib.list(.inbox, sort: .title, limit: 2).map(\.id.rawValue) == ["draft18", "due30"])

        // Exemptions and due dates on the summaries.
        #expect(try await lib.summary(.of("pinned40")).exempt == .pinned)
        #expect(try await lib.summary(.of("linked40")).exempt == .linkedLiveSession)
        #expect(try await lib.summary(.of("read40")).exempt == .readByLiveSession)
        #expect(try await lib.summary(.of("kept40")).exempt == .kept)
        let s21 = try await lib.summary(.of("stale21"))
        #expect(s21.staleSince == Self.now.addingTimeInterval(-7 * 86_400))
        #expect(s21.archivesAt == Self.now.addingTimeInterval(9 * 86_400))
        #expect(try await lib.summary(.of("scratch3")).archivesAt == Self.now.addingTimeInterval(4 * 86_400))
        #expect(try await lib.summary(.of("trashed31")).purgeAt == Self.now.addingTimeInterval(-86_400))
        // Without the live session the session exemptions end.
        await lib.setLiveSessions([])
        #expect(try await lib.summary(.of("linked40")).exempt == nil)
        #expect(try await lib.counts().stale == 5)
        await lib.close()
    }

    @Test func retentionTable() async throws {
        let (root, lib, clock, trash) = try await fixture()
        let report = await lib.runRetention(liveSessions: [Self.live])
        #expect(Set(report.archived.map(\.rawValue)) == ["due30", "scratch8", "sent8"])
        #expect(Set(report.staleIDs.map(\.rawValue)) == ["stale21", "draft18"])
        #expect(report.purged.map(\.rawValue) == ["trashed31"])
        #expect(root.read("due30.md").contains("status: archived\narchived: 2026-10-15T10:00:00+08:00\narchivedBy: auto\n"))
        #expect(!root.exists(".codd/trash/old-trash.md"))
        #expect(root.exists(".codd/trash/new-trash.md"))
        #expect(trash.items.contains { $0.hasSuffix("old-trash.md") })
        #expect(await lib.tombstone(.of("trashed31"))?.purgedAt == Self.now)
        let c = try await lib.counts()
        #expect(c.archive == 3 && c.trash == 1 && c.inbox == 8)

        // A week later, without live sessions: the session exemptions are gone, keepUntil still holds.
        clock.advance(days: 7)
        let second = await lib.runRetention(liveSessions: [])
        #expect(Set(second.archived.map(\.rawValue)) == ["linked40", "read40", "scratch3"])
        #expect(!second.archived.contains(.of("kept40")) && !second.archived.contains(.of("pinned40")))
        // Past keepUntil it goes too.
        clock.advance(days: 4)
        let third = await lib.runRetention(liveSessions: [])
        #expect(third.archived.contains(.of("kept40")))
        // stale21 reaches 30 days of inactivity at day +9.
        #expect(third.archived.contains(.of("stale21")))
        await lib.close()
    }

    @Test func exemptOffAndNeverPolicies() async throws {
        let policy = RetentionPolicy(staleDays: nil, archiveDays: nil, scratchArchiveDays: 7, trashPurgeDays: 30, tombstoneDays: nil, exempt: false)
        let (_, lib, _, _) = try await fixture(policy: policy)
        let report = await lib.runRetention(liveSessions: [Self.live])
        #expect(Set(report.archived.map(\.rawValue)) == ["scratch8", "sent8"])
        #expect(report.staleIDs.isEmpty)
        #expect(try await lib.summary(.of("pinned40")).exempt == nil)
        await lib.setPolicy(RetentionPolicy(staleDays: 14, archiveDays: 30, scratchArchiveDays: 7, trashPurgeDays: 30, tombstoneDays: nil, exempt: false), defaultAccess: .read)
        let again = await lib.runRetention(liveSessions: [Self.live])
        #expect(again.archived.contains(.of("pinned40")) && again.archived.contains(.of("linked40")))
        #expect(!again.archived.contains(.of("kept40")))
        await lib.close()
    }

    @Test func activityCountsButAIReadsDoNot() async throws {
        let (_, lib, _, _) = try await fixture()
        // An AI read of stale21 does not refresh it; opening it does.
        await lib.recordActivity(NoteActivityEvent(at: Self.now, note: .of("stale21"), action: "read", via: "mcp"))
        #expect(try await lib.summary(.of("stale21")).staleSince != nil)
        await lib.markOpened(.of("stale21"), at: Self.now)
        #expect(try await lib.summary(.of("stale21")).staleSince == nil)
        // Pinning (a metadata change) is activity.
        _ = try await lib.update(.of("due30"), .addTag("x"))
        #expect(try await lib.summary(.of("due30")).lastActivity == Self.now)
        // Unarchiving is activity, so the next run does not archive it again.
        _ = await lib.runRetention(liveSessions: [])
        try await lib.unarchive([.of("scratch8")])
        let r = await lib.runRetention(liveSessions: [])
        #expect(!r.archived.contains(.of("scratch8")))
        await lib.close()
    }
}
