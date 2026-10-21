import AppKit
import CoddPreferences
import CoddUI

/// M4 interface zoom (user feedback 2026-10-18: 「可以針對當前介面進行縮放（文字大小）」).
///
/// 顯示方式 › 放大 ⌘+ / 縮小 ⌘− / 實際大小 ⌘0 step Settings › 外觀 › UI 字級 and 終端機字級 together
/// (`CoddPreferences.Appearance.zoomed(by:)`: 1 pt each, offset kept, UI 10–20 and terminal 8–28)
/// through the preferences, so Settings shows the new values and `preferences.json` keeps them.
/// Applying the preferences (`applyInterfaceZoom`) zooms every window in place (`UIZoom`) and moves
/// every terminal (`ShellState.terminalFontSize`); a launch starts at the stored level.
extension AppDelegate {
    // MARK: Menu commands

    @objc func zoomIn(_ sender: Any?) { zoom(.in) }
    @objc func zoomOut(_ sender: Any?) { zoom(.out) }
    @objc func zoomToActualSize(_ sender: Any?) { zoom(.reset) }

    private func zoom(_ step: InterfaceZoomCommands.Step) {
        guard InterfaceZoomCommands.perform(step, on: preferences) else { return }
        zoomSteps += 1
        let a = preferences.preferences.appearance
        HolderSessionStore.printLog("zoom \(step.rawValue) ui=\(a.uiFontSize) terminal=\(a.terminalFontSize)")
    }

    /// The session header's A− / A+ (terminal only): through the preference too, so a later ⌘+
    /// steps from what the terminals show and Settings › 終端機字級 follows.
    func stepTerminalFont(_ delta: Int) {
        InterfaceZoomCommands.stepTerminal(preferences, by: delta)
    }

    /// The zoom items' enabled state (nil for every other item).
    func validateZoomMenuItem(_ menuItem: NSMenuItem) -> Bool? {
        InterfaceZoomCommands.isEnabled(menuItem.action, appearance: preferences.preferences.appearance,
                                        composing: keyWindowHasMarkedText)
    }

    // MARK: Applying

    /// Preferences → the interface zoom (every window refreshed in place when it changed) and the
    /// windows' own zoom-dependent sizes. The terminal size is applied with the other terminal
    /// settings (`applyLifecyclePreferences`).
    func applyInterfaceZoom(_ appearance: CoddPreferences.Appearance) {
        guard UIZoom.apply(fontSize: appearance.uiFontSize) else { return }
        HolderSessionStore.printLog("zoom applied ui=\(UIZoom.fontSize) scale=\(String(format: "%.3f", Double(UIZoom.scale)))")
        mainWindow?.applyZoom()
        files.applyZoom()
    }

    /// The UI 字級 a launch starts at, read before the first window is built so it is laid out
    /// once at that size (the full read of `preferences.json` runs off the main actor right
    /// after). Read-only (a missing, unreadable or invalid file means 13); DEBUG `-codd-set-pref`
    /// assignments count, as they will after the full read.
    nonisolated static func launchUIFontSize(file: URL?, assignments: [String]) -> Int {
        var prefs = CoddPreferences.defaults
        if let file, let data = try? Data(contentsOf: file),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let appearance = object["appearance"] as? [String: Any], let number = appearance["uiFontSize"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), Double(number.intValue) == number.doubleValue {
            try? prefs.set(String(number.intValue), atPath: "appearance.uiFontSize")
        }
        for assignment in assignments where assignment.hasPrefix("appearance.uiFontSize=") {
            try? prefs.apply(assignment: assignment)
        }
        return prefs.appearance.uiFontSize
    }

    // MARK: Dump

    /// `zoom`: the applied interface zoom (UI font size, scale, sample fonts and metrics), the
    /// terminals' size, the stored values and the menu's state.
    var zoomDump: [String: Any] {
        let a = preferences.preferences.appearance
        var terminal: [String: Any] = ["shell": shell.terminalFontSize]
        if let hub = terminalHub { terminal["engines"] = Double(hub.fontSize) }
        return [
            "uiFontSize": UIZoom.fontSize,
            "scale": Double(UIZoom.scale),
            "terminalFontSize": shell.terminalFontSize,
            "terminal": terminal,
            "stored": ["uiFontSize": a.uiFontSize, "terminalFontSize": a.terminalFontSize],
            "fonts": ["body13": Double(Typeface.mono(13).pointSize), "pageTitle26": Double(Typeface.display(26).pointSize)],
            "metrics": ["sessionRowHeight": Double(Metrics.sessionRowHeight), "headerHeight": Double(Metrics.headerHeight),
                        "statusBarHeight": Double(Metrics.statusBarHeight), "railWidth": Double(Metrics.railWidth)],
            "canZoomIn": a.canZoom(by: 1),
            "canZoomOut": a.canZoom(by: -1),
            "actualSize": a.isActualSize,
            "steps": zoomSteps,
        ]
    }

    #if DEBUG
    /// `-codd-zoom in|out|reset` (repeatable): the menu commands, in order.
    func runZoomDebugActions() {
        for step in realOptions.zoomSteps {
            switch step {
            case "in", "+": zoomIn(nil)
            case "out", "-": zoomOut(nil)
            case "reset", "0": zoomToActualSize(nil)
            default: HolderSessionStore.printLog("debug zoom refused: \(step) (in, out or reset)")
            }
        }
    }
    #endif
}

/// The zoom commands on the preferences (the menu items, the header's A− / A+, DEBUG `-codd-zoom`;
/// pure enough for tests): each writes `appearance` through `PreferencesService.update`, which
/// saves it and lets the preference consumers apply it.
@MainActor
enum InterfaceZoomCommands {
    enum Step: String, Sendable {
        case `in`, out, reset
    }

    /// Applies `step` (放大 / 縮小 / 實際大小); false when it would change nothing.
    @discardableResult
    static func perform(_ step: Step, on preferences: PreferencesService) -> Bool {
        let appearance = preferences.preferences.appearance
        let next: CoddPreferences.Appearance
        switch step {
        case .in: next = appearance.zoomed(by: 1)
        case .out: next = appearance.zoomed(by: -1)
        case .reset: next = appearance.zoomReset()
        }
        guard next != appearance else { return false }
        preferences.update { $0.appearance = next }
        return true
    }

    /// A− / A+: the terminal size alone, clamped to 8–28.
    static func stepTerminal(_ preferences: PreferencesService, by delta: Int) {
        let range = CoddPreferences.Appearance.terminalFontSizeRange
        preferences.update { prefs in
            prefs.appearance.terminalFontSize = min(max(prefs.appearance.terminalFontSize + delta, range.lowerBound), range.upperBound)
        }
    }

    /// A zoom item's enabled state (nil for any other action): a step that would change nothing
    /// is disabled, and nothing zooms while an input method composes (D36).
    static func isEnabled(_ action: Selector?, appearance: CoddPreferences.Appearance, composing: Bool) -> Bool? {
        switch action {
        case #selector(AppDelegate.zoomIn(_:)): !composing && appearance.canZoom(by: 1)
        case #selector(AppDelegate.zoomOut(_:)): !composing && appearance.canZoom(by: -1)
        case #selector(AppDelegate.zoomToActualSize(_:)): !composing && !appearance.isActualSize
        default: nil
        }
    }
}
