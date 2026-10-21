import CoddPreferences
import Foundation
import Observation
import UserNotifications

/// When a banner must stay silent (D23, D29), shared by the session and account notifications.
enum NotificationRules {
    /// `暫停通知 1 小時` until `pausedUntil`.
    static func isPaused(_ rules: CoddPreferences.Notifications, now: Date) -> Bool {
        rules.pausedUntil.map { $0 > now } ?? false
    }

    /// 勿擾時段 (local time, `HH:mm`–`HH:mm`, across midnight when the end is earlier than the
    /// start; equal times mean no quiet hours).
    static func isQuiet(_ rules: CoddPreferences.Notifications, now: Date, calendar: Calendar = .current) -> Bool {
        let quiet = rules.quietHours
        guard quiet.enabled, let start = minutes(quiet.start), let end = minutes(quiet.end), start != end else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: now)
        let current = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return start < end ? (current >= start && current < end) : (current >= start || current < end)
    }

    /// `23:00` → 1380; nil for anything else.
    static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }

    // MARK: Session matrix (D29)

    /// A session change that can notify: WAITING, ERROR, DONE (a finish the user did not see) or
    /// EXITED with a non-zero code.
    enum SessionEvent: String, CaseIterable, Sendable {
        case waiting, error, done, exited

        /// The dump's `notifications.posted[].kind`.
        var kind: String { "session-\(rawValue)" }
    }

    /// The event a transition into `new` is, if any. DONE is only ever entered unseen (a session
    /// the user looks at goes IDLE instead); EXITED counts only with a known non-zero code.
    static func event(from old: SessionState, to new: SessionState, exitCode: Int32?) -> SessionEvent? {
        guard old != new else { return nil }
        switch new {
        case .waiting: return .waiting
        case .error: return .error
        case .done: return .done
        case .exited:
            guard let exitCode, exitCode != 0 else { return nil }
            return .exited
        default: return nil
        }
    }

    static func rule(_ event: SessionEvent, in rules: CoddPreferences.Notifications) -> CoddPreferences.EventRule {
        switch event {
        case .waiting: rules.waiting
        case .error: rules.error
        case .done: rules.done
        case .exited: rules.exitedNonZero
        }
    }

    /// What one event does: `due` = it is a notification at all (its switch is on, its condition
    /// holds, its group is not muted); `silenced` = due but quiet hours or the pause keep it from
    /// showing (still recorded); `sound` = it plays `UNNotificationSound.default`.
    struct Verdict: Equatable, Sendable {
        var due: Bool
        var silenced: Bool
        var sound: Bool
    }

    /// The D29 matrix for one event. `viewing` = CODD is active and the session is the one on
    /// screen (`僅在未聚焦時` skips it then; `一律通知` does not). Muted groups never notify; pause
    /// and quiet hours silence banners and sounds alike.
    static func decide(_ event: SessionEvent, rules: CoddPreferences.Notifications, viewing: Bool, muted: Bool,
                       now: Date, calendar: Calendar = .current) -> Verdict {
        let rule = rule(event, in: rules)
        let due = rule.notify && !muted && (rule.condition == .always || !viewing)
        let silenced = due && (isPaused(rules, now: now) || isQuiet(rules, now: now, calendar: calendar))
        return Verdict(due: due, silenced: silenced, sound: due && !silenced && rule.sound)
    }
}

/// Every notification decision of this run, posted or suppressed (`-codd-notifications NO`,
/// paused, quiet hours), titles only (D29): the dump's `notifications.posted`, so automated runs can
/// count them without a notification ever showing.
@MainActor @Observable
final class NotificationLog {
    struct Entry: Equatable {
        var kind: String
        var title: String
        var suppressed: Bool
        var at: Date
    }

    private(set) var entries: [Entry] = []
    static let limit = 50

    func record(kind: String, title: String, suppressed: Bool, at: Date = Date()) {
        entries.append(Entry(kind: kind, title: title, suppressed: suppressed, at: at))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    var dumpObject: [String: Any] {
        ["posted": entries.map { ["kind": $0.kind, "title": $0.title, "suppressed": $0.suppressed] as [String: Any] }]
    }
}

/// Account notifications (D13, D29): the automatic switch (`↻ 已自動切換到 #2 藍鵲`, actions 復原 /
/// 好) and `所有帳號都低於 2%`. Pause and quiet hours silence them; `-codd-notifications NO`
/// posts nothing. Delivery goes through `SessionNotifier`, the app's one notification delegate.
@MainActor
final class AppNotifier {
    enum Kind: String {
        case autoSwitch = "account-auto-switch"
        case noEligibleTarget = "account-none-eligible"
        /// An automatic switch failed (once per episode of failures, M3 review).
        case autoSwitchFailed = "account-auto-switch-failed"
        /// M4 D31: `清理建議 · 15 項` / `筆記 8 · session 5 · 檔案 2`, action 查看.
        case cleanupDigest = "cleanup-digest"

        /// The notification category its actions come from.
        var category: String {
            self == .cleanupDigest ? SessionNotifier.cleanupCategoryID : SessionNotifier.accountCategoryID
        }

        /// The identifier a newer banner of the same kind replaces.
        var identifier: String {
            self == .cleanupDigest ? "codd.cleanup.digest" : "codd.account.\(rawValue)"
        }
    }

    private weak var dispatcher: SessionNotifier?
    private let allowedThisRun: Bool
    private let rules: @MainActor () -> CoddPreferences.Notifications
    private let now: @MainActor () -> Date
    private let log: @MainActor (String) -> Void
    let decisions: NotificationLog
    /// 復原 on an auto-switch notification: the account to switch back to.
    var onUndo: (@MainActor (AccountID) -> Void)?
    /// 查看 (or a click) on the cleanup digest: the Cleanup page.
    var onCleanupView: (@MainActor () -> Void)?

    nonisolated static let undoAccountKey = "undoAccount"

    init(dispatcher: SessionNotifier?, allowedThisRun: Bool, rules: @escaping @MainActor () -> CoddPreferences.Notifications,
         decisions: NotificationLog, now: @escaping @MainActor () -> Date = { Date() },
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.dispatcher = dispatcher
        self.allowedThisRun = allowedThisRun
        self.rules = rules
        self.decisions = decisions
        self.now = now
        self.log = log
        dispatcher?.onAccountResponse = { [weak self] action, info in self?.response(action, userInfo: info) }
        dispatcher?.onCleanupResponse = { [weak self] action in
            guard action != UNNotificationDismissActionIdentifier else { return }
            self?.onCleanupView?()
        }
    }

    /// Records the decision and posts unless suppressed. Returns whether it was posted.
    @discardableResult
    func post(_ kind: Kind, title: String, body: String, undoAccount: AccountID? = nil) -> Bool {
        let rules = rules()
        let at = now()
        let silent = NotificationRules.isPaused(rules, now: at) || NotificationRules.isQuiet(rules, now: at)
        let suppressed = !allowedThisRun || silent || dispatcher == nil
        decisions.record(kind: kind.rawValue, title: title, suppressed: suppressed, at: at)
        log("notification \(kind.rawValue)\(suppressed ? " suppressed" : "")")
        guard !suppressed, let dispatcher else { return false }
        var info: [String: String] = [:]
        if let undoAccount { info[Self.undoAccountKey] = undoAccount }
        dispatcher.post(SessionNotifier.Request(identifier: kind.identifier, title: title, body: body, category: kind.category,
                                                userInfo: info, sound: kind != .cleanupDigest))
        return true
    }

    private func response(_ action: String, userInfo: [String: String]) {
        guard action == SessionNotifier.undoActionID, let account = userInfo[Self.undoAccountKey] else { return }
        onUndo?(account)
    }
}
