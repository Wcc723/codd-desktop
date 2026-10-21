import Darwin
import Foundation

/// What the user asked for in STATUS / Settings › HOOKS & STATUS (D10).
public enum InstallerAction: Sendable, Equatable {
    /// `更新`: remove CODD web leftovers and install / refresh CODD Desktop's global status line,
    /// chaining the web wrapper's inner command, else the user's own command.
    case update
    /// `只移除舊版`: CODD web leftovers only; its status-line wrapper becomes the inner command.
    case removeLegacy
    /// `解除安裝`: CODD Desktop's wrapper becomes its chained command again (legacy untouched).
    case uninstall
    /// `停用重複通知`: remove `osascript … display notification` on Notification / Stop.
    case disableDuplicateNotifications
    /// `還原`: the file becomes this backup's bytes (the current file is backed up first).
    case restore(URL)

    /// Why the backup taken before this action exists, for `<dataRoot>/claude-settings-backups.json`
    /// and the Settings backup list (`10/12 09:15 · 更新 hooks 與 statusline · 4.1 KB`).
    public var backupReason: String {
        switch self {
        case .update: "更新 hooks 與 statusline"
        case .removeLegacy: "移除舊版 CODD web 設定"
        case .uninstall: "解除安裝 CODD statusline"
        case .disableDuplicateNotifications: "停用重複通知"
        case .restore(let url): "還原 \(url.lastPathComponent) 之前"
        }
    }
}

/// A previewed change: everything the Hook 差異 dialog shows, plus the exact text `apply` writes.
public struct InstallerPlan: Sendable, Equatable {
    public var action: InstallerAction
    /// False when the written text would be identical (nothing to apply).
    public var changes: Bool
    /// 繁體中文 lines for the dialog.
    public var summary: [String]
    public var removedEvents: [String]
    public var addedEvents: [String]
    public var statusLineBefore: String?
    public var statusLineAfter: String?
    public var diff: [DiffLine]
    public var addedLines: Int
    public var removedLines: Int
    /// Other tools' hooks still in the file afterwards.
    public var foreignKept: [ForeignHookTool]
    /// Other tools' handlers the write removes or brings back (a restore; empty otherwise).
    public var foreignChanges: [ForeignHookChange]
    /// `settings.json.codd-bak-YYYYMMDD-HHMMSS[-n]`, next to the path the user gave.
    public var backupName: String
    public var newText: String
    /// The version the preview was made from; `apply` refuses any other. Nil: no file yet.
    public var base: SettingsFingerprint?

    public init(action: InstallerAction, changes: Bool, summary: [String], removedEvents: [String] = [],
                addedEvents: [String] = [], statusLineBefore: String? = nil, statusLineAfter: String? = nil,
                diff: [DiffLine] = [], addedLines: Int = 0, removedLines: Int = 0, foreignKept: [ForeignHookTool] = [],
                foreignChanges: [ForeignHookChange] = [], backupName: String, newText: String, base: SettingsFingerprint?) {
        self.foreignChanges = foreignChanges
        self.action = action
        self.changes = changes
        self.summary = summary
        self.removedEvents = removedEvents
        self.addedEvents = addedEvents
        self.statusLineBefore = statusLineBefore
        self.statusLineAfter = statusLineAfter
        self.diff = diff
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.foreignKept = foreignKept
        self.backupName = backupName
        self.newText = newText
        self.base = base
    }
}

public struct SettingsBackup: Sendable, Equatable {
    public var url: URL
    /// From the name's local-time stamp (the file's mtime when the name has none).
    public var date: Date
    public var size: Int64

    public init(url: URL, date: Date, size: Int64) {
        self.url = url
        self.date = date
        self.size = size
    }
}

/// The global installer for the user's Claude settings (D10). Only `hooks` and `statusLine`
/// ever change; every other key, the key order, number spellings, the indent and the trailing
/// newline are kept, and a file nothing changes in is never written.
public enum ClaudeSettingsInstaller {
    /// Builds the preview. Reads a restore source and lists the directory for a free backup
    /// name, but never writes.
    public static func plan(_ f: ClaudeSettingsFile, action: InstallerAction, desktop: DesktopStatusLine,
                            now: Date) throws(ClaudeSettingsError) -> InstallerPlan {
        let old = f.root
        var new = old
        var summary: [String] = []
        var removedEvents: [String] = []
        var addedEvents: [String] = []
        var shown: (String, HookTree.Members) -> Bool = { _, handler in HookTree.isLegacy(handler) }
        var newIndent = f.indent
        var newTrailingNewline = f.trailingNewline
        var restoreText: String?
        var foreignPrefix: String? = "外部 hooks 保持不動"
        var foreignChanges: [ForeignHookChange] = []
        var changedForeign = Set<String>()

        switch action {
        case .update:
            try HookTree.checkShape(old)
            let kind = try statusLineKind(old)
            let removal = try HookTree.removeHandlers(from: &new) { _, h in HookTree.isLegacy(h) }
            removedEvents = removal.events
            if removal.handlers > 0 { summary.append(legacySummary(removal)) }
            let base: String?
            let line: String
            switch kind {
            case .none:
                base = nil
                line = "安裝 CODD statusline（目前沒有 statusline，只回報用量）"
            case .user(let command):
                base = command
                line = "安裝 CODD statusline，串接原本的 statusline"
            case .web(let inner?):
                // CODD web's wrapper goes; the command it chained is chained by CODD's instead.
                base = inner
                line = "安裝 CODD statusline，串接原本的 statusline"
            case .web(nil):
                base = nil
                line = "安裝 CODD statusline，取代 CODD web 的 statusline"
            case .desktop(let chain):
                base = chain
                line = "更新 CODD statusline 的路徑（串接的 statusline 不變）"
            case .webUndecodable, .desktopUndecodable:
                throw .chainUndecodable
            }
            let before = new["statusLine"]
            setStatusLineCommand(&new, desktop.command(chain: base), type: true)
            if new["statusLine"] != before { summary.append(line) }

        case .removeLegacy:
            try HookTree.checkShape(old)
            let kind = try statusLineKind(old)
            if kind == .webUndecodable { throw .chainUndecodable }
            let removal = try HookTree.removeHandlers(from: &new) { _, h in HookTree.isLegacy(h) }
            removedEvents = removal.events
            if removal.handlers > 0 { summary.append(legacySummary(removal)) }
            switch kind {
            case .web(let inner?):
                setStatusLineCommand(&new, inner, type: false)
                summary.append("CODD web 的 statusline 換回原本的 statusline")
            case .web(nil):
                removeStatusLineCommand(&new)
                summary.append("移除 CODD web 的 statusline（安裝前沒有 statusline）")
            default:
                break
            }

        case .uninstall:
            let kind = try statusLineKind(old)
            switch kind {
            case .desktop(let chain?):
                setStatusLineCommand(&new, chain, type: false)
                summary.append("解除安裝 CODD statusline，換回原本串接的 statusline")
            case .desktop(nil):
                removeStatusLineCommand(&new)
                summary.append("解除安裝 CODD statusline（安裝前沒有 statusline）")
            case .desktopUndecodable:
                throw .chainUndecodable
            default:
                break
            }

        case .disableDuplicateNotifications:
            try HookTree.checkShape(old)
            shown = { event, h in HookTree.isLegacy(h) || HookTree.isDuplicateNotification(event: event, h) }
            let removal = try HookTree.removeHandlers(from: &new) { event, h in HookTree.isDuplicateNotification(event: event, h) }
            removedEvents = removal.events
            if removal.handlers > 0 {
                summary.append("停用 \(removal.handlers) 個重複的 osascript 通知（\(removal.events.joined(separator: ", "))）· 改由 CODD 通知")
            }
            foreignPrefix = "其他外部 hooks 保持不動"

        case .restore(let source):
            guard let read = try SettingsFS.read(source.path, maxBytes: 4 << 20) else {
                throw .unreadable(SettingsFS.errnoText("open", ENOENT))
            }
            let backup = try ClaudeSettingsFile.decode(read.data, url: source, fingerprint: nil)
            new = backup.root
            newIndent = backup.indent
            newTrailingNewline = backup.trailingNewline
            restoreText = String(decoding: read.data, as: UTF8.self)
            let oldEvents = old["hooks"]?.objectMembers?.map(\.key) ?? []
            let newEvents = new["hooks"]?.objectMembers?.map(\.key) ?? []
            removedEvents = oldEvents.filter { !newEvents.contains($0) }
            addedEvents = newEvents.filter { !oldEvents.contains($0) }
            summary.append("還原備份 \(source.lastPathComponent)")
            // Say what the restore does to other tools' hooks and which other settings it
            // reverts, instead of one generic line (M3 review).
            let foreign = foreignChangesBetween(old: old, new: new)
            foreignChanges = foreign.changes
            changedForeign = foreign.keys
            // The program is named once when the tool has no other name (`hook-tap`).
            for change in foreignChanges where change.removed > 0 {
                let code = change.name == change.code ? "" : "\(change.code)，"
                summary.append("會移除 \(change.name) 的 \(change.removed) 個 hook（\(code)備份裡沒有）")
            }
            for change in foreignChanges where change.added > 0 {
                let code = change.name == change.code ? "" : "（\(change.code)）"
                summary.append("會加回 \(change.name) 的 \(change.added) 個 hook\(code)")
            }
            let reverted = changedKeysOutsideScope(old: old, new: new)
            if !reverted.isEmpty {
                summary.append("hooks 與 statusLine 以外也會還原：" + reverted.joined(separator: ", "))
            }
            foreignPrefix = nil
        }

        let oldText = f.exists ? f.serializedText : ""
        let newText = restoreText ?? ClaudeSettingsFile.text(new, indent: newIndent, trailingNewline: newTrailingNewline)
        let changes: Bool
        if f.exists {
            changes = newText != oldText
        } else if case .restore = action {
            changes = true
        } else {
            changes = new != old
        }

        let foreignKept = foreignTools(in: new)
        if changes, let foreignPrefix, !foreignKept.isEmpty {
            summary.append(foreignPrefix + "：" + foreignKept.map { "\($0.code) ×\($0.events.count)" }.joined(separator: " · "))
        }
        if changes, f.exists, !f.isCanonical, restoreText == nil {
            summary.append("目前的排版不是 Claude Code 的標準格式：寫入後每個值都不變，但整份檔案的空白與換行會重新排列")
        }
        if !changes { summary = [unchangedSummary(action)] }

        var diff = SettingsDiff.Result()
        if changes {
            let tags = TagTable()
            let oldLines = f.exists
                ? SettingsLineRenderer.render(old, indent: f.indent, tags: tags, changedForeign: changedForeign, shown: shown) : []
            let newLines = SettingsLineRenderer.render(new, indent: newIndent, tags: tags, changedForeign: changedForeign, shown: shown)
            diff = SettingsDiff.make(old: oldLines, new: newLines)
        }

        return InstallerPlan(
            action: action, changes: changes, summary: summary, removedEvents: changes ? removedEvents : [],
            addedEvents: changes ? addedEvents : [], statusLineBefore: StatusLineKind.command(in: old),
            statusLineAfter: StatusLineKind.command(in: new), diff: diff.lines, addedLines: diff.added,
            removedLines: diff.removed, foreignKept: foreignKept, foreignChanges: changes ? foreignChanges : [],
            backupName: BackupName.firstFree(for: f.url, stamp: BackupName.stamp(now)),
            newText: newText, base: f.fingerprint)
    }

    /// Writes a plan: re-reads the file and refuses when it is not the previewed version, backs
    /// the current bytes up next to the path the user gave (the symlink target's bytes,
    /// `COPYFILE_EXCL`, mode kept), then replaces the target through a temp file and a rename
    /// (mode kept, 0644 for a new file; a symlinked settings.json stays a symlink). Returns the
    /// backup's URL (nil when there was no file, or nothing to write).
    public static func apply(_ p: InstallerPlan, to url: URL) throws(ClaudeSettingsError) -> URL? {
        guard p.changes else { return nil }
        let current = try SettingsFS.statTarget(url.path)
        guard current.map(SettingsFS.fingerprint) == p.base else { throw .changedSinceRead }
        let target = SettingsFS.writeTarget(url.path)
        var mode: mode_t = 0o644
        var backup: URL?
        if let current {
            guard (current.st_mode & S_IFMT) == S_IFREG else { throw .unreadable("not a regular file") }
            mode = current.st_mode & 0o777
            let copy = try makeBackup(of: target, nextTo: url, preferred: p.backupName)
            // A writer between the check and the copy would make the backup another version.
            guard (try SettingsFS.statTarget(url.path)).map(SettingsFS.fingerprint) == p.base else {
                unlink(copy.path)
                throw .changedSinceRead
            }
            backup = copy
        } else {
            try SettingsFS.ensureDirectory((target as NSString).deletingLastPathComponent)
        }
        try SettingsFS.replace(target, with: Data(p.newText.utf8), mode: mode)
        return backup
    }

    /// `<name>.codd-bak-*` files next to `url`, newest first.
    public static func backups(of url: URL) -> [SettingsBackup] {
        let directory = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var found: [(backup: SettingsBackup, index: Int, name: String)] = []
        for name in names where name.hasPrefix(fileName + BackupName.infix) {
            let entry = directory.appendingPathComponent(name)
            var info = stat()
            guard lstat(entry.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let parsed = BackupName.parse(name, fileName: fileName)
            let mtime = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
            found.append((SettingsBackup(url: entry, date: parsed?.date ?? mtime, size: Int64(info.st_size)),
                          parsed?.index ?? 0, name))
        }
        found.sort { a, b in
            if a.backup.date != b.backup.date { return a.backup.date > b.backup.date }
            if a.index != b.index { return a.index > b.index }
            return a.name > b.name
        }
        return found.map(\.backup)
    }

    // MARK: - Helpers

    private static func statusLineKind(_ root: OrderedJSON) throws(ClaudeSettingsError) -> StatusLineKind {
        if let value = root["statusLine"], !value.isObject { throw .shapeNotSupported("statusLine") }
        return StatusLineKind.classify(root)
    }

    private static func legacySummary(_ removal: HookTree.Removal) -> String {
        "移除 \(removal.events.count) 個 event 的舊版 CODD web hook（status-writer.js）"
    }

    /// Sets `statusLine.command` in place (and `type: "command"` when asked), creating the
    /// object when missing; other keys (padding, refreshInterval, …) keep their place.
    private static func setStatusLineCommand(_ root: inout OrderedJSON, _ command: String, type: Bool) {
        var statusLine = root["statusLine"] ?? .object([])
        if type { statusLine.setValue(.string("command"), forKey: "type") }
        statusLine.setValue(.string(command), forKey: "command")
        root.setValue(statusLine, forKey: "statusLine")
    }

    /// Drops `type` / `command`, and the whole `statusLine` when nothing else is left.
    private static func removeStatusLineCommand(_ root: inout OrderedJSON) {
        guard var statusLine = root["statusLine"] else { return }
        statusLine.removeValue(forKey: "type")
        statusLine.removeValue(forKey: "command")
        if statusLine.objectMembers?.isEmpty ?? true {
            root.removeValue(forKey: "statusLine")
        } else {
            root.setValue(statusLine, forKey: "statusLine")
        }
    }

    private static func foreignChangesBetween(old: OrderedJSON, new: OrderedJSON) -> (changes: [ForeignHookChange], keys: Set<String>) {
        foreignChangeKeys(old: old, new: new)
    }

    /// Top-level keys other than `hooks` / `statusLine` whose value differs, in file order
    /// (the current file's first, then keys only the other side has).
    private static func changedKeysOutsideScope(old: OrderedJSON, new: OrderedJSON) -> [String] {
        let oldKeys = old.objectMembers?.map(\.key) ?? [], newKeys = new.objectMembers?.map(\.key) ?? []
        var keys: [String] = []
        for key in oldKeys + newKeys where !SettingsDiff.scope.contains(key) && !keys.contains(key) {
            if old[key] != new[key] { keys.append(key) }
        }
        return keys
    }

    private static func withoutScope(_ root: OrderedJSON) -> OrderedJSON {
        var copy = root
        for key in SettingsDiff.scope { copy.removeValue(forKey: key) }
        return copy
    }

    private static func unchangedSummary(_ action: InstallerAction) -> String {
        switch action {
        case .update: "已是最新：沒有舊版 hook，CODD statusline 已安裝"
        case .removeLegacy: "沒有舊版 CODD web 項目需要移除"
        case .uninstall: "沒有安裝 CODD statusline，不需要變更"
        case .disableDuplicateNotifications: "沒有重複的 osascript 通知"
        case .restore: "目前的設定與備份相同，不需要還原"
        }
    }

    /// Copies `target` to `<dir of url>/<preferred>`, moving on to the next free `-n` name when
    /// another backup took it since the plan. `mode` (CODE-3): the copy is created with it instead
    /// of taking `target`'s mode, ACL included.
    static func makeBackup(of target: String, nextTo url: URL, preferred: String,
                           mode: mode_t? = nil) throws(ClaudeSettingsError) -> URL {
        let directory = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent
        let parsed = BackupName.parse(preferred, fileName: fileName)
        var name = preferred
        var index = parsed?.index ?? 1
        for _ in 0..<1000 {
            let destination = directory.appendingPathComponent(name)
            let failure: Int32?
            if let mode {
                failure = SettingsFS.copyExclusive(from: target, to: destination.path, mode: mode)
            } else {
                failure = SettingsFS.copyExclusive(from: target, to: destination.path)
            }
            guard let code = failure else { return destination }
            guard code == EEXIST, let parsed else {
                if code != EEXIST { unlink(destination.path) }
                throw .backupFailed(SettingsFS.errnoText("copyfile", code))
            }
            index += 1
            name = BackupName.name(fileName: fileName, stamp: parsed.stamp, index: index)
        }
        throw .backupFailed(SettingsFS.errnoText("copyfile", EEXIST))
    }
}

/// `settings.json.codd-bak-YYYYMMDD-HHMMSS` (local time), then `-2`, `-3`… when taken.
enum BackupName {
    static let infix = ".codd-bak-"

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static func stamp(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func name(fileName: String, stamp: String, index: Int) -> String {
        index <= 1 ? "\(fileName)\(infix)\(stamp)" : "\(fileName)\(infix)\(stamp)-\(index)"
    }

    static func firstFree(for url: URL, stamp: String) -> String {
        let directory = url.deletingLastPathComponent()
        var index = 1
        while true {
            let candidate = name(fileName: url.lastPathComponent, stamp: stamp, index: index)
            if !SettingsFS.lstatExists(directory.appendingPathComponent(candidate).path) { return candidate }
            index += 1
        }
    }

    /// The stamp, the collision index (1 for none) and the local date of a backup name.
    static func parse(_ name: String, fileName: String) -> (stamp: String, index: Int, date: Date)? {
        let prefix = fileName + infix
        guard name.hasPrefix(prefix) else { return nil }
        let rest = Array(name.dropFirst(prefix.count).utf8)
        guard rest.count >= 15, rest[8] == UInt8(ascii: "-") else { return nil }
        let digits = rest[0..<8] + rest[9..<15]
        guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        var index = 1
        if rest.count > 15 {
            guard rest[15] == UInt8(ascii: "-"), rest.count > 16,
                  let n = Int(String(decoding: rest[16...], as: UTF8.self)), n >= 2
            else { return nil }
            index = n
        }
        func number(_ range: Range<Int>) -> Int { Int(String(decoding: rest[range], as: UTF8.self)) ?? 0 }
        let components = DateComponents(year: number(0..<4), month: number(4..<6), day: number(6..<8),
                                        hour: number(9..<11), minute: number(11..<13), second: number(13..<15))
        guard let date = calendar.date(from: components) else { return nil }
        return (String(decoding: rest[0..<15], as: UTF8.self), index, date)
    }
}
