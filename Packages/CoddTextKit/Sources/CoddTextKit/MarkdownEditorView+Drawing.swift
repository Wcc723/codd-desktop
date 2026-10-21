import AppKit
import CoddUI

extension MarkdownEditorView {
    /// One pass over the line fragments AppKit is drawing. Background: the caret band, code block
    /// plates, inline code and chip boxes (under the selection and the glyphs). Foreground: H2
    /// rules and fold glyphs, bullets, quote bars, rules, code labels, figures (over the glyphs).
    func drawDecorations(_ phase: DecorationPhase, glyphRange: NSRange, origin: NSPoint, layoutManager: NSLayoutManager) {
        guard appliedMode == .livePreview, !blocks.isEmpty, glyphRange.length > 0 else { return }
        let caretLine = caretBandLine()
        let selection = textView.selectedRange()
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, fragmentGlyphs, _ in
            let characters = layoutManager.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
            guard characters.length > 0, let geometry = self.lineGeometry(at: characters.location), !geometry.hidden else { return }
            let (isFirst, isLast) = self.fragmentPosition(characters, in: geometry)
            let fragment = rect.offsetBy(dx: origin.x, dy: origin.y)
            let textTop = fragment.minY + (isFirst ? geometry.top : 0)
            let textBox = CGRect(x: fragment.minX, y: textTop, width: fragment.width, height: geometry.textHeight)
            let context = FragmentContext(geometry: geometry, characters: characters, fragment: fragment, textBox: textBox,
                                          isFirst: isFirst, isLast: isLast, origin: origin)
            switch phase {
            case .underlay:
                self.drawCaretBand(context, caretLine: caretLine)
            case .background:
                self.drawBackground(context, layoutManager: layoutManager)
            case .foreground:
                self.drawForeground(context, selection: selection, layoutManager: layoutManager)
            }
        }
    }

    struct FragmentContext {
        let geometry: LineGeometry
        let characters: NSRange
        let fragment: CGRect
        let textBox: CGRect
        let isFirst: Bool
        let isLast: Bool
        let origin: NSPoint
    }

    /// The caret's source line while nothing is selected (the `.nb-raw` band).
    func caretBandLine() -> NSRange? {
        let selection = textView.selectedRange()
        guard selection.length == 0, isRevealActive, let index = blockIndexForCaret(selection.location) else { return nil }
        switch blocks[index].kind {
        case .codeFence, .hiddenFence, .table, .frontmatterLike: return nil
        default: return blocks[index].range
        }
    }

    // MARK: Background

    /// The `.nb-raw` band across the whole view (it reaches into the padding, so the text view
    /// draws it, not the layout manager, whose passes are clipped to the text container).
    private func drawCaretBand(_ c: FragmentContext, caretLine: NSRange?) {
        guard let caretLine, NSLocationInRange(c.geometry.lineRange.location, caretLine), c.textBox.height > 0 else { return }
        let band = CGRect(x: 0, y: c.textBox.minY, width: textView.bounds.width, height: c.textBox.height)
        let split = band.width * 0.7
        NSGradient(starting: style.caretLineStart, ending: style.caretLineEnd)?
            .draw(in: CGRect(x: band.minX, y: band.minY, width: split, height: band.height), angle: 0)
        Draw.fill(CGRect(x: band.minX + split, y: band.minY, width: band.width - split, height: band.height), style.caretLineEnd)
        Draw.fill(CGRect(x: band.minX, y: band.minY, width: 2, height: band.height), style.caretLineBar)
    }

    /// The text view's own passes (caret band under everything; rules, bullets, fold glyphs,
    /// labels and figures over the glyphs) for the fragments in `dirtyRect`.
    func drawTextViewDecorations(_ phase: DecorationPhase, in dirtyRect: NSRect) {
        guard appliedMode == .livePreview, !blocks.isEmpty else { return }
        let origin = textView.textContainerOrigin
        let rect = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layoutManagerRef.glyphRange(forBoundingRect: rect, in: container)
        drawDecorations(phase, glyphRange: glyphs, origin: origin, layoutManager: layoutManagerRef)
    }

    private func drawBackground(_ c: FragmentContext, layoutManager: NSLayoutManager) {
        let block = blocks[c.geometry.blockIndex]
        switch c.geometry.role {
        case .codeOpen, .codeInterior, .codeClose:
            let top = c.isFirst && c.geometry.extraTop > 0 ? c.fragment.minY + c.geometry.gap : c.fragment.minY
            let box = CGRect(x: c.fragment.minX, y: top, width: c.fragment.width, height: c.fragment.maxY - top)
            Draw.fill(box, style.codeBackground)
            Draw.fill(CGRect(x: box.minX, y: box.minY, width: 1, height: box.height), style.codeBorder)
            Draw.fill(CGRect(x: box.maxX - 1, y: box.minY, width: 1, height: box.height), style.codeBorder)
            if c.isFirst, c.geometry.extraTop > 0 { Draw.fill(CGRect(x: box.minX, y: box.minY, width: box.width, height: 1), style.codeBorder) }
            if c.isLast, c.geometry.extraBottom > 0 { Draw.fill(CGRect(x: box.minX, y: box.maxY - 1, width: box.width, height: 1), style.codeBorder) }
        default:
            break
        }
        switch block.kind {
        case .paragraph, .heading, .bullet, .ordered, .task, .quote:
            drawRuns(.coddInlineCode, in: c, layoutManager: layoutManager, height: style.inlineCodeHeight,
                     padding: style.inlineCodePadding, fill: style.inlineCodeBackground, border: style.inlineCodeBorder)
            drawRuns(.coddChip, in: c, layoutManager: layoutManager, height: style.chipHeight,
                     padding: style.chipPadding - 1, fill: style.chipFill, border: style.chipBorder)
        default:
            break
        }
    }

    /// Boxes behind attribute runs (inline code, note chips), vertically centered on the text line.
    private func drawRuns(_ key: NSAttributedString.Key, in c: FragmentContext, layoutManager: NSLayoutManager, height: CGFloat,
                          padding: CGFloat, fill: NSColor, border: NSColor) {
        storage.enumerateAttribute(key, in: c.characters, options: []) { value, range, _ in
            guard value != nil else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { return }
            let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            guard bounds.width > 0 else { return }
            let box = CGRect(x: c.origin.x + bounds.minX - padding, y: (c.textBox.midY - height / 2).rounded(),
                             width: bounds.width + 2 * padding, height: height)
            Draw.fill(box, fill)
            Draw.strokeRect(box, color: border)
        }
    }

    // MARK: Foreground

    private func drawForeground(_ c: FragmentContext, selection: NSRange, layoutManager: NSLayoutManager) {
        let index = c.geometry.blockIndex
        let block = blocks[index]
        let revealed = isRevealed(index)
        switch block.kind {
        case let .heading(level) where level == 2 && c.isFirst:
            if c.geometry.extraTop > 0 {
                let y = c.textBox.minY - style.heading2RulePadding - 1
                Draw.dashedLine(from: CGPoint(x: c.fragment.minX, y: y), to: CGPoint(x: c.fragment.maxX, y: y), color: style.headingRule)
            }
            let glyph = isFolded(headingAt: index) ? "▸" : "▾"
            let attributes: [NSAttributedString.Key: Any] = [.font: style.foldGlyphFont, .foregroundColor: style.foldGlyph]
            let size = (glyph as NSString).size(withAttributes: attributes)
            (glyph as NSString).draw(at: CGPoint(x: c.fragment.minX - style.foldGlyphOffset, y: c.textBox.midY - size.height / 2),
                                     withAttributes: attributes)
        case let .bullet(indent) where c.isFirst:
            let x = c.fragment.minX + style.listIndent * CGFloat(indent) + style.bulletInset
            let y = c.textBox.minY + 0.78 * style.bodyFont.pointSize
            Draw.fill(CGRect(x: x, y: y, width: style.bulletSize, height: style.bulletSize), style.bullet)
        case .quote:
            Draw.fill(CGRect(x: c.fragment.minX, y: c.textBox.minY, width: style.quoteBarWidth, height: c.textBox.height), style.quoteBar)
        case .rule where !revealed:
            Draw.dashedLine(from: CGPoint(x: c.fragment.minX, y: c.textBox.midY.rounded()),
                            to: CGPoint(x: c.fragment.maxX, y: c.textBox.midY.rounded()), color: style.rule)
        case let .codeFence(info) where c.isFirst && c.geometry.extraTop > 0:
            drawCodeLabel(info, boxTop: c.fragment.minY + c.geometry.gap, right: c.fragment.maxX)
        case let .image(_, path) where c.isLast:
            guard case .figure = c.geometry.role, let info = imageInfo(for: path), var figure = figureGeometry(forBlock: index) else { break }
            figure.translate(x: c.fragment.minX, y: c.fragment.maxY - figure.rowHeight)
            let selected = selection.length > 0 && NSIntersectionRange(selection, block.range).length > 0
            drawFigure(figure, info: info, selected: selected)
        default:
            break
        }
    }

    private func drawCodeLabel(_ info: String, boxTop: CGFloat, right: CGFloat) {
        guard let word = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first, !word.isEmpty else { return }
        let label = TextStyle(font: style.codeLabelFont, color: style.codeLabel, tracking: 0.14, uppercase: true).string(String(word))
        let size = label.size()
        let padding = style.codeLabelPadding
        let box = CGRect(x: right - 1 - ceil(size.width) - padding.left - padding.right, y: boxTop + 1,
                         width: ceil(size.width) + padding.left + padding.right, height: ceil(size.height) + padding.top + padding.bottom)
        Draw.fill(CGRect(x: box.minX, y: box.minY, width: 1, height: box.height), style.codeLabelBorder)
        Draw.fill(CGRect(x: box.minX, y: box.maxY - 1, width: box.width, height: 1), style.codeLabelBorder)
        label.draw(at: CGPoint(x: box.minX + padding.left, y: box.minY + padding.top))
    }

    // MARK: Figures

    func drawFigure(_ figure: FigureGeometry, info: MarkdownImageInfo, selected: Bool) {
        let plate = figure.plate
        let ring = NSBezierPath(rect: plate.insetBy(dx: -style.figureRingWidth, dy: -style.figureRingWidth))
        ring.append(NSBezierPath(rect: plate).reversed)
        style.figureRing.setFill()
        ring.fill()
        Draw.fill(plate, style.figurePlate)
        Draw.strokeRect(plate, color: style.figureBorder)
        if let image = info.image {
            image.draw(in: figure.image, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])
        } else {
            Draw.fill(figure.image, style.figureLoading)
        }
        for shape in info.overlay {
            drawOverlay(shape, pixelSize: info.pixelSize, image: figure.image)
        }
        if !figure.captionText.isEmpty {
            let caption = TextStyle(font: style.captionFont, color: style.caption, tracking: style.bodyTracking)
                .string(figure.captionText, lineBreak: .byTruncatingTail)
            caption.draw(with: figure.caption, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if selected {
            let outline = NSBezierPath(rect: plate.insetBy(dx: -1, dy: -1))
            outline.lineWidth = 2
            style.figureSelection.setStroke()
            outline.stroke()
        }
    }

    /// `.ann-box` (1.5 pt border, 10 % fill, black outer ring) with its pin at the top-left corner,
    /// `.ann-pin`, the artboard arrow (black 3.5 pt halo, 1.5 pt line, filled head), and text items
    /// on a black plate.
    func drawOverlay(_ shape: ImageOverlayShape, pixelSize: CGSize, image: CGRect) {
        let color = style.overlayColor(shape.colorName)
        switch shape {
        case let .rect(n, rect, _):
            let box = ImageOverlayGeometry.rect(rect, pixelSize: pixelSize, in: image)
            Draw.fill(box, color.withAlphaComponent(style.overlayBoxFillAlpha))
            let halo = NSBezierPath(rect: box.insetBy(dx: -1.25, dy: -1.25))
            halo.lineWidth = 1
            NSColor.black.withAlphaComponent(0.55).setStroke()
            halo.stroke()
            let border = NSBezierPath(rect: box.insetBy(dx: 0.75, dy: 0.75))
            border.lineWidth = 1.5
            color.setStroke()
            border.stroke()
            drawPin(n, at: box.origin, color: color)
        case let .point(n, point, _):
            drawPin(n, at: ImageOverlayGeometry.point(point, pixelSize: pixelSize, in: image), color: color)
        case let .arrow(n, from, to, _):
            let start = ImageOverlayGeometry.point(from, pixelSize: pixelSize, in: image)
            let end = ImageOverlayGeometry.point(to, pixelSize: pixelSize, in: image)
            let (shaftEnd, head) = ImageOverlayGeometry.arrow(from: start, to: end, headLength: style.arrowHeadLength,
                                                              headHalfWidth: style.arrowHeadHalfWidth)
            let shaft = NSBezierPath()
            shaft.move(to: start)
            shaft.line(to: shaftEnd)
            shaft.lineCapStyle = .square
            shaft.lineWidth = 3.5
            NSColor.black.setStroke()
            shaft.stroke()
            shaft.lineWidth = 1.5
            color.setStroke()
            shaft.stroke()
            let triangle = NSBezierPath()
            triangle.move(to: head[0])
            triangle.line(to: head[1])
            triangle.line(to: head[2])
            triangle.close()
            color.setFill()
            triangle.fill()
            triangle.lineWidth = 1
            NSColor.black.setStroke()
            triangle.stroke()
            drawPin(n, at: start, color: color)
        case let .text(n, point, text, _):
            let anchor = ImageOverlayGeometry.point(point, pixelSize: pixelSize, in: image)
            let label = TextStyle(font: style.overlayTextFont, color: color).string(text, lineBreak: .byTruncatingTail)
            let size = label.size()
            let maxWidth = max(20, image.maxX - anchor.x - 12)
            let plate = CGRect(x: anchor.x + style.pinSize / 2 + 2, y: anchor.y - (size.height + 4) / 2,
                               width: min(maxWidth, ceil(size.width) + 8), height: ceil(size.height) + 4)
            Draw.fill(plate, NSColor.black.withAlphaComponent(0.78))
            label.draw(with: plate.insetBy(dx: 4, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            drawPin(n, at: anchor, color: color)
        }
    }

    /// The numbered square pin, centered on `center`: 18 pt, black 1.5 pt ring, black bold number.
    func drawPin(_ number: Int, at center: CGPoint, color: NSColor) {
        let size = style.pinSize
        let rect = CGRect(x: (center.x - size / 2).rounded(), y: (center.y - size / 2).rounded(), width: size, height: size)
        let ring = NSBezierPath(rect: rect.insetBy(dx: -0.75, dy: -0.75))
        ring.lineWidth = 1.5
        NSColor.black.setStroke()
        ring.stroke()
        Draw.fill(rect, color)
        let label = TextStyle(font: style.pinFont, color: .black).string("\(number)")
        let labelSize = label.size()
        label.draw(at: CGPoint(x: rect.midX - labelSize.width / 2, y: rect.midY - labelSize.height / 2))
    }

    // MARK: Caret and placeholder

    /// The 2 pt amber insertion point with its glow, sized to the text line, not the fragment
    /// (which may also hold spacing, a figure or the title accessory).
    func drawCaret(defaultRect: NSRect) {
        var rect = defaultRect
        rect.size.width = style.caretWidth
        if let line = caretLineBox() {
            let height = min(line.height, (line.font.pointSize * 1.3).rounded())
            rect.origin.y = (line.box.midY - height / 2).rounded()
            rect.size.height = height
        }
        NSGraphicsContext.saveGraphicsState()
        Draw.glow(style.caretGlow, radius: style.caretGlowRadius).set()
        style.caret.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The text line box (text view coordinates) of the caret and its font.
    private func caretLineBox() -> (box: CGRect, height: CGFloat, font: NSFont)? {
        let location = textView.selectedRange().location
        guard let box = textLineRect(forCharacterAt: location) else { return nil }
        let font = lineGeometry(at: min(location, max(0, storage.length - 1)))?.font ?? style.bodyFont
        return (box, box.height, font)
    }

    /// The text line box holding the character at `location` (or the caret there), text view
    /// coordinates; nil on the empty last line.
    func textLineRect(forCharacterAt location: Int) -> NSRect? {
        let length = storage.length
        guard length > 0 else { return nil }
        var character = min(location, length - 1)
        if location >= length, storage.mutableString.character(at: length - 1) == Unit.newline { return nil }
        if location == length { character = length - 1 }
        guard let geometry = lineGeometry(at: character), !geometry.hidden, geometry.textHeight > 0 else { return nil }
        // A hidden prefix's glyphs sit in the previous line's fragment: ask for a visible one.
        let visible = firstVisibleCharacter(in: geometry.lineRange)
        if character < visible { character = min(visible, max(geometry.lineRange.location, NSMaxRange(geometry.lineRange) - 1)) }
        let glyph = layoutManagerRef.glyphIndexForCharacter(at: character)
        var fragmentGlyphs = NSRange()
        let fragment = layoutManagerRef.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        let characters = layoutManagerRef.characterRange(forGlyphRange: fragmentGlyphs, actualGlyphRange: nil)
        let isFirst = fragmentPosition(characters, in: geometry).isFirst
        let origin = textView.textContainerOrigin
        let top = fragment.minY + (isFirst ? geometry.top : 0)
        return NSRect(x: fragment.minX + origin.x, y: top + origin.y, width: fragment.width, height: geometry.textHeight)
    }

    /// The caret rectangle in text view coordinates (x from the glyph position).
    func caretRectInTextView() -> NSRect? {
        let location = textView.selectedRange().location
        let length = storage.length
        let origin = textView.textContainerOrigin
        layoutManagerRef.ensureLayout(for: container)
        var x: CGFloat
        if length == 0 || (location >= length && storage.mutableString.character(at: length - 1) == Unit.newline) {
            let extra = layoutManagerRef.extraLineFragmentRect
            x = extra.minX
            let height = styler.line(for: .paragraph).height
            let y = length == 0 ? 0 : extra.minY
            let font = style.bodyFont
            let caret = (font.pointSize * 1.3).rounded()
            return NSRect(x: x + origin.x, y: y + origin.y + (height - caret) / 2, width: style.caretWidth, height: caret)
        }
        if location < length {
            let glyph = layoutManagerRef.glyphIndexForCharacter(at: location)
            let fragment = layoutManagerRef.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = fragment.minX + layoutManagerRef.location(forGlyphAt: glyph).x
        } else {
            let glyph = layoutManagerRef.glyphIndexForCharacter(at: length - 1)
            let bounds = layoutManagerRef.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            x = bounds.maxX
        }
        guard let line = textLineRect(forCharacterAt: location) else { return nil }
        let font = lineGeometry(at: min(location, length - 1))?.font ?? style.bodyFont
        let height = min(line.height, (font.pointSize * 1.3).rounded())
        return NSRect(x: x + origin.x, y: (line.midY - height / 2).rounded(), width: style.caretWidth, height: height)
    }

    /// `placeholderTitle` on an empty first line (or `# ` alone), in the title style, dimmer.
    func drawPlaceholderIfNeeded() {
        guard !placeholderTitle.isEmpty else { return }
        let all = storage.mutableString
        var revealedPrefix: CGFloat = 0
        if all.length > 0 {
            guard let first = blocks.first else { return }
            switch first.kind {
            case .blank:
                // Only a document of one empty line; a blank line above text is just spacing.
                guard blocks.count == 1 else { return }
            case .heading(level: 1):
                let content = MarkdownStyler.contentRange(of: first, window: UTF16Window(all, from: 0, prefetchAll: false))
                guard content.length == 0 else { return }
                if isRevealed(0) || appliedMode == .source {
                    let prefix = all.substring(with: first.inlineMarks.first ?? NSRange(location: 0, length: 0))
                    revealedPrefix = (prefix as NSString).size(withAttributes: [.font: appliedMode == .source ? style.sourceFont : style.titleFont]).width
                }
            default:
                return
            }
            if textView.hasMarkedText(), textView.markedRange().location <= NSMaxRange(first.range) { return }
        } else if textView.hasMarkedText() {
            return
        }
        let font = appliedMode == .source ? style.sourceFont : style.titleFont
        let height = appliedMode == .source ? styler.line(for: .paragraph).height : font.pointSize * style.titleLineHeight
        let origin = textView.textContainerOrigin
        var top = origin.y
        if all.length > 0, let rect = textLineRect(forCharacterAt: 0) { top = rect.minY }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.placeholder]
        let string = NSAttributedString(string: placeholderTitle, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: origin.x + revealedPrefix, y: top + (height - size.height) / 2))
    }
}
