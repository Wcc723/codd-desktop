import CoddPreferences
import Foundation
import Observation
import ServiceManagement

/// The system login item as CODD sees it (D21).
enum LoginItemState: Equatable, Sendable {
    case enabled
    case notRegistered
    /// Registered, but the user has to allow it in System Settings.
    case requiresApproval
    /// The system does not know the app (an ad-hoc build run from a temp folder).
    case notFound
    /// This instance never registers one (a test data root, hosted tests): the reason to show.
    case unavailable(String)

    /// The dump's `loginItem.status`.
    var key: String {
        switch self {
        case .enabled: "enabled"
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        case .unavailable: "unavailable"
        }
    }
}

/// Registers CODD as a login item. Injectable: a login item is lasting system state, so only the
/// standard data root uses the real one (`SMAppService.mainApp`); every other root, hosted tests
/// and automated runs use `DisabledLoginItemService`, which never calls the system (D21).
@MainActor
protocol LoginItemService: AnyObject {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp` (macOS 13+; no helper bundle needed).
@MainActor
final class SystemLoginItemService: LoginItemService {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .notRegistered
        @unknown default: .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

/// A data root that is not the standard one never touches the system's login items.
@MainActor
final class DisabledLoginItemService: LoginItemService {
    static let testRootMessage = "測試資料根目錄不會註冊登入項目"
    let reason: String
    private(set) var calls = 0

    init(reason: String = DisabledLoginItemService.testRootMessage) { self.reason = reason }

    var state: LoginItemState { .unavailable(reason) }
    func register() throws { calls += 1 }
    func unregister() throws { calls += 1 }
}

/// Settings › 一般 › 登入時啟動 (D21): the toggle registers or unregisters, only when it changes
/// (never at launch, so a plain start never alters system state). A refused registration turns
/// the toggle back OFF and says why under the row; `requiresApproval` says where to allow it.
@MainActor @Observable
final class LoginItemController {
    @ObservationIgnored let service: any LoginItemService
    @ObservationIgnored private let preferences: PreferencesService
    @ObservationIgnored private let log: @MainActor (String) -> Void
    /// The text under the row (nil: nothing to say).
    private(set) var statusText: String?
    /// What the toggle last asked for (nil until the first preference value was seen).
    @ObservationIgnored private var applied: Bool?
    /// Whether the system has CODD registered (enabled or awaiting approval).
    private(set) var registered = false

    init(service: any LoginItemService, preferences: PreferencesService, log: @escaping @MainActor (String) -> Void = { _ in }) {
        self.service = service
        self.preferences = preferences
        self.log = log
        refreshStatus()
    }

    static let approvalHint = "請到 系統設定 › 一般 › 登入項目 允許"
    /// M5 D4: 登入時啟動 is ON but the system has no login item for this bundle id (the old id's
    /// entry does not carry over), and CODD never registers at launch (D21).
    static let identityChangedHint = "CODD 換了識別碼：請把「登入時啟動」關掉再打開一次"

    /// The row's text for a state (nil when registered or simply off). `launchAtLogin`: the
    /// preference is ON; then a real service that has CODD neither enabled nor awaiting approval
    /// says so (D4).
    static func text(for state: LoginItemState, launchAtLogin: Bool = false) -> String? {
        switch state {
        case .enabled: nil
        case .notRegistered: launchAtLogin ? identityChangedHint : nil
        case .requiresApproval: approvalHint
        case .notFound: launchAtLogin ? identityChangedHint : "系統找不到這個 App（請從「應用程式」資料夾執行），無法註冊登入項目"
        case .unavailable(let reason): reason
        }
    }

    func refreshStatus() {
        let state = service.state
        registered = state == .enabled || state == .requiresApproval
        let text = Self.text(for: state, launchAtLogin: applied ?? false)
        if statusText != text { statusText = text }
    }

    /// The preferences changed (also at launch: the first value is only remembered, and the row
    /// says whether the system agrees with it, D4).
    func apply(_ general: CoddPreferences.General) {
        let wanted = general.launchAtLogin
        guard let previous = applied else {
            applied = wanted
            refreshStatus()
            return
        }
        guard wanted != previous else { return }
        applied = wanted
        if case .unavailable(let reason) = service.state {
            // A test root: nothing is registered; the toggle keeps the value, the row says why.
            log("login item \(wanted ? "on" : "off") not applied (\(reason))")
            refreshStatus()
            return
        }
        do {
            if wanted { try service.register() } else if registered { try service.unregister() }
            log("login item \(wanted ? "registered" : "unregistered") state=\(service.state.key)")
            refreshStatus()
        } catch {
            log("login item \(wanted ? "register" : "unregister") failed: \(error.localizedDescription)")
            refreshStatus()
            statusText = (wanted ? "無法註冊登入項目：" : "無法取消登入項目：") + error.localizedDescription
            if wanted {
                // D21: the toggle returns to OFF (the next apply sees OFF as already applied).
                applied = false
                preferences.update { $0.general.launchAtLogin = false }
            }
        }
    }

    /// `loginItem {status, registered}` (§6).
    var dumpObject: [String: Any] {
        ["status": service.state.key, "registered": registered, "text": statusText.map { $0 as Any } ?? NSNull(),
         "real": !(service is DisabledLoginItemService)]
    }
}
