import AppKit
import CoddUI

/// HOST: `HOST studio-mbp · 曲線為最近 10 分鐘 ┄┄ [● 正常]` and the metric grid
/// (`.sx-host`: columns 1.45fr 1.45fr 1fr 1fr 1fr, gap 10; CPU and MEM span two rows).
final class HostSectionView: FlippedView {
    private let header = SectionHeaderRow(title: "Host")
    private let hint = TextLine(style: TextStyle.hint)
    private let chip = ChipLabel("", style: StatusChips.caps(.ok))
    private(set) var cards: [HostCardModel.Kind: HostCardView] = [:]
    private(set) var model: HostSectionModel?
    /// Section rebuilds (tests: an unchanged model must not rebuild).
    private(set) var configureCount = 0

    /// The artboard's columns; a page narrower than `narrowWidth` (the main pane can shrink to
    /// 560 pt) uses three equal ones so the cards keep a readable width, then two and one on a
    /// still narrower page (a small window at a large interface zoom).
    static let columns: [CGFloat] = [1.45, 1.45, 1, 1, 1]
    static let narrowColumns: [CGFloat] = [1, 1, 1]
    static var narrowWidth: CGFloat { sz(900) }
    static var twoColumnWidth: CGFloat { sz(460) }
    static var oneColumnWidth: CGFloat { sz(300) }

    static func columns(forWidth width: CGFloat) -> [CGFloat] {
        if width >= narrowWidth { return columns }
        if width >= twoColumnWidth { return narrowColumns }
        return width >= oneColumnWidth ? [1, 1] : [1]
    }
    static var gap: CGFloat { sz(10) }
    /// Small card height (two rows + the gap make a tall card: 98 · 2 + 10 = 206, artboard 205.4).
    static var rowHeight: CGFloat { sz(98) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        header.setLeading([hint])
        header.shrinkingLeading = [ObjectIdentifier(hint)]
        header.setTrailing([chip])
        addSubview(header)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("HOST 主機")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ model: HostSectionModel) {
        guard model != self.model else { return }
        configureCount += 1
        self.model = model
        hint.set("\(model.name) · \(HostSectionModel.historyHint)", style: TextStyle.hint)
        chip.set(model.healthy ? "● 正常" : "◆ 注意", style: StatusChips.caps(model.healthy ? .ok : .amber))
        // The hint and the chip changed width: the header row places them again (its frame may not change).
        header.needsLayout = true
        let kinds = Set(model.cards.map(\.kind))
        for (kind, view) in cards where !kinds.contains(kind) {
            view.removeFromSuperview()
            cards[kind] = nil
        }
        for card in model.cards {
            let view = cards[card.kind] ?? {
                let made = HostCardView()
                addSubview(made)
                cards[card.kind] = made
                return made
            }()
            view.configure(card)
        }
        needsLayout = true
    }

    // MARK: Layout

    /// Grid cells of the cards in model order (CSS grid auto-placement, row-major, tall cards
    /// span two rows).
    static func placement(_ cards: [HostCardModel], columns: Int = HostSectionView.columns.count)
        -> [(kind: HostCardModel.Kind, column: Int, row: Int, tall: Bool)] {
        var taken = Set<[Int]>()
        var out: [(HostCardModel.Kind, Int, Int, Bool)] = []
        for card in cards {
            var row = 0
            placing: while true {
                for column in 0..<columns {
                    let cells = card.isTall ? [[row, column], [row + 1, column]] : [[row, column]]
                    if cells.allSatisfy({ !taken.contains($0) }) {
                        cells.forEach { taken.insert($0) }
                        out.append((card.kind, column, row, card.isTall))
                        break placing
                    }
                }
                row += 1
            }
        }
        return out
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        let columns = Self.columns(forWidth: width).count
        let rows = Self.placement(model?.cards ?? [], columns: columns).map { $0.row + ($0.tall ? 2 : 1) }.max() ?? 0
        let grid = rows == 0 ? 0 : CGFloat(rows) * Self.rowHeight + CGFloat(rows - 1) * Self.gap
        return SectionHeaderRow.height + sz(10) + grid
    }

    override func layout() {
        super.layout()
        header.frame = CGRect(x: 0, y: 0, width: bounds.width, height: SectionHeaderRow.height)
        let top = SectionHeaderRow.height + sz(10)
        let columns = Self.columns(forWidth: bounds.width)
        let total = columns.reduce(0, +)
        let usable = bounds.width - Self.gap * CGFloat(columns.count - 1)
        var xs: [CGFloat] = []
        var x: CGFloat = 0
        let widths = columns.map { usable * $0 / total }
        for width in widths {
            xs.append(x)
            x += width + Self.gap
        }
        for cell in Self.placement(model?.cards ?? [], columns: columns.count) {
            guard let view = cards[cell.kind] else { continue }
            let y = top + CGFloat(cell.row) * (Self.rowHeight + Self.gap)
            let height = cell.tall ? Self.rowHeight * 2 + Self.gap : Self.rowHeight
            view.frame = CGRect(x: round(xs[cell.column]), y: y, width: round(widths[cell.column]), height: height)
        }
    }
}

/// One metric card (`.sx-m`): label line, big value, sub line, meter; CPU adds a sparkline with
/// its axis; MEM puts its stacked meter under the value, then the legend, sparkline and axis.
final class HostCardView: FlippedView {
    private let label = TextLine(style: TextStyle.caps(10, Palette.dim, tracking: 0.16))
    private let right = TextLine(style: TextStyle.mono(10.5, Palette.dimmer, tracking: 0.04))
    private let value = TextLine(style: TextStyle(font: Typeface.display(22), color: Palette.cream))
    private let sub = TextLine(style: TextStyle.mono(11, Palette.dim))
    private let meter = MeterView(fraction: 0)
    private let spark = SparklineView()
    private var axis: [TextLine] = []
    private var legend: [LegendLineView] = []
    private(set) var model: HostCardModel?
    private(set) var configureCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        right.alignRight = true
        spark.showsBottomRule = true
        for view in [label, right, value, sub, meter, spark] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ card: HostCardModel) {
        guard card != model else { return }
        configureCount += 1
        model = card
        label.set(card.label, style: TextStyle.caps(10, Palette.dim, tracking: 0.16))
        right.set(card.right ?? "", style: TextStyle.mono(10.5, card.rightColor ?? Palette.dimmer, tracking: 0.04))
        value.set(attributed: Self.valueString(card.value, unit: card.unit))
        sub.set(card.sub ?? "", style: TextStyle.mono(11, Palette.dim))
        sub.isHidden = card.sub == nil
        meter.content = card.meter.content
        meter.barHeight = card.meter.height
        meter.accessibilityText = card.meterLabel ?? "\(card.label) 使用量"
        spark.isHidden = card.spark == nil
        spark.values = card.spark ?? []
        spark.baseline = card.sparkBaseline
        if axis.count != card.axis.count {
            axis.forEach { $0.removeFromSuperview() }
            axis = card.axis.map { _ in TextLine(style: TextStyle.mono(10, Palette.dimmer, tracking: 0.04)) }
            axis.forEach { addSubview($0) }
        }
        for (view, text) in zip(axis, card.axis) { view.set(text, style: TextStyle.mono(10, Palette.dimmer, tracking: 0.04)) }
        if legend.count != card.legend.count {
            legend.forEach { $0.removeFromSuperview() }
            legend = card.legend.map { _ in LegendLineView() }
            legend.forEach { addSubview($0) }
        }
        for (view, item) in zip(legend, card.legend) { view.configure(item) }
        let spoken = [card.label, card.value + (card.unit ?? ""), card.sub].compactMap { $0 }.joined(separator: " ")
        setAccessibilityLabel(card.right.map { "\(spoken) · \($0)" } ?? spoken)
        needsLayout = true
    }

    /// `23<small>%</small>`: Space Mono 22 cream, the unit Space Mono 12.5 dim 2 px after it.
    static func valueString(_ value: String, unit: String?) -> NSAttributedString {
        let string = NSMutableAttributedString(attributedString: TextStyle(font: Typeface.display(22), color: Palette.cream).string(value))
        if let unit, string.length > 0 {
            string.addAttribute(.kern, value: 2, range: NSRange(location: string.length - 1, length: 1))
            string.append(TextStyle(font: Typeface.display(12.5), color: Palette.dim).string(unit))
        }
        return string
    }

    override func layout() {
        super.layout()
        guard let model else { return }
        // `.sx-m{padding:9px 12px 11px; gap:5px}` inside a 1 px border.
        let x: CGFloat = sz(13)
        let width = bounds.width - sz(26)
        let rightWidth = min(right.textWidth, width * 0.7)
        label.frame = CGRect(x: x, y: sz(10), width: max(0, width - rightWidth - sz(6)), height: sz(16))
        right.frame = CGRect(x: x + width - rightWidth, y: sz(10), width: rightWidth, height: sz(16))
        value.frame = CGRect(x: x, y: sz(30.5), width: width, height: sz(24))
        var y: CGFloat = sz(60)
        let bottom = bounds.height - sz(12)
        if !model.legend.isEmpty {
            // MEM: stacked meter, legend (15.8 px lines, 1 px apart), then the sparkline.
            meter.frame = CGRect(x: x, y: y, width: width, height: model.meter.height)
            y += model.meter.height + sz(5)
            for line in legend {
                line.frame = CGRect(x: x, y: y, width: width, height: sz(15.8))
                y += sz(16.8)
            }
            y += sz(4)
            layoutSpark(x: x, width: width, top: y, axisBottom: bottom)
        } else {
            if !sub.isHidden {
                sub.frame = CGRect(x: x, y: y, width: width, height: sz(16.5))
                y += sz(16.5) + sz(5)
            }
            let meterY = bottom - model.meter.height
            meter.frame = CGRect(x: x, y: meterY, width: width, height: model.meter.height)
            if model.spark != nil {
                layoutSpark(x: x, width: width, top: y, axisBottom: meterY - sz(5))
            }
        }
    }

    /// Sparkline down to the axis line (`.sx-ax{margin-top:-2px}`, 15 px).
    private func layoutSpark(x: CGFloat, width: CGFloat, top: CGFloat, axisBottom: CGFloat) {
        let axisTop = axisBottom - (axis.isEmpty ? 0 : sz(15))
        spark.frame = CGRect(x: x, y: top, width: width, height: max(26, axisTop + sz(2) - sz(5) - top))
        // `justify-content: space-between`.
        for (i, line) in axis.enumerated() {
            let w = line.textWidth
            let lx: CGFloat
            if i == 0 { lx = x } else if i == axis.count - 1 { lx = x + width - w } else {
                lx = axis.count == 3 ? x + (width - w) / 2 : x + width * CGFloat(i) / CGFloat(axis.count - 1) - w / 2
            }
            line.frame = CGRect(x: round(lx), y: axisTop, width: w, height: sz(15))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.strokeRect(bounds, color: Palette.lineBright)
    }

    var visibleTexts: [String] { statusVisibleTexts() }
    var meterView: MeterView { meter }
    var sparkView: SparklineView { spark }
}

/// One MEM legend line (`.sx-leg span`): 7 px square, label in --dim, value right in --bone.
final class LegendLineView: NSView, StatusTextShowing {
    private var item = HostLegendItem(label: "", value: "", color: .clear)

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

    var displayedText: String { "\(item.label) \(item.value)" }

    func configure(_ item: HostLegendItem) {
        guard item != self.item else { return }
        self.item = item
        setAccessibilityValue(displayedText)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let mid = bounds.midY
        Draw.fill(CGRect(x: 0, y: round(mid - sz(3.5)), width: sz(7), height: sz(7)), item.color)
        Draw.text(TextStyle.mono(10.5, Palette.dim).string(item.label), x: sz(13), centerY: mid)
        let value = TextStyle.mono(10.5, Palette.bone).string(item.value)
        Draw.text(value, x: bounds.width - Draw.width(value), centerY: mid)
    }
}
