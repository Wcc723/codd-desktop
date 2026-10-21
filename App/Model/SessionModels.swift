import Foundation
import Observation

/// Stable identifiers. Plain strings so a real store can use UUIDs or registry ids.
typealias SessionID = String
typealias ProjectID = String
typealias GroupID = String
typealias AccountID = String

/// Session state model (design/SPEC.md §3). Glyph, color and labels live in `StateStyle`.
enum SessionState: String, CaseIterable, Sendable {
    case waiting, error, done, busy, compacting, idle, starting, unknown, shell, exited, stopped

    /// Waiting and error need the user (rail badge, Dock badge, menu bar icon).
    var needsAttention: Bool { self == .waiting || self == .error }
    /// Generating, running tools or compacting (status bar `● n`).
    var isWorking: Bool { self == .busy || self == .compacting }
    /// The PTY (or the external process) is still alive.
    var isLive: Bool { self != .exited && self != .stopped }
}

/// What a waiting session is waiting for.
enum WaitingReason: String, Sendable {
    case permission, question, plan, other
}

/// The 8 Claude Code `/color` names. "No color" is `nil` wherever a tag is optional.
enum TagColor: String, CaseIterable, Sendable {
    case red, blue, green, yellow, purple, orange, pink, cyan
}

enum SessionKind: Sendable {
    /// `claude` CLI in a PTY.
    case claude
    /// Plain zsh in the project's cwd (glyph `$`).
    case shell
}

/// One Claude Code (or shell) session. Each property is observed separately, so a cell that
/// shows only `state` and `title` is not invalidated by a cost or context update.
@MainActor @Observable
final class SessionVM: Identifiable {
    let id: SessionID
    var projectID: ProjectID
    var kind: SessionKind
    var title: String
    var state: SessionState
    var waitingReason: WaitingReason?
    /// Short uppercase reason for errors, e.g. `OVERLOADED`, `RATE LIMIT`, `AUTH`.
    var errorReason: String?
    /// Tool currently running (busy) or asking (waiting), e.g. `Bash`, `Edit`.
    var tool: String?
    /// Tool argument or question text, e.g. `npm test -- auth.spec.ts`.
    var detail: String?
    /// AskUserQuestion choices (answer bar keys 1…n); empty for permission prompts.
    var answerOptions: [String] = []
    /// When the session entered `state` (drives the duration labels).
    var stateSince: Date
    /// Process start (drives `UP x`); nil when not running in this app run.
    var startedAt: Date?
    var exitCode: Int32?
    var tag: TagColor?
    var branch: String?
    var model: String?
    var contextPercent: Int?
    var costUSD: Double?
    var accountID: AccountID?
    /// Account fixed via `cswap run` (not following the global login).
    var accountPinned: Bool
    var remoteControl: Bool
    /// D6: a claude CODD did not start, seen in Claude's registry (`<claudeDir>/sessions`);
    /// read-only (no terminal, no answer bar). Nil for every CODD session.
    var externalInfo: ExternalInfo?
    /// Detected outside CODD (the cells read this Bool; true exactly when `externalInfo` is set).
    var external: Bool { externalInfo != nil }
    /// D15: IDLE for longer than the store's stale limit (1 h); the row is dimmed.
    var isStale: Bool
    var notesCount: Int
    var isPinned: Bool
    var pid: Int32?
    /// Last BEL from the session's PTY or one of its shell tabs (real mode; nothing draws it yet).
    var lastBellAt: Date?
    /// Why the last start failed (`claude` not found, holder did not come up), in 繁體中文; the
    /// pane shows it as an error banner until the next start.
    var launchError: String?
    /// The Claude conversation `claude --resume` continues (the latest hook `session_id`; it
    /// differs from `id` after `/clear` or RESTART). Nil for shells and mock sessions.
    var claudeSessionID: String?
    /// D8: since when its live holder has not answered (reconnects or a handshake failing for
    /// 5 s while meta.json says the holder runs). An overlay on `state`, not a state of its own:
    /// hook states keep arriving while the socket does not. Nil when reachable.
    var unreachableSince: Date?
    /// D20: the latest prompt the user sent (the `UserPromptSubmit` hook's `prompt`, one line,
    /// at most 200 characters). Memory only; the transcript's `last-prompt` is the fallback.
    /// A display form: never resend it (see `resendPrompt`).
    var lastPrompt: String?
    /// D26: the same prompt whole, as the hook delivered it (newlines kept, never cut), for
    /// `↻ 重送上一則` / `⟲ 稍後自動重試`; nil when only the display form is known or it is longer
    /// than one composer send (256 KiB). Memory only; the transcript's newest prompt is the fallback.
    var resendPrompt: String?

    init(id: SessionID, projectID: ProjectID, kind: SessionKind = .claude, title: String,
         state: SessionState, stateSince: Date) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.title = title
        self.state = state
        self.stateSince = stateSince
        self.accountPinned = false
        self.remoteControl = false
        self.isStale = false
        self.notesCount = 0
        self.isPinned = false
    }
}

/// What CODD knows about an external claude (D6, D27): registry facts plus, for one started by
/// hand inside a CODD shell, that shell (`在 CODD shell 中`, `[前往 shell]`).
struct ExternalInfo: Equatable, Sendable {
    var pid: Int32
    /// Registry `kind` (`interactive`, `daemon-worker`, …).
    var kind: String?
    /// Registry `entrypoint` (`cli`, `claude-vscode`, …).
    var entrypoint: String?
    /// The conversation it runs now (changes with `/clear`; the row id does not).
    var claudeSessionID: String?
    var version: String?
    /// The CODD session whose shell (its own PTY, or one of its shell tabs) runs this claude.
    var hostSessionID: SessionID?
    /// The shell tab of `hostSessionID` (nil: the session's own PTY).
    var hostTabID: String?

    init(pid: Int32, kind: String? = nil, entrypoint: String? = nil, claudeSessionID: String? = nil, version: String? = nil,
         hostSessionID: SessionID? = nil, hostTabID: String? = nil) {
        self.pid = pid
        self.kind = kind
        self.entrypoint = entrypoint
        self.claudeSessionID = claudeSessionID
        self.version = version
        self.hostSessionID = hostSessionID
        self.hostTabID = hostTabID
    }

    /// Sidebar line 2 (SidebarStates E): `外部啟動`, `外部啟動 · bg` for a background worker, or
    /// `在 CODD shell 中` when one of CODD's shells is its ancestor.
    var rowLabel: String {
        if hostSessionID != nil { return "在 CODD shell 中" }
        return kind == "daemon-worker" ? "外部啟動 · bg" : "外部啟動"
    }
}

/// A project = one cwd. Sessions reorder only within their project.
@MainActor @Observable
final class ProjectVM: Identifiable {
    let id: ProjectID
    var name: String
    var cwd: String
    var groupID: GroupID
    var sessionIDs: [SessionID]
    /// Archived transcripts (shown as `封存 n` when there is no live session).
    var archivedCount: Int
    var isCollapsed: Bool
    /// D6: a folder CODD does not know that an external claude runs in. Lives in 未分類 while it
    /// has externals, is never saved, and becomes a real project when a CODD session is created
    /// there or the user picks `加入為專案`.
    var isTransient = false

    init(id: ProjectID, name: String, cwd: String, groupID: GroupID, sessionIDs: [SessionID],
         archivedCount: Int = 0, isCollapsed: Bool = false) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.groupID = groupID
        self.sessionIDs = sessionIDs
        self.archivedCount = archivedCount
        self.isCollapsed = isCollapsed
    }
}

/// A user group (one level). The ungrouped bucket is a group with `isUngrouped == true`.
@MainActor @Observable
final class GroupVM: Identifiable {
    let id: GroupID
    var name: String
    /// Short form for breadcrumbs, e.g. `藍鵲·網站`.
    var shortName: String
    var color: TagColor?
    var projectIDs: [ProjectID]
    var isCollapsed: Bool
    let isUngrouped: Bool

    init(id: GroupID, name: String, shortName: String, color: TagColor?, projectIDs: [ProjectID],
         isCollapsed: Bool = false, isUngrouped: Bool = false) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.color = color
        self.projectIDs = projectIDs
        self.isCollapsed = isCollapsed
        self.isUngrouped = isUngrouped
    }
}
