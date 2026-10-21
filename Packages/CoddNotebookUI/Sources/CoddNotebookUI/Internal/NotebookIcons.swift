import AppKit
import CoddUI

/// The Notebook and Split artboards' stroke icons (viewBox 0 0 20 20, stroke 1.5, square caps),
/// with the artboard's own path data. CoddUI's `SVGPath` only knows M / L / H / V / Z, and these
/// icons use smooth curves (`s`, the eye) and arcs (`a`, the link and the lock), so the package
/// carries a complete path parser (`NotebookSVG`); a candidate to move into CoddUI.
public enum NotebookIcon: String, Sendable, CaseIterable {
    /// INBOX smart list.
    case inbox
    /// PINNED smart list, and (filled) the pinned star in note rows.
    case star
    /// STALE smart list.
    case clock
    /// ARCHIVE smart list.
    case archive
    /// TRASH smart list.
    case trash
    /// LOCAL FILES rows and the COPY REF file path item.
    case file
    /// AI access READ (note rows, pills, drawer, info panel 讀取).
    case eye
    /// AI access OFF.
    case lock
    /// AI access APPEND and the info panel's 附加.
    case plus
    /// COPY REF `codd://note/<id>`.
    case link
    /// COPY REF split button and 複製全文 Markdown.
    case copy
    /// COPY REF local URL.
    case globe
    /// The composer reference chip's note document (Split `.sp-ref`).
    case noteDoc

    /// SVG elements in viewBox units, exactly as in the artboard markup.
    var elements: [NotebookSVG.Element] {
        switch self {
        case .inbox:
            [.path("M2.75 11.5h4.25l1 2h4l1-2h4.25"), .path("M2.75 11.5L5 4.25h10l2.25 7.25v4.25H2.75z")]
        case .star:
            [.path("M10 2.75l2.2 4.6 5.05.55-3.75 3.45 1.05 5L10 13.75l-4.55 2.6 1.05-5L2.75 7.9l5.05-.55z")]
        case .clock:
            [.circle(cx: 10, cy: 10, r: 7.25), .path("M10 6v4.5l3 1.75")]
        case .archive:
            [.rect(x: 2.75, y: 3.75, w: 14.5, h: 3.5), .path("M4 7.25v9h12v-9M8 10.5h4")]
        case .trash:
            [.path("M3.5 5.5h13M8 5.5V3.25h4V5.5M5 5.5l.75 11.25h8.5L15 5.5M8.5 8.5v5.5M11.5 8.5v5.5")]
        case .file:
            [.path("M5 2.75h7l3 3v11.5H5z"), .path("M11.75 2.75V6H15")]
        case .eye:
            [.path("M2 10s3-5.25 8-5.25S18 10 18 10s-3 5.25-8 5.25S2 10 2 10z"), .circle(cx: 10, cy: 10, r: 2.25)]
        case .lock:
            [.rect(x: 4.75, y: 9, w: 10.5, h: 8), .path("M7 9V6.5a3 3 0 0 1 6 0V9")]
        case .plus:
            [.path("M10 4v12M4 10h12")]
        case .link:
            [.path("M8.5 11.5l3-3M7.25 9.25l-2 2a2.5 2.5 0 0 0 3.5 3.5l2-2M12.75 10.75l2-2a2.5 2.5 0 0 0-3.5-3.5l-2 2")]
        case .copy:
            [.rect(x: 6.75, y: 6.75, w: 10.5, h: 10.5), .path("M4 13.25H2.75V2.75h10.5V4")]
        case .globe:
            [.circle(cx: 10, cy: 10, r: 7.25),
             .path("M2.75 10h14.5M10 2.75c2.25 2 2.25 12.5 0 14.5M10 2.75c-2.25 2-2.25 12.5 0 14.5")]
        case .noteDoc:
            [.path("M5 2.75h7.5l3 3v11.5H5z"), .path("M7.5 9.5h5M7.5 12.5h5")]
        }
    }
}

/// Draws `NotebookIcon`s. Paths are parsed once per icon and cached.
@MainActor
enum NotebookIconRenderer {
    private static var cache: [NotebookIcon: NSBezierPath] = [:]

    /// The icon's outline in viewBox units (y down).
    static func path(_ icon: NotebookIcon) -> NSBezierPath {
        if let cached = cache[icon] { return cached }
        let path = NSBezierPath()
        for element in icon.elements { path.append(element.bezierPath) }
        cache[icon] = path
        return path
    }

    /// Draws `icon` into `rect` of a flipped view. `filled` also fills the outline (the pinned
    /// star `.nb-pin{fill:currentColor}`).
    static func draw(_ icon: NotebookIcon, in rect: CGRect, color: NSColor, filled: Bool = false, lineWidth: CGFloat = 1.5) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let scale = min(rect.width, rect.height) / 20
        let transform = NSAffineTransform()
        transform.translateX(by: rect.minX + (rect.width - 20 * scale) / 2, yBy: rect.minY + (rect.height - 20 * scale) / 2)
        transform.scale(by: scale)
        transform.concat()
        let outline = path(icon)
        outline.lineWidth = lineWidth
        outline.lineCapStyle = .square
        outline.lineJoinStyle = .miter
        if filled {
            color.setFill()
            outline.fill()
        }
        color.setStroke()
        outline.stroke()
        context.restoreGraphicsState()
    }
}

/// A small SVG path parser for icons: every path command (M L H V C S Q T A Z, absolute and
/// relative, implicit repeats, compact numbers like `5.05.55` and arc flags like `011`), plus the
/// `<circle>` and `<rect>` elements the artboard icons use. Arcs become cubic Béziers (SVG 1.1
/// appendix F.6, endpoint to center parameterization).
enum NotebookSVG {
    enum Element: Sendable, Equatable {
        case path(String)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
        case rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)

        @MainActor
        var bezierPath: NSBezierPath {
            switch self {
            case .path(let d): NotebookSVG.parse(d)
            case .circle(let cx, let cy, let r): NSBezierPath(ovalIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            case .rect(let x, let y, let w, let h): NSBezierPath(rect: CGRect(x: x, y: y, width: w, height: h))
            }
        }
    }

    enum Token: Equatable {
        case command(Character)
        case number(CGFloat)
    }

    /// Splits path data into commands and numbers. `arcFlags` positions (the 4th and 5th argument
    /// of every `A` / `a` group) are read as single digits, so `0 011 2` parses as SVG requires.
    static func tokenize(_ d: String) -> [Token] {
        var tokens: [Token] = []
        let chars = Array(d)
        var index = 0
        var command: Character = " "
        var argIndex = 0
        while index < chars.count {
            let ch = chars[index]
            if ch.isLetter, ch != "e", ch != "E" {
                tokens.append(.command(ch))
                command = ch
                argIndex = 0
                index += 1
                continue
            }
            if ch == " " || ch == "," || ch == "\n" || ch == "\t" {
                index += 1
                continue
            }
            let isArc = command == "A" || command == "a"
            if isArc, argIndex % 7 == 3 || argIndex % 7 == 4, ch == "0" || ch == "1" {
                tokens.append(.number(ch == "1" ? 1 : 0))
                argIndex += 1
                index += 1
                continue
            }
            // A number: optional sign, digits, one dot, digits, optional exponent.
            var buffer = ""
            if ch == "-" || ch == "+" {
                buffer.append(ch)
                index += 1
            }
            var seenDot = false
            var seenExponent = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber {
                    buffer.append(c)
                } else if c == ".", !seenDot, !seenExponent {
                    seenDot = true
                    buffer.append(c)
                } else if (c == "e" || c == "E"), !seenExponent, !buffer.isEmpty {
                    seenExponent = true
                    buffer.append(c)
                    if index + 1 < chars.count, chars[index + 1] == "-" || chars[index + 1] == "+" {
                        buffer.append(chars[index + 1])
                        index += 1
                    }
                } else {
                    break
                }
                index += 1
            }
            if let value = Double(buffer) {
                tokens.append(.number(CGFloat(value)))
                argIndex += 1
            } else if buffer.isEmpty {
                index += 1 // unknown character
            }
        }
        return tokens
    }

    @MainActor
    static func parse(_ d: String) -> NSBezierPath {
        let path = NSBezierPath()
        var tokens = tokenize(d)[...]
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        // The last control point, for S / s (cubic) and T / t (quadratic) reflection.
        var lastCubic: CGPoint?
        var lastQuad: CGPoint?

        func number() -> CGFloat? {
            guard case .number(let value)? = tokens.first else { return nil }
            tokens = tokens.dropFirst()
            return value
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while !tokens.isEmpty {
            if case .command(let c)? = tokens.first {
                command = c
                tokens = tokens.dropFirst()
                if c == "Z" || c == "z" {
                    path.close()
                    current = start
                    lastCubic = nil
                    lastQuad = nil
                    continue
                }
            }
            let relative = command.isLowercase
            switch command {
            case "M", "m":
                guard let p = point(relative: relative) else { return path }
                current = p
                start = p
                path.move(to: p)
                command = relative ? "l" : "L"
                lastCubic = nil
                lastQuad = nil
            case "L", "l":
                guard let p = point(relative: relative) else { return path }
                current = p
                path.line(to: p)
                lastCubic = nil
                lastQuad = nil
            case "H", "h":
                guard let x = number() else { return path }
                current.x = relative ? current.x + x : x
                path.line(to: current)
                lastCubic = nil
                lastQuad = nil
            case "V", "v":
                guard let y = number() else { return path }
                current.y = relative ? current.y + y : y
                path.line(to: current)
                lastCubic = nil
                lastQuad = nil
            case "C", "c":
                guard let c1 = point(relative: relative), let c2 = point(relative: relative), let p = point(relative: relative) else { return path }
                path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
                lastCubic = c2
                lastQuad = nil
                current = p
            case "S", "s":
                guard let c2 = point(relative: relative), let p = point(relative: relative) else { return path }
                let c1 = lastCubic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
                lastCubic = c2
                lastQuad = nil
                current = p
            case "Q", "q":
                guard let q = point(relative: relative), let p = point(relative: relative) else { return path }
                appendQuad(path, from: current, control: q, to: p)
                lastQuad = q
                lastCubic = nil
                current = p
            case "T", "t":
                guard let p = point(relative: relative) else { return path }
                let q = lastQuad.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                appendQuad(path, from: current, control: q, to: p)
                lastQuad = q
                lastCubic = nil
                current = p
            case "A", "a":
                guard let rx = number(), let ry = number(), let rotation = number(), let large = number(), let sweep = number(),
                      let p = point(relative: relative) else { return path }
                appendArc(path, from: current, to: p, rx: rx, ry: ry, rotation: rotation, largeArc: large != 0, sweep: sweep != 0)
                current = p
                lastCubic = nil
                lastQuad = nil
            default:
                tokens = tokens.dropFirst()
            }
        }
        return path
    }

    @MainActor
    private static func appendQuad(_ path: NSBezierPath, from p0: CGPoint, control q: CGPoint, to p: CGPoint) {
        let c1 = CGPoint(x: p0.x + 2.0 / 3.0 * (q.x - p0.x), y: p0.y + 2.0 / 3.0 * (q.y - p0.y))
        let c2 = CGPoint(x: p.x + 2.0 / 3.0 * (q.x - p.x), y: p.y + 2.0 / 3.0 * (q.y - p.y))
        path.curve(to: p, controlPoint1: c1, controlPoint2: c2)
    }

    /// SVG elliptical arc as cubic Béziers of at most 90° each.
    @MainActor
    static func appendArc(_ path: NSBezierPath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                          rotation: CGFloat, largeArc: Bool, sweep: Bool) {
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else {
            path.line(to: p1)
            return
        }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2
        let dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        // Scale radii up when they cannot reach (F.6.6).
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            rx *= sqrt(lambda)
            ry *= sqrt(lambda)
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * (rx * y1p / ry)
        let cyp = coefficient * -(ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let length = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var a = acos(max(-1, min(1, dot / length)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(step / 4)
        func ellipse(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = theta1
        for index in 0..<segments {
            let t2 = t + step
            let a = ellipse(t)
            let b = index == segments - 1 ? p1 : ellipse(t2)
            let da = derivative(t)
            let db = derivative(t2)
            path.curve(to: b, controlPoint1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                       controlPoint2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t = t2
        }
    }
}
