/// Terminal colors as `#rrggbb` strings (the form libghostty's config takes).
public struct TerminalColorTheme: Sendable, Hashable {
    public var background: String
    public var foreground: String
    public var cursor: String
    /// The glyph under the block cursor.
    public var cursorText: String
    public var selectionBackground: String
    public var selectionForeground: String
    /// ANSI colors 0–15. Entries past 16 are ignored; missing ones keep libghostty's default.
    public var palette: [String]

    public init(
        background: String,
        foreground: String,
        cursor: String,
        cursorText: String,
        selectionBackground: String,
        selectionForeground: String,
        palette: [String]
    ) {
        self.background = background
        self.foreground = foreground
        self.cursor = cursor
        self.cursorText = cursorText
        self.selectionBackground = selectionBackground
        self.selectionForeground = selectionForeground
        self.palette = palette
    }

    /// Phosphor Console (design/helmet.html `.term` and the §4 tokens): black background, warm
    /// off-white text, amber block cursor. Same values as the M0 spike's `CoddTheme`.
    ///
    /// ANSI mapping to helmet tokens: 0 `--line-bright`, 1 `--t-red`, 2 `--success-dim`,
    /// 3 `--t-yellow`, 4 `--t-blue`, 5 `--t-purple`, 6 `--t-cyan`, 7 `--bone`, 8 `--dimmer`,
    /// 9 `--danger`, 10 `--success`, 11 `--amber`, 12 a lighter `--t-blue` (no token),
    /// 13 `--t-pink`, 14 `--cyan`, 15 `--cream`. The selection background is a dark amber
    /// (no token) so cream selected text keeps its contrast.
    public static let phosphorConsole = TerminalColorTheme(
        background: "#000000",
        foreground: "#e8e6d8",
        cursor: "#ffb84a",
        cursorText: "#000000",
        selectionBackground: "#5a4420",
        selectionForeground: "#f5ecd6",
        palette: [
            "#2a2a2a", "#ef5b5b", "#52c472", "#e6c84e", "#5b8def", "#b07cff", "#4ed1e6", "#d4cdb8",
            "#7a7468", "#ff7058", "#7cff9a", "#ffb84a", "#8aa9f5", "#ff7cb5", "#6ee0f0", "#f5ecd6",
        ]
    )

    /// Whether `value` is `#rrggbb`.
    public static func isValidHex(_ value: String) -> Bool {
        let utf8 = Array(value.utf8)
        guard utf8.count == 7, utf8[0] == UInt8(ascii: "#") else { return false }
        return utf8.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A") ... UInt8(ascii: "F")).contains(byte)
        }
    }
}
