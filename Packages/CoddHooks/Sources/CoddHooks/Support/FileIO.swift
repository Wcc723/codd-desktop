import Darwin
import Foundation

/// Small-file helpers for config.json and the hook state files. Synchronous blocking I/O: call
/// them off the main actor.
enum FileIO {
    struct Failure: Error, Equatable, CustomStringConvertible {
        var operation: String
        var path: String
        var errno: Int32

        var description: String { "\(operation) \(path): \(String(cString: strerror(errno)))" }
    }

    /// Creates `url` (and missing parents) with `mode`. An existing directory keeps its mode: it
    /// may be a folder the user chose.
    static func ensureDirectory(_ url: URL, mode: mode_t = 0o700) throws(Failure) {
        if let e = makeDirectories(url.path, mode: mode) { throw Failure(operation: "mkdir", path: url.path, errno: e) }
    }

    private static func makeDirectories(_ path: String, mode: mode_t) -> Int32? {
        if mkdir(path, mode) == 0 {
            _ = chmod(path, mode) // mkdir applies the umask
            return nil
        }
        switch errno {
        case EEXIST:
            var info = stat()
            return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR ? nil : ENOTDIR
        case ENOENT:
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, parent != path else { return ENOENT }
            if let e = makeDirectories(parent, mode: mode) { return e }
            if mkdir(path, mode) == 0 || errno == EEXIST {
                _ = chmod(path, mode)
                return nil
            }
            return errno
        default:
            return errno
        }
    }

    /// Reads a regular file of at most `limit` bytes without following a symlink; `nil` + errno
    /// `ENOENT` when it does not exist.
    static func read(_ url: URL, limit: Int) throws(Failure) -> Data? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw Failure(operation: "open", path: url.path, errno: errno)
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure(operation: "fstat", path: url.path, errno: errno) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Failure(operation: "not a regular file", path: url.path, errno: EINVAL) }
        guard info.st_size <= limit else { throw Failure(operation: "too large", path: url.path, errno: EFBIG) }
        var data = Data(count: Int(info.st_size))
        var total = 0
        while total < data.count {
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + total, $0.count - total) }
            if n > 0 {
                total += n
            } else if n == 0 {
                break
            } else if errno != EINTR {
                throw Failure(operation: "read", path: url.path, errno: errno)
            }
        }
        return data.prefix(total)
    }

    /// Writes `data` to a new temp file next to `url` with `mode`, optionally `F_FULLFSYNC`s it,
    /// and returns the temp path. The caller renames or links it into place.
    private static func writeTemp(_ data: Data, near url: URL, mode: mode_t, durable: Bool) throws(Failure) -> String {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))").path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw Failure(operation: "create", path: temp, errno: errno) }
        var failure: Failure?
        // The umask may have narrowed `mode`; set it exactly (0600 matters for config.json).
        if fchmod(fd, mode) != 0 { failure = Failure(operation: "fchmod", path: temp, errno: errno) }
        if failure == nil {
            let e: Int32? = data.withUnsafeBytes { raw -> Int32? in
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
            if let e { failure = Failure(operation: "write", path: temp, errno: e) }
        }
        if failure == nil, durable, fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            failure = Failure(operation: "fsync", path: temp, errno: errno)
        }
        close(fd)
        if let failure {
            unlink(temp)
            throw failure
        }
        return temp
    }

    /// Atomically replaces `url`. `durable: false` skips the flush: hook state files are a cache
    /// rewritten up to once a second per session, and a torn file after a power cut only means
    /// "no restored state" (the decoder is tolerant), so a disk flush per write is not worth it.
    static func writeAtomically(_ data: Data, to url: URL, mode: mode_t = 0o600, durable: Bool) throws(Failure) {
        let temp = try writeTemp(data, near: url, mode: mode, durable: durable)
        guard rename(temp, url.path) == 0 else {
            let e = errno
            unlink(temp)
            throw Failure(operation: "rename", path: url.path, errno: e)
        }
    }

    /// Creates `url` with `data` only if it does not exist (`link(2)` of a complete temp file, so
    /// a concurrent creator can never observe or clobber a half-written file). `false` when it
    /// already existed.
    static func createExclusively(_ data: Data, at url: URL, mode: mode_t = 0o600) throws(Failure) -> Bool {
        let temp = try writeTemp(data, near: url, mode: mode, durable: true)
        defer { unlink(temp) }
        if link(temp, url.path) == 0 { return true }
        if errno == EEXIST { return false }
        throw Failure(operation: "link", path: url.path, errno: errno)
    }
}
