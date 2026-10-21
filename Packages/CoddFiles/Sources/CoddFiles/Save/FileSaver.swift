import Darwin
import Foundation

public enum FileSaveError: Error, Equatable, Sendable {
    /// The file's contents differ from `expected` (someone else wrote it since CODD read it).
    /// `current` is nil when the file is gone.
    case changedOnDisk(current: FileFingerprint?)
    /// No write permission (`這個檔案是唯讀的`).
    case readOnly(path: String)
    /// Not a regular file (a folder, a FIFO, a dangling link).
    case notAFile(path: String)
    case io(path: String, operation: String, errno: Int32)
}

/// How ``FileSaver`` wrote a file (tests and logs).
public enum FileSaveMethod: String, Sendable {
    /// Temp file in the same folder + `rename(2)`.
    case atomic
    /// Written into the existing file (more than one hard link, another owner, a read-only folder).
    case inPlace
    /// A new file.
    case created
}

/// The save rules of the local file editor (D24). Nothing calls this except an explicit ⌘S or the
/// dirty-close sheet's 儲存.
///
/// - A symlink is written through: the link stays, its (fully resolved) target gets the bytes.
/// - Normal case: a temp file in the target's folder gets the bytes, the original's ACL and extended
///   attributes (`fcopyfile` `COPYFILE_ACL | COPYFILE_XATTR`), its mode (`fchmod`) and its hidden flag,
///   is flushed with `F_FULLFSYNC` and renamed over the target. (`COPYFILE_STAT` is not used: it
///   would also copy the old modification time.)
/// - A file with more than one hard link, a file owned by someone else, or one in a folder CODD
///   cannot create files in, is written in place (write from offset 0, truncate to the new length,
///   `F_FULLFSYNC`), so links, ownership and the inode survive.
/// - No write permission → ``FileSaveError/readOnly(path:)``.
/// - Unless `force`, the current contents must match `expected` (size + SHA-256), else
///   ``FileSaveError/changedOnDisk(current:)``. `expected == nil` skips the check.
public enum FileSaver {
    @discardableResult
    public static func save(_ data: Data, to url: URL, expected: FileFingerprint?, force: Bool) throws -> FileFingerprint {
        try saveReporting(data, to: url, expected: expected, force: force).fingerprint
    }

    /// ``save(_:to:expected:force:)`` that also says how the file was written.
    public static func saveReporting(_ data: Data, to url: URL, expected: FileFingerprint?, force: Bool)
        throws -> (fingerprint: FileFingerprint, method: FileSaveMethod) {
        let target = try resolveTarget(url)
        var st = stat()
        guard stat(target, &st) == 0 else {
            guard errno == ENOENT else { throw FileSaveError.io(path: target, operation: "stat", errno: errno) }
            if !force, expected != nil { throw FileSaveError.changedOnDisk(current: nil) }
            try writeAtomically(data, to: target, original: nil)
            return (try fingerprint(of: data, at: target), .created)
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileSaveError.notAFile(path: target) }
        guard access(target, W_OK) == 0 else { throw FileSaveError.readOnly(path: target) }
        if !force, let expected {
            let current = try? FileFingerprint.read(URL(fileURLWithPath: target), maxBytes: Int.max / 2).fingerprint
            guard let current, current.sameContent(as: expected) else { throw FileSaveError.changedOnDisk(current: current) }
        }
        var method = FileSaveMethod.atomic
        if st.st_nlink > 1 || st.st_uid != geteuid() {
            method = .inPlace
        } else {
            do {
                try writeAtomically(data, to: target, original: st)
            } catch FileSaveError.io(_, "create temp", let code) where code == EACCES || code == EPERM || code == EROFS {
                method = .inPlace
            }
        }
        if method == .inPlace { try writeInPlace(data, to: target) }
        return (try fingerprint(of: data, at: target), method)
    }

    /// The path the bytes go to: an existing file's real path (symlinks resolved), else `url`
    /// with its folder resolved.
    static func resolveTarget(_ url: URL) throws -> String {
        let path = url.path
        var lst = stat()
        if lstat(path, &lst) == 0 {
            guard let real = realpath(path, nil) else {
                // A dangling link: there is no file to write through to.
                throw FileSaveError.notAFile(path: path)
            }
            defer { free(real) }
            return String(cString: real)
        }
        let folder = (path as NSString).deletingLastPathComponent
        guard let real = realpath(folder, nil) else { throw FileSaveError.io(path: folder, operation: "realpath", errno: errno) }
        defer { free(real) }
        return String(cString: real) + "/" + (path as NSString).lastPathComponent
    }

    private static func fingerprint(of data: Data, at path: String) throws -> FileFingerprint {
        var st = stat()
        guard stat(path, &st) == 0 else { throw FileSaveError.io(path: path, operation: "stat", errno: errno) }
        return FileFingerprint(data: data, stat: st)
    }

    private static func writeAtomically(_ data: Data, to target: String, original: stat?) throws {
        let folder = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        let temp = folder + "/.\(name).codd-save-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileSaveError.io(path: temp, operation: "create temp", errno: errno) }
        var renamed = false
        defer {
            if !renamed { unlink(temp) }
        }
        do {
            try writeAll(fd, data, path: temp)
            if let original {
                let source = open(target, O_RDONLY | O_CLOEXEC)
                if source >= 0 {
                    // Best effort: an attribute the kernel owns may refuse to be set; the mode below is not.
                    _ = fcopyfile(source, fd, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
                    close(source)
                }
                guard fchmod(fd, original.st_mode & 0o7777) == 0 else { throw FileSaveError.io(path: temp, operation: "chmod", errno: errno) }
                if original.st_flags & UInt32(UF_HIDDEN) != 0 { _ = fchflags(fd, UInt32(UF_HIDDEN)) }
            } else {
                let mask = umask(0)
                umask(mask)
                _ = fchmod(fd, 0o666 & ~mask)
            }
            try fullSync(fd, path: temp)
        } catch {
            close(fd)
            throw error
        }
        close(fd)
        guard rename(temp, target) == 0 else { throw FileSaveError.io(path: target, operation: "rename", errno: errno) }
        renamed = true
    }

    /// Writes from offset 0, then truncates to the new length (the file is never empty in between),
    /// then `F_FULLFSYNC`.
    private static func writeInPlace(_ data: Data, to target: String) throws {
        let fd = open(target, O_WRONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == EACCES || errno == EPERM { throw FileSaveError.readOnly(path: target) }
            throw FileSaveError.io(path: target, operation: "open", errno: errno)
        }
        defer { close(fd) }
        try writeAll(fd, data, path: target)
        guard ftruncate(fd, off_t(data.count)) == 0 else { throw FileSaveError.io(path: target, operation: "truncate", errno: errno) }
        try fullSync(fd, path: target)
    }

    private static func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        let failed: Int32? = data.withUnsafeBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            var offset = 0
            while offset < raw.count {
                let n = pwrite(fd, base + offset, raw.count - offset, off_t(offset))
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                offset += n
            }
            return nil
        }
        if let failed { throw FileSaveError.io(path: path, operation: "write", errno: failed) }
    }

    /// `fsync` does not flush the drive's cache on macOS; `F_FULLFSYNC` does (fsync where unsupported).
    private static func fullSync(_ fd: Int32, path: String) throws {
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw FileSaveError.io(path: path, operation: "fsync", errno: errno) }
    }
}
