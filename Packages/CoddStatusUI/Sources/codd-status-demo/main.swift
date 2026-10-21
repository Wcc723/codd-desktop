import AppKit
import CoddStatusUI
import CoddUI

// codd-status-demo: the STATUS sidebar (220) and page side by side at 1440 × 1300 (the Status
// artboard minus the rail), fed by `StatusSamples`.
//
//   codd-status-demo --fonts <repo>/App/Fonts --snapshot <dir> [--state <name>]
//       renders every state (or one) to <dir>/<state>.png and, when the page is taller than
//       1300, <dir>/<state>-full.png, then exits.
//   codd-status-demo --fonts <dir> [--state <name>]
//       opens a window (real clock: durations tick; actions print to stdout).
//   codd-status-demo --fonts <dir> --accounts-sweep <dir> [--widths 760,900,…] [--resize-from <pt>] [--state <name>]
//       renders only the ACCOUNTS section at each window width (sidebar 220 + page) to
//       <dir>/accounts-<width>.png; with --resize-from the page is also drawn at that width, live-resized
//       to each width, and <dir>/resize-report.txt counts the views that kept their old drawing.

@MainActor
struct Demo {
    static let size = CGSize(width: 1440, height: 1300)

    let fontsDir: URL?
    let snapshotDir: URL?
    let state: StatusSamples.State?
    let sweepDir: URL?
    let sweepWidths: [CGFloat]
    let resizeFrom: CGFloat?

    init(arguments: [String]) {
        var fonts: URL?
        var snapshot: URL?
        var state: StatusSamples.State?
        var sweep: URL?
        var widths: [CGFloat] = [760, 900, 1000, 1200, 1440, 1900]
        var from: CGFloat?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch argument {
            case "--fonts": fonts = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--snapshot": snapshot = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--accounts-sweep": sweep = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--widths":
                widths = (value ?? "").split(separator: ",").compactMap { Double($0).map { CGFloat($0) } }
                index += 1
            case "--resize-from": from = value.flatMap(Double.init).map { CGFloat($0) }; index += 1
            case "--state":
                state = value.flatMap(StatusSamples.State.init(rawValue:))
                if state == nil {
                    print("unknown state \(value ?? ""); one of: \(StatusSamples.State.allCases.map(\.rawValue).joined(separator: ", "))")
                    exit(2)
                }
                index += 1
            default:
                print("usage: codd-status-demo [--fonts <dir>] [--snapshot <dir>] [--state <name>]"
                      + " [--accounts-sweep <dir> [--widths <list>] [--resize-from <pt>]]")
                exit(2)
            }
            index += 1
        }
        fontsDir = fonts
        snapshotDir = snapshot
        self.state = state
        sweepDir = sweep
        sweepWidths = widths
        resizeFrom = from
    }

    func run() {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        if let fontsDir {
            if !Typeface.registerFonts(in: fontsDir) { print("warning: CODD fonts not found in \(fontsDir.path)") }
        }
        if let sweepDir {
            app.setActivationPolicy(.prohibited)
            try? FileManager.default.createDirectory(at: sweepDir, withIntermediateDirectories: true)
            AccountsSweep(model: StatusSamples.model(state ?? .spec), dir: sweepDir).run(widths: sweepWidths, resizeFrom: resizeFrom)
            exit(0)
        }
        if let snapshotDir {
            app.setActivationPolicy(.prohibited)
            try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
            for state in state.map({ [$0] }) ?? StatusSamples.State.allCases {
                snapshot(state, to: snapshotDir)
            }
            // The main pane at its 560 pt minimum (narrow fallbacks: stacked columns, 2 account columns).
            snapshot(state ?? .spec, to: snapshotDir, width: StatusSidebarView.preferredWidth + 560, suffix: "-narrow")
            exit(0)
        }
        app.setActivationPolicy(.regular)
        interactive(state ?? .spec)
        app.activate()
        app.run()
    }

    /// The sidebar and page in one flipped container.
    final class Area: FlippedView {
        let sidebar: StatusSidebarView
        let page: StatusPageView

        init(actions: StatusPageActions) {
            sidebar = StatusSidebarView(actions: actions)
            page = StatusPageView(actions: actions)
            super.init(frame: CGRect(origin: .zero, size: Demo.size))
            wantsLayer = true
            addSubview(sidebar)
            addSubview(page)
            sidebar.onSelectSection = { [weak self] section in self?.page.scroll(to: section) }
            page.onVisibleSectionChange = { [weak self] section in self?.sidebar.selectedSection = section }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func layout() {
            super.layout()
            sidebar.frame = CGRect(x: 0, y: 0, width: StatusSidebarView.preferredWidth, height: bounds.height)
            page.frame = CGRect(x: StatusSidebarView.preferredWidth, y: 0, width: bounds.width - StatusSidebarView.preferredWidth,
                                height: bounds.height)
        }
    }

    private func snapshot(_ state: StatusSamples.State, to dir: URL, width: CGFloat = Demo.size.width, suffix: String = "") {
        let model = StatusSamples.model(state)
        let fixed = StatusSamples.referenceNow
        /// Renders the area at `height`; returns the page's document height.
        func render(height: CGFloat, name: String) -> CGFloat {
            let area = Area(actions: StatusPageActions())
            area.sidebar.now = { fixed }
            area.page.now = { fixed }
            area.sidebar.calendar = StatusSamples.calendar
            area.page.calendar = StatusSamples.calendar
            area.sidebar.apply(model)
            area.page.apply(model)
            guard let rep = ViewSnapshot.render(area, size: CGSize(width: width, height: height)) else {
                print("cannot render \(name)")
                return height
            }
            do { try ViewSnapshot.writePNG(rep, to: dir.appendingPathComponent(name)) } catch { print("cannot write \(name): \(error)") }
            return area.page.documentHeight
        }
        let stem = state.rawValue + suffix
        let documentHeight = render(height: Demo.size.height, name: "\(stem).png")
        print("wrote \(stem).png")
        if documentHeight > Demo.size.height + 0.5 {
            _ = render(height: ceil(documentHeight), name: "\(stem)-full.png")
            print("wrote \(stem)-full.png (\(Int(ceil(documentHeight))) pt)")
        }
    }

    private func interactive(_ state: StatusSamples.State) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: Demo.size.width, height: 900)),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "codd-status-demo · \(state.rawValue)"
        window.appearance = NSAppearance(named: .darkAqua)
        func log(_ text: String) -> () -> Void { { print("action \(text)") } }
        let actions = StatusPageActions(
            refresh: log("refresh"), togglePause: log("togglePause"), openSessions: log("openSessions"),
            openSession: { print("action openSession \($0)") }, switchAccount: { print("action switchAccount \($0)") },
            addAccount: log("addAccount"), openAutoSwitch: log("openAutoSwitch"), toggleAutoSwitch: log("toggleAutoSwitch"),
            previewHooks: log("previewHooks"), update: log("update"), uninstall: log("uninstall"), removeLegacy: log("removeLegacy"),
            disableDuplicateNotifications: log("disableDuplicateNotifications"), openRemoteSettings: log("openRemoteSettings"))
        let area = Area(actions: actions)
        area.autoresizingMask = [.width, .height]
        window.contentView = area
        let model = StatusSamples.model(state, now: Date())
        area.sidebar.apply(model)
        area.page.apply(model)
        window.center()
        window.makeKeyAndOrderFront(nil)
        Demo.keep = window
    }

    static var keep: NSWindow?
}

MainActor.assumeIsolated {
    Demo(arguments: CommandLine.arguments).run()
}
