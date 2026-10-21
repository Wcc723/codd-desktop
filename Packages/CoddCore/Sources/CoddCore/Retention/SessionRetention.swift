import Foundation

/// M4 D30: how long stopped CODD sessions stay before they dim, archive, and lose their terminal
/// log (Settings › 清理).
public struct SessionRetentionPolicy: Sendable, Equatable {
    /// Stopped this long → the stale dim (`SessionVM.isStale`). `nil` (or < 1) = never.
    public var staleDays: Int?
    /// Stopped this long → archived like `封存` (restorable). `nil` (or < 1) = never.
    public var archiveDays: Int?
    /// Archived this long → the session's `ring` (and `holder.log`) go to the trash. `nil` (or < 1)
    /// = never. Settings › 清理 › 終端機紀錄 and 進階 › 終端機紀錄保留 edit this one value.
    public var scrollbackDeleteDays: Int?
    /// Claude's own `cleanupPeriodDays` (it deletes transcripts older than this at startup).
    public var cleanupPeriodDays: Int
    /// Settings › 清理 › resume 過期提醒: list sessions whose transcript Claude deletes soon.
    public var resumeWarning: Bool
    /// The `resume expires nd` warning starts this many days before Claude's sweep.
    public var resumeWarningDays: Int
    /// A pending archive / ring deletion is listed (`archives in nd`, `deletes in nd`) when it is
    /// due within this many days.
    public var soonDays: Int
    /// The D30 first-run grace (`cleanup.json` `retention.firstRunAt`): every clock (stopped →
    /// stale / archive, archived → ring) starts no earlier than this, so the first M4 launch never
    /// archives the user's existing stopped sessions or trashes rings at once.
    public var countFrom: Date?

    public init(staleDays: Int? = 3, archiveDays: Int? = 7, scrollbackDeleteDays: Int? = 30,
                cleanupPeriodDays: Int = TranscriptRetention.defaultCleanupPeriodDays, resumeWarning: Bool = true,
                resumeWarningDays: Int = 5, soonDays: Int = 7, countFrom: Date? = nil) {
        self.staleDays = staleDays
        self.archiveDays = archiveDays
        self.scrollbackDeleteDays = scrollbackDeleteDays
        self.cleanupPeriodDays = cleanupPeriodDays
        self.resumeWarning = resumeWarning
        self.resumeWarningDays = resumeWarningDays
        self.soonDays = soonDays
        self.countFrom = countFrom
    }
}

/// One session as the retention engine sees it.
public struct SessionRetentionInput: Sendable, Equatable {
    public var id: UUID
    /// The display title (not used by the rules; kept for the caller's rows and logs).
    public var title: String
    public var kind: SessionKind
    public var isRunning: Bool
    public var isPinned: Bool
    /// A claude CODD did not start: never touched.
    public var isExternal: Bool
    public var lastState: SessionState?
    /// When ``lastState`` was recorded; for a stopped / exited session, when it stopped.
    public var lastStateAt: Date?
    public var archivedAt: Date?
    /// `保留 30 天` (`cleanup.json`): while in the future, the session is left alone entirely
    /// (no dim, no archive, no ring deletion, no candidate).
    public var keepUntil: Date?
    /// The mtime of the session's transcript (claude sessions).
    public var transcriptModifiedAt: Date?
    /// `false` when the transcript is known to be gone; `nil` when unknown.
    public var transcriptExists: Bool?
    /// Size of the session's `ring` on disk; `nil` or 0 when there is none.
    public var ringBytes: Int64?

    public init(id: UUID, title: String = "", kind: SessionKind = .claude, isRunning: Bool = false, isPinned: Bool = false,
                isExternal: Bool = false, lastState: SessionState? = nil, lastStateAt: Date? = nil, archivedAt: Date? = nil,
                keepUntil: Date? = nil, transcriptModifiedAt: Date? = nil, transcriptExists: Bool? = nil, ringBytes: Int64? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.isRunning = isRunning
        self.isPinned = isPinned
        self.isExternal = isExternal
        self.lastState = lastState
        self.lastStateAt = lastStateAt
        self.archivedAt = archivedAt
        self.keepUntil = keepUntil
        self.transcriptModifiedAt = transcriptModifiedAt
        self.transcriptExists = transcriptExists
        self.ringBytes = ringBytes
    }
}

/// A row of the Cleanup page (D31): SESSIONS rows for live (not archived) sessions, and FILES rows
/// for the rings of archived ones (``isFile``). ``id`` is the session's id: unique among the
/// SESSIONS rows and among the FILES rows (a session can have one of each).
public struct SessionCleanupCandidate: Sendable, Equatable, Identifiable {
    public enum Reason: Sendable, Equatable {
        /// Stopped for at least the stale days (real days, not the grace clock).
        case stopped(days: Int)
        /// Auto-archived in `days` (0 = at the next run).
        case archivesSoon(days: Int)
        /// Claude deletes the transcript in `days` (`--resume` stops working).
        case resumeExpires(days: Int)
        case transcriptGone
        /// An archived session's terminal log, deleted in `deletesInDays`.
        case ring(bytes: Int64, deletesInDays: Int)
    }

    public var id: UUID
    public var reason: Reason
    /// The row's main line (`停止 5 天`, `終端機紀錄 · 8.0 MB`).
    public var why: String
    /// The row's second line (`最後畫面保留到 11/12`, `封存 26 天`).
    public var sub: String
    /// The status chip (`stale 5d`, `archives in 2d`, `resume expires 4d`, `deletes in 4d`).
    public var badge: String

    public init(id: UUID, reason: Reason, why: String, sub: String, badge: String) {
        self.id = id
        self.reason = reason
        self.why = why
        self.sub = sub
        self.badge = badge
    }

    /// A FILES-tab row (a ring), not a SESSIONS-tab row.
    public var isFile: Bool {
        if case .ring = reason { return true }
        return false
    }
}

public struct SessionRetentionResult: Sendable, Equatable {
    /// Not archived, stopped for at least the stale days (grace clock): the stale dim.
    public var staleIDs: Set<UUID>
    /// To archive now (input order).
    public var archiveIDs: [UUID]
    /// Archived sessions whose ring (and `holder.log`) go to the trash now (input order).
    public var ringDeleteIDs: [UUID]
    /// SESSIONS rows (at most one per session) and FILES rows, in input order.
    public var candidates: [SessionCleanupCandidate]

    public init(staleIDs: Set<UUID> = [], archiveIDs: [UUID] = [], ringDeleteIDs: [UUID] = [],
                candidates: [SessionCleanupCandidate] = []) {
        self.staleIDs = staleIDs
        self.archiveIDs = archiveIDs
        self.ringDeleteIDs = ringDeleteIDs
        self.candidates = candidates
    }
}

/// The D30 rules, pure (the app applies the result; I4a).
///
/// Only CODD sessions that are not running, not pinned and not kept (`keepUntil` in the future)
/// are considered. A session is stopped when ``SessionRetentionInput/lastState`` is `stopped` or
/// `exited` with a ``SessionRetentionInput/lastStateAt``; any other not-running session is left
/// alone (never archived by a guess). Day counts are whole days (`floor`), and a threshold of N
/// days is reached at exactly N × 24 h. With ``SessionRetentionPolicy/countFrom`` set, a session
/// stopped (or archived) before it counts as stopped (archived) at that moment for the stale,
/// archive and ring clocks; its candidate row still shows the real stopped days, with the later due
/// date. SESSIONS rows pick one reason per session: resume expires, then transcript gone, then
/// archives soon, then stopped.
public enum SessionRetention {
    static let day: TimeInterval = 86_400

    /// - Parameter timeZone: for the `M/D` dates in the row texts.
    public static func evaluate(_ sessions: [SessionRetentionInput], policy: SessionRetentionPolicy,
                                now: Date, timeZone: TimeZone = .current) -> SessionRetentionResult {
        var result = SessionRetentionResult()
        let staleDays = positive(policy.staleDays)
        let archiveDays = positive(policy.archiveDays)
        let ringDays = positive(policy.scrollbackDeleteDays)

        for s in sessions {
            guard !s.isExternal, !s.isRunning, !s.isPinned else { continue }
            if let keep = s.keepUntil, keep > now { continue }

            if let archivedAt = s.archivedAt {
                // Archived: only the ring clock runs.
                guard let ringDays, let bytes = s.ringBytes, bytes > 0 else { continue }
                let elapsed = days(since: graced(archivedAt, policy), now: now)
                if elapsed >= ringDays {
                    result.ringDeleteIDs.append(s.id)
                } else if ringDays - elapsed <= policy.soonDays {
                    let left = ringDays - elapsed
                    result.candidates.append(SessionCleanupCandidate(
                        id: s.id, reason: .ring(bytes: bytes, deletesInDays: left),
                        why: "終端機紀錄 · \(byteText(bytes))", sub: "封存 \(days(since: archivedAt, now: now)) 天",
                        badge: "deletes in \(left)d"))
                }
                continue
            }

            var stoppedFor: Int?      // real days, for the row
            var archiveLeft: Int?     // grace clock
            var archivedNow = false
            if let stoppedAt = stoppedSince(s) {
                let real = days(since: stoppedAt, now: now)
                let elapsed = days(since: graced(stoppedAt, policy), now: now)
                stoppedFor = real
                if let staleDays, elapsed >= staleDays { result.staleIDs.insert(s.id) }
                if let archiveDays {
                    if elapsed >= archiveDays {
                        result.archiveIDs.append(s.id)
                        archivedNow = true
                    } else {
                        archiveLeft = archiveDays - elapsed
                    }
                }
            }
            guard !archivedNow else { continue }

            let sub = stoppedSince(s).map { ringKeptText(stoppedAt: $0, policy: policy, timeZone: timeZone) } ?? ""
            if let candidate = sessionCandidate(s, stoppedFor: stoppedFor, archiveLeft: archiveLeft, sub: sub,
                                                staleDays: staleDays, policy: policy, now: now) {
                result.candidates.append(candidate)
            }
        }
        return result
    }

    private static func sessionCandidate(_ s: SessionRetentionInput, stoppedFor: Int?, archiveLeft: Int?, sub: String,
                                         staleDays: Int?, policy: SessionRetentionPolicy, now: Date) -> SessionCleanupCandidate? {
        let stoppedWhy = stoppedFor.map { "停止 \($0) 天" }
        if s.kind == .claude, policy.resumeWarning, s.transcriptExists != false, let modified = s.transcriptModifiedAt,
           let left = TranscriptRetention.daysLeft(lastActivity: modified, now: now, cleanupPeriodDays: policy.cleanupPeriodDays,
                                                   warnWithin: max(0, policy.resumeWarningDays)) {
            return SessionCleanupCandidate(
                id: s.id, reason: .resumeExpires(days: left), why: stoppedWhy ?? "對話紀錄 \(left) 天後刪除",
                sub: "Claude Code \(policy.cleanupPeriodDays) 天後刪除對話紀錄", badge: "resume expires \(left)d")
        }
        if s.kind == .claude, s.transcriptExists == false {
            return SessionCleanupCandidate(id: s.id, reason: .transcriptGone, why: "對話紀錄已不存在",
                                           sub: stoppedWhy.map { "\($0) · 無法接續" } ?? "無法接續", badge: "transcript gone")
        }
        // Listed once stopped for the stale days (real days, so the grace never hides a session
        // that has been stopped for weeks); without a stale step, once the archive is near.
        guard let stoppedFor, let stoppedWhy else { return nil }
        let stale = staleDays.map { stoppedFor >= $0 } ?? true
        if stale, let archiveLeft, archiveLeft <= policy.soonDays {
            return SessionCleanupCandidate(id: s.id, reason: .archivesSoon(days: archiveLeft), why: stoppedWhy, sub: sub,
                                           badge: "archives in \(archiveLeft)d")
        }
        guard staleDays != nil, stale else { return nil }
        return SessionCleanupCandidate(id: s.id, reason: .stopped(days: stoppedFor), why: stoppedWhy, sub: sub,
                                       badge: "stale \(stoppedFor)d")
    }

    /// When a stopped / exited session stopped.
    static func stoppedSince(_ s: SessionRetentionInput) -> Date? {
        switch s.lastState {
        case .stopped?, .exited?: return s.lastStateAt
        default: return nil
        }
    }

    /// `date`, or the grace start when that is later.
    static func graced(_ date: Date, _ policy: SessionRetentionPolicy) -> Date {
        guard let from = policy.countFrom else { return date }
        return max(date, from)
    }

    /// Whole days from `date` to `now` (0 when `date` is in the future).
    static func days(since date: Date, now: Date) -> Int {
        let d = (now.timeIntervalSince(date) / day).rounded(.down)
        guard d.isFinite, d > 0 else { return 0 }
        return Int(min(d, 1e9))
    }

    static func positive(_ days: Int?) -> Int? {
        guard let days, days >= 1 else { return nil }
        return days
    }

    /// `最後畫面保留到 M/D`: the day the ring goes (archive, then the scrollback days), on the
    /// grace clock; `最後畫面不會自動刪除` when either step is off.
    static func ringKeptText(stoppedAt: Date, policy: SessionRetentionPolicy, timeZone: TimeZone) -> String {
        guard let archive = positive(policy.archiveDays), let ring = positive(policy.scrollbackDeleteDays) else {
            return "最後畫面不會自動刪除"
        }
        let due = graced(stoppedAt, policy).addingTimeInterval(Double(archive + ring) * day)
        let c = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: due)
        return "最後畫面保留到 \(c.month ?? 0)/\(c.day ?? 0)"
    }

    /// `8.0 MB` (binary units, like the rest of the app).
    static func byteText(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.1f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", b / 1024) }
        return "\(bytes) B"
    }
}
