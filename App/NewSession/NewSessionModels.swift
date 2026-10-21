import CoddCore
import Foundation
import CoddUI

/// The project combobox's open list (NewSession artboard `.ns-list`): `最近 Recent n` (CODD
/// projects, most recently active first, `n live`, ✓ on the chosen one), `建議 · 來自
/// ~/.claude.json` `未加入` (folders Claude has used that CODD does not know, `+ 加入`), then
/// `+ 選擇資料夾…` `⌘O`. Typing filters both lists with CoddCore's `FuzzyMatcher` (name first, the
/// path at half weight, like ⌘K). Pure.
struct ProjectDropdownModel: Equatable {
    struct Row: Equatable {
        enum Kind: Equatable { case recent, suggestion, chooseFolder }
        var kind: Kind
        /// nil for `+ 選擇資料夾…`.
        var choice: ProjectChoice?
        /// Matched characters of the name (UTF-16).
        var spans: [TextSpan] = []
        /// `2 live`, the parent folder (`…/orb-toolkit-suite`, `~/Github`) or `⌘O`.
        var detail: String
        var isChosen = false
        var title: String { choice?.name ?? "選擇資料夾…" }
    }

    var recent: [Row] = []
    var suggested: [Row] = []
    /// Recent, suggested, then `+ 選擇資料夾…` (the order ↑↓ walk).
    var rows: [Row] { recent + suggested + [Self.chooseFolderRow] }

    static let chooseFolderRow = Row(kind: .chooseFolder, choice: nil, detail: "⌘O")
    /// With a query more rows qualify (the list scrolls).
    static let filteredRecentLimit = 20
    static let filteredSuggestionLimit = 10

    /// - Parameters:
    ///   - query: the typed filter; nil or blank lists everything.
    ///   - chosenPath: the folder the form has (✓).
    static func build(query: String?, known: [ProjectChoice], recent fromClaude: [RecentProject], chosenPath: String?) -> Self {
        let chosen = chosenPath.map(HolderSessionStore.standardize)
        let sortedKnown = known.sorted { lhs, rhs in
            switch (lhs.lastUsed, rhs.lastUsed) {
            case let (l?, r?) where l != r: return l > r
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        let knownPaths = Set(known.map { HolderSessionStore.standardize($0.path) })
        var seen = Set<String>()
        let suggestions = fromClaude.compactMap { project -> ProjectChoice? in
            let path = HolderSessionStore.standardize(project.path)
            guard !knownPaths.contains(path), seen.insert(path).inserted else { return nil }
            return ProjectChoice(path: path, name: project.name, tag: nil, isKnown: false, lastUsed: project.lastUsed)
        }
        let trimmed = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func row(_ choice: ProjectChoice, kind: Row.Kind, spans: [TextSpan]) -> Row {
            let detail = kind == .recent ? (choice.live > 0 ? "\(choice.live) live" : "") : parentText(choice.path)
            return Row(kind: kind, choice: choice, spans: spans, detail: detail,
                       isChosen: chosen == HolderSessionStore.standardize(choice.path))
        }
        guard !trimmed.isEmpty else {
            return Self(recent: sortedKnown.prefix(NewSessionForm.recentLimit).map { row($0, kind: .recent, spans: []) },
                        suggested: suggestions.prefix(NewSessionForm.suggestionLimit).map { row($0, kind: .suggestion, spans: []) })
        }
        func ranked(_ choices: [ProjectChoice], kind: Row.Kind, limit: Int) -> [Row] {
            var scored: [(row: Row, score: Int, order: Int)] = []
            for (order, choice) in choices.enumerated() {
                guard let match = QuickSwitchModel.score(trimmed, primary: choice.name,
                                                         secondary: PathFormat.abbreviateHome(choice.path)) else { continue }
                scored.append((row(choice, kind: kind, spans: match.spans), match.score, order))
            }
            return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.prefix(limit).map(\.row)
        }
        return Self(recent: ranked(sortedKnown, kind: .recent, limit: filteredRecentLimit),
                    suggested: ranked(suggestions, kind: .suggestion, limit: filteredSuggestionLimit))
    }

    /// A suggestion's parent folder: `~/Github` when short, else `…/orb-toolkit-suite`.
    static func parentText(_ path: String) -> String {
        let parent = PathFormat.abbreviateHome((path as NSString).deletingLastPathComponent)
        let parts = parent.split(separator: "/")
        guard parts.count > 2, let last = parts.last else { return parent }
        return "…/" + last
    }

    /// The combobox's second line: `~/…/orb-toolkit-suite/orb-toolkit-backend`.
    static func shortPath(_ path: String) -> String { HomeModel.shortPath(path) }
}

/// One row of the resume picker (`Past transcripts`, D18).
struct ResumePickerRow: Equatable, Sendable {
    var id: String
    var title: String
    var titleSource: TranscriptSummary.TitleSource
    var branch: String?
    var sizeBytes: Int64
    /// Whole days since its last activity (the age the expiry counts from).
    var ageDays: Int
    /// `2d`, `5h` (the picker's age column).
    var ageText: String
    /// D18: days before `cleanupPeriodDays` deletes it, when ≤ 5 (else nil).
    var expiresInDays: Int?
    /// A running CODD session or a live claude elsewhere uses it: shown `執行中`, not selectable.
    var disabled: Bool
    var lastActivity: Date

    var sizeText: String { HomeModel.size(sizeBytes) }

    /// `! resume 4 天後過期` (amber); 0 days: `! resume 即將過期`.
    var expiryText: String? {
        guard let days = expiresInDays else { return nil }
        return days > 0 ? "! resume \(days) 天後過期" : "! resume 即將過期"
    }

    /// The second line: `⎇ fix/refresh · 2d`.
    var detailText: String {
        [branch.map { "⎇ " + $0 }, ageText].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The resume picker's rows (D18): the folder's transcripts newest first (the catalog's order,
/// `sdk-*` already hidden), the expiry warning from Claude's `cleanupPeriodDays` (default 30), and
/// the ones a live claude uses disabled. Pure.
enum ResumePicker {
    static let loadingText = "// 讀取中…"
    static let emptyText = "// 這個資料夾沒有先前的對話紀錄"
    static let noFolderText = "// 先選一個專案資料夾"
    static let runningText = "執行中"
    /// About five rows show, then the list scrolls.
    static let visibleRows = 5

    /// `warnExpiry` false (Settings › 清理 › 接續前提醒 OFF) leaves every row without the amber expiry.
    static func rows(_ transcripts: [TranscriptSummary], inUse: Set<String>, cleanupPeriodDays: Int?, now: Date,
                     warnExpiry: Bool = true) -> [ResumePickerRow] {
        let period = cleanupPeriodDays ?? TranscriptRetention.defaultCleanupPeriodDays
        return transcripts.map { summary in
            let age = max(0, now.timeIntervalSince(summary.lastActivity))
            return ResumePickerRow(
                id: summary.id, title: summary.title, titleSource: summary.titleSource,
                branch: JSText.nonBlankTrimmed(summary.gitBranch), sizeBytes: summary.sizeBytes,
                ageDays: Int(min(age, 1e9) / 86_400), ageText: HomeModel.transcriptAge(summary.lastActivity, now: now),
                expiresInDays: warnExpiry ? TranscriptRetention.daysLeft(lastActivity: summary.lastActivity, now: now, cleanupPeriodDays: period)
                    : nil,
                disabled: inUse.contains(summary.id), lastActivity: summary.lastActivity)
        }
    }

    /// The row selected when the list arrives: the first one that is not running.
    static func firstEnabled(_ rows: [ResumePickerRow]) -> ResumePickerRow? {
        rows.first { !$0.disabled }
    }

    /// `orb-toolkit-backend · 4` (the picker head).
    static func headText(project: String, count: Int) -> String { "\(project) · \(count)" }

    /// The `resumePicker` state dump entry.
    static func dump(_ rows: [ResumePickerRow], selected: String?) -> [[String: Any]] {
        rows.map { row in
            ["id": row.id, "title": row.title, "branch": row.branch.map { $0 as Any } ?? NSNull(), "sizeBytes": Int(row.sizeBytes),
             "ageDays": row.ageDays, "expiresInDays": row.expiresInDays.map { $0 as Any } ?? NSNull(), "disabled": row.disabled,
             "selected": row.id == selected]
        }
    }
}
