import CoddPreferences
import Foundation
import Observation

/// The Settings page's state: the preferences being edited and the read-only facts. Views
/// observe both. Every edit made through the page goes through `update(_:)`, which changes
/// `preferences` and calls `onChange` once, right away (the app saves 300 ms later, D14).
/// Assigning `preferences` or `info` directly (the app's own refresh) does not call `onChange`.
@MainActor
@Observable
public final class SettingsModel {
    public var preferences: CoddPreferences
    public var info: SettingsInfo
    @ObservationIgnored public var onChange: ((CoddPreferences) -> Void)?

    public init(preferences: CoddPreferences = .defaults, info: SettingsInfo = SettingsInfo()) {
        self.preferences = preferences
        self.info = info
    }

    /// Applies one edit. Nothing happens when the edit leaves the preferences as they were, so a
    /// control set back to its own value never saves.
    public func update(_ edit: (inout CoddPreferences) -> Void) {
        var next = preferences
        edit(&next)
        guard next != preferences else { return }
        preferences = next
        onChange?(next)
    }

    /// `還原本頁預設`: the section's part of `CoddPreferences.defaults`, in one `onChange`.
    /// `keepHotkey` keeps the current global hotkey (GENERAL's reset when the default combo was
    /// refused by `SettingsActions.tryHotkey`). Sections without preferences do nothing.
    public func resetSection(_ section: SettingsSection, keepHotkey: Bool = false) {
        let defaults = CoddPreferences.defaults
        update { prefs in
            switch section {
            case .general:
                let hotkey = prefs.general.hotkey
                prefs.general = defaults.general
                if keepHotkey { prefs.general.hotkey = hotkey }
            case .appearance: prefs.appearance = defaults.appearance
            case .sessions: prefs.sessions = defaults.sessions
            case .notifications:
                // The menu bar pause is not a setting of this page; a reset keeps it.
                let paused = prefs.notifications.pausedUntil
                prefs.notifications = defaults.notifications
                prefs.notifications.pausedUntil = paused
            case .accounts: prefs.accounts = defaults.accounts
            case .notebook: prefs.notebook = defaults.notebook
            case .cleanup: prefs.cleanup = defaults.cleanup
            case .shortcuts:
                if !keepHotkey { prefs.general.hotkey = defaults.general.hotkey }
                prefs.shortcuts = defaults.shortcuts
            case .advanced: prefs.advanced = defaults.advanced
            case .about: prefs.about = defaults.about
            case .profiles, .hooks, .remote: break
            }
        }
    }

    /// The 即時預覽 as shown: the app's rows when it gave them, else derived from the account rows
    /// and the current auto-switch preferences.
    public var autoSwitchPreview: SettingsAutoSwitchPreview {
        if !info.autoSwitchPreview.isEmpty {
            return SettingsAutoSwitchPreview(rows: info.autoSwitchPreview, current: info.autoSwitchCurrent,
                                             next: info.autoSwitchNext, note: info.autoSwitchNote)
        }
        return SettingsAutoSwitchPreview.compute(accounts: info.accounts, autoSwitch: preferences.accounts.autoSwitch)
    }
}
