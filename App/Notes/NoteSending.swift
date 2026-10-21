import CoddComposer
import CoddCore
import CoddNotebookUI
import CoddNotes
import Foundation

/// D14: a note goes to a CODD claude session from the prompt footer, SEND TO SESSION, the drawer
/// cards and ⌘⏎ in the note editor. Three ways:
/// - 插入引用: `codd://note/<id>` at the end of that session's composer draft (the M2 draft path;
///   the composer opens, and takes the keyboard when the session is on screen);
/// - 插入全文: the note's §3.7 AI text into the draft the same way;
/// - 送出: the AI text through `ComposerEncoding.payload` → `TerminalInput.payload` (one paste
///   plus Return) straight to claude's own PTY, like the composer's Enter.
///
/// Refusals follow the composer's: a WAITING claude reads the next key as its answer, so nothing
/// is sent (`Claude 在等你確認 · 先用下方按鍵回答`); a session that is not running or whose PTY
/// takes nothing gets `session 沒有在執行`; text over the 256 KiB INPUT budget gets
/// `筆記太長，改用插入引用`. Externals and shell sessions are never targets. A PROMPT that went out
/// records `sent` / `sentTo` (D29: archived 7 days later like a SCRATCH).
@MainActor
final class NoteSending {
    enum Action: String, Sendable, CaseIterable {
        case ref, full, submit

        init(_ action: NotebookSendAction) {
            switch action {
            case .insertRef: self = .ref
            case .insertFull: self = .full
            case .send: self = .submit
            }
        }
    }

    enum Outcome: Equatable, Sendable {
        /// The text went into the session's draft.
        case inserted(SessionID)
        case sent(SessionID)
        case refused(String)

        var refusal: String? {
            if case .refused(let reason) = self { return reason }
            return nil
        }
    }

    /// The dump's `notes.lastSend` (ids and sizes, never the text).
    struct Record: Equatable, Sendable {
        var action: Action
        var note: String
        var session: SessionID
        var outcome: String
        var bytes: Int
        var paste: Bool
        var at: Date
    }

    static let waitingText = "Claude 在等你確認 · 先用下方按鍵回答"
    static let notRunningText = "session 沒有在執行"
    static let tooLongText = "筆記太長，改用插入引用"
    static let emptyText = "這則筆記沒有內容"
    /// An external, a shell session or one CODD no longer knows (D14: externals are never targets).
    static let notTargetText = "只能送到 CODD 啟動的 Claude session"
    static let unsavedText = NotebookCopy.unsavedReason
    static let noTargetText = NotebookCopy.noTargetReason

    static func sentText(_ title: String) -> String { "已送到「\(title)」" }
    static func insertedText(_ title: String) -> String { "已放進「\(title)」的訊息草稿 · ⌘L" }

    let notes: NotesService
    let store: any SessionStore
    let shell: ShellState
    /// The note editor: its pending text is saved before the AI text is rendered, and a PROMPT's
    /// `sent` change is adopted so the next autosave does not conflict.
    weak var editor: NoteEditorController?
    /// The main pane's composer (per-session drafts and the bar).
    var composer: () -> PaneComposer? = { nil }
    /// Sends to a PTY no slot needs to show (the hub's `send(_:to:)`; mock: the fake factory).
    var send: (TerminalInput, TerminalTarget) -> Bool = { _, _ in false }
    /// The target session is on screen: its composer shows and takes the keyboard.
    var revealComposer: (SessionID) -> Void = { _ in }
    private(set) var last: Record?
    /// Every request, refused ones included (the shortcut matrix proves ⌘⏎ in the editor routes here).
    private(set) var attempts = 0
    /// Something the dump shows changed.
    var onChange: (() -> Void)?

    init(notes: NotesService, store: any SessionStore, shell: ShellState) {
        self.notes = notes
        self.store = store
        self.shell = shell
    }

    /// Counts a request that could not even name a note or a target (no note shown, no live session).
    func refuse(_ reason: String) -> Outcome {
        attempts += 1
        onChange?()
        return .refused(reason)
    }

    /// Sends `note` to `sessionID` the way `action` says. Never throws: a refusal says why in
    /// 繁體中文 (the caller shows it as a toast).
    @discardableResult
    func perform(_ action: Action, note id: NoteID, to sessionID: SessionID) async -> Outcome {
        attempts += 1
        defer { onChange?() }
        guard let session = Self.session(sessionID, in: store), session.kind == .claude, !session.external else {
            return finish(.refused(Self.notTargetText), action, id, sessionID)
        }
        let target = session.id
        if action == .submit {
            if let reason = Self.submitRefusal(session) { return finish(.refused(reason), action, id, target) }
        }
        var text: String
        switch action {
        case .ref:
            text = id.uri
        case .full, .submit:
            switch await aiText(id) {
            case .success(let value): text = value
            case .failure(let refusal): return finish(.refused(refusal.text), action, id, target)
            }
        }
        // Post-M4 (review attachments-4): a note may name a composer image (a prompt copied into it).
        // A send marks those first and never sends a gone one's path: `[圖已過期]` goes in its place.
        let states = action == .submit ? composer()?.states : nil
        if let states {
            states.markAttachmentsSending(text, for: target)
            text = states.expiringMissingAttachments(in: text, for: target)
        }
        let payload: ComposerPayload
        do {
            payload = try ComposerEncoding.payload(for: text)
        } catch {
            switch error {
            case .empty: return finish(.refused(Self.emptyText), action, id, target)
            case .tooLong: return finish(.refused(Self.tooLongText), action, id, target)
            }
        }
        if action != .submit {
            insert(text, into: target)
            return finish(.inserted(target), action, id, target, bytes: Array(text.utf8).count, paste: false)
        }
        // The state may have changed while the text was rendered (a permission prompt came up).
        guard let now = Self.session(target, in: store) else { return finish(.refused(Self.notTargetText), action, id, target) }
        if let reason = Self.submitRefusal(now) { return finish(.refused(reason), action, id, target) }
        let input = TerminalInput.payload(bytes: payload.bytes, submit: payload.submit, paste: payload.paste)
        guard send(input, TerminalTarget(sessionID: target, tab: .claude)) else {
            return finish(.refused(Self.notRunningText), action, id, target)
        }
        states?.sweepAttachmentsAfterSend(for: target)
        await markSentIfPrompt(id, to: target)
        return finish(.sent(target), action, id, target, bytes: payload.bytes.count, paste: payload.paste)
    }

    /// The toast for an outcome (the session's title in the success texts).
    func toast(for outcome: Outcome) -> String {
        switch outcome {
        case .inserted(let id): Self.insertedText(Self.session(id, in: store)?.title ?? id)
        case .sent(let id): Self.sentText(Self.session(id, in: store)?.title ?? id)
        case .refused(let reason): reason
        }
    }

    // MARK: Steps

    /// Why 送出 cannot go to this session now (nil: it can).
    static func submitRefusal(_ session: SessionVM) -> String? {
        guard session.state.isLive else { return notRunningText }
        if session.state == .waiting { return waitingText }
        return nil
    }

    /// A session by id, store ids compared case-insensitively (notes link lowercase ids).
    static func session(_ id: SessionID, in store: any SessionStore) -> SessionVM? {
        store.session(id) ?? store.allSessions.first { $0.id.lowercased() == id.lowercased() }
    }

    /// The note's whole §3.7 text (the editor's pending text saved first). One character past the
    /// INPUT budget is enough to know it is too long (a character is at least one byte).
    private func aiText(_ id: NoteID) async -> Result<String, Refusal> {
        await notes.flushForAI(id)
        do {
            let rendered = try await notes.aiText(id, maxChars: ComposerEncoding.maxBytes + 1)
            if rendered.truncated { return .failure(Refusal(Self.tooLongText)) }
            return .success(rendered.text)
        } catch {
            return .failure(Refusal(NotesAreaViewController.message(error)))
        }
    }

    struct Refusal: Error {
        var text: String
        init(_ text: String) { self.text = text }
    }

    /// Appends to the session's draft and opens its composer (focused when it is on screen).
    private func insert(_ text: String, into id: SessionID) {
        composer()?.appendToDraft(text, for: id)
        shell.setComposerOpen(true, in: id)
        if shell.area == .sessions, shell.currentSessionID == id { revealComposer(id) }
    }

    /// D14 / D29: a PROMPT records when and where it was sent.
    private func markSentIfPrompt(_ id: NoteID, to session: SessionID) async {
        var found = notes.activeNotes.first { $0.id == id }
        if found == nil { found = try? await notes.summary(id) }
        guard let summary = found, summary.metadata.kind == .prompt else { return }
        do {
            let document = try await notes.update(id, .markSent(at: notes.clock(), to: session.lowercased()))
            editor?.adopt(document)
        } catch {
            HolderSessionStore.printLog("notes send markSent failed id=\(id.rawValue): \(NotesAreaViewController.message(error))")
        }
    }

    private func finish(_ outcome: Outcome, _ action: Action, _ id: NoteID, _ session: SessionID, bytes: Int = 0,
                        paste: Bool = false) -> Outcome {
        let name: String = switch outcome {
        case .inserted: "inserted"
        case .sent: "sent"
        case .refused(let reason): "refused:\(reason)"
        }
        last = Record(action: action, note: id.rawValue, session: session, outcome: name, bytes: bytes, paste: paste, at: notes.clock())
        HolderSessionStore.printLog("notes send action=\(action.rawValue) id=\(id.rawValue) session=\(session) "
                                    + "outcome=\(name.split(separator: ":").first.map(String.init) ?? name) bytes=\(bytes) paste=\(paste)")
        return outcome
    }

    /// `notes.lastSend` (ids, sizes and the outcome only).
    var dumpObject: [String: Any] {
        var out: [String: Any] = ["attempts": attempts]
        if let last {
            out["last"] = ["action": last.action.rawValue, "note": last.note, "session": last.session, "outcome": last.outcome,
                           "bytes": last.bytes, "paste": last.paste, "at": JSDate.isoString(last.at)]
        } else {
            out["last"] = NSNull()
        }
        return out
    }
}

