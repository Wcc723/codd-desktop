import Foundation
import Observation
import CoddUI

/// One-line facts for the sidebar footer, status bar and menu bar panel.
struct HostSummary: Equatable, Sendable {
    var line: String
    var mcpEndpoint: String
    var mcpClients: Int
    var mcpRunning: Bool
    var hooksInstalled: Bool
    var hooksHealthy: Bool
    var cleanupSuggestions: Int
    /// Real mode: the hook endpoint's one-line state for the status bar (`● :47821`, `▲ 埠被佔用`);
    /// nil draws the installer state (`hooksInstalled` / `hooksHealthy`) as in the mock.
    var hookStatus: String? = nil
}

/// Auto-switch rule (SPEC R8, Settings › 帳號 › 自動切換). OFF by default; the account surfaces show
/// it (one-line status, threshold ticks on the bars while ON).
struct AutoSwitchConfig: Equatable, Sendable {
    var enabled = false
    var thresholdPercent = 2
    var checkFiveHour = true
    var checkWeek = true
    var cooldownSeconds = 300
}

/// Something went wrong that the user should know about (discovery failed, another CODD took a
/// session over, a shell tab could not start). The pane shows it as a dismissible banner: for
/// every session when `sessionID` is nil, else only on that session (and on the home page).
struct StoreProblem: Equatable, Sendable {
    /// 繁體中文, one line.
    var message: String
    var at: Date
    var sessionID: SessionID?
    /// M5 D14: the file `[在 Finder 中顯示]` reveals (a data file moved aside), nil: no such button.
    var revealPath: String? = nil
    /// M5 D14: one of the queued data-file banners (shown one at a time; `[知道了]` shows the next,
    /// and a problem reported meanwhile only puts it back at the head of the queue).
    var queued = false
}

/// Read model + intents for sessions, projects and groups. `MockSessionStore` implements it
/// with SPEC §5 data; the real store (hooks / registry / holders) replaces it later.
/// Structure (group → project → session order) changes only on add / remove / reorder.
@MainActor
protocol SessionStore: AnyObject, Observable {
    /// Groups in sidebar order. The ungrouped bucket (`isUngrouped`) is always last.
    var groups: [GroupVM] { get }
    /// Every known session, in no particular order.
    var allSessions: [SessionVM] { get }
    /// Pinned sessions in pin order.
    var pinnedSessionIDs: [SessionID] { get }
    var clock: DisplayClock { get }
    var host: HostSummary { get }

    func group(_ id: GroupID) -> GroupVM?
    func project(_ id: ProjectID) -> ProjectVM?
    func session(_ id: SessionID) -> SessionVM?

    // MARK: Layout intents
    /// Reorders sessions inside their own project (cwd is fixed, so never across projects).
    func moveSessions(_ ids: [SessionID], toIndex index: Int, inProject projectID: ProjectID)
    /// Moves projects into `groupID` at `index` (same group = reorder).
    func moveProjects(_ ids: [ProjectID], toGroup groupID: GroupID, atIndex index: Int)
    /// Reorders user groups; `index` counts user groups only (ungrouped stays last).
    func moveGroups(_ ids: [GroupID], toIndex index: Int)
    func setCollapsed(_ collapsed: Bool, group id: GroupID)
    func setCollapsed(_ collapsed: Bool, project id: ProjectID)
    @discardableResult func addGroup(name: String, color: TagColor?) -> GroupID
    /// Deletes a user group; its projects move to the ungrouped bucket.
    func deleteGroup(_ id: GroupID)
    func renameGroup(_ id: GroupID, to name: String)
    func setGroupColor(_ color: TagColor?, group id: GroupID)

    // MARK: Session intents
    func renameSession(_ id: SessionID, to title: String)
    func setTag(_ tag: TagColor?, sessions ids: [SessionID])
    func setPinned(_ pinned: Bool, sessions ids: [SessionID])
    /// Removes sessions from the tree; returns an action that puts them back (UNDO toast).
    func archive(_ ids: [SessionID]) -> @MainActor () -> Void
    func stop(_ ids: [SessionID])
    func resume(_ id: SessionID)
    func restart(_ id: SessionID)
    /// 刪除對話紀錄… (D23): a claude session that is not running and whose conversation no live
    /// claude uses has its transcript moved to the Trash, then leaves CODD (a shell, which has no
    /// transcript, just leaves). True when that happened; false when refused or a file could not
    /// be moved (the session then stays).
    @discardableResult func deleteHistory(_ id: SessionID) async -> Bool
    /// Removes sessions from CODD for good; running ones are ended (the UI confirms first).
    /// Claude's own transcripts in `~/.claude` stay.
    func removeSessions(_ ids: [SessionID])
    func renameProject(_ id: ProjectID, to name: String)
    /// Removes a project and every session in it (running ones are ended; the UI confirms).
    func removeProject(_ id: ProjectID)
    /// Answer-bar key for a waiting session: `1`…`9` or `esc`.
    func answer(_ id: SessionID, key: String)
    /// The user left a session they had looked at: DONE (unseen) becomes IDLE.
    func markSeen(_ id: SessionID)

    // MARK: Robustness (M2)
    /// The latest problem to show (nil: none, or dismissed).
    var problem: StoreProblem? { get }
    func dismissProblem()
    /// `[在 Finder 中顯示]` on the problem banner (M5 D14): the shown problem's file, on a user
    /// click only (a background run logs and skips it).
    func revealProblemFile()
    /// `[↻ 立即重試]` on an UNREACHABLE session: reconnect to its holder now.
    func retryConnection(_ id: SessionID)

    // MARK: Sessions data (M2)
    /// Puts archived sessions back into their project, after its CODD sessions (D19).
    func unarchive(_ ids: [SessionID])
    /// The archived sessions of a project, most recently active first (`封存 n ▸`).
    func archivedSessions(inProject id: ProjectID) -> [SessionVM]
    /// `加入為專案` on a transient project (D6): it becomes a saved project and keeps its externals.
    func promoteTransient(_ id: ProjectID)
    /// Another claude runs the session's conversation right now (D23: `刪除對話紀錄…` is disabled).
    func isConversationInUse(_ id: SessionID) -> Bool

    // MARK: Projects from folders (M4)
    /// Whether folders can become projects (新增專案, ⌘O, folders dropped from Finder). Mock mode cannot.
    var canAddProjects: Bool { get }
    /// Adds each folder as a project the way 新增專案 does (standardized path, same validation and
    /// naming), into `groupID` at `index` among its saved projects (nil: where 新增專案 puts them).
    /// A folder that already is a saved project is not added again (`added == false`); the folder
    /// of an external (a transient project) becomes a saved one.
    @discardableResult
    func addProjects(paths: [String], toGroup groupID: GroupID?, atIndex index: Int?) -> [ProjectAddition]
}

/// One folder of an `addProjects` call.
struct ProjectAddition: Equatable, Sendable {
    /// The standardized folder path.
    var path: String
    /// Nil when the folder could not be added (missing: the store reports it).
    var projectID: ProjectID?
    /// False when the folder already was a saved project.
    var added: Bool
}

/// Mock mode has no holders and nothing goes wrong.
extension SessionStore {
    var problem: StoreProblem? { nil }
    func dismissProblem() {}
    func revealProblemFile() {}
    func retryConnection(_ id: SessionID) {}
    func promoteTransient(_ id: ProjectID) {}
    func isConversationInUse(_ id: SessionID) -> Bool { false }
    var canAddProjects: Bool { false }
    @discardableResult
    func addProjects(paths: [String], toGroup groupID: GroupID?, atIndex index: Int?) -> [ProjectAddition] { [] }
}


// MARK: - Accounts (M3 I1b)

/// Why an account switch runs (D5, D13): a click, the toast's UNDO, or the auto-switch engine.
enum AccountSwitchReason: String, Sendable {
    case user, undo, auto
}

/// The switch in progress, or how the last one ended (D5: one switch at a time).
enum AccountSwitchState: Equatable, Sendable {
    case idle
    /// `attempt` of 3 (cswap is retried while Claude Code holds its credential lock).
    case switching(to: AccountID, reason: AccountSwitchReason, attempt: Int, since: Date)
    /// The message is redacted (D31).
    case failed(message: String, at: Date)

    var isSwitching: Bool {
        if case .switching = self { return true }
        return false
    }

    /// The account being switched to.
    var target: AccountID? {
        if case .switching(let to, _, _, _) = self { return to }
        return nil
    }

    /// The dump spelling (`idle`, `switching`, `failed`).
    var key: String {
        switch self {
        case .idle: "idle"
        case .switching: "switching"
        case .failed: "failed"
        }
    }
}

/// How a `switchTo` ended. Views turn it into the D5 toast (`AccountSwitching`).
enum AccountSwitchOutcome: Equatable, Sendable {
    /// `from` is the account before (UNDO switches back to it); `following` the sessions that
    /// apply the new login within about 30 s.
    case switched(from: AccountID?, to: AccountID, following: Int)
    case alreadyActive
    /// Not tried: another switch runs, the account is unknown, disabled or the pseudo one, or
    /// there is no cswap (繁體中文).
    case refused(String)
    /// cswap failed; the message is redacted (D31).
    case failed(String)
}

/// Where the account list comes from (D1–D4).
enum AccountAvailability: Equatable, Sendable {
    /// Before the first read.
    case loading
    /// cswap's state was read (`accounts` are cswap's).
    case ready
    /// No cswap executable (or, on a test data root, no DEBUG `-codd-cswap-path`, D3).
    case noCswap
    /// `cswap --version` is older than 0.26 (or unreadable).
    case unsupported(version: String)
    /// cswap's state files cannot be used; the reason is 繁體中文, without paths or e-mails.
    case unreadable(reason: String)
    /// D4: one `#— 目前登入` row from status-line data; `note` is the underlying reason's copy.
    case pseudo(note: String)

    var isReady: Bool { self == .ready }

    /// The footer / menu bar / Home line while the list is not cswap's (nil when it is).
    var note: String? {
        switch self {
        case .loading, .ready: nil
        case .noCswap: Self.noCswapNote
        case .unsupported(let version): "// cswap \(version) 太舊，需要 ≥ 0.26"
        case .unreadable(let reason): "// 讀不到 cswap 狀態：\(reason) · 按 ↻ 立即更新 改用 cswap list（會查詢一次用量）"
        case .pseudo(let note): note
        }
    }

    static let noCswapNote = "// 找不到 cswap（設定 › 帳號）· 用量會在 claude 回報 statusline 後出現"
    /// D4 once the pseudo row has numbers (the "will appear" half of ``noCswapNote`` is no longer true).
    static let pseudoNote = "// 找不到 cswap（設定 › 帳號）· 只顯示目前登入的用量"

    /// The dump spelling.
    var key: String {
        switch self {
        case .loading: "loading"
        case .ready: "ready"
        case .noCswap: "noCswap"
        case .unsupported: "unsupported"
        case .unreadable: "unreadable"
        case .pseudo: "pseudo"
        }
    }
}

/// One entry of the ⌘N `帳號 Account` select (D12, NewSession artboard).
struct NewSessionAccountOption: Equatable, Sendable {
    /// `follow`, or the account number of a pin.
    var id: String
    var title: String
    var enabled: Bool
    /// Why it is disabled (menu item tooltip and the hint under the select).
    var hint: String?

    static let followID = "follow"

    /// The pinned account, nil for `跟隨全域登入`.
    var accountNumber: Int? { id == Self.followID ? nil : Int(id) }
}

/// cswap accounts (aliases only) and their quota. Direct switch per SPEC R3 (async, one at a time,
/// D5); UNDO = switch back through the same path.
@MainActor
protocol AccountStore: AnyObject, Observable {
    /// R7 order: weekly reset, soonest first.
    var accounts: [AccountVM] { get }
    /// Nil when unknown (no cswap, unreadable state, an unmanaged login).
    var activeAccountID: AccountID? { get }
    /// Settings › 帳號 › 自動切換 (preferences).
    var autoSwitch: AutoSwitchConfig { get }
    /// Live claude sessions that follow the global login (they apply a switch within ~30 s).
    var followingSessionCount: Int { get }
    /// Live sessions pinned to `id` (D12).
    func pinnedCount(for id: AccountID) -> Int
    var switchState: AccountSwitchState { get }
    var availability: AccountAvailability { get }
    /// The tool the numbers come from, for list headers (`cswap 0.26.0`); nil when unknown.
    var sourceLabel: String? { get }
    /// D29: the numbers are sample data (mock mode). Real mode says so next to every usage list.
    var isPlaceholder: Bool { get }
    func account(_ id: AccountID) -> AccountVM?
    /// D12: the ⌘N select as built (follow first, then one entry per account).
    var newSessionAccountOptions: [NewSessionAccountOption] { get }
    /// D5: switches the global login (cswap switch); returns how it ended.
    func switchTo(_ id: AccountID, reason: AccountSwitchReason) async -> AccountSwitchOutcome
    /// Re-reads the account state now. `userInitiated` (STATUS `↻ 立即更新`, Settings › 帳號
    /// `重新讀取`) may run the D1 `cswap list` fallback when the state files are unusable.
    func refresh(userInitiated: Bool) async
}

extension AccountStore {
    var activeAccount: AccountVM? { activeAccountID.flatMap(account) }
    var isSwitching: Bool { switchState.isSwitching }
}

/// D29 copy appended to usage headers while the account data is a placeholder in real mode.
enum SampleAccountNote {
    static let text = "· 示意資料，M3 接上 cswap"

    /// Shown in real mode only: mock mode is the artboard itself.
    @MainActor
    static func applies(_ accounts: any AccountStore, realMode: Bool) -> Bool { realMode && accounts.isPlaceholder }
}

/// The D5 toast copy and the click → switch → toast path shared by the sidebar footer, the menu
/// bar panel, the status item menu and the DEBUG `-codd-switch-account` flag.
@MainActor
enum AccountSwitching {
    /// D5 dialog A: the app's confirmation sheet, consulted for every user switch (footer, menu
    /// bar, STATUS, ⌘K); nil (mock tests, no window) switches directly.
    static weak var confirmation: (any AccountSwitchConfirming)?

    static func successText(name: String, following: Int) -> String {
        "已切換到 \(name) · \(following) 個 session 約 30 秒內套用"
    }

    static func failureText(_ message: String) -> String { "[ERROR] 切換失敗：\(message)" }

    /// Runs the switch and hands the toast to `toast` (text, UNDO action or nil). The toast of a
    /// user switch carries UNDO (= switch back, reason `undo`); UNDO's own toast does not. With
    /// Settings › 帳號 › 切換前確認 ON a user switch goes through dialog A first (D5); it ends
    /// `.refused` when the dialog is cancelled.
    @discardableResult
    static func run(_ id: AccountID, in store: any AccountStore, reason: AccountSwitchReason = .user,
                    toast: @escaping @MainActor (String, (@MainActor () -> Void)?) -> Void) -> Task<AccountSwitchOutcome, Never> {
        if reason == .user, let confirmation, confirmation.wantsConfirmation(for: id, in: store) {
            return confirmation.confirmSwitch(id, in: store, toast: toast)
        }
        return Task { @MainActor in
            let outcome = await store.switchTo(id, reason: reason)
            report(outcome, in: store, reason: reason, toast: toast)
            return outcome
        }
    }

    /// The D5 toast for how a switch ended (success with UNDO unless it was the UNDO itself).
    static func report(_ outcome: AccountSwitchOutcome, in store: any AccountStore, reason: AccountSwitchReason,
                       toast: @escaping @MainActor (String, (@MainActor () -> Void)?) -> Void) {
        switch outcome {
        case .switched(let from, let to, let following):
            let name = store.account(to)?.displayName ?? "#\(to)"
            var undo: (@MainActor () -> Void)?
            if reason != .undo, let from {
                undo = { run(from, in: store, reason: .undo, toast: toast) }
            }
            toast(successText(name: name, following: following), undo)
        case .failed(let message):
            toast(failureText(message), nil)
        case .alreadyActive, .refused:
            break
        }
    }
}

/// D5 dialog A: the confirmation sheet a user switch goes through while Settings › 帳號 ›
/// 切換前確認 is ON (`AccountSwitching.confirmation`).
@MainActor
protocol AccountSwitchConfirming: AnyObject {
    func wantsConfirmation(for id: AccountID, in store: any AccountStore) -> Bool
    /// Shows the dialog; the task ends when it closes (the switch's outcome, `.refused` when cancelled).
    func confirmSwitch(_ id: AccountID, in store: any AccountStore,
                       toast: @escaping @MainActor (String, (@MainActor () -> Void)?) -> Void) -> Task<AccountSwitchOutcome, Never>
}

/// D12: the ⌘N account select (NewSession artboard): `跟隨全域登入（#3 工作）` first, then the active
/// account listed disabled (`固定 #3 工作`), then every other account (R7 order) as `固定 #2 藍鵲（cswap
/// run）`, enabled only with a usable cswap session profile (one exists and is not marked stale).
@MainActor
enum AccountPinOptions {
    static func build(accounts: [AccountVM], activeID: AccountID?) -> [NewSessionAccountOption] {
        let real = accounts.filter { !$0.isPseudo }
        let active = real.first { $0.id == activeID }
        var options = [NewSessionAccountOption(id: NewSessionAccountOption.followID,
                                               title: "跟隨全域登入" + (active.map { "（\($0.displayName)）" } ?? ""),
                                               enabled: true, hint: nil)]
        if let active {
            options.append(NewSessionAccountOption(id: active.id, title: "固定 \(active.displayName)", enabled: false,
                                                   hint: "\(active.displayName) 是目前的全域登入；cswap 不為它建立獨立設定目錄"))
        }
        for account in real where account.id != activeID {
            let title = "固定 \(account.displayName)（cswap run）"
            let number = account.number.map(String.init) ?? account.id
            let hint: String?
            if account.isDisabled {
                hint = "\(account.slot) 在 cswap 中已停用"
            } else if !account.hasSessionProfile {
                hint = "先在終端機執行一次 cswap run \(number)"
            } else if account.profileStale {
                hint = staleProfileMessage(number)
            } else {
                hint = nil
            }
            options.append(NewSessionAccountOption(id: account.id, title: title, enabled: hint == nil, hint: hint))
        }
        return options
    }

    /// D12: RESUME / RESTART of a pinned session whose profile vanished or was marked stale.
    static func staleProfileMessage(_ number: String) -> String {
        "#\(number) 的登入資料需要更新：先在終端機執行一次 cswap run \(number)"
    }
}
