import Foundation

extension NotesLibrary {
    // MARK: - Metadata and summaries

    func metadata(_ r: IndexRow) -> NoteMetadata {
        let state: NoteState
        switch r.status {
        case "trashed": state = .trashed(at: Date(timeIntervalSince1970: r.trashed ?? r.mtime))
        case "archived": state = .archived(at: Date(timeIntervalSince1970: r.archived ?? r.updated), by: r.archivedBy ?? .user)
        default: state = .active
        }
        return NoteMetadata(
            id: r.id, title: r.title, kind: r.kind, tags: r.tags, links: NoteLinks(sessions: r.sessions, projects: r.projects),
            ai: r.ai ?? defaultAccess, scope: r.scope, pinned: r.pinned, state: state,
            created: Date(timeIntervalSince1970: r.created), updated: Date(timeIntervalSince1970: r.updated),
            sentAt: r.sent.map(Date.init(timeIntervalSince1970:)), sentTo: r.sentTo, condensedFrom: r.condensedFrom,
            condensedInto: r.condensedInto, createdBy: r.createdBy)
    }

    struct Lifecycle {
        var lastActivity: Date
        var staleSince: Date?
        var archivesAt: Date?
        var purgeAt: Date?
        var exempt: ExemptReason?
    }

    /// What the lifecycle needs of a row (a narrow query for `counts`).
    struct LifeInput {
        var id: NoteID
        var status: String
        var kind: NoteKind
        var pinned: Bool
        var created: Double
        var updatedFM: Double?
        var sent: Double?
        var trashed: Double?
        var mtime: Double
        var sessions: [String]

        var isTrashed: Bool { status == "trashed" }
        var isActive: Bool { status == "active" }
    }

    func lifecycle(_ r: IndexRow, now: Date) -> Lifecycle {
        lifecycle(LifeInput(id: r.id, status: r.status, kind: r.kind, pinned: r.pinned, created: r.created, updatedFM: r.updatedFM,
                            sent: r.sent, trashed: r.trashed, mtime: r.mtime, sessions: r.sessions), now: now)
    }

    /// D29: the user's last activity (state.json, the frontmatter `created` / `updated` / `sent`;
    /// never AI reads or writes, never a bare mtime), the exemption and the due dates.
    func lifecycle(_ r: LifeInput, now: Date) -> Lifecycle {
        let s = state[r.id]
        var last = r.created
        if let u = r.updatedFM { last = max(last, u) }
        if let sent = r.sent { last = max(last, sent) }
        if let a = s.lastUserActivityAt?.timeIntervalSince1970 { last = max(last, a) }
        if let o = s.lastOpenedAt?.timeIntervalSince1970 { last = max(last, o) }
        let lastActivity = Date(timeIntervalSince1970: last)
        var l = Lifecycle(lastActivity: lastActivity)
        if r.isTrashed {
            l.purgeAt = Date(timeIntervalSince1970: (r.trashed ?? r.mtime) + Double(policy.trashPurgeDays) * 86_400)
            return l
        }
        guard r.isActive else { return l }
        if let keep = s.keepUntil, keep > now {
            l.exempt = .kept
        } else if policy.exempt {
            if r.pinned {
                l.exempt = .pinned
            } else if !liveSessions.isDisjoint(with: r.sessions) {
                l.exempt = .linkedLiveSession
            } else if !liveSessions.isDisjoint(with: activityLog.sessions(thatRead: r.id)) {
                l.exempt = .readByLiveSession
            }
        }
        guard l.exempt == nil else { return l }
        if r.kind == .scratch || (r.kind == .prompt && r.sent != nil) {
            if let d = policy.scratchArchiveDays { l.archivesAt = lastActivity.addingTimeInterval(Double(d) * 86_400) }
        } else if let d = policy.archiveDays {
            l.archivesAt = lastActivity.addingTimeInterval(Double(d) * 86_400)
        }
        if let d = policy.staleDays {
            let due = lastActivity.addingTimeInterval(Double(d) * 86_400)
            if due <= now { l.staleSince = due }
        }
        return l
    }

    func summary(_ r: IndexRow, now: Date) -> NoteSummary {
        let l = lifecycle(r, now: now)
        return NoteSummary(
            metadata: metadata(r), snippet: r.snippet, assetCount: r.assetCount, assetBytes: r.assetBytes,
            lastActivity: l.lastActivity, staleSince: l.staleSince, archivesAt: l.archivesAt, purgeAt: l.purgeAt,
            exempt: l.exempt, flags: r.flags, fileURL: url(r.path))
    }

    func requireIndex() throws -> NotesIndex {
        guard let index else { throw NotesError.unavailable("筆記本尚未開啟") }
        return index
    }

    /// The row of a live (active / archived / trashed) note, or the matching error.
    func requireRow(_ id: NoteID) throws -> IndexRow {
        let index = try requireIndex()
        if let r = try index.row(id: id) { return r }
        if tombstones.contains(id) { throw NotesError.purged(id) }
        throw NotesError.notFound(id)
    }

    // MARK: - Lists

    public func counts() async throws -> NotesCounts {
        let index = try requireIndex()
        let now = clock()
        var c = NotesCounts()
        let facts = try index.countFacts()
        c.archive = facts.archived
        c.trash = facts.trashed
        c.byProject = facts.byProject
        for r in facts.active {
            c.inbox += 1
            if r.pinned { c.pinned += 1 }
            if r.kind == .prompt { c.prompts += 1 }
            if lifecycle(r, now: now).staleSince != nil { c.stale += 1 }
        }
        return c
    }

    public func list(_ list: SmartList, sort: NoteSort, limit: Int) async throws -> [NoteSummary] {
        let index = try requireIndex()
        let now = clock()
        let order: String
        switch sort {
        case .updated: order = "updated DESC"
        case .created: order = "created DESC"
        case .title: order = "title COLLATE NOCASE ASC"
        }
        let rows: [IndexRow]
        switch list {
        case .inbox: rows = try index.rows(where: "status = 'active'", orderBy: order, limit: limit)
        case .pinned: rows = try index.rows(where: "status = 'active' AND pinned = 1", orderBy: order, limit: limit)
        case .prompts: rows = try index.rows(where: "status = 'active' AND kind = 'prompt'", orderBy: order, limit: limit)
        case .archive: rows = try index.rows(where: "status = 'archived'", orderBy: order, limit: limit)
        case .trash: rows = try index.rows(where: "status = 'trashed'", orderBy: sort == .updated ? "trashed DESC" : order, limit: limit)
        case .project(let p):
            rows = try index.rows(
                where: "status = 'active' AND EXISTS (SELECT 1 FROM note_links l WHERE l.note_rowid = notes.rowid AND l.type = 'project' AND l.target = ?)",
                arguments: [HomePath.abbreviate(p)], orderBy: order, limit: limit)
        case .stale:
            let all = try index.rows(where: "status = 'active'", orderBy: order)
            return Array(all.filter { lifecycle($0, now: now).staleSince != nil }.prefix(max(0, limit))).map { summary($0, now: now) }
        }
        return rows.map { summary($0, now: now) }
    }

    public func summaries(linkedToSession id: String) async throws -> [NoteSummary] {
        let index = try requireIndex()
        let now = clock()
        return try index.rows(
            where: "status = 'active' AND EXISTS (SELECT 1 FROM note_links l WHERE l.note_rowid = notes.rowid AND l.type = 'session' AND l.target = ?)",
            arguments: [id.lowercased()]).map { summary($0, now: now) }
    }

    public func summary(_ id: NoteID) async throws -> NoteSummary {
        summary(try requireRow(id), now: clock())
    }

    // MARK: - Search (D6)

    public func search(_ query: NoteQuery) async throws -> [NoteSearchHit] {
        let index = try requireIndex()
        let q = SearchQuery(query.text)
        guard !q.isEmpty else { return [] }
        var statuses = ["active"]
        if query.includeArchived { statuses.append("archived") }
        if query.includeTrashed { statuses.append("trashed") }
        let plan = NotesIndex.SearchPlan(
            matchTerms: q.matchTerms, likeTerms: q.likeTerms, tags: q.tags, statuses: statuses,
            kinds: query.kinds.map { $0.map(\.rawValue).sorted() }, project: query.project.map(HomePath.abbreviate),
            limit: query.limit)
        let now = clock()
        return try index.search(plan).map { row, score in
            let s = summary(row, now: now)
            if let (text, ranges) = SearchSnippet.make(text: row.bodyText, terms: q.terms) {
                return NoteSearchHit(summary: s, snippet: text, highlights: ranges, score: score)
            }
            let fallback = row.snippet.replacingOccurrences(of: "\n", with: " ")
            return NoteSearchHit(summary: s, snippet: fallback, highlights: SearchSnippet.highlights(in: fallback, terms: q.terms), score: score)
        }
    }

    // MARK: - Documents

    /// The current file of a note (re-read from disk; a change the watcher has not delivered yet
    /// is indexed now and reported as external).
    func load(_ id: NoteID) throws -> (IndexRow, ParsedNote, Data) {
        let row = try requireRow(id)
        let fileURL = url(row.path)
        guard let data = try? Data(contentsOf: fileURL), let st = FileFacts.info(fileURL.path) else {
            try index?.delete(paths: [row.path])
            channel.yield(.removed([id]))
            throw NotesError.notFound(id)
        }
        var current = row
        let hash = Hashing.sha256Hex(data)
        if hash != row.hash {
            let own = ownWrites[row.path] == hash
            if let r = try reindex(rel: row.path, data: data, stat: st, external: !own) {
                current = r
                if !own {
                    externalEventCount += 1
                    channel.yield(.external([r.id]))
                }
            }
        }
        return (current, NoteFile.parse(data: data, timeZone: timeZone), data)
    }

    func makeDocument(_ row: IndexRow, _ parsed: ParsedNote) -> NoteDocument {
        NoteDocument(metadata: metadata(row), body: parsed.body, fileURL: url(row.path), relativePath: row.path,
                     contentHash: parsed.hash, flags: row.flags, lineEnding: parsed.lineEnding)
    }

    public func document(_ id: NoteID) async throws -> NoteDocument {
        let (row, parsed, _) = try load(id)
        return makeDocument(row, parsed)
    }

    public func resolve(_ reference: String) async -> NoteResolution {
        guard let id = NoteReferences.parseRef(reference) else { return .unknown(reference) }
        if let row = try? index?.row(id: id) {
            let s = summary(row, now: clock())
            if row.isTrashed { return .trashed(s, purgeAt: s.purgeAt ?? Date()) }
            return .note(s)
        }
        if let t = tombstones.tombstone(id) { return .purged(t) }
        return .unknown(id.rawValue)
    }

    public func tombstone(_ id: NoteID) async -> Tombstone? {
        tombstones.tombstone(id)
    }

    // MARK: - Writing

    /// The full frontmatter CODD writes for a new note (or a file that had none), §3.2 key order.
    func fullFrontmatter(_ m: NoteMetadata, lineEnding: NoteLineEnding) -> Frontmatter {
        var fm = Frontmatter(lineEnding: lineEnding)
        fm.set("id", scalar: m.id.rawValue)
        fm.set("title", scalar: m.title)
        fm.set("kind", scalar: m.kind.rawValue)
        fm.set("tags", list: m.tags)
        if !m.links.sessions.isEmpty { fm.set("sessions", list: m.links.sessions) }
        if !m.links.projects.isEmpty { fm.set("projects", list: m.links.projects) }
        fm.set("ai", scalar: m.ai.rawValue)
        fm.set("scope", scalar: m.scope.rawValue)
        fm.set("pinned", bool: m.pinned)
        if case .archived(let at, let by) = m.state {
            fm.set("status", scalar: "archived")
            fm.set("archived", scalar: iso(at))
            fm.set("archivedBy", scalar: by.rawValue)
        } else {
            fm.set("status", scalar: "active")
        }
        if let s = m.sentAt { fm.set("sent", scalar: iso(s)) }
        if let t = m.sentTo { fm.set("sentTo", scalar: t) }
        fm.set("created", scalar: iso(m.created))
        fm.set("updated", scalar: iso(m.updated))
        if !m.condensedFrom.isEmpty { fm.set("condensedFrom", list: m.condensedFrom.map(\.rawValue)) }
        if let c = m.condensedInto { fm.set("condensedInto", scalar: c.rawValue) }
        if m.createdBy != "user" { fm.set("createdBy", scalar: m.createdBy) }
        return fm
    }

    func iso(_ d: Date) -> String { ISODate.format(d, timeZone: timeZone) }

    /// The editable frontmatter of a loaded note: refused when unparsable, created when missing,
    /// with the index's id written back when the file's own differs (a derived or `-dup` id).
    func editableFrontmatter(_ row: IndexRow, _ parsed: ParsedNote) throws -> Frontmatter {
        if parsed.flags.contains(.unparsableFrontmatter) { throw NotesError.unparsableFrontmatter(row.id) }
        var fm = parsed.frontmatter ?? fullFrontmatter(metadata(row), lineEnding: parsed.lineEnding)
        if parsed.declaredID != row.id { fm.set("id", scalar: row.id.rawValue) }
        return fm
    }

    /// Writes a new version of a note file, re-indexes it and reports `.changed`.
    @discardableResult
    func commit(_ row: IndexRow, text: String, to rel: String? = nil, updatedHint: Double?) throws -> IndexRow {
        let target = rel ?? row.path
        let (data, st) = try writeNote(text, to: target)
        guard let index else { throw NotesError.unavailable("筆記本尚未開啟") }
        let parsed = NoteFile.parse(data: data, timeZone: timeZone)
        let trashed = target.hasPrefix(Self.trashPrefix)
        let assets = assetStat(folder: assetFolder(row.id, trashed: trashed))
        var newRow = makeRow(rel: target, parsed: parsed, stat: st, id: row.id,
                             duplicate: row.flags.contains(.duplicateID) && parsed.declaredID != row.id,
                             updatedHint: updatedHint, assets: assets)
        if target != row.path { try index.delete(paths: [row.path]) }
        try index.upsert([newRow])
        newRow = try index.row(path: target) ?? newRow
        return newRow
    }

    public func create(_ note: NewNote) async throws -> NoteDocument {
        _ = try requireIndex()
        let now = clock()
        let rawTitle = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? NoteFile.untitled : rawTitle
        let tags = NoteFile.normalizeTags(note.tags)
        let id: NoteID
        if let prefix = note.idPrefix {
            id = NoteNaming.makeID(prefix: prefix) { idTaken($0) }
        } else {
            id = NoteNaming.makeID(title: title, tags: tags) { idTaken($0) }
        }
        let fm = FileManager.default
        let name = NoteNaming.fileName(title: title, date: now, timeZone: timeZone) { candidate in
            fm.fileExists(atPath: url(candidate).path) || fm.fileExists(atPath: url(Self.trashPrefix + candidate).path)
        }
        let links = NoteLinks(sessions: NoteFile.dedupe(note.links.sessions.map { $0.lowercased() }),
                              projects: NoteFile.dedupe(note.links.projects.map(HomePath.abbreviate)))
        let meta = NoteMetadata(
            id: id, title: title, kind: note.kind, tags: tags, links: links, ai: note.ai ?? defaultAccess,
            scope: note.scope ?? (links.isEmpty ? .global : .project), created: now, updated: now,
            condensedFrom: note.condensedFrom, createdBy: note.createdBy)
        var body = note.body ?? "# \(title)\n"
        if body.contains("\r\n") { body = body.replacingOccurrences(of: "\r\n", with: "\n") }
        let text = NoteFile.compose(frontmatter: fullFrontmatter(meta, lineEnding: .lf), body: body, lineEnding: .lf)
        let (data, st) = try writeNote(text, to: name)
        let parsed = NoteFile.parse(data: data, timeZone: timeZone)
        let row = makeRow(rel: name, parsed: parsed, stat: st, id: id, duplicate: false, updatedHint: now.timeIntervalSince1970,
                          assets: (0, 0))
        try requireIndex().upsert([row])
        recordUserActivity(id, at: now)
        _ = try? historyStore.take(id, data: data, reason: nil, force: false, now: now)
        log("notes create id=\(id.rawValue) kind=\(note.kind.rawValue)")
        channel.yield(.changed([id]))
        return makeDocument(try requireRow(id), parsed)
    }

    public func save(_ id: NoteID, body: String, basedOn hash: String?) async throws -> SaveOutcome {
        let (row, parsed, _) = try load(id)
        if row.isTrashed { throw NotesError.trashed(id, purgeAt: lifecycle(row, now: clock()).purgeAt ?? clock()) }
        let current = makeDocument(row, parsed)
        if let hash, hash != parsed.hash { return .conflict(disk: current) }
        let newBody = body.contains("\r\n") ? body.replacingOccurrences(of: "\r\n", with: "\n") : body
        let needsID = !parsed.flags.contains(.unparsableFrontmatter) && parsed.declaredID != row.id
        if newBody == parsed.body, !needsID { return .saved(current) }
        let now = clock()
        var fm: Frontmatter?
        if parsed.flags.contains(.unparsableFrontmatter) {
            // The body save still works and never touches a frontmatter CODD cannot parse (D2).
            fm = parsed.frontmatter
        } else {
            var f = parsed.frontmatter ?? fullFrontmatter(metadata(row), lineEnding: parsed.lineEnding)
            if needsID { f.set("id", scalar: row.id.rawValue) }
            if let h1 = MarkdownText.firstH1(BodyLines.split(newBody))?.title { f.set("title", scalar: h1) }
            f.set("updated", scalar: iso(now))
            fm = f
        }
        let text = NoteFile.compose(frontmatter: fm, body: newBody, lineEnding: parsed.lineEnding)
        let newRow = try commit(row, text: text, updatedHint: now.timeIntervalSince1970)
        recordUserActivity(id, at: now)
        if let data = text.data(using: .utf8) { _ = try? historyStore.take(id, data: data, reason: nil, force: false, now: now) }
        channel.yield(.changed([id]))
        let (_, newParsed, _) = try load(id)
        return .saved(makeDocument(newRow, newParsed))
    }

    public func update(_ id: NoteID, _ change: MetadataChange) async throws -> NoteDocument {
        let (row, parsed, _) = try load(id)
        if row.isTrashed { throw NotesError.trashed(id, purgeAt: lifecycle(row, now: clock()).purgeAt ?? clock()) }
        var fm = try editableFrontmatter(row, parsed)
        let now = clock()
        var activity = true
        switch change {
        case .kind(let k):
            fm.set("kind", scalar: k.rawValue)
        case .tags(let t):
            fm.set("tags", list: NoteFile.normalizeTags(t))
        case .addTag(let t):
            fm.set("tags", list: NoteFile.normalizeTags(row.tags + [t]))
        case .removeTag(let t):
            var tag = t
            while tag.hasPrefix("#") { tag.removeFirst() }
            fm.set("tags", list: row.tags.filter { $0.lowercased() != tag.lowercased() })
        case .linkSession(let s):
            fm.set("sessions", list: NoteFile.dedupe(row.sessions + [s.lowercased()]))
        case .unlinkSession(let s):
            fm.set("sessions", list: row.sessions.filter { $0 != s.lowercased() })
        case .linkProject(let p):
            fm.set("projects", list: NoteFile.dedupe(row.projects + [HomePath.abbreviate(p)]))
        case .unlinkProject(let p):
            fm.set("projects", list: row.projects.filter { $0 != HomePath.abbreviate(p) })
        case .ai(let a):
            fm.set("ai", scalar: a.rawValue)
            activity = false
        case .scope(let s, let primary):
            fm.set("scope", scalar: s.rawValue)
            if let primary {
                let p = HomePath.abbreviate(primary)
                fm.set("projects", list: [p] + row.projects.filter { $0 != p })
            } else {
                activity = false
            }
        case .pinned(let b):
            fm.set("pinned", bool: b)
        case .markSent(let at, let to):
            fm.set("sent", scalar: iso(at))
            fm.set("sentTo", scalar: to.lowercased())
        case .condensedInto(let target):
            fm.set("condensedInto", scalar: target?.rawValue)
            activity = false
        }
        let text = NoteFile.compose(frontmatter: fm, body: parsed.body, lineEnding: parsed.lineEnding)
        try commit(row, text: text, updatedHint: row.updated)
        if activity {
            if case .markSent(let at, _) = change { recordUserActivity(id, at: at) } else { recordUserActivity(id, at: now) }
        }
        channel.yield(.changed([id]))
        return try await document(id)
    }

    // MARK: - Archive / trash

    /// Loads every note first and refuses the whole call when one is missing, trashed or has an
    /// unparsable frontmatter, so a batch never stops half way.
    func loadForStateChange(_ ids: [NoteID], allowTrashed: Bool) throws -> [(IndexRow, ParsedNote, Frontmatter)] {
        var out: [(IndexRow, ParsedNote, Frontmatter)] = []
        for id in ids {
            let (row, parsed, _) = try load(id)
            if row.isTrashed, !allowTrashed { throw NotesError.trashed(id, purgeAt: lifecycle(row, now: clock()).purgeAt ?? clock()) }
            out.append((row, parsed, try editableFrontmatter(row, parsed)))
        }
        return out
    }

    public func archive(_ ids: [NoteID], by reason: ArchiveReason) async throws {
        let now = clock()
        var done: [NoteID] = []
        for (row, parsed, var fm) in try loadForStateChange(ids, allowTrashed: false) where !row.isArchived {
            fm.set("status", scalar: "archived")
            fm.set("archived", scalar: iso(now))
            fm.set("archivedBy", scalar: reason.rawValue)
            try commit(row, text: NoteFile.compose(frontmatter: fm, body: parsed.body, lineEnding: parsed.lineEnding), updatedHint: row.updated)
            done.append(row.id)
            log("notes archive id=\(row.id.rawValue) by=\(reason.rawValue)")
        }
        if !done.isEmpty { channel.yield(.changed(done)) }
    }

    public func unarchive(_ ids: [NoteID]) async throws {
        let now = clock()
        var done: [NoteID] = []
        for (row, parsed, var fm) in try loadForStateChange(ids, allowTrashed: false) where row.isArchived {
            fm.set("status", scalar: "active")
            fm.set("archived", scalar: nil)
            fm.set("archivedBy", scalar: nil)
            try commit(row, text: NoteFile.compose(frontmatter: fm, body: parsed.body, lineEnding: parsed.lineEnding), updatedHint: row.updated)
            // Restoring is activity, or retention would archive it again at its next run.
            recordUserActivity(row.id, at: now)
            done.append(row.id)
        }
        if !done.isEmpty { channel.yield(.changed(done)) }
    }

    /// Moves notes to CODD's TRASH: `.codd/trash/<relative path>` with `trashed:` added, the
    /// assets to `.codd/trash/assets/<id>/`; a snapshot first (D8). History stays until the purge.
    public func trash(_ ids: [NoteID]) async throws {
        let now = clock()
        var done: [NoteID] = []
        let fm = FileManager.default
        for (row, parsed, var front) in try loadForStateChange(ids, allowTrashed: true) where !row.isTrashed {
            if let data = try? Data(contentsOf: url(row.path)) {
                _ = try? historyStore.take(row.id, data: data, reason: "trash", force: true, now: now)
            }
            front.set("trashed", scalar: iso(now))
            let target = uniquePath(Self.trashPrefix + row.path)
            moveAssets(row.id, toTrash: true)
            try commit(row, text: NoteFile.compose(frontmatter: front, body: parsed.body, lineEnding: parsed.lineEnding),
                       to: target, updatedHint: row.updated)
            try? fm.removeItem(at: url(row.path))
            ownWrites[row.path] = nil
            done.append(row.id)
            log("notes trash id=\(row.id.rawValue)")
        }
        if !done.isEmpty { channel.yield(.changed(done)) }
    }

    public func restore(_ ids: [NoteID]) async throws {
        let now = clock()
        var done: [NoteID] = []
        let fm = FileManager.default
        for (row, parsed, var front) in try loadForStateChange(ids, allowTrashed: true) where row.isTrashed {
            front.set("trashed", scalar: nil)
            let target = uniquePath(String(row.path.dropFirst(Self.trashPrefix.count)))
            moveAssets(row.id, toTrash: false)
            try commit(row, text: NoteFile.compose(frontmatter: front, body: parsed.body, lineEnding: parsed.lineEnding),
                       to: target, updatedHint: row.updated)
            try? fm.removeItem(at: url(row.path))
            recordUserActivity(row.id, at: now)
            done.append(row.id)
            log("notes restore id=\(row.id.rawValue)")
        }
        if !done.isEmpty { channel.yield(.changed(done)) }
    }

    /// `rel`, or `<stem>-2.md`, `-3` … when a file is already there.
    func uniquePath(_ rel: String) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url(rel).path) else { return rel }
        let stem = rel.hasSuffix(".md") ? String(rel.dropLast(3)) : rel
        var n = 2
        while fm.fileExists(atPath: url("\(stem)-\(n).md").path) { n += 1 }
        return "\(stem)-\(n).md"
    }

    func moveAssets(_ id: NoteID, toTrash: Bool) {
        let fm = FileManager.default
        let from = assetFolder(id, trashed: !toTrash)
        let to = assetFolder(id, trashed: toTrash)
        guard fm.fileExists(atPath: from.path) else { return }
        do {
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            if fm.fileExists(atPath: to.path) {
                // Merge: files already there win only when the moving folder lacks them.
                for name in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] {
                    let dst = to.appendingPathComponent(name)
                    if fm.fileExists(atPath: dst.path) { try? fm.removeItem(at: dst) }
                    try? fm.moveItem(at: from.appendingPathComponent(name), to: dst)
                }
                try? fm.removeItem(at: from)
            } else {
                try fm.moveItem(at: from, to: to)
            }
        } catch {
            log("notes assets move failed id=\(id.rawValue): \(error)")
        }
    }

    // MARK: - App state

    public func markOpened(_ id: NoteID, at: Date) async {
        var s = state[id]
        s.lastOpenedAt = at
        s.openCount += 1
        if (s.lastUserActivityAt ?? .distantPast) < at { s.lastUserActivityAt = at }
        state[id] = s
        touchState()
    }

    /// `保留 30 天`: exempt from STALE / archiving and from Cleanup until `until`.
    public func keep(_ id: NoteID, until: Date) async {
        var s = state[id]
        s.keepUntil = until
        state[id] = s
        touchState()
        channel.yield(.changed([id]))
    }

    public func recordActivity(_ event: NoteActivityEvent) async {
        activityLog.append(event)
        channel.yield(.activity(event.note))
    }

    /// Newest first.
    public func activity(of id: NoteID, limit: Int) async -> [NoteActivityEvent] {
        activityLog.events(of: id, limit: limit)
    }
}
