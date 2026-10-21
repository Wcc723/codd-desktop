import Foundation
import Testing
@testable import CODD

/// Replays the differ's operations on plain arrays, the way NSOutlineView applies them.
/// Inserted rows take their identity from the new snapshot (NSOutlineView asks the data
/// source, which already reports the new state).
@MainActor
final class FakeOutline: OutlineMutationSink {
    var children: [AnyNodeKey: [NodeKind]] = [:]
    var collapsed: Set<NodeKind> = []
    var reloaded: [NodeKind] = []
    var operations = 0
    var target = SidebarSnapshot()
    private var parents: [NodeKind: NodeKind?] = [:]

    init(_ snapshot: SidebarSnapshot) {
        children = [.root: snapshot.childrenOf(nil)]
        parents = snapshot.parentMap()
        for (node, _) in snapshot.allNodes() { children[.node(node)] = snapshot.childrenOf(node) }
    }

    private func key(_ node: NodeKind?) -> AnyNodeKey { node.map(AnyNodeKey.node) ?? .root }

    func isLive(_ node: NodeKind) -> Bool {
        var current: NodeKind? = node
        while let n = current {
            if collapsed.contains(n) { return false }
            current = parents[n] ?? nil
        }
        return true
    }

    func insert(at index: Int, in parent: NodeKind?) {
        operations += 1
        let node = target.childrenOf(parent)[index]
        children[key(parent), default: []].insert(node, at: index)
    }

    func remove(at index: Int, in parent: NodeKind?) {
        operations += 1
        children[key(parent)]?.remove(at: index)
    }

    func move(from index: Int, in source: NodeKind?, to newIndex: Int, in destination: NodeKind?) {
        operations += 1
        guard let node = children[key(source)]?.remove(at: index) else { return }
        children[key(destination), default: []].insert(node, at: newIndex)
    }

    func reloadChildren(of parent: NodeKind) { reloaded.append(parent) }
}

@MainActor
@Suite("Outline differ")
struct OutlineDifferTests {
    private func apply(_ old: SidebarSnapshot, _ new: SidebarSnapshot, collapsed: Set<NodeKind> = []) -> FakeOutline {
        let outline = FakeOutline(old)
        outline.collapsed = collapsed
        outline.target = new
        OutlineDiffer.apply(from: old, to: new, sink: outline)
        return outline
    }

    /// Every parent the fake considers live must end up equal to the new snapshot.
    private func expectConverged(_ outline: FakeOutline, _ new: SidebarSnapshot, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(outline.children[.root] == new.childrenOf(nil), sourceLocation: sourceLocation)
        for (node, _) in new.allNodes() where !new.childrenOf(node).isEmpty && outline.isLive(node) {
            if let got = outline.children[.node(node)], !outline.reloaded.contains(node) {
                #expect(got == new.childrenOf(node), "\(node)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func noChangeMeansNoOperations() {
        let store = MockSessionStore(shiftClock: false)
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        let outline = apply(snap, snap)
        #expect(outline.operations == 0)
    }

    @Test func stateChangeTouchesOnlyNeedsYou() {
        let store = MockSessionStore(shiftClock: false)
        let old = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        store.answer("s1", key: "1")
        let new = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        let outline = apply(old, new)
        #expect(outline.operations == 1) // one removal from NEEDS YOU
        expectConverged(outline, new)
    }

    @Test func crossGroupProjectMove() {
        let store = MockSessionStore(shiftClock: false)
        let old = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        store.moveProjects(["invoice"], toGroup: "northlab", atIndex: 0)
        let new = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        let outline = apply(old, new)
        expectConverged(outline, new)
        // One cross-group move + the NEEDS YOU mirror following the new tree order (s2 first).
        #expect(outline.operations == 2)
    }

    @Test func movingIntoACollapsedGroupReloadsIt() {
        let store = MockSessionStore(shiftClock: false)
        let old = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        store.moveProjects(["invoice"], toGroup: "codd", atIndex: 0)
        let new = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        let outline = apply(old, new, collapsed: [.group("codd")])
        #expect(outline.reloaded.contains(.group("codd")))
        #expect(outline.children[.node(.group("northweb"))] == new.childrenOf(.group("northweb")))
    }

    @Test("random mutations converge", arguments: 0..<25)
    func randomMutationsConverge(seed: Int) {
        var rng = SeededGenerator(seed: UInt64(seed + 1))
        let store = MockSessionStore(shiftClock: false)
        var snapshot = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        let states: [SessionState] = [.waiting, .error, .done, .busy, .idle, .exited]
        for _ in 0..<30 {
            let sessions = store.allSessions.sorted { $0.id < $1.id }
            let projects = store.groups.flatMap(\.projectIDs).compactMap(store.project)
            switch Int.random(in: 0..<5, using: &rng) {
            case 0: sessions.randomElement(using: &rng)?.state = states.randomElement(using: &rng) ?? .idle
            case 1:
                if let p = projects.randomElement(using: &rng), let s = p.sessionIDs.randomElement(using: &rng) {
                    store.moveSessions([s], toIndex: Int.random(in: 0...p.sessionIDs.count, using: &rng), inProject: p.id)
                }
            case 2:
                if let p = projects.randomElement(using: &rng), let g = store.groups.randomElement(using: &rng) {
                    store.moveProjects([p.id], toGroup: g.id, atIndex: Int.random(in: 0...g.projectIDs.count, using: &rng))
                }
            case 3:
                if let g = store.groups.filter({ !$0.isUngrouped }).randomElement(using: &rng) {
                    store.moveGroups([g.id], toIndex: Int.random(in: 0...store.groups.count, using: &rng))
                }
            default:
                if let s = sessions.randomElement(using: &rng) { store.setPinned(!s.isPinned, sessions: [s.id]) }
            }
            let next = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
            let outline = apply(snapshot, next)
            expectConverged(outline, next)
            snapshot = next
        }
    }
}

/// Deterministic generator for reproducible fuzzing.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
