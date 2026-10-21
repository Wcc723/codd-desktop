import AppKit
import CoddCore
import CoddUI

/// Main pane with no session selected (Home artboard, D17, D29): `// 沒有選取 session`, SESSIONS
/// with the live date and the counts, NEEDS YOU cards (`[1 允許]` for CODD permission waits,
/// `[前往 ⌘n]`), the DONE line, LAUNCH 最近專案 cards with the default launch profile, RECENTLY
/// STOPPED 可接續 (stopped CODD sessions and transcripts no session uses) and USAGE 剩餘. With no
/// session at all it is the first-launch empty state.
///
/// The model is rebuilt on every observed change, the views only when it differs; durations and
/// the date are redrawn on the pane's 1 Hz tick.
final class HomePageView: PanelView {
    private let store: any SessionStore
    private let accounts: any AccountStore
    private let shell: ShellState
    private weak var services: AppServices?
    private let profiles: LaunchProfiles?
    /// Real mode: the D29 note applies and transcripts come from `services`.
    let realMode: Bool
    private let scroll = NSScrollView()
    private let content = HomeContentView()
    /// The store's problem, whichever session it is about (the pane shows it per session).
    let problemBanner = ProblemBannerView()
    /// The scroll view starts under the banner while it shows, else at the top (the banner's own
    /// height is never forced, so its contents never fight a zero height).
    private var scrollUnderBanner: NSLayoutConstraint?
    private var scrollAtTop: NSLayoutConstraint?
    private var loop: ObservationLoop?
    /// RECENTLY STOPPED's transcripts per project folder (read off the main actor).
    private var transcripts: [String: [TranscriptSummary]]
    private var transcriptFolders: [String] = []
    private var transcriptTask: Task<Void, Never>?
    private(set) var model = HomeModel()
    /// Whether the page is on screen (the `home` dump key is written only then).
    private(set) var isActive = false
    /// Opens a session in the pane.
    var onOpen: ((SessionID) -> Void)?
    /// The model changed (state dump).
    var onModelChange: (() -> Void)?
    /// Opens Settings at a section (`accounts` for the auto-switch line).
    var onOpenSettings: ((String) -> Void)?
    /// Last render's duration (DEBUG log).
    private(set) var lastRenderDuration: Duration?

    init(store: any SessionStore, accounts: any AccountStore, shell: ShellState, services: AppServices?,
         profiles: LaunchProfiles?, mockTranscripts: [String: [TranscriptSummary]] = [:]) {
        self.store = store
        self.accounts = accounts
        self.shell = shell
        self.services = services
        self.profiles = profiles
        realMode = services != nil
        transcripts = mockTranscripts
        super.init(fill: Palette.bg)
        content.page = self
        scroll.documentView = content
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipResized), name: NSView.frameDidChangeNotification,
                                               object: scroll.contentView)
        problemBanner.onDismiss = { [weak store] in store?.dismissProblem() }
        problemBanner.onReveal = { [weak store] in store?.revealProblemFile() }
        problemBanner.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(problemBanner)
        addSubview(scroll)
        let atTop = scroll.topAnchor.constraint(equalTo: topAnchor)
        scrollAtTop = atTop
        scrollUnderBanner = scroll.topAnchor.constraint(equalTo: problemBanner.bottomAnchor)
        NSLayoutConstraint.activate([
            problemBanner.leadingAnchor.constraint(equalTo: leadingAnchor),
            problemBanner.trailingAnchor.constraint(equalTo: trailingAnchor),
            problemBanner.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            atTop,
        ])
        setAccessibilityLabel("主頁")
    }

    /// Starts rendering (and reading `.claude.json`, the transcripts) when shown; stops when hidden.
    func setActive(_ active: Bool) {
        isActive = active
        if active, loop == nil {
            services?.reloadRecentProjects()
            transcriptFolders = []
            loop = ObservationLoop(track: { [weak self] in self?.buildModel() }, apply: { [weak self] model in
                guard let self, let model else { return }
                self.apply(model)
            })
        } else if !active {
            loop?.cancel()
            loop = nil
            transcriptTask?.cancel()
            transcriptTask = nil
        }
    }

    /// The pane's 1 Hz tick: the problem's age, every duration on the page, the date (per minute).
    func tick(now: Date) {
        problemBanner.tick(now: now)
        guard isActive else { return }
        content.tick(now: now)
    }

    /// Kept for the pane (M1 name).
    func tickProblem(now: Date) { tick(now: now) }

    // MARK: Model

    /// Tracked: reads the stores, the sidebar order inputs, `.claude.json` and the profiles.
    private func buildModel() -> HomeModel {
        problemBanner.update(store.problem, now: store.clock.now())
        let snapshot = SidebarSnapshotBuilder.build(store: store, mode: shell.sidebarMode, filter: shell.filterText)
        var inputs = HomeModel.Inputs()
        inputs.sessionOrder = snapshot.sessionOrder
        inputs.suggestions = services?.recentProjects ?? []
        inputs.transcripts = transcripts
        if let services { inputs.usedClaudeSessionIDs = services.coddClaudeSessionIds.union(services.inUseClaudeSessionIds) }
        inputs.realMode = realMode
        inputs.sampleAccounts = accounts.isPlaceholder
        inputs.accountSource = accounts.sourceLabel
        inputs.accountNote = accounts.availability.note
        var model = HomeModel.build(store: store, inputs: inputs, now: store.clock.now())
        model.fillUsage(accounts)
        model.profileName = (profiles?.document ?? .seeded).claudeProfile(id: nil).name
        return model
    }

    private func apply(_ next: HomeModel) {
        if problemBanner.isHidden {
            scrollUnderBanner?.isActive = false
            scrollAtTop?.isActive = true
        } else {
            scrollAtTop?.isActive = false
            scrollUnderBanner?.isActive = true
        }
        loadTranscriptsIfNeeded()
        guard next != model || content.subviews.isEmpty else { return }
        let start = ContinuousClock.now
        model = next
        content.show(next, now: store.clock.now())
        layoutContent()
        lastRenderDuration = ContinuousClock.now - start
        #if DEBUG
        HolderSessionStore.printLog(String(format: "HOME render ms=%.2f cards=%d launch=%d stopped=%d", TerminalHub.milliseconds(ContinuousClock.now - start),
                                           next.needsYou.count, next.launch.count, next.stopped.count))
        #endif
        onModelChange?()
    }

    /// Reads up to 3 transcripts for each of the 6 most recently active projects (cached by
    /// `AppServices` for 10 s), then renders again.
    private func loadTranscriptsIfNeeded() {
        guard let services else { return }
        let folders = HomeModel.transcriptFolders(store: store)
        guard folders != transcriptFolders else { return }
        transcriptFolders = folders
        transcriptTask?.cancel()
        transcriptTask = Task { [weak self, weak services] in
            var found: [String: [TranscriptSummary]] = [:]
            for folder in folders {
                guard let services, !Task.isCancelled else { return }
                found[folder] = await services.transcripts(for: folder, limit: HomeModel.transcriptsPerProject)
            }
            guard let self, !Task.isCancelled else { return }
            self.transcripts = found
            self.loop?.refresh()
        }
    }

    // MARK: Layout

    @objc private func clipResized() { layoutContent() }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let width = scroll.contentView.bounds.width
        guard width > 0 else { return }
        let height = content.layoutContent(width: width)
        let size = NSSize(width: width, height: max(height, scroll.contentView.bounds.height))
        if content.frame.size != size { content.setFrameSize(size) }
    }

    // MARK: Actions

    fileprivate func open(_ id: SessionID) { onOpen?(id) }

    fileprivate func allow(_ id: SessionID) {
        guard let session = store.session(id), !session.external, session.state == .waiting, session.waitingReason == .permission else {
            NSSound.beep()
            return
        }
        store.answer(id, key: "1")
    }

    fileprivate func launch(_ path: String, kind: SessionKind) {
        guard let services else { NSSound.beep(); return }
        var request = NewSessionRequest(cwd: path, kind: kind)
        request.claude.profileID = nil  // the default profile (the pill above)
        report(services.launch(request))
    }

    fileprivate func resume(_ row: HomeModel.StoppedRow) {
        switch row.kind {
        case .session:
            store.resume(row.id)
            onOpen?(row.id)
        case .transcript:
            guard let services, let cwd = row.cwd else { NSSound.beep(); return }
            var request = NewSessionRequest(cwd: cwd, kind: .claude)
            request.claude.mode = .resume(row.id)
            request.resumeTitle = row.title
            report(services.launch(request))
        }
    }

    fileprivate func newSession() {
        guard let services else { NSSound.beep(); return }
        services.showNewSession(NewSessionForm())
    }

    /// `全部對話紀錄 →`: the ⌘N sheet on `接續先前對話`, its picker listing the folder's
    /// conversations (the most recently active project's when no session is shown).
    fileprivate func allTranscripts() {
        guard let services else { NSSound.beep(); return }
        var form = NewSessionForm()
        form.start = .resume(nil)
        services.showNewSession(form)
    }

    fileprivate func showProfileMenu(from view: NSView) {
        let document = profiles?.document ?? .seeded
        let current = document.claudeProfile(id: nil).id
        let menu = NSMenu()
        menu.autoenablesItems = false
        for profile in document.profiles where profile.kind == .claude {
            let item = ClosureMenuItem(title: profile.name) { [weak self] in self?.profiles?.setDefault(profile.id) }
            item.state = profile.id == current ? .on : .off
            item.isEnabled = profiles?.canEdit ?? false
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    fileprivate func openAccountSettings() { onOpenSettings?("accounts") }

    /// An account's capture time for USAGE's `statusline · 12s 前`, read at the tick (outside the
    /// observation loop, so a report does not rebuild the page).
    fileprivate func sourceAt(_ id: AccountID) -> Date? { accounts.account(id)?.sourceAt }

    private func report(_ problem: String??) {
        guard case let problem?? = problem else { return }
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "無法開始 session"
        alert.informativeText = problem
        if let window { alert.beginSheetModal(for: window) }
    }
}

/// The scroll view's document: every Home section laid out by hand for the page width
/// (`.hm-scroll` padding 28 / 36, gap 20; grids `auto-fit minmax(280px, 1fr)` gap 12 and
/// `minmax(420px, 1fr)` gap 22).
final class HomeContentView: FlippedView {
    fileprivate weak var page: HomePageView?
    private let header = HomeHeaderView()
    private let emptyText = WrappingLabel(
        "選一個專案資料夾，開一個 CLAUDE 或 SHELL session。Session 由 codd-holder 持有：關掉 CODD 也會繼續跑，下次開啟會接回來。",
        style: TextStyle.mono(12, Palette.bone))
    private let emptyButton = CoddButton("+ New session", style: .bracket(.primary, small: false))
    private let needsHead = HomeSectionHeadView(title: "Needs you", glyph: "◆")
    private let launchHead = HomeSectionHeadView(title: "Launch", zh: "最近專案")
    private let stoppedHead = HomeSectionHeadView(title: "Recently stopped", zh: "可接續")
    private let usageHead = HomeSectionHeadView(title: "Usage", zh: "剩餘")
    private let profilePill = ProfilePillButton(profileName: LaunchProfileDocument.builtInDefaultId)
    private let otherProjects = CoddButton("其他專案…", style: .bracket(.normal, small: true))
    private let allTranscripts = HomeLinkButton("全部對話紀錄 →")
    private let usageNote = HomeTextView()
    private let autoSwitch = AutoSwitchLineView()
    private var cards: [NeedsYouCardView] = []
    private var doneLine: DoneLineView?
    private var launchCards: [LaunchCardView] = []
    private var stoppedList: StoppedListView?
    private var usageList: UsageListView?
    private var model = HomeModel()

    static var padding: NSEdgeInsets { UIZoom.insets(NSEdgeInsets(top: 28, left: 36, bottom: 28, right: 36)) }
    static var sectionGap: CGFloat { hz(20) }
    static var headGap: CGFloat { hz(10) }
    static var gridGap: CGFloat { hz(12) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        emptyButton.trailing = "⌘N"
        otherProjects.trailing = "⌘N"
        emptyButton.target = self
        emptyButton.action = #selector(newSession)
        otherProjects.target = self
        otherProjects.action = #selector(newSession)
        profilePill.target = self
        profilePill.action = #selector(profileMenu(_:))
        allTranscripts.target = self
        allTranscripts.action = #selector(showAllTranscripts)
        autoSwitch.link.target = self
        autoSwitch.link.action = #selector(accountSettings)
        launchHead.accessories = [profilePill, otherProjects]
        stoppedHead.accessories = [allTranscripts]
        usageHead.accessories = [usageNote]
        for view in [header, emptyText, emptyButton, needsHead, launchHead, stoppedHead, usageHead, autoSwitch] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebuilds the sections for `model` (only called when it changed).
    func show(_ model: HomeModel, now: Date) {
        self.model = model
        header.comment = model.isEmpty ? "// 還沒有任何 session" : "// 沒有選取 session"
        header.counts = model.counts
        header.tick(now: now)
        emptyText.isHidden = !model.isEmpty
        emptyButton.isHidden = !model.isEmpty

        cards.forEach { $0.removeFromSuperview() }
        cards = model.needsYou.map { card in
            let view = NeedsYouCardView(card, now: now, target: self, allowAction: #selector(allowPressed(_:)), goAction: #selector(goPressed(_:)))
            addSubview(view)
            return view
        }
        needsHead.badge = model.needsYou.isEmpty ? nil : model.needsYou.count
        doneLine?.removeFromSuperview()
        doneLine = model.done.map { line in
            let view = DoneLineView(line, now: now)
            view.onClick = { [weak self] in self?.page?.open(line.id) }
            addSubview(view)
            return view
        }
        launchCards.forEach { $0.removeFromSuperview() }
        launchCards = model.launch.map { card in
            let view = LaunchCardView(card, now: now, target: self, claudeAction: #selector(claudePressed(_:)), shellAction: #selector(shellPressed(_:)))
            addSubview(view)
            return view
        }
        profilePill.profileName = model.profileName
        profilePill.setAccessibilityLabel("啟動設定檔：\(model.profileName)")
        stoppedList?.removeFromSuperview()
        if model.stopped.isEmpty {
            stoppedList = nil
        } else {
            let list = StoppedListView(model.stopped, now: now)
            list.onResume = { [weak self] row in self?.page?.resume(row) }
            addSubview(list)
            stoppedList = list
        }
        usageList?.removeFromSuperview()
        let usage = UsageListView(model.usage, now: now) { [weak page] id in page?.sourceAt(id) }
        addSubview(usage)
        usageList = usage
        usageNote.text = TextStyle.mono(11, Palette.dim).string(model.usageHeader)
        autoSwitch.on = model.autoSwitchOn
        autoSwitch.threshold = model.autoSwitchThreshold
        for view in [needsHead] as [NSView] { view.isHidden = model.needsYou.isEmpty && model.done == nil }
        launchHead.isHidden = model.launch.isEmpty
        stoppedHead.isHidden = model.stopped.isEmpty
        needsLayout = true
    }

    func tick(now: Date) {
        header.tick(now: now)
        for view in subviews { (view as? HomeTicking)?.tick(now: now) }
    }

    /// `auto-fit, minmax(min, 1fr)`: as many columns as fit, equally wide.
    static func columns(width: CGFloat, minimum: CGFloat, gap: CGFloat) -> (count: Int, width: CGFloat) {
        let count = max(1, Int((width + gap) / (min(minimum, width) + gap)))
        return (count, (width - gap * CGFloat(count - 1)) / CGFloat(count))
    }

    /// Lays everything out for `width`; returns the content height.
    @discardableResult
    func layoutContent(width: CGFloat) -> CGFloat {
        let pad = Self.padding
        let inner = max(0, width - pad.left - pad.right)
        let x0 = pad.left
        var y = pad.top
        header.frame = CGRect(x: x0, y: y, width: inner, height: HomeHeaderView.height)
        y = header.frame.maxY
        if model.isEmpty {
            y += Self.sectionGap
            let size = emptyText.sizeThatFits(NSSize(width: inner, height: .greatestFiniteMagnitude))
            emptyText.preferredMaxLayoutWidth = inner
            emptyText.frame = CGRect(x: x0, y: y, width: inner, height: ceil(size.height))
            y = emptyText.frame.maxY + hz(12)
            let buttonSize = emptyButton.intrinsicContentSize
            emptyButton.frame = CGRect(x: x0, y: y, width: buttonSize.width, height: buttonSize.height)
            y = emptyButton.frame.maxY
        }
        if !needsHead.isHidden {
            y += Self.sectionGap
            needsHead.frame = CGRect(x: x0, y: y, width: inner, height: HomeSectionHeadView.height)
            y = needsHead.frame.maxY + Self.headGap
            y = grid(cards, x: x0, y: y, width: inner, minimum: hz(280), gap: Self.gridGap, height: NeedsYouCardView.height,
                     outset: HomeCardBoxView.outset)
            if let doneLine {
                if !cards.isEmpty { y += Self.headGap }
                doneLine.frame = CGRect(x: x0, y: y, width: inner, height: DoneLineView.height)
                y = doneLine.frame.maxY
            }
        }
        if !launchHead.isHidden {
            y += Self.sectionGap
            launchHead.frame = CGRect(x: x0, y: y, width: inner, height: HomeSectionHeadView.height)
            y = launchHead.frame.maxY + Self.headGap
            y = grid(launchCards, x: x0, y: y, width: inner, minimum: hz(280), gap: Self.gridGap, height: LaunchCardView.height,
                     outset: 0)
        }
        // RECENTLY STOPPED (left) and USAGE (right): `minmax(420px, 1fr)`, gap 22, top aligned.
        y += Self.sectionGap
        let showStopped = stoppedList != nil
        let columns = Self.columns(width: inner, minimum: hz(420), gap: hz(22))
        let twoColumns = showStopped && columns.count >= 2
        let columnWidth = twoColumns ? columns.width : inner
        var stoppedBottom = y
        if let stoppedList {
            stoppedHead.frame = CGRect(x: x0, y: y, width: columnWidth, height: HomeSectionHeadView.height)
            stoppedList.frame = CGRect(x: x0, y: stoppedHead.frame.maxY + Self.headGap, width: columnWidth, height: stoppedList.height)
            stoppedBottom = stoppedList.frame.maxY
        }
        let usageX = twoColumns ? x0 + columnWidth + hz(22) : x0
        var usageY = twoColumns || !showStopped ? y : stoppedBottom + Self.sectionGap
        usageHead.frame = CGRect(x: usageX, y: usageY, width: columnWidth, height: HomeSectionHeadView.height)
        usageY = usageHead.frame.maxY + Self.headGap
        if let usageList {
            usageList.frame = CGRect(x: usageX, y: usageY, width: columnWidth, height: usageList.height)
            usageY = usageList.frame.maxY + Self.headGap
        }
        autoSwitch.frame = CGRect(x: usageX, y: usageY, width: columnWidth, height: hz(16))
        usageY = autoSwitch.frame.maxY
        y = max(stoppedBottom, usageY)
        for view in subviews { view.needsDisplay = true }
        return y + pad.bottom
    }

    /// Places `views` in an auto-fit grid; returns the bottom.
    private func grid(_ views: [NSView], x: CGFloat, y: CGFloat, width: CGFloat, minimum: CGFloat, gap: CGFloat,
                      height: CGFloat, outset: CGFloat) -> CGFloat {
        guard !views.isEmpty else { return y }
        let (count, cell) = Self.columns(width: width, minimum: minimum, gap: gap)
        var bottom = y
        for (index, view) in views.enumerated() {
            let row = index / count
            let column = index % count
            let top = y + CGFloat(row) * (height + gap)
            view.frame = CGRect(x: x + CGFloat(column) * (cell + gap), y: top - outset, width: cell, height: height + outset * 2)
            bottom = max(bottom, top + height)
        }
        return bottom
    }

    // MARK: Actions

    @objc private func allowPressed(_ sender: CoddButton) {
        guard let card = (sender.superview as? NeedsYouCardView)?.card else { return }
        page?.allow(card.id)
    }

    @objc private func goPressed(_ sender: CoddButton) {
        guard let card = (sender.superview as? NeedsYouCardView)?.card else { return }
        page?.open(card.id)
    }

    @objc private func claudePressed(_ sender: CoddButton) {
        guard let card = (sender.superview as? LaunchCardView)?.card else { return }
        page?.launch(card.path, kind: .claude)
    }

    @objc private func shellPressed(_ sender: CoddButton) {
        guard let card = (sender.superview as? LaunchCardView)?.card else { return }
        page?.launch(card.path, kind: .shell)
    }

    @objc private func newSession() { page?.newSession() }
    @objc private func showAllTranscripts() { page?.allTranscripts() }
    @objc private func profileMenu(_ sender: NSView) { page?.showProfileMenu(from: sender) }
    @objc private func accountSettings() { page?.openAccountSettings() }

    // MARK: Tests and dumps

    var needsYouCards: [NeedsYouCardView] { cards }
    var launchCardViews: [LaunchCardView] { launchCards }
    var stoppedListView: StoppedListView? { stoppedList }
    var usageHeaderText: String { usageNote.text.string }
}

/// One line of attributed text with an intrinsic size (section head accessories).
final class HomeTextView: FlippedView, ZoomRefreshing {
    /// The owner sizes it from `intrinsicContentSize` in its own `layout()` (frames, not
    /// constraints), so a new text asks the owner to lay out again: the USAGE note used to keep
    /// the width of its first, shorter text and end in `…` (M3 review).
    var text = NSAttributedString() {
        didSet {
            guard text != oldValue else { return }
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            superview?.needsDisplay = true
            needsDisplay = true
        }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: Draw.width(text), height: UIZoom.pt(18)) }
    override func draw(_ dirtyRect: NSRect) { Draw.text(text, x: 0, centerY: bounds.midY, maxWidth: bounds.width) }

    /// M4 interface zoom: the text built at the old zoom is made again at the new one.
    func zoomDidChange() {
        if let scaled = Typeface.rescaled(text) { text = scaled }
    }
}
