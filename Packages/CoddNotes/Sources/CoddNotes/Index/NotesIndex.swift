import Foundation
import GRDB

/// One indexed note: everything a list row, a search hit or a retention decision needs without
/// reading the file. Lists are stored `\u{1F}`-joined so a row decodes without JSON.
struct IndexRow: Sendable, Equatable {
    var rowid: Int64?
    var id: NoteID
    /// Relative to the notes root, NFC, `/`-separated.
    var path: String
    /// The `id:` the file itself declares (nil: none / unparsable / not a valid id).
    var declaredID: String?
    var title: String
    var kind: NoteKind
    /// nil: not set in the file, the default access applies.
    var ai: NoteAIAccess?
    var scope: NoteScope
    var pinned: Bool
    /// `active`, `archived` or `trashed`.
    var status: String
    var created: Double
    /// Effective `updated` (frontmatter or a later external mtime).
    var updated: Double
    /// The frontmatter `updated:` alone (retention counts this, never a bare mtime).
    var updatedFM: Double?
    var archived: Double?
    var archivedBy: ArchiveReason?
    var trashed: Double?
    var sent: Double?
    var sentTo: String?
    var condensedFrom: [NoteID]
    var condensedInto: NoteID?
    var createdBy: String
    var tags: [String]
    var sessions: [String]
    var projects: [String]
    var mtime: Double
    var size: Int
    var birth: Double
    var hash: String
    var snippet: String
    var bodyText: String
    var assetCount: Int
    var assetBytes: Int
    var flags: NoteFlags
    var lineEnding: NoteLineEnding

    var isTrashed: Bool { status == "trashed" }
    var isArchived: Bool { status == "archived" }
    var isActive: Bool { status == "active" }
}

/// The derived SQLite index (D5, §3.5) through GRDB, FTS5 by raw SQL. Owned by the
/// `NotesLibrary` actor; never touched from anywhere else.
final class NotesIndex {
    static let schemaVersion = 1
    static let sep = "\u{1F}"

    let url: URL
    private(set) var pool: DatabasePool

    private init(url: URL, pool: DatabasePool) {
        self.url = url
        self.pool = pool
    }

    /// Opens the index, recreating it when missing, unopenable, failing `quick_check`, of another
    /// schema version or built for another notes root. `rebuildReason` is nil for a usable index.
    static func open(url: URL, rootPath: String) -> Result<(NotesIndex, rebuildReason: String?), NotesError> {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: url.path)
        var reason: String? = existed ? nil : "missing"
        if existed {
            switch check(url: url, rootPath: rootPath) {
            case .ok: break
            case .rebuild(let r): reason = r
            }
            if reason != nil { removeFiles(url) }
        }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            let pool = try makePool(url)
            let index = NotesIndex(url: url, pool: pool)
            if reason != nil { try index.createSchema(rootPath: rootPath) }
            index.excludeFromBackup()
            return .success((index, reason))
        } catch {
            // One more try from scratch (a half-written file the check did not catch).
            removeFiles(url)
            do {
                let pool = try makePool(url)
                let index = NotesIndex(url: url, pool: pool)
                try index.createSchema(rootPath: rootPath)
                index.excludeFromBackup()
                return .success((index, "corrupt"))
            } catch {
                return .failure(.unavailable("筆記索引無法開啟：\(error.localizedDescription)"))
            }
        }
    }

    private enum Check { case ok, rebuild(String) }

    private static func check(url: URL, rootPath: String) -> Check {
        do {
            var config = Configuration()
            config.readonly = true
            let q = try DatabaseQueue(path: url.path, configuration: config)
            defer { try? q.close() }
            return try q.read { db -> Check in
                let qc = try String.fetchAll(db, sql: "PRAGMA quick_check")
                guard qc == ["ok"] else { return .rebuild("corrupt") }
                let v = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                guard v == schemaVersion else { return .rebuild("version") }
                let root = try String.fetchOne(db, sql: "SELECT value FROM index_meta WHERE key = 'root'")
                guard root == rootPath else { return .rebuild("root") }
                return .ok
            }
        } catch {
            return .rebuild("corrupt")
        }
    }

    private static func makePool(_ url: URL) throws -> DatabasePool {
        var config = Configuration()
        config.label = "codd-notes-index"
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        return try DatabasePool(path: url.path, configuration: config)
    }

    static func removeFiles(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func close() {
        try? pool.close()
    }

    /// Drops everything and creates the schema again (Settings › 重建筆記索引).
    func recreate(rootPath: String) throws {
        try? pool.close()
        Self.removeFiles(url)
        pool = try Self.makePool(url)
        try createSchema(rootPath: rootPath)
        excludeFromBackup()
    }

    /// The sqlite files (`-wal` / `-shm` appear lazily) are derived data: never in Time Machine.
    func excludeFromBackup() {
        for suffix in ["", "-wal", "-shm"] {
            let u = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: u.path) { FileFacts.excludeFromBackup(u) }
        }
    }

    private func createSchema(rootPath: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                DROP TABLE IF EXISTS note_tags; DROP TABLE IF EXISTS note_links; DROP TABLE IF EXISTS notes_fts;
                DROP TABLE IF EXISTS notes; DROP TABLE IF EXISTS index_meta;
                CREATE TABLE index_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE notes(
                  rowid INTEGER PRIMARY KEY, id TEXT UNIQUE NOT NULL, path TEXT UNIQUE NOT NULL, declared_id TEXT,
                  title TEXT NOT NULL, kind TEXT NOT NULL, ai TEXT NOT NULL, scope TEXT NOT NULL, pinned INTEGER NOT NULL,
                  status TEXT NOT NULL,
                  created REAL NOT NULL, updated REAL NOT NULL, updated_fm REAL, archived REAL, archived_by TEXT,
                  trashed REAL, sent REAL, sent_to TEXT, condensed_from TEXT NOT NULL, condensed_into TEXT,
                  created_by TEXT NOT NULL, tags TEXT NOT NULL, sessions TEXT NOT NULL, projects TEXT NOT NULL,
                  mtime REAL NOT NULL, size INTEGER NOT NULL, birth REAL NOT NULL, hash TEXT NOT NULL,
                  snippet TEXT NOT NULL, body_text TEXT NOT NULL, asset_count INTEGER NOT NULL, asset_bytes INTEGER NOT NULL,
                  flags INTEGER NOT NULL, line_ending TEXT NOT NULL,
                  search_text TEXT NOT NULL);
                CREATE INDEX notes_status ON notes(status, updated);
                CREATE TABLE note_tags(note_rowid INTEGER NOT NULL REFERENCES notes(rowid) ON DELETE CASCADE,
                  tag TEXT NOT NULL, PRIMARY KEY(note_rowid, tag));
                CREATE INDEX note_tags_tag ON note_tags(tag);
                CREATE TABLE note_links(note_rowid INTEGER NOT NULL REFERENCES notes(rowid) ON DELETE CASCADE,
                  type TEXT NOT NULL CHECK(type IN ('session','project')), target TEXT NOT NULL,
                  PRIMARY KEY(note_rowid, type, target));
                CREATE INDEX note_links_target ON note_links(type, target);
                CREATE VIRTUAL TABLE notes_fts USING fts5(title, body, tags, content='', contentless_delete=1,
                  tokenize='trigram case_sensitive 0');
                """)
            try db.execute(sql: "INSERT INTO index_meta(key, value) VALUES ('root', ?)", arguments: [rootPath])
            try db.execute(sql: "PRAGMA user_version = \(Self.schemaVersion)")
        }
    }

    // MARK: - Writes

    /// Inserts or replaces rows (by path) in one transaction.
    func upsert(_ rows: [IndexRow]) throws {
        guard !rows.isEmpty else { return }
        try pool.write { db in
            for row in rows { try Self.upsert(row, db: db) }
        }
    }

    private static func upsert(_ r: IndexRow, db: Database) throws {
        let folded = SearchFold.fold(r.title)
        let body = SearchFold.fold(r.bodyText)
        let tagText = SearchFold.fold(r.tags.joined(separator: " "))
        let searchText = folded + "\n" + body + "\n" + tagText
        let existing = try Int64.fetchOne(db, sql: "SELECT rowid FROM notes WHERE path = ?", arguments: [r.path])
        // A row elsewhere with the same id is the same note moved (the caller resolved duplicates).
        if let other = try Int64.fetchOne(db, sql: "SELECT rowid FROM notes WHERE id = ? AND path != ?", arguments: [r.id.rawValue, r.path]) {
            try db.execute(sql: "DELETE FROM notes_fts WHERE rowid = ?", arguments: [other])
            try db.execute(sql: "DELETE FROM notes WHERE rowid = ?", arguments: [other])
        }
        let values: StatementArguments = [
            r.id.rawValue, r.path, r.declaredID, r.title, r.kind.rawValue, r.ai?.rawValue ?? "", r.scope.rawValue,
            r.pinned ? 1 : 0, r.status, r.created, r.updated, r.updatedFM, r.archived, r.archivedBy?.rawValue, r.trashed,
            r.sent, r.sentTo, r.condensedFrom.map(\.rawValue).joined(separator: sep), r.condensedInto?.rawValue, r.createdBy,
            r.tags.joined(separator: sep), r.sessions.joined(separator: sep), r.projects.joined(separator: sep), r.mtime,
            r.size, r.birth, r.hash, r.snippet, r.bodyText, r.assetCount, r.assetBytes, r.flags.rawValue,
            r.lineEnding.rawValue, searchText,
        ]
        let rowid: Int64
        if let existing {
            try db.execute(sql: """
                UPDATE notes SET id=?, path=?, declared_id=?, title=?, kind=?, ai=?, scope=?, pinned=?, status=?, created=?,
                  updated=?, updated_fm=?, archived=?, archived_by=?, trashed=?, sent=?, sent_to=?, condensed_from=?,
                  condensed_into=?, created_by=?, tags=?, sessions=?, projects=?, mtime=?, size=?, birth=?, hash=?, snippet=?,
                  body_text=?, asset_count=?, asset_bytes=?, flags=?, line_ending=?, search_text=?
                WHERE rowid = \(existing)
                """, arguments: values)
            rowid = existing
            try db.execute(sql: "DELETE FROM notes_fts WHERE rowid = ?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM note_tags WHERE note_rowid = ?", arguments: [rowid])
            try db.execute(sql: "DELETE FROM note_links WHERE note_rowid = ?", arguments: [rowid])
        } else {
            try db.execute(sql: """
                INSERT INTO notes(id, path, declared_id, title, kind, ai, scope, pinned, status, created, updated, updated_fm,
                  archived, archived_by, trashed, sent, sent_to, condensed_from, condensed_into, created_by, tags, sessions,
                  projects, mtime, size, birth, hash, snippet, body_text, asset_count, asset_bytes, flags, line_ending, search_text)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, arguments: values)
            rowid = db.lastInsertedRowID
        }
        try db.execute(sql: "INSERT INTO notes_fts(rowid, title, body, tags) VALUES (?, ?, ?, ?)",
                       arguments: [rowid, folded, body, tagText])
        for tag in Set(r.tags.map(SearchFold.fold)) {
            try db.execute(sql: "INSERT OR IGNORE INTO note_tags(note_rowid, tag) VALUES (?, ?)", arguments: [rowid, tag])
        }
        for s in Set(r.sessions) {
            try db.execute(sql: "INSERT OR IGNORE INTO note_links(note_rowid, type, target) VALUES (?, 'session', ?)", arguments: [rowid, s])
        }
        for p in Set(r.projects) {
            try db.execute(sql: "INSERT OR IGNORE INTO note_links(note_rowid, type, target) VALUES (?, 'project', ?)", arguments: [rowid, p])
        }
    }

    func delete(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try pool.write { db in
            for p in paths {
                guard let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM notes WHERE path = ?", arguments: [p]) else { continue }
                try db.execute(sql: "DELETE FROM notes_fts WHERE rowid = ?", arguments: [rowid])
                try db.execute(sql: "DELETE FROM notes WHERE rowid = ?", arguments: [rowid])
            }
        }
    }

    func updateAssets(id: NoteID, count: Int, bytes: Int) throws {
        try pool.write { db in
            try db.execute(sql: "UPDATE notes SET asset_count = ?, asset_bytes = ? WHERE id = ?", arguments: [count, bytes, id.rawValue])
        }
    }

    // MARK: - Reads

    static let columns = """
        rowid, id, path, declared_id, title, kind, ai, scope, pinned, status, created, updated, updated_fm, archived,
        archived_by, trashed, sent, sent_to, condensed_from, condensed_into, created_by, tags, sessions, projects, mtime, size,
        birth, hash, snippet, body_text, asset_count, asset_bytes, flags, line_ending
        """

    static func decode(_ row: Row) -> IndexRow? {
        guard let id = NoteID(rawValue: row["id"]) else { return nil }
        func list(_ col: String) -> [String] {
            let s: String = row[col]
            return s.isEmpty ? [] : s.components(separatedBy: sep)
        }
        let ai: String = row["ai"]
        let lineEnding: String = row["line_ending"]
        return IndexRow(
            rowid: row["rowid"], id: id, path: row["path"], declaredID: row["declared_id"], title: row["title"],
            kind: NoteKind(rawValue: row["kind"]) ?? .note, ai: NoteAIAccess(rawValue: ai),
            scope: NoteScope(rawValue: row["scope"]) ?? .global, pinned: (row["pinned"] as Int) != 0, status: row["status"],
            created: row["created"], updated: row["updated"], updatedFM: row["updated_fm"], archived: row["archived"],
            archivedBy: (row["archived_by"] as String?).flatMap(ArchiveReason.init(rawValue:)), trashed: row["trashed"],
            sent: row["sent"], sentTo: row["sent_to"], condensedFrom: list("condensed_from").compactMap(NoteID.init(rawValue:)),
            condensedInto: (row["condensed_into"] as String?).flatMap(NoteID.init(rawValue:)), createdBy: row["created_by"],
            tags: list("tags"), sessions: list("sessions"), projects: list("projects"), mtime: row["mtime"], size: row["size"],
            birth: row["birth"], hash: row["hash"], snippet: row["snippet"], bodyText: row["body_text"],
            assetCount: row["asset_count"], assetBytes: row["asset_bytes"], flags: NoteFlags(rawValue: row["flags"]),
            lineEnding: NoteLineEnding(rawValue: lineEnding) ?? .lf)
    }

    /// The row columns without the plain body text (lists, counts and lookups never need it).
    static let lightColumns = columns.replacingOccurrences(of: "body_text", with: "'' AS body_text")

    func rows(where clause: String = "1", arguments: StatementArguments = [], orderBy: String = "updated DESC",
              limit: Int? = nil, withBody: Bool = false) throws -> [IndexRow] {
        try pool.read { db in
            var sql = "SELECT \(withBody ? Self.columns : Self.lightColumns) FROM notes WHERE \(clause) ORDER BY \(orderBy)"
            if let limit { sql += " LIMIT \(max(0, limit))" }
            return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap(Self.decode)
        }
    }

    func row(id: NoteID) throws -> IndexRow? {
        try rows(where: "id = ?", arguments: [id.rawValue], limit: 1).first
    }

    func row(path: String) throws -> IndexRow? {
        try rows(where: "path = ?", arguments: [path], limit: 1).first
    }

    func hasID(_ id: NoteID) throws -> Bool {
        try pool.read { db in try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notes WHERE id = ?)", arguments: [id.rawValue]) ?? false }
    }

    struct Facts: Sendable {
        var id: NoteID
        var mtime: Double
        var size: Int
        var hash: String
        var birth: Double
    }

    /// (mtime, size, hash) by path, for the open-time comparison.
    func facts() throws -> [String: Facts] {
        try pool.read { db in
            var out: [String: Facts] = [:]
            let rows = try Row.fetchAll(db, sql: "SELECT id, path, mtime, size, hash, birth FROM notes")
            for r in rows {
                guard let id = NoteID(rawValue: r["id"]) else { continue }
                out[r["path"]] = Facts(id: id, mtime: r["mtime"], size: r["size"], hash: r["hash"], birth: r["birth"])
            }
            return out
        }
    }

    /// `counts()` in three narrow queries: archived / trashed totals, active notes per project,
    /// and the few columns the STALE rule needs for each active note.
    func countFacts() throws -> (archived: Int, trashed: Int, byProject: [String: Int], active: [NotesLibrary.LifeInput]) {
        try pool.read { db in
            let archived = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes WHERE status = 'archived'") ?? 0
            let trashed = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes WHERE status = 'trashed'") ?? 0
            var byProject: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: """
                SELECT l.target AS p, COUNT(*) AS n FROM note_links l JOIN notes n ON n.rowid = l.note_rowid
                WHERE l.type = 'project' AND n.status = 'active' GROUP BY l.target
                """) {
                byProject[r["p"]] = r["n"]
            }
            var active: [NotesLibrary.LifeInput] = []
            for r in try Row.fetchAll(db, sql: "SELECT id, kind, pinned, created, updated_fm, sent, mtime, sessions FROM notes WHERE status = 'active'") {
                guard let id = NoteID(rawValue: r["id"]) else { continue }
                let sessions: String = r["sessions"]
                active.append(NotesLibrary.LifeInput(
                    id: id, status: "active", kind: NoteKind(rawValue: r["kind"]) ?? .note, pinned: (r["pinned"] as Int) != 0,
                    created: r["created"], updatedFM: r["updated_fm"], sent: r["sent"], trashed: nil, mtime: r["mtime"],
                    sessions: sessions.isEmpty ? [] : sessions.components(separatedBy: Self.sep)))
            }
            return (archived, trashed, byProject, active)
        }
    }

    func count() throws -> Int {
        try pool.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0 }
    }

    // MARK: - Search (D6)

    struct SearchPlan: Sendable {
        var matchTerms: [String]
        var likeTerms: [String]
        var tags: [String]
        var statuses: [String]
        var kinds: [String]?
        var project: String?
        var limit: Int
    }

    func search(_ plan: SearchPlan) throws -> [(IndexRow, Double)] {
        var sql = "SELECT \(Self.columns.split(separator: ",").map { "n." + $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: ", "))"
        var args: [(any DatabaseValueConvertible)?] = []
        var conditions: [String] = []
        let useFTS = !plan.matchTerms.isEmpty
        if useFTS {
            sql += ", bm25(notes_fts, 5.0, 1.0, 2.0) AS score FROM notes_fts JOIN notes n ON n.rowid = notes_fts.rowid"
            conditions.append("notes_fts MATCH ?")
            args.append(plan.matchTerms.map(Self.ftsLiteral).joined(separator: " AND "))
        } else {
            sql += ", 0.0 AS score FROM notes n"
        }
        conditions.append("n.status IN (" + plan.statuses.map { _ in "?" }.joined(separator: ",") + ")")
        args.append(contentsOf: plan.statuses.map { $0 as (any DatabaseValueConvertible)? })
        for t in plan.likeTerms {
            conditions.append("n.search_text LIKE ? ESCAPE '\\'")
            args.append("%" + Self.likeEscape(t) + "%")
        }
        for t in plan.tags {
            conditions.append("EXISTS (SELECT 1 FROM note_tags t WHERE t.note_rowid = n.rowid AND t.tag = ?)")
            args.append(t)
        }
        if let kinds = plan.kinds {
            conditions.append("n.kind IN (" + (kinds.isEmpty ? "''" : kinds.map { _ in "?" }.joined(separator: ",")) + ")")
            args.append(contentsOf: kinds.map { $0 as (any DatabaseValueConvertible)? })
        }
        if let p = plan.project {
            conditions.append("EXISTS (SELECT 1 FROM note_links l WHERE l.note_rowid = n.rowid AND l.type = 'project' AND l.target = ?)")
            args.append(p)
        }
        sql += " WHERE " + conditions.joined(separator: " AND ")
        sql += useFTS ? " ORDER BY score ASC, n.pinned DESC, n.updated DESC" : " ORDER BY n.pinned DESC, n.updated DESC"
        sql += " LIMIT \(max(0, plan.limit))"
        let arguments = StatementArguments(args.map { $0?.databaseValue ?? .null })
        return try pool.read { db in
            try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
                Self.decode(row).map { ($0, row["score"] as Double) }
            }
        }
    }

    /// An FTS5 string literal: the term in double quotes with `"` doubled, so `AND`, `a-b`, `*` or a
    /// quote are searched as text, never parsed as query syntax.
    static func ftsLiteral(_ term: String) -> String {
        "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func likeEscape(_ term: String) -> String {
        var out = ""
        for c in term {
            if c == "\\" || c == "%" || c == "_" { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
