import AppKit
import CoddUI

/// A drawn row of the code view: a text line's fragment (`first`: it starts the line, so it gets
/// the number), a hunk bar, or a removed line of a hunk. `minY` / `height` in text view coordinates.
struct VisualRow: Equatable {
    enum Kind: Equatable {
        case text(line: Int, first: Bool)
        case hunkBar(hunk: Int)
        case removed(hunk: Int, index: Int)
    }

    var kind: Kind
    var minY: CGFloat
    var height: CGFloat
}

extension CodeEditorView {
    // MARK: Inline diff

    /// Shows inline hunks (D27): each one's bar and removed lines as a block decoration above its
    /// first new line (at the deletion point for pure deletions), its added lines tinted. Hunks
    /// whose lines are out of range are dropped; so are hunks an edit invalidates, until the owner
    /// sends new ones.
    public func setInlineDiff(_ newHunks: [InlineDiffHunk]) {
        let lineCount = geometry.lines.count
        let valid = newHunks
            .filter { $0.newLines.lowerBound >= 0 && $0.newLines.upperBound <= lineCount && $0.newLines.lowerBound <= lineCount }
            .sorted { $0.newLines.lowerBound < $1.newLines.lowerBound }
        guard valid != hunks else { return }
        staleAnchorRanges.append(contentsOf: anchorRanges())
        hunks = valid
        removedLineCache = [:]
        rebuildDecorations()
        staleAnchorRanges.append(contentsOf: anchorRanges())
        applyStaleAnchors()
        rebuildHunkBars()
        refreshAll()
    }

    /// The shown hunks (after edits shifted or dropped some).
    public var inlineDiff: [InlineDiffHunk] { hunks }

    /// Scrolls the hunk's bar and removed lines into the middle of the view.
    public func scrollToHunk(_ id: Int) {
        guard let index = hunks.firstIndex(where: { $0.id == id }), let bar = barRect(hunk: index) else { return }
        let block = hunkHeight(hunks[index]) + CGFloat(max(1, hunks[index].newLines.count)) * lineHeight
        let clip = scrollView.contentView.bounds
        let target = block >= clip.height ? bar.minY - lineHeight : bar.minY - (clip.height - block) / 2
        scroll(toY: target)
    }

    func hunkHeight(_ hunk: InlineDiffHunk) -> CGFloat {
        style.hunkBarHeight + CGFloat(hunk.deletedLines.count) * lineHeight
    }

    /// Whether line `line` has no line fragment of its own (the empty line after a final newline).
    private func isExtraLine(_ line: Int) -> Bool {
        let length = storage.length
        return line >= geometry.lines.count - 1 && (length == 0 || storage.mutableString.character(at: length - 1) == 0x0A)
    }

    func rebuildDecorations() {
        geometry.above = [:]
        geometry.trailing = 0
        aboveHunks = [:]
        trailingHunks = []
        let lineCount = geometry.lines.count
        for (index, hunk) in hunks.enumerated() {
            let anchor = hunk.newLines.lowerBound
            let height = hunkHeight(hunk)
            if anchor >= lineCount || isExtraLine(anchor) {
                geometry.trailing += height
                trailingHunks.append(index)
            } else {
                geometry.above[anchor, default: 0] += height
                aboveHunks[anchor, default: []].append(index)
            }
        }
    }

    /// The character ranges whose layout carries the current decorations.
    private func anchorRanges() -> [NSRange] {
        var ranges = geometry.above.keys.map { geometry.lines.rangeWithNewline(of: $0) }
        if geometry.trailing > 0, storage.length > 0 {
            let last = geometry.lines.line(containing: storage.length - 1)
            ranges.append(geometry.lines.rangeWithNewline(of: last))
        }
        return ranges
    }

    /// Lays out again the fragments whose decoration space changed.
    func applyStaleAnchors() {
        let length = storage.length
        guard !staleAnchorRanges.isEmpty else { return }
        for range in staleAnchorRanges {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            let target = clamped.length > 0 ? clamped : NSRange(location: max(0, min(range.location, length - 1)), length: length > 0 ? 1 : 0)
            guard target.length > 0 else { continue }
            layoutManagerImpl.invalidateLayout(forCharacterRange: target, actualCharacterRange: nil)
            layoutManagerImpl.invalidateDisplay(forCharacterRange: target)
        }
        staleAnchorRanges = []
        // Re-lay out the visible part now, so the frame and the overlays match this pass.
        _ = visibleLineRange()
    }

    /// Hunks follow line insertions and deletions above them; a hunk the edit cut into keeps its
    /// adjusted range when that is still valid, otherwise it is dropped (the owner recomputes).
    func shiftDecorations(for edit: LineIndex.Edit) {
        let first = edit.line
        let oldEnd = first + edit.oldCount
        let delta = edit.delta
        let lineCount = geometry.lines.count
        if !hunks.isEmpty {
            let before = anchorRanges()
            var kept: [InlineDiffHunk] = []
            var changed = delta != 0
            for var hunk in hunks {
                let range = hunk.newLines
                if range.lowerBound >= oldEnd || (range.isEmpty && range.lowerBound > first && range.lowerBound >= oldEnd) {
                    if delta != 0 { hunk.newLines = (range.lowerBound + delta) ..< (range.upperBound + delta) }
                } else if range.upperBound <= first || (range.isEmpty && range.lowerBound <= first) {
                    // Entirely above the edit (a pure deletion at the edited line stays above it).
                } else if !range.isEmpty, range.lowerBound <= first {
                    hunk.newLines = range.lowerBound ..< max(range.lowerBound + 1, range.upperBound + delta)
                } else {
                    changed = true
                    continue
                }
                guard hunk.newLines.upperBound <= lineCount else {
                    changed = true
                    continue
                }
                kept.append(hunk)
            }
            if changed || kept != hunks {
                staleAnchorRanges.append(contentsOf: before)
                hunks = kept
                removedLineCache = [:]
                rebuildDecorations()
                staleAnchorRanges.append(contentsOf: anchorRanges())
                rebuildHunkBarsLater()
            }
        }
        if delta != 0, !modifiedLineMarkers.isEmpty {
            var shifted: [Int: NSColor] = [:]
            for (line, color) in modifiedLineMarkers {
                if line < first + 1 { shifted[line] = color } else if line >= oldEnd { shifted[line + delta] = color }
            }
            modifiedLineMarkers = shifted
        }
    }

    private func rebuildHunkBarsLater() {
        guard !hunkBarsNeedRebuild else { return }
        hunkBarsNeedRebuild = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hunkBarsNeedRebuild else { return }
                self.rebuildHunkBars()
            }
        }
    }

    /// One bar view per shown hunk (reused by id).
    func rebuildHunkBars() {
        hunkBarsNeedRebuild = false
        var bars: [Int: HunkBarView] = [:]
        for hunk in hunks {
            let bar = hunkBars[hunk.id] ?? HunkBarView(hunkID: hunk.id, header: hunk.header, textLeft: gutterWidth + style.textLeftInset, style: style)
            bar.update(header: hunk.header)
            bar.textLeft = gutterWidth + style.textLeftInset
            bar.editor = self
            bar.onAction = { [weak self] id, action in self?.onHunkAction?(id, action) }
            if bar.superview == nil { overlay.addSubview(bar) }
            bars[hunk.id] = bar
        }
        for (id, bar) in hunkBars where bars[id] == nil { bar.removeFromSuperview() }
        hunkBars = bars
        layoutOverlay()
    }

    /// The bar of hunk `index` in text view coordinates.
    func barRect(hunk index: Int) -> NSRect? {
        guard index < hunks.count else { return nil }
        let manager = layoutManagerImpl
        let origin = textView.textContainerOrigin
        let glyphCount = manager.numberOfGlyphs
        guard glyphCount > 0 else { return nil }
        if let position = trailingHunks.firstIndex(of: index) {
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: nil)
            let offset = trailingHunks[..<position].reduce(CGFloat(0)) { $0 + hunkHeight(hunks[$1]) }
            return NSRect(x: 0, y: fragment.maxY - geometry.trailing + offset + origin.y, width: textView.bounds.width, height: style.hunkBarHeight)
        }
        let anchor = hunks[index].newLines.lowerBound
        guard let group = aboveHunks[anchor], let position = group.firstIndex(of: index) else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: geometry.lines.start(of: anchor))
        let fragment = manager.lineFragmentRect(forGlyphAt: min(glyph, glyphCount - 1), effectiveRange: nil)
        let offset = group[..<position].reduce(CGFloat(0)) { $0 + hunkHeight(hunks[$1]) }
        return NSRect(x: 0, y: fragment.minY + offset + origin.y, width: textView.bounds.width, height: style.hunkBarHeight)
    }

    /// Places the bars of the hunks near the visible lines; the others are hidden.
    func layoutOverlay() {
        guard !hunkBars.isEmpty else { return }
        let clip = scrollView.contentView.bounds
        let visible = storage.length > 0 ? visibleLineRange() : 0 ..< 1
        let near = (visible.lowerBound - 2) ..< (visible.upperBound + 2)
        for (index, hunk) in hunks.enumerated() {
            guard let bar = hunkBars[hunk.id] else { continue }
            let anchor = hunk.newLines.lowerBound
            let isTrailing = trailingHunks.contains(index)
            guard isTrailing ? visible.upperBound >= geometry.lines.count - 1 : near.contains(anchor), let rect = barRect(hunk: index) else {
                bar.isHidden = true
                continue
            }
            let y = rect.minY - clip.minY
            bar.frame = NSRect(x: 0, y: y, width: overlay.bounds.width, height: style.hunkBarHeight)
            bar.isHidden = y + style.hunkBarHeight < 0 || y > overlay.bounds.height
        }
    }

    /// The frame of each visible hunk bar in the editor's coordinates (tests).
    var hunkBarFramesForTesting: [Int: NSRect] {
        var frames: [Int: NSRect] = [:]
        for (id, bar) in hunkBars where !bar.isHidden { frames[id] = overlay.convert(bar.frame, to: self) }
        return frames
    }

    var hunkBarViewsForTesting: [Int: HunkBarView] { hunkBars }

    /// The hunk whose added lines include `line`.
    func addedHunk(containing line: Int) -> InlineDiffHunk? {
        var low = 0
        var high = hunks.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = hunks[mid].newLines
            if range.contains(line) { return hunks[mid] }
            if line < range.lowerBound { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }

    // MARK: Rows

    /// The rows intersecting `rect` (text view coordinates), top to bottom.
    func visualRows(in rect: NSRect) -> [VisualRow] {
        var rows: [VisualRow] = []
        let manager = layoutManagerImpl
        let origin = textView.textContainerOrigin
        let glyphCount = manager.numberOfGlyphs
        if glyphCount > 0 {
            let glyphs = manager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
            if glyphs.length > 0 {
                manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, fragmentGlyphs, _ in
                    let start = manager.characterIndexForGlyph(at: fragmentGlyphs.location)
                    let line = self.geometry.lines.line(containing: start)
                    let first = self.geometry.lines.start(of: line) == start
                    let insets = self.geometry.insets(fragmentStart: start, glyphRange: fragmentGlyphs, numberOfGlyphs: glyphCount)
                    let top = fragment.minY + origin.y
                    if insets.top > 0, let group = self.aboveHunks[line] {
                        self.appendDecorationRows(group, top: top, into: &rows)
                    }
                    rows.append(VisualRow(kind: .text(line: line, first: first), minY: top + insets.top, height: fragment.height - insets.top - insets.bottom))
                    if insets.bottom > 0 {
                        self.appendDecorationRows(self.trailingHunks, top: fragment.maxY + origin.y - insets.bottom, into: &rows)
                    }
                }
            }
        }
        let extra = manager.extraLineFragmentRect
        if extra.height > 0 {
            let row = VisualRow(kind: .text(line: geometry.lines.count - 1, first: true), minY: extra.minY + origin.y, height: lineHeight)
            if row.minY < rect.maxY, row.minY + row.height > rect.minY { rows.append(row) }
        }
        return rows.filter { $0.minY < rect.maxY && $0.minY + $0.height > rect.minY }
    }

    private func appendDecorationRows(_ group: [Int], top: CGFloat, into rows: inout [VisualRow]) {
        var y = top
        for index in group {
            rows.append(VisualRow(kind: .hunkBar(hunk: index), minY: y, height: style.hunkBarHeight))
            y += style.hunkBarHeight
            for k in hunks[index].deletedLines.indices {
                rows.append(VisualRow(kind: .removed(hunk: index, index: k), minY: y, height: lineHeight))
                y += lineHeight
            }
        }
    }

    /// The line whose row shows the current-line band (none while text is selected).
    var bandLine: Int? {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return nil }
        return geometry.lines.line(containing: selection.location)
    }

    // MARK: Drawing: text view

    func drawTextBackground(in rect: NSRect) {
        let band = bandLine
        for row in visualRows(in: rect) {
            let area = NSRect(x: rect.minX, y: row.minY, width: rect.width, height: row.height)
            switch row.kind {
            case .text(let line, _):
                if addedHunk(containing: line) != nil { Draw.fill(area, style.addedBackground) }
                if line == band { drawCurrentLineBand(area) }
            case .removed(let hunk, let index):
                Draw.fill(area, style.removedBackground)
                drawRemovedLine(hunk: hunk, index: index, rowTop: row.minY)
            case .hunkBar:
                break
            }
        }
        drawHits(in: rect)
    }

    private func drawCurrentLineBand(_ area: NSRect) {
        Draw.fill(area, style.currentLineBand)
        Draw.fill(NSRect(x: area.minX, y: area.minY, width: area.width, height: 1), style.currentLineBorder)
        Draw.fill(NSRect(x: area.minX, y: area.maxY - 1, width: area.width, height: 1), style.currentLineBorder)
    }

    /// A removed line at `.72`, highlighted from the hunk position's lexer state.
    private func drawRemovedLine(hunk index: Int, index line: Int, rowTop: CGFloat) {
        let strings = removedLines(hunk: index)
        guard line < strings.count else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(style.removedTextOpacity)
        let origin = textView.textContainerOrigin
        let y = rowTop + geometry.baseline - font.ascender
        strings[line].draw(with: NSRect(x: origin.x, y: y, width: 100_000, height: lineHeight), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    func removedLines(hunk index: Int) -> [NSAttributedString] {
        let hunk = hunks[index]
        let state = highlight.state(at: min(hunk.newLines.lowerBound, max(0, geometry.lines.count - 1)))
        if let cached = removedLineCache[index], cached.state == state { return cached.lines }
        let highlighter = SyntaxHighlighter(language: highlightLanguage)
        var lexState = state
        let paragraph = (baseAttributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
        paragraph?.minimumLineHeight = 0
        paragraph?.maximumLineHeight = 0
        var base = baseAttributes
        base[.paragraphStyle] = paragraph
        let lines: [NSAttributedString] = hunk.deletedLines.map { text in
            let string = NSMutableAttributedString(string: text, attributes: base)
            guard highlightLanguage != .plain else { return string }
            let result = highlighter.tokens(line: text, startState: lexState)
            lexState = result.endState
            for (range, token) in result.tokens where NSMaxRange(range) <= string.length {
                string.addAttribute(.foregroundColor, value: style.color(for: token), range: range)
                if token == .comment { string.addAttribute(.obliqueness, value: style.commentObliqueness, range: range) }
            }
            return string
        }
        removedLineCache[index] = (state, lines)
        return lines
    }

    private func drawHits(in rect: NSRect) {
        guard findVisible, !findMatches.isEmpty else { return }
        let manager = layoutManagerImpl
        let origin = textView.textContainerOrigin
        let glyphs = manager.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let visible = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var index = firstMatch(endingAfter: visible.location)
        let glyphCount = manager.numberOfGlyphs
        while index < findMatches.count, findMatches[index].location <= NSMaxRange(visible) {
            let match = findMatches[index]
            let isCurrent = index == findCurrent
            let matchGlyphs = manager.glyphRange(forCharacterRange: match, actualCharacterRange: nil)
            manager.enumerateLineFragments(forGlyphRange: matchGlyphs) { fragment, _, _, fragmentGlyphs, _ in
                let piece = NSIntersectionRange(matchGlyphs, fragmentGlyphs)
                guard piece.length > 0 else { return }
                let bounds = manager.boundingRect(forGlyphRange: piece, in: self.container)
                let insets = self.geometry.insets(fragmentStart: manager.characterIndexForGlyph(at: fragmentGlyphs.location),
                                                  glyphRange: fragmentGlyphs, numberOfGlyphs: glyphCount)
                let box = NSRect(x: bounds.minX + origin.x, y: fragment.minY + insets.top + origin.y + self.geometry.contentTop,
                                 width: max(1, bounds.width), height: self.geometry.contentHeight)
                if isCurrent {
                    NSGraphicsContext.saveGraphicsState()
                    Draw.glow(self.style.currentHitGlow, radius: 8).set()
                    Draw.fill(box, self.style.currentHitFill)
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    Draw.fill(box, self.style.hitFill)
                    Draw.strokeRect(box, color: self.style.hitStroke)
                }
            }
            index += 1
        }
    }

    /// The first match whose end is after `location` (matches are sorted and disjoint).
    func firstMatch(endingAfter location: Int) -> Int {
        var low = 0
        var high = findMatches.count
        while low < high {
            let mid = (low + high) / 2
            if NSMaxRange(findMatches[mid]) <= location { low = mid + 1 } else { high = mid }
        }
        return low
    }

    // MARK: Drawing: gutter

    func drawGutter(in dirtyRect: NSRect) {
        Draw.fill(dirtyRect, style.background)
        let clipY = scrollView.contentView.bounds.minY
        let rect = NSRect(x: 0, y: dirtyRect.minY + clipY, width: max(1, textView.bounds.width), height: dirtyRect.height)
        let band = bandLine
        let caretLine = geometry.lines.line(containing: textView.selectedRange().location)
        let numberRight = gutterWidth - style.markerColumnWidth - style.numberRightPadding
        let markerLeft = gutterWidth - style.markerColumnWidth
        let width = gutter.bounds.width
        for row in visualRows(in: rect) {
            let y = row.minY - clipY
            let area = NSRect(x: 0, y: y, width: width, height: row.height)
            switch row.kind {
            case .text(let line, let first):
                let added = addedHunk(containing: line)
                if let added {
                    Draw.fill(area, style.addedBackground)
                    Draw.fill(NSRect(x: 0, y: y, width: style.hunkBarInset, height: row.height), added.header.tagColor)
                }
                if line == band { drawCurrentLineBand(area) }
                if added != nil {
                    if first { drawMarker("+", color: style.addedMarker, left: markerLeft, rowTop: y) }
                } else if let color = modifiedLineMarkers[line] {
                    Draw.fill(NSRect(x: markerLeft + (style.markerColumnWidth - style.modifiedBarWidth) / 2, y: y,
                                     width: style.modifiedBarWidth, height: row.height), color)
                }
                if first {
                    let color = line == caretLine ? style.currentLineNumber : (added != nil ? style.addedLineNumber : style.lineNumber)
                    let number = NSAttributedString(string: String(line + 1), attributes: [.font: font, .foregroundColor: color])
                    let numberWidth = number.size().width
                    number.draw(with: NSRect(x: numberRight - numberWidth, y: y + geometry.baseline - font.ascender, width: numberWidth + 2, height: lineHeight),
                                options: [.usesLineFragmentOrigin])
                }
            case .removed(let hunk, _):
                Draw.fill(area, style.removedBackground)
                Draw.fill(NSRect(x: 0, y: y, width: style.hunkBarInset, height: row.height), hunks[hunk].header.tagColor)
                drawMarker("−", color: style.removedMarker, left: markerLeft, rowTop: y)
            case .hunkBar:
                break
            }
        }
    }

    private func drawMarker(_ glyph: String, color: NSColor, left: CGFloat, rowTop: CGFloat) {
        let string = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: color])
        let width = string.size().width
        string.draw(with: NSRect(x: left + (style.markerColumnWidth - width) / 2, y: rowTop + geometry.baseline - font.ascender,
                                 width: width + 2, height: lineHeight), options: [.usesLineFragmentOrigin])
    }

    /// What the gutter shows (tests): per visible row, the number drawn (nil for none) and the marker.
    func gutterRowsForTesting() -> [(kind: VisualRow.Kind, number: Int?, marker: String?)] {
        let clip = scrollView.contentView.bounds
        return visualRows(in: NSRect(x: 0, y: clip.minY, width: max(1, textView.bounds.width), height: max(1, clip.height))).map { row in
            switch row.kind {
            case .text(let line, let first):
                let marker = addedHunk(containing: line) != nil ? (first ? "+" : nil) : (modifiedLineMarkers[line] != nil ? "mod" : nil)
                return (row.kind, first ? line + 1 : nil, marker)
            case .removed:
                return (row.kind, nil, "−")
            case .hunkBar:
                return (row.kind, nil, nil)
            }
        }
    }

    // MARK: Drawing: ruler

    func drawRuler(in bounds: NSRect) {
        Draw.fill(bounds, style.rulerBackground)
        Draw.fill(NSRect(x: 0, y: 0, width: 1, height: bounds.height), style.rulerBorder)
        let lineCount = CGFloat(max(1, geometry.lines.count))
        let height = bounds.height
        func y(_ line: Int) -> CGFloat { CGFloat(line) / lineCount * height }
        let visible = visibleLineRange()
        Draw.fill(NSRect(x: 1, y: y(visible.lowerBound), width: bounds.width - 1,
                         height: max(2, y(visible.upperBound) - y(visible.lowerBound))), style.rulerThumb)
        if findVisible {
            var lastLine = -1
            for match in findMatches {
                let line = geometry.lines.line(containing: match.location)
                guard line != lastLine else { continue }
                lastLine = line
                Draw.fill(NSRect(x: 8, y: y(line), width: bounds.width - 9, height: 3), style.rulerHit)
            }
        }
        let order: [OverviewMark.Kind] = [.hit, .aiChange, .removed, .added, .cursor]
        for kind in order {
            for mark in overviewMarks where mark.kind == kind {
                switch kind {
                case .hit:
                    Draw.fill(NSRect(x: 8, y: y(mark.line), width: bounds.width - 9, height: 3), mark.color ?? style.rulerHit)
                case .aiChange:
                    Draw.fill(NSRect(x: 1, y: y(mark.line), width: 4, height: 3), mark.color ?? style.rulerAIChange)
                case .removed:
                    Draw.fill(NSRect(x: 1, y: y(mark.line) - 1, width: 4, height: 2), mark.color ?? style.rulerRemoved)
                case .added:
                    let top = y(mark.line)
                    Draw.fill(NSRect(x: 1, y: top, width: 4, height: max(3, y(mark.line + max(1, mark.lineCount)) - top)),
                              mark.color ?? style.rulerAdded)
                case .cursor:
                    Draw.fill(NSRect(x: 1, y: y(mark.line), width: bounds.width - 1, height: 2), mark.color ?? style.rulerCursor)
                }
            }
        }
        let caretLine = geometry.lines.line(containing: textView.selectedRange().location)
        Draw.fill(NSRect(x: 1, y: y(caretLine), width: bounds.width - 1, height: 2), style.rulerCursor)
    }
}
