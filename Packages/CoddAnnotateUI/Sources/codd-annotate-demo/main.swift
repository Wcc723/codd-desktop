import AppKit
import CoddAnnotateUI
import CoddUI

// codd-annotate-demo: the ImageAnnotate screen at 1368 × 876 (the 1440 × 900 window minus the
// 72 pt rail and the 24 pt status bar) on a made-up 750 × 1334 placeholder with the three R6
// annotations, item 1 selected.
//
//   codd-annotate-demo --fonts <repo>/App/Fonts --snapshot <dir>
//       writes <dir>/annotate-fit.png (Fit = 50 %), <dir>/annotate-200.png (200 %, centered on
//       item 1) and <dir>/annotate-kinds.png (an extra: a cyan text label and a red box added, the
//       arrow selected), offscreen, then exits. Never activates the app or shows a window.
//   codd-annotate-demo --fonts <dir>
//       opens a window (not activated; click it) and prints every onChange / onDone / onCancel.

@MainActor
struct Demo {
    static let size = CGSize(width: 1368, height: 876)
    var fontsDir: URL?
    var snapshotDir: URL?

    init(arguments: [String]) {
        var index = 1
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "--fonts": fontsDir = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--snapshot": snapshotDir = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            default:
                print("usage: codd-annotate-demo [--fonts <dir>] [--snapshot <dir>]")
                exit(2)
            }
            index += 1
        }
    }

    func makeView(kinds: Bool = false) -> ImageAnnotateView {
        var document = ImageAnnotateSamples.document
        if kinds {
            document.items.append(.text(4, x: 40, y: 80, note: "這段文字直接畫在圖上", color: .cyan))
            document.items.append(.rect(5, x: 32, y: 472, w: 686, h: 128, note: "班別卡片", color: .danger))
        }
        let view = ImageAnnotateView(image: ImageAnnotateSamples.placeholderImage(), document: document, header: ImageAnnotateSamples.header)
        view.previewText = ImageAnnotateSamples.previewText
        view.markdownSource = ImageAnnotateSamples.markdownSource
        view.selection = kinds ? 3 : 1
        return view
    }

    func run() {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        if let fontsDir, !Typeface.registerFonts(in: fontsDir) { print("warning: CODD fonts not found in \(fontsDir.path)") }
        if let snapshotDir {
            app.setActivationPolicy(.prohibited)
            snapshot(zoom: .fit, to: snapshotDir.appendingPathComponent("annotate-fit.png"))
            snapshot(zoom: .double, to: snapshotDir.appendingPathComponent("annotate-200.png"))
            snapshot(zoom: .fit, kinds: true, to: snapshotDir.appendingPathComponent("annotate-kinds.png"))
            exit(0)
        }
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "codd-annotate-demo"
        window.appearance = NSAppearance(named: .darkAqua)
        let view = makeView()
        view.onChange = { print("onChange: \($0.items.count) items") }
        view.onDone = { print("onDone: \($0.items.map(\.coordinateText))") }
        view.onCancel = { print("onCancel") }
        window.contentView = view
        // Shown without activating the app (the user clicks it when they want it).
        window.orderBack(nil)
        app.run()
    }

    /// Renders the view offscreen at `size` (a borderless window that is never ordered in).
    func snapshot(zoom: AnnotateZoom, kinds: Bool = false, to url: URL) {
        let view = makeView(kinds: kinds)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: Self.size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let container = PanelView(fill: Palette.bg)
        container.frame = CGRect(origin: .zero, size: Self.size)
        window.contentView = container
        view.frame = container.bounds
        container.addSubview(view)
        container.layoutSubtreeIfNeeded()
        view.zoom = zoom
        if zoom != .fit { view.centerOnSelection() }
        container.layoutSubtreeIfNeeded()
        container.displayIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.size.width * 2), pixelsHigh: Int(Self.size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = Self.size
        container.cacheDisplay(in: container.bounds, to: rep)
        do {
            try ViewSnapshot.writePNG(rep, to: url)
            print("wrote \(url.path) (scale \(Int((view.canvasScale * 100).rounded()))%, \(view.statusText))")
        } catch {
            print("cannot write \(url.path): \(error)")
        }
        window.contentView = nil
        window.close()
    }
}

MainActor.assumeIsolated {
    Demo(arguments: CommandLine.arguments).run()
}
