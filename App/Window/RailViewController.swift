import AppKit
import CoddUI

/// Rail item (`.rail .ri`): 20 px icon, 9 px caps label, optional badge; `.on` = amber text,
/// amber glow gradient and a 2 px inset left bar.
///
/// M5 D21: VoiceOver hears one radio-like button per destination (`SESSIONS，3 個需要你`, selected
/// while its area shows); Full Keyboard Access reaches it, space / ⏎ press it and ↑ ↓ step to the
/// next destination. The destinations are also 顯示方式 › SESSIONS / NOTES / STATUS / SETTINGS.
final class RailItemButton: KeyFocusControl {
    let area: RailArea
    private let icon: Icon
    private let title: String
    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isOn ? 1 : 0)
        }
    }
    var badge: Int = 0 {
        didSet {
            guard badge != oldValue else { return }
            needsDisplay = true
            updateSpokenLabel()
        }
    }
    private var hovered = false
    private var trackingArea: NSTrackingArea?

    init(area: RailArea, icon: Icon, title: String) {
        self.area = area
        self.icon = icon
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(0)
        updateSpokenLabel()
    }

    /// `SESSIONS`, `SESSIONS，3 個需要你` (the badge is the attention count).
    static func spokenLabel(title: String, badge: Int) -> String {
        badge > 0 ? "\(title.uppercased())，\(badge) 個需要你" : title.uppercased()
    }

    private func updateSpokenLabel() { setAccessibilityLabel(Self.spokenLabel(title: title, badge: badge)) }

    override func handleArrow(_ key: KeyboardFocus.Key) -> Bool {
        switch key {
        case .up: AppKeyFocus.moveAmongSiblings(from: self, by: -1)
        case .down: AppKeyFocus.moveAmongSiblings(from: self, by: 1)
        default: false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: UIZoom.pt(60), height: UIZoom.pt(46)) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }
    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        let color = isOn ? Palette.amber : (hovered ? Palette.cream : Palette.dim)
        if isOn {
            Draw.hGradient(CGRect(x: 0, y: 0, width: bounds.width * 0.85, height: bounds.height), from: Palette.amberGlow,
                           to: Palette.amberGlow.withAlphaComponent(0))
            Draw.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), Palette.amber)
        }
        let z = UIZoom.pt
        let side = z(20)
        IconRenderer.draw(icon, in: CGRect(x: (bounds.width - side) / 2, y: z(7), width: side, height: side), color: color, flipped: true)
        let label = TextStyle.caps(9, color, tracking: 0.06).string(title)
        Draw.text(label, x: (bounds.width - Draw.width(label)) / 2, centerY: z(36))
        if badge > 0 {
            let badgeStyle = ChipStyle.badge
            let width = badgeStyle.size(for: "\(badge)").width
            badgeStyle.draw("\(badge)", x: bounds.width - z(6) - width, centerY: z(2) + badgeStyle.height / 2)
        }
    }
}

/// Rail account chip (`.rail .acct`): `#3 MAX` + two 3 px bars (5h / 1w remaining). Opens
/// Settings › 帳號 (also reachable from the keyboard, M5 D21).
final class RailAccountChip: KeyFocusControl {
    private var slot = ""
    private var plan = ""
    private var five = QuotaWindow.unknown
    private var week = QuotaWindow.unknown

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: UIZoom.pt(56), height: UIZoom.pt(32)) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func accessibilityPerformPress() -> Bool { sendAction(action, to: target) }

    /// The active account (nil: none known yet, the chip shows `—`).
    func update(_ account: AccountVM?) {
        let nextSlot = account?.slot ?? "—"
        // `MAX 20x` → `MAX` (the chip is 56 px wide).
        let nextPlan = account?.plan.map { $0.split(separator: " ").first.map(String.init) ?? $0 } ?? ""
        let nextFive = account?.fiveHour ?? .unknown
        let nextWeek = account?.week ?? .unknown
        guard nextSlot != slot || nextPlan != plan || nextFive != five || nextWeek != week else { return }
        slot = nextSlot
        plan = nextPlan
        five = nextFive
        week = nextWeek
        setAccessibilityLabel(account.map { "目前帳號 \($0.displayName)，5 小時剩 \(five.valueText)，本週剩 \(week.valueText)" } ?? "目前沒有帳號資料")
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) { sendAction(action, to: target) }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
        let z = UIZoom.pt
        Draw.text(TextStyle.mono(10, Palette.amber, .bold).string(slot), x: z(5), centerY: z(10))
        let planText = TextStyle.mono(10, Palette.dimmer).string(plan)
        Draw.text(planText, x: bounds.width - z(5) - Draw.width(planText), centerY: z(10))
        for (i, q) in [five, week].enumerated() {
            let bar = CGRect(x: z(5), y: z(19) + CGFloat(i) * z(6), width: bounds.width - z(10), height: z(3))
            Draw.fill(bar, Palette.lineBright)
            let fraction = q.known ? CGFloat(max(0, min(100, q.remainingPercent))) / 100 : 0
            Draw.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * fraction, height: bar.height), q.tone.color)
        }
    }
}

/// The 72 px rail: SESSIONS (attention badge) · NOTES · STATUS · SETTINGS, then `● MCP` and the
/// active account chip. Starts below the traffic lights (56 px).
final class RailViewController: NSViewController {
    private let store: any SessionStore
    private let accounts: any AccountStore
    private let shell: ShellState
    var onOpenSettings: (() -> Void)?
    /// The item of the area already shown was clicked (NOTES: back to the Notebook from Files).
    var onReselect: ((RailArea) -> Void)?
    private var items: [RailItemButton] = []
    private let mcp = Label.make(style: TextStyle.mono(9, Palette.dim))
    private let accountChip = RailAccountChip()
    private var loop: ObservationLoop?

    init(store: any SessionStore, accounts: any AccountStore, shell: ShellState) {
        self.store = store
        self.accounts = accounts
        self.shell = shell
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = WindowDragView(fill: Palette.bg, edges: [.right], edgeColor: Palette.line)
        items = [
            RailItemButton(area: .sessions, icon: .sessions, title: "Sessions"),
            RailItemButton(area: .notes, icon: .notes, title: "Notes"),
            RailItemButton(area: .status, icon: .status, title: "Status"),
            RailItemButton(area: .settings, icon: .settings, title: "Settings"),
        ]
        for item in items {
            item.target = self
            item.action = #selector(pick(_:))
        }
        accountChip.target = self
        accountChip.action = #selector(openAccounts)
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        filler.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let stack = vStack(items + [filler, mcp, accountChip], spacing: 4, alignment: .centerX,
                           edgeInsets: NSEdgeInsets(top: 56, left: 6, bottom: 10, right: 6))
        stack.setCustomSpacing(8, after: mcp)
        root.addSubview(stack)
        stack.pinEdges(to: root)
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loop = ObservationLoop { [weak self] in self?.render() }
    }

    private func render() {
        let attention = store.allSessions.filter { $0.state.needsAttention }.count
        for item in items {
            item.isOn = item.area == shell.area
            item.badge = item.area == .sessions ? attention : 0
        }
        let host = store.host
        let line = NSMutableAttributedString(attributedString: TextStyle.mono(8, host.mcpRunning ? Palette.success : Palette.dimmer).string("● "))
        line.append(TextStyle.mono(9, Palette.dim, tracking: 0.08).string("MCP"))
        mcp.attributedStringValue = line
        mcp.setAccessibilityLabel("MCP server \(host.mcpRunning ? "執行中" : "未啟動")，\(host.mcpClients) 個 client")
        accountChip.update(accounts.activeAccount)
    }

    @objc private func pick(_ sender: RailItemButton) {
        if sender.area == .settings {
            onOpenSettings?()
        } else if sender.area == shell.area {
            onReselect?(sender.area)
        } else {
            shell.area = sender.area
        }
    }

    @objc private func openAccounts() { onOpenSettings?() }
}
