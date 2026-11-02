import AppKit
import CoddUI

/// Quota bar drawing (`.bar10`): 10 segments with 1 px gaps, filled to `percent` in `tone`.
@MainActor
enum QuotaBar {
    static func draw(in rect: CGRect, percent: Int, tone: NSColor, threshold: Int? = nil) {
        let segment = rect.width / 10
        let fillWidth = rect.width * CGFloat(max(0, min(100, percent))) / 100
        for i in 0..<10 {
            let x = rect.minX + CGFloat(i) * segment
            let seg = CGRect(x: round(x), y: rect.minY, width: max(1, round(x + segment) - round(x) - 1), height: rect.height)
            Draw.fill(seg, Palette.lineBright)
            let filled = seg.intersection(CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height))
            if !filled.isNull, filled.width > 0 { Draw.fill(filled, tone) }
        }
        if let threshold {
            let x = rect.minX + rect.width * CGFloat(threshold) / 100
            Draw.fill(CGRect(x: round(x) - 1, y: rect.minY, width: 2, height: rect.height), Palette.danger)
        }
    }
}

/// One quota row (`.qrow`): `5h ▮▮▮▮▮▮▮▮▮▯ 91%` plus an optional trailing note (`2h57m後`).
/// `threshold` draws the R8 tick (auto-switch ON); an unknown window shows `—` and an empty bar.
/// A per-model window's name (`Fable`) widens the key column; `5h` / `1w` keep the design width,
/// and rows drawn together pass the widest key as `keyWidth` so their bars line up. The bar takes
/// what the key and the value leave (never the value's room) and is left out below `minBar`.
@MainActor
enum QuotaRowRenderer {
    /// Where a row's parts go: the key column's width, the bar (nil without room) and the value's
    /// left edge.
    struct Layout: Equatable {
        var keyWidth: CGFloat
        var bar: CGRect?
        var valueX: CGFloat
    }

    static let minBar: CGFloat = 10

    static func keyStyle(compact: Bool) -> TextStyle { TextStyle.mono(compact ? 10.5 : 11, Palette.dim) }

    /// The key column for `keys` drawn together (at least the design width).
    static func keyWidth(_ keys: [String], compact: Bool) -> CGFloat {
        let style = keyStyle(compact: compact)
        return keys.map { ceil(Draw.width(style.string($0))) }.reduce(UIZoom.pt(compact ? 16 : 22), max)
    }

    static func layout(key: String, quota: QuotaWindow, trailing: String?, compact: Bool, keyWidth minKey: CGFloat? = nil,
                       in rect: CGRect) -> Layout {
        // Widths are design points at the interface zoom (the key and the value grow with their text).
        let keyWidth = max(Self.keyWidth([key], compact: compact), minKey ?? 0)
        let valueWidth = UIZoom.pt(compact ? 30 : 34)
        let gap = UIZoom.pt(compact ? 5 : 8)
        var right = rect.maxX
        if let trailing { right -= Draw.width(TextStyle.mono(10.5, Palette.dim).string(trailing)) + gap }
        let value = TextStyle.mono(compact ? 10.5 : 11, Palette.dim).string(quota.valueText)
        let valueX = right - Draw.width(value)
        right -= valueWidth + gap
        let barX = rect.minX + keyWidth + gap
        let barHeight = UIZoom.pt(7)
        let bar = right - barX >= UIZoom.pt(minBar)
            ? CGRect(x: barX, y: round(rect.midY - barHeight / 2), width: right - barX, height: barHeight) : nil
        return Layout(keyWidth: keyWidth, bar: bar, valueX: valueX)
    }

    static func draw(key: String, quota: QuotaWindow, trailing: String?, trailingIsKey: Bool = false,
                     compact: Bool, threshold: Int? = nil, keyWidth minKey: CGFloat? = nil, in rect: CGRect) {
        let parts = layout(key: key, quota: quota, trailing: trailing, compact: compact, keyWidth: minKey, in: rect)
        let size: CGFloat = compact ? 10.5 : 11
        let tone = quota.tone.color
        Draw.text(keyStyle(compact: compact).string(key), x: rect.minX, centerY: rect.midY, maxWidth: parts.keyWidth)
        if let trailing {
            let t = TextStyle.mono(10.5, trailingIsKey ? Palette.bone : Palette.dim).string(trailing)
            Draw.text(t, x: rect.maxX - Draw.width(t), centerY: rect.midY)
        }
        Draw.text(TextStyle.mono(size, quota.known ? tone : Palette.dimmer).string(quota.valueText), x: parts.valueX, centerY: rect.midY)
        if let bar = parts.bar {
            QuotaBar.draw(in: bar, percent: quota.known ? quota.remainingPercent : 0, tone: tone, threshold: threshold)
        }
    }
}

/// View wrapper around `QuotaRowRenderer` for stack layouts.
final class QuotaRowView: FlippedView {
    var key = "5h" { didSet { if key != oldValue { needsDisplay = true } } }
    var quota = QuotaWindow.unknown { didSet { if quota != oldValue { needsDisplay = true } } }
    var trailing: String? { didSet { if trailing != oldValue { needsDisplay = true } } }
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    /// R8: the threshold tick while auto-switch is ON.
    var threshold: Int? { didSet { if threshold != oldValue { needsDisplay = true } } }
    /// The key column shared with the rows drawn with this one (nil: this key's own).
    var keyWidth: CGFloat? { didSet { if keyWidth != oldValue { needsDisplay = true } } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(16)) }

    override func draw(_ dirtyRect: NSRect) {
        QuotaRowRenderer.draw(key: key, quota: quota, trailing: trailing, compact: compact, threshold: threshold, keyWidth: keyWidth,
                              in: bounds)
    }

    // MARK: Accessibility (M5 D21)

    /// `5h 剩 91% · 2h57m後`, with the R8 threshold while auto-switch is ON: the bar's length and
    /// color are said as the number.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? {
        var text = "\(key) 剩 \(quota.valueText)"
        if let trailing, !trailing.isEmpty { text += " · \(trailing)" }
        if let threshold { text += "，自動切換門檻 \(threshold)%" }
        return text
    }
}
