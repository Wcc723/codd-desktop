import Foundation

/// Merged activity state of one session (session-insights.js `activity`).
public enum ActivityState: String, Sendable, Codable, CaseIterable {
    case busy, waiting, idle, ended, unknown
    /// Desktop dialect only.
    case error, compacting
}

/// Where the merged state came from.
public enum ActivitySource: String, Sendable, Codable {
    case hook, registry
}

/// The result of merging hook state, the Claude registry and the process status.
public struct SessionActivity: Sendable, Equatable {
    public var state: ActivityState
    /// When the state began (ISO string, `toISOString()` format).
    public var since: String?
    /// Waiting reason (only with `state == .waiting`).
    public var reason: WaitingReason?
    /// Desktop dialect: StopFailure error type (only with `state == .error`).
    public var errorKind: HookErrorKind?
    public var lastTool: String?
    public var toolCount: Int?
    public var source: ActivitySource?

    public init(
        state: ActivityState, since: String? = nil, reason: WaitingReason? = nil, errorKind: HookErrorKind? = nil,
        lastTool: String? = nil, toolCount: Int? = nil, source: ActivitySource? = nil
    ) {
        self.state = state
        self.since = since
        self.reason = reason
        self.errorKind = errorKind
        self.lastTool = lastTool
        self.toolCount = toolCount
        self.source = source
    }

    public var sinceDate: Date? { JSDate.date(fromISO: since) }
}

extension SessionActivity: Codable {
    enum CodingKeys: String, CodingKey {
        case state, since, reason, source
        case errorKind = "error_kind"
        case lastTool = "last_tool"
        case toolCount = "tool_count"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.lenient(String.self, forKey: .state).flatMap(ActivityState.init(rawValue:)) ?? .unknown
        since = c.lenient(String.self, forKey: .since)
        reason = c.lenient(String.self, forKey: .reason).flatMap(WaitingReason.init(rawValue:))
        errorKind = c.lenient(String.self, forKey: .errorKind).map { HookErrorKind(hookValue: $0) }
        lastTool = c.lenient(String.self, forKey: .lastTool)
        toolCount = c.lenient(Int.self, forKey: .toolCount)
        source = c.lenient(String.self, forKey: .source).flatMap(ActivitySource.init(rawValue:))
    }

    /// Same keys as the original `activity` object (`null` for absent values); `error_kind` only
    /// when set.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state.rawValue, forKey: .state)
        try c.encode(since, forKey: .since)
        try c.encode(reason?.rawValue, forKey: .reason)
        try c.encode(lastTool, forKey: .lastTool)
        try c.encode(toolCount, forKey: .toolCount)
        try c.encode(source?.rawValue, forKey: .source)
        try c.encodeIfPresent(errorKind, forKey: .errorKind)
    }
}

/// What the merger needs to know about the session's process (the PTY record in CODD web).
public struct ActivityContext: Sendable, Equatable {
    public enum Process: Sendable, Equatable {
        case running
        case exited(at: Date?)
    }

    /// The CODD session / terminal id hook records must belong to.
    public var terminalId: String?
    /// The child pid (the `claude` process), used to match the registry.
    public var pid: Int?
    /// Fallback Claude session id (CODD web `rec.claude_session_id`; desktop: the launch `--session-id`).
    public var claudeSessionId: String?
    public var process: Process

    public init(terminalId: String?, pid: Int?, claudeSessionId: String? = nil, process: Process) {
        self.terminalId = terminalId
        self.pid = pid
        self.claudeSessionId = claudeSessionId
        self.process = process
    }
}

/// Port of session-insights.js `_activity` (with the hook/registry lookup of `_enrichRecord`).
///
/// Rules (web dialect, exact): an exited process is `ended`; otherwise a hook record with a known
/// state wins (`ended` while the process lives → `idle`), except that a registry `busy`/`idle` that
/// differs and is more than 1 s newer than the hook's `last_event_at` overrides it (covers Esc
/// interrupts, approved permissions and mid-turn compaction, which fire no hook). Without hook state
/// the registry status is used (`unknown` for unrecognised values); with neither, `unknown`.
///
/// Desktop extensions: hook states `error` and `compacting` are recognised; `error` can only be
/// overridden by a newer registry `busy` (a failed turn stays visible), `compacting` only by a
/// newer registry `idle` (registry `busy` during compaction is expected); a registry-only
/// `waiting` carries a reason derived from `waitingFor` (critic.md C3), defaulting to `other`.
public struct ActivityMerger: Sendable {
    /// Registry must be newer than the hook by more than this to override it.
    public static let registryNewerMarginMilliseconds: Int64 = 1000

    public var dialect: HookDialect

    public init(dialect: HookDialect = .desktop) {
        self.dialect = dialect
    }

    /// Merges. `hook` is the session's hook record if any (ignored unless it belongs to
    /// `context.terminalId`); `registry` are the LIVE entries (``ClaudeRegistryReader/liveEntries(_:liveness:)``)
    /// of the relevant registry directories in priority order.
    public func merge(
        context: ActivityContext, hook rawHook: HookSessionState?, registry: [ClaudeRegistryEntry]
    ) -> SessionActivity {
        let hook = rawHook.flatMap { h in
            h.terminalId == nil || h.terminalId == context.terminalId ? h : nil
        }
        let claudeSessionId = JSText.nonBlankTrimmed(hook?.sessionId) ?? JSText.nonBlankTrimmed(context.claudeSessionId)
        let hookTool = JSText.nonBlankTrimmed(hook?.lastTool)
        let toolCount = hook?.toolCount

        if case .exited(let at) = context.process {
            return SessionActivity(
                state: .ended, since: at.map(JSDate.isoString), lastTool: hookTool, toolCount: toolCount, source: nil
            )
        }
        let reg = ClaudeRegistryReader.match(registry, pid: context.pid, sessionId: claudeSessionId)

        if let hook, let hookState = hook.state, isKnown(hookState) {
            let state: ActivityState = hookState == .ended ? .idle : ActivityState(hookState)
            var activity = SessionActivity(
                state: state,
                since: JSDate.toISO(hook.stateSince.map(JSONValue.string)),
                reason: state == .waiting ? hook.waitingReason.flatMap(webReason) : nil,
                errorKind: state == .error ? (hook.errorKind ?? .unknown) : nil,
                lastTool: hookTool,
                toolCount: toolCount,
                source: .hook
            )
            if hookState != .ended, let reg, let regState = reg.statusValue,
               let regAt = reg.statusTimestampMilliseconds,
               let regISO = JSDate.isoString(milliseconds: regAt),
               let hookAt = hook.lastEventAt.flatMap({ JSDate.parse($0) }),
               regAt > hookAt + Self.registryNewerMarginMilliseconds,
               let reconciled = reconcileTarget(hook: state, registry: regState) {
                activity.state = reconciled
                activity.reason = nil
                activity.errorKind = nil
                activity.since = regISO
                activity.source = .registry
            }
            return activity
        }

        if let reg {
            let state: ActivityState
            switch reg.statusValue {
            case .busy?: state = .busy
            case .idle?: state = .idle
            case .waiting?: state = .waiting
            case nil: state = .unknown
            }
            let reason: WaitingReason? = (dialect == .desktop && state == .waiting)
                ? RegistryStatus.waitingReason(forWaitingFor: reg.waitingFor) : nil
            return SessionActivity(
                state: state,
                since: reg.statusTimestampMilliseconds.flatMap { JSDate.isoString(milliseconds: $0) },
                reason: reason, lastTool: hookTool, toolCount: toolCount, source: .registry
            )
        }
        return SessionActivity(state: .unknown, lastTool: hookTool, toolCount: toolCount, source: nil)
    }

    /// STATES = busy/waiting/idle/ended (+ error/compacting on desktop).
    private func isKnown(_ s: HookActivityState) -> Bool {
        switch s {
        case .busy, .waiting, .idle, .ended: return true
        case .error, .compacting: return dialect == .desktop
        }
    }

    /// REASONS = permission/question/plan (`other` never comes from hooks).
    private func webReason(_ r: WaitingReason) -> WaitingReason? {
        r == .other ? nil : r
    }

    /// REGISTRY_RECONCILE_TO = busy/idle, only when different from the hook state.
    private func reconcileTarget(hook: ActivityState, registry: RegistryStatus) -> ActivityState? {
        let target: ActivityState
        switch registry {
        case .busy: target = .busy
        case .idle: target = .idle
        case .waiting: return nil
        }
        guard target != hook else { return nil }
        if dialect == .desktop {
            if hook == .error && target != .busy { return nil }
            if hook == .compacting && target != .idle { return nil }
        }
        return target
    }
}

extension ActivityState {
    init(_ s: HookActivityState) {
        switch s {
        case .busy: self = .busy
        case .waiting: self = .waiting
        case .idle: self = .idle
        case .ended: self = .ended
        case .error: self = .error
        case .compacting: self = .compacting
        }
    }
}
