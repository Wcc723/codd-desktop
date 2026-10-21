import AppKit
import CoddPreferences

/// Where a quit request came from (D18). It decides, with Settings › 一般 › 結束時, whether
/// dialog D shows.
enum QuitTrigger: String, Equatable, Sendable {
    /// ⌘Q, the app menu's 結束, the Dock's Quit, closing the main window with 關閉視窗時保留在選單列
    /// OFF (D19), DEBUG `-codd-quit-request`.
    case user
    /// The status item's right-click `結束`: dialog D while sessions run, whatever 結束時 says
    /// (the way out when ⌘Q only closes the window).
    case statusItem
    /// Logout, restart or shutdown (the quit Apple event's reason): never asks.
    case system
    /// DEBUG `-codd-quit-after`: a script must never wait for a dialog.
    case automation
    /// Dialog D was answered (`全部停止並結束` done, or `結束 · session 繼續執行`).
    case confirmed
}

/// What `applicationShouldTerminate` does with a request.
enum QuitDecision: String, Equatable, Sendable {
    /// Flush the hooks and quit (holders keep running).
    case terminate
    /// `全部停止`: stop every CODD session and shell tab (≤ 3 s for their EXITs), then quit.
    case stopAllThenTerminate
    /// `保留`: close the main window, CODD stays in the menu bar.
    case closeWindow
    /// `詢問`: dialog D.
    case ask
}

/// D18's decision table, pure. `running` is the live CODD sessions (claude and shell, never
/// externals): with none there is nothing to lose, so nothing asks.
enum QuitPolicy {
    static func decide(behavior: CoddPreferences.QuitBehavior, trigger: QuitTrigger, running: Int) -> QuitDecision {
        switch trigger {
        case .confirmed, .system, .automation:
            return .terminate
        case .statusItem:
            return running > 0 ? .ask : .terminate
        case .user:
            switch behavior {
            case .keep: return .closeWindow
            case .stopAll: return running > 0 ? .stopAllThenTerminate : .terminate
            case .ask: return running > 0 ? .ask : .terminate
            }
        }
    }

    /// The quit Apple event's reason is logout, restart or shutdown (`kAEQuitReason`): the system
    /// is going down and must not wait for CODD. The Dock's Quit sends the event without a reason.
    static func isSystemQuit(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event, event.eventClass == fourCharCode("aevt"), event.eventID == fourCharCode("quit"),
              let reason = event.attributeDescriptor(forKeyword: fourCharCode("why?"))?.enumCodeValue else { return false }
        return systemReasons.contains(reason)
    }

    /// `logo` `rlgo` (log out), `rrst` `rest` (restart), `rsdn` `shut` (shut down).
    static let systemReasons: Set<OSType> = Set(["logo", "rlgo", "rrst", "rest", "rsdn", "shut"].map(fourCharCode))

    static func fourCharCode(_ text: String) -> OSType {
        text.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
    }

    /// `全部停止並結束`: SIGTERM to every live CODD session's holder (it ends its child and jobs)
    /// and every shell tab's, then waits until their EXITs arrived or `timeout` passed. Externals
    /// are never touched. Returns what was signalled and how many sessions still ran at the end.
    @MainActor
    static func stopAll(_ holders: HolderSessionStore, hub: TerminalHub?, timeout: Duration = .seconds(3)) async
        -> (sessions: Int, tabs: Int, left: Int) {
        let ids = holders.sessionsByID.values.filter { $0.state.isLive }.map(\.id)
        holders.stop(ids)
        let tabs = hub?.stopAllTabs() ?? 0
        let deadline = ContinuousClock.now + timeout
        func left() -> Int { ids.filter { holders.session($0)?.state.isLive == true }.count }
        while ContinuousClock.now < deadline, left() > 0 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return (ids.count, tabs, left())
    }
}

/// D20: Settings › 一般 › 顯示於 Dock. OFF is `.accessory` (no Dock icon, no ⌘Tab; the menu bar
/// item stays and main-menu shortcuts still work while CODD is active). A background launch
/// (`AppActivation`) stays `.accessory` whatever the setting says.
enum DockPolicy {
    static func policy(showInDock: Bool, background: Bool) -> NSApplication.ActivationPolicy {
        showInDock && !background ? .regular : .accessory
    }

    static func name(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "unknown"
        }
    }
}
