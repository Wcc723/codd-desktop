import CoddClaudeSettings
import CoddOnboarding
import CoddUI
import Foundation

/// What one environment probe found (D5: only while the wizard shows), in the package's terms.
/// The App fills it from the live services; tests build it by hand.
struct OnboardingProbeResult: Equatable, Sendable {
    var facts: EnvironmentFacts
    var catalog: ProjectCatalog
    /// The sidebar's groups (D9 suggestions) at the time of the probe.
    var existingGroups: [ExistingGroup]
    var statusline: HooksStepModel.Statusline = .notInstalled
    var foreign: [HooksStepModel.Foreign] = []
    /// `SESSION HOOKS ● 14 / 14` (0 while the hook endpoint does not listen).
    var sessionHooksInstalled = 14
    var sessionHooksTotal = 14
    /// D12: CODD web leftovers (legacy hook handlers or its `codd-statusline.js`).
    var webLeftovers = false
    /// The notes folder with `~`.
    var notesPath: String
    /// nil: this data root cannot register (M4 D22), `claudeCodeReason` says why.
    var claudeCodeRegistered: Bool?
    var claudeCodeReason: String?
    var codexAvailable = true
    /// R7 order, aliases only.
    var accountRows: [AccountsStepModel.Row] = []
}

/// The pure mappings from CODD's services to the onboarding facts (tests feed fake values).
enum OnboardingFacts {
    /// D11 `claude`: an absolute executable that answered `--version`; a missing or not executable
    /// path is `找不到`, one that ran without a version `無法執行`.
    static func claude(path: String?, isExecutable: Bool, version: String?) -> EnvironmentFacts.Claude {
        guard let path, path.hasPrefix("/"), isExecutable else { return .missing }
        guard let version else { return .failed("--version 沒有回報版本") }
        return .found(version: version, path: path)
    }

    /// The account store's own availability (before the D4 pseudo account).
    static func cswap(base: AccountAvailability, version: String?, path: String?, accounts: Int) -> EnvironmentFacts.Cswap {
        switch base {
        case .ready: .ready(version: version ?? "?", path: path ?? "cswap", accounts: accounts)
        case .loading: .loading
        case .noCswap, .pseudo: .missing
        case .unsupported(let version): .unsupported(version)
        case .unreadable(let reason): .unreadable(reason)
        }
    }

    /// D11 hooks: CODD web leftovers to remove (`legacy`), an outdated global status line of this
    /// CODD, or nothing to do (`upToDate`; a status line not installed is optional).
    static func hooks(_ state: ClaudeSettingsService.InspectionState, file: String) -> EnvironmentFacts.Hooks {
        switch state {
        case .unknown: return .unknown
        case .failed(let reason): return .unreadable(reason)
        case .loaded(let inspection, _):
            if inspection.hasLegacy {
                var events = inspection.legacyHookEvents
                // Only the CODD web status line is left: name it, so the row is not `0 個事件`.
                if events.isEmpty { events = ["statusLine"] }
                return .legacy(events: events, file: file)
            }
            if case .coddDesktop(_, false) = inspection.statusLine { return .statuslineOutdated(file: file) }
            return .upToDate(file: file)
        }
    }

    /// Step 3's STATUSLINE row.
    static func statusline(_ state: ClaudeSettingsService.InspectionState) -> HooksStepModel.Statusline {
        guard case .loaded(let inspection, _) = state, case .coddDesktop(_, let current) = inspection.statusLine else {
            return .notInstalled
        }
        return current ? .installed : .outdated
    }

    /// Step 3's FOREIGN rows (each tool's own hooks, kept as they are).
    static func foreign(_ state: ClaudeSettingsService.InspectionState) -> [HooksStepModel.Foreign] {
        guard case .loaded(let inspection, _) = state else { return [] }
        return inspection.foreign.map { HooksStepModel.Foreign(command: $0.code, name: $0.name, count: $0.events.count) }
    }

    static func webLeftovers(_ state: ClaudeSettingsService.InspectionState) -> Bool {
        guard case .loaded(let inspection, _) = state else { return false }
        return inspection.hasLegacy
    }

    /// Step 5's rows: SPEC §9 R7 order (weekly reset soonest first), aliases only (never an
    /// e-mail; the D4 pseudo account is not a cswap account).
    @MainActor
    static func accountRows(_ accounts: [AccountVM], activeID: AccountID?, now: Date) -> [AccountsStepModel.Row] {
        AccountOrdering.byWeeklyReset(accounts).filter { !$0.isPseudo }.map { vm in
            let reset = vm.week.known ? vm.week.resetsAt.map { DurationFormat.countdown(to: $0, now: now) } : nil
            return AccountsStepModel.Row(slot: vm.slot, alias: vm.alias, plan: vm.plan,
                                         fiveHourRemaining: vm.fiveHour.known ? Double(vm.fiveHour.remainingPercent) : nil,
                                         weeklyRemaining: vm.week.known ? Double(vm.week.remainingPercent) : nil,
                                         weeklyReset: "1w 重置 " + (reset ?? "—"), active: vm.id == activeID)
        }
    }

    /// The sidebar's user groups with their projects' folders (D9).
    @MainActor
    static func existingGroups(_ store: any SessionStore) -> [ExistingGroup] {
        store.groups.filter { !$0.isUngrouped }.map { group in
            ExistingGroup(id: group.id, name: group.name, color: group.color?.rawValue,
                          projectPaths: group.projectIDs.compactMap { store.project($0) }.filter { !$0.isTransient }
                              .map { PathFormat.expandTilde($0.cwd) })
        }
    }

    /// On a test data root the real `~/.claude.json` and the transcripts under `~/.claude/projects`
    /// are never read (security review; like the registration, M4 D37): the Claude directory or
    /// the `.claude.json` next to it is the user's own.
    static func catalogIsProtected(standardRoot: Bool, claudeDirectory: String,
                                   home: String = RealModeOptions.realHome) -> Bool {
        guard !standardRoot else { return false }
        let config = ((claudeDirectory as NSString).deletingLastPathComponent as NSString).appendingPathComponent(".claude.json")
        return RealModeOptions.protectedPathReason(claudeDirectory, home: home) != nil
            || RealModeOptions.protectedPathReason(config, home: home) != nil
    }

    /// What step 2 shows instead of the user's projects on such a root.
    static let protectedCatalog = ProjectCatalog(source: "~/.claude.json", candidates: [], alreadyInCODD: 0,
                                                 problem: "測試資料夾不會讀取 ~/.claude.json")

    /// Every saved project's folder (left out of step 2, `另有 n 個已在側欄`).
    @MainActor
    static func projectPaths(_ store: any SessionStore) -> Set<String> {
        Set(store.groups.flatMap(\.projectIDs).compactMap { store.project($0) }.filter { !$0.isTransient }
            .map { PathFormat.expandTilde($0.cwd) })
    }

    /// D11's data-root row and the boot block's import-source row.
    static func projects(_ catalog: ProjectCatalog, expectedSource: String) -> EnvironmentFacts.Projects {
        guard let source = catalog.source else { return .missing(source: expectedSource) }
        if let problem = catalog.problem { return .unreadable(source: source, reason: problem) }
        return .found(count: catalog.visibleTotal, source: source)
    }

    /// Whether CODD may create and remove a file in `root` (the boot block's `可寫入`). Blocking.
    static func isWritable(_ root: String) -> Bool {
        let probe = root + "/.codd-onboarding-write-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(probe, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        close(fd)
        unlink(probe)
        return true
    }
}

/// Step 2's `下一步` (D8): the plan's new groups first (first-use order, their colors), then each
/// group's projects in table order (未分類 = no group). Never anything else: the sidebar only.
@MainActor
enum OnboardingImport {
    struct Outcome: Equatable, Sendable {
        /// Projects actually added (a folder already in CODD or gone is not counted).
        var projects: Int
        /// Groups that received at least one of them (未分類 not counted).
        var groups: Int
        /// The first added project in table order (shown when the wizard ends).
        var firstProject: ProjectID?
        /// Every added project folder.
        var paths: [String]
    }

    static func apply(_ plan: ImportPlan, to store: any SessionStore) -> Outcome {
        guard !plan.isEmpty, store.canAddProjects else { return Outcome(projects: 0, groups: 0, firstProject: nil, paths: []) }
        var created: [String: GroupID] = [:]
        for group in plan.newGroups {
            created[group.key] = store.addGroup(name: group.name, color: group.color.flatMap(TagColor.init(rawValue:)))
        }
        // One addProjects call per target group, in the order the table first uses it.
        var order: [String?] = []
        var paths: [String?: [String]] = [:]
        for addition in plan.additions {
            if paths[addition.groupKey] == nil { order.append(addition.groupKey) }
            paths[addition.groupKey, default: []].append(addition.path)
        }
        var added: [ProjectID: Int] = [:]
        var addedPaths: [String] = []
        var groups = Set<String>()
        for key in order {
            let groupID = key.flatMap { key in created[key] ?? existingGroupID(key).flatMap { store.group($0)?.id } }
            let results = store.addProjects(paths: paths[key] ?? [], toGroup: groupID, atIndex: nil)
            for result in results where result.added {
                guard let id = result.projectID else { continue }
                added[id] = plan.additions.firstIndex { HolderSessionStore.standardize($0.path) == result.path } ?? added.count
                addedPaths.append(result.path)
                if let key, groupID != nil { groups.insert(key) }
            }
        }
        let first = added.min { $0.value < $1.value }?.key
        return Outcome(projects: added.count, groups: groups.count, firstProject: first, paths: addedPaths)
    }

    /// `existing:<id>` → `<id>`.
    static func existingGroupID(_ key: String) -> GroupID? {
        guard key.hasPrefix("existing:") else { return nil }
        return String(key.dropFirst("existing:".count))
    }
}
