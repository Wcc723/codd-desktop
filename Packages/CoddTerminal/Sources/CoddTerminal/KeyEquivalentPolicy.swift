/// Modifier keys of a key equivalent (the device-independent four; Caps Lock, Fn and the
/// numeric-pad flag never take part in matching).
public struct KeyModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// One key equivalent, for example ⌘K or ⌘⇧[.
///
/// `key` is the character the key types on a US layout without Shift. `keyCode` is the ANSI
/// virtual key code of the same physical key: it decides only when the event's characters are not
/// ASCII, which is what an input method such as 注音 reports for a Cmd chord (the K key arrives
/// as `ㄜ`). Latin layouts (Dvorak, AZERTY) keep matching by character, the way AppKit's menus do.
public struct KeyChord: Sendable, Hashable, CustomStringConvertible {
    public var key: String
    public var keyCode: UInt16
    public var modifiers: KeyModifiers

    public init(key: String, keyCode: UInt16, modifiers: KeyModifiers) {
        self.key = key
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// A chord on `key` (a US-layout unshifted character with a known ANSI key code), or nil.
    public init?(_ key: String, _ modifiers: KeyModifiers) {
        guard let entry = KeyChord.ansiKeys[key] else { return nil }
        self.init(key: key, keyCode: entry.keyCode, modifiers: modifiers)
    }

    public var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key.uppercased()
    }

    /// Whether a key-down event is this chord. `characters` is the event's
    /// `charactersIgnoringModifiers` (Shift applied, as AppKit reports it).
    public func matches(characters: String?, keyCode eventKeyCode: UInt16, modifiers eventModifiers: KeyModifiers)
        -> Bool
    {
        guard eventModifiers == modifiers else { return false }
        let typed = KeyChord.unshifted(characters ?? "")
        if typed.isEmpty || !typed.unicodeScalars.allSatisfy(\.isASCII) {
            return eventKeyCode == keyCode
        }
        return typed == key
    }

    /// libghostty `keybind` triggers that name this chord. Both spellings are listed (the typed
    /// character and the physical W3C key name), because an `unbind` only removes the exact
    /// trigger a default binding was declared with.
    public var ghosttyTriggers: [String] {
        guard let entry = KeyChord.ansiKeys[key] else { return [] }
        var mods: [String] = []
        if modifiers.contains(.control) { mods.append("ctrl") }
        if modifiers.contains(.option) { mods.append("alt") }
        if modifiers.contains(.shift) { mods.append("shift") }
        if modifiers.contains(.command) { mods.append("super") }
        let prefix = mods.map { $0 + "+" }.joined()
        var names = [entry.physicalName]
        if entry.unicodeTriggerIsSafe { names.insert(key, at: 0) }
        return names.map { prefix + $0 }
    }

    /// The unshifted US-layout character for a Shift-produced one (`{` → `[`, `K` → `k`).
    static func unshifted(_ characters: String) -> String {
        let lowered = characters.lowercased()
        return shiftedSymbols[lowered] ?? lowered
    }

    private static let shiftedSymbols: [String: String] = [
        "{": "[", "}": "]", "|": "\\", "<": ",", ">": ".", "?": "/", ":": ";", "\"": "'", "~": "`",
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=",
    ]

    struct ANSIKey {
        var keyCode: UInt16
        var physicalName: String
        /// The character can stand as a libghostty trigger on its own (`\` and `=` would be read
        /// as config syntax).
        var unicodeTriggerIsSafe: Bool
    }

    /// kVK_ANSI_* codes (Carbon `Events.h`) and libghostty's W3C key names.
    static let ansiKeys: [String: ANSIKey] = {
        var table: [String: ANSIKey] = [:]
        let letters: [(String, UInt16)] = [
            ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03), ("h", 0x04), ("g", 0x05), ("z", 0x06),
            ("x", 0x07), ("c", 0x08), ("v", 0x09), ("b", 0x0B), ("q", 0x0C), ("w", 0x0D), ("e", 0x0E),
            ("r", 0x0F), ("y", 0x10), ("t", 0x11), ("o", 0x1F), ("u", 0x20), ("i", 0x22), ("p", 0x23),
            ("l", 0x25), ("j", 0x26), ("k", 0x28), ("n", 0x2D), ("m", 0x2E),
        ]
        for (letter, code) in letters {
            table[letter] = ANSIKey(keyCode: code, physicalName: "key_" + letter, unicodeTriggerIsSafe: true)
        }
        let digits: [(String, UInt16)] = [
            ("1", 0x12), ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16), ("5", 0x17), ("9", 0x19),
            ("7", 0x1A), ("8", 0x1C), ("0", 0x1D),
        ]
        for (digit, code) in digits {
            table[digit] = ANSIKey(keyCode: code, physicalName: "digit_" + digit, unicodeTriggerIsSafe: true)
        }
        let symbols: [(String, UInt16, String, Bool)] = [
            ("=", 0x18, "equal", false), ("-", 0x1B, "minus", true), ("]", 0x1E, "bracket_right", true),
            ("[", 0x21, "bracket_left", true), ("'", 0x27, "quote", true), (";", 0x29, "semicolon", true),
            ("\\", 0x2A, "backslash", false), (",", 0x2B, "comma", true), ("/", 0x2C, "slash", true),
            (".", 0x2F, "period", true), ("`", 0x32, "backquote", true),
        ]
        for (symbol, code, name, safe) in symbols {
            table[symbol] = ANSIKey(keyCode: code, physicalName: name, unicodeTriggerIsSafe: safe)
        }
        return table
    }()
}

/// Which Cmd shortcuts belong to the app rather than the terminal.
///
/// A reserved chord is never consumed by the terminal view: `performKeyEquivalent` declines it so
/// it reaches the main menu, and if no menu item takes it the view passes the key-down up the
/// responder chain instead of encoding it for the program. libghostty's own default bindings for
/// the same chords are unbound in the rendered config as a second line of defence.
public struct KeyEquivalentPolicy: Sendable, Hashable {
    public var reserved: [KeyChord]

    public init(reserved: [KeyChord]) {
        self.reserved = reserved
    }

    /// CODD's app shortcuts (design/SPEC.md §2 keyboard list): ⌘K ⌘1…⌘9 ⌘\ ⌘J ⌘T ⌘L ⌘, ⌘N ⌘W ⌘Q
    /// ⌘⇧[ ⌘⇧]. ⌘C ⌘V ⌘A ⌘+ ⌘- ⌘0 stay with the terminal (copy, paste, select all, zoom).
    public static let codd: KeyEquivalentPolicy = {
        var keys = ["k", "\\", "j", "t", "l", ",", "n", "w", "q"]
        keys += (1 ... 9).map(String.init)
        var chords = keys.compactMap { KeyChord($0, .command) }
        chords += ["[", "]"].compactMap { KeyChord($0, [.command, .shift]) }
        return KeyEquivalentPolicy(reserved: chords)
    }()

    /// Whether a key-down event is one of the reserved chords.
    public func isReserved(characters: String?, keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        reserved.contains { $0.matches(characters: characters, keyCode: keyCode, modifiers: modifiers) }
    }
}
