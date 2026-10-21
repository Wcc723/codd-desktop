/// Activity implied by Claude Code's terminal title glyph (undocumented; claude-local.md [bin]).
public enum TitleActivity: String, Sendable, Equatable {
    /// `◐` / `◑` spinner prefix (alternates about every 960 ms while working).
    case busy
    /// `✳` prefix.
    case idle
}

/// An OSC 0/2 title split into glyph-derived activity and the session title text.
public struct TerminalTitle: Sendable, Equatable {
    /// `nil` when the title has no recognised glyph (e.g. a shell prompt's title).
    public var activity: TitleActivity?
    /// The title without the glyph and its separating whitespace.
    public var text: String

    public init(activity: TitleActivity?, text: String) {
        self.activity = activity
        self.text = text
    }

    /// Parses `"<glyph> <title>"`. Recognised glyphs: U+25D0 `◐` and U+25D1 `◑` (busy), U+2733 `✳`
    /// (idle), each optionally followed by U+FE0F. Leading/trailing whitespace is ignored.
    public static func parse(_ raw: String) -> TerminalTitle {
        var scalars = Substring(raw).unicodeScalars.drop(while: { JSText.isWhitespace($0) })
        let activity: TitleActivity?
        switch scalars.first?.value {
        case 0x25D0?, 0x25D1?: activity = .busy
        case 0x2733?: activity = .idle
        default: activity = nil
        }
        if activity != nil {
            scalars = scalars.dropFirst()
            if scalars.first?.value == 0xFE0F { scalars = scalars.dropFirst() }
        }
        return TerminalTitle(activity: activity, text: JSText.trim(String(String.UnicodeScalarView(scalars))))
    }
}

/// Feeds raw titles (holder `TITLE` frames) and reports only meaningful changes, so the spinner's
/// `◐`/`◑` flips never reach the UI.
public struct TerminalTitleTracker: Sendable {
    public private(set) var current: TerminalTitle?

    public init() {}

    /// Returns the new parsed title when activity or text changed, else `nil`.
    public mutating func ingest(_ raw: String) -> TerminalTitle? {
        let parsed = TerminalTitle.parse(raw)
        guard parsed != current else { return nil }
        current = parsed
        return parsed
    }
}
