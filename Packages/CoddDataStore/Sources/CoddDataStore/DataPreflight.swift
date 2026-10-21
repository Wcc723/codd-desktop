import Darwin
import Foundation

/// The launch pass over the data root (M5 D14, plan §2.2), run off the main actor before any
/// store loads: older files are migrated after a backup, newer ones are left alone and reported,
/// corrupt USER DATA is moved aside (`<name>.corrupt-<epoch ms>`, never deleted), corrupt DERIVED
/// data is removed, `cache/` is wiped when its `VERSION` differs.
///
/// Safety rule: never stricter than a file's own store. Each ``DataInventory`` row copies its
/// store's load rules, only a parse failure is "corrupt" (an I/O error never is), and symlinks,
/// non-regular files and files over ``maxFileBytes`` are skipped and left alone (a symlinked
/// `cache/` is never wiped through). Blocking file I/O.
public struct DataPreflight: Sendable {
    /// Files larger than this are skipped (no CODD store writes anything near it).
    public static let maxFileBytes = 16 << 20

    public let root: URL
    public let inventory: [DataFileSpec]
    public let registry: MigrationRegistry
    public let maxFileBytes: Int
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void

    public init(root: URL, inventory: [DataFileSpec] = DataInventory.all, registry: MigrationRegistry = .standard,
                maxFileBytes: Int = DataPreflight.maxFileBytes,
                now: @escaping @Sendable () -> Date = Date.init, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.root = root
        self.inventory = inventory
        self.registry = registry
        self.maxFileBytes = maxFileBytes
        self.now = now
        self.log = log
    }

    /// Migrates, moves, removes and wipes as the rules say, logging one line per file that is not
    /// current and the summary. Blocking.
    public func run() -> DataPreflightReport {
        pass(apply: true)
    }

    /// The report ``run()`` would return, with nothing on disk touched (no aside or backup names:
    /// `corrupt(movedTo: nil)`, `migrated(…, backup: "")`; `cacheWiped` = would be wiped). For the
    /// state dump and tests; it logs nothing.
    public func scan() -> DataPreflightReport {
        pass(apply: false)
    }

    /// `<name>.corrupt-<ms>` (or `-<n>`) regular files next to inventoried files whose `ms` is at or
    /// after `date`, relative to the root and sorted: after the stores loaded, the moves they made
    /// themselves during this launch (schema errors the preflight cannot see), plus this launch's
    /// own preflight moves (the caller skips the ones its report already named).
    public func asideFiles(createdSince date: Date) -> [String] {
        guard let rootPath = DataFileIO.resolved(root.path) else { return [] }
        let threshold = Self.milliseconds(date)
        var found = Set<String>()
        for spec in inventory where spec.corrupt != .wipe {
            var components = spec.pattern.split(separator: "/").map(String.init)
            guard let last = components.popLast() else { continue }
            for folder in folders(components, rootPath: rootPath) {
                for name in DataFileIO.list(Self.join(rootPath, folder)) ?? [] {
                    guard let ms = Self.asideMilliseconds(name, base: last), ms >= threshold else { continue }
                    let relative = folder.isEmpty ? name : folder + "/" + name
                    if case .file = DataFileIO.entry(Self.join(rootPath, relative)) { found.insert(relative) }
                }
            }
        }
        return found.sorted()
    }

    /// The banner for an aside file ``asideFiles(createdSince:)`` found (`layout.json.corrupt-<ms>`
    /// names `layout.json`); nil when `aside` is not such a name.
    public static func corruptIssue(forAside aside: String) -> DataIssue? {
        let name = (aside as NSString).lastPathComponent
        guard let marker = name.range(of: ".corrupt-", options: .backwards), marker.lowerBound > name.startIndex else { return nil }
        let base = String(name[..<marker.lowerBound])
        guard asideMilliseconds(name, base: base) != nil else { return nil }
        return DataIssue(file: sibling(aside, named: base), kind: .corrupt, aside: aside)
    }

    // MARK: - The pass

    private struct Outcome {
        var status: DataFileStatus
        var issue: DataIssue?
        var logLine: String?
    }

    private func pass(apply: Bool) -> DataPreflightReport {
        let clock = ContinuousClock()
        let start = clock.now
        let date = now()
        guard let rootPath = DataFileIO.resolved(root.path) else {
            if apply { log("data preflight skipped reason=no-data-root") }
            return DataPreflightReport(files: [], issues: [], cacheWiped: false, milliseconds: Self.ms(clock.now - start))
        }
        var results: [String: Outcome] = [:]
        var cacheWiped = false
        for spec in inventory {
            if spec.corrupt == .wipe {
                let (path, outcome, wiped) = cachePass(spec, rootPath: rootPath, apply: apply)
                if results[path] == nil { results[path] = outcome }
                cacheWiped = cacheWiped || wiped
                continue
            }
            for candidate in candidates(spec, rootPath: rootPath) {
                guard results[candidate.path] == nil else { continue }
                switch candidate.kind {
                case .missing:
                    results[candidate.path] = Outcome(status: .missing)
                case .skipped(let reason):
                    results[candidate.path] = Outcome(status: .skipped(reason), logLine: "reason=\(reason)")
                case .file:
                    results[candidate.path] = examine(spec, relative: candidate.path, rootPath: rootPath, date: date, apply: apply)
                }
            }
        }
        let paths = results.keys.sorted()
        let files = paths.map { DataFileResult(path: $0, status: results[$0]!.status) }
        let issues = paths.compactMap { results[$0]!.issue }
        let report = DataPreflightReport(files: files, issues: issues, cacheWiped: cacheWiped, milliseconds: Self.ms(clock.now - start))
        if apply {
            for path in paths {
                guard let outcome = results[path], let detail = outcome.logLine else { continue }
                log("data \(outcome.status.label) file=\(path) \(detail)")
            }
            log(report.summaryLine)
        }
        return report
    }

    /// One existing regular file of `spec`.
    private func examine(_ spec: DataFileSpec, relative: String, rootPath: String, date: Date, apply: Bool) -> Outcome {
        let path = Self.join(rootPath, relative)
        let data: Data, mode: mode_t
        switch DataFileIO.read(path, maxBytes: maxFileBytes) {
        case .missing:
            return Outcome(status: .missing)
        case .skipped(let reason):
            return Outcome(status: .skipped(reason), logLine: "reason=\(reason)")
        case .ioError(let code):
            return Outcome(status: .skipped("unreadable errno=\(code)"), logLine: "reason=unreadable errno=\(code)")
        case .data(let bytes, let fileMode):
            data = bytes
            mode = fileMode
        }
        guard let found = JSONProbe.version(of: data, key: spec.versionKey) else {
            return corrupt(spec, relative: relative, path: path, why: "not-an-object", date: date, apply: apply)
        }
        let version: Int?
        switch found {
        case .integer(let n) where n > spec.currentVersion:
            return Outcome(status: .newer(n), issue: DataIssue(file: relative, kind: .newer, version: n), logLine: "v=\(n)")
        case .integer(let n) where n >= 1:
            version = n
        case .integer:
            version = spec.belowOneVersion ?? spec.absentVersion
        case .missing, .notInteger:
            version = spec.absentVersion
        }
        guard let from = version else {
            return corrupt(spec, relative: relative, path: path, why: "no-version", date: date, apply: apply)
        }
        guard from < spec.currentVersion else { return Outcome(status: .current(from)) }
        guard let key = spec.versionKey, let steps = registry.chain(pattern: spec.pattern, from: from, to: spec.currentVersion) else {
            return Outcome(status: .noMigration(from), issue: DataIssue(file: relative, kind: .noMigration, version: from),
                           logLine: "v=\(from)")
        }
        guard apply else { return Outcome(status: .migrated(from: from, to: spec.currentVersion, backup: "")) }
        return migrate(relative: relative, path: path, data: data, mode: mode, key: key, from: from, to: spec.currentVersion,
                       steps: steps, date: date)
    }

    private func corrupt(_ spec: DataFileSpec, relative: String, path: String, why: String, date: Date, apply: Bool) -> Outcome {
        switch spec.corrupt {
        case .report, .wipe:
            return Outcome(status: .corrupt(movedTo: nil), logLine: "\(why) kept=report-only")
        case .remove:
            guard apply else { return Outcome(status: .removed) }
            guard unlink(path) == 0 else {
                let code = errno
                return Outcome(status: .corrupt(movedTo: nil), logLine: "\(why) not-removed errno=\(code)")
            }
            return Outcome(status: .removed, logLine: why)
        case .moveAside:
            guard apply else {
                return Outcome(status: .corrupt(movedTo: nil), issue: DataIssue(file: relative, kind: .corrupt))
            }
            switch DataFileIO.moveAside(path, milliseconds: Self.milliseconds(date)) {
            case .success(let target):
                let aside = Self.sibling(relative, named: (target as NSString).lastPathComponent)
                return Outcome(status: .corrupt(movedTo: aside), issue: DataIssue(file: relative, kind: .corrupt, aside: aside),
                               logLine: "\(why) moved=\((aside as NSString).lastPathComponent)")
            case .failure(let error):
                // The store loads it next and decides (moves it itself, or reads it as empty);
                // the post-load sweep banners a move it makes.
                return Outcome(status: .corrupt(movedTo: nil), logLine: "\(why) not-moved errno=\(error.code)")
            }
        }
    }

    /// Backup first (`<name>.v<from>-backup-<yyyyMMdd-HHmmss>`, 0600, never over an existing
    /// file), then every step in memory, each checked to carry its `to`, then one atomic write
    /// keeping the file's mode. A failure leaves the original and the backup.
    private func migrate(relative: String, path: String, data: Data, mode: mode_t, key: String, from: Int, to: Int,
                         steps: [MigrationStep], date: Date) -> Outcome {
        func failed(_ reason: String, _ detail: String) -> Outcome {
            Outcome(status: .migrationFailed(reason), issue: DataIssue(file: relative, kind: .migrationFailed, version: from, reason: reason),
                    logLine: "from=\(from) \(detail)")
        }
        let backup: String
        switch makeBackup(path: path, data: data, from: from, date: date) {
        case .success(let name): backup = Self.sibling(relative, named: name)
        case .failure(let error): return failed("無法建立備份", "backup errno=\(error.code)")
        }
        guard var object = JSONProbe.object(of: data) else { return failed("無法解析", "backup=\(backup) parse") }
        for step in steps {
            do {
                object = try step.migrate(object)
            } catch {
                return failed("v\(step.from) 轉 v\(step.from + 1) 失敗", "backup=\(backup) step=\(step.from) error=\(type(of: error))")
            }
            guard JSONProbe.integer(object[key]) == step.from + 1 else {
                return failed("v\(step.from) 轉 v\(step.from + 1) 沒有設定版本", "backup=\(backup) step=\(step.from) version-not-set")
            }
        }
        guard JSONSerialization.isValidJSONObject(object),
              var output = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return failed("轉換結果不是 JSON", "backup=\(backup) encode") }
        output.append(0x0A)
        if let code = DataFileIO.writeAtomically(output, to: path, mode: mode) {
            return failed("無法寫入", "backup=\(backup) write errno=\(code)")
        }
        return Outcome(status: .migrated(from: from, to: to, backup: backup), logLine: "from=\(from) to=\(to) backup=\((backup as NSString).lastPathComponent)")
    }

    private func makeBackup(path: String, data: Data, from: Int, date: Date) -> Result<String, Errno> {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(path).v\(from)-backup-\(formatter.string(from: date))"
        for n in 1...1000 {
            let target = n == 1 ? stem : "\(stem)-\(n)"
            guard let code = DataFileIO.createExclusively(data, at: target, mode: 0o600) else {
                return .success((target as NSString).lastPathComponent)
            }
            guard code == EEXIST else { return .failure(Errno(code)) }
        }
        return .failure(Errno(EEXIST))
    }

    // MARK: - cache/VERSION

    /// `cache/VERSION` holds ``DataInventory/cacheVersion``: equal = current; a different number
    /// or an unreadable file = the folder's contents deleted (not the folder) and the file
    /// written; missing (or no `cache/`) = just written, nothing wiped (the post-M4 layout is
    /// version 1). A symlinked or non-folder `cache/`, or a symlinked / non-regular VERSION, is
    /// skipped and left alone.
    private func cachePass(_ spec: DataFileSpec, rootPath: String, apply: Bool) -> (String, Outcome, Bool) {
        let file = spec.pattern
        let folder = (file as NSString).deletingLastPathComponent
        let folderPath = Self.join(rootPath, folder)
        let filePath = Self.join(rootPath, file)
        let text = Data("\(spec.currentVersion)\n".utf8)
        switch DataFileIO.entry(folderPath) {
        case .directory:
            break
        case .missing:
            guard apply else { return (file, Outcome(status: .missing), false) }
            if let code = DataFileIO.makePrivateDirectory(folderPath, excludedFromBackup: true) {
                return (file, Outcome(status: .skipped("cannot create \(folder)/ errno=\(code)"), logLine: "reason=mkdir errno=\(code)"), false)
            }
            if let code = DataFileIO.writeAtomically(text, to: filePath, mode: 0o600) {
                return (file, Outcome(status: .skipped("cannot write errno=\(code)"), logLine: "reason=write errno=\(code)"), false)
            }
            return (file, Outcome(status: .missing, logLine: "written (no \(folder)/ folder)"), false)
        case .symlink:
            return (folder, Outcome(status: .skipped("symlink"), logLine: "reason=symlink"), false)
        case .file, .other:
            return (folder, Outcome(status: .skipped("not a folder"), logLine: "reason=not-a-folder"), false)
        case .error(let code):
            return (folder, Outcome(status: .skipped("unreadable errno=\(code)"), logLine: "reason=unreadable errno=\(code)"), false)
        }
        let found: String
        switch DataFileIO.read(filePath, maxBytes: maxFileBytes) {
        case .missing:
            guard apply else { return (file, Outcome(status: .missing), false) }
            if let code = DataFileIO.writeAtomically(text, to: filePath, mode: 0o600) {
                return (file, Outcome(status: .skipped("cannot write errno=\(code)"), logLine: "reason=write errno=\(code)"), false)
            }
            return (file, Outcome(status: .missing, logLine: "written (no wipe)"), false)
        case .skipped(let reason):
            return (file, Outcome(status: .skipped(reason), logLine: "reason=\(reason)"), false)
        case .ioError(let code):
            found = "unreadable errno=\(code)"
        case .data(let bytes, _):
            let value = Int(String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            if value == spec.currentVersion { return (file, Outcome(status: .current(spec.currentVersion)), false) }
            found = value.map { "\($0)" } ?? "not-a-number"
        }
        guard apply else { return (file, Outcome(status: .removed), true) }
        guard let wipe = DataFileIO.removeContents(of: folderPath) else {
            return (file, Outcome(status: .skipped("cannot list \(folder)/"), logLine: "reason=list found=\(found)"), false)
        }
        let (removed, failed) = wipe
        guard failed == 0 else {
            // VERSION is not written, so the next launch tries again.
            return (file, Outcome(status: .skipped("wipe incomplete"), logLine: "reason=wipe-incomplete found=\(found) removed=\(removed) left=\(failed)"),
                    false)
        }
        if let code = DataFileIO.writeAtomically(text, to: filePath, mode: 0o600) {
            return (file, Outcome(status: .removed, logLine: "wiped found=\(found) entries=\(removed) version-not-written errno=\(code)"), true)
        }
        return (file, Outcome(status: .removed, logLine: "wiped found=\(found) entries=\(removed)"), true)
    }

    // MARK: - Pattern expansion

    private struct Candidate {
        enum Kind {
            case file
            case missing
            case skipped(String)
        }

        let path: String
        let kind: Kind
    }

    /// The files a pattern names. A literal row whose file (or a folder on its way) is missing
    /// yields `missing`; a symlink or another non-folder on a literal part yields `skipped`
    /// (never followed); a wildcard part only matches real folders / files.
    private func candidates(_ spec: DataFileSpec, rootPath: String) -> [Candidate] {
        let components = spec.pattern.split(separator: "/").map(String.init)
        var out: [Candidate] = []
        var frontier = [""]
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            let wildcard = component.contains("*")
            var next: [String] = []
            for folder in frontier {
                let names: [String]
                if wildcard {
                    names = (DataFileIO.list(Self.join(rootPath, folder)) ?? []).filter { NamePattern.matches($0, component) }.sorted()
                } else {
                    names = [component]
                }
                for name in names {
                    let relative = folder.isEmpty ? name : folder + "/" + name
                    let entry = DataFileIO.entry(Self.join(rootPath, relative))
                    if isLast {
                        switch entry {
                        case .file: out.append(Candidate(path: relative, kind: .file))
                        // Only a literal row reports `missing`: a session folder without its
                        // composer.json is the normal case, not a finding.
                        case .missing: if spec.isLiteral { out.append(Candidate(path: relative, kind: .missing)) }
                        case .symlink: out.append(Candidate(path: relative, kind: .skipped("symlink")))
                        case .directory, .other: out.append(Candidate(path: relative, kind: .skipped("not a regular file")))
                        case .error(let code): out.append(Candidate(path: relative, kind: .skipped("unreadable errno=\(code)")))
                        }
                        continue
                    }
                    switch entry {
                    case .directory:
                        next.append(relative)
                    case .missing:
                        if spec.isLiteral { out.append(Candidate(path: spec.pattern, kind: .missing)) }
                    case .symlink:
                        out.append(Candidate(path: relative, kind: .skipped("symlink")))
                    case .file, .other:
                        if !wildcard { out.append(Candidate(path: relative, kind: .skipped("not a folder"))) }
                    case .error(let code):
                        out.append(Candidate(path: relative, kind: .skipped("unreadable errno=\(code)")))
                    }
                }
            }
            frontier = next
        }
        return out
    }

    /// The real folders (relative to the root) the folder part of a pattern names.
    private func folders(_ components: [String], rootPath: String) -> [String] {
        var frontier = [""]
        for component in components {
            var next: [String] = []
            for folder in frontier {
                let names = component.contains("*")
                    ? (DataFileIO.list(Self.join(rootPath, folder)) ?? []).filter { NamePattern.matches($0, component) }
                    : [component]
                for name in names {
                    let relative = folder.isEmpty ? name : folder + "/" + name
                    if DataFileIO.entry(Self.join(rootPath, relative)) == .directory { next.append(relative) }
                }
            }
            frontier = next
        }
        return frontier
    }

    // MARK: - Helpers

    /// `<base>.corrupt-<ms>` or `<base>.corrupt-<ms>-<n>` with `<base>` matching the pattern's
    /// last component: the milliseconds, else nil.
    static func asideMilliseconds(_ name: String, base pattern: String) -> Int64? {
        guard let marker = name.range(of: ".corrupt-", options: .backwards) else { return nil }
        guard NamePattern.matches(String(name[..<marker.lowerBound]), pattern) else { return nil }
        let parts = name[marker.upperBound...].split(separator: "-", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return Int64(parts[0])
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    private static func join(_ rootPath: String, _ relative: String) -> String {
        relative.isEmpty ? rootPath : rootPath + "/" + relative
    }

    /// `name` in the folder of `relative`.
    private static func sibling(_ relative: String, named name: String) -> String {
        let folder = (relative as NSString).deletingLastPathComponent
        return folder.isEmpty ? name : folder + "/" + name
    }

    private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
}
