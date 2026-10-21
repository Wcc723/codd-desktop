import AppKit
import CoddPreferences
import CoddUI

/// 08 NOTEBOOK & MCP 筆記本 (M4, D33): every row live. 位置 offers only LOCAL (`iCloud Drive` /
/// `自訂…` are `M5` segments), the MCP group shows the server from `SettingsInfo.notebook` (the hook
/// server's port read-only, the masked token, `輪替`, the 註冊 rows), the switches and the default
/// AI access edit their preferences.
final class NotebookSectionView: SettingsSectionView {
    private(set) var openFolderButton: CoddButton?
    private(set) var mcpHead: SxGroupHead?
    private(set) var portBox: SxValueBox?
    private(set) var tokenChip: ChipView?
    /// The token chip's text as drawn (tests).
    private(set) var tokenText = ""
    private(set) var rotateButton: CoddButton?
    private(set) var registrationsBox: RegistrationsBox?

    /// `<notesPath> · 每則筆記是一個 .md 檔` (`—` before the app knows the folder).
    static func locationHint(_ path: String) -> String { "\(path.isEmpty ? "—" : path) · 每則筆記是一個 .md 檔" }

    /// The MCP group head's right text: `● 執行中 · 3 clients` / `○ 未執行`.
    static func mcpHeadText(_ notebook: SettingsNotebookInfo) -> NSAttributedString {
        let style = SxGroupHead.rightStyle
        let text = NSMutableAttributedString()
        if notebook.mcpRunning {
            text.append(style.with(color: Palette.success).string("●"))
            text.append(style.string(" 執行中 · \(notebook.mcpClients) clients"))
        } else {
            text.append(style.string("○ 未執行"))
        }
        return text
    }

    override func build() {
        let open = button("開啟筆記本資料夾", accessibilityLabel: "在 Finder 開啟筆記本資料夾") { [weak self] in self?.actions.openNotesFolder() }
        registerControl("notebook.openFolder", open)
        openFolderButton = open
        bind { [weak open] _, info in open?.isEnabled = info.notebook.canOpenFolder }
        add(pageHead(lead: SxRich("筆記存在哪裡、MCP server 怎麼連，以及 AI 可以碰到多少。"), actions: [open]))

        let locationTitles = ["Local", "iCloud Drive", "自訂…"]
        let location = row("notebook.location", "位置", en: "Location", hint: Self.locationHint(""),
                           controls: [segmented("notebook.location", titles: locationTitles,
                                                values: [CoddPreferences.NotebookLocation.local, .iCloud, .custom], label: "筆記本位置",
                                                disabled: [1, 2], chips: [1: "M5", 2: "M5"],
                                                get: { $0.notebook.location }, set: { $0.notebook.location = $1 })],
                           keywords: locationTitles + ["M5"])
        bind { [weak location] _, info in location?.setHint(SxRich(Self.locationHint(info.notebook.notesPath))) }
        let resize = row("notebook.resizeImages", "圖片長邊壓到 2576px", en: "Resize images", hint: "貼上或拖入的截圖先縮小，再存進 assets/。",
                         controls: [toggle("notebook.resizeImages", label: "圖片長邊壓到 2576px", get: { $0.notebook.resizeImages },
                                           set: { $0.notebook.resizeImages = $1 })])
        let keep = row("notebook.keepOriginal", "保留原檔", en: "Keep original", hint: "另外保留未壓縮的原始圖片，比較佔空間。",
                       controls: [toggle("notebook.keepOriginal", label: "保留原始圖片", get: { $0.notebook.keepOriginal },
                                         set: { $0.notebook.keepOriginal = $1 })])
        add(sxGroup(groupHead("Storage", cjk: "儲存"), [SxCard([location, resize, keep])]))

        // The port is the hook server's (MCP shares it, D33): read-only text in the input look.
        let port = SxValueBox(value: "—", width: 80, alignment: .right, accessibilityLabel: "MCP port")
        registerControl("notebook.port", port)
        portBox = port
        let token = ChipView("—", style: ChipStyle(text: TextStyle.mono(12, Palette.amber), border: Palette.line, fill: Palette.bg,
                                                  height: 24, padding: 8))
        token.setAccessibilityLabel("MCP token（已遮蔽）")
        registerControl("notebook.token", token)
        tokenChip = token
        let rotate = button("輪替", accessibilityLabel: "輪替 MCP token") { [weak self] in self?.actions.rotateMCPToken() }
        registerControl("notebook.rotateToken", rotate)
        rotateButton = rotate
        bind { [weak self, weak port, weak token, weak rotate] _, info in
            port?.set(info.notebook.port.map { "\($0)" } ?? "—")
            let masked = info.notebook.tokenMasked.isEmpty ? "—" : info.notebook.tokenMasked
            self?.tokenText = masked
            token?.set(masked)
            rotate?.isEnabled = info.notebook.canRotateToken
        }
        let portRow = row("notebook.mcpPort", "Port 與 token", en: "127.0.0.1", hint: "只聽 127.0.0.1；輪替 token 後，已註冊的 client 需要重新註冊。",
                          controls: [port, token, rotate], keywords: ["MCP", "token", "輪替", "port"])

        let box = RegistrationsBox()
        box.onAction = { [weak self] id in self?.actions.mcpRegistration(id) }
        registerControl("notebook.registrations", box)
        registrationsBox = box
        bind { [weak box] _, info in box?.configure(info.notebook.registrations) }
        let registrations = row("notebook.registrations", "註冊", en: "Registrations", hint: "讓其他 agent 也能讀寫 CODD 筆記。",
                                controls: [box], keywords: ["Claude Code", "Codex", "Claude Desktop", "移除", "安裝 .mcpb", "MCP"])
        let attach = row("notebook.autoAttachMCP", "自動掛載 MCP", en: "Auto-attach", hint: "CODD 啟動的 session 自動帶上 codd MCP，並展開 codd:// 引用。",
                         controls: [toggle("notebook.autoAttachMCP", label: "CODD 啟動的 session 自動掛載 MCP 並展開 codd 引用",
                                           get: { $0.notebook.autoAttachMCP }, set: { $0.notebook.autoAttachMCP = $1 })])
        let head = groupHead("MCP server", cjk: "codd")
        mcpHead = head
        bind { [weak head] _, info in
            guard let head else { return }
            let text = Self.mcpHeadText(info.notebook)
            if head.right?.isEqual(to: text) != true { head.right = text }
        }
        add(sxGroup(head, [SxCard([portRow, registrations, attach])]))

        let accessTitles = ["Off", "Read", "Append"]
        let access = row("notebook.defaultAIAccess", "新筆記預設 AI 存取", en: "Default AI access", hint: "每則筆記可在編輯器上方個別調整。",
                         controls: [segmented("notebook.defaultAIAccess", titles: accessTitles,
                                              values: [CoddPreferences.AIAccess.off, .read, .append], label: "新筆記預設 AI 存取",
                                              get: { $0.notebook.defaultAIAccess }, set: { $0.notebook.defaultAIAccess = $1 })],
                         keywords: accessTitles)
        let write = row("notebook.aiCanWrite", "AI 可寫入", en: "AI can write", hint: "允許 AI 透過 MCP 改寫既有筆記；關閉時最多只能附加。",
                        controls: [toggle("notebook.aiCanWrite", label: "AI 可寫入筆記", get: { $0.notebook.aiCanWrite },
                                          set: { $0.notebook.aiCanWrite = $1 })])
        add(sxGroup(groupHead("AI access", cjk: "AI 存取"), [SxCard([access, write])]))
    }

    /// The notes folder and the registration states are found by the search too.
    override var factSearchText: String {
        let notebook = model.info.notebook
        return ([notebook.notesPath] + notebook.registrations.flatMap { [$0.name, $0.hint] }).joined(separator: " ")
    }

    var mcpHeadRightText: String { mcpHead?.right?.string ?? "" }
}

/// `.sx-regs`: 440 wide, one 34 pt row per app (glyph, name in a 120 column, hint, then the chip
/// and the button at the right). Built from `SettingsNotebookInfo.registrations`; without them
/// the three apps of the artboard read `—` and offer no button (a caller before M4).
final class RegistrationsBox: FlippedView {
    static var rowHeight: CGFloat { xz(34) }

    /// The neutral rows shown while the app sends none.
    static let placeholder: [SettingsMCPRegistration] = [
        SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: "—"),
        SettingsMCPRegistration(id: "codex", name: "Codex", hint: "—"),
        SettingsMCPRegistration(id: "claude-desktop", name: "Claude Desktop", hint: "—"),
    ]

    private(set) var registrations: [SettingsMCPRegistration] = []
    /// What is drawn: the registrations, or the placeholder rows.
    var shownRows: [SettingsMCPRegistration] { registrations.isEmpty ? Self.placeholder : registrations }
    /// A row's button was pressed (its registration id).
    var onAction: ((String) -> Void)?
    /// Inside a disabled row (D17): names and buttons in the disabled colors, nothing pressable.
    var isDisabledLook = false {
        didSet {
            guard isDisabledLook != oldValue else { return }
            rebuild()
        }
    }

    /// The buttons and chips of the current rows, by registration id (tests).
    private(set) var buttonsByID: [String: CoddButton] = [:]
    private(set) var chipsByID: [String: ChipView] = [:]
    private var targets: [ClosureTarget] = []
    private var heightConstraint: NSLayoutConstraint?

    var buttons: [CoddButton] { shownRows.compactMap { buttonsByID[$0.id] } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        translatesAutoresizingMaskIntoConstraints = false
        // 440 wide where the row has room; a narrow row (small window, zoom 20) narrows it down to
        // 260 (the hints end in `…`) instead of holding the Settings window wide.
        let preferred = widthAnchor.constraint(equalToConstant: 440).zoomed(440)
        preferred.priority = NSLayoutConstraint.Priority(480)
        preferred.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 260).zoomed(260).isActive = true
        let height = heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
        heightConstraint = height
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("MCP 註冊")
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// New rows from the facts; nothing is rebuilt when they did not change.
    func configure(_ registrations: [SettingsMCPRegistration]) {
        guard registrations != self.registrations else { return }
        self.registrations = registrations
        rebuild()
    }

    private func rebuild() {
        for view in subviews { view.removeFromSuperview() }
        buttonsByID = [:]
        chipsByID = [:]
        targets = []
        let rows = shownRows
        heightConstraint?.constant = CGFloat(rows.count) * Self.rowHeight + 1
        for row in rows {
            if let chip = row.chip {
                let view = ChipView(chip, style: .milestone)
                addSubview(view)
                chipsByID[row.id] = view
            }
            guard let title = row.actionTitle else { continue }
            let button = CoddButton(title, style: .bracket(row.accent ? .accent : .normal, small: true))
            button.setAccessibilityLabel(Self.accessibilityLabel(title: title, name: row.name))
            button.toolTip = row.toolTip
            button.isEnabled = row.isActionable && !isDisabledLook
            let id = row.id
            let target = ClosureTarget { [weak self] in self?.onAction?(id) }
            targets.append(target)
            button.target = target
            button.action = #selector(ClosureTarget.fire(_:))
            addSubview(button)
            buttonsByID[row.id] = button
        }
        setAccessibilityValue(rows.map { "\($0.name) \($0.hint)" }.joined(separator: "，"))
        needsLayout = true
        needsDisplay = true
    }

    /// The artboard's labels: `從 Claude Code 移除 MCP`, `註冊到 Codex`.
    static func accessibilityLabel(title: String, name: String) -> String {
        switch title {
        case "移除": "從 \(name) 移除 MCP"
        case "註冊": "註冊到 \(name)"
        default: "\(title) \(name)"
        }
    }

    override func layout() {
        super.layout()
        for (index, row) in shownRows.enumerated() {
            let mid = CGFloat(index) * Self.rowHeight + xz(17.5)
            var right = bounds.width - xz(6)
            if let button = buttonsByID[row.id] {
                let size = button.intrinsicContentSize
                button.frame = CGRect(x: right - size.width, y: round(mid - size.height / 2), width: size.width, height: size.height)
                right = button.frame.minX - 8
            }
            if let chip = chipsByID[row.id] {
                let size = chip.intrinsicContentSize
                chip.frame = CGRect(x: right - size.width, y: round(mid - size.height / 2), width: size.width, height: size.height)
            }
        }
        needsDisplay = true
    }

    /// Where the hint column ends for row `row` (before its chip / button).
    private func hintEnd(_ row: SettingsMCPRegistration) -> CGFloat {
        let leftmost = [chipsByID[row.id], buttonsByID[row.id]].compactMap { $0?.frame.minX }.min()
        return (leftmost ?? bounds.width - xz(6)) - xz(10)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        for (index, row) in shownRows.enumerated() {
            let y = CGFloat(index) * Self.rowHeight
            if index > 0 { Draw.dashedLine(from: CGPoint(x: 0, y: y), to: CGPoint(x: bounds.width, y: y), color: Palette.lineBright) }
            let mid = y + xz(17.5)
            let glyph = row.isOn ? TextStyle.mono(12, Palette.success).string("●") : TextStyle.mono(12, Palette.dimmer).string("○")
            Draw.text(glyph, x: xz(10), centerY: mid)
            Draw.text(TextStyle.mono(12, isDisabledLook ? Palette.dim : Palette.cream).string(row.name), x: xz(10) + xz(14) + xz(10), centerY: mid,
                      maxWidth: xz(120))
            let hintX: CGFloat = xz(10) + xz(14) + xz(10) + xz(120) + xz(10)
            Draw.text(SxStyle.hint.string(row.hint), x: hintX, centerY: mid, maxWidth: max(0, hintEnd(row) - hintX))
        }
        Draw.strokeRect(bounds, color: Palette.line)
    }
}
