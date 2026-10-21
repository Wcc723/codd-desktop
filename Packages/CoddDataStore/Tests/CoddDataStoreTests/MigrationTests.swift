import Foundation
import Testing
@testable import CoddDataStore

/// The registry with synthetic steps (none is registered at M5).
@Suite("Migrations")
struct MigrationTests {
    /// A made-up USER DATA file at version 3.
    static let thing = DataFileSpec(pattern: "thing.json", versionKey: "v", currentVersion: 3, absentVersion: nil,
                                    kind: .userData, corrupt: .moveAside)

    struct StepFailure: Error {}

    static let toTwo = MigrationStep(pattern: "thing.json", from: 1) { object in
        var out = object
        out["name"] = out.removeValue(forKey: "title")
        out["v"] = 2
        return out
    }

    static let toThree = MigrationStep(pattern: "thing.json", from: 2) { object in
        var out = object
        out["tags"] = ["migrated"]
        out["v"] = 3
        return out
    }

    func preflight(_ root: TempRoot, _ steps: [MigrationStep], now: Date = Fixture.now) -> DataPreflight {
        DataPreflight(root: root.url, inventory: [Self.thing], registry: MigrationRegistry(steps), now: { now })
    }

    func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    @Test func chainFindsEveryStepOrNone() {
        let registry = MigrationRegistry([Self.toThree, Self.toTwo])
        #expect(registry.chain(pattern: "thing.json", from: 1, to: 3)?.map(\.from) == [1, 2])
        #expect(registry.chain(pattern: "thing.json", from: 2, to: 3)?.map(\.from) == [2])
        #expect(registry.chain(pattern: "thing.json", from: 3, to: 3)?.isEmpty == true)
        #expect(registry.chain(pattern: "thing.json", from: 0, to: 3) == nil)
        #expect(registry.chain(pattern: "other.json", from: 1, to: 3) == nil)
    }

    @Test func migratesThroughEveryStepAfterOneBackup() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let original = #"{"title":"舊名稱","v":1}"#
        try root.write("thing.json", original, mode: 0o640)
        let report = preflight(root, [Self.toTwo, Self.toThree]).run()
        let backup = "thing.json.v1-backup-\(stamp(Fixture.now))"
        #expect(report.status(of: "thing.json") == .migrated(from: 1, to: 3, backup: backup))
        #expect(report.issues.isEmpty)
        // One backup, the original bytes, 0600.
        #expect(root.names(prefix: "thing.json.v") == [backup])
        #expect(root.read(backup) == Data(original.utf8))
        #expect(root.mode(backup) == 0o600)
        // Migrated content, version set, mode kept.
        let object = try root.jsonObject("thing.json")
        #expect(object["v"] as? Int == 3)
        #expect(object["name"] as? String == "舊名稱")
        #expect(object["title"] == nil)
        #expect(object["tags"] as? [String] == ["migrated"])
        #expect(root.mode("thing.json") == 0o640)
        // No temp file left; a second run finds it current and makes no new backup.
        #expect(root.names(prefix: ".thing.json").isEmpty)
        #expect(preflight(root, [Self.toTwo, Self.toThree]).run().status(of: "thing.json") == .current(3))
        #expect(root.names(prefix: "thing.json.v") == [backup])
    }

    @Test func takenBackupNameGetsANumber() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let taken = "thing.json.v2-backup-\(stamp(Fixture.now))"
        try root.write(taken, "someone else's")
        try root.write("thing.json", #"{"v":2}"#)
        let report = preflight(root, [Self.toThree]).run()
        #expect(report.status(of: "thing.json") == .migrated(from: 2, to: 3, backup: taken + "-2"))
        #expect(root.read(taken) == Data("someone else's".utf8))
        #expect(root.read(taken + "-2") == Data(#"{"v":2}"#.utf8))
    }

    @Test func failingStepKeepsTheOriginalAndTheBackup() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let original = #"{"title":"x","v":1}"#
        try root.write("thing.json", original)
        let failing = MigrationStep(pattern: "thing.json", from: 2) { _ in throw StepFailure() }
        let report = preflight(root, [Self.toTwo, failing]).run()
        let reason = "v2 轉 v3 失敗"
        #expect(report.status(of: "thing.json") == .migrationFailed(reason))
        #expect(root.read("thing.json") == Data(original.utf8))
        #expect(root.names(prefix: "thing.json.v1-backup-").count == 1)
        #expect(report.issues == [DataIssue(file: "thing.json", kind: .migrationFailed, version: 1, reason: reason)])
        #expect(report.issues.first?.message == "thing.json 無法轉換成這個版本的格式（v2 轉 v3 失敗）：原檔與備份都保留，這次改用預設值")
    }

    @Test func stepThatForgetsTheVersionFails() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("thing.json", #"{"v":2}"#)
        let forgetful = MigrationStep(pattern: "thing.json", from: 2) { $0 }
        let report = preflight(root, [forgetful]).run()
        #expect(report.status(of: "thing.json") == .migrationFailed("v2 轉 v3 沒有設定版本"))
        #expect(root.read("thing.json") == Data(#"{"v":2}"#.utf8))
    }

    @Test func stepOutputThatIsNotJSONFails() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("thing.json", #"{"v":2}"#)
        let odd = MigrationStep(pattern: "thing.json", from: 2) { _ in ["v": 3, "when": Date()] }
        let report = preflight(root, [odd]).run()
        #expect(report.status(of: "thing.json") == .migrationFailed("轉換結果不是 JSON"))
        #expect(root.read("thing.json") == Data(#"{"v":2}"#.utf8))
    }

    @Test func missingStepLeavesTheFileUntouched() throws {
        let root = try TempRoot()
        defer { root.remove() }
        try root.write("thing.json", #"{"v":1}"#)
        let report = preflight(root, [Self.toThree]).run()
        #expect(report.status(of: "thing.json") == .noMigration(1))
        #expect(report.issues == [DataIssue(file: "thing.json", kind: .noMigration, version: 1)])
        #expect(report.issues.first?.message == "thing.json 是舊格式（v1），這個版本不認得：原檔保持不動")
        #expect(root.read("thing.json") == Data(#"{"v":1}"#.utf8))
        #expect(root.names(prefix: "thing.json.v").isEmpty)
    }

    @Test func absentVersionMigratesFromItsVersion() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let spec = DataFileSpec(pattern: "sessions/*/thing.json", versionKey: "v", currentVersion: 2, absentVersion: 1,
                                kind: .userData, corrupt: .moveAside)
        let step = MigrationStep(pattern: spec.pattern, from: 1) { object in
            var out = object
            out["v"] = 2
            return out
        }
        let path = "sessions/\(Fixture.session)/thing.json"
        try root.write(path, #"{"draft":"x"}"#)
        let report = DataPreflight(root: root.url, inventory: [spec], registry: MigrationRegistry([step]), now: { Fixture.now }).run()
        guard case .migrated(1, 2, let backup) = report.status(of: path) else {
            Issue.record("expected migrated, got \(String(describing: report.status(of: path)))")
            return
        }
        #expect(backup.hasPrefix("sessions/\(Fixture.session)/thing.json.v1-backup-"))
        #expect(root.read(backup) == Data(#"{"draft":"x"}"#.utf8))
        let object = try root.jsonObject(path)
        #expect(object["v"] as? Int == 2 && object["draft"] as? String == "x")
    }
}
