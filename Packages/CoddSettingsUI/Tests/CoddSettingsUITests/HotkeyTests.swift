import AppKit
import Carbon.HIToolbox
import CoddPreferences
import CoddUI
import Foundation
import Testing
@testable import CoddSettingsUI

/// KeyCombo strings / descriptions / Codable, the recorder's key handling, and the exclusive
/// Carbon registration. Tests never register ⌥Space: the only registered combo is ⌃⌥⌘F12.
@Suite struct KeyComboTests {
    static let table: [(String, UInt32, UInt32, String, String, String)] = [
        ("option+space", UInt32(kVK_Space), KeyCombo.option, "⌥ Space", "⌥Space", "option+space"),
        ("ctrl+option+cmd+f12", UInt32(kVK_F12), KeyCombo.control | KeyCombo.option | KeyCombo.command, "⌃⌥⌘ F12", "⌃⌥⌘F12",
         "ctrl+option+cmd+f12"),
        ("cmd+shift+k", UInt32(kVK_ANSI_K), KeyCombo.command | KeyCombo.shift, "⇧⌘ K", "⇧⌘K", "shift+cmd+k"),
        ("Command+Control+Alt+Shift+1", UInt32(kVK_ANSI_1), KeyCombo.modifierMask, "⌃⌥⇧⌘ 1", "⌃⌥⇧⌘1", "ctrl+option+shift+cmd+1"),
        ("⌘+⇧+return", UInt32(kVK_Return), KeyCombo.command | KeyCombo.shift, "⇧⌘ ↩", "⇧⌘↩", "shift+cmd+return"),
        (" ctrl + left ", UInt32(kVK_LeftArrow), KeyCombo.control, "⌃ ←", "⌃←", "ctrl+left"),
        ("opt+,", UInt32(kVK_ANSI_Comma), KeyCombo.option, "⌥ ,", "⌥,", "option+comma"),
        ("cmd+key93", 93, KeyCombo.command, "⌘ Key 0x5d", "⌘Key 0x5d", "cmd+key93"),
    ]

    @Test func stringsAndDescriptions() throws {
        for (text, code, modifiers, description, compact, spec) in Self.table {
            let combo = try #require(KeyCombo(string: text), "\(text)")
            #expect(combo.keyCode == code, "\(text)")
            #expect(combo.modifiers == modifiers, "\(text)")
            #expect(combo.description == description, "\(text)")
            #expect(combo.compactDescription == compact, "\(text)")
            #expect(combo.spec == spec, "\(text)")
            #expect(KeyCombo(string: combo.spec) == combo, "\(text) round trip")
        }
        #expect(KeyCombo.optionSpace == KeyCombo(string: "option+space"))
        #expect(KeyCombo.optionSpace.description == CoddPreferences.defaults.general.hotkey.display)
        #expect(KeyCombo(CoddPreferences.defaults.general.hotkey) == .optionSpace)
    }

    @Test(arguments: ["", "option+", "+k", "foo+k", "cmd+k+j", "cmd+cmd+k", "cmd", "cmd+f21", "cmd+key200"])
    func invalidStrings(_ text: String) {
        #expect(KeyCombo(string: text) == nil, "\(text)")
    }

    @Test func requiredModifier() throws {
        #expect(try #require(KeyCombo(string: "cmd+k")).hasRequiredModifier)
        #expect(try #require(KeyCombo(string: "ctrl+f1")).hasRequiredModifier)
        #expect(!(try #require(KeyCombo(string: "shift+k")).hasRequiredModifier))
        #expect(!(try #require(KeyCombo(string: "f12")).hasRequiredModifier))
    }

    @Test func codable() throws {
        let combo = try #require(KeyCombo(string: "ctrl+option+cmd+f12"))
        let data = try JSONEncoder().encode(combo)
        #expect(String(decoding: data, as: UTF8.self).contains("\"keyCode\":111"))
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == combo)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: Data("\"cmd+shift+k\"".utf8)) == KeyCombo(string: "cmd+shift+k"))
        #expect(try JSONDecoder().decode(KeyCombo.self, from: Data(#"{"keyCode":49,"modifiers":2048}"#.utf8)) == .optionSpace)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(KeyCombo.self, from: Data("\"cmd+nope\"".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(KeyCombo.self, from: Data(#"{"keyCode":1}"#.utf8)) }
        // Bits outside ⌘ ⇧ ⌥ ⌃ are dropped.
        #expect(KeyCombo(keyCode: 40, modifiers: KeyCombo.command | 0x0100_0000).modifiers == KeyCombo.command)
    }

    @Test func preferencesHotkeyMapping() throws {
        let combo = try #require(KeyCombo(string: "cmd+shift+k"))
        let hotkey = CoddPreferences.Hotkey(combo, enabled: false)
        #expect(hotkey.keyCode == 40 && hotkey.modifiers == 768 && hotkey.display == "⇧⌘ K" && !hotkey.enabled)
        #expect(hotkey.combo == combo)
    }

    @Test @MainActor func eventFlagsMapToCarbon() {
        let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift, .capsLock, .function])
        #expect(combo == KeyCombo(string: "cmd+shift+k"))
    }
}

@MainActor
@Suite struct HotkeyRecorderTests {
    @Test func recorderNeedsAModifierAndCancelsOnEscape() {
        Harness.prepare()
        let recorder = HotkeyRecorderView(combo: .optionSpace)
        var recorded: [KeyCombo] = []
        var cancelled = 0
        var started = 0
        recorder.onRecorded = { recorded.append($0) }
        recorder.onCancelled = { cancelled += 1 }
        recorder.onStarted = { started += 1 }
        #expect(recorder.displayedText == "⌥ Space")
        #expect(!recorder.handleKeyDown(keyCode: UInt16(kVK_ANSI_K), flags: [.command]))
        recorder.startRecording()
        #expect(started == 1 && recorder.isRecording)
        #expect(recorder.displayedText == HotkeyRecorderView.prompt)
        #expect(recorder.button.label == "取消")
        // Plain and ⇧-only keys are swallowed; recording goes on.
        #expect(recorder.handleKeyDown(keyCode: UInt16(kVK_ANSI_K), flags: []))
        #expect(recorder.handleKeyDown(keyCode: UInt16(kVK_ANSI_K), flags: [.shift]))
        #expect(recorded.isEmpty && recorder.isRecording)
        #expect(recorder.handleKeyDown(keyCode: UInt16(kVK_Escape), flags: []))
        #expect(cancelled == 1 && !recorder.isRecording)
        #expect(recorder.displayedText == "⌥ Space")
        recorder.startRecording()
        #expect(recorder.handleKeyDown(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift]))
        #expect(recorded == [KeyCombo(string: "cmd+shift+k")!])
        #expect(!recorder.isRecording && cancelled == 1)
        // The owner decides; the shown combo changes only when it sets `combo`.
        #expect(recorder.displayedText == "⌥ Space")
        recorder.combo = recorded[0]
        #expect(recorder.displayedText == "⇧⌘ K")
        recorder.compact = true
        #expect(recorder.displayedText == "⇧⌘K")
        // A disabled recorder does not start.
        recorder.isEnabled = false
        recorder.startRecording()
        #expect(!recorder.isRecording)
    }

    @Test func generalRecorderStoresAcceptedCombosOnly() throws {
        let harness = Harness()
        let general = harness.section(.general, as: GeneralSectionView.self)
        let recorder = try #require(general.recorder)
        recorder.startRecording()
        #expect(harness.log.calls == ["recordHotkeyStarted"])
        recorder.handleKeyDown(keyCode: UInt16(kVK_F12), flags: [.control, .option, .command])
        #expect(harness.log.calls == ["recordHotkeyStarted", "recordHotkeyFinished"])
        #expect(harness.log.triedHotkeys == [KeyCombo(string: "ctrl+option+cmd+f12")!])
        #expect(harness.model.preferences.general.hotkey.display == "⌃⌥⌘ F12")
        #expect(harness.model.preferences.general.hotkey.keyCode == UInt32(kVK_F12))
        harness.sync()
        #expect(recorder.displayedText == "⌃⌥⌘ F12")
        // Refused: the previous combo stays and the reason shows under the row.
        harness.log.tryHotkeyResult = "⇧⌘ K 已被其他 App 使用，請改用別的組合鍵"
        recorder.startRecording()
        recorder.handleKeyDown(keyCode: UInt16(kVK_ANSI_K), flags: [.command, .shift])
        #expect(harness.model.preferences.general.hotkey.display == "⌃⌥⌘ F12")
        #expect(general.hotkeyNote == "⇧⌘ K 已被其他 App 使用，請改用別的組合鍵")
        #expect(harness.log.changes.count == 1)
        // ⎋ cancels and still tells the app to re-register.
        recorder.startRecording()
        recorder.handleKeyDown(keyCode: UInt16(kVK_Escape), flags: [])
        #expect(harness.log.calls.suffix(2) == ["recordHotkeyStarted", "recordHotkeyFinished"])
        // The app's own registration error wins over the recorder's.
        harness.model.info.hotkeyError = "⌃⌥⌘ F12 已被其他 App 使用，請改用別的組合鍵"
        harness.sync()
        #expect(general.hotkeyNote == "⌃⌥⌘ F12 已被其他 App 使用，請改用別的組合鍵")
    }

    @Test func shortcutsTableRecordsAndRestoresTheGlobalHotkey() throws {
        var prefs = CoddPreferences.defaults
        prefs.general.hotkey = CoddPreferences.Hotkey(KeyCombo(string: "ctrl+option+cmd+f12")!)
        let harness = Harness(preferences: prefs)
        let shortcuts = harness.section(.shortcuts, as: ShortcutsSectionView.self)
        let recorder = try #require(shortcuts.recorder)
        #expect(recorder.displayedText == "⌃⌥⌘F12")
        #expect(shortcuts.keyRows.count == 13)
        #expect(shortcuts.keyRows.last?.title == "叫出 CODD")
        // Only the Global row records; the others are static (M5).
        #expect(shortcuts.keyRows.dropLast().allSatisfy { $0.control is SxStaticButton })
        // `還原預設` asks for ⌥ Space (the stub accepts without registering anything).
        shortcuts.restoreDefaults()
        #expect(harness.log.triedHotkeys == [.optionSpace])
        #expect(KeyCombo(harness.model.preferences.general.hotkey) == .optionSpace)
        #expect(shortcuts.errorText == nil)
        harness.log.tryHotkeyResult = "⌥ Space 已被其他 App 使用，請改用別的組合鍵"
        recorder.startRecording()
        recorder.handleKeyDown(keyCode: UInt16(kVK_F12), flags: [.control, .option, .command])
        #expect(KeyCombo(harness.model.preferences.general.hotkey) == .optionSpace)
        #expect(shortcuts.errorText == "▲ ⌥ Space 已被其他 App 使用，請改用別的組合鍵")
    }
}

/// Real Carbon registrations, serialized (one combo, ⌃⌥⌘F12, never ⌥Space).
@MainActor
@Suite(.serialized) struct GlobalHotkeyTests {
    static let combo = KeyCombo(string: "ctrl+option+cmd+f12")!

    @Test func registersExclusivelyAndUnregisters() throws {
        Harness.prepare()
        let first = GlobalHotkey()
        do {
            try first.register(Self.combo) {}
        } catch GlobalHotkeyError.noEventTarget {
            print("GlobalHotkeyTests: skipped, no application event target in this process")
            return
        } catch GlobalHotkeyError.alreadyInUse {
            Issue.record("⌃⌥⌘F12 is held by another app on this Mac; the registration test cannot run")
            return
        }
        #expect(first.registered == Self.combo)
        // The same combo again on the same instance only swaps the action.
        try first.register(Self.combo) {}
        #expect(first.registered == Self.combo)

        // A second exclusive registration of the same combo from another instance.
        let second = GlobalHotkey()
        do {
            try second.register(Self.combo) {}
            print("GlobalHotkeyTests: this macOS accepted a second exclusive registration of ⌃⌥⌘F12 inside one process")
            second.unregister()
        } catch let error as GlobalHotkeyError {
            #expect(error == .alreadyInUse(Self.combo))
            #expect(error.message == "⌃⌥⌘ F12 已被其他 App 使用，請改用別的組合鍵")
            #expect(second.registered == nil)
        }

        // A press is routed by id: only the owning instance answers.
        var fired = 0
        try first.register(Self.combo) { fired += 1 }
        #expect(first.fire(signature: GlobalHotkey.signature, id: first.identifier))
        #expect(!first.fire(signature: GlobalHotkey.signature, id: second.identifier))
        #expect(!first.fire(signature: 0x1234_5678, id: first.identifier))
        #expect(fired == 1)

        first.unregister()
        #expect(first.registered == nil)
        #expect(!first.fire(signature: GlobalHotkey.signature, id: first.identifier))
        // Released: the other instance can take it now.
        try second.register(Self.combo) {}
        #expect(second.registered == Self.combo)
        second.unregister()
        #expect(second.registered == nil)
    }

    @Test func refusesCombosWithoutCommandOptionOrControl() throws {
        let hotkey = GlobalHotkey()
        let plain = try #require(KeyCombo(string: "f12"))
        #expect(throws: GlobalHotkeyError.needsModifier(plain)) { try hotkey.register(plain) {} }
        let shifted = try #require(KeyCombo(string: "shift+f12"))
        #expect(throws: GlobalHotkeyError.needsModifier(shifted)) { try hotkey.register(shifted) {} }
        #expect(hotkey.registered == nil)
        #expect(GlobalHotkeyError.needsModifier(plain).message == "F12 需要包含 ⌘、⌥ 或 ⌃")
    }
}
