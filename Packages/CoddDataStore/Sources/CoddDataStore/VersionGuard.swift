import Foundation

/// For writers that must never replace a file a newer CODD wrote (the App's `panes.json`, the
/// backups index writer): read the version member right before the write.
public enum VersionGuard {
    /// The integer `key` of the JSON object at `url` (CoddCore `exactIntegerValue` rules), nil when
    /// the file is missing, unreadable, larger than ``DataPreflight/maxFileBytes``, not a JSON
    /// object or has no integer member.
    public static func existingVersion(of url: URL, key: String) -> Int? {
        guard case .data(let data, _) = DataFileIO.read(url.path, maxBytes: DataPreflight.maxFileBytes, followLinks: true),
              case .integer(let version)? = JSONProbe.version(of: data, key: key) else { return nil }
        return version
    }

    /// False only when the file on disk carries a version above `current` (like the stores'
    /// own save guards, an unreadable or versionless file may be replaced).
    public static func mayReplace(_ url: URL, key: String, current: Int) -> Bool {
        guard let version = existingVersion(of: url, key: key) else { return true }
        return version <= current
    }
}
