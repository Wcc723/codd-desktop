import CryptoKit
import Darwin
import Foundation

/// One `mcpServers` entry of `~/.claude.json` as the registration rows need it (M4 D22, D23):
/// never more than its name, its `url`, whether it sends headers and whether its `X-CODD-Token`
/// is the current token.
public struct ClaudeUserConfigMCPEntry: Sendable, Equatable {
    public var name: String
    /// The entry's `url` string (nil for a stdio server).
    public var url: String?
    /// A non-empty `headers` object.
    public var hasHeaders: Bool
    /// The `X-CODD-Token` header (name matched case-insensitively) equals the token asked
    /// about; false when the header is missing; nil when no token was given.
    public var tokenMatches: Bool?

    public init(name: String, url: String? = nil, hasHeaders: Bool = false, tokenMatches: Bool? = nil) {
        self.name = name
        self.url = url
        self.hasHeaders = hasHeaders
        self.tokenMatches = tokenMatches
    }
}

/// What the registration row shows about the user-scope `mcpServers` of `~/.claude.json`.
public struct ClaudeUserConfigMCPInspection: Sendable, Equatable {
    public var fileExists: Bool
    /// The file is strict JSON (false: CODD will not edit it).
    public var parsable: Bool
    /// The keys of the top-level `mcpServers` object in file order (empty when it is missing or
    /// not an object). Keys only: no server's configuration leaves the call.
    public var serverNames: [String]
    /// The entry pointing at CODD's endpoint (the `codd` one first when several do), else the
    /// entry named `codd` (another server under CODD's name), else nil.
    public var codd: ClaudeUserConfigMCPEntry?
    /// Size, mtime, inode and SHA-256 of what was read (nil: no file).
    public var fingerprint: SettingsFingerprint?
    /// CODE-3: the file's permission bits when its bytes hold a CODD token (an `X-CODD-Token`
    /// header, or the token asked about) and the group or others may read it; nil otherwise.
    public var exposedMode: mode_t?
    /// CODE-3: CODD's backups of the file (`<name>.codd-bak-*`) that hold a token with such a mode.
    public var exposedBackups: Int

    /// A register plan only tightens modes (``ClaudeUserConfigMCPPlan/modeOnly``) when nothing else changes.
    public var exposesToken: Bool { exposedMode != nil || exposedBackups > 0 }

    public init(fileExists: Bool, parsable: Bool, serverNames: [String] = [], codd: ClaudeUserConfigMCPEntry? = nil,
                fingerprint: SettingsFingerprint? = nil, exposedMode: mode_t? = nil, exposedBackups: Int = 0) {
        self.fileExists = fileExists
        self.parsable = parsable
        self.serverNames = serverNames
        self.codd = codd
        self.fingerprint = fingerprint
        self.exposedMode = exposedMode
        self.exposedBackups = exposedBackups
    }
}

/// `註冊` / `移除` of CODD's server in Claude Code's user scope.
public enum ClaudeUserConfigMCPAction: Sendable, Equatable {
    /// Adds or replaces `mcpServers.<name>` with `{"type":"http","url":…,"headers":{"X-CODD-Token":…}}`.
    case register(name: String, url: String, token: String)
    /// Deletes `mcpServers.<name>` (an empty `mcpServers` object stays).
    case remove(name: String)

    public var name: String {
        switch self {
        case .register(let name, _, _), .remove(let name): name
        }
    }

    /// The reason recorded with the backup in `claude-settings-backups.json`.
    public var backupReason: String {
        switch self {
        case .register: "mcp-register"
        case .remove: "mcp-remove"
        }
    }
}

/// The token never appears in a log line, a dump or `print(plan)`.
extension ClaudeUserConfigMCPAction: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .register(let name, let url, _): "register(name: \(name), url: \(url), token: ••••)"
        case .remove(let name): "remove(name: \(name))"
        }
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: ["action": description]) }
}

/// The registration preview: what the diff dialog shows and what `apply` checks against.
public struct ClaudeUserConfigMCPPlan: Sendable, Equatable {
    public var action: ClaudeUserConfigMCPAction
    /// Only the `mcpServers` member; other servers elided (`…（保留既有 n 個 MCP server）`), header
    /// and env values (the token included) shown as `"••••"`.
    public var diff: [DiffLine]
    /// One 繁體中文 line, e.g. `只會在 mcpServers 加入 codd，其他設定不變`.
    public var summary: String
    /// Nothing would change; `apply` writes nothing.
    public var upToDate: Bool
    /// The version the preview was made from (size, mtime, inode, SHA-256).
    public var fingerprint: SettingsFingerprint?
    /// SHA-256 of the exact bytes of the `mcpServers` value the preview was made from (nil: the
    /// file had none). `apply` edits a file Claude rewrote since the preview only when its
    /// member still hashes to this. A digest rather than the bytes: they hold other servers'
    /// secrets, and plans end up in dumps.
    public var baseMemberDigest: String?
    public var addedLines: Int
    public var removedLines: Int
    /// `.claude.json.codd-bak-YYYYMMDD-HHMMSS[-n]`, next to the file (`apply` moves on to the next
    /// free `-n` should another backup take it first).
    public var backupName: String
    /// CODE-3: one 繁體中文 line when `apply` writes the file or its backup as 0600 instead of the
    /// file's group- or world-readable mode (they hold the token), e.g.
    /// `檔案權限 0644 → 0600：內含 token，不讓其他帳號讀取（備份同樣 0600）`; nil when the mode stays.
    public var modeNote: String?
    /// CODE-3: `mcpServers` is already right, but the file or CODD's backups of it hold a token the
    /// group or others may read (a registration made before CODD wrote such files 0600): `apply`
    /// only makes them 0600, takes no backup and changes no byte. `upToDate` is false.
    public var modeOnly: Bool

    public init(action: ClaudeUserConfigMCPAction, diff: [DiffLine] = [], summary: String, upToDate: Bool,
                fingerprint: SettingsFingerprint?, baseMemberDigest: String? = nil, addedLines: Int = 0,
                removedLines: Int = 0, backupName: String = "", modeNote: String? = nil, modeOnly: Bool = false) {
        self.action = action
        self.diff = diff
        self.summary = summary
        self.upToDate = upToDate
        self.fingerprint = fingerprint
        self.baseMemberDigest = baseMemberDigest
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.backupName = backupName
        self.modeNote = modeNote
        self.modeOnly = modeOnly
    }
}

public struct ClaudeUserConfigMCPResult: Sendable, Equatable {
    /// The copy of the replaced bytes (nil when nothing was written).
    public var backup: URL?
    public var wrote: Bool
    /// Why the backups index entry could not be written (the file itself was written).
    public var indexError: String?
    /// CODE-3: files made 0600 besides the write: the file of a ``ClaudeUserConfigMCPPlan/modeOnly``
    /// plan and CODD's older backups of it that hold a token.
    public var tightened: Int

    public init(backup: URL?, wrote: Bool, indexError: String? = nil, tightened: Int = 0) {
        self.backup = backup
        self.wrote = wrote
        self.indexError = indexError
        self.tightened = tightened
    }
}

/// Why inspecting, planning or applying stopped. No case carries file content.
public enum ClaudeUserConfigMCPError: Error, Sendable, Equatable {
    /// The App says `找不到 ~/.claude.json，請先執行一次 claude`.
    case missingFile
    /// Where the file stops being JSON (`line 3, column 7`); the file is never touched.
    case invalidJSON(String)
    /// The `mcpServers` member (or the file's parsability) changed since the preview.
    case changedSinceRead
    /// Another writer held `~/.claude.json.lock` for the whole wait (or took it over).
    case lockBusy
    /// The 繁體中文 message: `~/.claude.json.lock 看起來是殘留的鎖，請確認沒有 claude 在執行後再試`.
    case staleLock(String)
    /// The top level, or the `mcpServers` member a registration edits, is not an object.
    case notAnObject
    /// An operation and its errno text (`open: Permission denied`).
    case io(String)
}

/// Registers CODD's MCP server in Claude Code's user scope: the top-level `mcpServers` of
/// `~/.claude.json` (M4 D22). Only that member changes and only by splicing bytes, so every other
/// byte of a file Claude rewrites every few seconds stays as Claude wrote it. Writes take Claude's
/// own lock (``UserConfigLock``), re-read under it, and rebase the previewed edit onto a file
/// Claude changed elsewhere since the preview. The path is injectable: tests use temp files only.
/// Blocking I/O: call off the main actor.
public struct ClaudeUserConfigMCPInstaller: Sendable {
    /// Larger files are refused (Claude's real file is a few MB).
    public static let maximumBytes = 64 << 20
    public static let tokenHeader = "X-CODD-Token"
    static let member = "mcpServers"
    /// Re-reads under the lock when a writer that ignores the lock changes the file mid-write.
    static let attempts = 3

    public let file: URL
    public let backupsIndex: URL?
    public let lockWait: Duration
    public let clock: @Sendable () -> Date
    /// Tests: runs right after the lock is taken, before the re-read.
    var afterLock: (@Sendable () -> Void)?

    public init(file: URL, backupsIndex: URL?, clock: @escaping @Sendable () -> Date = { Date() },
                lockWait: Duration = .seconds(3)) {
        self.file = file
        self.backupsIndex = backupsIndex
        self.clock = clock
        self.lockWait = lockWait
    }

    /// The file's path normalised like node's `path.join` (`.` and `..` removed lexically, no
    /// symlink resolved), which is how Claude names its config.
    public var path: String { Self.lexicalPath(file.path) }

    /// `<path>.lock`: Claude's `lockfilePath` (next to the path, not to a symlink's target).
    public var lockPath: String { path + ".lock" }

    // MARK: Inspect

    public func inspect(ourURL: String, token: String?) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPInspection {
        guard let read = try readFile() else { return ClaudeUserConfigMCPInspection(fileExists: false, parsable: false) }
        let exposed = exposure(read.data, token: token)
        let snapshot: UserConfigSnapshot
        do throws(ClaudeUserConfigMCPError) {
            snapshot = try UserConfigSnapshot(read.data, validate: true)
        } catch {
            if case .invalidJSON = error {
                return ClaudeUserConfigMCPInspection(fileExists: true, parsable: false, fingerprint: read.fingerprint,
                                                     exposedMode: exposed.mode, exposedBackups: exposed.backups.count)
            }
            throw error
        }
        guard case .object(let servers)? = snapshot.servers else {
            return ClaudeUserConfigMCPInspection(fileExists: true, parsable: true, fingerprint: read.fingerprint,
                                                 exposedMode: exposed.mode, exposedBackups: exposed.backups.count)
        }
        let pointing = servers.filter { $0.value["url"]?.stringValue == ourURL }
        let chosen = pointing.first { $0.key == "codd" } ?? pointing.first ?? servers.last { $0.key == "codd" }
        let entry = chosen.map { server -> ClaudeUserConfigMCPEntry in
            let headers = server.value["headers"]?.objectMembers
            let value = headers?.last { $0.key.caseInsensitiveCompare(Self.tokenHeader) == .orderedSame }?.value.stringValue
            return ClaudeUserConfigMCPEntry(name: server.key, url: server.value["url"]?.stringValue,
                                            hasHeaders: !(headers?.isEmpty ?? true),
                                            tokenMatches: token.map { t in value.map { Self.constantTimeEqual($0, t) } ?? false })
        }
        return ClaudeUserConfigMCPInspection(fileExists: true, parsable: true, serverNames: servers.map(\.key), codd: entry,
                                             fingerprint: read.fingerprint, exposedMode: exposed.mode,
                                             exposedBackups: exposed.backups.count)
    }

    // MARK: Plan

    /// The preview of `action`. Reads the file and lists its directory for a free backup name;
    /// never writes. A registration with nothing to change in `mcpServers` is a
    /// ``ClaudeUserConfigMCPPlan/modeOnly`` plan while the file or a CODD backup of it holds a
    /// token the group or others may read (CODE-3).
    public func plan(_ action: ClaudeUserConfigMCPAction) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPPlan {
        guard let read = try readFile() else { throw .missingFile }
        let snapshot = try UserConfigSnapshot(read.data, validate: true)
        let edit = try UserConfigEdit(snapshot, action)
        if edit.bytes == nil, case .register = action {
            let exposed = exposure(read.data, token: Self.token(of: action))
            if let note = Self.modeOnlyNote(file: exposed.mode, backups: exposed.backups.count) {
                return ClaudeUserConfigMCPPlan(action: action, summary: Self.modeOnlySummary, upToDate: false,
                                               fingerprint: read.fingerprint, baseMemberDigest: snapshot.memberDigest,
                                               modeNote: note, modeOnly: true)
            }
        }
        let diff = edit.bytes == nil ? SettingsDiff.Result() : Self.diff(snapshot, edit, target: action.name)
        var modeNote: String?
        if let bytes = edit.bytes, let info = try? SettingsFS.statTarget(path) {
            modeNote = Self.modeNote(Self.modes(info.st_mode & 0o777, old: read.data, new: bytes, action))
        }
        return ClaudeUserConfigMCPPlan(
            action: action, diff: diff.lines, summary: Self.summary(edit.change, action), upToDate: edit.bytes == nil,
            fingerprint: read.fingerprint, baseMemberDigest: snapshot.memberDigest, addedLines: diff.added,
            removedLines: diff.removed,
            backupName: BackupName.firstFree(for: URL(fileURLWithPath: path), stamp: BackupName.stamp(clock())),
            modeNote: modeNote)
    }

    // MARK: Apply

    /// Writes a plan under Claude's lock: re-reads the file; the previewed version gets the
    /// previewed edit, a version Claude changed outside `mcpServers` gets the same member edit on
    /// its fresh bytes, a changed `mcpServers` (or a file that no longer parses) is refused. The
    /// bytes replaced are backed up next to the file first (mode kept), the new bytes written
    /// through a temp file, `F_FULLFSYNC` and a rename (a symlink stays a symlink), the backup
    /// recorded in the index. The lock is released on every path. CODE-3: bytes that hold a CODD
    /// token (``modes(_:old:new:_:)``) are never left group- or world-readable: such a file or
    /// backup is written 0600 (the backup created so, never chmodded afterwards), and CODD's older
    /// backups that hold a token are made 0600 too. A ``ClaudeUserConfigMCPPlan/modeOnly`` plan
    /// changes only those modes, under the same lock and checks.
    public func apply(_ plan: ClaudeUserConfigMCPPlan) throws(ClaudeUserConfigMCPError) -> ClaudeUserConfigMCPResult {
        guard !plan.upToDate else { return ClaudeUserConfigMCPResult(backup: nil, wrote: false) }
        guard let base = plan.fingerprint else { throw .changedSinceRead }
        let lock = try UserConfigLock.acquire(lockPath, wait: lockWait, display: BackupsIndex.abbreviate(lockPath))
        defer { lock.release() }
        afterLock?()
        for _ in 0..<Self.attempts {
            guard let read = try readFile() else { throw .missingFile }
            let snapshot: UserConfigSnapshot
            if read.fingerprint == base {
                snapshot = try UserConfigSnapshot(read.data, validate: false)
            } else {
                do throws(ClaudeUserConfigMCPError) {
                    snapshot = try UserConfigSnapshot(read.data, validate: true)
                } catch {
                    if case .io = error { throw error }
                    throw .changedSinceRead
                }
                guard snapshot.memberDigest == plan.baseMemberDigest else { throw .changedSinceRead }
            }
            let edit = try UserConfigEdit(snapshot, plan.action)
            guard let bytes = edit.bytes else {
                guard plan.modeOnly else { return ClaudeUserConfigMCPResult(backup: nil, wrote: false) }
                return ClaudeUserConfigMCPResult(backup: nil, wrote: false, tightened: tighten(read.data, plan.action))
            }
            try lock.refresh()

            let target = SettingsFS.writeTarget(path)
            let found: stat?
            do throws(ClaudeSettingsError) {
                found = try SettingsFS.statTarget(path)
            } catch {
                throw Self.mapped(error)
            }
            guard let info = found else { throw .missingFile }
            let modes = Self.modes(info.st_mode & 0o777, old: read.data, new: bytes, plan.action)
            let backup: URL
            do throws(ClaudeSettingsError) {
                backup = try ClaudeSettingsInstaller.makeBackup(of: target, nextTo: URL(fileURLWithPath: path),
                                                                preferred: plan.backupName,
                                                                mode: modes.backup != modes.current ? modes.backup : nil)
            } catch {
                throw Self.mapped(error)
            }
            // The backup must hold exactly the bytes this write replaces.
            let copied = (try? Data(contentsOf: backup)) ?? Data()
            guard copied == read.data, Self.unchanged(path, since: read.fingerprint) else {
                unlink(backup.path)
                continue
            }
            let replaced: Bool
            do throws(ClaudeSettingsError) {
                replaced = try SettingsFS.replace(target, with: bytes, mode: modes.file) {
                    lock.isHeld && Self.unchanged(path, since: read.fingerprint)
                }
            } catch {
                unlink(backup.path)
                throw Self.mapped(error)
            }
            guard replaced else {
                unlink(backup.path)
                if !lock.isHeld { throw .lockBusy }
                continue
            }
            let indexError = backupsIndex.flatMap {
                BackupsIndex.record($0, name: backup.lastPathComponent, reason: plan.action.backupReason, at: clock(),
                                    settingsPath: path)
            }
            return ClaudeUserConfigMCPResult(backup: backup, wrote: true, indexError: indexError,
                                             tightened: tighten(nil, plan.action))
        }
        throw .changedSinceRead
    }

    // MARK: Helpers

    /// The permission bits of one write (CODE-3).
    struct Modes: Equatable {
        /// The file's mode before the write.
        var current: mode_t
        var file: mode_t
        var backup: mode_t
    }

    /// The token opens CODD's whole AI-visible notebook, so bytes that hold one are written 0600
    /// when `current` lets the group or others in: the new file when `new` holds it, the backup
    /// when `old` or `new` does. Any other mode stays as it was.
    static func modes(_ current: mode_t, old: Data, new: Data, _ action: ClaudeUserConfigMCPAction) -> Modes {
        guard current & 0o077 != 0 else { return Modes(current: current, file: current, backup: current) }
        let newHolds = holdsToken(new, action)
        return Modes(current: current, file: newHolds ? 0o600 : current,
                     backup: newHolds || holdsToken(old, action) ? 0o600 : current)
    }

    /// The bytes carry a CODD token: the one being registered, or any `X-CODD-Token` header.
    static func holdsToken(_ data: Data, _ action: ClaudeUserConfigMCPAction) -> Bool {
        holdsToken(data, token: token(of: action))
    }

    /// The bytes carry `token` or any `X-CODD-Token` header.
    static func holdsToken(_ data: Data, token: String?) -> Bool {
        if let token, !token.isEmpty, data.range(of: Data(token.utf8)) != nil { return true }
        return data.range(of: Data(tokenHeader.utf8)) != nil
    }

    static func token(of action: ClaudeUserConfigMCPAction) -> String? {
        if case .register(_, _, let token) = action { return token }
        return nil
    }

    /// CODE-3: what holds a token the group or others may read: the file (`data`, its bytes; the
    /// mode of its target) and CODD's backups of it.
    func exposure(_ data: Data, token: String?) -> (mode: mode_t?, backups: [URL]) {
        var mode: mode_t?
        if let info = try? SettingsFS.statTarget(path), info.st_mode & 0o077 != 0, Self.holdsToken(data, token: token) {
            mode = info.st_mode & 0o777
        }
        return (mode, Self.exposedBackups(of: path, token: token))
    }

    /// CODD's backups next to `path` (``ClaudeSettingsInstaller/backups(of:)``) that hold a token
    /// with a mode the group or others may read.
    static func exposedBackups(of path: String, token: String?) -> [URL] {
        ClaudeSettingsInstaller.backups(of: URL(fileURLWithPath: path)).compactMap { backup in
            var info = stat()
            guard lstat(backup.url.path, &info) == 0, info.st_mode & 0o077 != 0,
                  let read = try? SettingsFS.read(backup.url.path, maxBytes: maximumBytes),
                  holdsToken(read.data, token: token) else { return nil }
            return backup.url
        }
    }

    /// Makes the file (when `data`, its bytes, hold a token) and CODD's backups of it that hold one
    /// 0600 where the group or others may read them; how many files changed. Best effort: a file
    /// that cannot be changed keeps its mode.
    func tighten(_ data: Data?, _ action: ClaudeUserConfigMCPAction) -> Int {
        let token = Self.token(of: action)
        var count = 0
        if let data, let info = try? SettingsFS.statTarget(path), info.st_mode & 0o077 != 0,
           Self.holdsToken(data, token: token), chmod(SettingsFS.writeTarget(path), 0o600) == 0 {
            count += 1
        }
        for backup in Self.exposedBackups(of: path, token: token) where chmod(backup.path, 0o600) == 0 { count += 1 }
        return count
    }

    static let modeOnlySummary = "mcpServers 已是最新，只把含 token 的檔案權限改成 0600"

    /// Dialog B's line for a ``ClaudeUserConfigMCPPlan/modeOnly`` plan; nil when nothing is exposed.
    static func modeOnlyNote(file: mode_t?, backups: Int) -> String? {
        let others = backups > 0 ? "（另有 \(backups) 個備份同樣改成 0600）" : ""
        if let file {
            return "檔案權限 \(String(format: "%04o", UInt32(file))) → 0600：內含 token，不讓其他帳號讀取\(others)"
        }
        return backups > 0 ? "\(backups) 個備份檔權限改成 0600：內含 token，不讓其他帳號讀取" : nil
    }

    /// Dialog B's line for a write that tightens a mode; nil when every mode stays.
    static func modeNote(_ m: Modes) -> String? {
        func octal(_ mode: mode_t) -> String { String(format: "%04o", UInt32(mode)) }
        if m.file != m.current {
            return "檔案權限 \(octal(m.current)) → \(octal(m.file))：內含 token，不讓其他帳號讀取（備份同樣 \(octal(m.backup))）"
        }
        if m.backup != m.current {
            return "備份檔權限 \(octal(m.backup))：內含 token，不讓其他帳號讀取（檔案維持 \(octal(m.current))）"
        }
        return nil
    }

    /// The file's bytes and fingerprint (with SHA-256); nil when nothing is there.
    func readFile() throws(ClaudeUserConfigMCPError) -> (data: Data, fingerprint: SettingsFingerprint)? {
        do throws(ClaudeSettingsError) {
            guard let read = try SettingsFS.read(path, maxBytes: Self.maximumBytes) else { return nil }
            var fingerprint = read.fingerprint
            fingerprint.sha256 = Self.sha256Hex(read.data)
            return (read.data, fingerprint)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// The same version is on disk (stat only: size, mtime, inode).
    static func unchanged(_ path: String, since fingerprint: SettingsFingerprint) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return SettingsFS.fingerprint(info).sameStat(fingerprint)
    }

    static func mapped(_ error: ClaudeSettingsError) -> ClaudeUserConfigMCPError {
        switch error {
        case .unreadable(let reason), .writeFailed(let reason): .io(reason)
        case .backupFailed(let reason): .io("backup: \(reason)")
        case .tooLarge: .io("larger than 64 MiB")
        case .invalidJSON(let line, let column): .invalidJSON("line \(line), column \(column)")
        case .notAnObject: .notAnObject
        case .changedSinceRead: .changedSinceRead
        case .shapeNotSupported(let path): .io("unsupported shape: \(path)")
        case .chainUndecodable: .io("chain undecodable")
        }
    }

    static func diff(_ s: UserConfigSnapshot, _ edit: UserConfigEdit, target: String) -> SettingsDiff.Result {
        let gap = s.layout.gap.isEmpty ? "  " : String(decoding: s.layout.gap, as: UTF8.self)
        let tags = TagTable()
        let more = s.memberIndex.map { $0 < s.root.members.count - 1 } ?? false
        let old = UserConfigMCPDiff.render(s.servers, gap: gap, more: more, target: target, tags: tags)
        let new = UserConfigMCPDiff.render(edit.newServers, gap: gap, more: more, target: target, tags: tags)
        let start: Int
        if let index = s.memberIndex {
            start = s.lineIndex(before: s.root.members[index].keyStart) + 1
        } else if let last = s.root.members.last {
            // A new member goes after the last one's final line.
            start = s.lineIndex(before: last.valueEnd) + 2
        } else {
            start = s.lineIndex(before: s.root.start) + 2
        }
        return UserConfigMCPDiff.make(old: old, oldStart: start, new: new, newStart: start)
    }

    static func summary(_ change: UserConfigEdit.Change, _ action: ClaudeUserConfigMCPAction) -> String {
        let name = action.name
        switch change {
        case .created: return "會新增 mcpServers 並加入 \(name)，其他設定不變"
        case .added: return "只會在 mcpServers 加入 \(name)，其他設定不變"
        case .updatedToken: return "只會更新 mcpServers 裡 \(name) 的 token，其他設定不變"
        case .updated: return "只會更新 mcpServers 裡的 \(name)，其他設定不變"
        case .replaced: return "會取代 mcpServers 裡現有的 \(name)（原本指向其他伺服器），其他設定不變"
        case .removed: return "只會從 mcpServers 移除 \(name)，其他設定不變"
        case .none:
            if case .register = action { return "\(name) 已經註冊在 mcpServers，不需要變更" }
            return "mcpServers 裡沒有 \(name)，不需要變更"
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for k in x.indices { difference |= x[k] ^ y[k] }
        return difference == 0
    }

    /// `.` and `..` removed and slashes collapsed without touching the file system.
    static func lexicalPath(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// One read of the file with what an edit needs: the root's members and layout, the last
/// top-level `mcpServers` member (what `JSON.parse` keeps) with its parsed value and digest.
struct UserConfigSnapshot {
    var data: Data
    var root: JSONObjectSpan
    var layout: JSONLayout
    /// Index of the last `mcpServers` member in ``root``.
    var memberIndex: Int?
    /// That member's value.
    var servers: OrderedJSON?
    /// Its spans when it is an object.
    var serversObject: JSONObjectSpan?
    var memberDigest: String?

    /// `validate`: run the strict parser over the whole file first (skipped only for bytes a
    /// plan already validated, i.e. an identical fingerprint).
    init(_ data: Data, validate: Bool) throws(ClaudeUserConfigMCPError) {
        if validate {
            let tree: OrderedJSON
            do throws(OrderedJSONError) {
                tree = try OrderedJSON.parse(data)
            } catch {
                throw .invalidJSON("line \(error.line), column \(error.column)")
            }
            guard tree.isObject else { throw .notAnObject }
        }
        let found = data.withUnsafeBytes { raw -> (JSONObjectSpan, JSONLayout, Int?, JSONObjectSpan?, Data?)? in
            let b = raw.bindMemory(to: UInt8.self)
            guard let root = JSONSpans.object(b, at: JSONSpans.skipWhitespace(b, 0)) else { return nil }
            let index = root.members.lastIndex { $0.key == ClaudeUserConfigMCPInstaller.member }
            var object: JSONObjectSpan?
            var bytes: Data?
            if let index {
                let member = root.members[index]
                object = JSONSpans.object(b, at: member.valueStart)
                bytes = Data(UnsafeRawBufferPointer(rebasing: raw[member.valueStart..<member.valueEnd]))
            }
            return (root, JSONLayout.detect(b, root: root), index, object, bytes)
        }
        guard let found else { throw .notAnObject }
        self.data = data
        root = found.0
        layout = found.1
        memberIndex = found.2
        serversObject = found.3
        if let bytes = found.4 {
            do throws(OrderedJSONError) {
                servers = try OrderedJSON.parse(bytes)
            } catch {
                throw .invalidJSON("line \(error.line), column \(error.column)")
            }
            memberDigest = ClaudeUserConfigMCPInstaller.sha256Hex(bytes)
        }
    }

    func lineIndex(before offset: Int) -> Int {
        data.withUnsafeBytes { raw in JSONSpans.lineIndex(raw.bindMemory(to: UInt8.self), before: offset) }
    }
}

/// The new file bytes for an action on a snapshot: one splice inside the root or inside
/// `mcpServers`, everything else copied.
struct UserConfigEdit {
    enum Change: Equatable {
        case none
        /// `mcpServers` did not exist: appended at the end of the top-level object, as assigning
        /// it to the parsed object and `JSON.stringify` would place it.
        case created
        case added
        case updatedToken
        case updated
        /// The entry pointed elsewhere (another URL, a stdio server).
        case replaced
        case removed
    }

    var change: Change
    /// Nil: nothing changes.
    var bytes: Data?
    /// The member's value afterwards, for the diff.
    var newServers: OrderedJSON?

    static func entry(url: String, token: String) -> OrderedJSON {
        .object([(key: "type", value: .string("http")), (key: "url", value: .string(url)),
                 (key: "headers", value: .object([(key: ClaudeUserConfigMCPInstaller.tokenHeader, value: .string(token))]))])
    }

    init(_ s: UserConfigSnapshot, _ action: ClaudeUserConfigMCPAction) throws(ClaudeUserConfigMCPError) {
        change = .none
        newServers = s.servers
        switch action {
        case .register(let name, let url, let token):
            let desired = Self.entry(url: url, token: token)
            guard s.memberIndex != nil else {
                let servers = OrderedJSON.object([(key: name, value: desired)])
                let text = s.layout.member(ClaudeUserConfigMCPInstaller.member, servers, level: 1)
                bytes = Self.splice(s.data, s.root.start..<s.root.end) { b in
                    JSONObjectEdit.appending(b, object: s.root, memberText: text, level: 1, layout: s.layout)
                }
                change = .created
                newServers = servers
                return
            }
            guard let object = s.serversObject, var servers = s.servers else { throw .notAnObject }
            if let existing = servers[name], let span = object.members.last(where: { $0.key == name }) {
                guard !Self.sameValue(existing, desired) else { return }
                let text = s.layout.text(desired, level: 2)
                bytes = Self.splice(s.data, span.valueStart..<span.valueEnd) { _ in text }
                if existing["url"]?.stringValue == url {
                    let oldToken = existing["headers"]?.objectMembers?
                        .last { $0.key.caseInsensitiveCompare(ClaudeUserConfigMCPInstaller.tokenHeader) == .orderedSame }?.value
                    var rest = existing
                    rest.removeValue(forKey: "headers")
                    var desiredRest = desired
                    desiredRest.removeValue(forKey: "headers")
                    change = oldToken != .string(token) && Self.sameValue(rest, desiredRest) ? .updatedToken : .updated
                } else {
                    change = .replaced
                }
            } else {
                let text = s.layout.member(name, desired, level: 2)
                bytes = Self.splice(s.data, object.start..<object.end) { b in
                    JSONObjectEdit.appending(b, object: object, memberText: text, level: 2, layout: s.layout)
                }
                change = .added
            }
            servers.setValue(desired, forKey: name)
            newServers = servers

        case .remove(let name):
            guard let object = s.serversObject, var servers = s.servers,
                  object.members.contains(where: { $0.key == name }) else { return }
            bytes = Self.splice(s.data, object.start..<object.end) { b in
                JSONObjectEdit.removing(b, object: object) { object.members[$0].key != name }
            }
            servers.removeValue(forKey: name)
            newServers = servers
            change = .removed
        }
    }

    /// `data` with `range` replaced by what `make` builds from the whole buffer.
    static func splice(_ data: Data, _ range: Range<Int>, _ make: (UnsafeBufferPointer<UInt8>) -> [UInt8]) -> Data {
        data.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            let middle = make(b)
            var out = Data(capacity: b.count - range.count + middle.count)
            out.append(UnsafeBufferPointer(rebasing: b[0..<range.lowerBound]))
            out.append(contentsOf: middle)
            out.append(UnsafeBufferPointer(rebasing: b[range.upperBound..<b.count]))
            return out
        }
    }

    /// Equal as `JSON.parse` values: object member order ignored, numbers by value when both
    /// spellings read as doubles.
    static func sameValue(_ a: OrderedJSON, _ b: OrderedJSON) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            var left: [String: OrderedJSON] = [:], right: [String: OrderedJSON] = [:]
            for m in x { left[m.key] = m.value }
            for m in y { right[m.key] = m.value }
            guard left.count == right.count else { return false }
            for (key, value) in left {
                guard let other = right[key], sameValue(value, other) else { return false }
            }
            return true
        case let (.array(x), .array(y)):
            return x.count == y.count && zip(x, y).allSatisfy { sameValue($0, $1) }
        case let (.number(x), .number(y)):
            if x == y { return true }
            if let p = Double(x), let q = Double(y) { return p == q }
            return false
        default:
            return a == b
        }
    }
}
