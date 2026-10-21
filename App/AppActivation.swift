import AppKit

/// Launches by scripts and agents must leave the user alone: the user keeps working on this Mac
/// while test runs start CODD again and again (「不要跳到幕前干擾我」). In background mode CODD never
/// activates itself (`CoddApplication` swallows every activation request), has no Dock icon
/// (`.accessory`), and every window it shows (main window, Settings, dialogs, sheets, alerts,
/// panels, dropdowns, child windows) stays behind every other app's normal windows, at launch and
/// on every later ordering (`BackgroundWindows`, installed by main.swift). Only the user brings it
/// forward: clicking one of its windows activates CODD as for any app, and while it is active (or
/// while that click is handled) windows order as usual; once the user leaves CODD, its windows sink
/// behind the other apps again. Foreground launches (Release, the user's own runs) are unchanged.
enum AppActivation {
    static let flag = "-codd-background"
    static let variable = "CODD_BACKGROUND"

    static let isBackground = resolve(arguments: ProcessInfo.processInfo.arguments,
                                      environment: ProcessInfo.processInfo.environment)

    /// `-codd-background [YES|NO]` or `CODD_BACKGROUND=1|0` decide in every build. Without them a
    /// DEBUG build stays in the background when a Claude Code shell launched it (`CLAUDECODE`) or
    /// when it runs on another data root (every automated launch passes one).
    static func resolve(arguments: [String], environment: [String: String]) -> Bool {
        if let index = arguments.firstIndex(of: flag) {
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, let value = parse(arguments[next]) else { return true }
            return value
        }
        if let raw = environment[variable], let value = parse(raw) { return value }
        #if DEBUG
        return environment["CLAUDECODE"] != nil || arguments.contains(RealModeOptions.dataRootFlag)
            || environment[RealModeOptions.dataRootVariable] != nil
        #else
        return false
        #endif
    }

    private static func parse(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "yes", "true", "1": true
        case "no", "false", "0": false
        default: nil
        }
    }
}

/// Swallows activation in background mode, so no path (launch, menu bar, a notification, a
/// second instance's hand-over, code added later) can take the user's keyboard focus, and marks
/// the user's real clicks, whose orderings `BackgroundWindows` lets through.
final class CoddApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        guard AppActivation.isBackground, BackgroundWindows.isUserClick(event) else { return super.sendEvent(event) }
        BackgroundWindows.duringUserClick { super.sendEvent(event) }
    }

    override func activate() {
        guard !AppActivation.isBackground else { return }
        super.activate()
    }

    override func activate(ignoringOtherApps flag: Bool) {
        guard !AppActivation.isBackground else { return }
        super.activate(ignoringOtherApps: flag)
    }
}
