import AppKit
import CoddUI

/// What a canvas point is over (select tool), in priority order: the selected rect's corner
/// handles and the selected arrow's endpoints, then items topmost first.
enum CanvasHit: Equatable {
    case none
    case item(Int)
    case corner(Int, RectCorner)
    case arrowStart(Int)
    case arrowEnd(Int)
}

/// Where the overlay pieces sit on the canvas for one mapping (shared by drawing and hit testing),
/// in the Notebook preview's look (helmet `.ann-box`, `.ann-pin`, the arrow svg) plus the board's
/// handles (`.ia-hdl`) and tooltip (`.ia-tip`).
@MainActor
struct OverlayLayout {
    let mapping: CanvasMapping
    /// A text label's font size in ORIGINAL pixels (it is part of the picture, so it scales).
    let textPixelSize: CGFloat

    static let pinSize: CGFloat = 18
    static let handleSize: CGFloat = 9
    /// The arrow head in canvas points (the artboard's 26 × 28 px head at 50 %).
    static let headLength: CGFloat = 13
    static let headHalfWidth: CGFloat = 7
    /// A selected rect's number moves out of the way of its top-left handle (`left:-13px;top:-13px`).
    static let selectedPinOffset: CGFloat = 12

    init(mapping: CanvasMapping, pixelWidth: Int, pixelHeight: Int) {
        self.mapping = mapping
        textPixelSize = Self.textPixelSize(width: pixelWidth, height: pixelHeight)
    }

    /// 24 px on a 1334 px tall screenshot; proportional to the image's long edge, at least 14 px.
    static func textPixelSize(width: Int, height: Int) -> CGFloat {
        max(14, (CGFloat(max(width, height)) * 0.018).rounded())
    }

    func pinCenter(_ item: AnnotationDraft, selected: Bool) -> CGPoint {
        switch item.kind {
        case .rect:
            let corner = mapping.view(item.x, item.y)
            return selected ? CGPoint(x: corner.x - Self.selectedPinOffset, y: corner.y - Self.selectedPinOffset) : corner
        case .text:
            return textLabelRect(item).origin
        case .point:
            return mapping.view(item.x, item.y)
        case .arrow:
            // At the tail; a selected arrow's number steps back along the line so the tail's
            // handle stays visible.
            let start = mapping.view(item.x, item.y)
            let end = mapping.view(item.endX, item.endY)
            let length = hypot(end.x - start.x, end.y - start.y)
            guard selected, length > 0 else { return start }
            let offset = Self.selectedPinOffset * 1.4
            return CGPoint(x: start.x - (end.x - start.x) / length * offset, y: start.y - (end.y - start.y) / length * offset)
        }
    }

    func pinRect(_ item: AnnotationDraft, selected: Bool) -> CGRect {
        let c = pinCenter(item, selected: selected)
        return CGRect(x: c.x - Self.pinSize / 2, y: c.y - Self.pinSize / 2, width: Self.pinSize, height: Self.pinSize)
    }

    var textFont: NSFont { Typeface.mono(max(8, textPixelSize * mapping.scale), .medium) }

    func textAttributes(_ item: AnnotationDraft) -> NSAttributedString {
        let text = item.note.isEmpty ? "…" : item.note.replacingOccurrences(of: "\n", with: " ")
        return NSAttributedString(string: text, attributes: [
            .font: textFont, .foregroundColor: AnnotateTheme.color(item.color), .ligature: 0,
        ])
    }

    /// The label plate of a text item: its top-left is the item's (x, y).
    func textLabelRect(_ item: AnnotationDraft) -> CGRect {
        let size = textAttributes(item).size()
        let em = textFont.pointSize
        let origin = mapping.view(item.x, item.y)
        return CGRect(x: origin.x, y: origin.y, width: ceil(size.width) + em, height: ceil(size.height) + em * 0.5)
    }

    func handleRect(_ center: CGPoint) -> CGRect {
        CGRect(x: center.x - Self.handleSize / 2, y: center.y - Self.handleSize / 2, width: Self.handleSize, height: Self.handleSize)
    }

    func cornerCenter(_ item: AnnotationDraft, _ corner: RectCorner) -> CGPoint {
        let r = mapping.viewRect(item)
        return CGPoint(x: corner.dirX > 0 ? r.maxX : r.minX, y: corner.dirY > 0 ? r.maxY : r.minY)
    }

    /// What the item covers on the canvas (tooltip placement and redraw).
    func bounds(_ item: AnnotationDraft, selected: Bool) -> CGRect {
        switch item.kind {
        case .rect: mapping.viewRect(item)
        case .point: pinRect(item, selected: selected)
        case .arrow:
            CGRect(x: min(mapping.view(item.x, item.y).x, mapping.view(item.endX, item.endY).x),
                   y: min(mapping.view(item.x, item.y).y, mapping.view(item.endX, item.endY).y),
                   width: abs(CGFloat(item.endX - item.x)) * mapping.scale,
                   height: abs(CGFloat(item.endY - item.y)) * mapping.scale)
        case .text: textLabelRect(item)
        }
    }

    /// The tooltip's text pieces and its frame under the item (`top: calc(100% + 9px)`).
    func tooltipRect(_ item: AnnotationDraft, selected: Bool) -> CGRect {
        let size = tooltipSize(item)
        let b = bounds(item, selected: selected)
        return CGRect(x: round(b.midX - size.width / 2), y: round(b.maxY + 8), width: size.width, height: size.height)
    }

    func tooltipSize(_ item: AnnotationDraft) -> CGSize {
        let text = Draw.width(AnnotateTheme.tooltip.string(item.coordinateText))
        let unit = Draw.width(AnnotateTheme.tooltipUnit.string("px"))
        // `padding: 0 8px`, `gap: 6px` (the text's trailing space included), 1 px border.
        return CGSize(width: ceil(text + 6 + unit + 16 + 2), height: 22)
    }

    // MARK: Hit testing

    func hit(_ p: CGPoint, items: [AnnotationDraft], selected: Int?) -> CanvasHit {
        if let selected, let item = items.first(where: { $0.n == selected }) {
            switch item.kind {
            case .rect:
                for corner in RectCorner.allCases where handleRect(cornerCenter(item, corner)).insetBy(dx: -3, dy: -3).contains(p) {
                    return .corner(item.n, corner)
                }
            case .arrow:
                if handleRect(mapping.view(item.endX, item.endY)).insetBy(dx: -3, dy: -3).contains(p) { return .arrowEnd(item.n) }
                if handleRect(mapping.view(item.x, item.y)).insetBy(dx: -3, dy: -3).contains(p) { return .arrowStart(item.n) }
            case .point, .text:
                break
            }
        }
        // Precise targets first (pins, points, arrow lines, labels, rect edges), topmost first, so
        // a point inside a big box stays reachable; then rect interiors, the smallest first.
        for item in items.reversed() {
            if pinRect(item, selected: item.n == selected).insetBy(dx: -2, dy: -2).contains(p) { return .item(item.n) }
            switch item.kind {
            case .arrow:
                let d = AnnotationGeometry.distance(from: p, toSegment: mapping.view(item.x, item.y), mapping.view(item.endX, item.endY))
                if d <= 6 { return .item(item.n) }
            case .text:
                if textLabelRect(item).contains(p) { return .item(item.n) }
            case .rect:
                let r = mapping.viewRect(item)
                if r.insetBy(dx: -5, dy: -5).contains(p), !r.insetBy(dx: 5, dy: 5).contains(p) { return .item(item.n) }
            case .point:
                break
            }
        }
        let boxes = items.filter { $0.kind == .rect && mapping.viewRect($0).contains(p) }
        if let smallest = boxes.min(by: { $0.width * $0.height < $1.width * $1.height }) { return .item(smallest.n) }
        return .none
    }
}

/// Draws annotations over the image: boxes (1.5 pt border, 10 % fill, a black ring; the selected one
/// glows), arrows (black halo, colored line, filled head with a black edge), text labels, numbered
/// squares on top, then the selection's handles and coordinate tooltip.
@MainActor
enum OverlayRenderer {
    static func draw(items: [AnnotationDraft], selected: Int?, provisional: AnnotationDraft?, layout: OverlayLayout) {
        var all = items
        if let provisional { all.append(provisional) }
        for item in all {
            let isSelected = item.n == selected || item.n == provisional?.n
            switch item.kind {
            case .rect: drawBox(item, selected: isSelected, layout: layout)
            case .arrow: drawArrow(item, layout: layout)
            case .text: drawText(item, layout: layout)
            case .point: break
            }
        }
        for item in all {
            drawPin(item.n, center: layout.pinCenter(item, selected: item.n == selected || item.n == provisional?.n), color: item.color)
        }
        let focus = provisional ?? selected.flatMap { n in items.first { $0.n == n } }
        guard let focus else { return }
        switch focus.kind {
        case .rect:
            for corner in RectCorner.allCases { drawHandle(layout.handleRect(layout.cornerCenter(focus, corner))) }
        case .arrow:
            drawHandle(layout.handleRect(layout.mapping.view(focus.x, focus.y)))
            drawHandle(layout.handleRect(layout.mapping.view(focus.endX, focus.endY)))
        case .point, .text:
            break
        }
        drawTooltip(focus, layout: layout)
    }

    static func drawBox(_ item: AnnotationDraft, selected: Bool, layout: OverlayLayout) {
        let r = layout.mapping.viewRect(item)
        let color = AnnotateTheme.color(item.color)
        // `box-shadow: 0 0 0 1px rgba(0,0,0,.55)` outside the border.
        stroke(NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5)), width: 1, color: NSColor.black.withAlphaComponent(0.55))
        Draw.fill(r.insetBy(dx: 1.5, dy: 1.5), color.withAlphaComponent(0.10))
        NSGraphicsContext.saveGraphicsState()
        if selected { Draw.glow(color.withAlphaComponent(0.22), radius: 10).set() }
        stroke(NSBezierPath(rect: r.insetBy(dx: 0.75, dy: 0.75)), width: 1.5, color: color)
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawArrow(_ item: AnnotationDraft, layout: OverlayLayout) {
        let start = layout.mapping.view(item.x, item.y)
        let tip = layout.mapping.view(item.endX, item.endY)
        let color = AnnotateTheme.color(item.color)
        let dx = tip.x - start.x, dy = tip.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }
        let ux = dx / length, uy = dy / length
        let headLength = min(OverlayLayout.headLength, length)
        let base = CGPoint(x: tip.x - ux * headLength, y: tip.y - uy * headLength)
        if length > headLength {
            let line = NSBezierPath()
            line.move(to: start)
            line.line(to: base)
            line.lineCapStyle = .square
            stroke(line, width: 5, color: .black)
            stroke(line, width: 2.5, color: color)
        }
        let half = OverlayLayout.headHalfWidth
        let head = NSBezierPath()
        head.move(to: tip)
        head.line(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        head.line(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        head.close()
        color.setFill()
        head.fill()
        stroke(head, width: 1.5, color: .black)
    }

    static func drawText(_ item: AnnotationDraft, layout: OverlayLayout) {
        let plate = layout.textLabelRect(item)
        let color = AnnotateTheme.color(item.color)
        Draw.fill(plate, NSColor.black.withAlphaComponent(0.72))
        Draw.strokeRect(plate, color: color.withAlphaComponent(0.55))
        let em = layout.textFont.pointSize
        layout.textAttributes(item).draw(at: CGPoint(x: plate.minX + em / 2, y: plate.minY + em / 4))
    }

    /// `.ann-pin`: 18 pt square in the item color with a black number, a 1.5 pt black ring and glow.
    static func drawPin(_ n: Int, center: CGPoint, color annotationColor: AnnotationColor) {
        let rect = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
        let color = AnnotateTheme.color(annotationColor)
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(color.withAlphaComponent(0.22), radius: 8).set()
        Draw.fill(rect.insetBy(dx: -1.5, dy: -1.5), .black)
        NSGraphicsContext.restoreGraphicsState()
        Draw.fill(rect, color)
        let number = AnnotateTheme.number.string("\(n)")
        Draw.text(number, x: rect.midX - Draw.width(number) / 2, centerY: rect.midY)
    }

    /// `.ia-hdl`: 9 pt black square, 1.5 pt amber border, 6 pt amber glow.
    static func drawHandle(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(Palette.amberGlow, radius: 6).set()
        Draw.fill(rect, .black)
        NSGraphicsContext.restoreGraphicsState()
        stroke(NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75)), width: 1.5, color: Palette.amber)
    }

    /// `.ia-tip`: `x 20 · y 1150 · 710×120 px` on --bg-lift with an --amber-dim border and a drop shadow.
    static func drawTooltip(_ item: AnnotationDraft, layout: OverlayLayout) {
        let rect = layout.tooltipRect(item, selected: true)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -6)
        shadow.set()
        Draw.fill(rect, Palette.bgLift)
        NSGraphicsContext.restoreGraphicsState()
        Draw.strokeRect(rect, color: Palette.amberDim)
        let text = AnnotateTheme.tooltip.string(item.coordinateText)
        let x = rect.minX + 9 + Draw.text(text, x: rect.minX + 9, centerY: rect.midY)
        Draw.text(AnnotateTheme.tooltipUnit.string("px"), x: x + 6, centerY: rect.midY)
    }

    private static func stroke(_ path: NSBezierPath, width: CGFloat, color: NSColor) {
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }
}
