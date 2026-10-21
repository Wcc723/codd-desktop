import AppKit
import CoddOnboarding
import CoddOnboardingUI
import CoddUI

// codd-onboarding-demo: the wizard fed by `OnboardingSamples`.
//
//   codd-onboarding-demo --fonts <repo>/App/Fonts --snapshot <dir> [--size WxH] [--only <name>]
//       renders every state (or one) offscreen to <dir>/<name>.png at 1440 × 900 and
//       <dir>/<name>-min.png at 1011 × 640 (with --size: only <dir>/<name>-<W>x<H>.png) and exits.
//       The window is never ordered in and the app never activates (activation policy .prohibited).
//   codd-onboarding-demo --fonts <dir>
//       opens a window for manual use (people only; agents always pass --snapshot).

@MainActor
struct Demo {
    struct Shot {
        let name: String
        let model: OnboardingViewModel
        /// Step 2: the row whose group menu is open.
        var menuPath: String?
    }

    static var shots: [Shot] {
        let menuRow = OnboardingSamples.home + "/Github/mysite.github.io"
        return [
            Shot(name: "step1", model: OnboardingSamples.step(.detect)),
            Shot(name: "step2", model: OnboardingSamples.artboard()),
            Shot(name: "step3", model: OnboardingSamples.step(.hooks)),
            Shot(name: "step4", model: OnboardingSamples.step(.notebook)),
            Shot(name: "step5", model: OnboardingSamples.step(.accounts)),
            Shot(name: "step6", model: OnboardingSamples.step(.done)),
            Shot(name: "step1-problems", model: OnboardingSamples.step(.detect, variant: [.claudeMissing, .cswapMissing])),
            Shot(name: "step2-menu", model: OnboardingSamples.artboard(), menuPath: menuRow),
            Shot(name: "step2-hidden", model: OnboardingSamples.step(.importProjects, variant: .showHidden)),
            Shot(name: "step5-nocswap", model: OnboardingSamples.step(.accounts, variant: .cswapMissing)),
            Shot(name: "step6-granted", model: OnboardingSamples.step(.done, variant: .notificationsGranted)),
        ]
    }

    static let sizes: [(suffix: String, size: CGSize)] = [
        ("", CGSize(width: 1440, height: 900)),
        ("-min", OnboardingView.minimumContentSize),
    ]

    let fontsDir: URL?
    let snapshotDir: URL?
    let only: String?
    let size: CGSize?

    init(arguments: [String]) {
        var fonts: URL?
        var snapshot: URL?
        var only: String?
        var size: CGSize?
        var index = 1
        while index < arguments.count {
            let value = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch arguments[index] {
            case "--fonts": fonts = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--snapshot": snapshot = value.map { URL(fileURLWithPath: $0, isDirectory: true) }; index += 1
            case "--only": only = value; index += 1
            case "--size":
                let parts = (value ?? "").lowercased().split(separator: "x").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 1, parts[1] >= 1 else { Self.usage() }
                size = CGSize(width: parts[0], height: parts[1])
                index += 1
            default: Self.usage()
            }
            index += 1
        }
        fontsDir = fonts
        snapshotDir = snapshot
        self.only = only
        self.size = size
    }

    static func usage() -> Never {
        print("usage: codd-onboarding-demo [--fonts <dir>] [--snapshot <dir> [--size WxH] [--only <name>]]")
        exit(2)
    }

    func run() {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .darkAqua)
        if let fontsDir, !Typeface.registerFonts(in: fontsDir) { print("warning: CODD fonts not found in \(fontsDir.path)") }
        guard let snapshotDir else {
            DemoWindow.shared.open()
            app.run()
            return
        }
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        let shots = Self.shots.filter { only == nil || $0.name == only }
        if shots.isEmpty {
            print("unknown state \(only ?? ""); one of: \(Self.shots.map(\.name).joined(separator: ", "))")
            exit(2)
        }
        let sizes = size.map { [("-\(Int($0.width))x\(Int($0.height))", $0)] } ?? Self.sizes
        for shot in shots {
            for (suffix, size) in sizes { render(shot, size: size, to: snapshotDir.appendingPathComponent("\(shot.name)\(suffix).png")) }
        }
        exit(0)
    }

    private func render(_ shot: Shot, size: CGSize, to url: URL) {
        let view = OnboardingView(model: shot.model)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        if let path = shot.menuPath { view.openGroupMenu(for: path) }
        guard let rep = ViewSnapshot.render(view, size: size) else {
            print("cannot render \(url.lastPathComponent)")
            return
        }
        do {
            try ViewSnapshot.writePNG(rep, to: url)
            print("wrote \(url.lastPathComponent) (\(Int(size.width)) × \(Int(size.height)))")
        } catch {
            print("cannot write \(url.lastPathComponent): \(error)")
        }
    }
}

/// Manual mode: one window whose buttons move a sample flow (no probes, nothing written).
@MainActor
final class DemoWindow {
    static let shared = DemoWindow()
    private var window: NSWindow?
    private var view: OnboardingView?
    private var model = OnboardingSamples.step(.detect)

    func open() {
        NSApplication.shared.setActivationPolicy(.regular)
        let view = OnboardingView(model: model, actions: actions())
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: OnboardingView.defaultContentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "首次啟動設定"
        window.contentMinSize = OnboardingView.minimumContentSize
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFront(nil)
        self.window = window
        self.view = view
    }

    private func actions() -> OnboardingActions {
        OnboardingActions(
            next: { [weak self] in self?.move { $0.next() } },
            skip: { [weak self] in self?.move { $0.skip() } },
            back: { [weak self] in self?.move { $0.back() } },
            finish: { NSApplication.shared.terminate(nil) },
            goTo: { [weak self] step in self?.move { _ = $0.go(to: step) } },
            importChanged: { [weak self] selection in
                guard let self else { return }
                self.model.importStep = self.model.importStep.with(selection)
            })
    }

    private func move(_ change: (inout OnboardingFlow) -> Void) {
        var flow = model.flow
        change(&flow)
        var next = OnboardingSamples.step(flow.current)
        next.flow = flow
        next.importStep = model.importStep
        next.stepDetails[.importProjects] = "已選 \(model.importStep.checkedCount) / \(model.importStep.catalog.visibleTotal)"
        model = next
        view?.update(next)
    }
}

MainActor.assumeIsolated {
    Demo(arguments: CommandLine.arguments).run()
}
