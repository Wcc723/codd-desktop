import Darwin
import Foundation
import Testing
@testable import CoddClaudeSettings

@Suite("ClaudeSettingsFile")
struct SettingsFileTests {
    @Test func missingFileIsAnEmptyObject() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try ClaudeSettingsFile.load(tmp.file("nope/settings.json"))
        #expect(!file.exists)
        #expect(file.root == .object([]))
        #expect(file.fingerprint == nil)
        #expect(file.indent == "  ")
        #expect(file.trailingNewline)
    }

    @Test func blankFileIsAnEmptyObject() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let file = try ClaudeSettingsFile.load(try tmp.write("settings.json", " \n\t\n"))
        #expect(file.exists)
        #expect(file.root == .object([]))
        #expect(file.fingerprint?.size == 4)
    }

    @Test func tooLargeIsRefusedBeforeParsing() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try tmp.write("settings.json", "{\"a\": \"" + String(repeating: "x", count: 100) + "\"}\n")
        #expect(throws: ClaudeSettingsError.tooLarge) { try ClaudeSettingsFile.load(url, maxBytes: 50) }
        #expect(try ClaudeSettingsFile.load(url, maxBytes: 200).exists)
    }

    @Test func invalidJSONAndNonObjects() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let bad = try tmp.write("bad.json", "{\n  \"env\": {\"TOKEN\": \"secret\",}\n}\n")
        #expect(throws: ClaudeSettingsError.invalidJSON(line: 2, column: 29)) { try ClaudeSettingsFile.load(bad) }
        let array = try tmp.write("array.json", "[1, 2]\n")
        #expect(throws: ClaudeSettingsError.notAnObject) { try ClaudeSettingsFile.load(array) }
        #expect(throws: ClaudeSettingsError.self) { try ClaudeSettingsFile.load(tmp.url) }
    }

    @Test func detectsIndentAndTrailingNewline() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let cases: [(String, String, Bool)] = [
            ("{\n  \"a\": 1\n}\n", "  ", true),
            ("{\n    \"a\": 1\n}", "    ", false),
            ("{\n\t\"a\": 1\n}\n", "\t", true),
            ("{\r\n   \"a\": 1\r\n}\r\n", "   ", true),
            ("{\"a\": 1}", "  ", false),
            ("{}\n", "  ", true),
            ("  {\n    \"a\": 1\n}", "  ", false),
        ]
        for (text, indent, newline) in cases {
            let file = try ClaudeSettingsFile.load(try tmp.write("s.json", text))
            #expect(file.indent == indent, "\(text.debugDescription)")
            #expect(file.trailingNewline == newline, "\(text.debugDescription)")
        }
    }

    @Test func readsThroughASymlinkAndFingerprintsTheTarget() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let target = try tmp.write("dotfiles/claude-settings.json", "{\n  \"model\": \"opus\"\n}\n")
        let link = tmp.file("claude/settings.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/claude-settings.json")
        let file = try ClaudeSettingsFile.load(link)
        #expect(file.root["model"] == .string("opus"))
        var info = stat()
        #expect(stat(target.path, &info) == 0)
        #expect(file.fingerprint?.inode == UInt64(info.st_ino))
        #expect(file.fingerprint?.size == Int64(info.st_size))
        #expect(file.url == link)
    }

    @Test func fingerprintChangesWithMtime() throws {
        let tmp = try TempDir()
        defer { tmp.remove() }
        let url = try tmp.write("settings.json", "{}\n")
        let first = try ClaudeSettingsFile.load(url).fingerprint
        var times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 123), timespec(tv_sec: 1_700_000_000, tv_nsec: 456)]
        #expect(utimensat(AT_FDCWD, url.path, &times, 0) == 0)
        let second = try ClaudeSettingsFile.load(url).fingerprint
        #expect(first != second)
        let expected: Int64 = 1_700_000_000_000_000_456
        #expect(second?.mtimeNanoseconds == expected)
    }
}
