import AppKit
import CoddUI

/// MCP SERVER: the section header and either the MCP card (`StatusPageModel.mcp`, M4) or, for a
/// caller without it, M3's placeholder card `// M4：筆記本與 MCP server 尚未提供` (D27). A model
/// equal to the last one changes nothing (per-section diffing like the other sections).
final class MCPSectionView: FlippedView {
    static let note = "// M4：筆記本與 MCP server 尚未提供"

    private let header = SectionHeaderRow(title: "MCP Server")
    private let placeholder = CardFrameView()
    private let comment = TextLine(MCPSectionView.note, style: TextStyle.comment)
    let card = MCPCardView()
    private(set) var model: StatusMCPModel?
    private var configured = false
    /// Configurations that changed something (tests: a client count change re-renders only this).
    private(set) var configureCount = 0
    var actions = StatusPageActions() { didSet { card.actions = actions } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        addSubview(placeholder)
        placeholder.addSubview(comment)
        addSubview(card)
        card.isHidden = true
        placeholder.setAccessibilityElement(true)
        placeholder.setAccessibilityRole(.group)
        placeholder.setAccessibilityLabel("MCP server")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MCP SERVER")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ model: StatusMCPModel?) {
        guard !configured || model != self.model else { return }
        configured = true
        configureCount += 1
        self.model = model
        placeholder.isHidden = model != nil
        card.isHidden = model == nil
        if let model { card.configure(model) }
        needsLayout = true
    }

    /// The placeholder is shown (no model).
    var showsPlaceholder: Bool { !placeholder.isHidden }

    func height(forWidth width: CGFloat) -> CGFloat {
        SectionHeaderRow.height + sz(10) + (model == nil ? sz(52) : card.preferredHeight(width: width))
    }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: SectionHeaderRow.height)
        let top = SectionHeaderRow.height + sz(10)
        placeholder.frame = CGRect(x: 0, y: top, width: bounds.width, height: sz(52))
        comment.frame = CGRect(x: sz(19), y: sz(17), width: bounds.width - sz(38), height: sz(18))
        card.frame = CGRect(x: 0, y: top, width: bounds.width, height: model == nil ? 0 : card.preferredHeight(width: bounds.width))
    }

    var visibleTexts: [String] { statusVisibleTexts() }
}

/// The `codd` card (`article.card`, Status artboard): head `CODD MCP · <notes>`, the run line
/// `● RUNNING 127.0.0.1:47821 · 3 clients … 只接受本機連線` (stopped: `○ STOPPED` dim and the
/// note), the client rows (`.sx-cl`), `REGISTRATIONS 註冊到其他 app` and its rows (`.sx-reg`), and
/// `TOKEN •••• client 連線時需附上 … [輪替]` (`.sx-tok`).
final class MCPCardView: CardFrameView {
    private let title = TextLine(runs: [])
    private let headRule = RuleLine(color: Palette.lineBright)
    // Run line (`.sx-run`: 12.5 bone, gap 8).
    let lamp = LampGlyph()
    private let runState = TextLine(style: TextStyle.caps(12.5, Palette.success, tracking: 0.14))
    private let endpoint = TextLine(style: TextStyle.mono(12.5, Palette.cream))
    private let runDot = TextLine("·", style: TextStyle.mono(12.5, Palette.dimmer))
    private let count = TextLine(style: TextStyle.mono(12.5, Palette.bone))
    private let localOnly = TextLine(StatusMCPModel.localOnlyHint, style: TextStyle.hint)
    private let note = TextBlock(style: TextStyle.comment, lineHeight: 1.5)
    // Clients (`.sx-cl`).
    private let clientsRule = RuleLine(color: Palette.line)
    private(set) var clientRows: [MCPClientRowView] = []
    private let noClients = TextLine(StatusMCPModel.noClients, style: TextStyle.comment)
    private let noClientsRule = RuleLine(color: Palette.line)
    // Registrations.
    private let regTitle = TextLine("Registrations", style: TextStyle.caps(10, Palette.dim, tracking: 0.18))
    private let regHint = TextLine(StatusMCPModel.registrationsHint, style: TextStyle.hint)
    private let regRule = RuleLine(color: Palette.lineBright)
    private(set) var registrationRows: [MCPRegistrationRowView] = []
    // Token (`.sx-tok`).
    private let tokenLabel = TextLine("Token", style: TextStyle.fieldLabel)
    private let token = ChipLabel("••••", style: StatusChips.code)
    private let tokenHint = TextLine(StatusMCPModel.tokenHint, style: TextStyle.hint)
    let rotateButton = CoddButton("輪替", style: .bracket(.normal, small: true))

    private var holder: ButtonAction?
    private(set) var model: StatusMCPModel?
    var actions = StatusPageActions() { didSet { for row in registrationRows { row.onAction = onRegistration } } }

    static var clientRowHeight: CGFloat { sz(27) }
    static var registrationRowHeight: CGFloat { sz(31) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        headRule.atTop = true
        clientsRule.atTop = true
        noClientsRule.atTop = true
        for view: NSView in [title, headRule, lamp, runState, endpoint, runDot, count, localOnly, note, clientsRule, noClients, noClientsRule,
                             regTitle, regHint, regRule, tokenLabel, token, tokenHint, rotateButton] {
            addSubview(view)
        }
        holder = rotateButton.onPress { [weak self] in self?.actions.onRotateMCPToken() }
        rotateButton.setAccessibilityLabel("輪替 MCP token")
        token.setAccessibilityLabel("MCP token（已遮蔽）")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MCP server codd")
    }

    private var onRegistration: (String) -> Void { { [weak self] id in self?.actions.onMCPRegistration(id) } }

    func configure(_ model: StatusMCPModel) {
        self.model = model
        title.set(attributed: TextRuns.joined([("codd", TextStyle.cardTitle, 8),
                                              ("MCP · \(model.notesPath.isEmpty ? "—" : model.notesPath)",
                                               TextStyle.mono(11.5, Palette.dimmer, tracking: 0.04), 0)]))
        if model.running {
            lamp.configure(.ok, size: 11, glows: true)
            runState.set("Running", style: TextStyle.caps(12.5, Palette.success, tracking: 0.14))
            endpoint.set(model.endpoint, style: TextStyle.mono(12.5, Palette.cream))
            count.set(StatusMCPModel.clientsText(model.clientsCount), style: TextStyle.mono(12.5, Palette.bone))
        } else {
            lamp.configure(.off, size: 11)
            runState.set("Stopped", style: TextStyle.caps(12.5, Palette.dim, tracking: 0.14))
            endpoint.set(model.endpoint, style: TextStyle.mono(12.5, Palette.dim))
        }
        endpoint.isHidden = model.endpoint.isEmpty
        runDot.isHidden = !model.running
        count.isHidden = !model.running
        localOnly.isHidden = !model.running
        note.isHidden = model.note == nil
        note.set(model.note ?? "")

        if clientRows.count != model.clients.count {
            clientRows.forEach { $0.removeFromSuperview() }
            clientRows = model.clients.map { _ in MCPClientRowView() }
            clientRows.forEach { addSubview($0) }
        }
        for (row, client) in zip(clientRows, model.clients) { row.configure(client) }
        // A stopped server with its note needs no `沒有 client 連線` under it.
        let showEmpty = model.clients.isEmpty && (model.running || model.note == nil)
        noClients.isHidden = !showEmpty
        noClientsRule.isHidden = !showEmpty

        if registrationRows.count != model.registrations.count {
            registrationRows.forEach { $0.removeFromSuperview() }
            registrationRows = model.registrations.map { _ in
                let row = MCPRegistrationRowView()
                row.onAction = onRegistration
                return row
            }
            registrationRows.forEach { addSubview($0) }
        }
        for (row, registration) in zip(registrationRows, model.registrations) { row.configure(registration) }
        let hasRegistrations = !model.registrations.isEmpty
        for view in [regTitle, regHint, regRule] as [NSView] { view.isHidden = !hasRegistrations }

        token.set(model.tokenMasked.isEmpty ? "—" : model.tokenMasked)
        rotateButton.isEnabled = model.canRotateToken
        setAccessibilityValue(model.running ? "執行中 \(model.endpoint) \(StatusMCPModel.clientsText(model.clientsCount))" : "未執行")
        needsLayout = true
    }

    // MARK: Layout

    func preferredHeight(width: CGFloat) -> CGFloat { arrange(width: width, apply: false) }

    @discardableResult
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        guard let model else { return 0 }
        // `.card{padding:16px 18px}`; `.card-h` 20 + 6 + its dashed rule, then 12.
        let x: CGFloat = sz(19)
        let inner = width - sz(38)
        if apply {
            title.frame = CGRect(x: x, y: sz(17), width: inner, height: sz(20))
            headRule.frame = CGRect(x: x, y: sz(17) + sz(26), width: inner, height: 1)
        }
        var y: CGFloat = sz(17) + sz(27) + sz(12)
        if apply {
            RowLayout.layout([RowItem(lamp, .fixed(12), height: 16), RowItem(runState), RowItem(endpoint, .shrink), RowItem(runDot),
                              RowItem(count), .flex(), RowItem(localOnly, .shrink)],
                             in: CGRect(x: x, y: y, width: inner, height: sz(19)), gap: 8)
        }
        y += sz(19)
        if !note.isHidden {
            y += sz(6)
            let h = note.height(forWidth: inner)
            if apply { note.frame = CGRect(x: x, y: y, width: inner, height: h) }
            y += h
        }
        // `.sx-cl{margin-top:8px; border-top:1px dashed var(--line)}`, 27 px rows.
        let listShown = !clientRows.isEmpty || !noClients.isHidden
        clientsRule.isHidden = !listShown
        if listShown {
            y += sz(8)
            if apply { clientsRule.frame = CGRect(x: x, y: y, width: inner, height: 1) }
            y += 1
            for row in clientRows {
                if apply { row.frame = CGRect(x: x, y: y, width: inner, height: Self.clientRowHeight + 1) }
                y += Self.clientRowHeight + 1
            }
            if !noClients.isHidden {
                if apply {
                    noClients.frame = CGRect(x: x, y: y + sz(4.5), width: inner, height: sz(18))
                    noClientsRule.frame = CGRect(x: x, y: y + Self.clientRowHeight, width: inner, height: 1)
                }
                y += Self.clientRowHeight + 1
            }
        }
        if !model.registrations.isEmpty {
            // `.sx-subh{margin-top:12px}` (17.3), then the 31 px rows.
            y += sz(12)
            if apply {
                RowLayout.layout([RowItem(regTitle), RowItem(regHint, .shrink), RowItem(regRule, .flex(min: 24), height: 1)],
                                 in: CGRect(x: x, y: y, width: inner, height: sz(17.3)), gap: 8)
            }
            y += sz(17.3)
            for row in registrationRows {
                if apply { row.frame = CGRect(x: x, y: y, width: inner, height: Self.registrationRowHeight + 1) }
                y += Self.registrationRowHeight + 1
            }
        }
        // `.sx-tok{margin-top:10px; gap:8px}`.
        y += sz(10)
        if apply {
            RowLayout.layout([RowItem(tokenLabel), RowItem(token), RowItem(tokenHint, .shrink), .flex(), RowItem(rotateButton)],
                             in: CGRect(x: x, y: y, width: inner, height: sz(22)), gap: 8)
        }
        y += sz(22)
        return y + sz(17)
    }

    override func layout() {
        super.layout()
        arrange(width: bounds.width, apply: true)
    }

    var visibleTexts: [String] { statusVisibleTexts() }
    var runText: String { [runState, endpoint, runDot, count, localOnly].filter { !$0.isHidden }.map(\.displayedText).joined(separator: " ") }
    var noteText: String? { note.isHidden ? nil : note.displayedText }
    var showsNoClients: Bool { !noClients.isHidden }
    var tokenText: String { token.displayedText }
}

/// One `.sx-cl li` (27 px + its dashed `--line` rule): `●` · title (≤ 150, truncated) · kind ·
/// `連線 42m` at the right.
final class MCPClientRowView: FlippedView {
    private let glyph = TextLine("●", style: TextStyle.mono(12, Palette.success))
    private let title = TextLine(style: TextStyle.mono(12, Palette.cream))
    private let kind = TextLine(style: TextStyle.hint)
    private let connected = TextLine(style: TextStyle.mono(12, Palette.dimmer))
    private let rule = RuleLine(color: Palette.line)
    private(set) var client: StatusMCPClient?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.atTop = true
        for view in [glyph, title, kind, connected, rule] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ client: StatusMCPClient) {
        guard client != self.client else { return }
        self.client = client
        title.set(client.title, style: TextStyle.mono(12, Palette.cream))
        kind.set(client.kind, style: TextStyle.hint)
        connected.set(client.connectedFor, style: TextStyle.mono(12, Palette.dimmer))
        setAccessibilityLabel("\(client.title) \(client.kind) \(client.connectedFor)")
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let titleWidth = min(title.textWidth, 150)
        RowLayout.layout([RowItem(glyph), RowItem(title, .fixed(titleWidth)), RowItem(kind, .shrink), .flex(), RowItem(connected)],
                         in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1), gap: 8)
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    var visibleTexts: [String] { statusVisibleTexts() }
}

/// One `.sx-reg li` (31 px + its dashed rule): name · hint … state (its tone) · chip · button.
final class MCPRegistrationRowView: FlippedView {
    private let name = TextLine(style: TextStyle.mono(12, Palette.cream))
    private let hint = TextLine(style: TextStyle.hint)
    private let state = TextLine(style: TextStyle.mono(12, Palette.dimmer))
    private let chip = ChipLabel("", style: .milestone)
    let button = CoddButton("", style: .bracket(.normal, small: true))
    private let rule = RuleLine(color: Palette.line)
    private var holder: ButtonAction?
    private(set) var registration: StatusMCPRegistration?
    var onAction: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rule.atTop = true
        for view: NSView in [name, hint, state, chip, button, rule] { addSubview(view) }
        holder = button.onPress { [weak self] in
            guard let self, let id = self.registration?.id else { return }
            self.onAction?(id)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ registration: StatusMCPRegistration) {
        guard registration != self.registration else { return }
        let restyle = registration.accent != self.registration?.accent
        self.registration = registration
        name.set(registration.name, style: TextStyle.mono(12, Palette.cream))
        hint.set(registration.hint, style: TextStyle.hint)
        state.set(registration.state, style: TextStyle.mono(12, registration.stateTone.color))
        chip.isHidden = registration.chip == nil
        chip.set(registration.chip ?? "", style: .milestone)
        if restyle { button.style = .bracket(registration.accent ? .accent : .normal, small: true) }
        button.isHidden = registration.actionTitle == nil
        button.label = registration.actionTitle ?? ""
        button.isEnabled = registration.isActionable
        button.toolTip = registration.toolTip
        button.setAccessibilityLabel(Self.accessibilityLabel(registration))
        setAccessibilityLabel("\(registration.name) \(registration.hint) \(registration.state)")
        needsLayout = true
    }

    /// `從 Claude Code 移除 MCP`, `註冊到 Codex`, `安裝 .mcpb 到 Claude Desktop`.
    static func accessibilityLabel(_ registration: StatusMCPRegistration) -> String {
        switch registration.actionTitle {
        case "移除": "從 \(registration.name) 移除 MCP"
        case "註冊": "註冊到 \(registration.name)"
        case let title?: "\(title) 到 \(registration.name)"
        case nil: registration.name
        }
    }

    override func layout() {
        super.layout()
        RowLayout.layout([RowItem(name), RowItem(hint, .shrink), .flex(), RowItem(state), RowItem(chip), RowItem(button)],
                         in: CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - 1), gap: 8)
        rule.frame = CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    var visibleTexts: [String] { statusVisibleTexts() }
}

/// REMOTE (`.sx-rm`): `◉ 1 個 session 已連 Remote Control（修正登入 API 401）` and
/// `切帳號後手機需登入同一帳號 … Remote & Mobile 設定 →`.
final class RemoteSectionView: FlippedView {
    private let header = SectionHeaderRow(title: "Remote")
    private let card = CardFrameView()
    private let glyph = TextLine(style: StatusStyles.body(Palette.cyan))
    private let line = TextLine(style: StatusStyles.body(Palette.cream))
    private let hint = TextLine("切帳號後手機需登入同一帳號", style: TextStyle.hint)
    let settingsLink = LinkRow("Remote & Mobile 設定 →", size: 13, color: Palette.amber, hoverColor: Palette.cream, underline: true)
    private(set) var model: RemoteModel?
    var onSettings: (() -> Void)? { didSet { settingsLink.onClick = onSettings } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(header)
        addSubview(card)
        for view in [glyph, line, hint, settingsLink] { card.addSubview(view) }
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Remote Control")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("REMOTE 遠端連線")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ model: RemoteModel) {
        guard model != self.model else { return }
        self.model = model
        let text = Self.text(model)
        glyph.set(model.count > 0 ? "◉" : "○", style: StatusStyles.body(model.count > 0 ? Palette.cyan : Palette.dimmer))
        line.set(text, style: StatusStyles.body(model.count > 0 ? Palette.cream : Palette.dim))
        needsLayout = true
    }

    /// `1 個 session 已連 Remote Control（修正登入 API 401）`; none: `沒有 session 連著 Remote Control`.
    static func text(_ model: RemoteModel) -> String {
        guard model.count > 0 else { return "沒有 session 連著 Remote Control" }
        let titles = model.titles.isEmpty ? "" : "（\(model.titles.joined(separator: "、"))）"
        return "\(model.count) 個 session 已連 Remote Control\(titles)"
    }

    func height(forWidth width: CGFloat) -> CGFloat { SectionHeaderRow.height + sz(10) + sz(77) }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: SectionHeaderRow.height)
        card.frame = CGRect(x: 0, y: SectionHeaderRow.height + sz(10), width: bounds.width, height: sz(77))
        // `.sx-rm{padding:14px 18px; gap:8px}`, lines 19.5.
        let x: CGFloat = sz(19)
        let inner = card.bounds.width - sz(38)
        RowLayout.layout([RowItem(glyph), RowItem(line, .shrink)], in: CGRect(x: x, y: sz(15), width: inner, height: sz(19.5)), gap: 8)
        RowLayout.layout([RowItem(hint, .shrink), .flex(), RowItem(settingsLink)], in: CGRect(x: x, y: sz(15) + sz(19.5) + sz(8), width: inner, height: sz(19.5)), gap: 8)
    }

    var visibleTexts: [String] { statusVisibleTexts() }
}
