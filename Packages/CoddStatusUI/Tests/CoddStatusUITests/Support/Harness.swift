import AppKit
import CoddUI
@testable import CoddStatusUI

/// Records every action the views call.
@MainActor
final class ActionLog {
    private(set) var events: [String] = []
    /// The answer to the auto-switch confirmation (FB): nil leaves it unanswered.
    var confirmAnswer: Bool? = true
    /// The cswap guide's buttons (FB).
    private(set) var guideEvents: [String] = []

    var guideActions: CswapGuideActions {
        CswapGuideActions(copy: { [weak self] text in self?.guideEvents.append("copy:\(text)") },
                          runInTerminal: { [weak self] text in self?.guideEvents.append("run:\(text)") })
    }

    func record(_ event: String) { events.append(event) }

    var actions: StatusPageActions {
        StatusPageActions(
            refresh: { [weak self] in self?.record("refresh") },
            togglePause: { [weak self] in self?.record("togglePause") },
            openSessions: { [weak self] in self?.record("openSessions") },
            openSession: { [weak self] id in self?.record("openSession:\(id)") },
            switchAccount: { [weak self] id in self?.record("switchAccount:\(id)") },
            addAccount: { [weak self] in self?.record("addAccount") },
            openAutoSwitch: { [weak self] in self?.record("openAutoSwitch") },
            toggleAutoSwitch: { [weak self] in self?.record("toggleAutoSwitch") },
            previewHooks: { [weak self] in self?.record("previewHooks") },
            update: { [weak self] in self?.record("update") },
            uninstall: { [weak self] in self?.record("uninstall") },
            removeLegacy: { [weak self] in self?.record("removeLegacy") },
            disableDuplicateNotifications: { [weak self] in self?.record("disableDuplicateNotifications") },
            openRemoteSettings: { [weak self] in self?.record("openRemoteSettings") },
            onMCPRegistration: { [weak self] id in self?.record("mcpRegistration:\(id)") },
            onRotateMCPToken: { [weak self] in self?.record("rotateMCPToken") },
            confirmAutoSwitch: { [weak self] _, done in
                self?.record("confirmAutoSwitch")
                if let answer = self?.confirmAnswer { done(answer) }
            })
    }
}

/// The sidebar and page side by side in an offscreen window (never ordered in), on the sample's
/// fixed clock and calendar.
@MainActor
final class StatusHarness {
    let log = ActionLog()
    let sidebar: StatusSidebarView
    let page: StatusPageView
    let window: NSWindow
    var now = StatusSamples.referenceNow

    init(_ model: StatusPageModel = StatusSamples.spec(), size: CGSize = CGSize(width: 1440, height: 1300), inWindow: Bool = true) {
        Self.registerFonts()
        sidebar = StatusSidebarView(actions: log.actions)
        page = StatusPageView(actions: log.actions)
        page.cswapGuideActions = log.guideActions
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let root = FlippedView(frame: CGRect(origin: .zero, size: size))
        sidebar.frame = CGRect(x: 0, y: 0, width: 220, height: size.height)
        page.frame = CGRect(x: 220, y: 0, width: size.width - 220, height: size.height)
        root.addSubview(sidebar)
        root.addSubview(page)
        if inWindow { window.contentView = root }
        for view in [sidebar as NSView, page] {
            if let sidebar = view as? StatusSidebarView {
                sidebar.now = { [unowned self] in self.now }
                sidebar.calendar = StatusSamples.calendar
            }
            if let page = view as? StatusPageView {
                page.now = { [unowned self] in self.now }
                page.calendar = StatusSamples.calendar
            }
        }
        apply(model)
    }

    func apply(_ model: StatusPageModel) {
        sidebar.apply(model)
        page.apply(model)
        settle()
    }

    func settle() {
        sidebar.layoutSubtreeIfNeeded()
        page.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    var pageTexts: [String] { page.visibleTexts }
    var sidebarTexts: [String] { sidebar.visibleTexts }

    func card(_ id: String) -> AccountCardView {
        guard let card = page.accounts.card(id) else { fatalError("no card \(id)") }
        return card
    }

    private static var fontsRegistered = false

    /// Registers App/Fonts from the repository (the tests also pass without them: Typeface falls
    /// back to the system monospaced font).
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        Typeface.registerFonts(in: repo.appendingPathComponent("App/Fonts", isDirectory: true))
    }
}

extension Array where Element == String {
    /// True when `expected` appear in this order (not necessarily adjacent).
    func containsInOrder(_ expected: [String]) -> Bool {
        var index = startIndex
        for item in expected {
            guard let found = self[index...].firstIndex(of: item) else { return false }
            index = found + 1
        }
        return true
    }

    /// The expected strings that are missing (for readable failures).
    func missing(_ expected: [String]) -> [String] { expected.filter { !contains($0) } }
}
