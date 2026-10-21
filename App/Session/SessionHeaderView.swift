import AppKit
import CoddUI

/// Everything the 52 px session header draws (computed by the pane from the session).
struct SessionHeaderModel: Equatable {
    var style: StateStyleKey
    var title: String
    var tag: TagColor?
    /// `◆ WAITING · PERMISSION · 3m` (duration filled in at draw time).
    var chipParts: [String]
    var chipShowsDuration: Bool
    var stateSince: Date
    var external: Bool
    var cwd: String
    /// Meta items after the cwd: (text, isDanger).
    var meta: [MetaItem]
    var startedAt: Date?
    var account: String?
    var accountPinned: Bool
    var remoteControl: Bool
    var notes: Int

    struct MetaItem: Equatable {
        var text: String
        var danger = false
    }
}

/// `StateStyle` is not Equatable (it holds colors); the header compares states instead.
struct StateStyleKey: Equatable {
    var state: SessionState
    /// D8 overlay: drawn as UNREACHABLE whatever the state.
    var unreachable = false
    var style: StateStyle { unreachable ? .unreachable : StateStyle.of(state) }
}

/// One part of the header that changes once a second (the state chip with its duration, the meta
/// line with `UP x`), drawn into its own transparent layer: the 1 Hz tick redraws only that part
/// and never the glowing title (its shadow blur was most of the visible-idle CPU, review
/// concurrency-perf-1). Clicks fall through to the header (window drag).
private final class HeaderPartView: FlippedView {
    var drawer: (() -> Void)?
    /// M5 D21: a part that says something VoiceOver should hear is a static text with this label
    /// (the meta line); nil keeps the part out of the tree (the chip: the lamp speaks the state).
    var spoken: (@MainActor () -> String?)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override func isAccessibilityElement() -> Bool { spoken?() != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { spoken?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { drawer?() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Session header (`.sh`): lamp · tag · title · state chip · EXT, meta line, and actions
/// (`✎ NOTES n`, files, bottom terminal, `A− 13 A+`, `⋯`). Drags the window like a title bar.
final class SessionHeaderView: WindowDragView {
    private let lamp = LampView()
    let notesButton = CoddButton("✎ Notes", style: .pill(count: nil))
    let filesButton = CoddButton("檔案（在編輯器開啟專案）", style: .icon(.files))
    let bottomTerminalButton = CoddButton("下方終端機 ⌘J", style: .icon(.bottomTerminal))
    let fontDown = CoddButton("A−", style: .glyph(size: 26))
    let fontUp = CoddButton("A+", style: .glyph(size: 26))
    let moreButton = CoddButton("⋯", style: .glyph())
    private let fontLabel = Label.make("13", style: TextStyle.mono(11, Palette.bone))
    private var model: SessionHeaderModel?
    private var now = Date()
    private var actions: NSStackView?
    private var fontGroup: NSView?
    private var divider: NSView?
    /// The state chip (and EXT) and the meta line, each in its own layer (see `HeaderPartView`).
    private let chipPart = HeaderPartView()
    private let metaPart = HeaderPartView()
    /// The chip width the title was truncated for: a tick that changes it lays the line out again.
    private var laidOutChipWidth: CGFloat = -1
    /// Line 1 / line 2 centers (design points; M4 interface zoom).
    private static var l1: CGFloat { UIZoom.pt(17) }
    private static var l2: CGFloat { UIZoom.pt(36) }

    init() {
        super.init(fill: Palette.bgSoft, edges: [.bottom], edgeColor: Palette.lineBright)
        addSubview(lamp)
        for part in [chipPart, metaPart] {
            part.translatesAutoresizingMaskIntoConstraints = true
            addSubview(part)
        }
        chipPart.drawer = { [weak self] in self?.drawChipPart() }
        metaPart.drawer = { [weak self] in self?.drawMetaPart() }
        metaPart.spoken = { [weak self] in self?.spokenMeta() }
        filesButton.setAccessibilityLabel("檔案（在編輯器開啟專案）")
        bottomTerminalButton.setAccessibilityLabel("下方終端機 ⌘J")
        fontDown.setAccessibilityLabel("字小一點")
        fontUp.setAccessibilityLabel("字大一點")
        moreButton.setAccessibilityLabel("更多動作")
        let fontGroup = PanelView(edges: [.top, .bottom, .left, .right], edgeColor: Palette.line)
        let fontStack = hStack([fontDown, fontLabel, fontUp], spacing: 0)
        fontGroup.addSubview(fontStack)
        fontStack.pinEdges(to: fontGroup, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        let divider = PanelView(fill: Palette.lineBright)
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 18).zoomed(18).isActive = true
        self.fontGroup = fontGroup
        self.divider = divider
        let stack = hStack([notesButton, filesButton, bottomTerminalButton, divider, fontGroup, moreButton], spacing: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.trailingAnchor.constraint(equalTo: trailingAnchor).zoomed(-10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        actions = stack
    }

    // MARK: Accessibility (M5 D21)

    /// The shown session's spoken state (`等待中 · 權限 · 3 分鐘`), read by the lamp when VoiceOver
    /// asks; the pane sets it.
    var spokenState: (@MainActor () -> String)? {
        didSet { lamp.spokenDescription = spokenState }
    }

    /// The header is one group: its label is the title (and `EXT`), its children the lamp (the
    /// state), the meta line and the actions.
    override func isAccessibilityElement() -> Bool { model != nil }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? {
        guard let model else { return nil }
        return model.external ? "\(model.title)，EXT 外部 session" : model.title
    }

    /// The meta line as words: `~/…/backend，⎇ fix/login-401，opus-5.5，CTX 58%，$2.14，已執行 42 分鐘，帳號 #3 工作`.
    private func spokenMeta() -> String? {
        guard let model else { return nil }
        var parts = [PathFormat.short(model.cwd)] + model.meta.map(\.text)
        if let started = model.startedAt { parts.append("已執行 " + SpokenDuration.text(now.timeIntervalSince(started))) }
        if let account = model.account { parts.append("帳號 \(account)") }
        if model.remoteControl { parts.append("Remote Control 已連線") }
        return parts.filter { !$0.isEmpty }.joined(separator: "，")
    }

    func setFontSize(_ size: Double) {
        Label.set(fontLabel, "\(Int(size.rounded()))", style: TextStyle.mono(11, Palette.bone))
        fontLabel.setAccessibilityLabel("終端機字級 \(Int(size.rounded()))")
    }

    func update(_ model: SessionHeaderModel?, now: Date) {
        self.model = model
        self.now = now
        lamp.isHidden = model == nil
        actions?.isHidden = model == nil
        if let model {
            lamp.configure(model.style.style)
            notesButton.style = .pill(count: model.notes > 0 ? "\(model.notes)" : nil)
            notesButton.setAccessibilityLabel(model.notes > 0 ? "筆記抽屜，\(model.notes) 則筆記" : "筆記抽屜")
        }
        fitActions()
        needsDisplay = true
        layoutParts()
        chipPart.needsDisplay = true
        metaPart.needsDisplay = true
    }

    /// 1 Hz: only the chip duration and `UP x` change, so only their layers redraw. A chip that
    /// changed width moves (and may truncate the title differently): then the line is laid out
    /// and drawn again.
    func tick(now: Date) {
        guard let model else { return }
        let chipBefore = chipText(model)
        let upBefore = upText(model)
        self.now = now
        var redraw: TickRedraw = []
        if chipText(model) != chipBefore {
            if chipStyle(model).size(for: chipText(model)).width != laidOutChipWidth {
                needsDisplay = true
                layoutParts()
                redraw.insert(.header)
            }
            chipPart.needsDisplay = true
            redraw.insert(.chip)
        }
        if upText(model) != upBefore {
            metaPart.needsDisplay = true
            redraw.insert(.meta)
        }
        lastTickRedraw = redraw
    }

    /// What a tick invalidated: the chip layer, the meta layer, the whole header (title included).
    struct TickRedraw: OptionSet, Equatable {
        let rawValue: Int
        static let chip = TickRedraw(rawValue: 1)
        static let meta = TickRedraw(rawValue: 2)
        static let header = TickRedraw(rawValue: 4)
    }

    /// The last tick's redraw (tests).
    private(set) var lastTickRedraw: TickRedraw = []

    /// The chip and meta layers (tests).
    var tickingParts: [NSView] { [chipPart, metaPart] }

    private func chipText(_ model: SessionHeaderModel) -> String {
        var parts = model.chipParts
        if model.chipShowsDuration { parts.append(DurationFormat.compact(now.timeIntervalSince(model.stateSince))) }
        return parts.joined(separator: " · ")
    }

    private func upText(_ model: SessionHeaderModel) -> String {
        model.startedAt.map { "UP " + DurationFormat.compact(now.timeIntervalSince($0)) } ?? ""
    }

    override func layout() {
        fitActions()
        super.layout()
        let z = UIZoom.pt
        lamp.frame = CGRect(x: z(16), y: z(9), width: z(12), height: z(16))
        layoutParts()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitActions()
    }

    /// Narrow panes (a small window, the interface zoom): line 1 keeps the lamp, up to 120 pt of
    /// title and of state chip (both truncated); the actions give way for them, `A− 13 A+`
    /// first, then the files and bottom-terminal icons (both are in the menus too). `✎ NOTES`
    /// and `⋯` always show.
    private func fitActions() {
        guard let actions, let model, let fontGroup, let divider else { return }
        let z = UIZoom.pt
        let spacing = actions.spacing
        let chip = min(chipStyle(model).size(for: chipText(model)).width, z(120))
        let ext = model.external ? ChipStyle.ext.size(for: "EXT").width + z(9) : 0
        let title = min(Draw.width(titleString(model)), z(120))
        let left = z(16 + 12 + 9) + (model.tag == nil ? 0 : z(8 + 9)) + title + z(9) + chip + ext + z(12) + z(10)
        let fixed = left + notesButton.intrinsicContentSize.width + spacing + moreButton.intrinsicContentSize.width
        let icons = filesButton.intrinsicContentSize.width + bottomTerminalButton.intrinsicContentSize.width + spacing * 2
        let font = 1 + fontGroup.fittingSize.width + spacing * 2
        let shown = RowFit.shown(available: bounds.width, fixed: fixed, costs: [icons, font])
        for (view, show) in [(filesButton, shown[0]), (bottomTerminalButton, shown[0]), (divider, shown[1]), (fontGroup, shown[1])]
        where view.isHidden == show {
            view.isHidden = !show
        }
    }

    /// Whether the files / bottom-terminal icons and `A− 13 A+` show at the current width (tests).
    var shownActionGroups: (icons: Bool, font: Bool) { (!filesButton.isHidden, !(fontGroup?.isHidden ?? true)) }

    private func chipStyle(_ model: SessionHeaderModel) -> ChipStyle {
        let style = model.style.style
        return ChipStyle(text: TextStyle(font: Typeface.mono(10.5), color: style.color, tracking: 0.1),
                         border: style.color,
                         fill: model.style.unreachable ? Palette.danger.withAlphaComponent(0.10)
                             : model.style.state == .waiting ? Palette.amber.withAlphaComponent(0.12)
                             : (model.style.state == .error ? Palette.danger.withAlphaComponent(0.10) : nil),
                         height: 20, padding: 7)
    }

    private func titleString(_ model: SessionHeaderModel) -> NSAttributedString {
        TextStyle(font: Typeface.display(15), color: Palette.amber, shadow: SidebarHeaderView.glow(radius: 10)).string(model.title)
    }

    private var right: CGFloat { (actions?.frame.minX ?? bounds.width) - UIZoom.pt(12) }

    /// Where the title starts (after the lamp and the tag square) and how wide it may be: chip +
    /// EXT are measured first so the title truncates instead of pushing them out.
    private func titleLayout(_ model: SessionHeaderModel, chipWidth: CGFloat) -> (x: CGFloat, maxWidth: CGFloat) {
        let z = UIZoom.pt
        let x = z(16 + 12 + 9) + (model.tag == nil ? 0 : z(8 + 9))
        let extWidth = model.external ? ChipStyle.ext.size(for: "EXT").width + z(9) : 0
        let chip = shownChipWidth(model, natural: chipWidth)
        return (x, max(z(40), right - x - chip - extWidth - z(9)))
    }

    /// The chip's drawn width: its own, or (narrow headers) what is left after up to 120 pt of
    /// title, never under 72 pt while the title keeps 40: it truncates (`…`) instead of running
    /// under the actions, and the title stays readable.
    private func shownChipWidth(_ model: SessionHeaderModel, natural: CGFloat) -> CGFloat {
        let z = UIZoom.pt
        let x = z(16 + 12 + 9) + (model.tag == nil ? 0 : z(8 + 9))
        let extWidth = model.external ? ChipStyle.ext.size(for: "EXT").width + z(9) : 0
        let available = right - x - z(9) - extWidth
        let title = min(Draw.width(titleString(model)), z(120))
        let chip = min(natural, max(available - title, min(natural, z(72))))
        return max(0, min(chip, available - z(40)))
    }

    /// Places the chip part after the title and the meta part on line 2.
    private func layoutParts() {
        guard let model else {
            chipPart.isHidden = true
            metaPart.isHidden = true
            return
        }
        chipPart.isHidden = false
        metaPart.isHidden = false
        let naturalChip = chipStyle(model).size(for: chipText(model)).width
        laidOutChipWidth = naturalChip
        let title = titleLayout(model, chipWidth: naturalChip)
        let titleWidth = min(Draw.width(titleString(model)), title.maxWidth)
        let z = UIZoom.pt
        let extWidth = model.external ? ChipStyle.ext.size(for: "EXT").width + z(9) : 0
        let chipWidth = shownChipWidth(model, natural: naturalChip)
        let chipFrame = CGRect(x: title.x + titleWidth + z(9), y: Self.l1 - z(11), width: chipWidth + extWidth + 1, height: z(22))
        if chipPart.frame != chipFrame { chipPart.frame = chipFrame }
        let metaFrame = CGRect(x: 0, y: Self.l2 - z(10), width: max(0, right), height: z(20))
        if metaPart.frame != metaFrame { metaPart.frame = metaFrame }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let model else { return }
        let chipWidth = chipStyle(model).size(for: chipText(model)).width
        let title = titleLayout(model, chipWidth: chipWidth)
        if let tag = model.tag {
            let side = UIZoom.pt(8)
            Draw.fill(CGRect(x: title.x - side - UIZoom.pt(9), y: Self.l1 - side / 2, width: side, height: side), tag.color)
        }
        Draw.text(titleString(model), x: title.x, centerY: Self.l1, maxWidth: title.maxWidth)
    }

    /// The chip part: `◆ WAITING · PERMISSION · 3m`, then `EXT` (part coordinates: line 1 at y 11).
    private func drawChipPart() {
        guard let model else { return }
        let chip = chipStyle(model)
        let center = UIZoom.pt(11)
        let maxWidth = shownChipWidth(model, natural: chip.size(for: chipText(model)).width)
        let width = chip.draw(chipText(model), x: 0, centerY: center, maxWidth: maxWidth)
        if model.external { ChipStyle.ext.draw("EXT", x: width + UIZoom.pt(9), centerY: center) }
    }

    /// The meta part: cwd · meta · `UP x`, account chip, RC (part coordinates: line 2 at y 10).
    private func drawMetaPart() {
        guard let model else { return }
        drawMeta(model, x: UIZoom.pt(16), centerY: UIZoom.pt(10), right: right)
    }

    private func drawMeta(_ model: SessionHeaderModel, x start: CGFloat, centerY: CGFloat, right: CGFloat) {
        let base = TextStyle.mono(10.5, Palette.dim)
        let separator = TextStyle.mono(10.5, Palette.dimmer).string(" · ")
        let line = NSMutableAttributedString(attributedString: base.string(PathFormat.short(model.cwd)))
        var items = model.meta
        if let up = model.startedAt.map({ _ in upText(model) }) { items.append(.init(text: up)) }
        for item in items {
            line.append(separator)
            line.append(base.with(color: item.danger ? Palette.danger : Palette.dim).string(item.text))
        }
        let z = UIZoom.pt
        let accountChip = model.account.map { account -> (String, ChipStyle) in
            let color = model.accountPinned ? Palette.cyan : Palette.bone
            return (account, ChipStyle(text: TextStyle.mono(10, color, tracking: 0.04),
                                       border: model.accountPinned ? Palette.cyan.withAlphaComponent(0.4) : Palette.lineBright,
                                       fill: nil, height: 16, padding: 5))
        }
        let rc = NSMutableAttributedString(attributedString: TextStyle.mono(10, Palette.success).string("◉ "))
        rc.append(TextStyle.mono(10, Palette.bone, tracking: 0.04).string("RC"))
        // The chips after the path stay whole: on a narrow header RC goes first, then the
        // account chip, so that at least 60 pt of the path (truncated) stays.
        let accountWidth = accountChip.map { $0.1.size(for: $0.0).width + z(6) } ?? 0
        let rcWidth = model.remoteControl ? Draw.width(rc) + z(10) : 0
        let chips = RowFit.shown(available: right - start, fixed: z(60) + z(8), costs: [accountWidth, rcWidth])
        let reserve = (chips[0] ? accountWidth : 0) + (chips[1] ? rcWidth : 0)
        var x = start + Draw.text(line, x: start, centerY: centerY, maxWidth: max(z(40), right - start - z(8) - reserve)) + z(8)
        if chips[0], let (account, chip) = accountChip {
            x += chip.draw(account, x: x, centerY: centerY) + z(6)
        }
        if model.remoteControl, chips[1] {
            let height = z(16)
            let rect = CGRect(x: x, y: centerY - height / 2, width: Draw.width(rc) + z(10), height: height)
            Draw.strokeRect(rect, color: Palette.lineBright)
            Draw.text(rc, x: x + z(5), centerY: centerY)
        }
    }
}
