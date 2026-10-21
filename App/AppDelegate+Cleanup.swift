import AppKit
import CoddCleanupUI
import CoddNotes
import CoddUI

/// M4 I4a: retention, the Cleanup page, the digest and `交給 Claude 濃縮` in the app (D29–D32):
/// building and wiring them, the entry points, the condense account select and the DEBUG flags.
extension AppDelegate {
    // MARK: Wiring

    /// The Cleanup mode of the NOTES area (mock mode: the artboard's sample data).
    func makeCleanupMode() -> CleanupController {
        let notes = self.notes
        let store = sessionStore
        let controller = CleanupController(retention: retention, condense: condense, notes: notes, preferences: preferences, store: store,
                                           presenter: { NotebookPresenter(now: notes.clock(), timeZone: notes.timeZone, store: store, projects: [:]) })
        controller.onOpenSettings = { [weak self] in self?.openSettings(section: "cleanup") }
        controller.accountOptions = { [weak self] in self?.condenseAccountOptions() ?? [] }
        controller.accountHint = { [weak self] id in self?.condenseAccountHint(id) ?? "" }
        controller.accountOverride = realOptions.condenseAccount
        #if DEBUG
        controller.onDumpNeeded = { [weak self] in self?.scheduleStateDump() }
        #endif
        cleanupMode = controller
        configureCondense()
        return controller
    }

    /// Real mode, once the notifier exists: the digest goes through AppNotifier (`cleanup-digest`),
    /// its `查看` opens the Cleanup page; Claude's `cleanupPeriodDays` drives `resume expires`.
    func wireRetention() {
        guard let retention else { return }
        retention.postDigest = { [weak self] title, body in
            self?.appNotifier?.post(.cleanupDigest, title: title, body: body) ?? false
        }
        appNotifier?.onCleanupView = { [weak self] in self?.openCleanup() }
        retention.cleanupPeriodDays = { [weak self] in self?.services?.claudeSettings.cleanupPeriodDays }
        #if DEBUG
        if realOptions.dumpStatePath != nil {
            notesLoops.append(ObservationLoop(track: { () -> String in
                "\(retention.revision)|\(retention.report.runs)|\(retention.lastDigest?.at.timeIntervalSince1970 ?? 0)"
            }, apply: { [weak self] _ in self?.scheduleStateDump() }))
        }
        #endif
    }

    /// The condense run's claude, account and availability (D32, D37).
    private func configureCondense() {
        guard let condense, let holders = holderStore else { return }
        let standard = holders.root == .standard
        let override = realOptions.claudePath
        condense.claudeExecutable = {
            let path = await LoginEnvironment.current()?["PATH"]
            return Self.claudeExecutable(override: override, standardRoot: standard, loginPATH: path)
        }
        condense.unavailableReason = { [weak holders] in
            // D37: a test or throwaway data root runs only the DEBUG claude, never the user's.
            if override == nil, !standard { return CondenseRunner.testRootReason }
            if holders?.hooks?.config == nil { return CondenseRunner.noHooksReason }
            return nil
        }
        condense.configDirectory = { [weak self] account in
            self?.condenseConfigDirectory(account) ?? .success(nil)
        }
    }

    /// `follow` → the global login; `#n` → its cswap profile (M3 D12 rules; the active account is
    /// the global login itself).
    func condenseConfigDirectory(_ account: String) -> Result<String?, CondenseRunner.Refusal> {
        guard account != "follow", let number = Int(account) else { return .success(nil) }
        guard let cswap = cswapAccounts else { return .failure(.init(message: "cswap 的帳號還不能用")) }
        switch cswap.pinResolution(number) {
        case .usable(let path): return .success(path)
        case .active: return .success(nil)
        case .notReady: return .failure(.init(message: "還在讀取 cswap 的帳號，請稍候再試一次。"))
        case .unknownAccount: return .failure(.init(message: "沒有 #\(number) 這個 cswap 帳號。"))
        case .needsProfile: return .failure(.init(message: AccountPinOptions.staleProfileMessage(String(number))))
        }
    }

    /// `跟隨全域登入（#3 工作）`, then each cswap account; one without a usable profile is disabled
    /// with why (D12).
    func condenseAccountOptions() -> [CondenseAccountOption] {
        SettingsInfoBuilder.condenseAccounts(accountStore).map { entry in
            guard entry.id != "follow", let number = Int(entry.id), let cswap = cswapAccounts else {
                return CondenseAccountOption(id: entry.id, title: entry.title)
            }
            switch cswap.pinResolution(number) {
            case .usable, .active:
                return CondenseAccountOption(id: entry.id, title: entry.title)
            case .needsProfile:
                return CondenseAccountOption(id: entry.id, title: entry.title, enabled: false,
                                             hint: AccountPinOptions.staleProfileMessage(String(number)))
            case .notReady:
                return CondenseAccountOption(id: entry.id, title: entry.title, enabled: false, hint: "還在讀取 cswap 的帳號")
            case .unknownAccount:
                return CondenseAccountOption(id: entry.id, title: entry.title, enabled: false, hint: "cswap 沒有這個帳號")
            }
        }
    }

    /// `#1 個人 5h 未開始 · 1w 剩 100% · 不佔用 #3 工作的額度`.
    func condenseAccountHint(_ id: String) -> String {
        let active = accountStore.activeAccountID.flatMap { accountStore.account($0) }
        let account = id == "follow" ? active : accountStore.account(id)
        guard let account else { return id == "follow" ? "使用目前的全域登入" : "" }
        func quota(_ window: QuotaWindow) -> String {
            guard window.known else { return "—" }
            return window.started ? "剩 \(window.remainingPercent)%" : "未開始"
        }
        var text = "\(account.displayName) 5h \(quota(account.fiveHour)) · 1w \(quota(account.week))"
        if id != "follow", let active, active.id != account.id { text += " · 不佔用 \(active.displayName) 的額度" }
        return text
    }

    // MARK: Entry points

    /// The menu bar's `清理建議 n →`, Settings › 清理's head button and the digest's `查看` (user
    /// actions): the main window on NOTES with the Cleanup page.
    func openCleanup() {
        statusItem?.closePanel()
        showMainWindow(nil)
        shell.area = .notes
        notesArea?.showCleanupMode()
    }

    #if DEBUG
    // MARK: DEBUG flags (§6, I4a)

    /// `-codd-show cleanup`, `-codd-retention-run`, `-codd-cleanup-action`, `-codd-condense`
    /// (+ `-codd-condense-account`, `-codd-condense-apply`).
    func runCleanupDebugActions() async {
        let o = realOptions
        if o.showKeyword == "cleanup" {
            shell.area = .notes
            notesArea?.showCleanupMode()
            HolderSessionStore.printLog("debug show cleanup shown=\(notesArea?.mode == .cleanup)")
        }
        guard let retention else { return }
        if o.retentionRun || o.cleanupAction != nil || o.condense != nil { await retention.start() }
        if o.retentionRun {
            let report = await retention.run(reason: "debug")
            HolderSessionStore.printLog("debug retention-run runs=\(report.runs) archived=\(report.archived.count) purged=\(report.purged.count) "
                                        + "sessionsArchived=\(report.sessionsArchived.count) rings=\(report.ringsTrashed.count)")
        }
        if let spec = o.cleanupAction { await debugCleanupAction(spec) }
        if let spec = o.condense { await debugCondense(spec, apply: o.condenseApply) }
        scheduleStateDump()
    }

    /// `<notes|sessions|files>:<id,id…>:keep|archive|trash`.
    private func debugCleanupAction(_ spec: String) async {
        guard let first = spec.firstIndex(of: ":"), let last = spec.lastIndex(of: ":"), first < last,
              let tab = CleanupTab(rawValue: String(spec[..<first]).lowercased()), let cleanupMode, let retention else {
            HolderSessionStore.printLog("debug cleanup-action refused spec")
            return
        }
        let ids = spec[spec.index(after: first)..<last].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let actions = ["keep": CleanupRowAction.keep, "archive": CleanupRowAction.archive, "trash": CleanupRowAction.trash]
        guard let action = actions[String(spec[spec.index(after: last)...]).lowercased()] else {
            HolderSessionStore.printLog("debug cleanup-action refused action")
            return
        }
        await retention.refresh()
        let before = retention.candidates.total
        await cleanupMode.act(action, ids: ids, tab: tab)
        HolderSessionStore.printLog("debug cleanup-action tab=\(tab.rawValue) ids=\(ids.count) action=\(action) "
                                    + "before=\(before) after=\(retention.candidates.total)")
    }

    /// `交給 Claude 濃縮…` with those notes, a run, then (with `-codd-condense-apply YES`) the apply.
    private func debugCondense(_ spec: String, apply: Bool) async {
        guard let cleanupMode, let condense, let retention else {
            HolderSessionStore.printLog("debug condense unavailable")
            return
        }
        shell.area = .notes
        notesArea?.showCleanupMode(tab: .notes)
        // A pinned account needs cswap's state read first (the launch reads it in parallel).
        if let account = realOptions.condenseAccount, let number = Int(account), let cswap = cswapAccounts {
            await waitFor(seconds: 15) {
                if case .notReady = cswap.pinResolution(number) { return false }
                return true
            }
        }
        await retention.refresh()
        let ids = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        await cleanupMode.openCondense(ids)
        cleanupMode.generate()
        await condense.waitForRun()
        let chars: Int = if case .preview(let output) = condense.phase { output.count } else { 0 }
        HolderSessionStore.printLog("debug condense sources=\(condense.sources.count) excluded=\(condense.excluded.count) "
                                    + "state=\(condense.dumpObject["state"] as? String ?? "-") previewChars=\(chars) "
                                    + "folderRemoved=\(condense.lastRun?.folderRemoved ?? false)")
        guard apply else { return }
        await cleanupMode.applyCondense()
        HolderSessionStore.printLog("debug condense-apply summary=\(condense.lastApplied?.summary.rawValue ?? "-") "
                                    + "archived=\(condense.lastApplied?.archived.count ?? 0) kept=\(condense.lastApplied?.kept.count ?? 0)")
    }
    #endif
}
