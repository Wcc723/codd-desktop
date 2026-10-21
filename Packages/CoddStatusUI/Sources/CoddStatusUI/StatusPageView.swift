import AppKit
import CoddUI

/// The STATUS page (Status artboard `.sx-page`): a scrolling page with 28 / 36 padding, the header
/// `STATUS … [● LIVE] [↻ 立即更新]` and `UPDATED hh:mm:ss · 每 5 秒`, then HOST, ACCOUNTS and two
/// columns (HOOKS & STATUSLINE | MCP SERVER + REMOTE).
///
/// `apply(_:)` reconfigures only the sections (and, inside them, the cards) whose values changed.
/// Relative times tick once a second through `UITicker` while the page is in a window; only those
/// labels are touched by a tick.
@MainActor
public final class StatusPageView: NSView, SecondTicking {
    /// The section scrolled to the top area changed (the app mirrors it in the sidebar nav).
    public var onVisibleSectionChange: ((StatusSection) -> Void)?
    /// The clock for relative times (tests inject a fixed one).
    public var now: () -> Date = { UITicker.shared.clock.now() }
    /// The calendar of the `UPDATED hh:mm:ss` clock (tests and the demo pin a time zone).
    public var calendar: Calendar = .current

    private var actions: StatusPageActions
    private(set) var model: StatusPageModel?

    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let title = TextLine("STATUS", style: TextStyle.pageTitle)
    private let liveChip = ChipLabel("Live", style: StatusChips.caps(.ok), lead: ("●", Palette.success, true))
    let refreshButton = CoddButton("↻ 立即更新", style: .bracket(.normal, small: true))
    private let metaRule = MetaRuleView()
    let host = HostSectionView()
    let accounts = AccountsSectionView()
    let hooks = HooksSectionView()
    let mcp = MCPSectionView()
    let remote = RemoteSectionView()
    private var refreshHolder: ButtonAction?
    private var ticking = false
    private var lastVisible: StatusSection?
    /// A nav click's section and the offset it scrolled to: reported until the user scrolls away.
    private var navigated: (section: StatusSection, offset: CGFloat)?
    /// Page header updates (tests).
    private(set) var headerConfigureCount = 0

    static var padding: NSEdgeInsets { NSEdgeInsets(top: sz(28), left: sz(36), bottom: sz(20), right: sz(36)) }
    /// Below this content width the HOOKS | MCP + REMOTE columns stack (the artboard has 1148).
    static var twoColumnWidth: CGFloat { sz(860) }

    public init(actions: StatusPageActions) {
        self.actions = actions
        super.init(frame: CGRect(x: 0, y: 0, width: sz(1220), height: sz(900)))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("狀態")

        scroll.drawsBackground = false
        // In a full-size-content window the title bar would add its height as a top inset.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)

        refreshButton.setAccessibilityLabel("立即更新")
        refreshHolder = refreshButton.onPress { [weak self] in self?.actions.refresh() }
        for view: NSView in [title, liveChip, refreshButton, metaRule, host, accounts, hooks, mcp, remote] {
            document.addSubview(view)
        }
        wireActions()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    /// FB: the cswap install guide's `[複製]` and `[在終端機執行]` (its `[↻ 重新偵測]` is `refresh`).
    public var cswapGuideActions: CswapGuideActions {
        get { accounts.guideActions }
        set { accounts.guideActions = newValue }
    }

    /// Replaces the closures.
    public func setActions(_ actions: StatusPageActions) {
        self.actions = actions
        wireActions()
    }

    private func wireActions() {
        accounts.actions = actions
        hooks.actions = actions
        mcp.actions = actions
        remote.onSettings = { [weak self] in self?.actions.openRemoteSettings() }
    }

    // MARK: Model

    public func apply(_ model: StatusPageModel) {
        let old = self.model
        self.model = model
        let now = now()
        if old?.updatedAt != model.updatedAt || old?.paused != model.paused || old?.live != model.live
            || old?.refreshSeconds != model.refreshSeconds {
            headerConfigureCount += 1
            let interval = model.paused ? "已暫停" : "每 \(model.refreshSeconds) 秒"
            metaRule.set("UPDATED \(ClockFormat.hourMinuteSecond(model.updatedAt, calendar: calendar)) · \(interval)")
            if model.paused {
                liveChip.set("Paused", style: StatusChips.caps(.plain), lead: ("○", Palette.dim, false))
            } else if model.live {
                liveChip.set("Live", style: StatusChips.caps(.ok), lead: ("●", Palette.success, true))
            } else {
                liveChip.set("Offline", style: StatusChips.caps(.plain), lead: ("○", Palette.dimmer, false))
            }
        }
        let sizes = (host.configureCount, accounts.configureCount, hooks.configureCount, mcp.configureCount, remote.model)
        host.configure(model.host)
        accounts.configure(model.accounts, now: now)
        hooks.configure(model.hooks, now: now)
        mcp.configure(model.mcp)
        remote.configure(model.remote)
        if sizes != (host.configureCount, accounts.configureCount, hooks.configureCount, mcp.configureCount, remote.model) || old == nil {
            needsLayout = true
        }
        updateTicking()
    }

    // MARK: Scrolling

    /// Scrolls so `section`'s header sits at the top padding (HOST: the very top).
    public func scroll(to section: StatusSection) {
        layoutSubtreeIfNeeded()
        let y = section == .host ? 0 : anchor(of: section) - Self.padding.top
        let maxY = max(0, document.frame.height - scroll.contentSize.height)
        let target = min(max(0, y), maxY)
        navigated = (section, target)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Opens or closes the HOOKS card's `▸ 詳細` (the app's DEBUG snapshots).
    public func toggleEndpointDetails() { hooks.card.toggleDetails() }

    /// Whether the HOOKS card's diagnostics are shown.
    public var isShowingEndpointDetails: Bool { hooks.card.detailsOpen }

    /// The section's frame in this view's coordinates (scrolled with the page): the demo's
    /// per-section snapshots crop to it.
    public func sectionRect(_ section: StatusSection) -> CGRect {
        let view: NSView = switch section {
        case .host: host
        case .accounts: accounts
        case .hooks: hooks
        case .mcp: mcp
        case .remote: remote
        }
        return convert(view.bounds, from: view)
    }

    /// The section's top in the scrolled document.
    func anchor(of section: StatusSection) -> CGFloat {
        switch section {
        case .host: host.frame.minY
        case .accounts: accounts.frame.minY
        case .hooks: hooks.frame.minY
        case .mcp: mcp.frame.minY
        case .remote: remote.frame.minY
        }
    }

    /// The current scroll offset (tests).
    var scrollOffset: CGFloat { scroll.contentView.bounds.minY }

    /// Scrolls like the wheel would (tests): no nav section is kept.
    func scrollTo(offset: CGFloat) {
        let maxY = max(0, document.frame.height - scroll.contentSize.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, offset), maxY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The section whose header is the last one at or above the top area (ties keep the earlier
    /// section, so HOOKS wins over MCP on their shared row). After a nav click, the clicked
    /// section until the page is scrolled by hand; at the end of the page, the last section whose
    /// header shows (M3 review: HOOKS, MCP and REMOTE could never be highlighted at 1440 × 900,
    /// their headers never reach the top line).
    func visibleSection() -> StatusSection {
        let offset = scroll.contentView.bounds.minY
        if let navigated {
            if abs(offset - navigated.offset) < 1 { return navigated.section }
            self.navigated = nil
        }
        let maxOffset = max(0, document.frame.height - scroll.contentSize.height)
        if maxOffset > 0, offset >= maxOffset - 1 {
            let bottom = offset + scroll.contentSize.height
            var last = StatusSection.host
            var lastY = -CGFloat.greatestFiniteMagnitude
            for section in StatusSection.allCases {
                let y = section == .host ? 0 : anchor(of: section)
                if y < bottom - sz(40), y > lastY {
                    last = section
                    lastY = y
                }
            }
            return last
        }
        let line = offset + Self.padding.top + sz(40)
        var best = StatusSection.host
        var bestY = -CGFloat.greatestFiniteMagnitude
        for section in StatusSection.allCases {
            let y = section == .host ? 0 : anchor(of: section)
            if y <= line, y > bestY {
                best = section
                bestY = y
            }
        }
        return best
    }

    @objc private func scrolled() {
        let section = visibleSection()
        guard section != lastVisible else { return }
        lastVisible = section
        onVisibleSectionChange?(section)
    }

    // MARK: Ticking

    var isTicking: Bool { ticking }

    private func updateTicking() {
        let want = window != nil && model != nil
        if want, !ticking { ticking = true; UITicker.shared.addSecond(self) }
        if !want, ticking { ticking = false; UITicker.shared.removeSecond(self) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicking()
        // Relative times went stale while the page was off screen.
        if window != nil, model != nil { secondTick(now: now()) }
    }

    override public func viewDidHide() {
        super.viewDidHide()
        UITicker.shared.updateTimers()
    }

    override public func viewDidUnhide() {
        super.viewDidUnhide()
        UITicker.shared.updateTimers()
    }

    /// Re-renders the relative times only (countdowns, ages); nothing is rebuilt.
    public func secondTick(now: Date) {
        accounts.tick(now: now)
        hooks.tick(now: now)
    }

    // MARK: Layout

    override public func layout() {
        super.layout()
        scroll.frame = bounds
        layoutDocument(width: scroll.contentSize.width)
        // Cards made since the last pass bring CoddUI views that would keep a stale drawing.
        ResizeRedraw.adopt(in: document)
    }

    /// Lays out the document at `width` and returns its height.
    @discardableResult
    func layoutDocument(width: CGFloat) -> CGFloat {
        let pad = Self.padding
        let x = pad.left
        let inner = max(0, width - pad.left - pad.right)
        var y = pad.top
        // Header row (31.2) then `gap:8px` and the meta rule (16.5).
        let button = refreshButton.intrinsicContentSize
        refreshButton.frame = CGRect(x: x + inner - button.width, y: y + sz(4.6), width: button.width, height: sz(22))
        let chip = liveChip.intrinsicContentSize
        liveChip.frame = CGRect(x: refreshButton.frame.minX - sz(10) - chip.width, y: y + sz(5.6), width: chip.width, height: sz(20))
        title.frame = CGRect(x: x, y: y, width: max(0, liveChip.frame.minX - sz(10) - x), height: sz(31))
        y += sz(31.2) + sz(8)
        metaRule.frame = CGRect(x: x, y: round(y), width: inner, height: sz(16.5))
        y += sz(16.5) + sz(20)
        y = round(y)

        let hostHeight = host.height(forWidth: inner)
        host.frame = CGRect(x: x, y: y, width: inner, height: hostHeight)
        y += hostHeight + sz(20)
        let accountsHeight = accounts.height(forWidth: inner)
        accounts.frame = CGRect(x: x, y: y, width: inner, height: accountsHeight)
        y += accountsHeight + sz(20)

        if inner >= Self.twoColumnWidth {
            // `.sx-two{grid-template-columns:minmax(0,1.3fr) minmax(0,1fr); gap:20px; align-items:start}`.
            let left = round((inner - sz(20)) * 1.3 / 2.3)
            let right = inner - sz(20) - left
            let hooksHeight = hooks.height(forWidth: left)
            hooks.frame = CGRect(x: x, y: y, width: left, height: hooksHeight)
            let mcpHeight = mcp.height(forWidth: right)
            mcp.frame = CGRect(x: x + left + sz(20), y: y, width: right, height: mcpHeight)
            let remoteHeight = remote.height(forWidth: right)
            remote.frame = CGRect(x: x + left + sz(20), y: y + mcpHeight + sz(10), width: right, height: remoteHeight)
            y += max(hooksHeight, mcpHeight + sz(10) + remoteHeight) + pad.bottom
        } else {
            // A narrow page stacks the columns (HOOKS, MCP, REMOTE).
            for section in [hooks as NSView, mcp, remote] {
                let h: CGFloat
                switch section {
                case let view as HooksSectionView: h = view.height(forWidth: inner)
                case let view as MCPSectionView: h = view.height(forWidth: inner)
                case let view as RemoteSectionView: h = view.height(forWidth: inner)
                default: h = 0
                }
                section.frame = CGRect(x: x, y: y, width: inner, height: h)
                y += h + sz(20)
            }
            y += pad.bottom - sz(20)
        }

        let height = max(y, scroll.contentSize.height)
        if document.frame.size != CGSize(width: width, height: height) {
            document.frame = CGRect(x: 0, y: 0, width: width, height: height)
        }
        return y
    }

    override public func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
    }

    // MARK: Testing

    var visibleTexts: [String] { document.statusVisibleTexts() }
    /// The laid-out page height (demo, tests).
    public var documentHeight: CGFloat { document.frame.height }
    var liveChipText: String { liveChip.displayedText }
    var metaText: String { metaRule.displayedText }
}
