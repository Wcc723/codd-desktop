import AppKit
import CoddUI

/// Session row (`.srow`, 38 px): lamp · 8 px tag · title · [#2] [EXT] · state pill, and line 2
/// (reason/tool · duration · uptime · badges). Tree rows are indented; NEEDS YOU / PINNED rows are
/// flat and show `group / project` instead of the uptime; STATE rows are flat and show
/// `<lead> · ■ <project>` with the group's color square (SidebarStates E).
final class SessionCellView: SidebarCellView, SecondTicking {
    static let identifier = NSUserInterfaceItemIdentifier("session")

    private let lamp = LampView()
    /// Line 2 has its own (small) layer: the 1 Hz tick repaints only this strip, never the
    /// row (title, pills and block background are drawn into the row's layer).
    private let line2View = SessionLine2View()

    // Snapshot of what we draw (filled in refresh(), read in draw()).
    private var flat = false
    private var style = StateStyle.of(.idle)
    private var state = SessionState.idle
    private var title = ""
    private var tagColor: TagColor?
    private var pill = ""
    private var accountChip: String?
    private var external = false
    private var stale = false
    private var titleColor = Palette.bone
    /// Line 2 without the clock (rendered once a second while visible).
    private var line2Parts = SessionLine2Parts()
    /// D8: the live holder does not answer (pill `Unreach`, line 2 `holder 無回應 · 30s`).
    private var unreachable = false
    private var renaming = false
    private var line2Cache = SessionLine2()
    /// The session the row speaks for (VoiceOver reads it when asked, with the current duration).
    private weak var spokenSession: SessionVM?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.identifier
        addSubview(lamp)
        addSubview(line2View)
    }

    var sessionID: SessionID? { node?.sessionID }

    /// `修正登入 API 401，等待中 · 權限 · 3 分鐘，標籤：紅，Remote Control 已連線` (M5 D21): the
    /// lamp, the pill and the badges are glyphs and colors, so the row says them.
    override var spokenLabel: String? {
        guard let session = spokenSession, let env else { return nil }
        return SessionSpeech.row(session, accountChip: accountChip, now: env.store.clock.now())
    }

    /// Title rect (for the inline rename field). Offsets are design points (M4 interface zoom).
    var titleFrame: CGRect {
        let z = UIZoom.pt
        let x = lampX + z(12 + 7) + (tagColor == nil ? 0 : z(15))
        return CGRect(x: x - z(3), y: z(4), width: max(z(40), contentRight - z(8) - x - z(40)), height: z(20))
    }

    /// What line 2 shows right now (tests).
    var line2ForTesting: SessionLine2 { line2Cache }

    func setRenaming(_ value: Bool) {
        renaming = value
        needsDisplay = true
    }

    private var lampX: CGFloat { contentLeft + UIZoom.pt(2 + (flat ? 10 : 24)) }

    // MARK: Model

    override func refresh() {
        guard case .session(let id, let context)? = node, let env, let session = env.store.session(id) else { return }
        flat = context.isFlat
        state = session.state
        unreachable = session.unreachableSince != nil
        style = StateStyle.of(session)
        title = session.title
        tagColor = session.tag
        external = session.external
        stale = session.isStale
        let isCurrent = env.shell.currentSessionID == id

        if unreachable {
            pill = style.pill
        } else if flat, state == .waiting, let reason = session.waitingReason {
            pill = reason.shortPill
        } else {
            pill = style.pill
        }
        if session.accountPinned, let account = session.accountID, account != env.accounts.activeAccountID {
            accountChip = env.accounts.account(account)?.slot
        } else {
            accountChip = nil
        }
        titleColor = (state == .exited || state == .stopped) ? Palette.dimmer : ((isCurrent || state == .waiting) ? Palette.cream : Palette.bone)
        spokenSession = session
        line2Parts = SessionLine2Parts(session: session, context: context, store: env.store)

        var deco = RowDecoration(block: blockStyle(for: .session(id, context)), hover: .session)
        switch state {
        case .waiting: deco.emphasis = isCurrent ? .waitingCurrent : .waiting
        case .error: deco.emphasis = .error
        default: deco.emphasis = isCurrent ? .current : .none
        }
        decoration = deco
        lamp.configure(style)
        lamp.alphaValue = stale ? 0.75 : 1
        line2Cache = line2Parts.render(now: env.store.clock.now())
        pushLine2()
        updateTicking()
    }

    private func pushLine2() {
        line2View.update(line2Cache, leadColor: line2Cache.leadDim ? Palette.dim : style.color)
        line2View.alphaValue = stale ? 0.75 : 1
    }

    // MARK: Ticking (1 Hz, visible rows only)

    private var ticking = false

    private func updateTicking() {
        let want = window != nil && line2Parts.ticks
        if want, !ticking { ticking = true; UITicker.shared.addSecond(self) }
        if !want, ticking { ticking = false; UITicker.shared.removeSecond(self) }
    }

    func secondTick(now: Date) {
        let line = line2Parts.render(now: now)
        if line != line2Cache {
            line2Cache = line
            pushLine2()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTicking()
    }

    // MARK: Layout + drawing

    override func layout() {
        super.layout()
        let z = UIZoom.pt
        lamp.frame = CGRect(x: lampX, y: z(6), width: z(12), height: z(16))
        let x = lampX + z(19)
        line2View.frame = CGRect(x: x, y: z(22), width: max(0, contentRight - z(8) - x), height: z(14))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard node != nil else { return }
        NSGraphicsContext.current?.cgContext.setAlpha(stale ? 0.75 : 1)
        let z = UIZoom.pt
        let l1 = z(14)
        let right = contentRight - z(8)

        if !flat, isHovered {
            Draw.text(TextStyle.mono(10, Palette.dimmer.withAlphaComponent(0.7)).string("⠿"), x: contentLeft + z(2 + 6), centerY: bounds.midY)
        }

        // Right side, right to left: pill, EXT, account chip.
        var x = right
        let pillStyle = ChipStyle.statePill(style)
        let pillWidth = pillStyle.size(for: pill).width
        x -= pillWidth
        pillStyle.draw(pill, x: x, centerY: l1)
        if external {
            let ext = ChipStyle.ext
            x -= ext.size(for: "EXT").width + z(7)
            ext.draw("EXT", x: x, centerY: l1)
        }
        if let accountChip {
            let chip = ChipStyle.smallChip(Palette.cyan, border: Palette.cyan.withAlphaComponent(0.4))
            x -= chip.size(for: accountChip).width + z(7)
            chip.draw(accountChip, x: x, centerY: l1)
        }

        var left = lampX + z(12 + 7)
        if let tag = tagColor {
            let side = z(8)
            Draw.fill(CGRect(x: left, y: l1 - side / 2, width: side, height: side), tag.color)
            left += side + z(7)
        }
        if !renaming {
            Draw.text(TextStyle.mono(12.5, titleColor).string(title), x: left, centerY: l1, maxWidth: x - z(7) - left)
        }
    }
}

/// Line 2 of a session row, rendered for one moment: the leading "reason · duration" run in the
/// state color (`.l2 .dur`), then the rest; STATE rows put the group's 8 px square before the rest.
struct SessionLine2: Equatable, Sendable {
    var lead = ""
    var rest = ""
    var square: TagColor?
    /// Idle and shell rows draw the lead in `--dim` instead of the state color.
    var leadDim = false

    /// The text as drawn, the square written as `■` (state dump, tests).
    var text: String {
        let tail = rest.isEmpty ? "" : (square == nil ? rest : "■ " + rest)
        return [lead, tail].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// What line 2 of a session row says, without the clock. Built from the model (inside the cell's
/// observation tracking, and by the `sidebar` state dump); `render(now:)` adds the durations.
struct SessionLine2Parts: Equatable, Sendable {
    enum Layout: Equatable, Sendable {
        /// Tree row: `perm · 3m · up 42m · ◉ rc`.
        case tree
        /// NEEDS YOU / PINNED in tree mode: `3m · 藍鵲·網站 / backend`.
        case flatWhere
        /// STATE view: `Edit · 6m · ■ orb-toolkit-frontend`.
        case stateList
    }

    var layout = Layout.tree
    var state = SessionState.idle
    var prefix = ""
    var showsDuration = true
    var since = Date.distantPast
    var startedAt: Date?
    /// Tree rows: `stale`, `外部啟動` / `在 CODD shell 中`, `◉ rc`.
    var suffix: [String] = []
    /// Flat tree rows: `group / project`.
    var location = ""
    /// STATE rows: the project's name and its group's color.
    var project = ""
    var square: TagColor?
    var leadDim = false
    var unreachable = false
    var external = false
    var stale = false

    init() {}

    @MainActor
    init(session s: SessionVM, context: SessionContext, store: any SessionStore) {
        switch context {
        case .tree: layout = .tree
        case .needs, .pinned: layout = .flatWhere
        case .stateList: layout = .stateList
        }
        state = s.state
        unreachable = s.unreachableSince != nil
        external = s.external
        stale = s.isStale
        since = s.unreachableSince ?? s.stateSince
        startedAt = s.startedAt
        switch s.state {
        case .waiting: prefix = s.waitingReason?.rowPrefix ?? ""
        case .error: prefix = (s.errorReason ?? "error").lowercased()
        case .busy: prefix = s.tool ?? ""
        case .shell: prefix = s.detail ?? "zsh"; showsDuration = false
        case .exited: prefix = "code \(s.exitCode ?? 0)"
        case .stopped: prefix = "可接續"
        // An external without a registry status has no hooks to miss.
        case .unknown: prefix = s.external ? "" : "! no hook"; showsDuration = s.external
        default: break
        }
        if unreachable {
            prefix = "holder 無回應"
            showsDuration = true
        }
        leadDim = !unreachable && (s.state == .idle || s.state == .shell)
        let projectVM = store.project(s.projectID)
        let group = projectVM.flatMap { store.group($0.groupID) }
        switch layout {
        case .tree:
            if s.isStale {
                suffix = ["stale"]
            } else if let info = s.externalInfo {
                // `外部啟動`, `外部啟動 · bg` (a background worker) or `在 CODD shell 中` (D6).
                suffix = [info.rowLabel]
            }
            if s.remoteControl { suffix.append("◉ rc") }
        case .flatWhere:
            location = [group?.shortName, projectVM?.name].compactMap { $0 }.joined(separator: " / ")
        case .stateList:
            project = projectVM?.name ?? ""
            square = (group?.isUngrouped ?? true) ? nil : group?.color
        }
    }

    /// Whether the text changes with the clock (the cell subscribes to the 1 Hz tick).
    var ticks: Bool { showsDuration || startedAt != nil }

    func render(now: Date) -> SessionLine2 {
        let duration = DurationFormat.compact(now.timeIntervalSince(since))
        let uptime = startedAt.map { "up \(DurationFormat.compact(now.timeIntervalSince($0)))" }
        var lead: [String]
        var rest: [String]
        switch layout {
        case .tree:
            lead = [prefix, showsDuration ? duration : ""]
            rest = suffix
            if rest.isEmpty || rest == ["◉ rc"], let uptime, state.isLive, !external, !stale, !unreachable {
                rest.insert(uptime, at: 0)
            }
        case .flatWhere:
            // NEEDS YOU: duration first; errors keep their reason before the location.
            if state.needsAttention, !unreachable {
                lead = [duration]
                rest = (state == .error ? [prefix] : []) + [location]
            } else {
                lead = [prefix, showsDuration ? duration : ""]
                rest = [location]
            }
        case .stateList:
            if unreachable {
                lead = [prefix, duration]
            } else if state == .waiting {
                // The pill already says Perm / Ask / Plan.
                lead = [duration]
            } else if state == .shell {
                lead = [prefix, state.isLive ? (uptime ?? "") : ""]
            } else if state == .exited || state == .stopped {
                lead = [prefix, duration + " 前"]
            } else {
                lead = [prefix, showsDuration ? duration : ""]
            }
            rest = [project]
        }
        let leadText = lead.filter { !$0.isEmpty }.joined(separator: " · ")
        let restText = rest.filter { !$0.isEmpty }.joined(separator: " · ")
        return SessionLine2(lead: leadText, rest: restText, square: layout == .stateList && !restText.isEmpty ? square : nil,
                            leadDim: leadDim)
    }
}

/// Line 2 of a session row (`.l2`): `perm · 3m · up 42m · ◉ rc`, the leading
/// "reason · duration" run in the state color (`.l2 .dur`). Its own layer, so a duration that
/// changes every second repaints ~250×14 pt instead of the whole row. Transparent to clicks.
final class SessionLine2View: NSView {
    private var line = SessionLine2()
    private var leadColor = Palette.dimmer

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The drawn text (tests).
    var displayedText: String { line.text }

    func update(_ line: SessionLine2, leadColor: NSColor) {
        guard line != self.line || leadColor != self.leadColor else { return }
        self.line = line
        self.leadColor = leadColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = TextStyle.mono(10.5, Palette.dimmer)
        let gap = UIZoom.pt(6)
        let side = UIZoom.pt(8)
        var x: CGFloat = 0
        let maxX = bounds.width
        if !line.lead.isEmpty {
            // A long lead (a shell's title is often a path) gives way so the rest (the STATE row's
            // project) keeps at least half the line.
            var leadMax = maxX
            if !line.rest.isEmpty {
                let restWidth = Draw.width(style.string(line.rest)) + gap + Draw.width(style.string("·")) + gap
                    + (line.square == nil ? 0 : side + gap)
                leadMax = max(maxX * 0.5, maxX - restWidth)
            }
            x += Draw.text(style.with(color: leadColor).string(line.lead), x: x, centerY: bounds.midY, maxWidth: leadMax)
        }
        guard !line.rest.isEmpty, x < maxX else { return }
        if !line.lead.isEmpty {
            // `.l2{gap:6px}` around the `·`.
            x += gap
            x += Draw.text(style.string("·"), x: x, centerY: bounds.midY, maxWidth: maxX - x) + gap
        }
        if let square = line.square, x + side < maxX {
            Draw.fill(CGRect(x: x, y: round(bounds.midY - side / 2), width: side, height: side), square.color)
            x += side + gap
        }
        if x < maxX {
            Draw.text(style.string(line.rest), x: x, centerY: bounds.midY, maxWidth: maxX - x)
        }
    }
}
