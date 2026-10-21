import AppKit
import CoddOnboarding
import CoddUI

/// Keyboard focus for the wizard's own buttons (stepper rows): like AppKit buttons they join the key
/// loop only with Full Keyboard Access (D21). Tests set the override.
@MainActor
enum OnboardingKeyboard {
    static var fullKeyboardAccessOverride: Bool?
    static var isFullKeyboardAccessOn: Bool {
        fullKeyboardAccessOverride ?? NSApplication.shared.isFullKeyboardAccessEnabled
    }
}

/// The 260 px stepper column (`.ob-steps`): drag area, brand, the six steps with their dashed
/// connectors, and the foot (hint, the D12 link, the version line).
final class StepperView: NSView {
    static let width: CGFloat = 260

    let drag = WindowDragView(fill: nil)
    let brand = BrandView()
    private(set) var rows: [StepRowView] = []
    let hint = RichTextView(look: RichLook(size: 11, color: Palette.dim, lineHeight: 11 * 1.55, codeSize: 10.5))
    let link = LinkButton("已在用 CODD Web？匯入它的設定 →")
    let version = TextLine()
    var onSelect: (OnboardingStep) -> Void = { _ in }
    /// The blinking `_` of the current step's title.
    var cursorVisible = true { didSet { if cursorVisible != oldValue { rows.first { $0.state == .current }?.needsDisplay = true } } }
    /// Whether the foot's hint fits (it gives way on short windows).
    private(set) var showsHint = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(drag)
        addSubview(brand)
        for step in OnboardingStep.allCases {
            let row = StepRowView(step: step)
            row.onPress = { [weak self] in self?.onSelect(step) }
            rows.append(row)
            addSubview(row)
        }
        hint.set("第 3 步按下套用前，不會改動 `~/.claude/settings.json`。每一步都能之後在 SETTINGS 調整。")
        addSubview(hint)
        addSubview(link)
        addSubview(version)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel("首次啟動設定步驟")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func accessibilityChildren() -> [Any]? { rows }

    func apply(_ model: OnboardingViewModel) {
        for (index, row) in rows.enumerated() {
            let step = row.step
            let state = model.flow.progress[step] ?? .todo
            let detail = state == .skipped ? OnboardingViewModel.skippedDetail : (model.stepDetails[step] ?? "")
            let incoming = index > 0 ? rows[index - 1].state : nil
            row.configure(state: state, detail: detail, incoming: incoming)
        }
        link.isHidden = !model.showsWebImportLink
        version.set(model.versionLine, style: TextStyle.mono(11, Palette.dimmer, tracking: 0.01))
        needsLayout = true
    }

    // MARK: Layout

    /// `.ob-brandblk`: padding 4 22 18, the 25.5 px brand row, gap 6, the 18 px comment, 1 px dashed rule.
    static var brandHeight: CGFloat { dz(4) + ceil(UIZoom.scaled(17 * 1.5)) + dz(6) + ceil(UIZoom.scaled(12 * 1.5)) + dz(18) + 1 }

    override func layout() {
        super.layout()
        let inner = bounds.width - 1
        drag.place(CGRect(x: 0, y: 0, width: inner, height: dz(52)))
        brand.place(CGRect(x: 0, y: dz(52), width: inner, height: Self.brandHeight))
        let rowsTop = brand.frame.maxY + dz(14)
        // Foot: dashed rule, padding 14 20 16, gap 9.
        let footWidth = inner - dz(40)
        let linkHeight = link.isHidden ? 0 : link.intrinsicContentSize.height
        let versionHeight = ceil(UIZoom.scaled(11 * 1.5))
        let hintHeight = hint.height(forWidth: footWidth)
        func footHeight(withHint: Bool) -> CGFloat {
            var height = 1 + dz(14) + versionHeight + dz(16)
            if withHint { height += hintHeight + dz(9) }
            if !link.isHidden { height += linkHeight + dz(9) }
            return height
        }
        let natural = StepRowView.naturalHeight
        showsHint = bounds.height - footHeight(withHint: true) - rowsTop >= natural * 6
        let footTop = bounds.height - footHeight(withHint: showsHint)
        // Short windows: the rows give up their bottom padding (15 px) before anything overlaps.
        let rowHeight = max(StepRowView.minimumHeight, min(natural, (footTop - rowsTop) / 6))
        // Fractional heights accumulate like CSS; each frame is rounded on its own edges.
        var y = rowsTop
        for row in rows {
            let top = y.rounded()
            row.place(CGRect(x: dz(12), y: top, width: inner - dz(24), height: (y + rowHeight).rounded() - top))
            y += rowHeight
        }
        hint.isHidden = !showsHint
        var footY = footTop + 1 + dz(14)
        if showsHint {
            hint.place(CGRect(x: dz(20), y: footY, width: footWidth, height: hintHeight))
            footY += hintHeight + dz(9)
        }
        if !link.isHidden {
            link.place(CGRect(x: dz(20), y: footY, width: min(footWidth, link.intrinsicContentSize.width), height: linkHeight))
            footY += linkHeight + dz(9)
        }
        version.place(CGRect(x: dz(20), y: footY, width: footWidth, height: versionHeight))
        footRuleY = footTop
        needsDisplay = true
    }

    private var footRuleY: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        Draw.dashedLine(from: CGPoint(x: 0, y: footRuleY), to: CGPoint(x: bounds.width - 1, y: footRuleY), color: Palette.line)
    }
}

/// `.ob-brandblk`: `Icon.brand` 20 px amber with a soft glow, `CODD` (§10: the brand alone) display 17 px
/// amber, `// first boot · 首次啟動設定`, dashed --line bottom rule.
final class BrandView: NSView, OnboardingTextShowing {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("CODD · 首次啟動設定")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    static let comment = "// first boot · 首次啟動設定"
    var displayedText: String { "CODD\n\(Self.comment)" }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight = ceil(UIZoom.scaled(17 * 1.5))
        let rowMid = dz(4) + rowHeight / 2
        let icon = dz(20)
        let iconRect = CGRect(x: dz(22), y: (rowMid - icon / 2).rounded(), width: icon, height: icon)
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(Palette.amber.withAlphaComponent(0.35), radius: 6).set()
        IconRenderer.draw(.brand, in: iconRect, color: Palette.amber, flipped: true)
        NSGraphicsContext.restoreGraphicsState()
        let brand = TextStyle(font: Typeface.display(17), color: Palette.amber, tracking: 0.04, shadow: Draw.glow(Palette.amberGlow, radius: 8))
        Draw.text(brand.string("CODD"), x: iconRect.maxX + dz(8), centerY: rowMid)
        let commentTop = dz(4) + rowHeight + dz(6)
        let commentHeight = ceil(UIZoom.scaled(12 * 1.5))
        Draw.text(TextStyle.comment.string(Self.comment), x: dz(22), centerY: commentTop + commentHeight / 2, maxWidth: bounds.width - dz(44))
        Draw.dashedLine(from: CGPoint(x: 0, y: bounds.height - 1), to: CGPoint(x: bounds.width, y: bounds.height - 1), color: Palette.line)
    }
}

/// One stepper row (`.ob-st`): the 26 px number box, title / English / detail, and the dashed
/// connector to the next box. Done and skipped rows are buttons (`goTo`); the current one is
/// `aria-current=step`; todo rows are static.
final class StepRowView: NSView, OnboardingTextShowing {
    let step: OnboardingStep
    private(set) var state: StepProgress = .todo
    private(set) var detail = ""
    /// The previous row's state (it colors the connector's tail that runs into this row).
    private(set) var incoming: StepProgress?
    var onPress: () -> Void = {}
    private(set) var isHovered = false
    private var trackingArea: NSTrackingArea?

    init(step: OnboardingStep) {
        self.step = step
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    var isClickable: Bool { state == .done || state == .skipped }

    func configure(state: StepProgress, detail: String, incoming: StepProgress?) {
        guard state != self.state || detail != self.detail || incoming != self.incoming else { return }
        self.state = state
        self.detail = detail
        self.incoming = incoming
        updateAccessibility()
        needsDisplay = true
    }

    private var stateWord: String {
        switch state {
        case .done: "已完成"
        case .skipped: "已略過"
        case .current: "目前步驟"
        case .todo: "尚未開始"
        }
    }

    private func updateAccessibility() {
        setAccessibilityRole(isClickable ? .button : .staticText)
        setAccessibilityLabel("\(step.rawValue). \(step.title)，\(stateWord)")
        setAccessibilityValue(detail)
    }

    var displayedText: String { "\(step.title)\n\(step.english)\n\(detail)" }

    // MARK: Metrics

    /// `padding-top:1` + title 13 × 1.35 + gap 2 + English 10 × 1.5 + gap 2 + detail 11 × 1.5.
    static var textHeight: CGFloat {
        dz(1) + UIZoom.scaled(13 * 1.35) + dz(2) + UIZoom.scaled(15) + dz(2) + UIZoom.scaled(16.5)
    }
    /// `padding: 10px 10px 15px`.
    static var naturalHeight: CGFloat { dz(10) + textHeight + dz(15) }
    static var minimumHeight: CGFloat { dz(10) + textHeight + dz(4) }
    static var boxRect: CGRect { CGRect(x: dz(10), y: dz(10), width: dz(26), height: dz(26)) }

    // MARK: Drawing

    private static let doneBorder = NSColor(hex: 0x7CFF9A, alpha: 0.4)
    private static let doneConnector = NSColor(hex: 0x52C472, alpha: 0.6)

    private func connectorColor(_ state: StepProgress?) -> NSColor { state == .done ? Self.doneConnector : Palette.lineBright }

    override func draw(_ dirtyRect: NSRect) {
        let box = Self.boxRect
        let current = state == .current
        if current {
            // `linear-gradient(90deg, var(--amber-glow), transparent 85%)` + `inset 2px 0 0 var(--amber)`.
            let gradient = NSGradient(colors: [Palette.amberGlow, Palette.amberGlow.withAlphaComponent(0), Palette.amberGlow.withAlphaComponent(0)],
                                      atLocations: [0, 0.85, 1], colorSpace: .sRGB)
            gradient?.draw(in: bounds, angle: 0)
            Draw.fill(CGRect(x: 0, y: 0, width: dz(2), height: bounds.height), Palette.amber)
        }
        // Connectors (`left:23px; top:36px; bottom:-10px`): the previous row's tail (top 10 px) and
        // this row's own line from the box to the bottom.
        let x = dz(23)
        if let incoming { dashedVLine(x: x, from: 0, to: box.minY, color: connectorColor(incoming)) }
        if step != .done { dashedVLine(x: x, from: box.maxY, to: bounds.height, color: connectorColor(state)) }
        // Number box (z-index 1 over the connector).
        switch state {
        case .current:
            NSGraphicsContext.saveGraphicsState()
            Draw.glow(Palette.amberGlow, radius: 12).set()
            Draw.fill(box, Palette.amber)
            NSGraphicsContext.restoreGraphicsState()
        case .done:
            Draw.fill(box, Palette.bg)
            Draw.strokeRect(box, color: Self.doneBorder)
        default:
            Draw.fill(box, Palette.bg)
            Draw.strokeRect(box, color: Palette.lineBright)
        }
        let numberColor: NSColor = current ? .black : (state == .done ? Palette.success : Palette.dim)
        let number = TextStyle.mono(11, numberColor, .semibold).string(state == .done ? "✓" : "\(step.rawValue)")
        Draw.text(number, x: (box.midX - Draw.width(number) / 2).rounded(), centerY: box.midY)
        drawText(textX: box.maxX + dz(12))
        if window?.firstResponder === self, window?.isKeyWindow == true {
            Draw.strokeRect(bounds, color: Palette.amber)
        }
    }

    private func drawText(textX: CGFloat) {
        let width = bounds.width - textX - dz(10)
        let current = state == .current
        var titleColor = state == .todo ? Palette.dim : Palette.bone
        if current { titleColor = Palette.amber } else if isHovered && isClickable { titleColor = Palette.cream }
        var title = TextStyle(font: Typeface.mono(13, .medium), color: titleColor)
        if current { title.shadow = Draw.glow(Palette.amberGlow, radius: 8) }
        let titleHeight = UIZoom.scaled(13 * 1.35)
        let titleTop = dz(10) + dz(1)
        let titleWidth = Draw.text(title.string(step.title), x: textX, centerY: titleTop + titleHeight / 2, maxWidth: width)
        if current, owner?.cursorVisible ?? true {
            // `b::after{content:'_';margin-left:2px}` blinking on UITicker.
            Draw.text(title.string("_"), x: textX + titleWidth + dz(2), centerY: titleTop + titleHeight / 2)
        }
        let englishTop = titleTop + titleHeight + dz(2)
        let english = TextStyle.caps(10, current ? Palette.amberDim : Palette.dim, tracking: 0.16)
        Draw.text(english.string(step.english), x: textX, centerY: englishTop + UIZoom.scaled(15) / 2, maxWidth: width)
        let detailTop = englishTop + UIZoom.scaled(15) + dz(2)
        let detailColor: NSColor = current ? Palette.bone : (state == .done ? Palette.dim : Palette.dimmer)
        let detailStyle = TextStyle.mono(11, detailColor)
        var detailRuns: [(String, TextStyle)]
        if detail.hasPrefix("◆") {
            detailRuns = [("◆", detailStyle.with(color: Palette.amberDim)), (String(detail.dropFirst()), detailStyle)]
        } else {
            detailRuns = [(detail, detailStyle)]
        }
        Draw.text(runs(detailRuns), x: textX, centerY: detailTop + UIZoom.scaled(16.5) / 2, maxWidth: width)
    }

    private var owner: StepperView? { superview as? StepperView }

    // MARK: Input

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { isClickable && OnboardingKeyboard.isFullKeyboardAccessOn }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func mouseDown(with event: NSEvent) {
        guard isClickable else { return }
        onPress()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", isClickable { onPress() } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isClickable else { return false }
        onPress()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; if isClickable { needsDisplay = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false; if isClickable { needsDisplay = true } }

    override func resetCursorRects() {
        if isClickable { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
