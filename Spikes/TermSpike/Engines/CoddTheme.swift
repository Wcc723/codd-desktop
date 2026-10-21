import AppKit

/// CODD terminal look (design/helmet.html `.term`, §4 tokens): black background,
/// warm off-white text, amber cursor; JetBrains Mono 13 pt with PingFang TC for CJK.
enum CoddTheme {
    static let background = "#000000"
    static let foreground = "#e8e6d8"
    static let cursor = "#ffb84a"
    static let cursorText = "#000000"
    static let selectionBackground = "#5a4420"
    static let selectionForeground = "#f5ecd6"

    /// ANSI 0–15, derived from the Phosphor Console tokens.
    static let palette: [String] = [
        "#2a2a2a", "#ef5b5b", "#52c472", "#e6c84e", "#5b8def", "#b07cff", "#4ed1e6", "#d4cdb8",
        "#7a7468", "#ff7058", "#7cff9a", "#ffb84a", "#8aa9f5", "#ff7cb5", "#6ee0f0", "#f5ecd6",
    ]

    static let fontFamily = "JetBrains Mono"
    static let fontPostScriptName = "JetBrainsMono-Regular"
    static let cjkFamily = "PingFang TC"
    static let cjkPostScriptName = "PingFangTC-Regular"
    static let fontSize: CGFloat = 13

    // Window chrome (helmet.html tokens).
    static let chromeBackground = color("#050505")
    static let chromeLine = color("#2a2a2a")
    static let chromeText = color("#d4cdb8")
    static let chromeDim = color("#7a7468")
    static let amber = color("#ffb84a")

    /// `#rrggbb` to components; malformed input yields black.
    static func rgb(_ hex: String) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return (0, 0, 0) }
        return (UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }

    static func color(_ hex: String) -> NSColor {
        let (red, green, blue) = rgb(hex)
        return NSColor(
            srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1
        )
    }

    /// JetBrains Mono with PingFang TC as the CoreText cascade fallback; falls
    /// back to the system monospaced font when JetBrains Mono is not installed.
    static func terminalFont() -> NSFont {
        let base = NSFont(name: fontPostScriptName, size: fontSize)
            ?? NSFont(name: fontFamily, size: fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let cjk = NSFontDescriptor(fontAttributes: [.name: cjkPostScriptName, .size: fontSize])
        let descriptor = base.fontDescriptor.addingAttributes([.cascadeList: [cjk]])
        return NSFont(descriptor: descriptor, size: fontSize) ?? base
    }

    static func chromeFont(size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont(name: fontPostScriptName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }
}
