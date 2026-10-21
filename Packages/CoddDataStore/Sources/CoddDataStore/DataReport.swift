import Foundation

/// What the preflight found (``DataPreflight/scan()``) or did (``DataPreflight/run()``) with one
/// inventoried file.
public enum DataFileStatus: Sendable, Equatable {
    case missing
    /// Read as this version (a missing version reads as the row's `absentVersion`).
    case current(Int)
    /// `backup` is the backup's path relative to the root ("" in a scan: nothing was written).
    case migrated(from: Int, to: Int, backup: String)
    /// Written by a newer CODD: left untouched (its store keeps it read only).
    case newer(Int)
    /// Not parseable (or an unusable version where the store rejects one). `movedTo` is the
    /// aside file's path relative to the root; nil when it stayed (report-only rows, a failed
    /// rename, a scan).
    case corrupt(movedTo: String?)
    /// A DERIVED file deleted because it did not parse (or the cache wiped).
    case removed
    /// A symlink, not a regular file, over the size limit or unreadable (an I/O error is never
    /// treated as corrupt): left alone.
    case skipped(String)
    /// Older than current with no registered step: left as it is (its store decides).
    case noMigration(Int)
    /// A step or the write failed: the original and the backup stay.
    case migrationFailed(String)

    /// The word the log lines and the state dump use.
    public var label: String {
        switch self {
        case .missing: "missing"
        case .current: "current"
        case .migrated: "migrated"
        case .newer: "newer"
        case .corrupt: "corrupt"
        case .removed: "removed"
        case .skipped: "skipped"
        case .noMigration: "no-migration"
        case .migrationFailed: "migration-failed"
        }
    }
}

/// One file of the report.
public struct DataFileResult: Sendable, Equatable {
    /// Relative to the data root (`layout.json`, `sessions/<uuid>/composer.json`).
    public let path: String
    public let status: DataFileStatus

    public init(path: String, status: DataFileStatus) {
        self.path = path
        self.status = status
    }
}

/// A problem the user is told about once, in the problem banner (`▲ …` with `[知道了]`, plus
/// `[在 Finder 中顯示]` for ``Kind/corrupt``, which reveals ``aside``).
public struct DataIssue: Sendable, Equatable, Codable {
    public enum Kind: String, Codable, Sendable {
        case newer, corrupt, migrationFailed, noMigration
    }

    /// The file's path relative to the data root.
    public let file: String
    public let kind: Kind
    public let version: Int?
    /// Where a corrupt file went, relative to the data root (nil when it was not moved).
    public let aside: String?
    /// The banner text (繁體中文).
    public let message: String

    /// `reason` is the short 繁體中文 cause a ``Kind/migrationFailed`` banner names.
    public init(file: String, kind: Kind, version: Int? = nil, aside: String? = nil, reason: String? = nil) {
        self.file = file
        self.kind = kind
        self.version = version
        self.aside = aside
        message = Self.message(file: file, kind: kind, version: version, aside: aside, reason: reason)
    }

    /// The M5 plan §2.2 banner copy. A corrupt file that was not moved (only a scan reports one)
    /// leaves out the `已移到` part.
    public static func message(file: String, kind: Kind, version: Int?, aside: String?, reason: String?) -> String {
        let n = version.map(String.init) ?? "?"
        switch kind {
        case .newer:
            return "\(file) 是較新版本的 CODD 寫的（v\(n)）：能讀的部分照用，這次的變更不會存進這個檔案"
        case .corrupt:
            guard let aside else { return "\(file) 無法讀取，改用預設值" }
            return "\(file) 無法讀取，已移到 \((aside as NSString).lastPathComponent)，改用預設值"
        case .migrationFailed:
            return "\(file) 無法轉換成這個版本的格式（\(reason ?? "未知原因")）：原檔與備份都保留，這次改用預設值"
        case .noMigration:
            return "\(file) 是舊格式（v\(n)），這個版本不認得：原檔保持不動"
        }
    }
}

public struct DataPreflightReport: Sendable {
    /// Every inventoried file found (and the literal rows that are missing), sorted by path.
    public let files: [DataFileResult]
    /// One per banner, in file order.
    public let issues: [DataIssue]
    /// `cache/`'s contents were deleted (a scan: would be).
    public let cacheWiped: Bool
    public let milliseconds: Double

    public init(files: [DataFileResult], issues: [DataIssue], cacheWiped: Bool, milliseconds: Double) {
        self.files = files
        self.issues = issues
        self.cacheWiped = cacheWiped
        self.milliseconds = milliseconds
    }

    /// The status of `path` (relative to the root), nil when the report does not list it.
    public func status(of path: String) -> DataFileStatus? {
        files.first { $0.path == path }?.status
    }

    /// `data preflight files=<n> current=<n> migrated=<n> newer=<n> corrupt=<n> removed=<n> ms=<x>`
    /// (`files` counts the files that exist).
    public var summaryLine: String {
        var counts: [String: Int] = [:]
        for file in files { counts[file.status.label, default: 0] += 1 }
        let present = files.count - (counts["missing"] ?? 0)
        func n(_ label: String) -> Int { counts[label] ?? 0 }
        return "data preflight files=\(present) current=\(n("current")) migrated=\(n("migrated")) newer=\(n("newer"))"
            + " corrupt=\(n("corrupt")) removed=\(n("removed")) ms=\(String(format: "%.1f", milliseconds))"
    }
}
