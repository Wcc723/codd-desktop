#if DEBUG
import AppKit
import Darwin

/// `-CODDMetrics YES` (Debug only): measures the docs/ARCHITECTURE.md budgets that the shell
/// owns and prints one `METRIC` line each, then exits.
/// - launch: process start → main window laid out and drawn with the sidebar rows loaded
///   (budget: launch to interactive sidebar < 400 ms).
/// - switch: `show(session)` + layout + draw of the window for every session, hot (budget
///   < 16 ms). Done twice; the first pass warms caches, the second is reported.
/// - footprint: `phys_footprint` after the measurements (budget: app base < 80 MB).
/// - `-CODDMetricsDelay <s>`: wait first (real-holder mode discovers and spawns its sessions
///   asynchronously; with `-codd-spawn-shell /tmp -codd-spawn-count 4` the switches go through
///   real libghostty terminals: cold on the first pass, hot on the later ones). The launch metric
///   is skipped then.
/// - `-CODDMetricsSessions <n>` (M5 D16): cycle only the first n sessions of the sidebar order (n
///   at most the hot tier's 6 is all hot after the first pass; all of 15 in order is all cold).
///   The summary line gains `sessions=<n> hot=<n> cold=<n>`, and with `-CODDMetricsVerbose` each
///   switch line names the tier the terminal came from (`tier=hot|cold`, read before the switch).
@MainActor
enum DebugMetrics {
    /// Call right after the main window was shown in `applicationDidFinishLaunching`.
    static func run(app: AppDelegate) {
        let delay = max(0, UserDefaults.standard.double(forKey: "CODDMetricsDelay"))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let main = app.mainWindow, let window = main.window else { exit(1) }
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let rows = main.sidebar.outline.numberOfRows
            if delay == 0, let start = LaunchTiming.processStart() {
                let ms = Date().timeIntervalSince(start) * 1000
                print(String(format: "METRIC launch_to_sidebar_ms=%.0f rows=%d (budget < 400)", ms, rows))
            }
            Task { @MainActor in
                await measureSwitches(main: main, window: window, app: app)
                if let footprint = physFootprint() {
                    print(String(format: "METRIC phys_footprint_mb=%.1f (budget < 80)", Double(footprint) / 1_048_576))
                }
                // Holders outlive the app; only the connections close (as on a normal quit).
                app.terminalHub?.shutdown()
                app.holderStore?.shutdown()
                app.removeMockNotes()
                exit(0)
            }
        }
    }

    /// One switch = `show` + the observation loops that react to it (they re-run on the next
    /// main-actor turns, so we yield until they have) + layout + draw.
    private static func measureSwitches(main: MainWindowController, window: NSWindow, app: AppDelegate) async {
        let all = main.sidebar.snapshot.sessionOrder
        let limit = UserDefaults.standard.integer(forKey: "CODDMetricsSessions")
        let order = limit > 0 ? Array(all.prefix(limit)) : all
        let verbose = UserDefaults.standard.bool(forKey: "CODDMetricsVerbose")
        var samples: [Double] = []
        var hot = 0, cold = 0
        let passes = max(2, UserDefaults.standard.integer(forKey: "CODDMetricsPasses"))
        for pass in 0..<passes {
            if pass > 0, verbose, let footprint = physFootprint() {
                print(String(format: "METRIC pass %d footprint_mb=%.1f", pass, Double(footprint) / 1_048_576))
            }
            for id in order {
                // Before the switch: whether the terminal it will show still had a surface.
                let tier = tierName(app: app, session: id)
                let t0 = DispatchTime.now().uptimeNanoseconds
                main.show(id)
                for _ in 0..<3 { await Task.yield() }
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                if pass == passes - 1 {
                    samples.append(dt)
                    if tier == "cold" { cold += 1 } else if tier == "hot" { hot += 1 }
                    if verbose { print(String(format: "METRIC switch %@ %.2f ms tier=%@", id, dt, tier)) }
                }
            }
        }
        samples.sort()
        guard let max = samples.last else { return }
        let p50 = samples[samples.count / 2]
        print(String(format: "METRIC session_switch_ms p50=%.2f max=%.2f n=%d sessions=%d hot=%d cold=%d (budget < 16)",
                     p50, max, samples.count, order.count, hot, cold))
    }

    /// The tier of the terminal `show(session)` would put on screen: `hot` (already on screen or
    /// still holding its surface), `cold` (a new surface and a replay), `mock` (no terminals).
    private static func tierName(app: AppDelegate, session id: SessionID) -> String {
        guard let hub = app.terminalHub else { return "mock" }
        switch hub.tier(of: TerminalTarget(sessionID: id, tab: app.shell.tab(for: id))) {
        case .visible, .hot: return "hot"
        case .cold: return "cold"
        }
    }

    /// `phys_footprint` (what Activity Monitor calls Memory).
    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
#endif
