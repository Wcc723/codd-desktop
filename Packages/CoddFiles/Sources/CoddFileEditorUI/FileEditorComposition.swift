import AppKit
import CoddUI

/// The FileEditor artboard laid out from this package's views (1440 × 900): a rail placeholder
/// (72), the tree (264), and the main column with the tab strip, toolbar, banner, an `NSView` slot
/// for the code view (a placeholder here) and the status bar (`● MCP …`, the editor's items,
/// `⌘K`). The demo and the render test use it; the app builds its own layout from the same views.
public final class FileEditorComposition: FlippedView {
    public let tree: FileTreeView
    public let tabs: EditorTabStripView
    public let toolbar: EditorToolbarView
    public let banner: DiskChangeBannerView
    public let statusItems: EditorStatusItemsView
    /// The code view's slot.
    public let codeSlot: NSView
    private let rail = RailPlaceholderView()
    private let statusBar = PanelView(fill: Palette.bgSoft, edges: [.top], edgeColor: Palette.line)
    private let mcpLabel = Label.make(style: TextStyle.mono(10.5, Palette.dim, tracking: 0.04))
    private let kbd = ChipView.kbd("⌘K")

    public init(tree: FileTreeModelView = FileEditorSamples.tree(), tabs: EditorTabStripModel = FileEditorSamples.tabs(),
                toolbar: EditorToolbarModel = FileEditorSamples.toolbar(), banner: DiskChangeBannerModel? = FileEditorSamples.banner(),
                status: EditorStatusModel = FileEditorSamples.status(), mcp: String = "MCP 127.0.0.1:47821 · 3 clients",
                codeView: NSView? = nil) {
        self.tree = FileTreeView(model: tree)
        self.tabs = EditorTabStripView(model: tabs)
        self.toolbar = EditorToolbarView(model: toolbar)
        self.banner = DiskChangeBannerView(model: banner ?? .fileChanged(aiSession: nil, time: nil))
        self.banner.isHidden = banner == nil
        statusItems = EditorStatusItemsView(model: status)
        codeSlot = codeView ?? CodePlaceholderView()
        super.init(frame: NSRect(x: 0, y: 0, width: 1440, height: 900))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let lamp = NSMutableAttributedString(attributedString: TextStyle(font: Typeface.mono(10.5), color: Palette.success,
                                                                         shadow: Draw.glow(Palette.success.withAlphaComponent(0.55), radius: 6))
            .string("● "))
        lamp.append(TextStyle.mono(10.5, Palette.dim, tracking: 0.04).string(mcp))
        mcpLabel.attributedStringValue = lamp
        for view in [rail, self.tree, self.tabs, self.toolbar, self.banner, codeSlot, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
        }
        for view in [mcpLabel, statusItems, kbd] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = true
            statusBar.addSubview(view)
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        let height = bounds.height
        rail.frame = CGRect(x: 0, y: 0, width: Metrics.railWidth, height: height)
        tree.frame = CGRect(x: Metrics.railWidth, y: 0, width: FileTreeView.width, height: height)
        let x = Metrics.railWidth + FileTreeView.width
        let width = bounds.width - x
        var y: CGFloat = 0
        tabs.frame = CGRect(x: x, y: y, width: width, height: EditorTabStripView.height)
        y += EditorTabStripView.height
        toolbar.frame = CGRect(x: x, y: y, width: width, height: EditorToolbarView.height)
        y += EditorToolbarView.height
        if !banner.isHidden {
            banner.frame = CGRect(x: x, y: y, width: width, height: DiskChangeBannerView.height)
            y += DiskChangeBannerView.height
        }
        let barHeight = Metrics.statusBarHeight
        codeSlot.frame = CGRect(x: x, y: y, width: width, height: max(0, height - barHeight - y))
        statusBar.frame = CGRect(x: x, y: height - barHeight, width: width, height: barHeight)
        // `.statusbar{gap:14px;padding:0 12px}`
        let mcp = mcpLabel.intrinsicContentSize
        mcpLabel.frame = CGRect(x: 12, y: round((barHeight - mcp.height) / 2), width: ceil(mcp.width), height: ceil(mcp.height))
        let k = kbd.intrinsicContentSize
        kbd.frame = CGRect(x: width - 12 - k.width, y: round((barHeight - k.height) / 2), width: k.width, height: k.height)
        let itemsX = mcpLabel.frame.maxX + 14
        statusItems.frame = CGRect(x: itemsX, y: 0, width: max(0, kbd.frame.minX - 14 - itemsX), height: barHeight)
    }

    public override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
    }
}

/// `.rail` stand-in (72 pt): the four rail items with NOTES on, so the composition reads like the
/// artboard. The app draws its real rail.
final class RailPlaceholderView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bg)
        Draw.fill(CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height), Palette.line)
        var y: CGFloat = 56
        for (icon, label, on) in [(Icon.sessions, "Sessions", false), (.notes, "Notes", true), (.status, "Status", false),
                                  (.settings, "Settings", false)] {
            let item = CGRect(x: 6, y: y, width: 60, height: 50)
            if on {
                Draw.hGradient(item, from: Palette.amberGlow, to: Palette.amberGlow.withAlphaComponent(0))
                Draw.fill(CGRect(x: item.minX, y: item.minY, width: 2, height: item.height), Palette.amber)
            }
            let color = on ? Palette.amber : Palette.dim
            IconRenderer.draw(icon, in: CGRect(x: item.midX - 10, y: item.minY + 9, width: 20, height: 20), color: color, flipped: true)
            let text = TextStyle.caps(9, color, tracking: 0.06).string(label)
            Draw.text(text, x: item.midX - Draw.width(text) / 2, centerY: item.minY + 39)
            y += 54
        }
    }
}

/// The code view's placeholder (black, like `.fe-code`).
final class CodePlaceholderView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, .black)
        Draw.dashedRect(bounds.insetBy(dx: 12, dy: 12), color: Palette.line)
        let text = TextStyle.mono(12, Palette.dimmer).string("// CODE VIEW · CoddCodeEditor CodeEditorView（NSView slot）")
        Draw.text(text, x: (bounds.width - Draw.width(text)) / 2, centerY: bounds.midY)
    }
}

/// Offscreen rendering in sRGB (the artboard's color space), for the demo and the tests: the view
/// is laid out in a borderless window that is never ordered in and drawn with `cacheDisplay`.
@MainActor
public enum FileEditorSnapshot {
    public static func sRGBBitmap(for size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB)
        rep?.size = size
        return rep
    }

    public static func render(_ view: NSView, size: NSSize, scale: CGFloat = 2) -> NSBitmapImageRep? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let container = PanelView(fill: Palette.bg)
        container.frame = NSRect(origin: .zero, size: size)
        window.contentView = container
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        defer {
            view.removeFromSuperview()
            window.contentView = nil
            window.close()
        }
        guard let rep = sRGBBitmap(for: size, scale: scale) else { return nil }
        container.cacheDisplay(in: container.bounds, to: rep)
        return rep
    }

    public static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
