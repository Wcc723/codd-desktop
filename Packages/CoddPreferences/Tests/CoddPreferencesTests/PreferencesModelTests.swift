import Foundation
import Testing
@testable import CoddPreferences

@Suite("Preferences model")
struct PreferencesModelTests {
    typealias P = CoddPreferences

    @Test func defaultsAreTheArtboardWithTheD15Exceptions() {
        let d = P.defaults
        #expect(d.version == 1 && P.currentVersion == 1)

        let g = d.general
        #expect(g.launchAtLogin == false)  // D15 (artboard: ON)
        #expect(g.showInDock && g.keepInMenuBarOnClose)
        #expect(g.quitBehavior == .ask)
        #expect(g.hotkey == P.Hotkey(enabled: true, keyCode: 49, modifiers: 2048, display: "⌥ Space"))
        #expect(g.projectRoot == "~/Github")
        #expect(g.language == .zhHant)

        let a = d.appearance
        #expect(a.crt == .off)  // D15 (artboard: SUBTLE)
        #expect(a.density == .compact)
        #expect(a.uiFontSize == 13 && a.terminalFont == "JetBrains Mono" && a.terminalFontSize == 13)
        #expect(a.nativeVibrancy == false && a.reduceMotion == .system)

        let s = d.sessions
        #expect(s.autoSessionId && s.restoreAsStopped && s.hideSDKAndDesktop)
        #expect(s.noHookWarningSeconds == 20 && s.staleAfterSeconds == 3600)
        #expect(s.externalDisplay == .project)

        let n = d.notifications
        #expect(n.waiting == P.EventRule(condition: .always, notify: true, sound: true))
        #expect(n.error == P.EventRule(condition: .always, notify: true, sound: true))
        #expect(n.done == P.EventRule(condition: .unfocusedOnly, notify: true, sound: false))
        #expect(n.exitedNonZero == P.EventRule(condition: .always, notify: true, sound: false))
        #expect(n.quietHours == P.QuietHours(enabled: true, start: "23:00", end: "08:00"))
        #expect(n.mutedGroupIDs.isEmpty)  // D15 (artboard: CODD chip is sample data)
        #expect(n.dockBadge == .waiting && n.menuBarIcon == .iconOnly && n.pausedUntil == nil)

        let ac = d.accounts
        #expect(ac.cswapPath == nil && ac.confirmBeforeSwitch == false)
        #expect(ac.autoSwitch == P.AutoSwitch(enabled: false, thresholdPercent: 2, checkFiveHour: true, checkWeekly: true,
                                              cooldownSeconds: 300))

        let nb = d.notebook
        #expect(nb.location == .local && nb.resizeImages && !nb.keepOriginal && nb.mcpPort == 47821)
        #expect(nb.autoAttachMCP && nb.defaultAIAccess == .read && !nb.aiCanWrite)

        let c = d.cleanup
        #expect(c.notesStaleDays == 14 && c.notesArchiveDays == 30 && c.scratchArchiveDays == 7)
        #expect(c.trashPurgeDays == 30 && c.tombstoneDays == 90 && c.exempt)
        #expect(c.sessionsStaleDays == 3 && c.sessionsArchiveDays == 7 && c.scrollbackDeleteDays == 30 && c.resumeWarning)
        #expect(c.digest == .weekly && c.condenseAccount == nil && c.condenseModel == "sonnet-5.5")

        #expect(d.shortcuts == P.Shortcuts())
        #expect(d.advanced.scrollbackRetentionDays == 30)
        #expect(d.about.updateChannel == .stable)
    }

    @Test func optionSetsAreTheArtboardsWithTheDefaultFirst() {
        #expect(P.QuitBehavior.allCases == [.ask, .stopAll, .keep])
        #expect(P.Language.allCases == [.zhHant, .english, .system])
        #expect(P.CRT.allCases == [.full, .subtle, .off])
        #expect(P.Density.allCases == [.compact, .comfort])
        #expect(P.ReduceMotion.allCases == [.system, .on, .off])
        #expect(P.ExternalDisplay.allCases == [.project, .detected, .hidden])
        #expect(P.NotifyCondition.allCases == [.always, .unfocusedOnly])
        #expect(P.DockBadge.allCases == [.waiting, .all, .off])
        #expect(P.MenuBarIcon.allCases == [.iconOnly, .iconAndCounts])
        #expect(P.NotebookLocation.allCases == [.local, .iCloud, .custom])
        #expect(P.AIAccess.allCases == [.off, .read, .append])
        #expect(P.Digest.allCases == [.weekly, .biweekly, .monthly, .off])
        #expect(P.UpdateChannel.allCases == [.stable, .beta])

        let d = P.defaults
        #expect(P.Appearance.uiFontSizeRange == 10...20 && P.Appearance.uiFontSizeRange.contains(d.appearance.uiFontSize))
        #expect(P.Appearance.uiFontSizeOptions == Array(10...20))
        #expect(P.Appearance.terminalFontOptions == ["JetBrains Mono", "SF Mono", "Menlo"])
        #expect(P.Appearance.terminalFontSizeRange == 8...28)
        #expect(P.Sessions.noHookWarningOptions == [20, 10, 60])
        #expect(P.Sessions.staleAfterOptions == [3600, 1800, 14400, nil])
        #expect(P.AutoSwitch.thresholdRange == 1...20 && P.AutoSwitch.cooldownRange == 60...3600)
        #expect(P.Cleanup.notesStaleOptions == [14, 7, 30, 60, nil])
        #expect(P.Cleanup.notesArchiveOptions == [30, 14, 60, nil])
        #expect(P.Cleanup.scratchArchiveOptions == [7, 14, 30, nil])
        #expect(P.Cleanup.trashPurgeOptions == [30, 7, 60])
        #expect(P.Cleanup.tombstoneOptions == [90, 30, nil])
        #expect(P.Cleanup.sessionsStaleOptions == [3, 1, 7, nil])
        #expect(P.Cleanup.sessionsArchiveOptions == [7, 3, 14, nil])
        #expect(P.Cleanup.scrollbackDeleteOptions == [30, 7, 90, nil])
        #expect(P.Cleanup.condenseModelOptions.first == d.cleanup.condenseModel)
        #expect(P.Advanced.scrollbackRetentionOptions == [30, 7, 90])
    }

    /// Every value differs from its default, optionals included both ways.
    static var changed: P {
        var p = P.defaults
        p.general = P.General(launchAtLogin: true, showInDock: false, keepInMenuBarOnClose: false, quitBehavior: .stopAll,
                              hotkey: P.Hotkey(enabled: false, keyCode: 111, modifiers: 256 | 2048 | 4096, display: "⌃⌥⌘ F12"),
                              projectRoot: "~/Work", language: .system)
        p.appearance = P.Appearance(crt: .subtle, density: .comfort, uiFontSize: 14, terminalFont: "Menlo", terminalFontSize: 18,
                                    nativeVibrancy: true, reduceMotion: .on, zoomTerminalSteps: 1)
        p.sessions = P.Sessions(autoSessionId: false, noHookWarningSeconds: 60, staleAfterSeconds: nil, restoreAsStopped: false,
                                externalDisplay: .hidden, hideSDKAndDesktop: false)
        p.notifications = P.Notifications(
            waiting: P.EventRule(condition: .unfocusedOnly, notify: false, sound: false),
            error: P.EventRule(condition: .unfocusedOnly, notify: false, sound: false),
            done: P.EventRule(condition: .always, notify: false, sound: true),
            exitedNonZero: P.EventRule(condition: .unfocusedOnly, notify: false, sound: true),
            quietHours: P.QuietHours(enabled: false, start: "22:30", end: "07:15"), mutedGroupIDs: ["g-1", "g-2"],
            dockBadge: .off, menuBarIcon: .iconAndCounts, pausedUntil: Date(timeIntervalSince1970: 1_760_700_000.25))
        p.accounts = P.Accounts(cswapPath: "/tmp/fake-cswap", confirmBeforeSwitch: true,
                                autoSwitch: P.AutoSwitch(enabled: true, thresholdPercent: 7, checkFiveHour: false, checkWeekly: false,
                                                         cooldownSeconds: 900))
        p.notebook = P.Notebook(location: .iCloud, resizeImages: false, keepOriginal: true, mcpPort: 50000, autoAttachMCP: false,
                                defaultAIAccess: .append, aiCanWrite: true)
        p.cleanup = P.Cleanup(notesStaleDays: nil, notesArchiveDays: 60, scratchArchiveDays: 30, trashPurgeDays: 7, tombstoneDays: nil,
                              exempt: false, sessionsStaleDays: 1, sessionsArchiveDays: nil, scrollbackDeleteDays: 90,
                              resumeWarning: false, digest: .off, condenseAccount: "2", condenseModel: "opus-5.5")
        p.advanced = P.Advanced(scrollbackRetentionDays: 90)
        p.about = P.About(updateChannel: .beta)
        return p
    }

    @Test func everyLeafOfChangedDiffersFromItsDefault() {
        let p = Self.changed
        for path in P.leafPaths {
            #expect(p.value(atPath: path) != P.defaults.value(atPath: path), "\(path)")
        }
    }

    @Test func jsonRoundTrip() throws {
        for p in [P.defaults, Self.changed] {
            let data = try JSONEncoder().encode(p)
            #expect(try JSONDecoder().decode(P.self, from: data) == p)
        }
    }

    @Test func emptyOptionalsAreWrittenAsNullNotLeftOut() throws {
        let data = try JSONEncoder().encode(Self.changed)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(lookup(object, "sessions.staleAfterSeconds") is NSNull)
        #expect(lookup(object, "cleanup.tombstoneDays") is NSNull)
        #expect(lookup(try defaultsObject(), "notifications.pausedUntil") is NSNull)
        #expect(lookup(try defaultsObject(), "accounts.cswapPath") is NSNull)
        // A missing key is the default, null is 永不.
        #expect(try JSONDecoder().decode(P.self, from: Data(#"{"sessions":{}}"#.utf8)).sessions.staleAfterSeconds == 3600)
        #expect(try JSONDecoder().decode(P.self, from: Data(#"{"sessions":{"staleAfterSeconds":null}}"#.utf8))
            .sessions.staleAfterSeconds == nil)
    }

    @Test func sectionsDecodeOnTheirOwn() throws {
        let rule = try JSONDecoder().decode(P.EventRule.self, from: Data(#"{"condition":"unfocusedOnly","sound":false}"#.utf8))
        #expect(rule == P.EventRule(condition: .unfocusedOnly, notify: true, sound: false))
        let auto = try JSONDecoder().decode(P.AutoSwitch.self, from: Data(#"{"thresholdPercent":99,"enabled":"x"}"#.utf8))
        #expect(auto == P.AutoSwitch(thresholdPercent: 20))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(P.General.self, from: Data("[1]".utf8)) }
    }

    @Test func leafPathsCoverEveryStoredLeaf() throws {
        let paths = P.leafPaths
        #expect(paths.count == 72)
        #expect(Set(paths).count == paths.count)
        #expect(paths.contains("sessions.staleAfterSeconds"))
        #expect(paths.contains("general.hotkey.keyCode"))
        #expect(paths.contains("notifications.exitedNonZero.sound"))
        #expect(paths.contains("accounts.autoSwitch.cooldownSeconds"))
        // Every leaf of the written file is a path, and nothing else is.
        func leaves(_ object: [String: Any], _ prefix: String) -> [String] {
            object.flatMap { key, value -> [String] in
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                if let nested = value as? [String: Any] { return leaves(nested, path) }
                return [path]
            }
        }
        #expect(Set(leaves(try defaultsObject(), "")) == Set(paths + ["version"]))
    }

    @Test func everyLeafReadsBackWhatItWasSetTo() throws {
        for source in [P.defaults, Self.changed] {
            var copy = P.defaults
            for path in P.leafPaths {
                let text = try #require(source.value(atPath: path), "\(path)")
                try copy.set(text, atPath: path)
            }
            #expect(copy == source)
        }
    }

    @Test(arguments: [
        ("sessions.staleAfterSeconds", "1800", "1800"),
        ("sessions.staleAfterSeconds", "nil", "nil"),
        ("sessions.staleAfterSeconds", "null", "nil"),
        ("sessions.noHookWarningSeconds", " 60 ", "60"),
        ("general.launchAtLogin", "YES", "true"),
        ("general.showInDock", "0", "false"),
        ("general.quitBehavior", "stopAll", "stopAll"),
        ("general.quitBehavior", "STOPALL", "stopAll"),
        ("general.hotkey.keyCode", "111", "111"),
        ("general.hotkey.display", "", ""),
        ("general.projectRoot", "~/Code", "~/Code"),
        ("appearance.terminalFontSize", "30", "28"),
        ("appearance.terminalFontSize", "3", "8"),
        ("appearance.terminalFont", "sf mono", "SF Mono"),
        ("appearance.uiFontSize", "12", "12"),
        ("appearance.uiFontSize", "16", "16"),
        ("appearance.uiFontSize", "30", "20"),
        ("appearance.uiFontSize", "3", "10"),
        ("accounts.autoSwitch.thresholdPercent", "50", "20"),
        ("accounts.autoSwitch.thresholdPercent", "0", "1"),
        ("accounts.autoSwitch.thresholdPercent", "5", "5"),
        ("accounts.autoSwitch.cooldownSeconds", "5", "60"),
        ("accounts.autoSwitch.cooldownSeconds", "99999", "3600"),
        ("accounts.autoSwitch.enabled", "true", "true"),
        ("accounts.cswapPath", "/x/cswap", "/x/cswap"),
        ("accounts.cswapPath", "  ", "nil"),
        ("notebook.mcpPort", "80", "1024"),
        ("notifications.menuBarIcon", "iconAndCounts", "iconAndCounts"),
        ("notifications.dockBadge", "off", "off"),
        ("notifications.done.condition", "always", "always"),
        ("notifications.quietHours.start", "7:30", "07:30"),
        ("notifications.mutedGroupIDs", "a, b,,c", "a,b,c"),
        ("notifications.mutedGroupIDs", "", ""),
        ("notifications.pausedUntil", "2026-10-17T09:30:00Z", "2026-10-17T09:30:00.000Z"),
        ("notifications.pausedUntil", "nil", "nil"),
        ("cleanup.tombstoneDays", "nil", "nil"),
        ("cleanup.condenseModel", "haiku-5", "haiku-5"),
        ("cleanup.condenseAccount", "follow", "follow"),
        ("cleanup.condenseAccount", "3", "3"),
        ("cleanup.scrollbackDeleteDays", "nil", "nil"),
        ("advanced.scrollbackRetentionDays", "7", "7"),
        ("about.updateChannel", "beta", "beta"),
    ])
    func setThenValue(path: String, input: String, expected: String) throws {
        var p = P.defaults
        try p.set(input, atPath: path)
        #expect(p.value(atPath: path) == expected)
    }

    @Test(arguments: ["nope", "sessions", "sessions.nope", "general.hotkey", "general.launchAtLogin.x", "", "version",
                      "sessions..staleAfterSeconds", "shortcuts.anything"])
    func unknownPaths(path: String) {
        var p = P.defaults
        #expect(throws: PreferencesPathError.unknownPath(path)) { try p.set("1", atPath: path) }
        #expect(p == P.defaults)
        #expect(p.value(atPath: path) == nil)
    }

    @Test(arguments: [
        ("sessions.noHookWarningSeconds", "15"),
        ("sessions.staleAfterSeconds", "60"),
        ("sessions.noHookWarningSeconds", "nil"),
        ("cleanup.trashPurgeDays", "nil"),
        ("appearance.crt", "bogus"),
        ("appearance.uiFontSize", "big"),
        ("appearance.terminalFont", "Comic Sans"),
        ("appearance.terminalFontSize", "big"),
        ("general.launchAtLogin", "maybe"),
        ("general.projectRoot", "  "),
        ("general.hotkey.keyCode", "-1"),
        ("notifications.quietHours.start", "25:00"),
        ("notifications.quietHours.end", "8"),
        ("notifications.pausedUntil", "tomorrow"),
        ("cleanup.condenseModel", ""),
    ])
    func invalidValues(path: String, value: String) {
        var p = P.defaults
        #expect(throws: PreferencesPathError.invalidValue(path: path, value: value)) { try p.set(value, atPath: path) }
        #expect(p == P.defaults)
    }

    /// M4 (D30, D33): two leaves are unused but still stored, so an M3 file round-trips and its
    /// values are kept; the scrollback value the engine obeys is the CLEANUP one.
    @Test func m4UnusedLeavesStayStoredAndUntouched() throws {
        var p = P.defaults
        p.notebook.mcpPort = 50000
        p.advanced.scrollbackRetentionDays = 90
        p.cleanup.scrollbackDeleteDays = nil
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(P.self, from: data)
        #expect(back.notebook.mcpPort == 50000 && back.advanced.scrollbackRetentionDays == 90)
        #expect(back.cleanup.scrollbackDeleteDays == nil)
        #expect(P.leafPaths.contains("notebook.mcpPort") && P.leafPaths.contains("advanced.scrollbackRetentionDays"))
        // ADVANCED's row offers only the frozen three options; CLEANUP's adds 永不.
        #expect(P.Advanced.scrollbackRetentionOptions.map { Optional($0) } == Array(P.Cleanup.scrollbackDeleteOptions.prefix(3)))
    }

    @Test func assignments() throws {
        var p = P.defaults
        try p.apply(assignment: "sessions.staleAfterSeconds=1800")
        try p.apply(assignment: "accounts.cswapPath=/a=b/cswap")
        #expect(p.sessions.staleAfterSeconds == 1800)
        #expect(p.accounts.cswapPath == "/a=b/cswap")
        #expect(throws: PreferencesPathError.malformedAssignment("sessions.staleAfterSeconds")) {
            try p.apply(assignment: "sessions.staleAfterSeconds")
        }
        #expect(throws: PreferencesPathError.unknownPath("nope")) { try p.apply(assignment: "nope=1") }
    }
}
