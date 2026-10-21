import Foundation

/// One sidebar row as the `sidebar` state dump reports it (M2-PLAN §5, I3): what the row draws,
/// in display order with collapse respected, so scripts can check the STATE view, stale rows and
/// the filter without reading pixels.
struct SidebarDumpRow: Equatable, Sendable {
    /// `section`, `group`, `project`, `session`, `doneSummary`, `emptyProject`, `addGroup`, `newGroup`.
    var kind: String
    var id: String?
    /// Session rows: where the row sits (`tree`, `needsYou`, `pinned`, or a STATE section);
    /// section heads: the section.
    var section: String?
    var title: String
    /// Session rows: line 2 as drawn (`■` = the group color square); projects: their count.
    var line2: String?
    var stale: Bool
    var depth: Int
    /// Section heads: their count; Idle: `1 stale`.
    var count: Int?
    var hint: String?
    var state: String?

    var object: [String: Any] {
        var out: [String: Any] = ["kind": kind, "title": title, "stale": stale, "depth": depth]
        out["id"] = id.map { $0 as Any } ?? NSNull()
        out["section"] = section.map { $0 as Any } ?? NSNull()
        out["line2"] = line2.map { $0 as Any } ?? NSNull()
        if let count { out["count"] = count }
        if let hint { out["hint"] = hint }
        if let state { out["state"] = state }
        return out
    }
}

@MainActor
enum SidebarDump {
    /// The rows of `snapshot` that are on screen (children only under expanded nodes).
    static func rows(snapshot: SidebarSnapshot, store: any SessionStore, shell: ShellState,
                     expanded: (NodeKind) -> Bool, now: Date) -> [SidebarDumpRow] {
        snapshot.visibleRows(expanded: expanded).map { entry in
            row(entry.node, depth: entry.depth, store: store, shell: shell, now: now)
        }
    }

    static func row(_ node: NodeKind, depth: Int, store: any SessionStore, shell: ShellState, now: Date) -> SidebarDumpRow {
        switch node {
        case .section(let section):
            let content = SectionHeaderCellView.content(section, store: store, filter: shell.filterText)
            return SidebarDumpRow(kind: "section", id: section.rawValue, section: section.rawValue, title: section.title, line2: nil,
                                  stale: false, depth: depth, count: content.count, hint: content.hint, state: nil)
        case .group(let id):
            return SidebarDumpRow(kind: "group", id: id, section: nil, title: store.group(id)?.name ?? "", line2: nil, stale: false,
                                  depth: depth, count: nil, hint: nil, state: nil)
        case .project(let id):
            let project = store.project(id)
            return SidebarDumpRow(kind: "project", id: id, section: nil, title: project?.name ?? "",
                                  line2: project.map { ProjectCellView.countText($0, store: store) }, stale: false, depth: depth,
                                  count: nil, hint: nil, state: nil)
        case .session(let id, let context):
            guard let session = store.session(id) else {
                return SidebarDumpRow(kind: "session", id: id, section: context.name, title: "", line2: nil, stale: false, depth: depth,
                                      count: nil, hint: nil, state: nil)
            }
            let line2 = SessionLine2Parts(session: session, context: context, store: store).render(now: now).text
            return SidebarDumpRow(kind: "session", id: id, section: context.name, title: session.title, line2: line2,
                                  stale: session.isStale, depth: depth, count: nil, hint: nil, state: session.state.rawValue)
        case .doneSummary:
            let done = SidebarSnapshotBuilder.unseenDone(store: store, filter: shell.filterText)
            return SidebarDumpRow(kind: "doneSummary", id: done.first?.id, section: SidebarSection.needsYou.rawValue,
                                  title: DoneSummaryCellView.text(done), line2: nil, stale: false, depth: depth, count: done.count,
                                  hint: nil, state: nil)
        case .emptyProject(let id):
            return SidebarDumpRow(kind: "emptyProject", id: id, section: nil, title: store.project(id).map(EmptyProjectCellView.text) ?? "",
                                  line2: nil, stale: false, depth: depth, count: nil, hint: nil, state: nil)
        case .addGroup:
            return SidebarDumpRow(kind: "addGroup", id: nil, section: nil, title: "+ 新增群組", line2: nil, stale: false, depth: depth,
                                  count: nil, hint: nil, state: nil)
        case .newGroup:
            return SidebarDumpRow(kind: "newGroup", id: nil, section: nil, title: "群組名稱", line2: nil, stale: false, depth: depth,
                                  count: nil, hint: nil, state: nil)
        }
    }
}

extension SidebarViewController {
    /// `sidebar {mode, filter, addingGroup, hoverCard, rows [...]}` for `-codd-dump-state`.
    func dumpObject() -> [String: Any] {
        let rows = SidebarDump.rows(snapshot: snapshot, store: store, shell: shell, expanded: wantsExpanded, now: store.clock.now())
        var out: [String: Any] = [
            "mode": shell.sidebarMode == .tree ? "tree" : "state",
            "filter": shell.filterText,
            "addingGroup": newGroupEditor != nil,
            "rows": rows.map(\.object),
        ]
        out["hoverCard"] = hoverCard.shownSessionID.map { $0 as Any } ?? NSNull()
        // M4: the last drop (row move or folders from Finder) and the selected project rows.
        out["lastDrop"] = lastDrop.map { $0 as Any } ?? NSNull()
        out["selectedProjects"] = outline.selectedRowIndexes.compactMap { row -> String? in
            if case .project(let id)? = kind(atRow: row) { return id }
            return nil
        }
        // fb: the latest reveal pulse (a dropped folder, ⌘O) and whether it animated (減少動態).
        out["highlight"] = lastHighlight.map { ["projects": $0.projects, "animated": $0.animated] as [String: Any] } ?? NSNull()
        return out
    }
}
