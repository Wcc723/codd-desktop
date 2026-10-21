import CoddCore
import CoddFiles
import CoddNotes
import CoddPreferences
import Foundation
import Observation

/// M4 I4a: the retention engine in the app (D29, D30) and the Cleanup page's candidates (D31).
///
/// A run — at launch (after the notebook opened and the first session discovery), every 24 h, and
/// after a CLEANUP setting changed — does two things:
/// - notes: `NotesLibrary.runRetention(liveSessions:)` (archive what is due, purge trash older than
///   `trashPurgeDays` through the app trash, D38);
/// - sessions: CoddCore `SessionRetention.evaluate` over CODD's own sessions (never externals,
///   running or pinned ones): the stopped-stale dim, auto-archive through the store's `封存`
///   (restorable, `archivedAt` set) and, for sessions archived longer than `scrollbackDeleteDays`,
///   their `ring` and `holder.log` through the app trash. The session clocks count from
///   `cleanup.json` `retention.firstRunAt` at the earliest (written by the first run on a data
///   root, D30): the first M4 launch never archives existing stopped sessions or trashes rings.
///
/// Between runs it keeps the candidates the Cleanup page lists (NOTES, SESSIONS, FILES), the
/// counts every `清理建議 n →` shows, and the D31 digest. Nothing outside the data root (and the
/// notes folder inside it) is ever moved.
@MainActor @Observable
final class RetentionService {
    /// A Recent entry (`files/recent.json`) whose file is gone (FILES).
    struct MissingRecent: Equatable, Sendable {
        var path: String
        var root: String
        var openedAt: Date
    }

    /// One FILES row.
    enum FileCandidate: Equatable, Sendable {
        /// A note image no body or kept snapshot uses (`path` relative to the notes folder).
        case image(NoteCleanupCandidate, path: String)
        /// An archived session's terminal log, deleted soon.
        case ring(SessionCleanupCandidate)
        case recent(MissingRecent)

        /// The row id (`image:<path>`, `ring:<session>`, `recent:<path>`).
        var id: String {
            switch self {
            case .image(_, let path): "image:" + path
            case .ring(let c): "ring:" + c.id.uuidString.lowercased()
            case .recent(let r): "recent:" + r.path
            }
        }
    }

    struct Candidates: Equatable, Sendable {
        var notes: [NoteCleanupCandidate] = []
        var sessions: [SessionCleanupCandidate] = []
        var files: [FileCandidate] = []

        var total: Int { notes.count + sessions.count + files.count }
    }

    /// What this app run's retention moved (the dump's `retention`): every run adds to it.
    struct Report: Equatable, Sendable {
        var runs = 0
        var lastReason: String?
        var staleIDs: [String] = []
        var archived: [String] = []
        var purged: [String] = []
        var sessionsStale: [String] = []
        var sessionsArchived: [String] = []
        var ringsTrashed: [String] = []
        var lastMs: Double?
    }

    /// The last digest decision (the dump's `cleanup.digest`).
    struct DigestRecord: Equatable, Sendable {
        var at: Date
        var count: Int
        var notified: Bool
    }

    // MARK: Configuration

    @ObservationIgnored let holders: HolderSessionStore?
    @ObservationIgnored let notes: NotesService
    @ObservationIgnored let preferences: PreferencesService
    @ObservationIgnored let trash: AppTrash
    @ObservationIgnored let state: CleanupStateStore
    @ObservationIgnored let recentFiles: RecentFilesStore?
    @ObservationIgnored let clock: @Sendable () -> Date
    @ObservationIgnored let timeZone: TimeZone
    @ObservationIgnored private let log: @Sendable (String) -> Void
    /// Claude's `cleanupPeriodDays` (`<claudeDir>/settings.json`; nil = 30).
    @ObservationIgnored var cleanupPeriodDays: () -> Int? = { nil }
    /// Posts the digest (AppNotifier `cleanup-digest`); returns whether it was posted (false when
    /// suppressed). Nil: no notifier yet (the digest waits).
    @ObservationIgnored var postDigest: ((_ title: String, _ body: String) -> Bool)?
    /// The hourly tick (tests shorten it).
    @ObservationIgnored var tickInterval: Duration = .seconds(3600)
    /// A run follows a CLEANUP setting change this long after the last change.
    @ObservationIgnored var settingsDebounce: Duration = .seconds(1)

    // MARK: Observable state

    private(set) var candidates = Candidates()
    private(set) var report = Report()
    private(set) var isRunning = false
    private(set) var lastDigest: DigestRecord?
    /// Bumped by every refresh (the page and the dump follow it).
    private(set) var revision = 0
    /// The first run finished (the counts mean something).
    private(set) var started = false

    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var appliedKey: String?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    static let keepDays = 30
    static let day: TimeInterval = 86_400

    init(holders: HolderSessionStore?, notes: NotesService, preferences: PreferencesService, trash: AppTrash, state: CleanupStateStore,
         recentFiles: RecentFilesStore?, clock: @escaping @Sendable () -> Date, timeZone: TimeZone = .current,
         log: @escaping @Sendable (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.holders = holders
        self.notes = notes
        self.preferences = preferences
        self.trash = trash
        self.state = state
        self.recentFiles = recentFiles
        self.clock = clock
        self.timeZone = timeZone
        self.log = log
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    // MARK: Lifecycle

    /// Loads cleanup.json, waits for the notebook, runs once and starts the hourly tick. Later
    /// calls wait for that same start (DEBUG flags, the Cleanup page).
    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { [weak self] () -> Void in await self?.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        if !state.isLoaded { state.load() }
        appliedKey = Self.policyKey(preferences.preferences)
        await notes.open()
        await run(reason: "launch")
        started = true
        let interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        settingsTask?.cancel()
        settingsTask = nil
    }

    /// The hourly tick: a run once 24 h passed since the last one, else fresh candidates; then the digest.
    func tick() async {
        let now = clock()
        if let last = state.state.retention.lastRunAt, now.timeIntervalSince(last) < Self.day, last <= now {
            await refresh()
            checkDigest()
        } else {
            await run(reason: "daily")
        }
    }

    /// Settings › 清理 changed: a run (debounced) when a retention value changed; the digest
    /// frequency only re-checks the digest.
    func apply(preferences value: CoddPreferences) {
        let key = Self.policyKey(value)
        guard started, let applied = appliedKey else {
            appliedKey = key
            return
        }
        guard key != applied else {
            checkDigest()
            return
        }
        appliedKey = key
        settingsTask?.cancel()
        let delay = settingsDebounce
        settingsTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.run(reason: "settings")
        }
    }

    /// The values a run depends on (Settings › 清理, the ADVANCED scrollback mirror included).
    static func policyKey(_ value: CoddPreferences) -> String {
        let c = value.cleanup
        let parts: [Int?] = [c.notesStaleDays, c.notesArchiveDays, c.scratchArchiveDays, c.trashPurgeDays, c.tombstoneDays,
                             c.sessionsStaleDays, c.sessionsArchiveDays, c.scrollbackDeleteDays]
        return parts.map { $0.map { String($0) } ?? "-" }.joined(separator: ",") + "|\(c.exempt)|\(c.resumeWarning)"
    }

    /// D30 from Settings › 清理 (12 終端機紀錄保留 edits the same `scrollbackDeleteDays` leaf).
    static func sessionPolicy(_ value: CoddPreferences, cleanupPeriodDays: Int?, firstRunAt: Date?) -> SessionRetentionPolicy {
        let c = value.cleanup
        return SessionRetentionPolicy(staleDays: c.sessionsStaleDays, archiveDays: c.sessionsArchiveDays,
                                      scrollbackDeleteDays: c.scrollbackDeleteDays,
                                      cleanupPeriodDays: cleanupPeriodDays ?? TranscriptRetention.defaultCleanupPeriodDays,
                                      resumeWarning: c.resumeWarning, countFrom: firstRunAt)
    }

    // MARK: Runs

    /// One retention run. Runs never overlap: each request is chained after the one before it.
    @discardableResult
    func run(reason: String) async -> Report {
        let previous = runTask
        let task = Task { [weak self] () -> Void in
            await previous?.value
            await self?.performRun(reason: reason)
        }
        runTask = task
        await task.value
        if runTask == task { runTask = nil }
        return report
    }

    private func performRun(reason: String) async {
        isRunning = true
        defer { isRunning = false }
        let started = ContinuousClock.now
        if !state.isLoaded { state.load() }
        let now = clock()
        var firstRun = false
        if state.state.retention.firstRunAt == nil {
            firstRun = true
            state.update { $0.retention.firstRunAt = now }
        }
        let prefs = preferences.preferences
        // Notes (D29): no grace, they are new in M4.
        if let library = notes.library, notes.availability.isReady {
            let (policy, access) = NotesService.policy(prefs)
            await library.setPolicy(policy, defaultAccess: access)
            let result = await library.runRetention(liveSessions: liveSessionIDs)
            report.staleIDs = result.staleIDs.map(\.rawValue)
            report.archived.append(contentsOf: result.archived.map(\.rawValue))
            report.purged.append(contentsOf: result.purged.map(\.rawValue))
            if !result.archived.isEmpty || !result.purged.isEmpty { await notes.refreshNow() }
        }
        // Sessions (D30), on the grace clock.
        if let holders {
            let policy = Self.sessionPolicy(prefs, cleanupPeriodDays: cleanupPeriodDays(), firstRunAt: state.state.retention.firstRunAt)
            let inputs = await sessionInputs(holders)
            let result = SessionRetention.evaluate(inputs, policy: policy, now: now, timeZone: timeZone)
            applyStale(result.staleIDs, holders)
            let archived = archiveSessions(result.archiveIDs, holders, now: now)
            let rings = trashRings(result.ringDeleteIDs, holders)
            report.sessionsStale = result.staleIDs.map { $0.uuidString.lowercased() }.sorted()
            report.sessionsArchived.append(contentsOf: archived)
            report.ringsTrashed.append(contentsOf: rings)
            log("retention sessions archived=\(archived.count) rings=\(rings.count) stale=\(result.staleIDs.count)"
                + (firstRun ? " first-run" : ""))
        }
        state.update { s in
            s.retention.lastRunAt = now
            s.expire(now: now)
        }
        report.runs += 1
        report.lastReason = reason
        report.lastMs = NotesService.milliseconds(ContinuousClock.now - started)
        await refresh()
        checkDigest()
    }

    /// Archived and live sessions: the Cleanup page refreshes its candidates when this changes
    /// (an unarchive or a RESUME while the page shows).
    var sessionsSignature: String {
        guard let holders else { return "" }
        let archived = holders.archivedByID.keys.sorted().joined(separator: ",")
        let live = holders.sessionsByID.values.filter { $0.state.isLive }.map(\.id).sorted().joined(separator: ",")
        return archived + "|" + live
    }

    /// Running CODD claude sessions (D29 exemptions: notes linked to or read by them stay).
    var liveSessionIDs: Set<String> {
        guard let holders else { return [] }
        return Set(holders.sessionsByID.values.filter { $0.kind == .claude && $0.state.isLive }.map { $0.id.lowercased() })
    }

    private func applyStale(_ ids: Set<UUID>, _ holders: HolderSessionStore) {
        let next = Set(ids.map { $0.uuidString.lowercased() })
        guard next != holders.retentionStaleIDs else { return }
        holders.retentionStaleIDs = next
        holders.refreshStale()
    }

    /// Auto-archive (D30): the store's `封存`, with `archivedAt` on the retention clock.
    private func archiveSessions(_ ids: [UUID], _ holders: HolderSessionStore, now: Date) -> [String] {
        var done: [String] = []
        for uuid in ids {
            let id = uuid.uuidString.lowercased()
            // Checked again: the session may have restarted since the facts were read.
            guard let session = holders.sessionsByID[id], !session.state.isLive, !session.isPinned, !session.external,
                  !(holders.runtime(id)?.holderAlive ?? false) else { continue }
            _ = holders.archive([id])
            guard holders.archivedByID[id] != nil else { continue }
            holders.records[id]?.archivedAt = now
            done.append(id)
            log("retention session archive id=\(id)")
        }
        if !done.isEmpty { holders.scheduleLayoutSave() }
        return done
    }

    /// The `ring` and `holder.log` of long-archived sessions through the app trash (D38).
    private func trashRings(_ ids: [UUID], _ holders: HolderSessionStore) -> [String] {
        var done: [String] = []
        for uuid in ids {
            let id = uuid.uuidString.lowercased()
            guard holders.archivedByID[id] != nil, !(holders.runtime(id)?.holderAlive ?? false) else { continue }
            if trashRing(id, holders) { done.append(id) }
        }
        return done
    }

    /// Moves `<dataRoot>/sessions/<id>/ring` (and `holder.log`) to the app trash; true when the ring went.
    /// Checked at the move itself, whoever asks: a session unarchived and resumed since the
    /// candidates were read (the Cleanup page can stay open) keeps its live ring and log.
    @discardableResult
    func trashRing(_ id: String, _ holders: HolderSessionStore) -> Bool {
        let id = id.lowercased()
        guard holders.archivedByID[id] != nil, !(holders.runtime(id)?.holderAlive ?? false) else {
            log("retention ring kept session=\(id) (not archived any more, or its holder runs)")
            return false
        }
        let directory = holders.root.sessionDirectory(id)
        var moved = false
        for name in ["ring", HolderLauncher.logFileName] {
            let path = directory + "/" + name
            guard Self.isRegularFile(path) else { continue }
            do {
                try trash.move(URL(fileURLWithPath: path, isDirectory: false))
                if name == "ring" { moved = true }
            } catch {
                log("retention ring trash failed session=\(id) name=\(name): \(error)")
            }
        }
        if moved { log("retention ring trashed session=\(id)") }
        return moved
    }

    nonisolated static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    // MARK: Session facts

    /// What the engine needs about one CODD session, read on the main actor.
    struct SessionFact: Sendable {
        var uuid: UUID
        var title: String
        var kind: CoddCore.SessionKind
        var isRunning: Bool
        var isPinned: Bool
        var lastState: CoddCore.SessionState?
        var lastStateAt: Date?
        var archivedAt: Date?
        var keepUntil: Date?
        var claudeID: String?
        var cwd: String?
        var catalog: TranscriptCatalog?
        var ringPath: String
    }

    /// Every CODD session (archived ones included; never externals, never ephemeral shells) with
    /// its transcript and ring facts, the file system part read off the main actor.
    func sessionInputs(_ holders: HolderSessionStore) async -> [SessionRetentionInput] {
        let now = clock()
        var facts: [SessionFact] = []
        let all = holders.sessionsByID.merging(holders.archivedByID, uniquingKeysWith: { a, _ in a })
        for (id, session) in all.sorted(by: { $0.key < $1.key }) {
            guard !session.external, holders.ephemeral[id] == nil, let uuid = UUID(uuidString: id) else { continue }
            let record = holders.records[id]
            let runtime = holders.runtime(id)
            let alive = runtime?.holderAlive ?? false
            let archived = holders.archivedByID[id] != nil
            var lastState: CoddCore.SessionState?
            switch session.state {
            case .stopped: lastState = .stopped
            case .exited: lastState = .exited(code: session.exitCode)
            default: lastState = nil
            }
            let claude = session.kind == .claude
            let cwd = runtime?.cwd ?? holders.project(session.projectID)?.cwd
            facts.append(SessionFact(
                uuid: uuid, title: session.title, kind: claude ? .claude : .shell, isRunning: session.state.isLive || alive,
                isPinned: session.isPinned, lastState: lastState, lastStateAt: session.stateSince,
                archivedAt: archived ? (record?.archivedAt ?? now) : nil, keepUntil: state.state.sessionKept(id, now: now),
                claudeID: claude ? (record?.claudeSessionId ?? session.claudeSessionID ?? id) : nil, cwd: cwd,
                catalog: claude && !(session.state.isLive || alive) ? holders.transcriptCatalog(for: id) : nil,
                ringPath: holders.root.sessionDirectory(id) + "/ring"))
        }
        return await Task.detached(priority: .utility) { facts.map(Self.input) }.value
    }

    /// Blocking file reads (transcript head, ring size): off the main actor.
    nonisolated static func input(_ f: SessionFact) -> SessionRetentionInput {
        var transcriptAt: Date?
        var exists: Bool?
        if let catalog = f.catalog, let claudeID = f.claudeID, let cwd = f.cwd {
            let summary = catalog.transcript(sessionId: claudeID, cwd: cwd)
            transcriptAt = summary?.lastActivity
            exists = summary != nil
        }
        var ring: Int64?
        var st = stat()
        if lstat(f.ringPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { ring = Int64(st.st_size) }
        return SessionRetentionInput(id: f.uuid, title: f.title, kind: f.kind, isRunning: f.isRunning, isPinned: f.isPinned,
                                     isExternal: false, lastState: f.lastState, lastStateAt: f.lastStateAt, archivedAt: f.archivedAt,
                                     keepUntil: f.keepUntil, transcriptModifiedAt: transcriptAt, transcriptExists: exists,
                                     ringBytes: ring)
    }

    // MARK: Candidates (D31)

    /// Recomputes the three lists and the counts.
    func refresh() async {
        let now = clock()
        var next = Candidates()
        if let library = notes.library, notes.availability.isReady {
            let all = await library.cleanupCandidates(liveSessions: liveSessionIDs)
            let kept = state.state
            for candidate in all {
                if case .unusedAsset(let path, _) = candidate.reason {
                    let absolute = notes.notesRoot.appendingPathComponent(path).path
                    if !kept.fileKept(absolute, now: now) { next.files.append(.image(candidate, path: path)) }
                } else {
                    next.notes.append(candidate)
                }
            }
        }
        if let holders {
            let policy = Self.sessionPolicy(preferences.preferences, cleanupPeriodDays: cleanupPeriodDays(),
                                            firstRunAt: state.state.retention.firstRunAt ?? now)
            let inputs = await sessionInputs(holders)
            let result = SessionRetention.evaluate(inputs, policy: policy, now: now, timeZone: timeZone)
            for candidate in result.candidates {
                if candidate.isFile { next.files.append(.ring(candidate)) } else { next.sessions.append(candidate) }
            }
        }
        next.files.append(contentsOf: await missingRecent(now: now).map { .recent($0) })
        if next != candidates { candidates = next }
        if let holders, holders.cleanupSuggestions != next.total { holders.cleanupSuggestions = next.total }
        revision += 1
    }

    /// Recent entries whose file no longer exists (and not kept).
    private func missingRecent(now: Date) async -> [MissingRecent] {
        guard let recentFiles else { return [] }
        let kept = state.state
        let items = await Task.detached(priority: .utility) { () -> [RecentFile] in
            recentFiles.load().filter { !FileManager.default.fileExists(atPath: $0.path) }
        }.value
        return items.filter { !kept.fileKept($0.path, now: now) }.map { MissingRecent(path: $0.path, root: $0.root, openedAt: $0.openedAt) }
    }

    var counts: (notes: Int, sessions: Int, files: Int) { (candidates.notes.count, candidates.sessions.count, candidates.files.count) }

    // MARK: Actions (the Cleanup page)

    /// `保留 30 天` of notes: `state.json` `keepUntil` (no STALE, no archive, no Cleanup row).
    func keepNotes(_ ids: [NoteID]) async {
        guard let library = notes.library else { return }
        let until = clock().addingTimeInterval(Double(Self.keepDays) * Self.day)
        for id in ids { await library.keep(id, until: until) }
        log("cleanup keep notes=\(ids.count)")
        await refresh()
    }

    /// `封存` of notes (by the user; restorable).
    func archiveNotes(_ ids: [NoteID]) async throws {
        guard let library = notes.library else { throw NotesError.unavailable("筆記本尚未開啟") }
        try await library.archive(ids, by: .user)
        log("cleanup archive notes=\(ids.count)")
        await notes.refreshNow()
        await refresh()
    }

    func unarchiveNotes(_ ids: [NoteID]) async {
        guard let library = notes.library else { return }
        try? await library.unarchive(ids)
        await notes.refreshNow()
        await refresh()
    }

    /// NOTES `移到垃圾桶`: CODD's TRASH (`.codd/trash/`, restorable until the purge).
    func trashNotes(_ ids: [NoteID]) async throws {
        guard let library = notes.library else { throw NotesError.unavailable("筆記本尚未開啟") }
        try await library.trash(ids)
        log("cleanup trash notes=\(ids.count)")
        await notes.refreshNow()
        await refresh()
    }

    func restoreNotes(_ ids: [NoteID]) async {
        guard let library = notes.library else { return }
        try? await library.restore(ids)
        await notes.refreshNow()
        await refresh()
    }

    /// `保留 30 天` of sessions (or an archived session's ring): `cleanup.json` `sessions.<id>`.
    func keepSessions(_ ids: [String]) async {
        let until = clock().addingTimeInterval(Double(Self.keepDays) * Self.day)
        state.update { s in
            for id in ids { s.sessions[id.lowercased()] = CleanupState.Keep(keepUntil: until) }
        }
        log("cleanup keep sessions=\(ids.count)")
        await refresh()
    }

    /// SESSIONS `封存`: the store's archive (the returned closure restores them).
    func archiveSessions(_ ids: [String]) async -> (@MainActor () -> Void)? {
        guard let holders else { return nil }
        let present = ids.filter { holders.sessionsByID[$0] != nil }
        guard !present.isEmpty else { return nil }
        let restore = holders.archive(present)
        log("cleanup archive sessions=\(present.count)")
        await refresh()
        return restore
    }

    /// FILES `保留 30 天`: images and Recent entries by path, rings through their session.
    func keepFiles(_ rowIDs: [String]) async {
        let until = clock().addingTimeInterval(Double(Self.keepDays) * Self.day)
        let rows = candidates.files.filter { rowIDs.contains($0.id) }
        state.update { s in
            for row in rows {
                switch row {
                case .image(_, let path): s.files[notes.notesRoot.appendingPathComponent(path).path] = CleanupState.Keep(keepUntil: until)
                case .ring(let c): s.sessions[c.id.uuidString.lowercased()] = CleanupState.Keep(keepUntil: until)
                case .recent(let r): s.files[r.path] = CleanupState.Keep(keepUntil: until)
                }
            }
        }
        log("cleanup keep files=\(rows.count)")
        await refresh()
    }

    /// FILES `移到垃圾桶`: an image or a ring through the app trash (D38); a Recent entry is
    /// removed from `recent.json` (its file is already gone). Returns how many went.
    func trashFiles(_ rowIDs: [String]) async -> Int {
        let rows = candidates.files.filter { rowIDs.contains($0.id) }
        var done = 0
        for row in rows {
            switch row {
            case .image(_, let path):
                let url = notes.notesRoot.appendingPathComponent(path)
                // Only a file inside the notes folder's assets (the candidate's own path).
                guard path.hasPrefix("assets/"), !path.contains("/../"), Self.isRegularFile(url.path) else { continue }
                do {
                    try trash.move(url)
                    done += 1
                } catch {
                    log("cleanup image trash failed: \(error)")
                }
            case .ring(let c):
                if let holders, trashRing(c.id.uuidString.lowercased(), holders) { done += 1 }
            case .recent(let r):
                recentFiles?.remove(URL(fileURLWithPath: r.path))
                done += 1
            }
        }
        log("cleanup trash files=\(done)")
        await refresh()
        return done
    }

    // MARK: Digest (D31)

    /// Shows the digest when it is due (once per period, ≥ 5 candidates); the decision is recorded
    /// in cleanup.json either way it went (posted or suppressed).
    func checkDigest() {
        guard let postDigest else { return }
        let now = clock()
        let frequency = preferences.preferences.cleanup.digest
        let total = candidates.total
        guard CleanupDigest.isDue(frequency, now: now, lastShownAt: state.state.digest.lastShownAt, candidates: total, calendar: calendar)
        else { return }
        let content = CleanupDigest.content(notes: candidates.notes.count, sessions: candidates.sessions.count, files: candidates.files.count)
        let posted = postDigest(content.title, content.body)
        state.update { $0.digest = CleanupState.Digest(lastShownAt: now, lastCount: total) }
        lastDigest = DigestRecord(at: now, count: total, notified: posted)
        log("cleanup digest count=\(total) posted=\(posted)")
    }

    // MARK: Dump (§6)

    /// `retention {firstRunAt, lastRunAt, staleIDs, archived[], purged[], sessionsArchived[], ringsTrashed[], trashTarget}`.
    var retentionDump: [String: Any] {
        let s = state.state.retention
        return [
            "firstRunAt": s.firstRunAt.map { CleanupState.isoString($0) as Any } ?? NSNull(),
            "lastRunAt": s.lastRunAt.map { CleanupState.isoString($0) as Any } ?? NSNull(),
            "runs": report.runs, "reason": report.lastReason ?? NSNull(), "ms": report.lastMs ?? NSNull(),
            "staleIDs": report.staleIDs, "archived": report.archived, "purged": report.purged,
            "sessionsStale": report.sessionsStale, "sessionsArchived": report.sessionsArchived, "ringsTrashed": report.ringsTrashed,
            "trashTarget": trash.target.name, "running": isRunning,
        ]
    }

    /// `cleanup.counts` and `cleanup.digest`.
    var countsDump: [String: Any] {
        ["notes": candidates.notes.count, "sessions": candidates.sessions.count, "files": candidates.files.count, "total": candidates.total]
    }

    var digestDump: [String: Any] {
        [
            "lastShownAt": state.state.digest.lastShownAt.map { CleanupState.isoString($0) as Any } ?? NSNull(),
            "lastCount": state.state.digest.lastCount ?? NSNull(),
            "notified": lastDigest?.notified ?? false, "shownThisRun": lastDigest != nil,
            "frequency": preferences.preferences.cleanup.digest.rawValue,
        ]
    }
}
