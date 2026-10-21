import Foundation
import Testing
@testable import CoddOnboarding

@Suite("ProjectCatalogReader (D8, §2.5)")
struct CatalogTests {
    @Test("newest first, counts, hidden kinds, never-used last, missing folders skipped")
    func orderCountsHidden() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("clients/a")
        let b = try box.project("clients/b")
        let wt = try box.project("a/.claude-worktrees/wt-1")
        let sdk = try box.project("runner")
        let unused = try box.project("unused")
        let gone = box.work + "/gone"
        try box.transcript(for: a, ago: 3600)
        try box.transcript(for: a, ago: 7200)
        try box.transcript(for: b, ago: 3 * 3600)
        try box.transcript(for: wt, ago: 2 * 3600)
        for hour in [4.0, 5.0, 6.0] { try box.transcript(for: sdk, ago: hour * 3600, entrypoint: "sdk-cli") }
        try box.transcript(for: sdk, ago: 30 * 3600)   // an older cli transcript: only the newest 3 count
        try box.writeConfig([a, b, wt, sdk, unused, gone, "relative/path"])

        let result = box.read()
        #expect(result.source == "~/.claude.json")
        #expect(result.problem == nil)
        #expect(result.candidates.map(\.path) == [a, wt, b, sdk, unused])
        #expect(result.candidates.map(\.transcripts) == [2, 1, 1, 4, 0])
        #expect(result.candidates.map(\.hidden) == [nil, .worktree, nil, .sdk, nil])
        #expect(result.candidates.last?.lastUsed == nil)
        #expect(result.candidates.first?.displayPath == a)   // outside the home folder: no `~`
        #expect(result.visibleTotal == 3)
        #expect(result.alreadyInCODD == 0)
    }

    @Test("an SDK project needs every one of its newest 3 transcripts to be sdk-*")
    func sdkNeedsAllNewest() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let mixed = try box.project("mixed")
        try box.transcript(for: mixed, ago: 60, entrypoint: "sdk-cli")
        try box.transcript(for: mixed, ago: 120, entrypoint: "cli")
        try box.writeConfig([mixed])
        #expect(box.read().candidates.first?.hidden == nil)
    }

    @Test("projects already in CODD are left out and counted (standardized, trailing slash ignored)")
    func alreadyInCODD() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("a")
        let b = try box.project("b")
        let c = try box.project("c")
        try box.writeConfig([a + "/", b, c])
        let result = box.read(existing: [a, b + "/", box.work + "/./c/../c"])
        #expect(result.candidates.isEmpty)
        #expect(result.alreadyInCODD == 3)
    }

    @Test("keys are standardized and deduplicated")
    func standardizedKeys() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("a")
        try box.transcript(for: a, ago: 60)
        try box.writeConfig([a, a + "/", box.work + "//a"])
        let result = box.read()
        #expect(result.candidates.map(\.path) == [a])
        #expect(result.candidates.first?.transcripts == 1)
    }

    @Test("a folder name longer than 200 characters matches by its 200-character prefix")
    func longFolderName() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let long = try box.project(String(repeating: "deep-folder-name/", count: 14) + "app")
        let slug = TranscriptFolderName.sanitized(long)
        #expect(slug.utf8.count > TranscriptFolderName.maxLength)
        let folder = String(slug.prefix(TranscriptFolderName.maxLength)) + "-1x2y3z"
        try box.transcript(for: long, ago: 60, folder: folder)
        try box.transcript(for: long, ago: 120, folder: folder)
        try box.writeConfig([long])
        let result = box.read()
        #expect(result.candidates.first?.transcripts == 2)
        #expect(result.candidates.first?.lastUsed != nil)
    }

    @Test("a file over the size cap is not read")
    func sizeCap() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("a")
        try box.writeConfig([a])
        let size = try #require(try FileManager.default.attributesOfItem(atPath: box.configPath)[.size] as? Int)
        let capped = ProjectCatalogReader.read(claudeDirectory: box.claudeDir, home: box.home, existingProjectPaths: [],
                                               maxFileBytes: size - 1, maxProjectKeys: 2000)
        #expect(capped.candidates.isEmpty)
        #expect(capped.problem?.contains("太大") == true)
        let fits = ProjectCatalogReader.read(claudeDirectory: box.claudeDir, home: box.home, existingProjectPaths: [],
                                             maxFileBytes: size, maxProjectKeys: 2000)
        #expect(fits.candidates.count == 1)
    }

    @Test("at most maxProjectKeys keys are looked at, sorted by key")
    func keyCap() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let paths = try ["c", "a", "b"].map { try box.project($0) }
        try box.writeConfig(paths)
        let result = ProjectCatalogReader.read(claudeDirectory: box.claudeDir, home: box.home, existingProjectPaths: [],
                                               maxFileBytes: ProjectCatalogReader.maxFileBytes, maxProjectKeys: 2)
        #expect(Set(result.candidates.map(\.name)) == ["a", "b"])
    }

    @Test("a symlinked .claude.json is read through and stays a symlink")
    func symlinkedConfig() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("a")
        let dotfiles = box.root.appendingPathComponent("dotfiles").path
        try FileManager.default.createDirectory(atPath: dotfiles, withIntermediateDirectories: true)
        try box.writeConfig([a], at: dotfiles + "/claude.json")
        try FileManager.default.createSymbolicLink(atPath: box.configPath, withDestinationPath: dotfiles + "/claude.json")
        let result = box.read()
        #expect(result.candidates.map(\.path) == [a])
        let type = try FileManager.default.attributesOfItem(atPath: box.configPath)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink)
    }

    @Test("transcript folders and files that are symlinks are never followed")
    func transcriptLinksNotFollowed() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("a")
        let b = try box.project("b")
        // a: its folder is a symlink to a real folder with transcripts.
        let elsewhere = box.root.appendingPathComponent("elsewhere").path
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try "{}\n".write(toFile: elsewhere + "/x.jsonl", atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: box.transcriptFolder(for: a), withDestinationPath: elsewhere)
        // b: a real folder holding one real transcript and one symlinked transcript.
        try box.transcript(for: b, ago: 60)
        try FileManager.default.createSymbolicLink(atPath: box.transcriptFolder(for: b) + "/linked.jsonl", withDestinationPath: elsewhere + "/x.jsonl")
        try box.writeConfig([a, b])
        let result = box.read()
        #expect(result.candidate(a)?.transcripts == 0)
        #expect(result.candidate(a)?.lastUsed == nil)
        #expect(result.candidate(b)?.transcripts == 1)
    }

    @Test("reading changes nothing: .claude.json and the transcripts keep their bytes and mtimes")
    func readOnly() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("a")
        let b = try box.project("b")
        var files = [try box.transcript(for: a, ago: 60), try box.transcript(for: b, ago: 120, entrypoint: "sdk-cli")]
        try box.writeConfig([a, b])
        files.append(box.configPath)
        let folders = [box.transcriptFolder(for: a), box.transcriptFolder(for: b)]
        let before = (files + folders).map(Fingerprint.init)
        let listing = try FileManager.default.contentsOfDirectory(atPath: box.claudeDir.path + "/projects").sorted()
        _ = box.read()
        _ = box.read(existing: [a])
        #expect((files + folders).map(Fingerprint.init) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: box.claudeDir.path + "/projects").sorted() == listing)
    }

    @Test("no .claude.json at all")
    func noConfig() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let result = box.read()
        #expect(result.source == nil)
        #expect(result.candidates.isEmpty)
        #expect(result.problem == "找不到 ~/.claude.json")
    }

    @Test("<claudeDir>/.claude.json is the fallback; a broken file is a problem, not a crash")
    func fallbackAndBroken() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let a = try box.project("a")
        try box.writeConfig([a], at: box.claudeDir.path + "/.claude.json")
        #expect(box.read().candidates.map(\.path) == [a])
        try "{not json".write(toFile: box.configPath, atomically: false, encoding: .utf8)
        let broken = box.read()
        #expect(broken.candidates.isEmpty)
        #expect(broken.problem == "~/.claude.json 無法解析")
    }

    @Test("200 projects read within the budget (150 ms, debug)")
    func budget() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        var keys: [String] = []
        for index in 0..<200 {
            let path = try box.project("p\(index)")
            try box.transcript(for: path, ago: TimeInterval(index * 60))
            keys.append(path)
        }
        try box.writeConfig(keys)
        let start = Date()
        let result = box.read()
        let elapsed = Date().timeIntervalSince(start)
        #expect(result.candidates.count == 200)
        #expect(elapsed < 0.6, "took \(elapsed) s (budget 0.15 s; loose bound for a busy machine)")
    }
}
