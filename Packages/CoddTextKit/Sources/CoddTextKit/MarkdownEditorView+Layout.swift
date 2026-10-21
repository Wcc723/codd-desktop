import AppKit

// MARK: - Storage edits

extension MarkdownEditorView: NSTextStorageDelegate {
    /// Character edits are reparsed here, inside the editing pass; their blocks are restyled right
    /// after it (`restyleAfterEdit`). While composing, block ranges only shift; the reparse waits
    /// for the commit.
    public nonisolated func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                        range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            self.storageWillProcessCharacters(editedRange, delta: delta)
        }
    }

    func storageWillProcessCharacters(_ edited: NSRange, delta: Int) {
        if loading { return }
        generation += 1
        shiftCaretState(edited, delta: delta)
        pendingRestyle = Self.shift(pendingRestyle, by: edited, delta: delta)
        if textView.isComposing {
            provisionalShift(edited, delta: delta)
            pendingDirty = Self.union(Self.shift(pendingDirty, by: edited, delta: delta), edited)
            return
        }
        if let dirty = pendingDirty {
            // A commit's own edit arrives with the composition region still pending: parse both.
            pendingDirty = nil
            let union = Self.union(Self.shift(dirty, by: edited, delta: delta), edited) ?? edited
            reparse(edited: edited, delta: delta)
            reparse(edited: union, delta: 0)
        } else {
            reparse(edited: edited, delta: delta)
        }
    }

    private func reparse(edited: NSRange, delta: Int) {
        let changed = MarkdownBlockParser.applyEdit(&blocks, text: storage.mutableString, edited: edited, delta: delta,
                                                    hidden: appliedHiddenFences)
        // Not restyled inside this pass: attributes set here widen the pass's edited range, and
        // NSTextView puts the caret at the end of that range (a Return mid-text jumped to the end).
        pendingRestyle = Self.union(pendingRestyle, span(of: changed) ?? NSRange(location: edited.location, length: 0))
        if !foldedHeadings.isEmpty { recomputeFolds() }
    }

    /// The characters of blocks `range` (nil when it is empty).
    private func span(of range: Range<Int>) -> NSRange? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= blocks.count else { return nil }
        let start = blocks[range.lowerBound].range.location
        return NSRange(location: start, length: NSMaxRange(blocks[range.upperBound - 1].range) - start)
    }

    /// The blocks the last edits touched get their attributes, in a pass of their own once the
    /// text view has placed the caret (attribute-only edits leave the selection alone). While
    /// composing they join the composition's region instead (restyled at the commit).
    func restyleAfterEdit() {
        guard let range = pendingRestyle else { return }
        pendingRestyle = nil
        guard !blocks.isEmpty else { return }
        if textView.isComposing {
            pendingDirty = Self.union(pendingDirty, range)
            return
        }
        let length = storage.length
        let location = min(range.location, length)
        let end = min(NSMaxRange(range), length)
        let first = MarkdownBlockParser.blockIndex(containing: location, in: blocks)
            ?? min(MarkdownBlockParser.firstBlockIndex(startingAtOrAfter: location, in: blocks), blocks.count - 1)
        let last = MarkdownBlockParser.blockIndex(containing: max(location, end - 1), in: blocks) ?? blocks.count - 1
        storage.beginEditing()
        restyle(blocksAround: first ..< max(first, last) + 1)
        storage.endEditing()
    }

    /// Reparses a region outside an editing pass (after a composition) and restyles it.
    func reparseAndRestyle(_ dirty: NSRange) {
        let length = storage.length
        let location = min(dirty.location, length)
        let clamped = NSRange(location: location, length: min(dirty.length, length - location))
        storage.beginEditing()
        let changed = MarkdownBlockParser.applyEdit(&blocks, text: storage.mutableString, edited: clamped, delta: 0,
                                                    hidden: appliedHiddenFences)
        restyle(blocksAround: changed)
        storage.endEditing()
        if !foldedHeadings.isEmpty { recomputeFolds() }
    }

    /// Restyles the parsed blocks plus one neighbor on each side (and the hidden blocks after them):
    /// a block's gap depends on the block before it, so its line must be laid out again too.
    func restyle(blocksAround changed: Range<Int>) {
        guard !blocks.isEmpty else { return }
        var lower = max(0, changed.lowerBound - 1)
        var upper = min(blocks.count, changed.upperBound + 1)
        while upper < blocks.count, isBlockHidden(upper - 1) { upper += 1 }
        lower = min(lower, upper)
        guard lower < upper else { return }
        let window = UTF16Window(storage.mutableString, from: blocks[lower].range.location, prefetchAll: false)
        styler.apply(blocks[lower ..< upper], to: storage, window: window)
    }

    func restyleAll() {
        guard !blocks.isEmpty else { return }
        let window = UTF16Window(storage.mutableString, from: 0, prefetchAll: true)
        styler.apply(blocks, to: storage, window: window)
    }

    /// While composing: shift block ranges and marks so lookups stay right; kinds stay as they were.
    func provisionalShift(_ edited: NSRange, delta: Int) {
        let editStart = edited.location
        let editEndOld = NSMaxRange(edited) - delta
        let length = storage.length
        guard !blocks.isEmpty else {
            if length > 0 { blocks = [MarkdownBlock(kind: .paragraph, range: NSRange(location: 0, length: length))] }
            return
        }
        let oldTotal = NSMaxRange(blocks[blocks.count - 1].range)
        if editStart >= oldTotal {
            let last = blocks.count - 1
            if storage.mutableString.length > 0, endsWithNewline(blocks[last].range, oldText: true) {
                blocks.append(MarkdownBlock(kind: .paragraph, range: NSRange(location: oldTotal, length: delta)))
            } else {
                blocks[last].range.length += delta
            }
            return
        }
        let first = MarkdownBlockParser.blockIndex(containing: editStart, in: blocks) ?? blocks.count - 1
        var lastIndex = first
        while lastIndex + 1 < blocks.count, NSMaxRange(blocks[lastIndex].range) < editEndOld { lastIndex += 1 }
        let start = blocks[first].range.location
        let end = NSMaxRange(blocks[lastIndex].range) + delta
        var marks: [NSRange] = blocks[first].inlineMarks.filter { NSMaxRange($0) <= editStart }
        for mark in blocks[lastIndex].inlineMarks where mark.location >= editEndOld {
            marks.append(NSRange(location: mark.location + delta, length: mark.length))
        }
        let merged = MarkdownBlock(kind: blocks[first].kind, range: NSRange(location: start, length: max(0, end - start)), inlineMarks: marks)
        if delta != 0, lastIndex + 1 < blocks.count {
            for index in (lastIndex + 1) ..< blocks.count {
                blocks[index].range.location += delta
                for mark in blocks[index].inlineMarks.indices { blocks[index].inlineMarks[mark].location += delta }
            }
        }
        blocks.replaceSubrange(first ... lastIndex, with: [merged])
    }

    private func endsWithNewline(_ range: NSRange, oldText: Bool) -> Bool {
        // The block's last unit in the old text sits at the same index (the edit is after it).
        let index = NSMaxRange(range) - 1
        guard index >= 0, index < storage.length else { return false }
        return storage.mutableString.character(at: index) == Unit.newline
    }

    /// Keeps the revealed range and fold anchors on the same text through an edit.
    private func shiftCaretState(_ edited: NSRange, delta: Int) {
        revealedRange = Self.shift(revealedRange, by: edited, delta: delta, growsAtEnd: true)
        if !foldedHeadings.isEmpty {
            let editEndOld = NSMaxRange(edited) - delta
            foldedHeadings = foldedHeadings.compactMap { start in
                if start >= editEndOld { return start + delta }
                if start < edited.location { return start }
                return nil
            }
        }
    }

    /// `range` (old coordinates) moved through an edit (`edited` new coordinates, `delta`).
    static func shift(_ range: NSRange?, by edited: NSRange, delta: Int, growsAtEnd: Bool = true) -> NSRange? {
        guard let range else { return nil }
        let editStart = edited.location
        let editEndOld = NSMaxRange(edited) - delta
        var start = range.location
        var end = NSMaxRange(range)
        if start >= editEndOld, !(start == editEndOld && start == editStart) { start += delta } else if start > editStart {
            start = editStart
        }
        if end > editEndOld || (growsAtEnd && end == editEndOld) { end += delta } else if end > editStart { end = NSMaxRange(edited) }
        if end < start { end = start }
        return NSRange(location: start, length: end - start)
    }

    static func union(_ a: NSRange?, _ b: NSRange?) -> NSRange? {
        guard let a else { return b }
        guard let b else { return a }
        return NSUnionRange(a, b)
    }
}

// MARK: - Glyphs and line fragments

extension MarkdownEditorView: NSLayoutManagerDelegate {
    public nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                          shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                          properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                                          characterIndexes charIndexes: UnsafePointer<Int>,
                                          font aFont: NSFont,
                                          forGlyphRange glyphRange: NSRange) -> Int {
        let count = glyphRange.length
        guard count > 0 else { return 0 }
        let first = charIndexes[0]
        let last = charIndexes[count - 1]
        let hidden = MainActor.assumeIsolated { self.hiddenRanges(in: NSRange(location: first, length: last - first + 1)) }
        guard !hidden.isEmpty else { return 0 }
        var properties = [NSLayoutManager.GlyphProperty](unsafeUninitializedCapacity: count) { buffer, initialized in
            for index in 0 ..< count { buffer[index] = props[index] }
            initialized = count
        }
        var changed = false
        var cursor = 0
        for index in 0 ..< count {
            let character = charIndexes[index]
            while cursor < hidden.count, NSMaxRange(hidden[cursor]) <= character { cursor += 1 }
            guard cursor < hidden.count, hidden[cursor].location <= character else { continue }
            // Control glyphs (line endings, tabs) keep their own property; the action delegate
            // below zeroes a hidden tab and keeps every line ending.
            if properties[index].contains(.controlCharacter) { continue }
            // Not `.null`: TextKit moves null glyphs at a line start into the previous line's
            // fragment (the line would then start at its first visible glyph and get the
            // paragraph's head indent). A zero-advance control glyph stays in its own line and
            // is never drawn.
            properties[index] = .controlCharacter
            changed = true
        }
        guard changed else { return 0 }
        properties.withUnsafeBufferPointer { buffer in
            layoutManager.setGlyphs(glyphs, properties: buffer.baseAddress!, characterIndexes: charIndexes, font: aFont,
                                    forGlyphRange: glyphRange)
        }
        return count
    }

    /// Hidden characters (made control glyphs above) take no space; real control characters keep
    /// their action (a line ending must still end its paragraph).
    public nonisolated func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                                          forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = layoutManager.textStorage, charIndex < storage.length else { return action }
        let unit = storage.mutableString.character(at: charIndex)
        switch unit {
        case 0x0A, 0x0D, 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
            return action
        case 0x09:
            let hidden = MainActor.assumeIsolated { self.hiddenRanges(in: NSRange(location: charIndex, length: 1)) }
            return hidden.contains { NSLocationInRange(charIndex, $0) } ? .zeroAdvancement : action
        default:
            return unit < 0x20 || unit == 0x7F ? action : .zeroAdvancement
        }
    }

    public nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                          shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                                          lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
                                          baselineOffset: UnsafeMutablePointer<CGFloat>,
                                          in textContainer: NSTextContainer,
                                          forGlyphRange glyphRange: NSRange) -> Bool {
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.length > 0 else { return false }
        guard let adjustment = MainActor.assumeIsolated({ self.fragmentAdjustment(for: characters) }) else { return false }
        var rect = lineFragmentRect.pointee
        var used = lineFragmentUsedRect.pointee
        rect.size.height = adjustment.height
        used.origin.y = rect.origin.y
        used.size.height = adjustment.height
        lineFragmentRect.pointee = rect
        lineFragmentUsedRect.pointee = used
        baselineOffset.pointee = adjustment.baseline
        return true
    }

    public nonisolated func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?,
                                          atEnd layoutFinishedFlag: Bool) {
        MainActor.assumeIsolated {
            self.needsLayout = true
        }
    }
}

/// How a line fragment is sized: total height and the baseline from its top.
struct FragmentAdjustment: Sendable {
    var height: CGFloat
    var baseline: CGFloat
}

/// The vertical anatomy of one source line in live preview.
struct LineGeometry {
    var hidden = false
    /// The block gap part of the space above (`.nb-doc{gap:10px}`).
    var gap: CGFloat = 0
    /// Margins, rules, borders and padding above the text line.
    var extraTop: CGFloat = 0
    /// The text line box (0 for a figure line off the caret).
    var textHeight: CGFloat = 0
    var font: NSFont
    /// Padding, borders, the title accessory or a figure below the text line.
    var extraBottom: CGFloat = 0
    var lineRange: NSRange
    var blockIndex: Int
    var role: Role = .text

    enum Role: Equatable {
        case text
        case codeOpen, codeInterior, codeClose
        case figure(revealed: Bool)
        case title
    }

    var top: CGFloat { gap + extraTop }
}

extension MarkdownEditorView {
    /// The fragment covering `characters`: its height and baseline (nil = AppKit's own).
    func fragmentAdjustment(for characters: NSRange) -> FragmentAdjustment? {
        guard let geometry = lineGeometry(at: characters.location) else { return nil }
        if geometry.hidden { return FragmentAdjustment(height: 0, baseline: 0) }
        let (isFirst, isLast) = fragmentPosition(characters, in: geometry)
        let top = isFirst ? geometry.top : 0
        let bottom = isLast ? geometry.extraBottom : 0
        let baseline = top + Self.centeredBaseline(lineHeight: geometry.textHeight, font: geometry.font)
        return FragmentAdjustment(height: top + geometry.textHeight + bottom, baseline: baseline)
    }

    /// Whether a fragment is its line's first and last. TextKit attaches the null glyphs of a
    /// hidden line prefix (`## `, `- `) to the previous line's fragment, so a line's first fragment
    /// may start at its first visible character rather than at the line start.
    func fragmentPosition(_ characters: NSRange, in geometry: LineGeometry) -> (isFirst: Bool, isLast: Bool) {
        let isFirst = characters.location <= firstVisibleCharacter(in: geometry.lineRange)
        let isLast = NSMaxRange(characters) >= NSMaxRange(geometry.lineRange)
        return (isFirst, isLast)
    }

    /// The first character of `line` whose glyph is not hidden (the line end when all are).
    func firstVisibleCharacter(in line: NSRange) -> Int {
        var position = line.location
        guard appliedMode == .livePreview else { return position }
        for range in hiddenRanges(in: line) {
            if range.location > position { break }
            position = max(position, NSMaxRange(range))
        }
        return min(position, NSMaxRange(line))
    }

    /// CSS half-leading: the font's ascent + descent centered in the line box, negative leading
    /// included (Space Mono is taller than its 1.3 / 1.4 line heights).
    static func centeredBaseline(lineHeight: CGFloat, font: NSFont) -> CGFloat {
        let ascender = font.ascender
        let descender = -font.descender
        let natural = ascender + descender
        return (lineHeight - natural) / 2 + ascender
    }

    /// The line containing `location` and how it is laid out (nil past the end).
    func lineGeometry(at location: Int) -> LineGeometry? {
        guard let index = MarkdownBlockParser.blockIndex(containing: location, in: blocks) else { return nil }
        return lineGeometry(blockIndex: index, at: location)
    }

    func lineGeometry(blockIndex index: Int, at location: Int) -> LineGeometry {
        let block = blocks[index]
        let lineRange = self.lineRange(at: location, in: block)
        let (height, font) = styler.line(for: block.kind)
        var geometry = LineGeometry(textHeight: height, font: font, lineRange: lineRange, blockIndex: index)
        guard appliedMode == .livePreview else { return geometry }
        if isBlockHidden(index) {
            geometry.hidden = true
            return geometry
        }
        let revealed = isRevealed(index)
        let isFirstLine = lineRange.location == block.range.location
        if isFirstLine { geometry.gap = gapBefore(index) }
        let hasPrevious = previousVisibleBlock(before: index) != nil
        switch block.kind {
        case let .heading(level):
            if hasPrevious {
                switch level {
                case 1: geometry.extraTop = style.heading2Margin
                case 2: geometry.extraTop = style.heading2Margin + 1 + style.heading2RulePadding
                default: geometry.extraTop = style.minorHeadingMargin
                }
            } else if level == 2 {
                geometry.extraTop = 1 + style.heading2RulePadding
            }
        case .blank:
            // A full body line, caret or not: a blank line that shrank off the caret moved every
            // line below whenever the caret crossed it, and a Return there looked like nothing.
            break
        case .codeFence:
            let open = block.inlineMarks.first ?? NSRange(location: block.range.location, length: 0)
            let close = block.inlineMarks.count > 1 ? block.inlineMarks[1] : nil
            let interiorStart = NSMaxRange(open)
            let interiorEnd = close?.location ?? NSMaxRange(block.range)
            let hasInterior = interiorEnd > interiorStart
            let hideFences = !revealed && hasInterior
            if lineRange.location == open.location {
                geometry.role = .codeOpen
                if hideFences { geometry.hidden = true; return geometry }
            } else if let close, lineRange.location == close.location {
                geometry.role = .codeClose
                if hideFences { geometry.hidden = true; return geometry }
            } else {
                geometry.role = .codeInterior
            }
            let isTop = geometry.role == .codeOpen || (hideFences && lineRange.location == interiorStart)
            let isBottom = geometry.role == .codeClose || (close == nil && NSMaxRange(lineRange) >= NSMaxRange(block.range))
                || (hideFences && NSMaxRange(lineRange) >= interiorEnd)
            if isTop {
                geometry.gap = gapBefore(index)
                geometry.extraTop = 1 + style.codePadding.top
            } else {
                geometry.gap = 0
            }
            if isBottom { geometry.extraBottom = style.codePadding.bottom + 1 }
        case .image:
            if let figure = figureGeometry(forBlock: index) {
                geometry.role = .figure(revealed: revealed)
                if revealed {
                    geometry.extraBottom = style.figureRevealGap + figure.rowHeight
                } else {
                    geometry.textHeight = 0
                    geometry.extraBottom = figure.rowHeight
                }
            }
        default:
            break
        }
        if index == 0, isFirstLine, titleAccessory != nil, !geometry.hidden {
            geometry.role = geometry.role == .text ? .title : geometry.role
            geometry.extraBottom += style.titleAccessoryGap + titleAccessoryHeight()
        }
        return geometry
    }

    /// The source line of `block` holding `location` (blocks of one line return the block).
    func lineRange(at location: Int, in block: MarkdownBlock) -> NSRange {
        switch block.kind {
        case .codeFence, .hiddenFence, .table, .frontmatterLike:
            let line = storage.mutableString.lineRange(for: NSRange(location: location, length: 0))
            return NSIntersectionRange(line, block.range).length > 0 ? NSIntersectionRange(line, block.range) : block.range
        default:
            return block.range
        }
    }

    // MARK: Visibility

    /// Hidden as a whole: a `codd-annotations` fence after an image, a folded section.
    func isBlockHidden(_ index: Int) -> Bool {
        guard appliedMode == .livePreview, index >= 0, index < blocks.count else { return false }
        if case .hiddenFence = blocks[index].kind { return true }
        guard !foldedSections.isEmpty else { return false }
        let location = blocks[index].range.location
        return foldedSections.contains { NSLocationInRange(location, $0) }
    }

    func isRevealed(_ index: Int) -> Bool {
        guard let revealedRange, index < blocks.count else { return false }
        let range = blocks[index].range
        return NSIntersectionRange(range, revealedRange).length > 0
            || (revealedRange.length == 0 && NSLocationInRange(revealedRange.location, range))
    }

    func previousVisibleBlock(before index: Int) -> Int? {
        var cursor = index - 1
        while cursor >= 0 {
            if !isBlockHidden(cursor) { return cursor }
            cursor -= 1
        }
        return nil
    }

    private enum Group: Equatable {
        case unique(Int), paragraph, list, quote, table, blank
    }

    private func group(of index: Int) -> Group {
        switch blocks[index].kind {
        case .paragraph: .paragraph
        case .bullet, .ordered, .task: .list
        case .quote: .quote
        case .table: .table
        case .blank: .blank
        default: .unique(index)
        }
    }

    /// The block gap above a block: none after a blank line or inside one group (list items,
    /// paragraph lines, quote lines), else `blockGap`.
    func gapBefore(_ index: Int) -> CGFloat {
        if case .blank = blocks[index].kind { return 0 }
        guard let previous = previousVisibleBlock(before: index) else { return 0 }
        let previousGroup = group(of: previous)
        if previousGroup == .blank { return 0 }
        if previousGroup == group(of: index) { return 0 }
        return style.blockGap
    }

    /// Ranges whose glyphs are hidden (live preview), sorted.
    func hiddenRanges(in characters: NSRange) -> [NSRange] {
        guard appliedMode == .livePreview, !blocks.isEmpty else { return [] }
        var result: [NSRange] = []
        var index = MarkdownBlockParser.blockIndex(containing: characters.location, in: blocks)
            ?? MarkdownBlockParser.firstBlockIndex(startingAtOrAfter: characters.location, in: blocks)
        let end = NSMaxRange(characters)
        while index < blocks.count, blocks[index].range.location < end {
            appendHiddenRanges(of: index, to: &result)
            index += 1
        }
        return result
    }

    private func appendHiddenRanges(of index: Int, to result: inout [NSRange]) {
        let block = blocks[index]
        if isBlockHidden(index) {
            result.append(block.range)
            return
        }
        let revealed = isRevealed(index)
        switch block.kind {
        case .heading, .paragraph:
            if !revealed { result.append(contentsOf: block.inlineMarks) }
        case .bullet, .task, .quote, .ordered:
            if revealed {
                if let first = block.inlineMarks.first, first.location == block.range.location { result.append(first) }
            } else {
                result.append(contentsOf: block.inlineMarks)
            }
        case .codeFence:
            if !revealed, block.inlineMarks.count > 0 {
                let interior = MarkdownStyler.codeInterior(of: block)
                if interior.length > 0 { result.append(contentsOf: block.inlineMarks) }
            }
        case .image:
            if !revealed, figureGeometry(forBlock: index) != nil { result.append(block.range) }
        case .rule:
            if !revealed { result.append(block.range) }
        default:
            break
        }
    }

    // MARK: Reveal

    /// The whole blocks the selection touches (nil when the caret is on the empty last line).
    /// The caret paragraph shows its syntax while the editor has focus (or when asked to always).
    var isRevealActive: Bool {
        revealsCaretLineWhenInactive || (textView.window != nil && textView.hasFocus)
    }

    func focusDidChange() {
        updateReveal()
    }

    func revealedRange(for selection: NSRange) -> NSRange? {
        guard appliedMode == .livePreview, !blocks.isEmpty, isRevealActive else { return nil }
        let startIndex = blockIndexForCaret(selection.location)
        let endIndex = blockIndexForCaret(NSMaxRange(selection))
        guard let startIndex else { return endIndex.map { blocks[$0].range } }
        let last = endIndex ?? startIndex
        // A select-all reveals only the caret's block, not the whole document.
        if last - startIndex > 64 { return blocks[last].range }
        return NSUnionRange(blocks[startIndex].range, blocks[last].range)
    }

    /// The block a caret at `location` is in (a caret at the end of an unterminated last line
    /// belongs to that line).
    func blockIndexForCaret(_ location: Int) -> Int? {
        if let index = MarkdownBlockParser.blockIndex(containing: location, in: blocks) { return index }
        guard let last = blocks.indices.last, location == NSMaxRange(blocks[last].range), location > 0,
              storage.mutableString.character(at: location - 1) != Unit.newline
        else { return nil }
        return last
    }

    /// Recomputes what the selection reveals; changed blocks get their glyphs and lines again.
    func updateReveal(force: Bool = false) {
        guard !textView.isComposing else { return }
        let new = revealedRange(for: textView.selectedRange())
        let old = revealedRange
        guard force || new != old else { return }
        revealedRange = new
        for range in [old, new].compactMap({ $0 }) {
            invalidate(characters: range)
        }
        textView.needsDisplay = true
        needsLayout = true
    }

    func invalidate(characters range: NSRange) {
        let length = storage.length
        guard length > 0 else { return }
        let location = min(range.location, length)
        let clamped = NSRange(location: location, length: min(range.length, length - location))
        layoutManagerRef.invalidateGlyphs(forCharacterRange: clamped, changeInLength: 0, actualCharacterRange: nil)
        layoutManagerRef.invalidateLayout(forCharacterRange: clamped, actualCharacterRange: nil)
    }

    func invalidateLayout(of blockIndex: Int) {
        guard blockIndex >= 0, blockIndex < blocks.count else { return }
        invalidate(characters: blocks[blockIndex].range)
    }

    func invalidateEverything() {
        invalidate(characters: NSRange(location: 0, length: storage.length))
        textView.needsDisplay = true
        needsLayout = true
    }

    func invalidateTitleLine() {
        titleAccessoryHeightCache = nil
        if !blocks.isEmpty { invalidateLayout(of: 0) }
        textView.needsDisplay = true
        needsLayout = true
    }

    // MARK: Folding

    /// H2 sections: from the line after the heading to the next heading of level ≤ 2.
    func recomputeFolds() {
        let old = foldedSections
        var valid: [Int] = []
        var sections: [NSRange] = []
        for start in foldedHeadings {
            guard let index = MarkdownBlockParser.blockIndex(containing: start, in: blocks), blocks[index].range.location == start,
                  case .heading(2) = blocks[index].kind
            else { continue }
            valid.append(start)
            let sectionStart = NSMaxRange(blocks[index].range)
            var end = storage.length
            var cursor = index + 1
            while cursor < blocks.count {
                if case let .heading(level) = blocks[cursor].kind, level <= 2 {
                    end = blocks[cursor].range.location
                    break
                }
                cursor += 1
            }
            if end > sectionStart { sections.append(NSRange(location: sectionStart, length: end - sectionStart)) }
        }
        foldedHeadings = valid
        foldedSections = sections
        if old != sections {
            for range in old + sections { invalidate(characters: range) }
            textView.needsDisplay = true
            needsLayout = true
        }
    }

    func isFolded(headingAt index: Int) -> Bool {
        foldedHeadings.contains(blocks[index].range.location)
    }

    func toggleFold(headingAt index: Int) {
        let start = blocks[index].range.location
        if let position = foldedHeadings.firstIndex(of: start) {
            foldedHeadings.remove(at: position)
        } else {
            foldedHeadings.append(start)
            foldedHeadings.sort()
        }
        recomputeFolds()
        // The heading's own line redraws its glyph.
        invalidateLayout(of: index)
        if let snapped = snappedSelection(textView.selectedRange(), previous: textView.selectedRange()) {
            setSelectionProgrammatically(snapped)
        }
    }

    // MARK: Images

    func resetImages(invalidate: Bool = true) {
        imageCache.removeAll()
        accessoryHeights.removeAll()
        for views in accessoryViews.values { views.forEach { $0.removeFromSuperview() } }
        accessoryViews.removeAll()
        if invalidate { invalidateEverything() }
    }

    func imageInfo(for path: String) -> MarkdownImageInfo? {
        if let cached = imageCache[path] { return cached }
        let info = imageResolver?(path)
        imageCache[path] = .some(info)
        return info
    }

    /// The geometry of the figure of image block `index` (nil = unresolved: shown as text).
    func figureGeometry(forBlock index: Int) -> FigureGeometry? {
        guard appliedMode == .livePreview, case let .image(_, path) = blocks[index].kind, let info = imageInfo(for: path),
              info.pixelSize.width > 0, info.pixelSize.height > 0
        else { return nil }
        let width = max(1, container.size.width)
        let hasAccessory = imageAccessoryProvider != nil
        var geometry = FigureGeometry.make(info: info, contentWidth: width, style: style, accessoryHeight: 0, hasAccessory: hasAccessory)
        if hasAccessory, geometry.accessory != nil {
            let height = accessoryHeight(for: info, width: geometry.accessory?.width ?? 0)
            geometry = FigureGeometry.make(info: info, contentWidth: width, style: style, accessoryHeight: height,
                                           hasAccessory: height > 0)
        }
        return geometry
    }

    private func accessoryHeight(for info: MarkdownImageInfo, width: CGFloat) -> CGFloat {
        if let cached = accessoryHeights[info.path], abs(cached.width - width) < 0.5 { return cached.height }
        guard let view = accessoryView(for: info.path, slot: 0, info: info) else {
            accessoryHeights[info.path] = (width, 0)
            return 0
        }
        let height = Self.measure(view, width: width)
        accessoryHeights[info.path] = (width, height)
        return height
    }

    func accessoryView(for path: String, slot: Int, info: MarkdownImageInfo) -> NSView? {
        var views = accessoryViews[path] ?? []
        while views.count <= slot {
            guard let view = imageAccessoryProvider?(info) else { break }
            views.append(view)
        }
        accessoryViews[path] = views
        return slot < views.count ? views[slot] : nil
    }

    func titleAccessoryHeight() -> CGFloat {
        guard let titleAccessory else { return 0 }
        let width = max(1, container.size.width)
        if let cached = titleAccessoryHeightCache, abs(cached.width - width) < 0.5 { return cached.height }
        let height = Self.measure(titleAccessory, width: width)
        titleAccessoryHeightCache = (width, height)
        return height
    }

    /// A view's height at `width`: its Auto Layout fitting height, else its frame height.
    static func measure(_ view: NSView, width: CGFloat) -> CGFloat {
        if let sizing = view as? MarkdownAccessorySizing { return ceil(max(0, sizing.markdownAccessoryHeight(forWidth: width))) }
        let constraint = view.widthAnchor.constraint(equalToConstant: width)
        let translates = view.translatesAutoresizingMaskIntoConstraints
        if !view.constraints.isEmpty || !translates || !view.subviews.isEmpty {
            view.translatesAutoresizingMaskIntoConstraints = false
            constraint.isActive = true
            view.layoutSubtreeIfNeeded()
            let fitting = view.fittingSize.height
            constraint.isActive = false
            view.translatesAutoresizingMaskIntoConstraints = translates
            if fitting > 0 { return ceil(fitting) }
        }
        return ceil(view.frame.height)
    }

    /// The image block at the caret, or the image a hidden fence under the caret belongs to.
    func imageBlockIndex(near location: Int) -> Int? {
        guard let index = blockIndexForCaret(location) else { return nil }
        if case .image = blocks[index].kind { return index }
        if case .hiddenFence = blocks[index].kind, index > 0, case .image = blocks[index - 1].kind { return index - 1 }
        if case .codeFence = blocks[index].kind, index > 0, case .image = blocks[index - 1].kind { return index - 1 }
        return nil
    }

    // MARK: Accessories

    /// Places the title accessory under line 1 and the figure accessories of the visible figures.
    func layoutAccessories() {
        let origin = textView.textContainerOrigin
        if let titleAccessory {
            if appliedMode == .livePreview, !blocks.isEmpty, let rect = titleAccessoryFrame() {
                if titleAccessory.superview !== textView { textView.addSubview(titleAccessory) }
                titleAccessory.translatesAutoresizingMaskIntoConstraints = true
                titleAccessory.frame = rect.offsetBy(dx: origin.x, dy: origin.y)
                titleAccessory.isHidden = false
            } else {
                titleAccessory.isHidden = true
            }
        }
        guard imageAccessoryProvider != nil else { return }
        var used: [String: Int] = [:]
        if appliedMode == .livePreview, !blocks.isEmpty {
            let visible = textView.visibleRect.insetBy(dx: 0, dy: -400).offsetBy(dx: -origin.x, dy: -origin.y)
            let glyphs = layoutManagerRef.glyphRange(forBoundingRectWithoutAdditionalLayout: visible, in: container)
            let characters = layoutManagerRef.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            var index = MarkdownBlockParser.blockIndex(containing: characters.location, in: blocks)
                ?? MarkdownBlockParser.firstBlockIndex(startingAtOrAfter: characters.location, in: blocks)
            while index < blocks.count, blocks[index].range.location <= NSMaxRange(characters) {
                defer { index += 1 }
                guard case let .image(_, path) = blocks[index].kind, !isBlockHidden(index),
                      let info = imageInfo(for: path), let frame = figureFrames(forBlock: index)?.accessory
                else { continue }
                let slot = used[path, default: 0]
                used[path] = slot + 1
                guard let view = accessoryView(for: path, slot: slot, info: info) else { continue }
                if view.superview !== textView { textView.addSubview(view) }
                view.translatesAutoresizingMaskIntoConstraints = true
                view.frame = frame.offsetBy(dx: origin.x, dy: origin.y)
                view.isHidden = false
            }
        }
        for (path, views) in accessoryViews {
            let keep = used[path, default: 0]
            for (slot, view) in views.enumerated() where slot >= keep {
                view.removeFromSuperview()
            }
        }
    }

    /// The title accessory's frame in container coordinates.
    func titleAccessoryFrame() -> NSRect? {
        guard !blocks.isEmpty, let fragment = lastFragment(ofLine: lineRange(at: 0, in: blocks[0])) else { return nil }
        let height = titleAccessoryHeight()
        return NSRect(x: 0, y: fragment.maxY - height, width: container.size.width, height: height)
    }

    /// The last line fragment rect (container coordinates) of a source line.
    func lastFragment(ofLine line: NSRange) -> NSRect? {
        guard line.length > 0 || storage.length == 0 else { return nil }
        let lastCharacter = max(line.location, NSMaxRange(line) - 1)
        guard lastCharacter < storage.length else { return nil }
        let glyph = layoutManagerRef.glyphIndexForCharacter(at: lastCharacter)
        return layoutManagerRef.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// The first line fragment rect (container coordinates) of a source line.
    func firstFragment(ofLine line: NSRange) -> NSRect? {
        guard line.location < storage.length else { return nil }
        let glyph = layoutManagerRef.glyphIndexForCharacter(at: line.location)
        return layoutManagerRef.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    /// Plate, image, caption and accessory of a figure in container coordinates.
    func figureFrames(forBlock index: Int) -> FigureGeometry? {
        guard var geometry = figureGeometry(forBlock: index), let fragment = lastFragment(ofLine: blocks[index].range) else { return nil }
        let rowTop = fragment.maxY - geometry.rowHeight
        geometry.translate(x: fragment.minX, y: rowTop)
        return geometry
    }
}
