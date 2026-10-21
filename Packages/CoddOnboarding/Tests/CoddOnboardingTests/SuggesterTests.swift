import Foundation
import Testing
@testable import CoddOnboarding

@Suite("GroupSuggester (D9) and ImportPlan")
struct SuggesterTests {
    @Test("an existing group holding a project in the same parent folder wins")
    func existingGroup() {
        let rows = [candidate("/w/clients/a"), candidate("/w/clients/b"), candidate("/w/other/c")]
        let existing = [ExistingGroup(id: "g1", name: "客戶", color: "blue", projectPaths: ["/w/clients/old/"])]
        let (options, suggestion) = GroupSuggester.suggest(for: rows, checked: ["/w/clients/a"], existing: existing)
        #expect(suggestion["/w/clients/a"] == "existing:g1")
        #expect(suggestion["/w/clients/b"] == "existing:g1")   // unchecked rows get a suggestion too
        #expect(suggestion["/w/other/c"] == "ungrouped")
        #expect(options.map(\.key) == ["existing:g1", "ungrouped"])
        #expect(options.first?.kind == .existing("g1"))
    }

    @Test("the group holding most projects of the parent wins; a tie goes to the earlier group")
    func mostHeld() {
        let rows = [candidate("/w/gh/a")]
        let one = ExistingGroup(id: "one", name: "One", color: nil, projectPaths: ["/w/gh/x"])
        let two = ExistingGroup(id: "two", name: "Two", color: nil, projectPaths: ["/w/gh/y", "/w/gh/z"])
        #expect(GroupSuggester.suggest(for: rows, checked: [], existing: [one, two]).suggestion["/w/gh/a"] == "existing:two")
        let three = ExistingGroup(id: "three", name: "Three", color: nil, projectPaths: ["/w/gh/q"])
        #expect(GroupSuggester.suggest(for: rows, checked: [], existing: [one, three]).suggestion["/w/gh/a"] == "existing:one")
    }

    @Test("a parent shared by two checked rows becomes a new group; one checked row stays 未分類")
    func sharedParent() {
        let rows = [candidate("/w/clients/a"), candidate("/w/solo/x"), candidate("/w/clients/b"), candidate("/w/clients/c")]
        let (options, suggestion) = GroupSuggester.suggest(for: rows, checked: ["/w/clients/a", "/w/clients/b", "/w/solo/x"], existing: [])
        #expect(suggestion["/w/clients/a"] == "new:/w/clients")
        #expect(suggestion["/w/clients/b"] == "new:/w/clients")
        #expect(suggestion["/w/clients/c"] == "new:/w/clients")
        #expect(suggestion["/w/solo/x"] == "ungrouped")
        #expect(options == [GroupOption(key: "new:/w/clients", name: "clients", color: "red", kind: .new), GroupOption.ungrouped])
    }

    @Test("new-group keys stay the same while rows are checked and unchecked")
    func stableKeys() {
        let rows = [candidate("/w/a/1"), candidate("/w/a/2"), candidate("/w/b/1"), candidate("/w/b/2")]
        let both = GroupSuggester.suggest(for: rows, checked: Set(rows.map(\.path)), existing: []).suggestion
        let onlyB = GroupSuggester.suggest(for: rows, checked: ["/w/b/1", "/w/b/2"], existing: []).suggestion
        #expect(both["/w/b/1"] == "new:/w/b")
        #expect(onlyB["/w/b/1"] == "new:/w/b")
        #expect(onlyB["/w/a/1"] == "ungrouped")
    }

    /// Review correctness-1: ↻ 重新偵測 keeps `selection.group`; keys must still name the same groups
    /// when the new catalog is in another order or has another parent.
    @Test("a re-detect that reorders the catalog or adds a parent keeps every row in its group")
    func keysSurviveARedetect() {
        let first = catalog([candidate("/w/A/a1"), candidate("/w/B/b1"), candidate("/w/A/a2"), candidate("/w/B/b2")])
        let model = ImportStepModel.make(catalog: first, selection: ImportSelection(checked: Set(first.candidates.map(\.path)))
                                             .applyingSuggestions(GroupSuggester.suggest(for: first.candidates,
                                                                                         checked: Set(first.candidates.map(\.path)),
                                                                                         existing: []).suggestion),
                                         existing: [], now: Date(), timeZone: .current)
        func groups(_ m: ImportStepModel) -> [String: String] {
            Dictionary(uniqueKeysWithValues: m.plan.additions.map { ($0.path, m.option($0.groupKey ?? "ungrouped").name) })
        }
        #expect(groups(model) == ["/w/A/a1": "A", "/w/A/a2": "A", "/w/B/b1": "B", "/w/B/b2": "B"])
        // b1 is newest now (the user ran claude there): B's rows come first.
        let reordered = catalog([candidate("/w/B/b1"), candidate("/w/A/a1"), candidate("/w/A/a2"), candidate("/w/B/b2")])
        let again = ImportStepModel.make(catalog: reordered, selection: model.selection, existing: [], now: Date(), timeZone: .current)
        #expect(groups(again) == groups(model))
        // A user-named group, then a re-detect that finds a new parent C with two rows.
        let (named, _) = again.selection.addingGroup(named: "我的", for: "/w/A/a1", catalog: reordered, options: again.options)
        let withC = catalog(reordered.candidates + [candidate("/w/C/c1"), candidate("/w/C/c2")])
        var selection = named
        selection.checked.formUnion(["/w/C/c1", "/w/C/c2"])
        selection.group["/w/C/c1"] = "new:/w/C"
        selection.group["/w/C/c2"] = "new:/w/C"
        let third = ImportStepModel.make(catalog: withC, selection: selection, existing: [], now: Date(), timeZone: .current)
        #expect(groups(third) == ["/w/A/a1": "我的", "/w/A/a2": "A", "/w/B/b1": "B", "/w/B/b2": "B", "/w/C/c1": "C", "/w/C/c2": "C"])
    }

    @Test("a name collision becomes `<grandparent> · <parent>`")
    func nameCollision() {
        let rows = [candidate("/w/clients/a"), candidate("/w/clients/b")]
        let existing = [ExistingGroup(id: "g", name: "Clients", color: nil, projectPaths: ["/elsewhere/x"])]
        let (options, _) = GroupSuggester.suggest(for: rows, checked: Set(rows.map(\.path)), existing: existing)
        #expect(options.map(\.name) == ["Clients", "w · clients", "未分類"])
    }

    @Test("colors follow the tag order and skip the colors groups already use")
    func colors() {
        let rows = [candidate("/w/a/1"), candidate("/w/a/2"), candidate("/w/b/1"), candidate("/w/b/2")]
        let existing = [ExistingGroup(id: "r", name: "R", color: "red", projectPaths: []),
                        ExistingGroup(id: "b", name: "B", color: "blue", projectPaths: [])]
        let (options, _) = GroupSuggester.suggest(for: rows, checked: Set(rows.map(\.path)), existing: existing)
        #expect(options.filter { $0.kind == .new }.map(\.color) == ["green", "yellow"])
        let user = GroupOption(key: "user:1", name: "我的", color: "green", kind: .new)
        let withUser = GroupSuggester.suggest(for: rows, checked: Set(rows.map(\.path)), existing: existing, userGroups: [user]).options
        #expect(withUser.map(\.key) == ["existing:r", "existing:b", "new:/w/a", "new:/w/b", "user:1", "ungrouped"])
        #expect(withUser.filter { $0.kind == .new }.map(\.color) == ["yellow", "purple", "green"])
    }

    @Test("the home folder and / never become a group")
    func homeNeverGroup() {
        let rows = [candidate("/Users/t/a"), candidate("/Users/t/b")]
        let suggestion = GroupSuggester.suggest(for: rows, checked: Set(rows.map(\.path)), existing: [], home: "/Users/t").suggestion
        #expect(suggestion.values.allSatisfy { $0 == "ungrouped" })
    }

    @Test("the plan keeps table order, lists new groups in first-use order, 未分類 and unknown keys as nil")
    func plan() {
        let rows = ["/w/x/a", "/w/y/b", "/w/x/c", "/w/z/d", "/w/q/e", "/w/q/f", "/w/q/unchecked"].map { candidate($0) }
        let options = [GroupOption(key: "existing:g1", name: "G", color: "blue", kind: .existing("g1")),
                       GroupOption(key: "new:2", name: "Y", color: "red", kind: .new),
                       GroupOption(key: "new:1", name: "X", color: "green", kind: .new), GroupOption.ungrouped]
        let selection = ImportSelection(checked: ["/w/x/a", "/w/y/b", "/w/x/c", "/w/z/d", "/w/q/e", "/w/q/f"],
                                        group: ["/w/x/a": "new:1", "/w/y/b": "new:2", "/w/x/c": "new:1", "/w/z/d": "existing:g1",
                                                "/w/q/e": "ungrouped", "/w/q/f": "new:77", "/w/q/unchecked": "new:1"])
        let plan = ImportPlan.make(selection, catalog: catalog(rows), options: options)
        #expect(plan.newGroups == [ImportPlan.NewGroup(key: "new:1", name: "X", color: "green"),
                                   ImportPlan.NewGroup(key: "new:2", name: "Y", color: "red")])
        #expect(plan.additions == [
            ImportPlan.Addition(path: "/w/x/a", groupKey: "new:1"), ImportPlan.Addition(path: "/w/y/b", groupKey: "new:2"),
            ImportPlan.Addition(path: "/w/x/c", groupKey: "new:1"), ImportPlan.Addition(path: "/w/z/d", groupKey: "existing:g1"),
            ImportPlan.Addition(path: "/w/q/e", groupKey: nil), ImportPlan.Addition(path: "/w/q/f", groupKey: nil),
        ])
        #expect(plan.groupCount == 3)
    }

    @Test("a named group takes the next free color and its own `user:<n>` key")
    func namedGroup() {
        let rows = [candidate("/w/x/a"), candidate("/w/y/b")]
        let all = catalog(rows)
        let options = [GroupOption(key: "existing:g", name: "G", color: "red", kind: .existing("g")), GroupOption.ungrouped]
        let (selection, group) = ImportSelection(checked: ["/w/x/a"]).addingGroup(named: " 新專案 ", for: "/w/x/a", catalog: all, options: options)
        #expect(group == GroupOption(key: "user:1", name: "新專案", color: "blue", kind: .new))
        #expect(selection.group["/w/x/a"] == "user:1")
        #expect(selection.newGroups == [group])
        let plan = ImportPlan.make(selection, catalog: all, options: options)
        #expect(plan.newGroups == [ImportPlan.NewGroup(key: "user:1", name: "新專案", color: "blue")])
        let model = ImportStepModel.make(catalog: all, selection: selection, existing: [], now: Date(), timeZone: .current)
        #expect(model.options.map(\.key) == ["user:1", "ungrouped"])
        #expect(model.summary == "1 個專案 → 1 個群組")
    }

    @Test("ImportStepModel moves a row whose group disappeared to its suggestion")
    func normalize() {
        let rows = [candidate("/w/x/a"), candidate("/w/x/b")]
        let selection = ImportSelection(checked: ["/w/x/a"], group: ["/w/x/a": "new:1", "/w/x/b": "new:1"])
        let model = ImportStepModel.make(catalog: catalog(rows), selection: selection, existing: [], now: Date(), timeZone: .current)
        #expect(model.selection.group["/w/x/a"] == "ungrouped")
        #expect(model.summary == "1 個專案 → 0 個群組 · 1 個未分類")
    }
}
