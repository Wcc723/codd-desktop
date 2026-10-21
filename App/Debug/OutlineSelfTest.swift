#if DEBUG
import AppKit
import CoddUI

/// Drives the real sidebar NSOutlineView through hundreds of model mutations (state changes,
/// drags, collapse, filter, mode, add / delete / archive) and checks after each one that the
/// outline's rows equal the snapshot as expanded on screen. A mismatch would mean the diff
/// sent inconsistent insert / remove / move calls (the crash class `reloadData` would hide).
@MainActor
struct OutlineSelfTest {
    let app: AppDelegate
    private var generator = SystemRandomNumberGenerator()

    init(app: AppDelegate) { self.app = app }

    mutating func run() -> Bool {
        guard let sidebar = app.mainWindow?.sidebar else { return false }
        let store = app.sessionStore
        var steps = 0
        func verify(_ label: String) -> Bool {
            steps += 1
            sidebar.applyNow()
            if let problem = Self.mismatch(sidebar) {
                print("SELFTEST mismatch after \(label): \(problem)")
                return false
            }
            return true
        }

        // Scripted cases first.
        store.answer("s1", key: "1")
        guard verify("answer s1") else { return false }
        store.session("s6")?.state = .waiting
        store.session("s6")?.waitingReason = .question
        guard verify("s6 waiting") else { return false }
        store.moveSessions(["s6"], toIndex: 0, inProject: "proto")
        guard verify("reorder s6") else { return false }
        store.moveProjects(["invoice"], toGroup: "northlab", atIndex: 1)
        guard verify("move invoice") else { return false }
        store.moveGroups(["github"], toIndex: 0)
        guard verify("move group github") else { return false }
        sidebar.toggleCollapsed(.group("northweb"))
        guard verify("collapse northweb") else { return false }
        store.moveProjects(["frontend"], toGroup: "codd", atIndex: 0)
        guard verify("move into collapsed") else { return false }
        sidebar.toggleCollapsed(.group("northweb"))
        sidebar.toggleCollapsed(.group("codd"))
        guard verify("expand both") else { return false }
        app.shell.filterText = "打卡"
        guard verify("filter") else { return false }
        app.shell.filterText = ""
        guard verify("clear filter") else { return false }
        let undo = store.archive(["s9", "s2"])
        guard verify("archive") else { return false }
        undo()
        guard verify("undo archive") else { return false }
        let gid = store.addGroup(name: "測試群組", color: .cyan)
        store.moveProjects(["gear", "pixel"], toGroup: gid, atIndex: 0)
        guard verify("new group") else { return false }
        store.deleteGroup(gid)
        guard verify("delete group") else { return false }
        app.shell.sidebarMode = .state
        guard verify("state mode") else { return false }
        app.shell.sidebarMode = .tree
        guard verify("tree mode") else { return false }

        // M2 rows: the inline new-group editor, group cleanup + archive restore, the hover card.
        sidebar.beginNewGroup()
        guard verify("new-group editor"), sidebar.snapshot.contains(.newGroup) else { print("SELFTEST no new-group row"); return false }
        sidebar.toggleNewGroupColorPopover()
        _ = sidebar.newGroupDigit("3")
        guard verify("new-group digit"), sidebar.newGroupEditor?.color == .green else { print("SELFTEST digit 3 did not pick green"); return false }
        sidebar.cancelNewGroup()
        guard verify("new-group cancel"), sidebar.snapshot.contains(.addGroup) else { return false }
        sidebar.beginNewGroup()
        sidebar.newGroupEditor?.name = "自測群組"
        guard let created = sidebar.commitNewGroup(), verify("new-group commit") else { return false }
        store.deleteGroup(created)
        guard verify("delete created group") else { return false }
        let stopped = sidebar.stoppedSessions(inGroup: "github")
        sidebar.cleanupStopped(inGroup: "github")
        guard verify("cleanup stopped") else { return false }
        sidebar.restore(stopped)
        guard verify("restore archived") else { return false }
        if let row = (0..<sidebar.outline.numberOfRows).first(where: { sidebar.kind(atRow: $0)?.sessionID != nil }),
           let node = sidebar.kind(atRow: row) {
            sidebar.hoverCard.show(node, row: row, force: true)
            guard verify("hover card"), sidebar.hoverCard.isShown else { print("SELFTEST hover card not shown"); return false }
            sidebar.hoverCard.hide()
            guard verify("hover card hidden") else { return false }
        }

        // Random mutations.
        let states: [SessionState] = [.waiting, .error, .done, .busy, .compacting, .idle, .shell, .exited, .stopped]
        for i in 0..<400 {
            let sessions = store.allSessions
            let groups = store.groups
            let projects = groups.flatMap(\.projectIDs).compactMap(store.project)
            switch Int.random(in: 0..<10, using: &generator) {
            case 0, 1, 2:
                if let s = sessions.randomElement(using: &generator), let st = states.randomElement(using: &generator) {
                    s.state = st
                    if st == .waiting { s.waitingReason = .permission }
                }
            case 3:
                if let p = projects.randomElement(using: &generator), let id = p.sessionIDs.randomElement(using: &generator) {
                    store.moveSessions([id], toIndex: Int.random(in: 0...p.sessionIDs.count, using: &generator), inProject: p.id)
                }
            case 4:
                if let p = projects.randomElement(using: &generator), let g = groups.randomElement(using: &generator) {
                    store.moveProjects([p.id], toGroup: g.id, atIndex: Int.random(in: 0...g.projectIDs.count, using: &generator))
                }
            case 5:
                if let g = groups.randomElement(using: &generator) { sidebar.toggleCollapsed(.group(g.id)) }
            case 6:
                if let p = projects.randomElement(using: &generator) { sidebar.toggleCollapsed(.project(p.id)) }
            case 7:
                if let s = sessions.randomElement(using: &generator) { store.setPinned(!s.isPinned, sessions: [s.id]) }
            case 8:
                if Int.random(in: 0..<4, using: &generator) == 0 {
                    // The inline editor appears and goes (only in TREE without a filter).
                    if sidebar.newGroupEditor == nil { sidebar.beginNewGroup() } else { sidebar.cancelNewGroup() }
                } else {
                    sidebar.cancelNewGroup()
                    app.shell.filterText = ["", "", "", "a", "打卡", "test", "CODD", "網站"].randomElement(using: &generator) ?? ""
                }
            default:
                if Bool.random(using: &generator), let g = groups.filter({ !$0.isUngrouped }).randomElement(using: &generator) {
                    store.moveGroups([g.id], toIndex: Int.random(in: 0...groups.count, using: &generator))
                } else {
                    sidebar.setMode(Int.random(in: 0..<6, using: &generator) == 0 ? .state : .tree)
                }
            }
            guard verify("random step \(i)") else { return false }
        }
        sidebar.cancelNewGroup()
        sidebar.hoverCard.hide()
        print("SELFTEST steps=\(steps) outlineOps=\(sidebar.appliedOperations) rows=\(sidebar.outline.numberOfRows)")
        return true
    }

    /// Main-menu key equivalents (⌘1–9, ⌃Tab, ⌘K) and title-bar hit testing of the custom header.
    func checkShortcutsAndChrome() -> Bool {
        guard let main = app.mainWindow, let window = main.window, let menu = NSApp.mainMenu else { return false }
        var ok = true
        func press(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { return false }
            return menu.performKeyEquivalent(with: event)
        }
        app.shell.filterText = ""
        app.shell.sidebarMode = .tree
        main.sidebar.applyNow()
        let order = main.sidebar.snapshot.sessionOrder
        if !press("2", 19, .command) || app.shell.currentSessionID != order[1] {
            print("SELFTEST ⌘2 failed: current=\(app.shell.currentSessionID ?? "nil") expected=\(order[1])"); ok = false
        }
        if !press("\t", 48, .control) || app.shell.currentSessionID != order[2] {
            print("SELFTEST ⌃Tab failed: current=\(app.shell.currentSessionID ?? "nil") expected=\(order[2])"); ok = false
        }
        if !press("k", 40, .command) || !NSApp.windows.contains(where: { $0 is PalettePanel && $0.isVisible }) {
            print("SELFTEST ⌘K failed"); ok = false
        }
        app.showQuickSwitch(nil) // close it again
        if !checkTabShortcuts(press: press, main: main, window: window) { ok = false }
        // Buttons drawn under the transparent title bar must still receive clicks.
        if let frame = window.contentView?.superview {
            for (name, view) in [("sidebar ⌘K", main.sidebar.view.descendant(ofType: CoddButton.self)), ("rail", main.rail.view.descendant(ofType: RailItemButton.self))] {
                guard let view else { continue }
                let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
                let hit = frame.hitTest(frame.convert(point, from: nil))
                if !(hit === view || hit?.isDescendant(of: view) == true) {
                    print("SELFTEST hit test failed for \(name): got \(hit.map { String(describing: type(of: $0)) } ?? "nil")"); ok = false
                }
            }
        }
        if !checkTrafficLights(window) { ok = false }
        if ok { print("SELFTEST shortcuts + title-bar hit tests OK") }
        return ok
    }

    /// ⌘T adds a terminal in the bottom panel, ⌘W (the menu's performClose) closes that tab and not
    /// the window, ⌘J opens and closes the bottom panel; inside it `+` adds a tab, maximize fills the
    /// area and ⌘W closes the panel's shown tab only.
    private func checkTabShortcuts(press: (String, UInt16, NSEvent.ModifierFlags) -> Bool, main: MainWindowController,
                                   window: NSWindow) -> Bool {
        guard let id = app.shell.currentSessionID else { print("SELFTEST tabs: no session"); return false }
        let before = app.shell.pane(for: id).panelTabs.count
        guard press("t", 17, .command), app.shell.pane(for: id).panelTabs.count == before + 1,
              app.shell.pane(for: id).panelOpen else {
            print("SELFTEST ⌘T failed: panel tabs=\(app.shell.pane(for: id).panelTabs.count)"); return false
        }
        let closeItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first { $0.action == #selector(NSWindow.performClose(_:)) }
        window.performClose(closeItem)
        guard app.shell.pane(for: id).panelTabs.count == before, window.isVisible else {
            print("SELFTEST ⌘W failed: panel tabs=\(app.shell.pane(for: id).panelTabs.count) visible=\(window.isVisible)"); return false
        }
        // Closing a tab leaves the panel open on a neighbour: hide it for the ⌘J check below.
        if app.shell.pane(for: id).panelOpen { main.pane.toggleBottomTerminal() }
        guard press("j", 38, .command), app.shell.pane(for: id).panelOpen else {
            print("SELFTEST ⌘J failed"); return false
        }
        // The panel's `+` and maximize; ⌘W then closes only the panel's shown tab (D11).
        let panelTabs = app.shell.pane(for: id).panelTabs.count
        main.pane.newPanelTab()
        main.pane.toggleMaximizePanel()
        guard app.shell.pane(for: id).panelTabs.count == panelTabs + 1, main.pane.isPanelMaximized else {
            print("SELFTEST panel tabs failed: tabs=\(app.shell.pane(for: id).panelTabs.count) maximized=\(main.pane.isPanelMaximized)")
            return false
        }
        window.performClose(closeItem)
        guard app.shell.pane(for: id).panelTabs.count == panelTabs, window.isVisible else {
            print("SELFTEST ⌘W in the panel failed: tabs=\(app.shell.pane(for: id).panelTabs.count)"); return false
        }
        main.pane.toggleMaximizePanel()
        guard !main.pane.isPanelMaximized, press("j", 38, .command), !app.shell.pane(for: id).panelOpen else {
            print("SELFTEST ⌘J failed"); return false
        }
        print("SELFTEST panel tabs + maximize OK")
        print("SELFTEST ⌘T ⌘W ⌘J OK")
        return true
    }

    /// The native traffic lights must sit inside the top header band (52 px) and over the rail,
    /// clear of the sidebar brand (rail 72 px + 16 px sidebar padding).
    private func checkTrafficLights(_ window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        var union = CGRect.null
        for type in buttons {
            guard let button = window.standardWindowButton(type), button.superview != nil else {
                print("SELFTEST traffic light \(type.rawValue) missing"); return false
            }
            union = union.union(content.convert(button.convert(button.bounds, to: nil), from: nil))
        }
        // contentView is not flipped: y grows upward, so the top band is near bounds.maxY.
        let topInset = content.bounds.maxY - union.maxY
        let bottomInset = content.bounds.maxY - union.minY
        print(String(format: "SELFTEST traffic lights x %.0f…%.0f, y %.0f…%.0f from top", union.minX, union.maxX, topInset, bottomInset))
        guard union.maxX <= Metrics.railWidth + 16, bottomInset <= Metrics.headerHeight else {
            print("SELFTEST traffic lights outside the header band / rail"); return false
        }
        return true
    }

    /// Compares outline rows with the snapshot flattened through the MODEL's expansion state
    /// (so a group the model wants collapsed but the outline shows expanded is a mismatch).
    static func mismatch(_ sidebar: SidebarViewController) -> String? {
        var expected: [NodeKind] = []
        var expansionProblem: String?
        func walk(_ parent: NodeKind?) {
            for child in sidebar.snapshot.childrenOf(parent) {
                expected.append(child)
                let item = sidebar.item(for: child)
                let hasChildren = !sidebar.snapshot.childrenOf(child).isEmpty
                if hasChildren, sidebar.outline.isItemExpanded(item) != sidebar.wantsExpanded(child), expansionProblem == nil {
                    expansionProblem = "\(child) expanded=\(sidebar.outline.isItemExpanded(item)) but model wants \(sidebar.wantsExpanded(child))"
                }
                if sidebar.outline.isItemExpanded(item) {
                    let count = sidebar.outline.numberOfChildren(ofItem: item)
                    if count != sidebar.snapshot.childrenOf(child).count {
                        expected.append(.addGroup) // force a mismatch report below
                    }
                    walk(child)
                }
            }
        }
        walk(nil)
        if let expansionProblem { return expansionProblem }
        let actual = (0..<sidebar.outline.numberOfRows).compactMap { sidebar.kind(atRow: $0) }
        if actual != expected {
            let firstDiff = zip(actual, expected).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actual.count, expected.count)
            return "rows \(actual.count) vs expected \(expected.count), first difference at \(firstDiff)"
        }
        return nil
    }
}
#endif
