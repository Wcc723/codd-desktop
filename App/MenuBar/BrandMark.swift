import AppKit
import CoddUI

/// What the single menu bar icon shows (R5: one icon, no counts).
enum StatusIconState: Equatable, Sendable {
    /// Monochrome bracket mark.
    case normal
    /// Inner square amber: something is waiting or failed.
    case attention
    /// Inner square hollow: hooks are not installed.
    case noHook
}

/// The `[■]` brand mark drawn with NSBezierPath (viewBox 0 0 20 20, stroke 1.5, square caps).
enum BrandMark {
    /// Status item image. Not a template image: the bracket uses `labelColor`, resolved when
    /// AppKit draws the item for each menu bar appearance; the inner square carries the state.
    /// `paused` (D23 `暫停通知`) draws the whole mark at 45 % (MenuBar artboard `.mb-off`).
    static func statusImage(_ state: StatusIconState, paused: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            if paused { NSGraphicsContext.current?.cgContext.setAlpha(0.45) }
            draw(in: rect, outline: .labelColor, core: state == .attention ? Palette.amber : .labelColor, hollowCore: state == .noHook,
                 glow: state == .attention)
            return true
        }
        image.isTemplate = false
        let base = switch state {
        case .normal: "CODD"
        case .attention: "CODD：有 session 需要你"
        case .noHook: "CODD：hooks 未安裝"
        }
        image.accessibilityDescription = paused ? base + "（通知已暫停）" : base
        return image
    }

    /// Draws the mark into `rect` of a flipped context.
    static func draw(in rect: NSRect, outline: NSColor, core: NSColor, hollowCore: Bool = false, glow: Bool = false) {
        let s = min(rect.width, rect.height) / 20
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        let bracket = NSBezierPath()
        bracket.move(to: p(6, 3)); bracket.line(to: p(3, 3)); bracket.line(to: p(3, 17)); bracket.line(to: p(6, 17))
        bracket.move(to: p(14, 3)); bracket.line(to: p(17, 3)); bracket.line(to: p(17, 17)); bracket.line(to: p(14, 17))
        bracket.lineWidth = 1.5 * s
        bracket.lineCapStyle = .square
        bracket.lineJoinStyle = .miter
        outline.setStroke()
        bracket.stroke()

        let coreRect = NSRect(x: rect.minX + 8.25 * s, y: rect.minY + 8.25 * s, width: 3.5 * s, height: 3.5 * s)
        NSGraphicsContext.saveGraphicsState()
        if glow {
            let shadow = NSShadow()
            shadow.shadowColor = Palette.amber.withAlphaComponent(0.8)
            shadow.shadowBlurRadius = 3 * s
            shadow.shadowOffset = .zero
            shadow.set()
        }
        if hollowCore {
            let path = NSBezierPath(rect: coreRect.insetBy(dx: 0.6 * s, dy: 0.6 * s))
            path.lineWidth = 1.2 * s
            core.setStroke()
            path.stroke()
        } else {
            core.setFill()
            NSBezierPath(rect: coreRect).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
