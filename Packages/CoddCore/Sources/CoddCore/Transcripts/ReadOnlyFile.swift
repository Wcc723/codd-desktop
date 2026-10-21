import Darwin
import Foundation

/// Read-only access to files Claude Code owns (transcripts, settings.json). CODD never writes them.
///
/// `O_NONBLOCK` keeps a FIFO from blocking the open, `O_CLOEXEC` keeps the fd out of children
/// spawned meanwhile, `O_NOFOLLOW` (when asked) refuses a symlink as the last component, and only
/// regular files are read. `pread` leaves no shared offset behind, so one fd serves head and tail.
enum ReadOnlyFile {
    struct Info: Sendable, Equatable {
        var size: Int64
        /// `st_mtimespec` in nanoseconds since the epoch (cache key; full precision).
        var mtimeNanoseconds: Int64

        var modified: Date { Date(timeIntervalSince1970: TimeInterval(mtimeNanoseconds) / 1_000_000_000) }
    }

    /// Opens `path` and passes the fd and its `fstat` info to `body`; `nil` when it cannot be
    /// opened or is not a regular file.
    static func with<T>(_ path: String, noFollow: Bool = false, _ body: (Int32, Info) -> T?) -> T? {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOCTTY | (noFollow ? O_NOFOLLOW : 0))
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return body(fd, info(st))
    }

    /// `lstat` of `path`: info of a regular file, `nil` for anything else (symlinks included).
    static func regularFileInfo(_ path: String) -> Info? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return info(st)
    }

    /// Whether `path` is a directory itself (`lstat`: a symlink to a directory is not).
    static func isRealDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Up to `count` bytes from `offset` (fewer at end of file); `nil` on a read error.
    static func read(_ fd: Int32, offset: Int64, count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        while done < count {
            let n = out.withUnsafeMutableBytes { raw in
                pread(fd, raw.baseAddress?.advanced(by: done), count - done, off_t(offset) + off_t(done))
            }
            if n > 0 {
                done += n
            } else if n == 0 {
                break
            } else if errno != EINTR {
                return nil
            }
        }
        if done < count { out.removeSubrange(done...) }
        return out
    }

    /// `realpath(3)`: the absolute physical path, or `nil` when it does not exist.
    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func info(_ st: stat) -> Info {
        Info(size: Int64(st.st_size),
             mtimeNanoseconds: Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec))
    }
}
