import CoddCore
import Foundation
import CoddUI

/// What the Home page shows (Home artboard, D17, D29): counts, NEEDS YOU cards, the DONE line,
/// LAUNCH project cards, RECENTLY STOPPED rows and the USAGE header. Pure: built from the stores
/// and the real-mode extras; the view draws it and computes durations from its dates on the 1 Hz
/// tick, so an unchanged model rebuilds nothing.
struct HomeModel: Equatable {
    struct Counts: Equatable {
        var live = 0
        var needsYou = 0
        var working = 0
        var exited = 0
    }

    /// One NEEDS YOU card (`.card.hm-nc`).
    struct NeedsYouCard: Equatable {
        enum Reason: Equatable {
            /// A `code` chip (`Bash: npm test -- auth.spec.ts`, `API 529`) and optional text after it.
            case code(String, String?)
            /// The question, quoted in cream (`「CSV 要用 UTF-8 BOM 還是 Big5？」`).
            case quote(String)
            /// Plain text (`計畫待核准`, `overloaded · 本輪未完成` without a code).
            case text(String)
            case none
        }

        var id: SessionID
        var state: SessionState
        /// `Waiting · Permission`, `Error · Overloaded` (drawn upper case).
        var head: String
        var since: Date
        var title: String
        var tag: TagColor?
        /// `藍鵲·網站 / orb-toolkit-backend`.
        var location: String
        var groupColor: TagColor?
        /// `up 42m` while it runs.
        var startedAt: Date?
        var reason: Reason
        /// `[1 允許]`: permission waits of CODD claude sessions only (never externals, D6).
        var canAllow: Bool
        /// `前往 ⌘n` (the sidebar's ⌘1–9 order).
        var number: Int?
        /// `opus-5.5 · ◉ rc`.
        var meta: String
        var external: Bool
    }

    /// `◇ 1 個待看 · <title> · <group / project> … 4m 前完成 Done`.
    struct DoneLine: Equatable {
        var count: Int
        var id: SessionID
        var title: String
        var location: String
        var since: Date
    }

    /// One LAUNCH 最近專案 card (`.hm-pc`).
    struct LaunchCard: Equatable {
        var path: String
        var name: String
        var tag: TagColor?
        /// A CODD project (else a `.claude.json` suggestion: `未加入`).
        var known: Bool
        /// Lamps of the first three live sessions (`◇ ○`).
        var lamps: [Lamp]
        var live: Int
        /// `~/…/agent-lab-2026/原型試做`.
        var shortPath: String
        /// `啟動 10:04` (today) or `啟動 10/14`.
        var lastActivity: Date?
    }

    struct Lamp: Equatable {
        var state: SessionState
        var unreachable: Bool
    }

    /// One RECENTLY STOPPED 可接續 row: a stopped / exited CODD claude session, or a transcript of a
    /// known project no CODD session and no live claude uses.
    struct StoppedRow: Equatable {
        enum Kind: String { case session, transcript }
        var kind: Kind
        /// CODD session id, or the Claude session id of the transcript.
        var id: String
        var title: String
        var state: SessionState
        /// `個人·Github / UsageBar · exited · code 0` / `orb-toolkit-backend · ⎇ fix/refresh`.
        var meta: [String]
        var date: Date
        /// Transcripts: the folder to resume in and the file size (`1.2MB`).
        var cwd: String?
        var sizeBytes: Int64?
    }

    /// One USAGE 剩餘 row (`.hm-acct`), R7 order.
    ///
    /// No capture time here: it moves with every status-line report (about once a second), and
    /// a model that changed with it rebuilt every Home card that often, window closed or not (M3
    /// review). The list reads it from the account at its 1 Hz tick instead.
    struct UsageRow: Equatable {
        var id: AccountID
        var slot: String
        var alias: String
        var active: Bool
        var fiveHour: QuotaWindow
        var week: QuotaWindow
        var source: String
        /// `1w 用量超前預期 · 預估 10/17 18:00 用完`.
        var weekExhaustsAt: Date?
        /// R8: the threshold tick while auto-switch is ON.
        var threshold: Int?

        /// `statusline · 12s 前` (`尚無用量` before the first number).
        func sourceLine(sourceAt: Date?, now: Date) -> String {
            guard let sourceAt, !source.isEmpty else { return "尚無用量" }
            return "\(source) · \(DurationFormat.ago(sourceAt, now: now))"
        }
    }

    var counts = Counts()
    /// No session at all: the first-launch empty state.
    var isEmpty = false
    /// The default launch profile's name (`Profile · claude-default ▾`).
    var profileName = LaunchProfileDocument.builtInDefaultId
    var usage: [UsageRow] = []
    var autoSwitchOn = false
    var autoSwitchThreshold = 2
    var needsYou: [NeedsYouCard] = []
    var done: DoneLine?
    var launch: [LaunchCard] = []
    var stopped: [StoppedRow] = []
    /// `↓ 依每週重置排序 · 越快重置越上面` plus the D29 note in real mode.
    var usageHeader = ""

    static let launchLimit = 6
    static let stoppedLimit = 6
    /// RECENTLY STOPPED reads this many transcripts for each of this many projects (M2 plan §7).
    static let transcriptsPerProject = 3
    static let transcriptProjects = 6
    static let usageSortNote = "↓ 依每週重置排序 · 越快重置越上面"

    /// What the builder needs besides the session store.
    struct Inputs {
        /// The sidebar's ⌘1–9 order.
        var sessionOrder: [SessionID] = []
        /// `.claude.json` folders, most recently used first.
        var suggestions: [RecentProject] = []
        /// Newest-first transcripts per standardized project folder.
        var transcripts: [String: [TranscriptSummary]] = [:]
        /// Conversations a live claude uses (registry) and every CODD session's own.
        var usedClaudeSessionIDs: Set<String> = []
        var realMode = false
        var sampleAccounts = false
        var accountSource: String?
        /// The accounts' availability copy while they are not cswap's (D1 / D3).
        var accountNote: String?
    }

    // MARK: Building

    @MainActor
    static func build(store: any SessionStore, inputs: Inputs, now: Date) -> HomeModel {
        var model = HomeModel()
        let sessions = store.allSessions
        let counts = SessionCounts(sessions: sessions)
        model.counts = Counts(live: counts.live, needsYou: counts.attention, working: counts.working, exited: counts.exited)
        model.isEmpty = sessions.isEmpty
        var numbers: [SessionID: Int] = [:]
        for (index, id) in inputs.sessionOrder.enumerated() where numbers[id] == nil { numbers[id] = index + 1 }

        let attention = sessions.filter { $0.state.needsAttention }.sorted { lhs, rhs in
            switch (numbers[lhs.id], numbers[rhs.id]) {
            case let (l?, r?): return l < r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.stateSince < rhs.stateSince
            }
        }
        model.needsYou = attention.map { card($0, store: store, number: numbers[$0.id]) }

        let done = sessions.filter { $0.state == .done }.sorted { $0.stateSince > $1.stateSince }
        if let newest = done.first {
            model.done = DoneLine(count: done.count, id: newest.id, title: newest.title, location: location(newest, store: store),
                                  since: newest.stateSince)
        }

        let known = knownProjects(store)
        model.launch = launchCards(known: known, store: store, suggestions: inputs.suggestions, now: now)
        model.stopped = stoppedRows(store: store, sessions: sessions, known: known, inputs: inputs)
        var header = usageSortNote
        if inputs.realMode, inputs.sampleAccounts {
            header += " " + SampleAccountNote.text
        } else if let note = inputs.accountNote {
            // D1 / D3: why there are no cswap accounts.
            header += " " + note
        } else if let source = inputs.accountSource {
            header += " · " + source
        }
        model.usageHeader = header
        return model
    }

    /// The USAGE rows and the auto-switch line, from the account store (R7: weekly reset first).
    @MainActor
    mutating func fillUsage(_ accounts: any AccountStore) {
        let threshold = accounts.autoSwitch.enabled ? accounts.autoSwitch.thresholdPercent : nil
        usage = AccountOrdering.byWeeklyReset(accounts.accounts).map { account in
            UsageRow(id: account.id, slot: account.slot, alias: account.alias, active: account.id == accounts.activeAccountID,
                     fiveHour: account.fiveHour, week: account.week, source: account.source,
                     weekExhaustsAt: account.weekExhaustsAt, threshold: threshold)
        }
        autoSwitchOn = accounts.autoSwitch.enabled
        autoSwitchThreshold = accounts.autoSwitch.thresholdPercent
    }

    /// `group short name / project` (just the project in 未分類).
    @MainActor
    static func location(_ session: SessionVM, store: any SessionStore) -> String {
        guard let project = store.project(session.projectID) else { return "" }
        guard let group = store.group(project.groupID), !group.isUngrouped else { return project.name }
        return "\(group.shortName) / \(project.name)"
    }

    @MainActor
    private static func card(_ s: SessionVM, store: any SessionStore, number: Int?) -> NeedsYouCard {
        let project = store.project(s.projectID)
        let group = project.flatMap { store.group($0.groupID) }
        var head: String
        var reason = NeedsYouCard.Reason.none
        let detail = s.detail.flatMap { $0.isEmpty ? nil : $0 }
        if s.state == .waiting {
            let what = s.waitingReason ?? .other
            head = "Waiting · " + what.label.capitalized
            switch what {
            case .permission:
                let code = [s.tool, detail].compactMap { $0 }.joined(separator: ": ")
                if !code.isEmpty { reason = .code(code, nil) }
            case .question:
                if let detail { reason = .quote("「\(detail)」") }
            case .plan:
                reason = .text(detail ?? "計畫待核准")
            case .other:
                if let detail { reason = .text(detail) }
            }
        } else {
            head = "Error"
            if let error = s.errorReason, !error.isEmpty { head += " · " + error.capitalized }
            let code = detail ?? errorCode(s.errorReason)
            let text = [s.errorReason?.lowercased(), "本輪未完成"].compactMap { $0 }.joined(separator: " · ")
            reason = code.map { .code($0, text) } ?? .text(text)
        }
        if s.unreachableSince != nil { head = "Unreachable · " + head }
        var meta: [String] = []
        if let info = s.externalInfo {
            meta.append(info.rowLabel)
        } else {
            if let model = s.model, !model.isEmpty { meta.append(model) }
            if s.remoteControl { meta.append("◉ rc") }
        }
        let canAllow = !s.external && s.kind == .claude && s.state == .waiting && s.waitingReason == .permission
        return NeedsYouCard(id: s.id, state: s.state, head: head, since: s.unreachableSince ?? s.stateSince, title: s.title,
                            tag: s.tag, location: location(s, store: store), groupColor: group?.isUngrouped == false ? group?.color : nil,
                            startedAt: s.state.isLive ? s.startedAt : nil, reason: reason, canAllow: canAllow,
                            number: number.flatMap { $0 <= 9 ? $0 : nil }, meta: meta.joined(separator: " · "), external: s.external)
    }

    /// The HTTP status a known failure reason stands for (`API 529`), when the hook gave no detail.
    static func errorCode(_ reason: String?) -> String? {
        switch reason {
        case "OVERLOADED": "API 529"
        case "RATE LIMIT": "API 429"
        case "AUTH": "API 401"
        default: nil
        }
    }

    /// Saved projects (transient ones are not CODD's) with their latest activity.
    @MainActor
    private static func knownProjects(_ store: any SessionStore) -> [(project: ProjectVM, group: GroupVM, activity: Date?)] {
        var out: [(ProjectVM, GroupVM, Date?)] = []
        for group in store.groups {
            for id in group.projectIDs {
                guard let project = store.project(id), !project.isTransient else { continue }
                let activity = project.sessionIDs.compactMap { store.session($0) }.filter { !$0.external }
                    .map { $0.startedAt ?? $0.stateSince }.max()
                out.append((project, group, activity))
            }
        }
        // Latest activity first; projects without a session keep their sidebar order after them.
        return out.enumerated().sorted { lhs, rhs in
            switch (lhs.element.2, rhs.element.2) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    @MainActor
    private static func launchCards(known: [(project: ProjectVM, group: GroupVM, activity: Date?)], store: any SessionStore,
                                    suggestions: [RecentProject], now: Date) -> [LaunchCard] {
        var cards: [LaunchCard] = []
        for entry in known.prefix(launchLimit) {
            let live = entry.project.sessionIDs.compactMap { store.session($0) }.filter { $0.state.isLive }
            cards.append(LaunchCard(path: entry.project.cwd, name: entry.project.name,
                                    tag: entry.group.isUngrouped ? nil : entry.group.color, known: true,
                                    lamps: live.prefix(3).map { Lamp(state: $0.state, unreachable: $0.unreachableSince != nil) },
                                    live: live.count, shortPath: shortPath(entry.project.cwd), lastActivity: entry.activity))
        }
        guard cards.count < launchLimit else { return cards }
        let knownPaths = Set(known.map { HolderSessionStore.standardize(PathFormat.expandTilde($0.project.cwd)) })
        for suggestion in suggestions where !knownPaths.contains(HolderSessionStore.standardize(suggestion.path)) {
            cards.append(LaunchCard(path: suggestion.path, name: suggestion.name, tag: nil, known: false, lamps: [], live: 0,
                                    shortPath: shortPath(suggestion.path), lastActivity: suggestion.lastUsed))
            if cards.count == launchLimit { break }
        }
        return cards
    }

    /// `~/…/<parent>/<name>` (home abbreviated, the last two levels kept).
    static func shortPath(_ path: String) -> String {
        PathFormat.short(PathFormat.abbreviateHome(path))
    }

    /// The folders whose transcripts RECENTLY STOPPED reads: the most recently active known projects.
    @MainActor
    static func transcriptFolders(store: any SessionStore) -> [String] {
        knownProjects(store).prefix(transcriptProjects).map { HolderSessionStore.standardize(PathFormat.expandTilde($0.project.cwd)) }
    }

    @MainActor
    private static func stoppedRows(store: any SessionStore, sessions: [SessionVM],
                                    known: [(project: ProjectVM, group: GroupVM, activity: Date?)], inputs: Inputs) -> [StoppedRow] {
        var rows: [StoppedRow] = []
        for s in sessions where s.kind == .claude && !s.external && (s.state == .stopped || s.state == .exited) {
            let status = s.state == .exited ? "exited · code \(s.exitCode ?? 0)" : "stopped"
            rows.append(StoppedRow(kind: .session, id: s.id, title: s.title, state: s.state,
                                   meta: [location(s, store: store), status], date: s.stateSince, cwd: nil, sizeBytes: nil))
        }
        var seen = Set<String>()
        for entry in known.prefix(transcriptProjects) {
            let folder = HolderSessionStore.standardize(PathFormat.expandTilde(entry.project.cwd))
            for transcript in (inputs.transcripts[folder] ?? []).prefix(transcriptsPerProject)
            where !inputs.usedClaudeSessionIDs.contains(transcript.id) && seen.insert(transcript.id).inserted {
                var meta = [entry.project.name]
                if let branch = transcript.gitBranch, !branch.isEmpty { meta.append("⎇ \(branch)") }
                rows.append(StoppedRow(kind: .transcript, id: transcript.id, title: transcript.title, state: .stopped, meta: meta,
                                       date: transcript.lastActivity, cwd: transcript.cwd ?? folder, sizeBytes: transcript.sizeBytes))
            }
        }
        return Array(rows.sorted { $0.date > $1.date }.prefix(stoppedLimit))
    }

    /// A transcript's age as the resume picker shows it: whole days from one day on (`2d`), else
    /// the compact duration (`5h`).
    static func transcriptAge(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite, seconds >= 86_400 else { return DurationFormat.compact(seconds) }
        return "\(Int(min(seconds, 1e9) / 86_400))d"
    }

    /// `1.2MB`, `640KB`, `512B` (the resume picker's size style).
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }

    /// `啟動 10:04` today, else `啟動 10/14`.
    static func launchedText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "啟動 " + ClockFormat.hourMinute(date, calendar: calendar) }
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "啟動 \(parts.month ?? 0)/\(parts.day ?? 0)"
    }

    /// The `home` state dump entry: `{needsYou [ids], done {id, count} | null, launch [cwd],
    /// stopped [{kind, id, title}]}`.
    var dump: [String: Any] {
        ["needsYou": needsYou.map(\.id),
         "done": done.map { ["id": $0.id, "count": $0.count] as [String: Any] } ?? NSNull(),
         "launch": launch.map(\.path),
         "stopped": stopped.map { ["kind": $0.kind.rawValue, "id": $0.id, "title": $0.title] }]
    }
}
