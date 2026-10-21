import Darwin
import Foundation
import Testing
@testable import CoddDataStore

@Suite("cache/VERSION, scan and aside files")
struct CacheAndScanTests {
    func fillCache(_ root: TempRoot) throws {
        try root.write("cache/notes-index.sqlite", "index")
        try root.write("cache/notes-index.sqlite-wal", "wal")
        try root.write("cache/annotated/abc-image.annotated.png", "png")
    }

    @Test func differentVersionWipesTheContentsAndKeepsTheFolder() throws {
        for found in ["0\n", "2", "abc", ""] {
            let root = try TempRoot()
            defer { root.remove() }
            try fillCache(root)
            try root.write("cache/VERSION", found)
            let logs = LogLines()
            let report = Fixture.preflight(root, log: logs).run()
            #expect(report.cacheWiped, "\(found)")
            #expect(report.status(of: "cache/VERSION") == .removed)
            #expect(root.names(in: "cache", prefix: "") == ["VERSION"])
            #expect(root.read("cache/VERSION") == Data("1\n".utf8))
            #expect(root.mode("cache/VERSION") == 0o600)
            #expect(report.issues.isEmpty)
            #expect(logs.all.contains { $0.hasPrefix("data removed file=cache/VERSION wiped found=") })
        }
    }

    @Test func missingVersionKeepsTheContentAndWritesOne() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try fillCache(root)
        let report = Fixture.preflight(root).run()
        #expect(!report.cacheWiped)
        #expect(report.status(of: "cache/VERSION") == .missing)
        #expect(root.read("cache/notes-index.sqlite") == Data("index".utf8))
        #expect(root.read("cache/annotated/abc-image.annotated.png") == Data("png".utf8))
        #expect(root.read("cache/VERSION") == Data("1\n".utf8))
        // Next launch: current, nothing touched.
        let again = Fixture.preflight(root).run()
        #expect(again.status(of: "cache/VERSION") == .current(1))
        #expect(root.read("cache/notes-index.sqlite") == Data("index".utf8))
    }

    @Test func missingCacheFolderIsCreatedPrivate() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "cache/VERSION") == .missing)
        #expect(root.mode("cache") == 0o700)
        #expect(root.read("cache/VERSION") == Data("1\n".utf8))
        let excluded = try URL(fileURLWithPath: root.path("cache")).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        #expect(excluded == true)
    }

    @Test func symlinkedCacheIsNeverWipedThrough() throws {
        let root = try TempRoot()
        let outside = try TempRoot("codd-datastore-outside")
        defer {
            root.remove()
            outside.remove()
        }
        try outside.write("precious.txt", "keep")
        try outside.write("VERSION", "0")
        try FileManager.default.createSymbolicLink(atPath: root.path("cache"), withDestinationPath: outside.url.path)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: "cache") == .skipped("symlink"))
        #expect(!report.cacheWiped)
        #expect(outside.read("precious.txt") == Data("keep".utf8))
        #expect(outside.read("VERSION") == Data("0".utf8))
    }

    @Test func scanChangesNothingOnDisk() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("layout.json", "not json")
        try root.write("quota.json", #"{"v":"x"}"#)
        try root.write("preferences.json", #"{"version":9}"#)
        try root.write("thing.json", #"{"v":1}"#)
        try fillCache(root)
        try root.write("cache/VERSION", "0")
        let before = root.snapshot()
        let step = MigrationStep(pattern: "thing.json", from: 1) { object in
            var out = object
            out["v"] = 2
            return out
        }
        let inventory = DataInventory.all + [DataFileSpec(pattern: "thing.json", versionKey: "v", currentVersion: 2, absentVersion: nil,
                                                          kind: .userData, corrupt: .moveAside)]
        let logs = LogLines()
        let report = DataPreflight(root: root.url, inventory: inventory, registry: MigrationRegistry([step]), now: { Fixture.now },
                                   log: logs.sink).scan()
        #expect(root.snapshot() == before)
        #expect(logs.all.isEmpty)
        #expect(report.status(of: "layout.json") == .corrupt(movedTo: nil))
        #expect(report.status(of: "quota.json") == .removed)
        #expect(report.status(of: "preferences.json") == .newer(9))
        #expect(report.status(of: "thing.json") == .migrated(from: 1, to: 2, backup: ""))
        #expect(report.status(of: "cache/VERSION") == .removed)
        #expect(report.cacheWiped)
        #expect(report.issues.map(\.file) == ["layout.json", "preferences.json"])
        #expect(report.issues.first?.message == "layout.json 無法讀取，改用預設值")
    }

    @Test func asideFilesFindsOnlyThisLaunchsMoves() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let launch = Fixture.now
        let before = DataPreflight.milliseconds(launch) - 1
        let after = DataPreflight.milliseconds(launch) + 250
        let session = "sessions/\(Fixture.session)"
        for name in ["layout.json.corrupt-\(before)", "preferences.json.corrupt-\(after)", "preferences.json.corrupt-\(after)-2",
                     "profiles.json.corrupt-\(DataPreflight.milliseconds(launch))", "foo.json.corrupt-\(after)",
                     "layout.json.corrupt-abc", "layout.json.corrupt-\(after).tmp",
                     "files/recent.json.corrupt-\(after)", "\(session)/composer.json.corrupt-\(after)",
                     "notes/.codd/state.json.corrupt-\(after)", "\(session)/answer.json.corrupt-\(before)"] {
            try root.write(name, "x")
        }
        try FileManager.default.createDirectory(atPath: root.path("cleanup.json.corrupt-\(after)"), withIntermediateDirectories: true)
        let found = Fixture.preflight(root).asideFiles(createdSince: launch)
        #expect(found == [
            "\(session)/composer.json.corrupt-\(after)", "files/recent.json.corrupt-\(after)",
            "notes/.codd/state.json.corrupt-\(after)", "preferences.json.corrupt-\(after)",
            "preferences.json.corrupt-\(after)-2", "profiles.json.corrupt-\(DataPreflight.milliseconds(launch))",
        ].sorted())
        // The banner each one gets after the stores loaded.
        let aside = "\(session)/composer.json.corrupt-\(after)"
        #expect(DataPreflight.corruptIssue(forAside: aside) == DataIssue(file: "\(session)/composer.json", kind: .corrupt, aside: aside))
        #expect(DataPreflight.corruptIssue(forAside: "preferences.json.corrupt-\(after)-2")?.message
            == "preferences.json 無法讀取，已移到 preferences.json.corrupt-\(after)-2，改用預設值")
        #expect(DataPreflight.corruptIssue(forAside: "layout.json") == nil)
        #expect(DataPreflight.corruptIssue(forAside: ".corrupt-\(after)") == nil)
    }

    @Test func preflightOverTwoHundredSessionsIsFast() throws {
        let root = try TempRoot()
        defer { root.remove() }
        for index in 0..<200 {
            let id = String(format: "%08x-1111-4a4a-8b8b-123456789abc", UInt32(index))
            var history: [String] = []
            for entry in 0..<20 { history.append("第 \(entry) 則：修正登入 API 401，然後跑一次測試") }
            let state: [String: Any] = ["draft": "草稿 \(index)", "history": ["entries": history], "v": 1]
            try root.write("sessions/\(id)/composer.json", try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]))
            if index % 4 == 0 { try root.write("sessions/\(id)/answer.json", #"{"tool":"Bash"}"#) }
            try root.write("hooks/\(id).json", #"{"state":"idle"}"#)
        }
        for (path, text) in Fixture.storeShapes where !path.hasPrefix("sessions/") && !path.hasPrefix("hooks/") {
            try root.write(path, text)
        }
        var timings: [Double] = []
        for _ in 0..<3 {
            let report = Fixture.preflight(root).run()
            #expect(report.files.filter { $0.status == .current(1) }.count >= 450)
            timings.append(report.milliseconds)
        }
        print("data preflight 200 sessions: ms=\(timings.map { String(format: "%.2f", $0) }.joined(separator: ","))")
        #expect(try #require(timings.min()) < 30)
    }
}
