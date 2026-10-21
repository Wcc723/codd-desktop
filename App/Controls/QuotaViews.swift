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
@MainActor
enum QuotaRowRenderer {
    static func draw(key: String, quota: QuotaWindow, trailing: String?, trailingIsKey: Bool = false,
                     compact: Bool, threshold: Int? = nil, in rect: CGRect) {
        // Widths are design points at the interface zoom (the key and the value grow with their text).
        let size: CGFloat = compact ? 10.5 : 11
        let keyWidth = UIZoom.pt(compact ? 16 : 22)
        let valueWidth = UIZoom.pt(compact ? 30 : 34)
        let gap = UIZoom.pt(compact ? 5 : 8)
        let tone = quota.tone.color
        Draw.text(TextStyle.mono(size, Palette.dim).string(key), x: rect.minX, centerY: rect.midY, maxWidth: keyWidth)

        var right = rect.maxX
        if let trailing {
            let t = TextStyle.mono(10.5, trailingIsKey ? Palette.bone : Palette.dim).string(trailing)
            let w = Draw.width(t)
            Draw.text(t, x: right - w, centerY: rect.midY)
            right -= w + gap
        }
        let value = TextStyle.mono(size, quota.known ? tone : Palette.dimmer).string(quota.valueText)
        Draw.text(value, x: right - Draw.width(value), centerY: rect.midY)
        right -= valueWidth + gap
        let barX = rect.minX + keyWidth + gap
        let barHeight = UIZoom.pt(7)
        let barRect = CGRect(x: barX, y: round(rect.midY - barHeight / 2), width: max(UIZoom.pt(30), right - barX), height: barHeight)
        QuotaBar.draw(in: barRect, percent: quota.known ? quota.remainingPercent : 0, tone: tone, threshold: threshold)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: UIZoom.pt(16)) }

    override func draw(_ dirtyRect: NSRect) {
        QuotaRowRenderer.draw(key: key, quota: quota, trailing: trailing, compact: compact, threshold: threshold, in: bounds)
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
