import CoddHooks
import CoddNotes
import Foundation
import Synchronization

/// D19 prompt expansion: `/hooks/prompt` hands over each UserPromptSubmit of a CODD session (the
/// event itself already reached the state engine); a prompt that names `codd://note/<id>` or
/// `[[note:<id>]]` (at most 5 distinct refs) is answered with the §3.7 text of each visible note
/// as `additionalContext` (≤ 9,500 characters) and the `codd：已展開 …` line Claude shows the user
/// as `systemMessage`. An OFF, unknown, trashed or purged ref gets one line saying why (an OFF note
/// is never named). No ref, no open notebook, or past the deadline: nil, which the server answers
/// 204 (Claude reads it as `{}`). Runs off the main actor.
final class PromptExpansion: Sendable {
    /// What one answered (or late) prompt did, for the dump's `promptExpansion` (ids only).
    struct Record: Sendable, Equatable {
        var refs: [String]
        var expanded: [String]
        var chars: Int
        var ms: Double
        var late: Bool
    }

    /// D19's budget for the whole context.
    static let maxChars = 9_500

    let context: NotesMCPContext
    /// The answer must be ready before the server's own 1.5 s deadline (D19), so a late
    /// expansion is counted and logged here rather than cut off silently there.
    let deadline: Duration
    private let report: @Sendable (Record) -> Void
    private let log: @Sendable (String) -> Void
    /// C1's expansion with the session's image scope (tests slow it down to check the deadline).
    private let expand: @Sendable (NotesLibrary, String, NoteAIText.ImageScope) async -> NoteAIText.Expansion

    init(context: NotesMCPContext, deadline: Duration = .milliseconds(1300), report: @escaping @Sendable (Record) -> Void = { _ in },
         log: @escaping @Sendable (String) -> Void = { _ in },
         expand: @escaping @Sendable (NotesLibrary, String, NoteAIText.ImageScope) async -> NoteAIText.Expansion = { library, prompt, scope in
             await library.expansion(for: [prompt], maxChars: PromptExpansion.maxChars, imageScope: scope)
         }) {
        self.context = context
        self.deadline = deadline
        self.report = report
        self.log = log
        self.expand = expand
    }

    /// The answer for one prompt of CODD session `sessionID`; nil = 204.
    func answer(sessionID: UUID, prompt: String?) async -> PromptHookAnswer? {
        guard let prompt else { return nil }
        let refs = NoteReferences.parse(prompt, limit: 5)
        guard !refs.isEmpty else { return nil }
        let session = sessionID.uuidString.lowercased()
        guard let library = context.library else {
            log("prompt-expand session=\(session) refs=\(refs.count) skipped (notebook not open)")
            return nil
        }
        let started = ContinuousClock.now
        let expand = self.expand
        // CODE-4: `[image]` sizes only for images inside the notes root or this session's folder.
        let scope = NoteAIText.ImageScope.ai(folders: context.session(session)?.cwd.map { [context.realPath($0)] } ?? [])
        let work = Task { await expand(library, prompt, scope) }
        let expansion = await Self.first(of: work, within: deadline)
        let ms = Self.milliseconds(ContinuousClock.now - started)
        guard let expansion else {
            log(String(format: "prompt-expand late session=%@ refs=%d ms=%.1f", session, refs.count, ms))
            report(Record(refs: refs.map(\.rawValue), expanded: [], chars: 0, ms: ms, late: true))
            return nil
        }
        guard let text = expansion.context else { return nil }
        let title = context.session(session)?.title
        let now = context.clock()
        for id in expansion.noteIDs {
            await library.recordActivity(NoteActivityEvent(at: now, note: id, action: "expand", client: "Claude Code", session: session,
                                                           sessionTitle: title, via: "hook"))
        }
        log(String(format: "prompt-expand session=%@ refs=%d expanded=%d refused=%d chars=%d ms=%.1f", session, refs.count,
                   expansion.noteIDs.count, expansion.refused.count, text.count, ms))
        report(Record(refs: refs.map(\.rawValue), expanded: expansion.noteIDs.map(\.rawValue), chars: text.count, ms: ms, late: false))
        return PromptHookAnswer(additionalContext: text, systemMessage: expansion.systemMessage)
    }

    /// The task's value, or nil once `limit` passed (the task keeps running; its result is dropped).
    static func first<T: Sendable>(of task: Task<T, Never>, within limit: Duration) async -> T? {
        let once = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let timer = Task {
                try? await Task.sleep(for: limit)
                if once.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let value = await task.value
                // An answer in time ends the timer's sleep (its claim then fails).
                timer.cancel()
                if once.claim() { continuation.resume(returning: value) }
            }
        }
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}

/// The first of two racing tasks to claim it wins (a continuation resumes exactly once).
private final class OnceFlag: Sendable {
    private let done = Mutex(false)

    func claim() -> Bool {
        done.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}

/// `GET /n/<id>.md?t=…` (D15; the server checked the per-note token): the note's 複製全文
/// Markdown (§3.7: the body, image links absolute) as `text/markdown; charset=utf-8`. An unknown
/// or AI OFF note is 404 (an OFF note never leaves CODD through a URL); a trashed or purged one
/// 410 with one Markdown line. Each served note records `url` activity (D20).
struct NoteURLResponder: Sendable {
    let context: NotesMCPContext
    private let log: @Sendable (String) -> Void

    static let contentType = "text/markdown; charset=utf-8"

    init(context: NotesMCPContext, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.context = context
        self.log = log
    }

    func respond(_ raw: String) async -> HTTPRouteResponse {
        guard let library = context.library, let id = NoteID(rawValue: raw) else { return .status(404) }
        switch await library.resolve(raw) {
        case .note(let summary):
            guard summary.metadata.ai != .off, let text = try? await library.copyMarkdown(id) else {
                log("note-url id=\(raw) status=404")
                return .status(404)
            }
            await library.recordActivity(NoteActivityEvent(at: context.clock(), note: id, action: "url", client: "URL", via: "url"))
            log("note-url id=\(raw) status=200 bytes=\(text.utf8.count)")
            return HTTPRouteResponse(status: 200, contentType: Self.contentType, body: Array(text.utf8))
        case .trashed(let summary, _):
            guard summary.metadata.ai != .off else { return .status(404) }
            log("note-url id=\(raw) status=410 trashed")
            return Self.gone("這則筆記在 CODD 垃圾桶")
        case .purged:
            log("note-url id=\(raw) status=410 purged")
            return Self.gone("這則筆記已永久刪除")
        case .unknown:
            log("note-url id=\(raw) status=404")
            return .status(404)
        }
    }

    static func gone(_ line: String) -> HTTPRouteResponse {
        HTTPRouteResponse(status: 410, contentType: contentType, body: Array((line + "\n").utf8))
    }
}
