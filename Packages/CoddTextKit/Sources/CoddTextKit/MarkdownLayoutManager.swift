import AppKit

/// The TextKit 1 layout manager of the editor. It only adds one drawing pass before AppKit's own:
/// code block plates and the inline code / note chip boxes under the selection and the glyphs.
/// (Decorations that reach into the padding or sit over the text are drawn by the text view:
/// this pass is clipped to the text container.) Hidden glyphs and line heights come from the
/// editor as the layout manager's delegate.
final class MarkdownLayoutManager: NSLayoutManager {
    /// Set once by the editor that owns this stack (main actor only).
    nonisolated(unsafe) weak var editor: MarkdownEditorView?

    // AppKit lays out and draws this stack on the main thread only (the text view's), so the
    // drawing passes may enter the main actor synchronously.

    override nonisolated func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        nonisolated(unsafe) let manager = self
        MainActor.assumeIsolated {
            manager.editor?.drawDecorations(.background, glyphRange: glyphsToShow, origin: origin, layoutManager: manager)
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

}

enum DecorationPhase {
    /// Text view, before AppKit's text: the caret band (full width).
    case underlay
    /// Layout manager, under the selection and glyphs: code plates, inline code and chip boxes.
    case background
    /// Text view, after the text: rules, bullets, fold glyphs, code labels, figures.
    case foreground
}
