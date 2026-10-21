import Foundation

/// CODD's identity (M5 D1, user decision 2026-10-18): the bundle id every configuration ships with,
/// the one builds before M5 had, and the names derived from them. Every other place uses these
/// constants instead of spelling a prefix (queue labels, the signposter, the private pasteboard,
/// the sidebar drag type, the show-window request).
///
/// The legacy id stays for three things only: the one-time defaults copy (D2), the show-window
/// request that an older CODD holding the lock still answers, and `BackgroundWindows`, which must
/// tell an older CODD's windows from other apps' (a background run of either id is CODD's own).
enum CoddIdentity {
    static let bundleIdentifier = "app.codd.CODD"
    static let legacyBundleIdentifier = "app.fancycodd.CODD"
    static let allBundleIdentifiers: Set<String> = [bundleIdentifier, legacyBundleIdentifier]

    /// The reverse-DNS prefix of every name CODD owns.
    static let prefix = "app.codd"

    /// `app.codd.<name>`: dispatch queue labels and other process-local names.
    static func label(_ name: String) -> String { prefix + "." + name }

    /// D28 / D1: the distributed show-window request, POSTED and OBSERVED under both ids, so a new
    /// build started while an older one holds the data root still brings that one forward.
    static let showMainWindowNames: [Notification.Name] = [
        Notification.Name(bundleIdentifier + ".showMainWindow"),
        Notification.Name(legacyBundleIdentifier + ".showMainWindow"),
    ]

    /// The id this process runs as (the built bundle's; the constant when there is no bundle).
    static var runningBundleIdentifier: String { Bundle.main.bundleIdentifier ?? bundleIdentifier }

    /// Whether a running app's bundle id is a CODD (either id, or this very build's).
    static func isCODD(bundleIdentifier id: String?) -> Bool {
        guard let id else { return false }
        return allBundleIdentifiers.contains(id) || id == Bundle.main.bundleIdentifier
    }

    /// `CFBundleShortVersionString` (`MARKETING_VERSION`, the repo's `VERSION`).
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// `CFBundleVersion` (`CURRENT_PROJECT_VERSION`; release.sh sets the commit count).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}
