import Foundation

/// Step 2's state: pure values with pure mutations, so the view, the App and tests agree on what
/// every check, filter, group, page or hidden change does.
public struct ImportSelection: Sendable, Equatable {
    /// D8: 12 rows first, `載入更多 ↓` adds 24.
    public static let pageSize = 12
    public static let pageStep = 24
    /// D8: rows used within this many days are pre-checked (at most `pageSize`, newest first).
    public static let recentDays = 14

    public var checked: Set<String>
    /// Path → `GroupOption.key`; a missing path is 未分類.
    public var group: [String: String]
    public var filter: String
    public var showHidden: Bool
    public var limit: Int
    /// Groups the user named here (`+ 新群組…`), in creation order.
    public var newGroups: [GroupOption]

    public init(checked: Set<String> = [], group: [String: String] = [:], filter: String = "", showHidden: Bool = false,
                limit: Int = ImportSelection.pageSize, newGroups: [GroupOption] = []) {
        self.checked = checked
        self.group = group
        self.filter = filter
        self.showHidden = showHidden
        self.limit = limit
        self.newGroups = newGroups
    }

    /// D8 pre-check (used in the last 14 days, not hidden, at most 12, newest first) and every row
    /// on its D9 suggestion.
    public static func initial(_ catalog: ProjectCatalog, existing: [ExistingGroup], now: Date) -> ImportSelection {
        initial(catalog, existing: existing, now: now, home: nil)
    }

    /// `initial` with the home folder (never suggested as a group).
    public static func initial(_ catalog: ProjectCatalog, existing: [ExistingGroup], now: Date, home: String?) -> ImportSelection {
        let cutoff = now.addingTimeInterval(-TimeInterval(recentDays) * 86_400)
        let recent = catalog.candidates
            .filter { candidate in candidate.hidden == nil && (candidate.lastUsed.map { $0 >= cutoff } ?? false) }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
            .prefix(pageSize)
        let checked = Set(recent.map(\.path))
        let suggestion = GroupSuggester.suggest(for: catalog.candidates, checked: checked, existing: existing, home: home).suggestion
        return ImportSelection(checked: checked, group: suggestion)
    }

    /// The rows the table shows: the filter (over every candidate), hidden ones only with
    /// `showHidden`, at most `limit`.
    public func visible(in catalog: ProjectCatalog) -> [ImportCandidate] {
        Array(matching(in: catalog).prefix(max(0, limit)))
    }

    /// Every row that passes the hidden toggle and the filter (before the page limit).
    public func matching(in catalog: ProjectCatalog) -> [ImportCandidate] {
        let needle = Self.fold(filter.trimmingCharacters(in: .whitespacesAndNewlines))
        return catalog.candidates.filter { candidate in
            (showHidden || candidate.hidden == nil) && (needle.isEmpty || Self.matches(candidate, folded: needle))
        }
    }

    /// Case, width and diacritics are ignored (`ＣＯＤＤ`, `codd` and `Códd` match `CODD`); name, prefix and
    /// path are searched.
    public static func matches(_ candidate: ImportCandidate, filter: String) -> Bool {
        let needle = fold(filter.trimmingCharacters(in: .whitespacesAndNewlines))
        return needle.isEmpty || matches(candidate, folded: needle)
    }

    static func matches(_ candidate: ImportCandidate, folded needle: String) -> Bool {
        [candidate.name, (candidate.prefix ?? "") + candidate.name, candidate.displayPath, candidate.path]
            .contains { fold($0).contains(needle) }
    }

    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The group key of `path` (未分類 when none was set).
    public func groupKey(for path: String) -> String { group[path] ?? GroupOption.ungroupedKey }

    // MARK: Mutations

    public func toggling(_ path: String) -> ImportSelection {
        var copy = self
        if copy.checked.contains(path) { copy.checked.remove(path) } else { copy.checked.insert(path) }
        return copy
    }

    public func setting(_ paths: [String], checked on: Bool) -> ImportSelection {
        var copy = self
        if on { copy.checked.formUnion(paths) } else { copy.checked.subtract(paths) }
        return copy
    }

    public func assigning(_ key: String, to path: String) -> ImportSelection {
        var copy = self
        copy.group[path] = key
        return copy
    }

    /// The `依父資料夾建議分組` button: every checked row gets its suggestion (D9).
    public func applyingSuggestions(_ suggestion: [String: String]) -> ImportSelection {
        var copy = self
        for path in checked { copy.group[path] = suggestion[path] ?? GroupOption.ungroupedKey }
        return copy
    }

    public func filtering(_ text: String) -> ImportSelection {
        var copy = self
        copy.filter = text
        return copy
    }

    public func togglingHidden() -> ImportSelection {
        var copy = self
        copy.showHidden.toggle()
        return copy
    }

    /// `載入更多 ↓`.
    public func loadingMore() -> ImportSelection {
        var copy = self
        copy.limit += Self.pageStep
        return copy
    }

    /// `+ 新群組…` named `name` for `path`: a new group with the next free color (after every color in
    /// `options`) and the next `user:<n>` key (user groups are only ever added, so `n` never repeats;
    /// the catalog does not take part, so a re-detect keeps it); the row moves into it.
    public func addingGroup(named name: String, for path: String, catalog: ProjectCatalog,
                            options: [GroupOption]) -> (selection: ImportSelection, group: GroupOption) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var used = Set(options.compactMap(\.color)).union(newGroups.compactMap(\.color))
        let color = GroupSuggester.nextColor(used: &used, index: newGroups.count)
        let group = GroupOption(key: GroupOption.userKey(newGroups.count + 1), name: trimmed.isEmpty ? "新群組" : trimmed,
                                color: color, kind: .new)
        var copy = self
        copy.newGroups.append(group)
        copy.group[path] = group.key
        return (copy, group)
    }
}

/// What `下一步` on step 2 does (D8): the checked rows in table order with their group, and the new
/// groups to create first.
public struct ImportPlan: Sendable, Equatable {
    public struct NewGroup: Sendable, Equatable {
        public let key: String
        public let name: String
        public let color: String?

        public init(key: String, name: String, color: String?) {
            self.key = key
            self.name = name
            self.color = color
        }
    }

    /// A struct, not a tuple: a tuple array would not be Equatable.
    public struct Addition: Sendable, Equatable {
        public let path: String
        /// nil = 未分類; `existing:<id>` for an existing group; `new:<parent>` / `user:<n>` for one of `newGroups`.
        public let groupKey: String?

        public init(path: String, groupKey: String?) {
            self.path = path
            self.groupKey = groupKey
        }
    }

    /// In first-use order.
    public let newGroups: [NewGroup]
    /// Table order.
    public let additions: [Addition]

    public init(newGroups: [NewGroup], additions: [Addition]) {
        self.newGroups = newGroups
        self.additions = additions
    }

    public var isEmpty: Bool { additions.isEmpty }

    /// Groups the additions land in (new and existing; 未分類 not counted).
    public var groupCount: Int { Set(additions.compactMap(\.groupKey)).count }

    /// A key the options do not know (a suggested group that no longer exists) imports as 未分類.
    public static func make(_ selection: ImportSelection, catalog: ProjectCatalog, options: [GroupOption]) -> ImportPlan {
        var byKey: [String: GroupOption] = [:]
        for option in options + selection.newGroups where byKey[option.key] == nil { byKey[option.key] = option }
        var additions: [Addition] = []
        var newGroups: [NewGroup] = []
        var seen = Set<String>()
        for candidate in catalog.candidates where selection.checked.contains(candidate.path) {
            guard let option = byKey[selection.groupKey(for: candidate.path)] else {
                additions.append(Addition(path: candidate.path, groupKey: nil))
                continue
            }
            switch option.kind {
            case .ungrouped:
                additions.append(Addition(path: candidate.path, groupKey: nil))
            case .existing:
                additions.append(Addition(path: candidate.path, groupKey: option.key))
            case .new:
                if seen.insert(option.key).inserted { newGroups.append(NewGroup(key: option.key, name: option.name, color: option.color)) }
                additions.append(Addition(path: candidate.path, groupKey: option.key))
            }
        }
        return ImportPlan(newGroups: newGroups, additions: additions)
    }
}
