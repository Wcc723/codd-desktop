import AppKit
import UniformTypeIdentifiers

extension MarkdownEditorView {
    // MARK: Commands (called by the text view after its marked-text checks)

    /// Return: a new item after a list / task / quote line (an empty item ends the list), the
    /// line's indentation inside a code block, else a plain LF.
    func insertNewlineContinuingBlock() {
        let selection = textView.selectedRange()
        guard let index = blockIndexForCaret(selection.location) else {
            textView.insertPlainNewline()
            return
        }
        let block = blocks[index]
        let all = storage.mutableString
        let window = UTF16Window(all, from: block.range.location, prefetchAll: false)
        let lineEnd = MarkdownStyler.lineContentEnd(of: block.range, window: window)
        switch block.kind {
        case .bullet, .task, .ordered, .quote:
            let content = MarkdownStyler.contentRange(of: block, window: window)
            var itemText = content
            if case .task = block.kind, let prefix = block.inlineMarks.first {
                let afterBox = NSMaxRange(prefix) + 3
                itemText = NSRange(location: afterBox, length: max(0, lineEnd - afterBox))
            }
            if case .ordered = block.kind {
                var cursor = content.location
                while cursor < lineEnd, Unit.isDigit(window[cursor]) { cursor += 1 }
                cursor += 1
                itemText = NSRange(location: min(cursor, lineEnd), length: max(0, lineEnd - cursor))
            }
            let isEmpty = (all.substring(with: itemText) as String).trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty, selection.length == 0, selection.location >= itemText.location {
                // An empty item ends the list: the marker goes, the line stays as an empty line.
                performEdit(NSRange(location: block.range.location, length: lineEnd - block.range.location), with: "",
                            actionName: nil, selectionAfter: NSRange(location: block.range.location, length: 0))
                return
            }
            if selection.location < content.location {
                textView.insertPlainNewline()
                return
            }
            textView.insertText("\n" + continuation(of: block, window: window), replacementRange: NSRange(location: NSNotFound, length: 0))
        case .codeFence:
            let interior = MarkdownStyler.codeInterior(of: block)
            guard NSLocationInRange(selection.location, interior) || selection.location == NSMaxRange(interior) else {
                textView.insertPlainNewline()
                return
            }
            let line = all.lineRange(for: NSRange(location: selection.location, length: 0))
            var cursor = line.location
            while cursor < selection.location, Unit.isSpace(all.character(at: cursor)) { cursor += 1 }
            let indent = all.substring(with: NSRange(location: line.location, length: cursor - line.location))
            textView.insertText("\n" + indent, replacementRange: NSRange(location: NSNotFound, length: 0))
        default:
            textView.insertPlainNewline()
        }
    }

    /// The prefix of the next item: same indentation and marker, `n + 1.` for ordered items, an
    /// open box for tasks.
    private func continuation(of block: MarkdownBlock, window: UTF16Window) -> String {
        var cursor = block.range.location
        while Unit.isSpace(window[cursor]) { cursor += 1 }
        let indent = cursor > block.range.location ? window.string(NSRange(location: block.range.location, length: cursor - block.range.location)) : ""
        switch block.kind {
        case .bullet:
            return indent + String(UnicodeScalar(UInt8(window[cursor]))) + " "
        case .task:
            return indent + String(UnicodeScalar(UInt8(window[cursor]))) + " [ ] "
        case let .ordered(_, number):
            var end = cursor
            while Unit.isDigit(window[end]) { end += 1 }
            let delimiter = String(UnicodeScalar(UInt8(window[end])))
            return indent + "\(number + 1)" + delimiter + " "
        case .quote:
            return indent + "> "
        default:
            return ""
        }
    }

    /// Tab / ⇧Tab on list lines: two spaces in or out at each touched list line, one undo step.
    /// False when no touched line is a list item (Tab then inserts a tab).
    func indentListLines(outdent: Bool) -> Bool {
        let selection = textView.selectedRange()
        guard let first = blockIndexForCaret(selection.location) else { return outdent }
        let last = blockIndexForCaret(max(selection.location, NSMaxRange(selection) - (selection.length > 0 ? 1 : 0))) ?? first
        let lines = (first ... max(first, last)).filter { index in
            switch blocks[index].kind {
            case .bullet, .ordered, .task: true
            default: false
            }
        }
        guard !lines.isEmpty else { return outdent }
        let all = storage.mutableString
        var edits: [(NSRange, String)] = []
        for index in lines {
            let start = blocks[index].range.location
            if outdent {
                var remove = 0
                if start < all.length, all.character(at: start) == Unit.tab {
                    remove = 1
                } else {
                    while remove < 2, start + remove < all.length, all.character(at: start + remove) == Unit.space { remove += 1 }
                }
                if remove > 0 { edits.append((NSRange(location: start, length: remove), "")) }
            } else {
                edits.append((NSRange(location: start, length: 0), "  "))
            }
        }
        guard !edits.isEmpty else { return true }
        var newStart = selection.location
        var newEnd = NSMaxRange(selection)
        for (range, replacement) in edits {
            let delta = (replacement as NSString).length - range.length
            if range.location < selection.location { newStart = max(range.location, newStart + delta) }
            if range.location < NSMaxRange(selection) || (range.location == NSMaxRange(selection) && selection.length == 0) {
                newEnd = max(range.location, newEnd + delta)
            }
        }
        if selection.length == 0 { newStart = newEnd }
        let undo = textView.ownUndoManager
        undo.beginUndoGrouping()
        for (range, replacement) in edits.reversed() {
            performEdit(range, with: replacement, actionName: nil, selectionAfter: nil)
        }
        undo.endUndoGrouping()
        undo.setActionName(outdent ? "減少縮排" : "增加縮排")
        textView.setSelectedRange(NSRange(location: newStart, length: max(0, newEnd - newStart)))
        return true
    }

    /// Backspace at the start of a list / task / quote item's text (live preview, where the
    /// marker is hidden): the marker goes, the text stays.
    func deleteListPrefixIfAtContentStart() -> Bool {
        let selection = textView.selectedRange()
        guard appliedMode == .livePreview, selection.length == 0, let index = blockIndexForCaret(selection.location) else { return false }
        let block = blocks[index]
        guard let prefix = block.inlineMarks.first, prefix.location == block.range.location else { return false }
        var contentStart = NSMaxRange(prefix)
        switch block.kind {
        case .bullet, .quote:
            break
        case .task:
            contentStart += 3
            let all = storage.mutableString
            while contentStart < NSMaxRange(block.range), Unit.isSpace(all.character(at: contentStart)) { contentStart += 1 }
        default:
            return false
        }
        guard selection.location == contentStart else { return false }
        return performEdit(NSRange(location: block.range.location, length: contentStart - block.range.location), with: "",
                           actionName: nil, selectionAfter: NSRange(location: block.range.location, length: 0))
    }

    /// ⌘B / ⌘I: wraps the selection in `marker` (or unwraps it when it already is), one undo step.
    func wrapSelection(with marker: String) {
        let selection = textView.selectedRange()
        let all = storage.mutableString
        let length = (marker as NSString).length
        let name = marker == "**" ? "粗體" : "斜體"
        if selection.length == 0 {
            performEdit(selection, with: marker + marker, actionName: name,
                        selectionAfter: NSRange(location: selection.location + length, length: 0))
            return
        }
        let before = NSRange(location: selection.location - length, length: length)
        let after = NSRange(location: NSMaxRange(selection), length: length)
        if before.location >= 0, NSMaxRange(after) <= all.length, all.substring(with: before) == marker, all.substring(with: after) == marker,
           !(length == 1 && isDoubled(before: before, after: after, in: all)) {
            let inner = all.substring(with: selection)
            performEdit(NSRange(location: before.location, length: selection.length + 2 * length), with: inner, actionName: name,
                        selectionAfter: NSRange(location: before.location, length: selection.length))
            return
        }
        let inner = all.substring(with: selection)
        performEdit(selection, with: marker + inner + marker, actionName: name,
                    selectionAfter: NSRange(location: selection.location + length, length: selection.length))
    }

    /// `*` next to `**` is bold, not italic.
    private func isDoubled(before: NSRange, after: NSRange, in all: NSMutableString) -> Bool {
        (before.location > 0 && all.character(at: before.location - 1) == Unit.star)
            || (NSMaxRange(after) < all.length && all.character(at: NSMaxRange(after)) == Unit.star)
    }

    /// Toggles `[ ]` ↔ `[x]` of task block `index`: one undoable edit, selection kept.
    func toggleTask(at index: Int) {
        guard index < blocks.count, case let .task(_, done) = blocks[index].kind, let prefix = blocks[index].inlineMarks.first else { return }
        let check = NSRange(location: NSMaxRange(prefix) + 1, length: 1)
        performEdit(check, with: done ? " " : "x", actionName: "切換待辦", selectionAfter: textView.selectedRange())
    }

    @discardableResult
    func commandReturn() -> Bool {
        guard !textView.isComposing, let onCommandReturn else { return false }
        onCommandReturn()
        return true
    }

    func editImageAnnotationsAtCaret() -> Bool {
        guard !textView.isComposing, let path = imagePathAtCaret, let onEditImageAnnotations else { return false }
        onEditImageAnnotations(path)
        return true
    }

    // MARK: Paste

    static let imagePasteboardTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, UTType.png.identifier),
        (.tiff, UTType.tiff.identifier),
        (NSPasteboard.PasteboardType(UTType.jpeg.identifier), UTType.jpeg.identifier),
        (NSPasteboard.PasteboardType(UTType.heic.identifier), UTType.heic.identifier),
        (NSPasteboard.PasteboardType(UTType.gif.identifier), UTType.gif.identifier),
        (NSPasteboard.PasteboardType(UTType.webP.identifier), UTType.webP.identifier),
    ]

    /// The user's paste or drop: image files and image data go to `onPasteImage`; rich text is
    /// inserted as its plain text; other files as their paths. Reads only `pasteboard`.
    @discardableResult
    func insertContents(of pasteboard: NSPasteboard) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !urls.isEmpty {
            let images = urls.filter { url in UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false }
            if !images.isEmpty, let onPasteImage {
                var handled = false
                for url in images {
                    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                    let type = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.image.identifier
                    pasteGeneration = generation
                    if onPasteImage(MarkdownPastedImage(data: data, typeIdentifier: type, suggestedName: url.lastPathComponent, fileURL: url)) {
                        handled = true
                    }
                }
                if handled { return true }
                pasteGeneration = nil
            }
            insertPlainText(urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n"))
            return true
        }
        let types = pasteboard.types ?? []
        let rich = types.contains(.rtf) || types.contains(.rtfd) || types.contains(.html)
        if rich, let string = pasteboard.string(forType: .string), !string.isEmpty {
            insertPlainText(string)
            return true
        }
        if let image = Self.image(from: pasteboard) {
            pasteGeneration = generation
            if onPasteImage?(image) == true { return true }
            pasteGeneration = nil
        }
        if let string = pasteboard.string(forType: .string) {
            insertPlainText(string)
            return true
        }
        return false
    }

    static func image(from pasteboard: NSPasteboard) -> MarkdownPastedImage? {
        for (type, identifier) in imagePasteboardTypes {
            if let data = pasteboard.data(forType: type), !data.isEmpty {
                return MarkdownPastedImage(data: data, typeIdentifier: identifier)
            }
        }
        return nil
    }

    /// One undo step, like a typed paste; line endings become LF.
    func insertPlainText(_ text: String) {
        let normalized = MarkdownTextView.normalizingLineEndings(text)
        guard !normalized.isEmpty else { return }
        textView.breakUndoCoalescing()
        textView.insertText(normalized, replacementRange: NSRange(location: NSNotFound, length: 0))
        textView.breakUndoCoalescing()
    }

    // MARK: Clicks

    /// Live preview: a fold glyph folds, a task box toggles, a link opens (off the caret's line), a
    /// double click on a figure edits its annotations. Source mode: ⌘-click opens a link. True when
    /// the click was taken (AppKit then does not move the caret).
    func handleClick(at point: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard !blocks.isEmpty, !textView.isComposing else { return false }
        let origin = textView.textContainerOrigin
        let p = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        if appliedMode == .source {
            guard modifiers.contains(.command), let (_, url) = link(at: p) else { return false }
            onOpenLink?(url)
            return onOpenLink != nil
        }
        if let index = foldHit(at: p) {
            toggleFold(headingAt: index)
            return true
        }
        if let index = figureHit(at: p) {
            if clickCount >= 2, case let .image(_, path) = blocks[index].kind, let onEditImageAnnotations {
                onEditImageAnnotations(path)
                return true
            }
            return false
        }
        if let index = taskBoxHit(at: p) {
            toggleTask(at: index)
            return true
        }
        if let (index, url) = link(at: p), !isRevealed(index), let onOpenLink {
            onOpenLink(url)
            return true
        }
        return false
    }

    /// The character whose glyph is under `p` (container coordinates), only when the point is on it.
    private func character(at p: CGPoint) -> Int? {
        guard storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let glyph = layoutManagerRef.glyphIndex(for: p, in: container, fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManagerRef.numberOfGlyphs else { return nil }
        let bounds = layoutManagerRef.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard bounds.width > 0, p.x >= bounds.minX - 1, p.x <= bounds.maxX + 1 else { return nil }
        let character = layoutManagerRef.characterIndexForGlyph(at: glyph)
        // Only on the text line, not in the spacing or figure sharing its fragment.
        guard let line = textLineRect(forCharacterAt: character) else { return nil }
        let origin = textView.textContainerOrigin
        let box = line.offsetBy(dx: -origin.x, dy: -origin.y)
        guard p.y >= box.minY, p.y <= box.maxY else { return nil }
        return character
    }

    private func link(at p: CGPoint) -> (Int, String)? {
        guard let character = character(at: p), let url = storage.attribute(.coddLink, at: character, effectiveRange: nil) as? String,
              let index = MarkdownBlockParser.blockIndex(containing: character, in: blocks)
        else { return nil }
        return (index, url)
    }

    private func taskBoxHit(at p: CGPoint) -> Int? {
        guard let character = character(at: p), storage.attribute(.coddTaskBox, at: character, effectiveRange: nil) != nil else { return nil }
        return MarkdownBlockParser.blockIndex(containing: character, in: blocks)
    }

    /// The H2 whose fold glyph (in the left padding) is under `p`.
    private func foldHit(at p: CGPoint) -> Int? {
        guard p.x < 0, p.x >= -(style.foldGlyphOffset + 8) else { return nil }
        let glyph = layoutManagerRef.glyphIndex(for: CGPoint(x: 0, y: p.y), in: container)
        guard glyph < layoutManagerRef.numberOfGlyphs else { return nil }
        let character = layoutManagerRef.characterIndexForGlyph(at: glyph)
        guard let index = MarkdownBlockParser.blockIndex(containing: character, in: blocks), case .heading(2) = blocks[index].kind,
              let line = textLineRect(forCharacterAt: blocks[index].range.location)
        else { return nil }
        let origin = textView.textContainerOrigin
        let box = line.offsetBy(dx: -origin.x, dy: -origin.y)
        return (box.minY ... box.maxY).contains(p.y) ? index : nil
    }

    private func figureHit(at p: CGPoint) -> Int? {
        let glyph = layoutManagerRef.glyphIndex(for: CGPoint(x: 0, y: p.y), in: container)
        guard glyph < layoutManagerRef.numberOfGlyphs else { return nil }
        let character = layoutManagerRef.characterIndexForGlyph(at: glyph)
        guard let index = MarkdownBlockParser.blockIndex(containing: character, in: blocks), case .image = blocks[index].kind,
              let frames = figureFrames(forBlock: index)
        else { return nil }
        return frames.plate.insetBy(dx: -style.figureRingWidth, dy: -style.figureRingWidth).contains(p) ? index : nil
    }

    // MARK: Selection

    /// Live preview: a caret never rests inside hidden text: a hidden fence or folded section is
    /// skipped in the direction of travel, a list marker's hidden prefix moves it to the item text.
    func snappedSelection(_ selection: NSRange, previous: NSRange) -> NSRange? {
        guard appliedMode == .livePreview, selection.length == 0, !blocks.isEmpty else { return nil }
        let location = selection.location
        guard let index = blockIndexForCaret(location) else { return nil }
        let forward = location >= previous.location
        if isBlockHidden(index) {
            return NSRange(location: escapeHidden(from: index, forward: forward), length: 0)
        }
        let block = blocks[index]
        guard let prefix = block.inlineMarks.first, prefix.location == block.range.location, prefix.length > 0 else { return nil }
        switch block.kind {
        case .bullet, .quote, .task, .ordered:
            break
        default:
            return nil
        }
        let prefixEnd = NSMaxRange(prefix)
        // Only a caret inside the hidden prefix moves; the task box is visible text.
        guard location < prefixEnd else { return nil }
        var contentStart = prefixEnd
        if case .task = block.kind {
            let all = storage.mutableString
            contentStart = min(NSMaxRange(block.range), contentStart + 3)
            while contentStart < NSMaxRange(block.range), Unit.isSpace(all.character(at: contentStart)) { contentStart += 1 }
        }
        // ← from the item text goes on to the end of the line above.
        if !forward, block.range.location > 0, previous.location >= block.range.location, previous.location <= contentStart {
            return NSRange(location: endOfPreviousLine(block.range.location), length: 0)
        }
        return location == contentStart ? nil : NSRange(location: contentStart, length: 0)
    }

    private func escapeHidden(from index: Int, forward: Bool) -> Int {
        var cursor = index
        if forward {
            while cursor < blocks.count, isBlockHidden(cursor) { cursor += 1 }
            if cursor < blocks.count { return blocks[cursor].range.location }
            // Hidden through the end: land after it when the text ends with a newline, else go back.
            let end = storage.length
            if end > 0, storage.mutableString.character(at: end - 1) == Unit.newline { return end }
        }
        cursor = index
        while cursor >= 0, isBlockHidden(cursor) { cursor -= 1 }
        guard cursor >= 0 else { return blocks[index].range.location }
        return endOfPreviousLine(blocks[cursor + 1].range.location)
    }

    /// The caret position at the end of the line before `lineStart` (before its line ending).
    private func endOfPreviousLine(_ lineStart: Int) -> Int {
        let all = storage.mutableString
        var position = max(0, lineStart - 1)
        if position > 0, all.character(at: position) == Unit.newline, all.character(at: position - 1) == Unit.carriageReturn { position -= 1 }
        return position
    }

    func selectionDidChange(stillSelecting: Bool) {
        if !programmaticSelection { hasUserCaret = true }
        guard !textView.isComposing else { return }
        updateReveal()
        textView.typingAttributes = typingAttributes(at: textView.selectedRange().location)
        if !stillSelecting { reportCaret() }
    }

    func typingAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        if let index = blockIndexForCaret(location) {
            switch blocks[index].kind {
            case .image, .rule, .blank: return styler.base(for: .paragraph)
            default: return styler.base(for: blocks[index].kind)
            }
        }
        return styler.base(for: .paragraph)
    }

    func reportCaret() {
        guard let onCaretChange else { return }
        let selection = textView.selectedRange()
        let (line, column) = lineAndColumn(at: selection.location)
        onCaretChange(MarkdownCaret(line: line, column: column, selectionLength: selection.length))
    }

    /// 1-based line and column (grapheme clusters) of `location`.
    func lineAndColumn(at location: Int) -> (Int, Int) {
        let all = storage.mutableString
        let clamped = min(max(0, location), all.length)
        let index = MarkdownBlockParser.blockIndex(containing: clamped, in: blocks) ?? blocks.count
        var lines = 0
        for block in blocks[0 ..< index] {
            lines += lineCount(of: block, in: all)
        }
        var lineStart = index < blocks.count ? blocks[index].range.location : all.length
        if index < blocks.count {
            switch blocks[index].kind {
            case .codeFence, .hiddenFence, .table, .frontmatterLike:
                var cursor = lineStart
                while cursor < clamped {
                    if all.character(at: cursor) == Unit.newline {
                        lines += 1
                        lineStart = cursor + 1
                    }
                    cursor += 1
                }
            default:
                break
            }
        } else if index == blocks.count, let last = blocks.last, all.length > 0, all.character(at: all.length - 1) != Unit.newline {
            // The caret at the end of an unterminated last line is on that line.
            lines -= 1
            lineStart = last.range.location
        }
        let prefix = all.substring(with: NSRange(location: lineStart, length: max(0, clamped - lineStart)))
        return (lines + 1, prefix.count + 1)
    }

    private func lineCount(of block: MarkdownBlock, in all: NSMutableString) -> Int {
        switch block.kind {
        case .codeFence, .hiddenFence, .table, .frontmatterLike:
            var count = 0
            var cursor = block.range.location
            let end = NSMaxRange(block.range)
            while cursor < end {
                if all.character(at: cursor) == Unit.newline { count += 1 }
                cursor += 1
            }
            if end > block.range.location, all.character(at: end - 1) != Unit.newline { count += 1 }
            return count
        default:
            return 1
        }
    }
}
