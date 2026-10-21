import CoddDataStore
import Foundation

/// M5 D14: the launch's data preflight and the post-load aside sweep, and what they found (the
/// dump's `dataFiles`). Each issue goes to the banner queue through `queue` (the store's
/// `queueDataIssue`), one banner per file.
@MainActor
final class DataFilesMonitor {
    /// The preflight's report (nil until it ran; mock mode never runs it).
    private(set) var report: DataPreflightReport?
    /// Corrupt issues of the stores' own moves that the sweep found after the preflight.
    private(set) var lateIssues: [DataIssue] = []
    private let log: @Sendable (String) -> Void

    init(log: @escaping @Sendable (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.log = log
    }

    /// Every issue of this launch, the preflight's first.
    var issues: [DataIssue] { (report?.issues ?? []) + lateIssues }

    /// The preflight over `root` (off the main actor; it logs one line per file that is not
    /// current and the summary), then each issue to `queue`.
    func runPreflight(root: URL, queue: (DataIssue) -> Void) async {
        let log = self.log
        let report = await Task.detached(priority: .userInitiated) { DataPreflight(root: root, log: log).run() }.value
        self.report = report
        for issue in report.issues { queue(issue) }
    }

    /// The `<name>.corrupt-<ms>` files made since `since` that no issue named yet (the stores'
    /// own moves: a schema error the preflight cannot see), each one as a corrupt issue to `queue`.
    /// Returns the new issues.
    @discardableResult
    func sweep(root: URL, since: Date, queue: (DataIssue) -> Void) async -> [DataIssue] {
        let found = await Task.detached(priority: .utility) { DataPreflight(root: root).asideFiles(createdSince: since) }.value
        let known = Set(issues.compactMap(\.aside))
        var added: [DataIssue] = []
        for aside in found where !known.contains(aside) {
            guard let issue = DataPreflight.corruptIssue(forAside: aside) else { continue }
            log("data corrupt file=\(issue.file) moved=\(aside) by=store")
            lateIssues.append(issue)
            added.append(issue)
            queue(issue)
        }
        return added
    }

    /// `dataFiles {preflight {ms, cacheWiped, files [{file, status, version?, from?, aside?, backup?,
    /// reason?}]} | null, issues [{file, kind, version?, aside?, message}], bannersShown,
    /// bannersQueued}`: names only, never contents. `bannersQueued` (the banners still waiting their
    /// turn) lets m5-e2e see one banner per issue without pressing `[知道了]`.
    func dump(bannersShown: Int, bannersQueued: Int = 0) -> [String: Any] {
        var object: [String: Any] = ["bannersShown": bannersShown, "bannersQueued": bannersQueued,
                                     "issues": issues.map(Self.issueDump)]
        if let report {
            object["preflight"] = ["ms": report.milliseconds, "cacheWiped": report.cacheWiped,
                                   "files": report.files.map(Self.fileDump)] as [String: Any]
        } else {
            object["preflight"] = NSNull()
        }
        return object
    }

    nonisolated static func fileDump(_ file: DataFileResult) -> [String: Any] {
        var entry: [String: Any] = ["file": file.path, "status": file.status.label]
        switch file.status {
        case .current(let version), .newer(let version), .noMigration(let version):
            entry["version"] = version
        case .migrated(let from, let to, let backup):
            entry["version"] = to
            entry["from"] = from
            entry["backup"] = backup
        case .corrupt(let movedTo):
            if let movedTo { entry["aside"] = movedTo }
        case .skipped(let reason), .migrationFailed(let reason):
            entry["reason"] = reason
        case .missing, .removed:
            break
        }
        return entry
    }

    nonisolated static func issueDump(_ issue: DataIssue) -> [String: Any] {
        var entry: [String: Any] = ["file": issue.file, "kind": issue.kind.rawValue, "message": issue.message]
        if let version = issue.version { entry["version"] = version }
        if let aside = issue.aside { entry["aside"] = aside }
        return entry
    }
}
