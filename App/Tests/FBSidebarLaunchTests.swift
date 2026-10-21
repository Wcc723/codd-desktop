import AppKit
import CoddCore
import CoddUI
import Darwin
import Foundation
import Testing
@testable import CODD

/// fb (the user's note 「CODD 接下來可以修正的問題」), three sidebar / launch items:
/// - 「#專案旁邊加入一個 +」: a project row's `+` starts a claude session in its folder right away
///   (no sheet), with the default launch profile, the global login and no `--model`.
/// - 「claude code 建立 session 不要選擇模型」: the ⌘N model select defaults to
///   `預設（跟隨 Claude Code 設定）`, which passes no `--model`.
/// - 「拖曳一個新的資料夾進來的時候，會直接凸顯那個資料夾」: a folder dropped from Finder reveals,
///   selects and pulses its project, new or already there (still with 減少動態).
/// Temp folders only; no holder is spawned and no claude runs (the plan is built, never started).

private func fbTemp(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    let path = String(cString: created)
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// What the `+` asked for (the callback the app wires to its launch).
@MainActor
private final class StartLog {
    var requests: [NewSessionRequest] = []
    var answer: String?

    func attach(_ controller: SidebarViewController) {
        controller.onStartSession = { [weak self] request in
            self?.requests.append(request)
            return self?.answer
        }
    }
}

@MainActor
private func projectCell(_ h: SidebarHarness, _ id: ProjectID) throws -> ProjectCellView {
    h.controller.applyNow()
    let row = h.controller.outline.row(forItem: h.controller.item(for: .project(id)))
    #expect(row >= 0, "\(id) is not a visible row")
    let cell = try #require(h.controller.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? ProjectCellView)
    cell.needsLayout = true
    cell.layoutSubtreeIfNeeded()
    // The offscreen window sits at the screen's corner: the real pointer may "hover" a row there.
    (cell.superview as? SidebarRowView)?.isHovered = false
    cell.isHovered = false
    return cell
}

@MainActor
private func rowView(_ controller: SidebarViewController, _ node: NodeKind) -> SidebarRowView? {
    let row = controller.outline.row(forItem: controller.item(for: node))
    guard row >= 0 else { return nil }
    return controller.outline.rowView(atRow: row, makeIfNecessary: true) as? SidebarRowView
}

@MainActor
private func selectedProjects(_ controller: SidebarViewController) -> [ProjectID] {
    controller.outline.selectedRowIndexes.compactMap { row -> ProjectID? in
        if case .project(let id)? = controller.kind(atRow: row) { return id }
        return nil
    }
}

// MARK: - The project `+`

@MainActor
@Suite("fb: the project row's + starts a claude session")
struct FBProjectPlusTests {
    let protoPath = "~/Project/Northstar/lab/agent-lab-2026/原型試做"

    @Test func theRequestFollowsTheDefaults() {
        let request = SidebarViewController.quickLaunchRequest(cwd: protoPath)
        #expect(request.cwd == PathFormat.expandTilde(protoPath))
        #expect(request.cwd.hasPrefix("/"))
        #expect(request.kind == .claude)
        #expect(request.claude.mode == .new)
        #expect(request.claude.profileID == nil, "the default launch profile")
        #expect(request.claude.accountNumber == nil, "the global login")
        #expect(request.claude.model == nil, "Claude Code's own model")
        #expect(request.claude.permissionMode == nil)
        #expect(request.claude.remoteControl == false)
        #expect(request.name == nil && request.tag == nil && request.groupID == nil && request.sessionID == nil)
    }

    @Test func thePlusIsHoverOnlyYetLabelledAndInTheTree() throws {
        let h = SidebarHarness()
        let cell = try projectCell(h, "proto")
        let label = "在 原型試做 開新的 Claude session"
        #expect(!cell.showsAdd)
        #expect(cell.addButton.alphaValue == 0 && !cell.addButton.isHidden, "transparent, not hidden: VoiceOver reaches it")
        #expect(cell.addButton.accessibilityLabel() == label)
        // Not drawn: a click there is the row's (it toggles the project).
        let center = cell.convert(NSPoint(x: cell.addButton.frame.midX, y: cell.addButton.frame.midY), to: cell.superview)
        let windowPoint = cell.addButton.convert(NSPoint(x: cell.addButton.bounds.midX, y: cell.addButton.bounds.midY), to: nil)
        #expect(cell.hitTest(center) === cell)
        #expect(cell.actionButton(atWindowPoint: windowPoint) == nil, "the row's click toggles the project")
        cell.isHovered = true
        #expect(cell.showsAdd && cell.addButton.alphaValue == 1)
        #expect(cell.hitTest(center) === cell.addButton)
        #expect(cell.actionButton(atWindowPoint: windowPoint) === cell.addButton, "a click on the + is the button's")
        cell.isHovered = false
        #expect(!cell.showsAdd && cell.addButton.alphaValue == 0)
        // The row offers it in VoiceOver's actions rotor.
        let row = try #require(rowView(h.controller, .project("proto")))
        #expect(row.accessibilityCustomActions()?.map(\.name) == [label])
        // Session rows offer nothing of the kind.
        let session = try #require(rowView(h.controller, .session("s4", .tree)))
        #expect(session.accessibilityCustomActions()?.map(\.name).contains(label) != true)
    }

    @Test func pressingThePlusStartsASessionInTheProjectsFolder() throws {
        let h = SidebarHarness()
        let log = StartLog()
        log.attach(h.controller)
        let cell = try projectCell(h, "proto")
        // VoiceOver's press (also what a click and Space do: the button's action).
        #expect(cell.addButton.accessibilityPerformPress())
        #expect(log.requests == [SidebarViewController.quickLaunchRequest(cwd: protoPath)])
        // The row's accessibility action starts the same.
        #expect(h.controller.startClaudeSession(inProject: "proto"))
        #expect(log.requests.count == 2 && log.requests[1].cwd == PathFormat.expandTilde(protoPath))
        #expect(h.controller.currentToast == nil)
        // The ⌘N sheet was not involved.
        var sheets = 0
        h.controller.onNewSession = { _ in sheets += 1 }
        #expect(cell.addButton.accessibilityPerformPress())
        #expect(sheets == 0 && log.requests.count == 3)
    }

    @Test func aRefusalSaysWhyAndMockModeStartsNothing() throws {
        let h = SidebarHarness()
        #expect(!h.controller.startClaudeSession(inProject: "proto"), "mock mode: no callback")
        let log = StartLog()
        log.attach(h.controller)
        log.answer = HolderSessionStore.missingFolderMessage("/gone")
        #expect(!h.controller.startClaudeSession(inProject: "proto"))
        #expect(log.requests.count == 1)
        #expect(h.controller.currentToast != nil, "the refusal is shown (there is no sheet to show it)")
        #expect(!h.controller.startClaudeSession(inProject: "no-such-project"))
        #expect(log.requests.count == 1)
    }

    @Test func aTransientProjectHasNoPlus() throws {
        let h = SidebarHarness()
        let line = try #require(h.store.project("line"))
        line.isTransient = true
        let cell = try projectCell(h, "line")
        cell.refresh()
        #expect(cell.addButton.isHidden && !cell.showsAdd && cell.rowAccessibilityActions.isEmpty)
        cell.isHovered = true
        #expect(!cell.showsAdd)
        let log = StartLog()
        log.attach(h.controller)
        #expect(!h.controller.startClaudeSession(inProject: "line"))
        #expect(log.requests.isEmpty)
    }

    /// What the holder would run for the `+`: claude with `--session-id` and no `--model`; a
    /// default profile that names a model on purpose passes it.
    @Test func theLaunchPlanHasNoModelUnlessTheProfileNamesOne() throws {
        let folder = try fbTemp("codd-fbplan")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        var launcher = HolderLauncher(holderExecutable: "/usr/bin/false", root: CoddDataRoot(path: folder + "/r"),
                                      claudePathOverride: folder + "/fake-claude")
        let request = SidebarViewController.quickLaunchRequest(cwd: folder)
        let plan = try launcher.planClaude(sessionID: UUID(), cwd: request.cwd, options: request.claude, hooks: nil)
        #expect(plan.argv.first == folder + "/fake-claude")
        #expect(plan.argv.contains("--session-id"))
        #expect(!plan.argv.contains("--model"), "\(plan.argv)")
        #expect(!plan.argv.contains("--permission-mode"))
        launcher.profiles[0].defaultModel = "opus"
        let named = try launcher.planClaude(sessionID: UUID(), cwd: request.cwd, options: request.claude, hooks: nil)
        #expect(named.argv.suffix(2) == ["--model", "opus"])
    }
}

// MARK: - The ⌘N model select

@MainActor
@Suite("fb: ⌘N follows Claude Code's model by default")
struct FBNewSessionModelTests {
    @Test func theDefaultEntryFollowsClaudeCodeAndPassesNoModel() {
        var form = NewSessionForm()
        form.path = "/synthetic/project"
        #expect(form.modelChoice == .default)
        #expect(form.modelTitle(.default) == "預設（跟隨 Claude Code 設定）")
        #expect(NewSessionForm.ModelChoice.allCases.map(form.modelTitle)
            == ["預設（跟隨 Claude Code 設定）", "opus", "sonnet", "haiku", "其他…"])
        #expect(form.requestModel == nil && form.request.claude.model == nil)
        #expect(!form.commandPreview().contains("--model"))
        #expect(!form.commandPreview(abbreviated: false).contains("--model"))
        // Claude Code's own `model` is what runs, not CODD's pick: the title stays, the tooltip names it.
        form.settingsModel = "opus"
        #expect(form.modelTitle(.default) == "預設（跟隨 Claude Code 設定）")
        #expect(form.defaultModelHint == "不傳 --model：Claude Code 目前設定的模型是 opus")
        #expect(form.request.claude.model == nil && !form.commandPreview().contains("--model"))
        form.settingsModel = nil
        #expect(form.defaultModelHint == "不傳 --model：由 Claude Code 自己的設定決定模型")
    }

    @Test func onlyAPickOrAProfileModelAddsTheFlag() {
        var form = NewSessionForm()
        form.path = "/synthetic/project"
        form.modelChoice = .sonnet
        #expect(form.request.claude.model == "sonnet")
        #expect(form.commandPreview().contains("--model sonnet"))
        form.modelChoice = .default
        form.profiles.profiles.append(LaunchProfile(id: "opus-work", name: "opus-work", kind: .claude, defaultModel: "opus"))
        form.setProfile("opus-work")
        #expect(form.modelTitle(.default) == "預設（啟動設定檔：opus）")
        #expect(form.defaultModelHint == "啟動設定檔「opus-work」指定 --model opus")
        #expect(form.request.claude.model == nil, "the profile's own model is applied at launch")
        #expect(form.commandPreview().contains("--model opus"))
        form.setProfile(LaunchProfileDocument.builtInDefaultId)
        #expect(form.modelTitle(.default) == "預設（跟隨 Claude Code 設定）")
        #expect(!form.commandPreview().contains("--model"))
    }
}

// MARK: - Folder drops reveal their project

/// A real store on an empty temp data root with the real sidebar in a window that is never shown;
/// drops go through the outline's own drag methods (`SyntheticDraggingInfo`).
@MainActor
private final class FBDropSeed {
    let path: String
    let store: HolderSessionStore
    let shell = ShellState()
    let controller: SidebarViewController
    let window: NSWindow

    init() async throws {
        path = try fbTemp("codd-fbdrop")
        let root = CoddDataRoot(path: path + "/root")
        let claude = ClaudeDirectory(path: path + "/claude")
        try FileManager.default.createDirectory(atPath: claude.path + "/projects", withIntermediateDirectories: true)
        // Never spawned: these tests start no session.
        let launcher = HolderLauncher(holderExecutable: "/usr/bin/false", root: root, shellArgvOverride: ["/bin/sh", "-c", "exec /bin/cat"],
                                      claudePathOverride: "/usr/bin/false")
        store = HolderSessionStore(root: root, launcher: launcher, claudeDirectory: claude, hooks: nil) { _ in }
        store.processAncestors = { _ in [1] }
        await store.start()
        controller = SidebarViewController(env: SidebarEnvironment(store: store, accounts: MockAccountStore(), shell: shell, realMode: true))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 300, height: 900))
        window.layoutIfNeeded()
    }

    func folder(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: path + "/work/" + name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func drop(_ urls: [URL], on target: NodeKind, _ fraction: CGFloat = 0.5) throws -> SyntheticDropResult {
        controller.applyNow()
        let info = try #require(controller.syntheticInfo(at: target, fraction: fraction, ownRows: false, fileURLs: urls))
        defer { info.release() }
        return controller.syntheticDrop(info)
    }

    func close() {
        window.close()
        store.shutdown()
        try? FileManager.default.removeItem(atPath: path)
    }
}

@MainActor
@Suite("fb: a dropped folder's project is revealed and pulses", .serialized)
struct FBFolderDropRevealTests {
    @Test func aNewFolderIsSelectedScrolledAndPulses() async throws {
        let s = try await FBDropSeed()
        defer { s.close() }
        s.controller.pulsesAllowed = { true }
        let group = s.store.addGroup(name: "工作", color: .blue)
        let folder = try s.folder("new-app")
        let result = try s.drop([folder], on: .group(group))
        #expect(result.performed && result.operation == .copy)
        let project = try #require(s.store.project(forPath: folder.path))
        #expect(project.groupID == group)
        #expect(selectedProjects(s.controller) == [project.id])
        #expect(s.controller.lastHighlight?.projects == [project.id] && s.controller.lastHighlight?.animated == true)
        let row = try #require(rowView(s.controller, .project(project.id)))
        #expect(row.isPulsing && row.lastPulseAnimated == true)
        #expect(row.isSelected)
        let index = s.controller.outline.row(forItem: s.controller.item(for: .project(project.id)))
        #expect(s.controller.outline.visibleRect.intersects(s.controller.outline.rect(ofRow: index)), "scrolled into view")
        #expect(s.controller.currentToast == nil, "a new project needs no toast")
        let dump = try #require(s.controller.dumpObject()["highlight"] as? [String: Any])
        #expect(dump["projects"] as? [String] == [project.id] && dump["animated"] as? Bool == true)
        #expect(s.controller.dumpObject()["selectedProjects"] as? [String] == [project.id])
        // The highlight goes after about a second; the selection stays.
        await m3Eventually("the pulse ends", timeout: .seconds(4)) { !row.isPulsing }
        #expect(selectedProjects(s.controller) == [project.id])
    }

    @Test func aFolderThatIsAlreadyAProjectIsRevealedToo() async throws {
        let s = try await FBDropSeed()
        defer { s.close() }
        let group = s.store.addGroup(name: "工作", color: .green)
        let folder = try s.folder("known")
        #expect(try s.drop([folder], on: .group(group)).performed)
        let project = try #require(s.store.project(forPath: folder.path))
        // Hidden away: its group and itself collapsed, nothing selected; 減少動態 on.
        s.controller.toggleCollapsed(.project(project.id))
        s.controller.toggleCollapsed(.group(group))
        #expect(project.isCollapsed && s.store.group(group)?.isCollapsed == true)
        s.controller.applyNow()
        s.controller.outline.deselectAll(nil)
        #expect(!s.controller.outline.isItemExpanded(s.controller.item(for: .group(group))))
        s.controller.pulsesAllowed = { false }
        let count = s.store.groups.flatMap(\.projectIDs).count
        let again = try s.drop([folder], on: .addGroup)
        #expect(again.performed)
        #expect(s.store.groups.flatMap(\.projectIDs).count == count, "not added twice")
        #expect(s.store.group(group)?.isCollapsed == false && project.isCollapsed == false, "its group and itself open")
        #expect(selectedProjects(s.controller) == [project.id])
        #expect(s.controller.lastHighlight?.projects == [project.id] && s.controller.lastHighlight?.animated == false)
        let row = try #require(rowView(s.controller, .project(project.id)))
        #expect(row.isPulsing && row.lastPulseAnimated == false, "with 減少動態 the highlight shows without animation")
        #expect(s.controller.currentToast != nil, "the toast says it already is a project")
        #expect(s.controller.lastDrop?["existing"] as? Int == 1 && s.controller.lastDrop?["added"] as? Int == 0)
        await m3Eventually("the still highlight goes", timeout: .seconds(4)) { !row.isPulsing }
    }

    @Test func severalFoldersAreAllRevealed() async throws {
        let s = try await FBDropSeed()
        defer { s.close() }
        s.controller.pulsesAllowed = { true }
        let known = try s.folder("one")
        #expect(try s.drop([known], on: .addGroup).performed)
        let fresh = try s.folder("two")
        let result = try s.drop([fresh, known], on: .addGroup)
        #expect(result.performed)
        let ids = try [fresh, known].map { try #require(s.store.project(forPath: $0.path)).id }
        #expect(Set(selectedProjects(s.controller)) == Set(ids))
        #expect(s.controller.lastHighlight?.projects == ids)
        for id in ids { #expect(rowView(s.controller, .project(id))?.isPulsing == true) }
    }
}
