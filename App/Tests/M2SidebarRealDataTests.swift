import AppKit
import CoddCore
import CoddHooks
import Darwin
import Foundation
import Testing
@testable import CODD

/// M2 step I3, "verify every M1 sidebar behaviour on real data": the real `HolderSessionStore` on a
/// data root seeded by `scripts/m2-fixtures/seed-layout.sh` (CoddCore's layout.json format), a
/// temp Claude directory, a registry entry for an external claude, and the real sidebar controller
/// in an offscreen window. No holder is spawned (the seeded sessions have none, so the claude
/// sessions are STOPPED and the shell EXITED); nothing outside the temp folder is touched.

/// The repository root, from this file's path (App/Tests/…).
private let repoRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<3 { url.deleteLastPathComponent() }
    return url.path
}()

/// A fresh, normalized `$TMPDIR` folder (short: socket paths must fit 104 bytes).
private func makeTemp(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    let path = String(cString: created)
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

@MainActor
private final class SeededSidebar {
    let path: String
    let root: CoddDataRoot
    let claude: ClaudeDirectory
    let manifest: [String: Any]
    let store: HolderSessionStore
    let shell = ShellState()
    let controller: SidebarViewController
    let window: NSWindow

    init() async throws {
        path = try makeTemp("codd-i3s")
        root = CoddDataRoot(path: path + "/root")
        claude = ClaudeDirectory(path: path + "/claude")
        try FileManager.default.createDirectory(atPath: claude.path + "/projects", withIntermediateDirectories: true)
        // The fixture writes layout.json exactly as CoddCore's LayoutStore does.
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
        let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let holder = try #require(HolderLauncher.bundledHolder, "CODD.app/Contents/MacOS/codd-holder is missing")
        var launcher = HolderLauncher(holderExecutable: holder, root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"],
                                      claudePathOverride: "/usr/bin/false")
        launcher.coddHookPath = "/usr/bin/true"
        store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: claude, hooks: nil) { _ in }
        store.processAncestors = { _ in [1] }
        await store.start()
        controller = SidebarViewController(env: SidebarEnvironment(store: store, accounts: MockAccountStore(), shell: shell))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.layoutIfNeeded()
    }

    func id(_ key: String, name: String) -> String? {
        (manifest[key] as? [[String: Any]])?.first { ($0["name"] as? String) == name || ($0["title"] as? String) == name }?["id"] as? String
    }

    func project(named name: String) -> ProjectVM? { id("projects", name: name).flatMap { store.project($0) } }
    func group(named name: String) -> GroupVM? { id("groups", name: name).flatMap { store.group($0) } }
    func session(titled title: String) -> String? { id("sessions", name: title) }

    /// A claude started in Terminal.app in `cwd` (what `RegistryWatcher` would deliver).
    func external(pid: Int, cwd: String, status: String, waitingFor: String? = nil) -> ClaudeRegistryEntry {
        ClaudeRegistryEntry(pid: pid, sessionId: "ext-claude-\(pid)", cwd: cwd, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                            version: "2.1.300", kind: "interactive", entrypoint: "cli", name: "外部修 bug", status: status,
                            waitingFor: waitingFor, statusTimestampMilliseconds: Int64(Date().timeIntervalSince1970 * 1000))
    }

    func row(_ node: NodeKind) -> Int { controller.outline.row(forItem: controller.item(for: node)) }

    func savedLayout() throws -> Layout {
        store.flushLayout()
        return try LayoutStore(fileURL: root.layoutURL).load()
    }

    func close() {
        window.close()
        store.shutdown()
        try? FileManager.default.removeItem(atPath: path)
    }
}

@MainActor
@Suite("M1 sidebar behaviours on a seeded real store", .serialized)
struct SidebarRealDataTests {
    @Test func seededTreeHasPinnedGroupsProjectsAndTheAddRow() async throws {
        let s = try await SeededSidebar()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        let blue = try #require(s.group(named: "藍鵲 · 網站"))
        let green = try #require(s.group(named: "個人 · Github"))
        let pinned = try #require(s.session(titled: "修正登入 API 401"))
        // SPEC §2: PINNED → groups (tinted blocks, colors) → projects → sessions → 未分類 → [+ 新增群組].
        #expect(s.controller.snapshot.childrenOf(nil) == [.section(.pinned), .group(blue.id), .group(green.id),
                                                          .group(LayoutMapping.ungroupedID), .addGroup])
        #expect(blue.color == .blue && green.color == .green)
        #expect(s.controller.snapshot.childrenOf(.section(.pinned)) == [.session(pinned, .pinned)])
        #expect(s.store.session(pinned)?.tag == .orange)
        #expect(s.store.session(pinned)?.state == .stopped, "no holder: resumable")
        #expect(site.archivedCount == 1)
        let collapsed = try #require(s.project(named: "整合範例"))
        #expect(collapsed.isCollapsed && !s.controller.outline.isItemExpanded(s.controller.item(for: .project(collapsed.id))))
        let empty = try #require(s.project(named: "codd-desktop"))
        #expect(s.controller.snapshot.childrenOf(.project(empty.id)) == [.emptyProject(empty.id)])
        let shellID = try #require(s.session(titled: "zsh"))
        #expect(s.store.session(shellID)?.state == .exited)
        let rows = SidebarDump.rows(snapshot: s.controller.snapshot, store: s.store, shell: s.shell, expanded: s.controller.wantsExpanded,
                                    now: Date())
        #expect(rows.count == s.controller.outline.numberOfRows)
        #expect(rows.first { $0.id == pinned && $0.section == "tree" }?.line2?.hasPrefix("可接續 · ") == true)
        #expect(OutlineSelfTest.mismatch(s.controller) == nil)
    }

    @Test func externalMirrorsIntoNeedsYouWithoutReorderingTheTree() async throws {
        let s = try await SeededSidebar()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        s.store.applyRegistry([s.external(pid: 910_001, cwd: site.cwd, status: "waiting", waitingFor: "permission prompt")])
        s.controller.applyNow()
        let ext = try #require(site.sessionIDs.last)
        #expect(ext.hasPrefix("ext-910001-"))
        #expect(s.store.session(ext)?.state == .waiting)
        #expect(s.controller.snapshot.childrenOf(.section(.needsYou)).compactMap(\.sessionID) == [ext])
        #expect(s.controller.snapshot.childrenOf(.project(site.id)).last == .session(ext, .tree), "the tree order is unchanged")
        // ⌘1 is the NEEDS YOU row; ⌥⇧↑↓ and drags never move an external.
        #expect(s.controller.snapshot.sessionOrder.first == ext)
        let extRow = s.row(.session(ext, .tree))
        #expect(s.controller.outlineView(s.controller.outline, pasteboardWriterForItem: s.controller.item(for: .session(ext, .tree))) == nil)
        s.controller.outline.selectRowIndexes(IndexSet(integer: extRow), byExtendingSelection: false)
        s.controller.moveSelected(by: -1)
        #expect(site.sessionIDs.last == ext)
        // Its row says where it runs; a hover card shows its pid.
        let line2 = SidebarDump.row(.session(ext, .tree), depth: 2, store: s.store, shell: s.shell, now: Date()).line2
        #expect(line2?.hasSuffix("外部啟動") == true)
        s.store.applyRegistry([])
        s.controller.applyNow()
        #expect(!s.controller.snapshot.contains(.section(.needsYou)))
    }

    @Test func reorderRestoreArchiveAndUndoPersist() async throws {
        let s = try await SeededSidebar()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        let pinned = try #require(s.session(titled: "修正登入 API 401"))
        let old = try #require(s.session(titled: "舊的部署腳本"))
        // D19: `封存 1 ▸` → `還原「舊的部署腳本」`.
        let restore = try #require(ArchiveRestoreMenuModel.make(project: site.id, store: s.store))
        #expect(restore.title == "封存 1" && restore.entries.map(\.title) == ["還原「舊的部署腳本」"])
        s.controller.restore([old])
        #expect(site.sessionIDs == [pinned, old])
        #expect(site.archivedCount == 0)
        // ⌥⇧↓ keeps the session in its project.
        s.controller.reveal(pinned)
        s.controller.moveSelected(by: 1)
        #expect(site.sessionIDs == [old, pinned])
        // ⌘⌫ archive + UNDO (5 s countdown).
        s.controller.archive([old])
        #expect(site.sessionIDs == [pinned])
        let toast = try #require(s.controller.currentToast)
        #expect(toast.countdownLabelText == "5s")
        let undo = s.store.archive([pinned])
        #expect(site.sessionIDs.isEmpty)
        undo()
        #expect(site.sessionIDs == [pinned])
        let saved = try s.savedLayout()
        let archived = saved.sessions.filter { $0.archivedAt != nil }.map { LayoutMapping.id($0.id) }
        #expect(archived == [old])
        #expect(OutlineSelfTest.mismatch(s.controller) == nil)
    }

    @Test func projectsMoveGroupsReorderAndLayoutIsSaved() async throws {
        let s = try await SeededSidebar()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        let blue = try #require(s.group(named: "藍鵲 · 網站"))
        let green = try #require(s.group(named: "個人 · Github"))
        // A project drops into another group (DropPlanner on the real snapshot), groups reorder.
        let plan = try #require(DropPlanner.plan(dragged: [.project(site.id)], parent: .group(green.id), index: -1,
                                                 snapshot: s.controller.snapshot, store: s.store))
        #expect(plan.target == .projects(group: green.id, index: 1))
        s.controller.showDropLine(for: plan)
        #expect(!s.controller.dropLine.isHidden)
        s.store.moveProjects([site.id], toGroup: green.id, atIndex: 1)
        s.store.moveGroups([green.id], toIndex: 0)
        s.controller.endDrag()
        s.controller.applyNow()
        #expect(s.controller.snapshot.childrenOf(nil).prefix(3) == [.section(.pinned), .group(green.id), .group(blue.id)])
        #expect(green.projectIDs.last == site.id)
        // Collapse, color, rename, pin.
        s.controller.toggleCollapsed(.group(blue.id))
        s.store.setGroupColor(.yellow, group: green.id)
        let pinned = try #require(s.session(titled: "修正登入 API 401"))
        s.store.renameSession(pinned, to: "登入 401（改名）")
        s.store.setTag(.cyan, sessions: [pinned])
        s.store.setPinned(false, sessions: [pinned])
        s.controller.applyNow()
        #expect(!s.controller.snapshot.contains(.section(.pinned)))
        let saved = try s.savedLayout()
        let groups = saved.groups.sorted { $0.order < $1.order }
        #expect(groups.map(\.name) == ["個人 · Github", "藍鵲 · 網站"])
        #expect(groups.first?.color == .yellow)
        #expect(groups.last?.collapsed == true)
        let row = try #require(saved.sessions.first { LayoutMapping.id($0.id) == pinned })
        #expect(row.titleOverride == "登入 401（改名）")
        #expect(row.color == .cyan)
        #expect(!row.pinned)
        #expect(saved.projects.first { LayoutMapping.id($0.id) == site.id }?.groupId.map(LayoutMapping.id) == green.id)
        #expect(OutlineSelfTest.mismatch(s.controller) == nil)
    }

    @Test func newGroupCleanupStateViewStaleAndFilter() async throws {
        let s = try await SeededSidebar()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        // Inline new group: the default color is the first unused one (blue and green are taken).
        s.controller.beginNewGroup()
        #expect(s.controller.newGroupEditor?.color == .red)
        s.controller.newGroupEditor?.name = "內部工具"
        let created = try #require(s.controller.commitNewGroup())
        #expect(s.store.group(created)?.name == "內部工具")
        #expect(try s.savedLayout().groups.contains { $0.name == "內部工具" && $0.color == .red })
        // 清理已停止: 未分類 has the exited shell; 藍鵲 · 網站 the stopped claude sessions.
        let shellID = try #require(s.session(titled: "zsh"))
        #expect(s.controller.stoppedSessions(inGroup: LayoutMapping.ungroupedID) == [shellID])
        s.controller.cleanupStopped(inGroup: LayoutMapping.ungroupedID)
        #expect(s.store.archivedSession(shellID) != nil)
        #expect(s.controller.currentToast?.countdownLabelText == "5s")
        // STATE view with an idle external that is stale (D15).
        s.store.applyRegistry([s.external(pid: 910_002, cwd: site.cwd, status: "idle")])
        s.store.staleAfter = 0
        s.store.refreshStale(now: Date().addingTimeInterval(5))
        s.controller.setMode(.state)
        s.controller.applyNow()
        let idle = SectionHeaderCellView.content(.idle, store: s.store, filter: "")
        #expect(idle.count == 1 && idle.hint == "1 stale")
        #expect(s.controller.snapshot.childrenOf(nil).contains(.section(.stopped)))
        let ext = try #require(site.sessionIDs.last)
        let line2 = SidebarDump.row(.session(ext, .stateList(.idle)), depth: 1, store: s.store, shell: s.shell, now: Date()).line2
        #expect(line2?.hasSuffix("■ northstar-site") == true)
        // The filter covers the STATE lists by group name.
        s.controller.setFilter("網站")
        s.controller.applyNow()
        #expect(s.controller.snapshot.childrenOf(.section(.idle)).compactMap(\.sessionID) == [ext])
        s.controller.setFilter("Github")
        s.controller.applyNow()
        #expect(!s.controller.snapshot.contains(.section(.idle)))
        s.store.applyRegistry([])
    }

    @Test func multiSelectShowsTheBarAndStopIsAsked() async throws {
        let s = try await SeededSidebar()
        defer { s.close() }
        let site = try #require(s.project(named: "northstar-site"))
        let old = try #require(s.session(titled: "舊的部署腳本"))
        s.controller.restore([old])
        s.controller.applyNow()
        let rows = site.sessionIDs.map { s.row(.session($0, .tree)) }
        s.controller.outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        #expect(!s.controller.selectionBar.isHidden, "已選 2 [封存] [停止] [顏色] ✕")
        // Nothing runs: 停止 asks nothing and stops nothing.
        s.controller.confirmStop(site.sessionIDs)
        #expect(s.window.attachedSheet == nil)
        s.controller.archive(s.controller.targetSessions(clickedRow: rows[0]))
        #expect(site.sessionIDs.isEmpty)
        #expect(s.controller.currentToast?.accessibilityLabel() == "✕ 2 個 session 已封存")
    }
}

/// Measurement (report): the sidebar snapshot for 100 real sessions (4 groups × 5 projects × 5
/// sessions, mixed states), in TREE, STATE, with a filter, and the `sidebar` dump of it.
@MainActor
@Suite("Sidebar snapshot cost", .serialized)
struct SidebarSnapshotCostTests {
    @Test func hundredSessions() async throws {
        let path = try makeTemp("codd-i3m")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let root = CoddDataRoot(path: path + "/root")
        try FileManager.default.createDirectory(atPath: root.path, withIntermediateDirectories: true)
        var groups: [ProjectGroup] = []
        var projects: [Project] = []
        var sessions: [SessionRecord] = []
        let colors: [ColorTag] = [.red, .blue, .green, .purple]
        for g in 0..<4 {
            let group = ProjectGroup(name: "群組 \(g)", color: colors[g], order: g)
            groups.append(group)
            for p in 0..<5 {
                let folder = path + "/work/g\(g)p\(p)"
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                let project = Project(groupId: group.id, name: "專案 \(g)-\(p)", path: folder, order: p)
                projects.append(project)
                for n in 0..<5 {
                    sessions.append(SessionRecord(claudeSessionId: UUID().uuidString.lowercased(), projectId: project.id,
                                                  kind: n == 4 ? .shell : .claude, title: "session \(g)-\(p)-\(n)", order: n,
                                                  createdAt: Date()))
                }
            }
        }
        try LayoutStore(fileURL: root.layoutURL).save(Layout(groups: groups, projects: projects, sessions: sessions))
        let holder = try #require(HolderLauncher.bundledHolder)
        let store = HolderSessionStore(root: root, launcher: HolderLauncher(holderExecutable: holder, root: root),
                                       claudeDirectory: ClaudeDirectory(path: path + "/claude"), hooks: nil) { _ in }
        store.processAncestors = { _ in [1] }
        await store.start()
        defer { store.shutdown() }
        let states: [CODD.SessionState] = [.waiting, .error, .done, .busy, .compacting, .idle, .starting, .shell, .exited, .stopped]
        for (i, session) in store.sessionsByID.values.sorted(by: { $0.id < $1.id }).enumerated() {
            session.state = states[i % states.count]
            if session.state == .waiting { session.waitingReason = .permission }
        }
        #expect(store.allSessions.count == 100)
        let shell = ShellState()
        func measure(_ label: String, _ body: () -> SidebarSnapshot) -> SidebarSnapshot {
            var best = Duration.seconds(10)
            var result = SidebarSnapshot()
            for _ in 0..<20 {
                let start = ContinuousClock.now
                result = body()
                best = min(best, ContinuousClock.now - start)
            }
            print(String(format: "MEASURE sidebar snapshot %@ 100 sessions: %.3f ms (best of 20)", label, TerminalHub.milliseconds(best)))
            #expect(best < .milliseconds(50))
            return result
        }
        let tree = measure("tree") { SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "") }
        #expect(tree.sessionOrder.count == 100)
        _ = measure("state") { SidebarSnapshotBuilder.build(store: store, mode: .state, filter: "") }
        _ = measure("tree+filter") { SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "群組 2") }
        let start = ContinuousClock.now
        let rows = SidebarDump.rows(snapshot: tree, store: store, shell: shell, expanded: { _ in true }, now: Date())
        print(String(format: "MEASURE sidebar dump %d rows: %.3f ms", rows.count, TerminalHub.milliseconds(ContinuousClock.now - start)))
        #expect(rows.count > 100)
    }
}
