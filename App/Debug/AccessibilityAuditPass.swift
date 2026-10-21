#if DEBUG
import AppKit
import CoddOnboarding
import CoddSettingsUI
import CoddUI

/// `-codd-a11y-audit <file>` (M5 D21, plan §2.6), mock mode: visits every main screen with the
/// SPEC §5 data and runs `AccessibilityAudit` on each window, sheet and panel it shows. The main
/// window, Settings, the sheets, dialog C and onboarding are ordered the usual way, which in a
/// background run keeps them behind every other app (`BackgroundWindows`); the menu bar panel is
/// only laid out offscreen (`debugLaidOutPanel`: never ordered in, never on the menu bar), and the
/// problem banner is audited in a window that is never shown.
///
/// Writes `{"screens":[Report…],"unlabeled":n,"outsideKeyLoop":n}`, prints one `A11Y screen=…` line
/// per report, one line per finding and `A11Y screens=<n> unlabeled=<n> outsideKeyLoop=<n>`; the
/// caller exits 3 when anything is unlabeled.
@MainActor
struct AccessibilityAuditPass {
    let app: AppDelegate
    let output: URL
    /// `-codd-a11y-screens`: names or prefixes (`settings`, `onboarding`); empty runs every screen.
    let filter: [String]

    /// Every screen, in visiting order.
    static let screenNames: [String] =
        ["sessions-waiting", "sessions-shell", "sessions-ext", "home",
         "notes-notebook", "notes-files", "notes-cleanup", "notes-annotate", "status"]
        + SettingsSection.allCases.map { "settings-\($0.rawValue)" }
        + ["menubar", "palette", "new-session", "new-session-dropdown",
           "dialog-a", "dialog-b", "dialog-c", "dialog-d", "problem-banner"]
        + OnboardingStep.allCases.map { "onboarding-\($0.rawValue)" }

    /// The screens `filter` picks (a name, or a prefix before a `-`), in visiting order.
    static func selected(_ filter: [String]) -> [String] {
        guard !filter.isEmpty else { return screenNames }
        return screenNames.filter { name in filter.contains { name == $0 || name.hasPrefix($0 + "-") } }
    }

    /// A finding the pass leaves out, with its reason (plan §8: an AppKit internal the audit would
    /// count). Only with a reason per entry; none has been needed so far.
    struct Ignore {
        let screen: String
        let path: String
        let problem: String
        let reason: String
    }

    static let ignores: [Ignore] = []

    /// The mock sessions SPEC §5 shows: a waiting one, a shell and an external.
    static let waitingSession: SessionID = "s1"
    static let shellSession: SessionID = "s8"
    static let externalSession: SessionID = "s14"

    // MARK: Run

    /// The exit code: 3 when an element is unlabeled, 0 otherwise.
    func run() async -> Int32 {
        var reports: [AccessibilityAudit.Report] = []
        for name in Self.selected(filter) {
            let screenReports = await visit(name).map(Self.applyingIgnores)
            if screenReports.isEmpty { print("A11Y screen=\(name) skipped (not shown)") }
            for report in screenReports {
                print("A11Y screen=\(report.screen) interactive=\(report.interactive) unlabeled=\(report.unlabeled.count) "
                      + "outsideKeyLoop=\(report.outsideKeyLoop.count)")
                for finding in report.unlabeled + report.outsideKeyLoop {
                    print("A11Y \(finding.problem) screen=\(report.screen) role=\(finding.role) "
                          + "label=\(finding.label ?? "-") path=\(finding.path)")
                }
            }
            reports += screenReports
        }
        let summary = AccessibilityAudit.Summary(screens: reports)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(summary).write(to: output, options: .atomic)
        } catch {
            print("A11Y error writing \(output.path): \(error)")
        }
        print("A11Y screens=\(reports.count) unlabeled=\(summary.unlabeled) outsideKeyLoop=\(summary.outsideKeyLoop)")
        return summary.unlabeled > 0 ? 3 : 0
    }

    static func applyingIgnores(_ report: AccessibilityAudit.Report) -> AccessibilityAudit.Report {
        let rules = ignores.filter { report.screen == $0.screen || report.screen.hasPrefix($0.screen + " ") }
        guard !rules.isEmpty else { return report }
        func kept(_ finding: AccessibilityAudit.Finding) -> Bool {
            !rules.contains { $0.problem == finding.problem && finding.path.contains($0.path) }
        }
        return AccessibilityAudit.Report(screen: report.screen, interactive: report.interactive,
                                         unlabeled: report.unlabeled.filter(kept), outsideKeyLoop: report.outsideKeyLoop.filter(kept))
    }

    // MARK: Screens

    private func visit(_ name: String) async -> [AccessibilityAudit.Report] {
        if name.hasPrefix("settings-") { return await settings(String(name.dropFirst("settings-".count)), screen: name) }
        if name.hasPrefix("onboarding-"), let raw = Int(name.dropFirst("onboarding-".count)),
           let step = OnboardingStep(rawValue: raw) {
            return await onboarding(step, screen: name)
        }
        closeSettings()
        switch name {
        case "sessions-waiting": return await session(Self.waitingSession, screen: name)
        case "sessions-shell": return await session(Self.shellSession, screen: name)
        case "sessions-ext": return await session(Self.externalSession, screen: name)
        case "home":
            app.shell.area = .sessions
            app.shell.currentSessionID = nil
            return await mainWindow(name)
        case "notes-notebook":
            app.showNotebookMode(nil)
            return await mainWindow(name)
        case "notes-files":
            await app.debugShowFiles("orb-toolkit-frontend/src/pages/punch.vue")
            return await mainWindow(name)
        case "notes-cleanup":
            app.openCleanup()
            return await mainWindow(name)
        case "notes-annotate":
            await app.debugShowAnnotate("rwd-punch-k7x2:9f3a1c.png")
            let reports = await mainWindow(name)
            app.notesArea?.cancelAnnotate()
            return reports
        case "status":
            app.shell.area = .status
            return await mainWindow(name)
        case "menubar":
            guard let panel = await app.statusItem?.debugLaidOutPanel() else { return [] }
            return AccessibilityAudit.auditIncludingAttachedWindows(panel, screen: name)
        case "palette":
            app.shell.area = .sessions
            app.mainWindow?.show(Self.waitingSession)
            app.showQuickSwitch(nil)
            await settle()
            defer { app.palette?.close() }
            guard let palette = app.palette, palette.isShown else { return [] }
            return AccessibilityAudit.auditIncludingAttachedWindows(palette.panel, screen: name)
        case "new-session", "new-session-dropdown":
            return await newSession(dropdown: name == "new-session-dropdown", screen: name)
        case "dialog-a", "dialog-b", "dialog-c", "dialog-d":
            return await dialog(name)
        case "problem-banner":
            return problemBanner(name)
        default:
            return []
        }
    }

    /// Lets deferred layout, observation loops and first draws land.
    private func settle(_ milliseconds: Int = 350) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
        for window in NSApp.windows where window.isVisible { window.contentView?.layoutSubtreeIfNeeded() }
    }

    private func mainWindow(_ screen: String) async -> [AccessibilityAudit.Report] {
        await settle()
        guard let window = app.mainWindow?.window else { return [] }
        return AccessibilityAudit.auditIncludingAttachedWindows(window, screen: screen)
    }

    private func session(_ id: SessionID, screen: String) async -> [AccessibilityAudit.Report] {
        app.showMainWindow(nil)
        app.shell.area = .sessions
        app.mainWindow?.show(id)
        app.shell.select(.claude, in: id)
        return await mainWindow(screen)
    }

    // MARK: Settings (13 sections)

    private func settings(_ section: String, screen: String) async -> [AccessibilityAudit.Report] {
        let first = app.settings?.window?.isVisible != true
        app.openSettings(section: section)
        if first { await app.settings?.coordinator.refreshSlowFacts() }
        await settle(200)
        guard let window = app.settings?.window else { return [] }
        return AccessibilityAudit.auditIncludingAttachedWindows(window, screen: screen)
    }

    private func closeSettings() {
        guard let window = app.settings?.window, window.isVisible else { return }
        window.close()
    }

    // MARK: Sheets and dialogs

    private func newSession(dropdown: Bool, screen: String) async -> [AccessibilityAudit.Report] {
        app.shell.area = .sessions
        app.mainWindow?.show(Self.waitingSession)
        app.presentNewSession(NewSessionForm(), openDropdown: dropdown)
        await settle(450)
        defer { app.newSessionSheet?.close() }
        guard let sheet = app.newSessionSheet else { return [] }
        if dropdown {
            guard sheet.isDropdownOpen else { return [] }
            return AccessibilityAudit.auditIncludingAttachedWindows(sheet.dropdown, screen: screen)
        }
        guard let window = sheet.window else { return [] }
        // The sheet alone (its open project list is the next screen).
        return [AccessibilityAudit.audit(window: window, screen: screen)]
    }

    /// A 切換帳號確認, B Hook 差異, C 加入帳號 (a child panel), D 結束.
    private func dialog(_ name: String) async -> [AccessibilityAudit.Report] {
        app.shell.area = .sessions
        app.mainWindow?.show(Self.waitingSession)
        switch name {
        case "dialog-a":
            let accounts = app.accountStore
            guard let target = accounts.accounts.first(where: { $0.id != accounts.activeAccountID && !$0.isPseudo }) else { return [] }
            app.switchDialogs?.show(target.id, in: accounts)
            await settle()
            defer { app.switchDialogs?.current?.cancel() }
            guard let sheet = app.switchDialogs?.current?.sheet else { return [] }
            return AccessibilityAudit.auditIncludingAttachedWindows(sheet, screen: name)
        case "dialog-b":
            app.presentHookDiff(.update)
            await settle()
            defer { app.debugDismissMockDialogs() }
            guard let sheet = app.mockSheet else { return [] }
            return AccessibilityAudit.auditIncludingAttachedWindows(sheet, screen: name)
        case "dialog-c":
            app.presentAddAccount()
            await settle()
            defer { app.debugDismissMockDialogs() }
            guard let panel = app.debugMockPanel else { return [] }
            return AccessibilityAudit.auditIncludingAttachedWindows(panel, screen: name)
        case "dialog-d":
            app.presentQuitDialog()
            await settle()
            defer { app.quitDialog.dismiss() }
            guard let window = app.quitDialog.window else { return [] }
            return AccessibilityAudit.auditIncludingAttachedWindows(window, screen: name)
        default:
            return []
        }
    }

    /// The problem banner with a data file moved aside (`[在 Finder 中顯示] [知道了]`), in a window
    /// that is never shown (mock mode's store reports no problem).
    private func problemBanner(_ screen: String) -> [AccessibilityAudit.Report] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 44), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let banner = ProblemBannerView(frame: NSRect(x: 0, y: 0, width: 900, height: 44))
        window.contentView = banner
        let problem = StoreProblem(message: "layout.json 無法讀取，已移到 layout.json.corrupt-1760000000000，改用預設值",
                                   at: Date().addingTimeInterval(-12), revealPath: "/tmp/layout.json.corrupt-1760000000000", queued: true)
        banner.update(problem, now: Date())
        banner.layoutSubtreeIfNeeded()
        return [AccessibilityAudit.audit(window: window, screen: screen)]
    }

    // MARK: Onboarding (steps 1–6, OnboardingSamples)

    private func onboarding(_ step: OnboardingStep, screen: String) async -> [AccessibilityAudit.Report] {
        closeSettings()
        if app.onboarding?.isOpen != true {
            app.openOnboarding(start: .detect, reason: "a11y-audit")
            let deadline = ContinuousClock.now + .seconds(10)
            while app.onboarding?.window == nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        }
        guard let presenter = app.onboarding, let window = presenter.window, let view = presenter.windowController?.onboardingView,
              let model = presenter.controller.snapshotModel(for: step) else { return [] }
        view.update(model)
        await settle(200)
        let reports = AccessibilityAudit.auditIncludingAttachedWindows(window, screen: screen)
        // The last step ends the wizard (mock mode writes nothing).
        if step == OnboardingStep.allCases.last { presenter.controller.finish(.done) }
        return reports
    }
}

extension AppDelegate {
    /// Runs the pass, then ends the run (`exit`, as `-CODDSelfTest` does; the mock notebook goes first).
    func runAccessibilityAudit(_ path: String) async {
        if let refusal = RealModeOptions.protectedPathReason(path) {
            print("A11Y refused: \(path) (\(refusal))")
            removeMockNotes()
            exit(64)
        }
        let code = await AccessibilityAuditPass(app: self, output: URL(fileURLWithPath: path), filter: realOptions.a11yScreens).run()
        removeMockNotes()
        exit(code)
    }
}
#endif
