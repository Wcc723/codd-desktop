import Foundation
import Testing
@testable import CoddComposer

@Suite("Composer state file")
struct ComposerStateFileTests {
    private func sample() -> ComposerState {
        var history = ComposerHistory()
        history.record("修正登入 API 401")
        history.record("第一行\n第二行")
        return ComposerState(draft: "還沒送出的草稿\n第二行", history: history)
    }

    @Test func roundTrips() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let state = sample()
        try ComposerStateFile.save(state, directory: dir.path)
        #expect(ComposerStateFile.load(directory: dir.path) == state)
    }

    @Test func writesTheDocumentedShape() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try ComposerStateFile.save(sample(), directory: dir.path)
        let data = try Data(contentsOf: URL(fileURLWithPath: dir.file(ComposerStateFile.name)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // M5 D14: the file carries its version (an M4 build ignores the extra key).
        #expect(object.keys.sorted() == ["draft", "history", "v"])
        #expect(object["v"] as? Int == ComposerStateFile.currentVersion)
        #expect(object["draft"] as? String == "還沒送出的草稿\n第二行")
        let history = try #require(object["history"] as? [String: Any])
        #expect(history.keys.sorted() == ["entries"])
        #expect(history["entries"] as? [String] == ["修正登入 API 401", "第一行\n第二行"])
    }

    @Test func fileIsOwnerOnlyAndNoTempFileIsLeft() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try ComposerStateFile.save(sample(), directory: dir.path)
        try ComposerStateFile.save(.empty, directory: dir.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.file(ComposerStateFile.name))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [ComposerStateFile.name])
        #expect(ComposerStateFile.load(directory: dir.path) == .empty)
    }

    @Test func missingFileLoadsEmpty() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        #expect(ComposerStateFile.load(directory: dir.path) == .empty)
        #expect(ComposerStateFile.load(directory: dir.file("no-such-session")) == .empty)
    }

    @Test(arguments: [
        "",
        "{",
        "not json",
        "[1, 2]",
        "{\"draft\": 42}",
        "{\"history\": {\"entries\": [1, 2]}}",
        "{\"history\": \"x\"}",
    ])
    func corruptFileLoadsEmpty(_ contents: String) throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try Data(contents.utf8).write(to: URL(fileURLWithPath: dir.file(ComposerStateFile.name)))
        #expect(ComposerStateFile.load(directory: dir.path) == .empty)
    }

    @Test func missingKeysReadAsEmpty() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let url = URL(fileURLWithPath: dir.file(ComposerStateFile.name))
        try Data("{\"draft\": \"only a draft\"}".utf8).write(to: url)
        #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(draft: "only a draft"))
        try Data("{\"history\": {\"entries\": [\"a\"]}, \"future\": true}".utf8).write(to: url)
        #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(history: ComposerHistory(entries: ["a"])))
    }

    @Test func saveIntoARemovedSessionIsANoOp() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let gone = dir.file("removed-session")
        try ComposerStateFile.save(sample(), directory: gone)
        #expect(!FileManager.default.fileExists(atPath: gone))
        // A file where the directory should be is not written through either.
        try Data().write(to: URL(fileURLWithPath: gone))
        try ComposerStateFile.save(sample(), directory: gone)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["removed-session"])
    }

    @Test func capsEntriesAndDraft() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let longEntry = String(repeating: "a", count: ComposerStateFile.historyEntryMaxBytes + 100)
        // 3-byte characters: the cap falls inside one, which must not be split.
        let cjkEntry = String(repeating: "注", count: ComposerStateFile.historyEntryMaxBytes / 3 + 10)
        let draft = String(repeating: "b", count: ComposerEncoding.maxBytes + 5)
        let state = ComposerState(draft: draft, history: ComposerHistory(entries: [longEntry, cjkEntry, "short"]))
        try ComposerStateFile.save(state, directory: dir.path)
        let loaded = ComposerStateFile.load(directory: dir.path)
        #expect(loaded.draft.utf8.count == ComposerEncoding.maxBytes)
        #expect(loaded.history.entries.count == 3)
        #expect(loaded.history.entries[0].utf8.count == ComposerStateFile.historyEntryMaxBytes)
        let cjk = loaded.history.entries[1]
        #expect(cjk.utf8.count <= ComposerStateFile.historyEntryMaxBytes)
        #expect(cjk.utf8.count > ComposerStateFile.historyEntryMaxBytes - 3)
        #expect(cjk.allSatisfy { $0 == "注" })
        #expect(loaded.history.entries[2] == "short")
    }

    @Test func replacesAnExistingFile() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try ComposerStateFile.save(sample(), directory: dir.path)
        let next = ComposerState(draft: "新的", history: ComposerHistory(entries: ["x"]))
        try ComposerStateFile.save(next, directory: dir.path)
        #expect(ComposerStateFile.load(directory: dir.path) == next)
    }
}
