import CoddTerminal
import Foundation

/// CODD's terminal configuration: the package defaults (Phosphor Console, JetBrains Mono 13 with
/// PingFang TC, steady block cursor) plus the app shortcuts that are not Cmd + character chords.
enum CoddTerminalSetup {
    /// `KeyEquivalentPolicy.codd` plus ⌃Tab / ⌃⇧Tab (cycle sessions), ⌘⏎ (allow in the answer
    /// bar), ⌥⌘F (sidebar filter), ⌘P (pin), ⌘. (stop, D21), ⌘⇧N (quick note, M4 D13) and the
    /// interface zoom ⌘= / ⌘+ / ⌘− / ⌘0 (M4): a terminal with focus declines them, so the main menu
    /// gets them instead of the program (or libghostty's own bindings for them). The package also
    /// unbinds libghostty's defaults for every reserved chord, so its own font-size bindings never
    /// fire next to the menu's step (one step per key press).
    static let keyEquivalents: KeyEquivalentPolicy = {
        var chords = KeyEquivalentPolicy.codd.reserved
        let tab: UInt16 = 0x30
        let returnKey: UInt16 = 0x24
        chords.append(KeyChord(key: "\t", keyCode: tab, modifiers: .control))
        chords.append(KeyChord(key: "\t", keyCode: tab, modifiers: [.control, .shift]))
        // AppKit reports Shift+Tab as the back-tab character.
        chords.append(KeyChord(key: "\u{19}", keyCode: tab, modifiers: [.control, .shift]))
        chords.append(KeyChord(key: "\r", keyCode: returnKey, modifiers: .command))
        if let filter = KeyChord("f", [.command, .option]) { chords.append(filter) }
        for key in ["p", "."] {
            if let chord = KeyChord(key, .command) { chords.append(chord) }
        }
        // M4 D13: ⌘⇧N (快速筆記) from a terminal reaches the menu, never the program.
        if let quickNote = KeyChord("n", [.command, .shift]) { chords.append(quickNote) }
        chords += zoomChords
        return KeyEquivalentPolicy(reserved: chords)
    }()

    /// M4 interface zoom: ⌘= and ⌘⇧= (⌘+ on a US keyboard; the keypad's + reads as `=` too),
    /// ⌘− and ⌘0 belong to 顯示方式 › 放大 / 縮小 / 實際大小, which step the UI and the terminal sizes.
    static let zoomChords: [KeyChord] = [
        KeyChord("=", .command), KeyChord("=", [.command, .shift]), KeyChord("-", .command), KeyChord("0", .command),
    ].compactMap { $0 }

    /// libghostty's default bindings on the extra chords (next/previous tab, fullscreen). The
    /// view already declines them; unbinding is the second line of defence, like the package does
    /// for its own reserved chords (whose triggers it renders itself).
    static let extraUnbinds = [
        "keybind = ctrl+tab=unbind",
        "keybind = ctrl+shift+tab=unbind",
        "keybind = super+enter=unbind",
        "keybind = super+shift+n=unbind",
    ]

    /// The one configuration every CODD terminal uses (libghostty has one per process). The font
    /// size is applied per engine (`TerminalEngine.fontSize`) from Settings › 終端機字級.
    static let configuration = TerminalConfiguration(keyEquivalents: keyEquivalents, additionalGhosttyConfig: extraUnbinds)

    /// `configuration` with Settings › 外觀 › 終端機字型 (M3 I3). libghostty keeps one configuration
    /// per process, so a family change reaches every terminal, not only new ones.
    static func configuration(fontFamily: String) -> TerminalConfiguration {
        var config = configuration
        let family = fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        if !family.isEmpty { config.fontFamily = family }
        return config
    }

    /// Shown in a terminal whose PTY cannot be replayed (its holder is gone, no usable ring).
    static let holderGoneNote = Array("\u{1B}[2m// 這個分頁的 holder 已結束，沒有可重播的輸出。\u{1B}[0m\r\n".utf8)

    /// After a dead session's ring replay (D7): attributes reset, a fresh line, the dim note, and
    /// the cursor hidden (nothing typed here goes anywhere).
    static let replayFooter = Array("\u{1B}[0m\r\n\u{1B}[2m// holder 已結束 · 以上是最後的畫面（唯讀）\u{1B}[0m\r\n\u{1B}[?25l".utf8)
}
