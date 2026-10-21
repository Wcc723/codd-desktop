import AppKit
import CoddUI

/// A design length at the interface zoom (``UIZoom/pt(_:)``): the dialogs' hand-laid rows,
/// cards and lines.
@inline(__always)
func dz(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

// Internal building blocks of the dialogs that CoddUI does not have (listed in the C8 report so
// integration can move them): StatusDialogs `.sd-*` classes and the flat `.srow`.

/// Shared text styles of the StatusDialogs artboard.
@MainActor
enum DialogText {
    /// `.sd-q`: Space Mono 700 17 px cream (CJK falls back to PingFang through the cascade).
    static var question: TextStyle { TextStyle(font: Typeface.display(17), color: Palette.cream, tracking: 0.01) }
    /// `.hint` (CoddUI preset).
    static var hint: TextStyle { TextStyle.hint }
    /// `.sec` (CoddUI preset).
    static var section: TextStyle { TextStyle.sectionLabel }
    /// `.lbl` (CoddUI preset).
    static var label: TextStyle { TextStyle.fieldLabel }
    /// `.sd-list li`: 12.5 bone.
    static var listItem: TextStyle { TextStyle.mono(12.5, Palette.bone) }
    /// `.sd-list b`, `.sd-kv b`, `.sd-detect b`: weight 600 cream.
    static func bold(_ size: CGFloat) -> TextStyle { TextStyle.mono(size, Palette.cream, .semibold) }

    /// An error line: `[ERROR]` in danger, then the message in cream (SPEC voice).
    static func error(_ message: String) -> NSAttributedString {
        runs([("[ERROR] ", TextStyle.mono(12, Palette.danger, .semibold)), (message, TextStyle.mono(12, Palette.cream))])
    }

    /// Concatenates styled runs into one attributed string.
    static func runs(_ parts: [(String, TextStyle)], lineBreak: NSLineBreakMode = .byWordWrapping) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, style) in parts { result.append(style.string(text, lineBreak: lineBreak)) }
        return result
    }
}

/// Chip styles of the dialogs (CoddUI's `.chip` presets).
@MainActor
enum DialogChipStyle {
    static func style(_ kind: ChipKind, caps: Bool = false) -> ChipStyle { ChipStyle.chip(kind, caps: caps) }

    static func style(_ chip: DialogChip) -> ChipStyle { style(chip.kind, caps: chip.caps) }

    /// A chip inside `.m-h`: it inherits the header's Space Mono 700; `.sd-nt` resets the case
    /// and sets .04em (`cswap 0.26.0`, `+9`, `−1`).
    static func header(_ kind: ChipKind) -> ChipStyle {
        var chip = style(kind)
        chip.text = TextStyle(font: Typeface.display(11), color: chip.text.color, tracking: 0.04)
        return chip
    }

    /// `.sd-q code`: mono 13.5 amber on #050505, 1 px #1a1a1a border, padding 1 / 6 (+1 for the
    /// border drawn inside the chip, as CoddUI's presets do).
    static var questionCode: ChipStyle {
        ChipStyle(text: TextStyle.mono(13.5, Palette.amber), border: Palette.line, fill: Palette.bg, height: 22, padding: 7)
    }

    /// `code` inside wrapping text (`claude /login`): 12 px amber; its box (#050505, 1 px border)
    /// is not drawn inside a wrapping label.
    static var inlineCode: TextStyle { TextStyle.mono(12, Palette.amber) }

    static func style(_ kind: DiffChipKind) -> ChipStyle {
        switch kind {
        case .added: style(.ok)
        case .removed: style(.bad)
        case .neutral: style(.plain)
        }
    }
}

/// A multi-line label whose attributed text wraps at the width the layout gives it.
final class RichWrappingLabel: NSTextField {
    init(_ text: NSAttributedString = NSAttributedString()) {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
        attributedStringValue = text
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Replaces the text only when it differs (no relayout for an identical model).
    func set(_ text: NSAttributedString) {
        if attributedStringValue != text { attributedStringValue = text }
    }

    override func layout() {
        super.layout()
        if preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// `.sd-list`: `▸` glyph (12 px wide, amber-dim, or dimmer when faint) + wrapping text, gap 6.
final class DialogListView: NSStackView {
    struct Item: Equatable {
        var text: NSAttributedString
        var faint = false
    }

    private(set) var items: [Item] = []

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = dz(6)
        setHuggingPriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ next: [Item]) {
        guard next != items else { return }
        items = next
        for view in arrangedSubviews { removeArrangedSubview(view); view.removeFromSuperview() }
        for item in next {
            let glyph = NSTextField(labelWithAttributedString: TextStyle.mono(12.5, item.faint ? Palette.dimmer : Palette.amberDim).string("▸"))
            glyph.translatesAutoresizingMaskIntoConstraints = false
            glyph.widthAnchor.constraint(equalToConstant: 12).zoomed(12).isActive = true
            glyph.setContentHuggingPriority(.required, for: .horizontal)
            glyph.setAccessibilityElement(false)
            let text = RichWrappingLabel(item.text)
            let row = NSStackView(views: [glyph, text])
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = dz(8)
            row.setHuggingPriority(.defaultLow, for: .horizontal)
            addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
    }

    /// The items' plain text (tests).
    var texts: [String] { items.map(\.text.string) }
}

/// A status box (`.sd-prog`: dashed line-bright border on #050505; the error variant uses a
/// danger border and tint): a lamp glyph and a wrapping text, padding 7 / 10, gap 8.
final class StatusLineBox: FlippedView {
    enum Kind { case progress, error }

    private let lamp = NSTextField(labelWithString: "")
    private let label = RichWrappingLabel()
    private var kind: Kind
    private var pulsing = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        lamp.wantsLayer = true
        lamp.setAccessibilityElement(false)
        lamp.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lamp)
        addSubview(label)
        lamp.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            lamp.leadingAnchor.constraint(equalTo: leadingAnchor, constant: dz(10)),
            lamp.widthAnchor.constraint(equalToConstant: 12).zoomed(12),
            lamp.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            label.leadingAnchor.constraint(equalTo: lamp.trailingAnchor, constant: dz(8)),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -dz(10)),
            label.topAnchor.constraint(equalTo: topAnchor, constant: dz(7)),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -dz(7)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        applyKind()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func applyKind() {
        switch kind {
        case .progress:
            lamp.attributedStringValue = TextStyle.mono(11, Palette.bone).string("◌")
        case .error:
            lamp.attributedStringValue = TextStyle.mono(11, Palette.danger).string("▲")
        }
        needsDisplay = true
    }

    /// The box's text as drawn (tests, accessibility).
    var text: String { label.attributedStringValue.string }

    func set(_ text: NSAttributedString) {
        label.set(text)
        setAccessibilityLabel(text.string)
    }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .progress:
            Draw.fill(bounds, Palette.bg)
            Draw.dashedRect(bounds, color: Palette.lineBright)
        case .error:
            Draw.fill(bounds, Palette.danger.withAlphaComponent(0.06))
            Draw.strokeRect(bounds, color: Palette.danger.withAlphaComponent(0.45))
        }
    }

    // `.lamp.st-starting`: a soft 1.2 s blink run by Core Animation (no main-thread timer);
    // off while the system asks for reduced motion.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePulse()
    }

    override func viewDidHide() { super.viewDidHide(); updatePulse() }
    override func viewDidUnhide() { super.viewDidUnhide(); updatePulse() }

    private func updatePulse() {
        let want = kind == .progress && window != nil && !isHiddenOrHasHiddenAncestor && UITicker.shared.pulsesAllowed
        guard want != pulsing, let layer = lamp.layer else { return }
        pulsing = want
        if want {
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1
            blink.toValue = 0.35
            blink.duration = 0.6
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(blink, forKey: "codd-soft")
        } else {
            layer.removeAnimation(forKey: "codd-soft")
        }
    }
}

/// `.srow.flat` in the quit dialog's NEEDS YOU panel: 38 pt, 2 pt left bar and tint in the state
/// color, lamp · tag · title · pill on line 1, `3m · location` on line 2 (the duration ticks).
final class DialogSessionRowView: FlippedView {
    private(set) var row: DialogSessionRow
    private let line2 = Line2View()

    init(_ row: DialogSessionRow, now: Date) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(line2)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        line2.color = row.color
        tick(now: now)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static var height: CGFloat { dz(38) }
    /// Left bar (2) + `.srow.flat` padding (10).
    private static var contentLeft: CGFloat { dz(12) }

    func update(_ next: DialogSessionRow, now: Date) {
        guard next != row else { return }
        row = next
        line2.color = next.color
        needsDisplay = true
        tick(now: now)
    }

    /// Redraws only line 2 when its duration text changed.
    func tick(now: Date) {
        let text = DurationFormat.compact(now.timeIntervalSince(row.since))
        line2.set(duration: text, location: row.location)
        setAccessibilityLabel("\(row.title) · \(row.pill) · \(text) · \(row.location)")
    }

    /// Line 2 as drawn (tests).
    var line2Text: String { line2.text }

    override func layout() {
        super.layout()
        let x = Self.contentLeft + dz(19)
        line2.frame = CGRect(x: x, y: dz(22), width: max(0, bounds.width - dz(8) - x), height: dz(14))
    }

    override func draw(_ dirtyRect: NSRect) {
        let strong: CGFloat = row.pillFilled ? 0.09 : 0.08
        let weak: CGFloat = row.pillFilled ? 0.02 : 0.015
        Draw.hGradient(bounds, from: row.color.withAlphaComponent(strong), to: row.color.withAlphaComponent(weak))
        Draw.fill(CGRect(x: 0, y: 0, width: dz(2), height: bounds.height), row.color)
        let l1: CGFloat = dz(14)
        var x = Self.contentLeft
        let glyph = TextStyle.mono(row.pillFilled ? 12 : 11, row.color).string(row.glyph)
        Draw.text(glyph, x: x + (dz(12) - Draw.width(glyph)) / 2, centerY: l1)
        x += dz(12) + dz(7)
        if let tag = row.tag {
            Draw.fill(CGRect(x: x, y: l1 - dz(4), width: dz(8), height: dz(8)), tag)
            x += dz(8) + dz(7)
        }
        let pillStyle = Self.pillStyle(color: row.color, filled: row.pillFilled)
        let pillWidth = pillStyle.size(for: row.pill).width
        let right = bounds.width - dz(8)
        pillStyle.draw(row.pill, x: right - pillWidth, centerY: l1)
        let titleColor = row.pillFilled ? Palette.cream : Palette.bone
        Draw.text(TextStyle.mono(12.5, titleColor).string(row.title), x: x, centerY: l1, maxWidth: max(0, right - pillWidth - dz(7) - x))
    }

    /// `.state` 9.5 caps .14em, 15 pt; waiting = solid fill with black bold text.
    static func pillStyle(color: NSColor, filled: Bool) -> ChipStyle {
        if filled {
            return ChipStyle(text: TextStyle.caps(9.5, .black, tracking: 0.14, .bold), border: nil, fill: color, height: 15, padding: 5)
        }
        return ChipStyle(text: TextStyle.caps(9.5, color, tracking: 0.14, .medium), border: color, fill: nil, height: 15, padding: 5)
    }

    /// `.l2`: the duration in the state color, ` · `, the location in dimmer (10.5).
    private final class Line2View: FlippedView {
        var color: NSColor = Palette.dimmer { didSet { needsDisplay = true } }
        private var duration = ""
        private var location = ""

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        var text: String { "\(duration) · \(location)" }

        func set(duration: String, location: String) {
            guard duration != self.duration || location != self.location else { return }
            self.duration = duration
            self.location = location
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            var x: CGFloat = 0
            let mid = bounds.midY
            x += Draw.text(TextStyle.mono(10.5, color).string(duration), x: x, centerY: mid) + dz(6)
            x += Draw.text(TextStyle.mono(10.5, Palette.dimmer).string("·"), x: x, centerY: mid) + dz(6)
            Draw.text(TextStyle.mono(10.5, Palette.dimmer).string(location), x: x, centerY: mid, maxWidth: max(0, bounds.width - x))
        }
    }
}

/// `.sd-step`: a 22 pt numbered box on a dashed rail (`done` ✓ green, `cur` amber fill with its
/// glow, pending dim), then the step body (title + controls) 12 pt to the right. The title is
/// cream, bone once done (`.sd-step.done .sd-st`).
final class StepView: FlippedView {
    enum State: Equatable { case done, current, pending }

    let number: Int
    let isLast: Bool
    var state: State = .pending {
        didSet {
            guard state != oldValue else { return }
            badge.state = state
            title.set(titleText(state == .done ? Palette.bone : Palette.cream))
            setAccessibilityValue(Self.accessibilityText(state))
        }
    }
    let body: NSStackView
    let title: RichWrappingLabel
    private let titleText: (NSColor) -> NSAttributedString
    private let badge: StepBadgeView

    /// - Parameter title: the title in a given text color (inline code keeps its amber).
    init(number: Int, isLast: Bool, title: @escaping (NSColor) -> NSAttributedString) {
        self.number = number
        self.isLast = isLast
        titleText = title
        self.title = RichWrappingLabel(title(Palette.cream))
        badge = StepBadgeView(number: number)
        body = NSStackView()
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(badge)
        badge.frame = CGRect(x: 0, y: 0, width: dz(22), height: dz(22))
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 7
        body.setHuggingPriority(.defaultLow, for: .horizontal)
        body.addArrangedSubview(self.title)
        self.title.translatesAutoresizingMaskIntoConstraints = false
        self.title.trailingAnchor.constraint(equalTo: body.trailingAnchor).isActive = true
        addSubview(body)
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: dz(22) + dz(12)),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor, constant: dz(2)),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: isLast ? 0 : -dz(16)),
            heightAnchor.constraint(greaterThanOrEqualToConstant: dz(22)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("步驟 \(number)")
        setAccessibilityValue(Self.accessibilityText(state))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    static func accessibilityText(_ state: State) -> String {
        switch state {
        case .done: "已完成"
        case .current: "進行中"
        case .pending: "未開始"
        }
    }

    /// Adds a control row to the body, full width.
    func addBody(_ view: NSView, fullWidth: Bool = false) {
        body.addArrangedSubview(view)
        if fullWidth {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor).isActive = true
        }
    }

    /// `.sd-rail::after`: 1 px dashed line-bright from 4 pt under the box to 4 pt above the step's end.
    override func draw(_ dirtyRect: NSRect) {
        guard !isLast, bounds.height > dz(22) + dz(8) else { return }
        let path = NSBezierPath()
        path.move(to: CGPoint(x: dz(11.5), y: dz(26)))
        path.line(to: CGPoint(x: dz(11.5), y: bounds.height - dz(4)))
        path.lineWidth = 1
        path.setLineDash([3, 2], count: 2, phase: 0)
        Palette.lineBright.setStroke()
        path.stroke()
    }
}

/// `.sd-n`: the step's 22 pt box. The current step's `box-shadow: 0 0 10px var(--amber-glow)` is
/// the view's layer shadow (blurred by the render server, outside the box).
final class StepBadgeView: FlippedView {
    let number: Int
    var state: StepView.State = .pending {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
            shadow = state == .current ? Draw.glow(Palette.amberGlow, radius: 10) : nil
        }
    }

    init(number: Int) {
        self.number = number
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds
        switch state {
        case .done:
            Draw.fill(box, Palette.bgSoft)
            Draw.strokeRect(box, color: Palette.success.withAlphaComponent(0.45))
            let mark = TextStyle.mono(11, Palette.success, .bold).string("✓")
            Draw.text(mark, x: box.midX - Draw.width(mark) / 2, centerY: box.midY)
        case .current:
            Draw.fill(box, Palette.amber)
            let digit = TextStyle.mono(11, .black, .bold).string("\(number)")
            Draw.text(digit, x: box.midX - Draw.width(digit) / 2, centerY: box.midY)
        case .pending:
            Draw.fill(box, Palette.bgSoft)
            Draw.strokeRect(box, color: Palette.lineBright)
            let digit = TextStyle.mono(11, Palette.dim, .bold).string("\(number)")
            Draw.text(digit, x: box.midX - Draw.width(digit) / 2, centerY: box.midY)
        }
    }
}
