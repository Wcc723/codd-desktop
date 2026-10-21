import AppKit
import CoddCodeEditor
import CoddFiles
import CoddUI

/// SHOW AI CHANGES (D27): per tab, the buffer against a baseline (`基準：git HEAD`, `基準：上次儲存
/// HH:mm`, `基準：AI 開始前 HH:mm`, and the banner's `比較` against the disk version) as inline
/// unified hunks with the hunk bar, `AI 變更 n 段` ↑ ↓ and the overview ruler marks. `還原此段`
/// edits the buffer only (undoable, the tab turns dirty); `接受` hides the hunk (a `.mod` bar
/// stays) until the file or the baseline changes. Nothing here writes the file.
extension FileEditorService {
    // MARK: Switch and baseline

    func setShowAI(_ tab: FileTab, on: Bool) {
        guard tab.state != nil else { return }
        tab.showAI = on
        if !on, tab.baseline == .disk { tab.baseline = tab.baselineBeforeCompare ?? .head }
        if on {
            if tab.baseline == .head, let workspace = workspace(containing: tab) { loadHead(tab, in: workspace, force: false) }
            scheduleDiff(tab, immediately: true)
        } else {
            clearDiff(tab)
        }
        log("files show-ai name=\(tab.title) on=\(on)")
    }

    /// The baselines the toolbar's select offers, in order (`ai` only when one was kept, `disk`
    /// while `比較` shows).
    func baselines(of tab: FileTab) -> [FileTab.Baseline] {
        var out: [FileTab.Baseline] = [.head, .saved]
        if tab.state?.aiBaseline != nil { out.append(.ai) }
        if tab.baseline == .disk { out.append(.disk) }
        return out
    }

    func setBaseline(_ tab: FileTab, _ baseline: FileTab.Baseline) {
        guard baseline != tab.baseline else { return }
        if baseline == .ai, tab.state?.aiBaseline == nil { return }
        if baseline == .disk, tab.state?.pendingDisk?.decoded == nil { return }
        tab.baseline = baseline
        tab.baselineBeforeCompare = nil
        tab.accepted = []
        tab.currentHunk = nil
        if baseline == .head, let workspace = workspace(containing: tab) { loadHead(tab, in: workspace, force: false) }
        scheduleDiff(tab, immediately: true)
        log("files baseline name=\(tab.title) baseline=\(baseline.rawValue)")
    }

    func workspace(containing tab: FileTab) -> FilesWorkspace? {
        workspaces.first { $0.tabs.contains { $0 === tab } }
    }

    // MARK: HEAD text

    /// `cat-file blob HEAD:<path>` of the tab's file (its old path after a rename), decoded like
    /// the file. Not in HEAD, or not a repository: every line is added.
    func loadHead(_ tab: FileTab, in workspace: FilesWorkspace, force: Bool) {
        guard let url = tab.url else { return }
        if !force, tab.headText != .unknown { return }
        guard workspace.gitLoaded else { return }
        guard let repo = workspace.repoRoot, let relative = workspace.relativePath(url.path) else {
            if tab.headText != .absent { tab.headText = .absent }
            scheduleDiff(tab, immediately: true)
            return
        }
        let path = workspace.gitPath(relative)
        let headPath = workspace.status?.renamedFrom[path] ?? path
        let git = self.git
        Task { [weak self, weak tab] in
            let data = try? await git.headText(root: repo, relativePath: headPath)
            let text = await Task.detached(priority: .userInitiated) { () -> String? in
                guard let data else { return nil }
                return try? TextFileCodec.decode(data).get().text
            }.value
            guard let self, let tab else { return }
            let head: FileTab.HeadText = text.map { .text($0) } ?? .absent
            if head != tab.headText { tab.headText = head }
            if tab.showAI, tab.baseline == .head { self.scheduleDiff(tab, immediately: true) }
        }
    }

    // MARK: Hunks

    /// The hunks follow edits 300 ms after the last one, computed off the main actor.
    func scheduleDiff(_ tab: FileTab, immediately: Bool = false) {
        tab.diffTask?.cancel()
        guard tab.showAI, tab.state != nil, tab.editor != nil else {
            tab.diffTask = nil
            return
        }
        tab.diffTask = Task { [weak self, weak tab] in
            if !immediately { try? await Task.sleep(for: Self.diffDebounce) }
            guard !Task.isCancelled, let self, let tab else { return }
            await self.computeDiff(tab)
        }
    }

    /// The baseline's lines (nil: HEAD not known yet; `[]`: not in HEAD).
    func baselineLines(_ tab: FileTab) -> [String]? {
        guard let state = tab.state else { return nil }
        switch tab.baseline {
        case .head:
            switch tab.headText {
            case .unknown: return nil
            case .absent: return []
            case .text(let text): return TextFileCodec.lines(text)
            }
        case .saved: return TextFileCodec.lines(state.savedText)
        case .ai: return TextFileCodec.lines(state.aiBaseline?.text ?? state.savedText)
        case .disk: return TextFileCodec.lines(state.pendingDisk?.decoded?.text ?? state.savedText)
        }
    }

    private func computeDiff(_ tab: FileTab) async {
        guard let state = tab.state else { return }
        guard let old = baselineLines(tab) else {
            if let workspace = workspace(containing: tab) { loadHead(tab, in: workspace, force: false) }
            return
        }
        let baseline = tab.baseline
        let new = TextFileCodec.lines(state.buffer)
        let hunks = await Task.detached(priority: .userInitiated) { LineDiff.hunks(old: old, new: new) }.value
        guard !Task.isCancelled, tab.showAI, tab.baseline == baseline else { return }
        tab.hunks = hunks
        tab.hunksBaseline = baseline
        if let current = tab.currentHunk, current >= hunks.count { tab.currentHunk = hunks.isEmpty ? nil : hunks.count - 1 }
        tab.diffRuns += 1
        applyDiff(tab)
    }

    func clearDiff(_ tab: FileTab) {
        tab.diffTask?.cancel()
        tab.diffTask = nil
        tab.hunks = []
        tab.currentHunk = nil
        guard let editor = tab.editor else { return }
        editor.setInlineDiff([])
        editor.modifiedLineMarkers = [:]
        editor.overviewMarks = []
    }

    /// The visible hunks (not accepted) for the editor, with their bars, the `.mod` bars of the
    /// accepted ones and the ruler marks, all in the AI session's tag color (D26).
    func applyDiff(_ tab: FileTab) {
        guard let editor = tab.editor else { return }
        let header = hunkHeaderFacts(tab)
        var inline: [InlineDiffHunk] = []
        var markers: [Int: NSColor] = [:]
        var marks: [OverviewMark] = []
        for (index, hunk) in tab.hunks.enumerated() {
            let accepted = tab.accepted.contains(FileTab.hunkKey(hunk, baseline: tab.hunksBaseline))
            if accepted {
                for line in hunk.newRange { markers[line] = header.color }
            } else {
                let bar = InlineDiffHeader(tagColor: header.color, showAIChip: header.ai, who: header.who,
                                           range: LineDiff.unifiedHeader(hunk), removed: hunk.oldLines.count, added: hunk.newLines.count,
                                           position: "\(index + 1) / \(tab.hunks.count)")
                inline.append(InlineDiffHunk(id: index, newLines: hunk.newRange, deletedLines: hunk.oldLines, header: bar))
            }
            if hunk.newRange.isEmpty {
                marks.append(OverviewMark(kind: .removed, line: hunk.newRange.lowerBound, color: header.ai ? header.color : nil))
            } else {
                marks.append(OverviewMark(kind: header.ai ? .aiChange : .added, line: hunk.newRange.lowerBound,
                                          lineCount: max(1, hunk.newRange.count), color: header.ai ? header.color : nil))
            }
        }
        editor.setInlineDiff(inline)
        editor.modifiedLineMarkers = markers
        editor.overviewMarks = marks
    }

    /// The hunk bar's color, AI chip and `who` (`打卡頁 RWD 調整 · 10:36`): the newest AI touch of
    /// the file, else the baseline's own words.
    func hunkHeaderFacts(_ tab: FileTab) -> (color: NSColor, ai: Bool, who: String) {
        if tab.baseline == .disk {
            let at = tab.state?.pendingDisk?.at
            return (Palette.amber, false, "磁碟上的版本" + (at.map { " · \(hourMinute($0))" } ?? ""))
        }
        if tab.baseline == .ai, let baseline = tab.state?.aiBaseline, let session = baseline.session {
            let vm = store.session(session)
            return (vm?.tag?.color ?? Palette.bone, true, "\(vm?.title ?? "Claude") · \(hourMinute(baseline.at))")
        }
        if let touch = touch(of: tab) {
            let vm = store.session(touch.session)
            return (vm?.tag?.color ?? Palette.bone, true, "\(vm?.title ?? "Claude") · \(hourMinute(touch.at))")
        }
        return (Palette.amber, false, tab.baseline == .saved ? "未儲存的修改" : "與 git HEAD 不同")
    }

    // MARK: Hunk actions

    /// `還原此段`: the hunk's lines go back to the baseline's in the buffer (one undoable edit,
    /// the tab turns dirty); `接受`: hidden until the file or the baseline changes.
    func hunkAction(_ tab: FileTab, index: Int, action: HunkAction) {
        guard tab.hunks.indices.contains(index), let editor = tab.editor else { return }
        let hunk = tab.hunks[index]
        switch action {
        case .revert:
            guard !(tab.state?.decoded.readOnly ?? true) else {
                onToast?(Self.readOnlyText)
                return
            }
            // The editor shifted its copy of the hunk with edits made since the diff ran.
            let lines = editor.inlineDiff.first { $0.id == index }?.newLines ?? hunk.newRange
            editor.replaceLines(lines, with: hunk.oldLines, actionName: "還原此段")
            log("files hunk revert name=\(tab.title) index=\(index)")
        case .accept:
            tab.accepted.insert(FileTab.hunkKey(hunk, baseline: tab.hunksBaseline))
            applyDiff(tab)
            log("files hunk accept name=\(tab.title) index=\(index)")
        }
    }

    /// `AI 變更 n 段` ↑ ↓: the next / previous hunk, scrolled into view.
    func stepChange(_ tab: FileTab, forward: Bool) {
        guard !tab.hunks.isEmpty, let editor = tab.editor else { return }
        let next: Int
        if let current = tab.currentHunk {
            next = (current + (forward ? 1 : -1) + tab.hunks.count) % tab.hunks.count
        } else {
            let caretLine = tab.caret.line - 1
            if forward {
                next = tab.hunks.firstIndex { $0.newRange.lowerBound > caretLine } ?? 0
            } else {
                next = tab.hunks.lastIndex { $0.newRange.lowerBound < caretLine } ?? tab.hunks.count - 1
            }
        }
        tab.currentHunk = next
        let hunk = tab.hunks[next]
        if editor.inlineDiff.contains(where: { $0.id == next }) {
            editor.scrollToHunk(next)
        } else {
            editor.goTo(line: hunk.newRange.lowerBound + 1, column: 1)
        }
    }
}
