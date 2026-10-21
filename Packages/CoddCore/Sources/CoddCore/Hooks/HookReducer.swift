import Foundation

/// Which rule set ``HookReducer`` and ``ActivityMerger`` apply.
public enum HookDialect: Sendable, Equatable {
    /// Byte-for-byte the CODD web behaviour (status-writer.js `applyEvent`,
    /// session-insights.js `_activity`). Verified by the golden fixtures.
    case web
    /// The web behaviour plus the documented desktop extensions (see ``HookReducer``).
    case desktop
}

/// Port of `applyEvent(prev, p, terminalId, now)` from CODD web `configs/hooks/status-writer.js`.
///
/// In the ``HookDialect/web`` dialect the output equals the original for every input
/// (golden-tested by executing the JS). The ``HookDialect/desktop`` dialect adds:
///
/// 1. `StopFailure` → `state = error` with `error_kind` (the `error` enum) and `error_detail`.
///    The original maps it to `idle`.
/// 2. `PreCompact` → `state = compacting` (remembering the prior state); `PostCompact` restores
///    it: `manual` → `idle`, `auto` → the prior state when it was `busy`/`idle`, else `busy`.
///    `SessionStart` with source `compact` while compacting ends compaction the same way (so a
///    lost PostCompact cannot leave the session stuck); otherwise it keeps the state, as in the
///    original. The original ignores PreCompact / PostCompact.
/// 3. `Notification idle_prompt` does not downgrade `error` to `idle`, so a failed turn stays
///    visible until the user acts. (The original sets `idle`.)
/// 4. `SubagentStart` / `SubagentStop` maintain `subagents_active`; the state is unchanged, as in
///    the original. The counter resets on a new Claude session and on non-compact SessionStart.
///
/// Leaving `error` or `compacting` (any other state transition) clears the extension fields.
public struct HookReducer: Sendable {
    public static let promptMax = 500
    public static let titleMax = 200

    public var dialect: HookDialect
    /// Written as `config_dir` (the original writes the hook process's `CLAUDE_CONFIG_DIR`, or
    /// `~/.claude`; the desktop agent passes the session's configured directory).
    public var configDir: String?

    public init(dialect: HookDialect = .desktop, configDir: String?) {
        self.dialect = dialect
        self.configDir = configDir
    }

    /// Applies one hook event. `prev == nil` is an absent or unreadable state file (`{}` in the
    /// original). Returns `nil` when the event must be ignored (an event from another Claude
    /// session — typically a nested `claude -p` — that is not a `/clear` or fork takeover).
    public func apply(
        _ prev: HookSessionState?, _ payload: HookPayload, terminalId: String, now: Date
    ) -> HookSessionState? {
        apply(prev, payload, terminalId: terminalId, nowISO: JSDate.isoString(now))
    }

    /// ``apply(_:_:terminalId:now:)`` with `now` already formatted (`toISOString()`).
    public func apply(
        _ prev: HookSessionState?, _ payload: HookPayload, terminalId: String, nowISO now: String
    ) -> HookSessionState? {
        let p = prev ?? HookSessionState(toolCount: nil)
        let event = payload.eventName
        let sessionId = payload.sessionId

        // Nested claude processes inherit the terminal id. Only /clear (SessionStart clear) and
        // /branch (SessionStart fork) may switch the session id while the previous one is not ended.
        if let prevSid = p.sessionId, !prevSid.isEmpty, let sid = sessionId, sid != prevSid, p.state != .ended {
            let takeover = event == HookEventName.sessionStart.rawValue
                && (payload.sourceIs("clear") || payload.sourceIs("fork"))
            if !takeover { return nil }
        }
        let sameSession = sessionId == nil || sessionId == p.sessionId

        var next = HookSessionState(
            terminalId: terminalId,
            configDir: configDir,
            sessionId: sessionId ?? p.sessionId,
            transcriptPath: payload.transcriptPath ?? (sameSession ? p.transcriptPath : nil),
            cwd: payload.cwd ?? p.cwd,
            event: event ?? p.event,
            state: p.state,
            stateSince: p.stateSince,
            waitingReason: p.waitingReason,
            lastEventAt: now,
            lastTool: p.lastTool,
            toolCount: p.toolCount ?? 0,
            lastPrompt: sameSession ? p.lastPrompt : nil,
            lastPromptAt: sameSession ? p.lastPromptAt : nil,
            customTitle: sameSession ? p.customTitle : nil
        )
        if dialect == .desktop {
            next.errorKind = p.errorKind
            next.errorDetail = p.errorDetail
            next.compactTrigger = p.compactTrigger
            next.stateBeforeCompact = p.stateBeforeCompact
            next.subagentsActive = sameSession ? p.subagentsActive : nil
        }

        let tool = payload.toolName
        let sessionTitle = JSText.cleanText(payload.raw["session_title"], max: Self.titleMax)

        switch event.flatMap(HookEventName.init(rawValue:)) {
        case .sessionStart?:
            // Auto-compaction can happen mid-turn: keep the current state and let the next event decide.
            if !payload.sourceIs("compact") || p.state == nil {
                setState(&next, prev: p, .idle, reason: nil, now: now)
                if dialect == .desktop { next.subagentsActive = nil }
            } else if dialect == .desktop, p.state == .compacting {
                // SessionStart(compact) fires once the compacted context is in place. Treat it as the
                // end of compaction too, so a lost or unsupported PostCompact cannot leave the
                // session stuck in `compacting` (the order of the two events is undocumented; either
                // order ends in the same state).
                endCompaction(&next, prev: p, trigger: p.compactTrigger, now: now)
            }
            if let sessionTitle { next.customTitle = sessionTitle }
            if payload.sourceIs("clear") { next.toolCount = 0 }

        case .userPromptSubmit?:
            setState(&next, prev: p, .busy, reason: nil, now: now)
            if let prompt = JSText.cleanText(payload.raw["prompt"], max: Self.promptMax) {
                next.lastPrompt = prompt
                next.lastPromptAt = now
            }
            if let sessionTitle { next.customTitle = sessionTitle }

        case .preToolUse?:
            let reason = Self.toolWaitReason(tool)
            setState(&next, prev: p, reason == nil ? .busy : .waiting, reason: reason, now: now)
            if let tool { next.lastTool = tool }

        case .postToolUse?, .postToolUseFailure?:
            setState(&next, prev: p, .busy, reason: nil, now: now)
            if let tool { next.lastTool = tool }
            next.toolCount = (next.toolCount ?? 0) + 1

        case .permissionRequest?:
            setState(&next, prev: p, .waiting, reason: Self.toolWaitReason(tool) ?? .permission, now: now)
            if let tool { next.lastTool = tool }

        case .notification?:
            applyNotification(&next, prev: p, payload, now: now)

        case .stop?:
            setState(&next, prev: p, .idle, reason: nil, now: now)

        case .stopFailure?:
            if dialect == .desktop {
                setState(&next, prev: p, .error, reason: nil, now: now)
                next.errorKind = HookErrorKind(hookValue: payload.error)
                next.errorDetail = JSText.cleanText(payload.raw["error_details"], max: Self.titleMax)
                    ?? JSText.cleanText(payload.raw["last_assistant_message"], max: Self.titleMax)
            } else {
                setState(&next, prev: p, .idle, reason: nil, now: now)
            }

        case .sessionEnd?:
            setState(&next, prev: p, .ended, reason: nil, now: now)
            if dialect == .desktop { next.subagentsActive = nil }

        case .preCompact? where dialect == .desktop:
            let before = p.state == .compacting ? p.stateBeforeCompact : p.state
            setState(&next, prev: p, .compacting, reason: nil, now: now)
            next.stateBeforeCompact = before
            next.compactTrigger = payload.trigger

        case .postCompact? where dialect == .desktop:
            applyPostCompact(&next, prev: p, payload, now: now)

        case .subagentStart? where dialect == .desktop:
            next.subagentsActive = (next.subagentsActive ?? 0) + 1

        case .subagentStop? where dialect == .desktop:
            next.subagentsActive = max(0, (next.subagentsActive ?? 0) - 1)

        default:
            break
        }
        return next
    }

    /// The `prev` record to feed the FIRST event after CODD (re)starts claude for a terminal (a new
    /// holder, a reboot resume). The previous claude process is gone, possibly without a SessionEnd
    /// (crash, kill, reboot), so its record is marked `ended`. Without this, the nested-claude guard
    /// above would ignore EVERY event of the new process whenever it runs under a different Claude
    /// session id than the stale record (for example resuming another conversation in the same
    /// tab), and the state would stay frozen. The other fields are kept; they are dropped by the
    /// usual `sameSession` rule if the session id changes. Records already `ended` are unchanged.
    public func relaunchBaseline(_ prev: HookSessionState?, now: Date) -> HookSessionState? {
        guard var p = prev, p.state != .ended else { return prev }
        p.state = .ended
        p.stateSince = JSDate.isoString(now)
        p.waitingReason = nil
        if dialect == .desktop {
            p.errorKind = nil
            p.errorDetail = nil
            p.compactTrigger = nil
            p.stateBeforeCompact = nil
            p.subagentsActive = nil
        }
        return p
    }

    /// AskUserQuestion / ExitPlanMode mean "waiting for the user", not "busy".
    static func toolWaitReason(_ tool: String?) -> WaitingReason? {
        switch tool {
        case "AskUserQuestion"?: return .question
        case "ExitPlanMode"?: return .plan
        default: return nil
        }
    }

    private func applyNotification(
        _ next: inout HookSessionState, prev p: HookSessionState, _ payload: HookPayload, now: String
    ) {
        switch payload.notificationType {
        case "permission_prompt"?:
            setState(&next, prev: p, .waiting, reason: .permission, now: now)
        case "elicitation_dialog"?, "elicitation_url_dialog"?:
            setState(&next, prev: p, .waiting, reason: .question, now: now)
        case "idle_prompt"?:
            if dialect == .desktop, p.state == .error { return }
            setState(&next, prev: p, .idle, reason: nil, now: now)
        case nil:
            if JSText.containsCaseInsensitiveASCII(payload.message ?? "", "permission") {
                setState(&next, prev: p, .waiting, reason: .permission, now: now)
            }
        default:
            break
        }
    }

    private func applyPostCompact(
        _ next: inout HookSessionState, prev p: HookSessionState, _ payload: HookPayload, now: String
    ) {
        endCompaction(&next, prev: p, trigger: payload.trigger ?? p.compactTrigger, now: now)
    }

    /// `manual` → `idle` (the user ran /compact and it is their turn); otherwise, while compacting,
    /// the state before compaction when it was `busy`/`idle`, else `busy`.
    private func endCompaction(
        _ next: inout HookSessionState, prev p: HookSessionState, trigger: String?, now: String
    ) {
        if trigger == "manual" {
            setState(&next, prev: p, .idle, reason: nil, now: now)
        } else if p.state == .compacting {
            let restored: HookActivityState
            switch p.stateBeforeCompact {
            case .busy?, .idle?: restored = p.stateBeforeCompact ?? .busy
            default: restored = .busy
            }
            setState(&next, prev: p, restored, reason: nil, now: now)
        }
    }

    /// `setState(next, prev, state, reason, now)`.
    private func setState(
        _ next: inout HookSessionState, prev p: HookSessionState,
        _ state: HookActivityState, reason: WaitingReason?, now: String
    ) {
        next.state = state
        next.waitingReason = state == .waiting ? reason : nil
        if p.state != state || (next.stateSince ?? "").isEmpty { next.stateSince = now }
        guard dialect == .desktop else { return }
        if state != .error {
            next.errorKind = nil
            next.errorDetail = nil
        }
        if state != .compacting {
            next.compactTrigger = nil
            next.stateBeforeCompact = nil
        }
    }
}
