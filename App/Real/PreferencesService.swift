import CoddPreferences
import Foundation
import Observation

/// `<dataRoot>/preferences.json` for the app (M3 D14): every Settings value, observable.
///
/// The file is read once, off the main actor (`load()`); until then `preferences` holds the
/// defaults and `isLoaded` is false. A first run (no file yet) migrates the M1 / M2 UserDefaults
/// switch `CODDNotificationsEnabled`. Edits go through `update(_:)` and are written 300 ms after the
/// last one (the store keeps unknown keys, never overwrites a newer file and moves a corrupt one
/// aside); `flush()` at quit writes a pending edit at once. Mock mode keeps everything in memory.
///
/// DEBUG `-codd-set-pref <path>=<value>` assignments are applied after the load for this run only:
/// they are never written, unless a later edit changes that same value (then it is the user's).
/// Loads and saves run on one serial queue, so they never overlap or reorder.
@MainActor @Observable
final class PreferencesService {
    /// The values in effect (the file's plus this run's DEBUG assignments).
    private(set) var preferences: CoddPreferences
    private(set) var isLoaded: Bool
    /// How the file was found; nil before the load and in memory.
    private(set) var origin: PreferencesStore.Origin?
    /// The last successful save, and the last failure as Settings shows it (nil after a success).
    private(set) var savedAt: Date?
    private(set) var saveProblem: String?

    /// nil in memory (mock mode).
    @ObservationIgnored let store: PreferencesStore?
    @ObservationIgnored private let legacyDefaults: UserDefaults?
    @ObservationIgnored private let assignments: [String]
    /// Each DEBUG assignment and its refusal (nil = applied), for the log and the state dump.
    @ObservationIgnored private(set) var assignmentResults: [(assignment: String, error: String?)] = []
    /// Leaves a DEBUG assignment set and no edit changed since: a save keeps their file value.
    @ObservationIgnored private var overridden: Set<String> = []
    /// What a save writes: `preferences` with the `overridden` leaves at their file value.
    @ObservationIgnored private var persisted: CoddPreferences
    /// Edits made before the load finished (leaf path → value), replayed over the file's values.
    @ObservationIgnored private var earlyEdits: [(path: String, value: String)] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savePending = false
    @ObservationIgnored private let saveDelay: Duration
    @ObservationIgnored private let queue = DispatchQueue(label: CoddIdentity.label("preferences"), qos: .utility)
    @ObservationIgnored private let log: @MainActor (String) -> Void

    /// D14: written this long after the last change.
    static let defaultSaveDelay: Duration = .milliseconds(300)

    /// - Parameters:
    ///   - url: `<dataRoot>/preferences.json`; nil keeps everything in memory (loaded at once).
    ///   - legacyDefaults: where the M1 / M2 notifications switch lives (nil: no migration).
    ///   - assignments: DEBUG `-codd-set-pref` values (`path=value`), applied after the load.
    init(url: URL?, legacyDefaults: UserDefaults? = .standard, assignments: [String] = [],
         saveDelay: Duration = PreferencesService.defaultSaveDelay, log: @escaping @MainActor (String) -> Void = { _ in }) {
        store = url.map(PreferencesStore.init(url:))
        self.legacyDefaults = legacyDefaults
        self.assignments = assignments
        self.saveDelay = saveDelay
        self.log = log
        preferences = .defaults
        persisted = .defaults
        isLoaded = false
        if store == nil { finishLoad(.defaults, migrated: false) }
    }

    /// Mock mode and tests: the defaults (plus `assignments`), never written.
    static func inMemory(assignments: [String] = []) -> PreferencesService {
        PreferencesService(url: nil, legacyDefaults: nil, assignments: assignments)
    }

    var isReadOnly: Bool { store?.isReadOnly ?? false }

    /// Reads the file once (later calls wait for the same read).
    func load() async {
        guard !isLoaded else { return }
        if let loadTask { return await loadTask.value }
        let task = Task { [weak self] () -> Void in await self?.performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        guard let store else { return }
        let queue = self.queue
        let (loaded, origin) = await withCheckedContinuation { (done: CheckedContinuation<(CoddPreferences, PreferencesStore.Origin), Never>) in
            queue.async { done.resume(returning: store.load()) }
        }
        self.origin = origin
        log("preferences load origin=\(origin)")
        var value = loaded
        var migrated = false
        if origin == .created, let legacyDefaults,
           PreferencesStore.migrateLegacyNotifications(from: legacyDefaults, into: &value) {
            migrated = true
            log("preferences migrated \(PreferencesStore.legacyNotificationsKey)=NO (waiting / error notify off)")
        }
        finishLoad(value, migrated: migrated)
    }

    /// The file's values (after migration), then early edits (saved), then DEBUG assignments (not).
    private func finishLoad(_ value: CoddPreferences, migrated: Bool) {
        var stored = value
        for edit in earlyEdits { try? stored.set(edit.value, atPath: edit.path) }
        let changedEarly = !earlyEdits.isEmpty && stored != value
        earlyEdits.removeAll()
        persisted = stored
        var effective = stored
        assignmentResults = assignments.map { assignment in
            do {
                try effective.apply(assignment: assignment)
                if let path = Self.path(of: assignment) { overridden.insert(path) }
                return (assignment, nil)
            } catch {
                return (assignment, String(describing: error))
            }
        }
        for result in assignmentResults {
            log("preferences set-pref \(result.assignment) " + (result.error.map { "refused \($0)" } ?? "applied"))
        }
        preferences = effective
        isLoaded = true
        if migrated || changedEarly { scheduleSave() }
    }

    /// Applies an edit to the values in effect; saved after `saveDelay` (nothing when unchanged).
    func update(_ edit: (inout CoddPreferences) -> Void) {
        var next = preferences
        edit(&next)
        guard next != preferences else { return }
        let previous = preferences
        preferences = next
        guard isLoaded else {
            // Kept as leaf values and replayed over the file's values once it is read.
            for path in CoddPreferences.leafPaths {
                guard let value = next.value(atPath: path), value != previous.value(atPath: path) else { continue }
                earlyEdits.removeAll { $0.path == path }
                earlyEdits.append((path, value))
            }
            return
        }
        persisted = Self.persistable(next, previous: previous, stored: persisted, overridden: &overridden)
        scheduleSave()
    }

    /// The value a save writes: `next`, except the leaves a DEBUG assignment set that this edit
    /// left alone (they keep their stored value). A leaf the edit changed leaves `overridden`.
    static func persistable(_ next: CoddPreferences, previous: CoddPreferences, stored: CoddPreferences,
                            overridden: inout Set<String>) -> CoddPreferences {
        var out = next
        for path in overridden.sorted() {
            if next.value(atPath: path) != previous.value(atPath: path) {
                overridden.remove(path)
            } else if let value = stored.value(atPath: path) {
                try? out.set(value, atPath: path)
            }
        }
        return out
    }

    /// `sessions.staleAfterSeconds=1800` → `sessions.staleAfterSeconds`.
    static func path(of assignment: String) -> String? {
        guard let eq = assignment.firstIndex(of: "=") else { return nil }
        return assignment[..<eq].trimmingCharacters(in: .whitespaces)
    }

    // MARK: Saving

    private func scheduleSave() {
        guard store != nil else { return }
        savePending = true
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save(waiting: false)
        }
    }

    /// Writes a pending edit now and waits for it (quit; tests).
    func flush() {
        save(waiting: true)
    }

    private func save(waiting: Bool) {
        guard let store, savePending else { return }
        savePending = false
        saveTask?.cancel()
        saveTask = nil
        let value = persisted
        if waiting {
            saved(queue.sync { Self.write(value, to: store) })
        } else {
            queue.async { [weak self] in
                let result = Self.write(value, to: store)
                Task { @MainActor [weak self] in self?.saved(result) }
            }
        }
    }

    nonisolated private static func write(_ value: CoddPreferences, to store: PreferencesStore) -> Result<Date, PreferencesStoreError> {
        // The data root exists in the app (its lock file is there); a missing folder is made like it.
        try? FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        do {
            try store.save(value)
            return .success(Date())
        } catch {
            return .failure(error)
        }
    }

    private func saved(_ result: Result<Date, PreferencesStoreError>) {
        switch result {
        case .success(let at):
            savedAt = at
            if saveProblem != nil { saveProblem = nil }
        case .failure(let error):
            let problem = Self.problemText(error)
            if saveProblem != problem { saveProblem = problem }
            log("preferences not saved: \(error)")
        }
    }

    /// Settings' footer line (`▲ …`) for a refused save.
    static func problemText(_ error: PreferencesStoreError) -> String {
        switch error {
        case .newerVersion(let v): "preferences.json 是較新版本的 CODD 寫的（v\(v)），變更不會儲存"
        case .unreadable(let reason): "preferences.json 讀不到，變更不會儲存（\(reason)）"
        case .io(let reason): "無法儲存 preferences.json（\(reason)）"
        }
    }

    // MARK: Consumers

    /// D15 of M2 / M3: IDLE sessions turn stale after this long; `nil` (永不) never. DEBUG
    /// `-codd-stale-after` wins for the run.
    static func staleAfter(_ preferences: CoddPreferences, override: Double?) -> TimeInterval {
        if let override { return override }
        return preferences.sessions.staleAfterSeconds.map(TimeInterval.init) ?? .infinity
    }

    /// `-codd-dump-state` key `preferences`: how the file was found and every leaf value.
    var dumpObject: [String: Any] {
        var object: [String: Any] = [
            "origin": origin?.description ?? (store == nil ? "memory" : "loading"),
            "loaded": isLoaded,
            "readOnly": isReadOnly,
            "values": Dictionary(uniqueKeysWithValues: CoddPreferences.leafPaths.map { ($0, preferences.value(atPath: $0) ?? "") }),
            "setPrefs": assignmentResults.map { result -> [String: Any] in
                ["assignment": result.assignment, "applied": result.error == nil, "error": result.error.map { $0 as Any } ?? NSNull()]
            },
        ]
        object["saveProblem"] = saveProblem.map { $0 as Any } ?? NSNull()
        object["savedAt"] = savedAt.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull()
        return object
    }
}
