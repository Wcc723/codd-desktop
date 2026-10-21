import AppKit

extension NSAttributedString.Key {
    /// A `codd://note/<id>` (or `[圖已過期]`) range drawn as a chip; the value is its `ChipKind`.
    static let composerReferenceChip = NSAttributedString.Key("codd.composer.referenceChip")
    /// The character before a chip, whose kern makes room for the chip's left padding.
    static let composerReferenceChipPad = NSAttributedString.Key("codd.composer.referenceChipPad")
}

/// `codd://note/<id>` references drawn as the Split artboard's `.sp-ref` chip (M4 C4). Only
/// attributes change (amber text, kern for the padding); the text, and so the payload, never does.
/// Nothing is recomputed while an input method composes, and a chip touching the marked range is
/// not drawn. The document icon of the artboard chip is left out (there is no room for it without
/// changing the text when a reference starts the line).
///
/// Post-M4: `[圖已過期]` (`ComposerAttachments.expiredMarker`, what a recalled entry shows for an
/// image removed 24 h after its send) is drawn the same way as a muted chip. It is plain text too:
/// what the field shows is what is sent.
extension ComposerTextView {
    /// The `.composerReferenceChip` value: which chip a run is.
    enum ChipKind: String {
        case note
        case expiredImage
    }

    /// `codd://note/` + the id charset `[a-z0-9]+(-[a-z0-9]+)*`, ≤ 48 characters (M4 §3.6).
    nonisolated static let referencePattern: NSRegularExpression = {
        // A literal pattern: it always compiles.
        try! NSRegularExpression(pattern: "codd://note/[a-z0-9]+(?:-[a-z0-9]+)*")
    }()

    /// The reference ranges of `text` (UTF-16), ids cut at 48 characters.
    nonisolated static func referenceRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let prefix = ("codd://note/" as NSString).length
        return referencePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            NSRange(location: match.range.location, length: min(match.range.length, prefix + 48))
        }
    }

    /// The `[圖已過期]` ranges of `text` (UTF-16).
    nonisolated static func expiredImageRanges(in text: String) -> [NSRange] {
        guard text.contains(ComposerAttachments.expiredMarker) else { return [] }
        let ns = text as NSString
        var ranges: [NSRange] = []
        var from = 0
        while from < ns.length {
            let found = ns.range(of: ComposerAttachments.expiredMarker, options: .literal,
                                 range: NSRange(location: from, length: ns.length - from))
            guard found.location != NSNotFound else { break }
            ranges.append(found)
            from = NSMaxRange(found)
        }
        return ranges
    }

    /// Every chip range of `text` in order: note references and expired images (they never overlap:
    /// a note id has no `[`).
    nonisolated static func chipRanges(in text: String) -> [NSRange] {
        let expired = expiredImageRanges(in: text)
        let notes = referenceRanges(in: text)
        guard !expired.isEmpty else { return notes }
        return (notes + expired).sorted { $0.location < $1.location }
    }

    /// Recomputes the chips from the committed text (no-op while composing or with chips off).
    func refreshReferenceChips() {
        // Chips off and none drawn: the composer behaves exactly as before (D40).
        guard style.referenceChips || !referenceChipRanges.isEmpty else { return }
        guard let storage = textStorage, !hasMarkedText(), inputDepth == 0 else { return }
        let length = storage.length
        let wanted = style.referenceChips && length > 0 ? Self.chipRanges(in: string) : []
        let expired = Set(Self.expiredImageRanges(in: string).map(\.location))
        guard wanted != referenceChipRanges || chipAttributesNeedReset(storage) else { return }
        storage.beginEditing()
        // Undo the previous chips (the chip runs and the padded character before each).
        for key in [NSAttributedString.Key.composerReferenceChip, .composerReferenceChipPad] {
            storage.enumerateAttribute(key, in: NSRange(location: 0, length: length)) { value, range, _ in
                guard value != nil else { return }
                storage.setAttributes(style.textAttributes, range: range)
            }
        }
        for range in wanted where NSMaxRange(range) <= length {
            let kind: ChipKind = expired.contains(range.location) ? .expiredImage : .note
            let color = kind == .expiredImage ? style.expiredChipText : style.referenceChipText
            storage.addAttributes([.foregroundColor: color, .composerReferenceChip: kind.rawValue], range: range)
            storage.addAttribute(.kern, value: Self.chipPadding + 2, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
            if range.location > 0 {
                let before = NSRange(location: range.location - 1, length: 1)
                storage.addAttributes([.kern: Self.chipPadding + 2, .composerReferenceChipPad: true], range: before)
            }
        }
        storage.endEditing()
        referenceChipRanges = wanted
        needsDisplay = true
    }

    private func chipAttributesNeedReset(_ storage: NSTextStorage) -> Bool {
        // Edits may have split, moved or removed attributed chips: compare the runs with the ranges.
        var runs: [NSRange] = []
        storage.enumerateAttribute(.composerReferenceChip, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { runs.append(range) }
        }
        return runs != referenceChipRanges
    }

    /// `.chip{padding:0 7px}` inside the border; the kern adds the `margin:0 2px`.
    static let chipPadding: CGFloat = 7

    /// The chip runs to draw now: attributed chips, minus any the marked range touches.
    func drawableReferenceChipRanges() -> [NSRange] {
        guard style.referenceChips, let storage = textStorage, storage.length > 0 else { return [] }
        let marked = hasMarkedText() ? markedRange() : NSRange(location: NSNotFound, length: 0)
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.composerReferenceChip, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil else { return }
            if marked.location != NSNotFound,
               NSIntersectionRange(range, marked).length > 0 || NSLocationInRange(marked.location, range) || marked.location == NSMaxRange(range) {
                return
            }
            ranges.append(range)
        }
        return ranges
    }

    /// The chip boxes behind the text (called from `drawBackground(in:)`).
    func drawReferenceChips(in dirtyRect: NSRect) {
        guard style.referenceChips, let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let height = style.referenceChipHeight
        for range in drawableReferenceChipRanges() {
            let value = textStorage?.attribute(.composerReferenceChip, at: range.location, effectiveRange: nil) as? String
            let expired = value == ChipKind.expiredImage.rawValue
            let fill = expired ? style.expiredChipFill : style.referenceChipFill
            let stroke = expired ? style.expiredChipBorder : style.referenceChipBorder
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { rect, _ in
                // The last glyph's kern is inside its advance; the box ends where the padding starts.
                let width = max(0, rect.width - 2)
                let box = NSRect(x: origin.x + rect.minX - Self.chipPadding, y: (origin.y + rect.midY - height / 2).rounded(),
                                 width: width + Self.chipPadding, height: height)
                guard box.intersects(dirtyRect) else { return }
                fill.setFill()
                box.fill(using: .sourceOver)
                stroke.setStroke()
                let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1
                border.stroke()
            }
        }
    }
}
