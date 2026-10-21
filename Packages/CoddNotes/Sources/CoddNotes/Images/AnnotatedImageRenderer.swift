import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Burns annotations into a copy of the image (D10): amber 3 px boxes with a black halo, numbered
/// 28 px squares, arrows with heads, text labels on a black plate. Sizes scale with the image so a
/// 4000 px photo gets the same visual weight as a 750 px phone screenshot. CoreGraphics + CoreText
/// only (system font with CJK fallback), so it runs off the main actor.
public enum AnnotatedImageRenderer {
    public enum RenderError: Error, Sendable {
        case unreadable
        case drawing
    }

    static func color(_ name: String?) -> CGColor {
        switch name {
        case "cyan": CGColor(srgbRed: 0x6E / 255, green: 0xE0 / 255, blue: 0xF0 / 255, alpha: 1)
        case "danger": CGColor(srgbRed: 1, green: 0x70 / 255, blue: 0x58 / 255, alpha: 1)
        case "success": CGColor(srgbRed: 0x7C / 255, green: 1, blue: 0x9A / 255, alpha: 1)
        case "cream": CGColor(srgbRed: 0xF5 / 255, green: 0xEC / 255, blue: 0xD6 / 255, alpha: 1)
        default: CGColor(srgbRed: 1, green: 0xB8 / 255, blue: 0x4A / 255, alpha: 1)
        }
    }

    /// PNG bytes of the image with `annotations` drawn over it.
    public static func render(image: URL, annotations: ImageAnnotations) throws -> Data {
        guard let src = CGImageSourceCreateWithURL(image as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let f = ImageProcessing.facts(src),
              let base = ImageProcessing.render(src, facts: f, longEdge: max(f.width, f.height))
        else { throw RenderError.unreadable }
        let w = base.width, h = base.height
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.drawing }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Top-left origin like the annotation coordinates.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        // Coordinates are in the annotated image's pixels; follow a resized file proportionally.
        let sx = annotations.size.width > 0 ? CGFloat(w) / CGFloat(annotations.size.width) : 1
        let sy = annotations.size.height > 0 ? CGFloat(h) / CGFloat(annotations.size.height) : 1
        let s = max(1, CGFloat(max(w, h)) / 1400)
        func pt(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: CGFloat(x) * sx, y: CGFloat(y) * sy) }

        let items = annotations.items.sorted { $0.n < $1.n }
        // Shapes first, pins and labels on top.
        for item in items {
            let c = color(item.color)
            switch item.type {
            case .rect:
                let r = CGRect(origin: pt(item.x, item.y), size: CGSize(width: CGFloat(item.w ?? 0) * sx, height: CGFloat(item.h ?? 0) * sy))
                ctx.setFillColor(c.copy(alpha: 0.10) ?? c)
                ctx.fill(r)
                stroke(ctx, path: CGPath(rect: r, transform: nil), color: c, width: 3 * s)
            case .arrow:
                let a = pt(item.x, item.y)
                let b = pt(item.x2 ?? item.x, item.y2 ?? item.y)
                drawArrow(ctx, from: a, to: b, color: c, scale: s)
            case .point, .text:
                break
            }
        }
        for item in items {
            let c = color(item.color)
            switch item.type {
            case .rect, .point, .arrow:
                drawPin(ctx, number: item.n, at: pt(item.x, item.y), color: c, scale: s, bounds: CGSize(width: w, height: h))
            case .text:
                drawLabel(ctx, text: item.note.isEmpty ? "\(item.n)" : item.note, at: pt(item.x, item.y), color: c, scale: s,
                          bounds: CGSize(width: w, height: h))
            }
        }
        guard let out = ctx.makeImage(), let png = ImageProcessing.encode(out, type: ImageProcessing.png, quality: 1) else {
            throw RenderError.drawing
        }
        return png
    }

    private static func stroke(_ ctx: CGContext, path: CGPath, color: CGColor, width: CGFloat) {
        ctx.saveGState()
        ctx.setLineJoin(.miter)
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
        ctx.setLineWidth(width + 2 * max(1, width / 3))
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func drawArrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, color: CGColor, scale s: CGFloat) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.001, hypot(dx, dy))
        let ux = dx / len, uy = dy / len
        let headLength = min(26 * s, len * 0.6)
        let headHalf = 11 * s
        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)
        let line = CGMutablePath()
        line.move(to: a)
        line.addLine(to: base)
        stroke(ctx, path: line, color: color, width: 3 * s)
        let head = CGMutablePath()
        head.move(to: b)
        head.addLine(to: CGPoint(x: base.x - uy * headHalf, y: base.y + ux * headHalf))
        head.addLine(to: CGPoint(x: base.x + uy * headHalf, y: base.y - ux * headHalf))
        head.closeSubpath()
        ctx.saveGState()
        ctx.addPath(head)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.75))
        ctx.setLineWidth(2 * s)
        ctx.strokePath()
        ctx.addPath(head)
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }

    private static func font(size: CGFloat, bold: Bool) -> CTFont {
        CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, "zh-Hant" as CFString)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private static func line(_ text: String, size: CGFloat, bold: Bool, color: CGColor) -> CTLine {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font(size: size, bold: bold), kCTForegroundColorAttributeName: color]
        let str = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        return CTLineCreateWithAttributedString(str)
    }

    /// Draws `line` with its top-left at `origin` in the flipped (top-left origin) context.
    private static func draw(_ line: CTLine, ctx: CGContext, topLeft origin: CGPoint, height: CGFloat, descent: CGFloat) {
        ctx.saveGState()
        // CoreText draws with a bottom-left origin: unflip locally around the baseline.
        ctx.textMatrix = .identity
        ctx.translateBy(x: origin.x, y: origin.y + height - descent)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func drawPin(_ ctx: CGContext, number: Int, at p: CGPoint, color: CGColor, scale s: CGFloat, bounds: CGSize) {
        let side = 28 * s
        var r = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        r.origin.x = min(max(0, r.origin.x), bounds.width - side)
        r.origin.y = min(max(0, r.origin.y), bounds.height - side)
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(r.insetBy(dx: -1.5 * s, dy: -1.5 * s))
        ctx.setFillColor(color)
        ctx.fill(r)
        ctx.restoreGState()
        let l = line("\(number)", size: 17 * s, bold: true, color: CGColor(gray: 0, alpha: 1))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(l, &ascent, &descent, &leading))
        let height = ascent + descent
        draw(l, ctx: ctx, topLeft: CGPoint(x: r.midX - width / 2, y: r.midY - height / 2), height: height, descent: descent)
    }

    private static func drawLabel(_ ctx: CGContext, text: String, at p: CGPoint, color: CGColor, scale s: CGFloat, bounds: CGSize) {
        let l = line(text, size: 22 * s, bold: true, color: color)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(l, &ascent, &descent, &leading))
        let height = ascent + descent
        let pad = 8 * s
        var plate = CGRect(x: p.x, y: p.y, width: width + 2 * pad, height: height + 2 * pad)
        plate.origin.x = min(max(0, plate.origin.x), max(0, bounds.width - plate.width))
        plate.origin.y = min(max(0, plate.origin.y), max(0, bounds.height - plate.height))
        ctx.saveGState()
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.82))
        ctx.fill(plate)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.5 * s)
        ctx.stroke(plate)
        ctx.restoreGState()
        draw(l, ctx: ctx, topLeft: CGPoint(x: plate.minX + pad, y: plate.minY + pad), height: height, descent: descent)
    }
}
