import Foundation
import Testing
@testable import CoddCore

private let day: TimeInterval = 86_400
/// 2026-10-17T12:00:00Z.
private let now = Date(timeIntervalSince1970: 1_792_238_400)
private let utc = TimeZone(identifier: "UTC") ?? .current

private func id(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n)) ?? UUID()
}

private func stopped(_ n: Int, daysAgo: Double, kind: SessionKind = .claude, state: SessionState = .stopped,
                     _ edit: (inout SessionRetentionInput) -> Void = { _ in }) -> SessionRetentionInput {
    var s = SessionRetentionInput(id: id(n), title: "s\(n)", kind: kind, lastState: state,
                                  lastStateAt: now.addingTimeInterval(-daysAgo * day))
    edit(&s)
    return s
}

private func archived(_ n: Int, daysAgo: Double, ring: Int64? = 8 * 1_048_576 + 4096,
                      _ edit: (inout SessionRetentionInput) -> Void = { _ in }) -> SessionRetentionInput {
    var s = SessionRetentionInput(id: id(n), title: "a\(n)", lastState: .stopped, lastStateAt: now.addingTimeInterval(-(daysAgo + 7) * day),
                                  archivedAt: now.addingTimeInterval(-daysAgo * day), ringBytes: ring)
    edit(&s)
    return s
}

private func evaluate(_ sessions: [SessionRetentionInput], _ policy: SessionRetentionPolicy = .init()) -> SessionRetentionResult {
    SessionRetention.evaluate(sessions, policy: policy, now: now, timeZone: utc)
}

@Suite("M4 session retention (D30)")
struct SessionRetentionTests {
    @Test func defaultsAre3730() {
        let p = SessionRetentionPolicy()
        #expect(p.staleDays == 3 && p.archiveDays == 7 && p.scrollbackDeleteDays == 30 && p.cleanupPeriodDays == 30)
        #expect(p.resumeWarning && p.resumeWarningDays == 5 && p.countFrom == nil)
    }

    @Test func staleAndArchiveBoundariesAtExactlyNDays() {
        let r = evaluate([
            stopped(1, daysAgo: 3 - 1.0 / 86_400),  // one second short of 3 days
            stopped(2, daysAgo: 3),
            stopped(3, daysAgo: 7 - 1.0 / 86_400),
            stopped(4, daysAgo: 7),
            stopped(5, daysAgo: 40, kind: .shell, state: .exited(code: 0)),
        ])
        #expect(r.staleIDs == [id(2), id(3), id(4), id(5)])
        #expect(r.archiveIDs == [id(4), id(5)])
        #expect(r.ringDeleteIDs.isEmpty)
        // Sessions archived now are not rows; the others are.
        #expect(r.candidates.map(\.id) == [id(2), id(3)])
    }

    @Test func ringBoundaryAndBytes() {
        let r = evaluate([archived(1, daysAgo: 30 - 1.0 / 86_400), archived(2, daysAgo: 30), archived(3, daysAgo: 60, ring: 0),
                          archived(4, daysAgo: 60, ring: nil), archived(5, daysAgo: 26)])
        #expect(r.ringDeleteIDs == [id(2)])
        #expect(r.archiveIDs.isEmpty && r.staleIDs.isEmpty)
        let rows = r.candidates.filter(\.isFile)
        #expect(rows.map(\.id) == [id(1), id(5)])
        let ring = rows[1]
        #expect(ring.reason == .ring(bytes: 8 * 1_048_576 + 4096, deletesInDays: 4))
        #expect(ring.why == "終端機紀錄 · 8.0 MB")
        #expect(ring.sub == "封存 26 天")
        #expect(ring.badge == "deletes in 4d")
        #expect(rows[0].badge == "deletes in 1d")
        // Far from deletion: no row.
        #expect(evaluate([archived(6, daysAgo: 2)]).candidates.isEmpty)
    }

    @Test func nilOrNonPositiveDaysMeanNever() {
        let old = [stopped(1, daysAgo: 400), archived(2, daysAgo: 400)]
        let never = evaluate(old, .init(staleDays: nil, archiveDays: nil, scrollbackDeleteDays: nil))
        #expect(never.staleIDs.isEmpty && never.archiveIDs.isEmpty && never.ringDeleteIDs.isEmpty)
        #expect(never.candidates.isEmpty)
        let zero = evaluate(old, .init(staleDays: 0, archiveDays: -1, scrollbackDeleteDays: 0))
        #expect(zero == never)
        // Stale only: rows with the stopped reason.
        let staleOnly = evaluate(old, .init(archiveDays: nil, scrollbackDeleteDays: nil))
        #expect(staleOnly.staleIDs == [id(1)])
        #expect(staleOnly.candidates.map(\.reason) == [.stopped(days: 400)])
        #expect(staleOnly.candidates.first?.sub == "最後畫面不會自動刪除")
    }

    @Test func exemptions() {
        let keep = now.addingTimeInterval(day)
        let r = evaluate([
            stopped(1, daysAgo: 30) { $0.isPinned = true },
            stopped(2, daysAgo: 30) { $0.isRunning = true },
            stopped(3, daysAgo: 30) { $0.isExternal = true },
            stopped(4, daysAgo: 30) { $0.keepUntil = keep },
            stopped(5, daysAgo: 30) { $0.keepUntil = now.addingTimeInterval(-1) },  // expired keep
            archived(6, daysAgo: 40) { $0.isPinned = true },
            archived(7, daysAgo: 40) { $0.keepUntil = keep },
            archived(8, daysAgo: 40) { $0.isExternal = true },
        ])
        #expect(r.staleIDs == [id(5)])
        #expect(r.archiveIDs == [id(5)])
        #expect(r.ringDeleteIDs.isEmpty)
        #expect(r.candidates.isEmpty)
    }

    @Test func onlyStoppedOrExitedSessionsAreArchived() {
        var idle = SessionRetentionInput(id: id(1), lastState: .idle, lastStateAt: now.addingTimeInterval(-30 * day))
        let noDate = SessionRetentionInput(id: id(2), lastState: .stopped)
        let r = evaluate([idle, noDate])
        #expect(r == SessionRetentionResult())
        idle.lastState = .exited(code: 1)
        #expect(evaluate([idle]).archiveIDs == [id(1)])
    }

    @Test func rowTexts() throws {
        let r = evaluate([stopped(1, daysAgo: 5.5)])
        let row = try #require(r.candidates.first)
        // 5.5 days stopped: archive due in 1.5 days, shown as 2d (whole days elapsed, like Claude's sweep).
        #expect(row.reason == .archivesSoon(days: 2))
        #expect(row.why == "停止 5 天")
        #expect(row.badge == "archives in 2d")
        // The ring goes 7 + 30 days after the stop: 2026-10-12 00:00 UTC + 37 d = 11/18.
        #expect(row.sub == "最後畫面保留到 11/18")
        #expect(!row.isFile)
        // Archive far away (30 days): `stale nd` with the stopped reason.
        let far = evaluate([stopped(2, daysAgo: 5)], .init(archiveDays: 30))
        #expect(far.candidates.first?.reason == .stopped(days: 5))
        #expect(far.candidates.first?.badge == "stale 5d")
        // Not yet stale: no row even though the archive is within the window.
        #expect(evaluate([stopped(3, daysAgo: 1)]).candidates.isEmpty)
    }

    @Test func resumeExpiresAndTranscriptGone() throws {
        let r = evaluate([
            stopped(1, daysAgo: 4) { $0.transcriptModifiedAt = now.addingTimeInterval(-26 * day) },
            stopped(2, daysAgo: 4) { $0.transcriptModifiedAt = now.addingTimeInterval(-24.5 * day) },  // 6 days left: no warning
            stopped(3, daysAgo: 4) { $0.transcriptExists = false },
            stopped(4, daysAgo: 4, kind: .shell) { $0.transcriptExists = false },
            // Not stopped by the rule, but its transcript is still going away.
            SessionRetentionInput(id: id(5), lastState: .idle, transcriptModifiedAt: now.addingTimeInterval(-29 * day)),
        ])
        let rows = Dictionary(uniqueKeysWithValues: r.candidates.map { ($0.id, $0) })
        let one = try #require(rows[id(1)])
        #expect(one.reason == .resumeExpires(days: 4))
        #expect(one.badge == "resume expires 4d")
        #expect(one.sub == "Claude Code 30 天後刪除對話紀錄")
        #expect(one.why == "停止 4 天")
        #expect(rows[id(2)]?.reason == .archivesSoon(days: 3))
        #expect(rows[id(3)]?.reason == .transcriptGone)
        #expect(rows[id(3)]?.why == "對話紀錄已不存在")
        #expect(rows[id(4)]?.reason == .archivesSoon(days: 3))  // shells have no transcript
        #expect(rows[id(5)]?.reason == .resumeExpires(days: 1))
        #expect(rows[id(5)]?.why == "對話紀錄 1 天後刪除")
        // The warning off, and another cleanupPeriodDays.
        let off = evaluate([stopped(1, daysAgo: 4) { $0.transcriptModifiedAt = now.addingTimeInterval(-26 * day) }],
                           .init(resumeWarning: false))
        #expect(off.candidates.first?.reason == .archivesSoon(days: 3))
        let longer = evaluate([stopped(1, daysAgo: 4) { $0.transcriptModifiedAt = now.addingTimeInterval(-26 * day) }],
                              .init(cleanupPeriodDays: 60))
        #expect(longer.candidates.first?.reason == .archivesSoon(days: 3))
        let overdue = evaluate([SessionRetentionInput(id: id(9), transcriptModifiedAt: now.addingTimeInterval(-45 * day))])
        #expect(overdue.candidates.first?.badge == "resume expires 0d")
    }

    @Test func firstRunGraceDelaysEveryClock() throws {
        // The first M4 run records countFrom = now: nothing is archived or deleted at once.
        let sessions = [stopped(1, daysAgo: 40), archived(2, daysAgo: 90), stopped(3, daysAgo: 2)]
        let first = evaluate(sessions, .init(countFrom: now))
        #expect(first.archiveIDs.isEmpty && first.ringDeleteIDs.isEmpty && first.staleIDs.isEmpty)
        // The long-stopped session is still a row, with the archive counted from the grace start.
        let row = try #require(first.candidates.first { $0.id == id(1) })
        #expect(row.why == "停止 40 天")
        #expect(row.reason == .archivesSoon(days: 7))
        #expect(row.sub == "最後畫面保留到 11/23")  // grace start + 37 days
        #expect(first.candidates.contains { $0.id == id(3) } == false)
        // Seven days later the clocks fire.
        let week = SessionRetention.evaluate(sessions, policy: .init(countFrom: now.addingTimeInterval(-7 * day)), now: now, timeZone: utc)
        #expect(week.archiveIDs == [id(1)])
        #expect(week.staleIDs.contains(id(1)))
        #expect(week.ringDeleteIDs.isEmpty)  // the ring clock needs 30 days from the grace start
        #expect(week.candidates.first { $0.id == id(2) }?.reason == nil)  // 23 days left: not soon
        let month = SessionRetention.evaluate(sessions, policy: .init(countFrom: now.addingTimeInterval(-30 * day)), now: now, timeZone: utc)
        #expect(month.ringDeleteIDs == [id(2)])
        // A grace start before the stop changes nothing.
        let early = evaluate(sessions, .init(countFrom: now.addingTimeInterval(-400 * day)))
        #expect(early == evaluate(sessions))
    }

    @Test func byteTexts() {
        #expect(SessionRetention.byteText(512) == "512 B")
        #expect(SessionRetention.byteText(655_360) == "640 KB")
        #expect(SessionRetention.byteText(8 * 1_048_576 + 4096) == "8.0 MB")
        #expect(SessionRetention.byteText(3 * 1_073_741_824 / 2) == "1.5 GB")
    }
}

@Suite("M4 hook payload: prompt and tool file paths")
struct M4HookPayloadTests {
    func payload(_ event: String, tool: String? = nil, input: [String: JSONValue]? = nil, cwd: String? = "/work/app",
                 extra: [String: JSONValue] = [:]) -> HookPayload {
        var o: [String: JSONValue] = ["hook_event_name": .string(event)]
        if let tool { o["tool_name"] = .string(tool) }
        if let input { o["tool_input"] = .object(input) }
        if let cwd { o["cwd"] = .string(cwd) }
        for (k, v) in extra { o[k] = v }
        return HookPayload(object: o)
    }

    @Test func prompt() {
        #expect(payload("UserPromptSubmit", extra: ["prompt": "  看一下 codd://note/rwd-punch-k7x2 "]).prompt == "  看一下 codd://note/rwd-punch-k7x2 ")
        #expect(payload("UserPromptSubmit", extra: ["prompt": "   "]).prompt == nil)
        #expect(payload("UserPromptSubmit", extra: ["prompt": 3]).prompt == nil)
        #expect(payload("UserPromptSubmit").prompt == nil)
        #expect(payload("Stop", extra: ["prompt": "x"]).prompt == nil)
    }

    @Test(arguments: [("Edit", "file_path"), ("Write", "file_path"), ("MultiEdit", "file_path"), ("NotebookEdit", "notebook_path")])
    func eachTool(_ tool: String, _ key: String) {
        let p = payload("PostToolUse", tool: tool, input: [key: "/work/app/src/pages/punch.vue", "old_string": "a"])
        #expect(p.toolFilePaths == ["/work/app/src/pages/punch.vue"])
        // The other tool's key does not count.
        let otherKey = key == "file_path" ? "notebook_path" : "file_path"
        #expect(payload("PostToolUse", tool: tool, input: [otherKey: "/x"]).toolFilePaths.isEmpty)
    }

    @Test func relativeAndUnusualPaths() {
        func paths(_ path: JSONValue, cwd: String? = "/work/app") -> [String] {
            payload("PostToolUse", tool: "Edit", input: ["file_path": path], cwd: cwd).toolFilePaths
        }
        #expect(paths("src/a.ts") == ["/work/app/src/a.ts"])
        #expect(paths("./src/../lib/b.ts") == ["/work/app/lib/b.ts"])
        #expect(paths("src/a.ts", cwd: "/work/app/") == ["/work/app/src/a.ts"])
        #expect(paths("/work/app/./x//y.ts") == ["/work/app/x/y.ts"])
        #expect(paths("src/a.ts", cwd: nil).isEmpty)
        #expect(paths("src/a.ts", cwd: "relative").isEmpty)
        #expect(paths("~/notes.md") == [NSHomeDirectory() + "/notes.md"])
        #expect(paths("").isEmpty)
        #expect(paths("  ").isEmpty)
        #expect(paths("/a\u{0}b").isEmpty)
        #expect(paths(42).isEmpty)
    }

    @Test func otherEventsAndToolsGiveNothing() {
        let input: [String: JSONValue] = ["file_path": "/work/app/a.ts"]
        #expect(payload("PreToolUse", tool: "Edit", input: input).toolFilePaths.isEmpty)
        #expect(payload("PostToolUseFailure", tool: "Edit", input: input).toolFilePaths.isEmpty)
        #expect(payload("PostToolUse", tool: "Bash", input: ["command": "sed -i x a.ts"]).toolFilePaths.isEmpty)
        #expect(payload("PostToolUse", tool: "Read", input: input).toolFilePaths.isEmpty)
        #expect(payload("PostToolUse", tool: "Edit").toolFilePaths.isEmpty)
        #expect(HookPayload(object: [:]).toolFilePaths.isEmpty)
    }
}
