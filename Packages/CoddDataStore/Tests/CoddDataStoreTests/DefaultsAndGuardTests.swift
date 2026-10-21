import Foundation
import Testing
@testable import CoddDataStore

/// Unique temp suites only (`codd-test-<uuid>-old` / `-new`), removed at the end; never the real
/// `app.codd.CODD` or `app.fancycodd.CODD` domains.
@Suite("Defaults domain migration")
struct DefaultsMigrationTests {
    struct Domains {
        let old = "codd-test-\(UUID().uuidString)-old"
        let new = "codd-test-\(UUID().uuidString)-new"
        let defaults: UserDefaults

        struct NoSuite: Error {}

        init() throws {
            guard let suite = UserDefaults(suiteName: new) else { throw NoSuite() }
            defaults = suite
        }

        func seedOld(_ values: [String: Any]) {
            defaults.setPersistentDomain(values, forName: old)
        }

        func remove() {
            defaults.removePersistentDomain(forName: old)
            defaults.removePersistentDomain(forName: new)
        }
    }

    static var oldValues: [String: Any] {
        [
        "NSWindow Frame CODDMainWindow": "100 100 1440 900 0 0 1728 1079 ",
        "NSSplitView Subview Frames CODDMainSplit": ["0.000000, 0.000000, 260.000000, 900.000000, NO, NO"],
        "NSStatusItem Preferred Position CODDStatusItem": 412,
        "NSStatusItem Visible CODDStatusItem": true,
        "CODDNotificationsEnabled": false,
        // Not CODD's own keys.
        "AppleLanguages": ["zh-Hant-TW"],
        "NSNavLastRootDirectory": "~/Desktop",
        "NSWindow Frame OtherWindow": "1 2 3 4 0 0 5 6 ",
        // DEBUG tool keys and the marker never move.
        "CODDMetrics": true,
        "CODDMetricsDelay": 3,
        "CODDSelfTest": true,
        "CODDSnapshotDir": "/tmp/x",
        "CODDForceVisibleTimers": true,
        "CODDHideAfterLaunch": true,
        "CODDDefaultsMigratedFrom": "somewhere",
        ]
    }

    @Test func copiesOnlyCoddKeysReplacingTargetValuesBeforeTheMarker() throws {
        let domains = try Domains()
        defer { domains.remove() }
        domains.seedOld(Self.oldValues)
        // A test run wrote these into the new domain before the first real launch.
        domains.defaults.setPersistentDomain(["NSWindow Frame CODDMainWindow": "0 0 800 600 0 0 1728 1079 ", "Unrelated": "kept"],
                                             forName: domains.new)
        let oldBefore = try #require(domains.defaults.persistentDomain(forName: domains.old)) as NSDictionary

        let result = DefaultsDomainMigration.migrate(from: domains.old, into: domains.new, defaults: domains.defaults)
        #expect(result == DefaultsDomainMigration.Result(copied: [
            "CODDNotificationsEnabled", "NSSplitView Subview Frames CODDMainSplit", "NSStatusItem Preferred Position CODDStatusItem",
            "NSStatusItem Visible CODDStatusItem", "NSWindow Frame CODDMainWindow",
        ]))
        let target = try #require(domains.defaults.persistentDomain(forName: domains.new))
        #expect(target["NSWindow Frame CODDMainWindow"] as? String == "100 100 1440 900 0 0 1728 1079 ")
        #expect(target["NSStatusItem Preferred Position CODDStatusItem"] as? Int == 412)
        #expect(target["CODDNotificationsEnabled"] as? Bool == false)
        #expect(target["Unrelated"] as? String == "kept")
        #expect(target["AppleLanguages"] == nil && target["NSWindow Frame OtherWindow"] == nil)
        for key in ["CODDMetrics", "CODDMetricsDelay", "CODDSelfTest", "CODDSnapshotDir", "CODDForceVisibleTimers", "CODDHideAfterLaunch"] {
            #expect(target[key] == nil, "\(key)")
        }
        #expect(target[DefaultsDomainMigration.marker] as? String == domains.old)
        #expect(domains.defaults.string(forKey: "NSWindow Frame CODDMainWindow") == "100 100 1440 900 0 0 1728 1079 ")
        // The old domain is unchanged.
        #expect(domains.defaults.persistentDomain(forName: domains.old) as NSDictionary? == oldBefore)
    }

    @Test func secondRunIsAlreadyDoneAndCopiesNothing() throws {
        let domains = try Domains()
        defer { domains.remove() }
        domains.seedOld(["NSWindow Frame CODDMainWindow": "first"])
        #expect(DefaultsDomainMigration.migrate(from: domains.old, into: domains.new, defaults: domains.defaults).copied
            == ["NSWindow Frame CODDMainWindow"])
        domains.defaults.set("moved by the user", forKey: "NSWindow Frame CODDMainWindow")
        domains.seedOld(["NSWindow Frame CODDMainWindow": "old build ran again"])
        let again = DefaultsDomainMigration.migrate(from: domains.old, into: domains.new, defaults: domains.defaults)
        #expect(again == DefaultsDomainMigration.Result(alreadyDone: true))
        #expect(domains.defaults.string(forKey: "NSWindow Frame CODDMainWindow") == "moved by the user")
    }

    @Test func missingOldDomainWritesNothing() throws {
        let domains = try Domains()
        defer { domains.remove() }
        let result = DefaultsDomainMigration.migrate(from: domains.old, into: domains.new, defaults: domains.defaults)
        #expect(result == DefaultsDomainMigration.Result(sourceMissing: true))
        #expect(domains.defaults.persistentDomain(forName: domains.new)?[DefaultsDomainMigration.marker] == nil)
    }

    /// A removed domain reads back as `[:]`, not nil: still a new user, no marker written.
    @Test func removedOldDomainWritesNothing() throws {
        let domains = try Domains()
        defer { domains.remove() }
        domains.seedOld(["NSWindow Frame CODDMainWindow": "x"])
        domains.defaults.removePersistentDomain(forName: domains.old)
        let result = DefaultsDomainMigration.migrate(from: domains.old, into: domains.new, defaults: domains.defaults)
        #expect(result == DefaultsDomainMigration.Result(sourceMissing: true))
        #expect(domains.defaults.persistentDomain(forName: domains.new)?[DefaultsDomainMigration.marker] == nil)
    }

    @Test func keyRules() {
        #expect(DefaultsDomainMigration.migrates("NSWindow Frame CODDMainWindow"))
        #expect(DefaultsDomainMigration.migrates("CODDNotificationsEnabled"))
        #expect(!DefaultsDomainMigration.migrates("CODDMetricsSessions"))
        #expect(!DefaultsDomainMigration.migrates(DefaultsDomainMigration.marker))
        #expect(!DefaultsDomainMigration.migrates("NSWindow Frame Settings"))
        #expect(!DefaultsDomainMigration.migrates("codd-verbose-log"))
    }
}

@Suite("Version guard")
struct VersionGuardTests {
    @Test func readsTheVersionRightBeforeAWrite() throws {
        let root = try TempRoot()
        defer { root.remove() }
        let url = root.url.appendingPathComponent("panes.json")
        #expect(VersionGuard.existingVersion(of: url, key: "version") == nil)
        #expect(VersionGuard.mayReplace(url, key: "version", current: 1))
        for (text, version, may) in [(#"{"version":1}"#, Int?.some(1), true), (#"{"version":2,"sessions":{}}"#, 2, false),
                                     (#"{"version":"2"}"#, nil, true), ("not json", nil, true), (#"{"v":5}"#, nil, true)] {
            try root.write("panes.json", text)
            #expect(VersionGuard.existingVersion(of: url, key: "version") == version, "\(text)")
            #expect(VersionGuard.mayReplace(url, key: "version", current: 1) == may, "\(text)")
        }
    }
}
