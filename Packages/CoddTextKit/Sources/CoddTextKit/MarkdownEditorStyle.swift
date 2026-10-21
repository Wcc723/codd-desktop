import AppKit
import CoddUI

/// Fonts, colors and metrics of the Markdown editor. `.notebook` is the Notebook artboard's
/// document column (`.nb-doc`, `.nb-title`, `.nb-h2`, `.nb-p`, `.nb-ul`, `.nb-tasks`, `.nb-code`,
/// `.nb-figrow`, `.nb-raw`) in CODD's own fonts; the app may pass a variant (a read-only card uses
/// smaller fonts through `MarkdownRender`). Line heights are multiples of their font size (CSS
/// `line-height`).
public struct MarkdownEditorStyle {
    // MARK: Fonts
    public var titleFont: NSFont
    public var heading2Font: NSFont
    public var heading3Font: NSFont
    /// H4–H6.
    public var minorHeadingFont: NSFont
    public var bodyFont: NSFont
    public var boldFont: NSFont
    public var codeFont: NSFont
    public var inlineCodeFont: NSFont
    public var captionFont: NSFont
    public var codeLabelFont: NSFont
    public var pinFont: NSFont
    public var overlayTextFont: NSFont
    public var foldGlyphFont: NSFont
    /// Source mode: every line in this font.
    public var sourceFont: NSFont

    // MARK: Line heights (× font size)
    public var titleLineHeight: CGFloat = 1.3
    public var heading2LineHeight: CGFloat = 1.4
    public var headingLineHeight: CGFloat = 1.4
    public var bodyLineHeight: CGFloat = 1.75
    public var taskLineHeight: CGFloat = 1.8
    public var codeLineHeight: CGFloat = 1.6
    public var sourceLineHeight: CGFloat = 1.6
    public var captionLineHeight: CGFloat = 1.5

    // MARK: Letter spacing (em)
    /// `.codd{letter-spacing:.01em}`: every run that sets no tracking of its own.
    public var bodyTracking: CGFloat = 0.01
    public var titleTracking: CGFloat = 0.01
    public var heading2Tracking: CGFloat = 0.04
    /// Synthesized italic for the monospaced face (JetBrains Mono ships upright only here).
    public var italicObliqueness: CGFloat = 0.2

    // MARK: Colors
    public var background: NSColor = Palette.bgSoft
    public var text: NSColor = Palette.bone
    public var strong: NSColor = Palette.cream
    public var title: NSColor = Palette.cream
    public var heading: NSColor = Palette.amber
    public var minorHeading: NSColor = Palette.amberDim
    /// Syntax marks shown on the caret paragraph and in source mode (`--dimmer`).
    public var mark: NSColor = Palette.dimmer
    public var link: NSColor = Palette.cyan
    public var chipText: NSColor = Palette.amber
    public var chipFill: NSColor = NSColor(hex: 0xFFB84A, alpha: 0.08)
    public var chipBorder: NSColor = Palette.amberDim
    public var bullet: NSColor = Palette.amberDim
    public var taskBox: NSColor = Palette.dim
    public var taskCheck: NSColor = Palette.amber
    public var doneText: NSColor = Palette.dimmer
    public var doneStrike: NSColor = Palette.lineBright
    public var quoteBar: NSColor = Palette.amberDim
    public var rule: NSColor = Palette.lineBright
    public var headingRule: NSColor = Palette.lineBright
    public var codeBackground: NSColor = .black
    public var codeBorder: NSColor = Palette.lineBright
    public var codeText: NSColor = Palette.cream
    public var codeKeyword: NSColor = Palette.amber
    public var codeString: NSColor = Palette.cyan
    public var codeComment: NSColor = Palette.dimmer
    public var codePunctuation: NSColor = Palette.dim
    public var codeLabel: NSColor = Palette.dim
    public var codeLabelBorder: NSColor = Palette.line
    public var inlineCodeText: NSColor = Palette.amber
    public var inlineCodeBackground: NSColor = Palette.bg
    public var inlineCodeBorder: NSColor = Palette.line
    public var tablePipe: NSColor = Palette.dim
    public var caret: NSColor = Palette.amber
    public var caretGlow: NSColor = Palette.amberGlow
    /// The `.nb-raw` band behind the caret paragraph: gradient start / end (at 70 %) and the inset bar.
    public var caretLineStart: NSColor = NSColor(hex: 0xFFB84A, alpha: 0.08)
    public var caretLineEnd: NSColor = NSColor(hex: 0xFFB84A, alpha: 0.015)
    public var caretLineBar: NSColor = Palette.amberDim
    public var figurePlate: NSColor = .black
    public var figureBorder: NSColor = Palette.amberDim
    public var figureRing: NSColor = NSColor(hex: 0xFFB84A, alpha: 0.08)
    public var figureLoading: NSColor = Palette.bgLift
    public var figureSelection: NSColor = Palette.amber
    public var caption: NSColor = Palette.dim
    public var foldGlyph: NSColor = Palette.dimmer
    public var placeholder: NSColor = Palette.dimmer
    public var selectionBackground: NSColor = Palette.amber
    public var selectionText: NSColor = .black
    public var markedText: NSColor = Palette.amber
    /// Overlay item colors by name (§3.3 `color`); `amber` is the default.
    public var overlayColors: [String: NSColor] = [
        "amber": Palette.amber, "cyan": Palette.cyan, "danger": Palette.danger,
        "success": Palette.success, "cream": Palette.cream,
    ]
    public var overlayBoxFillAlpha: CGFloat = 0.10

    // MARK: Metrics (points)
    /// `.nb-doc{padding:22px 40px 0 44px}` plus room to scroll the last line up.
    public var padding = NSEdgeInsets(top: 22, left: 44, bottom: 28, right: 40)
    /// `.nb-doc{gap:10px}` between blocks; also the height of a blank line off the caret.
    public var blockGap: CGFloat = 10
    public var heading2Margin: CGFloat = 8
    public var heading2RulePadding: CGFloat = 12
    public var minorHeadingMargin: CGFloat = 4
    /// The `▾` fold glyph sits this far left of the H2 text (`.fold{left:-24px}`).
    public var foldGlyphOffset: CGFloat = 24
    /// `.nb-ul li{padding-left:18px}`, also per nesting level.
    public var listIndent: CGFloat = 18
    public var bulletSize: CGFloat = 5
    public var bulletInset: CGFloat = 4
    /// `.nb-box{width:30px}` + the 6 px gap.
    public var taskBoxWidth: CGFloat = 36
    public var quoteIndent: CGFloat = 14
    public var quoteBarWidth: CGFloat = 2
    /// `.nb-code pre{padding:10px 14px}` inside a 1 px border.
    public var codePadding = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
    public var codeLabelPadding = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
    /// Tall screenshots are shown at most this high (`.nb-ph` 124 × 220).
    public var figureMaxHeight: CGFloat = 220
    public var figurePadding: CGFloat = 7
    public var figureRingWidth: CGFloat = 3
    public var figureCaptionGap: CGFloat = 6
    /// `.nb-figrow{padding:2px 0}`.
    public var figureRowPadding: CGFloat = 2
    /// Between the raw image line (on the caret) and its figure.
    public var figureRevealGap: CGFloat = 4
    /// `.nb-figrow{gap:18px}` between the figure and the accessory.
    public var accessoryGap: CGFloat = 18
    /// The narrowest accessory a figure leaves room for.
    public var accessoryMinWidth: CGFloat = 220
    /// Pixel size the image is shown at, at most (2 = a @2x screenshot at its point size).
    public var figurePixelsPerPoint: CGFloat = 2
    public var titleAccessoryGap: CGFloat = 10
    /// `code{padding:0 5px; border:1px}`: the box edge 6 pt from the text.
    public var inlineCodePadding: CGFloat = 6
    public var inlineCodeHeight: CGFloat = 17
    public var chipPadding: CGFloat = 5
    public var chipHeight: CGFloat = 19
    public var caretWidth: CGFloat = 2
    public var caretGlowRadius: CGFloat = 6
    public var pinSize: CGFloat = 18
    public var arrowHeadLength: CGFloat = 8
    public var arrowHeadHalfWidth: CGFloat = 4.5

    public init(titleFont: NSFont, heading2Font: NSFont, heading3Font: NSFont, minorHeadingFont: NSFont,
                bodyFont: NSFont, boldFont: NSFont, codeFont: NSFont, inlineCodeFont: NSFont, captionFont: NSFont,
                codeLabelFont: NSFont, pinFont: NSFont, overlayTextFont: NSFont, foldGlyphFont: NSFont, sourceFont: NSFont) {
        self.titleFont = titleFont
        self.heading2Font = heading2Font
        self.heading3Font = heading3Font
        self.minorHeadingFont = minorHeadingFont
        self.bodyFont = bodyFont
        self.boldFont = boldFont
        self.codeFont = codeFont
        self.inlineCodeFont = inlineCodeFont
        self.captionFont = captionFont
        self.codeLabelFont = codeLabelFont
        self.pinFont = pinFont
        self.overlayTextFont = overlayTextFont
        self.foldGlyphFont = foldGlyphFont
        self.sourceFont = sourceFont
    }

    /// The Notebook artboard: Space Mono 22 / 16 for title and H2, JetBrains Mono 13 / 1.75 body
    /// (PingFang TC for CJK through CoddUI's cascade), 12 / 1.6 code, 11 captions.
    @MainActor public static var notebook: MarkdownEditorStyle {
        MarkdownEditorStyle(
            titleFont: Typeface.display(22),
            heading2Font: Typeface.display(16),
            heading3Font: Typeface.display(14),
            minorHeadingFont: Typeface.display(13),
            bodyFont: Typeface.mono(13),
            boldFont: Typeface.mono(13, .bold),
            codeFont: Typeface.mono(12),
            inlineCodeFont: Typeface.mono(12),
            captionFont: Typeface.mono(11),
            codeLabelFont: Typeface.mono(10),
            pinFont: Typeface.mono(10.5, .bold),
            overlayTextFont: Typeface.mono(10.5, .medium),
            foldGlyphFont: Typeface.mono(10.5),
            sourceFont: Typeface.mono(12.5)
        )
    }

    /// Every font size and metric multiplied by `scale` (⌘+ / ⌘−); colors unchanged.
    public func scaled(by scale: CGFloat) -> MarkdownEditorStyle {
        guard scale > 0, scale != 1 else { return self }
        func f(_ font: NSFont) -> NSFont { NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font }
        func e(_ insets: NSEdgeInsets) -> NSEdgeInsets {
            NSEdgeInsets(top: insets.top * scale, left: insets.left * scale, bottom: insets.bottom * scale, right: insets.right * scale)
        }
        var copy = self
        copy.titleFont = f(titleFont)
        copy.heading2Font = f(heading2Font)
        copy.heading3Font = f(heading3Font)
        copy.minorHeadingFont = f(minorHeadingFont)
        copy.bodyFont = f(bodyFont)
        copy.boldFont = f(boldFont)
        copy.codeFont = f(codeFont)
        copy.inlineCodeFont = f(inlineCodeFont)
        copy.captionFont = f(captionFont)
        copy.codeLabelFont = f(codeLabelFont)
        copy.pinFont = f(pinFont)
        copy.overlayTextFont = f(overlayTextFont)
        copy.foldGlyphFont = f(foldGlyphFont)
        copy.sourceFont = f(sourceFont)
        copy.padding = e(padding)
        copy.codePadding = e(codePadding)
        copy.codeLabelPadding = e(codeLabelPadding)
        for path in [\MarkdownEditorStyle.blockGap, \.heading2Margin, \.heading2RulePadding, \.minorHeadingMargin,
                     \.foldGlyphOffset, \.listIndent, \.bulletSize, \.bulletInset, \.taskBoxWidth, \.quoteIndent,
                     \.figureMaxHeight, \.figurePadding, \.figureCaptionGap, \.figureRowPadding, \.figureRevealGap,
                     \.accessoryGap, \.accessoryMinWidth, \.titleAccessoryGap, \.inlineCodePadding, \.inlineCodeHeight,
                     \.chipPadding, \.chipHeight, \.pinSize, \.arrowHeadLength, \.arrowHeadHalfWidth] {
            copy[keyPath: path] = self[keyPath: path] * scale
        }
        return copy
    }

    func overlayColor(_ name: String?) -> NSColor {
        overlayColors[name ?? "amber"] ?? overlayColors["amber"] ?? Palette.amber
    }
}
