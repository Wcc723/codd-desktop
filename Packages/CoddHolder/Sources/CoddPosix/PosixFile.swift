import Darwin

/// Device + inode pair, used to notice that a path now names a different file.
public struct FileIdentity: Sendable, Hashable {
    public var device: dev_t
    public var inode: ino_t

    public init(device: dev_t, inode: ino_t) {
        self.device = device
        self.inode = inode
    }
}

/// Small file helpers (no Foundation).
public enum PosixFile {
    /// Reads a whole file, refusing files larger than `maxBytes`.
    public static func readAll(_ path: String, maxBytes: Int = 16 << 20) throws(SystemError) -> [UInt8] {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw .current("open(\(path))") }
        defer { Descriptor.closeQuietly(fd) }
        var result: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                result.append(contentsOf: chunk[0..<count])
                if result.count > maxBytes { throw SystemError("read(\(path))", code: EFBIG) }
            } else if count == 0 {
                return result
            } else if errno != EINTR {
                throw .current("read(\(path))")
            }
        }
    }

    /// Writes `bytes` to a temporary sibling and renames it over `path`, so readers never see a
    /// partial file.
    public static func writeAtomically(_ path: String, _ bytes: [UInt8], mode: mode_t = 0o600) throws(SystemError) {
        let temporary = path + ".tmp." + String(getpid())
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode)
        guard fd >= 0 else { throw .current("open(\(temporary))") }
        do {
            try Descriptor.writeAll(fd, bytes)
        } catch {
            Descriptor.closeQuietly(fd)
            unlink(temporary)
            throw error
        }
        Descriptor.closeQuietly(fd)
        guard rename(temporary, path) == 0 else {
            let error = SystemError.current("rename(\(path))")
            unlink(temporary)
            throw error
        }
    }

    /// Creates `path` (and missing parents) as directories owned by the caller. The last component
    /// is forced to `mode` (0700 by default); a last component owned by someone else is an error.
    public static func ensurePrivateDirectory(_ path: String, mode: mode_t = 0o700) throws(SystemError) {
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR else { throw SystemError("not a directory: \(path)", code: ENOTDIR) }
            guard info.st_uid == geteuid() else { throw SystemError("directory not owned by us: \(path)", code: EPERM) }
            if info.st_mode & 0o777 != mode, chmod(path, mode) != 0 {
                throw .current("chmod(\(path))")
            }
            return
        }
        let parent = directoryName(path)
        if parent != path, !parent.isEmpty, !exists(parent) {
            try ensureDirectoryTree(parent)
        }
        if mkdir(path, mode) != 0 && errno != EEXIST {
            throw .current("mkdir(\(path))")
        }
        if chmod(path, mode) != 0 { throw .current("chmod(\(path))") }
    }

    /// `mkdir -p` with 0700 for created components.
    private static func ensureDirectoryTree(_ path: String) throws(SystemError) {
        if exists(path) { return }
        let parent = directoryName(path)
        if parent != path, !parent.isEmpty { try ensureDirectoryTree(parent) }
        if mkdir(path, 0o700) != 0 && errno != EEXIST { throw .current("mkdir(\(path))") }
    }

    public static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    public static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    public static func identity(fd: Int32) -> FileIdentity? {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// Parent directory of a slash-separated path ("/a/b" → "/a", "b" → ".", "/a" → "/").
    public static func directoryName(_ path: String) -> String {
        var bytes = Array(path.utf8)
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { return "." }
        if slash == 0 { return "/" }
        return String(decoding: bytes[0..<slash], as: UTF8.self)
    }

    /// Last path component.
    public static func baseName(_ path: String) -> String {
        var bytes = Array(path.utf8)
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { return path }
        return String(decoding: bytes[(slash + 1)...], as: UTF8.self)
    }

    /// Joins two path components with exactly one slash.
    public static func join(_ base: String, _ component: String) -> String {
        if base.isEmpty { return component }
        return base.hasSuffix("/") ? base + component : base + "/" + component
    }

    /// Entries of a directory (excluding "." and "..").
    public static func listDirectory(_ path: String) throws(SystemError) -> [String] {
        guard let directory = opendir(path) else { throw .current("opendir(\(path))") }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }
}
