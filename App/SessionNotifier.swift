import AppKit
import CoddPreferences
import UserNotifications

/// macOS notifications for session changes (SPEC §7.13 banners: `◆ <title> 需要授權`,
/// `▲ <title> 失敗 · <reason>`, actions 前往 / 稍後), by the Settings › 通知 matrix (D29):
/// WAITING, ERROR, DONE (a finish the user did not see) and EXITED with a non-zero code, each with
/// its condition (`一律通知` / `僅在未聚焦時`), notify and sound switches; quiet hours and the menu
/// bar pause silence them, muted groups never notify (`NotificationRules.decide`).
///
/// Authorization is requested the first time a notification is due, never at launch. Anything that
/// fails (denied, ad-hoc signed build without notification rights, no bundle) degrades silently:
/// the Dock badge, the menu bar icon and the sidebar still show the state.
///
/// The rules come from the preferences (M3 D14); the M1 / M2 UserDefaults switch is only migrated
/// from. A session the user stopped (⌘., 全部停止並結束) is never an EXITED notification.
///
/// D29: it is the one `UNUserNotificationCenter` delegate of the app. `AppNotifier` posts the
/// account notifications (`codd.account`) through `post(_:)` and receives their responses through
/// `onAccountResponse`; it never sets a delegate of its own. Every decision, posted or not, is
/// recorded in `log` (the dump's `notifications.posted`).
@MainActor
final class SessionNotifier: NSObject {
    nonisolated static let categoryID = "codd.session"
    nonisolated static let openActionID = "codd.open"
    nonisolated static let laterActionID = "codd.later"
    nonisolated static let sessionKey = "sessionID"
    /// D13 / D29: auto-switch notifications (`↻ 已自動切換到 #2 藍鵲`, 復原 / 好).
    nonisolated static let accountCategoryID = "codd.account"
    nonisolated static let undoActionID = "codd.account.undo"
    nonisolated static let okActionID = "codd.account.ok"
    /// M4 D31: the cleanup digest (`清理建議 · 15 項`, action 查看).
    nonisolated static let cleanupCategoryID = "codd.cleanup"
    nonisolated static let cleanupViewActionID = "codd.cleanup.view"

    /// One notification to post (session or account).
    struct Request {
        var identifier: String
        var title: String
        var body: String
        var category: String
        var userInfo: [String: String]
        /// `UNNotificationSound.default` (the matrix's 聲音 switch).
        var sound = true
    }
    /// Restored states arriving right after launch are not news.
    static let launchQuietPeriod: TimeInterval = 5

    private let store: any SessionStore
    /// Settings › 通知, read when a notification is due (the preferences can change at any time).
    private let rules: () -> CoddPreferences.Notifications
    private let isFocused: (SessionID) -> Bool
    /// 依群組靜音: the session's group is muted (it still shows in NEEDS YOU).
    private let isMuted: (SessionVM) -> Bool
    /// The user stopped it (its EXIT is not news).
    private let stoppedByUser: (SessionID) -> Bool
    private let open: (SessionID) -> Void
    /// `-codd-notifications NO` turns notifications off for this run regardless of the setting.
    private let allowedThisRun: Bool
    private let launchedAt = Date()
    /// `launchQuietPeriod` (tests use 0).
    private let quietPeriod: TimeInterval
    private var authorization: Authorization = .unknown
    private var center: UNUserNotificationCenter?
    private var pending: [Request] = []
    private let log: @MainActor (String) -> Void
    /// Every notification decision of this run (titles only, D29).
    let decisions: NotificationLog
    /// A response to a `codd.account` notification: the action id and its user info.
    var onAccountResponse: (@MainActor (String, [String: String]) -> Void)?
    /// A response to the cleanup digest (`查看`, a click on the banner, or a dismissal).
    var onCleanupResponse: (@MainActor (String) -> Void)?

    private enum Authorization { case unknown, requesting, granted, unavailable }

    init(store: any SessionStore, allowedThisRun: Bool, rules: @escaping () -> CoddPreferences.Notifications,
         isFocused: @escaping (SessionID) -> Bool, isMuted: @escaping (SessionVM) -> Bool = { _ in false },
         stoppedByUser: @escaping (SessionID) -> Bool = { _ in false }, open: @escaping (SessionID) -> Void,
         decisions: NotificationLog = NotificationLog(), quietPeriod: TimeInterval = SessionNotifier.launchQuietPeriod,
         log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.store = store
        self.allowedThisRun = allowedThisRun
        self.rules = rules
        self.quietPeriod = quietPeriod
        self.isFocused = isFocused
        self.isMuted = isMuted
        self.stoppedByUser = stoppedByUser
        self.open = open
        self.decisions = decisions
        self.log = log
        super.init()
    }

    /// Whether a session in `state` can notify at all (its matrix row's `notify` switch): WAITING,
    /// ERROR, DONE and EXITED; other states never notify.
    nonisolated static func isEnabled(for state: SessionState, rules: CoddPreferences.Notifications) -> Bool {
        switch state {
        case .waiting: rules.waiting.notify
        case .error: rules.error.notify
        case .done: rules.done.notify
        case .exited: rules.exitedNonZero.notify
        default: false
        }
    }

    /// Banner text for a session in `state` (SPEC §7.13).
    static func content(for session: SessionVM, projectName: String?) -> (title: String, body: String) {
        let place = projectName.map { $0 + " · " } ?? ""
        if session.state == .error {
            return ("▲ \(session.title) 失敗 · \(SessionPaneViewController.errorText(session.errorReason))", place + "本輪未完成")
        }
        if session.state == .done {
            return ("◇ \(session.title) 完成", place + "回到 CODD 查看結果")
        }
        if session.state == .exited {
            return ("✕ \(session.title) 已結束 · exit \(session.exitCode.map(String.init) ?? "?")", place + "可在 CODD 重新開始")
        }
        let what: String
        switch session.waitingReason {
        case .question?: what = "在問你問題"
        case .plan?: what = "等你核准計畫"
        default: what = "需要授權"
        }
        let detail = [session.tool, session.detail].compactMap { $0 }.joined(separator: ": ")
        return ("◆ \(session.title) \(what)", place + (detail.isEmpty ? "回到 CODD 回應" : detail))
    }

    /// D23 `暫停通知 1 小時`: no banner and no sound until `pausedUntil` (badges still update).
    nonisolated static func isPaused(_ rules: CoddPreferences.Notifications, now: Date) -> Bool {
        NotificationRules.isPaused(rules, now: now)
    }

    /// A session changed state (the store reports every transition). Externals are never
    /// notified (D6).
    func sessionChanged(_ session: SessionVM, from old: SessionState) {
        guard Date().timeIntervalSince(launchedAt) >= quietPeriod, !session.external,
              let event = NotificationRules.event(from: old, to: session.state, exitCode: session.exitCode) else { return }
        if event == .exited, stoppedByUser(session.id) { return }
        let verdict = NotificationRules.decide(event, rules: rules(), viewing: isFocused(session.id), muted: isMuted(session), now: Date())
        guard verdict.due else { return }
        let text = Self.content(for: session, projectName: store.project(session.projectID)?.name)
        decisions.record(kind: event.kind, title: text.title, suppressed: !allowedThisRun || verdict.silenced)
        guard allowedThisRun else { return }
        guard !verdict.silenced else {
            log("notification suppressed session=\(session.id) event=\(event.rawValue) (paused or quiet hours)")
            return
        }
        post(Request(identifier: "codd.session.\(session.id)", title: text.title, body: text.body, category: Self.categoryID,
                     userInfo: [Self.sessionKey: session.id], sound: verdict.sound))
    }

    /// Settings › 通知 `傳送測試通知`: one banner right away (the user asked for it, so quiet hours
    /// and the pause do not hold it back; `-codd-notifications NO` does). Recorded like the rest.
    func sendTest() {
        let title = Self.testTitle
        decisions.record(kind: "test", title: title, suppressed: !allowedThisRun)
        log("notification test\(allowedThisRun ? "" : " suppressed")")
        guard allowedThisRun else { return }
        post(Request(identifier: "codd.test", title: title, body: "通知會像這樣出現；前往 / 稍後 會回到 CODD。", category: Self.categoryID,
                     userInfo: [:], sound: true))
    }

    static let testTitle = "◆ 測試通知 · CODD"

    /// The rule, pure for tests: a change of a CODD session into WAITING or ERROR the user is not
    /// looking at, with notifications on (the M1 condition `僅在未聚焦時`).
    nonisolated static func shouldNotify(from old: SessionState, to new: SessionState, focused: Bool, enabled: Bool,
                                         external: Bool = false) -> Bool {
        guard enabled, !focused, !external, old != new else { return false }
        return new == .waiting || new == .error
    }

    /// Posts one notification (asking for permission the first time). `AppNotifier` decides
    /// whether an account notification is due and records it; this only delivers.
    func post(_ request: Request) {
        guard allowedThisRun else { return }
        switch authorization {
        case .unavailable:
            return
        case .granted:
            deliver(request)
        case .requesting:
            pending.append(request)
        case .unknown:
            pending.append(request)
            requestAuthorization()
        }
    }

    /// Lazily, on the first notification due.
    private func requestAuthorization() {
        guard let center = prepareCenter() else {
            authorization = .unavailable
            pending.removeAll()
            return
        }
        authorization = .requesting
        Task { [weak self] in
            let granted = await self?.ask(center) ?? false
            self?.authorized(granted)
        }
    }

    /// The answer of onboarding step 6's `允許通知` (M5 D3).
    enum PermissionAnswer: String, Sendable {
        case granted, denied, suppressed
    }

    static let permissionTitle = "允許通知"

    /// Onboarding step 6 `允許通知` (M5 D3): asks macOS now instead of at the first notification
    /// due. A run that may not notify (`-codd-notifications NO`) or runs in the background (scripts,
    /// agents: nobody is there to answer the prompt) gets `.suppressed` without touching
    /// `UNUserNotificationCenter`. Recorded in the notification log either way.
    func requestAuthorizationNow(background: Bool = AppActivation.isBackground) async -> PermissionAnswer {
        guard allowedThisRun, !background else {
            decisions.record(kind: "permission", title: Self.permissionTitle, suppressed: true)
            log("notification permission suppressed (\(allowedThisRun ? "background run" : "notifications off this run"))")
            return .suppressed
        }
        decisions.record(kind: "permission", title: Self.permissionTitle, suppressed: false)
        if authorization == .granted { return .granted }
        guard let center = prepareCenter() else {
            authorization = .unavailable
            return .denied
        }
        authorization = .requesting
        let granted = await ask(center)
        authorized(granted)
        return granted ? .granted : .denied
    }

    /// The notification center has been set up (tests: a suppressed request never touches it).
    var usesNotificationCenter: Bool { center != nil }

    private func ask(_ center: UNUserNotificationCenter) async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log("notifications unavailable: \(error)")
            return false
        }
    }

    /// The center with this notifier as its delegate and CODD's categories, made once. A build
    /// without a bundle identifier would trap in `UNUserNotificationCenter.current()`: nil then.
    private func prepareCenter() -> UNUserNotificationCenter? {
        if let center { return center }
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let center = UNUserNotificationCenter.current()
        self.center = center
        center.delegate = self
        let openAction = UNNotificationAction(identifier: Self.openActionID, title: "前往", options: [.foreground])
        let laterAction = UNNotificationAction(identifier: Self.laterActionID, title: "稍後", options: [])
        let undoAction = UNNotificationAction(identifier: Self.undoActionID, title: "復原", options: [])
        let okAction = UNNotificationAction(identifier: Self.okActionID, title: "好", options: [])
        let viewAction = UNNotificationAction(identifier: Self.cleanupViewActionID, title: "查看", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.categoryID, actions: [openAction, laterAction], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.accountCategoryID, actions: [undoAction, okAction], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.cleanupCategoryID, actions: [viewAction], intentIdentifiers: [], options: []),
        ])
        return center
    }

    private func authorized(_ granted: Bool) {
        authorization = granted ? .granted : .unavailable
        log("notifications authorized=\(granted)")
        let queued = pending
        pending.removeAll()
        guard granted else { return }
        for item in queued { deliver(item) }
    }

    private func deliver(_ item: Request) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.sound = item.sound ? .default : nil
        content.categoryIdentifier = item.category
        content.userInfo = item.userInfo
        // One banner per session (or account event): a newer one replaces the older one.
        let request = UNNotificationRequest(identifier: item.identifier, content: content, trigger: nil)
        let log = self.log
        center.add(request) { error in
            if let error { Task { @MainActor in log("notification not posted: \(error)") } }
        }
    }

    fileprivate func activate(_ sessionID: SessionID) {
        NSApp.activate()
        open(sessionID)
    }

    /// D29: the one delegate routes every response by category: `codd.account` to AppNotifier
    /// (`onAccountResponse`), `codd.session` to the session it names (前往; 稍後 / dismiss do nothing).
    func route(category: String, action: String, userInfo: [String: String]) {
        if category == Self.accountCategoryID {
            onAccountResponse?(action, userInfo)
            return
        }
        if category == Self.cleanupCategoryID {
            onCleanupResponse?(action)
            return
        }
        guard action != Self.laterActionID, action != UNNotificationDismissActionIdentifier,
              let sessionID = userInfo[Self.sessionKey] else { return }
        activate(sessionID)
    }
}

extension SessionNotifier: UNUserNotificationCenterDelegate {
    /// Banners also show while CODD is frontmost: the session is not the one on screen.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // The sound only when the notification has one (the matrix's 聲音 switch).
        completionHandler(notification.request.content.sound == nil ? [.banner] : [.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let category = content.categoryIdentifier
        var info: [String: String] = [:]
        for (key, value) in content.userInfo { if let key = key as? String, let value = value as? String { info[key] = value } }
        completionHandler()
        Task { @MainActor [weak self] in self?.route(category: category, action: action, userInfo: info) }
    }
}
