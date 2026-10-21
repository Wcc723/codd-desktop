import AppKit

extension CodeEditorView {
    // MARK: Find widget

    /// Shows the find widget (`replace`: with the replace row) and focuses its field. `query` nil:
    /// a single-line selection seeds it, else the last query stays.
    public func showFind(replace: Bool, query: String?) {
        let seed: String?
        if let query {
            seed = query
        } else {
            let selection = textView.selectedRange()
            let selected = selection.length > 0 ? storage.mutableString.substring(with: selection) : ""
            seed = !selected.isEmpty && !selected.contains("\n") && selection.length <= 200 ? selected : nil
        }
        findVisible = true
        findWidget.isHidden = false
        findWidget.replaceVisible = replace && !readOnly
        if let seed { findWidget.queryField.setText(seed) }
        caretMovedSinceFind = false
        layoutFindWidget()
        runFind(resetCurrent: true, reveal: true)
        if let window {
            window.makeFirstResponder(findWidget.queryField)
            // Typing replaces the query (VS Code); an inactive window would show a gray selection.
            if let editor = findWidget.queryField.currentEditor() {
                if window.isKeyWindow { editor.selectAll(nil) } else { editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0) }
            }
        }
    }

    /// Hides the widget and its hits; focus returns to the text when it was in the widget.
    public func hideFind() {
        guard findVisible else { return }
        // Before hiding: hiding the widget makes the window resign its field editor.
        let hadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: findWidget) == true
            || ((window?.firstResponder as? NSText)?.delegate as? NSView)?.isDescendant(of: findWidget) == true
        findVisible = false
        findWidget.isHidden = true
        setCurrentHit(nil)
        findMatches = []
        findCurrent = nil
        if hadFocus { window?.makeFirstResponder(textView) }
        textView.needsDisplay = true
        ruler.needsDisplay = true
    }

    /// The widget's options (`Aa`, `ab`, `.*`); setting them searches again when it shows.
    public var findOptions: FindOptions {
        get { findWidget.options }
        set {
            findWidget.options = newValue
            if findVisible { runFind(resetCurrent: true, reveal: true) }
        }
    }

    /// The query field's text.
    public var findQuery: String { findWidget.query }

    /// ⌘G / Return: the next match (after the current one, or after the caret once it moved).
    public func findNext() {
        step(forward: true)
    }

    /// ⇧⌘G / ⇧Return.
    public func findPrevious() {
        step(forward: false)
    }

    func setReplaceVisible(_ visible: Bool) {
        findWidget.replaceVisible = visible && !readOnly
        layoutFindWidget()
        if visible, let window { window.makeFirstResponder(findWidget.replaceField) }
    }

    func findQueryChanged() {
        guard findVisible, !findWidget.queryField.isComposing else { return }
        runFind(resetCurrent: true, reveal: true)
    }

    func findOptionsChanged() {
        runFind(resetCurrent: true, reveal: true)
    }

    /// Searches the whole text. `resetCurrent`: the current match becomes the first one at or
    /// after the caret; else the one nearest the previous current match.
    func runFind(resetCurrent: Bool, reveal: Bool) {
        guard findVisible else { return }
        let query = findWidget.query
        let options = findWidget.options
        let previous = findCurrent.flatMap { $0 < findMatches.count ? findMatches[$0] : nil }
        do {
            findMatches = try FindEngine.matches(in: storage.mutableString, query: query, options: options)
            findInvalid = false
        } catch {
            findMatches = []
            findInvalid = true
        }
        if findMatches.isEmpty {
            findCurrent = nil
        } else if resetCurrent || previous == nil {
            let caret = textView.selectedRange().location
            findCurrent = findMatches.firstIndex(where: { $0.location >= caret }) ?? 0
        } else if let previous {
            findCurrent = min(firstMatch(endingAfter: previous.location), findMatches.count - 1)
        }
        updateFindDisplay()
        if reveal, let findCurrent { revealMatch(findMatches[findCurrent]) }
    }

    func updateFindDisplay() {
        let query = findWidget.query
        findWidget.isInvalid = findInvalid
        if findInvalid {
            findWidget.countText = "—"
        } else if query.isEmpty {
            findWidget.countText = ""
        } else {
            findWidget.countText = "\(findCurrent.map { $0 + 1 } ?? 0)/\(findMatches.count)"
        }
        layoutFindWidget()
        setCurrentHit(findCurrent.map { findMatches[$0] })
        textView.needsDisplay = true
        ruler.needsDisplay = true
        onFindChange?(query, findWidget.options, findCurrent.map { $0 + 1 } ?? 0, findInvalid ? -1 : findMatches.count)
    }

    private func step(forward: Bool) {
        guard findVisible else { return }
        if findMatches.isEmpty { runFind(resetCurrent: true, reveal: false) }
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        var index: Int
        if let current = findCurrent, !caretMovedSinceFind {
            index = forward ? (current + 1) % count : (current - 1 + count) % count
        } else {
            let selection = textView.selectedRange()
            if forward {
                index = findMatches.firstIndex(where: { $0.location >= NSMaxRange(selection) && $0 != selection }) ?? 0
            } else {
                index = findMatches.lastIndex(where: { NSMaxRange($0) <= selection.location && $0 != selection }) ?? count - 1
            }
        }
        index = max(0, min(index, count - 1))
        findCurrent = index
        navigatingFind = true
        textView.setSelectedRange(findMatches[index])
        navigatingFind = false
        caretMovedSinceFind = false
        updateFindDisplay()
        revealMatch(findMatches[index])
    }

    private func revealMatch(_ range: NSRange) {
        let line = geometry.lines.line(containing: range.location)
        scrollLineIntoView(line)
    }

    /// The current match's text color (black on solid amber); the previous one gets its colors back.
    func setCurrentHit(_ range: NSRange?) {
        guard range != currentHitRange else { return }
        let manager = layoutManagerImpl
        let length = storage.length
        if let old = currentHitRange, NSMaxRange(old) <= length {
            manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: old)
            if highlightLanguage != .plain {
                let first = geometry.lines.line(containing: old.location)
                let last = geometry.lines.line(containing: max(old.location, NSMaxRange(old) - 1))
                highlight.uncolor(first ..< last + 1)
            }
        }
        currentHitRange = range
        if let range, NSMaxRange(range) <= length {
            manager.addTemporaryAttribute(.foregroundColor, value: style.currentHitText, forCharacterRange: range)
        }
        ensureHighlight()
    }

    func scheduleFindRefresh() {
        guard !findRefreshScheduled else { return }
        findRefreshScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.findRefreshScheduled else { return }
                self.findRefreshScheduled = false
                guard !self.textView.hasMarkedText() else { return }
                self.runFind(resetCurrent: false, reveal: false)
            }
        }
    }

    /// Hits follow edits until the search runs again (those the edit touched are dropped).
    func shiftHits(editedRange: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(editedRange) - delta
        if let hit = currentHitRange {
            if hit.location >= oldEnd {
                currentHitRange = NSRange(location: hit.location + delta, length: hit.length)
            } else if NSMaxRange(hit) > editedRange.location {
                currentHitRange = nil
            }
        }
        guard !findMatches.isEmpty else { return }
        let current = findCurrent.map { findMatches[$0] }
        var kept: [NSRange] = []
        kept.reserveCapacity(findMatches.count)
        for match in findMatches {
            if NSMaxRange(match) <= editedRange.location {
                kept.append(match)
            } else if match.location >= oldEnd {
                kept.append(NSRange(location: match.location + delta, length: match.length))
            }
        }
        findMatches = kept
        if let current {
            let shifted = current.location >= oldEnd ? NSRange(location: current.location + delta, length: current.length) : current
            findCurrent = kept.firstIndex(of: shifted)
        }
    }

    // MARK: Replace

    /// `取代`: replaces the current match (one undo step) and moves to the next one.
    func replaceCurrent() {
        guard findVisible, !readOnly, !textView.hasMarkedText() else { return }
        if findMatches.isEmpty { runFind(resetCurrent: true, reveal: false) }
        guard let current = findCurrent, current < findMatches.count else { return }
        let match = findMatches[current]
        let text = storage.mutableString as NSString
        guard let replacement = try? FindEngine.replacement(for: match, in: text, query: findWidget.query,
                                                            template: findWidget.replacement, options: findWidget.options) else { return }
        guard performEdit(match, replacement, actionName: "取代") else { return }
        let after = match.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: after, length: 0))
        runFind(resetCurrent: true, reveal: true)
        caretMovedSinceFind = false
    }

    /// `全部取代`: every match in one edit, so one undo restores them all.
    func replaceAll() {
        guard findVisible, !readOnly, !textView.hasMarkedText() else { return }
        let text = storage.mutableString.copy() as! NSString
        let query = findWidget.query
        let options = findWidget.options
        guard let matches = try? FindEngine.matches(in: text, query: query, options: options), let first = matches.first,
              let last = matches.last else { return }
        let template = findWidget.replacement
        let span = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        let result = NSMutableString()
        var cursor = first.location
        for match in matches {
            result.append(text.substring(with: NSRange(location: cursor, length: match.location - cursor)))
            let replacement = (try? FindEngine.replacement(for: match, in: text, query: query, template: template, options: options)) ?? template
            result.append(replacement)
            cursor = NSMaxRange(match)
        }
        guard performEdit(span, result as String, actionName: "全部取代") else { return }
        textView.setSelectedRange(NSRange(location: first.location + result.length, length: 0))
        runFind(resetCurrent: true, reveal: false)
    }
}
