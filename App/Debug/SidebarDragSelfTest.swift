#if DEBUG
import AppKit
import CoddCore

/// `-codd-sidebar-drag-test YES` (M4 sidebar-dnd): every kind of sidebar drag through the real
/// drop path on the real store, with no posted events. Each drag checks the data source as AppKit
/// sees it (the Objective-C selectors, a pasteboard writer for the row), starts like AppKit's
/// `willBeginAt` (`beginDrag`), then hands a `SyntheticDraggingInfo` held at a row to the
/// outline's own `draggingUpdated` / `performDragOperation`: AppKit proposes, `validateDrop`
/// plans from the pointer (the amber line must show, on top of the rows), `acceptDrop` moves.
/// Then the model order, the outline (`OutlineSelfTest.mismatch`) and layout.json are checked.
/// Covered: sessions within their project (down onto the next row, back up onto the project
/// head), projects within a group, into another group, into and out of 未分類, groups among
/// groups; folders from Finder (a plain file has no target, a mixed drop between two projects,
/// the same folder again = revealed and selected, a drop outside the groups = where 新增專案
/// puts it). Logs `DRAGTEST <name> ok|FAIL <detail>` and `DRAGTESTS ok=<n> fail=<m>`.
///
/// Test data roots only (`-codd-data-root`): it reorders the layout and adds projects for
/// folders it creates under `<dataRoot>/drag-test/`. The seeded M2 layout
/// (`scripts/m2-fixtures/seed-layout.sh`) has every case; a kind with too few rows is skipped.
@MainActor
struct SidebarDragSelfTest {
    let app: AppDelegate

    private final class Tally {
        var ok = 0
        var fail = 0
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            if passed { ok += 1 } else { fail += 1 }
            HolderSessionStore.printLog("DRAGTEST \(name) \(passed ? "ok" : "FAIL") \(detail())")
        }
    }

    func run() async {
        guard let holders = app.holderStore, let main = app.mainWindow, main.window != nil else {
            HolderSessionStore.printLog("DRAGTESTS skipped: real mode with a main window only")
            return
        }
        guard app.realOptions.dataRoot != nil else {
            HolderSessionStore.printLog("DRAGTESTS skipped: needs -codd-data-root (it changes the layout)")
            return
        }
        let sidebar = main.sidebar
        let tally = Tally()
        sidebar.setMode(.tree)
        sidebar.setFilter("")
        sidebar.applyNow()
        checkDataSource(sidebar, tally)
        sessions(sidebar, holders, tally)
        projects(sidebar, holders, tally)
        groups(sidebar, holders, tally)
        persisted(holders, tally)
        folders(sidebar, holders, tally)
        tally.check("outline", OutlineSelfTest.mismatch(sidebar) == nil, OutlineSelfTest.mismatch(sidebar) ?? "")
        HolderSessionStore.printLog("DRAGTEST order " + orderLine(holders))
        HolderSessionStore.printLog("DRAGTESTS ok=\(tally.ok) fail=\(tally.fail)")
        app.scheduleStateDump()
    }

    /// The order a relaunch must show (the e2e compares it with the next launch's dump).
    func orderLine(_ holders: HolderSessionStore) -> String {
        holders.groups.map { group in
            "\(group.id)[" + group.projectIDs.map { pid in
                "\(pid)(" + (holders.project(pid)?.sessionIDs.joined(separator: ",") ?? "") + ")"
            }.joined(separator: ",") + "]"
        }.joined(separator: " ")
    }

    // MARK: Source side

    /// AppKit only drags when it sees the data source's selectors (an `@objc` witness).
    private func checkDataSource(_ sidebar: SidebarViewController, _ tally: Tally) {
        guard let source = sidebar.outline.dataSource else { tally.check("dataSource", false, "none"); return }
        let selectors = [
            #selector(NSOutlineViewDataSource.outlineView(_:pasteboardWriterForItem:)),
            #selector(NSOutlineViewDataSource.outlineView(_:draggingSession:willBeginAt:forItems:)),
            #selector(NSOutlineViewDataSource.outlineView(_:draggingSession:endedAt:operation:)),
            #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:)),
            #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:)),
        ]
        let missing = selectors.filter { !source.responds(to: $0) }
        tally.check("dataSource", missing.isEmpty, missing.map { NSStringFromSelector($0) }.joined(separator: " "))
        let types = sidebar.outline.registeredDraggedTypes
        tally.check("registered", SidebarDrag.acceptedTypes.allSatisfy(types.contains), types.map(\.rawValue).joined(separator: ","))
    }

    /// The row can be dragged (a pasteboard writer through the data source), then `willBeginAt`.
    private func start(_ sidebar: SidebarViewController, _ nodes: [NodeKind]) -> Bool {
        guard let source = sidebar.outline.dataSource else { return false }
        let writers = nodes.compactMap { source.outlineView?(sidebar.outline, pasteboardWriterForItem: sidebar.item(for: $0)) }
        guard writers.count == nodes.count else { return false }
        sidebar.beginDrag(nodes)
        return true
    }

    /// One drag of our own rows to `fraction` of `target`'s row; nil when the row is not shown.
    private func drag(_ sidebar: SidebarViewController, _ nodes: [NodeKind], to target: NodeKind,
                      fraction: CGFloat) -> SyntheticDropResult? {
        sidebar.applyNow()
        guard start(sidebar, nodes) else { return nil }
        defer { sidebar.endDrag() }
        guard let info = sidebar.syntheticInfo(at: target, fraction: fraction, ownRows: true) else { return nil }
        defer { info.release() }
        return sidebar.syntheticDrop(info)
    }

    private func open(_ sidebar: SidebarViewController, _ holders: HolderSessionStore, project: ProjectVM) {
        if holders.group(project.groupID)?.isCollapsed == true { holders.setCollapsed(false, group: project.groupID) }
        if project.isCollapsed { holders.setCollapsed(false, project: project.id) }
        sidebar.applyNow()
        sidebar.syncExpansion(animated: false)
    }

    // MARK: Sessions

    /// Every project in tree order.
    private func allProjects(_ holders: HolderSessionStore) -> [ProjectVM] {
        holders.groups.flatMap(\.projectIDs).compactMap { id in holders.project(id) }
    }

    private func coddSessions(_ project: ProjectVM, _ holders: HolderSessionStore) -> [SessionID] {
        project.sessionIDs.filter { holders.session($0)?.external == false }
    }

    private func sessions(_ sidebar: SidebarViewController, _ holders: HolderSessionStore, _ tally: Tally) {
        func candidate() -> ProjectVM? {
            allProjects(holders).first { coddSessions($0, holders).count >= 2 }
        }
        if candidate() == nil, let project = allProjects(holders)
            .first(where: { !holders.archivedSessions(inProject: $0.id).isEmpty && !coddSessions($0, holders).isEmpty }) {
            // The seeded layout has one archived session next to a live one: two to reorder.
            holders.unarchive(holders.archivedSessions(inProject: project.id).map(\.id))
        }
        guard let project = candidate() else { tally.check("sessions", true, "skipped: no project with two CODD sessions"); return }
        open(sidebar, holders, project: project)
        let before = coddSessions(project, holders)
        let first = before[0]
        let last = before[before.count - 1]
        // Down onto the last row's lower half: after it (AppKit proposes "on" that row).
        let down = drag(sidebar, [.session(first, .tree)], to: .session(last, .tree), fraction: 0.7)
        let expected = Array(before.dropFirst()) + [first]
        tally.check("sessions.down", down?.operation == .move && down?.lineShown == true && down?.performed == true
                        && coddSessions(project, holders) == expected,
                    "op=\(down?.operation.rawValue ?? 0) line=\(down?.lineShown ?? false) order=\(coddSessions(project, holders))")
        // Back up onto the project's head: the top of its list.
        let up = drag(sidebar, [.session(first, .tree)], to: .project(project.id), fraction: 0.5)
        tally.check("sessions.up", up?.performed == true && coddSessions(project, holders) == before,
                    "order=\(coddSessions(project, holders))")
        // Never into another project.
        if let other = allProjects(holders).first(where: { $0.id != project.id }) {
            open(sidebar, holders, project: other)
            let refused = drag(sidebar, [.session(first, .tree)], to: .project(other.id), fraction: 0.5)
            tally.check("sessions.otherProject", refused?.operation.isEmpty == true && project.sessionIDs.contains(first),
                        "op=\(refused?.operation.rawValue ?? 0)")
        }
    }

    // MARK: Projects

    private func saved(_ group: GroupVM, _ holders: HolderSessionStore) -> [ProjectID] {
        group.projectIDs.filter { holders.project($0)?.isTransient == false }
    }

    private func projects(_ sidebar: SidebarViewController, _ holders: HolderSessionStore, _ tally: Tally) {
        // Within a group: the first one dropped on the last one's lower half goes last.
        if let group = holders.groups.first(where: { saved($0, holders).count >= 2 }) {
            if group.isCollapsed { holders.setCollapsed(false, group: group.id) }
            let before = saved(group, holders)
            let first = before[0]
            let lastRow = sidebar.lastVisibleRow(of: .project(before[before.count - 1]))
            let result = drag(sidebar, [.project(first)], to: lastRow, fraction: 0.8)
            let expected = Array(before.dropFirst()) + [first]
            tally.check("projects.withinGroup", result?.performed == true && result?.lineShown == true && saved(group, holders) == expected,
                        "order=\(saved(group, holders))")
        } else {
            tally.check("projects.withinGroup", true, "skipped: no group with two projects")
        }
        // Into another group: dropped on its head, it lands after that group's projects (移入).
        let groups = holders.groups
        if let from = groups.first(where: { !$0.isUngrouped && !saved($0, holders).isEmpty }),
           let into = groups.first(where: { !$0.isUngrouped && $0.id != from.id }) {
            let moving = saved(from, holders)[0]
            let result = drag(sidebar, [.project(moving)], to: .group(into.id), fraction: 0.5)
            tally.check("projects.intoGroup", result?.performed == true && result?.targetBlock == .group(into.id)
                            && saved(into, holders).last == moving && holders.project(moving)?.groupID == into.id,
                        "block=\(String(describing: result?.targetBlock)) group=\(holders.project(moving)?.groupID ?? "-")")
            // Into 未分類 and back out: over its first project's upper half / onto the user group's head.
            if let ungrouped = groups.last(where: \.isUngrouped) {
                let target: NodeKind = saved(ungrouped, holders).first.map { .project($0) } ?? .group(ungrouped.id)
                let out = drag(sidebar, [.project(moving)], to: target, fraction: 0.2)
                let landed = holders.project(moving)?.groupID == ungrouped.id
                tally.check("projects.intoUngrouped", out?.performed == true && landed
                                && (saved(ungrouped, holders).first == moving || target == .group(ungrouped.id)),
                            "group=\(holders.project(moving)?.groupID ?? "-") order=\(saved(ungrouped, holders))")
                if let loose = saved(ungrouped, holders).first(where: { $0 != moving }) ?? saved(ungrouped, holders).first {
                    let back = drag(sidebar, [.project(loose)], to: .group(from.id), fraction: 0.5)
                    tally.check("projects.outOfUngrouped", back?.performed == true && holders.project(loose)?.groupID == from.id,
                                "group=\(holders.project(loose)?.groupID ?? "-")")
                }
            }
        } else {
            tally.check("projects.intoGroup", true, "skipped: fewer than two user groups")
        }
    }

    // MARK: Groups

    private func groups(_ sidebar: SidebarViewController, _ holders: HolderSessionStore, _ tally: Tally) {
        let users = holders.groups.filter { !$0.isUngrouped }
        guard users.count >= 2 else { tally.check("groups", true, "skipped: fewer than two user groups"); return }
        let before = users.map(\.id)
        let first = before[0]
        // Down: the first group over the last group's last row → after it.
        let down = drag(sidebar, [.group(first)], to: sidebar.lastVisibleRow(of: .group(before[before.count - 1])), fraction: 0.8)
        let expected = Array(before.dropFirst()) + [first]
        let afterDown = holders.groups.filter { !$0.isUngrouped }.map(\.id)
        tally.check("groups.down", down?.performed == true && down?.lineShown == true && afterDown == expected, "order=\(afterDown)")
        // Up: back over the (new) first group's head → before it; 未分類 stays last.
        let up = drag(sidebar, [.group(first)], to: .group(expected[0]), fraction: 0.3)
        let afterUp = holders.groups.map(\.id)
        tally.check("groups.up", up?.performed == true && afterUp.prefix(before.count) == ArraySlice(before)
                        && holders.groups.last?.isUngrouped == true, "order=\(afterUp)")
    }

    // MARK: Persistence

    /// layout.json read back the way the next launch reads it gives the same order.
    private func persisted(_ holders: HolderSessionStore, _ tally: Tally) {
        holders.flushLayout()
        guard let layout = try? LayoutStore(fileURL: holders.root.layoutURL).load() else {
            tally.check("persisted", false, "layout.json unreadable")
            return
        }
        let model = LayoutMapping.model(from: layout)
        let savedGroups = holders.groups.map { group in
            (group.id, group.projectIDs.filter { holders.project($0)?.isTransient == false })
        }
        let loadedGroups = model.groups.map { ($0.id, $0.projectIDs) }
        let groupsMatch = savedGroups.map(\.0) == loadedGroups.map(\.0) && savedGroups.map(\.1) == loadedGroups.map(\.1)
        let sessionsMatch = model.projects.values.allSatisfy { loaded in
            let written = Set(loaded.sessionIDs)
            return (holders.project(loaded.id)?.sessionIDs.filter(written.contains) ?? []) == loaded.sessionIDs
        }
        tally.check("persisted", groupsMatch && sessionsMatch, "groups=\(groupsMatch) sessions=\(sessionsMatch)")
    }

    // MARK: Folders from Finder

    private func folders(_ sidebar: SidebarViewController, _ holders: HolderSessionStore, _ tally: Tally) {
        let base = URL(fileURLWithPath: holders.root.path).appendingPathComponent("drag-test", isDirectory: true)
        let alpha = base.appendingPathComponent("alpha", isDirectory: true)
        let beta = base.appendingPathComponent("beta", isDirectory: true)
        let gamma = base.appendingPathComponent("gamma", isDirectory: true)
        let note = base.appendingPathComponent("note.txt")
        do {
            for folder in [alpha, beta, gamma] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
            try Data("drag test\n".utf8).write(to: note)
        } catch {
            tally.check("folders", false, "cannot create test folders: \(error)")
            return
        }
        func drop(_ urls: [URL], on node: NodeKind, fraction: CGFloat) -> SyntheticDropResult? {
            sidebar.applyNow()
            guard let info = sidebar.syntheticInfo(at: node, fraction: fraction, ownRows: false, fileURLs: urls) else { return nil }
            defer { info.release() }
            return sidebar.syntheticDrop(info)
        }
        // A plain file has no drop target.
        let fileOnly = drop([note], on: .addGroup, fraction: 0.5)
        tally.check("folders.plainFile", fileOnly?.operation.isEmpty == true && fileOnly?.performed == false,
                    "op=\(fileOnly?.operation.rawValue ?? 0)")
        // Folders (plus a file) between the first two projects of a group: at that position, in order.
        guard let group = holders.groups.first(where: { !$0.isUngrouped && !saved($0, holders).isEmpty }) else {
            tally.check("folders", true, "skipped: no user group with a project")
            return
        }
        if group.isCollapsed { holders.setCollapsed(false, group: group.id) }
        let before = saved(group, holders)
        let mixed = drop([alpha, note, beta], on: .project(before[0]), fraction: 0.1)
        let after = saved(group, holders)
        let alphaID = holders.project(forPath: alpha.path)?.id
        let betaID = holders.project(forPath: beta.path)?.id
        tally.check("folders.betweenProjects", mixed?.operation == .copy && mixed?.performed == true && mixed?.lineShown == true
                        && alphaID != nil && betaID != nil && after == [alphaID, betaID].compactMap { $0 } + before,
                    "order=\(after)")
        // The same folder again (outside the groups): not added, revealed and selected.
        let count = holders.groups.flatMap(\.projectIDs).count
        let again = drop([alpha], on: .addGroup, fraction: 0.5)
        let selected = sidebar.outline.selectedRowIndexes.compactMap { sidebar.kind(atRow: $0) }
        tally.check("folders.duplicate", again?.performed == true && holders.groups.flatMap(\.projectIDs).count == count
                        && alphaID.map { selected.contains(.project($0)) } == true, "selected=\(selected)")
        // Outside the groups: where 新增專案 puts a new project (未分類).
        let outside = drop([gamma], on: .addGroup, fraction: 0.5)
        let gammaProject = holders.project(forPath: gamma.path)
        tally.check("folders.outsideGroups", outside?.performed == true && outside?.lineShown == false
                        && gammaProject.flatMap { holders.group($0.groupID)?.isUngrouped } == true,
                    "group=\(gammaProject?.groupID ?? "-")")
    }
}

/// `-codd-drop-folders <path>` (repeatable) with `-codd-drop-folders-group <group id | name |
/// ungrouped>` and `-codd-drop-folders-index <n>` (M4 e2e): those folders dropped on the sidebar
/// as Finder would drop them (a synthetic drag through the outline's own drop path): on the
/// group's head, or before its n-th project; without a group, below the groups (where 新增專案
/// puts them). Logs `debug drop-folders op=… accepted=… added=… existing=…`.
@MainActor
enum SidebarFolderDropHook {
    static func run(app: AppDelegate, paths: [String], group wanted: String?, index: Int?) {
        guard let holders = app.holderStore, let main = app.mainWindow else {
            HolderSessionStore.printLog("debug drop-folders skipped: real mode with a main window only")
            return
        }
        let sidebar = main.sidebar
        sidebar.setMode(.tree)
        sidebar.setFilter("")
        sidebar.applyNow()
        let group = wanted.flatMap { name in
            holders.groups.first { $0.id == name || $0.name == name || (name == "ungrouped" && $0.isUngrouped) }
        }
        if let group, group.isCollapsed {
            holders.setCollapsed(false, group: group.id)
            sidebar.applyNow()
            sidebar.syncExpansion(animated: false)
        }
        var target: (node: NodeKind, fraction: CGFloat) = (.addGroup, 0.5)
        if let group {
            let saved = group.projectIDs.filter { holders.project($0)?.isTransient == false }
            if let index, saved.indices.contains(index) {
                // Upper part of that project's head: before it.
                target = (.project(saved[index]), 0.1)
            } else if index != nil, let last = saved.last {
                // Lower part of the last project's block: after it.
                target = (sidebar.lastVisibleRow(of: .project(last)), 0.9)
            } else {
                target = (.group(group.id), 0.5)
            }
        }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        guard let info = sidebar.syntheticInfo(at: target.node, fraction: target.fraction, ownRows: false, fileURLs: urls) else {
            HolderSessionStore.printLog("debug drop-folders target not shown")
            return
        }
        defer { info.release() }
        let result = sidebar.syntheticDrop(info)
        let drop = sidebar.lastDrop ?? [:]
        HolderSessionStore.printLog("debug drop-folders op=\(result.operation.rawValue) accepted=\(result.performed) "
            + "added=\(drop["added"] as? Int ?? 0) existing=\(drop["existing"] as? Int ?? 0) group=\(group?.id ?? "-")")
        app.scheduleStateDump()
    }
}
#endif
