import AppKit
import CoddUI

/// Outline item: a stable object per `NodeKind` (NSOutlineView tracks items by identity).
final class SidebarItem: NSObject {
    let kind: NodeKind
    init(_ kind: NodeKind) { self.kind = kind }
}

/// SESSIONS sidebar: head, filter, the NEEDS YOU / PINNED / group tree (view-based
/// NSOutlineView, fixed row heights, cell reuse) and the usage footer.
///
/// Structure changes arrive through one `ObservationLoop` that rebuilds a `SidebarSnapshot`
/// and diffs it into insert / remove / move calls (`OutlineDiffer`); `reloadData` is never
/// called after the first load. Row content updates itself per cell (see `SidebarCellView`).
final class SidebarViewController: NSViewController {
    let env: SidebarEnvironment
    var store: any SessionStore { env.store }
    var shell: ShellState { env.shell }

    private(set) var snapshot = SidebarSnapshot()
    let outline = SidebarOutlineView()
    private let scrollView = SidebarScrollView()
    private let header = SidebarHeaderView()
    private let filter = FilterField()
    private let modeSwitch = SegmentedSwitch(titles: ["Tree", "State"])
    private(set) lazy var footer = SidebarFooterView(store: env.store, accounts: env.accounts, shell: env.shell, realMode: env.realMode)
    let selectionBar = SelectionBarView()

    private var items: [NodeKind: SidebarItem] = [:]
    private var structureLoop: ObservationLoop?
    private var currentLoop: ObservationLoop?
    private var pendingReloads: [NodeKind] = []
    private var scrollObserver: NSObjectProtocol?
    private var isSyncingSelection = false
    var draggedNodes: [NodeKind] = []
    /// The folders of the Finder drag under way (`validateDrop` runs on every pointer move).
    var folderDropCache: (sequence: Int, paths: [String])?
    /// The last drop (row move or folders) for the `sidebar` state dump.
    var lastDrop: [String: Any]?
    /// Rows drawn as the drag ghost (SidebarStates A `.ss-ghost`) while a drag is under way.
    var dragGhostEdges: [NodeKind: BlockEdge] = [:]
    var dropTargetBlock: BlockID? { didSet { if dropTargetBlock != oldValue { refreshRowDecorations() } } }
    let renamer = InlineRenamer()
    /// SidebarStates F: the 380 ms hover card next to a session row.
    let hoverCard = HoverCardController()
    /// SidebarStates D: the open inline new-group editor (nil when `[+ 新增群組]` shows).
    private(set) var newGroupEditor: NewGroupEditor?
    /// The new-group color popover (a child panel; nil until first opened).
    private(set) var colorPopover: GroupColorPopoverPanel?
    /// SidebarStates A: the amber insertion line while dragging, and the drop it shows.
    let dropLine = DropLineView()
    var dropPlan: DropPlan?

    /// Number of fine-grained outline operations so far (debug self-test / tests).
    private(set) var appliedOperations = 0

    var onQuickSwitch: (() -> Void)?
    var onNewMenu: ((CoddButton) -> Void)?
    /// Real mode: opens the ⌘N sheet prefilled (a project's folder, a group). Nil in mock mode.
    var onNewSession: ((NewSessionForm) -> Void)?
    /// Real mode: starts a session right away and shows (selects) it, for the `+` on a project
    /// row; returns the reason when it was refused. Nil in mock mode (the `+` beeps).
    var onStartSession: ((NewSessionRequest) -> String?)?
    /// The projects the latest reveal highlighted (a dropped folder, ⌘O) and whether the pulse was
    /// animated (tests, the `sidebar` dump).
    private(set) var lastHighlight: (projects: [ProjectID], animated: Bool)?
    /// Whether the reveal pulse may animate: Settings › 外觀 › 減少動態, else the system setting
    /// (`UITicker`). Injectable for tests.
    var pulsesAllowed: @MainActor () -> Bool = { UITicker.shared.pulsesAllowed }
    var onOpenSettings: ((String) -> Void)?
    /// A new snapshot was applied (DEBUG: the `sidebar` state dump follows it).
    var onSnapshotChanged: (() -> Void)?

    init(env: SidebarEnvironment) {
        self.env = env
        super.init(nibName: nil, bundle: nil)
        env.controller = self
        hoverCard.sidebar = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: View

    override func loadView() {
        let root = PanelView(fill: Palette.bg)
        root.edges = []

        let filterRow = hStack([filter, modeSwitch], spacing: 6, edgeInsets: NSEdgeInsets(top: 8, left: 8, bottom: 2, right: 8))
        filter.heightAnchor.constraint(equalToConstant: 26).zoomed(26).isActive = true
        // Fixed at the height it has always had (the field centred, 8 above and below: the stack's
        // centerY alignment mirrors the top inset). The stack's insets are not required, so without
        // this the row could be squeezed under the header (seen in background launches).
        filterRow.heightAnchor.constraint(equalToConstant: 42).zoomed(42).isActive = true
        modeSwitch.target = self
        modeSwitch.action = #selector(modeChanged)
        modeSwitch.setAccessibilityLabel("檢視方式")
        filter.onChange = { [weak self] text in
            self?.hoverCard.hide()
            self?.shell.filterText = text
        }

        configureOutline()
        scrollView.documentView = outline
        scrollView.registerForDraggedTypes(SidebarDrag.acceptedTypes)
        scrollView.dropTarget = self
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 0, bottom: 10, right: 0)
        // The new-group color popover follows its row when the list scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.positionColorPopover() }
        }

        header.searchButton.target = self
        header.searchButton.action = #selector(quickSwitch)
        header.newButton.target = self
        header.newButton.action = #selector(newMenu(_:))
        footer.onOpenAutoSwitchSettings = { [weak self] in self?.onOpenSettings?("accounts") }
        footer.onToast = { [weak self] text, undo in self?.showToast(text, undo: undo) }
        selectionBar.isHidden = true
        selectionBar.controller = self

        for view in [header, filterRow, scrollView, selectionBar, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 0).zoomed(Metrics.Design.headerHeight),
            filterRow.topAnchor.constraint(equalTo: header.bottomAnchor),
            filterRow.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            filterRow.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: filterRow.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            selectionBar.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            selectionBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: selectionBar.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private func configureOutline() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = false
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.selectionHighlightStyle = .regular
        outline.allowsMultipleSelection = true
        outline.allowsEmptySelection = true
        outline.allowsTypeSelect = false
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.focusRingType = .none
        // SidebarStates A draws its own amber insertion line (`DropLineView`) instead of a gap.
        outline.draggingDestinationFeedbackStyle = .none
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // Rows never leave the app (the payload is a private marker anyway).
        outline.setDraggingSourceOperationMask([], forLocal: false)
        // Our own rows, and folders from Finder (M4: they become projects).
        outline.registerForDraggedTypes(SidebarDrag.acceptedTypes)
        dropLine.isHidden = true
        outline.addSubview(dropLine)
        outline.dataSource = self
        outline.delegate = self
        outline.actions = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.setAccessibilityLabel("Sessions")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        snapshot = buildSnapshot()
        outline.reloadData() // first load only; every later change is a diff
        syncExpansion(animated: false)
        refreshBlockEdges()
        structureLoop = ObservationLoop(track: { [weak self] in self?.buildSnapshot() },
                                        apply: { [weak self] snap in if let snap { self?.apply(snap) } })
        currentLoop = ObservationLoop(track: { [weak self] in self?.shell.currentSessionID },
                                      apply: { [weak self] id in self?.currentDidChange(id) })
        modeSwitch.selectedIndex = shell.sidebarMode == .tree ? 0 : 1
        if !shell.filterText.isEmpty { filter.field.stringValue = shell.filterText }
    }

    // MARK: Snapshot

    func buildSnapshot() -> SidebarSnapshot {
        SidebarSnapshotBuilder.build(store: store, mode: shell.sidebarMode, filter: shell.filterText,
                                     addingGroup: shell.isAddingGroup && shell.sidebarMode == .tree)
    }

    /// Applies a new snapshot with fine-grained outline operations.
    func apply(_ new: SidebarSnapshot) {
        guard new != snapshot else { return }
        let old = snapshot
        snapshot = new
        pendingReloads.removeAll()
        outline.beginUpdates()
        OutlineDiffer.apply(from: old, to: new, sink: self)
        outline.endUpdates()
        for node in pendingReloads { outline.reloadItem(item(for: node), reloadChildren: true) }
        pendingReloads.removeAll()
        let alive = Set(new.allNodes().map(\.node))
        items = items.filter { alive.contains($0.key) }
        syncExpansion(animated: false)
        refreshBlockEdges()
        syncSelectionToCurrent()
        outline.refreshHover()
        if newGroupEditor != nil, !snapshot.contains(.newGroup) { closeNewGroupEditor() }
        positionColorPopover()
        if hoverCard.isShown { hoverCard.reposition() }
        // Rows can move mid-drag (a session turns WAITING and NEEDS YOU grows): the line follows.
        if let dropPlan, !dropLine.isHidden { showDropLine(for: dropPlan) }
        onSnapshotChanged?()
    }

    func item(for kind: NodeKind) -> SidebarItem {
        if let existing = items[kind] { return existing }
        let made = SidebarItem(kind)
        items[kind] = made
        return made
    }

    /// Kind of the node at an outline row.
    func kind(atRow row: Int) -> NodeKind? { (outline.item(atRow: row) as? SidebarItem)?.kind }

    // MARK: Expansion

    /// Whether the model wants this node expanded.
    func wantsExpanded(_ kind: NodeKind) -> Bool {
        switch kind {
        case .section(let s): !shell.collapsedSections.contains(s)
        case .group(let id): !(store.group(id)?.isCollapsed ?? false)
        case .project(let id): !(store.project(id)?.isCollapsed ?? false)
        default: false
        }
    }

    /// Makes the outline's expansion match the model for every visible expandable node.
    func syncExpansion(animated: Bool, under parent: NodeKind? = nil) {
        func walk(_ p: NodeKind?) {
            for child in snapshot.childrenOf(p) where !snapshot.childrenOf(child).isEmpty {
                let it = item(for: child)
                let want = wantsExpanded(child)
                let has = outline.isItemExpanded(it)
                if want, !has { (animated ? outline.animator() : outline).expandItem(it) }
                if !want, has { (animated ? outline.animator() : outline).collapseItem(it) }
                if want { walk(child) }
            }
        }
        walk(parent)
    }

    func toggleCollapsed(_ kind: NodeKind) {
        switch kind {
        case .section(let s):
            if shell.collapsedSections.contains(s) { shell.collapsedSections.remove(s) } else { shell.collapsedSections.insert(s) }
        case .group(let id):
            store.setCollapsed(!(store.group(id)?.isCollapsed ?? false), group: id)
        case .project(let id):
            store.setCollapsed(!(store.project(id)?.isCollapsed ?? false), project: id)
        default:
            return
        }
        let it = item(for: kind)
        if wantsExpanded(kind) {
            outline.animator().expandItem(it)
            syncExpansion(animated: false, under: kind)
        } else {
            outline.animator().collapseItem(it)
        }
        refreshBlockEdges()
    }

    // MARK: Row decorations

    /// Recomputes which visible rows start / end a block.
    func refreshBlockEdges() {
        outline.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? SidebarRowView else { return }
            self.decorate(rowView, row: row)
        }
    }

    func decorate(_ rowView: SidebarRowView, row: Int) {
        guard let node = kind(atRow: row) else { return }
        let block = snapshot.block(of: node)
        let prev = row > 0 ? kind(atRow: row - 1).flatMap(snapshot.block(of:)) : nil
        let next = row + 1 < outline.numberOfRows ? kind(atRow: row + 1).flatMap(snapshot.block(of:)) : nil
        let isHeader: Bool
        switch node {
        case .group, .section: isHeader = true
        default: isHeader = false
        }
        let startsBlock = isHeader || prev != block
        let endsBlock = next != block
        switch (startsBlock, endsBlock) {
        case (true, true): rowView.edge = .single
        case (true, false): rowView.edge = .top
        case (false, true): rowView.edge = .bottom
        case (false, false): rowView.edge = .middle
        }
        rowView.isDropTarget = block != nil && block == dropTargetBlock
        rowView.ghostEdge = dragGhostEdges[node]
        rowView.showsMultiSelection = outline.numberOfSelectedRows > 1
    }

    private func refreshRowDecorations() { refreshBlockEdges() }

    // MARK: Selection ↔ current session

    /// Selects the tree row of `id` (expanding its group/project if needed).
    func reveal(_ id: SessionID) {
        guard let session = store.session(id) else { return }
        var target = NodeKind.session(id, .tree)
        if !snapshot.contains(target) {
            if let mirror = snapshot.allNodes().map(\.node).first(where: { $0.sessionID == id }) { target = mirror } else { return }
        }
        if target == .session(id, .tree), let project = store.project(session.projectID) {
            if project.isCollapsed { store.setCollapsed(false, project: project.id) }
            if store.group(project.groupID)?.isCollapsed == true { store.setCollapsed(false, group: project.groupID) }
            syncExpansion(animated: false)
            refreshBlockEdges()
        }
        let row = outline.row(forItem: item(for: target))
        guard row >= 0 else { return }
        isSyncingSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isSyncingSelection = false
        outline.scrollRowToVisible(row)
    }

    /// Projects the user pointed at (a dropped folder, ⌘O, onboarding's first project): their
    /// group opens, the tree view shows them (a filter that hides one is cleared) and their rows are
    /// selected (drawn `.srow.sel`) and scrolled into view. The current session does not change.
    /// - Parameters:
    ///   - expand: a collapsed project opens too (its sessions show).
    ///   - highlight: their rows pulse amber once (``highlightProjects(_:)``).
    func revealProjects(_ ids: [ProjectID], expand: Bool = false, highlight: Bool = false) {
        let projects = ids.compactMap(store.project)
        guard !projects.isEmpty else { return }
        if shell.sidebarMode != .tree { setMode(.tree) }
        for project in projects {
            if store.group(project.groupID)?.isCollapsed == true { store.setCollapsed(false, group: project.groupID) }
            if expand, project.isCollapsed { store.setCollapsed(false, project: project.id) }
        }
        applyNow()
        if projects.contains(where: { !snapshot.contains(.project($0.id)) }), !shell.filterText.isEmpty {
            setFilter("")
            applyNow()
        }
        syncExpansion(animated: false)
        refreshBlockEdges()
        let rows = projects.map { outline.row(forItem: item(for: .project($0.id))) }.filter { $0 >= 0 }
        guard let first = rows.min() else { return }
        // `selectionChanged` sees no session: the current one stays, the multi-select bar goes.
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        // `scrollRowToVisible` ignores the scroll view's insets: a little room around the row.
        outline.scrollToVisible(outline.rect(ofRow: first).insetBy(dx: 0, dy: -8))
        if highlight { highlightProjects(projects.map(\.id)) }
    }

    /// The reveal pulse on these projects' rows (about 1 s, amber); with 減少動態 the highlight
    /// shows without animation for the same time.
    func highlightProjects(_ ids: [ProjectID]) {
        let animated = pulsesAllowed()
        lastHighlight = (ids, animated)
        for id in ids {
            let row = outline.row(forItem: item(for: .project(id)))
            guard row >= 0, let rowView = outline.rowView(atRow: row, makeIfNecessary: true) as? SidebarRowView else { continue }
            rowView.pulse(animated: animated)
        }
    }

    /// Folders → projects: a Finder drop (`group` / `index` from the drop position) and 新增專案 /
    /// ⌘O (nil: where 新增專案 puts them) share this. Every folder's project, new or already there,
    /// is revealed (its group and itself opened, scrolled into view), selected and pulses once;
    /// folders that already are projects are not added again and a toast says so.
    @discardableResult
    func addFolders(_ paths: [String], toGroup group: GroupID?, atIndex index: Int?) -> [ProjectAddition] {
        guard store.canAddProjects, !paths.isEmpty else { return [] }
        let results = store.addProjects(paths: paths, toGroup: group, atIndex: index)
        applyNow()
        var seen = Set<ProjectID>()
        let projects = results.compactMap(\.projectID).filter { seen.insert($0).inserted }
        if !projects.isEmpty { revealProjects(projects, expand: true, highlight: true) }
        let existing = results.filter { !$0.added }.compactMap(\.projectID)
        if !existing.isEmpty {
            let names = existing.compactMap { store.project($0)?.name }
            showToast(names.count == 1 ? "「\(names[0])」已經是專案" : "\(names.count) 個資料夾已經是專案", undo: nil)
        }
        return results
    }

    // MARK: Project `+`

    /// `+` on a project row: a claude session in its folder right away (no sheet) with the default
    /// launch profile (D5) and the global login (D12), no `--model` unless that profile names one;
    /// the app shows and selects it. A refusal (folder gone, still loading) beeps with a toast.
    @discardableResult
    func startClaudeSession(inProject id: ProjectID) -> Bool {
        hoverCard.hide()
        guard let onStartSession, let project = store.project(id), !project.isTransient else {
            NSSound.beep()
            return false
        }
        if let problem = onStartSession(Self.quickLaunchRequest(cwd: project.cwd)) {
            NSSound.beep()
            showToast(problem, undo: nil)
            return false
        }
        return true
    }

    /// What the `+` starts: a new claude conversation in `cwd` (`~` expanded) with no profile
    /// (the default one runs), no account pin (the global login), no model, permission mode or name.
    static func quickLaunchRequest(cwd: String) -> NewSessionRequest {
        var request = NewSessionRequest(cwd: PathFormat.expandTilde(cwd), kind: .claude)
        request.claude.mode = .new
        request.claude.profileID = nil
        request.claude.accountNumber = nil
        request.claude.model = nil
        request.claude.permissionMode = nil
        return request
    }

    private func currentDidChange(_ id: SessionID?) {
        guard let id else { return }
        let selected = outline.selectedRowIndexes.compactMap { kind(atRow: $0)?.sessionID }
        if selected.count > 1, selected.contains(id) { return }
        if selected != [id] { reveal(id) }
    }

    /// After structural changes the selected row may have vanished (e.g. a NEEDS YOU mirror).
    private func syncSelectionToCurrent() {
        guard let id = shell.currentSessionID, outline.numberOfSelectedRows == 0 else { return }
        reveal(id)
    }

    func selectionChanged() {
        guard !isSyncingSelection else { refreshBlockEdges(); return }
        let ids = outline.selectedRowIndexes.compactMap { kind(atRow: $0)?.sessionID }
        if ids.count == 1, let id = ids.first, id != shell.currentSessionID {
            if let previous = shell.currentSessionID { store.markSeen(previous) }
            shell.currentSessionID = id
        }
        selectionBar.update(count: Set(ids).count)
        refreshBlockEdges()
    }

    /// Session IDs the user acts on: the selection if the clicked row is part of it.
    func targetSessions(clickedRow: Int) -> [SessionID] {
        let selected = outline.selectedRowIndexes
        let rows = selected.contains(clickedRow) ? Array(selected) : [clickedRow]
        var seen = Set<SessionID>()
        return rows.compactMap { kind(atRow: $0)?.sessionID }.filter { seen.insert($0).inserted }
    }

    // MARK: Actions

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let kind = kind(atRow: row) else { return }
        switch kind {
        case .group:
            // A click on one of the header's hover buttons is the button's, not the row's.
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? GroupHeaderCellView,
               let point = NSApp.currentEvent?.locationInWindow, cell.actionButton(atWindowPoint: point) != nil { return }
            toggleCollapsed(kind)
        case .project:
            // A click on the row's `+` is the button's.
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? ProjectCellView,
               let point = NSApp.currentEvent?.locationInWindow, cell.actionButton(atWindowPoint: point) != nil { return }
            toggleCollapsed(kind)
        case .section:
            toggleCollapsed(kind)
        case .doneSummary:
            if let target = (outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? DoneSummaryCellView)?.targetSessionID {
                // Same rule as every other way of leaving a session: an unseen DONE becomes IDLE.
                if let previous = shell.currentSessionID, previous != target { store.markSeen(previous) }
                shell.currentSessionID = target
            }
        default:
            break
        }
    }

    @objc private func modeChanged() {
        setMode(modeSwitch.selectedIndex == 0 ? .tree : .state)
    }

    /// TREE | STATE (the toggle, `-codd-sidebar-mode`). An open new-group editor closes first.
    func setMode(_ mode: SidebarMode) {
        if mode != .tree, newGroupEditor != nil { cancelNewGroup() }
        hoverCard.hide()
        shell.sidebarMode = mode
        let index = mode == .tree ? 0 : 1
        if modeSwitch.selectedIndex != index { modeSwitch.selectedIndex = index }
    }

    /// `-codd-sidebar-filter`: types the query into the filter field.
    func setFilter(_ text: String) {
        filter.field.stringValue = text
        shell.filterText = text
    }

    @objc private func quickSwitch() { onQuickSwitch?() }
    @objc private func newMenu(_ sender: CoddButton) { onNewMenu?(sender) }

    func focusFilter() { view.window?.makeFirstResponder(filter.field) }

    // MARK: New group (SidebarStates D)

    /// `[+ 新增群組]`, `+ NEW ▾ › 新增群組`, the palette: the add row turns into the editor (tree
    /// mode, filter cleared), the name input focused.
    func beginNewGroup() {
        hoverCard.hide()
        if shell.sidebarMode != .tree { setMode(.tree) }
        if !shell.filterText.isEmpty { setFilter("") }
        if newGroupEditor == nil {
            newGroupEditor = NewGroupEditor(color: NewGroupEditor.defaultColor(in: store))
            shell.isAddingGroup = true
        }
        applyNow()
        let row = outline.row(forItem: item(for: .newGroup))
        guard row >= 0 else { return }
        // `scrollRowToVisible` ignores the scroll view's bottom inset; the popover sits below the row.
        outline.scrollToVisible(outline.rect(ofRow: row).insetBy(dx: 0, dy: -12))
        (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NewGroupCellView)?.focus()
    }

    /// Enter: creates the group with the typed name (`新群組` when blank) and color.
    @discardableResult
    func commitNewGroup() -> GroupID? {
        guard let editor = newGroupEditor else { return nil }
        let id = store.addGroup(name: editor.committedName, color: editor.color)
        closeNewGroupEditor()
        applyNow()
        let row = outline.row(forItem: item(for: .group(id)))
        if row >= 0 { outline.scrollRowToVisible(row) }
        view.window?.makeFirstResponder(outline)
        return id
    }

    /// Esc: nothing is created.
    func cancelNewGroup() {
        guard newGroupEditor != nil else { return }
        closeNewGroupEditor()
        applyNow()
        view.window?.makeFirstResponder(outline)
    }

    /// The name input lost the focus (a click elsewhere): a typed name is kept, a blank one is not.
    func newGroupFocusLost() {
        guard let editor = newGroupEditor else { return }
        if editor.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            closeNewGroupEditor()
            applyNow()
        } else {
            let id = store.addGroup(name: editor.committedName, color: editor.color)
            closeNewGroupEditor()
            applyNow()
            let row = outline.row(forItem: item(for: .group(id)))
            if row >= 0 { outline.scrollRowToVisible(row) }
        }
    }

    private func closeNewGroupEditor() {
        newGroupCell?.prepareToEnd()
        newGroupEditor = nil
        hideColorPopover()
        if shell.isAddingGroup { shell.isAddingGroup = false }
    }

    var newGroupCell: NewGroupCellView? {
        let row = outline.row(forItem: item(for: .newGroup))
        return row >= 0 ? outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NewGroupCellView : nil
    }

    /// A digit typed into the name: 1–8 pick a color while the popover is open.
    func newGroupDigit(_ text: String) -> Bool {
        guard let editor = newGroupEditor, editor.pickDigit(text) else { return false }
        newGroupColorChanged()
        return true
    }

    func toggleNewGroupColorPopover() {
        guard let editor = newGroupEditor else { return }
        editor.isColorPopoverOpen.toggle()
        newGroupColorChanged()
        newGroupCell?.focus()
    }

    func pickNewGroupColor(_ color: TagColor?) {
        guard let editor = newGroupEditor else { return }
        editor.color = color
        editor.isColorPopoverOpen = false
        newGroupColorChanged()
        newGroupCell?.focus()
    }

    private func newGroupColorChanged() {
        newGroupCell?.sync()
        refreshBlockEdges()
        if newGroupEditor?.isColorPopoverOpen == true { showColorPopover() } else { hideColorPopover() }
    }

    private func showColorPopover() {
        guard let editor = newGroupEditor, let window = view.window else { return }
        let panel = colorPopover ?? GroupColorPopoverPanel()
        colorPopover = panel
        panel.popover.current = editor.color
        panel.popover.onPick = { [weak self] color in self?.pickNewGroupColor(color) }
        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        positionColorPopover()
    }

    private func hideColorPopover() {
        guard let panel = colorPopover, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// Keeps the popover under the editor row (scrolls, diffs).
    func positionColorPopover() {
        guard let panel = colorPopover, panel.isVisible, let window = view.window else { return }
        let row = outline.row(forItem: item(for: .newGroup))
        guard row >= 0 else { hideColorPopover(); return }
        panel.popover.current = newGroupEditor?.color
        let rowOnScreen = window.convertToScreen(outline.convert(outline.rect(ofRow: row), to: nil))
        let sidebarMinX = window.convertToScreen(view.convert(view.bounds, to: nil)).minX
        panel.setFrame(GroupColorPopoverPanel.place(size: GroupColorPopoverView.size, rowOnScreen: rowOnScreen,
                                                    sidebarMinX: sidebarMinX, windowFrame: window.frame), display: true)
    }

    // MARK: Group header actions (SidebarStates C / D)

    /// The group's stopped and exited CODD sessions (`清理已停止 (n)`; externals are never archived).
    func stoppedSessions(inGroup id: GroupID) -> [SessionID] {
        guard let group = store.group(id) else { return [] }
        return group.projectIDs.compactMap(store.project).flatMap(\.sessionIDs).filter { sid in
            guard let session = store.session(sid) else { return false }
            return !session.external && !session.state.isLive
        }
    }

    /// `清理已停止 (n)`: archives them with an UNDO toast.
    func cleanupStopped(inGroup id: GroupID) {
        let ids = stoppedSessions(inGroup: id)
        guard !ids.isEmpty else { NSSound.beep(); return }
        archive(ids)
    }

    /// `+` on a group header: the ⌘N sheet for that group (未分類: no group).
    func newSession(inGroup id: GroupID) {
        guard let onNewSession, let group = store.group(id) else { NSSound.beep(); return }
        var form = NewSessionForm()
        form.groupID = group.isUngrouped ? nil : id
        onNewSession(form)
    }

    /// `⋯` on a group header: the group menu at the button (the header keeps its actions up).
    func showGroupMenu(_ id: GroupID, from cell: GroupHeaderCellView) {
        hoverCard.hide()
        let row = outline.row(forItem: item(for: .group(id)))
        guard row >= 0, let menu = groupMenu(id, row: row) else { return }
        cell.isMenuOpen = true
        let anchor = cell.moreButton
        // Right-aligned under `⋯` (SidebarStates D `.ss-gmenu{right:0}`).
        menu.popUp(positioning: nil, at: NSPoint(x: anchor.bounds.width - menu.size.width, y: anchor.bounds.height + 2), in: anchor)
        cell.isMenuOpen = false
        outline.refreshHover()
    }

    // MARK: Toasts

    /// UNDO toasts (archive) count down from `countdown` seconds (SidebarStates C `5s`); the others
    /// keep M1's 6 s look.
    @discardableResult
    func showToast(_ text: String, undo: (@MainActor () -> Void)?, countdown: Int? = nil) -> ToastView {
        view.subviews.compactMap { $0 as? ToastView }.forEach { $0.removeFromSuperview() }
        let toast = ToastView(text: text, undo: undo, countdown: countdown)
        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        var constraints = [
            toast.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            toast.bottomAnchor.constraint(equalTo: selectionBar.isHidden ? footer.topAnchor : selectionBar.topAnchor, constant: -8),
        ]
        if countdown == nil {
            constraints.append(toast.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8))
            toast.dismiss(after: 6)
        } else {
            // `.toast` is inline-flex: it hugs its content.
            constraints.append(toast.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -8))
            toast.startCountdown()
        }
        NSLayoutConstraint.activate(constraints)
        return toast
    }

    /// The toast on screen (tests).
    var currentToast: ToastView? { view.subviews.compactMap { $0 as? ToastView }.last }

}

// MARK: - OutlineMutationSink

extension SidebarViewController: OutlineMutationSink {
    func isLive(_ node: NodeKind) -> Bool {
        guard let it = items[node], outline.isItemExpanded(it) else { return false }
        var parent = outline.parent(forItem: it)
        while let p = parent {
            if !outline.isItemExpanded(p) { return false }
            parent = outline.parent(forItem: p)
        }
        return outline.row(forItem: it) >= 0
    }

    func insert(at index: Int, in parent: NodeKind?) {
        appliedOperations += 1
        outline.insertItems(at: IndexSet(integer: index), inParent: parent.map(item(for:)), withAnimation: .effectFade)
    }

    func remove(at index: Int, in parent: NodeKind?) {
        appliedOperations += 1
        outline.removeItems(at: IndexSet(integer: index), inParent: parent.map(item(for:)), withAnimation: .effectFade)
    }

    func move(from index: Int, in source: NodeKind?, to newIndex: Int, in destination: NodeKind?) {
        appliedOperations += 1
        outline.moveItem(at: index, inParent: source.map(item(for:)), to: newIndex, inParent: destination.map(item(for:)))
    }

    func reloadChildren(of parent: NodeKind) {
        pendingReloads.append(parent)
    }
}
