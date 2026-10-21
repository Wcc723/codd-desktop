import AppKit
import CoddUI

/// The main window. ⌘W (the menu's performClose) closes the pane's shell tab first; the
/// traffic-light close button still closes the window.
final class CoddMainWindow: NSWindow {
    /// Returns true when it handled ⌘W itself (a tab closed or a confirmation is showing).
    var onCloseCommand: (() -> Bool)?
    /// D36: true while ⌘W belongs to another item (the Files mode's 關閉分頁 with a tab open), so
    /// the menu's 關閉分頁或視窗 steps aside (AppKit takes the first enabled item with the key).
    var suppressesCloseItem: (() -> Bool)?
    /// DEBUG layout sweep: the frame is used as set, also wider or taller than the screen (AppKit
    /// would pull it back inside the screen when the window is ordered in).
    var keepsFrameAsSet = false

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        keepsFrameAsSet ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }

    override func performClose(_ sender: Any?) {
        if sender is NSMenuItem, onCloseCommand?() == true { return }
        super.performClose(sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performClose(_:)), suppressesCloseItem?() == true { return false }
        return super.validateMenuItem(menuItem)
    }
}

/// The CODD main window: full-size content, transparent hidden title bar, native traffic
/// lights over our custom header band (they sit above the rail, which starts at 56 px), no
/// NSToolbar (titlebar-only windows keep the smaller Tahoe corner radius).
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: any SessionStore
    let accounts: any AccountStore
    let shell: ShellState
    let split: MainSplitViewController
    let sidebar: SidebarViewController
    let pane: SessionPaneViewController
    let rail: RailViewController
    /// The rail's STATUS area (D16): its sidebar replaces the session sidebar, its page covers the pane.
    let status: StatusController?
    /// The rail's NOTES area (M4 D12): the session sidebar collapses, the area covers the pane.
    let notes: NotesAreaViewController?
    private var areaLoop: ObservationLoop?

    var onOpenSettings: ((String?) -> Void)?
    var onQuickSwitch: (() -> Void)?
    /// Set in real mode: the ⌘N sheet, prefilled (kind, folder). Mock mode has no sessions to start.
    var onNewSession: ((NewSessionForm) -> Void)?
    /// Set in real mode: 加入專案資料夾… (a folder picker, no session).
    var onAddProject: (() -> Void)?
    /// D10: the window came on screen (true) or was closed / miniaturized / hidden (false), once
    /// per change. Real mode occludes every terminal while it is away.
    var onVisibilityChange: ((Bool) -> Void)?
    /// D19: the close button or ⌘W asks first; false keeps the window (the app runs the ⌘Q flow
    /// instead when 關閉視窗時保留在選單列 is OFF). nil closes as usual.
    var shouldClose: (() -> Bool)?
    /// The split plus the CRT overlay (Settings › 外觀 › CRT 效果).
    let container: MainContainerViewController
    private var reportedVisible: Bool?

    /// - Parameter savesFrame: false (M5 D25: any run but real mode on the standard data root;
    ///   the DEBUG layout sweep): the window's frame and the split's divider positions are neither
    ///   restored from nor written to the user defaults.
    init(store: any SessionStore, accounts: any AccountStore, shell: ShellState, surfaceFactory: TerminalSurfaceFactory,
         services: AppServices? = nil, profiles: LaunchProfiles? = nil, status: StatusController? = nil,
         notes: NotesAreaViewController? = nil, savesFrame: Bool = true) {
        self.store = store
        self.accounts = accounts
        self.shell = shell
        self.status = status
        self.notes = notes
        rail = RailViewController(store: store, accounts: accounts, shell: shell)
        // M4 I3: NOTES again while the Files mode shows goes back to the Notebook.
        rail.onReselect = { [weak notes] area in if area == .notes { notes?.showNotebookMode() } }
        sidebar = SidebarViewController(env: SidebarEnvironment(store: store, accounts: accounts, shell: shell, realMode: services != nil))
        pane = SessionPaneViewController(store: store, accounts: accounts, shell: shell, surfaceFactory: surfaceFactory,
                                         services: services, profiles: profiles, statusPage: status?.pageView, notesArea: notes)
        split = MainSplitViewController(rail: rail, sidebar: sidebar, pane: pane, statusSidebar: status?.sidebarView ?? NSView(),
                                        autosaveName: savesFrame ? MainSplitViewController.defaultAutosaveName : nil)
        container = MainContainerViewController(split: split)

        let window = CoddMainWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "CODD"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Palette.bg
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = Self.minimumSize
        super.init(window: window)
        window.delegate = self
        window.contentViewController = container
        window.setContentSize(NSSize(width: 1440, height: 900))
        if savesFrame {
            if !window.setFrameUsingName(DefaultsIsolation.windowFrameName) { window.center() }
            window.setFrameAutosaveName(DefaultsIsolation.windowFrameName)
        } else {
            window.keepsFrameAsSet = true
            window.center()
        }

        rail.onOpenSettings = { [weak self] in self?.onOpenSettings?(nil) }
        sidebar.onOpenSettings = { [weak self] section in self?.onOpenSettings?(section) }
        sidebar.onQuickSwitch = { [weak self] in self?.onQuickSwitch?() }
        sidebar.onNewMenu = { [weak self] button in self?.showNewMenu(from: button) }
        window.onCloseCommand = { [weak pane] in pane?.handleCloseCommand() ?? false }
        pane.onMoreMenu = { [weak self] id, anchor in
            self?.sidebar.menu(forSession: id)?.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
        }
        pane.onOpenSession = { [weak self] id in self?.show(id) }
        pane.onOpenSettings = { [weak self] section in self?.onOpenSettings?(section) }
        if let services {
            // D20: a hover card without a hook prompt reads the transcript's `last-prompt`.
            sidebar.hoverCard.promptProvider = { [weak services] id in await services?.lastPrompt(for: id) }
        }
        sidebar.onNewSession = { [weak self] form in self?.onNewSession?(form) }
        if shell.currentSessionID == nil {
            shell.currentSessionID = SidebarSnapshotBuilder.build(store: store, mode: .tree, filter: "").sessionOrder.first
        }
        // D16: the STATUS sidebar while the rail is on STATUS; sampling only while it is on screen.
        areaLoop = ObservationLoop(track: { [weak shell] in shell?.area ?? .sessions }, apply: { [weak self] area in
            self?.areaChanged(area)
        })
    }

    private func areaChanged(_ area: RailArea) {
        switch area {
        case .status: split.setSidebarMode(.status)
        case .notes where notes != nil: split.setSidebarMode(.notes)
        default: split.setSidebarMode(.sessions)
        }
        status?.setActive(area == .status && isOnScreen)
        notes?.setActive(area == .notes)
    }

    /// The D5 / installer toast over the visible sidebar (the session sidebar, or STATUS's).
    @discardableResult
    func showToast(_ text: String, undo: (@MainActor () -> Void)?) -> ToastView {
        split.sidebarContainer.showToast(text, undo: undo)
    }

    var currentToast: ToastView? { split.sidebarContainer.currentToast }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Commands

    /// ⌘1–9: the n-th session in sidebar order (NEEDS YOU first, mirrors counted once).
    func selectSession(number: Int) {
        let order = sidebar.snapshot.sessionOrder
        guard number >= 1, number <= order.count else { NSSound.beep(); return }
        show(order[number - 1])
    }

    /// ⌃Tab / ⌃⇧Tab.
    func cycleSession(forward: Bool) {
        let order = sidebar.snapshot.sessionOrder
        guard !order.isEmpty else { return }
        let index = shell.currentSessionID.flatMap(order.firstIndex(of:)) ?? (forward ? -1 : 0)
        let next = (index + (forward ? 1 : -1) + order.count) % order.count
        show(order[next])
    }

    /// Shows a session in the main pane (sidebar selection follows `currentSessionID`).
    func show(_ id: SessionID) {
        if shell.area != .sessions { shell.area = .sessions }
        if let previous = shell.currentSessionID, previous != id { store.markSeen(previous) }
        shell.currentSessionID = id
        sidebar.reveal(id)
    }

    func toggleSidebar() { split.toggleSessionSidebar() }

    /// M4 interface zoom: the window's minimum size and the split's fixed widths follow the zoom
    /// (the views themselves are refreshed by `UIZoom`).
    func applyZoom() {
        window?.minSize = Self.minimumSize
        growToMinimumSize()
        split.applyZoom()
    }

    /// A zoom that raises the minimum (UI 字級 13 → 20: 854 → 1011 pt) grows a smaller window to
    /// it, keeping its top-left corner and staying on its screen; otherwise an area without the
    /// sidebar (NOTES) would stay below the minimum and squeeze its columns.
    func growToMinimumSize() {
        guard let window else { return }
        let minimum = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.minSize)).size
        var frame = window.frame
        guard frame.width < minimum.width - 0.5 || frame.height < minimum.height - 0.5 else { return }
        let top = frame.maxY
        frame.size.width = max(frame.width, minimum.width)
        frame.size.height = max(frame.height, minimum.height)
        frame.origin.y = top - frame.height
        if let visible = window.screen?.visibleFrame {
            if frame.maxX > visible.maxX { frame.origin.x = max(visible.minX, visible.maxX - frame.width) }
            if frame.minY < visible.minY { frame.origin.y = visible.minY }
        }
        window.setFrame(frame, display: true)
    }

    /// The rail, the narrowest sidebar and the narrowest pane, at the current zoom (the height
    /// and the pane's minimum stay: a zoomed window must still fit a laptop screen).
    static var minimumSize: NSSize {
        NSSize(width: Metrics.railWidth + Metrics.sidebarMinWidth + Metrics.mainMinWidth + 2, height: 560)
    }

    private func showNewMenu(from button: CoddButton) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let claude = ClosureMenuItem(title: "新增 Claude session…") { [weak self] in self?.onNewSession?(NewSessionForm()) }
        claude.keyEquivalent = "n"
        claude.keyEquivalentModifierMask = [.command]
        let shellItem = ClosureMenuItem(title: "新增 Shell session…") { [weak self] in
            var form = NewSessionForm()
            form.kind = .shell
            self?.onNewSession?(form)
        }
        let project = ClosureMenuItem(title: "加入專案資料夾…") { [weak self] in self?.onAddProject?() }
        for item in [claude, shellItem] { item.isEnabled = onNewSession != nil }
        project.isEnabled = onAddProject != nil
        menu.addItem(claude)
        menu.addItem(shellItem)
        menu.addItem(project)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "新增群組") { [weak self] in self?.sidebar.beginNewGroup() })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: Visibility (D10)

    /// Ordered in and not miniaturized (an app hidden with ⌘H counts as not visible).
    var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        reportVisibility(isOnScreen)
    }

    private func reportVisibility(_ visible: Bool) {
        guard visible != reportedVisible else { return }
        reportedVisible = visible
        pane.isWindowVisible = visible
        status?.setActive(visible && shell.area == .status)
        onVisibilityChange?(visible)
    }

    // MARK: NSWindowDelegate

    func windowDidChangeOcclusionState(_ notification: Notification) {
        UITicker.shared.updateTimers()
        reportVisibility(isOnScreen)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose?() ?? true }

    /// Still `isVisible` while it closes. A note being edited is saved (D3 / I1a: flushed on close).
    func windowWillClose(_ notification: Notification) {
        reportVisibility(false)
        if let editor = notes?.editor { Task { await editor.flush() } }
    }
    func windowDidMiniaturize(_ notification: Notification) { reportVisibility(false) }
    func windowDidDeminiaturize(_ notification: Notification) { reportVisibility(isOnScreen) }
    func windowDidBecomeKey(_ notification: Notification) { reportVisibility(isOnScreen) }
}
