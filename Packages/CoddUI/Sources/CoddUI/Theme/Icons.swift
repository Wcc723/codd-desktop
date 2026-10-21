import AppKit

/// Stroke icons from the mockups (viewBox 0 0 20 20, stroke 1.5, square caps), drawn with
/// NSBezierPath so they stay crisp at any size and take any color.
public enum Icon: Sendable {
    case sessions, notes, status, settings, search, files, bottomTerminal, plus, window, brand, folder, maximize, restore, copy

    /// Pieces of an icon in viewBox units.
    fileprivate struct Shape {
        var strokes: [String] = []
        var strokeRects: [CGRect] = []
        var strokeCircles: [(center: CGPoint, radius: CGFloat)] = []
        var fillRects: [CGRect] = []
    }

    fileprivate var shape: Shape {
        switch self {
        case .sessions:
            Shape(strokes: ["M6 8l2.5 2L6 12M10.5 12.5H14"], strokeRects: [CGRect(x: 2.75, y: 3.75, width: 14.5, height: 12.5)])
        case .notes:
            Shape(strokes: ["M5 2.75h7.5l3 3v11.5H5z", "M12.25 2.75V6h3.25M7.5 9.5h5M7.5 12.5h5M7.5 15h3"])
        case .status:
            Shape(strokes: ["M2 11h3.5l2-5.5 4 10 2-4.5H18"])
        case .settings:
            Shape(strokes: ["M3 5.5h14M3 10h14M3 14.5h14"],
                  fillRects: [CGRect(x: 11.25, y: 4, width: 3, height: 3), CGRect(x: 5.25, y: 8.5, width: 3, height: 3),
                              CGRect(x: 9.25, y: 13, width: 3, height: 3)])
        case .search:
            Shape(strokes: ["M13 13l4.25 4.25"], strokeCircles: [(CGPoint(x: 9, y: 9), 5.25)])
        case .files:
            Shape(strokes: ["M2.75 4.75h5l1.75 2h7.75v9.5H2.75z", "M2.75 8.75h14.5"])
        case .bottomTerminal:
            Shape(strokes: ["M2.75 11.25h14.5M5.5 13.75h3"], strokeRects: [CGRect(x: 2.75, y: 3.75, width: 14.5, height: 12.5)])
        case .plus:
            Shape(strokes: ["M10 4.5v11M4.5 10h11"])
        case .window:
            Shape(strokes: ["M2.75 7.75h14.5"], strokeRects: [CGRect(x: 2.75, y: 4.25, width: 14.5, height: 11.5)])
        case .folder:
            // The quick switch's project rows (QuickSwitch artboard).
            Shape(strokes: ["M2.75 4.75h5l1.5 1.75h8v9.75H2.75z"])
        case .maximize:
            // The bottom panel's `最大化下方終端機` (Split artboard path).
            Shape(strokes: ["M11.75 3.75h4.5v4.5M8.25 16.25h-4.5v-4.5M16 4l-4.75 4.75M4 16l4.75-4.75"])
        case .restore:
            // `還原下方終端機`: the same arrows pointing inward.
            Shape(strokes: ["M11.25 4.25v4.5h4.5M8.75 15.75v-4.5h-4.5M16.25 3.75l-5 5M3.75 16.25l5-5"])
        case .copy:
            // The ⌘N command strip's `複製指令` (NewSession artboard).
            Shape(strokes: ["M13.25 4V2.75H2.75v10.5H4"], strokeRects: [CGRect(x: 6.75, y: 6.75, width: 10.5, height: 10.5)])
        case .brand:
            Shape(strokes: ["M6 3H3v14h3M14 3h3v14h-3"], fillRects: [CGRect(x: 8.25, y: 8.25, width: 3.5, height: 3.5)])
        }
    }
}

@MainActor
public enum IconRenderer {
    /// Draws `icon` into `rect` (any size; the 20×20 viewBox is scaled). Works in flipped and
    /// unflipped views: the SVG y axis points down, so unflipped contexts get a flip.
    public static func draw(_ icon: Icon, in rect: CGRect, color: NSColor, lineWidth: CGFloat = 1.5, flipped: Bool) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let scale = min(rect.width, rect.height) / 20
        let transform = NSAffineTransform()
        if flipped {
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scale(by: scale)
        } else {
            transform.translateX(by: rect.minX, yBy: rect.maxY)
            transform.scaleX(by: scale, yBy: -scale)
        }
        transform.concat()
        let shape = icon.shape
        let stroke = NSBezierPath()
        for d in shape.strokes { stroke.append(SVGPath.parse(d)) }
        for r in shape.strokeRects { stroke.append(NSBezierPath(rect: r)) }
        for c in shape.strokeCircles {
            stroke.append(NSBezierPath(ovalIn: CGRect(x: c.center.x - c.radius, y: c.center.y - c.radius,
                                                       width: c.radius * 2, height: c.radius * 2)))
        }
        stroke.lineWidth = lineWidth
        stroke.lineCapStyle = .square
        stroke.lineJoinStyle = .miter
        color.setStroke()
        stroke.stroke()
        if !shape.fillRects.isEmpty {
            color.setFill()
            for r in shape.fillRects { NSBezierPath(rect: r).fill() }
        }
        context.restoreGraphicsState()
    }
}

/// Minimal SVG path parser: M m L l H h V v Z z with implicit repeats. That is every command
/// the CODD icon set uses; anything else is ignored.
public enum SVGPath {
    @MainActor
    public static func parse(_ d: String) -> NSBezierPath {
        let path = NSBezierPath()
        var tokens = tokenize(d)[...]
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero

        func number() -> CGFloat? {
            guard case .number(let value)? = tokens.first else { return nil }
            tokens = tokens.dropFirst()
            return value
        }

        while !tokens.isEmpty {
            if case .command(let c)? = tokens.first {
                command = c
                tokens = tokens.dropFirst()
                if c == "Z" || c == "z" {
                    path.close()
                    current = start
                    continue
                }
            }
            switch command {
            case "M", "m":
                guard let x = number(), let y = number() else { return path }
                current = command == "M" ? CGPoint(x: x, y: y) : CGPoint(x: current.x + x, y: current.y + y)
                path.move(to: current)
                start = current
                command = command == "M" ? "L" : "l" // implicit lineto after the first pair
            case "L", "l":
                guard let x = number(), let y = number() else { return path }
                current = command == "L" ? CGPoint(x: x, y: y) : CGPoint(x: current.x + x, y: current.y + y)
                path.line(to: current)
            case "H", "h":
                guard let x = number() else { return path }
                current.x = command == "H" ? x : current.x + x
                path.line(to: current)
            case "V", "v":
                guard let y = number() else { return path }
                current.y = command == "V" ? y : current.y + y
                path.line(to: current)
            default:
                tokens = tokens.dropFirst()
            }
        }
        return path
    }

    public enum Token: Equatable {
        case command(Character)
        case number(CGFloat)
    }

    /// Splits `M6 8l2.5 2L6 12` / `l2-5.5` into commands and numbers.
    public static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        var buffer = ""
        func flush() {
            if let value = Double(buffer) { tokens.append(.number(CGFloat(value))) }
            buffer = ""
        }
        for ch in d {
            if ch.isLetter {
                flush()
                tokens.append(.command(ch))
            } else if ch == "-" {
                flush()
                buffer = "-"
            } else if ch == "." && buffer.contains(".") {
                flush()
                buffer = "."
            } else if ch.isNumber || ch == "." {
                buffer.append(ch)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
