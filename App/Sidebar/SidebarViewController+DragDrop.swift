import AppKit
import CoddUI

enum SidebarDrag {
    /// In-app drag type (the payload is only a marker; the dragged nodes live in the controller).
    static let pasteboardType = NSPasteboard.PasteboardType(CoddIdentity.label("sidebar-node"))
    /// What the list (and its scroll view's insets) take: our rows and files from Finder.
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [pasteboardType, .fileURL]
}

/// Drag & drop: sessions reorder within their project, projects move between groups, groups
/// reorder (SidebarStates A), and folders dragged in from Finder become projects. The drop
/// position is an amber 2 px line with a 6 px square end (`.ss-dropline`), the target group block
/// is highlighted (`.gblk.drop`) and says `移入`, the dragged rows leave a dashed ghost and travel
/// as a lifted image (`.ss-lift`). Drags start after AppKit's own drag threshold and are disabled
/// while a filter is active (indices would not map 1:1 to the model) or in the STATE view.
///
/// Where a drop lands comes from the pointer (`DropPointer`), not from AppKit's proposal: AppKit
/// proposes "on the row" for the middle of every row and names the deepest row under the
/// pointer, which made most mouse drops land where the row already was or be refused (the M3
/// user report). `validateDrop` and `acceptDrop` plan the same way, so the line shows exactly
/// what a drop does.
extension SidebarViewController: SidebarScrollDropTarget {
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard shell.filterText.isEmpty, shell.sidebarMode == .tree, let kind = (item as? SidebarItem)?.kind else { return nil }
        switch kind {
        case .session(let id, .tree):
            // D6: externals are read-only and never reordered.
            guard store.session(id)?.external == false else { return nil }
        case .project(let id):
            // A transient project is not CODD's: it cannot move until it is added.
            guard store.project(id)?.isTransient == false else { return nil }
        case .group(let id):
            guard store.group(id)?.isUngrouped == false else { return nil }
        default:
            return nil
        }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("node", forType: SidebarDrag.pasteboardType)
        return pasteboardItem
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        beginDrag(draggedItems.compactMap { ($0 as? SidebarItem)?.kind })
        let nodes = draggedNodes
        session.enumerateDraggingItems(options: [], for: outline, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, index, _ in
            MainActor.assumeIsolated {
                guard nodes.indices.contains(index), let lifted = self.liftedImage(for: nodes[index]) else { return }
                item.setDraggingFrame(lifted.frame, contents: lifted.image)
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        endDrag()
    }

    /// The rows a drag carries (AppKit's `willBeginAt`; the DEBUG drag self-test calls it directly
    /// since it starts no real dragging session): no hover card, the ghost on their slots.
    func beginDrag(_ nodes: [NodeKind]) {
        draggedNodes = nodes
        hoverCard.hide()
        dragGhostEdges = ghostEdges(for: draggedNodes)
        refreshBlockEdges()
    }

    /// DEBUG snapshots (`-codd-drag-preview`): the decorations of a project drag over a group, as
    /// AppKit would have them mid-drag (nothing moves).
    func previewDrag(project: ProjectID, over group: GroupID) {
        let dragged = [NodeKind.project(project)]
        guard let plan = DropPlanner.plan(dragged: dragged, parent: .group(group), index: -1, snapshot: snapshot, store: store) else { return }
        draggedNodes = dragged
        dragGhostEdges = ghostEdges(for: dragged)
        dropTargetBlock = .group(group)
        refreshBlockEdges()
        showDropLine(for: plan)
    }

    /// Clears every drag decoration (line, ghost, target block).
    func endDrag() {
        draggedNodes = []
        clearDropFeedback()
        if !dragGhostEdges.isEmpty {
            dragGhostEdges = [:]
            refreshBlockEdges()
        }
    }

    /// The pointer left the list (or a Finder drag ended): no line, no target block. A drag of
    /// our own rows keeps its ghost until it ends.
    func clearDropFeedback() {
        dropPlan = nil
        dropTargetBlock = nil
        dropLine.isHidden = true
    }

    /// The ghost of each dragged row; a dragged project's visible sessions share its dashed outline.
    func ghostEdges(for dragged: [NodeKind]) -> [NodeKind: BlockEdge] {
        var out: [NodeKind: BlockEdge] = [:]
        for node in dragged {
            var run = [node]
            if case .project = node, wantsExpanded(node) { run += snapshot.childrenOf(node) }
            for (i, member) in run.enumerated() {
                switch (i == 0, i == run.count - 1) {
                case (true, true): out[member] = .single
                case (true, false): out[member] = .top
                case (false, true): out[member] = .bottom
                case (false, false): out[member] = .middle
                }
            }
        }
        return out
    }

    /// `.ss-lift`: the row (a project with its visible sessions) on `--bg-lift`, a 1 px
    /// `--line-bright` ring and `0 6px 24px rgba(0,0,0,.6)`; the frame in outline coordinates.
    func liftedImage(for node: NodeKind) -> (image: NSImage, frame: CGRect)? {
        let first = outline.row(forItem: item(for: node))
        guard first >= 0 else { return nil }
        var rows = [first]
        if case .project = node, wantsExpanded(node) {
            for child in snapshot.childrenOf(node) {
                let row = outline.row(forItem: item(for: child))
                if row >= 0 { rows.append(row) }
            }
        }
        var parts: [(rep: NSBitmapImageRep, height: CGFloat, topGap: CGFloat)] = []
        for row in rows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarCellView,
                  let rep = cell.bitmapImageRepForCachingDisplay(in: cell.bounds) else { continue }
            cell.cacheDisplay(in: cell.bounds, to: rep)
            parts.append((rep, cell.bounds.height, cell.decoration.topGap))
        }
        guard !parts.isEmpty else { return nil }
        let margin: CGFloat = 18
        let inset = Metrics.sidebarInset
        let width = outline.bounds.width - inset * 2
        let height = parts.reduce(0) { $0 + $1.height - $1.topGap }
        let size = CGSize(width: width + margin * 2, height: height + margin * 2)
        let image = NSImage(size: size, flipped: true) { _ in
            let card = CGRect(x: margin, y: margin, width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            shadow.shadowBlurRadius = 24
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            Draw.fill(card, Palette.bgLift)
            NSGraphicsContext.restoreGraphicsState()
            var y = margin
            for part in parts {
                let source = CGRect(x: 0, y: part.topGap, width: part.rep.size.width, height: part.height - part.topGap)
                let target = CGRect(x: margin - inset, y: y, width: part.rep.size.width, height: part.height - part.topGap)
                part.rep.draw(in: target, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                y += part.height - part.topGap
            }
            Draw.strokeRect(card, color: Palette.lineBright)
            return true
        }
        let rowRect = outline.rect(ofRow: first)
        let frame = CGRect(x: rowRect.minX + inset - margin, y: rowRect.minY + parts[0].topGap - margin, width: size.width, height: size.height)
        return (image, frame)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let planned = plannedDrop(for: info) else {
            clearDropFeedback()
            return []
        }
        let plan = planned.plan
        let proposedParent = (item as? SidebarItem)?.kind
        if plan.parent != proposedParent || plan.childIndex != index {
            outline.setDropItem(plan.parent.map(self.item(for:)), dropChildIndex: plan.childIndex)
        }
        showDropFeedback(for: plan)
        return planned.operation
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        performDrop(info)
    }

    /// What a drag at its current position would do, and the operation to report: our own rows
    /// move (`.move`), folders from Finder are added (`.copy`); anything else gets no target
    /// (plain files, a drag of rows the rules refuse, mock mode for folders).
    func plannedDrop(for info: NSDraggingInfo) -> (plan: DropPlan, operation: NSDragOperation)? {
        if info.draggingSource as? NSOutlineView === outline {
            guard !draggedNodes.isEmpty,
                  let plan = DropPlanner.plan(dragged: draggedNodes, pointer: dropPointer(info), snapshot: snapshot, store: store)
            else { return nil }
            return (plan, .move)
        }
        guard store.canAddProjects, !droppedFolders(info).isEmpty else { return nil }
        // Positions map 1:1 to the model only in the unfiltered tree (like our own drags).
        let positional = shell.sidebarMode == .tree && shell.filterText.isEmpty
        let plan = DropPlanner.planFolders(pointer: positional ? dropPointer(info) : nil, snapshot: snapshot, store: store)
        let mask = info.draggingSourceOperationMask
        return (plan, mask.contains(.copy) ? .copy : mask.contains(.link) ? .link : .generic)
    }

    /// Carries out the drop at the pointer (AppKit's `acceptDrop`, the scroll view's insets).
    @discardableResult
    func performDrop(_ info: NSDraggingInfo) -> Bool {
        let ownRows = info.draggingSource as? NSOutlineView === outline
        defer { if ownRows { endDrag() } else { clearDropFeedback() } }
        guard let plan = plannedDrop(for: info)?.plan else {
            lastDrop = ["kind": ownRows ? "rows" : "folders", "accepted": false]
            return false
        }
        switch plan.target {
        case .sessions(let project, let i):
            store.moveSessions(draggedNodes.compactMap(\.sessionID), toIndex: i, inProject: project)
        case .projects(let group, let i):
            let ids = draggedNodes.compactMap { node -> ProjectID? in
                if case .project(let id) = node { return id }
                return nil
            }
            store.moveProjects(ids, toGroup: group, atIndex: i)
        case .groups(let i):
            let ids = draggedNodes.compactMap { node -> GroupID? in
                if case .group(let id) = node { return id }
                return nil
            }
            store.moveGroups(ids, toIndex: i)
        case .folders(let group, let i):
            let results = addFolders(droppedFolders(info), toGroup: group, atIndex: i)
            lastDrop = Self.dropObject(plan.target, extra: ["added": results.filter(\.added).count,
                                                            "existing": results.filter { !$0.added && $0.projectID != nil }.count])
            return true
        }
        lastDrop = Self.dropObject(plan.target, extra: ["count": draggedNodes.count])
        applyNow()
        return true
    }

    /// `sidebar.lastDrop` in the state dump (DEBUG / e2e).
    static func dropObject(_ target: DropTarget, extra: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["accepted": true]
        switch target {
        case .sessions(let project, let i): out.merge(["kind": "sessions", "project": project, "index": i]) { _, new in new }
        case .projects(let group, let i): out.merge(["kind": "projects", "group": group, "index": i]) { _, new in new }
        case .groups(let i): out.merge(["kind": "groups", "index": i]) { _, new in new }
        case .folders(let group, let i):
            out.merge(["kind": "folders", "group": group.map { $0 as Any } ?? NSNull(),
                       "index": i.map { $0 as Any } ?? NSNull()]) { _, new in new }
        }
        return out.merging(extra) { _, new in new }
    }

    /// The pointer over the list's visible rows (what the planner reads).
    func dropPointer(_ info: NSDraggingInfo) -> DropPointer {
        DropPointer(rows: dropRows(), y: outline.convert(info.draggingLocation, from: nil).y)
    }

    /// The outline's rows as they are on screen right now (expansion included).
    func dropRows() -> [DropRow] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = kind(atRow: row) else { return nil }
            let rect = outline.rect(ofRow: row)
            return DropRow(node: node, depth: outline.level(forRow: row), minY: rect.minY, maxY: rect.maxY)
        }
    }

    /// The folders a drag carries (cached per drag: `validateDrop` runs on every pointer move).
    func droppedFolders(_ info: NSDraggingInfo) -> [String] {
        if let cached = folderDropCache, cached.sequence == info.draggingSequenceNumber { return cached.paths }
        let paths = FolderDrop.folderPaths(FolderDrop.fileURLs(on: info.draggingPasteboard))
        folderDropCache = (info.draggingSequenceNumber, paths)
        return paths
    }

    func dropExited() {
        guard dropPlan != nil || !dropLine.isHidden || dropTargetBlock != nil else { return }
        clearDropFeedback()
    }

    func scrollDragUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        guard let planned = plannedDrop(for: info) else {
            clearDropFeedback()
            return []
        }
        showDropFeedback(for: planned.plan)
        return planned.operation
    }

    func scrollDragPerform(_ info: any NSDraggingInfo) -> Bool { performDrop(info) }

    /// The target block (`移入`) and the amber line for a plan.
    func showDropFeedback(for plan: DropPlan) {
        switch plan.target {
        case .projects(let group, _): dropTargetBlock = .group(group)
        case .folders(let group?, _): dropTargetBlock = .group(group)
        default: dropTargetBlock = nil
        }
        showDropLine(for: plan)
    }

    /// Puts the amber line at the plan's gap: above the child it lands before, else under the
    /// last visible row of the parent's subtree. A folder drop outside the groups has no line.
    func showDropLine(for plan: DropPlan) {
        dropPlan = plan
        if case .folders(nil, _) = plan.target { dropLine.isHidden = true; return }
        let rows = snapshot.visibleRows(expanded: wantsExpanded)
        guard let position = DropIndicator.position(parent: plan.parent, childIndex: plan.childIndex, snapshot: snapshot, rows: rows)
        else { dropLine.isHidden = true; return }
        let row = outline.row(forItem: item(for: position.anchor))
        guard row >= 0 else { dropLine.isHidden = true; return }
        let rect = outline.rect(ofRow: row)
        // Below the last row of a block: just inside it, not on its border.
        var y = position.below ? rect.maxY - DropLineView.height / 2 : rect.minY
        if !position.below, case .group = position.anchor { y += Metrics.groupGap / 2 }
        let left: CGFloat
        switch plan.target {
        case .groups: left = Metrics.sidebarInset + 6
        case .projects, .folders: left = Metrics.sidebarInset + 1 + 12
        case .sessions: left = Metrics.sidebarInset + 1 + 26
        }
        dropLine.frame = CGRect(x: left, y: round(y - DropLineView.height / 2), width: max(20, outline.bounds.width - left - 4),
                                height: DropLineView.height)
        // Row views are added above it as rows appear (and an opaque current row hid it): keep
        // the line on top of every row.
        if outline.subviews.last !== dropLine { outline.addSubview(dropLine, positioned: .above, relativeTo: nil) }
        dropLine.isHidden = false
    }

    /// ⌥⇧↑ / ⌥⇧↓ (SPEC §2): moves the single selected session within its project (cwd is
    /// fixed, so never across projects). Beeps at either end, with a filter, or in STATE mode.
    func moveSelected(by offset: Int) {
        let rows = outline.selectedRowIndexes
        guard shell.filterText.isEmpty, shell.sidebarMode == .tree, offset != 0, rows.count == 1, let row = rows.first,
              let node = kind(atRow: row), let id = node.sessionID, let session = store.session(id),
              let project = store.project(session.projectID), let index = project.sessionIDs.firstIndex(of: id)
        else { NSSound.beep(); return }
        let target = index + offset
        guard project.sessionIDs.indices.contains(target) else { NSSound.beep(); return }
        // ListMove indices refer to the original list: moving down lands after the next item.
        store.moveSessions([id], toIndex: offset > 0 ? target + 1 : target, inProject: project.id)
        applyNow()
        let moved = outline.row(forItem: item(for: node))
        if moved >= 0 { outline.scrollRowToVisible(moved) }
    }

    /// Applies the current model immediately (drops animate with `moveItem` right away).
    func applyNow() {
        apply(buildSnapshot())
    }
}

/// Where the drop line goes for a planned drop (pure; the controller turns it into pixels).
enum DropIndicator {
    /// `rows` = the visible rows (pre-order, with depth). Above `parent`'s child at `childIndex`, else
    /// below the last visible row of the last child's subtree, else below the parent itself.
    static func position(parent: NodeKind?, childIndex: Int, snapshot: SidebarSnapshot,
                         rows: [(node: NodeKind, depth: Int)]) -> (anchor: NodeKind, below: Bool)? {
        let kids = snapshot.childrenOf(parent)
        if childIndex >= 0, childIndex < kids.count { return (kids[childIndex], false) }
        guard let last = kids.last ?? parent, let start = rows.firstIndex(where: { $0.node == last }) else { return nil }
        var end = start
        while end + 1 < rows.count, rows[end + 1].depth > rows[start].depth { end += 1 }
        return (rows[end].node, true)
    }
}

/// `.ss-dropline`: a 6 px amber-outlined square at the left, then a 2 px amber line with a glow.
final class DropLineView: NSView {
    static let height: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let glow = NSShadow()
        glow.shadowColor = Palette.amberGlow
        glow.shadowBlurRadius = 8
        glow.shadowOffset = .zero
        shadow = glow
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let square = CGRect(x: 0, y: 0, width: 6, height: 6)
        Draw.fill(square, Palette.bg)
        let path = NSBezierPath(rect: square.insetBy(dx: 0.75, dy: 0.75))
        path.lineWidth = 1.5
        Palette.amber.setStroke()
        path.stroke()
        Draw.fill(CGRect(x: 6, y: 2, width: bounds.width - 6, height: 2), Palette.amber)
    }
}
