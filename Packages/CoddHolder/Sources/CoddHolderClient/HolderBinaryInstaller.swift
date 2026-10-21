import CommonCrypto
import CoddPosix
import Darwin
import Synchronization

/// Copies the bundled `codd-holder` to `<dataRoot>/bin/codd-holder-<sha256 prefix>` and spawns
/// holders from there (M1 plan, "Holder binary").
///
/// Holders outlive the app. Running them from inside the bundle ties them to a file that every
/// app update or Xcode rebuild replaces, and overwriting a running signed executable in place gets
/// the process killed. A content-addressed copy is written once, never modified, and only removed
/// when no process runs it.
///
/// The copy is the file's bytes only: the ad-hoc signature lives inside the Mach-O, so it stays
/// valid (`codesign -v`), and no extended attributes (quarantine) come along.
///
/// The same scheme serves other bundled tools whose absolute path outlives the app run (the app
/// installs `codd-hook`, whose path is baked into every claude session's `--settings`): pass their
/// own `namePrefix` to the `install(bundled:dataRoot:namePrefix:)` / `collectGarbage` overloads.
public enum HolderBinaryInstaller {
    public static let directoryName = "bin"
    public static let namePrefix = "codd-holder-"
    /// Hex digits of the SHA-256 in the file name (48 bits: collisions between builds are not a concern).
    public static let digestLength = 12
    /// Copies younger than this survive garbage collection even when unused: another CODD instance
    /// may have installed one a moment ago and be about to spawn from it. The age counts from the
    /// last install (a reused copy's mtime is refreshed); a copy a running app uses is protected by
    /// `markInUse` however old it is.
    public static let defaultMinimumAgeSeconds = 300

    /// Descriptors holding a shared lock on the copies this process uses (never closed).
    private static let inUse = Mutex<[String: Int32]>([:])

    public struct Installation: Sendable, Equatable {
        /// Absolute path to spawn holders from.
        public var path: String
        /// First `digestLength` lowercase hex digits of the binary's SHA-256.
        public var digest: String
        /// False when a verified copy was already in place.
        public var copied: Bool
    }

    /// Ensures the content-addressed copy of `bundledHolder` exists under `dataRoot` and returns it.
    /// An existing file of that name is reused only if its bytes equal the bundled binary; anything
    /// else there (a damaged or foreign file) is replaced. The new file is written to a temporary name, flushed, made 0755 and
    /// renamed into place, so a concurrent installer or spawner never sees a partial file (and a
    /// holder already running from a replaced file keeps its inode).
    public static func install(bundledHolder: String, dataRoot: String) throws(SystemError) -> Installation {
        try install(bundled: bundledHolder, dataRoot: dataRoot, namePrefix: namePrefix)
    }

    /// `install(bundledHolder:dataRoot:)` for any bundled executable: `<dataRoot>/bin/<namePrefix><digest>`.
    /// `namePrefix` must end in `-` and name a tool, e.g. `codd-hook-`.
    public static func install(bundled: String, dataRoot: String, namePrefix: String) throws(SystemError) -> Installation {
        let bytes = try PosixFile.readAll(bundled, maxBytes: 256 << 20)
        let digest = String(sha256Hex(bytes).prefix(digestLength))
        let directory = PosixFile.join(dataRoot, directoryName)
        try PosixFile.ensurePrivateDirectory(directory)
        let path = PosixFile.join(directory, namePrefix + digest)

        if isVerifiedCopy(path, of: bytes) {
            if let mode = fileMode(path), mode & 0o777 != 0o755 { chmod(path, 0o755) }
            // The grace period counts from now, not from the first install.
            utimes(path, nil)
            return Installation(path: path, digest: digest, copied: false)
        }
        let temporary = PosixFile.join(directory, ".\(namePrefix)\(digest).\(getpid()).\(arc4random()).tmp")
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw .current("open(\(temporary))") }
        do throws(SystemError) {
            try Descriptor.writeAll(fd, bytes)
            guard fchmod(fd, 0o755) == 0 else { throw .current("fchmod(\(temporary))") }
            guard fsync(fd) == 0 else { throw .current("fsync(\(temporary))") }
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
        return Installation(path: path, digest: digest, copied: true)
    }

    /// Marks `path` (an installed copy) as used by this process for as long as it runs: a shared
    /// `flock` on a descriptor kept open (close-on-exec, so children do not inherit it).
    /// `collectGarbage`, in any process, skips a copy it cannot lock exclusively. Without it an
    /// instance that had been running for a while (its copy older than the grace period, no
    /// holder running from it right now) lost the copy to another instance's collection, and
    /// its next spawn failed (review finding). Idempotent; false when the file cannot be locked.
    @discardableResult
    public static func markInUse(_ path: String) -> Bool {
        inUse.withLock { held in
            if held[path] != nil { return true }
            let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { return false }
            guard flock(fd, LOCK_SH | LOCK_NB) == 0 else {
                Descriptor.closeQuietly(fd)
                return false
            }
            held[path] = fd
            return true
        }
    }

    /// Some process (this one included) holds `markInUse` on the file at `path`.
    static func isMarkedInUse(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { Descriptor.closeQuietly(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) != 0 else {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Removes `codd-holder-<digest>` files in `<dataRoot>/bin` that are not in `keeping`, are at
    /// least `minimumAgeSeconds` old, that no running process executes (every pid's executable
    /// via proc_listpids + proc_pidpath, compared by device and inode) and that no running app
    /// marked in use (`markInUse`), plus stale temporary files. Other files are never touched.
    /// Returns the removed paths. Run it at launch, after `install`.
    @discardableResult
    public static func collectGarbage(
        dataRoot: String, keeping: [String], minimumAgeSeconds: Int = defaultMinimumAgeSeconds
    ) -> [String] {
        collectGarbage(dataRoot: dataRoot, namePrefix: namePrefix, keeping: keeping, minimumAgeSeconds: minimumAgeSeconds)
    }

    /// `collectGarbage(dataRoot:keeping:minimumAgeSeconds:)` for the copies named `<namePrefix><digest>`.
    /// A tool that is referenced rather than run continuously (codd-hook) must have every copy a
    /// live session still references in `keeping`: the running-process check only sees it while
    /// one of its invocations runs.
    @discardableResult
    public static func collectGarbage(
        dataRoot: String, namePrefix: String, keeping: [String], minimumAgeSeconds: Int = defaultMinimumAgeSeconds
    ) -> [String] {
        let directory = PosixFile.join(dataRoot, directoryName)
        guard let names = try? PosixFile.listDirectory(directory) else { return [] }
        let kept = Set(keeping.compactMap { PosixFile.identity($0) })
        let running = runningIdentities(namePrefix: namePrefix)
        let now = time(nil)
        var removed: [String] = []
        for name in names {
            let isCopy = isInstalledName(name, prefix: namePrefix)
            let isTemporary = name.hasPrefix("." + namePrefix) && name.hasSuffix(".tmp")
            guard isCopy || isTemporary else { continue }
            let path = PosixFile.join(directory, name)
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else { continue }
            guard now - info.st_mtimespec.tv_sec >= minimumAgeSeconds else { continue }
            let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
            guard !kept.contains(identity), !running.contains(identity), !isMarkedInUse(path) else { continue }
            if unlink(path) == 0 { removed.append(path) }
        }
        return removed
    }

    /// `codd-holder-` followed by exactly `digestLength` lowercase hex digits (not `codd-holderctl`,
    /// `codd-holder-testhelper` or other tools).
    public static func isInstalledHolderName(_ name: String) -> Bool {
        isInstalledName(name, prefix: namePrefix)
    }

    /// `prefix` followed by exactly `digestLength` lowercase hex digits.
    public static func isInstalledName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let digest = name.utf8.dropFirst(prefix.utf8.count)
        return digest.count == digestLength && digest.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// Lowercase hex SHA-256 of `bytes`.
    public static func sha256Hex(_ bytes: [UInt8]) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        bytes.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(raw.count), &digest)
        }
        let hex = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(digest.count * 2)
        for byte in digest {
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Helpers

    private static func isVerifiedCopy(_ path: String, of bytes: [UInt8]) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              Int(info.st_size) == bytes.count,
              let existing = try? PosixFile.readAll(path, maxBytes: bytes.count)
        else { return false }
        return existing == bytes
    }

    private static func fileMode(_ path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode : nil
    }

    /// Identities of the executables of running processes named like an installed copy.
    private static func runningIdentities(namePrefix: String) -> Set<FileIdentity> {
        var identities = Set<FileIdentity>()
        for pid in ProcessQueries.allProcessIDs() {
            guard let path = ProcessQueries.processPath(pid), isInstalledName(PosixFile.baseName(path), prefix: namePrefix),
                  let identity = PosixFile.identity(path)
            else { continue }
            identities.insert(identity)
        }
        return identities
    }
}
