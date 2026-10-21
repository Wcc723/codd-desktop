import Foundation
import Testing
@testable import CoddDataStore

/// Every inventory row through the same cases: missing, current, absent / non-integer / below-one
/// version, newer, corrupt (by its policy).
@Suite("Data inventory rows")
struct InventoryTests {
    static let jsonRows = DataInventory.all.filter { $0.corrupt != .wipe }

    @Test func inventoryListsTheDocumentedFiles() {
        let patterns = Set(DataInventory.all.map(\.pattern))
        #expect(patterns == [
            "layout.json", "panes.json", "preferences.json", "profiles.json", "cleanup.json", "claude-settings-backups.json",
            "files/recent.json", "files/ai-touches.json", "onboarding.json", "sessions/*/composer.json",
            "notes/.codd/notebook.json", "notes/.codd/state.json", "notes/.codd/tombstones.json", "config.json",
            "quota.json", "hooks/*.json", "sessions/*/answer.json", "cache/VERSION",
        ])
        #expect(DataInventory.all.count == patterns.count)
        #expect(MigrationRegistry.standard.steps.isEmpty)
        #expect(Fixture.spec("config.json").corrupt == .report)
        #expect(Fixture.spec("quota.json").kind == .derived && Fixture.spec("quota.json").corrupt == .remove)
        #expect(Fixture.spec("cache/VERSION").corrupt == .wipe)
    }

    @Test(arguments: jsonRows)
    func missingFile(_ spec: DataFileSpec) throws {
        let root = try TempRoot()
        defer { root.remove() }
        // The folders a pattern walks through exist, the file does not.
        let path = Fixture.path(for: spec.pattern)
        try FileManager.default.createDirectory(atPath: (root.path(path) as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let report = Fixture.preflight(root).run()
        if spec.isLiteral {
            #expect(report.status(of: path) == .missing)
        } else {
            #expect(report.status(of: path) == nil)
        }
        #expect(report.issues.isEmpty)
        #expect(!root.exists(path))
    }

    @Test(arguments: jsonRows)
    func currentVersionStaysAsItIs(_ spec: DataFileSpec) throws {
        let root = try TempRoot()
        defer { root.remove() }
        let path = Fixture.path(for: spec.pattern)
        let text = Fixture.object(key: spec.versionKey, version: "1")
        try root.write(path, text)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: path) == .current(1))
        #expect(report.issues.isEmpty)
        #expect(root.read(path) == Data(text.utf8))
    }

    @Test(arguments: jsonRows)
    func absentOrUnusableVersionFollowsTheStore(_ spec: DataFileSpec) throws {
        guard let key = spec.versionKey else { return }
        for (label, text) in [("missing", Fixture.object(key: nil, version: nil)),
                              ("string", Fixture.object(key: key, version: #""1""#)),
                              ("fraction", Fixture.object(key: key, version: "1.5")),
                              ("boolean", Fixture.object(key: key, version: "true")),
                              ("null", Fixture.object(key: key, version: "null"))] {
            let root = try TempRoot()
            defer { root.remove() }
            let path = Fixture.path(for: spec.pattern)
            try root.write(path, text)
            let report = Fixture.preflight(root).run()
            if let absent = spec.absentVersion {
                #expect(report.status(of: path) == .current(absent), "\(spec.pattern) \(label)")
                #expect(root.read(path) == Data(text.utf8), "\(spec.pattern) \(label)")
            } else {
                try expectCorruptHandled(spec, path: path, original: Data(text.utf8), report: report, root: root)
            }
        }
    }

    @Test(arguments: jsonRows)
    func versionBelowOneFollowsTheStore(_ spec: DataFileSpec) throws {
        guard let key = spec.versionKey else { return }
        for version in ["0", "-3"] {
            let root = try TempRoot()
            defer { root.remove() }
            let path = Fixture.path(for: spec.pattern)
            let text = Fixture.object(key: key, version: version)
            try root.write(path, text)
            let report = Fixture.preflight(root).run()
            if let reads = spec.belowOneVersion ?? spec.absentVersion {
                #expect(report.status(of: path) == .current(reads), "\(spec.pattern) v=\(version)")
                #expect(root.read(path) == Data(text.utf8))
            } else {
                try expectCorruptHandled(spec, path: path, original: Data(text.utf8), report: report, root: root)
            }
        }
    }

    @Test(arguments: jsonRows)
    func newerVersionIsLeftAloneAndReported(_ spec: DataFileSpec) throws {
        guard let key = spec.versionKey else { return }
        let root = try TempRoot()
        defer { root.remove() }
        let path = Fixture.path(for: spec.pattern)
        let text = Fixture.object(key: key, version: "2")
        try root.write(path, text)
        let report = Fixture.preflight(root).run()
        #expect(report.status(of: path) == .newer(2))
        #expect(report.issues == [DataIssue(file: path, kind: .newer, version: 2)])
        #expect(report.issues.first?.message == "\(path) 是較新版本的 CODD 寫的（v2）：能讀的部分照用，這次的變更不會存進這個檔案")
        #expect(root.read(path) == Data(text.utf8))
    }

    @Test(arguments: jsonRows)
    func notAJSONObjectFollowsTheCorruptPolicy(_ spec: DataFileSpec) throws {
        for text in [#"{"v":1,"#, "[1,2]", "", "\u{FF}\u{FE}garbage"] {
            let root = try TempRoot()
            defer { root.remove() }
            let path = Fixture.path(for: spec.pattern)
            try root.write(path, text)
            let report = Fixture.preflight(root).run()
            try expectCorruptHandled(spec, path: path, original: Data(text.utf8), report: report, root: root)
        }
    }

    /// The row's corrupt policy was applied: moved aside with the same bytes and one banner,
    /// removed, or reported and left untouched.
    private func expectCorruptHandled(_ spec: DataFileSpec, path: String, original: Data, report: DataPreflightReport,
                                      root: TempRoot) throws {
        switch spec.corrupt {
        case .moveAside:
            let folder = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let ms = DataPreflight.milliseconds(Fixture.now)
            let aside = (folder.isEmpty ? "" : folder + "/") + "\(name).corrupt-\(ms)"
            #expect(report.status(of: path) == .corrupt(movedTo: aside), "\(path)")
            #expect(!root.exists(path))
            #expect(root.read(aside) == original)
            #expect(report.issues == [DataIssue(file: path, kind: .corrupt, aside: aside)])
            #expect(report.issues.first?.message == "\(path) 無法讀取，已移到 \(name).corrupt-\(ms)，改用預設值")
        case .remove:
            #expect(report.status(of: path) == .removed, "\(path)")
            #expect(!root.exists(path))
            #expect(report.issues.isEmpty)
        case .report:
            #expect(report.status(of: path) == .corrupt(movedTo: nil), "\(path)")
            #expect(root.read(path) == original)
            #expect(report.issues.isEmpty)
        case .wipe:
            Issue.record("not a JSON row")
        }
    }
}
