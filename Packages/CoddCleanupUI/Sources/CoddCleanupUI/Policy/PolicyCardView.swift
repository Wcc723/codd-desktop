import AppKit
import CoddUI

/// The POLICY · 保留規則 card (`.card.nb-cl-pol`, full width under the grid): the header with
/// `[調整規則 → 設定]`, the lifecycle line (`ACTIVE → STALE 14d → ARCHIVE 30d → TRASH → PURGE 30d`
/// with a line of explanation under each box) and the rules list (`dt` / `dd` pairs, two per line).
final class PolicyCardView: NSView {
    /// `.nb-cl-pol{padding:14px 18px 16px}`.
    static var padding: NSEdgeInsets { NSEdgeInsets(top: kz(14), left: kz(18), bottom: kz(16), right: kz(18)) }

    let card = CardView(title: "", hot: false, padding: PolicyCardView.padding)
    let body = PolicyBodyView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(card)
        card.addSubview(body)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("保留規則")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func naturalHeight(width: CGFloat) -> CGFloat {
        2 + Self.padding.top + Self.padding.bottom + body.naturalHeight(width: width - 2 - Self.padding.left - Self.padding.right)
    }

    override func layout() {
        super.layout()
        card.frame = CGRect(x: 0, y: -CardView.outset, width: bounds.width, height: bounds.height + CardView.outset * 2)
        body.frame = CGRect(x: 1 + Self.padding.left, y: CardView.outset + 1 + Self.padding.top,
                            width: max(0, bounds.width - 2 - Self.padding.left - Self.padding.right),
                            height: max(0, bounds.height - 2 - Self.padding.top - Self.padding.bottom))
    }
}

/// The policy card's body. Lifecycle boxes take the step color (`--st`: success, amber-dim, cyan,
/// danger, dimmer by position unless the model gives one); every step but the last shares the
/// column's width (`li{flex:1}`), the last is as wide as its content.
final class PolicyBodyView: NSView {
    static var headerHeight: CGFloat { kz(22) }
    /// Header rule (6 px under the header) + 1 + `gap: 12px`.
    static var contentTop: CGFloat { headerHeight + kz(6) + 1 + kz(12) }
    static var columnGap: CGFloat { kz(28) }
    /// Below this body width the lifecycle and the rules stack (the artboard's body is 1258; at
    /// half of ~1100 the five boxes and their connectors still fit).
    static var twoColumnWidth: CGFloat { kz(1100) }
    static let defaultColors: [NSColor] = [Palette.success, Palette.amberDim, Palette.cyan, Palette.danger, Palette.dimmer]

    let titleLine = TextLine("Policy · 保留規則", style: TextStyle.cardTitle)
    let settingsButton = ActionButton("調整規則 → 設定", style: .bracket(.normal, small: true))
    private(set) var model: CleanupPolicyModel?
    private var stepBoxes: [PolicyStepBox] = []
    private var stepSubs: [TextBlock] = []
    private var stepConnectors: [PolicyConnectorView] = []
    private var terms: [TextLine] = []
    private var texts: [TextBlock] = []
    private var rulesRect: CGRect = .zero
    var onOpenSettings: (() -> Void)? { didSet { settingsButton.run = onOpenSettings } }

    static var subStyle: TextStyle { TextStyle.mono(10.5, Palette.dim) }
    static let subLineHeight: CGFloat = 10.5 * 1.4
    static var termStyle: TextStyle { TextStyle.caps(10, Palette.dim, tracking: 0.14) }
    static var textStyle: TextStyle { TextStyle.mono(11.5, Palette.bone) }
    static let textLineHeight: CGFloat = 11.5 * 1.5

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        settingsButton.button.setAccessibilityLabel("調整規則，前往設定")
        addSubview(titleLine)
        addSubview(settingsButton.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    func configure(_ model: CleanupPolicyModel) {
        guard model != self.model else { return }
        self.model = model
        (stepBoxes as [NSView] + stepSubs + stepConnectors + terms + texts).forEach { $0.removeFromSuperview() }
        stepBoxes = model.lifecycle.enumerated().map { index, step in
            PolicyStepBox(step: step, color: step.color ?? Self.defaultColors[min(index, Self.defaultColors.count - 1)])
        }
        stepSubs = model.lifecycle.map { TextBlock($0.sub, style: Self.subStyle, lineHeight: Self.subLineHeight) }
        stepConnectors = model.lifecycle.dropLast().map { _ in PolicyConnectorView() }
        terms = model.rules.map { TextLine($0.term, style: Self.termStyle) }
        texts = model.rules.map { TextBlock($0.text, style: Self.textStyle, lineHeight: Self.textLineHeight) }
        (stepBoxes as [NSView] + stepSubs + stepConnectors + terms + texts).forEach { addSubview($0) }
        needsLayout = true
    }

    // MARK: Layout

    private struct Plan {
        var frames: [ObjectIdentifier: CGRect] = [:]
        var rules: CGRect = .zero
        var height: CGFloat = 0
    }

    func naturalHeight(width: CGFloat) -> CGFloat { plan(width: width).height }

    override func layout() {
        super.layout()
        let plan = plan(width: bounds.width)
        for view in subviews { if let frame = plan.frames[ObjectIdentifier(view)] { view.frame = frame } }
        rulesRect = plan.rules
        needsDisplay = true
    }

    private func plan(width: CGFloat) -> Plan {
        var plan = Plan()
        func put(_ view: NSView, _ rect: CGRect) { plan.frames[ObjectIdentifier(view)] = rect.pixelAligned }
        let buttonWidth = settingsButton.button.intrinsicContentSize.width
        put(settingsButton.button, CGRect(x: width - buttonWidth, y: 0, width: buttonWidth, height: kz(22)))
        put(titleLine, CGRect(x: 0, y: kz(2), width: max(0, width - buttonWidth - kz(8)), height: kz(18)))
        let twoColumns = width >= Self.twoColumnWidth
        let columnWidth = twoColumns ? ((width - Self.columnGap) / 2).rounded(.down) : width
        let top = Self.contentTop

        // Lifecycle.
        var lifeHeight: CGFloat = 0
        if !stepBoxes.isEmpty {
            let lastBox = stepBoxes[stepBoxes.count - 1].preferredWidth
            let lastSub = stepSubs[stepSubs.count - 1]
            let lastWidth = ceil(max(lastBox, Draw.width(lastSub.attributed) + kz(8)))
            let others = stepBoxes.count > 1 ? (columnWidth - lastWidth) / CGFloat(stepBoxes.count - 1) : 0
            var x: CGFloat = 0
            for (index, box) in stepBoxes.enumerated() {
                let isLast = index == stepBoxes.count - 1
                let liWidth = isLast ? lastWidth : others
                let boxWidth = min(box.preferredWidth, liWidth)
                put(box, CGRect(x: x, y: top, width: boxWidth, height: kz(24)))
                if !isLast {
                    put(stepConnectors[index], CGRect(x: x + boxWidth, y: top, width: max(18, liWidth - boxWidth), height: kz(24)))
                }
                let subWidth = max(0, liWidth - kz(8))
                let subHeight = stepSubs[index].height(forWidth: subWidth)
                put(stepSubs[index], CGRect(x: x, y: top + kz(24) + kz(5), width: subWidth, height: subHeight))
                lifeHeight = max(lifeHeight, kz(24) + kz(5) + subHeight)
                x += liWidth
            }
        }

        // Rules: `grid-template-columns: auto 1fr auto 1fr; gap: 5px 14px; padding-left: 20px` after a
        // dashed left border.
        let rulesX = twoColumns ? columnWidth + Self.columnGap : 0
        let rulesTop = twoColumns ? top : top + lifeHeight + kz(16)
        let inner = (twoColumns ? width - rulesX : width) - 1 - kz(20)
        let termWidths = [0, 1].map { column in
            stride(from: column, to: terms.count, by: 2).map { terms[$0].textWidth }.max() ?? 0
        }.map { ceil($0) }
        let textWidth = max(40, ((inner - termWidths[0] - termWidths[1] - 3 * 14) / 2).rounded(.down))
        var y = rulesTop
        var index = 0
        while index < terms.count {
            var rowHeight: CGFloat = kz(16)
            for column in 0..<2 where index + column < terms.count {
                rowHeight = max(rowHeight, texts[index + column].height(forWidth: textWidth))
            }
            for column in 0..<2 where index + column < terms.count {
                let base = rulesX + 1 + kz(20) + CGFloat(column) * (termWidths[0] + kz(14) + textWidth + kz(14))
                let termWidth = termWidths[column]
                put(terms[index + column], CGRect(x: base, y: y + 1, width: termWidth, height: kz(15)))
                put(texts[index + column], CGRect(x: base + termWidth + kz(14), y: y, width: textWidth,
                                                  height: texts[index + column].height(forWidth: textWidth)))
            }
            y += rowHeight + kz(5)
            index += 2
        }
        let rulesHeight = terms.isEmpty ? 0 : y - kz(5) - rulesTop
        plan.rules = CGRect(x: rulesX, y: rulesTop, width: width - rulesX, height: rulesHeight)
        plan.height = ceil(twoColumns ? top + max(lifeHeight, rulesHeight) : rulesTop + rulesHeight)
        return plan
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.dashedLine(from: CGPoint(x: 0, y: Self.headerHeight + kz(6)), to: CGPoint(x: bounds.width, y: Self.headerHeight + kz(6)),
                        color: Palette.lineBright)
        if rulesRect.height > 0 {
            // `border-left: 1px dashed var(--line-bright)`.
            let path = NSBezierPath()
            path.move(to: CGPoint(x: rulesRect.minX + 0.5, y: rulesRect.minY))
            path.line(to: CGPoint(x: rulesRect.minX + 0.5, y: rulesRect.maxY))
            path.lineWidth = 1
            path.setLineDash([3, 2], count: 2, phase: 0)
            Palette.lineBright.setStroke()
            path.stroke()
        }
    }
}

/// `.nb-cl-life .bx`: 24 px box in the step color, `NAME` (10.5 caps .14em) and the bone detail.
final class PolicyStepBox: NSView, CleanupTextShowing {
    let step: CleanupPolicyStep
    let color: NSColor

    init(step: CleanupPolicyStep, color: NSColor) {
        self.step = step
        self.color = color
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(displayedText + "，" + step.sub)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    private var nameString: NSAttributedString { TextStyle.caps(10.5, color, tracking: 0.14).string(step.name) }
    private var detailString: NSAttributedString? { step.detail.map { TextStyle.mono(10.5, Palette.bone, tracking: 0.02).string($0) } }

    var displayedText: String { [step.name.uppercased(), step.detail].compactMap { $0 }.joined(separator: " ") }

    /// `padding: 0 8px` + border, name, `gap: 6px`, detail.
    var preferredWidth: CGFloat {
        ceil(1 + kz(8) + Draw.width(nameString) + (detailString.map { kz(6) + Draw.width($0) } ?? 0) + kz(8) + 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.strokeRect(bounds, color: color)
        let x = kz(9) + Draw.text(nameString, x: kz(9), centerY: bounds.midY)
        if let detailString { Draw.text(detailString, x: x + kz(6), centerY: bounds.midY) }
    }
}

/// `.nb-cl-life .ln`: a dashed --line-bright line and `→` (--dimmer), `padding: 0 4px; gap: 2px`.
final class PolicyConnectorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let arrow = TextStyle.mono(10.5, Palette.dimmer).string("→")
        let arrowWidth = Draw.width(arrow)
        let arrowX = bounds.width - kz(4) - arrowWidth
        let mid = bounds.midY.rounded(.down)
        Draw.dashedLine(from: CGPoint(x: kz(4), y: mid), to: CGPoint(x: max(4, arrowX - kz(2)), y: mid), color: Palette.lineBright)
        Draw.text(arrow, x: arrowX, centerY: bounds.midY)
    }
}
