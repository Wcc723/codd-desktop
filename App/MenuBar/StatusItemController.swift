import AppKit
import CoddPreferences
import CoddUI

/// What the status item shows: the R5 icon state, the D23 paused look (45 %) and, with Settings ›
/// 通知 › 選單列圖示 `圖示 + 數字`, the title `◆2 ▲1` (only the non-zero parts).
struct StatusItemAppearance: Equatable {
    var state: StatusIconState
    var paused: Bool
    var title: String

    /// `◆<waiting> ▲<error>`, empty when both are zero.
    static func countsTitle(waiting: Int, error: Int) -> String {
        [waiting > 0 ? "◆\(waiting)" : nil, error > 0 ? "▲\(error)" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// The look for these sessions and Settings › 通知 (pure: the controller reads it inside
    /// observation tracking, tests call it without a status item).
    @MainActor
    static func make(sessions: [SessionVM], hooksInstalled: Bool, rules: CoddPreferences.Notifications, now: Date) -> StatusItemAppearance {
        let state: StatusIconState
        if !hooksInstalled {
            state = .noHook
        } else {
            state = sessions.contains { $0.state.needsAttention } ? .attention : .normal
        }
        let paused = NotificationRules.isPaused(rules, now: now)
        var title = ""
        if rules.menuBarIcon == .iconAndCounts {
            title = countsTitle(waiting: sessions.filter { $0.state == .waiting }.count, error: sessions.filter { $0.state == .error }.count)
        }
        return StatusItemAppearance(state: state, paused: paused, title: title)
    }
}

/// One NSStatusItem (R5: a single ~28 px icon; D23 adds the optional counts title and the paused
/// look). Left click toggles the panel, right click (or ⌃-click) shows the native menu. The icon
/// image is replaced only when its appearance changes.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: any SessionStore
    private let accounts: any AccountStore
    private let preferences: PreferencesService
    private let presenter: MenuBarPanelPresenter
    private let actions: MenuBarPanelActions
    private var loop: ObservationLoop?
    private(set) var appearance: StatusItemAppearance?
    /// The right-click menu's `結束` (the app delegate tells it from ⌘Q, D18).
    static let quitItemID = "codd.statusItem.quit"
    /// Turns the paused look off when `pausedUntil` passes.
    private var pauseExpiry: Task<Void, Never>?
    /// The D5 toast of a switch picked from the right-click menu (the app shows it in the sidebar).
    var onToast: ((String, (@MainActor () -> Void)?) -> Void)?

    /// The status item's frame autosave (M5 D25): `autosaveName` nil leaves AppKit's own default
    /// name in place, so a test run never moves the installed CODD's menu bar position.
    /// - Parameter autosaveName: `DefaultsIsolation.statusItemName` in real mode on the standard
    ///   data root, nil in every other run.
    init(store: any SessionStore, accounts: any AccountStore, actions: MenuBarPanelActions, shell: ShellState = ShellState(),
         preferences: PreferencesService = .inMemory(), autosaveName: String? = nil) {
        self.store = store
        self.accounts = accounts
        self.preferences = preferences
        self.actions = actions
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        let content = MenuBarPanelView(store: store, accounts: accounts, actions: actions, shell: shell)
        presenter = MenuBarPanelPresenter(content: content)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("CODD")
            // No effectiveAppearance observation: the image's drawing handler resolves
            // `labelColor` at draw time, and AppKit redraws the status item per menu bar
            // appearance itself (observing it and re-setting the image loops forever).
        }
        if let autosaveName { statusItem.autosaveName = autosaveName }
        loop = ObservationLoop(track: { [weak self] () -> StatusItemAppearance in
            self?.currentAppearance() ?? StatusItemAppearance(state: .normal, paused: false, title: "")
        }, apply: { [weak self] appearance in self?.apply(appearance) })
    }

    /// Read inside observation tracking (sessions, hooks, the notification preferences).
    private func currentAppearance() -> StatusItemAppearance {
        StatusItemAppearance.make(sessions: store.allSessions, hooksInstalled: store.host.hooksInstalled,
                                  rules: preferences.preferences.notifications, now: Date())
    }

    /// Whether notifications are paused right now (D23).
    var isPaused: Bool { preferences.preferences.notifications.pausedUntil.map { $0 > Date() } ?? false }

    var isPanelShown: Bool { presenter.isShown }
    /// The popover opened or closed (D36's host line samples while it is open).
    var onPanelVisibilityChange: ((Bool) -> Void)? {
        get { presenter.onVisibilityChange }
        set { presenter.onVisibilityChange = newValue }
    }
    var button: NSStatusBarButton? { statusItem.button }

    func closePanel() { presenter.close() }

    #if DEBUG
    /// `-codd-show menubar` (layout sweep): the panel filled and sized as it opens, never ordered in.
    func debugLaidOutPanel() async -> NSWindow { await presenter.layOutWithoutShowing() }
    #endif

    private func apply(_ next: StatusItemAppearance) {
        schedulePauseExpiry()
        guard next != appearance else { return }
        appearance = next
        redrawIcon()
    }

    private func redrawIcon() {
        guard let appearance, let button = statusItem.button else { return }
        button.image = BrandMark.statusImage(appearance.state, paused: appearance.paused)
        if appearance.title.isEmpty {
            statusItem.length = 28
            button.title = ""
            button.imagePosition = .imageOnly
        } else {
            statusItem.length = NSStatusItem.variableLength
            button.attributedTitle = NSAttributedString(string: " " + appearance.title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium),
            ])
            button.imagePosition = .imageLeading
        }
        var value: [String] = []
        if appearance.state == .attention { value.append("有 session 需要你") }
        if appearance.paused { value.append("通知已暫停") }
        button.setAccessibilityValue(value.isEmpty ? nil : value.joined(separator: "，"))
    }

    /// The paused look ends by itself when the hour is over (nothing else changes then).
    private func schedulePauseExpiry() {
        pauseExpiry?.cancel()
        guard let until = preferences.preferences.notifications.pausedUntil, until > Date() else { return }
        pauseExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow + 0.5)))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.currentAppearance())
        }
    }

    /// `暫停通知 1 小時` / `恢復通知` (D23): `notifications.pausedUntil`; banners and sounds stay
    /// silent meanwhile, badges keep updating.
    func togglePause(now: Date = Date()) {
        let pause = !isPaused
        preferences.update { $0.notifications.pausedUntil = pause ? now.addingTimeInterval(3600) : nil }
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            presenter.close()
            showMenu(from: sender)
        } else {
            presenter.toggle(from: sender)
        }
    }

    // MARK: Right-click menu (native)

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "開啟 CODD") { [actions] in actions.openMain() })
        let new = ClosureMenuItem(title: "新增 session") { [actions] in actions.newSession() }
        new.keyEquivalent = "n"
        menu.addItem(new)
        let note = ClosureMenuItem(title: "快速筆記") { [actions] in actions.quickNote() }
        note.keyEquivalent = "N"
        menu.addItem(note)
        let switchItem = NSMenuItem(title: "切換帳號", action: nil, keyEquivalent: "")
        switchItem.submenu = accountsMenu()
        menu.addItem(switchItem)
        menu.addItem(ClosureMenuItem(title: isPaused ? "恢復通知" : "暫停通知 1 小時") { [weak self] in self?.togglePause() })
        let settings = ClosureMenuItem(title: "設定…") { [actions] in actions.openSettings(nil) }
        settings.keyEquivalent = ","
        menu.addItem(settings)
        menu.addItem(.separator())
        // Through the app delegate (responder chain): it ends attached sheets before quitting.
        let quit = NSMenuItem(title: "結束", action: #selector(CoddCommands.quitApp(_:)), keyEquivalent: "q")
        // D18: this `結束` always asks while sessions run (the way out when ⌘Q only closes the window).
        quit.identifier = NSUserInterfaceItemIdentifier(Self.quitItemID)
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    /// `ACCOUNTS · 依每週重置` submenu: R7 order, ✓ on the active one; a pick runs the D5 switch
    /// (its toast through `onToast`). While a switch runs every entry is disabled.
    func accountsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "Accounts · 依每週重置"))
        for account in accounts.accounts where !account.isPseudo {
            let id = account.id
            let item = ClosureMenuItem(title: "\(account.displayName)    1w \(account.week.valueText)") { [weak self] in
                guard let self else { return }
                AccountSwitching.run(id, in: self.accounts) { [weak self] text, undo in self?.onToast?(text, undo) }
            }
            item.state = account.id == accounts.activeAccountID ? .on : .off
            item.isEnabled = !accounts.isSwitching
            menu.addItem(item)
        }
        if let note = accounts.availability.note, accounts.accounts.allSatisfy(\.isPseudo) {
            let item = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "自動切換  \(accounts.autoSwitch.enabled ? "ON" : "OFF")") { [actions] in
            actions.openSettings("accounts")
        })
        return menu
    }
}
