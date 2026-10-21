import AppKit
import CoddCore
import Darwin
import Foundation
import Testing
@testable import CODD

/// M4 sidebar-dnd: mouse drag reorder planned from the pointer, and folders dropped from Finder.
/// The planner runs on the SPEC §5 mock snapshot with made-up row geometry; the drop path runs on
/// the real `HolderSessionStore` (a temp data root seeded by `scripts/m2-fixtures/seed-layout.sh`)
/// with the real sidebar controller in a window that is never shown, driven by
/// `SyntheticDraggingInfo` through the outline's own `draggingUpdated` / `performDragOperation`
/// (no posted events, no real dragging session, no general pasteboard).

private let repoRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.path
}()

private func makeTemp(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    let path = String(cString: created)
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

// MARK: - Planner (pure)

/// The mock tree's visible rows with fixed heights (section 32, group 27, project 26, session 38).
@MainActor
private func rows(_ snap: SidebarSnapshot, store: MockSessionStore) -> [DropRow] {
    func height(_ node: NodeKind) -> CGFloat {
        switch node {
        case .section: 32
        case .group: 27
        case .project: 26
        case .session: 38
        default: 30
        }
    }
    let visible = snap.visibleRows { node in
        switch node {
        case .group(let id): !(store.group(id)?.isCollapsed ?? false)
        case .project(let id): !(store.project(id)?.isCollapsed ?? false)
        default: true
        }
    }
    var y: CGFloat = 0
    var out: [DropRow] = []
    for entry in visible {
        let h = height(entry.node)
        out.append(DropRow(node: entry.node, depth: entry.depth, minY: y, maxY: y + h))
        y += h
    }
    return out
}

/// The pointer at `fraction` of the way down `node`'s row.
@MainActor
private func pointer(_ rows: [DropRow], at node: NodeKind, _ fraction: CGFloat) throws -> DropPointer {
    let row = try #require(rows.first { $0.node == node }, "\(node) is not a visible row")
    return DropPointer(rows: rows, y: row.minY + (row.maxY - row.minY) * fraction)
}

@MainActor
@Suite("M4 drop planner from the pointer")
struct M4PointerDropPlannerTests {
    private func setup() -> (MockSessionStore, SidebarSnapshot, [DropRow]) {
        let store = MockSessionStore(shiftClock: false)
        let snap = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "")
        return (store, snap, rows(snap, store: store))
    }

    @Test func pointerFindsTheRowAndItsBlock() throws {
        let (_, _, rows) = setup()
        #expect(DropPointer(rows: rows, y: -4).hoveredIndex == 0, "above the first row = the first row")
        #expect(DropPointer(rows: rows, y: (rows.last?.maxY ?? 0) + 40).hoveredIndex == nil, "below the list = no row")
        let onSession = try pointer(rows, at: .session("s8", .tree), 0.5)
        let index = try #require(onSession.hoveredIndex)
        let project = try #require(onSession.ancestorIndex(of: index) { if case .project = $0 { true } else { false } })
        #expect(rows[project].node == .project("backend"))
        let group = try #require(onSession.ancestorIndex(of: index) { if case .group = $0 { true } else { false } })
        #expect(rows[group].node == .group("northweb"))
    }

    /// The M3 report: a session dropped on the next one (AppKit proposes "on" that row) landed
    /// before it, i.e. where it already was. From the pointer it lands after it.
    @Test func sessionDroppedOnTheNextRowMovesAfterIt() throws {
        let (store, snap, rows) = setup()
        let dragged: [NodeKind] = [.session("s4", .tree)]
        let old = try #require(DropPlanner.plan(dragged: dragged, parent: .session("s6", .tree), index: -1, snapshot: snap, store: store))
        guard case .sessions(_, let oldIndex) = old.target else { Issue.record("not a session drop"); return }
        #expect(ListMove.apply(["s4", "s6"], moving: ["s4"], to: oldIndex) == ["s4", "s6"], "the proposal plan was a no-op")
        let plan = try #require(DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .session("s6", .tree), 0.7),
                                                 snapshot: snap, store: store))
        #expect(plan == DropPlan(target: .sessions(project: "proto", index: 2), parent: .project("proto"), childIndex: 2))
        #expect(ListMove.apply(["s4", "s6"], moving: ["s4"], to: 2) == ["s6", "s4"])
        // Upper half of the row above: before it.
        let up = DropPlanner.plan(dragged: [.session("s6", .tree)], pointer: try pointer(rows, at: .session("s4", .tree), 0.3),
                                  snapshot: snap, store: store)
        #expect(up?.target == .sessions(project: "proto", index: 0))
        // The project's own head: the top.
        let head = DropPlanner.plan(dragged: [.session("s6", .tree)], pointer: try pointer(rows, at: .project("proto"), 0.5),
                                    snapshot: snap, store: store)
        #expect(head?.target == .sessions(project: "proto", index: 0))
    }

    @Test func sessionsNeverLeaveTheirProject() throws {
        let (store, snap, rows) = setup()
        let dragged: [NodeKind] = [.session("s4", .tree)]
        #expect(DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .session("s1", .tree), 0.5), snapshot: snap, store: store) == nil)
        #expect(DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .project("backend"), 0.5), snapshot: snap, store: store) == nil)
        #expect(DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .group("northlab"), 0.5), snapshot: snap, store: store) == nil)
        // An external (s14) never moves, and nothing lands below a project's externals.
        #expect(DropPlanner.plan(dragged: [.session("s14", .tree)], pointer: try pointer(rows, at: .project("line"), 0.5),
                                 snapshot: snap, store: store) == nil)
    }

    /// A project over another project's sessions (most of an expanded group) used to be refused.
    @Test func projectOverAnotherProjectsSessionsGoesBeforeOrAfterIt() throws {
        let (store, snap, rows) = setup()
        let dragged: [NodeKind] = [.project("invoice")]
        #expect(DropPlanner.plan(dragged: dragged, parent: .session("s1", .tree), index: -1, snapshot: snap, store: store) == nil,
                "the proposal plan refused it")
        let upper = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .session("s1", .tree), 0.2), snapshot: snap, store: store)
        #expect(upper == DropPlan(target: .projects(group: "northweb", index: 0), parent: .group("northweb"), childIndex: 0))
        let lower = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .session("s8", .tree), 0.8), snapshot: snap, store: store)
        #expect(lower?.target == .projects(group: "northweb", index: 1))
        // Into another group: over its sessions, or onto its head (after its projects, `移入`).
        let between = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .session("s6", .tree), 0.9), snapshot: snap, store: store)
        #expect(between?.target == .projects(group: "northlab", index: 1))
        let head = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .group("northlab"), 0.5), snapshot: snap, store: store)
        #expect(head == DropPlan(target: .projects(group: "northlab", index: 3), parent: .group("northlab"), childIndex: 3))
        let collapsed = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .group("codd"), 0.5), snapshot: snap, store: store)
        #expect(collapsed?.target == .projects(group: "codd", index: 2))
        // The head of its own group: the top of that group (a reorder, not `移入`).
        let ownHead = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .group("northweb"), 0.5), snapshot: snap, store: store)
        #expect(ownHead?.target == .projects(group: "northweb", index: 0))
        // 未分類 takes projects too.
        let ungrouped = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .project("line"), 0.2), snapshot: snap, store: store)
        #expect(ungrouped?.target == .projects(group: "ungrouped", index: 0))
        // NEEDS YOU / PINNED and the add row are not group positions.
        let needs = try #require(snap.childrenOf(.section(.needsYou)).first)
        #expect(DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: needs, 0.5), snapshot: snap, store: store) == nil)
        #expect(DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .addGroup, 0.5), snapshot: snap, store: store) == nil)
    }

    /// Groups: over anything inside a group (not only its head), before / after its block.
    @Test func groupOverAnotherGroupsRowsGoesBeforeOrAfterIt() throws {
        let (store, snap, rows) = setup()
        // Root: [needs 0, pinned 1, northlab 2, northweb 3, github 4, codd 5, ungrouped 6, add 7].
        let dragged: [NodeKind] = [.group("northlab")]
        #expect(DropPlanner.plan(dragged: dragged, parent: .session("s11", .tree), index: -1, snapshot: snap, store: store) == nil,
                "the proposal plan refused it")
        let after = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .session("s11", .tree), 0.5), snapshot: snap, store: store)
        #expect(after == DropPlan(target: .groups(index: 3), parent: nil, childIndex: 5))
        let before = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: .group("github"), 0.5), snapshot: snap, store: store)
        #expect(before == DropPlan(target: .groups(index: 2), parent: nil, childIndex: 4))
        // Over 未分類 (always last), the add row or below the list: after the last user group.
        for node: NodeKind in [.project("line"), .group("ungrouped"), .addGroup] {
            let plan = DropPlanner.plan(dragged: dragged, pointer: try pointer(rows, at: node, 0.5), snapshot: snap, store: store)
            #expect(plan?.target == .groups(index: 4), "\(node)")
        }
        let below = DropPlanner.plan(dragged: dragged, pointer: DropPointer(rows: rows, y: (rows.last?.maxY ?? 0) + 30), snapshot: snap, store: store)
        #expect(below?.target == .groups(index: 4))
        // Over NEEDS YOU: the top of the user groups.
        let needs = try #require(snap.childrenOf(.section(.needsYou)).first)
        let top = DropPlanner.plan(dragged: [.group("codd")], pointer: try pointer(rows, at: needs, 0.5), snapshot: snap, store: store)
        #expect(top == DropPlan(target: .groups(index: 0), parent: nil, childIndex: 2))
        #expect(DropPlanner.plan(dragged: [.group("ungrouped")], pointer: try pointer(rows, at: .group("github"), 0.5),
                                 snapshot: snap, store: store) == nil)
    }

    @Test func folderDropsTakeTheProjectPositionUnderThePointer() throws {
        let (store, snap, rows) = setup()
        let head = DropPlanner.planFolders(pointer: try pointer(rows, at: .group("northweb"), 0.5), snapshot: snap, store: store)
        #expect(head == DropPlan(target: .folders(group: "northweb", index: 3), parent: .group("northweb"), childIndex: 3))
        let between = DropPlanner.planFolders(pointer: try pointer(rows, at: .session("s8", .tree), 0.9), snapshot: snap, store: store)
        #expect(between.target == .folders(group: "northweb", index: 1))
        let elsewhere = DropPlan(target: .folders(group: nil, index: nil), parent: nil, childIndex: -1)
        #expect(DropPlanner.planFolders(pointer: try pointer(rows, at: .addGroup, 0.5), snapshot: snap, store: store) == elsewhere)
        let needs = try #require(snap.childrenOf(.section(.needsYou)).first)
        #expect(DropPlanner.planFolders(pointer: try pointer(rows, at: needs, 0.5), snapshot: snap, store: store) == elsewhere)
        #expect(DropPlanner.planFolders(pointer: nil, snapshot: snap, store: store) == elsewhere, "STATE view / filter")
        #expect(DropPlanner.planFolders(pointer: DropPointer(rows: rows, y: (rows.last?.maxY ?? 0) + 30), snapshot: snap, store: store)
                == elsewhere)
    }

    @Test func onlyFoldersCountAndEachOnce() throws {
        let path = try makeTemp("codd-m4dnd-urls")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: path + "/alpha", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: path + "/Tool.app/Contents", withIntermediateDirectories: true)
        try Data("x".utf8).write(to: URL(fileURLWithPath: path + "/note.txt"))
        try fm.createSymbolicLink(atPath: path + "/link", withDestinationPath: path + "/alpha")
        let urls = [
            URL(fileURLWithPath: path + "/alpha", isDirectory: true),
            URL(fileURLWithPath: path + "/note.txt"),
            URL(fileURLWithPath: path + "/Tool.app", isDirectory: true),
            URL(fileURLWithPath: path + "/alpha/../alpha/"),
            URL(fileURLWithPath: path + "/link"),
            URL(fileURLWithPath: path + "/missing", isDirectory: true),
            try #require(URL(string: "https://example.com/folder/")),
        ]
        // A link to a folder is a folder here; the store finds the project it points to.
        #expect(FolderDrop.folderPaths(urls) == [HolderSessionStore.standardize(path + "/alpha"), HolderSessionStore.standardize(path + "/link")])
        #expect(FolderDrop.folderPaths([URL(fileURLWithPath: path + "/note.txt")]).isEmpty)
    }
}

// MARK: - Real store, real outline

@MainActor
private final class DragSeed {
    let path: String
    let root: CoddDataRoot
    let manifest: [String: Any]
    let store: HolderSessionStore
    let shell = ShellState()
    let controller: SidebarViewController
    let window: NSWindow

    init() async throws {
        path = try makeTemp("codd-m4dnd")
        root = CoddDataRoot(path: path + "/root")
        let claude = ClaudeDirectory(path: path + "/claude")
        try FileManager.default.createDirectory(atPath: claude.path + "/projects", withIntermediateDirectories: true)
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/bin/bash")
        seed.arguments = [repoRoot + "/scripts/m2-fixtures/seed-layout.sh", root.path, path + "/work"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHON3"] = "/usr/bin/python3"
        seed.environment = environment
        let output = Pipe()
        seed.standardOutput = output
        try seed.run()
        seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)
        let manifestPath = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifestPath))) as? [String: Any])
        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"],
                                      claudePathOverride: "/usr/bin/false")
        launcher.coddHookPath = "/usr/bin/true"
        store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: claude, hooks: nil) { _ in }
        store.processAncestors = { _ in [1] }
        await store.start()
        controller = SidebarViewController(env: SidebarEnvironment(store: store, accounts: MockAccountStore(), shell: shell, realMode: true))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // The content view controller shrinks the window to the view's own size (208 × 229, a
        // 0 pt scroll view): AppKit's draggingUpdated then sees no visible row and proposes nothing.
        window.setContentSize(NSSize(width: 300, height: 900))
        window.layoutIfNeeded()
    }

    private func id(_ key: String, name: String) -> String? {
        (manifest[key] as? [[String: Any]])?.first { ($0["name"] as? String) == name || ($0["title"] as? String) == name }?["id"] as? String
    }

    func project(named name: String) -> ProjectVM? { id("projects", name: name).flatMap { store.project($0) } }
    func group(named name: String) -> GroupVM? { id("groups", name: name).flatMap { store.group($0) } }
    func session(titled title: String) -> String? { id("sessions", name: title) }

    /// A drag of our own rows held at `fraction` of `target`'s row, dropped (or refused).
    func drag(_ nodes: [NodeKind], to target: NodeKind, _ fraction: CGFloat) throws -> SyntheticDropResult {
        controller.applyNow()
        let writers = nodes.compactMap { controller.outlineView(controller.outline, pasteboardWriterForItem: controller.item(for: $0)) }
        #expect(writers.count == nodes.count, "every dragged row has a pasteboard writer")
        controller.beginDrag(nodes)
        defer { controller.endDrag() }
        let info = try #require(controller.syntheticInfo(at: target, fraction: fraction, ownRows: true))
        defer { info.release() }
        return controller.syntheticDrop(info)
    }

    /// Folders from Finder held at `fraction` of `target`'s row.
    func dropFiles(_ urls: [URL], on target: NodeKind, _ fraction: CGFloat) throws -> SyntheticDropResult {
        controller.applyNow()
        let info = try #require(controller.syntheticInfo(at: target, fraction: fraction, ownRows: false, fileURLs: urls))
        defer { info.release() }
        return controller.syntheticDrop(info)
    }

    func savedLayout() throws -> LayoutMapping.Model {
        store.flushLayout()
        return LayoutMapping.model(from: try LayoutStore(fileURL: root.layoutURL).load())
    }

    func close() {
        window.close()
        store.shutdown()
        try? FileManager.default.removeItem(atPath: path)
    }
}

@MainActor
@Suite("M4 sidebar mouse drags and folder drops on the real store", .serialized)
struct M4SidebarRealDropTests {
    @Test func dataSourceIsVisibleToAppKit() async throws {
        let s = try await DragSeed()
        defer { s.close() }
        let source = try #require(s.controller.outline.dataSource)
        for selector in [#selector(NSOutlineViewDataSource.outlineView(_:pasteboardWriterForItem:)),
                         #selector(NSOutlineViewDataSource.outlineView(_:draggingSession:willBeginAt:forItems:)),
                         #selector(NSOutlineViewDataSource.outlineView(_:validateDrop:proposedItem:proposedChildIndex:)),
                         #selector(NSOutlineViewDataSource.outlineView(_:acceptDrop:item:childIndex:))] {
            #expect(source.responds(to: selector), "\(NSStringFromSelector(selector))")
        }
        #expect(s.controller.outline.registeredDraggedTypes.contains(.fileURL))
        #expect(s.controller.outline.registeredDraggedTypes.contains(SidebarDrag.pasteboardType))
    }

    @Test func sessionsProjectsAndGroupsReorderByMouseAndPersist() async throws {
        let s = try await DragSeed()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        let examples = try #require(s.project(named: "整合範例"))
        let blue = try #require(s.group(named: "藍鵲 · 網站"))
        let green = try #require(s.group(named: "個人 · Github"))
        let pinned = try #require(s.session(titled: "修正登入 API 401"))
        let old = try #require(s.session(titled: "舊的部署腳本"))
        s.store.unarchive([old])
        #expect(site.sessionIDs == [pinned, old])

        // A session dropped on the lower part of the next one goes after it, the line on top of the rows.
        let down = try s.drag([.session(pinned, .tree)], to: .session(old, .tree), 0.7)
        #expect(down.operation == .move && down.lineShown && down.performed)
        #expect(site.sessionIDs == [old, pinned])
        // Never into another project.
        let refused = try s.drag([.session(pinned, .tree)], to: .project(examples.id), 0.5)
        #expect(refused.operation.isEmpty && !refused.performed)
        #expect(s.controller.dropLine.isHidden, "no line once the drag left")

        // A project dropped on the lower part of the next one's block goes after it.
        #expect(blue.projectIDs == [site.id, examples.id])
        let project = try s.drag([.project(site.id)], to: s.controller.lastVisibleRow(of: .project(examples.id)), 0.8)
        #expect(project.performed && project.targetBlock == .group(blue.id))
        #expect(blue.projectIDs == [examples.id, site.id])

        // A group dropped on the upper part of the first one goes first; 未分類 stays last.
        let group = try s.drag([.group(green.id)], to: .group(blue.id), 0.3)
        #expect(group.performed)
        #expect(s.store.groups.map(\.id).prefix(2) == [green.id, blue.id])
        #expect(s.store.groups.last?.isUngrouped == true)
        #expect(OutlineSelfTest.mismatch(s.controller) == nil)

        // layout.json gives the next launch the same order.
        let model = try s.savedLayout()
        #expect(model.groups.map(\.id).prefix(2) == [green.id, blue.id])
        #expect(model.groups.first { $0.id == blue.id }?.projectIDs == [examples.id, site.id])
        #expect(model.projects[site.id]?.sessionIDs == [old, pinned])
        #expect(s.controller.lastDrop?["kind"] as? String == "groups")
    }

    @Test func projectsMoveIntoAndOutOfUngrouped() async throws {
        let s = try await DragSeed()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        let scratch = try #require(s.project(named: "scratch"))
        let blue = try #require(s.group(named: "藍鵲 · 網站"))
        let ungrouped = try #require(s.store.groups.last)
        #expect(ungrouped.isUngrouped && ungrouped.projectIDs == [scratch.id])
        // Onto 未分類's head: after its projects, the block highlighted (`移入`).
        let into = try s.drag([.project(site.id)], to: .group(ungrouped.id), 0.5)
        #expect(into.performed && into.targetBlock == .group(ungrouped.id))
        #expect(ungrouped.projectIDs == [scratch.id, site.id] && site.groupID == ungrouped.id)
        // Out of 未分類, before a user group's first project.
        let first = try #require(blue.projectIDs.first)
        let out = try s.drag([.project(scratch.id)], to: .project(first), 0.1)
        #expect(out.performed && blue.projectIDs.first == scratch.id && scratch.groupID == blue.id)
        let model = try s.savedLayout()
        #expect(model.groups.last?.projectIDs == [site.id])
        #expect(model.groups.first { $0.id == blue.id }?.projectIDs.first == scratch.id)
    }

    @Test func addProjectsKeepsDropOrderAndNeverDuplicates() async throws {
        let s = try await DragSeed()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        let blue = try #require(s.group(named: "藍鵲 · 網站"))
        let before = blue.projectIDs
        for name in ["x", "y"] { try FileManager.default.createDirectory(atPath: s.path + "/new-\(name)", withIntermediateDirectories: true) }
        let results = s.store.addProjects(paths: [s.path + "/new-x", s.path + "/new-y", s.path + "/new-x/", site.cwd, s.path + "/missing"],
                                          toGroup: blue.id, atIndex: 0)
        #expect(results.map(\.added) == [true, true, false, false])
        #expect(results[2].projectID == site.id && results[3].projectID == nil)
        let x = try #require(results[0].projectID)
        let y = try #require(results[1].projectID)
        #expect(blue.projectIDs == [x, y] + before)
        #expect(s.store.project(x)?.name == "new-x", "named like 新增專案")
        // A link to a project's folder is that project.
        try FileManager.default.createSymbolicLink(atPath: s.path + "/link-site", withDestinationPath: site.cwd)
        let linked = s.store.addProjects(paths: [s.path + "/link-site"], toGroup: nil, atIndex: nil)
        #expect(linked == [ProjectAddition(path: HolderSessionStore.standardize(s.path + "/link-site"), projectID: site.id, added: false)])
        #expect(s.store.groups.flatMap(\.projectIDs).count == before.count + 2 + 2)
    }

    @Test func foldersFromFinderBecomeProjectsWhereTheyAreDropped() async throws {
        let s = try await DragSeed()
        defer { s.close() }
        let blue = try #require(s.group(named: "藍鵲 · 網站"))
        let site = try #require(s.project(named: "northstar-site"))
        let folder = URL(fileURLWithPath: s.path + "/dropped", isDirectory: true)
        let other = URL(fileURLWithPath: s.path + "/elsewhere", isDirectory: true)
        let file = URL(fileURLWithPath: s.path + "/readme.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)

        // A plain file: no target.
        let plain = try s.dropFiles([file], on: .group(blue.id), 0.5)
        #expect(plain.operation.isEmpty && !plain.performed)
        // A folder (with a file) on a group's head: into that group after its projects.
        let before = blue.projectIDs
        let head = try s.dropFiles([file, folder], on: .group(blue.id), 0.5)
        #expect(head.operation == .copy && head.performed && head.targetBlock == .group(blue.id))
        let added = try #require(s.store.project(forPath: folder.path))
        #expect(blue.projectIDs == before + [added.id])
        #expect(s.controller.lastDrop?["added"] as? Int == 1)
        // The same folder again, onto a project: not duplicated; that project is revealed and selected.
        let count = s.store.groups.flatMap(\.projectIDs).count
        let again = try s.dropFiles([folder], on: .project(site.id), 0.2)
        #expect(again.performed && s.store.groups.flatMap(\.projectIDs).count == count)
        let selected = s.controller.outline.selectedRowIndexes.compactMap { s.controller.kind(atRow: $0) }
        #expect(selected == [.project(added.id)])
        #expect(s.controller.currentToast != nil)
        #expect(s.controller.dumpObject()["selectedProjects"] as? [String] == [added.id])
        // Outside the groups: where 新增專案 puts it, with no line.
        let outside = try s.dropFiles([other], on: .addGroup, 0.5)
        #expect(outside.performed && !outside.lineShown)
        #expect(s.store.project(forPath: other.path).flatMap { s.store.group($0.groupID)?.isUngrouped } == true)
        // Sessions still never move between projects (a folder drop is not a session drag).
        #expect(site.sessionIDs.allSatisfy { s.store.session($0)?.projectID == site.id })
    }

    @Test func mockModeHasNoFolderTarget() throws {
        let store = MockSessionStore(shiftClock: false)
        let controller = SidebarViewController(env: SidebarEnvironment(store: store, accounts: MockAccountStore(), shell: ShellState()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.layoutIfNeeded()
        defer { window.close() }
        let info = try #require(controller.syntheticInfo(at: .group("northweb"), fraction: 0.5, ownRows: false,
                                                         fileURLs: [URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)]))
        defer { info.release() }
        let result = controller.syntheticDrop(info)
        #expect(result.operation.isEmpty && !result.performed)
    }
}
