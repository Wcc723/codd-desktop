import AppKit

extension NSAttributedString.Key {
    /// Temporary attribute: draw these glyphs slanted (comments; no italic face is bundled).
    static let coddOblique = NSAttributedString.Key("CoddCodeEditorOblique")
}

/// What layout needs to know about lines and block decorations, shared by the editor (which keeps
/// it current), the layout manager's delegate and the layout manager. Main thread only.
final class EditorGeometry {
    var lines = LineIndex()
    var lineHeight: CGFloat = 20
    /// Baseline below a text row's top (CSS line box: half-leading + ascender).
    var baseline: CGFloat = 14.5
    /// The font's content area within a row (the find hits' boxes): top offset and height.
    var contentTop: CGFloat = 1.75
    var contentHeight: CGFloat = 16.5
    /// Block decoration heights above an anchor line that has its own line fragment.
    var above: [Int: CGFloat] = [:]
    /// Block decoration height after the last line fragment (anchors without a fragment of their
    /// own: past the end, or the empty line after a final newline).
    var trailing: CGFloat = 0
    /// The text view's `textContainerOrigin` (its insets), for layout-manager-side geometry.
    var textOrigin = NSPoint.zero

    /// The decoration space a line fragment carries above / below its text row.
    func insets(fragmentStart charIndex: Int, glyphRange: NSRange, numberOfGlyphs: Int) -> (top: CGFloat, bottom: CGFloat) {
        var top: CGFloat = 0
        if !above.isEmpty {
            let line = lines.line(containing: charIndex)
            if lines.start(of: line) == charIndex, let height = above[line] { top = height }
        }
        let bottom: CGFloat = trailing > 0 && NSMaxRange(glyphRange) >= numberOfGlyphs ? trailing : 0
        return (top, bottom)
    }
}

/// Every line fragment gets the artboard's fixed row height and a CSS-centered baseline; a
/// fragment that starts a decorated line also reserves the decoration's height above its text (the
/// block decorations of D11 / D27: hunk bar and removed lines).
final class FragmentDelegate: NSObject, NSLayoutManagerDelegate {
    let geometry: EditorGeometry

    init(geometry: EditorGeometry) {
        self.geometry = geometry
    }

    /// Layout finished a pass (the editor repositions its overlays and redraws the gutter later).
    var onLayoutComplete: (@MainActor () -> Void)?

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        guard let onLayoutComplete else { return }
        MainActor.assumeIsolated { onLayoutComplete() }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        let insets = geometry.insets(fragmentStart: charIndex, glyphRange: glyphRange, numberOfGlyphs: layoutManager.numberOfGlyphs)
        let height = geometry.lineHeight + insets.top + insets.bottom
        lineFragmentRect.pointee.size.height = height
        lineFragmentUsedRect.pointee.size.height = height
        baselineOffset.pointee = insets.top + geometry.baseline
        return true
    }
}

/// The code view's layout manager: slants glyphs marked `coddOblique` and keeps selection
/// backgrounds inside text rows (a fragment's decoration space is not text).
final class CodeLayoutManager: NSLayoutManager {
    var geometry: EditorGeometry?
    var obliqueness: CGFloat = 0.2
    private var drawingOblique = false

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard obliqueness != 0 else {
            super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
            return
        }
        var glyph = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        while glyph < end {
            let character = characterIndexForGlyph(at: glyph)
            var effective = NSRange()
            let oblique = temporaryAttribute(.coddOblique, atCharacterIndex: character, effectiveRange: &effective) != nil
            var run = glyphRange(forCharacterRange: effective, actualCharacterRange: nil)
            run = NSIntersectionRange(run, NSRange(location: glyph, length: end - glyph))
            if run.length == 0 || run.location != glyph { run = NSRange(location: glyph, length: max(1, min(run.length, end - glyph))) }
            drawingOblique = oblique
            super.drawGlyphs(forGlyphRange: run, at: origin)
            glyph = NSMaxRange(run)
        }
        drawingOblique = false
    }

    override func showCGGlyphs(_ glyphs: UnsafePointer<CGGlyph>, positions: UnsafePointer<CGPoint>, count glyphCount: Int,
                               font: NSFont, textMatrix: CGAffineTransform, attributes: [NSAttributedString.Key: Any] = [:],
                               in context: CGContext) {
        guard drawingOblique, glyphCount > 0 else {
            super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font, textMatrix: textMatrix,
                               attributes: attributes, in: context)
            return
        }
        // Slant around the baseline in the flipped view (glyph tops lean right).
        let baseline = positions[0].y
        context.saveGState()
        context.concatenate(CGAffineTransform(a: 1, b: 0, c: -obliqueness, d: 1, tx: obliqueness * baseline, ty: 0))
        super.showCGGlyphs(glyphs, positions: positions, count: glyphCount, font: font, textMatrix: textMatrix,
                           attributes: attributes, in: context)
        context.restoreGState()
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let geometry, !geometry.above.isEmpty || geometry.trailing > 0, let container = textContainers.first else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // The text rows of the fragments the range spans, in the same coordinates as the rects.
        var rows: [NSRect] = []
        let glyphs = glyphRange(forCharacterRange: charRange, actualCharacterRange: nil)
        let origin = geometry.textOrigin
        let total = numberOfGlyphs
        enumerateLineFragments(forGlyphRange: NSRange(location: glyphs.location, length: max(1, glyphs.length))) { rect, _, fragmentContainer, fragmentGlyphs, _ in
            guard fragmentContainer === container else { return }
            let insets = geometry.insets(fragmentStart: self.characterIndexForGlyph(at: fragmentGlyphs.location),
                                         glyphRange: fragmentGlyphs, numberOfGlyphs: total)
            rows.append(NSRect(x: rect.minX + origin.x, y: rect.minY + insets.top + origin.y, width: rect.width,
                               height: rect.height - insets.top - insets.bottom))
        }
        var clipped: [NSRect] = []
        for k in 0 ..< rectCount {
            let rect = rectArray[k]
            for row in rows {
                let piece = NSRect(x: rect.minX, y: max(rect.minY, row.minY), width: rect.width,
                                   height: min(rect.maxY, row.maxY) - max(rect.minY, row.minY))
                if piece.height > 0.5 { clipped.append(piece) }
            }
        }
        if rows.isEmpty { clipped = (0 ..< rectCount).map { rectArray[$0] } }
        guard !clipped.isEmpty else { return }
        clipped.withUnsafeBufferPointer { buffer in
            super.fillBackgroundRectArray(buffer.baseAddress!, count: buffer.count, forCharacterRange: charRange, color: color)
        }
    }
}
