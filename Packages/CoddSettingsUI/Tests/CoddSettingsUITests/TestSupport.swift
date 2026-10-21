import AppKit
import CoddPreferences
import CoddUI
@testable import CoddSettingsUI

/// Everything the page asked the app to do, in order.
@MainActor
final class ActionLog {
    var calls: [String] = []
    var tryHotkeyResult: String?
    var triedHotkeys: [KeyCombo] = []
    var changes: [CoddPreferences] = []
    /// FB: the answer to the auto-switch confirmation (nil leaves it unanswered).
    var confirmAnswer: Bool? = true

    func actions() -> SettingsActions {
        SettingsActions(
            chooseProjectRoot: { [unowned self] in calls.append("chooseProjectRoot") },
            recordHotkeyStarted: { [unowned self] in calls.append("recordHotkeyStarted") },
            recordHotkeyFinished: { [unowned self] in calls.append("recordHotkeyFinished") },
            tryHotkey: { [unowned self] combo in
                triedHotkeys.append(combo)
                return tryHotkeyResult
            },
            sendTestNotification: { [unowned self] in calls.append("sendTestNotification") },
            openHookDiff: { [unowned self] in calls.append("openHookDiff") },
            reinstallHooks: { [unowned self] in calls.append("reinstallHooks") },
            uninstallHooks: { [unowned self] in calls.append("uninstallHooks") },
            removeLegacy: { [unowned self] in calls.append("removeLegacy") },
            addAccount: { [unowned self] in calls.append("addAccount") },
            showDataRoot: { [unowned self] in calls.append("showDataRoot") },
            resetAll: { [unowned self] in calls.append("resetAll") },
            copyDiagnostics: { [unowned self] in calls.append("copyDiagnostics") },
            openRemoteBoard: { [unowned self] in calls.append("openRemoteBoard") },
            setAlias: { [unowned self] id, alias in calls.append("setAlias \(id) \(alias ?? "nil")") },
            restoreBackup: { [unowned self] id in calls.append("restoreBackup \(id)") },
            compareBackup: { [unowned self] id in calls.append("compareBackup \(id)") },
            revealPath: { [unowned self] path in calls.append("revealPath \(path)") },
            setDefaultProfile: { [unowned self] id in calls.append("setDefaultProfile \(id)") },
            resetSection: { [unowned self] section in calls.append("resetSection \(section.rawValue)") },
            rereadAccounts: { [unowned self] in calls.append("rereadAccounts") },
            openNotesFolder: { [unowned self] in calls.append("openNotesFolder") },
            rotateMCPToken: { [unowned self] in calls.append("rotateMCPToken") },
            mcpRegistration: { [unowned self] id in calls.append("mcpRegistration \(id)") },
            rebuildNotesIndex: { [unowned self] in calls.append("rebuildNotesIndex") },
            openCleanup: { [unowned self] in calls.append("openCleanup") },
            openOnboarding: { [unowned self] in calls.append("openOnboarding") },
            openThirdPartyNotices: { [unowned self] in calls.append("openThirdPartyNotices") },
            copyText: { [unowned self] text in calls.append("copyText \(text)") },
            openInstallTerminal: { [unowned self] text in calls.append("openInstallTerminal \(text)") },
            confirmAutoSwitch: { [unowned self] _, done in
                calls.append("confirmAutoSwitch")
                if let confirmAnswer { done(confirmAnswer) }
            }
        )
    }
}

@MainActor
struct Harness {
    let root: SettingsRootView
    let model: SettingsModel
    let log: ActionLog

    init(preferences: CoddPreferences = .defaults, info: SettingsInfo = SettingsSamples.info(now: Harness.now),
         profilesView: NSView = NSView()) {
        Harness.prepare()
        let log = ActionLog()
        let model = SettingsModel(preferences: preferences, info: info)
        model.onChange = { [unowned log] prefs in log.changes.append(prefs) }
        root = SettingsRootView(model: model, actions: log.actions(), profilesView: profilesView)
        root.frame = NSRect(x: 0, y: 0, width: 1040, height: 720)
        root.layoutSubtreeIfNeeded()
        self.model = model
        self.log = log
    }

    /// A fixed clock for the sample (no test depends on the wall clock).
    static let now = Date(timeIntervalSince1970: 1_792_115_660)

    func section<T: SettingsSectionView>(_ section: SettingsSection, as type: T.Type = T.self) -> T {
        root.select(section)
        root.layoutSubtreeIfNeeded()
        guard let view = root.sectionView(section) as? T else { fatalError("\(section) is not \(T.self)") }
        return view
    }

    /// Re-applies the model now (the observation loop would on the next turn).
    func sync() {
        root.applyNow()
        root.layoutSubtreeIfNeeded()
    }

    private static var prepared = false

    /// NSApplication and the bundled fonts (read from the repository, nothing written).
    static func prepare() {
        guard !prepared else { return }
        prepared = true
        _ = NSApplication.shared
        let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Fonts", isDirectory: true)
        Typeface.registerFonts(in: fonts)
    }
}

extension NSView {
    /// Every descendant of a type, depth first.
    func descendants<T: NSView>(ofType type: T.Type) -> [T] {
        subviews.flatMap { sub -> [T] in ((sub as? T).map { [$0] } ?? []) + sub.descendants(ofType: type) }
    }
}

/// A bitmap of `view` at 1x; the number of pixels that differ from the page background.
@MainActor
func paintedPixels(_ view: NSView) -> Int {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
    view.cacheDisplay(in: view.bounds, to: rep)
    var count = 0
    let step = 4
    for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent > 0.1 || color.greenComponent > 0.1 || color.blueComponent > 0.1 { count += 1 }
        }
    }
    return count
}
