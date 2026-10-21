#if DEBUG
import AppKit
import CoddSettingsUI
import CoddUI

/// Debug-only launch arguments (never active in Release):
/// - `-CODDSnapshotDir <dir>`: after launch, writes PNGs of the main window for several
///   sessions plus the menu bar panel, the bundle icon and the Dock tile frames, then quits.
/// - `-CODDSelfTest YES`: fuzzes model mutations against the real NSOutlineView, checks that
///   rows always match the snapshot, the shortcuts, the title bar and that hiding the app stops
///   every UI timer; prints `SELFTEST OK` / `SELFTEST FAIL`, exits 0 / 1.
/// - `-CODDHideAfterLaunch YES`: hides the app 1 s after launch (to measure hidden idle CPU).
/// - `-CODDMetrics YES`: measures launch, session switch and memory (`DebugMetrics`), exits.
@MainActor
enum DebugHooks {
    static func run(app: AppDelegate) {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "CODDMetrics") {
            DebugMetrics.run(app: app)
            return
        }
        if defaults.bool(forKey: "CODDHideAfterLaunch") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                NSApp.hide(nil)
            }
        }
        if let dir = defaults.string(forKey: "CODDSnapshotDir") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                await snapshots(app: app, dir: URL(fileURLWithPath: dir, isDirectory: true))
                NSApp.terminate(nil)
            }
        } else if defaults.bool(forKey: "CODDSelfTest") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.8))
                var test = OutlineSelfTest(app: app)
                var ok = test.run() && test.checkShortcutsAndChrome()
                if ok, let window = app.mainWindow?.window { ok = await timersStopWhenHidden(app: app, window: window) }
                print(ok ? "SELFTEST OK" : "SELFTEST FAIL")
                // exit() skips applicationWillTerminate: the mock notebook folder goes here (D35).
                app.removeMockNotes()
                exit(ok ? 0 : 1)
            }
        }
    }

    /// The 1 Hz clock runs exactly while the window is on screen (the pane header always shows
    /// a duration) and stops when the app is hidden; waiting lamps pulse through Core Animation
    /// (no app timer). Needs the window on screen: with a locked / asleep display run with
    /// `-CODDForceVisibleTimers YES`, otherwise the check reports SKIPPED instead of passing
    /// vacuously.
    private static func timersStopWhenHidden(app: AppDelegate, window: NSWindow) async -> Bool {
        let ticker = UITicker.shared
        // A launch the system denied activation still brings the window up; a background run
        // (`AppActivation`) leaves it behind the user's windows.
        if !AppActivation.isBackground { window.orderFrontRegardless() }
        try? await Task.sleep(for: .milliseconds(600))
        guard UITicker.isOnScreen(window) else {
            print("SELFTEST timers SKIPPED (window not on screen; use -CODDForceVisibleTimers YES)")
            return true
        }
        guard let main = app.mainWindow else { return false }
        var ok = true
        func expect(_ condition: Bool, _ what: String) {
            if !condition { print("SELFTEST timers FAIL: \(what)"); ok = false }
        }
        expect(ticker.isSecondTimerRunning, "1 Hz clock off while visible")
        // A waiting session in the header: its lamp pulses (CA animation, not a timer).
        app.sessionStore.session("s1")?.state = .waiting
        app.sessionStore.session("s1")?.waitingReason = .permission
        main.show("s1")
        try? await Task.sleep(for: .milliseconds(300))
        expect(ticker.pulseSubscriberCount > 0, "no lamp pulses with a waiting session shown")
        // Focus mode: the header still shows durations, so the 1 Hz clock stays on.
        main.split.sidebarItem.isCollapsed = true
        try? await Task.sleep(for: .milliseconds(300))
        expect(ticker.isSecondTimerRunning, "1 Hz clock off in focus mode")
        main.split.sidebarItem.isCollapsed = false

        NSApp.hide(nil)
        try? await Task.sleep(for: .milliseconds(600))
        expect(!ticker.isSecondTimerRunning, "1 Hz clock on while the app is hidden")
        NSApp.unhideWithoutActivation()
        if !AppActivation.isBackground { window.orderFrontRegardless() }
        try? await Task.sleep(for: .milliseconds(600))
        expect(ticker.isSecondTimerRunning, "1 Hz clock not restarted after unhide")
        if ok { print("SELFTEST timers OK (visible 1Hz on, lamps pulse via CA \(ticker.pulseSubscriberCount), hidden 1Hz off)") }
        return ok
    }

    // MARK: Snapshots

    private static func snapshots(app: AppDelegate, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The bundle icon as the system renders it, and the Dock tile's frames as CODD draws them
        // (`dock-normal` is only drawn for comparison: the live tile shows the bundle icon then).
        if let icon = NSApp.applicationIconImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: icon) {
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("app-icon.png"))
        }
        writeDockTileFrames(to: dir)
        guard let main = app.mainWindow, let window = main.window else { return }
        let plan: [(String, SessionID, Bool)] = [("main-s1", "s1", false), ("main-s2", "s2", false), ("main-s3", "s3", false),
                                                 ("main-s4", "s4", false), ("main-s9-zsh", "s9", true),
                                                 ("main-s14", "s14", false), ("main-s12", "s12", false)]
        for (name, id, zsh) in plan {
            main.show(id)
            if zsh {
                app.shell.selectFirstShellTab(in: id, kind: .claude)
            } else {
                app.shell.select(.claude, in: id)
            }
            try? await Task.sleep(for: .milliseconds(450))
            write(window, to: dir.appendingPathComponent("\(name).png"))
        }
        app.shell.footerExpanded = true
        main.show("s1")
        try? await Task.sleep(for: .milliseconds(450))
        write(window, to: dir.appendingPathComponent("main-footer-expanded.png"))
        app.shell.footerExpanded = false
        if let button = app.statusItem?.button {
            button.performClick(nil)
            try? await Task.sleep(for: .milliseconds(600))
            if let panel = NSApp.windows.first(where: { $0 is MenuBarPanel && $0.isVisible }) {
                write(panel, to: dir.appendingPathComponent("menubar-panel.png"))
            }
            app.statusItem?.closePanel()
        }
        app.showQuickSwitch(nil)
        try? await Task.sleep(for: .milliseconds(400))
        if let palette = NSApp.windows.first(where: { $0 is PalettePanel && $0.isVisible }) {
            write(palette, to: dir.appendingPathComponent("palette.png"))
        }
        print("SNAPSHOTS \(dir.path)")
    }

    /// `dock-normal.png`, `dock-dim.png`, `dock-lit.png` (512 px, the bitmaps the tile shows).
    static func writeDockTileFrames(to dir: URL) {
        for frame in DockTileFrame.allCases {
            guard let image = DockTileArt.cgImage(frame) else { continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("dock-\(frame.rawValue).png"))
        }
    }

    /// Layout sweep: the window's size against its minimum, and the views whose own fitting width
    /// is the widest (the ones that hold a window wider than its minimum), as `LAYOUT …` lines.
    static func logLayout(_ window: NSWindow, name: String) {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.bounds.size
        print(String(format: "LAYOUT %@ content=%.0fx%.0f min=%.0fx%.0f fitting=%.0fx%.0f", name, size.width, size.height,
                     window.minSize.width, window.minSize.height, content.fittingSize.width, content.fittingSize.height))
        var rows: [(depth: Int, line: String)] = []
        func visit(_ view: NSView, depth: Int) {
            guard depth <= 9, !view.isHidden else { return }
            let fitting = view.fittingSize
            if fitting.width > 0, fitting.width >= view.frame.width - 0.5, view.frame.width > 120 || fitting.width > 160 {
                rows.append((depth, String(format: "%@%@ frame=%.0fx%.0f fitting=%.0fx%.0f", String(repeating: " ", count: depth),
                                           String(describing: type(of: view)), view.frame.width, view.frame.height,
                                           fitting.width, fitting.height)))
            }
            for sub in view.subviews { visit(sub, depth: depth + 1) }
        }
        visit(content, depth: 0)
        for row in rows.prefix(80) { print("LAYOUT   " + row.line) }
        // The views that resist compression above the window's stay-put priority (500): together
        // they are the window's real minimum width.
        func resists(_ view: NSView, path: String, depth: Int) {
            guard !view.isHidden, depth < 24 else { return }
            let name = String(describing: type(of: view))
            let here = path.isEmpty ? name : path + ">" + name
            let intrinsic = view.intrinsicContentSize.width
            let priority = view.contentCompressionResistancePriority(for: .horizontal).rawValue
            if intrinsic > 12, priority > 500, view.frame.width > 0 {
                var text = ""
                if let field = view as? NSTextField { text = " \"" + field.stringValue.prefix(24) + "\"" }
                if let button = view as? NSButton { text = " \"" + button.title.prefix(24) + "\"" }
                print(String(format: "LAYOUT   resist %.0f p=%.0f %@%@", intrinsic, priority,
                             String(here.suffix(110)), text))
            }
            for sub in view.subviews { resists(sub, path: here.count > 300 ? name : here, depth: depth + 1) }
        }
        resists(content, path: "", depth: 0)
        // Every view of each split column with its frame, intrinsic width and compression priority.
        // (A window without a split, Settings: its whole content, deeper.)
        if ProcessInfo.processInfo.environment["CODD_LAYOUT_TREE"] == "1" {
            let split = content.descendant(ofType: NSSplitView.self)
            let maxDepth = split == nil ? 16 : 8
            func tree(_ view: NSView, depth: Int) {
                guard depth <= maxDepth, !view.isHidden else { return }
                var text = ""
                if let field = view as? NSTextField { text = " \"" + field.stringValue.prefix(20) + "\"" }
                if let button = view as? NSButton { text = " \"" + button.title.prefix(20) + "\"" }
                print(String(format: "LAYOUTTREE %@%@ x=%.0f y=%.0f w=%.0f h=%.0f iw=%.0f p=%.0f%@", String(repeating: ". ", count: depth),
                             String(describing: type(of: view)), view.frame.minX, view.frame.minY, view.frame.width, view.frame.height,
                             view.intrinsicContentSize.width, view.contentCompressionResistancePriority(for: .horizontal).rawValue, text))
                for sub in view.subviews where sub.frame.height > 0 { tree(sub, depth: depth + 1) }
            }
            for column in split?.arrangedSubviews ?? [content] { tree(column, depth: 0) }
        }
        // `CODD_LAYOUT_EXPLAIN=<class>`: the horizontal constraints of the first view of that class.
        // `A>B:2` finds the first A, then the second B inside it.
        if let wanted = ProcessInfo.processInfo.environment["CODD_LAYOUT_EXPLAIN"] {
            func all(_ view: NSView, named name: String) -> [NSView] {
                (String(describing: type(of: view)) == name ? [view] : []) + view.subviews.flatMap { all($0, named: name) }
            }
            var current: NSView? = content
            for step in wanted.split(separator: ">") {
                let parts = step.split(separator: ":")
                let index = parts.count > 1 ? (Int(parts[1]) ?? 1) - 1 : 0
                let hits = current.map { all($0, named: String(parts[0])) } ?? []
                current = hits.indices.contains(index) ? hits[index] : nil
            }
            if let view = current {
                print("LAYOUTEXPLAIN view \(view) frame=\(view.frame) intrinsic=\(view.intrinsicContentSize)")
                for constraint in view.constraintsAffectingLayout(for: .horizontal) { print("LAYOUTEXPLAIN \(constraint)") }
            }
        }
        // The constraints behind each split column's width (AppKit's own explanation).
        if let split = content.descendant(ofType: NSSplitView.self) {
            for column in split.arrangedSubviews {
                for constraint in column.constraintsAffectingLayout(for: .horizontal)
                where constraint.priority.rawValue > 500 && abs(constraint.constant) >= 20 {
                    print("LAYOUT   column \(Int(column.frame.width)) \(constraint)")
                }
            }
        }
    }

    /// `-codd-settings-all` (layout sweep): every Settings section at the window's current size as
    /// `<stem>-settings-<section>.png` (a moment between them for the pages' deferred layout).
    static func writeSettingsSections(_ controller: SettingsWindowController, stem: String) async {
        guard let window = controller.window else { return }
        let shown = controller.section
        for section in SettingsSection.allCases {
            controller.select(section.rawValue)
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            write(window, to: URL(fileURLWithPath: stem + "-settings-\(section.rawValue).png"))
            if ProcessInfo.processInfo.environment["CODD_LAYOUT_SETTINGS"] == "1" { logLayout(window, name: "settings-\(section.rawValue)") }
        }
        controller.select(shown)
    }

    /// Renders a window's content (layer tree, so lamp sublayers are included) to PNG. With
    /// `includingChildren`, visible child windows (the sidebar hover card, the color popover) are
    /// drawn on top at their place.
    static func write(_ window: NSWindow, to url: URL, includingChildren: Bool = false) {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard view.layer != nil,
              let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.scaleBy(x: scale, y: scale)
        render(view, in: context)
        if includingChildren {
            let contentOnScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
            for child in window.childWindows ?? [] where child.isVisible {
                guard let childView = child.contentView else { continue }
                childView.layoutSubtreeIfNeeded()
                childView.displayIfNeeded()
                context.saveGState()
                // Both in y-up points relative to the main content view's bottom-left corner.
                context.translateBy(x: child.frame.minX - contentOnScreen.minX, y: child.frame.minY - contentOnScreen.minY)
                render(childView, in: context)
                context.restoreGState()
            }
        }
        guard let image = context.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Renders a view's layer tree into a y-up context at the origin (flipped views flipped back).
    private static func render(_ view: NSView, in context: CGContext) {
        guard let layer = view.layer else { return }
        let size = view.bounds.size
        context.saveGState()
        if layer.isGeometryFlipped || view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        context.restoreGState()
    }
}
#endif
