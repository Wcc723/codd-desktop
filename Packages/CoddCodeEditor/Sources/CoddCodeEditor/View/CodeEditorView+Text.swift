import AppKit

extension CodeEditorView {
    // MARK: Storage edits

    /// Every character edit (typing, IME marked text, undo, replacements): the line index, the
    /// cached lexer states, hunks, markers and hits follow it at once (data only); restyling waits
    /// for the flush after the edit, and for the end of a composition.
    func storageDidProcessEditing(_ textStorage: NSTextStorage, mask editedMask: NSTextStorageEditActions,
                                  range editedRange: NSRange, delta: Int) {
        guard editedMask.contains(.editedCharacters), !applyingLoad else { return }
        let edit = geometry.lines.apply(editedRange: editedRange, delta: delta, text: textStorage.mutableString)
        highlight.edit(edit)
        shiftDecorations(for: edit)
        shiftHits(editedRange: editedRange, delta: delta)
        needsFlush = true
        scheduleFlush()
    }

    func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.flushScheduled = false
                self?.flush()
            }
        }
    }

    /// Runs now what the editor queued for the next turn of the run loop (tests and snapshots
    /// call this instead of spinning the run loop).
    func performPendingWork() {
        flush()
        if hunkBarsNeedRebuild { rebuildHunkBars() }
        if findRefreshScheduled, !textView.hasMarkedText() {
            findRefreshScheduled = false
            runFind(resetCurrent: false, reveal: false)
        }
        layoutOverlay()
        gutter.needsDisplay = true
        ruler.needsDisplay = true
    }

    /// After a committed edit (`didChangeText` outside a composition).
    func textDidChangeCommitted() {
        flush()
    }

    /// The composition ended (committed or cancelled): run what waited for it.
    func compositionDidEnd() {
        guard !textView.hasMarkedText() else { return }
        if pendingFontChange { fontDidChange() }
        flush()
        if let text = pendingExternalText {
            pendingExternalText = nil
            applyExternalText(text)
        }
        let actions = pendingActions
        pendingActions = []
        for action in actions { action() }
    }

    /// Restyles after edits: decoration layout, gutter width, highlighting of the window, hits.
    /// Never while marked text exists.
    func flush() {
        guard needsFlush, !textView.hasMarkedText() else { return }
        needsFlush = false
        applyStaleAnchors()
        updateGutterWidth()
        ensureHighlight()
        if findVisible { scheduleFindRefresh() }
        reportCaret()
        refreshAll()
    }

    // MARK: Highlighting

    /// Lexes what the window needs and colors its lines (D28: the visible lines + 200; files over
    /// 2 MiB only what is visible, from an approximate state when far below the lexed part).
    func ensureHighlight() {
        guard highlightLanguage != .plain, !textView.hasMarkedText(), !applyingLoad else { return }
        let visible = visibleLineRange()
        let huge = storage.length > 2 << 20
        let margin = huge ? 0 : 200
        let window = max(0, visible.lowerBound - margin) ..< min(geometry.lines.count, visible.upperBound + margin)
        highlightPassCount += 1
        highlight.ensure(window: window, text: storage.mutableString, lines: geometry.lines, maxGap: huge ? 4000 : nil) { line, tokens in
            applyTokens(line: line, tokens)
        }
    }

    func applyTokens(line: Int, _ tokens: [(NSRange, SyntaxToken)]) {
        let lineRange = geometry.lines.range(of: line)
        guard lineRange.length > 0, NSMaxRange(lineRange) <= storage.length else { return }
        let manager = layoutManagerImpl
        manager.setTemporaryAttributes([:], forCharacterRange: lineRange)
        for (range, token) in tokens {
            guard let attributes = tokenAttributes[token], range.location < lineRange.length else { continue }
            let length = min(range.length, lineRange.length - range.location)
            manager.addTemporaryAttributes(attributes, forCharacterRange: NSRange(location: lineRange.location + range.location, length: length))
        }
        if let currentHitRange {
            let overlap = NSIntersectionRange(currentHitRange, lineRange)
            if overlap.length > 0 { manager.addTemporaryAttribute(.foregroundColor, value: style.currentHitText, forCharacterRange: overlap) }
        }
    }

    /// The lines intersecting the clip view (plus one screen's guess before the first layout).
    func visibleLineRange() -> Range<Int> {
        let lineCount = geometry.lines.count
        guard storage.length > 0 else { return 0 ..< 1 }
        var rect = scrollView.contentView.bounds
        if rect.height < 1 { rect.size.height = 1200 }
        if rect.width < 1 { rect.size.width = 1200 }
        let origin = textView.textContainerOrigin
        let glyphs = layoutManagerImpl.glyphRange(forBoundingRect: rect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layoutManagerImpl.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = geometry.lines.line(containing: characters.location)
        let last = geometry.lines.line(containing: max(characters.location, NSMaxRange(characters) - 1))
        var upper = min(lineCount, last + 1)
        if layoutManagerImpl.extraLineFragmentRect.height > 0, layoutManagerImpl.extraLineFragmentRect.intersects(rect) {
            upper = lineCount
        }
        return first ..< max(first + 1, upper)
    }

    // MARK: Editing API

    /// Replaces 0-based `lines` with `newLines` as one undoable edit named `actionName`
    /// (`還原此段`), reported through `onTextChange`. An empty range inserts before its line (after
    /// the last line when it is the line count). Ignored when read-only or out of range; waits while
    /// an input method composes.
    public func replaceLines(_ lines: Range<Int>, with newLines: [String], actionName: String) {
        guard !textView.hasMarkedText() else {
            pendingActions.append { [weak self] in self?.replaceLines(lines, with: newLines, actionName: actionName) }
            return
        }
        let count = geometry.lines.count
        guard lines.lowerBound >= 0, lines.upperBound <= count, !readOnly else { return }
        let length = storage.length
        let joined = newLines.map(CodeTextView.normalizingLineEndings).joined(separator: "\n")
        var range: NSRange
        var replacement: String
        if lines.isEmpty {
            guard !newLines.isEmpty else { return }
            if lines.lowerBound < count {
                range = NSRange(location: geometry.lines.start(of: lines.lowerBound), length: 0)
                replacement = joined + "\n"
            } else {
                range = NSRange(location: length, length: 0)
                replacement = "\n" + joined
            }
        } else {
            let start = geometry.lines.start(of: lines.lowerBound)
            let end = lines.upperBound < count ? geometry.lines.start(of: lines.upperBound) : length
            range = NSRange(location: start, length: end - start)
            if newLines.isEmpty {
                replacement = ""
                if lines.upperBound >= count, lines.lowerBound > 0 {
                    // Removing the last lines also removes the newline before them.
                    range = NSRange(location: start - 1, length: end - start + 1)
                }
            } else {
                replacement = joined + (lines.upperBound < count ? "\n" : "")
            }
        }
        let caretLine = geometry.lines.line(containing: textView.selectedRange().location)
        guard performEdit(range, replacement, actionName: actionName) else { return }
        let target = max(0, min(lines.lowerBound, geometry.lines.count - 1))
        if caretLine >= lines.lowerBound, caretLine < max(lines.upperBound, lines.lowerBound + 1) {
            textView.setSelectedRange(NSRange(location: geometry.lines.start(of: target), length: 0))
        }
    }

    /// One undoable replacement through the text view (registers undo, `onTextChange`, flush).
    @discardableResult
    func performEdit(_ range: NSRange, _ replacement: String, actionName: String, select: NSRange? = nil) -> Bool {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return false }
        let undo = textView.undoManager
        let explicitGroup = (undo?.groupingLevel ?? 1) == 0
        if explicitGroup { undo?.beginUndoGrouping() }
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        if explicitGroup { undo?.endUndoGrouping() }
        undo?.setActionName(actionName)
        if let select { textView.setSelectedRange(select) }
        return true
    }

    /// The file changed on disk and the buffer had no edits (D25 clean reload): takes `text`,
    /// keeps the caret on its line and column and the scroll position, as one undoable step
    /// (`重新載入`) without `onTextChange`. While an input method composes it waits for the end.
    public func applyExternalText(_ text: String) {
        guard !textView.hasMarkedText() else {
            pendingExternalText = text
            return
        }
        let new = CodeTextView.normalizingLineEndings(text) as NSString
        let old = storage.mutableString
        // Only the changed middle is replaced: colors, states and layout outside it survive.
        let oldLength = old.length
        let newLength = new.length
        var prefix = 0
        let limit = min(oldLength, newLength)
        while prefix < limit, old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, old.character(at: oldLength - 1 - suffix) == new.character(at: newLength - 1 - suffix) { suffix += 1 }
        guard prefix < oldLength || prefix < newLength, !(prefix == oldLength && prefix == newLength) else { return }
        let range = NSRange(location: prefix, length: oldLength - prefix - suffix)
        let replacement = new.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix))
        let caret = self.caret
        let origin = scrollView.contentView.bounds.origin
        let wasEditable = textView.isEditable
        textView.isEditable = true
        textView.suppressesTextChange = true
        performEdit(range, replacement, actionName: "重新載入")
        textView.suppressesTextChange = false
        textView.isEditable = wasEditable
        let line = max(0, min(caret.line - 1, geometry.lines.count - 1))
        let lineRange = geometry.lines.range(of: line)
        textView.setSelectedRange(NSRange(location: lineRange.location + min(caret.column - 1, lineRange.length), length: 0))
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Geometry helpers

    /// The caret position for a character index: x and the baseline, in text view coordinates.
    func insertionPoint(at index: Int) -> (x: CGFloat, baseline: CGFloat)? {
        let manager = layoutManagerImpl
        let origin = textView.textContainerOrigin
        let length = storage.length
        let glyphCount = manager.numberOfGlyphs
        if length == 0 || (index >= length && storage.mutableString.character(at: length - 1) == 0x0A) {
            if glyphCount > 0 { manager.ensureLayout(forGlyphRange: NSRange(location: glyphCount - 1, length: 1)) } else { manager.ensureLayout(for: container) }
            let extra = manager.extraLineFragmentRect
            guard extra.height > 0 else { return nil }
            return (extra.minX + origin.x, extra.minY + origin.y + geometry.baseline)
        }
        guard glyphCount > 0 else { return nil }
        let atEnd = index >= length
        let glyph = atEnd ? glyphCount - 1 : manager.glyphIndexForCharacter(at: index)
        var fragmentGlyphs = NSRange()
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        let insets = geometry.insets(fragmentStart: manager.characterIndexForGlyph(at: fragmentGlyphs.location),
                                     glyphRange: fragmentGlyphs, numberOfGlyphs: glyphCount)
        var x = fragment.minX + manager.location(forGlyphAt: glyph).x
        if atEnd { x = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX }
        return (x + origin.x, fragment.minY + insets.top + origin.y + geometry.baseline)
    }

    /// The text row of `line`'s first fragment (text view coordinates).
    func textRowRect(line: Int) -> NSRect? {
        let manager = layoutManagerImpl
        let origin = textView.textContainerOrigin
        let start = geometry.lines.start(of: line)
        let length = storage.length
        let glyphCount = manager.numberOfGlyphs
        if start >= length {
            if glyphCount > 0 { manager.ensureLayout(forGlyphRange: NSRange(location: glyphCount - 1, length: 1)) } else { manager.ensureLayout(for: container) }
            let extra = manager.extraLineFragmentRect
            if extra.height > 0 { return NSRect(x: 0, y: extra.minY + origin.y, width: textView.bounds.width, height: lineHeight) }
            guard glyphCount > 0 else { return nil }
        }
        let glyph = min(manager.glyphIndexForCharacter(at: min(start, max(0, length - 1))), max(0, glyphCount - 1))
        var fragmentGlyphs = NSRange()
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &fragmentGlyphs)
        let insets = geometry.insets(fragmentStart: manager.characterIndexForGlyph(at: fragmentGlyphs.location),
                                     glyphRange: fragmentGlyphs, numberOfGlyphs: glyphCount)
        return NSRect(x: 0, y: fragment.minY + insets.top + origin.y, width: textView.bounds.width, height: lineHeight)
    }

    /// Redraws the text rows of `lines` (current-line band changes) in the text view.
    func invalidateRows(lines: [Int]) {
        for line in lines where line >= 0 && line < geometry.lines.count {
            guard let row = textRowRect(line: line) else { continue }
            textView.setNeedsDisplay(row.insetBy(dx: 0, dy: -1))
        }
    }
}
