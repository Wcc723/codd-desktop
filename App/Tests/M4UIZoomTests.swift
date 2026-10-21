import AppKit
import CoddPreferences
import CoddTerminal
import CoddUI
import Darwin
import Foundation
import Testing
@testable import CODD

/// M4 interface zoom (user feedback 2026-10-18): 顯示方式 › 放大 ⌘+ / 縮小 ⌘− / 實際大小 ⌘0, the
/// terminals leaving those chords to the menu, the steps on both sizes through the preferences
/// (persisted), the launch peek at preferences.json and the composer following the zoom. Temp
/// folders only; every test leaves the zoom at the default.

private func makeZoomTempDirectory(_ prefix: String) throws -> URL {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    return URL(fileURLWithPath: String(cString: created), isDirectory: true)
}

private func storedAppearance(_ url: URL) throws -> CoddPreferences.Appearance {
    try JSONDecoder().decode(CoddPreferences.self, from: Data(contentsOf: url)).appearance
}

@MainActor
@Suite("M4 interface zoom · menu and terminal keys")
struct M4ZoomMenuTests {
    private func viewMenu(_ menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.title == "顯示方式" }?.submenu
    }

    @Test func viewMenuHasTheZoomItemsAndTheMainWindowMovedToOptionCommandZero() throws {
        let commands = ZoomCountingCommands()
        let menu = MainMenuBuilder.build(commands: commands)
        let view = try #require(viewMenu(menu))
        let larger = view.items.filter { $0.action == #selector(CoddCommands.zoomIn(_:)) }
        #expect(larger.map(\.keyEquivalent) == ["+", "=", "+"])
        #expect(larger.map(\.isHidden) == [false, true, true])
        let allLarger = larger.allSatisfy { $0.title == "放大" }
        #expect(allLarger)
        let hiddenKeepTheirKeys = larger.dropFirst().allSatisfy { $0.allowsKeyEquivalentWhenHidden }
        #expect(hiddenKeepTheirKeys)
        #expect(larger.last?.keyEquivalentModifierMask == [.command, .shift])
        let smaller = try #require(view.items.first { $0.action == #selector(CoddCommands.zoomOut(_:)) })
        #expect(smaller.title == "縮小" && smaller.keyEquivalent == "-" && smaller.keyEquivalentModifierMask == .command)
        let actual = try #require(view.items.first { $0.action == #selector(CoddCommands.zoomToActualSize(_:)) })
        #expect(actual.title == "實際大小" && actual.keyEquivalent == "0" && actual.keyEquivalentModifierMask == .command)
        let mainWindow = menu.items.compactMap(\.submenu).flatMap(\.items).first { $0.action == #selector(CoddCommands.showMainWindow(_:)) }
        #expect(mainWindow?.keyEquivalent == "0" && mainWindow?.keyEquivalentModifierMask == [.command, .option])
    }

    @Test func zoomChordsReachTheirItems() {
        let commands = ZoomCountingCommands()
        let menu = MainMenuBuilder.build(commands: commands)
        func press(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else { return false }
            return menu.performKeyEquivalent(with: event)
        }
        #expect(press("=", 0x18, .command))
        #expect(press("+", 0x18, [.command, .shift]))
        #expect(commands.zoomIns == 2, "⌘= and ⌘+ are one step each")
        #expect(press("-", 0x1B, .command))
        #expect(commands.zoomOuts == 1)
        #expect(press("0", 0x1D, .command))
        #expect(commands.resets == 1)
        #expect(press("0", 0x1D, [.command, .option]))
        #expect(commands.mainWindows == 1, "⌥⌘0 opens the main window")
    }

    @Test func terminalsLeaveTheZoomChordsToTheMenuAlsoUnder注音() {
        let policy = CoddTerminalSetup.keyEquivalents
        #expect(policy.isReserved(characters: "=", keyCode: 0x18, modifiers: .command))
        #expect(policy.isReserved(characters: "+", keyCode: 0x18, modifiers: [.command, .shift]), "⌘+ on a US keyboard")
        #expect(policy.isReserved(characters: "-", keyCode: 0x1B, modifiers: .command))
        #expect(policy.isReserved(characters: "0", keyCode: 0x1D, modifiers: .command))
        #expect(policy.isReserved(characters: "ㄦ", keyCode: 0x1B, modifiers: .command), "注音 reports ⌘− as ㄦ")
        #expect(policy.isReserved(characters: "ㄢ", keyCode: 0x1D, modifiers: .command), "注音 reports ⌘0 as ㄢ")
        // Other keys still reach the program.
        #expect(!policy.isReserved(characters: "c", keyCode: 0x08, modifiers: .command), "⌘C copies in the terminal")
        #expect(!policy.isReserved(characters: "=", keyCode: 0x18, modifiers: []), "a plain = is typed")
        #expect(!policy.isReserved(characters: "-", keyCode: 0x1B, modifiers: .control))
        // libghostty's own font-size bindings are unbound as the second line of defence.
        let rendered = CoddTerminalSetup.configuration.renderedGhosttyConfig
        for line in ["keybind = super+equal=unbind", "keybind = shift+super+equal=unbind", "keybind = super+minus=unbind",
                     "keybind = super+digit_0=unbind"] {
            #expect(rendered.contains(line), "\(line)")
        }
        #expect(TerminalRuntime.diagnostics(for: CoddTerminalSetup.configuration).isEmpty)
    }

    @Test func itemsAreDisabledAtTheirBoundsAndWhileComposing() {
        typealias A = CoddPreferences.Appearance
        let zoomIn = #selector(AppDelegate.zoomIn(_:))
        let zoomOut = #selector(AppDelegate.zoomOut(_:))
        let reset = #selector(AppDelegate.zoomToActualSize(_:))
        let start = A()
        #expect(InterfaceZoomCommands.isEnabled(zoomIn, appearance: start, composing: false) == true)
        #expect(InterfaceZoomCommands.isEnabled(zoomOut, appearance: start, composing: false) == true)
        #expect(InterfaceZoomCommands.isEnabled(reset, appearance: start, composing: false) == false, "already the actual size")
        #expect(InterfaceZoomCommands.isEnabled(zoomIn, appearance: start, composing: true) == false)
        let top = A(uiFontSize: 20, terminalFontSize: 28)
        #expect(InterfaceZoomCommands.isEnabled(zoomIn, appearance: top, composing: false) == false)
        #expect(InterfaceZoomCommands.isEnabled(reset, appearance: top, composing: false) == true)
        #expect(InterfaceZoomCommands.isEnabled(#selector(AppDelegate.quickNote(_:)), appearance: start, composing: false) == nil)
    }
}

@MainActor
@Suite("M4 interface zoom · preferences and apply")
struct M4ZoomPreferencesTests {
    @Test func stepsWriteBothSizesAndPersist() async throws {
        let dir = try makeZoomTempDirectory("codd-m4-zoom")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        let service = PreferencesService(url: url, legacyDefaults: nil, saveDelay: .milliseconds(20))
        await service.load()
        service.update { $0.appearance.terminalFontSize = 15 }
        #expect(InterfaceZoomCommands.perform(.in, on: service))
        #expect(InterfaceZoomCommands.perform(.in, on: service))
        #expect(service.preferences.appearance.uiFontSize == 15 && service.preferences.appearance.terminalFontSize == 17)
        #expect(InterfaceZoomCommands.perform(.out, on: service))
        service.flush()
        var stored = try storedAppearance(url)
        #expect(stored.uiFontSize == 14 && stored.terminalFontSize == 16, "the offset of 2 is kept and written")
        #expect(InterfaceZoomCommands.perform(.reset, on: service))
        #expect(!InterfaceZoomCommands.perform(.reset, on: service), "nothing left to reset")
        service.flush()
        stored = try storedAppearance(url)
        #expect(stored.uiFontSize == 13 && stored.terminalFontSize == 15, "⌘0 takes back the zoom, not the chosen 15")
        #expect(stored.zoomTerminalSteps == 0)
        // A− / A+ move the terminal alone, through the same preference (⌘0 keeps it).
        InterfaceZoomCommands.stepTerminal(service, by: 1)
        #expect(service.preferences.appearance.uiFontSize == 13 && service.preferences.appearance.terminalFontSize == 16)
        #expect(!InterfaceZoomCommands.perform(.reset, on: service), "UI 13 and the user's own terminal size: nothing to reset")
        // At the top of both ranges a step changes nothing.
        service.update {
            $0.appearance.uiFontSize = 20
            $0.appearance.terminalFontSize = 28
        }
        #expect(!InterfaceZoomCommands.perform(.in, on: service))
        InterfaceZoomCommands.stepTerminal(service, by: 1)
        #expect(service.preferences.appearance.terminalFontSize == 28)
        #expect(ShellState.fontSizeRange == 8...28, "the live terminal size has the preference's range")
    }

    @Test func aLaunchPeeksAtTheStoredUIFontSize() throws {
        let dir = try makeZoomTempDirectory("codd-m4-zoom-launch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(PreferencesStore.fileName)
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: []) == 13, "no file: the default")
        func write(_ value: Any) throws {
            let object: [String: Any] = ["version": 1, "appearance": ["uiFontSize": value]]
            try JSONSerialization.data(withJSONObject: object).write(to: url)
        }
        try write(17)
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: []) == 17)
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: ["appearance.uiFontSize=11", "sessions.staleAfterSeconds=1800"]) == 11,
                "a DEBUG assignment wins, as after the full read")
        try write(99)
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: []) == 20, "clamped like the full read")
        try write("big")
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: []) == 13)
        try write(14.5)
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: []) == 13)
        try write(true)
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: []) == 13, "a JSON boolean is not a size")
        try Data("{ not json".utf8).write(to: url)
        #expect(AppDelegate.launchUIFontSize(file: url, assignments: []) == 13)
        #expect(FileManager.default.fileExists(atPath: url.path), "the peek never moves or rewrites the file")
    }

    @Test func theComposerFollowsTheZoomAndComesBack() {
        defer { UIZoom.apply(fontSize: UIZoom.defaultFontSize) }
        let bar = ComposerBarView()
        let height = bar.preferredHeight
        #expect(height > 0)
        UIZoom.apply(fontSize: 18)
        bar.zoomDidChange()
        #expect(bar.preferredHeight > height, "taller field and rows at UI 18")
        let font = bar.textView.font
        #expect(font.map { abs($0.pointSize - 12.5 * 18 / 13) < 0.01 } == true)
        UIZoom.apply(fontSize: 13)
        bar.zoomDidChange()
        #expect(bar.preferredHeight == height)
        #expect(bar.textView.font?.pointSize == 12.5)
    }

    @Test func theWindowMinimumGrowsWithTheRailAndSidebarOnly() {
        let base = MainWindowController.minimumSize
        let zoomed = UIZoom.withScale(1.5) { MainWindowController.minimumSize }
        #expect(zoomed.width == (Metrics.Design.railWidth + Metrics.Design.sidebarMinWidth) * 1.5 + Metrics.Design.mainMinWidth + 2)
        #expect(zoomed.height == base.height, "the height stays: a zoomed window must still fit a laptop screen")
    }
}

/// Counts the zoom commands (and ⌥⌘0) a menu sends.
@MainActor
private final class ZoomCountingCommands: NSObject, CoddCommands {
    var zoomIns = 0
    var zoomOuts = 0
    var resets = 0
    var mainWindows = 0
    @objc func showSettings(_ sender: Any?) {}
    @objc func showQuickSwitch(_ sender: Any?) {}
    @objc func toggleSessionSidebar(_ sender: Any?) {}
    @objc func selectSessionByNumber(_ sender: NSMenuItem) {}
    @objc func selectNextSession(_ sender: Any?) {}
    @objc func selectPreviousSession(_ sender: Any?) {}
    @objc func allowCurrentSession(_ sender: Any?) {}
    @objc func newShellTab(_ sender: Any?) {}
    @objc func toggleBottomTerminal(_ sender: Any?) {}
    @objc func showMainWindow(_ sender: Any?) { mainWindows += 1 }
    @objc func focusSidebarFilter(_ sender: Any?) {}
    @objc func newSession(_ sender: Any?) {}
    @objc func quitApp(_ sender: Any?) {}
    @objc func togglePinCurrentSession(_ sender: Any?) {}
    @objc func stopCurrentSession(_ sender: Any?) {}
    @objc func toggleComposer(_ sender: Any?) {}
    @objc func zoomIn(_ sender: Any?) { zoomIns += 1 }
    @objc func zoomOut(_ sender: Any?) { zoomOuts += 1 }
    @objc func zoomToActualSize(_ sender: Any?) { resets += 1 }
}
