import Foundation
import Testing
@testable import CoddComposer

/// M5 D14: composer.json carries `"v":1`; a file without it is version 1; a newer CODD's file is
/// read as far as possible and never saved over.
@Suite("Composer state file versions")
struct ComposerStateVersionTests {
    private func url(_ dir: TempDirectory) -> URL {
        URL(fileURLWithPath: dir.file(ComposerStateFile.name))
    }

    @Test func saveWritesVersionOneBesideTheMembers() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try ComposerStateFile.save(ComposerState(draft: "草稿", history: ComposerHistory(entries: ["a"])), directory: dir.path)
        let text = try String(contentsOf: url(dir), encoding: .utf8)
        #expect(text == #"{"draft":"草稿","history":{"entries":["a"]},"v":1}"#)
        #expect(ComposerStateFile.storedVersion(directory: dir.path) == 1)
    }

    @Test func m4FileWithoutVersionLoadsAndIsReplaced() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        try Data(#"{"draft":"舊的","history":{"entries":["x"]}}"#.utf8).write(to: url(dir))
        #expect(ComposerStateFile.storedVersion(directory: dir.path) == nil)
        #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(draft: "舊的", history: ComposerHistory(entries: ["x"])))
        try ComposerStateFile.save(ComposerState(draft: "新的"), directory: dir.path)
        #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(draft: "新的"))
        #expect(ComposerStateFile.storedVersion(directory: dir.path) == 1)
    }

    @Test func unusableVersionCountsAsOne() throws {
        for version in [#""2""#, "0", "true", "1.5"] {
            let dir = try TempDirectory()
            defer { dir.remove() }
            try Data(#"{"draft":"x","v":\#(version)}"#.utf8).write(to: url(dir))
            #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(draft: "x"), "\(version)")
            try ComposerStateFile.save(ComposerState(draft: "y"), directory: dir.path)
            #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(draft: "y"), "\(version)")
        }
    }

    @Test func newerFileIsReadAndNeverReplaced() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        let newer = Data(#"{"draft":"新版的草稿","history":{"entries":["h1"]},"pinned":[1],"v":2}"#.utf8)
        try newer.write(to: url(dir))
        #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(draft: "新版的草稿", history: ComposerHistory(entries: ["h1"])))
        #expect(ComposerStateFile.storedVersion(directory: dir.path) == 2)
        #expect(throws: ComposerStateFileError.newerVersion(2)) {
            try ComposerStateFile.save(ComposerState(draft: "舊版的修改"), directory: dir.path)
        }
        #expect(throws: ComposerStateFileError.newerVersion(2)) {
            try ComposerStateFile.save(.empty, directory: dir.path)
        }
        #expect(try Data(contentsOf: url(dir)) == newer)
        // No temp file left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [ComposerStateFile.name])
    }

    @Test func newerFileKeepsWhateverStillDecodes() throws {
        let dir = try TempDirectory()
        defer { dir.remove() }
        // The newer format changed `history`; the draft still reads.
        try Data(#"{"draft":"留著","history":{"entries":[{"text":"x"}]},"v":3}"#.utf8).write(to: url(dir))
        #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(draft: "留著"))
        try Data(#"{"draft":42,"history":{"entries":["h"]},"v":3}"#.utf8).write(to: url(dir))
        #expect(ComposerStateFile.load(directory: dir.path) == ComposerState(history: ComposerHistory(entries: ["h"])))
        // A version-1 file of the same shape is still corrupt (M2 behaviour).
        try Data(#"{"draft":42,"history":{"entries":["h"]},"v":1}"#.utf8).write(to: url(dir))
        #expect(ComposerStateFile.load(directory: dir.path) == .empty)
    }
}
