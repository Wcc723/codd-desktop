import Darwin
import Foundation
import Testing
@testable import CoddCore

/// Synthetic Claude transcript folders written into a temp dir (never `~/.claude`).
struct TranscriptFixture {
    let temp: TempDir
    let projects: URL

    init() throws {
        temp = try TempDir("codd-transcripts")
        projects = temp.url.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
    }

    func remove() { temp.remove() }

    func catalog(headBytes: Int = 256 << 10, tailBytes: Int = 128 << 10) -> TranscriptCatalog {
        TranscriptCatalog(projectsDirectory: projects, headBytes: headBytes, tailBytes: tailBytes)
    }

    /// A real folder inside the temp dir (its `/var/...` spelling; the physical one is `/private/var/...`).
    func makeDirectory(_ relative: String) throws -> String {
        let url = temp.url.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// Writes `<projects>/<folder>/<id>.jsonl` (folder = Claude's name for `folderCwd`, else `folder`).
    @discardableResult
    func write(_ id: String, folderCwd: String? = nil, folder: String? = nil, lines: [JSONValue],
               modified: Date? = nil) throws -> URL {
        let name = folder ?? TranscriptCatalog.folderName(for: folderCwd ?? "/")
        let dir = projects.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(id).jsonl")
        var data = Data()
        for line in lines {
            data.append(try line.jsonData())
            data.append(0x0A)
        }
        try data.write(to: file)
        if let modified { try setModified(file, modified) }
        return file
    }

    func setModified(_ file: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    // MARK: Lines (Claude Code 2.1.30x layout)

    static func user(_ content: JSONValue, cwd: String, branch: String = "main", entrypoint: String = "cli",
                     timestamp: String = "2026-10-01T08:00:00.000Z", extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": "user", "cwd": .string(cwd), "gitBranch": .string(branch), "entrypoint": .string(entrypoint),
            "timestamp": .string(timestamp), "isSidechain": false, "userType": "external", "version": "2.1.301",
            "sessionId": "s", "uuid": "u", "message": ["role": "user", "content": content],
        ]
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    static func assistant(cwd: String, text: String = "好的", branch: String = "main") -> JSONValue {
        ["type": "assistant", "cwd": .string(cwd), "gitBranch": .string(branch), "timestamp": "2026-10-01T08:00:05.000Z",
         "message": ["role": "assistant", "content": [["type": "text", "text": .string(text)]]]]
    }

    static func customTitle(_ t: String) -> JSONValue { ["type": "custom-title", "customTitle": .string(t), "sessionId": "s"] }
    static func aiTitle(_ t: String) -> JSONValue { ["type": "ai-title", "aiTitle": .string(t), "sessionId": "s"] }
    static func lastPrompt(_ t: String) -> JSONValue { ["type": "last-prompt", "lastPrompt": .string(t), "leafUuid": "l"] }
}

private let idA = "3f2a91c0-0000-4000-8000-00000000000a"
private let idB = "3f2a91c0-0000-4000-8000-00000000000b"
private let idC = "3f2a91c0-0000-4000-8000-00000000000c"
private let idD = "3f2a91c0-0000-4000-8000-00000000000d"
private let idE = "3f2a91c0-0000-4000-8000-00000000000e"

@Suite("Transcript catalog")
struct TranscriptCatalogTests {
    typealias F = TranscriptFixture

    @Test func titlePriority() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let now = Date()
        try fx.write(idA, folderCwd: cwd, lines: [
            F.user("第一個 prompt", cwd: cwd), F.customTitle("舊的名稱"), F.aiTitle("AI 標題"), F.customTitle("refresh token 流程改寫"),
        ], modified: now)
        try fx.write(idB, folderCwd: cwd, lines: [F.user("第一個 prompt", cwd: cwd), F.aiTitle("舊 AI"), F.aiTitle("auth middleware 單元測試")],
                     modified: now.addingTimeInterval(-10))
        try fx.write(idC, folderCwd: cwd, lines: [F.user("登入頁錯誤訊息 i18n", cwd: cwd), F.assistant(cwd: cwd)],
                     modified: now.addingTimeInterval(-20))
        try fx.write(idD, folderCwd: cwd, lines: [F.assistant(cwd: cwd)], modified: now.addingTimeInterval(-30))
        let list = fx.catalog().list(cwd: cwd)
        #expect(list.map(\.id) == [idA, idB, idC, idD])
        #expect(list.map(\.title) == ["refresh token 流程改寫", "auth middleware 單元測試", "登入頁錯誤訊息 i18n", "（沒有標題）"])
        #expect(list.map(\.titleSource) == [.custom, .ai, .firstPrompt, .none])
        #expect(list[0].cwd == cwd)
        #expect(list[0].path == fx.projects.path + "/" + TranscriptCatalog.folderName(for: cwd) + "/\(idA).jsonl")
    }

    @Test func customTitleInTheTailBeatsOneInTheHead() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let filler = String(repeating: "x", count: 900)
        let lines: [JSONValue] = [F.user("prompt", cwd: cwd), F.customTitle("head 名稱")]
            + (0..<20).map { _ in F.assistant(cwd: cwd, text: filler) } + [F.aiTitle("ai"), F.customTitle("tail 名稱")]
        try fx.write(idA, folderCwd: cwd, lines: lines)
        let item = try #require(fx.catalog(headBytes: 4096, tailBytes: 4096).list(cwd: cwd).first)
        #expect(item.title == "tail 名稱")
        #expect(item.titleSource == .custom)
    }

    @Test func metaSidechainAndCommandLinesAreSkipped() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        try fx.write(idA, folderCwd: cwd, lines: [
            F.user("Caveat: The messages below were generated by the user while running local commands.", cwd: cwd, extra: ["isMeta": true]),
            F.user("<command-name>/clear</command-name>\n<command-message>clear</command-message>", cwd: cwd),
            F.user("<local-command-stdout></local-command-stdout>", cwd: cwd),
            F.user("Caveat: something", cwd: cwd),
            F.user("  \n ", cwd: cwd),
            F.user("我是 meta", cwd: cwd, extra: ["isMeta": true]),
            F.user("我是 sidechain", cwd: cwd, extra: ["isSidechain": true]),
            F.user([["type": "tool_result", "tool_use_id": "t", "content": "ok"]], cwd: cwd),
            F.user([["type": "image", "source": ["type": "base64", "data": "AAAA"]],
                    ["type": "text", "text": "<command-message>x</command-message>"],
                    ["type": "text", "text": "  修正\n登入\t API   401 "]], cwd: cwd),
            F.user("之後的 prompt", cwd: cwd),
        ])
        let item = try #require(fx.catalog().list(cwd: cwd).first)
        #expect(item.title == "修正 登入 API 401")
        #expect(item.titleSource == .firstPrompt)
    }

    @Test func stringContentAndLongPromptTruncation() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let long = String(repeating: "很長的提示", count: 40) // 200 characters
        try fx.write(idA, folderCwd: cwd, lines: [F.user(.string(long), cwd: cwd)])
        let item = try #require(fx.catalog().list(cwd: cwd).first)
        #expect(item.title.count == 80)
        #expect(item.title.hasSuffix("…"))
        #expect(item.title.hasPrefix("很長的提示很長的提示"))
    }

    @Test func branchEntrypointAndCreatedAt() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        try fx.write(idA, folderCwd: cwd, lines: [
            ["type": "file-history-snapshot", "messageId": "m"],
            F.user("<command-name>/model</command-name>", cwd: cwd, branch: "", entrypoint: "claude-vscode",
                   timestamp: "2026-10-03T01:02:03.000Z"),
            F.user("修正", cwd: cwd, branch: "fix/refresh", entrypoint: "cli", timestamp: "2026-10-03T01:05:00.000Z"),
        ])
        let item = try #require(fx.catalog().list(cwd: cwd).first)
        #expect(item.gitBranch == "fix/refresh")
        #expect(item.entrypoint == "claude-vscode")
        #expect(item.createdAt == JSDate.date(fromISO: "2026-10-03T01:02:03.000Z"))
        #expect(item.title == "修正")
    }

    @Test func sdkEntrypointsHiddenUnlessIncluded() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let now = Date()
        try fx.write(idA, folderCwd: cwd, lines: [F.user("cli prompt", cwd: cwd)], modified: now)
        try fx.write(idB, folderCwd: cwd, lines: [F.user("sdk prompt", cwd: cwd, entrypoint: "sdk-cli")], modified: now.addingTimeInterval(-5))
        let catalog = fx.catalog()
        #expect(catalog.list(cwd: cwd).map(\.id) == [idA])
        #expect(catalog.list(cwd: cwd, includeSDK: true).map(\.id) == [idA, idB])
        #expect(catalog.list(cwd: cwd, includeSDK: true).last?.entrypoint == "sdk-cli")
    }

    @Test func anotherCwdInTheSameFolderAndCwdlessFilesAreExcluded() throws {
        let fx = try F()
        defer { fx.remove() }
        // Both sanitize to the same slug (each CJK character becomes one "-").
        let mine = try fx.makeDirectory("x/整合")
        let other = try fx.makeDirectory("x/字典")
        #expect(TranscriptCatalog.folderName(for: mine) == TranscriptCatalog.folderName(for: other))
        try fx.write(idA, folderCwd: mine, lines: [F.user("mine", cwd: mine)])
        try fx.write(idB, folderCwd: mine, lines: [F.user("other", cwd: other)])
        try fx.write(idC, folderCwd: mine, lines: [F.customTitle("no cwd at all")])
        try fx.write("bad name", folderCwd: mine, lines: [F.user("not a session id", cwd: mine)])
        try fx.write(idD, folder: TranscriptCatalog.folderName(for: mine) + "/subagents", lines: [F.user("subfolder", cwd: mine)])
        let catalog = fx.catalog()
        #expect(catalog.list(cwd: mine).map(\.id) == [idA])
        #expect(catalog.list(cwd: other).map(\.id) == [idB])
    }

    @Test func symlinkedAndPhysicalCwdsMatchBothWays() throws {
        let fx = try F()
        defer { fx.remove() }
        let viaVar = try fx.makeDirectory("real/proj")                     // /var/folders/…/real/proj
        let physical = try #require(ReadOnlyFile.realPath(viaVar))           // /private/var/folders/…/real/proj
        #expect(physical != viaVar)
        let alias = fx.temp.url.appendingPathComponent("alias").path
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: physical)
        let now = Date()
        // Claude started from the physical path: found from the user symlink and from the /var spelling.
        try fx.write(idA, folderCwd: physical, lines: [F.user("physical", cwd: physical)], modified: now)
        // Claude started from the /var spelling: found from the physical path.
        try fx.write(idB, folderCwd: viaVar, lines: [F.user("via var", cwd: viaVar)], modified: now.addingTimeInterval(-10))
        // Lines carrying the symlinked path inside the physical folder still match the physical cwd.
        try fx.write(idC, folderCwd: physical, lines: [F.user("alias lines", cwd: alias)], modified: now.addingTimeInterval(-20))
        let catalog = fx.catalog()
        #expect(catalog.list(cwd: alias).map(\.id) == [idA, idB, idC])
        #expect(catalog.list(cwd: physical).map(\.id) == [idA, idB, idC])
        #expect(catalog.list(cwd: viaVar).map(\.id) == [idA, idB, idC])
        #expect(catalog.list(cwd: viaVar + "/").map(\.id) == [idA, idB, idC])
    }

    @Test func newestFirstAndLimit() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let now = Date()
        let ids = [idA, idB, idC, idD, idE]
        for (n, id) in ids.enumerated() {
            try fx.write(id, folderCwd: cwd, lines: [F.user(.string("p\(n)"), cwd: cwd)], modified: now.addingTimeInterval(-Double(n) * 3600))
        }
        let catalog = fx.catalog()
        #expect(catalog.list(cwd: cwd, limit: 3).map(\.id) == [idA, idB, idC])
        #expect(catalog.fileReads == 3) // only the newest `limit` are opened
        #expect(catalog.list(cwd: cwd).map(\.id) == ids)
        #expect(catalog.list(cwd: cwd, limit: 0).isEmpty)
        let first = try #require(catalog.list(cwd: cwd).first)
        #expect(first.sizeBytes > 0)
        #expect(abs(first.lastActivity.timeIntervalSince(now)) < 1)
    }

    @Test func hugeFileReadsOnlyHeadAndTail() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let file = try fx.write(idA, folderCwd: cwd, lines: [F.user("大檔案的第一個 prompt", cwd: cwd)])
        // 50 MB, mostly a sparse hole of NULs, with one real line at the very end.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 50 << 20)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8) + (try F.assistant(cwd: cwd).jsonData()) + Data("\n".utf8))
        try handle.close()
        let catalog = fx.catalog()
        let clock = ContinuousClock()
        let start = clock.now
        let list = catalog.list(cwd: cwd)
        let elapsed = clock.now - start
        print("PERF transcript list, one 50 MB file: \(elapsed)")
        #expect(elapsed < .milliseconds(500))
        #expect(list.first?.title == "大檔案的第一個 prompt")
        #expect((list.first?.sizeBytes ?? 0) > 50 << 20)
    }

    @Test func firstLineLongerThanTheHeadHasNoTitle() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let pasted = String(repeating: "貼上的大量文字 ", count: 1500) // ≈ 30 KB in UTF-8
        try fx.write(idA, folderCwd: cwd, lines: [F.user(.string(pasted), cwd: cwd), F.assistant(cwd: cwd, branch: "feat/x")])
        let item = try #require(fx.catalog(headBytes: 4096, tailBytes: 4096).list(cwd: cwd).first)
        #expect(item.title == "（沒有標題）")
        #expect(item.titleSource == .none)
        #expect(item.cwd == cwd)            // from the tail
        #expect(item.gitBranch == "feat/x") // from the tail
    }

    @Test func folderNameMatchesClaudeCode() {
        #expect(TranscriptCatalog.folderName(for: "/Users/a/My Proj_1") == "-Users-a-My-Proj-1")
        #expect(TranscriptCatalog.folderName(for: "/x/整合") == "-x---")
        #expect(TranscriptCatalog.folderName(for: "/a/\u{1F680}") == "-a---") // two UTF-16 units
        // Reference values from Claude Code 2.1.301's own function (node).
        let long = "/Users/synthetic/" + String(repeating: "deep-folder-", count: 20) + "整合"
        #expect(TranscriptCatalog.folderName(for: long)
            == "-Users-synthetic-" + String(repeating: "deep-folder-", count: 15) + "dee-j6uo9g")
        let exactly200 = "/Users/synthetic/" + String(repeating: "x", count: 183)
        #expect(TranscriptCatalog.folderName(for: exactly200) == "-Users-synthetic-" + String(repeating: "x", count: 183))
        let just201 = "/Users/synthetic/" + String(repeating: "x", count: 184)
        #expect(TranscriptCatalog.folderName(for: just201) == "-Users-synthetic-" + String(repeating: "x", count: 183) + "-wnqy0w")
    }

    @Test func longPathFoundThroughItsPrefix() throws {
        let fx = try F()
        defer { fx.remove() }
        let segment = String(repeating: "很長的資料夾", count: 4) + "-segment"
        let cwd = try fx.makeDirectory((0..<6).map { "\(segment)\($0)" }.joined(separator: "/"))
        let other = try fx.makeDirectory((0..<6).map { "\(segment)\($0)" }.joined(separator: "/") + "-other")
        #expect(cwd.utf16.count > 250)
        let prefix = String(TranscriptCatalog.sanitized(cwd).prefix(200))
        #expect(TranscriptCatalog.folderName(for: other).hasPrefix(prefix))
        let now = Date()
        try fx.write(idA, folder: TranscriptCatalog.folderName(for: cwd), lines: [F.user("exact", cwd: cwd)], modified: now)
        try fx.write(idB, folder: prefix + "-otherhash", lines: [F.user("another version's hash", cwd: cwd)],
                     modified: now.addingTimeInterval(-10))
        try fx.write(idC, folder: prefix + "-otherhash", lines: [F.user("same prefix, other cwd", cwd: other)],
                     modified: now.addingTimeInterval(-20))
        let catalog = fx.catalog()
        #expect(catalog.list(cwd: cwd).map(\.id) == [idA, idB])
        #expect(catalog.list(cwd: other).map(\.id) == [idC])
    }

    @Test func warmCallsOnlyStat() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let now = Date()
        try fx.write(idA, folderCwd: cwd, lines: [F.user("a", cwd: cwd)], modified: now)
        let fileB = try fx.write(idB, folderCwd: cwd, lines: [F.user("b", cwd: cwd)], modified: now.addingTimeInterval(-60))
        let catalog = fx.catalog()
        let cold = catalog.list(cwd: cwd)
        #expect(catalog.fileReads == 2)
        let warm = catalog.list(cwd: cwd)
        #expect(warm == cold)
        #expect(catalog.fileReads == 2)
        #expect(catalog.lastPrompt(cwd: cwd, sessionId: idA) == "a")
        #expect(catalog.fileReads == 2)
        // A changed file (size and mtime) is read again; the other one stays cached.
        let handle = try FileHandle(forWritingTo: fileB)
        try handle.seekToEnd()
        try handle.write(contentsOf: try F.customTitle("改名了").jsonData() + Data("\n".utf8))
        try handle.close()
        try fx.setModified(fileB, now.addingTimeInterval(30))
        let changed = catalog.list(cwd: cwd)
        #expect(catalog.fileReads == 3)
        #expect(changed.map(\.id) == [idB, idA])
        #expect(changed.first?.title == "改名了")
    }

    @Test func concurrentListsAgree() async throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        for (n, id) in [idA, idB, idC].enumerated() {
            try fx.write(id, folderCwd: cwd, lines: [F.user(.string("p\(n)"), cwd: cwd)], modified: Date().addingTimeInterval(-Double(n)))
        }
        let catalog = fx.catalog()
        let results = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 { group.addTask { catalog.list(cwd: cwd).map(\.id) } }
            var out: [[String]] = []
            for await r in group { out.append(r) }
            return out
        }
        #expect(results.allSatisfy { $0 == [idA, idB, idC] })
    }

    @Test func lastPromptFromRecordThenUserMessage() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        try fx.write(idA, folderCwd: cwd, lines: [
            F.user("第一個", cwd: cwd), F.lastPrompt("舊的 last prompt"), F.user("較新的 user", cwd: cwd),
            F.lastPrompt("  refresh token\n流程改寫 "), F.assistant(cwd: cwd),
        ])
        try fx.write(idB, folderCwd: cwd, lines: [
            F.user("第一個", cwd: cwd), F.user("最後一個 prompt", cwd: cwd),
            F.user([["type": "tool_result", "tool_use_id": "t", "content": "ok"]], cwd: cwd), F.assistant(cwd: cwd),
        ])
        let long = String(repeating: "長", count: 300)
        try fx.write(idC, folderCwd: cwd, lines: [F.lastPrompt(long)])
        let catalog = fx.catalog()
        #expect(catalog.lastPrompt(cwd: cwd, sessionId: idA) == "refresh token 流程改寫")
        #expect(catalog.lastPrompt(cwd: cwd, sessionId: idB) == "最後一個 prompt")
        #expect(catalog.lastPrompt(cwd: cwd, sessionId: idC) == nil) // no cwd line: not this folder's
        #expect(catalog.lastPrompt(cwd: cwd, sessionId: idD) == nil)
        #expect(catalog.lastPrompt(cwd: cwd, sessionId: "../\(idA)") == nil)
        try fx.write(idE, folderCwd: cwd, lines: [F.user("x", cwd: cwd), F.lastPrompt(long)])
        let cut = try #require(catalog.lastPrompt(cwd: cwd, sessionId: idE))
        #expect(cut.count == 200)
        #expect(cut.hasSuffix("…"))
    }

    @Test func filesOfOneConversation() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("x/整合")
        let other = try fx.makeDirectory("x/字典")
        let jsonl = try fx.write(idA, folderCwd: cwd, lines: [F.user("mine", cwd: cwd)])
        let sibling = jsonl.deletingLastPathComponent().appendingPathComponent(idA, isDirectory: true)
        try FileManager.default.createDirectory(at: sibling.appendingPathComponent("subagents"), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: sibling.appendingPathComponent("subagents/agent-1.jsonl"))
        let otherFile = try fx.write(idB, folderCwd: cwd, lines: [F.user("theirs", cwd: other)])
        let catalog = fx.catalog()

        let before = try modificationDates([jsonl, sibling, otherFile, jsonl.deletingLastPathComponent()])
        #expect(catalog.files(sessionId: idA, cwd: cwd).map(\.path) == [jsonl.path, sibling.path])
        #expect(catalog.files(sessionId: idA, cwd: cwd).last?.hasDirectoryPath == true)
        #expect(catalog.files(sessionId: idB, cwd: cwd).isEmpty)               // another cwd's file
        #expect(catalog.files(sessionId: idB, cwd: other).map(\.path) == [otherFile.path])
        #expect(catalog.files(sessionId: idC, cwd: cwd).isEmpty)
        #expect(catalog.files(sessionId: "../\(idA)", cwd: cwd).isEmpty)
        _ = catalog.list(cwd: cwd)
        _ = catalog.lastPrompt(cwd: cwd, sessionId: idA)
        #expect(try modificationDates([jsonl, sibling, otherFile, jsonl.deletingLastPathComponent()]) == before)
        #expect(FileManager.default.fileExists(atPath: jsonl.path))
    }

    @Test func filesNeverFollowSymlinksOutOfTheProjectsDirectory() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let outside = try fx.makeDirectory("outside")
        // A transcript-looking file outside, linked into the folder.
        let victim = URL(fileURLWithPath: outside).appendingPathComponent("victim.jsonl")
        try (try F.user("victim", cwd: cwd).jsonData() + Data("\n".utf8)).write(to: victim)
        let folder = fx.projects.appendingPathComponent(TranscriptCatalog.folderName(for: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/\(idA).jsonl", withDestinationPath: victim.path)
        // A real transcript whose sibling folder is a link to a folder outside.
        try fx.write(idB, folderCwd: cwd, lines: [F.user("real", cwd: cwd)])
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/\(idB)", withDestinationPath: outside)
        let catalog = fx.catalog()
        #expect(catalog.files(sessionId: idA, cwd: cwd).isEmpty)
        #expect(catalog.files(sessionId: idB, cwd: cwd).map(\.lastPathComponent) == ["\(idB).jsonl"])
        #expect(catalog.list(cwd: cwd).map(\.id) == [idB]) // the link is not listed either

        // The whole slug folder linked outside the projects directory.
        let cwd2 = try fx.makeDirectory("proj2")
        let elsewhere = try fx.makeDirectory("elsewhere")
        try (try F.user("elsewhere", cwd: cwd2).jsonData() + Data("\n".utf8))
            .write(to: URL(fileURLWithPath: elsewhere).appendingPathComponent("\(idC).jsonl"))
        try FileManager.default.createSymbolicLink(
            atPath: fx.projects.path + "/" + TranscriptCatalog.folderName(for: cwd2), withDestinationPath: elsewhere)
        #expect(catalog.files(sessionId: idC, cwd: cwd2).isEmpty)
        #expect(FileManager.default.fileExists(atPath: victim.path))
    }

    func modificationDates(_ urls: [URL]) throws -> [Date] {
        try urls.map { url in
            try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        }
    }

    @Test(arguments: [
        (26.0, 30, Int?.some(4)), (10.0, 30, nil), (31.0, 30, 0), (25.0, 30, 5), (24.9, 30, nil), (26.9, 30, 4),
        (30.0, 30, 0), (29.99, 30, 1), (400.0, 30, 0), (-3.0, 30, nil), (3.0, 7, 4), (0.0, 1, 1), (5.0, 0, nil),
    ])
    func daysLeft(ageDays: Double, period: Int, expected: Int?) {
        let now = referenceNow
        let last = now.addingTimeInterval(-ageDays * 86_400)
        #expect(TranscriptRetention.daysLeft(lastActivity: last, now: now, cleanupPeriodDays: period) == expected)
    }

    @Test func daysLeftDefaults() {
        let last = referenceNow.addingTimeInterval(-26 * 86_400 - 3600)
        #expect(TranscriptRetention.daysLeft(lastActivity: last, now: referenceNow) == 4)
        #expect(TranscriptRetention.daysLeft(lastActivity: last, now: referenceNow, warnWithin: 3) == nil)
    }

    @Test func perfSixtyOneMegabyteTranscripts() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let filler = String(repeating: "tool output 工具輸出 ", count: 50) // ≈ 1.3 KB per line
        var lines: [JSONValue] = [F.user("prompt", cwd: cwd)]
        while lines.count < 760 { lines.append(F.assistant(cwd: cwd, text: filler)) }
        lines.append(F.aiTitle("AI 標題"))
        var data = Data()
        for line in lines {
            data.append(try line.jsonData())
            data.append(0x0A)
        }
        let now = Date()
        let folder = fx.projects.appendingPathComponent(TranscriptCatalog.folderName(for: cwd), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for n in 0..<60 {
            let file = folder.appendingPathComponent(String(format: "3f2a91c0-0000-4000-8000-%012d.jsonl", n))
            try data.write(to: file)
            try fx.setModified(file, now.addingTimeInterval(-Double(n)))
        }
        let size = try #require(try FileManager.default.attributesOfItem(
            atPath: fx.projects.path + "/" + TranscriptCatalog.folderName(for: cwd) + "/3f2a91c0-0000-4000-8000-000000000000.jsonl")[.size] as? Int)
        #expect(size > 1_000_000)
        let catalog = fx.catalog()
        let clock = ContinuousClock()
        var start = clock.now
        let cold = catalog.list(cwd: cwd, limit: 60)
        let coldTime = clock.now - start
        start = clock.now
        let warm = catalog.list(cwd: cwd, limit: 60)
        let warmTime = clock.now - start
        print("PERF transcript list, 60 × \(size / 1000) KB: cold \(coldTime), warm \(warmTime)")
        #expect(cold.count == 60)
        #expect(warm == cold)
        #expect(cold.allSatisfy { $0.title == "AI 標題" })
        #expect(coldTime < .seconds(5))
        #expect(warmTime < .milliseconds(200))
    }
}

@Suite("Claude user settings")
struct ClaudeUserSettingsTests {
    func read(_ text: String) throws -> ClaudeUserSettingsSummary {
        let temp = try TempDir("codd-claude-settings")
        defer { temp.remove() }
        let file = temp.file("settings.json")
        try Data(text.utf8).write(to: file)
        return ClaudeUserSettings.read(settingsFile: file)
    }

    @Test func validValues() throws {
        let s = try read(#"{"cleanupPeriodDays": 14, "model": " opus ", "hooks": {"Stop": []}, "permissions": {"defaultMode": "plan"}}"#)
        #expect(s == ClaudeUserSettingsSummary(cleanupPeriodDays: 14, model: "opus"))
    }

    @Test func missingFileAndDirectory() throws {
        let temp = try TempDir("codd-claude-settings")
        defer { temp.remove() }
        #expect(ClaudeUserSettings.read(settingsFile: temp.file("missing.json")) == ClaudeUserSettingsSummary())
        #expect(ClaudeUserSettings.read(settingsFile: temp.url) == ClaudeUserSettingsSummary())
        #expect(TranscriptRetention.cleanupPeriodDays(settingsFile: temp.file("missing.json")) == nil)
    }

    @Test(arguments: [
        (#"{"cleanupPeriodDays": "30"}"#, Int?.none), (#"{"cleanupPeriodDays": -1}"#, nil), (#"{"cleanupPeriodDays": 0}"#, nil),
        (#"{"cleanupPeriodDays": 7.5}"#, nil), (#"{"cleanupPeriodDays": 1}"#, 1), (#"{"cleanupPeriodDays": 365}"#, 365),
        (#"{"cleanupPeriodDays": null}"#, nil), ("[30]", nil), ("not json", nil), ("", nil),
    ])
    func cleanupPeriodDays(text: String, expected: Int?) throws {
        #expect(try read(text).cleanupPeriodDays == expected)
    }

    @Test(arguments: [
        (#"{"model": "claude-opus-5-5"}"#, String?.some("claude-opus-5-5")), (#"{"model": "opus[1m]"}"#, "opus[1m]"),
        (#"{"model": "claude opus"}"#, nil), (#"{"model": "-x"}"#, nil), (#"{"model": "  "}"#, nil), (#"{"model": 5}"#, nil),
        (#"{"model": "a\u0007b"}"#, nil), (#"{"env": {"model": "opus"}}"#, nil),
    ])
    func model(text: String, expected: String?) throws {
        #expect(try read(text).model == expected)
    }

    @Test func fileOverOneMebibyteIsIgnored() throws {
        let padding = String(repeating: " ", count: 1 << 20)
        #expect(try read(#"{"cleanupPeriodDays": 9, "model": "opus"}"# + padding) == ClaudeUserSettingsSummary())
        #expect(try read(#"{"cleanupPeriodDays": 9}"# + String(repeating: " ", count: (1 << 20) - 40)).cleanupPeriodDays == 9)
    }

    @Test func retentionDelegates() throws {
        let temp = try TempDir("codd-claude-settings")
        defer { temp.remove() }
        let file = temp.file("settings.json")
        try Data(#"{"cleanupPeriodDays": 60}"#.utf8).write(to: file)
        #expect(TranscriptRetention.cleanupPeriodDays(settingsFile: file) == 60)
    }
}

/// M2 review round 1: the list limit counts listed conversations (e2e-1), lookups by id, and the
/// whole prompt for D26 resends (correctness-1 / security-data-2).
@Suite("Transcript catalog (M2 review fixes)")
struct TranscriptCatalogReviewFixTests {
    typealias F = TranscriptFixture

    private static func sdkID(_ n: Int) -> String { String(format: "5d000000-0000-4000-8000-%012d", n) }

    @Test func newerSDKRunsNeverHideResumableConversations() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("lab")
        let now = Date()
        for (n, id) in [idA, idB, idC, idD].enumerated() {
            try fx.write(id, folderCwd: cwd, lines: [F.user(.string("對話 \(n)"), cwd: cwd)],
                         modified: now.addingTimeInterval(-3600 - Double(n)))
        }
        for n in 0..<60 {
            try fx.write(Self.sdkID(n), folderCwd: cwd, lines: [F.user(.string("run \(n)"), cwd: cwd, entrypoint: "sdk-cli")],
                         modified: now.addingTimeInterval(-Double(n)))
        }
        let catalog = fx.catalog()
        #expect(catalog.list(cwd: cwd, limit: 50).map(\.id) == [idA, idB, idC, idD], "the 60 newer sdk runs do not count")
        #expect(catalog.list(cwd: cwd, limit: 2).map(\.id) == [idA, idB])
        // The read bound keeps a huge folder cheap (then fewer may come back).
        let bounded = fx.catalog()
        #expect(bounded.list(cwd: cwd, limit: 3, readLimit: 10).isEmpty)
        #expect(bounded.fileReads == 10)
        #expect(catalog.list(cwd: cwd, limit: 70, includeSDK: true).count == 64)
    }

    @Test func transcriptByIdFindsAnOldConversation() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("lab")
        let now = Date()
        try fx.write(idA, folderCwd: cwd, lines: [F.user("舊的對話", cwd: cwd), F.customTitle("很久以前")],
                     modified: now.addingTimeInterval(-86_400))
        for n in 0..<60 {
            try fx.write(Self.sdkID(n), folderCwd: cwd, lines: [F.user(.string("p\(n)"), cwd: cwd)], modified: now.addingTimeInterval(-Double(n)))
        }
        let catalog = fx.catalog()
        let found = try #require(catalog.transcript(sessionId: idA, cwd: cwd))
        #expect(found.title == "很久以前" && found.titleSource == .custom)
        #expect(catalog.transcript(sessionId: idB, cwd: cwd) == nil)
        #expect(catalog.transcript(sessionId: "../\(idA)", cwd: cwd) == nil)
        let other = try fx.makeDirectory("other")
        #expect(catalog.transcript(sessionId: idA, cwd: other) == nil, "another folder's lines")
    }

    @Test func resendablePromptIsTheWholeNewestPrompt() throws {
        let fx = try F()
        defer { fx.remove() }
        let cwd = try fx.makeDirectory("proj")
        let head = String(repeating: "請把 auth middleware 在 token 過期時的處理改寫，", count: 10)
        let prompt = head + "\n第二行：\t保留縮排\n但是絕對不要刪 backups/ 和 db/ 底下的任何檔案。"
        #expect(prompt.count > 200)
        try fx.write(idA, folderCwd: cwd, lines: [
            F.user("較早的 prompt", cwd: cwd), F.assistant(cwd: cwd),
            F.user(.string("  " + prompt + "\n"), cwd: cwd),
            F.lastPrompt(String(prompt.prefix(120))),
            F.user([["type": "tool_result", "tool_use_id": "t", "content": "ok"]], cwd: cwd),
            F.user("[Request interrupted by user]", cwd: cwd), F.assistant(cwd: cwd),
        ])
        let catalog = fx.catalog()
        #expect(catalog.resendablePrompt(cwd: cwd, sessionId: idA) == prompt, "whole, newlines and TAB kept")
        #expect(catalog.lastPrompt(cwd: cwd, sessionId: idA)?.count ?? 0 <= 200, "the display form stays short")

        // Blocks: reminders are skipped; an image or a second typed block cannot be repeated.
        try fx.write(idB, folderCwd: cwd, lines: [
            F.user([["type": "text", "text": "<system-reminder>x</system-reminder>"], ["type": "text", "text": "只有這段"]], cwd: cwd),
        ])
        #expect(catalog.resendablePrompt(cwd: cwd, sessionId: idB) == "只有這段")
        try fx.write(idC, folderCwd: cwd, lines: [
            F.user("較早的", cwd: cwd),
            F.user([["type": "image", "source": ["type": "base64", "data": "AA=="]], ["type": "text", "text": "看這張圖"]], cwd: cwd),
        ])
        #expect(catalog.resendablePrompt(cwd: cwd, sessionId: idC) == nil, "never an older prompt instead")
        try fx.write(idD, folderCwd: cwd, lines: [F.user([["type": "text", "text": "一"], ["type": "text", "text": "二"]], cwd: cwd)])
        #expect(catalog.resendablePrompt(cwd: cwd, sessionId: idD) == nil)

        // A prompt line that starts before the window is never read in part.
        try fx.write(idE, folderCwd: cwd, lines: [
            F.user(.string(String(repeating: "長", count: 4000)), cwd: cwd), F.assistant(cwd: cwd, text: String(repeating: "x", count: 64)),
        ])
        #expect(catalog.resendablePrompt(cwd: cwd, sessionId: idE, window: 1024) == nil)
        #expect(catalog.resendablePrompt(cwd: cwd, sessionId: idE)?.count == 4000)
        #expect(catalog.resendablePrompt(cwd: try fx.makeDirectory("other"), sessionId: idA) == nil)
    }
}
