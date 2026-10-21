import AppKit
import CoddUI

/// The 220 px STATUS sidebar (Status artboard `aside.sx-side`): head `STATUS ↻`, SECTIONS nav,
/// the NEEDS YOU mini list (so attention stays visible on STATUS), SESSIONS counts with
/// `→ 開啟 SESSIONS`, and the refresh footer (`Refresh 每 5 秒`, `上次 hh:mm:ss`, `[暫停]`).
/// The app shows it in place of the session sidebar while the rail is on STATUS (D16).
@MainActor
public final class StatusSidebarView: NSView, SecondTicking {
    public static var preferredWidth: CGFloat { sz(220) }

    /// A nav item was clicked: the app scrolls the page (`StatusPageView.scroll(to:)`).
    public var onSelectSection: ((StatusSection) -> Void)?
    /// The highlighted nav item (`.sx-ni.on`); the app mirrors the page's visible section.
    public var selectedSection: StatusSection = .host {
        didSet { if selectedSection != oldValue { for item in navViews { item.isCurrent = item.section == selectedSection } } }
    }
    /// The clock for durations (tests inject a fixed one).
    public var now: () -> Date = { UITicker.shared.clock.now() }
    /// The calendar of the `上次 hh:mm:ss` clock.
    public var calendar: Calendar = .current

    private var actions: StatusPageActions
    private(set) var model: StatusPageModel?

    // Head
    private let brand = TextLine("STATUS", style: TextStyle(font: Typeface.display(15), color: Palette.amber,
                                                             tracking: 0.04, shadow: Draw.glow(Palette.amberGlow, radius: 8)))
    let refreshButton = CoddButton("↻", style: .glyph())

    // Scrolling middle
    private let scroll = NSScrollView()
    private let document = FlippedView()
    private let sectionsHeader = SidebarSectionHeader()
    private(set) var navViews: [StatusNavItemView] = []
    private let needsBlock = NeedsBlockView()
    private let sessionsHeader = SidebarSectionHeader()
    private var countViews: [CountRowView] = []
    let goLive = LinkRow("→ 開啟 SESSIONS")

    // Footer
    private let refreshLabel = TextLine("Refresh", style: TextStyle.caps(9.5, Palette.dim, tracking: 0.18))
    private let intervalLabel = TextLine("", style: TextStyle.mono(11, Palette.dim))
    private let lastLabel = TextLine("", style: TextStyle.mono(11, Palette.dimmer))
    let pauseButton = CoddButton("暫停", style: .bracket(.normal, small: true))

    private var ticking = false

    public init(actions: StatusPageActions) {
        self.actions = actions
        super.init(frame: CGRect(x: 0, y: 0, width: Self.preferredWidth, height: sz(900)))
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("狀態區段")

        refreshButton.setAccessibilityLabel("立即更新")
        refreshButton.toolTip = "立即更新"
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)
        addSubview(brand)
        addSubview(refreshButton)

        scroll.drawsBackground = false
        // In a full-size-content window the title bar would add its height as a top inset.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = document
        addSubview(scroll)

        sectionsHeader.configure(title: "Sections")
        document.addSubview(sectionsHeader)
        for section in StatusSection.allCases {
            let item = StatusNavItemView(section: section)
            item.isCurrent = section == selectedSection
            item.onClick = { [weak self] in self?.select(section) }
            navViews.append(item)
            document.addSubview(item)
        }
        needsBlock.onOpen = { [weak self] id in self?.actions.openSession(id) }
        needsBlock.onToggle = { [weak self] in self?.needsLayout = true }
        document.addSubview(needsBlock)
        document.addSubview(sessionsHeader)
        goLive.onClick = { [weak self] in self?.actions.openSessions() }
        goLive.setAccessibilityLabel("開啟 SESSIONS")
        document.addSubview(goLive)

        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        for view in [refreshLabel, intervalLabel, lastLabel, pauseButton] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }
    override public var intrinsicContentSize: NSSize { NSSize(width: Self.preferredWidth, height: NSView.noIntrinsicMetric) }

    /// Replaces the closures (the app may rebuild them).
    public func setActions(_ actions: StatusPageActions) { self.actions = actions }

    // MARK: Model

    /// Applies a new model; only the parts whose values changed are touched.
    public func apply(_ model: StatusPageModel) {
        let old = self.model
        self.model = model
        let now = now()
        if old?.nav != model.nav {
            for item in navViews {
                if let nav = model.nav.first(where: { $0.id == item.section }) {
                    item.configure(nav)
                    item.isHidden = false
                } else {
                    item.isHidden = true
                }
            }
        }
        if old?.needsYou != model.needsYou {
            needsBlock.configure(model.needsYou, now: now)
        }
        if old?.liveCount != model.liveCount || old == nil {
            sessionsHeader.configure(title: "Sessions", count: "\(model.liveCount) live")
        }
        if old?.counts != model.counts {
            if countViews.count != model.counts.count {
                countViews.forEach { $0.removeFromSuperview() }
                countViews = model.counts.map { _ in CountRowView() }
                countViews.forEach { document.addSubview($0) }
            }
            for (view, count) in zip(countViews, model.counts) { view.configure(count) }
        }
        if old?.paused != model.paused || old?.refreshSeconds != model.refreshSeconds {
            intervalLabel.set(model.paused ? "已暫停" : "每 \(model.refreshSeconds) 秒",
                              style: TextStyle.mono(11, model.paused ? Palette.amber : Palette.dim))
            pauseButton.label = model.paused ? "繼續" : "暫停"
            pauseButton.setAccessibilityLabel(model.paused ? "繼續自動更新" : "暫停自動更新")
        }
        if old?.updatedAt != model.updatedAt {
            lastLabel.set("上次 \(ClockFormat.hourMinuteSecond(model.updatedAt, calendar: calendar))", style: TextStyle.mono(11, Palette.dimmer))
        }
        if old != model { needsLayout = true }
        updateTicking()
    }

    private func select(_ section: StatusSection) {
        selectedSection = section
        onSelectSection?(section)
    }

    @objc private func refreshClicked() { actions.refresh() }
    @objc private func pauseClicked() { actions.togglePause() }

    // MARK: Ticking (NEEDS YOU durations, 1 Hz while on screen)

    /// True while subscribed to the 1 Hz ticker (tests).
    var isTicking: Bool { ticking }

    private func updateTicking() {
        let want = window != nil && !(model?.needsYou.isEmpty ?? true)
        if want, !ticking { ticking = true; UITicker.shared.addSecond(self) }
        if !want, ticking { ticking = false; UITicker.shared.removeSecond(self) }
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicking()
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

    public func secondTick(now: Date) {
        needsBlock.tick(now: now)
    }

    // MARK: Layout

    override public func layout() {
        super.layout()
        let width = bounds.width
        let content = width - 1   // the right border
        brand.frame = CGRect(x: sz(14), y: sz(26) - brand.lineHeight / 2, width: brand.textWidth + sz(4), height: brand.lineHeight)
        refreshButton.frame = CGRect(x: content - sz(10) - sz(28), y: sz(12), width: sz(28), height: sz(28))

        // Footer: `.side-foot{padding:8px 12px 10px; gap:6px}`, rows 16.5 and 22.
        let footHeight: CGFloat = sz(63.5)
        let footTop = bounds.height - footHeight
        let row1 = footTop + 1 + sz(8) + sz(8.25)
        refreshLabel.frame = CGRect(x: sz(12), y: row1 - sz(8), width: refreshLabel.textWidth + sz(2), height: sz(16))
        intervalLabel.frame = CGRect(x: content - sz(12) - intervalLabel.textWidth, y: row1 - sz(8), width: intervalLabel.textWidth, height: sz(16))
        let row2 = footTop + 1 + sz(8) + sz(16.5) + sz(6) + sz(11)
        let pause = pauseButton.intrinsicContentSize
        pauseButton.frame = CGRect(x: content - sz(12) - pause.width, y: round(row2 - sz(11)), width: pause.width, height: sz(22))
        lastLabel.frame = CGRect(x: sz(12), y: row2 - sz(8), width: max(0, pauseButton.frame.minX - sz(20)), height: sz(16))

        scroll.frame = CGRect(x: 0, y: sz(52), width: content, height: max(0, footTop - sz(52)))
        // The clip's width: a legacy (always shown) scroller takes its share of the frame.
        layoutDocument(width: scroll.contentSize.width)
        ResizeRedraw.adopt(in: self)
    }

    private func layoutDocument(width: CGFloat) {
        // `.side-scroll{padding:8px 6px 12px; gap:1px}`.
        let inner = width - sz(12)
        var y: CGFloat = sz(8)
        sectionsHeader.frame = CGRect(x: sz(6), y: y, width: inner, height: sz(27))
        y += sz(27) + 1
        // `.sx-nav{gap:2px; padding-bottom:8px}`.
        let visibleNav = navViews.filter { !$0.isHidden }
        for (i, item) in visibleNav.enumerated() {
            item.frame = CGRect(x: sz(6), y: y, width: inner, height: StatusNavItemView.height)
            y += StatusNavItemView.height + (i == visibleNav.count - 1 ? 0 : sz(2))
        }
        y += sz(8) + 1
        if needsBlock.isHidden {
            needsBlock.frame = .zero
        } else {
            // `.needs{margin:2px 0 6px}`.
            y += sz(2)
            let h = needsBlock.preferredHeight
            needsBlock.frame = CGRect(x: sz(6), y: y, width: inner, height: h)
            y += h + sz(6) + 1
        }
        sessionsHeader.frame = CGRect(x: sz(6), y: y, width: inner, height: sz(27))
        y += sz(27) + 1
        // `.sx-cnts{padding:0 2px 4px}`, rows 22 px.
        for view in countViews {
            view.frame = CGRect(x: sz(8), y: y, width: inner - sz(4), height: sz(22))
            y += sz(22)
        }
        // `.sx-golive{margin:6px 8px 0}`.
        y += sz(6)
        goLive.frame = CGRect(x: sz(16), y: y, width: goLive.intrinsicContentSize.width, height: sz(16.5))
        y += sz(16.5) + sz(4) + sz(12)
        document.frame = CGRect(x: 0, y: 0, width: width, height: max(y, scroll.contentSize.height))
    }

    // MARK: Drawing

    override public func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        Draw.dashedLine(from: CGPoint(x: 0, y: sz(51)), to: CGPoint(x: bounds.width - 1, y: sz(51)), color: Palette.line)
        let footTop = bounds.height - sz(63.5)
        Draw.dashedLine(from: CGPoint(x: 0, y: round(footTop)), to: CGPoint(x: bounds.width - 1, y: round(footTop)), color: Palette.line)
    }

    // MARK: Testing

    /// Every readable string, top to bottom (tests).
    var visibleTexts: [String] { statusVisibleTexts() }
    var needsRows: [NeedsRowView] { needsBlock.rows }
    func navItem(_ section: StatusSection) -> StatusNavItemView? { navViews.first { $0.section == section } }
}

// MARK: - Pieces

/// `.sbsec`: `SECTIONS ┄┄┄`, `SESSIONS 13 live ┄┄┄`, and the NEEDS YOU head
/// (`▸ ◆ NEEDS YOU [3] ┄┄┄`, amber, caret).
final class SidebarSectionHeader: NSView, StatusTextShowing {
    private var title = ""
    private var count: String?
    private var badge: Int?
    private var caretOpen: Bool?
    private var color = Palette.dim

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String {
        [title.uppercased(), badge.map(String.init), count].compactMap { $0 }.joined(separator: " ")
    }

    func configure(title: String, count: String? = nil, badge: Int? = nil, caretOpen: Bool? = nil, color: NSColor = Palette.dim) {
        self.title = title
        self.count = count
        self.badge = badge
        self.caretOpen = caretOpen
        self.color = color
        setAccessibilityValue(displayedText)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // `padding:8px 8px 4px` around a 15 px line.
        let centerY: CGFloat = sz(8) + sz(7.5)
        var x: CGFloat = sz(8)
        if let caretOpen {
            Draw.caret(open: caretOpen, at: CGPoint(x: x, y: centerY), color: Palette.dimmer)
            x += sz(10) + sz(6)
        }
        x += Draw.text(TextStyle.caps(10, color, tracking: 0.18).string(title), x: x, centerY: centerY) + sz(6)
        if let badge {
            x += ChipStyle.badge.draw("\(badge)", x: x, centerY: centerY) + sz(6)
        }
        if let count {
            x += Draw.text(TextStyle.mono(10, Palette.amberDim).string(count), x: x, centerY: centerY) + sz(6)
        }
        let end = bounds.width - sz(8)
        if end > x + sz(4) {
            Draw.dashedLine(from: CGPoint(x: x + sz(4), y: centerY), to: CGPoint(x: end, y: centerY), color: Palette.line)
        }
    }
}

/// One SECTIONS nav item (`.sx-ni`, 41 px): glyph · title / subtitle · value; current = bg-lift,
/// 2 px amber bar, amber title with glow and `_`.
final class StatusNavItemView: HoverControl {
    static var height: CGFloat { sz(41) }

    let section: StatusSection
    var isCurrent = false { didSet { if isCurrent != oldValue { restyle(); needsDisplay = true } } }
    private let glyph = TextLine(style: TextStyle.mono(11, Palette.success))
    private let title = TextLine(style: TextStyle.caps(11, Palette.bone, tracking: 0.14, .medium))
    private let subtitle = TextLine(style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))
    private let value = TextLine(style: TextStyle.mono(10.5, Palette.dim))
    private var item: StatusNavItem?

    init(section: StatusSection) {
        self.section = section
        super.init(frame: .zero)
        glyph.alignCenter = true
        value.alignRight = true
        for view in [glyph, title, subtitle, value] {
            addSubview(view)
            // The item reads as one button with the combined label (D21).
            view.setAccessibilityElement(false)
        }
        steppedByArrows = true
        configure(StatusNavItem(id: section, glyph: .off, value: ""))
    }

    func configure(_ item: StatusNavItem) {
        self.item = item
        glyph.set(item.glyph.text, style: TextStyle.mono(11, item.glyph.color))
        subtitle.set(item.subtitle, style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.02))
        value.set(item.value, style: TextStyle.mono(10.5, item.valueColor ?? Palette.dim))
        restyle()
        setAccessibilityLabel("\(item.title) \(item.subtitle) \(item.value)")
        needsLayout = true
    }

    private func restyle() {
        guard let item else { return }
        if isCurrent {
            let style = TextStyle(font: Typeface.mono(11, .medium), color: Palette.amber, tracking: 0.14, uppercase: true,
                                  shadow: Draw.glow(Palette.amberGlow, radius: 6))
            // The artboard's blinking `_`; drawn static (lamps are the only animation, like the tab strip).
            title.set(runs: [(item.title, style), ("_", style)])
        } else {
            title.set(item.title, style: TextStyle.caps(11, Palette.bone, tracking: 0.14, .medium))
        }
        setAccessibilityValue(isCurrent ? "目前位置" : nil)
        setAccessibilitySelected(isCurrent)
    }

    override func layout() {
        super.layout()
        // `padding:4px 10px 4px 8px; border-left:2px; grid 14px 1fr auto; gap 8`.
        let left: CGFloat = sz(2) + sz(8)
        glyph.frame = CGRect(x: left, y: 0, width: sz(14), height: bounds.height)
        let valueWidth = min(value.textWidth, 90)
        value.frame = CGRect(x: bounds.width - sz(10) - valueWidth, y: 0, width: valueWidth, height: bounds.height)
        let textX = left + sz(14) + sz(8)
        let textWidth = max(0, value.frame.minX - sz(8) - textX)
        title.frame = CGRect(x: textX, y: sz(4), width: textWidth, height: sz(16.5))
        subtitle.frame = CGRect(x: textX, y: sz(4) + sz(16.5) + 1, width: textWidth, height: sz(15.5))
    }

    override func draw(_ dirtyRect: NSRect) {
        if isCurrent {
            Draw.fill(bounds, Palette.bgLift)
            Draw.fill(CGRect(x: 0, y: 0, width: sz(2), height: bounds.height), Palette.amber)
        } else if isHovered {
            Draw.fill(bounds, Palette.bgSoft)
            Draw.fill(CGRect(x: 0, y: 0, width: sz(2), height: bounds.height), Palette.lineBright)
        }
    }
}

/// The NEEDS YOU block (`.needs`): amber-edged box with its collapsible head and flat rows.
final class NeedsBlockView: FlippedView {
    private let header = SidebarSectionHeader()
    private let headerButton = HoverControl()
    private(set) var rows: [NeedsRowView] = []
    private(set) var isOpen = true
    var onOpen: ((String) -> Void)?
    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("需要你處理")
        addSubview(header)
        headerButton.onClick = { [weak self] in self?.toggle() }
        headerButton.setAccessibilityLabel("收合 NEEDS YOU")
        addSubview(headerButton)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var preferredHeight: CGFloat { 1 + 27 + (isOpen ? CGFloat(rows.count) * NeedsRowView.height : 0) + 1 }

    func configure(_ items: [StatusSessionRow], now: Date) {
        isHidden = items.isEmpty
        if rows.count != items.count {
            rows.forEach { $0.removeFromSuperview() }
            rows = items.map { _ in NeedsRowView() }
            for row in rows {
                row.onClick = { [weak self, weak row] in
                    guard let id = row?.sessionID else { return }
                    self?.onOpen?(id)
                }
                addSubview(row)
            }
        }
        for (row, item) in zip(rows, items) { row.configure(item, now: now) }
        configureHeader()
        needsLayout = true
    }

    private func configureHeader() {
        header.configure(title: "◆ Needs you", badge: rows.count, caretOpen: isOpen, color: Palette.amber)
        headerButton.setAccessibilityLabel(isOpen ? "收合 NEEDS YOU" : "展開 NEEDS YOU")
    }

    private func toggle() {
        isOpen.toggle()
        rows.forEach { $0.isHidden = !isOpen }
        configureHeader()
        onToggle?()
    }

    func tick(now: Date) {
        for row in rows where !row.isHidden { row.tick(now: now) }
    }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 1, y: 1, width: bounds.width - sz(2), height: sz(27))
        headerButton.frame = header.frame
        var y: CGFloat = sz(28)
        for row in rows {
            row.frame = CGRect(x: 1, y: y, width: bounds.width - sz(2), height: NeedsRowView.height)
            y += NeedsRowView.height
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // `linear-gradient(180deg, rgba(255,184,74,.05), transparent)` and a 28 % amber border.
        NSGradient(starting: Palette.amber.withAlphaComponent(0.05), ending: Palette.amber.withAlphaComponent(0))?
            .draw(in: bounds, angle: 90)
        Draw.strokeRect(bounds, color: Palette.amber.withAlphaComponent(0.28))
    }
}

/// One NEEDS YOU row (`.srow.flat`, 38 px like the session sidebar): lamp · tag · title · pill,
/// line 2 `3m · detail` with the duration in the state color.
final class NeedsRowView: HoverControl {
    static var height: CGFloat { sz(38) }

    private(set) var sessionID: String?
    private let lamp = LampGlyph()
    private let title = TextLine(style: TextStyle.mono(12.5, Palette.bone))
    private let pill = ChipLabel("", style: ChipStyle(text: TextStyle.caps(9.5, Palette.amber, tracking: 0.14)))
    private let line2 = TextLine(style: TextStyle.mono(10.5, Palette.dimmer))
    private var item: StatusSessionRow?
    private var tagColor: NSColor?
    private(set) var line2Text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [lamp, title, pill, line2] {
            addSubview(view)
            view.setAccessibilityElement(false)
        }
        steppedByArrows = true
    }

    func configure(_ item: StatusSessionRow, now: Date) {
        self.item = item
        sessionID = item.id
        tagColor = item.tag
        let waiting = item.attention == .waiting
        lamp.configure(item.glyph, size: waiting ? 12 : 11, glows: false, pulses: waiting)
        title.set(item.title, style: TextStyle.mono(12.5, item.attention == .other ? Palette.bone : Palette.cream))
        pill.set(item.pill, style: Self.pillStyle(item))
        setAccessibilityLabel("\(item.title) · \(item.pill)")
        renderLine2(now: now)
        needsLayout = true
        needsDisplay = true
    }

    private static func pillStyle(_ item: StatusSessionRow) -> ChipStyle {
        let color = item.glyph.color
        switch item.attention {
        case .waiting:
            return ChipStyle(text: TextStyle.caps(9.5, .black, tracking: 0.14, .bold), border: nil, fill: color, height: 15, padding: 5)
        case .error, .other:
            return ChipStyle(text: TextStyle.caps(9.5, color, tracking: 0.14, .medium), border: color, fill: nil, height: 15, padding: 5)
        }
    }

    func tick(now: Date) { renderLine2(now: now) }

    private func renderLine2(now: Date) {
        guard let item else { return }
        let duration = DurationFormat.compact(now.timeIntervalSince(item.since))
        let text = item.detail.isEmpty ? duration : "\(duration) · \(item.detail)"
        guard text != line2Text else { return }
        line2Text = text
        setAccessibilityValue(text)
        var runs: [(String, TextStyle)] = [(duration, TextStyle.mono(10.5, item.glyph.color))]
        if !item.detail.isEmpty {
            runs.append((" · ", TextStyle.mono(10.5, Palette.dimmer)))
            runs.append((item.detail, TextStyle.mono(10.5, Palette.dimmer)))
        }
        line2.set(runs: runs)
    }

    override func layout() {
        super.layout()
        // `.srow.flat{padding:4px 8px 4px 10px}` after the 2 px bar; lamp 12, gaps 7, tag 8.
        let lampX: CGFloat = sz(2) + sz(10)
        lamp.frame = CGRect(x: lampX, y: sz(6), width: sz(12), height: sz(16))
        let pillSize = pill.intrinsicContentSize
        pill.frame = CGRect(x: bounds.width - sz(8) - pillSize.width, y: sz(14) - sz(7.5), width: pillSize.width, height: sz(15))
        var x = lampX + sz(12) + sz(7)
        if tagColor != nil { x += sz(8) + sz(7) }
        title.frame = CGRect(x: x, y: sz(6), width: max(0, pill.frame.minX - sz(7) - x), height: sz(16))
        let l2x = lampX + sz(19)
        line2.frame = CGRect(x: l2x, y: sz(22), width: max(0, bounds.width - sz(8) - l2x), height: sz(14))
    }

    override func draw(_ dirtyRect: NSRect) {
        let bar = CGRect(x: 0, y: 0, width: sz(2), height: bounds.height)
        switch item?.attention {
        case .waiting:
            Draw.hGradient(bounds, from: Palette.amber.withAlphaComponent(isHovered ? 0.16 : 0.09),
                           to: Palette.amber.withAlphaComponent(isHovered ? 0.04 : 0.02))
            Draw.fill(bar, Palette.amber)
        case .error:
            Draw.hGradient(bounds, from: Palette.danger.withAlphaComponent(isHovered ? 0.14 : 0.08),
                           to: Palette.danger.withAlphaComponent(0.015))
            Draw.fill(bar, Palette.danger)
        default:
            if isHovered {
                Draw.fill(bounds, Palette.bgSoft)
                Draw.fill(bar, Palette.lineBright)
            }
        }
        if let tagColor {
            Draw.fill(CGRect(x: sz(2) + sz(10) + sz(12) + sz(7), y: sz(10), width: sz(8), height: sz(8)), tagColor)
        }
    }
}

/// One SESSIONS count (`.sx-cn`, 22 px): `◆ WAITING ……… 2`; a zero dims the label and count.
final class CountRowView: NSView, StatusTextShowing {
    private var count = StatusCount(glyph: .off, label: "", count: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var displayedText: String { "\(count.glyph.text) \(count.label) \(count.count)" }

    func configure(_ count: StatusCount) {
        guard count != self.count else { return }
        self.count = count
        setAccessibilityValue("\(count.label) \(count.count)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let zero = count.count == 0
        let mid = bounds.midY
        let glyph = TextStyle.mono(11, count.glyph.color).string(count.glyph.text)
        Draw.text(glyph, x: sz(10) + (sz(14) - Draw.width(glyph)) / 2, centerY: mid)
        Draw.text(TextStyle.mono(11, zero ? Palette.dimmer : Palette.bone).string(count.label), x: sz(10) + sz(14) + sz(8), centerY: mid)
        let n = TextStyle.mono(11, zero ? Palette.dimmer : Palette.cream).string("\(count.count)")
        Draw.text(n, x: bounds.width - sz(10) - Draw.width(n), centerY: mid)
    }
}

/// A text link row (`.sx-golive`: 11 px dim, amber on hover).
final class LinkRow: HoverControl {
    private let text: TextLine
    private let label: String
    private let size: CGFloat
    private let color: NSColor
    private let hoverColor: NSColor

    init(_ label: String, size: CGFloat = 11, color: NSColor = Palette.dim, hoverColor: NSColor = Palette.amber, underline: Bool = false) {
        self.label = label
        self.size = size
        self.color = color
        self.hoverColor = hoverColor
        text = TextLine(label, style: TextStyle.mono(size, color))
        super.init(frame: .zero)
        if underline { text.underline = color }
        addSubview(text)
        setAccessibilityLabel(label)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: text.textWidth, height: text.lineHeight) }

    override func hoverChanged() {
        let c = isHovered ? hoverColor : color
        text.set(label, style: TextStyle.mono(size, c))
        if text.underline != nil { text.underline = c }
    }

    override func layout() {
        super.layout()
        text.frame = bounds
    }
}
