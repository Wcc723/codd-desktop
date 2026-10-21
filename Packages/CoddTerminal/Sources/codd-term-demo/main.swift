import AppKit
import CoddTerminal

// codd-term-demo: one window hosting one CODD terminal on a local PTY.
//
//   swift run --package-path Packages/CoddTerminal --scratch-path .build-terminal codd-term-demo
//   … codd-term-demo --login        # $SHELL -l instead of /bin/zsh -f
//   … codd-term-demo -- /bin/cat    # any absolute argv after --
//   … codd-term-demo --smoke        # unattended check, prints SMOKE OK / SMOKE FAIL and exits
//   … codd-term-demo --background   # never activates, no Dock icon, window ordered behind every
//                                   # other window (automated runs: never take the user's focus)
//
// Measurements (M5 F2; use with --background): --force-render keeps drawing while the window is
// covered, --measure <s> prints `MEASURE` footprint / frame lines every second and exits after <s>,
// --size <w>x<h> sets the window's content size in points, --cursor-blink turns the configured
// cursor blink on, --config "<key = value>" (repeatable) appends a libghostty config line,
// --metal-drawables <2|3> and --metal-no-timeout set CAMetalLayer properties when the view's layer
// is one (libghostty may replace it with its own IOSurface layer; `MEASURE layer=` names it).
//
// Terminal ▸ Replay History Into Fresh Surface (⌘⇧R) disposes of the engine and replays every byte
// the shell printed (plus startup probes) into a new one; the window subtitle reports how many
// bytes the engine wrote back while replaying (0 = no replies leaked).

@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DemoController?

    func applicationDidFinishLaunching(_: Notification) {
        let options = DemoOptions.current
        TerminalEngine.rendersWhileWindowOccludedByDefault = options.forceRender
        let controller = DemoController(argv: Self.argv(), options: options)
        self.controller = controller
        NSApp.mainMenu = DemoMenu.make(target: controller)
        controller.start()
        // A background run never activates: it would take the user's keyboard focus.
        if !options.background { NSApp.activate() }
        if CommandLine.arguments.contains("--smoke") {
            Task { await controller.runSmoke() }
        }
        if let seconds = options.measureSeconds {
            Task { await controller.runMeasurement(seconds: seconds) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    static func argv() -> [String] {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count {
            return Array(arguments[(separator + 1)...])
        }
        if arguments.contains("--login"), !arguments.contains("--smoke") {
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            return [shell, "-l"]
        }
        return ["/bin/zsh", "-f"]
    }
}

@MainActor
enum DemoMenu {
    static func make(target: DemoController) -> NSMenu {
        let main = NSMenu()

        let app = NSMenu(title: "codd-term-demo")
        app.addItem(item("Quit codd-term-demo", #selector(NSApplication.terminate(_:)), "q", target: nil))
        add(app, to: main)

        let edit = NSMenu(title: "Edit")
        // nil targets: the first responder (the terminal view) answers copy:/paste:/selectAll:.
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c", target: nil))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v", target: nil))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil))
        add(edit, to: main)

        let terminal = NSMenu(title: "Terminal")
        terminal.addItem(item(
            "Replay History Into Fresh Surface", #selector(DemoController.replayIntoFreshSurface(_:)), "R",
            target: target
        ))
        terminal.addItem(item("Reset Terminal", #selector(DemoController.resetTerminal(_:)), "", target: target))
        terminal.addItem(item("Restart Shell", #selector(DemoController.restartShell(_:)), "", target: target))
        terminal.addItem(.separator())
        terminal.addItem(item("Bigger Font", #selector(DemoController.biggerFont(_:)), "", target: target))
        terminal.addItem(item("Smaller Font", #selector(DemoController.smallerFont(_:)), "", target: target))
        add(terminal, to: main)

        // The shortcuts CODD reserves for its own menus. Each logs that it reached the menu; none
        // may be swallowed by the terminal.
        let session = NSMenu(title: "Session")
        var reserved: [(String, String, NSEvent.ModifierFlags)] = [
            ("Quick Switch", "k", .command), ("Toggle Sidebar", "\\", .command),
            ("Bottom Terminal", "j", .command), ("New Shell Tab", "t", .command),
            ("Composer", "l", .command), ("Settings", ",", .command), ("New Session", "n", .command),
            ("Close Tab", "w", .command), ("Previous Tab", "[", [.command, .shift]),
            ("Next Tab", "]", [.command, .shift]),
        ]
        reserved += (1 ... 9).map { ("Session \($0)", String($0), .command) }
        for (title, key, modifiers) in reserved {
            let menuItem = item(title, #selector(DemoController.reservedShortcut(_:)), key, target: target)
            menuItem.keyEquivalentModifierMask = modifiers
            session.addItem(menuItem)
        }
        add(session, to: main)
        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, target: AnyObject?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func add(_ menu: NSMenu, to main: NSMenu) {
        let holder = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        main.addItem(holder)
    }
}

/// Command-line options besides the argv after `--`.
struct DemoOptions {
    var background = false
    var forceRender = false
    var measureSeconds: Double?
    var contentSize = NSSize(width: 900, height: 560)
    var cursorBlinks = false
    var extraConfig: [String] = []
    var metalDrawables: Int?
    var metalNoTimeout = false

    static let current = parse(Array(CommandLine.arguments.dropFirst()))

    static func parse(_ all: [String]) -> DemoOptions {
        let arguments = all.firstIndex(of: "--").map { Array(all[..<$0]) } ?? all
        var options = DemoOptions()
        var index = 0
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        while index < arguments.count {
            switch arguments[index] {
            case "--background": options.background = true
            case "--force-render": options.forceRender = true
            case "--measure": options.measureSeconds = value().flatMap(Double.init)
            case "--size":
                let parts = (value() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { options.contentSize = NSSize(width: parts[0], height: parts[1]) }
            case "--cursor-blink": options.cursorBlinks = true
            case "--config": if let line = value() { options.extraConfig.append(line) }
            case "--metal-drawables": options.metalDrawables = value().flatMap { Int($0) }
            case "--metal-no-timeout": options.metalNoTimeout = true
            default: break
            }
            index += 1
        }
        return options
    }

    var configuration: TerminalConfiguration {
        var configuration = TerminalConfiguration.default
        configuration.cursorBlinks = cursorBlinks
        configuration.additionalGhosttyConfig = extraConfig
        return configuration
    }
}

let application = NSApplication.shared
let delegate = DemoAppDelegate()
application.delegate = delegate
// Background runs (tests, measurements): no Dock icon and no activation, like CODD's own
// background mode (App/AppActivation.swift).
application.setActivationPolicy(DemoOptions.current.background ? .accessory : .regular)
application.run()
