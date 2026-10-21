import AppKit
import CoddUI

/// A design length (a CSS px of the ImageAnnotate board) at the current interface zoom: the
/// screen's bars and panel are laid out by hand, so they follow the zoom like their fonts (the
/// canvas keeps image coordinates). Exact at UI 字級 13 (`UIZoom.pt`).
func az(_ value: CGFloat) -> CGFloat { UIZoom.pt(value) }

/// The board's own tokens (ImageAnnotate artboard `.ia-*` rules) on top of CoddUI's palette.
@MainActor
enum AnnotateTheme {
    /// `.ia-stage` background and its 16 px grid lines (`rgba(245,236,214,.035)`).
    static let stageBackground = NSColor(hex: 0x060606)
    static let gridLine = NSColor(hex: 0xF5ECD6, alpha: 0.035)
    static let gridStep: CGFloat = 16

    static var topBarHeight: CGFloat { az(52) }
    static var toolStripWidth: CGFloat { az(48) }
    static var panelWidth: CGFloat { az(380) }
    /// Fit leaves this much room around the frame on every side (brief: 40 pt margins).
    static var fitMargin: CGFloat { az(40) }
    /// `.ia-frame{padding:8px;border:1px}`.
    static var framePadding: CGFloat { az(8) }
    static var frameInset: CGFloat { az(9) }
    /// `.ia-stage{gap:12px}` between the frame and the caption.
    static var captionGap: CGFloat { az(12) }
    /// `.ia-o.tl{right:calc(100% + 16px)}`.
    static var originLabelGap: CGFloat { az(16) }

    static func color(_ color: AnnotationColor) -> NSColor {
        switch color {
        case .amber: Palette.amber
        case .cyan: Palette.cyan
        case .danger: Palette.danger
        case .success: Palette.success
        case .cream: Palette.cream
        }
    }

    // MARK: Text styles

    /// `.ia-crumb`: 10.5 caps .16em dim; `.cj` 12 bone .02em as written.
    static var crumb: TextStyle { TextStyle.caps(10.5, Palette.dim, tracking: 0.16) }
    static var crumbNote: TextStyle { TextStyle.mono(12, Palette.bone, tracking: 0.02) }
    static var crumbSlash: TextStyle { TextStyle.mono(10.5, Palette.dimmer) }
    /// `.sh .ttl`: Space Mono 15 amber with its 10 px glow.
    static var title: TextStyle {
        TextStyle(font: Typeface.display(15), color: Palette.amber, shadow: Draw.glow(Palette.amberGlow, radius: 10))
    }
    /// `.sh .meta`: 10.5 dim, separators dimmer.
    static var meta: TextStyle { TextStyle.mono(10.5, Palette.dim) }
    static var metaSeparator: TextStyle { TextStyle.mono(10.5, Palette.dimmer) }
    /// `.ia-shint` / `.ia-cap`: 11 dim.
    static var stageHint: TextStyle { TextStyle.mono(11, Palette.dim) }
    static var faint: TextStyle { TextStyle.mono(11, Palette.dimmer) }
    /// `.ia-o`: 10.5 dimmer.
    static var originLabel: TextStyle { TextStyle.mono(10.5, Palette.dimmer) }
    /// `.sec` with `font-weight:500`.
    static var section: TextStyle { TextStyle.caps(10.5, Palette.dim, tracking: 0.18, .medium) }
    /// `.ia-cnt`: amber, no letter spacing.
    static var sectionCount: TextStyle { TextStyle.mono(10.5, Palette.amber, .medium) }
    /// `.hint` at 11 px (`font-size:11px` everywhere on this board).
    static var hint: TextStyle { TextStyle.mono(11, Palette.dimmer, tracking: 0.02) }
    /// `.ia-f .lbl`: 10 caps .16em dim.
    static var fieldLabel: TextStyle { TextStyle.caps(10, Palette.dim, tracking: 0.16) }
    /// `.ann-item` body text: 12 bone.
    static var itemNote: TextStyle { TextStyle.mono(12, Palette.bone) }
    /// `.ann-item .xy`: 10.5 dimmer.
    static var itemXY: TextStyle { TextStyle.mono(10.5, Palette.dimmer) }
    /// `.ia-exh .tn`: 11.5 bone.
    static var typeName: TextStyle { TextStyle.mono(11.5, Palette.bone) }
    /// `.ann-item .no` / `.ann-pin`: 10.5 bold black.
    static var number: TextStyle { TextStyle.mono(10.5, .black, .bold) }
    /// `.ia-tip`: 11 cream, `.u` dim.
    static var tooltip: TextStyle { TextStyle.mono(11, Palette.cream) }
    static var tooltipUnit: TextStyle { TextStyle.mono(11, Palette.dim) }
    /// `.ia-ck`: 12 bone (dim when off), hint 11 dimmer.
    static var check: TextStyle { TextStyle.mono(12, Palette.bone) }
    /// `.ia-md`: 11 dim.
    static var disclosure: TextStyle { TextStyle.mono(11, Palette.dim) }
    static var disclosureFaint: TextStyle { TextStyle.mono(11, Palette.dimmer) }

    /// `.chip.caps.ia-ty`: 16 px tall, 9.5 px caps .1em, `padding: 0 5px`.
    static func typeChip(amber: Bool) -> ChipStyle {
        let color = amber ? Palette.amber : Palette.bone
        let border = amber ? Palette.amberDim : Palette.lineBright
        return ChipStyle(text: TextStyle(font: Typeface.mono(9.5), color: color, tracking: 0.1, uppercase: true),
                         border: border, fill: nil, height: 16, padding: 6)
    }

    /// `.kbd` inside hint lines.
    static var kbd: ChipStyle { KbdView.style(.regular) }
}

/// Anything on this board that draws text a user reads; tests collect `displayedText`.
@MainActor
protocol AnnotateTextShowing: AnyObject {
    var displayedText: String { get }
}

extension NSView {
    /// Every displayed text in this subtree, depth first (tests and accessibility checks).
    @MainActor
    var annotateTexts: [String] {
        var texts: [String] = []
        if let showing = self as? AnnotateTextShowing {
            let text = showing.displayedText
            if !text.isEmpty { texts.append(text) }
        }
        if let field = self as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
        if let text = self as? NSTextView, !text.string.isEmpty { texts.append(text.string) }
        if let button = self as? CoddButton { texts.append(button.label) }
        for subview in subviews where !subview.isHidden { texts.append(contentsOf: subview.annotateTexts) }
        return texts
    }
}
