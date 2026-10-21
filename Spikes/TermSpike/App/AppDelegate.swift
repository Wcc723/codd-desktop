import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: LaunchMode
    private var windowController: SpikeWindowController?

    init(mode: LaunchMode) {
        self.mode = mode
    }

    func applicationDidFinishLaunching(_: Notification) {
        NSApp.mainMenu = MainMenu.make()
        switch mode {
        case let .interactive(options):
            let controller = SpikeWindowController(options: options)
            windowController = controller
            controller.showWindow(nil)
            NSApp.activate()
            print("TermSpike interactive window open (\(BuildInfo.configuration) build).")
        case let .probe(outputDirectory):
            Task { @MainActor in
                let status = await ProbeRunner(outputDirectory: outputDirectory).run()
                Self.finish(status)
            }
        case let .benchWorker(spec):
            Task { @MainActor in
                let status = await BenchWorker(spec: spec).run()
                Self.finish(status)
            }
        case .bench, .report, .invalid:
            Self.finish(64) // handled in main.swift
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        if case .interactive = mode { return true }
        // CLI modes exit on their own.
        return false
    }

    func applicationWillTerminate(_: Notification) {
        guard let windowController else { return }
        print(windowController.latencyReport())
        windowController.shutdown()
    }

    /// Flushes stdout and exits without running AppKit teardown (CLI modes).
    static func finish(_ status: Int32) {
        fflush(stdout)
        fflush(stderr)
        exit(status)
    }
}
