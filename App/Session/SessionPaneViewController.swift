import AppKit
import CoddComposer
import CoddNotebookUI
import CoddUI

/// Root view of the pane; relays the shared 1 Hz tick while it is on screen.
final class PaneRootView: PanelView, SecondTicking {
    var onTick: ((Date) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { UITicker.shared.addSecond(self) } else { UITicker.shared.removeSecond(self) }
    }

    func secondTick(now: Date) { onTick?(now) }
}

/// The terminal area and, while the session's `✎ NOTES` pill is on, the notes drawer as a 300 pt
/// column at its right (M4 I2b, Split artboard `.sp-row` = `.sp-col` + `.sp-pad`). Frames are set
/// by hand; a closed drawer is only hidden, so the terminal gets the whole width back at once.
final class PaneBodyRowView: FlippedView {
    let content: NSView
    /// The drawer's view (installed once the app has a notebook).
    var drawer: NSView? {
        didSet {
            guard drawer !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let drawer {
                drawer.translatesAutoresizingMaskIntoConstraints = true
                drawer.isHidden = !showsDrawer
                addSubview(drawer)
            }
            needsLayout = true
        }
    }
    var showsDrawer = false {
        didSet {
            guard showsDrawer != oldValue else { return }
            drawer?.isHidden = !showsDrawer
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
    }
    /// The drawer's width at the interface zoom (the Split artboard's 300).
    static var drawerWidth: CGFloat { NotesDrawerView.preferredWidth }

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content)
        setContentHuggingPriority(.init(1), for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The drawer takes its 300 pt only when it is shown and the pane is wide enough to keep a
    /// usable terminal next to it.
    var drawerShown: Bool { showsDrawer && drawer != nil }

    /// The drawer's width in a body `width` wide: its own, at most half the body on a narrow pane
    /// (a small window, a large zoom), so the terminal and its composer keep a usable width.
    static func drawerWidth(in width: CGFloat) -> CGFloat {
        min(drawerWidth, max(0, width - UIZoom.pt(200)), floor(width / 2))
    }

    override func layout() {
        super.layout()
        let width = drawerShown ? Self.drawerWidth(in: bounds.width) : 0
        content.frame = CGRect(x: 0, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        drawer?.frame = CGRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
    }
}

/// Main pane bound to the current session: header, banner, tab strip, terminal area (the
/// selected tab's terminal, the ⌘L composer and the ⌘J bottom panel), answer bar (waiting only)
/// and status bar.
final class SessionPaneViewController: NSViewController {
    private let store: any SessionStore
    private let accounts: any AccountStore
    private let shell: ShellState
    private let factory: TerminalSurfaceFactory
    /// The tab strip's terminal.
    let surface: TerminalSurface
    /// The ⌘J panel's terminal.
    let panelSurface: TerminalSurface

    private let header = SessionHeaderView()
    /// The store's problem (above the session banner); the home page has its own.
    private let problemBanner = ProblemBannerView()
    private let banner = BannerView()
    private let tabStrip = TabStripView()
    private let doneNote = BannerView()
    private let terminalHost: TerminalHostView
    private let panelHost: TerminalHostView
    private let terminalArea: TerminalAreaView
    /// The terminal area with the notes drawer beside it (M4 I2b).
    private let bodyRow: PaneBodyRowView
    private let answerBar = AnswerBarView()
    private lazy var statusBar = StatusBarView(store: store)
    /// Real-mode extras for the home and status pages (nil in mock mode).
    let services: AppServices?
    /// D5: the launch profiles (Home's `Profile · <default> ▾`); nil shows the built-ins.
    let profiles: LaunchProfiles?
    private(set) lazy var homePage = HomePageView(store: store, accounts: accounts, shell: shell, services: services, profiles: profiles,
                                                  mockTranscripts: services == nil ? MockData.homeTranscripts() : [:])
    /// The rail's STATUS page (CoddStatusUI, driven by `StatusController`; D16): it covers the
    /// session chrome while the rail is on STATUS.
    private let statusPage: NSView
    /// The NOTES area (D12, M4): it covers the whole pane (status bar included: the Notebook draws
    /// the app status bar under its editor column only, as the artboard does).
    private let notesArea: NSViewController?
    private enum Page { case none, home, status, notes }
    private var page = Page.none
    /// The main window is on screen (D10, from the window controller): Home observes the stores
    /// and renders only while it is both the page and visible (M3 review: it kept rebuilding with
    /// the window closed).
    var isWindowVisible = true {
        didSet { if isWindowVisible != oldValue { homePage.setActive(page == .home && isWindowVisible) } }
    }
    private var loop: ObservationLoop?
    private var renderedSessionID: SessionID?
    /// D6: external sessions' last prompts read from their transcripts, and what each was read
    /// for (its state change and conversation), so a new turn reads it again.
    private var externalPrompts: [SessionID: String] = [:]
    private var externalPromptKeys: [SessionID: String] = [:]
    /// `⋯` in the header: the owner shows the session's context menu.
    var onMoreMenu: ((SessionID, NSView) -> Void)?
    /// A page asked to show a session (home NEEDS YOU / RESUME rows).
    var onOpenSession: ((SessionID) -> Void)?
    /// The ⌘L composer (D1–D4): bar, per-session drafts and history, send path.
    let composer: PaneComposer
    /// D26: armed `⟲ 稍後自動重試` resends (one per failed session, 60 s).
    let autoRetry: AutoRetryScheduler
    /// D26: whole prompts read from transcripts for sessions without a hook prompt, keyed by the
    /// failure (`stateSince`) each was read for: a new failure reads again and never reuses one
    /// read for an earlier failure.
    private var resendLookups: [SessionID: (since: Date, prompt: String?)] = [:]
    /// Something the state dump shows changed (composer sends, the home page's sections).
    var onDumpNeeded: (() -> Void)?
    /// A page asked for Settings at a section (Home's `自動切換 … 設定 →`).
    var onOpenSettings: ((String) -> Void)?
    /// M4 I2b: the `✎ NOTES` drawer (nil until the app has a notebook: tests, older rigs).
    var notesDrawer: NotesDrawerController? {
        didSet {
            notesDrawer?.draftReferences = { [weak self] id in self?.composer.draftReferences(id) ?? [] }
            bodyRow.drawer = notesDrawer?.view
            if isViewLoaded { render() }
        }
    }
    /// Sessions whose drawer is open (in memory for the run, D12-like).
    private(set) var drawerOpenSessions: Set<SessionID> = []

    /// - Parameter composerDirectory: a session's folder for its `composer.json` and attachments
    ///   (nil: memory only, as in mock mode).
    init(store: any SessionStore, accounts: any AccountStore, shell: ShellState, surfaceFactory: TerminalSurfaceFactory,
         services: AppServices? = nil, profiles: LaunchProfiles? = nil, composerDirectory: (@MainActor (SessionID) -> String?)? = nil,
         autoRetryDelay: TimeInterval = AutoRetryScheduler.defaultDelay, statusPage: NSView? = nil, notesArea: NSViewController? = nil) {
        self.statusPage = statusPage ?? PanelView(fill: Palette.bg)
        self.notesArea = notesArea
        self.store = store
        self.accounts = accounts
        self.shell = shell
        self.services = services
        self.profiles = profiles ?? services?.profiles
        factory = surfaceFactory
        surface = surfaceFactory.makeSurface(slot: .main)
        panelSurface = surfaceFactory.makeSurface(slot: .panel)
        terminalHost = TerminalHostView(surface: surface)
        panelHost = TerminalHostView(surface: panelSurface)
        terminalArea = TerminalAreaView(top: terminalHost, panelHost: panelHost)
        bodyRow = PaneBodyRowView(content: terminalArea)
        let directory: @MainActor (SessionID) -> String?
        if let composerDirectory {
            directory = composerDirectory
        } else if let holders = services?.store {
            directory = { [weak holders] id in holders?.runtime(id)?.directory }
        } else {
            directory = { _ in nil }
        }
        composer = PaneComposer(states: ComposerStates(directory: directory, log: { HolderSessionStore.printLog($0) }))
        let clock = store.clock
        autoRetry = AutoRetryScheduler(delay: autoRetryDelay, clock: { clock.now() })
        super.init(nibName: nil, bundle: nil)
        autoRetry.isStillFailing = { [weak store] id, since in
            guard let session = store?.session(id) else { return false }
            return session.state == .error && session.stateSince == since
        }
        autoRetry.onFire = { [weak self] id in self?.resend(id, why: "auto") }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = PaneRootView(fill: Palette.bg)
        root.onTick = { [weak self] now in self?.tick(now) }

        surface.onGridSizeChange = { [weak self] grid in self?.tabStrip.setGrid(grid) }

        homePage.isHidden = true
        statusPage.isHidden = true
        homePage.onOpen = { [weak self] id in self?.onOpenSession?(id) }
        homePage.onOpenSettings = { [weak self] section in self?.onOpenSettings?(section) }
        homePage.onModelChange = { [weak self] in self?.onDumpNeeded?() }
        problemBanner.onDismiss = { [weak self] in self?.store.dismissProblem() }
        problemBanner.onReveal = { [weak self] in self?.store.revealProblemFile() }
        terminalHost.onReadOnlyAction = { [weak self] in self?.goToHostShell() }
        terminalArea.install(composer: composer.bar)
        composer.send = { [weak self] input, target in self?.factory.send(input, to: target) ?? false }
        composer.awaitingAnswer = { [weak self] target in
            guard let session = self?.store.session(target.sessionID) else { return false }
            return Self.awaitsAnswer(session, tab: target.tab)
        }
        composer.onEscape = { [weak self] in self?.surface.focus() }
        composer.onSent = { [weak self] id, payload, elapsed in
            #if DEBUG
            HolderSessionStore.printLog(String(format: "COMPOSER sent session=%@ bytes=%d paste=%@ submit=%@ ms=%.3f", id,
                                               payload.bytes.count, payload.paste ? "true" : "false",
                                               payload.submit ? "true" : "false", TerminalHub.milliseconds(elapsed)))
            #endif
            self?.onDumpNeeded?()
        }
        let stack = vStack([header, problemBanner, banner, tabStrip, doneNote, bodyRow, answerBar, statusBar], spacing: 0,
                           alignment: .width)
        stack.distribution = .fill
        root.addSubview(stack)
        stack.pinEdges(to: root)
        // Pages cover everything above the status bar (outside the stack: a hidden arranged view is
        // detached and would lose its width constraints).
        for page in [homePage, statusPage] as [NSView] {
            page.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                page.topAnchor.constraint(equalTo: root.topAnchor),
                page.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            ])
        }
        if let notesArea {
            addChild(notesArea)
            let notes = notesArea.view
            notes.isHidden = true
            notes.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(notes)
            notes.pinEdges(to: root)
        }
        // M4 interface zoom: the bars keep their design heights at the current zoom.
        header.heightAnchor.constraint(equalToConstant: 0).zoomed(Metrics.Design.headerHeight).isActive = true
        tabStrip.heightAnchor.constraint(equalToConstant: 0).zoomed(Metrics.Design.tabStripHeight).isActive = true
        statusBar.heightAnchor.constraint(equalToConstant: 0).zoomed(Metrics.Design.statusBarHeight).isActive = true
        for view in [header, problemBanner, banner, tabStrip, doneNote, answerBar, statusBar] as [NSView] {
            view.setContentHuggingPriority(.required, for: .vertical)
        }
        wireActions()
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        tabStrip.setGrid(surface.gridSize)
    }

    private func wireActions() {
        answerBar.onAnswer = { [weak self] key in self?.answer(key) }
        tabStrip.onSelect = { [weak self] item in self?.selectTab(item) }
        tabStrip.onAdd = { [weak self] in self?.newShellTab() }
        tabStrip.onTogglePanel = { [weak self] in self?.toggleBottomTerminal() }
        tabStrip.onToggleComposer = { [weak self] in self?.toggleComposer() }
        terminalArea.onPanelHeightChange = { [weak self] height in
            guard let self, let id = self.shell.currentSessionID else { return }
            self.shell.setPanelHeight(Double(height), in: id)
        }
        let panelStrip = terminalArea.panel.strip
        panelStrip.onSelect = { [weak self] tabID in self?.selectPanelTab(tabID) }
        panelStrip.onAdd = { [weak self] in self?.newPanelTab() }
        panelStrip.onCloseTab = { [weak self] tabID in self?.closePanelTab(tabID) }
        panelStrip.onToggleMaximize = { [weak self] in self?.toggleMaximizePanel() }
        panelStrip.onClose = { [weak self] in self?.closePanel() }
        header.fontDown.target = self
        header.fontDown.action = #selector(fontSmaller)
        header.fontUp.target = self
        header.fontUp.action = #selector(fontLarger)
        header.moreButton.target = self
        header.moreButton.action = #selector(showMore(_:))
        // M5 D21: the header lamp says the shown session's state, current when VoiceOver asks.
        header.spokenState = { [weak self] in
            guard let self, let id = self.shell.currentSessionID, let session = self.store.session(id) else { return "" }
            return SessionSpeech.state(session, now: self.store.clock.now())
        }
        header.bottomTerminalButton.target = self
        header.bottomTerminalButton.action = #selector(toggleBottomTerminalAction)
        header.notesButton.target = self
        header.notesButton.action = #selector(toggleNotesDrawerAction)
        header.filesButton.target = self
        header.filesButton.action = #selector(openFilesAction)
        for (button, tip) in [(header.notesButton, Self.notesPillTip), (header.filesButton, "檔案（在編輯器開啟專案）"),
                              (header.bottomTerminalButton, "下方終端機 ⌘J")] {
            button.toolTip = tip
        }
    }

    // MARK: Rendering (tracked)

    private var current: SessionVM? { shell.currentSessionID.flatMap(store.session) }

    private func render() {
        let now = store.clock.now()
        let fontSize = CGFloat(shell.terminalFontSize)
        surface.fontSize = fontSize
        panelSurface.fontSize = fontSize
        header.setFontSize(shell.terminalFontSize)
        if shell.area == .status {
            show(.status)
            return
        }
        if shell.area == .notes, notesArea != nil {
            show(.notes)
            return
        }
        guard shell.area == .sessions, let session = current else {
            if shell.area == .sessions {
                show(.home)
            } else {
                show(.none)
                showPlaceholder("// \(shell.area.rawValue.uppercased()) · 尚未實作")
            }
            return
        }
        show(.none)
        renderDrawer(session)
        if session.external {
            renderExternal(session, now: now)
            return
        }
        terminalHost.showPlaceholder(nil)
        tabStrip.isHidden = false
        renderProblem(for: session.id, now: now)
        let layout = shell.pane(for: session.id)
        let tab = layout.effectiveSelection
        let isShell = session.kind == .shell
        let style = StateStyle.of(session)
        header.update(headerModel(session), now: now)
        header.bottomTerminalButton.isOn = layout.panelOpen
        tabStrip.update(entries: stripEntries(session), isShellSession: isShell, lamp: style, selected: tab)
        surface.attach(TerminalTarget(sessionID: session.id, tab: tab))
        // The composer first: a panel being maximized lays the split out with the composer's height.
        bindComposer(session, tab: tab, open: layout.composerOpen)
        if layout.panelOpen, let panel = layout.panel {
            terminalArea.setPanel(open: true, height: CGFloat(layout.panelHeight), maximized: layout.isPanelMaximized)
            terminalArea.panel.strip.update(tabs: panelEntries(session.id), selected: panel.id, cwd: panelCwd(session, tab: panel),
                                            maximized: layout.isPanelMaximized)
            panelHost.showPlaceholder(nil)
            panelSurface.attach(TerminalTarget(sessionID: session.id, tab: .shell(panel.id)))
        } else {
            terminalArea.setPanel(open: false, height: CGFloat(layout.panelHeight))
            panelSurface.detach()
        }
        renderedSessionID = session.id
        tabStrip.setComposerLinkVisible(true)
        autoRetry.dropStale()
        renderBanners(session, now: now)
        if session.state == .waiting, !isShell, tab == .claude {
            answerBar.isHidden = false
            answerBar.configure(reason: session.waitingReason, tool: session.tool, detail: session.detail, options: session.answerOptions)
        } else {
            answerBar.isHidden = true
        }
    }

    // MARK: Tab labels and marks (D11, D12, D25)

    /// The tab strip: the session's own tab (`◆ Claude` / `$ zsh`, the running lamp for a SHELL
    /// session's shell), then the shell tabs an older panes.json may still keep there until the
    /// terminal hub moves them into the panel (OSC title or `zsh n`, lamp, bell). No `$ ZSH`: every
    /// extra terminal opens in the panel (`+`, ⌘T).
    private func stripEntries(_ session: SessionVM) -> [TabStripEntry] {
        ([PaneTabItem.main] + shell.pane(for: session.id).tabs.map(PaneTabItem.shell)).map { item in
            switch item {
            case .main:
                return TabStripEntry(item: item, label: TabStripView.label(.main, isShellSession: session.kind == .shell),
                                     marks: marks(BellKey(sessionID: session.id, tabID: nil),
                                                  running: session.kind == .shell ? session.id : nil))
            case .shell(let tab):
                return TabStripEntry(item: item, label: shell.label(for: tab, inPanel: false),
                                     marks: marks(BellKey(sessionID: session.id, tabID: tab.id), running: tab.id))
            case .pendingShell:
                return TabStripEntry(item: item, label: TabStripView.label(.pendingShell, isShellSession: false))
            }
        }
    }

    /// The panel strip's tabs (`zsh 1`, `zsh 2`, or OSC titles).
    private func panelEntries(_ id: SessionID) -> [PanelStripView.Tab] {
        shell.pane(for: id).panelTabs.map { tab in
            PanelStripView.Tab(id: tab.id, label: shell.label(for: tab, inPanel: true),
                               marks: marks(BellKey(sessionID: id, tabID: tab.id), running: tab.id))
        }
    }

    private func marks(_ bell: BellKey, running: String?) -> [CoddButton.TabMark] {
        var marks: [CoddButton.TabMark] = []
        if let running, shell.runningTabs.contains(running) { marks.append(.running) }
        if shell.bells.contains(bell) { marks.append(.bell) }
        return marks
    }

    /// The panel's `.tfill` folder: the shown tab's OSC 7 folder, else the project's (`~/…/a/b`).
    private func panelCwd(_ session: SessionVM, tab: ShellTab) -> String {
        let path = shell.tabCwd(tab.id) ?? store.project(session.projectID)?.cwd ?? ""
        return PathFormat.short(PathFormat.abbreviateHome(path))
    }

    /// D6: an external session is read-only: header, the EXT banner, no tabs, no terminal (its
    /// comment instead), no answer bar, no ⌘J panel.
    private func renderExternal(_ session: SessionVM, now: Date) {
        renderProblem(for: session.id, now: now)
        header.update(headerModel(session), now: now)
        header.bottomTerminalButton.isOn = false
        tabStrip.isHidden = true
        surface.detach()
        terminalArea.setPanel(open: false, height: CGFloat(shell.pane(for: session.id).panelHeight))
        terminalArea.setComposer(open: false)
        panelSurface.detach()
        renderedSessionID = session.id
        banner.isHidden = false
        banner.show(.info, glyph: "EXT", glyphColor: Palette.dim, message: "外部啟動的 session，唯讀狀態偵測",
                    detail: "· 偵測自 \(services?.registryDisplayPath ?? "~/.claude/sessions")", target: self)
        doneNote.isHidden = true
        answerBar.isHidden = true
        terminalHost.showReadOnly(readOnlyContent(session))
        loadExternalPrompt(session)
    }

    /// §3 copy: outside CODD `// 這個 session 在 CODD 外面執行（pid 48211 · cli）· CODD 只讀取狀態，
    /// 不能在這裡輸入`, inside one of CODD's shells `// 這個 session 在 CODD 的 shell「<title>」裡執行`
    /// with `[前往 shell]`; then `最近 prompt：…` when the transcript has one.
    func readOnlyContent(_ session: SessionVM) -> TerminalHostView.ReadOnlyContent {
        let info = session.externalInfo
        var lines: [String]
        var action: String?
        if let hostID = info?.hostSessionID, let host = store.session(hostID) {
            var title = host.title
            if let tabID = info?.hostTabID {
                let layout = shell.pane(for: hostID)
                if let tab = layout.tabs.first(where: { $0.id == tabID }) {
                    title += " · " + shell.label(for: tab, inPanel: false)
                } else if let tab = layout.panelTabs.first(where: { $0.id == tabID }) {
                    title += " · " + shell.label(for: tab, inPanel: true)
                }
            }
            lines = ["// 這個 session 在 CODD 的 shell「\(title)」裡執行"]
            action = "前往 shell"
        } else {
            let what = [info.map { "pid \($0.pid)" }, info?.entrypoint].compactMap { $0 }.joined(separator: " · ")
            lines = ["// 這個 session 在 CODD 外面執行（\(what)）· CODD 只讀取狀態，不能在這裡輸入"]
        }
        if let prompt = externalPrompts[session.id] { lines.append("最近 prompt：\(prompt)") }
        return TerminalHostView.ReadOnlyContent(lines: lines, action: action)
    }

    /// Reads the external's last prompt from its transcript (off the main actor) once per state
    /// change, then shows it if the session is still on screen.
    private func loadExternalPrompt(_ session: SessionVM) {
        guard let services else { return }
        let id = session.id
        let key = "\(session.stateSince.timeIntervalSince1970)|\(session.externalInfo?.claudeSessionID ?? "-")"
        guard externalPromptKeys[id] != key else { return }
        externalPromptKeys[id] = key
        Task { [weak self, weak services] in
            let prompt = await services?.lastPrompt(for: id)
            guard let self, self.externalPrompts[id] != prompt else { return }
            self.externalPrompts[id] = prompt
            if let current = self.current, current.id == id, current.external { self.terminalHost.showReadOnly(self.readOnlyContent(current)) }
        }
    }

    /// `[前往 shell]`: the CODD shell an external claude runs in (its session, its tab).
    private func goToHostShell() {
        guard let info = current?.externalInfo, let host = info.hostSessionID, store.session(host) != nil else { NSSound.beep(); return }
        if let tabID = info.hostTabID {
            let layout = shell.pane(for: host)
            if layout.panelTabs.contains(where: { $0.id == tabID }) {
                shell.selectPanelTab(tabID, in: host)
                if !layout.panelOpen { shell.togglePanel(in: host) }
            } else if layout.tabs.contains(where: { $0.id == tabID }) {
                shell.select(.shell(tabID), in: host)
                shell.setPanelMaximized(false, in: host)
            }
        }
        onOpenSession?(host)
    }

    /// Home / status replace the session chrome; `.none` gives it back.
    private func show(_ next: Page) {
        guard next != page else { return }
        page = next
        homePage.setActive(next == .home && isWindowVisible)
        homePage.isHidden = next != .home
        statusPage.isHidden = next != .status
        notesArea?.view.isHidden = next != .notes
        let chromeHidden = next != .none
        header.isHidden = chromeHidden
        if chromeHidden {
            renderedSessionID = nil
            // A page covers the terminal area: the composer neither shows nor keeps the keyboard.
            if composer.bar.hasFocus { view.window?.makeFirstResponder(nil) }
            terminalArea.setComposer(open: false)
            surface.detach()
            panelSurface.detach()
            for view in [problemBanner, banner, doneNote, answerBar, tabStrip] as [NSView] { view.isHidden = true }
            bodyRow.showsDrawer = false
            notesDrawer?.show(nil)
        }
    }

    /// A problem of every session, or of the one shown (tracked: reads `store.problem`).
    private func renderProblem(for id: SessionID, now: Date) {
        let problem = store.problem.flatMap { $0.sessionID == nil || $0.sessionID == id ? $0 : nil }
        problemBanner.update(problem, now: now)
    }

    private func showPlaceholder(_ text: String) {
        renderedSessionID = nil
        bodyRow.showsDrawer = false
        notesDrawer?.show(nil)
        header.update(nil, now: Date())
        terminalHost.showPlaceholder(text)
        terminalArea.setPanel(open: false, height: CGFloat(PaneLayout.defaultPanelHeight))
        terminalArea.setComposer(open: false)
        panelSurface.detach()
        problemBanner.isHidden = true
        banner.isHidden = true
        doneNote.isHidden = true
        answerBar.isHidden = true
        tabStrip.isHidden = true
    }

    private func headerModel(_ s: SessionVM) -> SessionHeaderModel {
        let style = StateStyle.of(s)
        var chip = ["\(style.glyph) \(style.label)"]
        var showsDuration = true
        switch s.state {
        case _ where s.unreachableSince != nil: break  // `◌ UNREACHABLE · 30s`
        case .waiting: chip.append(s.waitingReason?.label ?? "INPUT")
        case .error: if let reason = s.errorReason { chip.append(reason) }
        case .busy: if let tool = s.tool { chip.append(tool) }
        case .shell: chip.append(s.detail ?? "zsh"); showsDuration = false
        case .exited: chip.append("code \(s.exitCode ?? 0)")
        case .stopped: chip.append("可接續"); showsDuration = false
        case .unknown where !s.external: chip.append("! NO HOOK"); showsDuration = false
        default: break
        }
        let project = store.project(s.projectID)
        var meta: [SessionHeaderModel.MetaItem] = []
        if let branch = s.branch { meta.append(.init(text: "⎇ \(branch)")) }
        if let pid = s.pid { meta.append(.init(text: "pid \(pid)")) }
        if let model = s.model { meta.append(.init(text: model)) }
        if let ctx = s.contextPercent { meta.append(.init(text: "CTX \(ctx)%", danger: ctx < 20)) }
        if let cost = s.costUSD { meta.append(.init(text: String(format: "$%.2f", cost))) }
        if let info = s.externalInfo { meta.append(.init(text: info.rowLabel)) }
        var account: String?
        if let id = s.accountID, let a = accounts.account(id) {
            account = s.accountPinned ? "\(a.displayName) · cswap run" : a.displayName
        }
        return SessionHeaderModel(style: StateStyleKey(state: s.state, unreachable: s.unreachableSince != nil), title: s.title,
                                  tag: s.tag, chipParts: chip, chipShowsDuration: showsDuration,
                                  stateSince: s.unreachableSince ?? s.stateSince, external: s.external,
                                  cwd: project?.cwd ?? "", meta: meta, startedAt: s.state.isLive ? s.startedAt : nil,
                                  account: account, accountPinned: s.accountPinned, remoteControl: s.remoteControl,
                                  notes: s.notesCount)
    }

    private func renderBanners(_ s: SessionVM, now: Date) {
        let ago = DurationFormat.ago(s.stateSince, now: now)
        if let problem = s.launchError, !s.state.isLive {
            // The start itself failed (`claude` not on PATH, holder did not come up).
            banner.isHidden = false
            banner.show(.error, glyph: "▲", glyphColor: Palette.danger, message: "[ERROR] 無法啟動 · \(problem)",
                        actions: [BannerAction(title: "↻ 再試一次", action: s.kind == .claude ? #selector(resume) : #selector(restart))],
                        target: self)
            doneNote.isHidden = true
            return
        }
        if s.unreachableSince != nil {
            // D8: the holder runs but does not answer; reconnects keep going (every 10 s).
            banner.isHidden = false
            banner.show(.error, glyph: "▲", glyphColor: Palette.danger, message: "holder 沒有回應 · 每 10 秒重試一次，畫面與狀態可能不是最新的",
                        actions: [BannerAction(title: "↻ 立即重試", action: #selector(retryConnection))], target: self)
            doneNote.isHidden = true
            return
        }
        switch s.state {
        case .error:
            banner.isHidden = false
            // D26: resend needs a known prompt (the hook's, else the transcript's, read once per failure).
            let prompt = resendPrompt(for: s)
            var resend = BannerAction(title: "↻ 重送上一則", action: #selector(retryLast))
            if prompt == nil {
                resend.isEnabled = false
                resend.toolTip = Self.noPromptHint
            }
            banner.show(.error, glyph: "▲", glyphColor: Palette.danger,
                        message: "\(Self.errorText(s.errorReason)) · \(ago) · 本輪未完成",
                        hint: prompt == nil ? Self.noPromptHint : nil,
                        actions: [resend, BannerAction(title: autoRetry.title(for: s.id, now: now), action: #selector(retryLater),
                                                       isEnabled: prompt != nil, toolTip: prompt == nil ? Self.noPromptHint : nil)],
                        target: self)
        case .exited where s.kind == .claude, .stopped where s.kind == .claude:
            banner.isHidden = false
            let what = s.state == .exited ? "Session 已結束 · code \(s.exitCode ?? 0) · \(ago)" : "Session 已停止 · \(ago)"
            banner.show(.info, glyph: StateStyle.of(s.state).glyph, glyphColor: Palette.dimmer, message: what,
                        detail: "· 對話紀錄保留，可接續",
                        actions: [BannerAction(title: "⟲ 接續對話", action: #selector(resume), variant: .accent),
                                  BannerAction(title: "↻ 重新開始", action: #selector(restart))], target: self)
        case .exited, .stopped:
            // A shell has no conversation to resume: it starts again in the same folder.
            banner.isHidden = false
            let what = s.state == .exited ? "Shell 已結束 · code \(s.exitCode ?? 0) · \(ago)" : "Shell 已停止 · \(ago)"
            banner.show(.info, glyph: StateStyle.of(s.state).glyph, glyphColor: Palette.dimmer, message: what,
                        actions: [BannerAction(title: "↻ 重新開始", action: #selector(restart), variant: .accent)], target: self)
        default:
            banner.isHidden = true
        }
        if s.state == .done {
            doneNote.isHidden = false
            doneNote.show(.doneNote, glyph: "◇", glyphColor: Palette.cyan, message: "剛完成 · 開啟後標為已讀",
                          detail: "· \(ClockFormat.hourMinute(s.stateSince)) 完成")
        } else {
            doneNote.isHidden = true
        }
    }

    static func errorText(_ reason: String?) -> String {
        switch reason {
        case "OVERLOADED": "API 過載（529 overloaded）"
        case "RATE LIMIT": "已達用量上限（429 rate limit）"
        case "AUTH": "登入失效（401）"
        default: "本輪失敗"
        }
    }

    private func tick(_ now: Date) {
        header.tick(now: now)
        problemBanner.tick(now: now)
        homePage.tickProblem(now: now)
        if let session = current, session.id == renderedSessionID, !session.external, session.state == .error || !session.state.isLive {
            renderBanners(session, now: now)
        }
        // Connections come and go without an observed change: the composer rechecks its PTY.
        if let session = current, session.id == renderedSessionID, !session.external, terminalArea.isComposerShown {
            let layout = shell.pane(for: session.id)
            bindComposer(session, tab: layout.effectiveSelection, open: layout.composerOpen)
        }
    }

    // MARK: Notes drawer (M4 I2b, Split artboard)

    static let notesPillTip = "筆記 · 連結這個 session 的筆記"

    /// The drawer column follows the session on screen: open for the sessions whose pill is on.
    private func renderDrawer(_ session: SessionVM) {
        let open = notesDrawer != nil && drawerOpenSessions.contains(session.id)
        header.notesButton.isOn = open
        bodyRow.showsDrawer = open
        notesDrawer?.show(open ? session.id : nil)
    }

    /// `✎ NOTES n`: opens or closes the session's drawer (remembered per session for the run).
    func toggleNotesDrawer() {
        guard let session = current, notesDrawer != nil else { NSSound.beep(); return }
        setNotesDrawer(open: !drawerOpenSessions.contains(session.id), for: session.id)
    }

    /// Opens or closes `id`'s drawer (`✕`, DEBUG `-codd-show split`).
    func setNotesDrawer(open: Bool, for id: SessionID) {
        if open { drawerOpenSessions.insert(id) } else { drawerOpenSessions.remove(id) }
        render()
        onDumpNeeded?()
    }

    /// The drawer is open for the session on screen.
    var isNotesDrawerShown: Bool { bodyRow.drawerShown && !bodyRow.isHidden }

    @objc private func toggleNotesDrawerAction() { toggleNotesDrawer() }

    /// M4 I3: the header's files button opens the session's cwd in the NOTES area's Files mode.
    var onOpenFiles: ((SessionID) -> Void)?

    @objc private func openFilesAction() {
        guard let session = current, onOpenFiles != nil else { NSSound.beep(); return }
        onOpenFiles?(session.id)
    }

    /// D14: input to a PTY no slot needs to show (a note sent from NOTES or the drawer), the path
    /// the error banner's resend takes.
    func sendInput(_ input: TerminalInput, to target: TerminalTarget) -> Bool {
        factory.send(input, to: target)
    }

    /// D14 from outside the pane: the session on screen opens its composer and takes the keyboard there.
    func revealComposer(for id: SessionID) {
        guard current?.id == id, !(current?.external ?? true) else { return }
        if shell.pane(for: id).isPanelMaximized { shell.setPanelMaximized(false, in: id) }
        if !shell.pane(for: id).composerOpen { shell.setComposerOpen(true, in: id) }
        render()
        composer.bar.focus()
        onDumpNeeded?()
    }

    // MARK: Composer (⌘L, D1–D4)

    /// Points the composer at the tab strip's terminal and shows or hides it.
    private func bindComposer(_ session: SessionVM, tab: PaneTab, open: Bool) {
        let target = TerminalTarget(sessionID: session.id, tab: tab)
        let claudeTab = session.kind == .claude && tab == .claude
        let ownPTY = tab == .claude
        let live = (!ownPTY || session.state.isLive) && surface.acceptsInput
        composer.bind(session: session.id, target: target, shell: !claudeTab, live: live,
                      busy: claudeTab && session.state.isWorking, awaitingAnswer: Self.awaitsAnswer(session, tab: tab))
        terminalArea.setComposer(open: open)
    }

    /// Claude's own PTY shows a prompt (permission, plan, question): whatever the composer sends
    /// would answer it, so it sends nothing until the answer bar was used (review security-data-1).
    static func awaitsAnswer(_ session: SessionVM, tab: PaneTab) -> Bool {
        session.kind == .claude && !session.external && tab == .claude && session.state == .waiting
    }

    /// ⌘L: hidden → shown and focused; shown, focus elsewhere → focused; shown and focused →
    /// hidden, the terminal focused (Esc in the composer only moves focus).
    func toggleComposer() {
        guard shell.area == .sessions, let session = current, !session.external else { NSSound.beep(); return }
        // The composer belongs to the tab strip's terminal: a maximized panel gives the room back.
        if shell.pane(for: session.id).isPanelMaximized {
            shell.setPanelMaximized(false, in: session.id)
            if !shell.pane(for: session.id).composerOpen { shell.setComposerOpen(true, in: session.id) }
            render()
            composer.bar.focus()
            onDumpNeeded?()
            return
        }
        let open = shell.pane(for: session.id).composerOpen
        if !open {
            shell.setComposerOpen(true, in: session.id)
            render()
            composer.bar.focus()
        } else if !composer.bar.hasFocus {
            composer.bar.focus()
        } else {
            shell.setComposerOpen(false, in: session.id)
            render()
            surface.focus()
        }
        onDumpNeeded?()
    }

    /// The composer is up for the session on screen.
    var isComposerShown: Bool { terminalArea.isComposerShown }

    /// The banner under the header (tests read the error banner's actions).
    var sessionBanner: BannerView { banner }

    #if DEBUG
    /// `-codd-composer-send`: the text goes through the composer as if typed and Entered.
    func debugComposerSend(_ text: String) -> Bool {
        if let session = current, session.id == renderedSessionID {
            let layout = shell.pane(for: session.id)
            bindComposer(session, tab: layout.effectiveSelection, open: layout.composerOpen)
        }
        composer.bar.field.text = text
        return composer.submit(text)
    }
    #endif

    /// The state dump's `home` entry while the home page is shown, else nil.
    var homeDump: [String: Any]? {
        guard page == .home, homePage.isActive else { return nil }
        return homePage.model.dump
    }

    /// The state dump's `pane` entry (D11–D13, D25) for the session on screen (a CODD session):
    /// `{session, tabs [{id, label, bell, running, selected, holderPid?}], panelTabs [{id, label,
    /// bell, running, holderPid?}], panelSelected, panelOpen, panelMaximized, composerOpen,
    /// notesDrawer}`. The session's own tab is `id: "main"`; `tabs` lists nothing else unless an
    /// older layout's strip shell tabs have not moved into the panel yet.
    func paneDump(holderPid: (String) -> Int32?) -> [String: Any]? {
        guard shell.area == .sessions, let session = current, !session.external else { return nil }
        let layout = shell.pane(for: session.id)
        let selected = layout.effectiveSelection
        func row(_ id: String, _ label: String, _ marks: [CoddButton.TabMark], tabID: String?) -> [String: Any] {
            var row: [String: Any] = ["id": id, "label": label, "bell": marks.contains(.bell), "running": marks.contains(.running)]
            if let tabID, let pid = holderPid(tabID) { row["holderPid"] = Int(pid) }
            return row
        }
        let tabs = stripEntries(session).map { entry -> [String: Any] in
            var out: [String: Any]
            switch entry.item {
            case .main:
                out = row("main", entry.label, entry.marks, tabID: nil)
                out["selected"] = selected == .claude
            case .shell(let tab):
                out = row(tab.id, entry.label, entry.marks, tabID: tab.id)
                out["selected"] = selected == .shell(tab.id)
            case .pendingShell:
                out = row("pending", entry.label, entry.marks, tabID: nil)
                out["selected"] = false
            }
            return out
        }
        let panelTabs = panelEntries(session.id).map { row($0.id, $0.label, $0.marks, tabID: $0.id) }
        return ["session": session.id, "tabs": tabs, "panelTabs": panelTabs,
                "panelSelected": layout.panel?.id as Any? ?? NSNull(), "panelOpen": layout.panelOpen,
                "panelMaximized": layout.isPanelMaximized, "composerOpen": layout.composerOpen,
                "notesDrawer": drawerOpenSessions.contains(session.id)]
    }

    /// The state dump's `composer` entry of a session.
    func composerDump(_ id: SessionID) -> [String: Any] {
        composer.dump(id, open: shell.pane(for: id).composerOpen)
    }

    // MARK: Error banner (D26)

    static let noPromptHint = "沒有可重送的 prompt"

    /// The prompt `↻ 重送上一則` sends, always whole: the hook's (`SessionVM.resendPrompt`), else
    /// the transcript's newest prompt read uncut (off the main actor once per failure; the banner
    /// redraws when it comes). Never a display form (`lastPrompt` is one line of at most 200
    /// characters): when the hook's prompt is known only in that form, nothing is resent (an older
    /// transcript prompt would not be the one that failed).
    private func resendPrompt(for session: SessionVM) -> String? {
        if let prompt = session.resendPrompt {
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : prompt
        }
        guard session.lastPrompt == nil else { return nil }
        if let lookup = resendLookups[session.id], lookup.since == session.stateSince { return lookup.prompt }
        guard let services else { return nil }
        let id = session.id
        let since = session.stateSince
        resendLookups[id] = (since, nil)
        Task { [weak self, weak services] in
            guard let prompt = await services?.resendPrompt(for: id), let self, self.resendLookups[id]?.since == since else { return }
            self.resendLookups[id] = (since, prompt)
            if let current = self.current, current.id == id { self.renderBanners(current, now: self.store.clock.now()) }
        }
        return nil
    }

    /// Sends the session's last prompt to its own PTY as one paste plus Return (the composer path).
    /// Post-M4 (review attachments-6): when the prompt names a note's annotated copy that is gone
    /// from the cache, the copy is rendered again first and the prompt goes right after (true: it is
    /// on its way).
    @discardableResult
    func resend(_ id: SessionID, why: String) -> Bool {
        guard let session = store.session(id), !session.external, session.kind == .claude,
              let found = resendPrompt(for: session) else { NSSound.beep(); return false }
        if let copies = composer.annotatedCopies, !copies.missing(in: found).isEmpty {
            Task { [weak self] in
                await copies.restore(found)
                guard let self, let session = self.store.session(id), !session.external else { return }
                self.sendLastPrompt(found, to: id, why: why)
            }
            return true
        }
        return sendLastPrompt(found, to: id, why: why)
    }

    @discardableResult
    private func sendLastPrompt(_ found: String, to id: SessionID, why: String) -> Bool {
        // Post-M4: a resend is a send, so the images it names get another 24 h (marked before the
        // check and the send, review attachments-2); a composer image or an annotated copy that is
        // gone goes as `[圖已過期]`, never as its path.
        composer.states.markAttachmentsSending(found, for: id)
        var prompt = composer.states.expiringMissingAttachments(in: found, for: id)
        if let copies = composer.annotatedCopies { prompt = copies.replacingMissing(in: prompt) }
        guard let payload = try? ComposerEncoding.payload(for: prompt) else { NSSound.beep(); return false }
        let input = TerminalInput.payload(bytes: payload.bytes, submit: true, paste: true)
        let sent = factory.send(input, to: TerminalTarget(sessionID: id, tab: .claude))
        HolderSessionStore.printLog("resend session=\(id) why=\(why) bytes=\(payload.bytes.count) sent=\(sent)")
        if sent { composer.states.sweepAttachmentsAfterSend(for: id) } else { NSSound.beep() }
        return sent
    }
    // MARK: Actions

    /// Answer-bar key (also ⌘⏎ = `1` for permission prompts).
    func answer(_ key: String) {
        guard let session = current, session.state == .waiting, !session.external else { return }
        // The store sends the key to the session's own PTY (the same path the menu bar uses).
        store.answer(session.id, key: key)
    }

    /// ⌘⏎: allow the current permission prompt.
    func allowCurrent() -> Bool {
        guard let session = current, session.state == .waiting, session.waitingReason != .question, !session.external else { return false }
        answer("1")
        return true
    }

    /// Never for an external: nothing of it can be answered from CODD (D6).
    var canAllowCurrent: Bool {
        guard let session = current, !session.external else { return false }
        return session.state == .waiting && session.waitingReason != .question
    }

    // MARK: Tabs and panel

    private func selectTab(_ item: PaneTabItem) {
        guard let session = current else { return }
        // A strip tab is shown in the top terminal: a maximized panel gives the room back.
        shell.setPanelMaximized(false, in: session.id)
        switch item {
        case .main: shell.select(.claude, in: session.id)
        case .shell(let tab): shell.select(.shell(tab.id), in: session.id)
        case .pendingShell:
            openShellTab()
            return
        }
        render()
        surface.focus()
    }

    /// `-codd-open-zsh-tab` (what the strip's `$ ZSH` opened before every extra terminal moved to
    /// the panel): a new shell in the bottom panel, as ⌘T.
    func openShellTab() { newPanelTab() }

    /// ⌘T / the strip's `+`: a new terminal in the session's folder. Every extra terminal opens in
    /// the bottom panel (the user's note 2026-10-19), shown and focused there.
    @objc func newShellTab() { newPanelTab() }

    /// ⌘J: opens (and focuses) or closes the bottom shell panel.
    func toggleBottomTerminal() {
        guard let session = current, !session.external else { NSSound.beep(); return }
        let opened = shell.togglePanel(in: session.id) != nil
        render()
        if opened { panelSurface.focus() } else { surface.focus() }
    }

    @objc private func toggleBottomTerminalAction() { toggleBottomTerminal() }

    /// `✕ ⌘J`: hides the panel (its shells keep running), like ⌘J.
    private func closePanel() {
        guard let session = current, shell.pane(for: session.id).panelOpen else { return }
        toggleBottomTerminal()
    }

    /// A panel tab was clicked: it shows in the panel and takes the keyboard.
    func selectPanelTab(_ tabID: String) {
        guard let session = current, !session.external else { return }
        shell.selectPanelTab(tabID, in: session.id)
        render()
        panelSurface.focus()
    }

    /// The panel's `+`: a new shell in the session's folder, shown in the panel.
    func newPanelTab() {
        guard let session = current, !session.external else { NSSound.beep(); return }
        shell.addPanelTab(in: session.id)
        render()
        panelSurface.focus()
    }

    /// The panel's maximize button (D11): the panel fills the terminal area, or the split comes back.
    func toggleMaximizePanel() {
        guard let session = current, !session.external, shell.pane(for: session.id).panelOpen else { NSSound.beep(); return }
        let maximized = shell.toggleMaximize(in: session.id)
        // The top terminal and the composer hide: neither may keep the keyboard.
        if maximized, composer.bar.hasFocus || surface.hasFocus { view.window?.makeFirstResponder(nil) }
        render()
        if maximized || !surface.hasFocus { panelSurface.focus() }
        onDumpNeeded?()
    }

    /// The panel is open and fills the terminal area (tests, dumps).
    var isPanelMaximized: Bool { terminalArea.isPanelMaximized }

    /// The panel's strip (tests).
    var panelStrip: PanelStripView { terminalArea.panel.strip }

    /// The tab strip (tests).
    var sessionTabStrip: TabStripView { tabStrip }

    /// ⌘W in the main window (視窗 › 關閉分頁或視窗): closes the focused terminal tab (the panel's
    /// shown one, or an older layout's strip tab) and its shell, asking first while a program runs
    /// in it. The CLAUDE tab is the session itself: ending it needs a confirmation. Returns false
    /// when no session is shown (the window closes instead).
    func handleCloseCommand() -> Bool {
        guard shell.area == .sessions, let session = current else { return false }
        // An external has no tab to close and cannot be ended from CODD.
        guard !session.external else { NSSound.beep(); return true }
        let layout = shell.pane(for: session.id)
        // The panel's shown tab, when the panel has the keyboard (or is all there is: maximized).
        if layout.panelOpen, let panel = layout.panel, panelSurface.hasFocus || layout.isPanelMaximized {
            closeTerminal(panel.id, in: session.id, label: shell.label(for: panel, inPanel: true))
            return true
        }
        if case .shell(let tabID) = layout.effectiveSelection, let tab = layout.tabs.first(where: { $0.id == tabID }) {
            closeTerminal(tabID, in: session.id, label: shell.label(for: tab, inPanel: false))
            return true
        }
        confirmEndSession(session)
        return true
    }

    // MARK: Closing a terminal

    /// Asks whether to close a terminal that still runs a program (its label; the answer is true
    /// to close). Nil shows the sheet on the main window; tests answer here instead.
    var confirmCloseTerminal: ((_ label: String, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?

    /// A panel tab's `✕`, its menu's `關閉終端機`: ends that tab's shell, asking first while a
    /// program runs in it. The panel then shows a neighbour; the last tab hides the panel.
    func closePanelTab(_ tabID: String) {
        guard let session = current, !session.external,
              let tab = shell.pane(for: session.id).panelTabs.first(where: { $0.id == tabID }) else { return }
        closeTerminal(tabID, in: session.id, label: shell.label(for: tab, inPanel: true))
    }

    /// Closes a shell tab now, or after the sheet when a foreground job runs in its shell (the
    /// green lamp's rule: a process besides the shell itself).
    private func closeTerminal(_ tabID: String, in id: SessionID, label: String) {
        guard runsForegroundJob(tabID) else { return finishClosing(tabID, in: id) }
        askBeforeClosing(label) { [weak self] close in
            if close { self?.finishClosing(tabID, in: id) }
        }
    }

    /// Real mode reads the shell's process group now; mock mode has only the lamp's state.
    private func runsForegroundJob(_ tabID: String) -> Bool {
        if let probe = factory as? ShellTabJobProbe { return probe.runsForegroundJob(tabID: tabID) }
        return shell.runningTabs.contains(tabID)
    }

    /// Drops the tab and ends its shell's holder. Nothing when it went meanwhile (its shell exited
    /// while the sheet was up).
    private func finishClosing(_ tabID: String, in id: SessionID) {
        let layout = shell.pane(for: id)
        let inPanel = layout.panelTabs.contains { $0.id == tabID }
        if inPanel {
            shell.removePanelTab(tabID, in: id)
        } else if layout.tabs.contains(where: { $0.id == tabID }) {
            shell.removeShellTab(tabID, in: id)
        } else {
            return
        }
        factory.closeShellTab(sessionID: id, tabID: tabID)
        guard current?.id == id else { return }
        render()
        if inPanel, shell.pane(for: id).panelOpen { panelSurface.focus() } else { surface.focus() }
    }

    private func askBeforeClosing(_ label: String, answer: @escaping @MainActor (Bool) -> Void) {
        if let confirmCloseTerminal { return confirmCloseTerminal(label, answer) }
        guard let window = view.window, window.attachedSheet == nil else { NSSound.beep(); return }
        let text = Self.closeRunningConfirmation(label)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.message
        alert.informativeText = text.info
        let close = alert.addButton(withTitle: "關閉")
        close.hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        Task { @MainActor in
            answer(await alert.beginSheetModal(for: window) == .alertFirstButtonReturn)
        }
    }

    /// The sheet's text (tests).
    static func closeRunningConfirmation(_ label: String) -> (message: String, info: String) {
        ("要關閉「\(label)」嗎？", "這個終端機裡還有程式在執行，關閉後 shell 和裡面的程式會一起結束。")
    }

    /// What the tab strip's terminal shows (debug dumps, input).
    var shownTarget: TerminalTarget? {
        guard let session = current else { return nil }
        return TerminalTarget(sessionID: session.id, tab: shell.tab(for: session.id))
    }

    private func confirmEndSession(_ session: SessionVM) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        let what = session.kind == .claude ? "CLAUDE 分頁" : "這個分頁"
        alert.messageText = "要結束「\(session.title)」嗎？"
        alert.informativeText = "⌘W 只會關閉終端機分頁。\(what)就是 session 本身，結束後程式與 holder 會一起停止。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "關閉視窗")
        let end = alert.addButton(withTitle: "結束 SESSION")
        end.hasDestructiveAction = true
        let id = session.id
        alert.beginSheetModal(for: window) { [weak self, weak window] response in
            switch response {
            // `close`, not `orderOut`: the window delegate hears it and the terminals stop rendering.
            case .alertSecondButtonReturn: window?.close()
            case .alertThirdButtonReturn: self?.store.stop([id])
            default: break
            }
        }
    }

    @objc private func showMore(_ sender: NSView) {
        if let id = shell.currentSessionID { onMoreMenu?(id, sender) }
    }

    /// A− / A+ (M4: through Settings › 終端機字級, so ⌘+ / ⌘− step from what the terminals show).
    /// Without the hook (tests) the live size moves alone, as before.
    var onTerminalFontStep: ((Int) -> Void)?

    @objc func fontSmaller() { stepTerminalFont(-1) }
    @objc func fontLarger() { stepTerminalFont(1) }

    private func stepTerminalFont(_ delta: Int) {
        if let onTerminalFontStep { return onTerminalFontStep(delta) }
        let range = ShellState.fontSizeRange
        shell.terminalFontSize = min(range.upperBound, max(range.lowerBound, shell.terminalFontSize + Double(delta)))
    }

    @objc private func resume() { if let id = shell.currentSessionID { store.resume(id) } }
    @objc private func retryConnection() { if let id = shell.currentSessionID { store.retryConnection(id) } }
    @objc private func restart() { if let id = shell.currentSessionID { store.restart(id) } }
    /// `↻ 重送上一則`.
    @objc private func retryLast() {
        guard let session = current, session.state == .error else { return }
        resend(session.id, why: "banner")
    }

    /// `⟲ 稍後自動重試`: arms the 60 s resend, or cancels it.
    @objc private func retryLater() {
        guard let session = current, session.state == .error, resendPrompt(for: session) != nil else { NSSound.beep(); return }
        autoRetry.toggle(session.id, stateSince: session.stateSince)
        renderBanners(session, now: store.clock.now())
    }
}
