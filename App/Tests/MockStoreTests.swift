import Foundation
import Testing
@testable import CODD
import CoddUI

@MainActor
@Suite("Mock data (SPEC §5)")
struct MockDataTests {
    @Test func countsMatchTheSpecSummaryLine() {
        let store = MockSessionStore(shiftClock: false)
        let counts = SessionCounts(sessions: store.allSessions)
        // `13 LIVE · ◆ 3 NEEDS YOU · ● 4 WORKING · ✕ 1 EXITED`
        #expect(counts.live == 13)
        #expect(counts.attention == 3)
        #expect(counts.waiting == 2 && counts.error == 1)
        #expect(counts.working == 4)
        #expect(counts.exited == 1)
    }

    @Test func groupsProjectsAndSessionsInManualOrder() {
        let store = MockSessionStore(shiftClock: false)
        #expect(store.groups.map(\.id) == ["northlab", "northweb", "github", "codd", "ungrouped"])
        #expect(store.groups.last?.isUngrouped == true)
        #expect(store.group("northweb")?.projectIDs == ["backend", "frontend", "invoice"])
        #expect(store.project("backend")?.sessionIDs == ["s1", "s8"])
        #expect(store.group("codd")?.isCollapsed == true)
        #expect(store.pinnedSessionIDs == ["s5"])
    }

    @Test func canonicalSessionFields() throws {
        let store = MockSessionStore(shiftClock: false)
        let s1 = try #require(store.session("s1"))
        #expect(s1.title == "修正登入 API 401")
        #expect(s1.state == .waiting && s1.waitingReason == .permission)
        #expect(s1.tag == .red && s1.remoteControl && s1.contextPercent == 58)
        let s7 = try #require(store.session("s7"))
        #expect(s7.accountID == "2" && s7.accountPinned)
        let s8 = try #require(store.session("s8"))
        #expect(s8.kind == .shell && s8.state == .shell)
        #expect(store.session("s14")?.external == true)
        #expect(store.session("s11")?.isStale == true)
    }

    @Test func mockClockShowsTheSpecNumbersAtLaunch() throws {
        let store = MockSessionStore(shiftClock: true)
        let now = store.clock.now()
        let s1 = try #require(store.session("s1"))
        #expect(DurationFormat.compact(now.timeIntervalSince(s1.stateSince)) == "3m")
        let s7 = try #require(store.session("s7"))
        #expect(DurationFormat.compact(now.timeIntervalSince(s7.stateSince)) == "1m12s")
    }

    @Test func accountsAreOrderedByWeeklyResetR7() {
        let accounts = MockAccountStore()
        #expect(accounts.accounts.map(\.slot) == ["#2", "#3", "#1"])
        #expect(accounts.activeAccountID == "3")
        #expect(accounts.autoSwitch.enabled == false)
        #expect(accounts.activeAccount?.worstTone == .crit)
    }
}

@MainActor
@Suite("Mock store intents")
struct MockStoreIntentTests {
    @Test func listMoveUsesOriginalIndices() {
        #expect(ListMove.apply(["a", "b", "c", "d"], moving: ["a"], to: 3) == ["b", "c", "a", "d"])
        #expect(ListMove.apply(["a", "b", "c", "d"], moving: ["d"], to: 0) == ["d", "a", "b", "c"])
        #expect(ListMove.apply(["a", "b", "c", "d"], moving: ["b", "c"], to: 4) == ["a", "d", "b", "c"])
        #expect(ListMove.apply(["a", "b"], moving: ["x"], to: 1) == ["a", "x", "b"])
        #expect(ListMove.apply(["a", "b"], moving: [], to: 1) == ["a", "b"])
    }

    @Test func sessionsReorderOnlyInsideTheirProject() {
        let store = MockSessionStore(shiftClock: false)
        store.moveSessions(["s6"], toIndex: 0, inProject: "proto")
        #expect(store.project("proto")?.sessionIDs == ["s6", "s4"])
        store.moveSessions(["s9"], toIndex: 0, inProject: "proto") // s9 belongs to frontend: ignored
        #expect(store.project("proto")?.sessionIDs == ["s6", "s4"])
        #expect(store.project("frontend")?.sessionIDs == ["s9"])
    }

    @Test func projectsMoveBetweenGroups() {
        let store = MockSessionStore(shiftClock: false)
        store.moveProjects(["invoice"], toGroup: "northlab", atIndex: 1)
        #expect(store.group("northlab")?.projectIDs == ["proto", "invoice", "mcp", "skills"])
        #expect(store.group("northweb")?.projectIDs == ["backend", "frontend"])
        #expect(store.project("invoice")?.groupID == "northlab")
    }

    @Test func groupsReorderButUngroupedStaysLast() {
        let store = MockSessionStore(shiftClock: false)
        store.moveGroups(["codd"], toIndex: 0)
        #expect(store.groups.map(\.id) == ["codd", "northlab", "northweb", "github", "ungrouped"])
        store.moveGroups(["ungrouped"], toIndex: 0)
        #expect(store.groups.last?.id == "ungrouped")
    }

    @Test func archiveAndUndoRestoreOrderAndPins() {
        let store = MockSessionStore(shiftClock: false)
        let undo = store.archive(["s1", "s5"])
        #expect(store.session("s1") == nil)
        #expect(store.project("backend")?.sessionIDs == ["s8"])
        #expect(store.pinnedSessionIDs.isEmpty)
        undo()
        #expect(store.project("backend")?.sessionIDs == ["s1", "s8"])
        #expect(store.pinnedSessionIDs == ["s5"])
        #expect(store.session("s1")?.title == "修正登入 API 401")
    }

    @Test func answeringAWaitingSessionMakesItBusy() {
        let store = MockSessionStore(shiftClock: false)
        store.answer("s1", key: "1")
        #expect(store.session("s1")?.state == .busy)
        #expect(store.session("s1")?.waitingReason == nil)
        store.answer("s2", key: "esc")
        #expect(store.session("s2")?.state == .idle)
        #expect(store.session("s2")?.answerOptions.isEmpty == true)
    }

    @Test func seenDoneBecomesIdle() {
        let store = MockSessionStore(shiftClock: false)
        store.markSeen("s4")
        #expect(store.session("s4")?.state == .idle)
        store.markSeen("s1")
        #expect(store.session("s1")?.state == .waiting)
    }

    @Test func deletingAGroupMovesItsProjectsToUngrouped() {
        let store = MockSessionStore(shiftClock: false)
        let id = store.addGroup(name: "內部工具", color: .cyan)
        #expect(store.groups.map(\.id).suffix(2) == [id, "ungrouped"])
        store.moveProjects(["gear"], toGroup: id, atIndex: 0)
        store.deleteGroup(id)
        #expect(store.group(id) == nil)
        #expect(store.group("ungrouped")?.projectIDs == ["line", "gear"])
        #expect(store.project("gear")?.groupID == "ungrouped")
    }

    @Test func pinOrderIsKept() {
        let store = MockSessionStore(shiftClock: false)
        store.setPinned(true, sessions: ["s9", "s1"])
        #expect(store.pinnedSessionIDs == ["s5", "s9", "s1"])
        store.setPinned(false, sessions: ["s5"])
        #expect(store.pinnedSessionIDs == ["s9", "s1"])
        #expect(store.session("s5")?.isPinned == false)
    }

    @Test func directAccountSwitchAndUndo() async {
        let accounts = MockAccountStore()
        #expect(await accounts.switchTo("2", reason: .user) == .switched(from: "3", to: "2", following: 12))
        #expect(accounts.activeAccountID == "2")
        #expect(await accounts.switchTo("3", reason: .undo) == .switched(from: "2", to: "3", following: 12)) // UNDO = switch back
        #expect(accounts.activeAccountID == "3")
        #expect(await accounts.switchTo("3", reason: .user) == .alreadyActive)
        if case .refused = await accounts.switchTo("nope", reason: .user) {} else { Issue.record("an unknown account is refused") }
        #expect(accounts.activeAccountID == "3")
    }
}
