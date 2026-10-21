import Foundation

/// The user-visible session state (design/SPEC.md §3). Glyph and color are double-encoded; tags
/// never color lamps.
public enum SessionState: Sendable, Hashable {
    case waiting(WaitingReason)
    case error(HookErrorKind)
    /// Finished a turn while the user wasn't looking (unseen).
    case done
    case busy
    case compacting
    /// The user's turn, already seen.
    case idle
    /// Spawned, no hook data yet (< ``SessionStateResolver/startingGrace``).
    case starting
    /// Running, but no hook or registry data after the grace period.
    case unknown
    /// A plain shell tab with a live PTY.
    case shell
    /// The process ended during this run.
    case exited(code: Int32?)
    /// Persisted from an earlier run; resumable.
    case stopped

    /// SPEC §3 glyph.
    public var glyph: String {
        switch self {
        case .waiting: return "◆"
        case .error: return "▲"
        case .done: return "◇"
        case .busy, .unknown: return "●"
        case .compacting, .starting: return "◌"
        case .idle: return "○"
        case .shell: return "$"
        case .exited: return "✕"
        case .stopped: return "⟲"
        }
    }

    /// SPEC §3 pill label (English uppercase structural label).
    public var pillLabel: String {
        switch self {
        case .waiting: return "WAITING"
        case .error: return "ERROR"
        case .done: return "DONE"
        case .busy: return "BUSY"
        case .compacting: return "COMPACT"
        case .idle: return "IDLE"
        case .starting: return "START"
        case .unknown: return "—"
        case .shell: return "SHELL"
        case .exited: return "EXITED"
        case .stopped: return "STOPPED"
        }
    }

    /// CSS-equivalent class name from the design tokens (`st-waiting`, …).
    public var styleClass: String {
        switch self {
        case .waiting: return "st-waiting"
        case .error: return "st-error"
        case .done: return "st-done"
        case .busy: return "st-busy"
        case .compacting: return "st-compacting"
        case .idle: return "st-idle"
        case .starting: return "st-starting"
        case .unknown: return "st-unknown"
        case .shell: return "st-shell"
        case .exited: return "st-exited"
        case .stopped: return "st-stopped"
        }
    }

    /// Attention = waiting + error (rail badge, menu bar, NEEDS YOU).
    public var needsAttention: Bool {
        switch self {
        case .waiting, .error: return true
        default: return false
        }
    }
}

extension SessionState: Codable {
    private enum CodingKeys: String, CodingKey { case kind, reason, error, code }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "waiting":
            self = .waiting(c.lenient(String.self, forKey: .reason).flatMap(WaitingReason.init(rawValue:)) ?? .other)
        case "error":
            self = .error(HookErrorKind(hookValue: c.lenient(String.self, forKey: .error)))
        case "done": self = .done
        case "busy": self = .busy
        case "compacting": self = .compacting
        case "idle": self = .idle
        case "starting": self = .starting
        case "shell": self = .shell
        case "exited": self = .exited(code: c.lenient(Int32.self, forKey: .code))
        case "stopped": self = .stopped
        default: self = .unknown
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .waiting(let r):
            try c.encode("waiting", forKey: .kind)
            try c.encode(r.rawValue, forKey: .reason)
        case .error(let e):
            try c.encode("error", forKey: .kind)
            try c.encode(e.rawValue, forKey: .error)
        case .exited(let code):
            try c.encode("exited", forKey: .kind)
            try c.encodeIfPresent(code, forKey: .code)
        case .done: try c.encode("done", forKey: .kind)
        case .busy: try c.encode("busy", forKey: .kind)
        case .compacting: try c.encode("compacting", forKey: .kind)
        case .idle: try c.encode("idle", forKey: .kind)
        case .starting: try c.encode("starting", forKey: .kind)
        case .unknown: try c.encode("unknown", forKey: .kind)
        case .shell: try c.encode("shell", forKey: .kind)
        case .stopped: try c.encode("stopped", forKey: .kind)
        }
    }
}

/// Turns the merged activity plus app-side facts into a ``SessionState``.
public enum SessionStateResolver {
    /// SPEC §3: `starting` while there is no hook data for less than 20 s.
    public static let startingGrace: TimeInterval = 20

    public enum ProcessStatus: Sendable, Equatable {
        case running(startedAt: Date)
        case exited(code: Int32?)
        /// Persisted from an earlier app run / boot; not running now.
        case stopped
    }

    public struct Input: Sendable, Equatable {
        public var kind: SessionKind
        public var process: ProcessStatus
        public var activity: SessionActivity
        /// Last time the user looked at the session (selected / visible).
        public var lastViewedAt: Date?
        /// Whether the session has had at least one turn (a prompt or a tool call); a session that
        /// is idle straight after startup is not "done".
        public var hasHadTurn: Bool
        /// How long a session without hook data stays `starting` before it is `unknown` (SPEC's
        /// `! NO HOOK`): Settings › 工作階段 › NO HOOK 警告 (10 / 20 / 60 s, M3).
        public var startingGrace: TimeInterval

        public init(kind: SessionKind, process: ProcessStatus, activity: SessionActivity,
                    lastViewedAt: Date? = nil, hasHadTurn: Bool, startingGrace: TimeInterval = SessionStateResolver.startingGrace) {
            self.kind = kind
            self.process = process
            self.activity = activity
            self.lastViewedAt = lastViewedAt
            self.hasHadTurn = hasHadTurn
            self.startingGrace = startingGrace
        }
    }

    public static func resolve(_ input: Input, now: Date) -> SessionState {
        switch input.process {
        case .stopped:
            return .stopped
        case .exited(let code):
            return .exited(code: code)
        case .running(let startedAt):
            if input.kind == .shell { return .shell }
            let a = input.activity
            switch a.state {
            case .waiting: return .waiting(a.reason ?? .other)
            case .error: return .error(a.errorKind ?? .unknown)
            case .compacting: return .compacting
            case .busy: return .busy
            case .idle:
                guard input.hasHadTurn, let since = a.sinceDate else { return .idle }
                if let seen = input.lastViewedAt, seen >= since { return .idle }
                return .done
            case .ended:
                // Claude ended but the PTY is alive (SPEC §3 st-shell, critique row 12). The merger
                // reports this as `idle` (CODD web rule); raw `ended` only reaches here from callers
                // that bypass it.
                return .shell
            case .unknown:
                return now.timeIntervalSince(startedAt) < input.startingGrace ? .starting : .unknown
            }
        }
    }
}
