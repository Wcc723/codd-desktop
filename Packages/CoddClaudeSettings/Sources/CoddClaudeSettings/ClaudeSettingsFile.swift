import Darwin
import Foundation

/// What a write checks before it replaces the file: the preview was made from exactly this
/// version (size, modification time and inode of the symlink's target).
public struct SettingsFingerprint: Sendable, Equatable {
    public var size: Int64
    public var mtimeNanoseconds: Int64
    public var inode: UInt64
    /// Lowercase hex SHA-256 of the bytes, for `~/.claude.json` (M4 D22), which Claude rewrites
    /// so often that a same-size rewrite within one mtime tick is plausible. Nil for the
    /// settings.json installer (M3 compares size, mtime and inode only).
    public var sha256: String?

    public init(size: Int64, mtimeNanoseconds: Int64, inode: UInt64, sha256: String? = nil) {
        self.size = size
        self.mtimeNanoseconds = mtimeNanoseconds
        self.inode = inode
        self.sha256 = sha256
    }

    /// The same version on disk, ignoring the content hash (a `stat` cannot give one).
    func sameStat(_ other: SettingsFingerprint) -> Bool {
        size == other.size && mtimeNanoseconds == other.mtimeNanoseconds && inode == other.inode
    }
}

/// Why loading, planning or applying stopped. No case carries file content (settings hold
/// tokens); `unreadable` / `backupFailed` / `writeFailed` carry an operation and the errno text.
public enum ClaudeSettingsError: Error, Equatable {
    case unreadable(String)
    case invalidJSON(line: Int, column: Int)
    case notAnObject
    /// The key path whose shape CODD will not edit: `hooks` (not an object), `hooks.<event>`
    /// (not an array) or `statusLine` (not an object).
    case shapeNotSupported(String)
    case changedSinceRead
    /// A CODD status-line wrapper whose `--chain-b64` does not round-trip: rewriting it would
    /// lose the user's own status line.
    case chainUndecodable
    case backupFailed(String)
    case writeFailed(String)
    case tooLarge
}

/// One Claude settings file as CODD read it, plus the formatting choices a rewrite keeps.
public struct ClaudeSettingsFile: Sendable, Equatable {
    /// The path as given (it may be a symlink; reads and writes go to its target).
    public var url: URL
    public var exists: Bool
    /// Always an object; `{}` for a missing or blank file.
    public var root: OrderedJSON
    /// The indent of the first nested line (two spaces when there is none).
    public var indent: String
    public var trailingNewline: Bool
    /// Nil when the file does not exist.
    public var fingerprint: SettingsFingerprint?
    /// The bytes on disk are exactly ``serializedText`` (what Claude Code itself writes). When
    /// false, a write keeps every value but re-lays out the whole file, which the hooks /
    /// statusLine diff cannot show, so the plan says so.
    public var isCanonical: Bool

    public init(url: URL, exists: Bool = true, root: OrderedJSON = .object([]), indent: String = "  ",
                trailingNewline: Bool = true, fingerprint: SettingsFingerprint? = nil, isCanonical: Bool = true) {
        self.url = url
        self.exists = exists
        self.root = root
        self.indent = indent
        self.trailingNewline = trailingNewline
        self.fingerprint = fingerprint
        self.isCanonical = isCanonical
    }

    /// The text CODD would write for ``root`` with this file's indent and newline choice.
    public var serializedText: String {
        Self.text(root, indent: indent, trailingNewline: trailingNewline)
    }

    static func text(_ root: OrderedJSON, indent: String, trailingNewline: Bool) -> String {
        root.serialized(indent: indent) + (trailingNewline ? "\n" : "")
    }

    /// Reads `url` (following a symlink). A missing file is `exists == false` with an empty
    /// object, so a first install can still be planned; a blank file counts as `{}`.
    public static func load(_ url: URL, maxBytes: Int = 4 << 20) throws(ClaudeSettingsError) -> ClaudeSettingsFile {
        guard let read = try SettingsFS.read(url.path, maxBytes: maxBytes) else {
            return ClaudeSettingsFile(url: url, exists: false)
        }
        return try decode(read.data, url: url, fingerprint: read.fingerprint)
    }

    static func decode(_ data: Data, url: URL, fingerprint: SettingsFingerprint?) throws(ClaudeSettingsError) -> ClaudeSettingsFile {
        let blank = data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        let root: OrderedJSON
        if blank {
            root = .object([])
        } else {
            do {
                root = try OrderedJSON.parse(data)
            } catch {
                throw .invalidJSON(line: error.line, column: error.column)
            }
        }
        guard root.isObject else { throw .notAnObject }
        var file = ClaudeSettingsFile(url: url, exists: true, root: root, indent: detectIndent(data),
                                      trailingNewline: data.last == 0x0A, fingerprint: fingerprint)
        file.isCanonical = blank || data.elementsEqual(file.serializedText.utf8)
        return file
    }

    /// The whitespace before the first member, as `^\{\r?\n([ \t]+)\S` finds it (CODD web's
    /// rule); two spaces otherwise.
    static func detectIndent(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(64))
        guard bytes.first == UInt8(ascii: "{") else { return "  " }
        var k = 1
        if k < bytes.count, bytes[k] == 0x0D { k += 1 }
        guard k < bytes.count, bytes[k] == 0x0A else { return "  " }
        k += 1
        let start = k
        while k < bytes.count, bytes[k] == 0x20 || bytes[k] == 0x09 { k += 1 }
        guard k > start, k < bytes.count, !isSpace(bytes[k]) else { return "  " }
        return String(decoding: bytes[start..<k], as: UTF8.self)
    }

    private static func isSpace(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C
    }
}

/// Blocking POSIX file operations for one settings file. Synchronous: call off the main actor.
enum SettingsFS {
    static func errnoText(_ operation: String, _ code: Int32) -> String {
        "\(operation): \(String(cString: strerror(code)))"
    }

    static func fingerprint(_ info: stat) -> SettingsFingerprint {
        SettingsFingerprint(size: Int64(info.st_size),
                            mtimeNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec),
                            inode: UInt64(info.st_ino))
    }

    /// `stat` following symlinks; nil when nothing is there.
    static func statTarget(_ path: String) throws(ClaudeSettingsError) -> stat? {
        var info = stat()
        if stat(path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw .unreadable(errnoText("stat", errno))
    }

    static func lstatExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Reads a regular file (through symlinks) of at most `maxBytes`; nil when it does not
    /// exist. The fingerprint comes from the same descriptor as the bytes.
    static func read(_ path: String, maxBytes: Int) throws(ClaudeSettingsError) -> (data: Data, fingerprint: SettingsFingerprint)? {
        // O_NONBLOCK: a FIFO named settings.json must not hang the caller.
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw .unreadable(errnoText("open", errno))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unreadable(errnoText("fstat", errno)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw .unreadable("not a regular file") }
        guard info.st_size <= maxBytes else { throw .tooLarge }
        var data = Data(count: Int(info.st_size))
        var total = 0
        while total < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if n > 0 {
                total += n
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw .unreadable(errnoText("read", errno))
            }
        }
        return (data.prefix(total), fingerprint(info))
    }

    /// The file a write must replace: the fully resolved symlink target, or, when nothing
    /// exists yet, the end of a dangling link chain (so a dotfiles link keeps working), else
    /// `path` itself.
    static func writeTarget(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var current = path
        for _ in 0..<32 {
            var info = stat()
            guard lstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else { return current }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(current, &buffer, Int(PATH_MAX))
            guard n > 0 else { return current }
            let destination = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            current = destination.hasPrefix("/")
                ? destination
                : (current as NSString).deletingLastPathComponent + "/" + destination
        }
        return current
    }

    /// `copyfile(3)` with `COPYFILE_EXCL`: data, mode, ACL and extended attributes. Returns the
    /// errno on failure (`EEXIST` when the name is taken).
    static func copyExclusive(from source: String, to destination: String) -> Int32? {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW_DST)
        return copyfile(source, destination, nil, flags) == 0 ? nil : errno
    }

    /// ``copyExclusive(from:to:)`` for a copy that must never be readable with the source's mode,
    /// not even for a moment (CODE-3): the copy is created with exactly `mode` before any byte is
    /// written and gets the data, the extended attributes and the times, not the source's mode or
    /// ACL. Returns the errno on failure (`EEXIST` when the name is taken; then nothing is removed).
    static func copyExclusive(from source: String, to destination: String, mode: mode_t) -> Int32? {
        let input = open(source, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { return errno }
        defer { close(input) }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard output >= 0 else { return errno }
        var code: Int32?
        var info = stat()
        if fchmod(output, mode) != 0 {
            code = errno
        } else if fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)) != 0 {
            code = errno
        } else if fstat(input, &info) == 0 {
            let times = [info.st_atimespec, info.st_mtimespec]
            _ = futimens(output, times)
        }
        if code == nil, fsync(output) != 0 { code = errno }
        close(output)
        if code != nil { unlink(destination) }
        return code
    }

    /// Writes `data` to a temp file next to `target` with exactly `mode`, flushes it and renames
    /// it over `target` (a symlink pointing at `target` stays a symlink).
    static func replace(_ target: String, with data: Data, mode: mode_t) throws(ClaudeSettingsError) {
        _ = try replace(target, with: data, mode: mode, beforeRename: { true })
    }

    /// ``replace(_:with:mode:)`` that asks `beforeRename` once the temp file is flushed: false
    /// removes the temp file and returns false with the target untouched (the caller saw the
    /// file change under it).
    static func replace(_ target: String, with data: Data, mode: mode_t,
                        beforeRename: () -> Bool) throws(ClaudeSettingsError) -> Bool {
        let directory = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        let temp = "\(directory)/.\(name).codd-tmp-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw .writeFailed(errnoText("create", errno)) }
        var failure: String?
        if fchmod(fd, mode) != 0 { failure = errnoText("fchmod", errno) }
        if failure == nil {
            let code: Int32? = data.withUnsafeBytes { raw -> Int32? in
                guard var p = raw.baseAddress else { return nil }
                var left = raw.count
                while left > 0 {
                    let n = Darwin.write(fd, p, left)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    left -= n
                    p += n
                }
                return nil
            }
            if let code { failure = errnoText("write", code) }
        }
        // The user's real configuration: worth a full flush before it replaces the old one.
        if failure == nil, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { failure = errnoText("fsync", errno) }
        close(fd)
        if failure == nil, !beforeRename() {
            unlink(temp)
            return false
        }
        if failure == nil, rename(temp, target) != 0 { failure = errnoText("rename", errno) }
        if let failure {
            unlink(temp)
            throw .writeFailed(failure)
        }
        return true
    }

    static func ensureDirectory(_ path: String) throws(ClaudeSettingsError) {
        var info = stat()
        if stat(path, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw .writeFailed(errnoText("mkdir", ENOTDIR)) }
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            throw .writeFailed("mkdir: \((error as NSError).localizedDescription)")
        }
    }
}
