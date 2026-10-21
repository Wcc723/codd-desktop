import Foundation
import Testing
@testable import CoddFiles

@Suite("OpenFileState")
struct OpenFileStateTests {
    let t0 = Date(timeIntervalSince1970: 1_792_000_000)

    private func open(_ text: String, in dir: TempDir) throws -> (URL, OpenFileState) {
        let file = try dir.write("punch.vue", text)
        return (file, try OpenFileState.load(file, at: t0))
    }

    /// Writes `text` to `file` and returns what the watcher path would hand the state.
    private func external(_ text: String, to file: URL) throws -> (Data, FileFingerprint) {
        try Data(text.utf8).write(to: file)
        return try FileFingerprint.read(file)
    }

    @Test func loadReadsTheFacts() throws {
        let dir = TempDir()
        let (_, state) = try open("<style>\r\n  .a { }\r\n</style>\r\n", in: dir)
        #expect(state.decoded.encoding == .utf8)
        #expect(state.decoded.lineEnding == .crlf)
        #expect(state.decoded.indentation == .spaces(2))
        #expect(state.buffer == "<style>\n  .a { }\n</style>")
        #expect(!state.isDirty && !state.showsBanner)
        #expect(state.savedAt == t0)
        let binary = try dir.write("img.png", Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00]))
        #expect(throws: TextFileError.binary) { try OpenFileState.load(binary) }
    }

    @Test func aCleanTabReloadsInPlace() throws {
        let dir = TempDir()
        var (file, state) = try open("a\nb\n", in: dir)
        let (data, fingerprint) = try external("a\nb\nc\n", to: file)
        let t1 = t0.addingTimeInterval(60)
        #expect(state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: nil, now: t1) == .reloaded)
        #expect(state.buffer == "a\nb\nc" && state.savedText == "a\nb\nc")
        #expect(state.disk == fingerprint && state.savedAt == t1)
        #expect(state.aiBaseline == nil)
        // The same bytes again (our own save, a touch): nothing.
        #expect(state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: nil) == .none)
    }

    @Test func anAIChangeToACleanTabKeepsTheBaseline() throws {
        let dir = TempDir()
        var (file, state) = try open("position: fixed;\n", in: dir)
        let (data, fingerprint) = try external("position: sticky;\n", to: file)
        let at = t0.addingTimeInterval(30)
        #expect(state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: (session: "s9", at: at)) == .reloaded)
        #expect(state.aiBaseline?.text == "position: fixed;")
        #expect(state.aiBaseline?.session == "s9" && state.aiBaseline?.at == at)
        // A second change by the same session keeps the first baseline ("AI 開始前").
        let (data2, fingerprint2) = try external("position: sticky;\nbottom: 0;\n", to: file)
        _ = state.diskChanged(newData: data2, fingerprint: fingerprint2, aiTouch: (session: "s9", at: at.addingTimeInterval(5)))
        #expect(state.aiBaseline?.text == "position: fixed;")
        #expect(state.aiBaseline?.at == at)
    }

    @Test func aDirtyTabGetsTheBannerWithAndWithoutAnAITouch() throws {
        let dir = TempDir()
        var (file, state) = try open("one\n", in: dir)
        state.edit("one\nmine")
        #expect(state.isDirty)
        let (data, fingerprint) = try external("one\ntheirs\n", to: file)
        let now = t0.addingTimeInterval(10)
        #expect(state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: nil, now: now) == .banner(aiSession: nil, at: now))
        #expect(state.showsBanner && state.canReload)
        #expect(state.buffer == "one\nmine", "the edits stay")
        #expect(state.pendingDisk?.decoded?.text == "one\ntheirs")
        #expect(state.aiBaseline == nil)

        let otherDir = TempDir()
        var (file2, other) = try open("x\n", in: otherDir)
        other.edit("x\ny")
        let (data2, fingerprint2) = try external("x\nai\n", to: file2)
        let at = t0.addingTimeInterval(41)
        #expect(other.diskChanged(newData: data2, fingerprint: fingerprint2, aiTouch: (session: "打卡頁 RWD 調整", at: at))
                == .banner(aiSession: "打卡頁 RWD 調整", at: at))
        #expect(other.aiBaseline?.text == "x")
    }

    @Test func keepMineThenSaveOverwritesOnPurpose() throws {
        let dir = TempDir()
        var (file, state) = try open("base\n", in: dir)
        state.edit("base\nmine")
        let (data, fingerprint) = try external("base\ntheirs\n", to: file)
        _ = state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: nil)
        // Before 保留我的 the save is refused (the disk changed since the load).
        let loadedFingerprint = state.disk
        #expect(throws: FileSaveError.self) {
            try FileSaver.save(try state.encodedBuffer(), to: file, expected: loadedFingerprint, force: false)
        }
        state.keepMine(now: t0.addingTimeInterval(20))
        #expect(!state.showsBanner)
        #expect(state.buffer == "base\nmine" && state.isDirty)
        #expect(state.disk == fingerprint)
        let written = try FileSaver.save(try state.encodedBuffer(), to: file, expected: state.disk, force: false)
        state.saved(written, at: t0.addingTimeInterval(21))
        #expect(!state.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "base\nmine\n")
    }

    @Test func reloadFromDiskDropsTheEdits() throws {
        let dir = TempDir()
        var (file, state) = try open("a\n", in: dir)
        state.edit("a\nb")
        let (data, fingerprint) = try external("z\n", to: file)
        _ = state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: nil)
        state.reloadFromDisk()
        #expect(state.buffer == "z" && !state.isDirty && !state.showsBanner && state.disk == fingerprint)
    }

    @Test func aDiskChangeBackToTheBaseClearsTheBanner() throws {
        let dir = TempDir()
        var (file, state) = try open("a\n", in: dir)
        state.edit("a\nb")
        let (data, fingerprint) = try external("other\n", to: file)
        _ = state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: nil)
        #expect(state.showsBanner)
        let (back, backPrint) = try external("a\n", to: file)
        #expect(state.diskChanged(newData: back, fingerprint: backPrint, aiTouch: nil) == .none)
        #expect(!state.showsBanner && state.isDirty)
    }

    /// M4 fix: keystrokes while ⌘S writes are not marked saved (the written text is the base).
    @Test func textTypedDuringTheWriteStaysDirty() throws {
        let dir = TempDir()
        var (file, state) = try open("a\n", in: dir)
        state.edit("a\nb")
        let writtenText = state.buffer
        let written = try FileSaver.save(try state.encodedBuffer(), to: file, expected: state.disk, force: false)
        state.edit("a\nbc")
        state.saved(written, at: t0, text: writtenText)
        #expect(state.isDirty && state.savedText == "a\nb" && state.buffer == "a\nbc")
        #expect(state.decoded.text == "a\nb" && state.disk == written)
        // The next save starts from the first one's fingerprint.
        let second = try FileSaver.save(try state.encodedBuffer(), to: file, expected: state.disk, force: false)
        state.saved(second, at: t0)
        #expect(!state.isDirty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "a\nbc\n")
    }

    @Test func savedFollowsTheWrittenEndingsOfAMixedFile() throws {
        let dir = TempDir()
        var (file, state) = try open("a\r\nb\nc\r\n", in: dir)
        state.edit("a\nb\nnew\nc")
        let written = try FileSaver.save(try state.encodedBuffer(), to: file, expected: state.disk, force: false)
        state.saved(written, at: t0)
        #expect(try Data(contentsOf: file) == Data("a\r\nb\nnew\r\nc\r\n".utf8))
        #expect(state.decoded.lineEndings == [.crlf, .lf, .crlf, .crlf])
        // A second save of the same buffer writes the same bytes.
        #expect(try state.encodedBuffer() == Data("a\r\nb\nnew\r\nc\r\n".utf8))
    }

    @Test func aBinaryDiskVersionCannotBeReloaded() throws {
        let dir = TempDir()
        var (file, state) = try open("text\n", in: dir)
        state.edit("text!")
        try Data([0, 1, 2]).write(to: file)
        let (data, fingerprint) = try FileFingerprint.read(file)
        _ = state.diskChanged(newData: data, fingerprint: fingerprint, aiTouch: nil)
        #expect(state.showsBanner && !state.canReload)
        state.reloadFromDisk()
        #expect(state.buffer == "text!", "nothing to reload into")
    }
}
