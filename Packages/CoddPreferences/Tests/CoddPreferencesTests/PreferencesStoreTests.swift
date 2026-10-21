import Foundation
import Testing
@testable import CoddPreferences

@Suite("Preferences store")
struct PreferencesStoreTests {
    typealias P = CoddPreferences

    @Test func missingFileIsTheDefaultsAndNothingIsWritten() throws {
        try withStore { store, temp in
            let (p, origin) = store.load()
            #expect(p == .defaults)
            #expect(origin == .created)
            #expect(!store.isReadOnly)
            let names = try temp.names()
            #expect(names.isEmpty)
        }
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withStore { store, _ in
            try store.save(PreferencesModelTests.changed)
            let (p, origin) = PreferencesStore(url: store.url).load()
            #expect(p == PreferencesModelTests.changed)
            #expect(origin == .loaded)
        }
    }

    @Test func fileIsPrettySortedAnd0600() throws {
        try withStore { store, temp in
            try store.save(.defaults)
            #expect(try fileMode(store.url) == 0o600)
            let text = try String(contentsOf: store.url, encoding: .utf8)
            #expect(text.hasPrefix("{\n  \"about\" : {\n    \"updateChannel\" : \"stable\"\n  },\n  \"accounts\" : {"))
            #expect(text.contains("\n  \"version\" : 1\n}"))
            #expect(text.contains("\"projectRoot\" : \"~/Github\""))
            let top = text.split(separator: "\n").filter { $0.hasPrefix("  \"") }.map { String($0.split(separator: "\"")[1]) }
            #expect(top == ["about", "accounts", "advanced", "appearance", "cleanup", "general", "notebook", "notifications",
                            "sessions", "shortcuts", "version"])
            // Replacing a looser file still ends at 0600, and no temp file is left behind.
            chmod(store.url.path, 0o644)
            try store.save(PreferencesModelTests.changed)
            #expect(try fileMode(store.url) == 0o600)
            #expect(try temp.names() == [PreferencesStore.fileName])
        }
    }

    @Test func saveCreatesTheDataRoot() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let store = PreferencesStore(url: temp.file("nested/root/preferences.json"))
        try store.save(.defaults)
        #expect(store.load().1 == .loaded)
    }

    @Test func missingSectionsAndFieldsAreDefaultsWithoutRepair() throws {
        try withStore { store, _ in
            try Data(#"{"version":1}"#.utf8).write(to: store.url)
            #expect(store.load() == (.defaults, .loaded))

            try Data(#"{"version":1,"general":{"showInDock":false},"notifications":{"done":{"sound":true}}}"#.utf8).write(to: store.url)
            var expected = P.defaults
            expected.general.showInDock = false
            expected.notifications.done.sound = true
            #expect(store.load() == (expected, .loaded))
        }
    }

    @Test(arguments: [
        "general.quitBehavior", "general.language", "appearance.crt", "appearance.density", "appearance.reduceMotion",
        "sessions.externalDisplay", "notifications.waiting.condition", "notifications.error.condition",
        "notifications.done.condition", "notifications.exitedNonZero.condition", "notifications.dockBadge",
        "notifications.menuBarIcon", "notebook.location", "notebook.defaultAIAccess", "cleanup.digest", "about.updateChannel",
    ])
    func unknownEnumValueIsTheDefault(path: String) throws {
        try withStore { store, _ in
            var object = try defaultsObject()
            // Start from a non-default neighbour so only this field is reset.
            object = setting(object, "general.showInDock", false)
            try write(setting(object, path, "fromTheFuture"), to: store.url)
            let (p, origin) = store.load()
            var expected = P.defaults
            expected.general.showInDock = false
            #expect(p == expected)
            #expect(origin == .repaired(path))
            #expect(p.value(atPath: path) == P.defaults.value(atPath: path))
        }
    }

    @Test func wrongTypesAndBadValuesAreRepairedOneByOne() throws {
        try withStore { store, _ in
            var object = try defaultsObject()
            object = setting(object, "general.launchAtLogin", "yes")
            object = setting(object, "general.showInDock", false)  // valid, kept
            object = setting(object, "general.hotkey", [1, 2])
            object = setting(object, "appearance.terminalFontSize", "big")
            object = setting(object, "appearance.uiFontSize", 99)  // clamped to 20
            object = setting(object, "sessions.noHookWarningSeconds", 15)
            object = setting(object, "sessions.staleAfterSeconds", 1800.0)  // integral double, kept
            object = setting(object, "notifications.quietHours.start", "25:00")
            object = setting(object, "notifications.mutedGroupIDs", ["g-1", 7, ""])
            object = setting(object, "notifications.pausedUntil", "later")
            object = setting(object, "accounts.autoSwitch.thresholdPercent", 50)
            object = setting(object, "accounts.autoSwitch.cooldownSeconds", 10)
            object = setting(object, "accounts.cswapPath", 3)
            object = setting(object, "notebook.mcpPort", 80)
            object = setting(object, "cleanup.trashPurgeDays", nil)
            object = setting(object, "cleanup.tombstoneDays", nil)  // 永久, kept
            object["advanced"] = 5
            try write(object, to: store.url)

            let (p, origin) = store.load()
            var expected = P.defaults
            expected.general.showInDock = false
            expected.appearance.uiFontSize = 20
            expected.sessions.staleAfterSeconds = 1800
            expected.notifications.mutedGroupIDs = ["g-1"]
            expected.accounts.autoSwitch.thresholdPercent = 20
            expected.accounts.autoSwitch.cooldownSeconds = 60
            expected.notebook.mcpPort = 1024
            expected.cleanup.tombstoneDays = nil
            #expect(p == expected)
            #expect(origin == .repaired([
                "general.launchAtLogin", "general.hotkey", "appearance.uiFontSize", "appearance.terminalFontSize",
                "sessions.noHookWarningSeconds", "notifications.quietHours.start", "notifications.mutedGroupIDs",
                "notifications.pausedUntil", "accounts.cswapPath", "accounts.autoSwitch.thresholdPercent",
                "accounts.autoSwitch.cooldownSeconds", "notebook.mcpPort", "cleanup.trashPurgeDays", "advanced",
            ].joined(separator: ", ")))

            // Saving writes the repaired values over the bad ones.
            try store.save(p)
            let reloaded = PreferencesStore(url: store.url).load()
            #expect(reloaded == (expected, .loaded))
        }
    }

    @Test func missingOrBadVersionIsReadAsCurrent() throws {
        try withStore { store, _ in
            try Data(#"{"general":{"showInDock":false}}"#.utf8).write(to: store.url)
            let (p, origin) = store.load()
            #expect(p.general.showInDock == false && p.version == 1)
            #expect(origin == .repaired("version"))
            #expect(!store.isReadOnly)
            try Data(#"{"version":"1","about":{"updateChannel":"nope"}}"#.utf8).write(to: store.url)
            #expect(store.load().1 == .repaired("version, about.updateChannel"))
        }
    }

    @Test func unknownKeysSurviveLoadAndSaveAtEveryLevel() throws {
        try withStore { store, _ in
            var object = try defaultsObject()
            object["remote"] = ["provider": "tailscale", "devices": [1, 2]]
            object = setting(object, "general.futureToggle", true)
            object = setting(object, "general.hotkey.secondary", "⌃ Space")
            object = setting(object, "notifications.waiting.vibrate", 2.5)
            object = setting(object, "shortcuts.newSession", "cmd+n")
            try write(object, to: store.url)

            let (loaded, origin) = store.load()
            #expect(origin == .loaded)
            var p = loaded
            p.general.showInDock = false
            p.notifications.waiting.sound = false
            try store.save(p)

            let saved = try readObject(store.url)
            #expect(lookup(saved, "remote.provider") as? String == "tailscale")
            #expect(lookup(saved, "remote.devices") as? [Int] == [1, 2])
            #expect(lookup(saved, "general.futureToggle") as? Bool == true)
            #expect(lookup(saved, "general.hotkey.secondary") as? String == "⌃ Space")
            #expect(lookup(saved, "notifications.waiting.vibrate") as? Double == 2.5)
            #expect(lookup(saved, "shortcuts.newSession") as? String == "cmd+n")
            #expect(lookup(saved, "general.showInDock") as? Bool == false)
            #expect(lookup(saved, "notifications.waiting.sound") as? Bool == false)

            // A second save without a reload keeps them too.
            p.general.projectRoot = "~/Code"
            try store.save(p)
            #expect(lookup(try readObject(store.url), "general.hotkey.secondary") as? String == "⌃ Space")
            #expect(PreferencesStore(url: store.url).load() == (p, .loaded))
        }
    }

    @Test func clearingAnOptionalReplacesTheStoredValue() throws {
        try withStore { store, _ in
            var p = P.defaults
            p.notifications.pausedUntil = Date(timeIntervalSince1970: 1_760_700_000)
            p.accounts.cswapPath = "/x/cswap"
            try store.save(p)
            p.notifications.pausedUntil = nil
            p.accounts.cswapPath = nil
            try store.save(p)
            #expect(lookup(try readObject(store.url), "notifications.pausedUntil") is NSNull)
            #expect(store.load() == (p, .loaded))
        }
    }

    @Test func newerVersionIsReadOnly() throws {
        try withStore { store, _ in
            var object = try defaultsObject()
            object["version"] = 2
            object = setting(object, "appearance.crt", "full")
            object = setting(object, "appearance.hdr", true)
            try write(object, to: store.url)
            let before = try Data(contentsOf: store.url)

            let (p, origin) = store.load()
            #expect(origin == .newerReadOnly(2))
            #expect(store.isReadOnly)
            #expect(p.appearance.crt == .full && p.version == P.currentVersion)
            #expect(throws: PreferencesStoreError.newerVersion(2)) { try store.save(p) }
            #expect(try Data(contentsOf: store.url) == before)
        }
    }

    @Test func newerFileAppearingAfterLoadIsNotOverwritten() throws {
        try withStore { store, _ in
            #expect(store.load().1 == .created)
            try Data(#"{"version":3}"#.utf8).write(to: store.url)
            #expect(throws: PreferencesStoreError.newerVersion(3)) { try store.save(.defaults) }
            #expect(store.isReadOnly)
            #expect(try Data(contentsOf: store.url) == Data(#"{"version":3}"#.utf8))
        }
    }

    @Test(arguments: ["{\"version\":1,", "", "[1,2]", "\"text\"", "null", "{\"version\":1}}"])
    func corruptFileIsMovedAside(content: String) throws {
        try withStore { store, temp in
            try Data(content.utf8).write(to: store.url)
            let now = Date(timeIntervalSince1970: 1_760_700_000.123)
            let (p, origin) = store.load(now: now)
            #expect(p == .defaults)
            #expect(origin == .corruptMovedAside("preferences.json.corrupt-1760700000123"))
            #expect(!store.isReadOnly)
            #expect(try temp.names() == ["preferences.json.corrupt-1760700000123"])
            #expect(try Data(contentsOf: temp.file("preferences.json.corrupt-1760700000123")) == Data(content.utf8))

            // The defaults can be saved now; a second corrupt file at the same ms gets a suffix.
            try store.save(p)
            #expect(store.load().1 == .loaded)
            try Data("{".utf8).write(to: store.url)
            #expect(store.load(now: now).1 == .corruptMovedAside("preferences.json.corrupt-1760700000123-2"))
        }
    }

    @Test func unreadableFileIsNeverReplaced() throws {
        try withStore { store, _ in
            try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: false)
            let (p, origin) = store.load()
            #expect(p == .defaults)
            guard case .unreadable = origin else {
                Issue.record("expected unreadable, got \(origin)")
                return
            }
            #expect(store.isReadOnly)
            #expect(throws: PreferencesStoreError.self) { try store.save(p) }
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: store.url.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        }
    }

    @Test func reloadClearsReadOnlyOnceTheFileIsFine() throws {
        try withStore { store, _ in
            try Data(#"{"version":9}"#.utf8).write(to: store.url)
            #expect(store.load().1 == .newerReadOnly(9))
            try Data(#"{"version":1}"#.utf8).write(to: store.url)
            #expect(store.load().1 == .loaded)
            #expect(!store.isReadOnly)
            try store.save(.defaults)
        }
    }

    @Test func concurrentSavesLeaveOneCompleteFile() async throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let store = PreferencesStore(url: temp.file(PreferencesStore.fileName))
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<16 {
                group.addTask {
                    var p = P.defaults
                    p.appearance.terminalFontSize = 10 + i
                    try? store.save(p)
                }
            }
        }
        let (p, origin) = PreferencesStore(url: store.url).load()
        #expect(origin == .loaded)
        #expect((10..<26).contains(p.appearance.terminalFontSize))
        #expect(try temp.names() == [PreferencesStore.fileName])
    }

    // MARK: - Migration

    static var silenced: P {
        var p = P.defaults
        p.notifications.waiting.notify = false
        p.notifications.error.notify = false
        return p
    }

    @Test func legacyOffSilencesWaitingAndErrorOnly() {
        var p = P.defaults
        #expect(PreferencesStore.migrateLegacyNotifications(enabled: false, into: &p))
        #expect(p == Self.silenced)
        // Already silent: nothing more to change.
        #expect(!PreferencesStore.migrateLegacyNotifications(enabled: false, into: &p))
        for enabled: Bool? in [true, nil] {
            var q = P.defaults
            #expect(!PreferencesStore.migrateLegacyNotifications(enabled: enabled, into: &q))
            #expect(q == .defaults)
        }
    }

    /// A suite named by an absolute path keeps its plist in the temp directory, never in
    /// ~/Library/Preferences, and is not shared with tests running in parallel.
    @Test func legacyKeyIsReadFromUserDefaults() throws {
        let temp = try TempDir()
        defer { temp.remove() }
        let cases: [(Any?, Bool)] = [(false, true), ("NO", true), (true, false), ("YES", false), (nil, false)]
        for (i, (stored, changes)) in cases.enumerated() {
            let name = temp.file("legacy-\(i)").path
            let defaults = try #require(UserDefaults(suiteName: name))
            if let stored { defaults.set(stored, forKey: PreferencesStore.legacyNotificationsKey) }
            var p = P.defaults
            #expect(PreferencesStore.migrateLegacyNotifications(from: defaults, into: &p) == changes, "\(String(describing: stored))")
            #expect(p == (changes ? Self.silenced : .defaults))
            defaults.removePersistentDomain(forName: name)
        }
    }
}
