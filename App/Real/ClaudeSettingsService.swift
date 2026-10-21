import CoddClaudeSettings
import CoddCore
import CoddDataStore
import CoddDialogsUI
import Darwin
import Foundation
import Observation

/// The global installer of Claude's user settings (D10, D11): inspection for STATUS and Settings,
/// plans for each action, the Hook 差異 dialog (B) and the write with its backup. Nothing is ever
/// written without a plan the user saw and confirmed with `套用並備份` (or the DEBUG
/// `-codd-hooks-apply`, refused for any target inside the real `~/.claude`).
///
/// Every read, plan and write runs off the main actor (CoddClaudeSettings is blocking file I/O).
/// The file is the store's `claudeSettingsURL` (DEBUG `-codd-claude-settings`, else
/// `<claudeDir>/settings.json`), so tests and test roots only ever touch temp files.
@MainActor @Observable
final class ClaudeSettingsService {
    /// What STATUS and Settings show about the file.
    enum InspectionState: Equatable {
        case unknown
        case loaded(ClaudeSettingsInspection, exists: Bool)
        /// The file cannot be inspected (繁體中文 reason, no content).
        case failed(String)
    }

    private(set) var inspection: InspectionState = .unknown
    /// The last plan built (dialog B, DEBUG `-codd-hooks-plan`), for the dump.
    private(set) var lastPlan: InstallerPlan?
    /// The last write: its backup's file name (nil when the file was created) and when.
    private(set) var lastApplied: (backup: String?, action: InstallerAction, at: Date)?
    /// A write is running (one at a time).
    private(set) var isApplying = false

    @ObservationIgnored let settingsURL: URL
    @ObservationIgnored let dataRoot: URL
    @ObservationIgnored let desktop: DesktopStatusLine
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    /// The fingerprint the current inspection was made from (unchanged files are not re-parsed).
    @ObservationIgnored private var inspectedStamp: FileStamp?
    @ObservationIgnored private var inspecting: Task<Void, Never>?
    @ObservationIgnored private let indexQueue = DispatchQueue(label: CoddIdentity.label("claude-settings-backups"), qos: .utility)

    static let backupsIndexName = "claude-settings-backups.json"
    /// The index keeps the newest entries only.
    static let backupsIndexLimit = 200

    init(settingsURL: URL, dataRoot: URL, now: @escaping @MainActor () -> Date = { Date() },
         log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.settingsURL = settingsURL
        self.dataRoot = dataRoot
        desktop = DesktopStatusLine(dataRoot: dataRoot.path)
        self.now = now
        self.log = log
    }

    var backupsIndexURL: URL { dataRoot.appendingPathComponent(Self.backupsIndexName) }

    /// `~/.claude/settings.json` (or the temp path a test root uses).
    var displayPath: String { HolderSessionStore.abbreviate(settingsURL.path) }

    // MARK: Inspection

    /// Re-inspects when the file changed since the last inspection (size, mtime, inode), or always
    /// with `force`. Concurrent calls share one read.
    func refreshInspection(force: Bool = false) async {
        if let inspecting { return await inspecting.value }
        let url = settingsURL
        let desktop = self.desktop
        let known = force ? nil : inspectedStamp
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (FileStamp?, InspectionState?) in
                let stamp = FileStamp.of(url.path)
                if let known, known == stamp { return (stamp, nil) }
                return (stamp, Self.inspect(url, desktop: desktop))
            }.value
            guard let self else { return }
            self.inspectedStamp = result.0
            if let state = result.1, state != self.inspection { self.inspection = state }
        }
        inspecting = task
        await task.value
        inspecting = nil
    }

    /// Blocking: loads and inspects the file.
    nonisolated static func inspect(_ url: URL, desktop: DesktopStatusLine) -> InspectionState {
        do throws(ClaudeSettingsError) {
            let file = try ClaudeSettingsFile.load(url)
            return .loaded(ClaudeSettingsInstaller.inspect(file, desktop: desktop), exists: file.exists)
        } catch {
            return .failed(message(for: error))
        }
    }

    // MARK: Plans and writes

    /// The preview of `action` (off the main actor; nothing is written).
    func plan(_ action: InstallerAction) async -> Result<InstallerPlan, ClaudeSettingsError> {
        let url = settingsURL
        let desktop = self.desktop
        let at = now()
        let result = await Task.detached(priority: .userInitiated) { () -> Result<InstallerPlan, ClaudeSettingsError> in
            do throws(ClaudeSettingsError) {
                let file = try ClaudeSettingsFile.load(url)
                return .success(try ClaudeSettingsInstaller.plan(file, action: action, desktop: desktop, now: at))
            } catch {
                return .failure(error)
            }
        }.value
        if case .success(let plan) = result { lastPlan = plan }
        log("installer plan action=\(Self.actionName(action)) changes=\(result.successValue?.changes ?? false) "
            + "+\(result.successValue?.addedLines ?? 0) -\(result.successValue?.removedLines ?? 0)\(result.failureValue.map { " error=\(Self.errorKind($0))" } ?? "")")
        return result
    }

    /// Writes `plan` (backup first when the file exists), records the backup in
    /// `<dataRoot>/claude-settings-backups.json` and inspects the file again. Refused (nothing
    /// written) when the file changed since the plan.
    func apply(_ plan: InstallerPlan) async -> Result<URL?, ClaudeSettingsError> {
        guard !isApplying else { return .failure(.writeFailed("另一個寫入正在進行")) }
        isApplying = true
        defer { isApplying = false }
        let url = settingsURL
        let result = await Task.detached(priority: .userInitiated) { () -> Result<URL?, ClaudeSettingsError> in
            do throws(ClaudeSettingsError) {
                return .success(try ClaudeSettingsInstaller.apply(plan, to: url))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let backup):
            let at = now()
            lastApplied = (backup?.lastPathComponent, plan.action, at)
            if let backup { recordBackup(name: backup.lastPathComponent, reason: plan.action.backupReason, at: at) }
            log("installer applied action=\(Self.actionName(plan.action)) backup=\(backup?.lastPathComponent ?? "-")")
        case .failure(let error):
            log("installer apply refused action=\(Self.actionName(plan.action)) (\(Self.errorKind(error)))")
        }
        await refreshInspection(force: true)
        return result
    }

    /// D10: one entry per backup in `<dataRoot>/claude-settings-backups.json` (0600, atomic), the
    /// settings path abbreviated. Written in call order off the main actor.
    private func recordBackup(name: String, reason: String, at: Date) {
        let url = backupsIndexURL
        let fields = ["name": name, "reason": reason, "at": JSDate.isoString(at), "settingsPath": displayPath]
        let log = self.log
        let limit = Self.backupsIndexLimit
        indexQueue.async {
            // M5 D14: never over a newer CODD's index (the backup file itself was still made).
            guard VersionGuard.mayReplace(url, key: "v", current: Self.backupsIndexVersion) else {
                let found = VersionGuard.existingVersion(of: url, key: "v") ?? 0
                Task { @MainActor in log("error \(Self.backupsIndexName) is v\(found) (newer CODD): entry not written") }
                return
            }
            var entries = Self.readIndex(url)
            entries.append(fields)
            if entries.count > limit { entries.removeFirst(entries.count - limit) }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["v": Self.backupsIndexVersion, "backups": entries],
                                                      options: [.prettyPrinted, .sortedKeys])
                try Self.writeAtomically(data, to: url)
            } catch {
                Task { @MainActor in log("error \(Self.backupsIndexName) not written (\(error))") }
            }
        }
    }

    /// Waits for pending index writes (tests, quit).
    func flushIndex() { indexQueue.sync {} }

    /// Settings › HOOKS & STATUS backups: `settings.json.codd-bak-…` next to the file, newest first,
    /// each with the reason the D10 index recorded for it (nil for a backup CODD did not note).
    /// Off the main actor (a directory listing).
    func backups() async -> [(backup: SettingsBackup, reason: String?)] {
        let url = settingsURL
        let index = backupsIndexURL
        let queue = indexQueue
        return await Task.detached(priority: .utility) { () -> [(backup: SettingsBackup, reason: String?)] in
            // After the pending index writes, so a fresh backup has its reason.
            let entries = queue.sync { Self.readIndex(index) }
            var reasons: [String: String] = [:]
            for entry in entries {
                if let name = entry["name"] as? String, let reason = entry["reason"] as? String { reasons[name] = reason }
            }
            return ClaudeSettingsInstaller.backups(of: url).map { ($0, reasons[$0.url.lastPathComponent]) }
        }.value
    }

    /// The backup file a Settings row names (only a `settings.json.codd-bak-…` sibling of the file).
    func backupURL(named name: String) -> URL? {
        let file = settingsURL.lastPathComponent
        guard name.hasPrefix(file + ".codd-bak-"), !name.contains("/") else { return nil }
        return settingsURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// The `v` this build writes into the backups index.
    nonisolated static let backupsIndexVersion = 1

    /// The index's entries (newest last); an unreadable or foreign file reads as empty. M5 D14: a
    /// newer version's index (an integer `v` above 1) is read as far as its entries are objects.
    nonisolated static func readIndex(_ url: URL) -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url), data.count <= 4 << 20,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["v"] as? Int, version >= backupsIndexVersion else { return [] }
        if version == backupsIndexVersion, let backups = object["backups"] as? [[String: Any]] { return backups }
        return ((object["backups"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }
    }

    nonisolated static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory + "/.\(url.lastPathComponent).\(getpid()).tmp"
        guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary, url.path) == 0 else {
            try? FileManager.default.removeItem(atPath: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // MARK: DEBUG apply guard

    /// `-codd-hooks-apply YES` writes only when the run named its Claude files (`-codd-claude-dir`
    /// or `-codd-claude-settings`) and the target, symlinks resolved, is not inside the real
    /// `~/.claude`. Path logic only: nothing is written or created to decide.
    nonisolated static func isDebugApplyAllowed(target: URL, claudeDirGiven: Bool, settingsGiven: Bool,
                                                home: String = NSHomeDirectory()) -> (allowed: Bool, reason: String) {
        guard claudeDirGiven || settingsGiven else { return (false, "no -codd-claude-dir or -codd-claude-settings") }
        let real = resolvedPath(target.path)
        let claude = resolvedPath(home + "/.claude")
        if real == claude || real.hasPrefix(claude + "/") { return (false, "the target resolves into the real ~/.claude") }
        let claudeJSON = resolvedPath(home + "/.claude.json")
        if real == claudeJSON { return (false, "the target is the real ~/.claude.json") }
        return (true, "ok")
    }

    /// The path with every symlink resolved: the file itself when it exists, else its nearest
    /// existing ancestor (the rest appended), so a link pointing into `~/.claude` is seen through.
    nonisolated static func resolvedPath(_ path: String) -> String {
        var remainder: [String] = []
        var current = (path as NSString).standardizingPath
        while !current.isEmpty, current != "/" {
            if let real = realpath(current, nil) {
                defer { free(real) }
                let base = String(cString: real)
                return remainder.isEmpty ? base : base + "/" + remainder.reversed().joined(separator: "/")
            }
            remainder.append((current as NSString).lastPathComponent)
            current = (current as NSString).deletingLastPathComponent
        }
        return "/" + remainder.reversed().joined(separator: "/")
    }

    // MARK: Copy

    /// 繁體中文 for the dialog, the toast and STATUS (no file content, D10).
    nonisolated static func message(for error: ClaudeSettingsError) -> String {
        switch error {
        case .changedSinceRead: "settings.json 在預覽後被改過，請重新預覽"
        case .invalidJSON(let line, let column): "settings.json 不是有效的 JSON（第 \(line) 行第 \(column) 欄），CODD 不會改動它"
        case .notAnObject: "settings.json 的最外層不是物件，CODD 不會改動它"
        case .shapeNotSupported(let path): "settings.json 的 \(path) 格式 CODD 不支援，不會改動它"
        case .chainUndecodable: "statusLine 串接的指令無法解碼，CODD 不會改動它"
        case .backupFailed(let reason): "無法備份 settings.json（\(reason)），沒有寫入任何東西"
        case .writeFailed(let reason): "無法寫入 settings.json（\(reason)）"
        case .unreadable(let reason): "無法讀取 settings.json（\(reason)）"
        case .tooLarge: "settings.json 超過 4 MiB，CODD 不會改動它"
        }
    }

    /// `update`, `remove-legacy`, … (logs, the dump, `-codd-hooks-plan`).
    nonisolated static func actionName(_ action: InstallerAction) -> String {
        switch action {
        case .update: "update"
        case .removeLegacy: "remove-legacy"
        case .uninstall: "uninstall"
        case .disableDuplicateNotifications: "disable-notifications"
        case .restore: "restore"
        }
    }

    nonisolated static func action(named name: String) -> InstallerAction? {
        switch name.lowercased() {
        case "update": .update
        case "remove-legacy": .removeLegacy
        case "uninstall": .uninstall
        case "disable-notifications": .disableDuplicateNotifications
        default: nil
        }
    }

    /// A log-safe name (never content).
    nonisolated static func errorKind(_ error: ClaudeSettingsError) -> String {
        switch error {
        case .changedSinceRead: "changedSinceRead"
        case .invalidJSON(let line, let column): "invalidJSON \(line):\(column)"
        case .notAnObject: "notAnObject"
        case .shapeNotSupported(let path): "shapeNotSupported \(path)"
        case .chainUndecodable: "chainUndecodable"
        case .backupFailed: "backupFailed"
        case .writeFailed: "writeFailed"
        case .unreadable: "unreadable"
        case .tooLarge: "tooLarge"
        }
    }

    // MARK: Dialog B model

    /// The Hook 差異 dialog for a plan (summary, event chips, diff lines, foreign kept, the backup
    /// it will take).
    nonisolated static func diffModel(_ plan: InstallerPlan, settingsURL: URL, fileExists: Bool) -> HookDiffModel {
        let full = HolderSessionStore.abbreviate(settingsURL.path)
        let path = questionPath(full)
        var chips = plan.addedEvents.map { DiffChip("+ \($0)", kind: .added) }
        chips += plan.removedEvents.map { DiffChip("− \($0)", kind: .removed) }
        let emphasis = plan.addedEvents.map { "\"\($0)\"" }
        let lines = plan.diff.map { line -> DiffLineModel in
            let kind: DiffLineModel.Kind
            switch line.kind {
            case .hunk: kind = .hunk
            case .context: kind = .context
            case .added: kind = .added
            case .removed: kind = .removed
            case .elided: kind = .elided
            }
            let marks = kind == .added ? emphasis.filter { line.text.contains($0 + ":") } : []
            return DiffLineModel(kind, oldNumber: line.oldNumber, newNumber: line.newNumber, text: line.text, emphasis: marks)
        }
        let foreign = plan.foreignKept.map { "\($0.code) ×\($0.events.count)" }.joined(separator: " · ")
        let foreignChanged = plan.foreignChanges.map(\.text).joined(separator: " · ")
        let directory = (full as NSString).deletingLastPathComponent
        let backup = plan.changes && fileExists ? (directory.isEmpty ? plan.backupName : directory + "/" + plan.backupName) : ""
        var title = HookDiffModel.defaultApplyTitle
        if case .restore = plan.action { title = "還原" }
        return HookDiffModel(settingsPath: path, summary: plan.summary, chips: chips, lines: lines, added: plan.addedLines,
                             removed: plan.removedLines, foreignKept: foreign, foreignChanged: foreignChanged, backupPath: backup,
                             canApply: plan.changes,
                             applyTitle: title)
    }

    /// The dialog when no plan could be made (nothing to apply, the reason as the error line).
    nonisolated static func failedModel(_ error: ClaudeSettingsError, settingsURL: URL) -> HookDiffModel {
        HookDiffModel(settingsPath: questionPath(HolderSessionStore.abbreviate(settingsURL.path)), lines: [], added: 0, removed: 0,
                      canApply: false, error: message(for: error))
    }

    /// The dialog's question line fits one line (`預覽 ~/.claude/settings.json 變更`): a long path (a
    /// test root's) keeps its last three components (`…/home/.claude/settings.json`).
    nonisolated static func questionPath(_ path: String, limit: Int = 44) -> String {
        guard path.count > limit else { return path }
        let parts = path.split(separator: "/")
        return "…/" + parts.suffix(3).joined(separator: "/")
    }

    // MARK: Dump

    /// `installer {inspection, plan {action, added, removed, removedEvents, addedEvents, statusLineAfter, changes},
    /// applied {backup, action, at}}` (no file content; the status-line commands are not shown).
    var dumpObject: [String: Any] {
        var object: [String: Any] = ["settingsPath": displayPath]
        switch inspection {
        case .unknown:
            object["inspection"] = ["state": "unknown"]
        case .failed(let reason):
            object["inspection"] = ["state": "failed", "reason": reason]
        case .loaded(let found, let exists):
            var status: String
            var current: Any = NSNull()
            switch found.statusLine {
            case .none: status = "none"
            case .user: status = "user"
            case .coddWeb: status = "coddWeb"
            case .coddDesktop(_, let isCurrent): status = "coddDesktop"; current = isCurrent
            case .undecodable: status = "undecodable"
            }
            object["inspection"] = ["state": "loaded", "exists": exists, "legacyEvents": found.legacyHookEvents,
                                    "legacyHandlers": found.legacyHandlerCount, "statusLine": status, "current": current,
                                    "chained": found.chainedCommand != nil, "upToDate": found.isUpToDate,
                                    "duplicateNotifications": found.duplicateNotificationHandlers,
                                    "foreign": found.foreign.map { ["code": $0.code, "name": $0.name, "events": $0.events.count] }]
        }
        if let plan = lastPlan {
            object["plan"] = ["action": Self.actionName(plan.action), "changes": plan.changes, "added": plan.addedLines,
                              "removed": plan.removedLines, "removedEvents": plan.removedEvents, "addedEvents": plan.addedEvents,
                              "statusLineAfter": Self.statusLineKindName(plan.statusLineAfter, desktop: desktop),
                              "foreignKept": plan.foreignKept.map(\.code), "backupName": plan.backupName]
        } else {
            object["plan"] = NSNull()
        }
        if let applied = lastApplied {
            object["applied"] = ["backup": applied.backup.map { $0 as Any } ?? NSNull(), "action": Self.actionName(applied.action),
                                 "at": JSDate.isoString(applied.at)]
        } else {
            object["applied"] = NSNull()
        }
        return object
    }

    /// What a plan's status line becomes, by kind (`desktop`, `user`, `none`): commands stay out of
    /// the dump.
    nonisolated static func statusLineKindName(_ command: String?, desktop: DesktopStatusLine) -> String {
        guard let command, !command.trimmingCharacters(in: .whitespaces).isEmpty else { return "none" }
        if command.contains(DesktopStatusLine.binaryMarker) { return DesktopStatusLine.parse(command) != nil ? "desktop" : "desktopOther" }
        if command.contains("codd-statusline.js") { return "coddWeb" }
        return "user"
    }
}

/// Size, modification time and inode of a path (a changed file is inspected again).
struct FileStamp: Equatable, Sendable {
    var size: Int64
    var mtime: Int64
    var inode: UInt64

    /// nil when the path does not exist (symlinks followed).
    static func of(_ path: String) -> FileStamp? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileStamp(size: Int64(info.st_size),
                         mtime: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                         inode: UInt64(info.st_ino))
    }
}

extension Result {
    var successValue: Success? { if case .success(let value) = self { return value } else { return nil } }
    var failureValue: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
