import Darwin
import Foundation
import Testing
@testable import CoddClaudeSettings

@Suite("Installer plans")
struct InstallerPlanTests {
    /// 2026-10-17 10:42:10 local time.
    static let now: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 10, minute: 42, second: 10))!
    }()

    static let stamp = "20261017-104210"

    func plan(_ file: ClaudeSettingsFile, _ action: InstallerAction, _ desktop: DesktopStatusLine) throws -> InstallerPlan {
        try ClaudeSettingsInstaller.plan(file, action: action, desktop: desktop, now: Self.now)
    }

    func root(_ text: String) throws -> OrderedJSON {
        try OrderedJSON.parse(Data(text.utf8))
    }

    /// The plan's diff is consistent with both texts: every numbered line is the real line.
    func checkDiffAgainstTexts(_ p: InstallerPlan, old: String, new: String) {
        let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
        for line in p.diff {
            switch line.kind {
            case .context:
                #expect(oldLines[line.oldNumber! - 1] == line.text)
                #expect(newLines[line.newNumber! - 1] == line.text)
            case .removed:
                #expect(oldLines[line.oldNumber! - 1] == line.text)
                #expect(line.newNumber == nil)
            case .added:
                #expect(newLines[line.newNumber! - 1] == line.text)
                #expect(line.oldNumber == nil)
            case .hunk:
                #expect(line.text.wholeMatch(of: /@@ -\d+,\d+ \+\d+,\d+ @@  "(hooks|statusLine)"/) != nil, "\(line.text)")
            case .elided:
                #expect(line.text.wholeMatch(of: /…（保留既有 \d+ 組 hook）/) != nil)
            }
        }
        #expect(p.addedLines == p.diff.filter { $0.kind == .added }.count)
        #expect(p.removedLines == p.diff.filter { $0.kind == .removed }.count)
    }

    /// `bin/hook-tap` marks hook-tap's handlers: the status-line lines the diff does show chain
    /// `~/.hook-tap/statusline.sh`.
    func expectNoForeignOrOutsideText(_ p: InstallerPlan) {
        for line in p.diff {
            for word in ["bin/hook-tap", "osascript", "display notification", "\"env\"", "permissions", "GREETING",
                         "enabledPlugins", "$schema", "\"model\"", "numbers", "feedbackSurveyState"] {
                #expect(!line.text.contains(word), "diff line leaks \(word): \(line.text)")
            }
        }
    }

    // MARK: update

    @Test func updateOnTheUserFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try Fixture.writeUserSettings(tmp)
        let file = try ClaudeSettingsFile.load(url)
        let desktop = ClaudeSettingsInstaller.testDesktop(tmp)
        let p = try plan(file, .update, desktop)
        let inner = Fixture.hookTapStatusLine(tmp)
        let oldText = try Fixture.userSettings(tmp)

        #expect(p.changes)
        #expect(p.action == .update)
        #expect(p.removedEvents == InspectionTests.legacyEvents)
        #expect(p.addedEvents == [])
        #expect(p.statusLineBefore == file.root["statusLine"]?["command"]?.stringValue)
        #expect(p.statusLineAfter == desktop.command(chain: inner))
        #expect(p.backupName == "settings.json.codd-bak-\(Self.stamp)")
        #expect(p.base == file.fingerprint)
        #expect(p.summary == [
            "移除 10 個 event 的舊版 CODD web hook（status-writer.js）",
            "安裝 CODD statusline，串接原本的 statusline",
            "外部 hooks 保持不動：hook-tap ×12 · osascript ×2",
        ])
        #expect(p.foreignKept.map(\.code) == ["hook-tap", "osascript"])

        let new = try root(p.newText)
        let old = file.root
        // Every key keeps its place and value except hooks and statusLine.
        #expect(new.objectMembers?.map(\.key) == old.objectMembers?.map(\.key))
        for member in old.objectMembers! where !["hooks", "statusLine"].contains(member.key) {
            #expect(new[member.key] == member.value, "\(member.key)")
        }
        // The text outside hooks / statusLine is byte-identical.
        let hooksStart = try #require(oldText.range(of: "\n  \"hooks\": {"))
        let pluginsStart = try #require(oldText.range(of: "\n  \"enabledPlugins\": {"))
        #expect(p.newText.hasPrefix(String(oldText[..<hooksStart.lowerBound])))
        #expect(p.newText.hasSuffix(String(oldText[pluginsStart.lowerBound...])))
        // No legacy left; every foreign handler survives, same order, same bytes.
        #expect(!p.newText.contains("status-writer.js"))
        let foreignBefore = handlers(in: old).filter { !HookTree.isLegacy($0.handler.objectMembers!) }
        let foreignAfter = handlers(in: new)
        #expect(foreignBefore.map(\.event) == foreignAfter.map(\.event))
        #expect(foreignBefore.map(\.handler) == foreignAfter.map(\.handler))
        var foreignGroups = 0
        for event in old["hooks"]!.objectMembers! {
            for group in event.value.arrayElements! where !containsLegacy(group) {
                #expect(p.newText.contains(embedded(group, indent: "  ", level: 3)))
                foreignGroups += 1
            }
        }
        #expect(foreignGroups == 14)
        // statusLine: wrapper chaining the web wrapper's inner command, padding kept in place.
        #expect(new["statusLine"] == .object([
            ("type", .string("command")), ("command", .string(desktop.command(chain: inner))), ("padding", .number("0")),
        ]))
        #expect(p.newText.hasSuffix("\n"))
        #expect(ClaudeSettingsInstaller.inspect(ClaudeSettingsFile(url: url, root: new), desktop: desktop).isUpToDate)
    }

    @Test func updateDiffShowsOnlyCODDLines() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try ClaudeSettingsFile.load(try Fixture.writeUserSettings(tmp))
        let p = try plan(file, .update, ClaudeSettingsInstaller.testDesktop(tmp))
        checkDiffAgainstTexts(p, old: file.serializedText, new: p.newText)
        expectNoForeignOrOutsideText(p)
        #expect(p.diff.contains { $0.kind == .elided })
        #expect(p.diff.filter { $0.kind == .removed && $0.text.contains("status-writer.js") }.count == 10)
        #expect(p.diff.filter { $0.kind == .added && $0.text.contains("/bin/codd-statusline") }.count == 1)
        #expect(p.diff.filter { $0.kind == .removed && $0.text.contains("codd-statusline.js") }.count == 1)
        #expect(p.diff.first?.kind == .hunk)
        #expect(p.diff.contains { $0.kind == .hunk && $0.text.hasSuffix("  \"statusLine\"") })
        #expect(p.addedLines > 0 && p.removedLines > p.addedLines)
        // The status line's position: the hooks hunks come first, as in the file.
        let statusHunk = p.diff.firstIndex { $0.kind == .hunk && $0.text.hasSuffix("\"statusLine\"") }!
        #expect(p.diff[..<statusHunk].contains { $0.text.contains("status-writer.js") })
    }

    @Test func diffOfASmallFileLineByLine() throws {
        let text = """
        {
          "model": "opus",
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "node /w/status-writer.js"
                  }
                ]
              },
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "/x/hook-tap Stop"
                  }
                ]
              }
            ]
          },
          "statusLine": {
            "type": "command",
            "command": "/u/sl.sh"
          }
        }

        """
        let file = try ClaudeSettingsFile.decode(Data(text.utf8), url: URL(fileURLWithPath: "/nonexistent/settings.json"), fingerprint: nil)
        #expect(file.serializedText == text)
        let desktop = DesktopStatusLine(dataRoot: "/r")
        let p = try plan(file, .update, desktop)
        let wrapper = JSONWriter.quoted(desktop.command(chain: "/u/sl.sh"))
        let expected: [DiffLine] = [
            DiffLine(kind: .hunk, text: "@@ -3,12 +3,4 @@  \"hooks\""),
            DiffLine(kind: .context, oldNumber: 3, newNumber: 3, text: "  \"hooks\": {"),
            DiffLine(kind: .context, oldNumber: 4, newNumber: 4, text: "    \"Stop\": ["),
            DiffLine(kind: .removed, oldNumber: 5, text: "      {"),
            DiffLine(kind: .removed, oldNumber: 6, text: "        \"hooks\": ["),
            DiffLine(kind: .removed, oldNumber: 7, text: "          {"),
            DiffLine(kind: .removed, oldNumber: 8, text: "            \"type\": \"command\","),
            DiffLine(kind: .removed, oldNumber: 9, text: "            \"command\": \"node /w/status-writer.js\""),
            DiffLine(kind: .removed, oldNumber: 10, text: "          }"),
            DiffLine(kind: .removed, oldNumber: 11, text: "        ]"),
            DiffLine(kind: .removed, oldNumber: 12, text: "      },"),
            DiffLine(kind: .elided, text: "…（保留既有 1 組 hook）"),
            DiffLine(kind: .hunk, text: "@@ -23,4 +15,4 @@  \"statusLine\""),
            DiffLine(kind: .context, oldNumber: 23, newNumber: 15, text: "  \"statusLine\": {"),
            DiffLine(kind: .context, oldNumber: 24, newNumber: 16, text: "    \"type\": \"command\","),
            DiffLine(kind: .removed, oldNumber: 25, text: "    \"command\": \"/u/sl.sh\""),
            DiffLine(kind: .added, newNumber: 17, text: "    \"command\": \(wrapper)"),
            DiffLine(kind: .context, oldNumber: 26, newNumber: 18, text: "  }"),
        ]
        #expect(p.diff == expected)
        #expect(p.addedLines == 1)
        #expect(p.removedLines == 9)
        #expect(p.summary == [
            "移除 1 個 event 的舊版 CODD web hook（status-writer.js）",
            "安裝 CODD statusline，串接原本的 statusline",
            "外部 hooks 保持不動：hook-tap ×1",
        ])
    }

    @Test func removingTheLastGroupElidesTheForeignCommaChange() throws {
        let text = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/x/hook-tap Stop"}]},{"hooks":[{"type":"command","command":"node /w/status-writer.js"}]}]}}"#
        let file = try ClaudeSettingsFile.decode(Data(text.utf8), url: URL(fileURLWithPath: "/n/settings.json"), fingerprint: nil)
        let p = try plan(file, .removeLegacy, DesktopStatusLine(dataRoot: "/r"))
        checkDiffAgainstTexts(p, old: file.serializedText, new: p.newText)
        expectNoForeignOrOutsideText(p)
        // `},` → `}` on the kept hook-tap group is folded into the elided line, not shown.
        #expect(p.diff.filter { $0.kind == .elided }.map(\.text) == ["…（保留既有 1 組 hook）"])
        #expect(p.diff.filter { $0.kind == .removed }.count == 8)
        #expect(p.addedLines == 0)
    }

    @Test func updateTwiceIsANoOp() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try Fixture.writeUserSettings(tmp)
        let desktop = ClaudeSettingsInstaller.testDesktop(tmp)
        let first = try plan(try ClaudeSettingsFile.load(url), .update, desktop)
        _ = try ClaudeSettingsInstaller.apply(first, to: url)
        let second = try plan(try ClaudeSettingsFile.load(url), .update, desktop)
        #expect(!second.changes)
        #expect(second.diff.isEmpty)
        #expect(second.addedLines == 0 && second.removedLines == 0)
        #expect(second.summary == ["已是最新：沒有舊版 hook，CODD statusline 已安裝"])
        #expect(second.newText == first.newText)
        #expect(try ClaudeSettingsInstaller.apply(second, to: url) == nil)
    }

    @Test func uninstallAfterUpdateGivesTheInnerCommandBack() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try Fixture.writeUserSettings(tmp)
        let desktop = ClaudeSettingsInstaller.testDesktop(tmp)
        _ = try ClaudeSettingsInstaller.apply(try plan(try ClaudeSettingsFile.load(url), .update, desktop), to: url)
        let updated = try ClaudeSettingsFile.load(url)
        let p = try plan(updated, .uninstall, desktop)
        #expect(p.changes)
        #expect(p.summary == ["解除安裝 CODD statusline，換回原本串接的 statusline", "外部 hooks 保持不動：hook-tap ×12 · osascript ×2"])
        let new = try root(p.newText)
        #expect(new["statusLine"] == .object([
            ("type", .string("command")), ("command", .string(Fixture.hookTapStatusLine(tmp))), ("padding", .number("0")),
        ]))
        #expect(new["hooks"] == updated.root["hooks"])
        #expect(p.statusLineAfter == Fixture.hookTapStatusLine(tmp))
        checkDiffAgainstTexts(p, old: updated.serializedText, new: p.newText)
        #expect(p.diff.allSatisfy { $0.kind == .hunk ? $0.text.hasSuffix("\"statusLine\"") : true })
        #expect(p.addedLines == 1 && p.removedLines == 1)
        // Legacy is never restored, and a second uninstall has nothing to do.
        #expect(!p.newText.contains("status-writer.js"))
        _ = try ClaudeSettingsInstaller.apply(p, to: url)
        #expect(try !plan(try ClaudeSettingsFile.load(url), .uninstall, desktop).changes)
    }

    @Test func uninstallWithoutChainRemovesTheCommandKeepingOtherKeys() throws {
        let desktop = DesktopStatusLine(dataRoot: "/r")
        let command = JSONWriter.quoted(desktop.command(chain: nil))
        let keep = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"),
                                      root: try root("{\"statusLine\": {\"type\": \"command\", \"command\": \(command), \"refreshInterval\": 5}}"))
        let p = try plan(keep, .uninstall, desktop)
        #expect(try root(p.newText) == root(#"{"statusLine": {"refreshInterval": 5}}"#))
        #expect(p.summary == ["解除安裝 CODD statusline（安裝前沒有 statusline）"])
        let drop = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"),
                                      root: try root("{\"model\": \"x\", \"statusLine\": {\"type\": \"command\", \"command\": \(command)}}"))
        #expect(try root(try plan(drop, .uninstall, desktop).newText) == root(#"{"model": "x"}"#))
    }

    @Test func updateCasesForTheStatusLine() throws {
        let desktop = DesktopStatusLine(dataRoot: "/r")
        func run(_ text: String) throws -> InstallerPlan {
            try plan(ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"), root: try root(text)), .update, desktop)
        }
        let none = try run(#"{"model": "x"}"#)
        #expect(none.summary == ["安裝 CODD statusline（目前沒有 statusline，只回報用量）"])
        #expect(try root(none.newText)["statusLine"] == .object([("type", .string("command")), ("command", .string(desktop.command(chain: nil)))]))

        let user = try run(#"{"statusLine": {"refreshInterval": 5, "command": "~/bin/sl.sh", "hideVimModeIndicator": true}}"#)
        #expect(user.summary == ["安裝 CODD statusline，串接原本的 statusline"])
        #expect(try root(user.newText)["statusLine"] == .object([
            ("refreshInterval", .number("5")), ("command", .string(desktop.command(chain: "~/bin/sl.sh"))),
            ("hideVimModeIndicator", .bool(true)), ("type", .string("command")),
        ]))

        let otherRoot = DesktopStatusLine(dataRoot: "/old").command(chain: "~/bin/sl.sh")
        let refresh = try run("{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONWriter.quoted(otherRoot))}}")
        #expect(refresh.summary == ["更新 CODD statusline 的路徑（串接的 statusline 不變）"])
        #expect(refresh.statusLineAfter == desktop.command(chain: "~/bin/sl.sh"))
    }

    // MARK: removeLegacy

    @Test func removeLegacyOnTheUserFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try ClaudeSettingsFile.load(try Fixture.writeUserSettings(tmp))
        let p = try plan(file, .removeLegacy, ClaudeSettingsInstaller.testDesktop(tmp))
        #expect(p.summary == [
            "移除 10 個 event 的舊版 CODD web hook（status-writer.js）",
            "CODD web 的 statusline 換回原本的 statusline",
            "外部 hooks 保持不動：hook-tap ×12 · osascript ×2",
        ])
        let new = try root(p.newText)
        #expect(new["statusLine"] == .object([
            ("type", .string("command")), ("command", .string(Fixture.hookTapStatusLine(tmp))), ("padding", .number("0")),
        ]))
        #expect(!p.newText.contains("status-writer.js"))
        #expect(!p.newText.contains("codd-statusline"))
        #expect(handlers(in: new).count == 14)
        for event in file.root["hooks"]!.objectMembers! {
            for group in event.value.arrayElements! where !containsLegacy(group) {
                #expect(p.newText.contains(embedded(group, indent: "  ", level: 3)))
            }
        }
        checkDiffAgainstTexts(p, old: file.serializedText, new: p.newText)
        expectNoForeignOrOutsideText(p)
    }

    @Test func removeLegacyOnAStandaloneWebWrapper() throws {
        let web = JSONWriter.quoted("if [ -x '/n' ] && [ -f '/r/configs/statusline/codd-statusline.js' ]; then STATUS_DIR_PATH='/s' '/n' '/r/configs/statusline/codd-statusline.js'; else :; fi")
        let desktop = DesktopStatusLine(dataRoot: "/r")
        let keep = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"),
                                      root: try root("{\"statusLine\": {\"type\": \"command\", \"command\": \(web), \"padding\": 1}}"))
        let p = try plan(keep, .removeLegacy, desktop)
        #expect(try root(p.newText) == root(#"{"statusLine": {"padding": 1}}"#))
        #expect(p.summary == ["移除 CODD web 的 statusline（安裝前沒有 statusline）"])
        #expect(p.statusLineAfter == nil)
        let drop = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"),
                                      root: try root("{\"statusLine\": {\"type\": \"command\", \"command\": \(web)}, \"model\": \"x\"}"))
        #expect(try root(try plan(drop, .removeLegacy, desktop).newText) == root(#"{"model": "x"}"#))
        // `update` on a standalone web wrapper installs CODD's without a chain.
        let update = try plan(keep, .update, desktop)
        #expect(update.statusLineAfter == desktop.command(chain: nil))
        #expect(update.summary == ["安裝 CODD statusline，取代 CODD web 的 statusline"])
    }

    @Test func groupsAndEventsAreDroppedOnlyWhenEmptied() throws {
        let file = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"), root: try root(#"""
        {"hooks": {
          "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "node /w/status-writer.js"}, {"type": "command", "command": "/x/foo"}]}],
          "SessionEnd": [{"matcher": "*", "command": "node /w/status-writer.js"}],
          "PreCompact": [],
          "Notification": [{"hooks": []}]
        }, "model": "x"}
        """#))
        let p = try plan(file, .removeLegacy, DesktopStatusLine(dataRoot: "/r"))
        #expect(try root(p.newText) == root(#"""
        {"hooks": {
          "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "/x/foo"}]}],
          "PreCompact": [],
          "Notification": [{"hooks": []}]
        }, "model": "x"}
        """#))
        #expect(p.removedEvents == ["Stop", "SessionEnd"])
        #expect(!p.diff.contains { $0.text.contains("/x/foo") })
        // Only legacy in the file: the whole `hooks` key goes.
        let only = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"),
                                      root: try root(#"{"model": "x", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "a/status-writer.js"}]}]}}"#))
        #expect(try root(try plan(only, .removeLegacy, DesktopStatusLine(dataRoot: "/r")).newText) == root(#"{"model": "x"}"#))
    }

    // MARK: disableDuplicateNotifications

    @Test func disableDuplicateNotificationsOnTheUserFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try ClaudeSettingsFile.load(try Fixture.writeUserSettings(tmp))
        let p = try plan(file, .disableDuplicateNotifications, ClaudeSettingsInstaller.testDesktop(tmp))
        #expect(p.summary == [
            "停用 2 個重複的 osascript 通知（Notification, Stop）· 改由 CODD 通知",
            "其他外部 hooks 保持不動：hook-tap ×12",
        ])
        #expect(p.removedEvents == ["Notification", "Stop"])
        #expect(p.foreignKept.map(\.code) == ["hook-tap"])
        let new = try root(p.newText)
        #expect(!p.newText.contains("osascript"))
        #expect(new["statusLine"] == file.root["statusLine"])
        #expect(handlers(in: new).count == handlers(in: file.root).count - 2)
        #expect(ClaudeSettingsInstaller.inspect(ClaudeSettingsFile(url: file.url, root: new), desktop: ClaudeSettingsInstaller.testDesktop(tmp)).legacyHandlerCount == 10)
        // The removed duplicates are what the dialog shows; hook-tap stays elided.
        checkDiffAgainstTexts(p, old: file.serializedText, new: p.newText)
        #expect(p.diff.filter { $0.kind == .removed && $0.text.contains("display notification") }.count == 2)
        #expect(!p.diff.contains { $0.text.contains("hook-tap") })
        #expect(p.addedLines == 0)
        #expect(!p.diff.contains { $0.text.contains("statusLine") })
    }

    // MARK: Refusals

    @Test func undecodableChainsAreRefused() throws {
        let desktop = DesktopStatusLine(dataRoot: "/r")
        let web = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"), root: try root(
            #"{"statusLine": {"type": "command", "command": "'/n' '/r/codd-statusline.js' --chain-b64 eA; else /bin/sh -c 'x'; fi"}}"#))
        #expect(ClaudeSettingsInstaller.inspect(web, desktop: desktop).statusLine == .undecodable)
        #expect(throws: ClaudeSettingsError.chainUndecodable) { try plan(web, .update, desktop) }
        #expect(throws: ClaudeSettingsError.chainUndecodable) { try plan(web, .removeLegacy, desktop) }
        #expect(try !plan(web, .uninstall, desktop).changes)
        #expect(try !plan(web, .disableDuplicateNotifications, desktop).changes)

        let edited = desktop.command(chain: "x").replacingOccurrences(of: "else /bin/sh -c 'x'", with: "else /bin/sh -c 'y'")
        let desk = ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"),
                                      root: try root("{\"statusLine\": {\"type\": \"command\", \"command\": \(JSONWriter.quoted(edited))}}"))
        #expect(throws: ClaudeSettingsError.chainUndecodable) { try plan(desk, .update, desktop) }
        #expect(throws: ClaudeSettingsError.chainUndecodable) { try plan(desk, .uninstall, desktop) }
        #expect(try !plan(desk, .removeLegacy, desktop).changes)
    }

    @Test func unsupportedShapesAreRefused() throws {
        let desktop = DesktopStatusLine(dataRoot: "/r")
        func file(_ text: String) throws -> ClaudeSettingsFile {
            ClaudeSettingsFile(url: URL(fileURLWithPath: "/n/s.json"), root: try root(text))
        }
        #expect(throws: ClaudeSettingsError.shapeNotSupported("hooks")) { try plan(try file(#"{"hooks": []}"#), .update, desktop) }
        #expect(throws: ClaudeSettingsError.shapeNotSupported("hooks.Stop")) {
            try plan(try file(#"{"hooks": {"SessionStart": [], "Stop": {}}}"#), .removeLegacy, desktop)
        }
        #expect(throws: ClaudeSettingsError.shapeNotSupported("hooks")) {
            try plan(try file(#"{"hooks": "x"}"#), .disableDuplicateNotifications, desktop)
        }
        #expect(throws: ClaudeSettingsError.shapeNotSupported("statusLine")) { try plan(try file(#"{"statusLine": "x"}"#), .update, desktop) }
        #expect(throws: ClaudeSettingsError.shapeNotSupported("statusLine")) { try plan(try file(#"{"statusLine": []}"#), .uninstall, desktop) }
        // Uninstall never looks at hooks.
        #expect(try !plan(try file(#"{"hooks": []}"#), .uninstall, desktop).changes)
    }

    // MARK: Formatting kept

    @Test func fourSpaceFileKeepsItsIndent() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let two = try ClaudeSettingsFile.load(try Fixture.writeUserSettings(tmp))
        let four = try ClaudeSettingsFile.load(try Fixture.writeUserSettings(tmp, name: "four.json", fourSpaces: true))
        #expect(four.indent == "    ")
        let desktop = ClaudeSettingsInstaller.testDesktop(tmp)
        let p2 = try plan(two, .update, desktop), p4 = try plan(four, .update, desktop)
        #expect(try root(p4.newText) == root(p2.newText))
        #expect(p4.newText == (try root(p2.newText)).serialized(indent: "    ") + "\n")
        #expect(p4.newText.contains("\n        \"SessionStart\": [\n"))
        #expect(p4.backupName == "four.json.codd-bak-\(Self.stamp)")
        checkDiffAgainstTexts(p4, old: four.serializedText, new: p4.newText)
        expectNoForeignOrOutsideText(p4)
    }

    @Test func noTrailingNewlineAndTabsAreKept() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = tmp.file("settings.json")
        try Fixture.data("tabs-no-newline.json").write(to: url)
        let file = try ClaudeSettingsFile.load(url)
        let p = try plan(file, .update, DesktopStatusLine(dataRoot: "/r"))
        #expect(!p.newText.hasSuffix("\n"))
        #expect(p.newText.hasPrefix("{\n\t\"zeta\": 1,\n\t\"alpha\": {\n\t\t\"b\": [\n"))
        #expect(p.newText.hasSuffix("\n\t\"statusLine\": {\n\t\t\"type\": \"command\",\n\t\t\"command\": \(JSONWriter.quoted(DesktopStatusLine(dataRoot: "/r").command(chain: nil)))\n\t}\n}"))
    }

    @Test func nonCanonicalLayoutIsFlaggedAndNeverRewrittenForNothing() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let text = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"a/status-writer.js"}]}]}}"#
        let url = try tmp.write("settings.json", text)
        let file = try ClaudeSettingsFile.load(url)
        #expect(!file.isCanonical)
        #expect(try ClaudeSettingsFile.load(try Fixture.writeUserSettings(tmp, name: "user.json")).isCanonical)
        // Nothing to change: no write, the hand layout stays byte for byte.
        let none = try plan(file, .uninstall, DesktopStatusLine(dataRoot: "/r"))
        #expect(!none.changes)
        #expect(try ClaudeSettingsInstaller.apply(none, to: url) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        // A real change says that the layout will be normalized.
        let p = try plan(file, .removeLegacy, DesktopStatusLine(dataRoot: "/r"))
        #expect(p.summary == [
            "移除 1 個 event 的舊版 CODD web hook（status-writer.js）",
            "目前的排版不是 Claude Code 的標準格式：寫入後每個值都不變，但整份檔案的空白與換行會重新排列",
        ])
        #expect(p.newText == "{\n  \"model\": \"opus\"\n}")
    }

    @Test func backupReasons() {
        #expect(InstallerAction.update.backupReason == "更新 hooks 與 statusline")
        #expect(InstallerAction.removeLegacy.backupReason == "移除舊版 CODD web 設定")
        #expect(InstallerAction.uninstall.backupReason == "解除安裝 CODD statusline")
        #expect(InstallerAction.disableDuplicateNotifications.backupReason == "停用重複通知")
        #expect(InstallerAction.restore(URL(fileURLWithPath: "/x/settings.json.codd-bak-20261012-091503")).backupReason
            == "還原 settings.json.codd-bak-20261012-091503 之前")
    }

    @Test func numberSpellingsSurviveAnUpdate() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = tmp.file("settings.json")
        try Fixture.data("numbers.json").write(to: url)
        let p = try plan(try ClaudeSettingsFile.load(url), .update, DesktopStatusLine(dataRoot: "/r"))
        for token in ["1e3", "0.10", "-0", "12345678901234567890", "-1.5E+7", "-12.500", "1E-0"] {
            #expect(p.newText.contains(token))
        }
        let original = try Fixture.text("numbers.json")
        #expect(p.newText.hasPrefix(String(original.dropLast(3))))
    }
}

@Suite("Installer apply and backups")
struct InstallerApplyTests {
    func plan(_ url: URL, _ action: InstallerAction = .update, desktop: DesktopStatusLine = DesktopStatusLine(dataRoot: "/r"),
              now: Date = InstallerPlanTests.now) throws -> InstallerPlan {
        try ClaudeSettingsInstaller.plan(try ClaudeSettingsFile.load(url), action: action, desktop: desktop, now: now)
    }

    @Test func applyBacksUpThenWrites() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try Fixture.writeUserSettings(tmp)
        let original = try Data(contentsOf: url)
        chmod(url.path, 0o600)
        let p = try plan(url, desktop: ClaudeSettingsInstaller.testDesktop(tmp))
        let backup = try #require(try ClaudeSettingsInstaller.apply(p, to: url))
        #expect(backup == tmp.file("settings.json.codd-bak-\(InstallerPlanTests.stamp)"))
        #expect(try Data(contentsOf: backup) == original)
        #expect(try String(contentsOf: url, encoding: .utf8) == p.newText)
        #expect(fileMode(url.path) == 0o600)
        #expect(fileMode(backup.path) == 0o600)
        // No temp file left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: tmp.path).filter { $0.contains("codd-tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func changedSinceReadIsRefused() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try Fixture.writeUserSettings(tmp)
        let p = try plan(url)
        // Same bytes, new mtime (a `touch`).
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW)), timespec(tv_sec: 1_800_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        let before = try Data(contentsOf: url)
        #expect(throws: ClaudeSettingsError.changedSinceRead) { try ClaudeSettingsInstaller.apply(p, to: url) }
        #expect(try Data(contentsOf: url) == before)
        #expect(ClaudeSettingsInstaller.backups(of: url).isEmpty)
        // Deleted since the preview, or created since a preview of a missing file.
        let gone = try plan(url)
        try FileManager.default.removeItem(at: url)
        #expect(throws: ClaudeSettingsError.changedSinceRead) { try ClaudeSettingsInstaller.apply(gone, to: url) }
        let fresh = try plan(url)
        try tmp.write("settings.json", "{}\n")
        #expect(throws: ClaudeSettingsError.changedSinceRead) { try ClaudeSettingsInstaller.apply(fresh, to: url) }
    }

    @Test func backupNamesAvoidCollisions() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try tmp.write("settings.json", "{\n  \"model\": \"opus\"\n}\n")
        let base = "settings.json.codd-bak-\(InstallerPlanTests.stamp)"
        try tmp.write(base, "older")
        let p = try plan(url)
        #expect(p.backupName == base + "-2")
        // Another backup took -2 between preview and apply: the next free name is used.
        try tmp.write(base + "-2", "racing")
        let backup = try ClaudeSettingsInstaller.apply(p, to: url)
        #expect(backup?.lastPathComponent == base + "-3")
        #expect(try String(contentsOf: tmp.file(base), encoding: .utf8) == "older")
        #expect(try String(contentsOf: tmp.file(base + "-2"), encoding: .utf8) == "racing")
        #expect(try String(contentsOf: backup!, encoding: .utf8) == "{\n  \"model\": \"opus\"\n}\n")
    }

    @Test func symlinkedSettingsStayASymlink() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let target = try Fixture.writeUserSettings(tmp, name: "dotfiles/claude/settings.json")
        let original = try Data(contentsOf: target)
        let link = tmp.file("home/.claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../dotfiles/claude/settings.json")
        let p = try plan(link, desktop: ClaudeSettingsInstaller.testDesktop(tmp))
        let backup = try #require(try ClaudeSettingsInstaller.apply(p, to: link))
        // The backup sits next to the path the user gave and holds the target's bytes.
        #expect(backup.deletingLastPathComponent().path == link.deletingLastPathComponent().path)
        #expect(!isSymlink(backup.path))
        #expect(try Data(contentsOf: backup) == original)
        // The link is still a link to the same file, which now has the new text.
        #expect(isSymlink(link.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../../dotfiles/claude/settings.json")
        #expect(try String(contentsOf: target, encoding: .utf8) == p.newText)
        #expect(ClaudeSettingsInstaller.backups(of: link).map(\.url) == [backup])
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["settings.json"])
    }

    @Test func missingFileUpdateCreatesItWithoutBackup() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = tmp.file("home/.claude/settings.json")
        let desktop = DesktopStatusLine(dataRoot: "/r")
        let p = try plan(url, desktop: desktop)
        #expect(p.changes)
        #expect(p.base == nil)
        #expect(p.diff.first == DiffLine(kind: .hunk, text: "@@ -0,0 +2,4 @@  \"statusLine\""))
        #expect(p.addedLines == 4 && p.removedLines == 0)
        #expect(try ClaudeSettingsInstaller.apply(p, to: url) == nil)
        #expect(try String(contentsOf: url, encoding: .utf8) ==
            "{\n  \"statusLine\": {\n    \"type\": \"command\",\n    \"command\": \(JSONWriter.quoted(desktop.command(chain: nil)))\n  }\n}\n")
        #expect(fileMode(url.path) == 0o644)
        #expect(ClaudeSettingsInstaller.backups(of: url).isEmpty)
        // The other actions have nothing to do on a missing file and create nothing.
        let other = tmp.file("other/settings.json")
        for action in [InstallerAction.removeLegacy, .uninstall, .disableDuplicateNotifications] {
            let q = try plan(other, action)
            #expect(!q.changes)
            #expect(try ClaudeSettingsInstaller.apply(q, to: other) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func danglingSymlinkIsWrittenThroughToItsTarget() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let link = tmp.file("claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/settings.json")
        let p = try plan(link)
        #expect(p.base == nil)
        #expect(try ClaudeSettingsInstaller.apply(p, to: link) == nil)
        #expect(isSymlink(link.path))
        #expect(try String(contentsOf: tmp.file("dotfiles/settings.json"), encoding: .utf8) == p.newText)
    }

    @Test func restoreWritesTheBackupBytes() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try Fixture.writeUserSettings(tmp)
        let original = try Data(contentsOf: url)
        let desktop = ClaudeSettingsInstaller.testDesktop(tmp)
        let backup = try #require(try ClaudeSettingsInstaller.apply(try plan(url, desktop: desktop), to: url))
        let updated = try ClaudeSettingsFile.load(url)

        let p = try ClaudeSettingsInstaller.plan(updated, action: .restore(backup), desktop: desktop, now: InstallerPlanTests.now)
        #expect(p.changes)
        #expect(p.newText == String(decoding: original, as: UTF8.self))
        #expect(p.summary == ["還原備份 \(backup.lastPathComponent)"])
        #expect(p.backupName == backup.lastPathComponent + "-2")
        #expect(p.diff.filter { $0.kind == .added && $0.text.contains("status-writer.js") }.count == 10)
        #expect(!p.diff.contains { $0.text.contains("bin/hook-tap") || $0.text.contains("osascript") })
        #expect(p.removedEvents == [] && p.addedEvents == [])

        let second = try #require(try ClaudeSettingsInstaller.apply(p, to: url))
        #expect(try Data(contentsOf: url) == original)
        #expect(try Data(contentsOf: second) == Data(updated.serializedText.utf8))
        #expect(ClaudeSettingsInstaller.backups(of: url).map(\.url.lastPathComponent) == [second.lastPathComponent, backup.lastPathComponent])
        // Restoring the same bytes again is a no-op.
        let again = try ClaudeSettingsInstaller.plan(try ClaudeSettingsFile.load(url), action: .restore(backup), desktop: desktop, now: InstallerPlanTests.now)
        #expect(!again.changes)
        #expect(again.summary == ["目前的設定與備份相同，不需要還原"])
    }

    @Test func restoreReportsOtherKeysAndEventChanges() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try tmp.write("settings.json", "{\n  \"model\": \"opus\",\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n")
        let old = try tmp.write("settings.json.codd-bak-20261001-080000", "{\n  \"model\": \"sonnet\",\n  \"hooks\": {\n    \"PreCompact\": []\n  }\n}\n")
        let p = try ClaudeSettingsInstaller.plan(try ClaudeSettingsFile.load(url), action: .restore(old),
                                                 desktop: DesktopStatusLine(dataRoot: "/r"), now: InstallerPlanTests.now)
        #expect(p.summary == ["還原備份 settings.json.codd-bak-20261001-080000", "hooks 與 statusLine 以外也會還原：model"])
        #expect(p.removedEvents == ["Stop"])
        #expect(p.addedEvents == ["PreCompact"])
        #expect(!p.diff.contains { $0.text.contains("model") })
        let invalid = try tmp.write("settings.json.codd-bak-20261001-090000", "{ not json")
        #expect(throws: ClaudeSettingsError.invalidJSON(line: 1, column: 3)) {
            try ClaudeSettingsInstaller.plan(try ClaudeSettingsFile.load(url), action: .restore(invalid),
                                             desktop: DesktopStatusLine(dataRoot: "/r"), now: InstallerPlanTests.now)
        }
        #expect(throws: ClaudeSettingsError.self) {
            try ClaudeSettingsInstaller.plan(try ClaudeSettingsFile.load(url), action: .restore(tmp.file("missing")),
                                             desktop: DesktopStatusLine(dataRoot: "/r"), now: InstallerPlanTests.now)
        }
    }

    /// M3 review (security-data-2): the restore preview folded the user's hook-tap handlers it
    /// deletes into `…（保留既有 n 組 hook）` and the dialog said foreign hooks were kept.
    @Test func restoreShowsTheForeignHandlersItRemoves() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let stop = #"{"hooks": [{"type": "command", "command": "hook-tap stop"}]}"#
        let stop2 = #"{"hooks": [{"type": "command", "command": "hook-tap stop-2"}]}"#
        let permission = #"{"hooks": [{"type": "command", "command": "hook-tap permission", "timeout": 600}]}"#
        let current = "{\"hooks\": {\"Stop\": [\(stop), \(stop2)], \"PermissionRequest\": [\(permission)]}, \"model\": \"opus\", \"env\": {\"A\": \"1\"}}"
        let url = try tmp.write("settings.json", current)
        let backup = try tmp.write("settings.json.codd-bak-20261012-091500", "{\"hooks\": {\"Stop\": [\(stop)]}, \"model\": \"sonnet\", \"env\": {\"A\": \"1\"}}")
        let p = try ClaudeSettingsInstaller.plan(try ClaudeSettingsFile.load(url), action: .restore(backup),
                                                 desktop: DesktopStatusLine(dataRoot: "/r"), now: InstallerPlanTests.now)
        #expect(p.changes)
        #expect(p.foreignChanges == [ForeignHookChange(name: "hook-tap", code: "hook-tap", removed: 2)])
        #expect(p.summary.contains("會移除 hook-tap 的 2 個 hook（備份裡沒有）"))
        #expect(p.summary.contains("hooks 與 statusLine 以外也會還原：model"), "env is the same: not named")
        // The deleted handlers are removed lines; the one kept on both sides stays elided.
        let removed = p.diff.filter { $0.kind == .removed }.map(\.text)
        #expect(removed.contains { $0.contains("hook-tap stop-2") })
        #expect(removed.contains { $0.contains("hook-tap permission") })
        #expect(!p.diff.contains { $0.kind != .elided && $0.text.contains("\"hook-tap stop\"") })
        #expect(p.diff.allSatisfy { $0.kind != .elided || !$0.text.contains("保留既有 2") }, "no 'kept' line for what goes")
        #expect(p.removedLines >= 2)
        // The other actions keep foreign handlers: nothing listed.
        let update = try plan(url)
        #expect(update.foreignChanges.isEmpty)
    }

    /// A tool known only by its program is named once in the summary; `osascript` keeps both names.
    @Test func restoreNamesEachForeignToolOnce() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let tap = #"{"hooks": [{"type": "command", "command": "~/.hook-tap/bin/hook-tap Stop"}]}"#
        let beep = #"{"hooks": [{"type": "command", "command": "osascript -e 'beep'"}]}"#
        let url = try tmp.write("settings.json", "{\"hooks\": {\"Stop\": [\(beep)]}}")
        let backup = try tmp.write("settings.json.codd-bak-20261012-091500", "{\"hooks\": {\"Stop\": [\(tap)]}}")
        let p = try ClaudeSettingsInstaller.plan(try ClaudeSettingsFile.load(url), action: .restore(backup),
                                                 desktop: DesktopStatusLine(dataRoot: "/r"), now: InstallerPlanTests.now)
        #expect(p.summary.contains("會移除 通知 的 1 個 hook（osascript，備份裡沒有）"))
        #expect(p.summary.contains("會加回 hook-tap 的 1 個 hook"))
    }

    @Test func backupsAreListedNewestFirst() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try tmp.write("settings.json", "{}\n")
        try tmp.write("settings.json.codd-bak-20261003-183020", "aaa")
        try tmp.write("settings.json.codd-bak-20261012-091503", "bbbb")
        try tmp.write("settings.json.codd-bak-20260921-140812", "c")
        try tmp.write("settings.json.codd-bak-20261012-091503-2", "dd")
        let odd = try tmp.write("settings.json.codd-bak-hand-made", "e")
        try tmp.write("other.json.codd-bak-20261012-091503", "ignored")
        let badSuffix = try tmp.write("settings.json.codd-bak-20261013-000000-x", "bad suffix")
        try FileManager.default.createDirectory(at: tmp.file("settings.json.codd-bak-20261020-000000"), withIntermediateDirectories: true)
        // Names without a valid stamp sort by their mtime.
        var times = [timespec(tv_sec: 1_600_000_000, tv_nsec: 0), timespec(tv_sec: 1_600_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, odd.path, &times, 0) == 0)
        times = [timespec(tv_sec: 1_500_000_000, tv_nsec: 0), timespec(tv_sec: 1_500_000_000, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, badSuffix.path, &times, 0) == 0)

        let list = ClaudeSettingsInstaller.backups(of: url)
        #expect(list.map(\.url.lastPathComponent) == [
            "settings.json.codd-bak-20261012-091503-2",
            "settings.json.codd-bak-20261012-091503",
            "settings.json.codd-bak-20261003-183020",
            "settings.json.codd-bak-20260921-140812",
            "settings.json.codd-bak-hand-made",
            "settings.json.codd-bak-20261013-000000-x",
        ])
        #expect(list.first?.size == 2)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(list[1].date == calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 15, second: 3)))
        #expect(list[4].date == Date(timeIntervalSince1970: 1_600_000_000))
        #expect(ClaudeSettingsInstaller.backups(of: tmp.file("nowhere/settings.json")).isEmpty)
    }

    @Test func backupNameParsing() {
        let parsed = BackupName.parse("settings.json.codd-bak-20261017-104210-3", fileName: "settings.json")
        #expect(parsed?.stamp == "20261017-104210")
        #expect(parsed?.index == 3)
        #expect(parsed?.date == InstallerPlanTests.now)
        #expect(BackupName.parse("settings.json.codd-bak-20261017-104210", fileName: "settings.json")?.index == 1)
        #expect(BackupName.parse("settings.json.codd-bak-20261017-104210-1", fileName: "settings.json") == nil)
        #expect(BackupName.parse("settings.json.codd-bak-2026101-1042100", fileName: "settings.json") == nil)
        #expect(BackupName.stamp(InstallerPlanTests.now) == InstallerPlanTests.stamp)
    }
}
