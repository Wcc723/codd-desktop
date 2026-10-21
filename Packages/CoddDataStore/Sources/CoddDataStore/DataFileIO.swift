import Darwin
import Foundation

/// The file operations of the preflight: `lstat` before anything, reads with `O_NOFOLLOW`, never
/// following a link into or out of the data root, exclusive creates for backups, `RENAME_EXCL`
/// for aside names and the crash-safe replace (temp + `F_FULLFSYNC` + `rename`) the stores use.
enum DataFileIO {
    enum Entry: Equatable {
        case missing
        case file(size: Int64, mode: mode_t)
        case directory
        case symlink
        case other
        case error(Int32)
    }

    static func entry(_ path: String) -> Entry {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? .missing : .error(code)
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: return .file(size: Int64(info.st_size), mode: info.st_mode & 0o7777)
        case S_IFDIR: return .directory
        case S_IFLNK: return .symlink
        default: return .other
        }
    }

    enum ReadResult {
        case missing
        case data(Data, mode: mode_t)
        /// A symlink, not a regular file, or over the limit: never read.
        case skipped(String)
        /// open / fstat / read failed: never treated as corrupt.
        case ioError(Int32)
    }

    /// The whole file, opened without following a final symlink (unless `followLinks`) and
    /// without blocking on a FIFO, re-checked with `fstat` after the open.
    static func read(_ path: String, maxBytes: Int, followLinks: Bool = false) -> ReadResult {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followLinks ? 0 : O_NOFOLLOW))
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR: return .missing
            case ELOOP: return .skipped("symlink")
            default: return .ioError(code)
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .ioError(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .skipped("not a regular file") }
        guard info.st_size <= maxBytes else { return .skipped("larger than \(maxBytes) bytes") }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size) + 1)
        var count = 0
        while true {
            if count == bytes.count {
                // It grew since the fstat: read on, but never past the limit.
                guard bytes.count <= maxBytes else { return .skipped("larger than \(maxBytes) bytes") }
                bytes.append(contentsOf: [UInt8](repeating: 0, count: min(64 << 10, maxBytes + 1 - bytes.count)))
            }
            let n = bytes.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!.advanced(by: count), raw.count - count)
            }
            if n < 0 {
                let code = errno
                if code == EINTR { continue }
                return .ioError(code)
            }
            if n == 0 { break }
            count += n
        }
        guard count <= maxBytes else { return .skipped("larger than \(maxBytes) bytes") }
        return .data(Data(bytes[0..<count]), mode: info.st_mode & 0o7777)
    }

    /// The names in a real directory (hidden ones included), nil when it cannot be listed.
    static func list(_ path: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: path)
    }

    /// Writes `data` to a new file (`O_EXCL`: an existing file is never replaced). Nil on
    /// success, else errno (`EEXIST` when the name is taken).
    static func createExclusively(_ data: Data, at path: String, mode: mode_t) -> Int32? {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { return errno }
        var ok = false
        defer {
            if !ok { unlink(path) }
        }
        _ = fchmod(fd, mode)
        if let code = writeAll(fd, data) {
            close(fd)
            return code
        }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            let code = errno
            close(fd)
            return code
        }
        close(fd)
        ok = true
        return nil
    }

    /// Crash-safe replacement: a temp file in the same folder with `mode`, `F_FULLFSYNC`, then
    /// `rename(2)`; a failed sync is never followed by the rename. Nil on success, else errno.
    static func writeAtomically(_ data: Data, to path: String, mode: mode_t) -> Int32? {
        let folder = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temp = "\(folder)/.\(name).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))"
        if let code = createExclusively(data, at: temp, mode: mode) { return code }
        guard rename(temp, path) == 0 else {
            let code = errno
            unlink(temp)
            return code
        }
        return nil
    }

    /// Renames `path` to `<path>.corrupt-<ms>` (`-2`, `-3`… when taken; never over an existing
    /// file). Returns the new path or errno.
    static func moveAside(_ path: String, milliseconds: Int64) -> Result<String, Errno> {
        let stem = "\(path).corrupt-\(milliseconds)"
        for n in 1...1000 {
            let target = n == 1 ? stem : "\(stem)-\(n)"
            if renamex_np(path, target, UInt32(RENAME_EXCL)) == 0 { return .success(target) }
            let code = errno
            guard code == EEXIST else { return .failure(Errno(code)) }
        }
        return .failure(Errno(EEXIST))
    }

    /// Deletes every entry of a real directory (links themselves, never what they point to),
    /// keeping the directory. Nil when it cannot be listed.
    static func removeContents(of path: String) -> (removed: Int, failed: Int)? {
        guard let names = list(path) else { return nil }
        var removed = 0, failed = 0
        for name in names {
            if (try? FileManager.default.removeItem(atPath: path + "/" + name)) != nil { removed += 1 } else { failed += 1 }
        }
        return (removed, failed)
    }

    /// `mkdir` 0700, excluded from Time Machine (the cache folder's rule). Nil on success.
    static func makePrivateDirectory(_ path: String, excludedFromBackup: Bool) -> Int32? {
        guard mkdir(path, 0o700) == 0 else { return errno }
        if excludedFromBackup {
            var url = URL(fileURLWithPath: path, isDirectory: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        return nil
    }

    /// `realpath(3)` of an existing path.
    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Int32? {
        data.withUnsafeBytes { raw -> Int32? in
            guard var pointer = raw.baseAddress else { return nil }
            var left = raw.count
            while left > 0 {
                let n = write(fd, pointer, left)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                left -= n
                pointer = pointer.advanced(by: n)
            }
            return nil
        }
    }
}

/// An errno as an `Error`, so it can be a `Result` failure.
struct Errno: Error, Equatable {
    let code: Int32

    init(_ code: Int32) {
        self.code = code
    }
}

/// `*` within one path component (never a hidden name unless the pattern starts with `.`).
enum NamePattern {
    static func matches(_ name: String, _ pattern: String) -> Bool {
        guard pattern.contains("*") else { return name == pattern }
        if name.hasPrefix("."), !pattern.hasPrefix(".") { return false }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map { Array($0.utf8) }
        let bytes = Array(name.utf8)
        guard let first = parts.first, let last = parts.last, bytes.count >= first.count + last.count,
              bytes.starts(with: first), bytes.suffix(last.count).elementsEqual(last) else { return false }
        // Middle parts in order, between the prefix and the suffix.
        var index = first.count
        let end = bytes.count - last.count
        for part in parts.dropFirst().dropLast() where !part.isEmpty {
            var found = false
            while index + part.count <= end {
                if bytes[index..<(index + part.count)].elementsEqual(part) {
                    index += part.count
                    found = true
                    break
                }
                index += 1
            }
            guard found else { return false }
        }
        return true
    }
}
