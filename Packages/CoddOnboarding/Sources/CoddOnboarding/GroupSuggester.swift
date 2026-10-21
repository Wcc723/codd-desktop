import Foundation

/// A sidebar group that already exists in CODD (the App maps its layout into these).
public struct ExistingGroup: Sendable, Equatable {
    public let id: String
    public let name: String
    /// Claude Code `/color` name (`red`, `blue`, …); nil: no tag.
    public let color: String?
    public let projectPaths: [String]

    public init(id: String, name: String, color: String?, projectPaths: [String]) {
        self.id = id
        self.name = name
        self.color = color
        self.projectPaths = projectPaths
    }
}

/// One entry of a row's group menu.
///
/// Keys: `existing:<group id>`, `new:<parent folder>`, `user:<n>` and `ungrouped`. A suggested new
/// group is keyed by its (standardized) parent folder, so its key names the same folder while rows
/// are checked and unchecked and across a re-detect that reorders the catalog or finds new parents
/// (a position in the catalog would then point at another folder's group); a group the user names
/// counts in its own namespace (`ImportSelection.addingGroup`), never colliding with a parent.
public struct GroupOption: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case existing(String), new, ungrouped
    }

    public let key: String
    public let name: String
    public let color: String?
    public let kind: Kind

    public init(key: String, name: String, color: String?, kind: Kind) {
        self.key = key
        self.name = name
        self.color = color
        self.kind = kind
    }

    public static let ungroupedKey = "ungrouped"
    /// `未分類` (the dashed square).
    public static let ungrouped = GroupOption(key: ungroupedKey, name: "未分類", color: nil, kind: .ungrouped)

    public static func existingKey(_ id: String) -> String { "existing:\(id)" }
    /// The suggested new group of the rows under `parent`.
    public static func newKey(parent: String) -> String { "new:\(parent)" }
    /// The `n`-th group the user named in this step (1-based).
    public static func userKey(_ n: Int) -> String { "user:\(n)" }
}

/// D9 `依父資料夾建議分組`: a suggested group for every candidate.
///
/// 1. An existing CODD group holding a project whose parent folder equals the row's parent → that
///    group (the one holding most such projects; ties go to the earlier group).
/// 2. Else a parent shared by ≥ 2 checked rows → a new group named after the parent's last path
///    component (on a name collision `<grandparent> · <parent>`), colors in SPEC §3 tag order
///    skipping the colors groups already use. The home folder and `/` never become a group.
/// 3. Else 未分類.
///
/// Unchecked rows get a suggestion too (they keep it while their select is disabled, D9).
public enum GroupSuggester {
    /// SPEC §3 tag order.
    public static let colorOrder = ["red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan"]

    /// - Parameters:
    ///   - userGroups: groups the user named in this step (kept after the suggested ones; their
    ///     colors and names are taken).
    ///   - home: the home folder, never suggested as a group.
    public static func suggest(for candidates: [ImportCandidate], checked: Set<String>, existing: [ExistingGroup],
                               userGroups: [GroupOption] = [], home: String? = nil)
        -> (options: [GroupOption], suggestion: [String: String]) {
        // Existing projects per parent folder and group.
        var heldByParent: [String: [Int: Int]] = [:]
        for (index, group) in existing.enumerated() {
            for path in group.projectPaths {
                let parent = PathText.parent(PathText.standardize(path, home: home))
                heldByParent[parent, default: [:]][index, default: 0] += 1
            }
        }
        var checkedPerParent: [String: Int] = [:]
        for candidate in candidates where checked.contains(candidate.path) {
            checkedPerParent[PathText.parent(candidate.path), default: 0] += 1
        }
        var usedColors = Set(existing.compactMap(\.color)).union(userGroups.compactMap(\.color))
        var takenNames = Set(existing.map { fold($0.name) }).union(userGroups.map { fold($0.name) })
        let homeFolder = home.map { PathText.standardize($0) }

        var created: [String: GroupOption] = [:]
        var newGroups: [GroupOption] = []
        var suggestion: [String: String] = [:]
        for candidate in candidates {
            let parent = PathText.parent(candidate.path)
            if let held = heldByParent[parent], let best = held.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                suggestion[candidate.path] = GroupOption.existingKey(existing[best.key].id)
                continue
            }
            if (checkedPerParent[parent] ?? 0) >= 2, parent != "/", parent != homeFolder {
                if let group = created[parent] {
                    suggestion[candidate.path] = group.key
                    continue
                }
                let name = uniqueName(for: parent, taken: &takenNames)
                let color = nextColor(used: &usedColors, index: newGroups.count)
                let group = GroupOption(key: GroupOption.newKey(parent: parent), name: name, color: color, kind: .new)
                created[parent] = group
                newGroups.append(group)
                suggestion[candidate.path] = group.key
                continue
            }
            suggestion[candidate.path] = GroupOption.ungroupedKey
        }
        let existingOptions = existing.map {
            GroupOption(key: GroupOption.existingKey($0.id), name: $0.name, color: $0.color, kind: .existing($0.id))
        }
        return (existingOptions + newGroups + userGroups + [GroupOption.ungrouped], suggestion)
    }

    /// The parent's last component, `<grandparent> · <parent>` when that name is taken, then a number.
    static func uniqueName(for parent: String, taken: inout Set<String>) -> String {
        let base = PathText.lastComponent(parent)
        var name = base
        if taken.contains(fold(name)) {
            let grandparent = PathText.parent(parent)
            if grandparent != "/" { name = "\(PathText.lastComponent(grandparent)) · \(base)" }
        }
        var counter = 2
        let stem = name
        while taken.contains(fold(name)) {
            name = "\(stem) \(counter)"
            counter += 1
        }
        taken.insert(fold(name))
        return name
    }

    /// The first color of the tag order nobody uses; when all are taken, the order again.
    static func nextColor(used: inout Set<String>, index: Int) -> String {
        if let free = colorOrder.first(where: { !used.contains($0) }) {
            used.insert(free)
            return free
        }
        return colorOrder[index % colorOrder.count]
    }

    static func fold(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
