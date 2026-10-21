import AppKit
import CoddPreferences
import CoddUI
import Darwin
import Foundation
import Testing
@testable import CODD

/// M3 I1a (ui-switch): the design-system move to CoddUI (D30), `PreferencesService` (D14) and its
/// first consumers (stale threshold, notifications on / off). Temp folders and temp UserDefaults
/// suites only; nothing reads or writes the real data root or the app's defaults domain.

/// A fresh `$TMPDIR` folder.
private func makeTempDirectory(_ prefix: String) throws -> URL {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    return URL(fileURLWithPath: String(cString: created), isDirectory: true)
}

@MainActor
private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition(), "timed out waiting for \(what)")
}

/// A UserDefaults suite stored as a plist at an absolute path inside `dir` (never the app's
/// domain or ~/Library/Preferences).
private func temporaryDefaults(in dir: URL) throws -> UserDefaults {
    try #require(UserDefaults(suiteName: dir.appendingPathComponent("defaults-\(UUID().uuidString)").path))
}

private func fileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func storedPreferences(_ url: URL) throws -> CoddPreferences {
    try JSONDecoder().decode(CoddPreferences.self, from: Data(contentsOf: url))
}

// MARK: - Design system (D30)

@MainActor
struct M3ParitySnapshotTests {
    /// Renders the menu bar panel with the SPEC §5 mock data. With `CODD_PARITY_DIR` set
    /// (`TEST_RUNNER_CODD_PARITY_DIR=<dir> xcodebuild test …`) it also writes the PNG, so the
    /// panel can be compared by eye before and after a design-system change (the status item's
    /// panel cannot be opened by `-CODDSnapshotDir` while the screen is locked).
    @Test func menuBarPanelRenders() throws {
        let store = MockSessionStore(shiftClock: false)
        let accounts = MockAccountStore()
        let actions = MenuBarPanelActions(openSession: { _ in }, allow: { _ in }, openMain: {}, openSettings: { _ in },
                                          newSession: {}, quickNote: {})
        let view = MenuBarPanelView(store: store, accounts: accounts, actions: actions)
        let panel = MenuBarPanel()
        panel.contentView = view
        view.activate()
        defer { view.deactivate() }
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        panel.setContentSize(NSSize(width: 380, height: height))
        view.layoutSubtreeIfNeeded()
        #expect(height > 300)
        if let dir = ProcessInfo.processInfo.environment["CODD_PARITY_DIR"] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Self.writePNG(view, to: URL(fileURLWithPath: dir).appendingPathComponent("menubar-panel.png"))
        }
    }

    /// `cacheDisplay` at 2x (the panel is never ordered in, so its layers have no contents yet).
    static func writePNG(_ view: NSView, to url: URL) throws {
        let size = view.bounds.size
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}

@MainActor
struct M3DesignSystemTests {
    /// CoddUI's value-based quota row, its moved DashedRuleView and Draw.glow resolve next to the
    /// app's own QuotaRowView in a file that imports both modules (no ambiguity), and the app's
    /// HomeHeaderView.glow is the same shadow as Draw.glow.
    @Test func coddUITypesResolveNextToAppTypes() {
        let shared = QuotaBarRowView(key: "5h", remainingPercent: 91, trailing: "2h57m後", threshold: 2)
        let app = QuotaRowView(frame: .zero)
        app.quota = QuotaWindow(remainingPercent: 91)
        #expect(shared.row.valueText == "91%")
        #expect(shared.tone == .ok)
        #expect(app.quota.tone == .ok)
        let rule = DashedRuleView()
        #expect(rule.intrinsicContentSize.height == 1)
        #expect(rule.color == Palette.line, "the moved rule keeps the app's color by default")
        let glow = Draw.glow(Palette.amber, radius: 8)
        let forwarded = HomeHeaderView.glow(Palette.amber, radius: 8)
        #expect(glow.shadowBlurRadius == forwarded.shadowBlurRadius)
        #expect(glow.shadowColor == forwarded.shadowColor)
        #expect(forwarded.shadowOffset == .zero)
        // The App-only theme parts that stayed behind still draw with CoddUI's tokens.
        #expect(QuotaTone.crit.color == Palette.danger)
        #expect(ChipStyle.statePill(StateStyle.of(.waiting)).fill == StateStyle.of(.waiting).color)
    }

    /// Regression (found by C8, fixed in CoddUI and App in I1a): the fields' `viewDidMoveToWindow`
    /// removed every observation of the view, including the NSControl delegate registration, so
    /// typing into a field in a window never reached `onChange` (profile editor, ⌘N name / model,
    /// the ⌘N folder box).
    @Test func typingInAWindowReachesOnChange() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let input = InputField(placeholder: "名稱")
        input.frame = NSRect(x: 0, y: 0, width: 200, height: 30)
        var changes: [String] = []
        input.onChange = { changes.append($0) }
        let combo = ProjectComboBox(frame: NSRect(x: 0, y: 40, width: 300, height: ProjectComboBox.height))
        var comboChanges: [String] = []
        combo.onTextChange = { comboChanges.append($0) }
        window.contentView?.addSubview(input)
        window.contentView?.addSubview(combo)

        #expect(window.makeFirstResponder(input.field))
        let editor = try #require(input.field.currentEditor() as? NSTextView)
        editor.insertText("ab", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(changes == ["ab"])

        #expect(window.makeFirstResponder(combo.field))
        let comboEditor = try #require(combo.field.currentEditor() as? NSTextView)
        comboEditor.insertText("north", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(comboChanges == ["north"])

        // Moving to another window keeps the delegate (only the window observation is redone).
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.contentView?.addSubview(input)
        #expect(other.makeFirstResponder(input.field))
        try #require(input.field.currentEditor() as? NSTextView).insertText("c", replacementRange: NSRange(location: NSNotFound, length: 0))
        // (Focusing selects the whole text, so the typed `c` replaces it.)
        #expect(changes == ["ab", "c"])
    }
}

// MARK: - PreferencesService (D14)

@MainActor
struct M3PreferencesServiceTests {
    @Test func aFirstRunUsesTheDefaultsAndWritesNothingUntilAnEdit() async throws {
        let dir = try makeTempDirectory("codd-i1a-prefs")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        let service = PreferencesService(url: url, legacyDefaults: try temporaryDefaults(in: dir), saveDelay: .milliseconds(30))
        #expect(!service.isLoaded)
        await service.load()
        #expect(service.isLoaded)
        #expect(service.origin == .created)
        #expect(service.preferences == .defaults)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: url.path), "defaults are not written by themselves")

        service.update { $0.sessions.staleAfterSeconds = 1800 }
        service.update { $0.accounts.autoSwitch.thresholdPercent = 5 }
        await eventually("the debounced save") { FileManager.default.fileExists(atPath: url.path) && service.savedAt != nil }
        #expect(try fileMode(url) == 0o600)
        let stored = try storedPreferences(url)
        #expect(stored.sessions.staleAfterSeconds == 1800)
        #expect(stored.accounts.autoSwitch.thresholdPercent == 5)
        #expect(service.saveProblem == nil)

        // An unchanged edit saves nothing; a reload sees the file.
        let savedAt = service.savedAt
        service.update { $0.sessions.staleAfterSeconds = 1800 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.savedAt == savedAt)
        let again = PreferencesService(url: url, legacyDefaults: nil)
        await again.load()
        #expect(again.origin == .loaded)
        #expect(again.preferences.sessions.staleAfterSeconds == 1800)
    }

    @Test func flushWritesAPendingEditAtOnce() async throws {
        let dir = try makeTempDirectory("codd-i1a-flush")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        let service = PreferencesService(url: url, legacyDefaults: nil, saveDelay: .seconds(30))
        await service.load()
        service.update { $0.sessions.staleAfterSeconds = nil }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        service.flush()
        #expect(try storedPreferences(url).sessions.staleAfterSeconds == nil)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("\"staleAfterSeconds\" : null"), "永不 is an explicit null")
        #expect(service.savedAt != nil)
        service.flush() // nothing pending: no second write
    }

    @Test func theLegacyNotificationsSwitchIsMigratedOnTheFirstRunOnly() async throws {
        let dir = try makeTempDirectory("codd-i1a-migrate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let defaults = try temporaryDefaults(in: dir)
        defaults.set(false, forKey: PreferencesStore.legacyNotificationsKey)
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        let service = PreferencesService(url: url, legacyDefaults: defaults, saveDelay: .milliseconds(20))
        await service.load()
        #expect(!service.preferences.notifications.waiting.notify)
        #expect(!service.preferences.notifications.error.notify)
        #expect(service.preferences.notifications.done.notify, "DONE is new in M3 and keeps its default")
        await eventually("the migrated values are saved") { FileManager.default.fileExists(atPath: url.path) }
        #expect(try !storedPreferences(url).notifications.waiting.notify)
        #expect(defaults.object(forKey: PreferencesStore.legacyNotificationsKey) != nil, "the old key is left alone")

        // The file exists now: a later run keeps the user's newer choice.
        let edited = PreferencesService(url: url, legacyDefaults: defaults, saveDelay: .milliseconds(20))
        await edited.load()
        edited.update { $0.notifications.waiting.notify = true }
        edited.flush()
        let third = PreferencesService(url: url, legacyDefaults: defaults)
        await third.load()
        #expect(third.origin == .loaded)
        #expect(third.preferences.notifications.waiting.notify)

        // Never set, or set to YES: nothing to migrate and nothing written.
        let other = try makeTempDirectory("codd-i1a-migrate2")
        defer { try? FileManager.default.removeItem(at: other) }
        let on = try temporaryDefaults(in: other)
        on.set(true, forKey: PreferencesStore.legacyNotificationsKey)
        let untouched = PreferencesService(url: other.appendingPathComponent(PreferencesStore.fileName), legacyDefaults: on,
                                           saveDelay: .milliseconds(20))
        await untouched.load()
        #expect(untouched.preferences == .defaults)
        try await Task.sleep(for: .milliseconds(80))
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent(PreferencesStore.fileName).path))
    }

    @Test func setPrefAssignmentsApplyForTheRunWithoutBeingWritten() async throws {
        let dir = try makeTempDirectory("codd-i1a-setpref")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        var onDisk = CoddPreferences.defaults
        onDisk.sessions.staleAfterSeconds = 14400
        try JSONEncoder().encode(onDisk).write(to: url)
        let service = PreferencesService(url: url, legacyDefaults: nil,
                                         assignments: ["sessions.staleAfterSeconds=1800", "notifications.menuBarIcon=iconAndCounts",
                                                       "no.such.path=1", "sessions.staleAfterSeconds"],
                                         saveDelay: .milliseconds(20))
        await service.load()
        #expect(service.preferences.sessions.staleAfterSeconds == 1800)
        #expect(service.preferences.notifications.menuBarIcon == .iconAndCounts)
        #expect(service.assignmentResults.map { $0.error == nil } == [true, true, false, false])
        try await Task.sleep(for: .milliseconds(80))
        #expect(service.savedAt == nil, "assignments alone write nothing")

        // Another edit writes the file's own value for the assigned leaves.
        service.update { $0.accounts.confirmBeforeSwitch = true }
        await eventually("the edit is saved") { service.savedAt != nil }
        var stored = try storedPreferences(url)
        #expect(stored.accounts.confirmBeforeSwitch)
        #expect(stored.sessions.staleAfterSeconds == 14400)
        #expect(stored.notifications.menuBarIcon == .iconOnly)
        #expect(service.preferences.sessions.staleAfterSeconds == 1800, "still in effect for the run")

        // Editing an assigned leaf makes it the user's: written from then on.
        let before = service.savedAt
        service.update { $0.sessions.staleAfterSeconds = 3600 }
        await eventually("the second save") { service.savedAt != before }
        stored = try storedPreferences(url)
        #expect(stored.sessions.staleAfterSeconds == 3600)
        #expect(stored.notifications.menuBarIcon == .iconOnly)

        let dump = service.dumpObject
        #expect(dump["origin"] as? String == "loaded")
        #expect((dump["values"] as? [String: String])?["sessions.staleAfterSeconds"] == "3600")
        #expect((dump["values"] as? [String: String])?.count == CoddPreferences.leafPaths.count)
        #expect((dump["setPrefs"] as? [[String: Any]])?.count == 4)
    }

    @Test func inMemoryPreferencesApplyAssignmentsAndNeverTouchDisk() {
        let service = PreferencesService.inMemory(assignments: ["appearance.crt=subtle"])
        #expect(service.isLoaded)
        #expect(service.store == nil)
        #expect(service.preferences.appearance.crt == .subtle)
        service.update { $0.general.showInDock = false }
        service.flush()
        #expect(!service.preferences.general.showInDock)
        #expect(service.savedAt == nil)
        #expect(service.dumpObject["origin"] as? String == "memory")
    }

    @Test func editsBeforeTheLoadAreKeptOverTheFile() async throws {
        let dir = try makeTempDirectory("codd-i1a-early")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        var onDisk = CoddPreferences.defaults
        onDisk.general.projectRoot = "~/Work"
        onDisk.sessions.staleAfterSeconds = 14400
        try JSONEncoder().encode(onDisk).write(to: url)
        let service = PreferencesService(url: url, legacyDefaults: nil, saveDelay: .milliseconds(20))
        service.update { $0.sessions.staleAfterSeconds = 1800 }
        await service.load()
        #expect(service.preferences.sessions.staleAfterSeconds == 1800)
        #expect(service.preferences.general.projectRoot == "~/Work", "the file's other values are read")
        await eventually("the early edit is saved") { service.savedAt != nil }
        #expect(try storedPreferences(url).sessions.staleAfterSeconds == 1800)
    }

    @Test func aCorruptFileIsMovedAsideAndReplacedOnTheNextSave() async throws {
        let dir = try makeTempDirectory("codd-i1a-corrupt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        try Data("{ not json".utf8).write(to: url)
        let service = PreferencesService(url: url, legacyDefaults: nil, saveDelay: .milliseconds(20))
        await service.load()
        guard case .corruptMovedAside(let name)? = service.origin else {
            Issue.record("origin \(String(describing: service.origin))")
            return
        }
        #expect(name.hasPrefix("preferences.json.corrupt-"))
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == Data("{ not json".utf8))
        #expect(service.preferences == .defaults)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        service.update { $0.appearance.terminalFontSize = 15 }
        service.flush()
        #expect(try storedPreferences(url).appearance.terminalFontSize == 15)
        #expect(try fileMode(url) == 0o600)
    }

    @Test func aNewerFileIsReadButNeverOverwritten() async throws {
        let dir = try makeTempDirectory("codd-i1a-newer")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        let text = #"{"version": 2, "sessions": {"staleAfterSeconds": 1800}, "future": {"x": 1}}"#
        try Data(text.utf8).write(to: url)
        let service = PreferencesService(url: url, legacyDefaults: nil, saveDelay: .milliseconds(20))
        await service.load()
        #expect(service.origin == .newerReadOnly(2))
        #expect(service.isReadOnly)
        #expect(service.preferences.sessions.staleAfterSeconds == 1800, "the known fields are used")
        service.update { $0.sessions.staleAfterSeconds = 3600 }
        service.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        #expect(service.saveProblem == "preferences.json 是較新版本的 CODD 寫的（v2），變更不會儲存")
        #expect(service.savedAt == nil)
        #expect(service.dumpObject["readOnly"] as? Bool == true)
    }
}

// MARK: - Consumers

@MainActor
struct M3PreferenceConsumerTests {
    @Test func staleAfterFollowsThePreferenceUnlessTheDebugFlagIsGiven() throws {
        var preferences = CoddPreferences.defaults
        #expect(PreferencesService.staleAfter(preferences, override: nil) == 3600)
        preferences.sessions.staleAfterSeconds = 1800
        #expect(PreferencesService.staleAfter(preferences, override: nil) == 1800)
        #expect(PreferencesService.staleAfter(preferences, override: 5) == 5, "-codd-stale-after wins for the run")
        preferences.sessions.staleAfterSeconds = nil
        let never = PreferencesService.staleAfter(preferences, override: nil)
        #expect(never == .infinity)

        // 永不: an IDLE session never turns stale, however old.
        let dir = try makeTempDirectory("codd-i1a-stale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HolderSessionStore(root: CoddDataRoot(path: dir.path + "/r"), launcher: nil)
        let now = Date()
        let session = SessionVM(id: "s", projectID: "p", title: "閒置", state: .idle, stateSince: now.addingTimeInterval(-30 * 86_400))
        store.staleAfter = never
        #expect(!store.refreshStale(session, now: now))
        #expect(!session.isStale)
        store.staleAfter = PreferencesService.staleAfter(.defaults, override: nil)
        #expect(store.refreshStale(session, now: now))
        #expect(session.isStale)
    }

    /// Since I3 the D29 matrix has four rows (WAITING, ERROR, DONE, EXITED); each follows its switch.
    @Test func notificationsFollowTheWaitingAndErrorSwitches() {
        var rules = CoddPreferences.defaults.notifications
        #expect(SessionNotifier.isEnabled(for: .waiting, rules: rules))
        #expect(SessionNotifier.isEnabled(for: .error, rules: rules))
        let rows: [SessionState] = [.waiting, .error, .done, .exited]
        for state in SessionState.allCases where !rows.contains(state) {
            #expect(!SessionNotifier.isEnabled(for: state, rules: rules), "\(state)")
        }
        rules.waiting.notify = false
        #expect(!SessionNotifier.isEnabled(for: .waiting, rules: rules))
        #expect(SessionNotifier.isEnabled(for: .error, rules: rules))
        rules.error.notify = false
        #expect(!SessionNotifier.isEnabled(for: .error, rules: rules))
        // The pure rule still decides focus, externals and repeats.
        #expect(!SessionNotifier.shouldNotify(from: .busy, to: .waiting, focused: false,
                                              enabled: SessionNotifier.isEnabled(for: .waiting, rules: rules)))
    }

    /// `-codd-dump-state` carries the preferences (D14 / §6 `preferences {origin, values}`).
    @Test func theStateDumpCarriesThePreferences() throws {
        let dir = try makeTempDirectory("codd-i1a-dump")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HolderSessionStore(root: CoddDataRoot(path: dir.path + "/r"), launcher: nil)
        let preferences = PreferencesService.inMemory(assignments: ["sessions.staleAfterSeconds=nil"])
        let object = StateDump.object(store: store, dockBadge: nil, preferences: preferences.dumpObject)
        let dump = try #require(object["preferences"] as? [String: Any])
        #expect(dump["origin"] as? String == "memory")
        #expect((dump["values"] as? [String: String])?["sessions.staleAfterSeconds"] == "nil")
        #expect(StateDump.object(store: store, dockBadge: nil)["preferences"] == nil)
        // It serializes like the rest of the dump.
        #expect(JSONSerialization.isValidJSONObject(object))
    }

    /// Settings › 通知 (the D29 matrix since I3) writes the preferences, and a change made
    /// elsewhere (the menu bar pause, a DEBUG assignment) comes back into the page's model.
    @Test func theSettingsNotificationRowsWriteThePreferences() throws {
        let preferences = PreferencesService.inMemory()
        let settings = SettingsWindowController(profiles: LaunchProfiles.inMemory(), preferences: preferences)
        settings.select("notifications")
        #expect(settings.section == "notifications")
        let model = settings.coordinator.model
        model.update {
            $0.notifications.waiting.notify = false
            $0.notifications.error.notify = false
        }
        #expect(!preferences.preferences.notifications.waiting.notify)
        #expect(!preferences.preferences.notifications.error.notify)
        #expect(preferences.preferences.notifications.done.notify, "every row has its own switch")
        preferences.update { $0.notifications.error.notify = true }
        // The observation loop applies on the next turn; the value is the service's.
        #expect(preferences.preferences.notifications.error.notify)
    }
}

// MARK: - DEBUG flag

struct M3RealModeOptionTests {
    @Test func setPrefIsRepeatableAndDebugOnly() {
        let options = RealModeOptions.parse(arguments: ["CODD", "-codd-set-pref", "sessions.staleAfterSeconds=1800",
                                                        "-codd-set-pref", "notifications.waiting.notify=NO", "-codd-stale-after", "5"],
                                            environment: [:], home: "/Users/u")
        #expect(options.setPrefs == ["sessions.staleAfterSeconds=1800", "notifications.waiting.notify=NO"])
        #expect(options.staleAfterSeconds == 5)
        #expect(options.releaseSubset.setPrefs.isEmpty)
    }
}
