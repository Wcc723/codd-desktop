import AppKit
import CoddPreferences
import CoddUI

/// Static CRT scanlines (helmet `.crt-subtle` / `.crt-full`): one 1-pixel-wide image, one window
/// tall, stretched horizontally. Static (no flicker / rolling bar), ignores the mouse. Settings ›
/// 外觀 › CRT 效果 (M3 I3): `關` (default, D15: no overlay at all), `輕微` and `完整` (twice the
/// line alpha).
final class ScanlineOverlayView: NSView {
    private var renderedHeight: Int = 0
    private var renderedAlpha: CGFloat = 0
    /// The line alpha (`subtle` 0.03, `full` 0.06).
    var lineAlpha: CGFloat = ScanlineOverlayView.alpha(for: .subtle) {
        didSet { if lineAlpha != oldValue { needsLayout = true } }
    }

    /// 0 for `.off` (the overlay is then removed, not drawn transparent).
    static func alpha(for mode: CoddPreferences.CRT) -> CGFloat {
        switch mode {
        case .off: 0
        case .subtle: 0.03
        case .full: 0.06
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        let height = Int(bounds.height * scale)
        guard height > 0, height != renderedHeight || lineAlpha != renderedAlpha else { return }
        renderedHeight = height
        renderedAlpha = lineAlpha
        layer?.contentsScale = scale
        layer?.contents = Self.image(height: height, scale: scale, alpha: lineAlpha)
    }

    /// 1 × height image: a faint amber line every 3 points (`rgba(255,176,0,.014)`, 1 of 3).
    private static func image(height: Int, scale: CGFloat, alpha: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: 1, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: 1, green: 176 / 255, blue: 0, alpha: alpha))
        let pitch = max(1, Int((3 * scale).rounded()))
        let line = max(1, Int(scale.rounded()))
        var y = 0
        while y < height {
            context.fill(CGRect(x: 0, y: y, width: 1, height: line))
            y += pitch
        }
        return context.makeImage()
    }
}

/// Window content: the split view (or the onboarding view, M5 D6) plus the (optional) scanline
/// overlay on top.
final class MainContainerViewController: NSViewController {
    private let content: NSViewController
    /// On top of the content while CRT is not `.off`.
    private(set) var overlay: ScanlineOverlayView?
    private(set) var crt: CoddPreferences.CRT = .off

    init(content: NSViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(split: NSSplitViewController) {
        self.init(content: split)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content.view)
        content.view.pinEdges(to: root)
        view = root
        applyCRT(crt)
    }

    /// Settings › 外觀 › CRT 效果, live: `.off` takes the overlay out of the view tree.
    func setCRT(_ mode: CoddPreferences.CRT) {
        guard mode != crt else { return }
        crt = mode
        if isViewLoaded { applyCRT(mode) }
    }

    private func applyCRT(_ mode: CoddPreferences.CRT) {
        guard mode != .off else {
            overlay?.removeFromSuperview()
            overlay = nil
            return
        }
        let overlay = self.overlay ?? ScanlineOverlayView()
        overlay.lineAlpha = ScanlineOverlayView.alpha(for: mode)
        if overlay.superview == nil {
            view.addSubview(overlay)
            overlay.pinEdges(to: view)
        }
        self.overlay = overlay
    }
}
