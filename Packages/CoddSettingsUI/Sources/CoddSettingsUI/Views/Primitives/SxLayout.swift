import AppKit
import CoddUI

/// A row the search can find and highlight.
@MainActor
protocol SxSearchable: NSView {
    var searchText: String { get }
    var isSearchHit: Bool { get set }
}

/// A row drawn inside an `SxCard` with a dashed separator above every row but the first.
@MainActor
protocol SxSeparated: NSView {
    var showsSeparator: Bool { get set }
}

/// Target / action bridge for AppKit controls that only speak selectors.
final class ClosureTarget: NSObject {
    let handler: @MainActor () -> Void

    init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }

    @MainActor @objc func fire(_ sender: Any?) { handler() }
}

/// `.sx-gh`: caps title (an optional leading chip), CJK note, amber-dim count, the dashed rule,
/// then the dimmer right-hand note.
final class SxGroupHead: FlippedView, ZoomRefreshing {
    var title: String { didSet { needsDisplay = true } }
    var cjk: String? { didSet { needsDisplay = true } }
    var count: String? { didSet { needsDisplay = true } }
    var right: NSAttributedString? { didSet { needsDisplay = true } }
    var leadingChip: String? { didSet { needsDisplay = true } }
    var titleColor = Palette.dim { didSet { needsDisplay = true } }

    init(_ title: String, cjk: String? = nil, count: String? = nil, right: String? = nil) {
        self.title = title
        self.cjk = cjk
        self.count = count
        self.right = right.map { SxGroupHead.rightStyle.string($0) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 16).zoomed(16).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// M4 interface zoom: the right-hand note built at the old zoom is made again.
    func zoomDidChange() {
        if let right, let scaled = Typeface.rescaled(right) { self.right = scaled }
    }

    /// `.sx-gh .r`: 10.5 dimmer, .06em.
    static var rightStyle: TextStyle { TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06) }

    func setRight(_ text: String?) { right = text.map { Self.rightStyle.string($0) } }

    var plainText: String {
        [leadingChip, title, cjk, count, right?.string].compactMap { $0 }.joined(separator: " ")
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        var x: CGFloat = 0
        if let leadingChip {
            x += ChipStyle.chip(.plain, caps: true, mini: true).draw(leadingChip, x: x, centerY: mid) + xz(8)
        }
        // A narrow page (small window, zoom 20) cuts the notes with `…` at the edge, never past it.
        x += Draw.text(TextStyle.caps(10.5, titleColor, tracking: 0.18).string(title), x: x, centerY: mid,
                       maxWidth: max(0, bounds.width - x)) + xz(8)
        let countText = count.map { TextStyle.mono(10.5, Palette.amberDim).string($0) }
        let countWidth = countText.map { Draw.width($0) + xz(8) } ?? 0
        if let cjk, bounds.width - countWidth - x >= xz(24) {
            x += Draw.text(TextStyle.mono(10.5, Palette.dimmer, tracking: 0.06).string(cjk), x: x, centerY: mid,
                           maxWidth: bounds.width - countWidth - x) + xz(8)
        }
        if let countText { x += Draw.text(countText, x: x, centerY: mid) + xz(8) }
        var end = bounds.width
        if let right, right.length > 0 {
            end -= Draw.width(right)
            Draw.text(right, x: end, centerY: mid)
            end -= xz(8)
        }
        if end > x { Draw.dashedLine(from: CGPoint(x: x, y: round(mid)), to: CGPoint(x: end, y: round(mid)), color: Palette.lineBright) }
        setAccessibilityValue(plainText)
    }
}

/// `.sx-card`: bg-soft with a 1 px line-bright border (`danger`: dashed, danger at 45 %); its
/// rows stack with dashed separators between them.
final class SxCard: FlippedView {
    let stack = columnStack([], spacing: 0)
    var danger = false { didSet { needsDisplay = true } }
    var fill = Palette.bgSoft { didSet { needsDisplay = true } }
    private(set) var rows: [NSView] = []

    init(_ rows: [NSView] = [], danger: Bool = false) {
        self.danger = danger
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        set(rows)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ rows: [NSView]) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for (index, row) in rows.enumerated() {
            (row as? SxSeparated)?.showsSeparator = index > 0
            stack.addFullWidth(row)
        }
        self.rows = rows
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, fill)
        if danger {
            Draw.dashedRect(bounds, color: Palette.danger.withAlphaComponent(0.45))
        } else {
            Draw.strokeRect(bounds, color: Palette.lineBright)
        }
    }
}

/// `.sx-row` (and `.tight`): name + EN + chips, hint and note lines on the left; the controls at
/// the right, vertically centered; a dashed separator above. Later-milestone rows (`milestone`,
/// D17) draw at 55 % with the chip and their controls ignore input; search hits get the
/// `.srow.sel` look (amber-dim outline, amber 6 % fill).
final class SxRow: FlippedView, SxSearchable, SxSeparated {
    let key: String
    let title: String
    let milestone: String?
    let controls: [NSView]
    private(set) var searchText: String
    var isSearchHit = false { didSet { if isSearchHit != oldValue { needsDisplay = true } } }
    var showsSeparator = false { didSet { if showsSeparator != oldValue { needsDisplay = true } } }
    let labelColumn: NSStackView
    private let hintLabel: SxLabel?
    private var notes: [String: SxLabel] = [:]
    /// The name and the caps EN label after it: a narrow row hides the EN label (never clips it).
    private var nameLabel: SxLabel?
    private var englishLabel: SxLabel?
    /// The controls' stack and the constraints of the two arrangements (beside / under the labels).
    private var controlStack: NSStackView?
    private var sideBySide: [NSLayoutConstraint] = []
    private var stacked: [NSLayoutConstraint] = []
    private var padH: CGFloat = 0
    private var gap: CGFloat = 0

    /// - Parameters:
    ///   - name: the `.sx-name` text (with `code` pieces); `en` the caps label after it.
    ///   - chips: views after the EN label (`實驗`, `! 與預設不同`).
    ///   - extra: views between the name line and the hint (a `.path` line).
    ///   - keywords: more text the search should find in this row (option titles).
    init(key: String, name: SxRich, en: String? = nil, hint: SxRich? = nil, leading: [NSView] = [], chips: [NSView] = [],
         extra: [NSView] = [], controls: [NSView] = [], tight: Bool = false, milestone: String? = nil, labelGap: CGFloat = 2,
         keywords: [String] = [], inColumn: Bool = false) {
        self.key = key
        title = name.plain
        self.milestone = milestone
        self.controls = controls
        let leadingText = leading.compactMap { ($0 as? NSTextField)?.stringValue }
        searchText = (leadingText + [name.plain, en, hint?.plain].compactMap { $0 } + keywords).joined(separator: " ")
        let nameView = SxLabel(name.attributed(SxStyle.name, lineBreak: .byTruncatingTail), wraps: false)
        var nameViews: [NSView] = leading + [nameView]
        var englishView: SxLabel?
        if let en, !en.isEmpty {
            let label = SxLabel(SxRich(en).attributed(SxStyle.english, lineBreak: .byClipping), wraps: false)
            // Below the window's stay-put priority: `layout()` hides it where it does not fit whole.
            label.setContentCompressionResistancePriority(RowFit.optionalCompression, for: .horizontal)
            nameViews.append(label)
            englishView = label
        }
        nameViews += chips
        if let milestone { nameViews.append(ChipView(milestone, style: .milestone)) }
        // A trailing spacer takes any width the column gives the line, so the EN label and the
        // chips stay right after the name.
        nameViews.append(spacer())
        let nameLine = hStack(nameViews, spacing: 8)
        // The name line keeps its own width (the EN label right after the name, never spread).
        nameLine.setHuggingPriority(.defaultHigh, for: .horizontal)
        nameLine.heightAnchor.constraint(greaterThanOrEqualToConstant: 18).isActive = true
        if let hint {
            hintLabel = SxLabel(hint.attributed(SxStyle.hint, lineHeight: SxStyle.hintLineHeight))
        } else {
            hintLabel = nil
        }
        labelColumn = vStack([nameLine] + extra + [hintLabel].compactMap { $0 }, spacing: labelGap)
        super.init(frame: .zero)
        nameLabel = nameView
        englishLabel = englishView
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // `.sx-2col .sx-row{gap:14px;padding:8px 14px;min-height:50px}` for the CLEANUP columns.
        let padV: CGFloat = inColumn ? xz(8) : (tight ? xz(6) : xz(9))
        let padH: CGFloat = inColumn ? xz(14) : xz(16)
        let gap: CGFloat = inColumn ? xz(14) : xz(24)
        let minHeight: CGFloat = inColumn ? xz(50) : (tight ? xz(42) : xz(52))
        labelColumn.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelColumn)
        for view in [nameLine] + extra + [hintLabel].compactMap({ $0 }) as [NSView] {
            view.widthAnchor.constraint(lessThanOrEqualTo: labelColumn.widthAnchor).isActive = true
        }
        hintLabel?.widthAnchor.constraint(equalTo: labelColumn.widthAnchor).isActive = true
        // `.path` lines are `display:block`: as wide as the label column.
        for view in extra { view.widthAnchor.constraint(equalTo: labelColumn.widthAnchor).isActive = true }
        var constraints = [
            labelColumn.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padH),
            labelColumn.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: padV),
            labelColumn.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padV),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight),
        ]
        let hug = heightAnchor.constraint(equalToConstant: minHeight)
        hug.priority = .defaultLow
        constraints.append(hug)
        let centered = labelColumn.centerYAnchor.constraint(equalTo: centerYAnchor)
        if controls.isEmpty {
            let fill = labelColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padH)
            constraints += [fill, centered]
        } else {
            // The label column takes the rest of the row (`minmax(0,1fr) auto`): the controls keep
            // their own width and never stretch.
            for control in controls where !(control is SxFlowView) {
                control.setContentHuggingPriority(.required, for: .horizontal)
            }
            let controlStack = hStack(controls, spacing: 8)
            controlStack.setHuggingPriority(.required, for: .horizontal)
            controlStack.setContentCompressionResistancePriority(.required, for: .horizontal)
            controlStack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(controlStack)
            self.controlStack = controlStack
            constraints += [
                controlStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: padV),
                controlStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -padV),
            ]
            let fill = labelColumn.trailingAnchor.constraint(equalTo: controlStack.leadingAnchor, constant: -gap)
            fill.priority = .defaultHigh
            sideBySide = [
                centered,
                controlStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padH),
                controlStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                labelColumn.trailingAnchor.constraint(lessThanOrEqualTo: controlStack.leadingAnchor, constant: -gap),
                fill,
            ]
            // A narrow row (small window, zoom 20): the controls go under the label column, at its
            // leading edge, instead of squeezing the name and the hint into a sliver.
            stacked = [
                labelColumn.topAnchor.constraint(equalTo: topAnchor, constant: padV),
                labelColumn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padH),
                controlStack.topAnchor.constraint(equalTo: labelColumn.bottomAnchor, constant: xz(8)),
                controlStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padH),
                controlStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padH),
            ]
            constraints += sideBySide
        }
        self.padH = padH
        self.gap = gap
        NSLayoutConstraint.activate(constraints)
        if let milestone {
            alphaValue = 0.55
            for control in controls { SxRow.disable(control) }
            setAccessibilityHelp("\(milestone) 提供")
        }
        setAccessibilityElement(false)
    }

    /// A narrow row (small window, zoom): the controls move under the label column when the
    /// label column would get narrower than `minimumLabelWidth`, and the caps EN label shows
    /// only whole, after the name. Both only depend on the row's width (no flicker while dragging).
    override func layout() {
        if controlStack != nil, bounds.width > 0 {
            let stack = SxRow.stacks(rowWidth: bounds.width, padding: padH, gap: gap, controls: controlsWidth,
                                     minimumLabel: minimumLabelWidth)
            if stack != isStacked {
                isStacked = stack
                NSLayoutConstraint.deactivate(stack ? sideBySide : stacked)
                NSLayoutConstraint.activate(stack ? stacked : sideBySide)
            }
        }
        super.layout()
        guard let englishLabel, let nameLabel else { return }
        let needed = nameLabel.intrinsicContentSize.width + xz(8) + englishLabel.intrinsicContentSize.width
        let fits = labelColumn.frame.width >= needed
        if englishLabel.isHidden == fits {
            englishLabel.isHidden = !fits
            needsLayout = true
        }
    }

    /// Whether a row of `rowWidth` puts its controls (`controls` wide) under the label column:
    /// side by side would leave the label column less than `minimumLabel`.
    static func stacks(rowWidth: CGFloat, padding: CGFloat, gap: CGFloat, controls: CGFloat, minimumLabel: CGFloat) -> Bool {
        rowWidth - 2 * padding - gap - controls < minimumLabel
    }

    /// The controls' one-line width (a chip flow counts its widest chip: it wraps).
    private var controlsWidth: CGFloat {
        let widths = controls.filter { !$0.isHidden }.map { control -> CGFloat in
            if let flow = control as? SxFlowView {
                return flow.items.map { $0.intrinsicContentSize.width }.max() ?? 0
            }
            let width = control.intrinsicContentSize.width
            return width == NSView.noIntrinsicMetric ? control.fittingSize.width : width
        }
        return widths.reduce(0, +) + 8 * CGFloat(max(0, widths.count - 1))
    }

    /// The narrowest label column worth keeping beside the controls: a hint wraps into a sliver
    /// below `xz(160)`; a name-only row needs its name (up to that).
    private var minimumLabelWidth: CGFloat {
        let limit = xz(160)
        guard hintLabel == nil, let nameLabel else { return limit }
        return min(limit, nameLabel.intrinsicContentSize.width)
    }

    /// The controls sit under the label column (tests).
    private(set) var isStacked = false

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var isDisabledRow: Bool { milestone != nil }

    /// The hint as shown (tests).
    var hintText: String? { hintLabel?.text }

    func setHint(_ hint: SxRich) {
        hintLabel?.set(hint.attributed(SxStyle.hint, lineHeight: SxStyle.hintLineHeight))
    }

    /// An extra line under the hint (login item status, a refusal); nil removes it.
    func setNote(_ id: String, _ text: String?, color: NSColor = Palette.amber) {
        if let text, !text.isEmpty {
            let attributed = SxRich(text).attributed(TextStyle.mono(11, color), lineHeight: 16)
            if let label = notes[id] {
                label.set(attributed)
            } else {
                let label = SxLabel(attributed)
                notes[id] = label
                labelColumn.addArrangedSubview(label)
                label.widthAnchor.constraint(equalTo: labelColumn.widthAnchor).isActive = true
            }
        } else if let label = notes.removeValue(forKey: id) {
            label.removeFromSuperview()
        }
    }

    func note(_ id: String) -> String? { notes[id]?.text }

    /// Disables a control inside a dimmed row without dimming it a second time (the row is at 55 %).
    static func disable(_ view: NSView) {
        switch view {
        case let toggle as SwitchToggle:
            toggle.isEnabled = false
            toggle.alphaValue = 1
        case let select as SelectButton:
            select.isEnabled = false
            select.isDimmed = false
        case let input as SxTextInput:
            input.isEnabled = false
        case let seg as SxSegmented:
            seg.isEnabled = false
        case let checkbox as SxCheckbox:
            checkbox.isEnabled = false
        case let stepper as SxStepper:
            stepper.isEnabled = false
        case let button as CoddButton:
            button.isEnabled = false
        case let recorder as HotkeyRecorderView:
            recorder.isEnabled = false
        case let button as SxStaticButton:
            button.isDisabledLook = true
        case let box as RegistrationsBox:
            box.isDisabledLook = true
        default:
            for sub in view.subviews { disable(sub) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSearchHit {
            Draw.fill(bounds, Palette.amber.withAlphaComponent(0.06))
            Draw.strokeRect(bounds, color: Palette.amberDim)
        }
        if showsSeparator { Draw.dashedLine(from: .zero, to: CGPoint(x: bounds.width, y: 0), color: Palette.lineBright) }
    }
}

/// `.sx-ph`: the `.h-page` title, the CJK name, optional marks (REMOTE's `FUTURE`), the head
/// buttons at the right, and the lead.
final class SxPageHead: FlippedView {
    private let heading: SxLabel
    private let zhLabel: SxLabel
    private let marks: [NSView]
    private let actions: [NSView]
    private let titleLine: NSStackView
    /// The head buttons on a line of their own, under the title (a narrow page).
    private let actionsLine: NSStackView
    /// The head buttons sit under the title (tests).
    private(set) var wrapsActions = false

    init(title: String, zh: String, marks: [NSView] = [], actions: [NSView] = [], lead: SxRich) {
        // A narrow page (small window, zoom) hides the 中文 title first, then moves the head
        // buttons under the title; only a page narrower than the title alone truncates it (`…`).
        // Both labels stay below the window's stay-put priority, the actions keep theirs.
        heading = SxLabel(SxRich(title).attributed(TextStyle.pageTitle, lineBreak: .byTruncatingTail), wraps: false)
        heading.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        heading.setAccessibilityRole(.staticText)
        heading.setAccessibilityLabel(title)
        zhLabel = SxLabel(SxRich(zh).attributed(SxStyle.pageZh, lineBreak: .byClipping), wraps: false)
        zhLabel.setContentCompressionResistancePriority(RowFit.optionalCompression, for: .horizontal)
        self.marks = marks
        self.actions = actions
        titleLine = hStack([heading, zhLabel] + marks + [spacer()] + actions, spacing: xz(12))
        actionsLine = hStack([], spacing: xz(12))
        super.init(frame: .zero)
        titleLine.heightAnchor.constraint(greaterThanOrEqualToConstant: xz(32)).isActive = true
        actionsLine.isHidden = true
        let leadLabel = SxLabel(lead.attributed(SxStyle.lead, lineHeight: 18))
        let column = columnStack([titleLine, actionsLine, leadLabel], spacing: xz(6))
        addSubview(column)
        column.pinEdges(to: self)
    }

    /// Whether a head `width` wide puts its buttons under the title: beside it they would cut
    /// the title (the 中文 name is dropped first).
    static func wrapsActions(width: CGFloat, heading: CGFloat, marks: CGFloat, actions: CGFloat) -> Bool {
        actions > 0 && width < heading + marks + actions
    }

    override func layout() {
        let gap = xz(12)
        let marksWidth = marks.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width + gap }
        let actionsWidth = actions.reduce(CGFloat(0)) { $0 + $1.intrinsicContentSize.width + gap }
        // (Every count includes the gap before the spacer that pushes the buttons to the right.)
        let wraps = Self.wrapsActions(width: bounds.width, heading: heading.intrinsicContentSize.width + gap, marks: marksWidth,
                                      actions: actionsWidth)
        if wraps != wrapsActions {
            wrapsActions = wraps
            for view in actions {
                view.removeFromSuperview()
                (wraps ? actionsLine : titleLine).addArrangedSubview(view)
            }
            actionsLine.isHidden = !wraps
        }
        let fits = bounds.width >= heading.intrinsicContentSize.width + gap + zhLabel.intrinsicContentSize.width + gap + marksWidth
            + (wraps ? 0 : actionsWidth)
        if zhLabel.isHidden == fits {
            zhLabel.isHidden = !fits
        }
        super.layout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// `.sx-grp`: a group head and its body (a card, an info box, a flow), 8 apart.
@MainActor
func sxGroup(_ head: SxGroupHead, _ body: [NSView]) -> NSStackView {
    columnStack([head] + body, spacing: xz(8))
}

/// `.sx-info`: dashed line-bright border on --bg (REMOTE: on --bg-soft), padding 10 / 14, lines 6
/// apart in 11.5 dim.
final class SxInfoBox: FlippedView {
    let stack = columnStack([], spacing: 6)
    var fill = Palette.bg { didSet { needsDisplay = true } }

    init(_ lines: [NSView] = []) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addSubview(stack)
        stack.pinEdges(to: self, insets: NSEdgeInsets(top: xz(10), left: xz(14), bottom: xz(10), right: xz(14)))
        set(lines)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ lines: [NSView]) {
        for view in stack.arrangedSubviews { view.removeFromSuperview() }
        for line in lines { stack.addFullWidth(line) }
    }

    var lineTexts: [String] {
        stack.arrangedSubviews.map { view in
            if let label = view as? NSTextField { return label.stringValue }
            return view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ")
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, fill)
        Draw.dashedRect(bounds, color: Palette.lineBright)
    }
}

/// Lays out fixed-size children left to right, wrapping (`flex-wrap`, gap 6), aligned leading
/// (`.sx-chips`) or trailing (`.sx-gchips`). Its height follows the width it gets (the second
/// layout pass), its intrinsic width is the one-line width.
final class SxFlowView: FlippedView {
    /// Design points (laid out at the interface zoom).
    var gap: CGFloat = 6 { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    private var spacing: CGFloat { xz(gap) }
    var trailing = false { didSet { needsLayout = true } }
    var insets = NSEdgeInsets() { didSet { invalidateIntrinsicContentSize(); needsLayout = true } }
    private(set) var items: [NSView] = []
    private var laidOutWidth: CGFloat = -1
    private var height: CGFloat = 0

    init(_ items: [NSView] = []) {
        super.init(frame: .zero)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        set(items)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ items: [NSView]) {
        for item in self.items { item.removeFromSuperview() }
        self.items = items
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = true
            addSubview(item)
        }
        laidOutWidth = -1
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func size(of item: NSView) -> NSSize {
        let size = item.intrinsicContentSize
        return NSSize(width: max(0, size.width == NSView.noIntrinsicMetric ? item.fittingSize.width : size.width),
                      height: max(0, size.height == NSView.noIntrinsicMetric ? item.fittingSize.height : size.height))
    }

    /// One-line width (all items in a row).
    var naturalWidth: CGFloat {
        let widths = items.map { size(of: $0).width }
        return widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1)) + insets.left + insets.right
    }

    /// Frames for `width` (flipped coordinates) and the total height.
    func frames(for width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        let available = max(1, width - insets.left - insets.right)
        var lines: [[(NSView, NSSize)]] = [[]]
        var lineWidth: CGFloat = 0
        for item in items {
            let size = size(of: item)
            let needed = lines[lines.count - 1].isEmpty ? size.width : lineWidth + spacing + size.width
            if needed > available, !lines[lines.count - 1].isEmpty {
                lines.append([(item, size)])
                lineWidth = size.width
            } else {
                lines[lines.count - 1].append((item, size))
                lineWidth = needed
            }
        }
        var frames: [CGRect] = []
        var y = insets.top
        for line in lines where !line.isEmpty {
            let lineHeight = line.map(\.1.height).max() ?? 0
            let total = line.map(\.1.width).reduce(0, +) + spacing * CGFloat(line.count - 1)
            var x = trailing ? insets.left + available - total : insets.left
            for (_, size) in line {
                frames.append(CGRect(x: round(x), y: round(y + (lineHeight - size.height) / 2), width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += lineHeight + spacing
        }
        let height = items.isEmpty ? insets.top + insets.bottom : y - spacing + insets.bottom
        return (frames, height)
    }

    override var intrinsicContentSize: NSSize {
        let width = laidOutWidth > 0 ? laidOutWidth : naturalWidth
        return NSSize(width: naturalWidth, height: frames(for: width).height)
    }

    override func layout() {
        super.layout()
        let result = frames(for: bounds.width)
        for (item, frame) in zip(items, result.frames) where item.frame != frame { item.frame = frame }
        if bounds.width != laidOutWidth {
            laidOutWidth = bounds.width
            if abs(result.height - height) > 0.5 {
                height = result.height
                invalidateIntrinsicContentSize()
            }
        }
    }
}
