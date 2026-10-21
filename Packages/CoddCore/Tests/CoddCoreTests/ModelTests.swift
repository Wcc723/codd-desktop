import Darwin
import Foundation
import Testing
@testable import CoddCore

@Suite("Color tags")
struct ColorTagTests {
    @Test func eightColorsPlusNone() {
        #expect(ColorTag.allCases.count == 9)
        #expect(ColorTag.red.hex == "#ef5b5b")
        #expect(ColorTag.cyan.hex == "#4ed1e6")
        #expect(ColorTag.none.hex == nil)
        #expect(ColorTag.purple.rgb?.red == 0xB0)
        #expect(ColorTag.none.rgb == nil)
    }

    @Test func lenientDecoding() throws {
        let v = try JSONDecoder().decode([ColorTag].self, from: Data(#"["RED","pink","default","magenta"]"#.utf8))
        #expect(v == [.red, .pink, .none, .none])
        #expect(String(decoding: try JSONEncoder().encode(ColorTag.orange), as: UTF8.self) == "\"orange\"")
    }
}

@Suite("Session state (SPEC §3)")
struct SessionStateTests {
    let started = referenceNow.addingTimeInterval(-600)

    func resolve(_ activity: SessionActivity, kind: SessionKind = .claude, process: SessionStateResolver.ProcessStatus? = nil,
                 viewed: Date? = nil, hadTurn: Bool = true, now: Date = referenceNow) -> SessionState {
        SessionStateResolver.resolve(.init(kind: kind, process: process ?? .running(startedAt: started), activity: activity,
                                           lastViewedAt: viewed, hasHadTurn: hadTurn), now: now)
    }

    func activity(_ s: ActivityState, since: Date? = referenceNow.addingTimeInterval(-60)) -> SessionActivity {
        SessionActivity(state: s, since: since.map(JSDate.isoString))
    }

    @Test func glyphsAndAttention() {
        let all: [SessionState] = [.waiting(.permission), .error(.overloaded), .done, .busy, .compacting, .idle, .starting,
                                   .unknown, .shell, .exited(code: 0), .stopped]
        #expect(all.map(\.glyph) == ["◆", "▲", "◇", "●", "◌", "○", "◌", "●", "$", "✕", "⟲"])
        #expect(all.filter(\.needsAttention) == [.waiting(.permission), .error(.overloaded)])
        #expect(SessionState.compacting.pillLabel == "COMPACT")
        #expect(SessionState.waiting(.question).styleClass == "st-waiting")
        #expect(WaitingReason.permission.shortLabel == "PERM")
    }

    @Test func processStatusWins() {
        #expect(resolve(activity(.busy), process: .stopped) == .stopped)
        #expect(resolve(activity(.busy), process: .exited(code: 0)) == .exited(code: 0))
        #expect(resolve(activity(.busy), kind: .shell) == .shell)
    }

    @Test func activityStates() {
        var w = activity(.waiting)
        w.reason = .plan
        #expect(resolve(w) == .waiting(.plan))
        #expect(resolve(activity(.waiting)) == .waiting(.other))
        var e = activity(.error)
        e.errorKind = .rateLimit
        #expect(resolve(e) == .error(.rateLimit))
        #expect(resolve(activity(.compacting)) == .compacting)
        #expect(resolve(activity(.busy)) == .busy)
        #expect(resolve(activity(.ended)) == .shell) // PTY alive, claude ended (SPEC §3 st-shell)
    }

    @Test func doneUntilViewed() {
        let idle = activity(.idle)
        #expect(resolve(idle) == .done)
        #expect(resolve(idle, viewed: referenceNow.addingTimeInterval(-120)) == .done)
        #expect(resolve(idle, viewed: referenceNow.addingTimeInterval(-30)) == .idle)
        #expect(resolve(idle, hadTurn: false) == .idle)
        #expect(resolve(activity(.idle, since: nil)) == .idle)
    }

    @Test func startingThenUnknown() {
        let fresh = referenceNow.addingTimeInterval(-5)
        #expect(resolve(activity(.unknown, since: nil), process: .running(startedAt: fresh)) == .starting)
        #expect(resolve(activity(.unknown, since: nil), process: .running(startedAt: referenceNow.addingTimeInterval(-20))) == .unknown)
    }

    @Test func codableRoundTrip() throws {
        let all: [SessionState] = [.waiting(.question), .error(.billingError), .done, .busy, .compacting, .idle, .starting,
                                   .unknown, .shell, .exited(code: 137), .exited(code: nil), .stopped]
        let data = try JSONEncoder().encode(all)
        #expect(try JSONDecoder().decode([SessionState].self, from: data) == all)
        let odd = try JSONDecoder().decode([SessionState].self, from: Data(#"[{"kind":"zzz"},{"kind":"waiting"}]"#.utf8))
        #expect(odd == [.unknown, .waiting(.other)])
    }
}

@Suite("Layout and LayoutStore")
struct LayoutStoreTests {
    func sample() -> Layout {
        let g1 = ProjectGroup(name: "藍鵲 · 網站", color: .blue, order: 0)
        let g2 = ProjectGroup(name: "CODD", color: .purple, order: 1, collapsed: true)
        let p1 = Project(groupId: g1.id, name: "orb-toolkit-backend", path: "/synthetic/Project/orb-toolkit-backend", order: 0)
        let p2 = Project(groupId: g1.id, name: "orb-toolkit-frontend", path: "/synthetic/Project/orb-toolkit-frontend", order: 1,
                         colorOverride: .pink, collapsed: true)
        let p3 = Project(groupId: nil, name: "claude-line-test", path: "/synthetic/Desktop/claude-line-test", order: 0, pinned: true)
        let created = referenceNow.addingTimeInterval(-3600)
        let s1 = SessionRecord(claudeSessionId: "11111111-aaaa-4aaa-8aaa-111111111111", projectId: p1.id, kind: .claude,
                               title: "修正登入 API 401", color: .red, order: 0, createdAt: created,
                               lastState: .waiting(.permission), lastStateAt: referenceNow, holderSocket: "/synthetic/run/7c1e9a04.sock",
                               launchProfileId: "claude-default", model: "opus-5.5", permissionMode: "acceptEdits", accountNumber: 2,
                               lastViewedAt: referenceNow)
        let s2 = SessionRecord(projectId: p1.id, kind: .shell, title: "npm run dev", order: 1, createdAt: created)
        let s3 = SessionRecord(projectId: p1.id, kind: .claude, order: 2, createdAt: created, archivedAt: referenceNow)
        return Layout(groups: [g2, g1], projects: [p1, p2, p3], sessions: [s1, s2, s3])
    }

    @Test func missingFileIsEmpty() throws {
        let tmp = try TempDir("codd-layout")
        defer { tmp.remove() }
        #expect(try LayoutStore(fileURL: tmp.file("layout.json")).load() == .empty)
    }

    @Test func saveLoadRoundTripAtomicAndPrivate() throws {
        let tmp = try TempDir("codd-layout")
        defer { tmp.remove() }
        let url = tmp.url.appendingPathComponent("nested/dir/layout.json")
        let store = LayoutStore(fileURL: url)
        let layout = sample()
        try store.save(layout)
        #expect(try store.load() == layout)
        var st = stat()
        #expect(stat(url.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(stat(url.deletingLastPathComponent().path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
        // No temp files left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["layout.json"])
        let json = try #require(JSONValue.parse(Data(contentsOf: url)))
        #expect(json["version"] == .number(1))
        #expect(json["sessions"]?.arrayValue?.first?["createdAt"]?.stringValue == "2026-10-15T01:42:00.000Z")
    }

    @Test func overwriteReplacesContent() throws {
        let tmp = try TempDir("codd-layout")
        defer { tmp.remove() }
        let store = LayoutStore(fileURL: tmp.file("layout.json"))
        try store.save(sample())
        try store.save(.empty)
        #expect(try store.load() == .empty)
    }

    @Test func newerVersionIsRefused() throws {
        let tmp = try TempDir("codd-layout")
        defer { tmp.remove() }
        let url = tmp.file("layout.json")
        let newer = Data(#"{"version": 2, "groups": []}"#.utf8)
        try newer.write(to: url)
        #expect(throws: LayoutStoreError.unsupportedVersion(2)) { try LayoutStore(fileURL: url).load() }
        // Saving over it is refused too (an older build must not downgrade the data).
        #expect(throws: LayoutStoreError.unsupportedVersion(2)) { try LayoutStore(fileURL: url).save(sample()) }
        #expect(try Data(contentsOf: url) == newer)
    }

    /// M5 D14: a newer file is shown read-only through this version's decoder (saving is still refused).
    @Test func newerVersionIsReadReadOnlyAsFarAsItDecodes() throws {
        let tmp = try TempDir("codd-layout")
        defer { tmp.remove() }
        let url = tmp.file("layout.json")
        let store = LayoutStore(fileURL: url)
        // sample() makes fresh ids on every call, so compare against one value.
        let layout = sample()
        try store.save(layout)
        let current = try Data(contentsOf: url)
        var object = try #require(try JSONSerialization.jsonObject(with: current) as? [String: Any])
        object["version"] = 99
        object["futureMember"] = ["kept": true]
        let newer = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try newer.write(to: url)
        #expect(throws: LayoutStoreError.unsupportedVersion(99)) { try store.load() }
        #expect(try store.loadNewerReadOnly() == layout)
        #expect(throws: LayoutStoreError.unsupportedVersion(99)) { try store.save(.empty) }
        #expect(try Data(contentsOf: url) == newer)
        // A current file is not "newer" (save refuses to replace the v99 file, so write it back
        // directly); garbage does not decode.
        try current.write(to: url)
        #expect(throws: (any Error).self) { try store.loadNewerReadOnly() }
        try Data("{oops".utf8).write(to: url)
        #expect(throws: (any Error).self) { try store.loadNewerReadOnly() }
    }

    @Test func corruptFilesAreReportedAndCanBeMovedAside() throws {
        let tmp = try TempDir("codd-layout")
        defer { tmp.remove() }
        let url = tmp.file("layout.json")
        let store = LayoutStore(fileURL: url)
        for bad in ["{oops", "[1]", #"{"groups":[]}"#, #"{"version":0}"#] {
            try Data(bad.utf8).write(to: url)
            #expect(throws: (any Error).self) { try store.load() }
        }
        let aside = try store.moveAside(now: referenceNow)
        #expect(aside.lastPathComponent == "layout.json.corrupt-1792032120000")
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try store.load() == .empty)
    }

    @Test func tolerantDecodingFillsDefaultsAndSkipsBrokenRows() throws {
        let tmp = try TempDir("codd-layout")
        defer { tmp.remove() }
        let url = tmp.file("layout.json")
        let gid = UUID().uuidString, pid = UUID().uuidString, sid = UUID().uuidString
        try Data("""
        {"version":1,"futureKey":true,
         "groups":[{"id":"\(gid)","name":"G","color":"ultraviolet"},{"name":"no id"}],
         "projects":[{"id":"\(pid)","path":"/p","groupId":"not-a-uuid"},{"id":"\(UUID().uuidString)"}],
         "sessions":[{"id":"\(sid)","projectId":"\(pid)","kind":"robot","createdAt":"bad","lastState":{"kind":"busy"}}]}
        """.utf8).write(to: url)
        let layout = try LayoutStore(fileURL: url).load()
        #expect(layout.groups.count == 1)
        #expect(layout.groups[0].color == ColorTag.none)
        #expect(!layout.groups[0].collapsed)
        #expect(layout.projects.count == 1)
        #expect(layout.projects[0].groupId == nil)
        #expect(layout.sessions.count == 1)
        #expect(layout.sessions[0].kind == .claude)
        #expect(layout.sessions[0].lastState == .busy)
    }

    @Test func orderingQueries() {
        let l = sample()
        #expect(l.orderedGroups.map(\.name) == ["藍鵲 · 網站", "CODD"])
        let backend = l.projects[0]
        #expect(l.sessions(inProject: backend.id).map(\.title) == ["修正登入 API 401", "npm run dev"]) // archived hidden
        #expect(l.projects(inGroup: nil).map(\.name) == ["claude-line-test"])
        #expect(l.project(forPath: "/synthetic/Project/orb-toolkit-backend/")?.id == backend.id)
        #expect(l.project(forPath: "/synthetic/Project/./orb-toolkit-frontend")?.name == "orb-toolkit-frontend")
        #expect(l.project(forPath: "/elsewhere") == nil)
        #expect(l.projects[1].effectiveColor(group: l.groups[1]) == .pink)
        #expect(l.projects[0].effectiveColor(group: l.groups[1]) == .blue)
        #expect(l.sessions[0].displayTitle(fallback: "x") == "修正登入 API 401")
        var renamed = l.sessions[0]
        renamed.titleOverride = "  我的名字 "
        #expect(renamed.displayTitle(fallback: "x") == "我的名字")
        #expect(l.sessions[2].displayTitle(fallback: "orb-toolkit-backend") == "orb-toolkit-backend")
    }

    @Test func moveOperations() {
        var l = sample()
        let backend = l.projects[0]
        let shell = l.sessions[1]
        l.moveSession(shell.id, toIndex: 0)
        #expect(l.sessions(inProject: backend.id).map(\.id) == [shell.id, l.sessions[0].id])
        let ungrouped = l.projects[2]
        let g1 = l.groups[1]
        l.moveProject(ungrouped.id, toGroup: g1.id, index: 1)
        #expect(l.projects(inGroup: g1.id).map(\.name) == ["orb-toolkit-backend", "claude-line-test", "orb-toolkit-frontend"])
        #expect(l.projects(inGroup: nil).isEmpty)
        l.moveGroup(l.groups[0].id, toIndex: 0)
        #expect(l.orderedGroups.map(\.name) == ["CODD", "藍鵲 · 網站"])
        l.moveGroup(UUID(), toIndex: 0) // unknown id: no-op
        #expect(l.orderedGroups.map(\.name) == ["CODD", "藍鵲 · 網站"])
    }
}

@Suite("Atomic file")
struct AtomicFileTests {
    @Test func failsCleanlyWhenDirectoryIsAFile() throws {
        let tmp = try TempDir("codd-atomic")
        defer { tmp.remove() }
        try Data("x".utf8).write(to: tmp.file("blocker"))
        #expect(throws: (any Error).self) { try AtomicFile.write(Data("y".utf8), to: tmp.file("blocker/inner.json")) }
    }

    @Test func customPermissions() throws {
        let tmp = try TempDir("codd-atomic")
        defer { tmp.remove() }
        let url = tmp.file("f.bin")
        try AtomicFile.write(Data([1, 2, 3]), to: url, permissions: 0o640)
        var st = stat()
        #expect(stat(url.path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o640)
        #expect(try Data(contentsOf: url) == Data([1, 2, 3]))
    }
}
