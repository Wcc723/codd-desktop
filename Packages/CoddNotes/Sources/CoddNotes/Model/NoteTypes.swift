import CoreGraphics
import Foundation

/// A note's stable id: `[a-z0-9]+(-[a-z0-9]+)*`, at most 48 characters (plan §3.6). It never
/// changes once written, so `codd://note/<id>` references stay valid across renames and rebuilds.
public struct NoteID: RawRepresentable, Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public static let maxLength = 48

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// `codd://note/<id>`, the recommended reference form.
    public var uri: String { "codd://note/\(rawValue)" }

    public static func < (lhs: NoteID, rhs: NoteID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard Self.isValid(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid note id"))
        }
        rawValue = raw
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    static func isValid(_ s: String) -> Bool {
        let u = s.utf8
        guard !u.isEmpty, u.count <= maxLength else { return false }
        var previousHyphen = true  // a leading hyphen is invalid
        for b in u {
            switch b {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                previousHyphen = false
            case UInt8(ascii: "-"):
                if previousHyphen { return false }
                previousHyphen = true
            default:
                return false
            }
        }
        return !previousHyphen
    }
}

public enum NoteKind: String, Sendable, Codable, CaseIterable {
    case note, prompt, scratch
}

public enum NoteAIAccess: String, Sendable, Codable, CaseIterable {
    case off, read, append
}

public enum NoteScope: String, Sendable, Codable, CaseIterable {
    case global, project
}

public enum ArchiveReason: String, Sendable, Codable {
    case auto, user, condense
}

public enum NoteState: Sendable, Equatable {
    case active
    case archived(at: Date, by: ArchiveReason)
    case trashed(at: Date)

    /// The index's `status` column value.
    public var status: String {
        switch self {
        case .active: "active"
        case .archived: "archived"
        case .trashed: "trashed"
        }
    }
}

/// Sessions are lowercase CODD session UUIDs; projects are `~`-abbreviated paths.
public struct NoteLinks: Sendable, Equatable {
    public var sessions: [String]
    public var projects: [String]

    public init(sessions: [String] = [], projects: [String] = []) {
        self.sessions = sessions
        self.projects = projects
    }

    public var isEmpty: Bool { sessions.isEmpty && projects.isEmpty }
}

public struct NoteFlags: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The frontmatter could not be parsed: indexed with defaults, metadata edits refused (D2).
    public static let unparsableFrontmatter = NoteFlags(rawValue: 1 << 0)
    /// Another file holds the same id: this one is indexed as `<id>-dup<n>` (D3, `ID 重複`).
    public static let duplicateID = NoteFlags(rawValue: 1 << 1)
    /// No frontmatter at all (a dropped-in file): a derived id; frontmatter written at the first save.
    public static let noFrontmatter = NoteFlags(rawValue: 1 << 2)
}

public enum NoteLineEnding: String, Sendable, Equatable {
    case lf, crlf
}

public struct NoteMetadata: Sendable, Equatable {
    public var id: NoteID
    public var title: String
    public var kind: NoteKind
    public var tags: [String]
    public var links: NoteLinks
    public var ai: NoteAIAccess
    public var scope: NoteScope
    public var pinned: Bool
    public var state: NoteState
    public var created: Date
    /// The frontmatter `updated:`, or the file's mtime when another program changed the file later.
    public var updated: Date
    public var sentAt: Date?
    public var sentTo: String?
    public var condensedFrom: [NoteID]
    public var condensedInto: NoteID?
    /// `user` or `ai`.
    public var createdBy: String

    public init(
        id: NoteID, title: String, kind: NoteKind = .note, tags: [String] = [], links: NoteLinks = NoteLinks(),
        ai: NoteAIAccess = .read, scope: NoteScope = .global, pinned: Bool = false, state: NoteState = .active,
        created: Date, updated: Date, sentAt: Date? = nil, sentTo: String? = nil, condensedFrom: [NoteID] = [],
        condensedInto: NoteID? = nil, createdBy: String = "user"
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.tags = tags
        self.links = links
        self.ai = ai
        self.scope = scope
        self.pinned = pinned
        self.state = state
        self.created = created
        self.updated = updated
        self.sentAt = sentAt
        self.sentTo = sentTo
        self.condensedFrom = condensedFrom
        self.condensedInto = condensedInto
        self.createdBy = createdBy
    }

    /// A PROMPT that was never sent (`Prompt · 草稿`).
    public var isPromptDraft: Bool { kind == .prompt && sentAt == nil }

    /// The scope's primary project: the first linked project (plan §3.2).
    public var primaryProject: String? { links.projects.first }
}

public struct NoteDocument: Sendable, Equatable {
    public var metadata: NoteMetadata
    /// The Markdown body after the frontmatter, with LF line ends (a CRLF file is converted back on save).
    public var body: String
    public var fileURL: URL
    /// Relative to the notes root, `/`-separated, NFC (`.codd/trash/…` for a trashed note).
    public var relativePath: String
    /// Lowercase hex SHA-256 of the file's bytes: the `basedOn` value for `save`.
    public var contentHash: String
    public var flags: NoteFlags
    public var lineEnding: NoteLineEnding

    public init(
        metadata: NoteMetadata, body: String, fileURL: URL, relativePath: String, contentHash: String,
        flags: NoteFlags, lineEnding: NoteLineEnding
    ) {
        self.metadata = metadata
        self.body = body
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.flags = flags
        self.lineEnding = lineEnding
    }
}

public enum ExemptReason: String, Sendable {
    case pinned, linkedLiveSession, readByLiveSession, kept
}

public struct NoteSummary: Sendable, Equatable, Identifiable {
    public var metadata: NoteMetadata
    /// Two lines of plain text from the body (Markdown stripped, the H1 left out).
    public var snippet: String
    /// Images in `assets/<id>/` (not counting `.orig` copies) and their bytes.
    public var assetCount: Int
    public var assetBytes: Int
    /// The user's last activity (D29): edits, opening ≥ 3 s, pin, kind / tag / link changes, send.
    /// AI reads and writes never count.
    public var lastActivity: Date
    /// Set while the note is STALE.
    public var staleSince: Date?
    /// When retention will archive it (nil: never, exempt, or not active).
    public var archivesAt: Date?
    /// When a trashed note is purged.
    public var purgeAt: Date?
    public var exempt: ExemptReason?
    public var flags: NoteFlags
    public var fileURL: URL

    public var id: NoteID { metadata.id }

    public init(
        metadata: NoteMetadata, snippet: String, assetCount: Int, assetBytes: Int, lastActivity: Date,
        staleSince: Date?, archivesAt: Date?, purgeAt: Date?, exempt: ExemptReason?, flags: NoteFlags, fileURL: URL
    ) {
        self.metadata = metadata
        self.snippet = snippet
        self.assetCount = assetCount
        self.assetBytes = assetBytes
        self.lastActivity = lastActivity
        self.staleSince = staleSince
        self.archivesAt = archivesAt
        self.purgeAt = purgeAt
        self.exempt = exempt
        self.flags = flags
        self.fileURL = fileURL
    }
}

public enum SmartList: Sendable, Hashable {
    case inbox, pinned, prompts, stale, archive, trash
    /// Active notes linking exactly this (`~`-abbreviated) project path.
    case project(String)
}

public enum NoteSort: Sendable {
    case updated, created, title
}

public struct NotesCounts: Sendable, Equatable {
    public var inbox: Int
    public var pinned: Int
    public var prompts: Int
    public var stale: Int
    public var archive: Int
    public var trash: Int
    public var byProject: [String: Int]

    public init(inbox: Int = 0, pinned: Int = 0, prompts: Int = 0, stale: Int = 0, archive: Int = 0, trash: Int = 0,
                byProject: [String: Int] = [:]) {
        self.inbox = inbox
        self.pinned = pinned
        self.prompts = prompts
        self.stale = stale
        self.archive = archive
        self.trash = trash
        self.byProject = byProject
    }
}

public struct NoteQuery: Sendable {
    /// Whitespace-separated terms, `#tag` filters and `"quoted phrases"`, all AND-ed (D6).
    public var text: String
    public var includeArchived: Bool
    public var includeTrashed: Bool
    public var kinds: Set<NoteKind>?
    /// Only notes linking this `~`-abbreviated project path.
    public var project: String?
    public var limit: Int

    public init(text: String, includeArchived: Bool = false, includeTrashed: Bool = false, kinds: Set<NoteKind>? = nil,
                project: String? = nil, limit: Int = 50) {
        self.text = text
        self.includeArchived = includeArchived
        self.includeTrashed = includeTrashed
        self.kinds = kinds
        self.project = project
        self.limit = limit
    }
}

public struct NoteSearchHit: Sendable, Equatable {
    public var summary: NoteSummary
    /// Plain text around the first match (from the stored Markdown-stripped body, original case).
    public var snippet: String
    /// UTF-16 ranges into `snippet` of every term occurrence.
    public var highlights: [NSRange]
    /// bm25 when any term used the FTS index (lower is better), else 0.
    public var score: Double

    public init(summary: NoteSummary, snippet: String, highlights: [NSRange], score: Double) {
        self.summary = summary
        self.snippet = snippet
        self.highlights = highlights
        self.score = score
    }
}

public struct NewNote: Sendable {
    public var title: String
    public var body: String?
    public var kind: NoteKind
    public var tags: [String]
    public var links: NoteLinks
    /// nil = the library's default access (Settings › 新筆記預設 AI 存取).
    public var ai: NoteAIAccess?
    /// nil = `project` when the note is created linked to a session / project, else `global` (D20).
    public var scope: NoteScope?
    /// `user` or `ai`.
    public var createdBy: String
    /// The id's word part instead of the title's / tags' words (D32: `cleanup-1015` gives
    /// `cleanup-1015-xxxx`); `[a-z0-9-]`, ≤ 30 characters, else ignored.
    public var idPrefix: String?
    /// D32: the notes a condensed summary was made from (`condensedFrom:`).
    public var condensedFrom: [NoteID]

    public init(title: String, body: String? = nil, kind: NoteKind = .note, tags: [String] = [],
                links: NoteLinks = NoteLinks(), ai: NoteAIAccess? = nil, scope: NoteScope? = nil,
                createdBy: String = "user", idPrefix: String? = nil, condensedFrom: [NoteID] = []) {
        self.title = title
        self.body = body
        self.kind = kind
        self.tags = tags
        self.links = links
        self.ai = ai
        self.scope = scope
        self.createdBy = createdBy
        self.idPrefix = idPrefix
        self.condensedFrom = condensedFrom
    }
}

public enum SaveOutcome: Sendable, Equatable {
    case saved(NoteDocument)
    /// The file changed since `basedOn`; nothing was written.
    case conflict(disk: NoteDocument)
}

public enum MetadataChange: Sendable {
    case kind(NoteKind)
    case tags([String])
    case addTag(String)
    case removeTag(String)
    case linkSession(String)
    case unlinkSession(String)
    case linkProject(String)
    case unlinkProject(String)
    case ai(NoteAIAccess)
    /// `primaryProject` (when given) becomes the first linked project.
    case scope(NoteScope, primaryProject: String?)
    case pinned(Bool)
    case markSent(at: Date, to: String)
    /// D32: the summary an archived original was condensed into (nil removes it).
    case condensedInto(NoteID?)
}

public struct AIActor: Sendable, Equatable {
    public var client: String?
    public var sessionID: String?
    public var sessionTitle: String?
    /// `mcp`, `hook` or `url`.
    public var via: String

    public init(client: String? = nil, sessionID: String? = nil, sessionTitle: String? = nil, via: String) {
        self.client = client
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.via = via
    }
}

/// One line of `.codd/activity.jsonl` (plan §3.4, D20).
public struct NoteActivityEvent: Sendable, Codable, Equatable {
    public var at: Date
    public var note: NoteID
    /// `read`, `append`, `write`, `expand` or `url`.
    public var action: String
    public var client: String?
    public var session: String?
    public var sessionTitle: String?
    public var via: String

    public init(at: Date, note: NoteID, action: String, client: String? = nil, session: String? = nil,
                sessionTitle: String? = nil, via: String) {
        self.at = at
        self.note = note
        self.action = action
        self.client = client
        self.session = session
        self.sessionTitle = sessionTitle
        self.via = via
    }
}

public struct AssetRef: Sendable, Equatable {
    /// Relative to the notes root: `assets/<id>/<hash6>.png`.
    public var relativePath: String
    public var pixelSize: CGSize
    public var bytes: Int
    /// Downscaled to the long-edge limit.
    public var resized: Bool
    /// Identical bytes were already stored; nothing was written.
    public var reused: Bool
    /// The link to put in the note: relative to the note file's folder (`assets/…` for a note at the
    /// root, `../assets/…` for one in a sub-folder).
    public var markdownPath: String
    /// `assets/<id>/<hash6>.orig.<ext>` when 保留原檔 kept the original bytes.
    public var originalPath: String?

    public init(relativePath: String, pixelSize: CGSize, bytes: Int, resized: Bool, reused: Bool,
                markdownPath: String? = nil, originalPath: String? = nil) {
        self.relativePath = relativePath
        self.pixelSize = pixelSize
        self.bytes = bytes
        self.resized = resized
        self.reused = reused
        self.markdownPath = markdownPath ?? relativePath
        self.originalPath = originalPath
    }
}

public struct AssetInfo: Sendable, Equatable {
    public var relativePath: String
    public var url: URL
    public var bytes: Int
    public var pixelSize: CGSize
    public var isOriginalCopy: Bool
    /// The body links it (a `.orig` copy counts as referenced when its image is).
    public var referenced: Bool
    public var modified: Date

    public init(relativePath: String, url: URL, bytes: Int, pixelSize: CGSize, isOriginalCopy: Bool,
                referenced: Bool, modified: Date) {
        self.relativePath = relativePath
        self.url = url
        self.bytes = bytes
        self.pixelSize = pixelSize
        self.isOriginalCopy = isOriginalCopy
        self.referenced = referenced
        self.modified = modified
    }
}

public struct NoteSnapshotInfo: Sendable, Equatable, Identifiable {
    /// The snapshot's file name: `<yyyyMMdd-HHmmss-SSS>-<hash8>.md` (UTC).
    public var id: String
    public var takenAt: Date
    public var bytes: Int
    /// Why a forced snapshot was taken (`ai-append`, `restore`, `trash`, …); nil for a save.
    public var reason: String?

    public init(id: String, takenAt: Date, bytes: Int, reason: String?) {
        self.id = id
        self.takenAt = takenAt
        self.bytes = bytes
        self.reason = reason
    }
}

/// Settings › 清理 for notes (D29). nil days = never.
public struct RetentionPolicy: Sendable, Equatable {
    public var staleDays: Int?
    public var archiveDays: Int?
    public var scratchArchiveDays: Int?
    public var trashPurgeDays: Int
    public var tombstoneDays: Int?
    /// 豁免: pinned notes and notes used by a live session are not marked stale or archived.
    public var exempt: Bool

    public init(staleDays: Int? = 14, archiveDays: Int? = 30, scratchArchiveDays: Int? = 7, trashPurgeDays: Int = 30,
                tombstoneDays: Int? = 90, exempt: Bool = true) {
        self.staleDays = staleDays
        self.archiveDays = archiveDays
        self.scratchArchiveDays = scratchArchiveDays
        self.trashPurgeDays = trashPurgeDays
        self.tombstoneDays = tombstoneDays
        self.exempt = exempt
    }

    public static let defaults = RetentionPolicy()
}

public struct RetentionReport: Sendable, Equatable {
    public var staleIDs: [NoteID]
    public var archived: [NoteID]
    public var purged: [NoteID]
    public var snapshotsRemoved: Int

    public init(staleIDs: [NoteID] = [], archived: [NoteID] = [], purged: [NoteID] = [], snapshotsRemoved: Int = 0) {
        self.staleIDs = staleIDs
        self.archived = archived
        self.purged = purged
        self.snapshotsRemoved = snapshotsRemoved
    }
}

/// One row of the Cleanup page's NOTES tab (or, for `unusedAsset`, its FILES tab), with the
/// artboard's texts already formatted.
public struct NoteCleanupCandidate: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        case stale(days: Int)
        case archivesSoon(days: Int)
        case sentPrompt(days: Int)
        case scratch(days: Int)
        case duplicate(of: NoteID, percent: Int)
        case longNote(sections: Int, olderThanDays: Int)
        case unusedAsset(path: String, days: Int)
    }

    public enum AIHint: Sendable, Equatable {
        case keep(lastReadDaysAgo: Int)
        case condense
        case read(daysAgo: Int)

        /// The artboard text (`AI 2d 前讀取 → 建議保留`, `適合濃縮`, `AI 9d 前讀取`).
        public var text: String {
            switch self {
            case .keep(let d): "AI \(d)d 前讀取 → 建議保留"
            case .condense: "適合濃縮"
            case .read(let d): "AI \(d)d 前讀取"
            }
        }
    }

    /// The note. NOTES reasons give one row per note; an `unusedAsset` row shares its note's id, so
    /// key rows by ``rowKey``.
    public var id: NoteID
    public var reason: Reason
    public var title: String
    public var why: String
    public var sub: String
    public var badge: String
    public var aiHint: AIHint?
    /// The AI column text (`適合濃縮舊段落` for a long note, else ``AIHint/text``).
    public var aiHintText: String?
    public var suggestsCondense: Bool

    public var rowKey: String {
        if case .unusedAsset(let path, _) = reason { return "\(id.rawValue)#\(path)" }
        return id.rawValue
    }

    public init(id: NoteID, reason: Reason, title: String, why: String, sub: String, badge: String, aiHint: AIHint?,
                aiHintText: String? = nil, suggestsCondense: Bool) {
        self.id = id
        self.reason = reason
        self.title = title
        self.why = why
        self.sub = sub
        self.badge = badge
        self.aiHint = aiHint
        self.aiHintText = aiHintText ?? aiHint?.text
        self.suggestsCondense = suggestsCondense
    }
}

/// `.codd/tombstones.json` entry: what remains of a purged note, so old references answer 已刪除.
public struct Tombstone: Sendable, Equatable, Codable {
    public var id: NoteID
    public var title: String
    public var trashedAt: Date
    public var purgedAt: Date

    public init(id: NoteID, title: String, trashedAt: Date, purgedAt: Date) {
        self.id = id
        self.title = title
        self.trashedAt = trashedAt
        self.purgedAt = purgedAt
    }
}

/// An H2 / H3 section of a body whose heading starts with a date (§3.4 long-note rule, D32 input).
public struct NoteSection: Sendable, Equatable {
    /// The heading text without the `##` marks.
    public var heading: String
    /// The heading's date (local start of day); nil when the heading carries none.
    public var date: Date?
    /// UTF-16 range in the body, from the heading line to the end of the section.
    public var range: NSRange
    public var text: String

    public init(heading: String, date: Date?, range: NSRange, text: String) {
        self.heading = heading
        self.date = date
        self.range = range
        self.text = text
    }
}

public enum NoteResolution: Sendable, Equatable {
    /// Active or archived.
    case note(NoteSummary)
    case trashed(NoteSummary, purgeAt: Date)
    case purged(Tombstone)
    case unknown(String)
}

public enum NotesChange: Sendable, Equatable {
    /// Written by CODD (saves, metadata, AI writes, assets, retention).
    case changed([NoteID])
    /// Removed from the index (deleted on disk or purged).
    case removed([NoteID])
    /// Created or changed on disk by another program (the watcher; never CODD's own writes).
    case external([NoteID])
    case indexRebuilt(count: Int)
    case activity(NoteID)
    /// The notes folder became unusable (`// 筆記資料夾無法使用：<reason>`).
    case unavailable(String)
}

/// The app's editor: saved before an AI write so the AI never appends to a stale file.
public protocol OpenNoteCoordinator: Sendable {
    func flushPendingEdits(of id: NoteID) async
    /// An AI write (`appendFromAI` / `replaceBodyFromAI`) landed: CODD's own write, so the
    /// watcher stays quiet and an open editor learns of it only here.
    func didWriteFromAI(_ document: NoteDocument) async
}

extension OpenNoteCoordinator {
    public func didWriteFromAI(_ document: NoteDocument) async {}
}

public struct NotesOpenReport: Sendable, Equatable {
    public var rebuilt: Bool
    /// `missing`, `corrupt`, `version`, `root` or `requested` when rebuilt.
    public var reason: String?
    public var count: Int
    public var buildMs: Double
    public var warnings: [String]

    public init(rebuilt: Bool, reason: String?, count: Int, buildMs: Double, warnings: [String]) {
        self.rebuilt = rebuilt
        self.reason = reason
        self.count = count
        self.buildMs = buildMs
        self.warnings = warnings
    }
}

public enum NotesError: Error, Sendable, Equatable {
    case notFound(NoteID)
    case trashed(NoteID, purgeAt: Date)
    case purged(NoteID)
    case unparsableFrontmatter(NoteID)
    case accessDenied(String)
    case tooLarge(String)
    case io(String)
    case unavailable(String)
}

extension NotesError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notFound(let id): "找不到筆記 \(id.rawValue)"
        case .trashed: "這則筆記在 CODD 垃圾桶"
        case .purged: "這則筆記已永久刪除"
        case .unparsableFrontmatter: "這則筆記的 frontmatter 無法解析，請先手動修正"
        case .accessDenied(let s), .tooLarge(let s), .io(let s), .unavailable(let s): s
        }
    }
}
