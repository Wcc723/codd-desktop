import AppKit
import Carbon.HIToolbox
import CoddPreferences

/// A global hotkey in Carbon terms (virtual key code + `cmdKey` / `shiftKey` / `optionKey` /
/// `controlKey` mask), so `GlobalHotkey` registers it as stored. Key names follow the ANSI
/// layout (the key code is the physical key).
public struct KeyCombo: Sendable, Equatable, Hashable, Codable, CustomStringConvertible {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// ⌥ Space, the default (D22).
    public static let optionSpace = KeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))

    // MARK: Modifiers

    public static let command = UInt32(cmdKey)
    public static let shift = UInt32(shiftKey)
    public static let option = UInt32(optionKey)
    public static let control = UInt32(controlKey)
    static let modifierMask = command | shift | option | control

    /// At least one of ⌘ ⌥ ⌃ (⇧ alone is typing): the rule for recorded and registered combos.
    public var hasRequiredModifier: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    // MARK: Strings

    /// `"option+space"`, `"ctrl+option+cmd+f12"`, `"cmd+shift+k"` (any order, any case; also
    /// `command` / `control` / `alt` / `opt` and the glyphs ⌘ ⌥ ⌃ ⇧). Exactly one key, each
    /// modifier at most once; nil otherwise.
    public init?(string: String) {
        let tokens = string.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard !tokens.isEmpty, !tokens.contains(where: \.isEmpty) else { return nil }
        var mask: UInt32 = 0
        var key: UInt32?
        for token in tokens {
            if let flag = Self.modifierNames[token] {
                guard mask & flag == 0 else { return nil }
                mask |= flag
            } else if let code = Self.keyCode(named: token) {
                guard key == nil else { return nil }
                key = code
            } else {
                return nil
            }
        }
        guard let key else { return nil }
        self.init(keyCode: key, modifiers: mask)
    }

    /// `⌥ Space`, `⌃⌥⌘ F12`, `⇧⌘ K`: the glyphs in ⌃⌥⇧⌘ order, a space, the key.
    public var description: String {
        let glyphs = modifierGlyphs
        return glyphs.isEmpty ? keyName : "\(glyphs) \(keyName)"
    }

    /// Without the space (`⌥Space`), as the SHORTCUTS table writes keys.
    public var compactDescription: String { modifierGlyphs + keyName }

    /// The canonical `init?(string:)` form: `ctrl+option+shift+cmd+<key>` (dumps, DEBUG flags).
    public var spec: String {
        var parts: [String] = []
        if modifiers & Self.control != 0 { parts.append("ctrl") }
        if modifiers & Self.option != 0 { parts.append("option") }
        if modifiers & Self.shift != 0 { parts.append("shift") }
        if modifiers & Self.command != 0 { parts.append("cmd") }
        parts.append(Self.specName(for: keyCode))
        return parts.joined(separator: "+")
    }

    public var modifierGlyphs: String {
        var out = ""
        if modifiers & Self.control != 0 { out += "⌃" }
        if modifiers & Self.option != 0 { out += "⌥" }
        if modifiers & Self.shift != 0 { out += "⇧" }
        if modifiers & Self.command != 0 { out += "⌘" }
        return out
    }

    /// `Space`, `F12`, `K`, `1`, `↩`, `←`, `,`; an unknown code reads `Key 0x5d`.
    public var keyName: String {
        if let name = Self.displayNames[keyCode] { return name }
        return String(format: "Key 0x%02x", keyCode)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    /// Decodes `{"keyCode":49,"modifiers":2048}` or a string spec (`"option+space"`).
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            guard let combo = KeyCombo(string: text) else {
                throw DecodingError.dataCorruptedError(in: single, debugDescription: "not a key combo: \(text)")
            }
            self = combo
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try container.decode(UInt32.self, forKey: .keyCode),
                  modifiers: try container.decode(UInt32.self, forKey: .modifiers))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
    }

    // MARK: AppKit

    /// The combo of a key-down event (Carbon key code, ⌘ ⇧ ⌥ ⌃ only).
    public init(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= Self.command }
        if flags.contains(.shift) { mask |= Self.shift }
        if flags.contains(.option) { mask |= Self.option }
        if flags.contains(.control) { mask |= Self.control }
        self.init(keyCode: UInt32(keyCode), modifiers: mask)
    }

    // MARK: Tables

    private static let modifierNames: [String: UInt32] = [
        "cmd": command, "command": command, "⌘": command,
        "shift": shift, "⇧": shift,
        "option": option, "opt": option, "alt": option, "⌥": option,
        "ctrl": control, "control": control, "⌃": control,
    ]

    private static let letters: [(String, Int)] = [
        ("a", kVK_ANSI_A), ("b", kVK_ANSI_B), ("c", kVK_ANSI_C), ("d", kVK_ANSI_D), ("e", kVK_ANSI_E), ("f", kVK_ANSI_F),
        ("g", kVK_ANSI_G), ("h", kVK_ANSI_H), ("i", kVK_ANSI_I), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L),
        ("m", kVK_ANSI_M), ("n", kVK_ANSI_N), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P), ("q", kVK_ANSI_Q), ("r", kVK_ANSI_R),
        ("s", kVK_ANSI_S), ("t", kVK_ANSI_T), ("u", kVK_ANSI_U), ("v", kVK_ANSI_V), ("w", kVK_ANSI_W), ("x", kVK_ANSI_X),
        ("y", kVK_ANSI_Y), ("z", kVK_ANSI_Z),
        ("0", kVK_ANSI_0), ("1", kVK_ANSI_1), ("2", kVK_ANSI_2), ("3", kVK_ANSI_3), ("4", kVK_ANSI_4), ("5", kVK_ANSI_5),
        ("6", kVK_ANSI_6), ("7", kVK_ANSI_7), ("8", kVK_ANSI_8), ("9", kVK_ANSI_9),
    ]

    private static let functionKeys: [Int] = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                              kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]

    /// spec name, display name, key code; the first spec name of a code is canonical.
    private static let named: [(spec: [String], display: String, code: Int)] = [
        (["space"], "Space", kVK_Space),
        (["return", "enter"], "↩", kVK_Return),
        (["tab"], "Tab", kVK_Tab),
        (["escape", "esc"], "⎋", kVK_Escape),
        (["delete", "backspace"], "⌫", kVK_Delete),
        (["forwarddelete"], "⌦", kVK_ForwardDelete),
        (["left"], "←", kVK_LeftArrow), (["right"], "→", kVK_RightArrow),
        (["up"], "↑", kVK_UpArrow), (["down"], "↓", kVK_DownArrow),
        (["home"], "Home", kVK_Home), (["end"], "End", kVK_End),
        (["pageup"], "PgUp", kVK_PageUp), (["pagedown"], "PgDn", kVK_PageDown),
        (["comma", ","], ",", kVK_ANSI_Comma), (["period", "."], ".", kVK_ANSI_Period),
        (["slash", "/"], "/", kVK_ANSI_Slash), (["semicolon", ";"], ";", kVK_ANSI_Semicolon),
        (["quote", "'"], "'", kVK_ANSI_Quote), (["leftbracket", "["], "[", kVK_ANSI_LeftBracket),
        (["rightbracket", "]"], "]", kVK_ANSI_RightBracket), (["backslash", "\\"], "\\", kVK_ANSI_Backslash),
        (["minus", "-"], "-", kVK_ANSI_Minus), (["equal", "="], "=", kVK_ANSI_Equal),
        (["grave", "`"], "`", kVK_ANSI_Grave),
    ]

    private static let codesBySpec: [String: UInt32] = {
        var table: [String: UInt32] = [:]
        for (name, code) in letters { table[name] = UInt32(code) }
        for (index, code) in functionKeys.enumerated() { table["f\(index + 1)"] = UInt32(code) }
        for entry in named { for name in entry.spec { table[name] = UInt32(entry.code) } }
        return table
    }()

    private static let displayNames: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        for (name, code) in letters { table[UInt32(code)] = name.uppercased() }
        for (index, code) in functionKeys.enumerated() { table[UInt32(code)] = "F\(index + 1)" }
        for entry in named { table[UInt32(entry.code)] = entry.display }
        return table
    }()

    private static let canonicalSpecs: [UInt32: String] = {
        var table: [UInt32: String] = [:]
        for (name, code) in letters { table[UInt32(code)] = name }
        for (index, code) in functionKeys.enumerated() { table[UInt32(code)] = "f\(index + 1)" }
        for entry in named { table[UInt32(entry.code)] = entry.spec[0] }
        return table
    }()

    /// A table name, or `key<decimal code>` (the canonical spec of a key without a name).
    private static func keyCode(named token: String) -> UInt32? {
        if let code = codesBySpec[token] { return code }
        guard token.hasPrefix("key"), let code = UInt32(token.dropFirst(3)), code < 128 else { return nil }
        return code
    }

    private static func specName(for code: UInt32) -> String { canonicalSpecs[code] ?? "key\(code)" }
}

extension KeyCombo {
    /// The stored hotkey of the preferences (`general.hotkey`).
    public init(_ hotkey: CoddPreferences.Hotkey) {
        self.init(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
    }
}

extension CoddPreferences.Hotkey {
    /// The preference value for `combo` (its `display` is the combo's description).
    public init(_ combo: KeyCombo, enabled: Bool = true) {
        self.init(enabled: enabled, keyCode: combo.keyCode, modifiers: combo.modifiers, display: combo.description)
    }

    public var combo: KeyCombo { KeyCombo(self) }
}
