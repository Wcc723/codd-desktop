import CoddCore
import CoddHolderClient
import CoddHooks
import CoddProtocol
import Foundation
import Observation
import CoddUI

/// CoddHolderClient's discovery record (`sessions/*/meta.json`); the bare name clashes with
/// CoddCore's layout row in files that import both.
typealias DiscoveredHolder = CoddHolderClient.SessionRecord

/// What the new-session sheet (or a quick launch) asks for.
struct NewSessionRequest: Sendable, Equatable {
    var cwd: String
    var kind: SessionKind
    /// The user's name for the session (`-n` for claude); blank = learned from Claude.
    var name: String?
    var tag: TagColor?
    var claude = ClaudeLaunchOptions()
    /// Group for the project when the folder is new (nil = ungrouped).
    var groupID: GroupID?
    /// The id the ⌘N preview showed (`--session-id 7c1e9a04-…`): used as the CODD session id (and,
    /// for a new conversation, the Claude session id) when no session or directory has it yet.
    var sessionID: UUID?
    /// With `claude.mode == .resume`: the transcript's title the picker showed (the session's
    /// title when no name is given; else it is read from the transcript).
    var resumeTitle: String?
}

/// The real `SessionStore` (the default since M1): sessions are `codd-holder` processes running
/// `claude` or a shell, persisted in `<dataRoot>/layout.json` (groups → projects → sessions).
///
/// - Launch: claude sessions get CoddCore's `LaunchBuilder` argv with the per-session hooks
///   `--settings`, the login environment minus the deny-list, `CODD_SESSION_ID` and
///   `CODD_HOOK_TOKEN`; the terminal is created and pinned before the holder starts (startup
///   probes). Shells run `$SHELL -l` in the project folder.
/// - States: claude sessions take theirs from the `SessionStateEngine` (hooks, registry, title,
///   holder EXIT) through `HookPipeline`; shells from the holder (`SHELL` / `EXITED`).
/// - Relaunch: holders are discovered from `sessions/*/meta.json` and reattached; a claude session
///   whose holder is gone is `STOPPED · 可接續` (RESUME = `claude --resume <current Claude session
///   id>`), a shell one is `EXITED` with RESTART. Holders the layout does not know are adopted.
///
/// Each live holder has one `PtyConnection` (HELLO with takeover); `TerminalHub` attaches an
/// engine to it while the session's own tab is visible or hot.
@MainActor @Observable
final class HolderSessionStore: SessionStore {
    /// Mutated by the layout intents (`HolderSessionStore+Layout.swift`).
    var groups: [GroupVM]
    var pinnedSessionIDs: [SessionID] = []
    let clock = DisplayClock()
    /// The latest problem the pane shows as a banner until dismissed (discovery failed, taken over
    /// by another CODD, a shell tab that cannot start); every `report` is also logged as
    /// `REALHOLDERS error …`.
    private(set) var problem: StoreProblem?
    /// Why the last `createSession` returned nil (繁體中文). The ⌘N sheet and the home page show
    /// it themselves, so it never becomes the banner's `problem`.
    @ObservationIgnored var lastRefusal: String?
    /// M5 D14: data-file banners waiting for the one shown to be dismissed (in order).
    @ObservationIgnored private(set) var problemQueue: [StoreProblem] = []
    /// The queued banners shown so far, by message (the dump's `dataFiles.bannersShown` counts
    /// them; one that came back after another report counts once).
    @ObservationIgnored private(set) var queuedProblemsShown: Set<String> = []
    /// layout.json and the holders were read (until then the sidebar is empty and launches wait).
    private(set) var isLoaded = false

    var sessionsByID: [SessionID: SessionVM] = [:]
    /// D6: claude processes CODD did not start (Claude's registry), read-only. Kept apart from
    /// `sessionsByID`: everything that persists, registers with the hook engine, spawns, archives,
    /// answers or moves iterates `sessionsByID` only; `session(_:)` and `allSessions` see both.
    var externalByID: [SessionID: SessionVM] = [:]
    @ObservationIgnored var projectsByID: [ProjectID: ProjectVM] = [:]
    /// Archived (hidden) sessions keep receiving holder events so UNDO restores current facts.
    @ObservationIgnored var archivedByID: [SessionID: SessionVM] = [:]
    /// Persisted per-session facts the view models do not carry (layout.json rows).
    @ObservationIgnored var records: [SessionID: LayoutSessionRecord] = [:]
    @ObservationIgnored var projectRecords: [ProjectID: Project] = [:]
    /// The tool the latest hook named, per session (answer bar).
    @ObservationIgnored var toolDetails: [SessionID: HookToolDetail] = [:]
    /// What `PendingAnswerFile` holds per session (a waiting session's detail), so it is
    /// rewritten only when that changes.
    @ObservationIgnored var persistedDetails: [SessionID: HookToolDetail] = [:]
    @ObservationIgnored var runtimes: [SessionID: HolderRuntime] = [:]
    @ObservationIgnored let root: CoddDataRoot
    @ObservationIgnored let claudeDirectory: ClaudeDirectory
    /// Nil in tests that run without hooks: claude sessions then show `NO HOOK` while running.
    @ObservationIgnored let hooks: HookPipeline?
    /// Nil until `start()` installed the holder binary, and when the bundle has none (spawning is
    /// then refused).
    @ObservationIgnored private(set) var launcher: HolderLauncher?
    @ObservationIgnored private let shellArgvOverride: [String]?
    @ObservationIgnored private let claudePathOverride: String?
    /// Keepalive, backoff and UNREACHABLE timings of every holder connection (shell tabs too).
    @ObservationIgnored var connectionTuning = PtyConnectionTuning()
    @ObservationIgnored private var started = false
    @ObservationIgnored let log: @MainActor (String) -> Void
    @ObservationIgnored let layoutSaver: LayoutSaver
    /// A session's connection was created (spawn, restart, discovery): the hub attaches the
    /// session tab's engine to it.
    @ObservationIgnored var onConnection: ((SessionID, PtyConnection) -> Void)?
    /// Called before a holder is spawned, so the session's terminal exists (pinned) when the
    /// child's startup probes arrive (M1 decision "Startup probes").
    @ObservationIgnored var prepareTerminal: ((SessionID) -> Void)?
    /// Size of the pane's terminal, for the holder's initial `--cols` / `--rows`.
    @ObservationIgnored var terminalGrid: (() -> TerminalGridSize?)?
    /// A session and its directory were deleted (its shell tabs end with it).
    @ObservationIgnored var onSessionDeleted: ((SessionID, String) -> Void)?
    /// A session's own PTY rang its bell (D12: the hub marks its tab unless it is on screen).
    @ObservationIgnored var onBell: ((SessionID) -> Void)?
    /// Any session's state was applied (debug state dump).
    @ObservationIgnored var onStatesChanged: (() -> Void)?
    /// Once, in `start`, right after the loaded layout and the discovered holders are installed
    /// (the sidebar can show them), before the claude registrations and the hook endpoint (M5 D16:
    /// the launch-to-sidebar line).
    @ObservationIgnored var onLoaded: (() -> Void)?
    /// A session changed state (notifications); the session already holds the new state.
    @ObservationIgnored var onTransition: ((SessionVM, SessionState) -> Void)?
    /// Whether the user is looking at the session right now (shown in the visible window of the
    /// active app). Such a session never turns DONE: it finished in front of the user.
    @ObservationIgnored var isViewing: ((SessionID) -> Bool)?

    // MARK: Settings (M3 I3)

    /// Sessions the user stopped this run (⌘., 全部停止並結束): their EXIT is not a notification
    /// (D29). Cleared when the session starts again.
    @ObservationIgnored var stopRequested: Set<SessionID> = []
    /// M5 D20: stops asked for while the session's holder was still being spawned (no pid yet);
    /// `launched(.success)` applies them through `stop` once it is connected. A failed spawn,
    /// RESUME, RESTART, removal and archive clear them.
    @ObservationIgnored var pendingStops: Set<SessionID> = []
    /// Sessions whose holder spawn is in flight (from `launch` until `launched`).
    @ObservationIgnored var launchesInFlight: Set<SessionID> = []
    /// Settings › 工作階段 › 外部 session `隱藏`: no external enters the store (sidebar, NEEDS YOU,
    /// counts, badges); the registry is still read (in-use checks, the Settings count).
    @ObservationIgnored var hidesExternals = false
    /// Settings › 工作階段 › 隱藏 SDK / Desktop session (D6).
    @ObservationIgnored var externalFilter = ExternalSessionFilter()

    // MARK: Sessions data (M2, I2)

    /// D5: `<dataRoot>/profiles.json`, read during `start()` (before `isLoaded`).
    @ObservationIgnored let profiles: LaunchProfiles
    /// Claude's transcripts (`<claudeDir>/projects`), read only: resume titles, last prompts, D23.
    @ObservationIgnored let transcripts: TranscriptCatalog
    /// Bumped whenever a launch may have added or changed a transcript (create, resume): caches of
    /// `transcripts.list` older than this are stale.
    @ObservationIgnored var transcriptsGeneration = 0
    /// D23: moves one file or folder to the Trash. Tests and DEBUG `-codd-trash-dir` move into a
    /// folder of their own instead; nothing in automated runs touches `~/.Trash`.
    @ObservationIgnored var trash: @Sendable (URL) throws -> Void = HolderSessionStore.moveToSystemTrash
    /// The latest registry entries (live only), applied once the store is loaded.
    @ObservationIgnored var registryEntries: [ClaudeRegistryEntry] = []
    /// The first registry snapshot arrived: until then `registryEntries` knows nothing about the
    /// claudes running outside CODD, so in-use checks wait for it (review e2e-3).
    @ObservationIgnored var registrySeen = false
    @ObservationIgnored var registryWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// What the detector reported last, per external id (diffing).
    @ObservationIgnored var externalRecords: [SessionID: ExternalSession] = [:]
    /// The hub's shell-tab holders (their claude children are EXT `在 CODD shell 中`).
    @ObservationIgnored var shellTabHolders: (() -> [ShellTabHolder])?
    /// Parent chain of a pid (tests inject one; default: sysctl).
    @ObservationIgnored var processAncestors: (Int) -> [Int] = ProcessAncestry.chain
    /// `realpath` of project folders and registry cwds (D6 compares both sides resolved), failures
    /// included: a folder that does not resolve (deleted, an unmounted volume) is tried again only
    /// after `realpathRetry`, not on every lookup (review concurrency-perf-5).
    @ObservationIgnored var realpathCache: [String: ResolvedPath] = [:]
    /// Project folders being resolved off the main actor (`prewarmProjectPaths`).
    @ObservationIgnored var realpathPrewarm: Task<Void, Never>?
    @ObservationIgnored var externalRefreshScheduled = false
    /// D15: IDLE for longer than this is stale (DEBUG `-codd-stale-after`).
    @ObservationIgnored var staleAfter: TimeInterval = HolderSessionStore.defaultStaleAfter
    /// How often the stale flags are recomputed (also on every transition).
    @ObservationIgnored var staleInterval: Duration = .seconds(60)
    @ObservationIgnored var staleTask: Task<Void, Never>?

    static let defaultStaleAfter: TimeInterval = 3600

    // MARK: Accounts (M3 I1b, D8 / D12)

    /// The Claude user settings the status-line chain is read from (D35: after the session cwd's
    /// own files): `<claudeDir>/settings.json`, DEBUG `-codd-claude-settings`. Read only.
    @ObservationIgnored var claudeSettingsURL: URL
    /// The account following sessions run on (the active one, from the account store): their
    /// `accountID`. Pinned sessions keep their own number (D12).
    @ObservationIgnored var followingAccountID: AccountID?
    /// D12: whether account n can be pinned now (the account store; `relaunch` allows the active
    /// account for an existing pinned session); nil: no accounts.
    @ObservationIgnored var accountPinning: (@MainActor (Int, Bool) -> AccountPinResolution)?
    /// D12: account n's profile path, stale or not (its pinned sessions' transcripts live there).
    @ObservationIgnored var accountProfilePath: (@MainActor (Int) -> String?)?
    /// D12: the account a launch profile's own `CLAUDE_CONFIG_DIR` belongs to.
    @ObservationIgnored var accountForConfigDir: (@MainActor (String) -> Int?)?
    /// Transcript catalogs of other Claude config directories (pinned sessions), by directory.
    @ObservationIgnored var configDirCatalogs: [String: TranscriptCatalog] = [:]

    // MARK: M3 I2

    /// D24: sessions that exist for one task only (dialog C's login shell): never in layout.json.
    @ObservationIgnored var ephemeral: [SessionID: EphemeralShell] = [:]
    /// D36: `cpu 23% · mem 21/36G · bat 86%` from `HostLineService`; nil until the first sample.
    var hostLine: String?

    // MARK: M4 I2a (MCP)

    /// CODD's MCP server (the status bar, the rail and the Notebook footer read it through `host`).
    @ObservationIgnored weak var mcp: MCPService?
    /// D18 Settings › 自動掛載 MCP: claude launches get the per-session `--mcp-config` and the
    /// `/hooks/prompt` route. Off until the app applies the preferences (tests stay on M3's argv).
    @ObservationIgnored var autoAttachMCP = false
    /// What each claude launch did about MCP (the dump's `mcp.sessionConfigs`; never a token).
    @ObservationIgnored var mcpSessionConfigs: [SessionID: MCPSessionConfig] = [:]
    /// D18's server-name scans, cached 10 s by the files' size and mtime.
    @ObservationIgnored let mcpNames = MCPNameCache()

    // MARK: M4 I4a (retention, cleanup)

    /// D31: the Cleanup page's candidates (the menu bar footer, the Notebook footer and Settings ›
    /// 清理 show `清理建議 n →`), set by `RetentionService` after every run and action.
    var cleanupSuggestions = 0
    /// D30: stopped / exited sessions the last retention run found stopped for the stale days:
    /// dimmed like an IDLE session past its limit (`SessionVM.isStale`) while they stay stopped.
    @ObservationIgnored var retentionStaleIDs: Set<SessionID> = []
    /// D32: the pid of a running condense `claude -p`: CODD's own, never an EXT session.
    @ObservationIgnored var transientClaudePids: Set<Int> = []

    /// D32: registry entries of CODD's condense runs (their cwd is a run folder) are never externals.
    func isCondenseRun(_ entry: ClaudeRegistryEntry) -> Bool {
        if let pid = entry.pid, transientClaudePids.contains(pid) { return true }
        guard let cwd = entry.cwd else { return false }
        return cwd.hasPrefix(root.runPath + "/" + Self.condenseRunPrefix)
            || Self.standardize(cwd).hasPrefix(Self.standardize(root.runPath) + "/" + Self.condenseRunPrefix)
    }

    /// `<dataRoot>/run/condense-<uuid>/`.
    nonisolated static let condenseRunPrefix = "condense-"

    static var ungroupedID: GroupID { LayoutMapping.ungroupedID }

    /// - Parameters:
    ///   - launcher: nil installs the bundled holder in `start()` (tests pass their own).
    ///   - hooks: the hook pipeline (nil: no hook endpoint, claude states from the holder only).
    init(root: CoddDataRoot, launcher: HolderLauncher?, shellArgvOverride: [String]? = nil, claudePathOverride: String? = nil,
         claudeDirectory: ClaudeDirectory = .standard, hooks: HookPipeline? = nil,
         log: @escaping @MainActor (String) -> Void = HolderSessionStore.printLog) {
        self.root = root
        self.launcher = launcher
        self.shellArgvOverride = shellArgvOverride
        self.claudePathOverride = claudePathOverride
        self.claudeDirectory = claudeDirectory
        self.hooks = hooks
        self.log = log
        layoutSaver = LayoutSaver(fileURL: root.layoutURL, log: log)
        groups = [LayoutMapping.ungroupedGroup()]
        profiles = LaunchProfiles(root: root, log: log)
        transcripts = TranscriptCatalog(projectsDirectory: URL(fileURLWithPath: claudeDirectory.transcriptsPath, isDirectory: true))
        claudeSettingsURL = URL(fileURLWithPath: claudeDirectory.path + "/settings.json", isDirectory: false)
    }

    /// The store for `options`: data root, Claude directory, the hook pipeline, overrides. The
    /// holder binary is installed under the data root by `start()`.
    /// Touches nothing on disk: the single-instance lock is taken before `start()` (D9).
    static func make(options: RealModeOptions) -> HolderSessionStore {
        let root = options.dataRoot.map(CoddDataRoot.init(path:)) ?? .standard
        let claude = options.claudeDir.map(ClaudeDirectory.init(path:)) ?? .standard
        let hooks = HookPipeline(dataRoot: root.url, claudeDirectory: claude, portRange: HookPipeline.portRange(for: root))
        let store = HolderSessionStore(root: root, launcher: nil, shellArgvOverride: options.shellArgv,
                                       claudePathOverride: options.claudePath, claudeDirectory: claude, hooks: hooks)
        store.connectionTuning = options.connectionTuning
        if let settings = options.claudeSettings { store.claudeSettingsURL = URL(fileURLWithPath: settings, isDirectory: false) }
        return store
    }

    /// `REALHOLDERS …` lines on stdout (smoke runs grep them). Plain write(2): unlike
    /// `FileHandle.write`, a closed stdout is an ignored error, not an exception.
    /// Per-title and per-cwd log lines (DEBUG, `-codd-verbose-log YES`): a program that changes
    /// its title in a loop would otherwise write a log line per change.
    @ObservationIgnored var verboseLog = UserDefaults.standard.bool(forKey: "codd-verbose-log")

    nonisolated static func printLog(_ line: String) {
        let bytes = Array("REALHOLDERS \(line)\n".utf8)
        _ = bytes.withUnsafeBytes { write(STDOUT_FILENO, $0.baseAddress, $0.count) }
    }

    /// CODD sessions and externals (counts, NEEDS YOU, badges, the palette).
    var allSessions: [SessionVM] { Array(sessionsByID.values) + Array(externalByID.values) }

    /// Sidebar footer, status bar and menu bar icon: the hook endpoint's state. A busy port or a
    /// failed listener is the degraded mode (registry only): the icon goes hollow and the status
    /// bar says why.
    var host: HostSummary {
        let status = hooks?.status
        let hookStatus: String
        var healthy = false
        switch status {
        case .listening(let port)?:
            hookStatus = "● ok :\(port)"
            healthy = true
        case .portInUse(let port, let otherCODD)?:
            hookStatus = otherCODD ? "▲ :\(port) 由另一個 CODD 使用 · 只用 registry" : "▲ :\(port) 被其他程式佔用 · 只用 registry"
        case .failed?:
            hookStatus = "▲ 無法啟動 · 只用 registry"
        case .starting?:
            hookStatus = "◌ 啟動中"
        case nil:
            hookStatus = "○ 未啟用"
        }
        return HostSummary(line: hostLine ?? "CODD · \(Self.abbreviate(root.path))", mcpEndpoint: mcp?.endpoint ?? "—",
                           mcpClients: mcp?.clientCount ?? 0, mcpRunning: mcp?.running ?? false,
                           hooksInstalled: healthy || status == .starting, hooksHealthy: healthy, cleanupSuggestions: cleanupSuggestions,
                           hookStatus: hookStatus)
    }

    func group(_ id: GroupID) -> GroupVM? { groups.first { $0.id == id } }
    func project(_ id: ProjectID) -> ProjectVM? { projectsByID[id] }
    func session(_ id: SessionID) -> SessionVM? { sessionsByID[id] ?? externalByID[id] }
    func runtime(_ id: SessionID) -> HolderRuntime? { runtimes[id] }
    func record(_ id: SessionID) -> LayoutSessionRecord? { records[id] }
    /// The connection of a session's own PTY (nil while it is not running).
    func connection(for id: SessionID) -> PtyConnection? { runtimes[id]?.connection }
    /// Directories of every known session, archived ones included (shell tabs live under them).
    var sessionDirectories: [SessionID: String] { runtimes.mapValues(\.directory) }
    /// No project at all yet (first launch: the empty state). Transient projects do not count.
    var isEmpty: Bool { groups.allSatisfy { $0.projectIDs.allSatisfy { projectsByID[$0]?.isTransient ?? true } } }

    /// The project whose folder is `path` (`~`, `.`, `..` and a trailing `/` ignored), else the one
    /// whose folder is the same directory once symlinks are resolved on both sides (D6: an
    /// external in `/var/…` and a project in `/private/var/…` are one folder).
    func project(forPath path: String) -> ProjectVM? {
        let wanted = Self.standardize(path)
        if let exact = projectsByID.values.first(where: { Self.standardize($0.cwd) == wanted }) { return exact }
        let real = resolvedPath(wanted)
        return projectsByID.values.sorted { $0.id < $1.id }.first { resolvedPath(Self.standardize($0.cwd)) == real }
    }

    // MARK: - Start: layout, discovery, hooks

    /// Reads layout.json and `sessions/*/meta.json` off the main actor, shows every session,
    /// reattaches to the live holders, registers claude sessions with the state engine and starts
    /// the hook endpoint. Then starts a shell in `spawnCwd`, if given.
    func start(spawnShellIn spawnCwd: String? = nil) async {
        guard !started else { return }
        started = true
        let root = self.root
        if launcher == nil {
            let (holder, hook, statusLine) = await Task.detached(priority: .userInitiated) { () -> (String?, String?, String?) in
                let log: @Sendable (String) -> Void = { HolderSessionStore.printLog($0) }
                return (HolderBinary.install(root: root, log: log), CoddHookBinary.install(root: root, log: log),
                        CoddStatusLineBinary.install(root: root, log: log))
            }.value
            launcher = holder.map {
                var launcher = HolderLauncher(holderExecutable: $0, root: root, shellArgvOverride: shellArgvOverride,
                                              claudePathOverride: claudePathOverride)
                if let hook { launcher.coddHookPath = hook }
                launcher.coddStatusLinePath = statusLine
                return launcher
            }
        }
        hooks?.onBatch = { [weak self] batch in self?.apply(batch) }
        hooks?.onDetail = { [weak self] id, update in self?.applyDetail(update, for: id) }
        hooks?.onRegistry = { [weak self] snapshot in self?.applyRegistry(snapshot.entries) }
        hooks?.onPrompt = { [weak self] id, prompt, full in self?.applyPrompt(prompt, full: full, for: id) }
        profiles.onChange = { [weak self] document in self?.applyLaunchProfiles(document) }
        profiles.onProblem = { [weak self] message, detail in self?.report(message, detail: detail) }
        let layoutURL = root.layoutURL
        let (layout, found, pendingAnswers) = await Task.detached(priority: .userInitiated)
            { () -> (LayoutSaver.Loaded, Result<[DiscoveredHolder], HolderStartError>, [SessionID: HookToolDetail]) in
            do {
                try root.prepare()
            } catch {
                return (LayoutSaver.load(layoutURL), .failure(.files(String(describing: error))), [:])
            }
            let loaded = LayoutSaver.load(layoutURL)
            do {
                // D24: an ephemeral session a crash left behind never comes back.
                let holders = Self.removeEphemeralLeftovers(try SessionDirectory.list(root: root.sessionsPath), root: root,
                                                            log: { HolderSessionStore.printLog($0) })
                var answers: [SessionID: HookToolDetail] = [:]
                for holder in holders {
                    if let detail = PendingAnswerFile.read(directory: holder.directory) { answers[holder.meta.session] = detail }
                }
                return (loaded, .success(holders), answers)
            } catch {
                return (loaded, .failure(.files(String(describing: error))), [:])
            }
        }.value
        // D5: once the data root exists and before `isLoaded`, so the first launch already uses
        // the saved profiles.
        await profiles.load()
        applyLaunchProfiles(profiles.document)
        layoutSaver.loaded(layout)
        if let shown = LayoutSaver.shown(layout) { install(LayoutMapping.model(from: shown)) }
        var adopted = 0
        switch found {
        case .success(let holders):
            adopted = merge(holders)
            log("discovered root=\(root.path) sessions=\(holders.count) live=\(holders.filter(\.holderAlive).count)")
            collectHookCopies(liveArgv: holders.filter { $0.holderAlive && !$0.meta.exited }.map(\.meta.argv))
        case .failure(let error):
            report(error.userMessage, detail: error.description)
        }
        settleUndiscovered()
        restorePendingAnswers(pendingAnswers)
        isLoaded = true
        onLoaded?()
        prewarmProjectPaths()
        if adopted > 0 { scheduleLayoutSave() }
        // Registry snapshots that arrived while loading (tests apply them directly).
        if !registryEntries.isEmpty { applyRegistry(registryEntries) }
        startStaleTimer()
        await registerClaudeSessions()
        for (id, runtime) in runtimes where runtime.holderAlive && !runtime.childExited && sessionsByID[id] != nil { connect(id) }
        await hooks?.start()
        onStatesChanged?()
        if let spawnCwd { spawnShell(in: spawnCwd) }
    }

    /// Old codd-hook copies go once no live session's `--settings` names them (the current one
    /// always stays). Only for copies this store installed under the data root.
    private func collectHookCopies(liveArgv: [[String]]) {
        let root = self.root
        let inRoot = root.path + "/bin/"
        let hook = launcher?.coddHookPath.flatMap { $0.hasPrefix(inRoot) ? $0 : nil }
        let statusLine = launcher?.coddStatusLinePath.flatMap { $0.hasPrefix(inRoot) ? $0 : nil }
        Task.detached(priority: .utility) {
            let log: @Sendable (String) -> Void = { HolderSessionStore.printLog($0) }
            if let hook { CoddHookBinary.collectGarbage(root: root, current: hook, liveArgv: liveArgv, log: log) }
            if let statusLine { CoddStatusLineBinary.collectGarbage(root: root, current: statusLine, liveArgv: liveArgv, log: log) }
        }
    }

    /// The layout's view models (placeholder states until `merge`).
    private func install(_ model: LayoutMapping.Model) {
        groups = model.groups
        projectsByID = model.projects
        sessionsByID = model.sessions
        archivedByID = model.archived
        records = model.records
        projectRecords = model.projectRecords
        pinnedSessionIDs = model.pinned
        for (id, record) in records {
            let cwd = projectsByID[LayoutMapping.id(record.projectId)]?.cwd ?? NSHomeDirectory()
            runtimes[id] = HolderRuntime(directory: root.sessionDirectory(id),
                                         socketPath: record.holderSocket ?? root.socketPath(for: id) ?? "", cwd: cwd)
            if let session = sessionsByID[id] ?? archivedByID[id] { applyAccount(to: session) }
        }
    }

    /// Matches discovered holders to layout rows (adopting unknown ones into the tree) and sets
    /// each one's state from its meta.json. Returns how many were adopted.
    private func merge(_ holders: [DiscoveredHolder]) -> Int {
        var adopted = 0
        for holder in holders.sorted(by: { $0.meta.startedAt < $1.meta.startedAt }) {
            let meta = holder.meta
            let id = meta.session
            guard !meta.socket.isEmpty, let uuid = UUID(uuidString: id), LayoutMapping.id(uuid) == id else { continue }
            if records[id] == nil {
                adopt(meta, uuid: uuid)
                adopted += 1
            }
            guard let session = sessionsByID[id] ?? archivedByID[id] else { continue }
            var runtime = HolderRuntime(directory: holder.directory, socketPath: meta.socket, cwd: meta.cwd, holderPid: meta.holderPid)
            runtime.holderAlive = holder.holderAlive
            runtime.childExited = meta.exited
            runtimes[id] = runtime
            session.pid = meta.childPid
            let live = holder.holderAlive && !meta.exited
            if live { session.startedAt = Self.date(milliseconds: meta.startedAt) }
            switch session.kind {
            case .shell:
                if records[id]?.titleOverride == nil { session.title = Self.displayTitle(meta.title, argv: meta.argv) }
                session.detail = Self.abbreviate(meta.oscCwd ?? meta.cwd)
                if live {
                    transition(session, to: .shell, since: Self.date(milliseconds: meta.startedAt))
                } else {
                    transition(session, to: .exited, since: Self.date(milliseconds: meta.exitedAt ?? meta.startedAt))
                    session.exitCode = meta.exited ? Self.exitCode(status: meta.exitStatus ?? 0, signaled: meta.signaled ?? false) : nil
                }
            case .claude:
                if live {
                    // The engine reports the restored hook state right after registration.
                    transition(session, to: hooks == nil ? .unknown : .starting, since: Self.date(milliseconds: meta.startedAt))
                } else {
                    transition(session, to: .stopped, since: Self.date(milliseconds: meta.exitedAt ?? meta.startedAt))
                }
            }
        }
        return adopted
    }

    /// A holder the layout does not know (an older CODD, a lost layout.json): added to the
    /// project of its folder.
    private func adopt(_ meta: HolderMeta, uuid: UUID) {
        let id = LayoutMapping.id(uuid)
        let kind: SessionKind = Self.isClaudeArgv(meta.argv) ? .claude : .shell
        let project = project(forPath: meta.cwd) ?? addProjectVM(path: meta.cwd, groupID: nil)
        promoteTransient(project)
        guard let projectUUID = UUID(uuidString: project.id) else { return }
        let record = LayoutSessionRecord(id: uuid, claudeSessionId: kind == .claude ? id : nil, projectId: projectUUID,
                                         kind: kind == .claude ? .claude : .shell, title: meta.title, order: project.sessionIDs.count,
                                         createdAt: Self.date(milliseconds: meta.startedAt), holderSocket: meta.socket)
        records[id] = record
        let session = SessionVM(id: id, projectID: project.id, kind: kind,
                                title: kind == .shell ? Self.displayTitle(meta.title, argv: meta.argv) : record.displayTitle(fallback: "claude"),
                                state: kind == .shell ? .exited : .stopped, stateSince: record.createdAt)
        session.claudeSessionID = record.claudeSessionId
        sessionsByID[id] = session
        applyAccount(to: session)
        insertCODDSession(id, in: project)
    }

    /// A running claude session's pending prompt detail from before the relaunch (shown once the
    /// engine reports its restored WAITING); a stale one of an ended session goes.
    private func restorePendingAnswers(_ answers: [SessionID: HookToolDetail]) {
        for (id, detail) in answers {
            let runtime = runtimes[id]
            let running = (runtime?.holderAlive ?? false) && !(runtime?.childExited ?? true)
            if running, (sessionsByID[id] ?? archivedByID[id])?.kind == .claude {
                toolDetails[id] = detail
                persistedDetails[id] = detail
            } else if let directory = runtime?.directory {
                PendingAnswerFile.write(nil, directory: directory)
            }
        }
    }

    /// Layout rows without a holder directory: their process is long gone.
    private func settleUndiscovered() {
        for (id, session) in sessionsByID.merging(archivedByID, uniquingKeysWith: { a, _ in a })
        where !(runtimes[id]?.holderAlive ?? false) && session.state != .exited && session.state != .stopped {
            transition(session, to: session.kind == .shell ? .exited : .stopped)
        }
    }

    /// Every claude session goes to the state engine: running ones keep their restored hook state
    /// (CODD relaunched, claude kept running), the rest are STOPPED.
    private func registerClaudeSessions() async {
        guard let engine = hooks?.engine else { return }
        var keep = Set<UUID>()
        for (id, session) in sessionsByID.merging(archivedByID, uniquingKeysWith: { a, _ in a }) where session.kind == .claude {
            guard let uuid = UUID(uuidString: id) else { continue }
            keep.insert(uuid)
            let runtime = runtimes[id]
            let running = (runtime?.holderAlive ?? false) && !(runtime?.childExited ?? true)
            let process: SessionStateResolver.ProcessStatus = running ? .running(startedAt: session.startedAt ?? clock.now()) : .stopped
            await engine.register(registration(id, uuid: uuid, process: process, fresh: false))
        }
        await engine.pruneHookStates(keeping: keep)
    }

    func registration(_ id: SessionID, uuid: UUID, process: SessionStateResolver.ProcessStatus, fresh: Bool) -> SessionRegistration {
        let record = records[id]
        return SessionRegistration(sessionID: uuid, kind: .claude, process: process, claudePid: sessionsByID[id]?.pid.map(Int.init),
                                   claudeSessionId: record?.claudeSessionId ?? id, cwd: runtimes[id]?.cwd, configDir: nil,
                                   lastViewedAt: record?.lastViewedAt, freshClaudeProcess: fresh)
    }

    // MARK: - Connections

    func connect(_ id: SessionID, freshSpawn: Bool = false) {
        guard let runtime = runtimes[id] else { return }
        if let existing = runtime.connection {
            // RESTART / RESUME: same socket and directory, a new holder behind them.
            if freshSpawn {
                existing.restartedProcess()
                onConnection?(id, existing)
            } else {
                existing.connect()
            }
            return
        }
        let connection = PtyConnection(sessionID: id, socketPath: runtime.socketPath, directory: runtime.directory,
                                       tuning: connectionTuning, log: log)
        connection.onEvent = { [weak self] event in self?.handle(event, session: id) }
        runtimes[id]?.connection = connection
        onConnection?(id, connection)
        connection.connect(freshSpawn: freshSpawn)
    }

    /// D5: the launcher starts sessions and shell tabs with these profiles from now on.
    func applyLaunchProfiles(_ document: LaunchProfileDocument) {
        launcher?.profiles = document.profiles
        launcher?.defaultProfileID = document.defaultProfileId
    }

    /// App quit, first step: the state engine writes its pending hook records and the endpoint
    /// releases its port (the next CODD binds it right away).
    func shutdownHooks() async {
        await hooks?.shutdown()
    }

    /// App quit: writes the layout, closes every connection. Holders keep running; the next
    /// launch reattaches.
    func shutdown() {
        staleTask?.cancel()
        staleTask = nil
        flushLayout()
        for runtime in runtimes.values { runtime.connection?.close() }
    }

    private func handle(_ event: PtyEvent, session id: SessionID) {
        guard runtimes[id] != nil, let session = sessionsByID[id] ?? archivedByID[id] else { return }
        let isClaude = session.kind == .claude
        let uuid = UUID(uuidString: id)
        switch event {
        case .welcome(let welcome):
            setUnreachable(session, since: nil)
            if let holderPid = welcome.holderPid { runtimes[id]?.holderPid = holderPid }
            runtimes[id]?.holderAlive = true
            session.pid = welcome.childPid
            // Its child (or shell) is now known by pid: an entry seen as external may be ours.
            scheduleExternalRefresh()
            log("attached session=\(id) holderPid=\(welcome.holderPid.map { String($0) } ?? "?") childPid=\(welcome.childPid) "
                + "title=\(welcome.title ?? "-") cwd=\(welcome.cwd ?? "-") exited=\(welcome.exited) ringEnd=\(welcome.ringEnd)")
            if isClaude {
                if let engine = hooks?.engine, let uuid {
                    let pid = Int(welcome.childPid)
                    let title = welcome.title
                    Task { await engine.childPidChanged(uuid, pid: pid); if let title { await engine.ingestTitle(title, for: uuid) } }
                }
                if welcome.exited {
                    claudeExited(session, status: welcome.exitStatus ?? 0, signaled: welcome.signaled ?? false)
                } else if hooks == nil, session.state == .starting {
                    transition(session, to: .unknown)
                }
            } else {
                if records[id]?.titleOverride == nil, let title = welcome.title { session.title = Self.displayTitle(title, argv: []) }
                if let cwd = welcome.cwd { session.detail = Self.abbreviate(cwd) }
                if welcome.exited {
                    markExited(session, status: welcome.exitStatus ?? 0, signaled: welcome.signaled ?? false)
                } else {
                    if session.state != .shell {
                        transition(session, to: .shell)
                        if session.startedAt == nil { session.startedAt = clock.now() }
                    }
                    ephemeralShellStarted(id)
                }
            }
        case .title(let title):
            if isClaude {
                if let engine = hooks?.engine, let uuid { Task { await engine.ingestTitle(title, for: uuid) } }
            } else if records[id]?.titleOverride == nil {
                session.title = Self.displayTitle(title, argv: [])
            }
            #if DEBUG
            if verboseLog { log("title session=\(id) \(title)") }
            #endif
        case .cwd(let cwd):
            if !isClaude { session.detail = Self.abbreviate(cwd) }
            #if DEBUG
            if verboseLog { log("cwd session=\(id) \(cwd)") }
            #endif
        case .bell:
            session.lastBellAt = clock.now()
            onBell?(id)
        case .exit(let info):
            runtimes[id]?.childExited = true
            if isClaude { claudeExited(session, status: info.status, signaled: info.signaled) } else {
                markExited(session, status: info.status, signaled: info.signaled)
            }
            log("exit session=\(id) status=\(info.status) signaled=\(info.signaled)")
        case .unreachable(let unreachable):
            setUnreachable(session, since: unreachable ? (runtimes[id]?.connection?.unreachableSince ?? clock.now()) : nil)
        case .ended(let ending):
            log("ended session=\(id) \(ending)")
            setUnreachable(session, since: nil)
            runtimes[id]?.holderAlive = false
            switch ending {
            case .holderGone(let exit?) where session.state.isLive:
                if isClaude { claudeExited(session, status: exit.status, signaled: exit.signaled) } else {
                    markExited(session, status: exit.status, signaled: exit.signaled)
                }
            case .takenOver:
                // The process still runs, held by another client: STOPPED for either kind.
                if session.state.isLive { processGone(session, takenOver: true) }
                report("另一個 CODD 接管了這個 session", detail: "session \(id): taken over by another CODD", sessionID: id)
            default:
                // Gone without EXIT (killed, crashed): claude can be resumed, the shell restarted.
                if session.state.isLive { processGone(session) }
            }
        }
    }

    /// D8 overlay (archived sessions too, so UNDO shows current facts).
    func setUnreachable(_ session: SessionVM, since: Date?) {
        guard session.unreachableSince != since else { return }
        session.unreachableSince = since
        onStatesChanged?()
    }

    /// `[↻ 立即重試]`: the session's own connection reconnects now.
    func retryConnection(_ id: SessionID) {
        guard let connection = runtimes[id]?.connection else { return }
        log("retry session=\(id) phase=\(connection.phase)")
        connection.retryNow()
    }

    private func markExited(_ session: SessionVM, status: Int32, signaled: Bool) {
        transition(session, to: .exited)
        session.exitCode = Self.exitCode(status: status, signaled: signaled)
        onStatesChanged?()
        if session.kind == .shell { ephemeralShellExited(session.id) }
    }

    /// Claude's process ended this run: EXITED (with RESUME), through the engine when it runs.
    private func claudeExited(_ session: SessionVM, status: Int32, signaled: Bool) {
        let code = Self.exitCode(status: status, signaled: signaled)
        session.exitCode = code
        guard let engine = hooks?.engine, let uuid = UUID(uuidString: session.id) else {
            markExited(session, status: status, signaled: signaled)
            return
        }
        Task { await engine.processExited(uuid, code: signaled ? nil : status) }
    }

    /// The holder vanished without an exit (killed, crashed) or another client took it over:
    /// claude can be resumed (STOPPED), a shell restarted (EXITED; STOPPED when taken over, since
    /// it still runs elsewhere).
    private func processGone(_ session: SessionVM, takenOver: Bool = false) {
        if session.kind == .claude, let engine = hooks?.engine, let uuid = UUID(uuidString: session.id) {
            let registration = registration(session.id, uuid: uuid, process: .stopped, fresh: false)
            Task { await engine.register(registration) }
        }
        transition(session, to: session.kind == .claude || takenOver ? .stopped : .exited)
        onStatesChanged?()
    }

    // MARK: - Hook states

    /// One engine batch (≤ 10 Hz) onto the view models.
    func apply(_ batch: SessionStateBatch) {
        var layoutChanged = false
        for update in batch.updates {
            let id = LayoutMapping.id(update.sessionID)
            guard let session = sessionsByID[id] ?? archivedByID[id] else { continue }
            if apply(update, to: session) { layoutChanged = true }
        }
        if layoutChanged { scheduleLayoutSave() }
        if !batch.updates.isEmpty { onStatesChanged?() }
    }

    /// Returns true when a persisted fact changed (Claude session id, learned title).
    @discardableResult
    func apply(_ update: SessionStateUpdate, to session: SessionVM) -> Bool {
        let id = session.id
        var mapped = Self.appState(update.state)
        if mapped.state == .done, isViewing?(id) == true {
            // Seen as it finished: IDLE, and the engine learns it was viewed (DONE is not
            // reported again, also not after a relaunch).
            mapped.state = .idle
            markViewed(id)
        }
        var since = update.activity.sinceDate
        if mapped.state == .starting { since = session.startedAt ?? since }
        let before = session.state
        transition(session, to: mapped.state, since: since)
        #if DEBUG
        // Hook received → view model updated (engine batching included), for the M1 report.
        if session.state != before, let began = update.activity.sinceDate, update.hookSeen {
            log(String(format: "hook-applied session=%@ state=%@ latencyMs=%.1f", id, session.state.rawValue,
                       clock.now().timeIntervalSince(began) * 1000))
        }
        #endif
        session.waitingReason = mapped.reason
        session.errorReason = mapped.errorLabel
        if case .exited(let code) = update.state, let code { session.exitCode = code }
        refreshToolFields(session)
        session.remoteControl = update.registry?.bridgeSessionId != nil
        guard var record = records[id] else { return false }
        var changed = false
        if let claudeID = JSText.nonBlankTrimmed(update.hook?.sessionId), record.claudeSessionId != claudeID {
            record.claudeSessionId = claudeID
            session.claudeSessionID = claudeID
            changed = true
        }
        if let learned = Self.learnedTitle(update), record.title != learned {
            record.title = learned
            changed = true
        }
        if changed { records[id] = record }
        let title = record.displayTitle(fallback: "claude")
        if session.title != title { session.title = title }
        return changed
    }

    /// Tool, detail and answer options for the current state (from the latest hook detail).
    private func refreshToolFields(_ session: SessionVM) {
        let detail = toolDetails[session.id]
        switch session.state {
        case .waiting:
            let question = session.waitingReason == .question
            session.tool = detail?.tool
            session.detail = question ? (detail?.question ?? detail?.summary) : detail?.summary
            session.answerOptions = question ? (detail?.options ?? []) : []
        case .busy:
            session.tool = detail?.tool
            session.detail = detail?.summary
            session.answerOptions = []
        default:
            session.tool = nil
            session.detail = nil
            session.answerOptions = []
        }
        persistPendingAnswer(session)
    }

    /// Keeps `PendingAnswerFile` equal to the detail of a waiting claude session (none otherwise).
    private func persistPendingAnswer(_ session: SessionVM) {
        let pending = session.kind == .claude && session.state == .waiting ? toolDetails[session.id] : nil
        guard persistedDetails[session.id] != pending, let directory = runtimes[session.id]?.directory else { return }
        persistedDetails[session.id] = pending
        PendingAnswerFile.write(pending, directory: directory)
    }

    /// A hook named a tool (or a turn ended): arrives just before the engine's state for it.
    func applyDetail(_ update: HookToolDetail.Update, for uuid: UUID) {
        let id = LayoutMapping.id(uuid)
        switch update {
        case .set(let detail): toolDetails[id] = detail
        case .clear: toolDetails[id] = nil
        }
        if let session = sessionsByID[id] ?? archivedByID[id], session.kind == .claude, session.state == .waiting {
            refreshToolFields(session)
        }
    }

    /// The hook's custom title, else the registry's name, else the OSC title (Claude's default
    /// `Claude Code` title says nothing).
    nonisolated static func learnedTitle(_ update: SessionStateUpdate) -> String? {
        let candidates = [update.hook?.customTitle, update.registry?.name, update.title?.text]
        for candidate in candidates {
            guard let text = JSText.nonBlankTrimmed(candidate) else { continue }
            if text.caseInsensitiveCompare("Claude Code") == .orderedSame || text.caseInsensitiveCompare("claude") == .orderedSame {
                continue
            }
            return String(text.prefix(120))
        }
        return nil
    }

    /// CoddCore's state → the app's state, waiting reason, error label and exit code.
    nonisolated static func appState(_ state: CoddCore.SessionState) -> (state: SessionState, reason: WaitingReason?, errorLabel: String?) {
        switch state {
        case .waiting(let reason): (.waiting, WaitingReason(rawValue: reason.rawValue) ?? .other, nil)
        case .error(let kind): (.error, nil, kind.label)
        case .done: (.done, nil, nil)
        case .busy: (.busy, nil, nil)
        case .compacting: (.compacting, nil, nil)
        case .idle: (.idle, nil, nil)
        case .starting: (.starting, nil, nil)
        case .unknown: (.unknown, nil, nil)
        case .shell: (.shell, nil, nil)
        case .exited: (.exited, nil, nil)
        case .stopped: (.stopped, nil, nil)
        }
    }

    // MARK: - Session intents

    func renameSession(_ id: SessionID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let session = sessionsByID[id], !trimmed.isEmpty, session.title != trimmed else { return }
        session.title = trimmed
        records[id]?.titleOverride = trimmed
        scheduleLayoutSave()
    }

    /// SIGTERM to the holder: it ends the child (and its jobs), reports EXIT, then exits itself.
    /// M5 D20: a session still STARTING (its spawn in flight, no holder pid yet) remembers the
    /// stop instead of dropping it; it is applied right after the holder is up and connected.
    func stop(_ ids: [SessionID]) {
        for id in ids {
            guard let session = sessionsByID[id], session.state.isLive else { continue }
            if launchesInFlight.contains(id) {
                stopRequested.insert(id)
                if pendingStops.insert(id).inserted { log("stop deferred session=\(id)") }
                continue
            }
            guard let pid = runtimes[id]?.holderPid, SessionDirectory.isHolderProcess(pid) else { continue }
            stopRequested.insert(id)
            kill(pid, SIGTERM)
        }
    }

    /// Answer-bar key for a waiting claude session: the key's bytes go to its PTY (the state then
    /// follows from Claude's hooks).
    func answer(_ id: SessionID, key: String) {
        guard let session = sessionsByID[id], session.kind == .claude, session.state == .waiting,
              TerminalInput.isAnswerKey(key) else { return }
        let sent = connection(for: id)?.send(TerminalInput.key(key).bytes) ?? false
        log("answer session=\(id) key=\(key) sent=\(sent)")
    }

    /// The user left a session they had looked at: DONE (unseen) becomes IDLE.
    func markSeen(_ id: SessionID) {
        markViewed(id)
        if let session = sessionsByID[id], session.state == .done { transition(session, to: .idle) }
    }

    /// Remembers when the user last looked at a session (persisted: DONE vs IDLE after a relaunch).
    func markViewed(_ id: SessionID) {
        guard records[id] != nil else { return }
        let now = clock.now()
        records[id]?.lastViewedAt = now
        if sessionsByID[id]?.kind == .claude, let engine = hooks?.engine, let uuid = UUID(uuidString: id) {
            Task { await engine.setLastViewed(uuid, at: now) }
        }
        scheduleLayoutSave()
    }

    // MARK: - Helpers

    func transition(_ session: SessionVM, to state: SessionState, since: Date? = nil) {
        guard session.state != state else { return }
        let old = session.state
        session.state = state
        session.stateSince = since ?? clock.now()
        refreshStale(session, now: clock.now())
        // Placeholder states while loading are not transitions anyone should hear about.
        guard isLoaded else { return }
        log("state session=\(session.id) \(old.rawValue)->\(state.rawValue)")
        onTransition?(session, old)
        // Shell states (WELCOME, EXIT) bypass the engine's batches: the state dump hears them here.
        onStatesChanged?()
    }

    /// Logs `detail` (else `message`) as `REALHOLDERS error …` and, with `surface`, makes
    /// `message` (繁體中文, what the user sees) the banner's problem: for every session when
    /// `sessionID` is nil, else on that session. Pass `surface: false` for what another view
    /// already shows (the ⌘N sheet's refusal, a session's own launch-error banner).
    func report(_ message: String, detail: String? = nil, surface: Bool = true, sessionID: SessionID? = nil) {
        log("error \(detail ?? message)")
        guard surface else { return }
        // A queued data-file banner that was showing comes back after this one (M5 D14).
        if let shown = problem, shown.queued { problemQueue.insert(shown, at: 0) }
        problem = StoreProblem(message: message, at: clock.now(), sessionID: sessionID)
        onStatesChanged?()
    }

    /// `[知道了]` on the problem banner: the next queued banner, if any, takes its place.
    func dismissProblem() {
        guard problem != nil else { return }
        problem = nil
        if !problemQueue.isEmpty { showQueued(problemQueue.removeFirst()) }
        onStatesChanged?()
    }

    /// M5 D14: a banner that waits its turn (one data-file issue each): shown now when nothing
    /// else is, else after the ones before it.
    func queueProblem(_ queued: StoreProblem) {
        var item = queued
        item.queued = true
        if problem == nil {
            showQueued(item)
            onStatesChanged?()
        } else {
            problemQueue.append(item)
        }
    }

    private func showQueued(_ item: StoreProblem) {
        var shown = item
        shown.at = clock.now()
        problem = shown
        queuedProblemsShown.insert(shown.message)
    }

    /// A `createSession` refusal: returned to the sheet through `lastRefusal`, logged, no banner.
    func refuse(_ message: String, detail: String? = nil) {
        lastRefusal = message
        report(message, detail: detail, surface: false)
    }

    /// A project for `path` in the given group (ungrouped when nil or unknown).
    @discardableResult
    func addProjectVM(path: String, groupID: GroupID?) -> ProjectVM {
        let uuid = UUID()
        let id = LayoutMapping.id(uuid)
        let target = groupID.flatMap(group) ?? group(Self.ungroupedID) ?? groups.last
        let project = ProjectVM(id: id, name: Self.projectName(cwd: path), cwd: path, groupID: target?.id ?? Self.ungroupedID,
                                sessionIDs: [])
        projectsByID[id] = project
        projectRecords[id] = Project(id: uuid, name: project.name, path: path, order: target?.projectIDs.count ?? 0)
        if let target { insertSavedProject(id, in: target) }
        prewarmProjectPaths()
        return project
    }

    func scheduleLayoutSave() {
        guard isLoaded else { return }
        layoutSaver.schedule { [weak self] in self?.currentLayout() ?? Layout() }
    }

    func flushLayout() {
        guard isLoaded else { return }
        if let current = shellCurrentSession?() { markViewedSilently(current) }
        layoutSaver.flush(currentLayout())
    }

    /// The session the pane shows at quit counts as seen (no engine round trip needed).
    @ObservationIgnored var shellCurrentSession: (() -> SessionID?)?

    private func markViewedSilently(_ id: SessionID) {
        if records[id] != nil { records[id]?.lastViewedAt = clock.now() }
    }

    func currentLayout() -> Layout {
        LayoutMapping.layout(groups: groups, projects: projectsByID, sessions: sessionsByID, archived: archivedByID,
                             records: persistentRecords, projectRecords: projectRecords, now: clock.now())
    }

    // MARK: - Formatting

    nonisolated static func standardize(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    nonisolated static func projectName(cwd: String) -> String {
        if cwd == NSHomeDirectory() { return "~" }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    /// Home folder shown as `~`.
    nonisolated static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// OSC title, trimmed and capped; the program name when there is none.
    nonisolated static func displayTitle(_ title: String?, argv: [String]) -> String {
        let trimmed = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return String(trimmed.prefix(120)) }
        let program = argv.first.map { ($0 as NSString).lastPathComponent } ?? ""
        return program.isEmpty ? "zsh" : program
    }

    /// A holder child that is Claude Code (adopting holders the layout lost).
    nonisolated static func isClaudeArgv(_ argv: [String]) -> Bool {
        guard let program = argv.first else { return false }
        return (program as NSString).lastPathComponent == "claude" || argv.contains("--session-id") || argv.contains("--resume")
    }

    /// Shell convention: 128 + signal number for a signaled exit.
    nonisolated static func exitCode(status: Int32, signaled: Bool) -> Int32 {
        signaled ? 128 + status : status
    }

    nonisolated static func date(milliseconds: UInt64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
    }
}

/// Process-side facts about one session (not observed by views).
struct HolderRuntime {
    var directory: String
    var socketPath: String
    var cwd: String
    var holderPid: pid_t?
    var connection: PtyConnection?
    /// meta.json (or WELCOME) says a holder process runs for this session.
    var holderAlive = false
    /// Its child already exited (the holder only lingers).
    var childExited = false
}
