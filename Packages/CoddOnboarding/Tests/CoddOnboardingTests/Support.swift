import CryptoKit
import Foundation
@testable import CoddOnboarding

/// A throwaway home under the temp folder: `home/.claude`, `home/.claude.json`, made-up projects
/// under `work/`. Removed by `cleanUp()`.
struct Sandbox {
    let root: URL
    var home: String { root.appendingPathComponent("home").path }
    var claudeDir: URL { root.appendingPathComponent("home/.claude", isDirectory: true) }
    var work: String { root.appendingPathComponent("work").path }
    var configPath: String { home + "/.claude.json" }

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
        root = base.appendingPathComponent("codd-onboarding-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir.appendingPathComponent("projects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }

    /// Creates `work/<relative>` and returns its path.
    @discardableResult
    func project(_ relative: String) throws -> String {
        let path = work + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// `home/.claude/projects/<sanitized path>` (or `folder` when given).
    func transcriptFolder(for path: String, folder: String? = nil) -> String {
        claudeDir.path + "/projects/" + (folder ?? TranscriptFolderName.sanitized(path))
    }

    /// One transcript for `path`, modified `ago` seconds before `now`.
    @discardableResult
    func transcript(for path: String, ago: TimeInterval, entrypoint: String = "cli", folder: String? = nil,
                    now: Date = Date()) throws -> String {
        let directory = transcriptFolder(for: path, folder: folder)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let file = directory + "/\(UUID().uuidString.lowercased()).jsonl"
        let line = #"{"type":"user","cwd":"\#(path)","sessionId":"x","entrypoint":"\#(entrypoint)","message":{"role":"user","content":"hi"}}"#
        try (line + "\n").write(toFile: file, atomically: false, encoding: .utf8)
        try setModified(file, now.addingTimeInterval(-ago))
        return file
    }

    func setModified(_ path: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    /// `home/.claude.json` with `projects` keys and unrelated members.
    func writeConfig(_ keys: [String], at path: String? = nil) throws {
        var projects: [String: Any] = [:]
        for key in keys { projects[key] = ["allowedTools": [String](), "hasTrustDialogAccepted": true] }
        let object: [String: Any] = ["numStartups": 7, "projects": projects,
                                     "oauthAccount": ["emailAddress": "someone@example.com"]]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: path ?? configPath))
    }

    func read(existing: Set<String> = []) -> ProjectCatalog {
        ProjectCatalogReader.read(claudeDirectory: claudeDir, home: home, existingProjectPaths: existing)
    }
}

/// sha256 + modification time of a file (the read-only checks).
struct Fingerprint: Equatable {
    let digest: String
    let modified: Date?

    init(_ path: String) {
        let data = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var info = stat()
        if lstat(path, &info) == 0 {
            modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        } else {
            modified = nil
        }
    }
}

/// A Taipei date for the artboard's clock.
func taipei(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
    OnboardingSamples.date(year, month, day, hour, minute, second)
}

/// A candidate with defaults (rule tests).
func candidate(_ path: String, lastUsed: Date? = nil, transcripts: Int = 1, hidden: ImportCandidate.Hidden? = nil,
               prefix: String? = nil, home: String = "/Users/test") -> ImportCandidate {
    ImportCandidate(path: path, name: PathText.lastComponent(path), prefix: prefix, displayPath: PathText.abbreviate(path, home: home),
                    lastUsed: lastUsed, transcripts: transcripts, hidden: hidden)
}

func catalog(_ candidates: [ImportCandidate], already: Int = 0) -> ProjectCatalog {
    ProjectCatalog(source: "~/.claude.json", candidates: candidates, alreadyInCODD: already, problem: nil)
}
