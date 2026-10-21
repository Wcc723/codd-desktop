import AppKit
import CoddOnboarding
import Foundation

/// What the wizard asks of the running app (`AppDelegate` in CODD; fakes in tests). Every effect
/// goes through here: the controller itself only holds the wizard's state.
@MainActor
protocol OnboardingHost: AnyObject {
    /// One environment probe and the import catalog (D5: only while the wizard shows; the I/O
    /// runs off the main actor).
    func onboardingProbe() async -> OnboardingProbeResult
    /// The sidebar's groups now (suggestions after an import).
    func onboardingExistingGroups() -> [ExistingGroup]
    /// Step 2's `下一步`: the plan into the sidebar.
    func onboardingApply(_ plan: ImportPlan) -> OnboardingImport.Outcome
    /// Step 3 `預覽變更`: dialog B with the `update` plan over the wizard's window.
    func onboardingPreviewHooks(on window: NSWindow?)
    /// Step 4 `在 Finder 中顯示` (a background run logs and skips it).
    func onboardingRevealNotes()
    /// Step 4 `註冊…`: the M4 registration dialog over the wizard's window.
    func onboardingRegisterClaudeCode(on window: NSWindow?)
    /// Step 4 `複製設定…`: the M4 Codex snippet sheet over the wizard's window.
    func onboardingCopyCodexSnippet(on window: NSWindow?)
    /// Step 5 `+ 加入帳號`: dialog C (it needs the main window, D13).
    func onboardingAddAccount()
    /// Step 6 `允許通知`.
    func onboardingRequestNotifications() async -> DoneStepModel.Notifications
    /// The wizard ended (開始使用, 略過 on step 6, the window closed): `firstProject` is the first
    /// imported project, if any.
    func onboardingEnded(firstProject: ProjectID?)
    func onboardingLog(_ line: String)
    /// FB: step 5's cswap guide `複製` (D39 pasteboard).
    func onboardingCopyCommand(_ command: String)
    /// FB: step 5's cswap guide `在終端機執行` (an ephemeral SHELL session with the command typed, not run).
    func onboardingRunInTerminal(_ command: String)
    /// FB: before `↻ 重新偵測` probes, look for cswap again while it is missing or too old (it may
    /// have just been installed from the guide).
    func onboardingRelocateCswap() async
}

extension OnboardingHost {
    // Hosts without a pasteboard, sessions or cswap (test fakes) do nothing.
    func onboardingCopyCommand(_ command: String) {}
    func onboardingRunInTerminal(_ command: String) {}
    func onboardingRelocateCswap() async {}
}

/// The first-launch wizard's state (M5 D5–D13): the flow, the probed facts, step 2's selection,
/// what was imported and asked, and the view model drawn from them. Mock mode draws
/// `OnboardingSamples` and never writes `onboarding.json`.
@MainActor
final class OnboardingController {
    enum Source: Equatable { case live, mock }

    let source: Source
    /// Why it opened (`new-root`, `reopen-help`, …; the dump's `reason`).
    let reason: String
    private weak var host: OnboardingHost?
    /// nil in mock mode (it never writes).
    let stateStore: OnboardingStateStore?
    private(set) var flow: OnboardingFlow
    private(set) var probe: OnboardingProbeResult?
    private(set) var importStep: ImportStepModel
    private(set) var notifications: DoneStepModel.Notifications = .notAsked
    private(set) var importedProjects = 0
    private(set) var importedGroups = 0
    /// Step 2 was left with 下一步 (`done`) or 略過 (`skipped`); nil: not yet.
    private(set) var importHandled: StepProgress?
    private(set) var firstImportedProject: ProjectID?
    /// `● 已套用 · 備份 <name>` once dialog B wrote during the wizard.
    private(set) var appliedBackup: String?
    private(set) var hooksApplied = false
    private(set) var isProbing = false
    private var probeAgain = false
    private(set) var probeCount = 0
    /// The state written when it ended (nil while open or after a quit).
    private(set) var endedState: OnboardingState?
    private(set) var savedFile: String?
    private(set) var hasEnded = false
    /// Set when CODD quits: a window closing then is not an ending (D7: ⌘Q writes nothing).
    var isQuitting = false
    /// The model changed (the window updates its view; the dump follows).
    var onChange: (() -> Void)?
    let home: String
    let timeZone: TimeZone
    private let now: () -> Date
    let versionLine: String

    init(source: Source, reason: String, start: OnboardingStep, host: OnboardingHost?, stateStore: OnboardingStateStore?,
         home: String = NSHomeDirectory(), timeZone: TimeZone = .current, now: @escaping () -> Date = { Date() },
         versionLine: String = OnboardingViewModel.versionLine(shortVersion: CoddIdentity.version, build: CoddIdentity.build,
                                                               os: ProcessInfo.processInfo.operatingSystemVersion)) {
        self.source = source
        self.reason = reason
        self.host = host
        self.home = home
        self.timeZone = timeZone
        self.now = now
        self.versionLine = versionLine
        switch source {
        case .mock:
            let sample = OnboardingSamples.step(start)
            flow = sample.flow
            importStep = sample.importStep
            notifications = sample.done.notifications
            self.stateStore = nil
        case .live:
            flow = OnboardingLaunch.flow(start: start)
            importStep = ImportStepModel.make(catalog: .empty, selection: ImportSelection(), existing: [], now: now(),
                                              timeZone: timeZone, home: home)
            self.stateStore = stateStore
        }
    }

    // MARK: Model

    /// What the window draws (nil before the first live probe finished).
    var model: OnboardingViewModel? {
        switch source {
        case .mock: mockModel
        case .live: probe.map(liveModel)
        }
    }

    /// The sample of the current step with this wizard's flow, selection and answer.
    private var mockModel: OnboardingViewModel {
        var model = OnboardingSamples.step(flow.current)
        model.flow = flow
        model.importStep = importStep
        model.stepDetails[.importProjects] = "已選 \(importStep.checkedCount) / \(importStep.catalog.visibleTotal)"
        model.done.notifications = notifications
        return model
    }

    private func liveModel(_ probe: OnboardingProbeResult) -> OnboardingViewModel {
        let facts = probe.facts
        let report = EnvironmentReport.make(facts, step: flow.current, imported: importHandled == nil ? nil : importedProjects,
                                            timeZone: timeZone, home: home)
        let hooks = HooksStepModel.make(hooks: facts.hooks, statusline: probe.statusline,
                                        sessionHooks: (probe.sessionHooksInstalled, probe.sessionHooksTotal), foreign: probe.foreign,
                                        appliedBackup: appliedBackup)
        var notebook = NotebookStepModel.make(notesPath: probe.notesPath, mcpEndpoint: facts.dataRoot.mcpEndpoint,
                                              mcpRunning: facts.dataRoot.mcpRunning, claudeCodeRegistered: probe.claudeCodeRegistered,
                                              codexAvailable: probe.codexAvailable)
        if probe.claudeCodeRegistered == nil, let reason = probe.claudeCodeReason { notebook.claudeCodeState = "○ 未註冊 · \(reason)" }
        var accounts: Int?
        if case .ready(_, _, let count) = facts.cswap { accounts = count }
        let done = DoneStepModel.make(imported: importedProjects > 0 ? (importedProjects, importedGroups) : nil,
                                      hooks: hooksOutcome(pending: hooks.pending), notesPath: probe.notesPath, accounts: accounts,
                                      notifications: notifications)
        return OnboardingViewModel(flow: flow, boot: report, versionLine: versionLine, showsWebImportLink: probe.webLeftovers,
                                   stepDetails: OnboardingViewModel.stepDetails(facts: facts, report: report, importStep: importStep,
                                                                                notesPath: probe.notesPath),
                                   detect: DetectItem.items(for: facts, home: home), importStep: importStep, hooks: hooks,
                                   notebook: notebook, accounts: AccountsStepModel.make(cswap: facts.cswap, rows: probe.accountRows),
                                   done: done)
    }

    /// The model on `step` (the earlier steps done) for `-codd-show onboarding:all` snapshots:
    /// mock mode's sample of that step, or this wizard's live facts on it.
    func snapshotModel(for step: OnboardingStep) -> OnboardingViewModel? {
        switch source {
        case .mock: return OnboardingSamples.step(step)
        case .live:
            guard let probe else { return nil }
            let kept = flow
            flow = OnboardingLaunch.flow(start: step)
            defer { flow = kept }
            return liveModel(probe)
        }
    }

    /// Step 6's hooks line: applied during the wizard, skipped, nothing to do, or left pending.
    func hooksOutcome(pending: Int) -> DoneStepModel.HooksOutcome {
        if hooksApplied { return .applied }
        if flow.state(of: .hooks) == .skipped { return .skipped }
        return pending == 0 ? .upToDate : .notApplied
    }

    private func changed() {
        onChange?()
    }

    // MARK: Probe

    /// The first probe (live) or nothing (mock). The window shows once it returns.
    func start() async {
        guard source == .live else { return }
        await redetect()
    }

    /// `↻ 重新偵測` (and the first probe): every fact again; step 2 keeps its choices for the
    /// projects still there.
    func redetect() async {
        guard source == .live, let host, !hasEnded else { return }
        guard !isProbing else {
            // Asked again while a probe runs: one more probe after it.
            probeAgain = true
            return
        }
        isProbing = true
        let result = await host.onboardingProbe()
        isProbing = false
        probeCount += 1
        let first = probe == nil
        probe = result
        if first {
            importStep = ImportStepModel.initial(catalog: result.catalog, existing: result.existingGroups, now: now(), timeZone: timeZone,
                                                 home: home)
        } else {
            let candidates = Set(result.catalog.candidates.map(\.path))
            var selection = importStep.selection
            selection.checked = selection.checked.filter(candidates.contains)
            importStep = ImportStepModel.make(catalog: result.catalog, selection: selection, existing: result.existingGroups, now: now(),
                                              timeZone: timeZone, home: home)
        }
        changed()
        if probeAgain, !hasEnded {
            probeAgain = false
            await redetect()
        }
    }

    // MARK: Actions

    /// The primary button (`下一步：… →`, ⏎). On step 2 the selection is imported first; on step 6
    /// it is `開始使用`.
    func next() {
        guard !hasEnded else { return }
        if flow.current == .done { return finish(.done) }
        if flow.current == .importProjects { applyImport() }
        flow.next()
        changed()
    }

    /// `略過`: the step is left as it is (step 2 imports nothing); on step 6 it ends the wizard
    /// without asking for notifications.
    func skip() {
        guard !hasEnded else { return }
        if flow.current == .done { return finish(.skipped) }
        if flow.current == .importProjects, importHandled == nil { importHandled = .skipped }
        flow.skip()
        changed()
    }

    func back() {
        guard !hasEnded else { return }
        flow.back()
        changed()
    }

    /// A done or skipped stepper row, or a `第 n 步 →` / D12 jump forward: the steps between
    /// stay as they are (step 1 only reads, so leaving it counts as done).
    func go(to step: OnboardingStep) {
        guard !hasEnded else { return }
        if !flow.go(to: step) {
            var states: [OnboardingStep: StepProgress] = [:]
            for other in OnboardingStep.allCases { states[other] = flow.state(of: other) }
            if flow.current == .detect { states[.detect] = .done }
            flow = OnboardingFlow(current: step, states: states)
        }
        changed()
    }

    /// Step 2's selection after a change (the view applied it already; the model follows, so
    /// the next `update` draws the same).
    func importChanged(_ selection: ImportSelection) {
        guard !hasEnded else { return }
        importStep = importStep.with(selection)
        changed()
    }

    /// `依父資料夾建議分組` on the current selection.
    func applySuggestions() {
        importChanged(importStep.selection.applyingSuggestions(importStep.suggestion))
    }

    /// Step 2 → sidebar (D8). The imported rows leave the table (they are in CODD now) and nothing
    /// stays checked, so going back and on again never imports twice.
    private func applyImport() {
        let plan = importStep.plan
        importHandled = .done
        guard !plan.isEmpty else {
            host?.onboardingLog("onboarding import projects=0 groups=0")
            return
        }
        switch source {
        case .mock:
            importedProjects += plan.additions.count
            importedGroups += plan.groupCount
            host?.onboardingLog("onboarding import projects=\(plan.additions.count) groups=\(plan.groupCount) (mock: nothing added)")
        case .live:
            guard let host else { return }
            let outcome = host.onboardingApply(plan)
            importedProjects += outcome.projects
            importedGroups += outcome.groups
            if firstImportedProject == nil { firstImportedProject = outcome.firstProject }
            host.onboardingLog("onboarding import projects=\(outcome.projects) groups=\(outcome.groups)")
            let added = Set(outcome.paths)
            let catalog = importStep.catalog
            let remaining = ProjectCatalog(source: catalog.source,
                                           candidates: catalog.candidates.filter { !added.contains(HolderSessionStore.standardize($0.path)) },
                                           alreadyInCODD: catalog.alreadyInCODD + added.count, problem: catalog.problem)
            var selection = importStep.selection
            selection.checked = []
            selection.newGroups = []
            importStep = ImportStepModel.make(catalog: remaining, selection: selection, existing: host.onboardingExistingGroups(),
                                              now: now(), timeZone: timeZone, home: home)
        }
    }

    // MARK: Changes from elsewhere

    /// Dialog B closed (the installer inspected the file again): step 3's rows from the new
    /// inspection; when it wrote `settings.json` (`backup`: the backup's name, nil when the file
    /// was created) step 3 says `● 已套用 · 備份 <name>`.
    func updateHooks(_ hooks: EnvironmentFacts.Hooks, statusline: HooksStepModel.Statusline, foreign: [HooksStepModel.Foreign],
                     webLeftovers: Bool, applied: Bool, backup: String?) {
        guard !hasEnded else { return }
        if applied {
            hooksApplied = true
            appliedBackup = backup ?? "（新檔案，無備份）"
        }
        if source == .live, var probe {
            probe.facts.hooks = hooks
            probe.statusline = statusline
            probe.foreign = foreign
            probe.webLeftovers = webLeftovers
            self.probe = probe
        }
        changed()
    }

    /// The accounts changed while the wizard shows (dialog C added one, cswap's state moved).
    func updateAccounts(_ cswap: EnvironmentFacts.Cswap, rows: [AccountsStepModel.Row]) {
        guard source == .live, !hasEnded, var probe, probe.facts.cswap != cswap || probe.accountRows != rows else { return }
        probe.facts.cswap = cswap
        probe.accountRows = rows
        self.probe = probe
        changed()
    }

    /// The registration dialog closed: step 4's CLAUDE CODE and CODEX rows again.
    func updateRegistration(registered: Bool?, reason: String?, codexAvailable: Bool) {
        guard source == .live, !hasEnded, var probe else { return }
        guard probe.claudeCodeRegistered != registered || probe.claudeCodeReason != reason || probe.codexAvailable != codexAvailable
        else { return }
        probe.claudeCodeRegistered = registered
        probe.claudeCodeReason = reason
        probe.codexAvailable = codexAvailable
        self.probe = probe
        changed()
    }

    /// Step 6 `允許通知`.
    func requestNotifications() async {
        guard !hasEnded, notifications != .asking else { return }
        notifications = .asking
        changed()
        let answer: DoneStepModel.Notifications = await host?.onboardingRequestNotifications() ?? .suppressed
        notifications = answer
        host?.onboardingLog("onboarding notifications=\(answer.rawValue)")
        changed()
    }

    // MARK: Ending (D7)

    /// 開始使用 (`.done`), 略過 on step 6 or a closed window (`.skipped`): `onboarding.json` (live
    /// mode), then the main window.
    func finish(_ finishing: StepProgress) {
        guard !hasEnded else { return }
        hasEnded = true
        let state = OnboardingState(flow: flow, finishing: finishing,
                                    imported: .init(projects: importedProjects, groups: importedGroups),
                                    notifications: OnboardingState.notifications(notifications), appVersion: CoddIdentity.version,
                                    build: CoddIdentity.build, completedAt: now())
        endedState = state
        if let stateStore {
            do {
                try stateStore.save(state)
                savedFile = stateStore.url.path
                host?.onboardingLog("onboarding saved file=\(stateStore.url.lastPathComponent) finishing=\(finishing.rawValue) "
                                    + "imported=\(importedProjects) notifications=\(state.notifications.rawValue)")
            } catch {
                host?.onboardingLog("error onboarding.json not saved: \(error)")
            }
        } else {
            host?.onboardingLog("onboarding ended finishing=\(finishing.rawValue) (mock: onboarding.json not written)")
        }
        changed()
        host?.onboardingEnded(firstProject: firstImportedProject)
    }

    /// The window was closed by the user (D7: it counts as ended; never on quit).
    func windowClosed() {
        guard !hasEnded, !isQuitting else { return }
        finish(.skipped)
    }
}
