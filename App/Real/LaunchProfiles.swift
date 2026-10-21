import CoddCore
import Foundation
import Observation

/// The launch profiles of this data root (D5, `<dataRoot>/profiles.json`), for ⌘N, Home and
/// Settings › 啟動設定檔. Wraps CoddCore's `LaunchProfileStore`: every read and write happens off
/// the main actor, writes in call order on one queue.
///
/// - First read: a missing file is written with the four built-ins (seeded on first read); an
///   unreadable one is moved aside (`profiles.json.corrupt-<ms>`) and seeded; one from a newer
///   CODD is shown as the built-ins and never written (edits are refused with a problem).
/// - Every change goes to `onChange` (the store pushes it into `HolderLauncher.profiles`).
/// - Mock mode uses `inMemory()`: the same rules, nothing on disk.
@MainActor @Observable
final class LaunchProfiles {
    private(set) var document = LaunchProfileDocument.seeded
    /// The first read finished (until then `document` is the built-ins).
    private(set) var isLoaded = false
    /// profiles.json was written by a newer CODD, or could not be read: shown, never replaced.
    private(set) var isReadOnly = false
    /// Edits are possible: the file is in (an edit before that would save the built-ins over the
    /// user's profiles, review correctness-4) and may be written.
    var canEdit: Bool { isLoaded && !isReadOnly }
    /// Why edits are refused now (繁體中文), nil while `canEdit`.
    var editRefusal: String? {
        if !isLoaded { return Self.notLoadedMessage }
        return isReadOnly ? readOnlyReason : nil
    }
    /// Why edits are refused while `isReadOnly` (繁體中文).
    @ObservationIgnored private var readOnlyReason = LaunchProfiles.readOnlyMessage
    /// nil: in memory only (mock mode).
    @ObservationIgnored let fileURL: URL?
    /// A change was made (or loaded): the launcher gets the new profiles.
    @ObservationIgnored var onChange: ((LaunchProfileDocument) -> Void)?
    /// An edit was refused or a save failed (繁體中文, for the problem banner).
    @ObservationIgnored var onProblem: ((String, String) -> Void)?
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Saves run in call order, off the main actor.
    @ObservationIgnored private let queue = DispatchQueue(label: CoddIdentity.label("profiles"), qos: .utility)

    nonisolated static let readOnlyMessage = "profiles.json 是較新版的 CODD 寫的：這個版本只能讀，不能修改啟動設定檔。"
    nonisolated static let unreadableMessage = "無法讀取 profiles.json：為了不覆蓋它，這次不能修改啟動設定檔。"
    nonisolated static let notLoadedMessage = "啟動設定檔還在讀取，請稍候再試一次。"

    init(fileURL: URL?, log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.fileURL = fileURL
        self.log = log
    }

    /// `<dataRoot>/profiles.json`.
    convenience init(root: CoddDataRoot, log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.init(fileURL: root.url.appendingPathComponent(LaunchProfileStore.fileName, isDirectory: false), log: log)
    }

    static func inMemory() -> LaunchProfiles {
        let profiles = LaunchProfiles(fileURL: nil) { _ in }
        profiles.isLoaded = true
        return profiles
    }

    var profiles: [LaunchProfile] { document.profiles }
    var claudeProfiles: [LaunchProfile] { document.profiles.filter { $0.kind == .claude } }
    var shellProfiles: [LaunchProfile] { document.profiles.filter { $0.kind == .shell } }
    /// The profile ⌘N and Home preselect (may be a shell profile).
    var defaultProfile: LaunchProfile? { document.defaultProfile }

    // MARK: Loading

    /// Reads profiles.json once (off the main actor); later calls wait for the same read.
    func load() async {
        if let loading { return await loading.value }
        guard let fileURL, !isLoaded else { return }
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.read(fileURL) }.value
            self?.finishLoad(result)
        }
        loading = task
        await task.value
    }

    enum LoadResult: Sendable {
        case loaded(LaunchProfileDocument)
        /// No file yet: written now with the built-ins.
        case seeded(LaunchProfileDocument, written: Bool, error: String?)
        /// Unreadable: moved aside (to `aside`), then seeded.
        case corrupt(reason: String, aside: String?, written: Bool)
        case newer(Int)
        case failed(String)
    }

    /// Blocking file I/O.
    nonisolated static func read(_ url: URL) -> LoadResult {
        let store = LaunchProfileStore(fileURL: url)
        let exists = FileManager.default.fileExists(atPath: url.path)
        do throws(LaunchProfileStoreError) {
            let document = try store.load()
            guard !exists else { return .loaded(document) }
            do throws(LaunchProfileStoreError) {
                try store.save(document)
                return .seeded(document, written: true, error: nil)
            } catch {
                return .seeded(document, written: false, error: String(describing: error))
            }
        } catch .unsupportedVersion(let version) {
            return .newer(version)
        } catch .corrupt(let reason) {
            let aside = try? store.moveAside().path
            let written = (try? store.save(.seeded)) != nil
            return .corrupt(reason: reason, aside: aside, written: written)
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func finishLoad(_ result: LoadResult) {
        isLoaded = true
        switch result {
        case .loaded(let document):
            self.document = document
            log("profiles loaded count=\(document.profiles.count) default=\(document.defaultProfileId)")
        case .seeded(let document, let written, let error):
            self.document = document
            log(written ? "profiles seeded count=\(document.profiles.count)" : "error profiles not seeded: \(error ?? "-")")
        case .corrupt(let reason, let aside, let written):
            document = .seeded
            log("error profiles.json unreadable (\(reason)), moved to \(aside ?? "-"), seeded=\(written)")
        case .newer(let version):
            document = .seeded
            isReadOnly = true
            log("error profiles.json is version \(version) (newer CODD): read-only")
        case .failed(let reason):
            // EACCES, EIO, …: the file may hold the user's profiles; never save the built-ins over it.
            document = .seeded
            isReadOnly = true
            readOnlyReason = Self.unreadableMessage
            log("error profiles.json not read: \(reason): read-only")
            onProblem?(Self.unreadableMessage, "profiles.json not read: \(reason)")
        }
        reportUnlaunchable()
        onChange?(document)
    }

    /// A hand-edited profile LaunchBuilder would refuse (`--settings`, a model with a space) is
    /// skipped at launch (`LaunchProfileDocument.claudeProfile(id:)`); say so once it is read.
    private func reportUnlaunchable() {
        let broken = document.unlaunchableProfiles
        guard !broken.isEmpty else { return }
        let names = broken.map { "「\($0.name)」" }.joined(separator: "、")
        let fallback = document.claudeProfile(id: nil).name
        let detail = broken.map { "\($0.id): \(LaunchProfileEditing.launchIssues($0))" }.joined(separator: "; ")
        log("error profiles not launchable: \(detail); claude sessions use \(fallback)")
        onProblem?("啟動設定檔\(names)有 CODD 不能使用的設定，新的 claude session 改用「\(fallback)」。請到 設定 › 啟動設定檔 修正。",
                   "profiles not launchable: \(detail)")
    }

    // MARK: Editing (Settings › 啟動設定檔, I6)

    /// Adds or replaces a profile (matched by id). Returns the problems that kept it from being
    /// saved (empty when saved). A read-only file (`isReadOnly`) refuses every edit through
    /// `onProblem` instead.
    @discardableResult
    func upsert(_ profile: LaunchProfile) -> [LaunchProfileIssue] {
        guard allowEdit("upsert \(profile.id)") else { return [] }
        let issues = LaunchProfileEditing.validate(profile, in: document)
        guard issues.isEmpty else { return issues }
        var next = document
        if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) {
            next.profiles[index] = profile
        } else {
            next.profiles.append(profile)
        }
        commit(next)
        return []
    }

    /// Deletes a profile; the last claude profile stays (`.lastClaudeProfile`). Deleting the default
    /// falls back to the first claude profile.
    @discardableResult
    func delete(_ id: String) -> LaunchProfileIssue? {
        guard allowEdit("delete \(id)") else { return nil }
        var next = document
        if let issue = LaunchProfileEditing.remove(id, from: &next) { return issue }
        if next != document { commit(next) }
        return nil
    }

    /// `複製` (Settings › 啟動設定檔): a copy of profile `id` with a fresh id and the name
    /// `<name> 複本` (`claude-default-2`, `claude-default 複本`; `… 複本 2` when taken). Returns the
    /// new id.
    @discardableResult
    func duplicate(_ id: String) -> String? {
        guard allowEdit("duplicate \(id)"), var copy = document.profile(id: id) else { return nil }
        copy.id = LaunchProfileEditing.uniqueId(id, in: document)
        copy.name = Self.uniqueName(JSText.trim(copy.name) + " 複本", in: document)
        var next = document
        next.profiles.append(copy)
        commit(next)
        return copy.id
    }

    func setDefault(_ id: String) {
        guard allowEdit("default \(id)"), document.profile(id: id) != nil, document.defaultProfileId != id else { return }
        var next = document
        next.defaultProfileId = id
        commit(next)
    }

    /// `name`, else `name 2`, `name 3`, … (names are unique ignoring case).
    nonisolated static func uniqueName(_ name: String, in document: LaunchProfileDocument) -> String {
        let taken = Set(document.profiles.map { JSText.trim($0.name).lowercased() })
        let stem = JSText.trim(name).isEmpty ? "profile" : JSText.trim(name)
        guard taken.contains(stem.lowercased()) else { return stem }
        var n = 2
        while taken.contains("\(stem) \(n)".lowercased()) { n += 1 }
        return "\(stem) \(n)"
    }

    private func allowEdit(_ what: String) -> Bool {
        guard isLoaded else {
            log("profiles edit refused (\(what)): profiles.json not read yet")
            onProblem?(Self.notLoadedMessage, "profiles edit refused (\(what)): not loaded")
            return false
        }
        guard isReadOnly else { return true }
        log("profiles edit refused (\(what)): profiles.json is read-only")
        onProblem?(readOnlyReason, "profiles edit refused (\(what)): read-only profiles.json")
        return false
    }

    private func commit(_ next: LaunchProfileDocument) {
        document = next
        onChange?(next)
        guard let fileURL else { return }
        let log = self.log
        queue.async { [weak self] in
            do throws(LaunchProfileStoreError) {
                try LaunchProfileStore(fileURL: fileURL).save(next)
            } catch {
                Task { @MainActor [weak self] in
                    log("error cannot save profiles.json: \(error)")
                    if case .unsupportedVersion = error {
                        self?.isReadOnly = true
                        self?.readOnlyReason = Self.readOnlyMessage
                    }
                    self?.onProblem?("無法儲存啟動設定檔：\(error)", "profiles.json save failed: \(error)")
                }
            }
        }
    }

    /// Waits for the saves queued so far (tests).
    nonisolated func flush() {
        queue.sync {}
    }
}
