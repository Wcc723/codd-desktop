import Foundation

/// The per-terminal hook state record: the v2 `<terminal-id>.hook.json` document written by
/// CODD web's status-writer.js, plus a few desktop-only fields.
///
/// Timestamps are kept as the ISO strings the original writes (`toISOString()`), so a record
/// round-trips byte-for-byte with files produced by the web app; use the `…Date` accessors for
/// `Date` values. Decoding is tolerant: a field of the wrong type decodes as `nil` (the original
/// passes such values through unchanged; CoddCore drops them — only garbage files differ).
public struct HookSessionState: Sendable, Equatable {
    /// File format version written by status-writer.js.
    public static let formatVersion = 2

    /// `codd_terminal_id` — the PTY / CODD session id this record belongs to.
    public var terminalId: String?
    /// `config_dir` — the `CLAUDE_CONFIG_DIR` the session runs with.
    public var configDir: String?
    /// `session_id` — the current Claude session id (changes on /clear, /resume, fork).
    public var sessionId: String?
    public var transcriptPath: String?
    public var cwd: String?
    /// `event` — the last hook event name seen.
    public var event: String?
    public var state: HookActivityState?
    /// `state_since` (ISO string).
    public var stateSince: String?
    public var waitingReason: WaitingReason?
    /// `last_event_at` (ISO string).
    public var lastEventAt: String?
    public var lastTool: String?
    /// `tool_count`. `nil` when the stored value was not a non-negative integer.
    public var toolCount: Int?
    public var lastPrompt: String?
    /// `last_prompt_at` (ISO string).
    public var lastPromptAt: String?
    public var customTitle: String?

    // MARK: Desktop extensions (never written by the web dialect)

    /// `error_kind` — StopFailure error type while `state == .error`.
    public var errorKind: HookErrorKind?
    /// `error_detail` — cleaned `error_details` / `last_assistant_message` while `state == .error`.
    public var errorDetail: String?
    /// `compact_trigger` — `manual` / `auto` while `state == .compacting`.
    public var compactTrigger: String?
    /// `state_before_compact` — state to restore after an automatic compaction.
    public var stateBeforeCompact: HookActivityState?
    /// `subagents_active` — SubagentStart minus SubagentStop (never negative).
    public var subagentsActive: Int?

    public init(
        terminalId: String? = nil, configDir: String? = nil, sessionId: String? = nil,
        transcriptPath: String? = nil, cwd: String? = nil, event: String? = nil,
        state: HookActivityState? = nil, stateSince: String? = nil, waitingReason: WaitingReason? = nil,
        lastEventAt: String? = nil, lastTool: String? = nil, toolCount: Int? = 0,
        lastPrompt: String? = nil, lastPromptAt: String? = nil, customTitle: String? = nil
    ) {
        self.terminalId = terminalId
        self.configDir = configDir
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.event = event
        self.state = state
        self.stateSince = stateSince
        self.waitingReason = waitingReason
        self.lastEventAt = lastEventAt
        self.lastTool = lastTool
        self.toolCount = toolCount
        self.lastPrompt = lastPrompt
        self.lastPromptAt = lastPromptAt
        self.customTitle = customTitle
    }

    public var stateSinceDate: Date? { JSDate.date(fromISO: stateSince) }
    public var lastEventDate: Date? { JSDate.date(fromISO: lastEventAt) }
    public var lastPromptDate: Date? { JSDate.date(fromISO: lastPromptAt) }
}

extension HookSessionState: Codable {
    enum CodingKeys: String, CodingKey {
        case v
        case terminalId = "codd_terminal_id"
        case configDir = "config_dir"
        case sessionId = "session_id"
        case transcriptPath = "transcript_path"
        case cwd, event, state
        case stateSince = "state_since"
        case waitingReason = "waiting_reason"
        case lastEventAt = "last_event_at"
        case lastTool = "last_tool"
        case toolCount = "tool_count"
        case lastPrompt = "last_prompt"
        case lastPromptAt = "last_prompt_at"
        case customTitle = "custom_title"
        case errorKind = "error_kind"
        case errorDetail = "error_detail"
        case compactTrigger = "compact_trigger"
        case stateBeforeCompact = "state_before_compact"
        case subagentsActive = "subagents_active"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminalId = c.lenient(String.self, forKey: .terminalId)
        configDir = c.lenient(String.self, forKey: .configDir)
        sessionId = c.lenient(String.self, forKey: .sessionId)
        transcriptPath = c.lenient(String.self, forKey: .transcriptPath)
        cwd = c.lenient(String.self, forKey: .cwd)
        event = c.lenient(String.self, forKey: .event)
        state = c.lenient(String.self, forKey: .state).flatMap(HookActivityState.init(rawValue:))
        stateSince = c.lenient(String.self, forKey: .stateSince)
        waitingReason = c.lenient(String.self, forKey: .waitingReason).flatMap(WaitingReason.init(rawValue:))
        lastEventAt = c.lenient(String.self, forKey: .lastEventAt)
        lastTool = c.lenient(String.self, forKey: .lastTool)
        toolCount = c.lenient(JSONValue.self, forKey: .toolCount)?.nonNegativeIntegerValue
        lastPrompt = c.lenient(String.self, forKey: .lastPrompt)
        lastPromptAt = c.lenient(String.self, forKey: .lastPromptAt)
        customTitle = c.lenient(String.self, forKey: .customTitle)
        errorKind = c.lenient(String.self, forKey: .errorKind).map { HookErrorKind(hookValue: $0) }
        errorDetail = c.lenient(String.self, forKey: .errorDetail)
        compactTrigger = c.lenient(String.self, forKey: .compactTrigger)
        stateBeforeCompact = c.lenient(String.self, forKey: .stateBeforeCompact).flatMap(HookActivityState.init(rawValue:))
        subagentsActive = c.lenient(JSONValue.self, forKey: .subagentsActive)?.nonNegativeIntegerValue
    }

    /// Encodes every v2 field (writing `null` like the original) and the desktop fields only when set.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.formatVersion, forKey: .v)
        try c.encode(terminalId, forKey: .terminalId)
        try c.encode(configDir, forKey: .configDir)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(transcriptPath, forKey: .transcriptPath)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(event, forKey: .event)
        try c.encode(state?.rawValue, forKey: .state)
        try c.encode(stateSince, forKey: .stateSince)
        try c.encode(waitingReason?.rawValue, forKey: .waitingReason)
        try c.encode(lastEventAt, forKey: .lastEventAt)
        try c.encode(lastTool, forKey: .lastTool)
        try c.encode(toolCount ?? 0, forKey: .toolCount)
        try c.encode(lastPrompt, forKey: .lastPrompt)
        try c.encode(lastPromptAt, forKey: .lastPromptAt)
        try c.encode(customTitle, forKey: .customTitle)
        try c.encodeIfPresent(errorKind, forKey: .errorKind)
        try c.encodeIfPresent(errorDetail, forKey: .errorDetail)
        try c.encodeIfPresent(compactTrigger, forKey: .compactTrigger)
        try c.encodeIfPresent(stateBeforeCompact?.rawValue, forKey: .stateBeforeCompact)
        try c.encodeIfPresent(subagentsActive, forKey: .subagentsActive)
    }
}
