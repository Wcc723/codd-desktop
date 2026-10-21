import Darwin
import Foundation

/// Crash-safe file replacement: write a temp file in the same directory, `F_FULLFSYNC`, `rename(2)`.
/// Synchronous blocking I/O: call it off the main actor.
public enum AtomicFile {
    public enum WriteError: Error, Equatable {
        case createDirectory(path: String, reason: String)
        case openTemp(path: String, errno: Int32)
        case write(path: String, errno: Int32)
        case rename(path: String, errno: Int32)
    }

    /// Atomically replaces `url` with `data`. The parent directory is created (mode
    /// `directoryPermissions`) if missing; the file gets `permissions` (default 0600).
    public static func write(
        _ data: Data, to url: URL, permissions: mode_t = 0o600, directoryPermissions: mode_t = 0o700
    ) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: directoryPermissions)])
            } catch {
                throw WriteError.createDirectory(path: dir.path, reason: String(describing: error))
            }
        }
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw WriteError.openTemp(path: temp.path, errno: errno) }
        var ok = false
        defer {
            if !ok { unlink(temp.path) }
        }
        let writeFailed: Int32? = data.withUnsafeBytes { raw -> Int32? in
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
        if let e = writeFailed {
            close(fd)
            throw WriteError.write(path: temp.path, errno: e)
        }
        // On macOS `fsync` does not flush the drive's cache; F_FULLFSYNC does (fall back to fsync on
        // file systems that do not support it). A failed sync must not be followed by the rename,
        // or a power loss could replace good data with a torn file.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            let e = errno
            close(fd)
            throw WriteError.write(path: temp.path, errno: e)
        }
        close(fd)
        guard rename(temp.path, url.path) == 0 else { throw WriteError.rename(path: url.path, errno: errno) }
        ok = true
    }
}
