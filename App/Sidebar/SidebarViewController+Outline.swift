import AppKit
import CoddUI

/// Data source + delegate: answers from the current snapshot, fixed row heights per kind,
/// reused row and cell views.
extension SidebarViewController: NSOutlineViewDataSource, NSOutlineViewDelegate {
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("row")

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        snapshot.childrenOf((item as? SidebarItem)?.kind).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let kids = snapshot.childrenOf((item as? SidebarItem)?.kind)
        // Out of range never happens with a consistent diff; answer something valid anyway.
        return self.item(for: kids.indices.contains(index) ? kids[index] : .addGroup)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let kind = (item as? SidebarItem)?.kind else { return false }
        switch kind {
        case .section, .group, .project: return !snapshot.childrenOf(kind).isEmpty
        default: return false
        }
    }

    // Do NOT implement `outlineView(_:shouldShowOutlineCellForItem:)` returning false to hide
    // the disclosure triangles: NSOutlineView then refuses every collapse (expand still works).
    // The triangles are hidden by `SidebarOutlineView.frameOfOutlineCell(atRow:)` instead, and
    // the cells draw their own `▸` carets.

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let kind = (item as? SidebarItem)?.kind else { return Metrics.sessionRowHeight }
        switch kind {
        case .section: return Metrics.sectionHeaderHeight
        case .group: return Metrics.groupHeaderHeight + Metrics.groupGap
        case .project: return Metrics.projectRowHeight
        case .session: return Metrics.sessionRowHeight
        case .doneSummary: return Metrics.doneRowHeight
        case .emptyProject: return Metrics.emptyProjectRowHeight
        case .addGroup: return Metrics.addGroupRowHeight
        case .newGroup: return NewGroupCellView.rowHeight
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = outlineView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? SidebarRowView ?? {
            let made = SidebarRowView()
            made.identifier = Self.rowIdentifier
            return made
        }()
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let kind = (item as? SidebarItem)?.kind else { return nil }
        let cell: SidebarCellView
        switch kind {
        case .session: cell = reuse(SessionCellView.identifier) { SessionCellView() }
        case .group: cell = reuse(GroupHeaderCellView.identifier) { GroupHeaderCellView() }
        case .project: cell = reuse(ProjectCellView.identifier) { ProjectCellView() }
        case .section: cell = reuse(SectionHeaderCellView.identifier) { SectionHeaderCellView() }
        case .doneSummary: cell = reuse(DoneSummaryCellView.identifier) { DoneSummaryCellView() }
        case .emptyProject: cell = reuse(EmptyProjectCellView.identifier) { EmptyProjectCellView() }
        case .addGroup: cell = reuse(AddGroupCellView.identifier) { AddGroupCellView() }
        case .newGroup: cell = reuse(NewGroupCellView.identifier) { NewGroupCellView() }
        }
        cell.bind(kind, env: env)
        return cell
    }

    private func reuse<T: SidebarCellView>(_ identifier: NSUserInterfaceItemIdentifier, make: () -> T) -> T {
        outline.makeView(withIdentifier: identifier, owner: nil) as? T ?? make()
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? SidebarRowView else { return }
        decorate(rowView, row: row)
        // Neighbours may change their block edge when rows are inserted next to them.
        for neighbour in [row - 1, row + 1] where neighbour >= 0 && neighbour < outlineView.numberOfRows {
            if let view = outlineView.rowView(atRow: neighbour, makeIfNecessary: false) as? SidebarRowView {
                decorate(view, row: neighbour)
            }
        }
    }

    // MARK: Selection (sessions only)

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarItem)?.kind.sessionID != nil
    }

    func outlineView(_ outlineView: NSOutlineView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        IndexSet(proposed.filter { kind(atRow: $0)?.sessionID != nil })
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        selectionChanged()
    }

    // MARK: Expansion (keep the model in sync with keyboard / option-click expansion)

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        if !wantsExpanded(item.kind) { setModelExpanded(item.kind, true) }
        syncExpansion(animated: false, under: item.kind)
        refreshBlockEdges()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let item = notification.userInfo?["NSObject"] as? SidebarItem else { return }
        if wantsExpanded(item.kind) { setModelExpanded(item.kind, false) }
        refreshBlockEdges()
    }

    private func setModelExpanded(_ kind: NodeKind, _ expanded: Bool) {
        switch kind {
        case .section(let s):
            if expanded { shell.collapsedSections.remove(s) } else { shell.collapsedSections.insert(s) }
        case .group(let id): store.setCollapsed(!expanded, group: id)
        case .project(let id): store.setCollapsed(!expanded, project: id)
        default: break
        }
    }
}
