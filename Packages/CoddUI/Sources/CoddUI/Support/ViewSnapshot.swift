import AppKit

/// Renders views to bitmaps without showing them: the view is laid out in an offscreen borderless
/// window (never ordered in) and drawn with `cacheDisplay`, so it works with a locked screen, in
/// `swift test` and from command-line demos (`--snapshot`). `cacheDisplay` runs every view's
/// `draw(_:)`; layer-only effects (the hover / focus glows, which are layer shadows) are not drawn.
@MainActor
public enum ViewSnapshot {
    /// The size `view` wants at `width` (nil: its own fitting width).
    public static func fittingSize(of view: NSView, width: CGFloat? = nil) -> NSSize {
        let wasAutoresizing = view.translatesAutoresizingMaskIntoConstraints
        view.translatesAutoresizingMaskIntoConstraints = false
        var constraint: NSLayoutConstraint?
        if let width {
            constraint = view.widthAnchor.constraint(equalToConstant: width)
            constraint?.isActive = true
        }
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        constraint?.isActive = false
        view.translatesAutoresizingMaskIntoConstraints = wasAutoresizing
        return NSSize(width: ceil(width ?? size.width), height: ceil(size.height))
    }

    /// Lays `view` out at `size` (nil: its fitting size at `width`) on `background` and renders it at
    /// `scale` pixels per point. The view is detached from any superview first.
    public static func render(_ view: NSView, size: NSSize? = nil, width: CGFloat? = nil, scale: CGFloat = 2,
                              background: NSColor = Palette.bg) -> NSBitmapImageRep? {
        renderView(view, size: size, width: width, scale: scale, background: background) { _ in }
    }

    /// ``render(_:size:width:scale:background:)`` that calls `prepare` with the offscreen window once
    /// the view is in it and laid out, before drawing: e.g. to focus a control
    /// (``KeyboardFocus/focusAsKeyboardNavigation(_:)``, with ``KeyboardFocus/keyWindowOverride``).
    public static func render(_ view: NSView, size: NSSize? = nil, width: CGFloat? = nil, scale: CGFloat = 2,
                              background: NSColor = Palette.bg, prepare: (NSWindow) -> Void) -> NSBitmapImageRep? {
        renderView(view, size: size, width: width, scale: scale, background: background, prepare: prepare)
    }

    private static func renderView(_ view: NSView, size: NSSize?, width: CGFloat?, scale: CGFloat, background: NSColor,
                                   prepare: (NSWindow) -> Void) -> NSBitmapImageRep? {
        view.removeFromSuperview()
        let target = size ?? fittingSize(of: view, width: width)
        guard target.width >= 1, target.height >= 1 else { return nil }
        let container = PanelView(fill: background)
        container.frame = NSRect(origin: .zero, size: target)
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = container
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        prepare(window)
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width * scale), pixelsHigh: Int(target.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = target
        container.cacheDisplay(in: container.bounds, to: rep)
        view.removeFromSuperview()
        window.contentView = nil
        window.close()
        return rep
    }

    /// Writes `rep` as PNG (creating the directory).
    public static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }

    /// Pixels that differ from `background` by more than `tolerance` in any channel (0...255); a
    /// rendering smoke test's "not blank" measure.
    public static func pixelsDiffering(from background: NSColor, in rep: NSBitmapImageRep, tolerance: Int = 8) -> Int {
        guard let bg = background.usingColorSpace(.sRGB) else { return 0 }
        let reference = [bg.redComponent, bg.greenComponent, bg.blueComponent].map { Int(($0 * 255).rounded()) }
        var count = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let pixel = [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
                if zip(pixel, reference).contains(where: { abs($0 - $1) > tolerance }) { count += 1 }
            }
        }
        return count
    }

    /// The sRGB color of the pixel under point `point` (flipped view coordinates, top-left origin).
    public static func color(at point: CGPoint, in rep: NSBitmapImageRep) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / max(1, rep.size.width)
        let x = Int(point.x * scale)
        let y = Int(point.y * scale)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }
}
