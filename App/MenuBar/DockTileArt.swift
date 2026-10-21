import AppKit

/// What the Dock tile shows (`DockTileController` picks it, `DockTileArt` draws it).
enum DockTileFrame: String, Equatable, Sendable, CaseIterable {
    /// The system-rendered bundle icon (`NSDockTile.contentView = nil`). `DockTileArt` draws it
    /// only for DEBUG snapshots and the comparison with the bundle icon.
    case normal
    /// The dark half of a blink: the amber cell dimmed.
    case dim
    /// Attention: the amber cell lit, with a soft amber glow.
    case lit
}

/// The d1 icon (`build/icon-candidates/round5/d1-make-icon.py`, the art of `App/AppIcon.icon`)
/// drawn by CODD for the Dock tile's attention frames. The tile's view fills the whole tile, so
/// the art sits on the macOS icon grid: the 1024 art scaled into an 824 px continuous-corner
/// square centered in a 1024 canvas, with the drop shadow and the edge light of the system's
/// rendering of `App/AppIcon.icon` (Default appearance), approximated from that rendering
/// (corner radius, shadow and light measured on `NSWorkspace.icon(forFile:)` of a built CODD.app).
///
/// Each frame is ONE 8-bit sRGB bitmap (512 px, shown at 256 pt): a drawing-handler NSImage of a
/// 512 pt canvas costs about 16 MB in deep-color caches, and the Dock never draws larger than
/// 256 pt @2x. Pure CoreGraphics, no main-actor state: tests and tools draw it anywhere.
enum DockTileArt {
    static let pixels = 512
    /// The macOS icon shape inside the 1024 canvas.
    static let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    /// Fitted to the system shape (continuous corners, rms 0.7 px at 1024).
    static let cornerRadius: CGFloat = 210

    // d1 art (1024 grid, y down).
    static let leftBracket: [CGPoint] = [(352, 192), (192, 192), (192, 832), (352, 832), (352, 736), (288, 736), (288, 288), (352, 288)]
        .map { CGPoint(x: $0.0, y: $0.1) }
    static let rightBracket: [CGPoint] = leftBracket.map { CGPoint(x: 1024 - $0.x, y: $0.y) }
    static let cells: [CGRect] = [(352, 352), (544, 352), (352, 544)].map { CGRect(x: $0.0, y: $0.1, width: 128, height: 128) }
    static let accentCell = CGRect(x: 544, y: 544, width: 128, height: 128)

    /// The colors as the Dock shows them: the system's rendering draws the art's #F5ECD6 and
    /// #FFB84A about 2.5 % darker (measured), the background gradient as is.
    private static func cream() -> CGColor { srgb(239, 230, 208) }
    private static func amber() -> CGColor { srgb(249, 179, 72) }
    /// `lit`: the art's full #FFB84A (a touch brighter than the bundle icon's cell) and its glow.
    private static func litAmber(_ alpha: CGFloat = 1) -> CGColor { srgb(0xFF, 0xB8, 0x4A, alpha) }
    /// `dim`: the amber cell at 30 % over the background.
    private static let dimAmount: CGFloat = 0.30

    /// The frame as an 8-bit bitmap image (`pixels`², `pixels / 2` points).
    static func image(_ frame: DockTileFrame, pixels: Int = DockTileArt.pixels) -> NSImage? {
        guard let cgImage = cgImage(frame, pixels: pixels) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: CGFloat(pixels) / 2, height: CGFloat(pixels) / 2))
    }

    /// The frame as an 8-bit sRGB CGImage (`pixels`²).
    static func cgImage(_ frame: DockTileFrame, pixels: Int = DockTileArt.pixels) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(frame, in: ctx, pixels: CGFloat(pixels))
        return ctx.makeImage()
    }

    /// Draws into a y-up bitmap context of `pixels`². Shadow offsets and blurs are in device
    /// pixels (CoreGraphics ignores the CTM for them), hence `s`.
    static func draw(_ frame: DockTileFrame, in ctx: CGContext, pixels: CGFloat) {
        let s = pixels / 1024
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // The 1024 canvas, y down.
        ctx.translateBy(x: 0, y: pixels)
        ctx.scaleBy(x: s, y: -s)
        ctx.interpolationQuality = .high
        let shape = continuousRect(shapeRect, radius: cornerRadius)

        // Drop shadow (measured: black 24 %, sigma 15, 8 below at 1024).
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 30 * s, color: srgb(0, 0, 0, 0.24))
        ctx.addPath(shape)
        ctx.setFillColor(srgb(20, 20, 20))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        // Background: the art's diagonal gradient #222222 → #070707.
        if let gradient = gradient([(0, srgb(0x22, 0x22, 0x22)), (1, srgb(0x07, 0x07, 0x07))]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: shapeRect.minX, y: shapeRect.minY),
                                   end: CGPoint(x: shapeRect.maxX, y: shapeRect.maxY), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        drawArt(frame, in: ctx, s: s)
        drawEdgeLight(in: ctx)
        ctx.restoreGState()
    }

    /// The brackets and cells in the 1024 art grid mapped into the shape.
    private static func drawArt(_ frame: DockTileFrame, in ctx: CGContext, s: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let scale = shapeRect.width / 1024
        ctx.translateBy(x: shapeRect.minX, y: shapeRect.minY)
        ctx.scaleBy(x: scale, y: scale)
        if frame == .lit {
            // The glow first, so the cream cells and brackets stay crisp on top of it.
            ctx.saveGState()
            ctx.setFillColor(litAmber())
            ctx.setShadow(offset: .zero, blur: 84 * s, color: litAmber())
            ctx.fill(accentCell)
            ctx.setShadow(offset: .zero, blur: 30 * s, color: litAmber(0.85))
            ctx.fill(accentCell)
            ctx.restoreGState()
        }
        ctx.setFillColor(cream())
        for polygon in [leftBracket, rightBracket] {
            ctx.addLines(between: polygon)
            ctx.closePath()
        }
        ctx.fillPath()
        ctx.fill(cells)
        if frame == .dim {
            // Over the background as it is under the cell (the gradient at the cell's center).
            let t = (accentCell.midX + accentCell.midY) / 2048
            let back = 0x22 + (0x07 - 0x22) * t
            let mix = { (value: CGFloat) in (back + (value - back) * dimAmount) / 255 }
            ctx.setFillColor(CGColor(srgbRed: mix(249), green: mix(179), blue: mix(72), alpha: 1))
        } else {
            ctx.setFillColor(frame == .lit ? litAmber() : amber())
        }
        ctx.fill(accentCell)
    }

    /// The system's edge light: a bright rim at the top and the bottom centers that fades toward
    /// the corners, a broader soft part around the corners, a faint line all around and a dark
    /// band low on the sides. Bands of 2 px (1024 canvas) from the edge inward.
    private static func drawEdgeLight(in ctx: CGContext) {
        let sharpProfile: [CGFloat] = [1, 0.66, 0.47, 0.335, 0.16, 0.126, 0.096, 0.078, 0.06, 0.048, 0.036, 0.03, 0.018, 0.012, 0.006]
        let broadProfile: [CGFloat] = [1, 0.92, 0.84, 0.74, 0.64, 0.54, 0.44, 0.34, 0.25, 0.17, 0.1, 0.06, 0.03, 0.01, 0]
        let darkProfile: [CGFloat] = [0, 0.3, 0.42, 0.27, 0.05]
        let white = { (alpha: CGFloat) in srgb(255, 255, 255, alpha) }
        let black = { (alpha: CGFloat) in srgb(0, 0, 0, alpha) }
        let stops: [CGFloat] = [0, 0.42, 0.61, 0.70, 0.78, 0.85, 0.91, 1]
        let sharpWeights: [CGFloat] = [0.73, 0.39, 0.16, 0.10, 0.07, 0.038, 0.016, 0]
        let broadWeights: [CGFloat] = [0, 0, 0.11, 0.09, 0.06, 0.035, 0.01, 0]
        guard let sharp = gradient(zip(stops, sharpWeights).map { ($0, white($1)) }),
              let broad = gradient(zip(stops, broadWeights).map { ($0, white($1)) }),
              let line = gradient([(0, white(0.025)), (1, white(0.1))]),
              let dark = gradient([(0, black(0)), (0.25, black(0.35)), (0.53, black(1)), (0.75, black(0.8)), (1, black(0))])
        else { return }
        let top = CGPoint(x: shapeRect.midX, y: shapeRect.minY)
        let bottom = CGPoint(x: shapeRect.midX, y: shapeRect.maxY)
        let reach: CGFloat = 500
        for band in 0..<sharpProfile.count {
            let depth = CGFloat(band) * 2
            ctx.saveGState()
            ctx.addPath(continuousRect(shapeRect.insetBy(dx: depth + 1, dy: depth + 1), radius: max(0, cornerRadius - depth - 1)))
            ctx.setLineWidth(2)
            ctx.replacePathWithStrokedPath()
            ctx.clip()
            for (center, weight) in [(top, CGFloat(1)), (bottom, 0.62)] {
                ctx.setAlpha(sharpProfile[band] * weight)
                ctx.drawRadialGradient(sharp, startCenter: center, startRadius: 0, endCenter: center, endRadius: reach, options: [])
                ctx.setAlpha(broadProfile[band] * weight)
                ctx.drawRadialGradient(broad, startCenter: center, startRadius: 0, endCenter: center, endRadius: reach, options: [])
            }
            if band == 0 {
                ctx.setAlpha(1)
                ctx.drawLinearGradient(line, start: CGPoint(x: shapeRect.minX, y: 0), end: CGPoint(x: shapeRect.maxX, y: 0), options: [])
            }
            if band < darkProfile.count, darkProfile[band] > 0 {
                ctx.setAlpha(darkProfile[band])
                ctx.drawLinearGradient(dark, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 700), options: [])
            }
            ctx.restoreGState()
        }
    }

    // MARK: Helpers

    /// A rounded rectangle with continuous corners (the curve Apple's icon shapes use; the
    /// constants are the widely used reconstruction of UIKit's): each corner starts 1.528665 r
    /// from the corner along both edges.
    static func continuousRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2 / 1.52866483)
        let path = CGMutablePath()
        let (l, t, rt, b) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        // Corner points in units of r from the corner: TR uses (rt - x·r, t + y·r) and so on.
        func tr(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rt - x * r, y: t + y * r) }
        func br(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rt - x * r, y: b - y * r) }
        func bl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: l + x * r, y: b - y * r) }
        func tl(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: l + x * r, y: t + y * r) }
        typealias Corner = (CGFloat, CGFloat) -> CGPoint
        // One corner from the edge it enters by to the edge it leaves by, as (x, y) along / across.
        func corner(_ p: Corner, swap: Bool) {
            func q(_ a: CGFloat, _ c: CGFloat) -> CGPoint { swap ? p(c, a) : p(a, c) }
            path.addLine(to: q(1.52866483, 0))
            path.addCurve(to: q(0.66993427, 0.06549600), control1: q(1.08849323, 0), control2: q(0.86840689, 0))
            path.addCurve(to: q(0.06549600, 0.66993427), control1: q(0.37487118, 0.17442730), control2: q(0.17442730, 0.37487118))
            path.addCurve(to: q(0, 1.52866483), control1: q(0, 0.86840689), control2: q(0, 1.08849323))
        }
        path.move(to: tl(1.52866483, 0))
        corner(tr, swap: false)
        corner(br, swap: true)
        corner(bl, swap: false)
        corner(tl, swap: true)
        path.closeSubpath()
        return path
    }

    private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private static func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGGradient(colorsSpace: space, colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))
    }
}
