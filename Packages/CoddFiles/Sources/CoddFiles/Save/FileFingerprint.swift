import CommonCrypto
import Darwin
import Foundation

/// What a file looked like when CODD read or wrote it. Two fingerprints describe the same
/// contents when size and SHA-256 match (``sameContent(as:)``); mtime and inode only say that
/// something touched the file (a `touch`, an identical atomic rewrite).
public struct FileFingerprint: Sendable, Equatable {
    public var size: Int64
    public var mtime: Date
    public var inode: UInt64
    /// Lowercase hex SHA-256 of the bytes.
    public var sha256: String

    public init(size: Int64, mtime: Date, inode: UInt64, sha256: String) {
        self.size = size
        self.mtime = mtime
        self.inode = inode
        self.sha256 = sha256
    }

    public func sameContent(as other: FileFingerprint) -> Bool {
        size == other.size && sha256 == other.sha256
    }

    /// Reads `url` (following symlinks) and fingerprints the bytes it read. Refuses files over
    /// `maxBytes` before reading them (``FileReadError/tooLarge(_:)``).
    public static func read(_ url: URL, maxBytes: Int = TextFileCodec.refuseBytes) throws -> (data: Data, fingerprint: FileFingerprint) {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FileReadError.open(path: url.path, errno: errno) }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw FileReadError.open(path: url.path, errno: errno) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw FileReadError.notAFile(path: url.path) }
        if st.st_size > Int64(maxBytes) { throw FileReadError.tooLarge(Int(st.st_size)) }
        var data = Data(count: Int(st.st_size))
        var total = 0
        let failed: Int32? = data.withUnsafeMutableBytes { raw -> Int32? in
            guard let base = raw.baseAddress else { return nil }
            while total < raw.count {
                let n = Darwin.read(fd, base + total, raw.count - total)
                if n < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                if n == 0 { break }
                total += n
            }
            return nil
        }
        if let failed { throw FileReadError.read(path: url.path, errno: failed) }
        if total < data.count { data.removeSubrange(total...) }
        // The file may have grown since fstat: read the rest too, up to the limit.
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: chunk[0..<n])
            if data.count > maxBytes { throw FileReadError.tooLarge(data.count) }
        }
        return (data, FileFingerprint(data: data, stat: st))
    }

    /// The fingerprint of `data` as written to a file with status `st`.
    public init(data: Data, stat st: stat) {
        self.init(size: Int64(data.count), mtime: Self.date(st.st_mtimespec), inode: UInt64(st.st_ino), sha256: Self.sha256Hex(data))
    }

    /// The current fingerprint of `url` (reads and hashes it); nil when it does not exist.
    public static func current(_ url: URL) throws -> FileFingerprint? {
        do {
            return try read(url, maxBytes: Int.max / 2).fingerprint
        } catch FileReadError.open(_, let code) where code == ENOENT {
            return nil
        }
    }

    public static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { raw in
            _ = CC_SHA256(raw.baseAddress, CC_LONG(raw.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func date(_ ts: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(ts.tv_sec) + TimeInterval(ts.tv_nsec) / 1e9)
    }
}

/// Why reading a file failed.
public enum FileReadError: Error, Equatable, Sendable {
    case open(path: String, errno: Int32)
    case read(path: String, errno: Int32)
    case notAFile(path: String)
    case tooLarge(Int)
}
