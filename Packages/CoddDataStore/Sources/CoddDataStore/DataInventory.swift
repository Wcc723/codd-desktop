import Foundation

/// USER DATA (CODD cannot rebuild it: migrated after a backup, moved aside when corrupt) or
/// DERIVED (rebuildable: removed when corrupt).
public enum DataFileKind: String, Sendable, Codable {
    case userData, derived
}

/// What the preflight does with a file that does not parse (or has an unusable version where its
/// store rejects one).
public enum CorruptPolicy: String, Sendable, Codable {
    /// Renamed to `<name>.corrupt-<epoch ms>` next to it (never deleted), like the stores do.
    case moveAside
    /// Deleted (DERIVED files only).
    case remove
    /// Logged and reported, never touched: its store repairs it (config.json) or never reads it.
    case report
    /// `cache/VERSION`: the folder's contents are deleted and the file written again.
    case wipe
}

/// One row of the data root inventory (M5 plan §2.2).
public struct DataFileSpec: Sendable, Hashable {
    /// Relative to the data root; one `*` matches within one path component and never a hidden
    /// name (`sessions/*/composer.json`, `hooks/*.json`).
    public let pattern: String
    /// The top-level member holding the version (`version` or `v`); nil for versionless DERIVED
    /// files (any JSON object is current) and for the `cache/VERSION` text file.
    public let versionKey: String?
    public let currentVersion: Int
    /// The version a file reads as when the member is missing or not an integer; nil: the store
    /// rejects such a file, so it is corrupt.
    public let absentVersion: Int?
    /// The version an integer member below 1 reads as; nil: like a missing member. StoreFile and
    /// PaneLayoutStore decode `v` / `version` as any `Int` and check only the upper bound, so they
    /// load `0` and negative values as their own version while rejecting a missing one.
    public let belowOneVersion: Int?
    public let kind: DataFileKind
    public let corrupt: CorruptPolicy

    public init(pattern: String, versionKey: String?, currentVersion: Int, absentVersion: Int?,
                belowOneVersion: Int? = nil, kind: DataFileKind, corrupt: CorruptPolicy) {
        self.pattern = pattern
        self.versionKey = versionKey
        self.currentVersion = currentVersion
        self.absentVersion = absentVersion
        self.belowOneVersion = belowOneVersion
        self.kind = kind
        self.corrupt = corrupt
    }

    /// Whether the pattern names exactly one file (no `*`).
    var isLiteral: Bool { !pattern.contains("*") }
}

/// Every JSON file CODD owns in the data root, with the rules its store applies when loading it
/// (D14: the preflight is never stricter than a file's own store). Each row names the load code
/// it mirrors; change both together.
public enum DataInventory {
    /// The number `cache/VERSION` holds. The post-M4 cache layout (notes index, annotated images)
    /// is version 1, so a missing file is written without wiping.
    public static let cacheVersion = 1
    public static let cacheVersionPath = "cache/VERSION"

    public static let all: [DataFileSpec] = [
        // CoddCore LayoutStore.load: `version` exactIntegerValue required, > current = unsupported
        // (read only), < 1 = corrupt.
        DataFileSpec(pattern: "layout.json", versionKey: "version", currentVersion: 1, absentVersion: nil,
                     kind: .userData, corrupt: .moveAside),
        // App PaneLayoutStore.LenientFile: `container.decode(Int.self, forKey: .version)` (missing
        // or non-integer = not read), `file.version <= currentVersion` (no lower bound).
        DataFileSpec(pattern: "panes.json", versionKey: "version", currentVersion: 1, absentVersion: nil,
                     belowOneVersion: 1, kind: .userData, corrupt: .moveAside),
        // CoddPreferences PreferencesStore.load: a missing, non-integer or < 1 `version` is read
        // as the current one (repaired); only a non-object moves aside.
        DataFileSpec(pattern: "preferences.json", versionKey: "version", currentVersion: 1, absentVersion: 1,
                     kind: .userData, corrupt: .moveAside),
        // CoddCore LaunchProfileStore.load: like LayoutStore.
        DataFileSpec(pattern: "profiles.json", versionKey: "version", currentVersion: 1, absentVersion: nil,
                     kind: .userData, corrupt: .moveAside),
        // App CleanupState.decode: `(object["v"] as? NSNumber)?.intValue ?? 1`.
        DataFileSpec(pattern: "cleanup.json", versionKey: "v", currentVersion: 1, absentVersion: 1,
                     kind: .userData, corrupt: .moveAside),
        // CoddClaudeSettings BackupsIndex.read / App ClaudeSettingsService.readIndex: only an
        // integer `v` is the index (anything else reads as foreign and the next entry replaced
        // it before M5), so a file without one is moved aside before a writer sees it.
        DataFileSpec(pattern: "claude-settings-backups.json", versionKey: "v", currentVersion: 1, absentVersion: nil,
                     kind: .userData, corrupt: .moveAside),
        // CoddFiles StoreFile.load: `VersionOnly { v: Int }` required (else moved aside),
        // `v > currentVersion` read only, no lower bound.
        DataFileSpec(pattern: "files/recent.json", versionKey: "v", currentVersion: 1, absentVersion: nil,
                     belowOneVersion: 1, kind: .userData, corrupt: .moveAside),
        DataFileSpec(pattern: "files/ai-touches.json", versionKey: "v", currentVersion: 1, absentVersion: nil,
                     belowOneVersion: 1, kind: .userData, corrupt: .moveAside),
        // M5 §2.3 (CoddOnboarding): `v` required.
        DataFileSpec(pattern: "onboarding.json", versionKey: "v", currentVersion: 1, absentVersion: nil,
                     kind: .userData, corrupt: .moveAside),
        // CoddComposer ComposerStateFile.load: tolerant decode, no `v` before M5 (= 1).
        DataFileSpec(pattern: "sessions/*/composer.json", versionKey: "v", currentVersion: 1, absentVersion: 1,
                     kind: .userData, corrupt: .moveAside),
        // CoddNotes NotesLibrary.ensureLayout: the marker is only checked for existence, never
        // parsed, so a damaged one is reported and left where it is.
        DataFileSpec(pattern: "notes/.codd/notebook.json", versionKey: "v", currentVersion: 1, absentVersion: 1,
                     kind: .userData, corrupt: .report),
        // CoddNotes StateFileIO.load: a non-object moves aside, `obj["v"] as? Int` > 1 read only,
        // anything else read as current.
        DataFileSpec(pattern: "notes/.codd/state.json", versionKey: "v", currentVersion: 1, absentVersion: 1,
                     kind: .userData, corrupt: .moveAside),
        DataFileSpec(pattern: "notes/.codd/tombstones.json", versionKey: "v", currentVersion: 1, absentVersion: 1,
                     kind: .userData, corrupt: .moveAside),
        // CoddHooks HookConfigStore.readExisting: repairs a bad file itself (keeps the port and a
        // `.invalid-<s>` copy); M4 never read `v`.
        DataFileSpec(pattern: "config.json", versionKey: "v", currentVersion: 1, absentVersion: 1,
                     kind: .userData, corrupt: .report),
        // CoddCore QuotaStore.load: `v` exactIntegerValue in 1...current, else an empty book that
        // the next save replaces.
        DataFileSpec(pattern: "quota.json", versionKey: "v", currentVersion: 1, absentVersion: nil,
                     kind: .derived, corrupt: .remove),
        // CoddHooks HookStatePersister.load / App PendingAnswerFile.read: `try? JSONDecoder()`,
        // a bad file is ignored and rewritten.
        DataFileSpec(pattern: "hooks/*.json", versionKey: nil, currentVersion: 1, absentVersion: 1,
                     kind: .derived, corrupt: .remove),
        DataFileSpec(pattern: "sessions/*/answer.json", versionKey: nil, currentVersion: 1, absentVersion: 1,
                     kind: .derived, corrupt: .remove),
        // App NotesService.prepareCache + M5 D14: the cache layout's version as text.
        DataFileSpec(pattern: cacheVersionPath, versionKey: nil, currentVersion: cacheVersion, absentVersion: cacheVersion,
                     kind: .derived, corrupt: .wipe),
    ]
}
