import AppKit
import CoddCore
import CoddPreferences
import CoddSettingsUI
import CoddUI

/// ⌘, settings window (D16: a window of its own, 1040 × 720, resizable down to 860 × 560): the
/// v3 Settings artboard as CoddSettingsUI's `SettingsRootView`, with M2's `ProfilesSettingsView`
/// as section 04 PROFILES. The coordinator binds it to the preferences and reads its facts while
/// the window shows.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let profilesPage: ProfilesSettingsView
    let coordinator: SettingsCoordinator
    let root: SettingsRootView
    private let profiles: LaunchProfiles
    var preferences: PreferencesService { coordinator.env.preferences }
    private(set) var editor: ProfileEditorSheet?

    static let size = NSSize(width: 1040, height: 720)
    static let minimumSize = NSSize(width: 860, height: 560)

    /// The section shown (`general`, `accounts`, …).
    var section: String { root.selected.rawValue }

    /// - Parameters:
    ///   - profiles: the data root's launch profiles (mock mode: the in-memory set).
    ///   - claudeSettings: Claude's own settings (D30 `預設（Claude Code：opus）`), observed while shown.
    ///   - accountLabel: PROFILES' account (`跟隨全域（#3 工作）`), read while observed.
    ///   - preferences: the app's preferences (tests: an in-memory set), used when no coordinator is given.
    ///   - coordinator: the app's facts and actions (nil: preferences only, for tests).
    init(profiles: LaunchProfiles, claudeSettings: @escaping @MainActor () -> ClaudeUserSettingsSummary = { ClaudeUserSettingsSummary() },
         accountLabel: @escaping @MainActor () -> String = { "跟隨全域" }, preferences: PreferencesService = .inMemory(),
         coordinator: SettingsCoordinator? = nil) {
        self.profiles = profiles
        profilesPage = ProfilesSettingsView(profiles: profiles, claudeSettings: claudeSettings, accountLabel: accountLabel)
        let coordinator = coordinator ?? SettingsCoordinator(environment: .init(preferences: preferences, profiles: profiles,
                                                                                    claudeSettings: claudeSettings))
        self.coordinator = coordinator
        root = SettingsRootView(model: coordinator.model, actions: coordinator.makeActions(), profilesView: profilesPage)
        // The title bar's height: the traffic lights sit over the sidebar head (full-size content).
        root.topInset = 28
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: true)
        window.title = "設定"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Palette.bg
        window.isReleasedWhenClosed = false
        window.minSize = Self.minimumSize
        window.contentView = root
        super.init(window: window)
        window.delegate = self
        window.center()
        coordinator.window = window
        coordinator.selectSection = { [weak self] section in self?.root.select(section) }
        profilesPage.onEdit = { [weak self] id in self?.edit(id) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window on a section (`accounts`, `cleanup`, `profiles`, …).
    func show(section: String?) {
        if let section { select(section) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        coordinator.setVisible(true)
    }

    /// Shows a section without bringing the window up (tests; `show(section:)` for the app).
    /// Unknown ids keep the current section.
    func select(_ id: String) {
        guard let section = SettingsSection(rawValue: id) else { return }
        root.select(section)
    }

    // MARK: NSWindowDelegate

    /// A typed value commits before the window goes (Return or a focus change were the only
    /// commits, so closing the window lost it, M3 review).
    func windowWillClose(_ notification: Notification) {
        endEditing()
        coordinator.setVisible(false)
    }

    /// Commits a value being typed (window close, app quit).
    func endEditing() { root.endEditing() }
    func windowDidMiniaturize(_ notification: Notification) { coordinator.setVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { coordinator.setVisible(true) }

    // MARK: Profiles

    /// `+ New profile` (nil) or `編輯`: the editor sheet on this window (one at a time).
    func edit(_ id: String?) {
        guard editor == nil, let window else { return }
        let profile = id.flatMap { profiles.document.profile(id: $0) }
        if id != nil, profile == nil { return }
        let sheet = ProfileEditorSheet(form: ProfileEditorForm(profile: profile, document: profiles.document), profiles: profiles,
                                       onClose: { [weak self] in self?.editor = nil })
        editor = sheet
        sheet.present(on: window)
    }

    /// `-codd-edit-profile <id>|new` (DEBUG): the settings window on PROFILES with the editor up.
    func debugEditProfile(_ id: String?) {
        select("profiles")
        edit(id)
    }

    /// The window's dump entry (`settings {shown, section}`).
    var dumpObject: [String: Any] {
        ["shown": window?.isVisible ?? false, "section": section, "infoBuilds": coordinator.infoBuilds]
    }
}
