import CryptoKit
import Darwin
import Foundation

enum Hashing {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
}

/// Crash-safe replacement in the notes folder: the temp file is written in `.codd/tmp/` (same
/// volume), `F_FULLFSYNC`ed and renamed over the target, so a note is never partially on disk and
/// the watcher never sees a half-written file. The same style as CoddCore's `AtomicFile` (copied,
/// not imported: this package has no CoddCore dependency).
struct AtomicWriter: Sendable {
    let tempDirectory: URL

    enum WriteError: Error {
        case failed(String)
    }

    /// Writes `data` to `url`. `mode` nil keeps an existing file's mode (new files get 0600).
    func write(_ data: Data, to url: URL, mode: mode_t? = nil) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try createDirectory(dir)
        }
        if !fm.fileExists(atPath: tempDirectory.path) {
            try createDirectory(tempDirectory)
        }
        var targetMode: mode_t = mode ?? 0o600
        if mode == nil {
            var st = stat()
            if lstat(url.path, &st) == 0 { targetMode = st.st_mode & 0o7777 }
        }
        let temp = tempDirectory.appendingPathComponent("\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, targetMode)
        guard fd >= 0 else { throw WriteError.failed("open temp \(temp.lastPathComponent): errno \(errno)") }
        var ok = false
        defer { if !ok { unlink(temp.path) } }
        let failed: Int32? = data.withUnsafeBytes { raw -> Int32? in
            guard var p = raw.baseAddress else { return nil }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                left -= n
                p = p.advanced(by: n)
            }
            return nil
        }
        if let e = failed {
            close(fd)
            throw WriteError.failed("write: errno \(e)")
        }
        // The umask may have narrowed the open(2) mode.
        fchmod(fd, targetMode)
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            let e = errno
            close(fd)
            throw WriteError.failed("sync: errno \(e)")
        }
        close(fd)
        // Keep the replaced file's extended attributes (Finder tags, other tools' metadata).
        if mode == nil, FileManager.default.fileExists(atPath: url.path) {
            _ = copyfile(url.path, temp.path, nil, copyfile_flags_t(COPYFILE_XATTR))
        }
        guard rename(temp.path, url.path) == 0 else { throw WriteError.failed("rename: errno \(errno)") }
        ok = true
    }

    func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: 0o700)])
        } catch {
            throw WriteError.failed("mkdir \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

enum FileFacts {
    struct Stat: Equatable {
        var mtime: Double
        var size: Int
        var birth: Double
        var isDirectory: Bool
    }

    static func info(_ path: String) -> Stat? {
        var st = Darwin.stat()
        guard posixStat(path, &st) == 0 else { return nil }
        let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let b = Double(st.st_birthtimespec.tv_sec) + Double(st.st_birthtimespec.tv_nsec) / 1e9
        return Stat(mtime: m, size: Int(st.st_size), birth: b, isDirectory: (st.st_mode & S_IFMT) == S_IFDIR)
    }

    /// `realpath(3)`, or the standardized path when it does not exist.
    static func realPath(_ url: URL) -> URL {
        guard let p = Darwin.realpath(url.path, nil) else { return PathText.clean(url) }
        defer { free(p) }
        return URL(fileURLWithPath: String(cString: p), isDirectory: true)
    }

    static func setXattr(_ name: String, _ value: String, on url: URL) {
        let bytes = Array(value.utf8)
        _ = bytes.withUnsafeBufferPointer { buf in
            setxattr(url.path, name, buf.baseAddress, buf.count, 0, 0)
        }
    }

    static func xattr(_ name: String, of url: URL) -> String? {
        let n = getxattr(url.path, name, nil, 0, 0, 0)
        guard n > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: n)
        let r = getxattr(url.path, name, &buf, n, 0, 0)
        guard r == n else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    static func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }
}

enum PathText {
    /// `.` and `..` components resolved lexically; unlike `standardizedFileURL` it never drops a
    /// `/private` prefix, so paths stay the ones the user's root was given with.
    static func clean(_ url: URL) -> URL {
        var parts: [Substring] = []
        for c in url.path.split(separator: "/", omittingEmptySubsequences: true) {
            if c == "." { continue }
            if c == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(c)
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }
}

/// `~` abbreviation for project paths (plan §3.2: links carry `~`-abbreviated paths).
enum HomePath {
    static var home: String {
        let h = NSHomeDirectory()
        return h.hasSuffix("/") ? String(h.dropLast()) : h
    }

    static func abbreviate(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        let h = home
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }

    static func expand(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

/// `stat(2)` (the struct of the same name shadows the function inside types).
private func posixStat(_ path: String, _ st: inout stat) -> Int32 {
    stat(path, &st)
}
