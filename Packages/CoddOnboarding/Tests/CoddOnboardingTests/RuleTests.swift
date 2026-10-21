import Foundation
import Testing
@testable import CoddOnboarding

@Suite("Name prefix, path elision, last-used text (D10)")
struct RuleTests {
    static let home = "/Users/operator"

    @Test("the artboard rows that get `parent/` and those that do not")
    func artboardPrefixes() {
        let paths = OnboardingSamples.artboardRows.map { Self.home + $0.path }
        let prefixes = NamePrefixRule.prefixes(for: paths, home: Self.home)
        func prefix(_ tail: String) -> String? { prefixes[Self.home + tail] }
        #expect(prefix("/Project/Northstar/lab/agent-lab-2026/原型試做") == "agent-lab-2026/")
        #expect(prefix("/Project/Northstar/lab/agent-lab-2026/整合範例/MCP") == "整合範例/")
        #expect(prefix("/Project/Northstar/lab/agent-lab-2026/整合範例/Skills") == "整合範例/")
        #expect(prefix("/Github/Gear3D") == nil)
        #expect(prefix("/Github/UsageBar") == nil)
        #expect(prefix("/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend") == nil)
        #expect(prefix("/Github/mysite.github.io") == nil)
    }

    @Test("a duplicate name gets its parent; a short name directly in home or a common root does not")
    func duplicatesAndRoots() {
        let prefixes = NamePrefixRule.prefixes(for: ["/w/a/app", "/w/b/app", "/Users/t/x", "/w/src/tool", "/w/labs/mcp"], home: "/Users/t")
        #expect(prefixes["/w/a/app"] == "a/")
        #expect(prefixes["/w/b/app"] == "b/")
        #expect(prefixes["/Users/t/x"] == nil)
        #expect(prefixes["/w/src/tool"] == nil)
        #expect(prefixes["/w/labs/mcp"] == "labs/")
    }

    /// JetBrains Mono at 11.5 px: 0.6 em per ASCII character and `…`, 1 em per CJK character.
    static func fits(_ width: CGFloat) -> (String) -> Bool {
        { text in
            let measured = text.reduce(CGFloat(0)) { sum, character in sum + (character.isASCII || character == "…" ? 6.9 : 11.5) }
            return measured <= width
        }
    }

    @Test("the path column keeps as many trailing components as fit (330 px = the artboard's column)")
    func elision() {
        #expect(PathText.elide("~/Project/Northstar/websites/業主/Northstar invoice system", fits: Self.fits(330))
                == "~/…/websites/業主/Northstar invoice system")
        #expect(PathText.elide("~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend", fits: Self.fits(330))
                == "~/…/orb-toolkit-suite/orb-toolkit-backend")
        #expect(PathText.elide("~/Github/Gear3D", fits: Self.fits(330)) == "~/Github/Gear3D")
        // At least the last component (the view then cuts its tail).
        #expect(PathText.elide("~/Project/Northstar/websites/orb-toolkit-suite/orb-toolkit-backend", fits: Self.fits(60))
                == "~/…/orb-toolkit-backend")
        #expect(PathText.elide("/opt/tools/a/b", fits: Self.fits(70)) == "/…/a/b")
    }

    @Test("standardize, abbreviate, compact")
    func pathText() {
        #expect(PathText.standardize("/a//b/./c/../d/") == "/a/b/d")
        #expect(PathText.standardize("~/x", home: "/Users/t") == "/Users/t/x")
        #expect(PathText.abbreviate("/Users/t/Github/a", home: "/Users/t/") == "~/Github/a")
        #expect(PathText.abbreviate("/Users/tt/a", home: "/Users/t") == "/Users/tt/a")
        #expect(PathText.compact("~/Library/Application Support/CODD/notes") == "~/…/CODD/notes")
        #expect(PathText.parent("/a") == "/")
    }

    @Test("今天 / 昨天 / M/dd (month unpadded, day padded)")
    func lastUsed() {
        let now = taipei(2026, 10, 15, 10, 41, 58)
        let zone = OnboardingSamples.timeZone
        #expect(LastUsedFormat.text(taipei(2026, 10, 15, 10, 34), now: now, timeZone: zone) == "今天 10:34")
        #expect(LastUsedFormat.text(taipei(2026, 10, 15, 0, 5), now: now, timeZone: zone) == "今天 00:05")
        #expect(LastUsedFormat.text(taipei(2026, 10, 14, 22, 47), now: now, timeZone: zone) == "昨天 22:47")
        #expect(LastUsedFormat.text(taipei(2026, 10, 13, 9, 0), now: now, timeZone: zone) == "10/13")
        #expect(LastUsedFormat.text(taipei(2026, 10, 9, 9, 0), now: now, timeZone: zone) == "10/09")
        #expect(LastUsedFormat.text(taipei(2026, 9, 21, 9, 0), now: now, timeZone: zone) == "9/21")
        #expect(LastUsedFormat.text(nil, now: now, timeZone: zone) == "—")
        // The zone decides the day: 00:30 in Taipei is the previous day in UTC.
        let early = taipei(2026, 10, 15, 0, 30)
        let utc = TimeZone(identifier: "UTC")!
        #expect(LastUsedFormat.text(early, now: taipei(2026, 10, 15, 9, 0), timeZone: utc) == "昨天 16:30")
    }
}

@Suite("Pre-check, filter, page (D8)")
struct SelectionTests {
    static let now = taipei(2026, 10, 15, 12, 0)

    @Test("used in the last 14 days, not hidden, at most 12, newest first")
    func preCheck() {
        var candidates: [ImportCandidate] = []
        for index in 0..<15 { candidates.append(candidate("/w/p\(index)", lastUsed: Self.now.addingTimeInterval(-Double(index) * 3600))) }
        candidates.append(candidate("/w/old", lastUsed: Self.now.addingTimeInterval(-15 * 86_400)))
        candidates.append(candidate("/w/wt/.claude-worktrees/x", lastUsed: Self.now, hidden: .worktree))
        candidates.append(candidate("/w/never"))
        let selection = ImportSelection.initial(catalog(candidates), existing: [], now: Self.now)
        #expect(selection.checked == Set((0..<12).map { "/w/p\($0)" }))
        #expect(selection.limit == 12)
        #expect(!selection.showHidden)
        #expect(selection.filter.isEmpty)
    }

    @Test("the filter ignores case, width and diacritics over name and path, and searches every candidate")
    func filter() {
        var candidates = (0..<30).map { candidate("/w/project-\($0)") }
        candidates.append(candidate("/Users/test/Github/Gear3D"))
        candidates.append(candidate("/w/Café"))
        candidates.append(candidate("/w/hidden/.claude-worktrees/gear-wt", hidden: .worktree))
        let all = catalog(candidates)
        func names(_ text: String, hidden: Bool = false) -> [String] {
            ImportSelection(filter: text, showHidden: hidden).visible(in: all).map(\.name)
        }
        #expect(names("gear") == ["Gear3D"])
        #expect(names("ＧＥＡＲ") == ["Gear3D"])
        #expect(names("cafe") == ["Café"])
        #expect(names("~/github") == ["Gear3D"])
        #expect(names("gear", hidden: true) == ["Gear3D", "gear-wt"])
        #expect(names("  ").count == 12)
    }

    @Test("12 rows, then 24 more per page; hidden rows only with the toggle")
    func paging() {
        let candidates = (0..<50).map { candidate("/w/p\($0)", hidden: $0 == 3 ? .sdk : nil) }
        let all = catalog(candidates)
        var selection = ImportSelection()
        #expect(selection.visible(in: all).count == 12)
        #expect(!selection.visible(in: all).contains { $0.name == "p3" })
        selection = selection.loadingMore()
        #expect(selection.visible(in: all).count == 36)
        selection = selection.loadingMore()
        #expect(selection.visible(in: all).count == 49)
        #expect(selection.togglingHidden().matching(in: all).count == 50)
    }

    @Test("mutations: toggle, set, assign, apply suggestions to checked rows only")
    func mutations() {
        var selection = ImportSelection(checked: ["/a"])
        selection = selection.toggling("/b").toggling("/a")
        #expect(selection.checked == ["/b"])
        selection = selection.setting(["/c", "/d"], checked: true).setting(["/d"], checked: false)
        #expect(selection.checked == ["/b", "/c"])
        selection = selection.assigning("existing:g", to: "/b")
        #expect(selection.groupKey(for: "/b") == "existing:g")
        #expect(selection.groupKey(for: "/z") == GroupOption.ungroupedKey)
        let applied = selection.applyingSuggestions(["/b": "new:1", "/c": "new:2", "/x": "new:3"])
        #expect(applied.group["/b"] == "new:1")
        #expect(applied.group["/c"] == "new:2")
        #expect(applied.group["/x"] == nil)
    }
}
