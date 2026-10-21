import CoddDataStore
import Foundation

/// Which runs may touch CODD's own UserDefaults domain (M5 D2, D25), decided in one place.
///
/// The domain is shared by every build with the same bundle id: after D1 that is the installed
/// Release's `app.codd.CODD`. A test, perf or agent run (any data root but the standard one, and
/// mock mode) therefore never restores or saves the main window frame, the split view frames or
/// the status item position, and never runs the one-time copy from the legacy domain: the user's
/// first standard-root launch must find their old values, not a test window's.
enum DefaultsIsolation {
    /// The autosave name of the main window's frame (`NSWindow Frame CODDMainWindow`).
    static let windowFrameName = "CODDMainWindow"
    /// The status item's autosave name (`NSStatusItem Preferred Position CODDStatusItem`).
    static let statusItemName = "CODDStatusItem"

    /// D25: real mode on the standard data root only.
    static func autosavesLayout(realMode: Bool, root: CoddDataRoot?) -> Bool {
        realMode && root == .standard
    }

    /// What the launch did about the legacy domain (the dump's `bundle.legacyDefaults*`).
    enum Outcome: Equatable, Sendable {
        /// Not the standard data root, or mock mode: nothing read or written.
        case notApplicable
        /// This build already runs under the legacy id (nothing to copy from).
        case sameDomain
        case migrated(DefaultsDomainMigration.Result)

        var key: String {
            switch self {
            case .notApplicable: "notApplicable"
            case .sameDomain: "sameDomain"
            case .migrated(let result): result.alreadyDone ? "alreadyDone" : result.sourceMissing ? "sourceMissing" : "migrated"
            }
        }

        /// True once CODD's keys came over (now or at an earlier launch), false when there was no
        /// legacy domain, nil when the copy does not run on this root.
        var legacyDefaultsMigrated: Bool? {
            guard case .migrated(let result) = self else { return nil }
            return !result.sourceMissing
        }
    }

    /// D2: once, on the standard data root only, before any window or status item exists: CODD's
    /// own keys from the legacy domain into `newDomain` (replacing what a test run may have
    /// written there while the marker is absent), then the marker. Logs `defaults migrated
    /// from=<old> keys=<n>` or `defaults migration skipped reason=<r>`; on any other root it does
    /// nothing at all, not even a log line. `defaults` is the object both domains go through
    /// (`.standard` in the app; tests pass a temp suite and their own domain names).
    @discardableResult
    static func migrateLegacyDefaults(applies: Bool, from oldDomain: String = CoddIdentity.legacyBundleIdentifier,
                                      into newDomain: String, defaults: UserDefaults = .standard,
                                      log: (String) -> Void) -> Outcome {
        guard applies else { return .notApplicable }
        guard oldDomain != newDomain else {
            log("defaults migration skipped reason=sameDomain")
            return .sameDomain
        }
        let result = DefaultsDomainMigration.migrate(from: oldDomain, into: newDomain, defaults: defaults)
        if result.alreadyDone {
            log("defaults migration skipped reason=alreadyDone")
        } else if result.sourceMissing {
            log("defaults migration skipped reason=sourceMissing")
        } else {
            log("defaults migrated from=\(oldDomain) keys=\(result.copied.count)")
        }
        return .migrated(result)
    }
}
