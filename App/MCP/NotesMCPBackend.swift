import CoddMCP
import CoddNotes
import Foundation
import Synchronization

/// What the MCP request path knows about CODD and its sessions (M4 I2a): the notes library once it
/// is open, a snapshot of the CODD sessions (title, folder, live), Settings › AI 可寫入 and the
/// client names `initialize` reported. The main actor writes it (`MCPService`); requests read it
/// from any thread, so nothing on the request path ever waits for the main actor.
final class NotesMCPContext: Sendable {
    /// One CODD session as MCP sees it (D17: project scope follows the session's folder).
    struct Session: Sendable, Equatable {
        var title: String
        /// The session's project folder as CODD stores it (resolved lazily, `realPath`).
        var cwd: String?
        var live: Bool
        /// The CODD project's folder as the Notebook links it (`ProjectVM.cwd`, never a transient
        /// project's): what `notes_create` puts in the new note's `projects:`.
        var project: String? = nil
    }

    private struct State {
        var library: NotesLibrary?
        /// Lowercase CODD session id → facts.
        var sessions: [String: Session] = [:]
        var writeEnabled = false
        /// Lowercase session id → `clientInfo.name` of its `initialize`.
        var sessionClients: [String: String] = [:]
        /// The newest external client's name (requests carry no client name: stateless MCP).
        var externalClient: String?
        var realPaths: [String: String] = [:]
        /// M4 I4a, D32: a condense run's UUID → the notes it was given. Such a caller is read
        /// only and sees its source notes besides the global ones, for the run's life.
        var transient: [String: Set<String>] = [:]
    }

    private let state = Mutex(State())
    /// The notes clock (DEBUG `-codd-now`): `days` filters and activity times.
    let clock: @Sendable () -> Date
    let timeZone: TimeZone

    init(clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current) {
        self.clock = clock
        self.timeZone = timeZone
    }

    var library: NotesLibrary? { state.withLock { $0.library } }

    func setLibrary(_ library: NotesLibrary?) {
        state.withLock { $0.library = library }
    }

    func setSessions(_ sessions: [String: Session]) {
        state.withLock { $0.sessions = sessions }
    }

    func session(_ id: String) -> Session? {
        state.withLock { $0.sessions[id.lowercased()] }
    }

    /// D32: registers a condense run (`claude -p` with the run's `mcp.json`) as a transient,
    /// read-only caller that may read `notes` (raw note ids) besides the global ones.
    func setTransientCaller(_ id: UUID, notes: Set<String>) {
        state.withLock { $0.transient[id.uuidString.lowercased()] = notes }
    }

    func removeTransientCaller(_ id: UUID) {
        _ = state.withLock { $0.transient.removeValue(forKey: id.uuidString.lowercased()) }
    }

    /// The source notes of a transient caller, nil for every other caller.
    func transientNotes(_ id: String) -> Set<String>? {
        state.withLock { $0.transient[id.lowercased()] }
    }

    var writeEnabled: Bool {
        get { state.withLock { $0.writeEnabled } }
        set { state.withLock { $0.writeEnabled = newValue } }
    }

    func setClientName(_ name: String?, for caller: MCPCaller) {
        state.withLock { s in
            switch caller.kind {
            case .session(let id): s.sessionClients[id.uuidString.lowercased()] = name
            case .external: s.externalClient = name
            }
        }
    }

    /// The display kind of the caller's client (`Claude Code`, `Codex CLI`, or its raw name).
    func clientKind(for caller: MCPCaller) -> String {
        let raw: String? = state.withLock { s in
            switch caller.kind {
            case .session(let id): s.sessionClients[id.uuidString.lowercased()]
            case .external: s.externalClient
            }
        }
        return Self.clientKind(raw, session: caller.sessionID != nil)
    }

    /// `claude-code` → `Claude Code`, `codex…` → `Codex CLI` (D21's STATUS kinds); a CODD session
    /// that has not said its name yet is a Claude Code.
    static func clientKind(_ raw: String?, session: Bool) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return session ? "Claude Code" : "external"
        }
        let lower = raw.lowercased()
        if lower.contains("claude-code") || lower.contains("claude code") { return "Claude Code" }
        if lower.contains("codex") { return "Codex CLI" }
        return raw
    }

    /// `realpath(3)` of `path` (`~` expanded), cached; a path that does not resolve stays as given
    /// (standardized), so a deleted project folder still compares lexically.
    func realPath(_ path: String) -> String {
        let expanded = MCPPaths.expandTilde(path)
        if let known = state.withLock({ $0.realPaths[expanded] }) { return known }
        let resolved = MCPPaths.resolve(expanded)
        state.withLock { s in
            if s.realPaths.count > 1024 { s.realPaths.removeAll() }
            s.realPaths[expanded] = resolved
        }
        return resolved
    }
}

/// Path helpers of the MCP backend (no file is ever read through them).
enum MCPPaths {
    static func expandTilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }

    static func resolve(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        guard let real = Darwin.realpath(standardized, nil) else { return standardized }
        defer { free(real) }
        return String(cString: real)
    }

    /// `path` is `root` or inside it.
    static func isInside(_ path: String, _ root: String) -> Bool {
        guard !root.isEmpty else { return false }
        if path == root { return true }
        return path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

/// CODD's `MCPNotesBackend` over CoddNotes (M4 I2a, D17). Every call applies the visibility rules
/// for its caller before anything leaves CODD:
///
/// - AI OFF notes do not exist for any caller (search, list, read, resources, prompts; the
///   refusals look exactly like an unknown ref, so their existence never leaks).
/// - A `global` note is visible to everyone; a `project` note to CODD sessions whose folder (real
///   path) is inside one of its projects, to sessions it is linked to, and to external callers
///   (a token the user registered).
/// - The tools' `scope: project` only narrows to the caller's project and linked notes.
/// - READ notes are read-only, APPEND notes take `notes_append` (and `notes_write` while Settings ›
///   AI 可寫入 is ON); archived notes appear in search / list only with `include_archived`.
/// - `notes_create` only ever adds a new note: linked to the calling session and its project, AI
///   access APPEND, `createdBy: ai` (an external caller's note is unlinked, so `global`).
///
/// Reads record `read` activity (D20) and creates `create`; C1 records `append` / `write` itself.
/// Never on the main actor: the session facts come from `NotesMCPContext`.
struct NotesMCPBackend: MCPNotesBackend {
    let context: NotesMCPContext

    /// D17: images for Claude are at most 1568 px on the long edge and 900 KB.
    static let imageLongEdge = 1568
    static let imageMaxBytes = 900_000
    /// Notes looked at per search before the caller's filters (the library's own cap).
    static let searchWindow = 500

    // MARK: Caller

    private struct Caller {
        var sessionID: String?
        var session: NotesMCPContext.Session?
        /// The session folder's real path.
        var cwd: String?
        /// D32: a condense run's source notes (a transient, read-only caller).
        var transientNotes: Set<String>?
    }

    private func who(_ caller: MCPCaller) -> Caller {
        guard let id = caller.sessionID?.uuidString.lowercased() else { return Caller() }
        let session = context.session(id)
        return Caller(sessionID: id, session: session, cwd: session?.cwd.map(context.realPath), transientNotes: context.transientNotes(id))
    }

    /// D17's visibility of a note for a caller.
    private func visible(_ m: NoteMetadata, _ caller: Caller) -> Bool {
        guard m.ai != .off else { return false }
        if m.scope == .global { return true }
        if let sources = caller.transientNotes { return sources.contains(m.id.rawValue) }
        guard caller.sessionID != nil else { return true }
        return inCallersProject(m, caller)
    }

    /// D32: a condense run only reads.
    private static let transientReadOnly = "濃縮工作只能讀取筆記"

    /// The note is linked to the caller's session, or one of its projects holds the caller's folder.
    private func inCallersProject(_ m: NoteMetadata, _ caller: Caller) -> Bool {
        guard let id = caller.sessionID else { return false }
        if m.links.sessions.contains(where: { $0.lowercased() == id }) { return true }
        guard let cwd = caller.cwd else { return false }
        return m.links.projects.contains { MCPPaths.isInside(cwd, context.realPath($0)) }
    }

    private func library() throws(MCPBackendError) -> NotesLibrary {
        guard let library = context.library else { throw .unavailable("筆記本尚未開啟") }
        return library
    }

    /// CODE-4: the images this caller receives: those inside the notes root, and for a CODD session
    /// inside its folder (real paths). Any other image a note links is named in the text only.
    private func imageScope(_ c: Caller) -> NoteAIText.ImageScope {
        .ai(folders: c.cwd.map { [$0] } ?? [])
    }

    // MARK: Search and list

    func search(_ r: MCPSearchRequest, caller: MCPCaller) async throws -> [MCPNoteHit] {
        let library = try library()
        let c = who(caller)
        let kind = r.kind.flatMap(NoteKind.init(rawValue:))
        let query = r.query.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [(summary: NoteSummary, snippet: String)] = []
        do {
            if query.isEmpty {
                candidates = try await Self.allNotes(library, archived: r.includeArchived).map { ($0, $0.snippet) }
            } else {
                let hits = try await library.search(NoteQuery(text: query, includeArchived: r.includeArchived,
                                                              kinds: kind.map { [$0] }, limit: Self.searchWindow))
                candidates = hits.map { ($0.summary, $0.snippet) }
            }
        } catch {
            throw Self.mapped(error, ref: query)
        }
        let tags = r.tags.map { $0.lowercased() }
        let found = candidates.filter { candidate in
            let m = candidate.summary.metadata
            guard visible(m, c), Self.isListed(m.state, archived: r.includeArchived) else { return false }
            if r.scope == .project, !inCallersProject(m, c) { return false }
            if let kind, m.kind != kind { return false }
            let noteTags = Set(m.tags.map { $0.lowercased() })
            return tags.allSatisfy(noteTags.contains)
        }
        return found.prefix(r.limit).map { Self.hit($0.summary, snippet: $0.snippet) }
    }

    func list(_ r: MCPListRequest, caller: MCPCaller) async throws -> [MCPNoteHit] {
        let library = try library()
        let c = who(caller)
        var sessionFilter: String?
        if let session = r.session {
            if session == "current" {
                guard let id = c.sessionID else { throw MCPBackendError.invalid(Self.currentSessionOnly) }
                sessionFilter = id
            } else {
                sessionFilter = session.lowercased()
            }
        }
        var projectFilter: String?
        if let project = r.project {
            if project == "current" {
                guard let cwd = c.cwd else { throw MCPBackendError.invalid(Self.currentSessionOnly) }
                projectFilter = cwd
            } else {
                projectFilter = context.realPath(project)
            }
        }
        let kind = r.kind.flatMap(NoteKind.init(rawValue:))
        let since = r.days.map { context.clock().addingTimeInterval(-Double($0) * 86_400) }
        let notes: [NoteSummary]
        do {
            notes = try await Self.allNotes(library, archived: r.includeArchived)
        } catch {
            throw Self.mapped(error, ref: "")
        }
        let found = notes.filter { s in
            let m = s.metadata
            guard visible(m, c), Self.isListed(m.state, archived: r.includeArchived) else { return false }
            if let kind, m.kind != kind { return false }
            if let pinned = r.pinned, m.pinned != pinned { return false }
            if let since, m.updated < since { return false }
            if let sessionFilter, !m.links.sessions.contains(where: { $0.lowercased() == sessionFilter }) { return false }
            if let projectFilter {
                let matches = m.links.projects.contains { project in
                    let real = context.realPath(project)
                    return MCPPaths.isInside(projectFilter, real) || MCPPaths.isInside(real, projectFilter)
                }
                if !matches { return false }
            }
            return true
        }
        return found.prefix(r.limit).map { Self.hit($0, snippet: $0.snippet) }
    }

    static let currentSessionOnly = "\"current\" 只適用於 CODD 啟動的 session；請改用 session id 或專案路徑"

    /// Active notes (and archived ones when asked), newest update first.
    static func allNotes(_ library: NotesLibrary, archived: Bool) async throws -> [NoteSummary] {
        var notes = try await library.list(.inbox, sort: .updated, limit: 100_000)
        if archived {
            notes += try await library.list(.archive, sort: .updated, limit: 100_000)
            notes.sort { $0.metadata.updated > $1.metadata.updated }
        }
        return notes
    }

    static func isListed(_ state: NoteState, archived: Bool) -> Bool {
        switch state {
        case .active: true
        case .archived: archived
        case .trashed: false
        }
    }

    static func hit(_ s: NoteSummary, snippet: String) -> MCPNoteHit {
        let m = s.metadata
        let state: String = if case .archived = m.state { "archived" } else { "active" }
        return MCPNoteHit(id: m.id.rawValue, uri: m.id.uri, title: m.title, kind: m.kind.rawValue, tags: m.tags, updated: m.updated,
                          snippet: snippet, path: s.fileURL.path, state: state)
    }

    // MARK: Reading

    /// The note behind `ref` when this caller may see it: OFF and out-of-scope notes are
    /// `notFound` (also in the trash); a visible trashed one is `trashed`; a purged one `purged`.
    private func resolveVisible(_ ref: String, _ library: NotesLibrary, _ c: Caller) async throws(MCPBackendError) -> NoteSummary {
        switch await library.resolve(ref) {
        case .note(let s):
            guard visible(s.metadata, c) else { throw .notFound(ref) }
            return s
        case .trashed(let s, let purgeAt):
            guard visible(s.metadata, c) else { throw .notFound(ref) }
            throw .trashed(id: s.id.rawValue, purgeAt: purgeAt)
        case .purged(let tombstone):
            throw .purged(id: tombstone.id.rawValue)
        case .unknown:
            throw .notFound(ref)
        }
    }

    func read(_ r: MCPReadRequest, caller: MCPCaller) async throws -> MCPNoteContent {
        let library = try library()
        let c = who(caller)
        let summary = try await resolveVisible(r.ref, library, c)
        let id = summary.id
        let rendered: NoteAIText.Rendered
        do {
            rendered = try await library.aiText(id, offset: r.offset, maxChars: r.maxChars, imageScope: imageScope(c))
        } catch {
            throw Self.mapped(error, ref: r.ref)
        }
        var images: [MCPImage] = []
        var extra: [String] = []
        for part in rendered.images {
            var files: [URL] = []
            if part.includeAnnotated, let annotated = part.annotated { files.append(annotated) }
            if part.includeOriginal { files.append(part.original) }
            for file in files {
                guard r.includeImages, images.count < MCPLimits.maxImageBlocks else {
                    extra.append(file.path)
                    continue
                }
                if let image = try? await library.aiImage(file, maxLongEdge: Self.imageLongEdge, maxBytes: Self.imageMaxBytes) {
                    images.append(MCPImage(data: image.data, mimeType: image.mimeType, path: file.path))
                } else {
                    extra.append(file.path)
                }
            }
        }
        await record("read", id, caller: caller, c, library)
        return MCPNoteContent(text: rendered.text, images: images, extraImagePaths: extra, truncated: rendered.truncated,
                              nextOffset: rendered.nextOffset, totalChars: rendered.totalChars)
    }

    /// The whole §3.7 text for a resource or the `note` prompt (one 50,000-character page, with a
    /// pointer to `notes_read` paging when the note is longer).
    private func fullText(_ ref: String, caller: MCPCaller) async throws -> String {
        let library = try library()
        let c = who(caller)
        let summary = try await resolveVisible(ref, library, c)
        let rendered: NoteAIText.Rendered
        do {
            rendered = try await library.aiText(summary.id, offset: 0, maxChars: MCPLimits.readMaxChars.upperBound,
                                                imageScope: imageScope(c))
        } catch {
            throw Self.mapped(error, ref: ref)
        }
        await record("read", summary.id, caller: caller, c, library)
        guard rendered.truncated, let next = rendered.nextOffset else { return rendered.text }
        return rendered.text + "\n\n（內容已截斷；用 notes_read 讀取 \(summary.id.uri) 並帶 offset=\(next) 取得下一段）"
    }

    func readResource(uri: String, caller: MCPCaller) async throws -> String {
        try await fullText(uri, caller: caller)
    }

    func promptNote(id: String, caller: MCPCaller) async throws -> String {
        try await fullText(id, caller: caller)
    }

    func resources(caller: MCPCaller) async throws -> [MCPResourceEntry] {
        let library = try library()
        let c = who(caller)
        let notes: [NoteSummary]
        do {
            notes = try await Self.allNotes(library, archived: false)
        } catch {
            throw Self.mapped(error, ref: "")
        }
        return notes.filter { visible($0.metadata, c) }.prefix(MCPLimits.maxResources).map {
            MCPResourceEntry(uri: $0.id.uri, name: $0.metadata.title, lastModified: $0.metadata.updated)
        }
    }

    // MARK: Writing

    func append(_ r: MCPAppendRequest, caller: MCPCaller) async throws -> MCPWriteResult {
        let library = try library()
        let c = who(caller)
        guard c.transientNotes == nil else { throw MCPBackendError.accessDenied(Self.transientReadOnly) }
        let summary = try await resolveVisible(r.ref, library, c)
        do {
            _ = try await library.appendFromAI(summary.id, markdown: r.markdown, heading: r.heading, actor: actor(caller, c))
        } catch {
            throw Self.mapped(error, ref: r.ref)
        }
        let heading = r.heading.map { "（### \($0)）" } ?? ""
        return MCPWriteResult(id: summary.id.rawValue, uri: summary.id.uri, text: "已附加到 \(summary.id.uri)\(heading)")
    }

    func write(_ r: MCPWriteRequest, caller: MCPCaller) async throws -> MCPWriteResult {
        let library = try library()
        guard context.writeEnabled else {
            throw MCPBackendError.accessDenied("notes_write 未開啟：使用者需要在 CODD 設定 › 筆記本 & MCP 打開「AI 可寫入」。")
        }
        let c = who(caller)
        guard c.transientNotes == nil else { throw MCPBackendError.accessDenied(Self.transientReadOnly) }
        let summary = try await resolveVisible(r.ref, library, c)
        do {
            _ = try await library.replaceBodyFromAI(summary.id, markdown: r.markdown, actor: actor(caller, c))
        } catch {
            throw Self.mapped(error, ref: r.ref)
        }
        return MCPWriteResult(id: summary.id.rawValue, uri: summary.id.uri, text: "已改寫 \(summary.id.uri)")
    }

    /// `notes_create`: always a new file and a new id (`NotesLibrary.create` never reuses either),
    /// so no existing note is read for it, let alone changed. The H1 is the title; a repeated H1 at
    /// the top of the body is dropped. A condense run (D32) only reads.
    func create(_ r: MCPCreateRequest, caller: MCPCaller) async throws -> MCPCreateResult {
        let library = try library()
        let c = who(caller)
        guard c.transientNotes == nil else { throw MCPBackendError.accessDenied(Self.transientReadOnly) }
        let title = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw MCPBackendError.invalid("notes_create 需要標題") }
        guard r.body.count <= MCPLimits.createMaxBodyCharacters else { throw MCPBackendError.tooLarge("筆記內容超過 100,000 字") }
        guard let kind = NoteKind(rawValue: r.kind), kind != .scratch else {
            throw MCPBackendError.invalid("notes_create 的 kind 只能是 note 或 prompt")
        }
        var links = NoteLinks()
        if let id = c.sessionID { links.sessions = [id] }
        if let project = c.session?.project, !project.isEmpty { links.projects = [project] }
        let document: NoteDocument
        do {
            document = try await library.create(NewNote(title: title, body: Self.createdBody(title: title, markdown: r.body), kind: kind,
                                                        tags: r.tags, links: links, ai: .append, createdBy: "ai"))
        } catch {
            throw Self.mapped(error, ref: "")
        }
        let id = document.metadata.id
        await record("create", id, caller: caller, c, library)
        return MCPCreateResult(id: id.rawValue, uri: id.uri, title: document.metadata.title, path: document.fileURL.path)
    }

    /// `# <title>`, a blank line, the AI's Markdown (CRLF as LF, a first line repeating the title
    /// as an H1 dropped, leading blank lines dropped), one final newline.
    static func createdBody(title: String, markdown: String) -> String {
        var md = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        while md.hasPrefix("\n") { md.removeFirst() }
        // The AI's text can never open a frontmatter: it always follows CODD's H1.
        let firstBreak = md.firstIndex(of: "\n") ?? md.endIndex
        let first = md[..<firstBreak].trimmingCharacters(in: .whitespaces)
        if first.hasPrefix("# "), first.dropFirst(2).trimmingCharacters(in: .whitespaces) == title {
            md = String(md[firstBreak...])
            while md.hasPrefix("\n") { md.removeFirst() }
        }
        while md.hasSuffix("\n") { md.removeLast() }
        return md.isEmpty ? "# \(title)\n" : "# \(title)\n\n\(md)\n"
    }

    func capabilities(caller: MCPCaller) async -> MCPBackendCapabilities {
        let transient = caller.sessionID.flatMap { context.transientNotes($0.uuidString) } != nil
        return MCPBackendCapabilities(writeEnabled: context.writeEnabled && !transient)
    }

    // MARK: Activity and errors

    private func actor(_ caller: MCPCaller, _ c: Caller) -> AIActor {
        AIActor(client: context.clientKind(for: caller), sessionID: c.sessionID, sessionTitle: c.session?.title, via: "mcp")
    }

    /// D20: a read by this caller (never a search hit).
    private func record(_ action: String, _ id: NoteID, caller: MCPCaller, _ c: Caller, _ library: NotesLibrary) async {
        await library.recordActivity(NoteActivityEvent(at: context.clock(), note: id, action: action, client: context.clientKind(for: caller),
                                                       session: c.sessionID, sessionTitle: c.session?.title, via: "mcp"))
    }

    /// CoddNotes errors as the refusals the model reads. An OFF refusal that slipped past the
    /// visibility check (the access changed meanwhile) is reported as an unknown ref.
    static func mapped(_ error: any Error, ref: String) -> any Error {
        if error is MCPBackendError { return error }
        guard let e = error as? NotesError else { return error }
        switch e {
        case .notFound: return MCPBackendError.notFound(ref)
        case .trashed(let id, let purgeAt): return MCPBackendError.trashed(id: id.rawValue, purgeAt: purgeAt)
        case .purged(let id): return MCPBackendError.purged(id: id.rawValue)
        case .unparsableFrontmatter: return MCPBackendError.invalid("這則筆記的 frontmatter 無法解析，請使用者先手動修正")
        case .accessDenied(let reason): return reason.contains("OFF") ? MCPBackendError.notFound(ref) : MCPBackendError.accessDenied(reason)
        case .tooLarge(let reason): return MCPBackendError.tooLarge(reason)
        case .io(let reason), .unavailable(let reason): return MCPBackendError.unavailable(reason)
        }
    }
}
