import AppKit
import CoddUI

/// The host one-liner of the sidebar footer and the menu bar footer as one row of meters (FB
/// 2026-11, D36): `CPU ▬▬ 23%  MEM ▬▬ 59%  BAT ▬▬ 86%`, each bar and value in its load tone
/// (`HostLoad`, the quota bars' colors). The meters share the width in equal cells; a narrow row
/// tightens the gaps and shortens the bars, then drops them (`CPU 23%`), then the labels (`23%`).
/// The value column always has room for `100%`, so a value never changes the layout. Without
/// meters (real mode before the first sample) it shows the summary's text. VoiceOver and the
/// tooltip read ``HostMeters/spoken``.
final class HostMetersView: FlippedView {
    /// How the meters fit the width.
    struct Layout: Equatable {
        enum Mode: Equatable { case bars, values, numbers }
        var mode: Mode
        /// The bars' width (design points at the current zoom); 0 without bars.
        var barWidth: CGFloat
        /// The least gap between two meters and the gap between a meter's label, bar and value.
        var cellGap: CGFloat
        var innerGap: CGFloat
    }

    var meters: HostMeters? { didSet { if meters != oldValue { update() } } }
    /// Drawn while `meters` is nil (`CODD · <root>`).
    var fallback = "" { didSet { if fallback != oldValue { update() } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(16)) }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { needsDisplay = true }
    }

    private func update() {
        let text = meters?.spoken ?? fallback
        toolTip = text.isEmpty ? nil : text
        needsDisplay = true
    }

    // MARK: Layout

    private static var labelStyle: TextStyle { TextStyle.caps(9.5, Palette.dim, tracking: 0.08) }
    private static func valueStyle(_ tone: QuotaTone) -> TextStyle { TextStyle.mono(10.5, tone.color) }

    /// Label column: the widest label; value column: `100%`, the widest value (percentages are
    /// clamped to 0 ... 100), so the bars keep their length whatever the numbers.
    static func columns(_ meters: [HostMeter]) -> (label: CGFloat, value: CGFloat) {
        let label = meters.map { Draw.width(labelStyle.string($0.label)) }.max() ?? 0
        let value = (meters.map { Draw.width(valueStyle(.ok).string($0.valueText)) } + [Draw.width(valueStyle(.ok).string("100%"))]).max() ?? 0
        return (label, value)
    }

    /// The pure fitting rule: `count` equal cells, the gaps of the first tier in `gapTiers` whose
    /// bar reaches `comfortableBar`, else of the tightest one while its bar reaches `minBar` (the
    /// sidebar's minimum width); a bar up to `maxBar` after the label and before the value. Else
    /// label and value, else the value alone (narrower than any sidebar or the menu bar).
    static func layout(width: CGFloat, count: Int, labelWidth: CGFloat, valueWidth: CGFloat) -> Layout {
        let z = UIZoom.pt
        let textTier = gapTiers[1]
        guard count > 0 else { return Layout(mode: .numbers, barWidth: 0, cellGap: z(textTier.cell), innerGap: z(textTier.inner)) }
        func cell(_ gap: CGFloat) -> CGFloat { (width - z(gap) * CGFloat(count - 1)) / CGFloat(count) }
        func bars(_ tier: (cell: CGFloat, inner: CGFloat)) -> Layout {
            let bar = min(z(maxBar), floor(cell(tier.cell) - labelWidth - valueWidth - z(tier.inner) * 2))
            return Layout(mode: .bars, barWidth: bar, cellGap: z(tier.cell), innerGap: z(tier.inner))
        }
        if let roomy = gapTiers.lazy.map(bars).first(where: { $0.barWidth >= z(comfortableBar) }) { return roomy }
        if let tightest = gapTiers.last.map(bars), tightest.barWidth >= z(minBar) { return tightest }
        let mode: Layout.Mode = labelWidth + z(textTier.inner) + valueWidth <= cell(textTier.cell) ? .values : .numbers
        return Layout(mode: mode, barWidth: 0, cellGap: z(textTier.cell), innerGap: z(textTier.inner))
    }

    /// Gaps between meters and inside one (design points), roomiest first; labels and values
    /// without bars use the second.
    static let gapTiers: [(cell: CGFloat, inner: CGFloat)] = [(14, 4), (8, 4), (6, 3)]
    static let comfortableBar: CGFloat = 16
    static let minBar: CGFloat = 8
    static let maxBar: CGFloat = 64
    static let barHeight: CGFloat = 4

    /// The layout at the current width (tests).
    var currentLayout: Layout? {
        guard let meters else { return nil }
        let list = meters.meters
        let columns = Self.columns(list)
        return Self.layout(width: bounds.width, count: list.count, labelWidth: columns.label, valueWidth: columns.value)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let meters else {
            Draw.text(TextStyle.mono(11, Palette.dim).string(fallback), x: 0, centerY: bounds.midY, maxWidth: bounds.width)
            return
        }
        let list = meters.meters
        let columns = Self.columns(list)
        let layout = Self.layout(width: bounds.width, count: list.count, labelWidth: columns.label, valueWidth: columns.value)
        let gap = layout.innerGap
        let content: CGFloat = switch layout.mode {
        case .bars: columns.label + gap + layout.barWidth + gap + columns.value
        case .values: columns.label + gap + columns.value
        case .numbers: columns.value
        }
        // Justified: the first meter at the left edge, the last one ending at the right edge.
        let count = CGFloat(list.count)
        let spacing = list.count > 1 ? max(0, (bounds.width - content * count) / (count - 1)) : 0
        let midY = bounds.midY
        for (i, meter) in list.enumerated() {
            var x = round(CGFloat(i) * (content + spacing))
            let value = Self.valueStyle(meter.tone).string(meter.valueText)
            if layout.mode != .numbers {
                Draw.text(Self.labelStyle.string(meter.label), x: x, centerY: midY)
                x += columns.label + gap
            }
            if layout.mode == .bars {
                let height = UIZoom.pt(Self.barHeight)
                let track = CGRect(x: x, y: round(midY - height / 2), width: layout.barWidth, height: height)
                Draw.fill(track, Palette.lineBright)
                let fill = round(track.width * CGFloat(max(0, min(100, meter.percent))) / 100)
                if fill > 0 { Draw.fill(CGRect(x: track.minX, y: track.minY, width: max(1, fill), height: height), meter.tone.color) }
                x += layout.barWidth + gap
            }
            // Right-aligned in the value column.
            Draw.text(value, x: x + columns.value - Draw.width(value), centerY: midY)
        }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { meters?.spoken ?? fallback }
}
