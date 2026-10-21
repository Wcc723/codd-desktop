import AppKit

/// The caret for the status bar's `Ln 42, Col 18`: 1-based line and column, the column and
/// `selectionLength` in UTF-16 units (tabs count as one; CJK characters are one unit each).
public struct CodeCaret: Sendable, Equatable {
    public var line: Int
    public var column: Int
    public var selectionLength: Int

    public init(line: Int, column: Int, selectionLength: Int) {
        self.line = line
        self.column = column
        self.selectionLength = selectionLength
    }
}

/// The hunk bar (`.fe-hunk`): `■ AI 打卡頁 RWD 調整 · 10:36  @@ -40,2 +40,4 @@  −2 +4 … 2 / 2 [還原此段] [接受]`.
public struct InlineDiffHeader: Sendable, Equatable {
    /// The session's tag color: the square, the AI chip, the bar's tint and the hunk's 2 pt bars.
    public var tagColor: NSColor
    public var showAIChip: Bool
    /// `打卡頁 RWD 調整 · 10:36`
    public var who: String
    /// `@@ -40,2 +40,4 @@`
    public var range: String
    public var removed: Int
    public var added: Int
    /// `2 / 2`
    public var position: String

    public init(tagColor: NSColor, showAIChip: Bool, who: String, range: String, removed: Int, added: Int, position: String) {
        self.tagColor = tagColor
        self.showAIChip = showAIChip
        self.who = who
        self.range = range
        self.removed = removed
        self.added = added
        self.position = position
    }
}

/// One inline unified hunk (D27). `newLines` are 0-based lines of the current text (the added
/// lines, tinted); an empty range is a pure deletion shown before line `lowerBound` (at the end of
/// the text when `lowerBound` is the line count). `deletedLines` are drawn under the hunk bar as
/// removed lines (they are not part of the text).
public struct InlineDiffHunk: Sendable, Equatable, Identifiable {
    public var id: Int
    public var newLines: Range<Int>
    public var deletedLines: [String]
    public var header: InlineDiffHeader

    public init(id: Int, newLines: Range<Int>, deletedLines: [String], header: InlineDiffHeader) {
        self.id = id
        self.newLines = newLines
        self.deletedLines = deletedLines
        self.header = header
    }
}

/// The hunk bar's buttons: `還原此段` (the owner replaces the lines, `replaceLines`) and `接受`.
public enum HunkAction: Sendable {
    case revert, accept
}

/// A mark in the overview ruler (`.fe-ruler`). `line` is 0-based, `lineCount` ≥ 1 sets an added
/// block's height; `color` overrides the kind's (an AI change takes the session's tag color).
/// The view draws find hits and the caret itself; the owner passes AI changes, added and removed.
public struct OverviewMark: Sendable, Equatable {
    public enum Kind: Sendable {
        case hit, aiChange, added, removed, cursor
    }

    public var kind: Kind
    public var line: Int
    public var lineCount: Int
    public var color: NSColor?

    public init(kind: Kind, line: Int, lineCount: Int = 1, color: NSColor? = nil) {
        self.kind = kind
        self.line = line
        self.lineCount = lineCount
        self.color = color
    }
}
