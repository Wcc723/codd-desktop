import Foundation

/// The notebook: Markdown files under `root` (the truth), a derived SQLite index and derived
/// annotated images (both outside `root`, in folders the app names), CODD's own state under
/// `root/.codd/`, and an FSEvents watcher. An actor: file IO blocks inside it, long loops
/// yield so MCP reads interleave with an index build; nothing here touches the main actor.
public actor NotesLibrary {
    public nonisolated let rootURL: URL
    let indexURL: URL
    /// Burned-in annotated copies (D10, DERIVED): ``NoteAIText/annotatedURL(for:in:)``.
    public nonisolated let annotatedFolder: URL
    var policy: RetentionPolicy
    var defaultAccess: NoteAIAccess
    let clock: @Sendable () -> Date
    let trashItem: @Sendable (URL) throws -> Void
    let log: @Sendable (String) -> Void
    let timeZone: TimeZone
    let calendar: LocalCalendar
    let channel = ChangeChannel()

    var coordinator: (any OpenNoteCoordinator)?
    var liveSessions: Set<String> = []
    var sessionTitles: [String: String] = [:]

    var index: NotesIndex?
    var realRoot: String = ""
    var state: StateStore
    var activityLog: ActivityLog
    var tombstones: TombstoneStore
    let writer: AtomicWriter
    /// Writes into `annotatedFolder` with its temp files in that folder (the same volume even when
    /// the notes folder is elsewhere); leftovers are collected at open.
    let annotatedWriter: AtomicWriter
    let historyStore: HistoryStore
    var watcher: NotesWatcher?
    var watchTask: Task<Void, Never>?
    var stateFlushTask: Task<Void, Never>?
    /// CODD's own writes: relative path → SHA-256 of the bytes written, so the watcher never
    /// reports them as external.
    var ownWrites: [String: String] = [:]
    var isOpen = false
    var lastReport: NotesOpenReport?
    /// External changes seen by the watcher since open (for the app's dump).
    public internal(set) var externalEventCount = 0

    /// - Parameters:
    ///   - root: `<dataRoot>/notes`.
    ///   - indexURL: the derived index, outside the notes folder (the app: `<dataRoot>/cache/notes-index.sqlite`).
    ///   - annotatedFolder: the derived burned-in annotated images, outside the notes folder (the
    ///     app: `<dataRoot>/cache/annotated`). Everything in it may be deleted; it is rebuilt on use.
    ///   - trash: moves a purged note's file / folders to a system-level trash (the app's D38
    ///     function; tests pass a folder move).
    ///   - timeZone: dates written into notes and shown in AI text (`+08:00`).
    public init(root: URL, indexURL: URL, annotatedFolder: URL, policy: RetentionPolicy, defaultAccess: NoteAIAccess,
                clock: @escaping @Sendable () -> Date = { Date() },
                trash: @escaping @Sendable (URL) throws -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in },
                timeZone: TimeZone = .current) {
        // Kept as given: `standardizedFileURL` would drop a `/private` prefix and change the
        // paths that AI text and COPY REF hand out.
        let root = URL(fileURLWithPath: root.path, isDirectory: true)
        rootURL = root
        self.indexURL = indexURL
        let annotated = URL(fileURLWithPath: annotatedFolder.path, isDirectory: true)
        self.annotatedFolder = annotated
        annotatedWriter = AtomicWriter(tempDirectory: annotated)
        self.policy = policy
        self.defaultAccess = defaultAccess
        self.clock = clock
        trashItem = trash
        self.log = log
        self.timeZone = timeZone
        calendar = LocalCalendar(timeZone: timeZone)
        let codd = root.appendingPathComponent(".codd", isDirectory: true)
        writer = AtomicWriter(tempDirectory: codd.appendingPathComponent("tmp", isDirectory: true))
        historyStore = HistoryStore(root: codd.appendingPathComponent("history", isDirectory: true), writer: writer)
        state = StateStore(url: codd.appendingPathComponent("state.json"), timeZone: timeZone)
        activityLog = ActivityLog(url: codd.appendingPathComponent("activity.jsonl"), timeZone: timeZone)
        tombstones = TombstoneStore(url: codd.appendingPathComponent("tombstones.json"), timeZone: timeZone)
    }

    /// Single consumer: each access returns a stream over the same buffer.
    public nonisolated var changes: AsyncStream<NotesChange> {
        let ch = channel
        return AsyncStream(unfolding: { await ch.next() })
    }

    // MARK: - Paths

    var coddDir: URL { rootURL.appendingPathComponent(".codd", isDirectory: true) }
    var trashDir: URL { coddDir.appendingPathComponent("trash", isDirectory: true) }
    var assetsDir: URL { rootURL.appendingPathComponent("assets", isDirectory: true) }
    static let trashPrefix = ".codd/trash/"

    func url(_ relativePath: String) -> URL {
        rootURL.appendingPathComponent(relativePath, isDirectory: false)
    }

    func assetFolder(_ id: NoteID, trashed: Bool) -> URL {
        (trashed ? trashDir.appendingPathComponent("assets", isDirectory: true) : assetsDir)
            .appendingPathComponent(id.rawValue, isDirectory: true)
    }

    // MARK: - Lifecycle

    /// Creates the folders and the marker, opens (or builds / updates) the index and starts the
    /// watcher. Calling it again returns the first report.
    public func open() async throws(NotesError) -> NotesOpenReport {
        if isOpen, let lastReport { return lastReport }
        let started = ContinuousClock.now
        try ensureLayout()
        realRoot = FileFacts.realPath(rootURL).path
        let now = clock()
        state.load(clock: now, log: log)
        tombstones.load(clock: now, log: log)
        activityLog.load(now: now, writer: writer, log: log)
        let opened: (NotesIndex, rebuildReason: String?)
        switch NotesIndex.open(url: indexURL, rootPath: rootURL.path) {
        case .success(let v): opened = v
        case .failure(let e): throw e
        }
        index = opened.0
        var warnings: [String] = []
        var rebuilt = false
        do {
            if opened.rebuildReason != nil {
                warnings = try await fullBuild()
                rebuilt = true
            } else {
                warnings = try await updateFromDisk(reportExternal: false)
            }
        } catch {
            throw .unavailable("筆記索引建立失敗：\(error.localizedDescription)")
        }
        let count = (try? index?.count()) ?? 0
        index?.excludeFromBackup()
        let collected = collectStaleAnnotatedCopies()
        if collected > 0 { log("notes annotated-cache removed=\(collected)") }
        let ms = Self.ms(since: started)
        let report = NotesOpenReport(rebuilt: rebuilt, reason: opened.rebuildReason, count: count, buildMs: ms, warnings: warnings)
        lastReport = report
        isOpen = true
        startWatcher()
        log("notes open root=\(rootURL.lastPathComponent) count=\(count) rebuilt=\(rebuilt) reason=\(opened.rebuildReason ?? "-") ms=\(Int(ms))")
        if rebuilt { channel.yield(.indexRebuilt(count: count)) }
        return report
    }

    public func close() async {
        watcher?.finish()
        watcher = nil
        watchTask?.cancel()
        watchTask = nil
        stateFlushTask?.cancel()
        stateFlushTask = nil
        flushState()
        index?.close()
        index = nil
        isOpen = false
        lastReport = nil
        channel.finish()
    }

    /// True once `open()` finished (tests poll it while a build runs).
    var isOpenForTests: Bool { isOpen }

    public func setPolicy(_ policy: RetentionPolicy, defaultAccess: NoteAIAccess) {
        self.policy = policy
        self.defaultAccess = defaultAccess
    }

    public func setOpenNoteCoordinator(_ coordinator: (any OpenNoteCoordinator)?) {
        self.coordinator = coordinator
    }

    /// Running CODD sessions (lowercase UUIDs): their linked notes and the notes they read are
    /// exempt from STALE / archiving (D29). `runRetention` sets it too.
    public func setLiveSessions(_ ids: Set<String>) {
        liveSessions = Set(ids.map { $0.lowercased() })
    }

    /// Session titles for the AI text's `links:` line and the Cleanup `送到 <session>` texts.
    public func setSessionTitles(_ titles: [String: String]) {
        sessionTitles = Dictionary(titles.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    /// The index rebuilt from the files (Settings › 進階 › 重建筆記索引).
    public func rebuildIndex() async throws -> NotesOpenReport {
        guard let index else { throw NotesError.unavailable("筆記本尚未開啟") }
        let started = ContinuousClock.now
        try index.recreate(rootPath: rootURL.path)
        let warnings = try await fullBuild()
        let count = try index.count()
        let report = NotesOpenReport(rebuilt: true, reason: "requested", count: count, buildMs: Self.ms(since: started), warnings: warnings)
        log("notes index rebuilt reason=requested count=\(count) ms=\(Int(report.buildMs))")
        channel.yield(.indexRebuilt(count: count))
        return report
    }

    static func ms(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    func ensureLayout() throws(NotesError) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: rootURL.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw .unavailable("\(rootURL.path) 不是資料夾") }
        }
        do {
            for dir in [rootURL, coddDir, writer.tempDirectory] where !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
            }
            let marker = coddDir.appendingPathComponent("notebook.json")
            if !fm.fileExists(atPath: marker.path) {
                let text = "{\"v\":1,\"createdAt\":\(JSONText.quoted(ISODate.format(clock(), timeZone: timeZone)))}\n"
                try writer.write(Data(text.utf8), to: marker, mode: 0o600)
            }
            // Leftovers of writes interrupted by a crash.
            for name in (try? fm.contentsOfDirectory(atPath: writer.tempDirectory.path)) ?? [] {
                try? fm.removeItem(at: writer.tempDirectory.appendingPathComponent(name))
            }
        } catch {
            throw .unavailable("筆記資料夾無法建立：\(error.localizedDescription)")
        }
        guard fm.isWritableFile(atPath: rootURL.path) else { throw .unavailable("筆記資料夾無法寫入") }
    }

    // MARK: - State file

    func touchState() {
        guard stateFlushTask == nil else { return }
        stateFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.flushStateFromTask()
        }
    }

    private func flushStateFromTask() {
        stateFlushTask = nil
        flushState()
    }

    func flushState() {
        do {
            try state.flush(writer: writer)
        } catch {
            log("notes state write failed: \(error)")
        }
    }

    func recordUserActivity(_ id: NoteID, at date: Date) {
        var s = state[id]
        if let last = s.lastUserActivityAt, last >= date { return }
        s.lastUserActivityAt = date
        state[id] = s
        touchState()
    }

    // MARK: - Scanning

    /// Every note file: `.md` files outside dot-folders and the root `assets/`, plus the trashed
    /// notes under `.codd/trash/` (not its `assets/`). Relative paths are NFC.
    func scanNoteFiles() -> [String: FileFacts.Stat] {
        var out: [String: FileFacts.Stat] = [:]
        walk(rootURL, relative: "", into: &out, trash: false)
        if FileManager.default.fileExists(atPath: trashDir.path) {
            walk(trashDir, relative: String(Self.trashPrefix.dropLast()), into: &out, trash: true)
        }
        return out
    }

    private func walk(_ dir: URL, relative: String, into out: inout [String: FileFacts.Stat], trash: Bool) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let atTop = relative.isEmpty || (trash && relative == String(Self.trashPrefix.dropLast()))
        for name in names {
            if name.hasPrefix(".") { continue }
            if atTop, name == "assets" { continue }
            let rel = (relative.isEmpty ? name : relative + "/" + name).precomposedStringWithCanonicalMapping
            let path = dir.appendingPathComponent(name).path
            var lst = stat()
            guard lstat(path, &lst) == 0 else { continue }
            let isLink = (lst.st_mode & S_IFMT) == S_IFLNK
            guard let st = FileFacts.info(path) else { continue }
            if st.isDirectory {
                // Symlinked folders are not followed (no loops, nothing outside the notebook).
                if !isLink { walk(dir.appendingPathComponent(name, isDirectory: true), relative: rel, into: &out, trash: trash) }
            } else if name.lowercased().hasSuffix(".md") {
                out[rel] = st
            }
        }
    }

    /// Images per note id in `assets/` (or the trash's `assets/`): count and bytes of the main
    /// images (not `.orig` copies).
    func assetStats(trashed: Bool) -> [String: (Int, Int)] {
        let base = trashed ? trashDir.appendingPathComponent("assets", isDirectory: true) : assetsDir
        var out: [String: (Int, Int)] = [:]
        for idName in (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? [] where !idName.hasPrefix(".") {
            out[idName] = assetStat(folder: base.appendingPathComponent(idName, isDirectory: true))
        }
        return out
    }

    func assetStat(folder: URL) -> (Int, Int) {
        var count = 0, bytes = 0
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where Self.isMainImage(name) {
            count += 1
            bytes += FileFacts.info(folder.appendingPathComponent(name).path)?.size ?? 0
        }
        return (count, bytes)
    }

    static func isMainImage(_ name: String) -> Bool {
        !name.hasPrefix(".") && !name.contains(".orig.") && !name.hasSuffix(".tmp")
    }

    // MARK: - Rows

    /// The id a file stands for before duplicate handling: its declared id, else one derived from
    /// its path (a trashed file derives from the path it had before trashing).
    func baseID(_ parsed: ParsedNote, relativePath rel: String) -> NoteID {
        if let d = parsed.declaredID { return d }
        let original = rel.hasPrefix(Self.trashPrefix) ? String(rel.dropFirst(Self.trashPrefix.count)) : rel
        return NoteNaming.derivedID(relativePath: original)
    }

    func makeRow(rel: String, parsed: ParsedNote, stat st: FileFacts.Stat, id: NoteID, duplicate: Bool,
                 updatedHint: Double?, assets: (Int, Int)) -> IndexRow {
        let trashed = rel.hasPrefix(Self.trashPrefix)
        var flags = parsed.flags
        if duplicate { flags.insert(.duplicateID) }
        let fmUpdated = parsed.updated?.timeIntervalSince1970
        var updated = max(fmUpdated ?? 0, updatedHint ?? 0)
        if updated == 0 { updated = st.mtime }
        let created = parsed.created?.timeIntervalSince1970 ?? (st.birth > 0 ? st.birth : st.mtime)
        return IndexRow(
            rowid: nil, id: id, path: rel, declaredID: parsed.declaredID?.rawValue, title: parsed.title, kind: parsed.kind,
            ai: parsed.ai, scope: parsed.scope, pinned: parsed.pinned,
            status: trashed ? "trashed" : (parsed.archived ? "archived" : "active"), created: created, updated: updated,
            updatedFM: fmUpdated, archived: parsed.archived ? (parsed.archivedAt?.timeIntervalSince1970 ?? updated) : nil,
            archivedBy: parsed.archived ? (parsed.archivedBy ?? .user) : nil,
            trashed: trashed ? (parsed.trashedAt?.timeIntervalSince1970 ?? st.mtime) : nil,
            sent: parsed.sentAt?.timeIntervalSince1970, sentTo: parsed.sentTo, condensedFrom: parsed.condensedFrom,
            condensedInto: parsed.condensedInto, createdBy: parsed.createdBy, tags: parsed.tags, sessions: parsed.sessions,
            projects: parsed.projects, mtime: st.mtime, size: st.size, birth: st.birth, hash: parsed.hash,
            snippet: parsed.snippet, bodyText: parsed.plain, assetCount: assets.0, assetBytes: assets.1, flags: flags,
            lineEnding: parsed.lineEnding)
    }

    func dupID(for base: NoteID, taken: (NoteID) -> Bool) -> NoteID {
        var n = 1
        while true {
            let raw = "\(base.rawValue)-dup\(n)"
            if let id = NoteID(rawValue: raw), !taken(id) { return id }
            if raw.count > NoteID.maxLength {
                // A long id cannot grow: fall back to a fresh derived one.
                return NoteNaming.makeID(title: base.rawValue, tags: [], taken: taken)
            }
            n += 1
        }
    }

    func idTaken(_ id: NoteID) -> Bool {
        if (try? index?.hasID(id)) == true { return true }
        if tombstones.contains(id) { return true }
        let fm = FileManager.default
        return fm.fileExists(atPath: historyStore.folder(id).path) || fm.fileExists(atPath: assetFolder(id, trashed: false).path)
    }

    // MARK: - Building

    /// Indexes every file into an empty index: oldest file first (birth time, then path), so the
    /// oldest copy of a duplicated id keeps it; batches of 50 rows (one short write transaction
    /// each), yielding between files.
    func fullBuild() async throws -> [String] {
        guard let index else { return [] }
        let files = scanNoteFiles()
        let live = assetStats(trashed: false)
        let trashed = assetStats(trashed: true)
        var warnings: [String] = []
        var taken: [NoteID: String] = [:]
        var batch: [IndexRow] = []
        batch.reserveCapacity(50)
        let ordered = files.sorted { $0.value.birth == $1.value.birth ? $0.key < $1.key : $0.value.birth < $1.value.birth }
        for (rel, st) in ordered {
            guard let data = try? Data(contentsOf: url(rel)) else { continue }
            let parsed = NoteFile.parse(data: data, timeZone: timeZone)
            var id = baseID(parsed, relativePath: rel)
            var duplicate = false
            if taken[id] != nil {
                id = dupID(for: id) { taken[$0] != nil || tombstones.contains($0) }
                duplicate = true
                warnings.append("ID 重複：\(rel) → \(id.rawValue)")
            }
            taken[id] = rel
            if parsed.flags.contains(.unparsableFrontmatter) { warnings.append("frontmatter 無法解析：\(rel)") }
            let a = (rel.hasPrefix(Self.trashPrefix) ? trashed : live)[id.rawValue] ?? (0, 0)
            batch.append(makeRow(rel: rel, parsed: parsed, stat: st, id: id, duplicate: duplicate, updatedHint: nil, assets: a))
            if batch.count >= 50 {
                try index.upsert(batch)
                batch.removeAll(keepingCapacity: true)
            }
            await Task.yield()
        }
        try index.upsert(batch)
        return warnings
    }

    /// Brings an existing index up to date with the disk: re-parses files whose (mtime, size)
    /// changed, adds new ones, drops vanished ones. Returns warnings; emits changes when asked.
    @discardableResult
    func updateFromDisk(reportExternal: Bool) async throws -> [String] {
        guard let index else { return [] }
        let known = try index.facts()
        let files = scanNoteFiles()
        var warnings: [String] = []
        var external: [NoteID] = []
        let ordered = files.sorted { $0.value.birth == $1.value.birth ? $0.key < $1.key : $0.value.birth < $1.value.birth }
        for (rel, st) in ordered {
            if let k = known[rel], k.mtime == st.mtime, k.size == st.size { continue }
            guard let data = try? Data(contentsOf: url(rel)) else { continue }
            if let row = try reindex(rel: rel, data: data, stat: st, external: true) {
                if let k = known[rel], k.hash == row.hash { continue }
                if row.flags.contains(.unparsableFrontmatter) { warnings.append("frontmatter 無法解析：\(rel)") }
                if row.flags.contains(.duplicateID) { warnings.append("ID 重複：\(rel) → \(row.id.rawValue)") }
                external.append(row.id)
            }
            await Task.yield()
        }
        let gone = known.keys.filter { files[$0] == nil }
        var removed: [NoteID] = []
        for rel in gone {
            // A row already replaced by a move (same id at a new path) is gone from the index.
            if let row = try index.row(path: rel) {
                try index.delete(paths: [rel])
                removed.append(row.id)
            }
        }
        if reportExternal {
            if !removed.isEmpty { channel.yield(.removed(removed)) }
            if !external.isEmpty {
                externalEventCount += external.count
                channel.yield(.external(external))
            }
        }
        return warnings
    }

    /// Re-indexes one file. Keeps the id the index already gave this path while the file's declared
    /// id is unchanged; a newcomer whose id another existing file holds gets `<id>-dup<n>`; an id
    /// whose holder vanished from disk moves to this path. External content changes count as user
    /// activity at the file's mtime (another editor), CODD's own writes do not get here.
    @discardableResult
    func reindex(rel: String, data: Data, stat st: FileFacts.Stat, external: Bool, updatedHint: Double? = nil) throws -> IndexRow? {
        guard let index else { return nil }
        let parsed = NoteFile.parse(data: data, timeZone: timeZone)
        let existing = try index.row(path: rel)
        var id = baseID(parsed, relativePath: rel)
        var duplicate = false
        if let existing, existing.declaredID == parsed.declaredID?.rawValue {
            id = existing.id
            duplicate = existing.flags.contains(.duplicateID)
        } else if let holder = try index.row(id: id), holder.path != rel {
            if FileManager.default.fileExists(atPath: url(holder.path).path) {
                id = dupID(for: id) { idTaken($0) }
                duplicate = true
            } else {
                try index.delete(paths: [holder.path])
            }
        }
        let trashed = rel.hasPrefix(Self.trashPrefix)
        let assets = assetStat(folder: assetFolder(id, trashed: trashed))
        let hint = updatedHint ?? (external ? st.mtime : existing?.updated)
        let row = makeRow(rel: rel, parsed: parsed, stat: st, id: id, duplicate: duplicate, updatedHint: hint, assets: assets)
        try index.upsert([row])
        if external, let existing, existing.hash != row.hash, !trashed {
            recordUserActivity(id, at: Date(timeIntervalSince1970: st.mtime))
        }
        return row
    }

    // MARK: - Watcher

    func startWatcher() {
        let w = NotesWatcher()
        guard w.start(root: realRoot) else {
            log("notes watcher failed to start")
            return
        }
        watcher = w
        let batches = w.batches
        watchTask = Task { [weak self] in
            for await batch in batches {
                guard let self else { return }
                await self.handle(batch)
            }
        }
    }

    func handle(_ events: [NotesWatcher.Event]) async {
        guard isOpen, let index else { return }
        let prefix = realRoot.hasSuffix("/") ? realRoot : realRoot + "/"
        if events.contains(where: { $0.rootChanged }) || !FileManager.default.fileExists(atPath: rootURL.path) {
            if !FileManager.default.fileExists(atPath: rootURL.path) {
                channel.yield(.unavailable("筆記資料夾不見了"))
                return
            }
        }
        if events.contains(where: { $0.mustRescan }) {
            _ = try? await updateFromDisk(reportExternal: true)
            return
        }
        var files = Set<String>()
        var dirs = Set<String>()
        var assetIDs = Set<String>()
        for e in events {
            var path = e.path
            if path.hasPrefix("/private/"), !prefix.hasPrefix("/private/") { path.removeFirst("/private".count) }
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count)).precomposedStringWithCanonicalMapping
            if rel.hasPrefix(".") || rel.contains("/.") { continue }
            if rel.hasPrefix("assets/") {
                let parts = rel.split(separator: "/")
                if parts.count >= 2 { assetIDs.insert(String(parts[1])) }
                continue
            }
            if rel == "assets" { continue }
            if e.isDirectory {
                dirs.insert(rel)
            } else if rel.lowercased().hasSuffix(".md") {
                files.insert(rel)
            }
        }
        // A created / renamed / deleted folder: every note under it, on disk and in the index.
        for d in dirs {
            var found: [String: FileFacts.Stat] = [:]
            if FileManager.default.fileExists(atPath: url(d).path) {
                walkFolder(d, into: &found)
            }
            files.formUnion(found.keys)
            if let rows = try? index.rows(where: "path LIKE ? ESCAPE '\\'", arguments: [NotesIndex.likeEscape(d) + "/%"]) {
                files.formUnion(rows.map(\.path))
            }
        }
        var external: [NoteID] = []
        var changed: [NoteID] = []
        var removed: [NoteID] = []
        let existing = files.filter { FileManager.default.fileExists(atPath: url($0).path) }.sorted()
        let missing = files.subtracting(existing).sorted()
        for rel in existing {
            guard let st = FileFacts.info(url(rel).path), !st.isDirectory, let data = try? Data(contentsOf: url(rel)) else { continue }
            let hash = Hashing.sha256Hex(data)
            let row = try? index.row(path: rel)
            if let row, row.hash == hash {
                if row.mtime != st.mtime || row.size != st.size { _ = try? reindex(rel: rel, data: data, stat: st, external: false) }
                continue
            }
            let own = ownWrites[rel] == hash
            guard let newRow = try? reindex(rel: rel, data: data, stat: st, external: !own) else { continue }
            if own { changed.append(newRow.id) } else { external.append(newRow.id) }
            // A folder of notes copied in at once must not hold the actor for the whole batch.
            await Task.yield()
        }
        for rel in missing {
            guard let row = try? index.row(path: rel) else { continue }
            try? index.delete(paths: [rel])
            if !external.contains(row.id), !changed.contains(row.id) { removed.append(row.id) }
        }
        for idName in assetIDs {
            guard let id = NoteID(rawValue: idName), let row = try? index.row(id: id), !row.isTrashed else { continue }
            let (count, bytes) = assetStat(folder: assetFolder(id, trashed: false))
            if count != row.assetCount || bytes != row.assetBytes {
                try? index.updateAssets(id: id, count: count, bytes: bytes)
                if !external.contains(id) { changed.append(id) }
            }
        }
        if !removed.isEmpty { channel.yield(.removed(removed)) }
        if !changed.isEmpty { channel.yield(.changed(changed)) }
        if !external.isEmpty {
            externalEventCount += external.count
            log("notes external change count=\(external.count)")
            channel.yield(.external(external))
        }
    }

    private func walkFolder(_ rel: String, into out: inout [String: FileFacts.Stat]) {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: url(rel).path) else { return }
        while let sub = e.nextObject() as? String {
            if sub.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            guard sub.lowercased().hasSuffix(".md") else { continue }
            let full = rel + "/" + sub
            if let st = FileFacts.info(url(full).path), !st.isDirectory { out[full.precomposedStringWithCanonicalMapping] = st }
        }
    }

    // MARK: - Writing note files

    /// Writes a note file atomically and remembers it as CODD's own write.
    func writeNote(_ text: String, to rel: String) throws(NotesError) -> (Data, FileFacts.Stat) {
        let data = Data(text.utf8)
        do {
            try writer.write(data, to: url(rel))
        } catch {
            throw .io("無法寫入筆記：\(error)")
        }
        ownWrites[rel] = Hashing.sha256Hex(data)
        if ownWrites.count > 2048 { ownWrites.removeAll() }
        guard let st = FileFacts.info(url(rel).path) else { throw .io("無法讀取剛寫入的筆記") }
        return (data, st)
    }
}
