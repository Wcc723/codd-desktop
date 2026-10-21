import Darwin
import Foundation
import Testing
@testable import CoddDataStore

/// D14's safety rule: a file its store would load without moving it aside is never moved,
/// removed or rewritten by the preflight; symlinks, non-regular, large and unreadable files are
/// left alone.
@Suite("Preflight never stricter than the stores")
struct NeverStricterTests {
    @Test func everyStoreShapeScansCurrentAndRunLeavesItAlone() throws {
        let root = try TempRoot()
        defer { root.remove() }
        for (path, text) in Fixture.storeShapes { try root.write(path, text) }
        try root.write("cache/VERSION", "1\n")
        let before = root.snapshot()
        let scan = Fixture.preflight(root).scan()
        for path in Fixture.storeShapes.keys {
            #expect(scan.status(of: path) == .current(1), "\(path)")
        }
        #expect(scan.status(of: "cache/VERSION") == .current(1))
        #expect(scan.issues.isEmpty)
        let run = Fixture.preflight(root).run()
        #expect(run.files == scan.files)
        #expect(run.issues.isEmpty && !run.cacheWiped)
        #expect(root.snapshot() == before)
    }

    @Test func preferencesWithoutAUsableVersionStayInPlace() throws {
        for text in [#"{"version":"1","general":{}}"#, #"{"general":{}}"#, #"{"version":0}"#] {
            let root = try TempRoot()
            defer { root.remove() }
            try root.write("preferences.json", text)
            let report = Fixture.preflight(root).run()
            #expect(report.status(of: "preferences.json") == .current(1), "\(text)")
            #expect(root.read("preferences.json") == Data(text.utf8))
            #expect(root.names(prefix: "preferences.json.corrupt").isEmpty)
        }
    }

    @Test func layoutWithoutVersionIsCorruptLikeLayoutStore() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("layout.json", #"{"groups":[]}"#)
        let report = Fixture.preflight(root).run()
        let aside = "layout.json.corrupt-\(DataPreflight.milliseconds(Fixture.now))"
        #expect(report.status(of: "layout.json") == .corrupt(movedTo: aside))
        #expect(root.read(aside) == Data(#"{"groups":[]}"#.utf8))
        #expect(report.issues.map(\.kind) == [.corrupt])
    }

    @Test func m4ComposerFileWithoutVersionReadsAsVersionOne() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let path = "sessions/\(Fixture.session)/composer.json"
        let text = #"{"draft":"草稿","history":{"entries":[]}}"#
        try root.write(path, text)
        #expect(Fixture.preflight(root).run().status(of: path) == .current(1))
        #expect(root.read(path) == Data(text.utf8))
    }

    @Test func storesThatAcceptVersionZeroKeepTheirFile() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("panes.json", #"{"version":0,"sessions":{}}"#)
        try root.write("files/recent.json", #"{"v":0,"items":[]}"#)
        try root.write("profiles.json", #"{"version":0,"profiles":[]}"#)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "panes.json") == .current(1))
        #expect(report.status(of: "files/recent.json") == .current(1))
        // LaunchProfileStore rejects `version < 1`.
        if case .corrupt(let aside?) = report.status(of: "profiles.json") {
            #expect(aside.hasPrefix("profiles.json.corrupt-"))
        } else {
            Issue.record("profiles.json v0 should be moved aside")
        }
    }

    @Test func wholeNumbersWrittenAsFractionsAreIntegers() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("layout.json", #"{"version":1.0,"groups":[]}"#)
        try root.write("quota.json", #"{"v":1e0}"#)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "layout.json") == .current(1))
        #expect(report.status(of: "quota.json") == .current(1))
    }

    @Test func documentsOnlyCoddCoreAcceptsAreNotCorrupt() throws {
        let root = try TempRoot()
        defer { root.remove() }
        // JSONValue.parse repairs an unpaired surrogate escape and prunes deep nesting, so
        // LayoutStore sees a newer version here (read only) rather than a corrupt file.
        let surrogate = #"{"version":2,"title":"\ud83d"}"#
        let deep = #"{"v":2,"x":"# + String(repeating: "[", count: 600) + String(repeating: "]", count: 600) + "}"
        try root.write("layout.json", surrogate)
        try root.write("quota.json", deep)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "layout.json") == .newer(2))
        #expect(report.status(of: "quota.json") == .newer(2))
        #expect(root.read("layout.json") == Data(surrogate.utf8))
        #expect(root.read("quota.json") == Data(deep.utf8))
    }

    @Test func configJSONIsReportOnly() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("config.json", "not json")
        let logs = LogLines()
        let report = Fixture.preflight(root, log: logs).run()
        #expect(report.status(of: "config.json") == .corrupt(movedTo: nil))
        #expect(report.issues.isEmpty)
        #expect(root.read("config.json") == Data("not json".utf8))
        #expect(logs.all.contains("data corrupt file=config.json not-an-object kept=report-only"))
    }

    @Test func symlinkedFileIsSkippedAndItsTargetUntouched() throws {
        let root = try TempRoot()
        let outside = try TempRoot("codd-datastore-outside")
        defer {
            root.remove()
            outside.remove()
        }
        let target = try outside.write("elsewhere.json", "not json")
        try FileManager.default.createSymbolicLink(atPath: root.path("layout.json"), withDestinationPath: target)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "layout.json") == .skipped("symlink"))
        #expect(outside.read("elsewhere.json") == Data("not json".utf8))
        #expect(root.exists("layout.json"))
        #expect(report.issues.isEmpty)
    }

    @Test func symlinkedFolderIsNeverEntered() throws {
        let root = try TempRoot()
        let outside = try TempRoot("codd-datastore-outside")
        defer {
            root.remove()
            outside.remove()
        }
        try outside.write(".codd/state.json", "not json")
        try FileManager.default.createSymbolicLink(atPath: root.path("notes"), withDestinationPath: outside.url.path)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "notes") == .skipped("symlink"))
        #expect(outside.read(".codd/state.json") == Data("not json".utf8))
        #expect(outside.names(in: ".codd", prefix: "state.json.corrupt").isEmpty)
    }

    @Test func symlinkedDataRootIsResolved() throws {
        let real = try TempRoot()
        let parent = try TempRoot("codd-datastore-link")
        defer {
            real.remove()
            parent.remove()
        }
        try real.write("layout.json", Fixture.storeShapes["layout.json"]!)
        let link = parent.path("root")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real.url.path)
        let report = DataPreflight(root: URL(fileURLWithPath: link), now: { Fixture.now }).run()
        #expect(report.status(of: "layout.json") == .current(1))
    }

    @Test func largeFileIsSkipped() throws {
        let root = try TempRoot()
        defer { root.remove() }
        // Sparse: 16 MiB + 1 byte without writing them.
        let path = root.path("layout.json")
        #expect(FileManager.default.createFile(atPath: path, contents: nil))
        let fd = open(path, O_WRONLY)
        #expect(fd >= 0)
        #expect(ftruncate(fd, off_t(DataPreflight.maxFileBytes + 1)) == 0)
        close(fd)
        let report = Fixture.preflight(root).run()
        guard case .skipped(let reason) = report.status(of: "layout.json") else {
            Issue.record("expected skipped, got \(String(describing: report.status(of: "layout.json")))")
            return
        }
        #expect(reason.hasPrefix("larger than"))
        #expect(root.exists("layout.json"))
        // The limit is a parameter: a small one skips a small corrupt file the same way.
        try root.write("cleanup.json", "not json")
        let small = Fixture.preflight(root, maxFileBytes: 4).run()
        #expect(small.status(of: "cleanup.json") == .skipped("larger than 4 bytes"))
        #expect(root.read("cleanup.json") == Data("not json".utf8))
    }

    @Test func unreadableFileIsNotCorrupt() throws {
        guard getuid() != 0 else { return }
        let root = try TempRoot()
        defer {
            chmod(root.path("layout.json"), 0o600)
            root.remove()
        }
        try root.write("layout.json", "not json", mode: 0o000)
        let report = Fixture.preflight(root).run()
        guard case .skipped(let reason) = report.status(of: "layout.json") else {
            Issue.record("expected skipped, got \(String(describing: report.status(of: "layout.json")))")
            return
        }
        #expect(reason.hasPrefix("unreadable errno="))
        #expect(root.exists("layout.json"))
        #expect(root.names(prefix: "layout.json.corrupt").isEmpty)
        #expect(report.issues.isEmpty)
    }

    @Test func fifoIsSkippedWithoutBlocking() throws {
        let root = try TempRoot()
        defer { root.remove() }
        #expect(mkfifo(root.path("panes.json"), 0o600) == 0)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "panes.json") == .skipped("not a regular file"))
        #expect(root.exists("panes.json"))
    }

    @Test func missingDataRootChangesNothing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("codd-datastore-none-\(UUID().uuidString)")
        let logs = LogLines()
        let report = DataPreflight(root: missing, log: logs.sink).run()
        #expect(report.files.isEmpty && report.issues.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(logs.all == ["data preflight skipped reason=no-data-root"])
    }

    @Test func logsNameFilesNeverContents() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let secret = "sk-secret-0123456789"
        try root.write("layout.json", #"{"groups":"\#(secret)""#)
        try root.write("preferences.json", #"{"version":7,"token":"\#(secret)"}"#)
        try root.write("hooks/\(Fixture.session).json", "[\"\(secret)\"]")
        let logs = LogLines()
        let report = Fixture.preflight(root, log: logs).run()
        #expect(!logs.all.joined(separator: "\n").contains(secret))
        let ms = DataPreflight.milliseconds(Fixture.now)
        #expect(logs.all.contains("data corrupt file=layout.json not-an-object moved=layout.json.corrupt-\(ms)"))
        #expect(logs.all.contains("data newer file=preferences.json v=7"))
        #expect(logs.all.contains("data removed file=hooks/\(Fixture.session).json not-an-object"))
        let summary = try #require(logs.all.last)
        #expect(summary.hasPrefix("data preflight files=3 current=0 migrated=0 newer=1 corrupt=1 removed=1 ms="))
        #expect(summary == report.summaryLine)
    }
}
