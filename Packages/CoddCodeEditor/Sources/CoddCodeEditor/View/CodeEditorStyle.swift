import AppKit
import CoddUI

/// The code view's tokens, from the FileEditor artboard (`.fe-code`, `.fe-lines`, `.fe-l`, the token
/// classes, `.fe-hit`, `.fe-caret`, `.fe-hunk`, `.fe-ruler`, `.fe-find`) and design/helmet.html.
public struct CodeEditorStyle {
    // Code (`.fe-code{background:#000}`, `.fe-lines{font-size:12.5px;line-height:20px;color:#e8e6d8;padding-top:4px}`)
    public var background: NSColor = .black
    public var text = NSColor(hex: 0xE8E6D8)
    public var fontSize: CGFloat = 12.5
    public var lineHeight: CGFloat = 20
    public var topInset: CGFloat = 4
    /// `.fe-l .c{padding-left:4px}`
    public var textLeftInset: CGFloat = 4
    public var tabWidth = 4

    // Gutter (`.fe-l .n{width:46px;padding-right:4px}`, `.fe-l .m{width:16px}`)
    public var numberColumnWidth: CGFloat = 46
    public var numberRightPadding: CGFloat = 4
    public var markerColumnWidth: CGFloat = 16
    public var lineNumber = Palette.dimmer
    public var currentLineNumber = Palette.cream
    /// `.fe-l.add .n{color:#8fd6a0}`
    public var addedLineNumber = NSColor(hex: 0x8FD6A0)
    public var addedMarker = Palette.success
    public var removedMarker = Palette.danger
    /// `.fe-l.mod .m::before{width:3px}`
    public var modifiedBarWidth: CGFloat = 3

    // Lines
    public var addedBackground = NSColor(hex: 0x7CFF9A, alpha: 0.075)
    public var removedBackground = NSColor(hex: 0xFF7058, alpha: 0.085)
    public var removedTextOpacity: CGFloat = 0.72
    /// `inset 2px 0 0 <hunk color>` on added and removed rows.
    public var hunkBarInset: CGFloat = 2
    /// `.fe-l.curl`: `rgba(245,236,214,.05)` over the row, `#262626` top and bottom hairlines.
    public var currentLineBand = NSColor(hex: 0xF5ECD6, alpha: 0.05)
    public var currentLineBorder = NSColor(hex: 0x262626)

    // Caret (`.fe-caret{width:2px;height:16px;vertical-align:-3px;box-shadow:0 0 6px amber-glow}`)
    public var caret = Palette.amber
    public var caretGlow = Palette.amberGlow
    public var caretWidth: CGFloat = 2
    public var caretHeight: CGFloat = 16
    /// How far the caret's bottom sits below the baseline.
    public var caretDrop: CGFloat = 3
    public var selectionBackground = Palette.amber
    public var selectionText = NSColor.black
    public var markedTextUnderline = Palette.amber

    // Tokens
    public var keyword = Palette.amber
    public var string = Palette.cyan
    public var comment = Palette.dimmer
    public var number = NSColor(hex: 0xA6E9F2)
    public var punctuation = NSColor(hex: 0x8A8578)
    public var tag = NSColor(hex: 0xE0896A)
    public var attribute = Palette.bone
    public var directive = Palette.amberDim
    public var function = Palette.cream
    public var property = Palette.bone
    /// Comments are italic in the artboard; JetBrains Mono Italic is not bundled, so the glyphs are slanted.
    public var commentObliqueness: CGFloat = 0.2

    // Find hits (`.fe-hit`, `.fe-hit.cur`)
    public var hitFill = NSColor(hex: 0xFFB84A, alpha: 0.16)
    public var hitStroke = NSColor(hex: 0xFFB84A, alpha: 0.5)
    public var currentHitFill = Palette.amber
    public var currentHitText = NSColor.black
    public var currentHitGlow = Palette.amberGlow

    // Hunk bar (`.fe-hunk{height:26px;padding:0 12px 0 66px;gap:8px;font-size:10.5px}`; the 66 pt is
    // the gutter plus the text inset, so the bar's content follows a wider gutter)
    public var hunkBarHeight: CGFloat = 26
    public var hunkBarRightPadding: CGFloat = 12
    public var hunkBarGap: CGFloat = 8
    public var hunkBarText = Palette.dim
    public var hunkWho = Palette.bone
    public var hunkFaint = Palette.dimmer

    // Overview ruler (`.fe-ruler{width:14px;background:#030303;border-left:1px solid var(--line)}`)
    public var rulerWidth: CGFloat = 14
    public var rulerBackground = NSColor(hex: 0x030303)
    public var rulerBorder = Palette.line
    public var rulerThumb = NSColor(hex: 0xF5ECD6, alpha: 0.07)
    public var rulerHit = Palette.amber
    public var rulerAdded = Palette.success
    public var rulerRemoved = Palette.danger
    public var rulerAIChange = NSColor(hex: 0xFF7CB5)
    public var rulerCursor = Palette.cream.withAlphaComponent(0.75)

    // Find widget (`.fe-find{top:0;right:26px;padding:5px 6px;background:var(--bg-lift);border:1px solid var(--amber-dim)}`)
    public var findRightInset: CGFloat = 26
    public var findBackground = Palette.bgLift
    public var findBorder = Palette.amberDim
    public var findFieldWidth: CGFloat = 232
    public var findFieldHeight: CGFloat = 24

    public init() {}

    /// The FileEditor artboard's code view.
    public static var fileEditor: CodeEditorStyle { CodeEditorStyle() }

    public func color(for token: SyntaxToken) -> NSColor {
        switch token {
        case .keyword: keyword
        case .string: string
        case .comment: comment
        case .number: number
        case .punctuation: punctuation
        case .tag: tag
        case .attribute: attribute
        case .directive: directive
        case .function: function
        case .property: property
        case .plain: text
        }
    }

    /// The gutter: line numbers + the marker column (`46 + 16`), wider for six-digit line numbers.
    func gutterWidth(lineCount: Int, digitWidth: CGFloat) -> CGFloat {
        let digits = max(3, String(lineCount).count)
        let numbers = max(numberColumnWidth, ceil(CGFloat(digits) * digitWidth) + numberRightPadding + 6)
        return numbers + markerColumnWidth
    }
}
