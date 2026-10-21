import CoreGraphics
import Foundation

/// How CODD terminals look and behave. Rendered into one libghostty config that every surface
/// shares (one libghostty app, so font atlases are shared between sessions).
///
/// The rendered config is the whole config: libghostty never reads the user's own Ghostty config
/// files or resources.
public struct TerminalConfiguration: Sendable, Hashable {
    public enum CursorStyle: String, Sendable, Hashable {
        case block
        case bar
        case underline
    }

    /// Primary font family. libghostty falls back to its embedded JetBrains Mono when the family
    /// is not installed or registered with the process.
    public var fontFamily: String
    /// Families tried, in order, for glyphs the primary font lacks (CJK).
    public var fallbackFontFamilies: [String]
    /// Points. Each surface starts here; ⌘0 returns to it.
    public var fontSize: CGFloat
    public var colors: TerminalColorTheme
    public var cursorStyle: CursorStyle
    /// Off by default: a blinking cursor kept about 225 MiB of Metal memory resident per surface in
    /// the M0 spike. A program can still request blinking itself (DECSCUSR).
    public var cursorBlinks: Bool
    /// Horizontal and vertical padding around the grid, in points (helmet.html `.term`: 16 / 10).
    public var paddingX: Int
    public var paddingY: Int
    /// Scrollback per surface, in bytes of libghostty's page memory (not lines).
    public var scrollbackLimitBytes: Int
    /// Cmd shortcuts the terminal leaves to the app's main menu.
    public var keyEquivalents: KeyEquivalentPolicy
    /// Plain ⌘V while the pasteboard holds only an image sends Ctrl+V (0x16) instead of an empty
    /// paste, because Claude Code reads image pastes from the clipboard itself on Ctrl+V.
    public var pasteImageAsControlV: Bool
    /// Raw libghostty config lines (`key = value`) appended last. An escape hatch for experiments;
    /// a line libghostty rejects makes it fall back to its defaults for the whole config.
    public var additionalGhosttyConfig: [String]

    public init(
        fontFamily: String = "JetBrains Mono",
        fallbackFontFamilies: [String] = ["PingFang TC"],
        fontSize: CGFloat = 13,
        colors: TerminalColorTheme = .phosphorConsole,
        cursorStyle: CursorStyle = .block,
        cursorBlinks: Bool = false,
        paddingX: Int = 16,
        paddingY: Int = 10,
        scrollbackLimitBytes: Int = 10_000_000,
        keyEquivalents: KeyEquivalentPolicy = .codd,
        pasteImageAsControlV: Bool = true,
        additionalGhosttyConfig: [String] = []
    ) {
        self.fontFamily = fontFamily
        self.fallbackFontFamilies = fallbackFontFamilies
        self.fontSize = fontSize
        self.colors = colors
        self.cursorStyle = cursorStyle
        self.cursorBlinks = cursorBlinks
        self.paddingX = paddingX
        self.paddingY = paddingY
        self.scrollbackLimitBytes = scrollbackLimitBytes
        self.keyEquivalents = keyEquivalents
        self.pasteImageAsControlV = pasteImageAsControlV
        self.additionalGhosttyConfig = additionalGhosttyConfig
    }

    public static let `default` = TerminalConfiguration()

    /// Smallest and largest font size the engine accepts (libghostty clamps similarly).
    public static let fontSizeRange: ClosedRange<CGFloat> = 6 ... 72

    /// The libghostty config, one `key = value` per entry.
    public var ghosttyConfigLines: [String] {
        var lines: [String] = []
        // Repeated font-family entries form libghostty's fallback chain.
        for family in [fontFamily] + fallbackFontFamilies where !family.isEmpty {
            lines.append("font-family = \(family)")
        }
        lines.append("font-size = \(Self.number(Self.clampedFontSize(fontSize)))")
        lines.append("font-thicken = false")

        lines.append("background = \(colors.background)")
        lines.append("foreground = \(colors.foreground)")
        lines.append("cursor-color = \(colors.cursor)")
        lines.append("cursor-text = \(colors.cursorText)")
        lines.append("selection-background = \(colors.selectionBackground)")
        lines.append("selection-foreground = \(colors.selectionForeground)")
        for (index, color) in colors.palette.prefix(16).enumerated() {
            lines.append("palette = \(index)=\(color)")
        }

        lines.append("cursor-style = \(cursorStyle.rawValue)")
        lines.append("cursor-style-blink = \(cursorBlinks)")
        lines.append("window-padding-x = \(max(0, paddingX))")
        lines.append("window-padding-y = \(max(0, paddingY))")
        lines.append("scrollback-limit = \(max(0, scrollbackLimitBytes))")
        // CODD owns closing tabs; libghostty must never ask.
        lines.append("confirm-close-surface = false")

        for chord in keyEquivalents.reserved {
            for trigger in chord.ghosttyTriggers {
                lines.append("keybind = \(trigger)=unbind")
            }
        }
        lines += additionalGhosttyConfig
        return lines
    }

    /// `ghosttyConfigLines` as one config file text.
    public var renderedGhosttyConfig: String {
        ghosttyConfigLines.joined(separator: "\n") + "\n"
    }

    static func clampedFontSize(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return 13 }
        return min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
    }

    /// libghostty parses numbers with a `.` separator only; `String(format:)` without a locale is
    /// POSIX, so a German or Arabic system locale cannot change the output.
    static func number(_ value: CGFloat) -> String {
        let rounded = (Double(value) * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}
