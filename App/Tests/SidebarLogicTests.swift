import Foundation
import Testing
@testable import CODD

@MainActor
@Suite("Sidebar snapshot")
struct SidebarSnapshotTests {
    @Test func treeHasNeedsYouPinnedGroupsAndAddRow() {
        let store = MockSessionStore(shiftClock: false)
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        #expect(snap.childrenOf(nil) == [.section(.needsYou), .section(.pinned), .group("northlab"), .group("northweb"),
                                         .group("github"), .group("codd"), .group("ungrouped"), .addGroup])
        // NEEDS YOU mirrors waiting + error in tree order, then the DONE line.
        #expect(snap.childrenOf(.section(.needsYou)) == [.session("s1", .needs), .session("s2", .needs), .session("s3", .needs), .doneSummary])
        #expect(snap.childrenOf(.section(.pinned)) == [.session("s5", .pinned)])
        #expect(snap.childrenOf(.group("northweb")) == [.project("backend"), .project("frontend"), .project("invoice")])
        #expect(snap.childrenOf(.project("backend")) == [.session("s1", .tree), .session("s8", .tree)])
        #expect(snap.childrenOf(.project("skills")) == [.emptyProject("skills")])
    }

    @Test func blocksCoverGroupsAndNeedsYou() {
        let store = MockSessionStore(shiftClock: false)
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        #expect(snap.block(of: .session("s1", .needs)) == .needs)
        #expect(snap.block(of: .session("s1", .tree)) == .group("northweb"))
        #expect(snap.block(of: .project("skills")) == .group("northlab"))
        #expect(snap.block(of: .section(.pinned)) == nil)
        #expect(snap.block(of: .session("s5", .pinned)) == nil)
    }

    @Test func sessionOrderForCommandNumbers() {
        let store = MockSessionStore(shiftClock: false)
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        #expect(snap.sessionOrder == ["s1", "s2", "s3", "s5", "s4", "s6", "s7", "s8", "s9", "s10", "s11", "s12", "s13", "s14"])
    }

    @Test func stateChangesMoveRowsInAndOutOfNeedsYou() {
        let store = MockSessionStore(shiftClock: false)
        store.answer("s1", key: "1")
        store.session("s9")?.state = .error
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        #expect(snap.childrenOf(.section(.needsYou)).compactMap(\.sessionID) == ["s9", "s2", "s3"])
    }

    @Test func filterKeepsMatchingSessionsAndTheirProjects() {
        let store = MockSessionStore(shiftClock: false)
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "打卡")
        #expect(snap.childrenOf(nil).filter { if case .group = $0 { return true } else { return false } } == [.group("northweb")])
        #expect(snap.childrenOf(.group("northweb")) == [.project("frontend")])
        #expect(snap.childrenOf(.project("frontend")) == [.session("s9", .tree)])
        #expect(!snap.childrenOf(nil).contains(.addGroup))
    }

    @Test func stateModeGroupsByState() {
        let store = MockSessionStore(shiftClock: false)
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .state, filter: "")
        #expect(snap.childrenOf(nil) == [.section(.needsYou), .section(.working), .section(.ready), .section(.idle),
                                         .section(.shell), .section(.stopped)])
        #expect(snap.childrenOf(.section(.working)).compactMap(\.sessionID) == ["s7", "s9", "s10", "s5"])
        #expect(snap.childrenOf(.section(.stopped)).compactMap(\.sessionID) == ["s12"])
    }
}

@MainActor
@Suite("Drop rules")
struct DropPlannerTests {
    private func setup() -> (MockSessionStore, SidebarSnapshot) {
        let store = MockSessionStore(shiftClock: false)
        return (store, SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: ""))
    }

    @Test func sessionsReorderWithinTheirProject() {
        let (store, snap) = setup()
        let plan = DropPlanner.plan(dragged: [.session("s8", .tree)], parent: .project("backend"), index: 0, snapshot: snap, store: store)
        #expect(plan?.target == .sessions(project: "backend", index: 0))
        let onRow = DropPlanner.plan(dragged: [.session("s8", .tree)], parent: .session("s1", .tree), index: -1, snapshot: snap, store: store)
        #expect(onRow?.target == .sessions(project: "backend", index: 0))
    }

    @Test func sessionsCannotLeaveTheirProject() {
        let (store, snap) = setup()
        #expect(DropPlanner.plan(dragged: [.session("s8", .tree)], parent: .project("frontend"), index: 0, snapshot: snap, store: store) == nil)
        #expect(DropPlanner.plan(dragged: [.session("s8", .tree), .session("s9", .tree)], parent: .project("backend"), index: 0,
                                 snapshot: snap, store: store) == nil)
        #expect(DropPlanner.plan(dragged: [.session("s1", .needs)], parent: .project("backend"), index: 0, snapshot: snap, store: store) == nil)
    }

    @Test func projectsDropIntoGroups() {
        let (store, snap) = setup()
        let onHeader = DropPlanner.plan(dragged: [.project("invoice")], parent: .group("northlab"), index: -1, snapshot: snap, store: store)
        #expect(onHeader == DropPlan(target: .projects(group: "northlab", index: 3), parent: .group("northlab"), childIndex: 3))
        let onProject = DropPlanner.plan(dragged: [.project("invoice")], parent: .project("proto"), index: -1, snapshot: snap, store: store)
        #expect(onProject?.target == .projects(group: "northlab", index: 1))
        #expect(DropPlanner.plan(dragged: [.project("invoice")], parent: nil, index: 2, snapshot: snap, store: store) == nil)
    }

    @Test func groupsReorderAmongGroupsOnly() {
        let (store, snap) = setup()
        // Root: [needs, pinned, northlab(2), northweb, github, codd(5), ungrouped(6), add]
        let toTop = DropPlanner.plan(dragged: [.group("codd")], parent: nil, index: 0, snapshot: snap, store: store)
        #expect(toTop == DropPlan(target: .groups(index: 0), parent: nil, childIndex: 2))
        let toEnd = DropPlanner.plan(dragged: [.group("northlab")], parent: nil, index: 8, snapshot: snap, store: store)
        #expect(toEnd?.target == .groups(index: 4))
        #expect(DropPlanner.plan(dragged: [.group("ungrouped")], parent: nil, index: 2, snapshot: snap, store: store) == nil)
    }
}
