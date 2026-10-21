import Foundation

/// The operations an NSOutlineView understands, applied in sequence (each index refers to the
/// state after the previous operation, which is how NSOutlineView processes calls inside
/// `beginUpdates()` / `endUpdates()`).
@MainActor
protocol OutlineMutationSink: AnyObject {
    /// True when the outline currently shows this item expanded with every ancestor (in the
    /// OLD structure) expanded too, i.e. its children are loaded rows.
    func isLive(_ node: NodeKind) -> Bool
    func insert(at index: Int, in parent: NodeKind?)
    func remove(at index: Int, in parent: NodeKind?)
    func move(from index: Int, in source: NodeKind?, to newIndex: Int, in destination: NodeKind?)
    /// A parent whose children changed while they were not loaded: reload just that item.
    func reloadChildren(of parent: NodeKind)
}

/// Turns "old snapshot → new snapshot" into insert / remove / move calls so the sidebar never
/// needs `reloadData` (a state change touches only the rows that changed).
///
/// Fine-grained operations go only to "live" parents: the root, plus items that exist in both
/// snapshots, are expanded on screen, and whose old AND new parents are live (fixed point).
/// Steps: (1) remove rows that disappear or move under a non-live parent, (2) move rows
/// between live parents, (3) per live parent, walk the target order left to right
/// with moves and inserts, (4) reload changed non-live parents. Left-to-right insertion keeps
/// every inserted index equal to its final index, so the data source (already reporting the
/// new snapshot) answers consistently whenever the outline asks.
@MainActor
enum OutlineDiffer {
    static func apply(from old: SidebarSnapshot, to new: SidebarSnapshot, sink: OutlineMutationSink) {
        let oldParents = old.parentMap()
        let newParents = new.parentMap()

        // Live parents (fixed point over both structures).
        var live = Set<NodeKind>()
        for (node, _) in old.allNodes() where newParents[node] != nil && sink.isLive(node) { live.insert(node) }
        func inLive(_ parent: NodeKind?) -> Bool { parent.map(live.contains) ?? true }
        var changed = true
        while changed {
            changed = false
            for node in live {
                let oldParent = oldParents[node] ?? nil
                let newParent = newParents[node] ?? nil
                if !inLive(oldParent) || !inLive(newParent) {
                    live.remove(node)
                    changed = true
                }
            }
        }
        // Deterministic order: root first, then old pre-order.
        let liveParents: [NodeKind?] = [nil] + old.allNodes().map(\.node).filter(live.contains).map { Optional($0) }

        var work: [AnyNodeKey: [NodeKind]] = [:]
        for p in liveParents { work[key(p)] = old.childrenOf(p) }

        // 1. Removals: gone from the new tree, or now under a parent that is not live.
        for p in liveParents {
            var kids = work[key(p)] ?? []
            for index in kids.indices.reversed() {
                let child = kids[index]
                let keep: Bool
                if let newParent = newParents[child] { keep = newParent == p || inLive(newParent) } else { keep = false }
                if !keep {
                    sink.remove(at: index, in: p)
                    kids.remove(at: index)
                }
            }
            work[key(p)] = kids
        }

        // 2. Cross-parent moves between live parents, inserted after the rows that precede
        //    them in the new order (step 3 fixes whatever is still out of place).
        for p in liveParents {
            var index = 0
            while index < (work[key(p)] ?? []).count {
                let child = (work[key(p)] ?? [])[index]
                guard let target = newParents[child], target != p else { index += 1; continue }
                let targetOrder = new.childrenOf(target)
                let rank = targetOrder.firstIndex(of: child) ?? Int.max
                let destination = (work[key(target)] ?? []).filter { (targetOrder.firstIndex(of: $0) ?? Int.max) < rank }.count
                sink.move(from: index, in: p, to: destination, in: target)
                work[key(p)]?.remove(at: index)
                work[key(target), default: []].insert(child, at: destination)
            }
        }

        // 3. Order + inserts per live parent.
        for p in liveParents {
            let target = new.childrenOf(p)
            var kids = work[key(p)] ?? []
            for (i, node) in target.enumerated() {
                if i < kids.count, kids[i] == node { continue }
                if let j = kids.firstIndex(of: node) {
                    sink.move(from: j, in: p, to: i, in: p)
                    kids.remove(at: j)
                    kids.insert(node, at: i)
                } else {
                    sink.insert(at: i, in: p)
                    kids.insert(node, at: i)
                }
            }
            while kids.count > target.count { // defensive: unreachable when steps 1–2 are right
                sink.remove(at: kids.count - 1, in: p)
                kids.removeLast()
            }
            work[key(p)] = kids
        }

        // 4. Parents present in both trees whose children are not loaded rows.
        for (node, _) in new.allNodes() where oldParents[node] != nil && !live.contains(node) {
            if old.childrenOf(node) != new.childrenOf(node) { sink.reloadChildren(of: node) }
        }
    }

    private static func key(_ parent: NodeKind?) -> AnyNodeKey { parent.map(AnyNodeKey.node) ?? .root }
}

/// Hashable stand-in for an optional parent (root = `.root`).
enum AnyNodeKey: Hashable {
    case root
    case node(NodeKind)
}
