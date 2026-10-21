import Foundation

/// M5 D2: the one-time copy of CODD's own UserDefaults keys from the old bundle id's persistent
/// domain (`app.fancycodd.CODD`) into the new one, on the standard data root only (the App
/// decides; automated runs never call it). The old domain is only read
/// (`persistentDomain(forName:)`), never written.
///
/// Until the marker is set the copied keys REPLACE what the new domain holds: before the user's
/// first standard-root launch only a test or throwaway run can have written them (window frame,
/// split view, status item position). Once the marker is set nothing is copied again.
public enum DefaultsDomainMigration {
    public struct Result: Sendable, Equatable {
        /// The keys written into the new domain, sorted.
        public var copied: [String]
        /// The marker was already set: nothing was read or written.
        public var alreadyDone: Bool
        /// The old domain does not exist or is empty (a new user): nothing written, no marker.
        public var sourceMissing: Bool

        public init(copied: [String] = [], alreadyDone: Bool = false, sourceMissing: Bool = false) {
            self.copied = copied
            self.alreadyDone = alreadyDone
            self.sourceMissing = sourceMissing
        }
    }

    /// CODD's own keys: the window frame, the split view frames, the status item's position and
    /// visibility (AppKit autosave names start with `CODD`), and CODD's own `CODD…` keys.
    public static let keyPrefixes = [
        "NSWindow Frame CODD", "NSSplitView Subview Frames CODD", "NSStatusItem Preferred Position CODD",
        "NSStatusItem Visible CODD", "CODD",
    ]

    /// Never copied: DEBUG tool keys a test run may have persisted, and the marker itself.
    public static let excludedKeyPrefixes = [
        "CODDMetrics", "CODDSelfTest", "CODDSnapshotDir", "CODDForceVisibleTimers", "CODDHideAfterLaunch", marker,
    ]

    /// Set in the new domain to the old domain's name once the copy ran.
    public static let marker = "CODDDefaultsMigratedFrom"

    /// Whether `key` is one of CODD's own keys that migrate.
    public static func migrates(_ key: String) -> Bool {
        keyPrefixes.contains { key.hasPrefix($0) } && !excludedKeyPrefixes.contains { key.hasPrefix($0) }
    }

    /// Copies the keys (replacing the new domain's values while the marker is absent), then sets
    /// the marker, in one write of the new domain. `defaults` is the object both domains are
    /// read and written through (`.standard` in the App; a temp suite in tests).
    public static func migrate(from oldDomain: String, into newDomain: String, defaults: UserDefaults = .standard) -> Result {
        let target = defaults.persistentDomain(forName: newDomain) ?? [:]
        if target[marker] != nil { return Result(alreadyDone: true) }
        // A domain that was removed reads back as an empty dictionary, not nil: the same new user.
        guard let source = defaults.persistentDomain(forName: oldDomain), !source.isEmpty else { return Result(sourceMissing: true) }
        var merged = target
        var copied: [String] = []
        for (key, value) in source where migrates(key) {
            merged[key] = value
            copied.append(key)
        }
        merged[marker] = oldDomain
        defaults.setPersistentDomain(merged, forName: newDomain)
        return Result(copied: copied.sorted())
    }
}
