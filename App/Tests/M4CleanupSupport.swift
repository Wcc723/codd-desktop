import CoddCore
import CoddNotes
import CoddPreferences
import Foundation
import Testing
@testable import CODD

// M4 I4a test support: a temp data root with an unstarted session store (no holder, no claude),
// the notebook on a clock the test moves, the D38 app trash into a temp folder and the retention
// service on all of them.

/// A clock the test moves (notes, retention and the digest read it).
final class CleanupTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) { value = date }

    var now: Date { lock.withLock { value } }

    func advance(days: Double) {
        lock.withLock { value = value.addingTimeInterval(days * 86_400) }
    }

    var function: @Sendable () -> Date { { [self] in self.now } }
}

@MainActor
final class CleanupRig {
    static let taipei = TimeZone(identifier: "Asia/Taipei")!
    /// Sunday 2026-10-18 10:00 Taipei.
    static let start = Date(timeIntervalSince1970: 1_792_288_800)

    let folder: String
    let root: CoddDataRoot
    let claude: ClaudeDirectory
    let store: HolderSessionStore
    let notes: NotesService
    let preferences: PreferencesService
    let clock: CleanupTestClock
    let trashFolder: String
    let trash: AppTrash
    let state: CleanupStateStore
    let retention: RetentionService
    let logs = LockedLines()
    let projectID: ProjectID
    let projectUUID = UUID()
    let work: String

    init(_ prefix: String, hooks: Bool = false, preferences: PreferencesService = .inMemory()) async throws {
        folder = try m3TempFolder(prefix)
        root = CoddDataRoot(path: folder + "/data")
        claude = ClaudeDirectory(path: folder + "/home/.claude")
        work = folder + "/work"
        trashFolder = folder + "/trash"
        for dir in [root.path, root.sessionsPath, root.runPath, claude.path + "/projects", work] {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let logs = self.logs
        clock = CleanupTestClock(Self.start)
        var pipeline: HookPipeline?
        if hooks {
            pipeline = HookPipeline(dataRoot: root.url, claudeDirectory: claude, port: 0, portRange: HookPipeline.testPortRange) { logs.append($0) }
            _ = await pipeline?.loadConfig()
        }
        store = HolderSessionStore(root: root, launcher: HolderLauncher(holderExecutable: "/usr/bin/false", root: root), claudeDirectory: claude,
                                   hooks: pipeline) { logs.append($0) }
        projectID = LayoutMapping.id(projectUUID)
        store.projectsByID[projectID] = ProjectVM(id: projectID, name: "work", cwd: work, groupID: HolderSessionStore.ungroupedID, sessionIDs: [])
        self.preferences = preferences
        trash = AppTrash(target: .folder(trashFolder), log: { logs.append($0) })
        let locations = NotesService.locations(dataRoot: root)
        notes = NotesService(notesRoot: locations.notes, cacheFolder: locations.cache, preferences: preferences, trash: trash,
                             clock: clock.function, timeZone: Self.taipei, log: { logs.append($0) })
        state = CleanupStateStore(dataRoot: root.url, log: { logs.append($0) })
        retention = RetentionService(holders: store, notes: notes, preferences: preferences, trash: trash, state: state, recentFiles: nil,
                                     clock: clock.function, timeZone: Self.taipei, log: { logs.append($0) })
        await notes.open()
    }

    func tearDown() {
        retention.stop()
        m3RemoveFolder(folder)
        m4RemoveAgainLater(folder)
    }

    var library: NotesLibrary { notes.library! }

    // MARK: Notes

    @discardableResult
    func note(_ title: String, body: String? = nil, kind: NoteKind = .note, ai: NoteAIAccess = .read, links: NoteLinks = NoteLinks()) async throws -> NoteID {
        try await notes.create(NewNote(title: title, body: body ?? "# \(title)\n\n\(title) 的內容，記錄一些決定與數字 42。\n", kind: kind,
                                       links: links, ai: ai)).metadata.id
    }

    func status(_ id: NoteID) async -> String? {
        (try? await library.summary(id))?.metadata.state.status
    }

    // MARK: Sessions

    /// A CODD session in the project: stopped (or `state`) since `since`, archived at `archivedAt`.
    @discardableResult
    func session(_ title: String, kind: CODD.SessionKind = .shell, state: CODD.SessionState = .stopped, since: Date, pinned: Bool = false,
                 archivedAt: Date? = nil, ringBytes: Int? = nil) throws -> SessionID {
        let uuid = UUID()
        let id = LayoutMapping.id(uuid)
        let vm = SessionVM(id: id, projectID: projectID, kind: kind, title: title, state: state, stateSince: since)
        vm.isPinned = pinned
        store.records[id] = LayoutSessionRecord(id: uuid, projectId: projectUUID, kind: kind == .claude ? .claude : .shell, title: title,
                                                pinned: pinned, order: 0, createdAt: since, lastState: .stopped, lastStateAt: since,
                                                archivedAt: archivedAt)
        if archivedAt != nil {
            store.archivedByID[id] = vm
        } else {
            store.sessionsByID[id] = vm
            store.projectsByID[projectID]?.sessionIDs.append(id)
        }
        if let ringBytes {
            let dir = root.sessionDirectory(id)
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: ringBytes).write(to: URL(fileURLWithPath: dir + "/ring"))
            try Data("holder log\n".utf8).write(to: URL(fileURLWithPath: dir + "/holder.log"))
        }
        return id
    }

    func days(_ n: Double) -> Date { clock.now.addingTimeInterval(n * 86_400) }

    /// `cleanup.json` with an old `firstRunAt` (the D30 grace is over).
    func graceOver(daysAgo: Double = 60) throws {
        let at = days(-daysAgo)
        let json = "{\"v\":1,\"sessions\":{},\"files\":{},\"retention\":{\"firstRunAt\":\"\(CleanupState.isoString(at))\"}}\n"
        try json.write(toFile: root.path + "/cleanup.json", atomically: true, encoding: .utf8)
    }

    var trashed: [String] { (try? FileManager.default.contentsOfDirectory(atPath: trashFolder)) ?? [] }

    var taipeiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.taipei
        return calendar
    }
}
