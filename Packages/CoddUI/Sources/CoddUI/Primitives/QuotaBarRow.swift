import AppKit

/// One quota row (`.qrow`) as a value: `5h ▮▮▮▮▮▮▮▮▮▯ 91%` plus an optional trailing note
/// (`2h57m後`). Value-based (no app `QuotaWindow`), so STATUS, Settings and the dialogs draw the
/// app's quota rows from plain numbers. Named apart from the app's own `QuotaRowView` /
/// `QuotaRowRenderer`, which stay in App (one name in two modules would be ambiguous there).
public struct QuotaBarRow: Equatable, Sendable {
    /// `5h`, `1w`, `Fable`.
    public var key: String
    /// Remaining 0...100; nil draws an empty bar and `—`.
    public var remainingPercent: Double?
    public var tone: Tone
    /// Text after the value (`2h57m後`, `13:39 · 2h57m後`).
    public var trailing: String?
    /// The trailing text is the sort key (R7 weekly reset): bone instead of dim.
    public var trailingIsKey: Bool
    /// `.acrow .qrow`: 10.5 px, key 16, value 30, gap 5 (sidebar / menu bar rows).
    public var compact: Bool
    /// Auto-switch threshold (remaining %): the 2 px `.thr` tick in danger at that position.
    public var threshold: Double?
    /// Overrides for artboard variants: `.sx-acct .qrow .k{width:34px}` (fits `Fable`),
    /// `.qrow .v{width:32px}`, `.sx-pvrow .qrow{font-size:10.5px}`.
    public var keyWidth: CGFloat?
    public var valueWidth: CGFloat?
    public var fontSize: CGFloat?

    /// `tone` nil derives it from the number (`Tone.tone(forRemaining:)`).
    public init(key: String, remainingPercent: Double?, tone: Tone? = nil, trailing: String? = nil, trailingIsKey: Bool = false,
                compact: Bool = false, threshold: Double? = nil, keyWidth: CGFloat? = nil, valueWidth: CGFloat? = nil,
                fontSize: CGFloat? = nil) {
        self.key = key
        self.remainingPercent = remainingPercent
        self.tone = tone ?? Tone.tone(forRemaining: remainingPercent)
        self.trailing = trailing
        self.trailingIsKey = trailingIsKey
        self.compact = compact
        self.threshold = threshold
        self.keyWidth = keyWidth
        self.valueWidth = valueWidth
        self.fontSize = fontSize
    }

    /// `91%` (rounded to a whole percent, clamped 0...100) or `—`.
    public var valueText: String {
        guard let remainingPercent, remainingPercent.isFinite else { return "—" }
        return "\(Int(min(100, max(0, remainingPercent)).rounded()))%"
    }
}

/// Draws `QuotaBarRow`s for custom-drawn lists and for `QuotaBarRowView`. Flipped coordinates.
/// Geometry follows helmet `.qrow` / `.bar10` and matches the app's `QuotaRowRenderer`: key at the
/// left in its fixed width, trailing text right-aligned at the far right, the value right-aligned in
/// its fixed width before it, the bar filling the rest (at least 40 px, `.bar10{min-width:40px}`).
@MainActor
public enum QuotaBarRowRenderer {
    /// Row height for layouts (`.qrow` line box), at the interface zoom.
    public static var height: CGFloat { UIZoom.pt(16) }
    /// `.bar10{height:7px}`, at the interface zoom.
    public static var barHeight: CGFloat { UIZoom.pt(7) }

    /// Resolved metrics of a row.
    public struct Layout: Equatable, Sendable {
        public var fontSize: CGFloat
        public var keyWidth: CGFloat
        public var valueWidth: CGFloat
        public var gap: CGFloat
    }

    /// The widths are design points (a row's own `keyWidth` / `valueWidth` too), resolved at the
    /// interface zoom so the zoomed key and value text keep fitting; the font size stays a design
    /// size (`Typeface` zooms it).
    public static func layout(for row: QuotaBarRow) -> Layout {
        Layout(fontSize: row.fontSize ?? (row.compact ? 10.5 : 11),
               keyWidth: UIZoom.pt(row.keyWidth ?? (row.compact ? 16 : 22)),
               valueWidth: UIZoom.pt(row.valueWidth ?? (row.compact ? 30 : 34)),
               gap: UIZoom.pt(row.compact ? 5 : 8))
    }

    /// The `.bar10` rectangle of `row` drawn in `rect`.
    public static func barRect(for row: QuotaBarRow, in rect: CGRect) -> CGRect {
        let metrics = layout(for: row)
        var right = rect.maxX
        if let trailing = row.trailing {
            right -= Draw.width(trailingStyle(row).string(trailing)) + metrics.gap
        }
        right -= metrics.valueWidth + metrics.gap
        let x = rect.minX + metrics.keyWidth + metrics.gap
        return CGRect(x: x, y: round(rect.midY - barHeight / 2), width: max(UIZoom.pt(40), right - x), height: barHeight)
    }

    /// The `.thr` tick (`width:2px;margin-left:-1px` at `left: threshold%`), or nil without a threshold.
    public static func thresholdTickRect(for row: QuotaBarRow, in rect: CGRect) -> CGRect? {
        thresholdTick(threshold: row.threshold, in: barRect(for: row, in: rect))
    }

    public static func draw(_ row: QuotaBarRow, in rect: CGRect) {
        let metrics = layout(for: row)
        let tone = row.tone.color
        Draw.text(TextStyle.mono(metrics.fontSize, Palette.dim).string(row.key), x: rect.minX, centerY: rect.midY, maxWidth: metrics.keyWidth)
        var right = rect.maxX
        if let trailing = row.trailing {
            let text = trailingStyle(row).string(trailing)
            let width = Draw.width(text)
            Draw.text(text, x: right - width, centerY: rect.midY)
            right -= width + metrics.gap
        }
        let value = TextStyle.mono(metrics.fontSize, tone).string(row.valueText)
        Draw.text(value, x: right - Draw.width(value), centerY: rect.midY)
        drawBar(in: barRect(for: row, in: rect), remaining: row.remainingPercent, color: tone, threshold: row.threshold)
    }

    /// `.bar10`: 10 segments with 1 px gaps on --line-bright, filled to `remaining` % in `color`
    /// (nil: empty), plus the threshold tick. Same segment geometry as the app's `QuotaBar`.
    public static func drawBar(in rect: CGRect, remaining: Double?, color: NSColor, threshold: Double? = nil) {
        let segment = rect.width / 10
        let percent = remaining.map { $0.isFinite ? min(100, max(0, $0)) : 0 } ?? 0
        let fillWidth = rect.width * CGFloat(percent) / 100
        for i in 0..<10 {
            let x = rect.minX + CGFloat(i) * segment
            let seg = CGRect(x: round(x), y: rect.minY, width: max(1, round(x + segment) - round(x) - 1), height: rect.height)
            Draw.fill(seg, Palette.lineBright)
            let filled = seg.intersection(CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height))
            if !filled.isNull, filled.width > 0 { Draw.fill(filled, color) }
        }
        if let tick = thresholdTick(threshold: threshold, in: rect) { Draw.fill(tick, Palette.danger) }
    }

    private static func thresholdTick(threshold: Double?, in bar: CGRect) -> CGRect? {
        guard let threshold, threshold.isFinite else { return nil }
        let x = bar.minX + bar.width * CGFloat(min(100, max(0, threshold))) / 100
        return CGRect(x: round(x) - 1, y: bar.minY, width: 2, height: bar.height)
    }

    private static func trailingStyle(_ row: QuotaBarRow) -> TextStyle {
        TextStyle.mono(10.5, row.trailingIsKey ? Palette.bone : Palette.dim)
    }
}

/// View wrapper around `QuotaBarRowRenderer` for stack layouts (16 pt tall, any width). Redraws only
/// when the row value changes. VoiceOver: static text with what the row shows (`5h 剩 91%`,
/// `1w 剩 46% · 1d12h後`).
public final class QuotaBarRowView: FlippedView {
    public var row: QuotaBarRow {
        didSet {
            guard row != oldValue else { return }
            needsDisplay = true
        }
    }

    public init(_ row: QuotaBarRow) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    public convenience init(key: String, remainingPercent: Double?, tone: Tone? = nil, trailing: String? = nil,
                            trailingIsKey: Bool = false, compact: Bool = false, threshold: Double? = nil) {
        self.init(QuotaBarRow(key: key, remainingPercent: remainingPercent, tone: tone, trailing: trailing,
                              trailingIsKey: trailingIsKey, compact: compact, threshold: threshold))
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Field shortcuts (each assignment goes through `row`'s change check).
    public var key: String { get { row.key } set { row.key = newValue } }
    public var remainingPercent: Double? { get { row.remainingPercent } set { row.remainingPercent = newValue } }
    public var tone: Tone { get { row.tone } set { row.tone = newValue } }
    public var trailing: String? { get { row.trailing } set { row.trailing = newValue } }
    public var trailingIsKey: Bool { get { row.trailingIsKey } set { row.trailingIsKey = newValue } }
    public var compact: Bool { get { row.compact } set { row.compact = newValue } }
    public var threshold: Double? { get { row.threshold } set { row.threshold = newValue } }

    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(QuotaBarRowRenderer.height)) }

    public override func draw(_ dirtyRect: NSRect) {
        QuotaBarRowRenderer.draw(row, in: bounds)
    }

    /// What the row shows, as read by VoiceOver: `5h 剩 91%` plus ` · <trailing>`.
    public var spokenText: String {
        let text = "\(row.key) 剩 \(row.valueText)"
        guard let trailing = row.trailing, !trailing.isEmpty else { return text }
        return "\(text) · \(trailing)"
    }

    // MARK: Accessibility

    private var explicitAccessibilityLabel: String?

    /// ``spokenText`` unless a caller set a label (theirs wins, also after later changes).
    public override func accessibilityLabel() -> String? { explicitAccessibilityLabel ?? spokenText }

    public override func setAccessibilityLabel(_ accessibilityLabel: String?) {
        explicitAccessibilityLabel = accessibilityLabel
        super.setAccessibilityLabel(accessibilityLabel)
    }
}
