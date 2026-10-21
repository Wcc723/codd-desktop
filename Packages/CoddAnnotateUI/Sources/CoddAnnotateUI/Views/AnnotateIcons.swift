import AppKit
import CoddUI

/// The board's stroke icons (viewBox 0 0 20 20, stroke 1.5, square caps), with the artboard's
/// paths. CoddUI's `Icon` set has none of them, and the undo / redo paths use arcs, which
/// `SVGPath` does not parse, so the arcs are built here.
enum AnnotateIcon: Sendable {
    case undo, redo, select, rect, point, arrow, text

    static func tool(_ tool: AnnotateTool) -> AnnotateIcon {
        switch tool {
        case .select: .select
        case .rect: .rect
        case .point: .point
        case .arrow: .arrow
        case .text: .text
        }
    }

    /// The icon's path in viewBox units.
    @MainActor
    var path: NSBezierPath {
        switch self {
        case .undo:
            // M7.5 5.5L4 9l3.5 3.5 · M4 9h8a4 4 0 0 1 0 8H9
            let path = SVGPath.parse("M7.5 5.5L4 9l3.5 3.5")
            path.move(to: CGPoint(x: 4, y: 9))
            path.line(to: CGPoint(x: 12, y: 9))
            path.appendArc(withCenter: CGPoint(x: 12, y: 13), radius: 4, startAngle: -90, endAngle: 90, clockwise: false)
            path.line(to: CGPoint(x: 9, y: 17))
            return path
        case .redo:
            // M12.5 5.5L16 9l-3.5 3.5 · M16 9H8a4 4 0 0 0 0 8h3
            let path = SVGPath.parse("M12.5 5.5L16 9l-3.5 3.5")
            path.move(to: CGPoint(x: 16, y: 9))
            path.line(to: CGPoint(x: 8, y: 9))
            path.appendArc(withCenter: CGPoint(x: 8, y: 13), radius: 4, startAngle: 270, endAngle: 90, clockwise: true)
            path.line(to: CGPoint(x: 11, y: 17))
            return path
        case .select:
            return SVGPath.parse("M5.5 3.25v12.5l3.25-3.25 2.25 5 2-.9-2.25-4.85h4.5z")
        case .rect:
            return NSBezierPath(rect: CGRect(x: 3.75, y: 5.25, width: 12.5, height: 9.5))
        case .point:
            let path = NSBezierPath(rect: CGRect(x: 6, y: 3, width: 8, height: 8))
            path.append(SVGPath.parse("M10 11v6"))
            return path
        case .arrow:
            return SVGPath.parse("M4.5 15.5L15 5M9 4.75h6.25V11")
        case .text:
            return SVGPath.parse("M4.5 4.75h11M10 4.75v11M7.5 15.75h5")
        }
    }

    /// Strokes the icon into `rect` of a flipped view.
    @MainActor
    func draw(in rect: CGRect, color: NSColor) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX, yBy: rect.minY)
        transform.scale(by: min(rect.width, rect.height) / 20)
        transform.concat()
        let path = self.path
        path.lineWidth = 1.5
        path.lineCapStyle = .square
        path.lineJoinStyle = .miter
        color.setStroke()
        path.stroke()
        context.restoreGraphicsState()
    }
}
