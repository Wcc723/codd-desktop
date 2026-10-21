import CoddComposer
import CoddCore
import Foundation
import Observation

/// Real-mode data and actions the pane's home and status pages need beyond `SessionStore`:
/// folders Claude has used (`.claude.json`), Claude's transcripts and settings (read only), the
/// launch profiles, the hook endpoint, and the new-session entry points. Mock mode has none (the
/// pages show their mock-free placeholders).
@MainActor @Observable
final class AppServices {
    /// `.claude.json` projects, most recently used first (read off the main actor).
    private(set) var recentProjects: [RecentProject] = []
    /// D18 / D30: `cleanupPeriodDays` and `model` of `<claudeDir>/settings.json`, read once off the
    /// main actor (`loadClaudeSettings`), never written. Empty until read.
    private(set) var claudeSettings = ClaudeUserSettingsSummary()
    @ObservationIgnored let store: HolderSessionStore
    /// The real account store (STATUS shows its status-line counters until I2's page).
    @ObservationIgnored weak var accounts: CswapAccountStore?
    /// Opens the ⌘N sheet, prefilled.
    @ObservationIgnored var showNewSession: (NewSessionForm) -> Void = { _ in }
    /// Starts a session right away (home page `[+ CLAUDE]` / `[+ SHELL]`); returns the problem.
    @ObservationIgnored var launch: (NewSessionRequest) -> String? = { _ in nil }
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var settingsLoad: Task<Void, Never>?
    /// `transcripts(for:)` results per standardized folder: when read, in which store generation
    /// (a launch since then may have added one) and how many were asked for (a longer list answers
    /// a shorter request).
    @ObservationIgnored private var transcriptCache: [String: (at: Date, generation: Int, limit: Int, items: [TranscriptSummary])] = [:]

    /// How long a folder's transcript list is reused (the picker reopens often while typing).
    static let transcriptCacheLifetime: TimeInterval = 10
    /// The resume picker's list length (`TranscriptCatalog.list`'s default).
    static let transcriptListLimit = 50

    init(store: HolderSessionStore) {
        self.store = store
    }

    var hooks: HookPipeline? { store.hooks }
    /// D5: the data root's launch profiles (⌘N, Home, Settings › 啟動設定檔).
    var profiles: LaunchProfiles { store.profiles }
    /// D18: conversations a live claude uses (shown disabled `執行中` in the resume picker).
    var inUseClaudeSessionIds: Set<String> { store.inUseClaudeSessionIds }
    /// `<claudeDir>/sessions`, `~` for the home folder (the EXT banner's `偵測自 …`).
    var registryDisplayPath: String { HolderSessionStore.abbreviate(store.claudeDirectory.registryURL.path) }

    /// Re-reads `.claude.json` (at most one read at a time).
    func reloadRecentProjects() {
        guard loading == nil else { return }
        let directory = store.claudeDirectory
        loading = Task { [weak self] in
            let projects = await Task.detached(priority: .utility) { RecentProjectsReader.read(directory) }.value
            guard let self else { return }
            if projects != self.recentProjects { self.recentProjects = projects }
            self.loading = nil
        }
    }

    /// Reads `<claudeDir>/settings.json` once (later calls wait for the same read).
    func loadClaudeSettings() async {
        if let settingsLoad { return await settingsLoad.value }
        let file = URL(fileURLWithPath: store.claudeDirectory.path + "/settings.json", isDirectory: false)
        let task = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) { ClaudeUserSettings.read(settingsFile: file) }.value
            self?.claudeSettings = summary
        }
        settingsLoad = task
        await task.value
    }

    /// D18: the conversations of `cwd` (newest first, `sdk-*` hidden, at most `limit`), read off the
    /// main actor and reused for 10 s unless a session was started or resumed since. Home asks for
    /// 3 per project (only the newest files are read).
    func transcripts(for cwd: String, limit: Int = AppServices.transcriptListLimit) async -> [TranscriptSummary] {
        let key = HolderSessionStore.standardize(cwd)
        let generation = store.transcriptsGeneration
        if let cached = transcriptCache[key], cached.generation == generation, cached.limit >= limit,
           Date().timeIntervalSince(cached.at) < Self.transcriptCacheLifetime {
            return Array(cached.items.prefix(limit))
        }
        let catalog = store.transcripts
        let items = await Task.detached(priority: .userInitiated) { catalog.list(cwd: key, limit: limit) }.value
        transcriptCache[key] = (Date(), generation, limit, items)
        if transcriptCache.count > 64 {
            let oldest = transcriptCache.min { $0.value.at < $1.value.at }?.key
            if let oldest { transcriptCache[oldest] = nil }
        }
        return items
    }

    /// Whether `transcripts(for:)` would answer from its cache now (DEBUG timings).
    func isTranscriptListCached(_ cwd: String, limit: Int = AppServices.transcriptListLimit) -> Bool {
        guard let cached = transcriptCache[HolderSessionStore.standardize(cwd)] else { return false }
        return cached.generation == store.transcriptsGeneration && cached.limit >= limit
            && Date().timeIntervalSince(cached.at) < Self.transcriptCacheLifetime
    }

    /// Claude conversation ids CODD itself has (every CODD session's current and first id, archived
    /// ones too): Home's RECENTLY STOPPED lists only transcripts outside these.
    var coddClaudeSessionIds: Set<String> {
        var ids = Set<String>()
        for session in store.sessionsByID.values {
            ids.insert(session.id)
            if let claude = session.claudeSessionID { ids.insert(claude) }
        }
        for session in store.archivedByID.values {
            ids.insert(session.id)
            if let claude = session.claudeSessionID { ids.insert(claude) }
        }
        for record in store.records.values { if let claude = record.claudeSessionId { ids.insert(claude) } }
        return ids
    }

    /// D20: the session's last prompt: the latest `UserPromptSubmit` hook, else the transcript's
    /// `last-prompt` record (read off the main actor). Externals read their transcript.
    func lastPrompt(for id: SessionID) async -> String? {
        guard let session = store.session(id), session.kind == .claude else { return nil }
        if let prompt = session.lastPrompt { return prompt }
        let claudeID = session.externalInfo?.claudeSessionID ?? session.claudeSessionID
        guard let claudeID, let cwd = store.project(session.projectID)?.cwd else { return nil }
        // D12: a pinned session's transcripts are its account's (`<profile>/projects`).
        let catalog = session.external ? store.transcripts : store.transcriptCatalog(for: id)
        return await Task.detached(priority: .utility) { catalog.lastPrompt(cwd: cwd, sessionId: claudeID) }.value
    }

    /// D26: the prompt a resend sends, whole: the latest hook's, else the newest prompt of the
    /// transcript, read uncut off the main actor. nil when neither is known whole (the banner then
    /// disables both actions): a display form is never resent.
    func resendPrompt(for id: SessionID) async -> String? {
        guard let session = store.session(id), session.kind == .claude, !session.external else { return nil }
        if let prompt = session.resendPrompt { return prompt }
        guard let claudeID = session.claudeSessionID, let cwd = store.project(session.projectID)?.cwd else { return nil }
        let catalog = store.transcriptCatalog(for: id)
        let found = await Task.detached(priority: .utility) { catalog.resendablePrompt(cwd: cwd, sessionId: claudeID) }.value
        guard let found, (try? ComposerEncoding.payload(for: found)) != nil else { return nil }
        return found
    }

    /// The store's saved projects as sheet choices, with the latest session activity as "last
    /// used" (transient projects are not choices: they are not CODD's).
    func knownProjectChoices() -> [ProjectChoice] {
        var out: [ProjectChoice] = []
        for group in store.groups {
            for id in group.projectIDs {
                guard let project = store.project(id), !project.isTransient else { continue }
                let lastUsed = project.sessionIDs.compactMap { store.sessionsByID[$0]?.stateSince }.max()
                out.append(ProjectChoice(path: project.cwd, name: project.name, tag: group.color, isKnown: true, lastUsed: lastUsed))
            }
        }
        return out
    }
}
