import Darwin
import Foundation
import Testing
@testable import CoddClaudeSettings

/// Shared helpers for the `~/.claude.json` registration tests (temp files only).
enum MCPTest {
    static let url = ClaudeJSONFixture.ourURL
    static let token = ClaudeJSONFixture.token
    static let stamp = InstallerPlanTests.stamp

    static func installer(_ file: URL, index: URL? = nil, lockWait: Duration = .seconds(3)) -> ClaudeUserConfigMCPInstaller {
        ClaudeUserConfigMCPInstaller(file: file, backupsIndex: index, clock: { InstallerPlanTests.now }, lockWait: lockWait)
    }

    static let register = ClaudeUserConfigMCPAction.register(name: "codd", url: url, token: token)
    static let remove = ClaudeUserConfigMCPAction.remove(name: "codd")

    @discardableResult
    static func write(_ tmp: TempDir, _ name: String, _ data: Data, mode: mode_t = 0o600) throws -> URL {
        let url = tmp.file(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        chmod(url.path, mode)
        return url
    }

    /// `.claude.json` in `tmp`.
    @discardableResult
    static func write(_ tmp: TempDir, _ data: Data, mode: mode_t = 0o600) throws -> URL {
        try write(tmp, ".claude.json", data, mode: mode)
    }

    @discardableResult
    static func write(_ tmp: TempDir, _ name: String, text: String, mode: mode_t = 0o600) throws -> URL {
        try write(tmp, name, Data(text.utf8), mode: mode)
    }

    @discardableResult
    static func write(_ tmp: TempDir, text: String, mode: mode_t = 0o600) throws -> URL {
        try write(tmp, ".claude.json", Data(text.utf8), mode: mode)
    }

    /// Replaces the first occurrence of `old` with `new` in the file, as another writer would.
    static func edit(_ url: URL, _ old: String, _ new: String) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let range = try #require(text.range(of: old))
        try Data(text.replacingCharacters(in: range, with: new).utf8).write(to: url)
    }

    static func backups(_ tmp: TempDir) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []).filter { $0.contains(".codd-bak-") }.sorted()
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Every diff line that shows a token shows it masked, and nothing secret leaks.
    static func expectMasked(_ plan: ClaudeUserConfigMCPPlan, tokens: [String] = [token, ClaudeJSONFixture.oldToken]) {
        for line in plan.diff {
            for secret in tokens + [ClaudeJSONFixture.stdioSecret, ClaudeJSONFixture.httpSecret, "pencil-like", "stitch-like",
                                    "projects", "numStartups", "oauthAccount", "專案"] {
                #expect(!line.text.contains(secret), "diff line leaks \(secret): \(line.text)")
            }
        }
    }

    /// Numbered diff lines are the real lines of the files (masked values aside).
    static func expectNumbers(_ plan: ClaudeUserConfigMCPPlan, old: String, new: String) {
        let oldLines = old.components(separatedBy: "\n"), newLines = new.components(separatedBy: "\n")
        /// Equal, or equal around the one masked value (which must hide a real, different value).
        func same(_ shown: String, _ real: String) -> Bool {
            let parts = shown.components(separatedBy: "\"••••\"")
            guard parts.count == 2 else { return shown == real }
            return real.hasPrefix(parts[0] + "\"") && real.hasSuffix("\"" + parts[1]) && real != shown
        }
        for line in plan.diff {
            switch line.kind {
            case .context:
                #expect(same(line.text, oldLines[line.oldNumber! - 1]), "\(line.text) vs \(oldLines[line.oldNumber! - 1])")
                #expect(same(line.text, newLines[line.newNumber! - 1]))
            case .removed:
                #expect(same(line.text, oldLines[line.oldNumber! - 1]), "\(line.text) vs \(oldLines[line.oldNumber! - 1])")
            case .added:
                #expect(same(line.text, newLines[line.newNumber! - 1]), "\(line.text) vs \(newLines[line.newNumber! - 1])")
            case .hunk:
                #expect(line.text.wholeMatch(of: /@@ -\d+,\d+ \+\d+,\d+ @@  "mcpServers"/) != nil, "\(line.text)")
            case .elided:
                #expect(line.text.wholeMatch(of: /…（保留既有 \d+ 個 MCP server）/) != nil, "\(line.text)")
            }
        }
        #expect(plan.addedLines == plan.diff.filter { $0.kind == .added }.count)
        #expect(plan.removedLines == plan.diff.filter { $0.kind == .removed }.count)
    }
}

@Suite("~/.claude.json inspection")
struct UserConfigInspectionTests {
    @Test func absentFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let found = try MCPTest.installer(tmp.file(".claude.json")).inspect(ourURL: MCPTest.url, token: MCPTest.token)
        #expect(found == ClaudeUserConfigMCPInspection(fileExists: false, parsable: false))
    }

    @Test func serversWithoutCODD() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let found = try MCPTest.installer(file).inspect(ourURL: MCPTest.url, token: MCPTest.token)
        #expect(found.fileExists && found.parsable)
        #expect(found.serverNames == ["pencil-like", "stitch-like"])
        #expect(found.codd == nil)
        let fingerprint = try #require(found.fingerprint)
        #expect(fingerprint.sha256 == ClaudeUserConfigMCPInstaller.sha256Hex(try Data(contentsOf: file)))
        #expect(fingerprint.size == Int64(try Data(contentsOf: file).count))
    }

    @Test func noMCPServersMember() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: nil))
        let found = try MCPTest.installer(file).inspect(ourURL: MCPTest.url, token: nil)
        #expect(found.parsable && found.serverNames.isEmpty && found.codd == nil)
    }

    @Test func oursWithMatchingOldAndNoToken() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: ClaudeJSONFixture.defaultServers
            + [("codd", ClaudeJSONFixture.ours())]))
        let installer = MCPTest.installer(file)
        let matching = try installer.inspect(ourURL: MCPTest.url, token: MCPTest.token)
        #expect(matching.serverNames == ["pencil-like", "stitch-like", "codd"])
        #expect(matching.codd == ClaudeUserConfigMCPEntry(name: "codd", url: MCPTest.url, hasHeaders: true, tokenMatches: true))
        let rotated = try installer.inspect(ourURL: MCPTest.url, token: ClaudeJSONFixture.oldToken)
        #expect(rotated.codd?.tokenMatches == false)
        let unknown = try installer.inspect(ourURL: MCPTest.url, token: nil)
        #expect(unknown.codd?.tokenMatches == nil)
        // Another port: still the entry named codd, pointing elsewhere.
        let moved = try installer.inspect(ourURL: "http://127.0.0.1:50000/mcp", token: MCPTest.token)
        #expect(moved.codd == ClaudeUserConfigMCPEntry(name: "codd", url: MCPTest.url, hasHeaders: true, tokenMatches: true))
    }

    @Test func foreignCODDAndOursUnderAnotherName() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let foreign = ClaudeJSONFixture.obj([("type", .string("stdio")), ("command", .string("codd-other"))])
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: [("codd", foreign)]))
        let found = try MCPTest.installer(file).inspect(ourURL: MCPTest.url, token: MCPTest.token)
        #expect(found.codd == ClaudeUserConfigMCPEntry(name: "codd", url: nil, hasHeaders: false, tokenMatches: false))

        let both = try MCPTest.write(tmp, "both.json", Data(ClaudeJSONFixture.text(servers: [
            ("codd", foreign), ("codd-desktop", ClaudeJSONFixture.ours(token: ClaudeJSONFixture.oldToken)),
        ]).utf8))
        let ours = try MCPTest.installer(both).inspect(ourURL: MCPTest.url, token: MCPTest.token)
        #expect(ours.codd == ClaudeUserConfigMCPEntry(name: "codd-desktop", url: MCPTest.url, hasHeaders: true, tokenMatches: false))
    }

    @Test func headerNameIsCaseInsensitive() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let entry = ClaudeJSONFixture.obj([("type", .string("http")), ("url", .string(MCPTest.url)),
                                           ("headers", ClaudeJSONFixture.obj([("x-codd-token", .string(MCPTest.token))]))])
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: [("codd", entry)]))
        #expect(try MCPTest.installer(file).inspect(ourURL: MCPTest.url, token: MCPTest.token).codd?.tokenMatches == true)
    }

    @Test func invalidAndNonObjectFiles() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let invalid = try MCPTest.write(tmp, text: "{\n  \"a\": 1,\n}")
        let found = try MCPTest.installer(invalid).inspect(ourURL: MCPTest.url, token: nil)
        #expect(found.fileExists && !found.parsable && found.fingerprint != nil)
        let array = try MCPTest.write(tmp, "array.json", Data("[1, 2]".utf8))
        #expect(throws: ClaudeUserConfigMCPError.notAnObject) { try MCPTest.installer(array).inspect(ourURL: MCPTest.url, token: nil) }
        let odd = try MCPTest.write(tmp, "odd.json", Data("{\"mcpServers\": [1]}".utf8))
        let shape = try MCPTest.installer(odd).inspect(ourURL: MCPTest.url, token: nil)
        #expect(shape.parsable && shape.serverNames.isEmpty && shape.codd == nil)
    }
}

@Suite("~/.claude.json registration plans")
struct UserConfigPlanTests {
    @Test func registerOnTheLargeFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, ClaudeJSONFixture.large)
        let plan = try MCPTest.installer(file).plan(MCPTest.register)
        #expect(!plan.upToDate)
        #expect(plan.summary == "只會在 mcpServers 加入 codd，其他設定不變")
        #expect(plan.backupName == ".claude.json.codd-bak-\(MCPTest.stamp)")
        #expect(plan.fingerprint?.sha256 == ClaudeUserConfigMCPInstaller.sha256Hex(ClaudeJSONFixture.large))
        #expect(plan.baseMemberDigest != nil)
        let added = plan.diff.filter { $0.kind == .added }.map { $0.text.trimmingCharacters(in: .whitespaces) }
        #expect(added == ["\"codd\": {", "\"type\": \"http\",", "\"url\": \"\(MCPTest.url)\",", "\"headers\": {",
                          "\"X-CODD-Token\": \"••••\"", "}", "}"])
        #expect(plan.removedLines == 0)
        #expect(plan.diff.contains { $0.kind == .elided && $0.text == "…（保留既有 1 個 MCP server）" })
        MCPTest.expectMasked(plan)
        // The numbers are the real file lines, before and after.
        let old = String(decoding: ClaudeJSONFixture.large, as: UTF8.self)
        _ = try MCPTest.installer(file).apply(plan)
        MCPTest.expectNumbers(plan, old: old, new: try String(contentsOf: file, encoding: .utf8))
    }

    @Test func smallDiffLineByLine() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let text = "{\n  \"numStartups\": 3,\n  \"mcpServers\": {\n    \"pencil-like\": {\n      \"type\": \"stdio\",\n"
            + "      \"command\": \"x\"\n    }\n  },\n  \"userID\": \"u\"\n}"
        let file = try MCPTest.write(tmp, text: text)
        let plan = try MCPTest.installer(file).plan(MCPTest.register)
        // pencil-like's lines (and its `}` becoming `},`) are elided; codd's are new lines 8–14.
        #expect(plan.diff == [
            DiffLine(kind: .hunk, text: "@@ -5,4 +5,11 @@  \"mcpServers\""),
            DiffLine(kind: .elided, text: "…（保留既有 1 個 MCP server）"),
            DiffLine(kind: .added, newNumber: 8, text: "    \"codd\": {"),
            DiffLine(kind: .added, newNumber: 9, text: "      \"type\": \"http\","),
            DiffLine(kind: .added, newNumber: 10, text: "      \"url\": \"\(MCPTest.url)\","),
            DiffLine(kind: .added, newNumber: 11, text: "      \"headers\": {"),
            DiffLine(kind: .added, newNumber: 12, text: "        \"X-CODD-Token\": \"••••\""),
            DiffLine(kind: .added, newNumber: 13, text: "      }"),
            DiffLine(kind: .added, newNumber: 14, text: "    }"),
            DiffLine(kind: .context, oldNumber: 8, newNumber: 15, text: "  },"),
        ])
        #expect(plan.addedLines == 7 && plan.removedLines == 0)
        _ = try MCPTest.installer(file).apply(plan)
        let expected = "{\n  \"numStartups\": 3,\n  \"mcpServers\": {\n    \"pencil-like\": {\n      \"type\": \"stdio\",\n"
            + "      \"command\": \"x\"\n    },\n    \"codd\": {\n      \"type\": \"http\",\n      \"url\": \"\(MCPTest.url)\",\n"
            + "      \"headers\": {\n        \"X-CODD-Token\": \"\(MCPTest.token)\"\n      }\n    }\n  },\n  \"userID\": \"u\"\n}"
        #expect(try String(contentsOf: file, encoding: .utf8) == expected)
        MCPTest.expectNumbers(plan, old: text, new: expected)
    }

    @Test func tokenRotationShowsAChangedMaskedLine() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: ClaudeJSONFixture.defaultServers
            + [("codd", ClaudeJSONFixture.ours(token: ClaudeJSONFixture.oldToken))]))
        let old = try String(contentsOf: file, encoding: .utf8)
        let plan = try MCPTest.installer(file).plan(MCPTest.register)
        #expect(plan.summary == "只會更新 mcpServers 裡 codd 的 token，其他設定不變")
        #expect(plan.diff.filter { $0.kind == .removed }.map(\.text) == ["        \"X-CODD-Token\": \"••••\""])
        #expect(plan.diff.filter { $0.kind == .added }.map(\.text) == ["        \"X-CODD-Token\": \"••••\""])
        MCPTest.expectMasked(plan)
        _ = try MCPTest.installer(file).apply(plan)
        let new = try String(contentsOf: file, encoding: .utf8)
        #expect(new == old.replacingOccurrences(of: ClaudeJSONFixture.oldToken, with: MCPTest.token))
        MCPTest.expectNumbers(plan, old: old, new: new)
    }

    @Test func replacingAForeignCODDMasksItsSecrets() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let foreign = ClaudeJSONFixture.obj([("type", .string("stdio")), ("command", .string("codd-other")),
                                             ("env", ClaudeJSONFixture.obj([("CODD_OTHER_TOKEN", .string(ClaudeJSONFixture.stdioSecret))]))])
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: [("codd", foreign)]))
        let plan = try MCPTest.installer(file).plan(MCPTest.register)
        #expect(plan.summary == "會取代 mcpServers 裡現有的 codd（原本指向其他伺服器），其他設定不變")
        #expect(plan.diff.contains { $0.kind == .removed && $0.text == "        \"CODD_OTHER_TOKEN\": \"••••\"" })
        MCPTest.expectMasked(plan)
        // Same URL and token, other fields: an update.
        let partial = ClaudeJSONFixture.obj([("url", .string(MCPTest.url)),
                                             ("headers", ClaudeJSONFixture.obj([("X-CODD-Token", .string(MCPTest.token))]))])
        let other = try MCPTest.write(tmp, "other.json", Data(ClaudeJSONFixture.text(servers: [("codd", partial)]).utf8))
        #expect(try MCPTest.installer(other).plan(MCPTest.register).summary == "只會更新 mcpServers 裡的 codd，其他設定不變")
    }

    @Test func upToDatePlans() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: ClaudeJSONFixture.defaultServers
            + [("codd", ClaudeJSONFixture.ours())]))
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        #expect(plan.upToDate && plan.diff.isEmpty && plan.addedLines == 0)
        #expect(plan.summary == "codd 已經註冊在 mcpServers，不需要變更")
        let before = try Data(contentsOf: file)
        #expect(try installer.apply(plan) == ClaudeUserConfigMCPResult(backup: nil, wrote: false))
        #expect(try Data(contentsOf: file) == before)
        // Key order inside the entry does not matter.
        let reordered = ClaudeJSONFixture.obj([("url", .string(MCPTest.url)),
                                               ("headers", ClaudeJSONFixture.obj([("X-CODD-Token", .string(MCPTest.token))])),
                                               ("type", .string("http"))])
        let other = try MCPTest.write(tmp, "reordered.json", Data(ClaudeJSONFixture.text(servers: [("codd", reordered)]).utf8))
        #expect(try MCPTest.installer(other).plan(MCPTest.register).upToDate)
        // Nothing to remove.
        let none = try MCPTest.write(tmp, "none.json", Data(ClaudeJSONFixture.text().utf8))
        let removal = try MCPTest.installer(none).plan(MCPTest.remove)
        #expect(removal.upToDate && removal.summary == "mcpServers 裡沒有 codd，不需要變更")
        let noMember = try MCPTest.write(tmp, "nomember.json", Data(ClaudeJSONFixture.text(servers: nil).utf8))
        #expect(try MCPTest.installer(noMember).plan(MCPTest.remove).upToDate)
        #expect(MCPTest.backups(tmp).isEmpty)
    }

    @Test func refusals() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        #expect(throws: ClaudeUserConfigMCPError.missingFile) { try MCPTest.installer(tmp.file(".claude.json")).plan(MCPTest.register) }
        let invalid = try MCPTest.write(tmp, text: "{\n  \"a\": 1,\n  \"b\": tru\n}")
        let before = try Data(contentsOf: invalid)
        // Where the literal stops matching (no content in the error).
        #expect(throws: ClaudeUserConfigMCPError.invalidJSON("line 3, column 11")) { try MCPTest.installer(invalid).plan(MCPTest.register) }
        #expect(try Data(contentsOf: invalid) == before)
        let bom = try MCPTest.write(tmp, "bom.json", Data([0xEF, 0xBB, 0xBF]) + Data("{}".utf8))
        #expect(throws: ClaudeUserConfigMCPError.invalidJSON("line 1, column 1")) { try MCPTest.installer(bom).plan(MCPTest.register) }
        let array = try MCPTest.write(tmp, "array.json", Data("[]".utf8))
        #expect(throws: ClaudeUserConfigMCPError.notAnObject) { try MCPTest.installer(array).plan(MCPTest.register) }
        let shape = try MCPTest.write(tmp, "shape.json", Data("{\"mcpServers\": \"x\"}".utf8))
        #expect(throws: ClaudeUserConfigMCPError.notAnObject) { try MCPTest.installer(shape).plan(MCPTest.register) }
        #expect(try MCPTest.installer(shape).plan(MCPTest.remove).upToDate)
        #expect(MCPTest.backups(tmp).isEmpty)
    }

    @Test func actionDescriptionsHideTheToken() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let plan = try MCPTest.installer(file).plan(MCPTest.register)
        #expect("\(MCPTest.register)" == "register(name: codd, url: \(MCPTest.url), token: ••••)")
        var dumped = ""
        dump(plan, to: &dumped)
        for text in [String(describing: plan), String(reflecting: plan), dumped, "\(MCPTest.remove)"] {
            #expect(!text.contains(MCPTest.token), "\(text)")
        }
        #expect(MCPTest.register.backupReason == "mcp-register" && MCPTest.remove.backupReason == "mcp-remove")
    }
}

@Suite("~/.claude.json registration writes")
struct UserConfigApplyTests {
    @Test func registerAndRemoveRoundTripOnTheLargeFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let original = ClaudeJSONFixture.large
        let file = try MCPTest.write(tmp, original)
        let installer = MCPTest.installer(file)
        let result = try installer.apply(try installer.plan(MCPTest.register))
        #expect(result.wrote)
        let backup = try #require(result.backup)
        #expect(backup.lastPathComponent == ".claude.json.codd-bak-\(MCPTest.stamp)")
        #expect(try Data(contentsOf: backup) == original)
        let registered = try Data(contentsOf: file)
        #expect(ClaudeJSONFixture.outsideMember(registered) == ClaudeJSONFixture.outsideMember(original))
        let servers = try #require(try ClaudeJSONFixture.servers(registered))
        #expect(servers.objectMembers?.map(\.key) == ["pencil-like", "stitch-like", "codd"])
        #expect(servers["codd"] == ClaudeJSONFixture.ours())
        #expect(servers["pencil-like"] == ClaudeJSONFixture.stdioServer && servers["stitch-like"] == ClaudeJSONFixture.httpServer)
        // Still exactly what JSON.stringify(x, null, 2) writes for the new value.
        #expect(String(decoding: registered, as: UTF8.self) == (try OrderedJSON.parse(registered)).serialized(indent: "  "))
        #expect(!MCPTest.exists(installer.lockPath))

        let removed = try installer.apply(try installer.plan(MCPTest.remove))
        #expect(removed.wrote && removed.backup?.lastPathComponent == ".claude.json.codd-bak-\(MCPTest.stamp)-2")
        #expect(try Data(contentsOf: removed.backup!) == registered)
        #expect(try Data(contentsOf: file) == original)
        #expect(!MCPTest.exists(installer.lockPath))
    }

    @Test func createsMCPServersAtTheEnd() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let original = Data(ClaudeJSONFixture.text(servers: nil).utf8)
        let file = try MCPTest.write(tmp, original)
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        #expect(plan.summary == "會新增 mcpServers 並加入 codd，其他設定不變")
        #expect(plan.baseMemberDigest == nil)
        #expect(plan.diff.filter { $0.kind != .added && $0.kind != .hunk }.isEmpty)
        #expect(plan.diff.first?.kind == .hunk)
        _ = try installer.apply(plan)
        let registered = try Data(contentsOf: file)
        let text = String(decoding: registered, as: UTF8.self)
        #expect(ClaudeJSONFixture.outsideMember(registered) == original)
        #expect(try OrderedJSON.parse(registered).objectMembers?.last?.key == "mcpServers")
        #expect(text == (try OrderedJSON.parse(registered)).serialized(indent: "  "))
        MCPTest.expectNumbers(plan, old: String(decoding: original, as: UTF8.self), new: text)
        // Removing leaves the (now empty) member, as Claude's own removal would.
        _ = try installer.apply(try installer.plan(MCPTest.remove))
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("\"lastReleaseNotesSeen\": \"2.1.302\",\n  \"mcpServers\": {}\n}"))
    }

    @Test func emptyAndOnlyMembers() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let text = "{\n  \"a\": 1,\n  \"mcpServers\": {}\n}\n"
        let file = try MCPTest.write(tmp, text: text)
        let installer = MCPTest.installer(file)
        _ = try installer.apply(try installer.plan(MCPTest.register))
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\n  \"a\": 1,\n  \"mcpServers\": {\n    \"codd\": {\n"
            + "      \"type\": \"http\",\n      \"url\": \"\(MCPTest.url)\",\n      \"headers\": {\n"
            + "        \"X-CODD-Token\": \"\(MCPTest.token)\"\n      }\n    }\n  }\n}\n")
        _ = try installer.apply(try installer.plan(MCPTest.remove))
        #expect(try String(contentsOf: file, encoding: .utf8) == text)
        // An empty root.
        let empty = try MCPTest.write(tmp, "empty.json", Data("{}".utf8))
        let other = MCPTest.installer(empty)
        _ = try other.apply(try other.plan(MCPTest.register))
        let created = try String(contentsOf: empty, encoding: .utf8)
        #expect(created == OrderedJSON.object([(key: "mcpServers", value: .object([(key: "codd", value: ClaudeJSONFixture.ours())]))])
            .serialized(indent: "  "))
    }

    @Test func compactAndCRLFLayoutsAreFollowed() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let compact = try MCPTest.write(tmp, text: "{\"a\":1,\"mcpServers\":{\"x\":{\"type\":\"stdio\"}},\"z\":[1e21,-0]}")
        _ = try MCPTest.installer(compact).apply(try MCPTest.installer(compact).plan(MCPTest.register))
        #expect(try String(contentsOf: compact, encoding: .utf8) == "{\"a\":1,\"mcpServers\":{\"x\":{\"type\":\"stdio\"},"
            + "\"codd\":{\"type\":\"http\",\"url\":\"\(MCPTest.url)\",\"headers\":{\"X-CODD-Token\":\"\(MCPTest.token)\"}}},\"z\":[1e21,-0]}")

        let crlfText = "{\r\n  \"a\": 1,\r\n  \"mcpServers\": {\r\n    \"x\": {\r\n      \"type\": \"stdio\"\r\n    }\r\n  }\r\n}\r\n"
        let crlf = try MCPTest.write(tmp, "crlf.json", Data(crlfText.utf8))
        let installer = MCPTest.installer(crlf)
        _ = try installer.apply(try installer.plan(MCPTest.register))
        let written = try String(contentsOf: crlf, encoding: .utf8)
        #expect(!written.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        #expect(written.contains("    },\r\n    \"codd\": {\r\n      \"type\": \"http\",\r\n"))
        _ = try installer.apply(try installer.plan(MCPTest.remove))
        #expect(try String(contentsOf: crlf, encoding: .utf8) == crlfText)

        let fourSpaces = "{\n    \"a\": 1,\n    \"mcpServers\": {\n        \"x\": {}\n    }\n}"
        let four = try MCPTest.write(tmp, "four.json", Data(fourSpaces.utf8))
        _ = try MCPTest.installer(four).apply(try MCPTest.installer(four).plan(MCPTest.register))
        let written4 = try Data(contentsOf: four)
        #expect(String(decoding: written4, as: UTF8.self) == (try OrderedJSON.parse(written4)).serialized(indent: "    "))
    }

    @Test func middleMemberRemovalKeepsNeighbours() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let servers = [("pencil-like", ClaudeJSONFixture.stdioServer), ("codd", ClaudeJSONFixture.ours()),
                       ("stitch-like", ClaudeJSONFixture.httpServer)]
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(servers: servers))
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.remove)
        #expect(plan.summary == "只會從 mcpServers 移除 codd，其他設定不變")
        #expect(plan.diff.filter { $0.kind == .removed }.count == 7)
        MCPTest.expectMasked(plan)
        _ = try installer.apply(plan)
        #expect(try String(contentsOf: file, encoding: .utf8) == ClaudeJSONFixture.text())
    }

    @Test func aChangeOutsideMCPServersIsRebased() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, ClaudeJSONFixture.large)
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        // Claude rewrites other members meanwhile (same layout, new values, a new project).
        try MCPTest.edit(file, "\"numStartups\": 412", "\"numStartups\": 413")
        try MCPTest.edit(file, "\"lastReleaseNotesSeen\": \"2.1.302\"", "\"lastReleaseNotesSeen\": \"2.1.303\"")
        try MCPTest.edit(file, "\"projects\": {\n", "\"projects\": {\n    \"/Users/fixture/新的\": {\n      \"lastCost\": 0\n    },\n")
        let fresh = try Data(contentsOf: file)
        let result = try installer.apply(plan)
        #expect(result.wrote)
        #expect(try Data(contentsOf: result.backup!) == fresh)
        let written = try Data(contentsOf: file)
        // The other change survives byte for byte; only the member edit was added.
        #expect(ClaudeJSONFixture.outsideMember(written) == ClaudeJSONFixture.outsideMember(fresh))
        #expect(try ClaudeJSONFixture.servers(written)?["codd"] == ClaudeJSONFixture.ours())
        #expect(!MCPTest.exists(installer.lockPath))
    }

    @Test func aTouchedButIdenticalFileIsRebased() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        var times = [timeval(tv_sec: 1_800_000_000, tv_usec: 0), timeval(tv_sec: 1_800_000_000, tv_usec: 0)]
        utimes(file.path, &times)
        #expect(try installer.apply(plan).wrote)
        #expect(try ClaudeJSONFixture.servers(try Data(contentsOf: file))?["codd"] == ClaudeJSONFixture.ours())
    }

    @Test func aChangeInsideMCPServersIsRefused() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, ClaudeJSONFixture.large)
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        try MCPTest.edit(file, "\"--app\"", "\"--application\"")
        let changed = try Data(contentsOf: file)
        #expect(throws: ClaudeUserConfigMCPError.changedSinceRead) { try installer.apply(plan) }
        #expect(try Data(contentsOf: file) == changed)
        #expect(MCPTest.backups(tmp).isEmpty)
        #expect(!MCPTest.exists(installer.lockPath))

        // A file that stopped parsing, or lost its member, is refused too.
        let second = try MCPTest.write(tmp, "second.json", Data(ClaudeJSONFixture.text().utf8))
        let other = MCPTest.installer(second)
        let plan2 = try other.plan(MCPTest.register)
        try MCPTest.edit(second, "\"numStartups\": 412", "\"numStartups\": 412,")
        let broken = try Data(contentsOf: second)
        #expect(throws: ClaudeUserConfigMCPError.changedSinceRead) { try other.apply(plan2) }
        #expect(try Data(contentsOf: second) == broken)
        try Data(ClaudeJSONFixture.text(servers: nil).utf8).write(to: second)
        #expect(throws: ClaudeUserConfigMCPError.changedSinceRead) { try other.apply(plan2) }
        // Gone entirely.
        try FileManager.default.removeItem(at: second)
        #expect(throws: ClaudeUserConfigMCPError.missingFile) { try other.apply(plan2) }
        #expect(MCPTest.backups(tmp).isEmpty)
    }

    @Test func backupNamesAvoidCollisions() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text())
        let base = ".claude.json.codd-bak-\(MCPTest.stamp)"
        try MCPTest.write(tmp, base, text: "older")
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        #expect(plan.backupName == base + "-2")
        // Another backup takes the planned name before the write: the next one is used.
        try MCPTest.write(tmp, base + "-2", text: "racing")
        let result = try installer.apply(plan)
        #expect(result.backup?.lastPathComponent == base + "-3")
        #expect(try String(contentsOf: tmp.file(base), encoding: .utf8) == "older")
        #expect(try String(contentsOf: tmp.file(base + "-2"), encoding: .utf8) == "racing")
        #expect(try String(contentsOf: result.backup!, encoding: .utf8) == ClaudeJSONFixture.text())
        // Listed with the settings.json backups' parser.
        #expect(ClaudeSettingsInstaller.backups(of: file).map { $0.url.lastPathComponent } == [base + "-3", base + "-2", base])
    }

    /// CODE-3: a private mode is kept; a group- or world-readable one is kept only while the bytes
    /// hold no token.
    @Test func modesAreKeptUnlessATokenWouldBeReadableByOthers() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        for mode: mode_t in [0o600, 0o400] {
            let file = try MCPTest.write(tmp, ".claude-\(mode).json", Data(ClaudeJSONFixture.text().utf8), mode: mode)
            let installer = MCPTest.installer(file)
            let plan = try installer.plan(MCPTest.register)
            #expect(plan.modeNote == nil)
            let result = try installer.apply(plan)
            #expect(fileMode(file.path) == mode && fileMode(result.backup!.path) == mode)
        }
        // Bytes without a token keep a group-readable mode.
        let plain = Data(ClaudeJSONFixture.text().utf8)
        #expect(ClaudeUserConfigMCPInstaller.modes(0o640, old: plain, new: plain, MCPTest.remove)
            == .init(current: 0o640, file: 0o640, backup: 0o640))
        #expect(ClaudeUserConfigMCPInstaller.modes(0o640, old: plain, new: plain, MCPTest.register)
            == .init(current: 0o640, file: 0o640, backup: 0o640))
        #expect(ClaudeUserConfigMCPInstaller.modeNote(.init(current: 0o640, file: 0o640, backup: 0o640)) == nil)
    }

    @Test func registeringIntoAReadableFileWritesItAndTheBackup0600() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        for mode: mode_t in [0o644, 0o664, 0o604] {
            let file = try MCPTest.write(tmp, ".claude-\(mode).json", Data(ClaudeJSONFixture.text().utf8), mode: mode)
            let installer = MCPTest.installer(file)
            let plan = try installer.plan(MCPTest.register)
            let shown = String(format: "%04o", UInt32(mode))
            #expect(plan.modeNote == "檔案權限 \(shown) → 0600：內含 token，不讓其他帳號讀取（備份同樣 0600）")
            #expect(fileMode(file.path) == mode, "the preview changes nothing")
            let result = try installer.apply(plan)
            #expect(fileMode(file.path) == 0o600)
            #expect(fileMode(result.backup!.path) == 0o600)
            #expect(try String(contentsOf: result.backup!, encoding: .utf8) == ClaudeJSONFixture.text(), "same bytes")
            #expect(try ClaudeJSONFixture.servers(try Data(contentsOf: file))?["codd"] == ClaudeJSONFixture.ours())
        }
    }

    @Test func removingFromAReadableFileKeepsItsModeButTheBackupIs0600() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let text = ClaudeJSONFixture.text(servers: ClaudeJSONFixture.defaultServers + [("codd", ClaudeJSONFixture.ours())])
        let file = try MCPTest.write(tmp, text: text, mode: 0o644)
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.remove)
        #expect(plan.modeNote == "備份檔權限 0600：內含 token，不讓其他帳號讀取（檔案維持 0644）")
        let result = try installer.apply(plan)
        #expect(fileMode(file.path) == 0o644, "the token is gone from the file")
        #expect(fileMode(result.backup!.path) == 0o600, "the backup still holds it")
        #expect(try String(contentsOf: result.backup!, encoding: .utf8) == text)
    }

    @Test func aSymlinkedReadableFileIsTightenedAtItsTarget() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let target = try MCPTest.write(tmp, "dotfiles/claude.json", Data(ClaudeJSONFixture.text().utf8), mode: 0o644)
        let link = tmp.file(".claude.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "dotfiles/claude.json")
        let installer = MCPTest.installer(link)
        let result = try installer.apply(try installer.plan(MCPTest.register))
        #expect(isSymlink(link.path) && fileMode(target.path) == 0o600 && fileMode(result.backup!.path) == 0o600)
    }

    /// Review RV-3: a file registered before CODE-3 (the token in it, 0644) and older backups that
    /// hold the token get a tighten-only plan: no byte changes, no new backup, only 0600.
    @Test func aRegisteredReadableFileGetsATightenOnlyPlan() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let text = ClaudeJSONFixture.text(servers: ClaudeJSONFixture.defaultServers + [("codd", ClaudeJSONFixture.ours())])
        let file = try MCPTest.write(tmp, text: text, mode: 0o644)
        let tokenBackup = try MCPTest.write(tmp, ".claude.json.codd-bak-20261001-090000", text: text, mode: 0o644)
        let plainBackup = try MCPTest.write(tmp, ".claude.json.codd-bak-20260901-090000", text: ClaudeJSONFixture.text(), mode: 0o644)
        let installer = MCPTest.installer(file)
        let found = try installer.inspect(ourURL: MCPTest.url, token: MCPTest.token)
        #expect(found.codd?.tokenMatches == true && found.exposedMode == 0o644 && found.exposedBackups == 1 && found.exposesToken)
        let plan = try installer.plan(MCPTest.register)
        #expect(plan.modeOnly && !plan.upToDate && plan.diff.isEmpty && plan.backupName.isEmpty)
        #expect(plan.summary == "mcpServers 已是最新，只把含 token 的檔案權限改成 0600")
        #expect(plan.modeNote == "檔案權限 0644 → 0600：內含 token，不讓其他帳號讀取（另有 1 個備份同樣改成 0600）")
        #expect(fileMode(file.path) == 0o644, "the preview changes nothing")
        let result = try installer.apply(plan)
        #expect(result == ClaudeUserConfigMCPResult(backup: nil, wrote: false, tightened: 2))
        #expect(fileMode(file.path) == 0o600 && fileMode(tokenBackup.path) == 0o600)
        #expect(fileMode(plainBackup.path) == 0o644, "a backup without a token keeps its mode")
        #expect(try String(contentsOf: file, encoding: .utf8) == text, "not a byte changed")
        #expect(MCPTest.backups(tmp).count == 2, "no new backup")
        let again = try installer.plan(MCPTest.register)
        #expect(again.upToDate && !again.modeOnly && again.summary == "codd 已經註冊在 mcpServers，不需要變更")
        let tightened = try installer.inspect(ourURL: MCPTest.url, token: MCPTest.token)
        #expect(!tightened.exposesToken)
        // Only a backup is readable: the plan says so, and only the backup changes.
        try MCPTest.write(tmp, ".claude.json.codd-bak-20261002-090000", text: text, mode: 0o640)
        let backupsOnly = try installer.plan(MCPTest.register)
        #expect(backupsOnly.modeOnly && backupsOnly.modeNote == "1 個備份檔權限改成 0600：內含 token，不讓其他帳號讀取")
        #expect(try installer.apply(backupsOnly).tightened == 1)
        #expect(fileMode(tmp.file(".claude.json.codd-bak-20261002-090000").path) == 0o600)
    }

    /// Review RV-3: a write also tightens CODD's older backups that hold a token, and a new backup
    /// that must be 0600 is created so (never chmodded afterwards).
    @Test func aWriteTightensOlderBackupsThatHoldTheToken() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let registered = ClaudeJSONFixture.text(servers: [("codd", ClaudeJSONFixture.ours(token: ClaudeJSONFixture.oldToken))])
        let old = try MCPTest.write(tmp, ".claude.json.codd-bak-20261001-090000", text: registered, mode: 0o644)
        let file = try MCPTest.write(tmp, text: ClaudeJSONFixture.text(), mode: 0o600)
        let installer = MCPTest.installer(file)
        let plan = try installer.plan(MCPTest.register)
        #expect(!plan.modeOnly && plan.modeNote == nil)
        let result = try installer.apply(plan)
        #expect(result.wrote && result.tightened == 1 && fileMode(old.path) == 0o600)
        #expect(fileMode(file.path) == 0o600 && fileMode(result.backup!.path) == 0o600)
        // The private copy keeps the bytes and the times of what it copies.
        let source = try MCPTest.write(tmp, "source.json", text: "{\"X-CODD-Token\": \"x\"}", mode: 0o644)
        var times = [timespec(tv_sec: 1_790_000_000, tv_nsec: 0), timespec(tv_sec: 1_790_000_000, tv_nsec: 0)]
        _ = utimensat(AT_FDCWD, source.path, &times, 0)
        let copy = tmp.file("copy.json")
        #expect(SettingsFS.copyExclusive(from: source.path, to: copy.path, mode: 0o600) == nil)
        let copied = try Data(contentsOf: copy), original = try Data(contentsOf: source)
        #expect(fileMode(copy.path) == 0o600 && copied == original)
        var info = stat()
        #expect(stat(copy.path, &info) == 0 && info.st_mtimespec.tv_sec == 1_790_000_000)
        #expect(SettingsFS.copyExclusive(from: source.path, to: copy.path, mode: 0o600) == EEXIST)
        #expect(FileManager.default.fileExists(atPath: copy.path), "a taken name is left alone")
    }

    @Test func symlinkIsWrittenThrough() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let target = try MCPTest.write(tmp, "dotfiles/claude.json", Data(ClaudeJSONFixture.text().utf8))
        let link = tmp.file("home/.claude.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/claude.json")
        var installer = MCPTest.installer(link)
        let lockPath = installer.lockPath
        #expect(lockPath == tmp.file("home/.claude.json.lock").path)
        let sawLock = LockedFlag()
        installer.afterLock = { sawLock.set(MCPTest.isDirectory(lockPath)) }
        let result = try installer.apply(try installer.plan(MCPTest.register))
        #expect(sawLock.value)
        #expect(isSymlink(link.path))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/claude.json")
        #expect(try ClaudeJSONFixture.servers(try Data(contentsOf: target))?["codd"] == ClaudeJSONFixture.ours())
        #expect(result.backup?.deletingLastPathComponent().path == link.deletingLastPathComponent().path)
        #expect(try String(contentsOf: result.backup!, encoding: .utf8) == ClaudeJSONFixture.text())
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path) == ["claude.json"])
        #expect(!MCPTest.exists(lockPath))
    }

    @Test func lexicalPathAndLockPath() {
        let installer = ClaudeUserConfigMCPInstaller(file: URL(fileURLWithPath: "/tmp/x/home/.claude/../.claude.json"), backupsIndex: nil)
        #expect(installer.path == "/tmp/x/home/.claude.json")
        #expect(installer.lockPath == "/tmp/x/home/.claude.json.lock")
        #expect(ClaudeUserConfigMCPInstaller.lexicalPath("/a//b/./c/../d") == "/a/b/d")
    }

    @Test func backupsIndexEntries() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, "home/.claude.json", Data(ClaudeJSONFixture.text().utf8))
        let index = tmp.file("root/claude-settings-backups.json")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        // An M3 entry already there stays.
        let m3 = ["name": "settings.json.codd-bak-20261016-090000", "reason": "更新 hooks 與 statusline",
                  "at": "2026-10-16T01:00:00.000Z", "settingsPath": "~/.claude/settings.json"]
        try JSONSerialization.data(withJSONObject: ["v": 1, "backups": [m3]]).write(to: index)
        let installer = MCPTest.installer(file, index: index)
        let registered = try installer.apply(try installer.plan(MCPTest.register))
        #expect(registered.indexError == nil)
        let removed = try installer.apply(try installer.plan(MCPTest.remove))
        let entries = BackupsIndex.read(index)
        #expect(entries.count == 3)
        #expect(entries[0]["name"] as? String == m3["name"])
        #expect(entries[1]["name"] as? String == registered.backup?.lastPathComponent)
        #expect(entries[1]["reason"] as? String == "mcp-register")
        #expect(entries[1]["at"] as? String == BackupsIndex.isoString(InstallerPlanTests.now))
        #expect(entries[1]["settingsPath"] as? String == installer.path)
        #expect(entries[2]["name"] as? String == removed.backup?.lastPathComponent)
        #expect(entries[2]["reason"] as? String == "mcp-remove")
        #expect(fileMode(index.path) == 0o600)
        #expect((entries[1]["at"] as? String)?.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
        // Written like the App's writer: pretty, sorted keys.
        let text = try String(contentsOf: index, encoding: .utf8)
        #expect(text.contains("\"backups\""))
        #expect(BackupsIndex.abbreviate(NSHomeDirectory() + "/.claude.json") == "~/.claude.json")
    }

    @Test func codexSnippet() {
        #expect(CodexMCPSnippet.toml(url: "http://127.0.0.1:47821/mcp", token: "<mcpToken>") ==
            "[mcp_servers.codd]\nurl = \"http://127.0.0.1:47821/mcp\"\nhttp_headers = { \"X-CODD-Token\" = \"<mcpToken>\" }\n")
        #expect(CodexMCPSnippet.toml(url: "http://x/\"q\"", token: "a\\b\u{01}") ==
            "[mcp_servers.codd]\nurl = \"http://x/\\\"q\\\"\"\nhttp_headers = { \"X-CODD-Token\" = \"a\\\\b\\u0001\" }\n")
    }

    @Test func performanceOfTheLargeFile() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, ClaudeJSONFixture.large)
        let installer = MCPTest.installer(file)
        let clock = ContinuousClock()
        var plan: ClaudeUserConfigMCPPlan?
        let planTime = try clock.measure { plan = try installer.plan(MCPTest.register) }
        let applyTime = try clock.measure { _ = try installer.apply(plan!) }
        let inspectTime = try clock.measure { _ = try installer.inspect(ourURL: MCPTest.url, token: MCPTest.token) }
        print("claude.json \(ClaudeJSONFixture.large.count) bytes: plan \(planTime), apply \(applyTime), inspect \(inspectTime)")
        #expect(planTime + applyTime < .seconds(1))
    }
}

extension MCPTest {
    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}

/// A flag a `@Sendable` test hook can set.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set(_ value: Bool) {
        lock.lock()
        flag = value
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
