import Foundation

/// What `initialize` reports about the server.
public struct MCPServerInfo: Sendable, Equatable {
    public var name: String
    public var title: String
    /// The app version (`CFBundleShortVersionString`).
    public var version: String
    /// Sent in `initialize`; Claude Code cuts server instructions at 4,096 characters.
    public var instructions: String

    public init(name: String = "codd", title: String = "CODD notes", version: String,
                instructions: String = MCPInstructions.notes)
    {
        self.name = name
        self.title = title
        self.version = version
        self.instructions = instructions
    }
}

/// How a `tools/call` ended, for the app's activity and diagnostics.
public enum MCPToolOutcome: Sendable, Equatable {
    case ok
    /// A tool result with `isError: true` the model can read: a backend refusal (OFF, READ,
    /// trashed, …) or invalid arguments. The text is what the model was told.
    case isError(String)
    /// A non-backend error was thrown; the model got a generic message, this carries the error's
    /// type name for the log (never a stack trace, never note content).
    case failed(String)
}

/// Everything the server saw, in the order it happened. `request` comes first for every request
/// and notification, then `initialized` / `tool` / `resource` once that request is answered; a
/// successful `notes_create` adds `created` right before its `tool`.
public enum MCPEvent: Sendable, Equatable {
    case initialized(caller: MCPCaller, clientName: String?, clientVersion: String?, protocolVersion: String, at: Date)
    case tool(caller: MCPCaller, name: String, outcome: MCPToolOutcome, ms: Double, at: Date)
    case resource(caller: MCPCaller, uri: String, ok: Bool, at: Date)
    case request(caller: MCPCaller, method: String, at: Date)
    /// `notes_create` made a new note (the app's toast `Claude 建立了筆記：<title>`): the backend's
    /// id and title as it stored them.
    case created(caller: MCPCaller, id: String, uri: String, title: String, at: Date)
}

// MARK: - Requests to the backend (validated and clamped by the server)

/// `notes_search`. `scope` only narrows what the backend lets this caller see (D17).
public struct MCPSearchRequest: Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable, CaseIterable {
        /// The caller's project and the notes linked to its session.
        case project
        /// Every note this caller may see (the default).
        case all
    }

    public var query: String
    public var scope: Scope
    /// Without `#`, trimmed, deduplicated.
    public var tags: [String]
    /// `note`, `prompt` or `scratch` (lowercase).
    public var kind: String?
    public var includeArchived: Bool
    /// 1…20, default 10.
    public var limit: Int

    public init(query: String, scope: Scope = .all, tags: [String] = [], kind: String? = nil,
                includeArchived: Bool = false, limit: Int = 10)
    {
        self.query = query
        self.scope = scope
        self.tags = tags
        self.kind = kind
        self.includeArchived = includeArchived
        self.limit = limit
    }
}

/// `notes_list`: newest first.
public struct MCPListRequest: Sendable, Equatable {
    /// `"current"` (the calling session) or a lowercase session UUID.
    public var session: String?
    /// `"current"` (the calling session's project) or a path as the model gave it.
    public var project: String?
    public var kind: String?
    public var pinned: Bool?
    /// Only notes updated in the last `days` days (1…3650).
    public var days: Int?
    public var includeArchived: Bool
    /// 1…50, default 20.
    public var limit: Int

    public init(session: String? = nil, project: String? = nil, kind: String? = nil, pinned: Bool? = nil,
                days: Int? = nil, includeArchived: Bool = false, limit: Int = 20)
    {
        self.session = session
        self.project = project
        self.kind = kind
        self.pinned = pinned
        self.days = days
        self.includeArchived = includeArchived
        self.limit = limit
    }
}

/// `notes_read`. `ref` is passed as given (trimmed): an id, `codd://note/<id>`, `[[note:<id>]]`
/// or `@<server>:codd://note/<id>`; the backend parses it.
public struct MCPReadRequest: Sendable, Equatable {
    public var ref: String
    /// Character offset into the note's AI text (≥ 0).
    public var offset: Int
    /// 1,000…50,000, default 12,000 (D17: Claude caps a result at 25,000 tokens and CJK costs
    /// about a token per character).
    public var maxChars: Int
    public var includeImages: Bool

    public init(ref: String, offset: Int = 0, maxChars: Int = 12_000, includeImages: Bool = true) {
        self.ref = ref
        self.offset = offset
        self.maxChars = maxChars
        self.includeImages = includeImages
    }
}

/// `notes_append`.
public struct MCPAppendRequest: Sendable, Equatable {
    public var ref: String
    /// Non-empty, at most ``MCPLimits/appendMaxCharacters`` characters.
    public var markdown: String
    /// One line (newlines folded to spaces), at most ``MCPLimits/headingMaxCharacters``; nil →
    /// the backend's default heading (`AI 附加 · HH:mm`).
    public var heading: String?

    public init(ref: String, markdown: String, heading: String? = nil) {
        self.ref = ref
        self.markdown = markdown
        self.heading = heading
    }
}

/// `notes_write`: replaces the body after the H1 line.
public struct MCPWriteRequest: Sendable, Equatable {
    public var ref: String
    /// Non-empty, at most ``MCPLimits/writeMaxCharacters`` characters.
    public var markdown: String

    public init(ref: String, markdown: String) {
        self.ref = ref
        self.markdown = markdown
    }
}

/// `notes_create`: a NEW note in INBOX. The caller decides nothing else: the backend links it to
/// the calling session and its project, gives it AI access APPEND and never touches another note.
public struct MCPCreateRequest: Sendable, Equatable {
    /// One line (newlines folded), trimmed, a leading Markdown heading marker (`# `) removed,
    /// non-empty, at most ``MCPLimits/createTitleMaxCharacters`` characters.
    public var title: String
    /// The Markdown body without the title line (non-blank, at most
    /// ``MCPLimits/createMaxBodyCharacters`` characters).
    public var body: String
    /// Normalized like the Notebook's tag editor: trimmed, `#` stripped at both ends, spaces as
    /// `-`, NFC, deduplicated ignoring case; at most ``MCPLimits/createMaxTags``.
    public var tags: [String]
    /// `note` (the default) or `prompt`.
    public var kind: String

    public init(title: String, body: String, tags: [String] = [], kind: String = "note") {
        self.title = title
        self.body = body
        self.tags = tags
        self.kind = kind
    }
}

/// What `notes_create` reports back to the model (and, through ``MCPEvent/created(caller:id:uri:title:at:)``,
/// to the app).
public struct MCPCreateResult: Sendable, Equatable {
    public var id: String
    /// `codd://note/<id>`.
    public var uri: String
    /// The title the note got.
    public var title: String
    /// The new note file's absolute path.
    public var path: String

    public init(id: String, uri: String, title: String, path: String) {
        self.id = id
        self.uri = uri
        self.title = title
        self.path = path
    }
}

// MARK: - Results from the backend

/// One search / list result.
public struct MCPNoteHit: Sendable, Equatable {
    public var id: String
    /// `codd://note/<id>`.
    public var uri: String
    public var title: String
    /// `note`, `prompt` or `scratch`.
    public var kind: String
    public var tags: [String]
    public var updated: Date
    /// Plain text; newlines are folded to spaces in the tool's text output.
    public var snippet: String
    /// The note file's absolute path.
    public var path: String
    /// `active` or `archived`.
    public var state: String

    public init(id: String, uri: String, title: String, kind: String, tags: [String], updated: Date,
                snippet: String, path: String, state: String)
    {
        self.id = id
        self.uri = uri
        self.title = title
        self.kind = kind
        self.tags = tags
        self.updated = updated
        self.snippet = snippet
        self.path = path
        self.state = state
    }
}

/// An image for `notes_read`, already sized for Claude (D17: ≤ 1568 px long edge, ≤ 900 KB).
public struct MCPImage: Sendable, Equatable {
    public var data: Data
    /// `image/png`, `image/jpeg`, `image/gif` or `image/webp`.
    public var mimeType: String
    /// The absolute path of the file the data came from (the annotated copy when one was sent).
    public var path: String

    public init(data: Data, mimeType: String, path: String) {
        self.data = data
        self.mimeType = mimeType
        self.path = path
    }
}

/// A page of a note's AI text (§3.7) with its images.
public struct MCPNoteContent: Sendable, Equatable {
    public var text: String
    /// At most ``MCPLimits/maxImageBlocks`` become image blocks; the server lists the rest by path.
    public var images: [MCPImage]
    /// Images not attached (over the cap, too big, or `include_images: false`), absolute paths.
    public var extraImagePaths: [String]
    /// True when the text stops before the end of the note.
    public var truncated: Bool
    /// Where the next page starts (the `offset` to pass), when truncated.
    public var nextOffset: Int?
    /// The length of the whole AI text in characters, for the paging line `共 N 字`. Optional
    /// (an addition to the brief's contract): without it the line leaves the total out.
    public var totalChars: Int?

    public init(text: String, images: [MCPImage] = [], extraImagePaths: [String] = [], truncated: Bool = false,
                nextOffset: Int? = nil, totalChars: Int? = nil)
    {
        self.text = text
        self.images = images
        self.extraImagePaths = extraImagePaths
        self.truncated = truncated
        self.nextOffset = nextOffset
        self.totalChars = totalChars
    }
}

/// What an append / write reports back to the model.
public struct MCPWriteResult: Sendable, Equatable {
    public var id: String
    public var uri: String
    /// A short confirmation, e.g. `已附加到 codd://note/<id>（### AI 附加 · 10:12）`.
    public var text: String

    public init(id: String, uri: String, text: String) {
        self.id = id
        self.uri = uri
        self.text = text
    }
}

/// One entry of `resources/list`.
public struct MCPResourceEntry: Sendable, Equatable {
    /// `codd://note/<id>`.
    public var uri: String
    /// The note title.
    public var name: String
    /// `text/markdown`.
    public var mimeType: String
    public var lastModified: Date?

    public init(uri: String, name: String, mimeType: String = "text/markdown", lastModified: Date? = nil) {
        self.uri = uri
        self.name = name
        self.mimeType = mimeType
        self.lastModified = lastModified
    }
}

/// Per-caller switches, asked for on every `tools/list` and `notes_write` call.
public struct MCPBackendCapabilities: Sendable, Equatable {
    /// Settings › AI 可寫入: `notes_write` is listed and callable only while true.
    public var writeEnabled: Bool

    public init(writeEnabled: Bool = false) { self.writeEnabled = writeEnabled }
}

/// The refusals a backend reports. Tools turn them into `isError` results the model reads;
/// resources and prompts into JSON-RPC `-32602` with `data.state`.
public enum MCPBackendError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No visible note for this ref (OFF and out-of-scope notes are reported this way too, so
    /// their existence never leaks). Carries the ref as the caller wrote it.
    case notFound(String)
    case trashed(id: String, purgeAt: Date?)
    case purged(id: String)
    /// A user-facing reason, e.g. `這則筆記的 AI 存取是 READ，不能附加`.
    case accessDenied(String)
    case invalid(String)
    case tooLarge(String)
    case unavailable(String)

    /// The text the model (or a resource error) gets, in 繁體中文 like the rest of CODD's AI copy.
    /// The trashed date is a calendar day in `timeZone`.
    public func message(timeZone: TimeZone = .current) -> String {
        switch self {
        case .notFound(let ref):
            return "找不到筆記 \(MCPText.clip(ref, 200))"
        case .trashed(_, let purgeAt?):
            return "這則筆記在 CODD 垃圾桶（\(MCPDateText(timeZone: timeZone).day(purgeAt)) 永久刪除），請使用者先還原"
        case .trashed(_, nil):
            return "這則筆記在 CODD 垃圾桶，請使用者先還原"
        case .purged:
            return "這則筆記已永久刪除"
        case .accessDenied(let reason):
            return reason.isEmpty ? "AI 無法存取這則筆記" : reason
        case .invalid(let reason):
            return reason.isEmpty ? "參數不正確" : reason
        case .tooLarge(let reason):
            return reason.isEmpty ? "內容太大" : reason
        case .unavailable(let reason):
            return reason.isEmpty ? "CODD 筆記本目前無法使用" : "CODD 筆記本目前無法使用：\(reason)"
        }
    }

    public var description: String { message() }
}

/// The notes behind the server (the app's adapter over CoddNotes, I2a). Called concurrently from
/// many requests; never on the main actor by the server. Every method applies D17's visibility
/// for `caller`: OFF notes and notes outside the caller's scope do not exist for it.
public protocol MCPNotesBackend: Sendable {
    func search(_ r: MCPSearchRequest, caller: MCPCaller) async throws -> [MCPNoteHit]
    func list(_ r: MCPListRequest, caller: MCPCaller) async throws -> [MCPNoteHit]
    func read(_ r: MCPReadRequest, caller: MCPCaller) async throws -> MCPNoteContent
    func append(_ r: MCPAppendRequest, caller: MCPCaller) async throws -> MCPWriteResult
    func write(_ r: MCPWriteRequest, caller: MCPCaller) async throws -> MCPWriteResult
    /// `notes_create`: a new note only (never an existing one), linked to the caller's session and
    /// project, AI access APPEND, its creation recorded as AI activity.
    func create(_ r: MCPCreateRequest, caller: MCPCaller) async throws -> MCPCreateResult
    /// At most 200 visible active notes, newest first (the server cuts longer lists).
    func resources(caller: MCPCaller) async throws -> [MCPResourceEntry]
    /// The §3.7 text of `codd://note/<id>`.
    func readResource(uri: String, caller: MCPCaller) async throws -> String
    /// The §3.7 text for the `note` prompt; `id` as the user typed it.
    func promptNote(id: String, caller: MCPCaller) async throws -> String
    func capabilities(caller: MCPCaller) async -> MCPBackendCapabilities
}

/// The limits the server enforces before calling the backend.
public enum MCPLimits {
    public static let searchLimit = 1...20
    public static let searchDefaultLimit = 10
    public static let listLimit = 1...50
    public static let listDefaultLimit = 20
    public static let listDays = 1...3650
    public static let readMaxChars = 1_000...50_000
    public static let readDefaultMaxChars = 12_000
    /// Image blocks per `notes_read` (D17; Claude counts about 1,600 tokens per image).
    public static let maxImageBlocks = 4
    /// Raw image bytes per `notes_read` result; images past it are listed by path instead, so a
    /// misbehaving backend cannot push a result toward the hook server's 16 MiB response cap.
    public static let maxImageBytesPerResult = 8 * 1024 * 1024
    public static let appendMaxCharacters = 20_000
    /// `notes_write` replaces a whole body; it may carry what one `notes_read` page shows.
    public static let writeMaxCharacters = 50_000
    public static let headingMaxCharacters = 200
    /// `notes_create`'s body, in characters like `notes_append` / `notes_write`. Well under the
    /// hook server's 1 MiB cap on the whole `POST /mcp` body: even 4-byte characters, or 3-byte
    /// ones sent as `\uXXXX` escapes, stay below it with the JSON-RPC envelope, so the tool's own
    /// refusal (with its notes_append hint) is always the one that answers, never a bare HTTP 413.
    public static let createMaxBodyCharacters = 100_000
    public static let createTitleMaxCharacters = 200
    public static let createMaxTags = 20
    public static let createTagMaxCharacters = 64
    public static let refMaxCharacters = 500
    public static let queryMaxCharacters = 1_000
    public static let maxResources = 200
}
