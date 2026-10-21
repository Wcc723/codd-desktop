import Foundation

/// The Onboarding artboard's data (demo, mock mode, tests): 187 projects (the artboard's 12 rows and
/// 175 older ones) plus 2 hidden ones, the artboard's selection and groups, and states for every step.
public enum OnboardingSamples {
    public struct Variant: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let claudeMissing = Variant(rawValue: 1 << 0)
        public static let cswapMissing = Variant(rawValue: 1 << 1)
        public static let hooksUpToDate = Variant(rawValue: 1 << 2)
        public static let notificationsGranted = Variant(rawValue: 1 << 3)
        /// Step 2 with `顯示隱藏項目` on.
        public static let showHidden = Variant(rawValue: 1 << 4)
    }

    public static let home = "/Users/operator"
    public static let timeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    /// 2026-10-15 10:41:58 in Taipei (the artboard's boot time).
    public static var now: Date { date(2026, 10, 15, 10, 41, 58) }

    /// Step 2 exactly as the artboard draws it.
    public static func artboard() -> OnboardingViewModel { step(.importProjects) }

    /// The sample state of `step` (steps 3–6 come after an import of 9 projects into 3 groups; the
    /// hooks step is skipped on the way to steps 4–6).
    public static func step(_ step: OnboardingStep, variant: Variant = []) -> OnboardingViewModel {
        let facts = facts(variant)
        let imported: Int? = step.rawValue > OnboardingStep.importProjects.rawValue ? 9 : nil
        let report = EnvironmentReport.make(facts, step: step, imported: imported, timeZone: timeZone, home: home)
        var importStep = importModel()
        if variant.contains(.showHidden) { importStep = importStep.with(importStep.selection.togglingHidden()) }
        let notesPath = "\(home)/Library/Application Support/CODD/notes"
        var states: [OnboardingStep: StepProgress] = [:]
        for earlier in OnboardingStep.allCases where earlier.rawValue < step.rawValue {
            states[earlier] = earlier == .hooks ? .skipped : .done
        }
        let accounts: Int? = variant.contains(.cswapMissing) ? nil : 3
        return OnboardingViewModel(
            flow: OnboardingFlow(current: step, states: states),
            boot: report,
            versionLine: "1.0.0 (build 1) · macOS 27.0",
            showsWebImportLink: !variant.contains(.hooksUpToDate),
            stepDetails: OnboardingViewModel.stepDetails(facts: facts, report: report, importStep: importStep,
                                                         notesPath: PathText.abbreviate(notesPath, home: home)),
            detect: DetectItem.items(for: facts, home: home),
            importStep: importStep,
            hooks: HooksStepModel.make(hooks: facts.hooks, statusline: .notInstalled, foreign: [
                HooksStepModel.Foreign(command: "hook-tap", name: "hook-tap", count: 11),
                HooksStepModel.Foreign(command: "osascript", name: "通知", count: 2),
            ]),
            notebook: NotebookStepModel.make(notesPath: PathText.abbreviate(notesPath, home: home), mcpEndpoint: "127.0.0.1:47821",
                                             mcpRunning: true, claudeCodeRegistered: false),
            accounts: AccountsStepModel.make(cswap: facts.cswap, rows: accountRows),
            done: DoneStepModel.make(imported: (9, 3), hooks: .skipped, notesPath: PathText.abbreviate(notesPath, home: home),
                                     accounts: accounts, notifications: variant.contains(.notificationsGranted) ? .granted : .notAsked))
    }

    public static func facts(_ variant: Variant = []) -> EnvironmentFacts {
        EnvironmentFacts(
            claude: variant.contains(.claudeMissing) ? .missing : .found(version: "2.1.302", path: "\(home)/.local/bin/claude"),
            cswap: variant.contains(.cswapMissing) ? .missing : .ready(version: "0.26.0", path: "\(home)/.local/bin/cswap", accounts: 3),
            hooks: variant.contains(.hooksUpToDate)
                ? .upToDate(file: "\(home)/.claude/settings.json")
                : .legacy(events: ["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"], file: "\(home)/.claude/settings.json"),
            dataRoot: EnvironmentFacts.DataRoot(path: "\(home)/Library/Application Support/CODD", writable: true,
                                                mcpEndpoint: "127.0.0.1:47821", mcpRunning: true),
            checkedAt: now, milliseconds: 800,
            projects: .found(count: 187, source: "\(home)/.claude.json"))
    }

    /// Step 2 with the artboard's selection: 9 rows checked (整合範例/Skills, UsageBar and
    /// chat-bot-mcp not), every row on its suggestion except chat-bot-mcp,
    /// which the operator moved to 未分類.
    public static func importModel() -> ImportStepModel {
        let catalog = catalog()
        let rows = artboardRows
        let checked = Set(rows.enumerated().filter { ![2, 9, 10].contains($0.offset) }.map { home + $0.element.path })
        let suggestion = GroupSuggester.suggest(for: catalog.candidates, checked: checked, existing: existingGroups, home: home).suggestion
        var group = suggestion
        group[home + "/Github/chat-bot-mcp"] = GroupOption.ungroupedKey
        return ImportStepModel.make(catalog: catalog, selection: ImportSelection(checked: checked, group: group),
                                    existing: existingGroups, now: now, timeZone: timeZone, home: home)
    }

    /// The sidebar the artboard's groups come from (each holds projects next to the rows' folders).
    public static let existingGroups: [ExistingGroup] = [
        ExistingGroup(id: "g-lab", name: "藍鵲 · 實驗室", color: "orange", projectPaths: [
            "\(home)/Project/Northstar/lab/agent-lab-2026/概念驗證",
            "\(home)/Project/Northstar/lab/agent-lab-2026/整合範例/Hooks",
        ]),
        ExistingGroup(id: "g-web", name: "藍鵲 · 網站", color: "blue", projectPaths: [
            "\(home)/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-admin",
            "\(home)/Project/Northstar/websites/業主/預約系統",
        ]),
        ExistingGroup(id: "g-github", name: "個人 · Github", color: "green", projectPaths: [
            "\(home)/Github/dotfiles", "\(home)/Github/blog",
        ]),
        ExistingGroup(id: "g-codd", name: "CODD", color: "purple", projectPaths: [
            "\(home)/Github/codd-web",
        ]),
    ]

    struct Row {
        let path: String          // below home
        let lastUsed: Date
        let transcripts: Int
        var hidden: ImportCandidate.Hidden?
    }

    /// The artboard's 12 rows.
    static var artboardRows: [Row] {
        [
            Row(path: "/Project/Northstar/lab/agent-lab-2026/原型試做", lastUsed: date(2026, 10, 15, 10, 34), transcripts: 14),
            Row(path: "/Project/Northstar/lab/agent-lab-2026/整合範例/MCP", lastUsed: date(2026, 10, 15, 10, 12), transcripts: 9),
            Row(path: "/Project/Northstar/lab/agent-lab-2026/整合範例/Skills", lastUsed: date(2026, 10, 15, 8, 50), transcripts: 6),
            Row(path: "/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend", lastUsed: date(2026, 10, 15, 8, 21), transcripts: 31),
            Row(path: "/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-frontend", lastUsed: date(2026, 10, 14, 22, 47), transcripts: 23),
            Row(path: "/Project/Northstar/websites/業主/Northstar invoice system", lastUsed: date(2026, 10, 14, 18, 5), transcripts: 8),
            Row(path: "/Github/Gear3D", lastUsed: date(2026, 10, 13, 21, 30), transcripts: 17),
            Row(path: "/Github/keynote-deck", lastUsed: date(2026, 10, 13, 15, 2), transcripts: 5),
            Row(path: "/Github/pixel-town-demo", lastUsed: date(2026, 10, 11, 19, 40), transcripts: 12),
            Row(path: "/Github/UsageBar", lastUsed: date(2026, 10, 9, 11, 15), transcripts: 4),
            Row(path: "/Github/chat-bot-mcp", lastUsed: date(2026, 10, 2, 16, 20), transcripts: 3),
            Row(path: "/Github/mysite.github.io", lastUsed: date(2026, 9, 21, 9, 5), transcripts: 2),
        ]
    }

    /// Two hidden projects (shown with `顯示隱藏項目`, between the artboard's rows by date).
    static var hiddenRows: [Row] {
        [
            Row(path: "/Github/Gear3D/.claude-worktrees/scene-load-wt1", lastUsed: date(2026, 10, 15, 9, 30), transcripts: 3, hidden: .worktree),
            Row(path: "/Project/Northstar/automation/review-sdk", lastUsed: date(2026, 10, 14, 20, 15), transcripts: 11, hidden: .sdk),
        ]
    }

    /// The artboard's 12 rows, 175 older projects (every total reads 187) and the 2 hidden ones,
    /// sorted as the reader sorts.
    public static func catalog() -> ProjectCatalog {
        var rows = artboardRows + hiddenRows
        let start = date(2026, 9, 20, 21, 0)
        for index in 1...175 {
            let number = index < 10 ? "00\(index)" : (index < 100 ? "0\(index)" : "\(index)")
            rows.append(Row(path: "/Project/archive/archive-project-\(number)",
                            lastUsed: start.addingTimeInterval(-TimeInterval(index) * 43_200), transcripts: 1 + index % 7))
        }
        rows.sort { $0.lastUsed > $1.lastUsed }
        let paths = rows.map { home + $0.path }
        let prefixes = NamePrefixRule.prefixes(for: paths, home: home)
        let candidates = rows.map { row in
            let path = home + row.path
            return ImportCandidate(path: path, name: PathText.lastComponent(path), prefix: prefixes[path],
                                   displayPath: PathText.abbreviate(path, home: home), lastUsed: row.lastUsed,
                                   transcripts: row.transcripts, hidden: row.hidden)
        }
        return ProjectCatalog(source: "~/.claude.json", candidates: candidates, alreadyInCODD: 0, problem: nil)
    }

    /// R7 order (weekly reset soonest first), SPEC §5 aliases.
    public static let accountRows: [AccountsStepModel.Row] = [
        AccountsStepModel.Row(slot: "#2", alias: "藍鵲", plan: "MAX 20x", fiveHourRemaining: 98, weeklyRemaining: 46,
                              weeklyReset: "1w 重置 1d12h後", active: false),
        AccountsStepModel.Row(slot: "#3", alias: "工作", plan: "MAX 20x", fiveHourRemaining: 91, weeklyRemaining: 15,
                              weeklyReset: "1w 重置 3d01h後", active: true),
        AccountsStepModel.Row(slot: "#1", alias: "個人", plan: "MAX 20x", fiveHourRemaining: 100, weeklyRemaining: 100,
                              weeklyReset: "1w 重置 4d09h後", active: false),
    ]

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
            ?? Date(timeIntervalSince1970: 0)
    }
}
