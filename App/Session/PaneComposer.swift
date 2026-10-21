import AppKit
import CoddComposer
import CoddNotes

/// Binds the ⌘L composer bar to what the pane's tab-strip terminal shows (D1–D4): the session's
/// draft and history (switched with the session), the target PTY (claude's own or a shell tab),
/// and the send path `ComposerEncoding.payload` → `TerminalInput.payload` → the PTY (the holder
/// brackets a paste when the child has ?2004 on and sends the Return 50 ms later).
///
/// The text view never clears itself: a send that went out records the text in the history and
/// empties the field; a refused one (not running, too long, the PTY did not take it) keeps it.
@MainActor
final class PaneComposer {
    let bar = ComposerBarView()
    let states: ComposerStates
    /// Session whose draft the field shows.
    private(set) var sessionID: SessionID?
    /// Where Enter / SEND goes.
    private(set) var target: TerminalTarget?
    private(set) var isLive = false
    /// The target is claude's own PTY showing a prompt (WAITING): Enter would answer it.
    private(set) var isAwaitingAnswer = false
    /// Asked again at the moment of a send (the state may have changed since the last bind):
    /// true while the target is a claude prompt waiting for an answer.
    var awaitingAnswer: ((TerminalTarget) -> Bool)?
    /// The user edited since the field switched to this session: a draft read late from disk must
    /// not replace what they typed.
    private var editedSinceSwitch = false
    /// Sends to a PTY; false when nothing took the input.
    var send: ((TerminalInput, TerminalTarget) -> Bool)?
    /// Esc in the composer (the pane focuses the terminal).
    var onEscape: (() -> Void)?
    /// A send went out (DEBUG timing log and the state dump).
    var onSent: ((SessionID, ComposerPayload, Duration) -> Void)?

    init(states: ComposerStates) {
        self.states = states
        let textView = bar.textView
        textView.onSubmit = { [weak self] text in self?.submit(text) }
        textView.onEscape = { [weak self] in self?.onEscape?() }
        textView.onHistory = { [weak self] direction in self?.history(direction) }
        textView.onPasteImage = { [weak self] image in self?.pasteImage(image) ?? false }
        textView.onTextChange = { [weak self] text in self?.edited(text) }
        bar.onSend = { [weak self] in
            guard let self else { return }
            self.submit(self.bar.field.text)
        }
        states.onLoaded = { [weak self] id in self?.loaded(id) }
    }

    /// Shows `session`'s draft (when it changed) and points the bar at `target`.
    /// - Parameters:
    ///   - shell: the target is a shell (placeholder `輸入要送到 shell 的文字（⌘L）`).
    ///   - live: the target PTY runs (else `session 沒有在執行`, read-only).
    ///   - busy: claude is working (`Claude 工作中 · 送出後排入佇列`).
    ///   - awaitingAnswer: claude's own PTY shows a permission, plan or question prompt (WAITING):
    ///     sends are refused (`Claude 在等你確認 · 先用下方按鍵回答`), the draft is kept.
    func bind(session: SessionID, target: TerminalTarget, shell: Bool, live: Bool, busy: Bool, awaitingAnswer: Bool = false) {
        if session != sessionID {
            if let old = sessionID { states.resetCursor(for: old) }
            sessionID = session
            editedSinceSwitch = false
            bar.field.text = states.state(session)?.draft ?? ""
            states.prefetch(session)
            if case .tooLong = bar.currentStatus { bar.setStatus(.none) }
        }
        self.target = target
        isLive = live
        isAwaitingAnswer = awaitingAnswer
        bar.setPlaceholder(shell: shell)
        if case .tooLong = bar.currentStatus, live, !awaitingAnswer { return }
        bar.setStatus(live ? (awaitingAnswer ? .awaitingAnswer : busy ? .busy : .none) : .notRunning)
    }

    /// Enter or SEND. True when the text went out.
    @discardableResult
    func submit(_ text: String) -> Bool {
        guard let id = sessionID, let target, isLive else {
            NSSound.beep()
            return false
        }
        // A WAITING claude reads the next key as the answer (`2` = always allow, Return = the
        // highlighted option): the text would grant a tool call or approve a plan.
        if awaitingAnswer?(target) ?? isAwaitingAnswer {
            isAwaitingAnswer = true
            bar.setStatus(.awaitingAnswer)
            NSSound.beep()
            return false
        }
        // Post-M4 (review attachments-6): a note's annotated copy the text names that is gone from
        // the cache is rendered again first; the send goes once it is back.
        if restoringAnnotatedCopies(of: text, for: id) { return false }
        // Post-M4: the images the text names get their 24 h now, before the check and the send (a
        // sweep running at this moment either removed one first or keeps it, review attachments-2).
        states.markAttachmentsSending(text, for: id)
        // An image of the text that is gone (removed 24 h after its last send) is never sent as a
        // path. The field shows `[圖已過期]` in its place and nothing goes; Enter again sends.
        var checked = states.expiringMissingAttachments(in: text, for: id)
        if let annotatedCopies { checked = annotatedCopies.replacingMissing(in: checked) }
        if checked != text {
            bar.field.text = checked
            states.setDraft(checked, for: id)
            editedSinceSwitch = true
            NSSound.beep()
            return false
        }
        let payload: ComposerPayload
        do {
            payload = try ComposerEncoding.payload(for: text)
        } catch {
            switch error {
            case .empty:
                return false
            case .tooLong(let bytes):
                bar.setStatus(.tooLong(bytes))
                NSSound.beep()
                return false
            }
        }
        let start = ContinuousClock.now
        let sent = send?(.payload(bytes: payload.bytes, submit: payload.submit, paste: payload.paste), target) ?? false
        let elapsed = ContinuousClock.now - start
        guard sent else {
            NSSound.beep()
            return false
        }
        states.recordSent(text, for: id)
        // The session's old images go (off the main actor; this send's were marked above).
        states.sweepAttachmentsAfterSend(for: id)
        copyRestore = nil
        bar.field.text = ""
        editedSinceSwitch = false
        onSent?(id, payload, elapsed)
        return true
    }

    /// Post-M4 (review attachments-6): the notes' burned-in annotated copies (`cache/annotated/`,
    /// DERIVED) that drafts and history entries made with 插入全文 name; nil without notes.
    var annotatedCopies: AnnotatedCopies?
    /// The text whose missing annotated copies are being (or were) rendered again, and whether
    /// that is done: one try per text, so a copy that cannot come back goes as `[圖已過期]`.
    private var copyRestore: (text: String, done: Bool)?

    /// True when the send must wait: the text names an annotated copy that is gone and this is the
    /// first Enter for that text (the copies are rendered again, then the text is submitted again
    /// while the field still shows it), or that rendering still runs. False lets the send go on
    /// (nothing missing, or rendered once already: what is still missing becomes `[圖已過期]`).
    private func restoringAnnotatedCopies(of text: String, for id: SessionID) -> Bool {
        guard let annotatedCopies, !annotatedCopies.missing(in: text).isEmpty else { return false }
        if let copyRestore, copyRestore.text == text { return !copyRestore.done }
        copyRestore = (text, false)
        Task { [weak self] in
            await annotatedCopies.restore(text)
            guard let self, self.copyRestore?.text == text else { return }
            self.copyRestore?.done = true
            if self.sessionID == id, self.bar.field.text == text { self.submit(text) }
        }
        return true
    }

    /// ↑ / ↓ recall. Post-M4: an image removed 24 h after its send comes back as `[圖已過期]` (a
    /// muted chip), never as its path; the saved entry keeps the path.
    private func history(_ direction: ComposerHistoryDirection) -> String? {
        guard let id = sessionID else { return nil }
        let entry: String?
        switch direction {
        case .previous: entry = states.previous(current: bar.field.text, for: id)
        case .next: entry = states.next(for: id)
        }
        return entry.map { states.expiringMissingAttachments(in: $0, for: id) }
    }

    /// Takes a pasted image when the session has a folder; the path goes in once the file is
    /// written (converted and saved off the main actor): at the caret while the field still shows
    /// that session, else at the end of its draft.
    private func pasteImage(_ image: ComposerPastedImage) -> Bool {
        guard let id = sessionID, states.canSaveAttachment(for: id) else {
            NSSound.beep()
            return false
        }
        pendingAttachments += 1
        Task { [weak self] in
            guard let self else { return }
            let path = await self.states.saveAttachment(image, for: id)
            self.pendingAttachments -= 1
            guard let path else {
                NSSound.beep()
                return
            }
            if self.sessionID == id {
                // A path glued to the word before it (usual after Chinese text) reaches claude as one token.
                let view = self.bar.textView
                let text = view.string as NSString
                let caret = view.selectedRange().location
                let glued = caret > 0 && caret <= text.length
                    && !CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: caret - 1)) ?? "x")
                view.insertAttachmentText(glued ? " " + path : path)
            } else {
                self.states.appendToDraft(path, for: id)
            }
            self.onAttachmentSaved?(id)
        }
        return true
    }

    /// Images being converted and saved now (tests wait for 0).
    private(set) var pendingAttachments = 0
    /// A pasted image's path went into a draft (tests).
    var onAttachmentSaved: ((SessionID) -> Void)?

    /// M4 D14 (插入引用 / 插入全文): `text` at the end of a session's draft. When the bar shows that
    /// session the field takes it as one undoable insertion at its end (the draft follows through
    /// `onTextChange`); otherwise the stored draft gets it (read from disk first when needed).
    func appendToDraft(_ text: String, for id: SessionID) {
        guard id == sessionID, states.state(id) != nil else {
            states.appendToDraft(text, for: id)
            return
        }
        let view = bar.textView
        let current = bar.field.text
        if view.isEditable, !view.hasMarkedText() {
            let gap = ComposerStates.appending("", to: current)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            view.insertAttachmentText(String(gap.dropFirst(current.count)) + text)
        } else {
            let next = ComposerStates.appending(text, to: current)
            bar.field.text = next
            states.setDraft(next, for: id)
        }
        editedSinceSwitch = true
    }

    /// The `codd://note/<id>` references in a session's draft (the drawer's `.ref` card, the dump).
    func draftReferences(_ id: SessionID) -> [String] {
        let draft = id == sessionID ? bar.field.text : (states.state(id)?.draft ?? "")
        return NoteReferences.parse(draft, limit: 20).map(\.rawValue)
    }

    /// The session left CODD (removed, 刪除對話紀錄, its project removed).
    func forget(_ id: SessionID) {
        states.forget(id)
        if sessionID == id {
            sessionID = nil
            target = nil
            bar.field.text = ""
        }
    }

    private func edited(_ text: String) {
        guard let id = sessionID else { return }
        editedSinceSwitch = true
        states.setDraft(text, for: id)
        if case .tooLong = bar.currentStatus { bar.setStatus(isLive ? (isAwaitingAnswer ? .awaitingAnswer : .none) : .notRunning) }
    }

    private func loaded(_ id: SessionID) {
        guard id == sessionID, !editedSinceSwitch, let draft = states.state(id)?.draft, bar.field.text != draft else { return }
        bar.field.text = draft
    }

    /// The state dump's per-session `composer` entry (`open` comes from the pane layout).
    func dump(_ id: SessionID, open: Bool) -> [String: Any] {
        let state = states.state(id)
        return ["open": open, "draftLength": state?.draft.count ?? 0, "historyCount": state?.history.entries.count ?? 0,
                "loaded": state != nil, "refs": draftReferences(id)]
    }
}

/// Post-M4 (review attachments-6): a note's burned-in annotated copy,
/// `<dataRoot>/cache/annotated/<hash12>-<stem>.annotated.png`, is DERIVED (an update may delete the
/// cache, the notebook's open drops copies nothing needs) while a draft or history entry made with
/// 插入全文 (user data) names it. Before a composer send or a resend, a missing copy is rendered
/// again from the notes the text references (the AI text's `codd://note/<id>` header line); one that
/// cannot come back (its note or image is gone, the reference was edited away) goes as `[圖已過期]`,
/// like a composer image: a missing path is never sent.
@MainActor
struct AnnotatedCopies {
    /// `<dataRoot>/cache/annotated`.
    let folder: String
    /// Renders again the annotated copies of the notes `text` references (the notes service).
    let restore: @MainActor (String) async -> Void
    private let expression: NSRegularExpression

    init(folder: String, restore: @escaping @MainActor (String) async -> Void) {
        self.folder = folder
        self.restore = restore
        // An escaped literal and a fixed tail: it always compiles.
        expression = try! NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: folder + "/")
            + "[0-9a-f]{12}-[^/\\n]*?\\.annotated\\.png")
    }

    /// The UTF-16 ranges of the copies `text` names whose file is missing (a `stat` each).
    func missing(in text: String) -> [NSRange] {
        guard text.contains(folder + "/") else { return [] }
        let ns = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            .filter { !ComposerAttachments.fileExists(ns.substring(with: $0)) }
    }

    /// `text` with every missing copy shown as `[圖已過期]`.
    func replacingMissing(in text: String) -> String {
        let ranges = missing(in: text)
        guard !ranges.isEmpty else { return text }
        let out = NSMutableString(string: text)
        for range in ranges.reversed() { out.replaceCharacters(in: range, with: ComposerAttachments.expiredMarker) }
        return out as String
    }
}
