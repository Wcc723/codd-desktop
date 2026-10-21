import AppKit
import CoddCleanupUI
import CoddUI

// codd-cleanup-demo: the Cleanup page at 1368 × 900 (the Cleanup artboard minus the 72 px rail:
// the page 1368 × 876 and a status bar placeholder), fed by `CleanupSamples`.
//
//   codd-cleanup-demo --fonts <repo>/App/Fonts --snapshot <dir> [--only <name>]
//       renders every composition (or one) to <dir>/<name>.png offscreen and exits. It never opens
//       a window on screen and never activates (activation policy .prohibited).

@MainActor
struct Demo {
    static let size = CGSize(width: 1368, height: 900)

    struct Shot {
        let name: String
        let model: CleanupPageModel
        var width: CGFloat = 1368
        /// Render the whole scrolled page instead of the first 876 px.
        var full = false
        var scroll: CGFloat = 0
    }

    static var shots: [Shot] {
        [
            Shot(name: "artboard", model: CleanupSamples.artboard),
            Shot(name: "artboard-as-drawn", model: CleanupSamples.artboardAsDrawn),
            Shot(name: "artboard-full", model: CleanupSamples.artboard, full: true),
            Shot(name: "artboard-as-drawn-full", model: CleanupSamples.artboardAsDrawn, full: true),
            Shot(name: "sessions", model: CleanupSamples.sessions),
            Shot(name: "files", model: CleanupSamples.files),
            Shot(name: "condense-idle", model: CleanupSamples.page(condense: .idle, withPreview: false)),
            Shot(name: "condense-running", model: CleanupSamples.page(condense: .running(elapsed: "12s"), withPreview: false)),
            Shot(name: "condense-failed", model: CleanupSamples.page(condense: .failed("claude -p 在 180 秒內沒有完成，已停止"),
                                                                     withPreview: false)),
            Shot(name: "condense-disabled", model: CleanupSamples.page(condense: .idle, withPreview: false,
                                                                       disabledReason: "測試資料根目錄只用 -codd-claude-path")),
            Shot(name: "empty", model: {
                var model = CleanupSamples.files
                model.rows = []
                model.selected = []
                return model
            }()),
            Shot(name: "narrow", model: CleanupSamples.artboard, width: 1000, full: true),
        ]
    }

    let fontsDir: URL?
    let snapshotDir: URL?
    let only: String?

    init(arguments: [String]) {
        var fonts: URL?
        var snapshot: URL?
        var only: String?
        var index = 1
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "--fonts": fonts = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--snapshot": snapshot = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--only": only = value; index += 1
            default:
                print("usage: codd-cleanup-demo [--fonts <dir>] --snapshot <dir> [--only <name>]")
                exit(2)
            }
            index += 1
        }
        fontsDir = fonts
        snapshotDir = snapshot
        self.only = only
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .darkAqua)
        if let fontsDir, !Typeface.registerFonts(in: fontsDir) { print("warning: CODD fonts not found in \(fontsDir.path)") }
        guard let snapshotDir else {
            print("usage: codd-cleanup-demo [--fonts <dir>] --snapshot <dir> [--only <name>] (offscreen only)")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        let shots = Self.shots.filter { only == nil || $0.name == only }
        if shots.isEmpty {
            print("unknown composition \(only ?? ""); one of: \(Self.shots.map(\.name).joined(separator: ", "))")
            exit(2)
        }
        for shot in shots { render(shot, to: snapshotDir) }
        exit(0)
    }

    private func render(_ shot: Shot, to dir: URL) {
        let page = CleanupPageView(model: shot.model)
        var height = Demo.size.height
        if shot.full {
            page.frame = CGRect(x: 0, y: 0, width: shot.width, height: Demo.size.height - StatusBarPlaceholder.height)
            height = ceil(page.documentHeight) + StatusBarPlaceholder.height
        }
        let area = Composition(page: page)
        guard let rep = ViewSnapshot.render(area, size: CGSize(width: shot.width, height: height)) else {
            print("cannot render \(shot.name)")
            return
        }
        do {
            try ViewSnapshot.writePNG(rep, to: dir.appendingPathComponent("\(shot.name).png"))
            print("wrote \(shot.name).png (\(Int(shot.width)) × \(Int(height)))")
        } catch {
            print("cannot write \(shot.name): \(error)")
        }
    }
}

/// The page above a 24 px status bar placeholder (the app's own bar, drawn as on the artboard).
final class Composition: FlippedView {
    let page: CleanupPageView
    let bar = StatusBarPlaceholder()

    init(page: CleanupPageView) {
        self.page = page
        super.init(frame: .zero)
        addSubview(page)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        page.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height - StatusBarPlaceholder.height)
        bar.frame = CGRect(x: 0, y: bounds.height - StatusBarPlaceholder.height, width: bounds.width, height: StatusBarPlaceholder.height)
    }
}

/// The artboard's `.statusbar` (24 px, --bg-soft, 1 px --line top, 10.5 --dim).
final class StatusBarPlaceholder: NSView {
    static let height: CGFloat = 24

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Draw.fill(bounds, Palette.bgSoft)
        Draw.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1), Palette.line)
        let dim = TextStyle.mono(10.5, Palette.dim, tracking: 0.04)
        let ok = TextStyle.mono(10.5, Palette.success, tracking: 0.04)
        let amber = TextStyle.mono(10.5, Palette.amber, tracking: 0.04)
        let mid = bounds.midY
        var x: CGFloat = 12
        x += Draw.text(ok.string("●"), x: x, centerY: mid)
        x += Draw.text(dim.string(" MCP 127.0.0.1:47821 · 3 clients"), x: x, centerY: mid) + 14
        x += Draw.text(dim.string("hooks "), x: x, centerY: mid)
        x += Draw.text(ok.string("●"), x: x, centerY: mid)
        Draw.text(dim.string(" ok"), x: x, centerY: mid)
        let kbd = KbdView.style(.regular)
        let kbdWidth = kbd.size(for: "⌘K").width
        var right = bounds.width - 12 - kbdWidth
        kbd.draw("⌘K", x: right, centerY: mid)
        let runs: [NSAttributedString] = [dim.string("13 live · "), amber.string("◆ 3"), dim.string(" · "), ok.string("● 4")]
        let total = runs.map(Draw.width).reduce(0, +)
        right -= 14 + total
        for run in runs { right += Draw.text(run, x: right, centerY: mid) }
    }
}

MainActor.assumeIsolated {
    Demo(arguments: CommandLine.arguments).run()
}
