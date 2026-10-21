import CoddCore
import Foundation

/// A CODD session the engine tracks.
public struct SessionRegistration: Sendable, Equatable {
    public var sessionID: UUID
    public var kind: SessionKind
    public var process: SessionStateResolver.ProcessStatus
    /// The `claude` process (the holder's child), used to match the registry.
    public var claudePid: Int?
    /// The launch `--session-id` / `--resume` id; the registry fallback until a hook names the
    /// current Claude session.
    public var claudeSessionId: String?
    public var cwd: String?
    /// The session's `CLAUDE_CONFIG_DIR` (written as `config_dir`; default `~/.claude`).
    public var configDir: String?
    /// Last time the user looked at the session (`done` vs `idle`).
    public var lastViewedAt: Date?
    /// CODD has just (re)started claude for this session (new session, RESTART, RESUME): any
    /// restored hook record belongs to a previous process. It is hidden until this process sends
    /// its first hook, and that first event is applied on top of
    /// ``HookReducer/relaunchBaseline(_:now:)``. `false` when CODD relaunched and reattached to a
    /// claude that kept running: the restored record is shown as is.
    public var freshClaudeProcess: Bool

    public init(sessionID: UUID, kind: SessionKind, process: SessionStateResolver.ProcessStatus, claudePid: Int? = nil,
                claudeSessionId: String? = nil, cwd: String? = nil, configDir: String? = nil,
                lastViewedAt: Date? = nil, freshClaudeProcess: Bool) {
        self.sessionID = sessionID
        self.kind = kind
        self.process = process
        self.claudePid = claudePid
        self.claudeSessionId = claudeSessionId
        self.cwd = cwd
        self.configDir = configDir
        self.lastViewedAt = lastViewedAt
        self.freshClaudeProcess = freshClaudeProcess
    }
}

/// What the UI needs to know about one session after a change.
public struct SessionStateUpdate: Sendable, Equatable {
    public var sessionID: UUID
    public var state: SessionState
    /// The merged activity behind ``state`` (since, reason, last tool, source).
    public var activity: SessionActivity
    /// The latest hook record (current Claude session id for RESUME, prompt, custom title). For a
    /// fresh process this is `nil` until its first hook.
    public var hook: HookSessionState?
    /// A hook arrived from the current claude process (or was restored for a process that kept
    /// running). `false` after the grace period is SPEC's `! NO HOOK`.
    public var hookSeen: Bool
    /// The parsed OSC title (glyph activity and text), when the holder reported one.
    public var title: TerminalTitle?
    /// The live registry entry matched to this session (name, Remote Control).
    public var registry: ClaudeRegistryEntry?

    public init(sessionID: UUID, state: SessionState, activity: SessionActivity, hook: HookSessionState?,
                hookSeen: Bool, title: TerminalTitle?, registry: ClaudeRegistryEntry?) {
        self.sessionID = sessionID
        self.state = state
        self.activity = activity
        self.hook = hook
        self.hookSeen = hookSeen
        self.title = title
        self.registry = registry
    }
}

/// One emission of ``SessionStateEngine/updates``: the latest value of every session that changed
/// since the previous batch, and the sessions that were unregistered.
public struct SessionStateBatch: Sendable, Equatable {
    public var updates: [SessionStateUpdate]
    public var removed: [UUID]

    public init(updates: [SessionStateUpdate], removed: [UUID]) {
        self.updates = updates
        self.removed = removed
    }
}

/// Combines every state source of CODD's sessions into ``SessionState`` changes.
///
/// Sources, in priority order (docs/ARCHITECTURE.md "State model"): hook events through
/// ``HookReducer`` (desktop dialect), the live registry through ``ActivityMerger`` (which also
/// lets a newer registry `busy`/`idle` correct a hook state after an Esc or an approved
/// permission), holder EXIT, and the OSC title glyph, which is only used once a session would
/// otherwise be `unknown` (no hook and no registry entry after the starting grace).
///
/// Output: ``updates`` yields at most one batch per ``Configuration/batchInterval`` (default
/// 100 ms, so ≤ 10 Hz): the first change after a quiet period goes out immediately, later ones
/// are coalesced per session. Only sessions whose update differs from the last one emitted are
/// included.
///
/// Persistence: each hook record is written to `<dataRoot>/hooks/<session-id>.json` (debounced,
/// ≤ 1 s) and read back by ``register(_:)``. Events for a session that is not registered yet (the
/// server may start before the app has restored its sessions) are kept, at most
/// ``Configuration/maxOrphanEvents``, and replayed in order on registration.
public actor SessionStateEngine {
    public struct Configuration: Sendable {
        /// `<dataRoot>/hooks`; `nil` disables persistence.
        public var hooksDirectory: URL?
        public var batchInterval: Duration
        public var persistDebounce: Duration
        public var startingGrace: TimeInterval
        /// `config_dir` for sessions without their own `CLAUDE_CONFIG_DIR`.
        public var defaultConfigDir: String
        public var dialect: HookDialect
        public var maxOrphanEvents: Int

        public init(dataRoot: URL?, batchInterval: Duration = .milliseconds(100), persistDebounce: Duration = .seconds(1),
                    startingGrace: TimeInterval = SessionStateResolver.startingGrace,
                    defaultConfigDir: String = NSHomeDirectory() + "/.claude",
                    dialect: HookDialect = .desktop, maxOrphanEvents: Int = 256) {
            hooksDirectory = dataRoot?.appendingPathComponent("hooks", isDirectory: true)
            self.batchInterval = batchInterval
            self.persistDebounce = persistDebounce
            self.startingGrace = startingGrace
            self.defaultConfigDir = defaultConfigDir
            self.dialect = dialect
            self.maxOrphanEvents = maxOrphanEvents
        }
    }

    private struct Tracked {
        var registration: SessionRegistration
        var hook: HookSessionState?
        var baselinePending: Bool
        var hookSeen: Bool
        var title = TerminalTitleTracker()
        /// When the title's glyph activity last changed (the `since` of a title-derived state).
        var titleActivitySince: Date?
        var exitedAt: Date?
        /// The current claude process has had a turn (busy / waiting / … at least once), so a
        /// later `idle` can be `done`. For a process CODD reattached to after a relaunch, a restored
        /// record with a prompt or a tool call counts; a fresh process starts without one, so a
        /// RESUME does not open as DONE because of the previous process's last turn.
        var sawTurn = false
        /// The NO HOOK grace this session was registered with (a later setting applies to the
        /// sessions registered after it: new sessions, RESUME, RESTART).
        var startingGrace: TimeInterval = SessionStateResolver.startingGrace
        var current: SessionStateUpdate?
        var lastEmitted: SessionStateUpdate?
    }

    public nonisolated let updates: AsyncStream<SessionStateBatch>
    private let continuation: AsyncStream<SessionStateBatch>.Continuation
    private let configuration: Configuration
    private let clock: any HookClock
    private let persister: HookStatePersister?
    private let merger: ActivityMerger

    private var sessions: [UUID: Tracked] = [:]
    private var orphanEvents: [HookEvent] = []
    private var registry: [ClaudeRegistryEntry] = []
    private var dirty: Set<UUID> = []
    private var removedPending: [UUID] = []
    private var lastFlushAt: Date?
    private var flushTask: Task<Void, Never>?
    private var graceTasks: [UUID: Task<Void, Never>] = [:]
    /// ``Configuration/startingGrace`` until ``setStartingGrace(_:)`` changes it.
    private var startingGrace: TimeInterval

    public init(configuration: Configuration, clock: any HookClock = SystemHookClock()) {
        self.configuration = configuration
        startingGrace = configuration.startingGrace
        self.clock = clock
        persister = configuration.hooksDirectory.map { HookStatePersister(directory: $0, debounce: configuration.persistDebounce) }
        merger = ActivityMerger(dialect: configuration.dialect)
        (updates, continuation) = AsyncStream.makeStream(of: SessionStateBatch.self, bufferingPolicy: .unbounded)
    }

    // MARK: - Sessions

    /// Settings › 工作階段 › NO HOOK 警告 (M3): how long a claude without hook data stays
    /// `starting`. Sessions registered from now on use it; tracked ones keep theirs.
    public func setStartingGrace(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0 else { return }
        startingGrace = seconds
    }

    /// The grace new registrations get (tests).
    public var currentStartingGrace: TimeInterval { startingGrace }

    /// Starts tracking a session (or replaces its registration), restoring its persisted hook
    /// record and replaying hooks that arrived before it was registered.
    public func register(_ registration: SessionRegistration) {
        let id = registration.sessionID
        graceTasks.removeValue(forKey: id)?.cancel()
        let restored = persister?.load(id)
        var t = Tracked(
            registration: registration, hook: restored,
            baselinePending: registration.kind == .claude && registration.freshClaudeProcess,
            hookSeen: !registration.freshClaudeProcess && restored != nil)
        t.startingGrace = startingGrace
        if case .exited = registration.process { t.exitedAt = clock.now() }
        if !registration.freshClaudeProcess, let restored {
            t.sawTurn = restored.lastPromptAt != nil || (restored.toolCount ?? 0) > 0
        }
        let replay = orphanEvents.filter { $0.sessionID == id }
        orphanEvents.removeAll { $0.sessionID == id }
        for event in replay { apply(event, to: &t) }
        sessions[id] = t
        armGraceTimer(id)
        recompute(id)
        scheduleFlush()
    }

    /// Stops tracking. `deletePersistedState` removes the hook file (session deleted); otherwise
    /// it is kept for the next registration.
    public func unregister(_ id: UUID, deletePersistedState: Bool = false) {
        graceTasks.removeValue(forKey: id)?.cancel()
        guard sessions.removeValue(forKey: id) != nil else { return }
        if deletePersistedState { persister?.remove(id) }
        dirty.remove(id)
        removedPending.append(id)
        scheduleFlush()
    }

    /// CODD started a new claude process for a registered session (RESTART / RESUME into a new
    /// holder): the hook record of the previous process is baselined (see
    /// ``SessionRegistration/freshClaudeProcess``).
    public func claudeProcessStarted(_ id: UUID, pid: Int?, startedAt: Date, claudeSessionId: String? = nil) {
        guard var t = sessions[id] else { return }
        t.registration.process = .running(startedAt: startedAt)
        t.registration.claudePid = pid
        if let claudeSessionId { t.registration.claudeSessionId = claudeSessionId }
        t.baselinePending = t.registration.kind == .claude
        t.hookSeen = false
        t.sawTurn = false
        t.exitedAt = nil
        t.title = TerminalTitleTracker()
        t.titleActivitySince = nil
        sessions[id] = t
        armGraceTimer(id)
        recompute(id)
        scheduleFlush()
    }

    /// Holder EXIT: the child ended with `code` (`nil` = killed by a signal / unknown).
    public func processExited(_ id: UUID, code: Int32?, at date: Date? = nil) {
        guard var t = sessions[id] else { return }
        t.registration.process = .exited(code: code)
        t.exitedAt = date ?? clock.now()
        sessions[id] = t
        graceTasks.removeValue(forKey: id)?.cancel()
        recompute(id)
        scheduleFlush()
    }

    /// The holder reported a (new) child pid.
    public func childPidChanged(_ id: UUID, pid: Int?) {
        guard var t = sessions[id], t.registration.claudePid != pid else { return }
        t.registration.claudePid = pid
        sessions[id] = t
        recompute(id)
        scheduleFlush()
    }

    /// The user looked at the session (clears `done`).
    public func setLastViewed(_ id: UUID, at date: Date) {
        guard var t = sessions[id] else { return }
        t.registration.lastViewedAt = date
        sessions[id] = t
        recompute(id)
        scheduleFlush()
    }

    // MARK: - Inputs

    /// One hook delivery from ``HookServer/events``.
    public func ingest(_ event: HookEvent) {
        guard var t = sessions[event.sessionID] else {
            orphanEvents.append(event)
            if orphanEvents.count > configuration.maxOrphanEvents {
                orphanEvents.removeFirst(orphanEvents.count - configuration.maxOrphanEvents)
            }
            return
        }
        apply(event, to: &t)
        sessions[event.sessionID] = t
        recompute(event.sessionID)
        scheduleFlush()
    }

    /// A snapshot from ``RegistryWatcher/snapshots`` (live entries only).
    public func ingestRegistry(_ snapshot: RegistrySnapshot) {
        guard snapshot.entries != registry else { return }
        registry = snapshot.entries
        for (id, t) in sessions where t.registration.kind == .claude { recompute(id) }
        scheduleFlush()
    }

    /// A holder TITLE frame (raw OSC 0/2 title). Spinner flips are filtered out.
    public func ingestTitle(_ raw: String, for id: UUID) {
        guard var t = sessions[id] else { return }
        let previous = t.title.current?.activity
        guard let parsed = t.title.ingest(raw) else { return }
        if parsed.activity != previous { t.titleActivitySince = clock.now() }
        sessions[id] = t
        recompute(id)
        scheduleFlush()
    }

    // MARK: - Queries

    public func update(for id: UUID) -> SessionStateUpdate? {
        sessions[id]?.current
    }

    public func allUpdates() -> [SessionStateUpdate] {
        sessions.values.compactMap(\.current).sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    /// Emits the pending batch now and writes pending hook records (app quit, tests).
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        emit()
        persister?.flush()
    }

    /// Deletes persisted hook records of sessions not in `keeping`.
    public func pruneHookStates(keeping: Set<UUID>) {
        persister?.prune(keeping: keeping)
    }

    /// Ends ``updates`` after a final flush.
    public func finish() {
        flush()
        for task in graceTasks.values { task.cancel() }
        graceTasks.removeAll()
        continuation.finish()
    }

    /// Hook-file writes so far and the last write error (diagnostics, tests).
    public func persistenceStatistics() -> (writes: Int, lastError: String?) {
        persister?.statistics() ?? (0, nil)
    }

    // MARK: - Internals

    private func reducer(for t: Tracked) -> HookReducer {
        HookReducer(dialect: configuration.dialect, configDir: t.registration.configDir ?? configuration.defaultConfigDir)
    }

    private func apply(_ event: HookEvent, to t: inout Tracked) {
        let reducer = reducer(for: t)
        var prev = t.hook
        if t.baselinePending { prev = reducer.relaunchBaseline(prev, now: event.receivedAt) }
        // nil: an event of a nested `claude -p` (another Claude session id) — ignored, as in CODD web.
        guard let next = reducer.apply(prev, event.payload, terminalId: Self.terminalId(event.sessionID), now: event.receivedAt) else {
            return
        }
        t.baselinePending = false
        t.hookSeen = true
        if let s = next.state, s != .idle, s != .ended { t.sawTurn = true }
        guard next != t.hook else { return }
        t.hook = next
        persister?.schedule(event.sessionID, next)
    }

    static func terminalId(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private func recompute(_ id: UUID) {
        guard var t = sessions[id] else { return }
        let update = compute(id, &t, now: clock.now())
        t.current = update
        sessions[id] = t
        if update != t.lastEmitted { dirty.insert(id) } else { dirty.remove(id) }
    }

    private func compute(_ id: UUID, _ t: inout Tracked, now: Date) -> SessionStateUpdate {
        let reg = t.registration
        let hook = t.baselinePending ? nil : t.hook
        let process: ActivityContext.Process
        if case .exited = reg.process { process = .exited(at: t.exitedAt) } else { process = .running }
        var activity: SessionActivity
        var matched: ClaudeRegistryEntry?
        if reg.kind == .claude {
            let context = ActivityContext(terminalId: Self.terminalId(id), pid: reg.claudePid,
                                          claudeSessionId: reg.claudeSessionId, process: process)
            activity = merger.merge(context: context, hook: hook, registry: registry)
            let sessionId = JSText.nonBlankTrimmed(hook?.sessionId) ?? JSText.nonBlankTrimmed(reg.claudeSessionId)
            matched = ClaudeRegistryReader.match(registry, pid: reg.claudePid, sessionId: sessionId)
            if activity.state == .unknown, case .running(let startedAt) = reg.process,
               now.timeIntervalSince(startedAt) >= t.startingGrace,
               let glyph = t.title.current?.activity {
                activity.state = glyph == .busy ? .busy : .idle
                activity.since = t.titleActivitySince.map(JSDate.isoString)
            }
            switch activity.state {
            case .busy, .waiting, .error, .compacting: t.sawTurn = true
            default: break
            }
        } else {
            activity = SessionActivity(state: .unknown)
        }
        let hasHadTurn = t.sawTurn
        let state = SessionStateResolver.resolve(
            .init(kind: reg.kind, process: reg.process, activity: activity, lastViewedAt: reg.lastViewedAt, hasHadTurn: hasHadTurn,
                  startingGrace: t.startingGrace),
            now: now)
        return SessionStateUpdate(
            sessionID: id, state: state, activity: activity, hook: hook, hookSeen: t.hookSeen,
            title: t.title.current, registry: matched)
    }

    /// `starting` turns into `unknown` (or a title-derived state) when the grace period ends, with
    /// no event to trigger it, so a timer re-evaluates the session then.
    private func armGraceTimer(_ id: UUID) {
        graceTasks.removeValue(forKey: id)?.cancel()
        guard let t = sessions[id], t.registration.kind == .claude,
              case .running(let startedAt) = t.registration.process else { return }
        let deadline = startedAt.addingTimeInterval(t.startingGrace)
        guard deadline > clock.now() else { return }
        let clock = clock
        graceTasks[id] = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.graceExpired(id)
        }
    }

    private func graceExpired(_ id: UUID) {
        graceTasks[id] = nil
        recompute(id)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !dirty.isEmpty || !removedPending.isEmpty, flushTask == nil else { return }
        let interval = Self.seconds(configuration.batchInterval)
        let now = clock.now()
        guard let last = lastFlushAt, now.timeIntervalSince(last) < interval else {
            emit() // first change after a quiet period: no added latency
            return
        }
        let deadline = last.addingTimeInterval(interval)
        let clock = clock
        flushTask = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            await self?.timerFlush()
        }
    }

    private func timerFlush() {
        flushTask = nil
        emit()
    }

    private func emit() {
        guard !dirty.isEmpty || !removedPending.isEmpty else { return }
        lastFlushAt = clock.now()
        var out: [SessionStateUpdate] = []
        for id in dirty.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard var t = sessions[id], let current = t.current else { continue }
            t.lastEmitted = current
            sessions[id] = t
            out.append(current)
        }
        let removed = removedPending
        dirty.removeAll()
        removedPending.removeAll()
        if out.isEmpty && removed.isEmpty { return }
        continuation.yield(SessionStateBatch(updates: out, removed: removed))
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        let c = d.components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
