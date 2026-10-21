import Foundation
import Testing
@testable import CoddClaudeSettings

/// M5 D14: an index a newer CODD wrote is read and never written; v1 behaviour unchanged.
@Suite("Backups index versions")
struct BackupsIndexVersionTests {
    static var entry: [String: Any] {
        ["name": "settings.json.codd-bak-20261016-090000", "reason": "更新 hooks 與 statusline",
         "at": "2026-10-16T01:00:00.000Z", "settingsPath": "~/.claude/settings.json"]
    }

    @Test func newerIndexIsReadButNeverWritten() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let newer = #"{"backups":[{"name":"a","reason":"r","at":"2026-10-16T01:00:00.000Z","settingsPath":"~/x","extra":1},"not an entry"],"v":2}"#
        let index = try tmp.write("root/claude-settings-backups.json", newer)
        let entries = BackupsIndex.read(index)
        #expect(entries.count == 1)
        #expect(entries.first?["name"] as? String == "a")
        let reason = BackupsIndex.record(index, name: "b", reason: "mcp-register", at: Date(), settingsPath: "/tmp/x/.claude.json")
        #expect(reason == "claude-settings-backups.json is v2 (a newer CODD): entry not written")
        #expect(try Data(contentsOf: index) == Data(newer.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: index.deletingLastPathComponent().path) == ["claude-settings-backups.json"])
    }

    @Test func installerStillBacksUpWhenTheIndexIsNewer() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try MCPTest.write(tmp, "home/.claude.json", Data(ClaudeJSONFixture.text().utf8))
        let newer = #"{"backups":[],"v":3}"#
        let index = try tmp.write("root/claude-settings-backups.json", newer)
        let installer = MCPTest.installer(file, index: index)
        let applied = try installer.apply(try installer.plan(MCPTest.register))
        #expect(applied.wrote)
        let backup = try #require(applied.backup)
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(applied.indexError == "claude-settings-backups.json is v3 (a newer CODD): entry not written")
        #expect(try Data(contentsOf: index) == Data(newer.utf8))
    }

    @Test func versionOneIndexStillAppends() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let index = tmp.file("root/claude-settings-backups.json")
        try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["v": 1, "backups": [Self.entry]]).write(to: index)
        #expect(BackupsIndex.record(index, name: "b", reason: "mcp-register", at: Date(), settingsPath: "/tmp/x/.claude.json") == nil)
        let entries = BackupsIndex.read(index)
        #expect(entries.map { $0["name"] as? String } == ["settings.json.codd-bak-20261016-090000", "b"])
        #expect(BackupsIndex.version(index) == 1)
    }

    @Test func foreignIndexStillReadsEmptyAndIsReplaced() throws {
        for text in [#"{"backups":[{"name":"a"}]}"#, #"{"v":"1","backups":[{"name":"a"}]}"#, #"{"v":0,"backups":[]}"#, "not json"] {
            let tmp = try TempDir()
            defer { tmp.remove() }
            let index = try tmp.write("root/claude-settings-backups.json", text)
            #expect(BackupsIndex.read(index).isEmpty, "\(text)")
            #expect(BackupsIndex.record(index, name: "b", reason: "mcp-register", at: Date(), settingsPath: "/tmp/x/.claude.json") == nil)
            #expect(BackupsIndex.read(index).map { $0["name"] as? String } == ["b"], "\(text)")
        }
    }
}
