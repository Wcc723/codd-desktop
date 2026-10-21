import Darwin
import Foundation

/// The shared rules of `files/recent.json` and `files/ai-touches.json` (M4 plan §3.4):
/// `{"v":1,"items":[…]}`, 0600, atomic (temp + `F_FULLFSYNC` + rename, folder 0700), tolerant (a
/// file that does not parse is renamed to `<name>.corrupt-<ms>` and the store starts empty), and a
/// file with a newer `v` is read when its items decode but never written.
struct StoreFile<Item: Codable & Sendable>: Sendable {
    static var currentVersion: Int { 1 }

    let url: URL

    struct Loaded {
        var items: [Item]
        /// Written by a newer CODD: never overwrite.
        var readOnly: Bool
    }

    private struct Envelope: Codable {
        var v: Int
        var items: [Item]
    }

    private struct VersionOnly: Decodable {
        var v: Int
    }

    func load(now: Date) -> Loaded {
        guard let data = try? Data(contentsOf: url) else { return Loaded(items: [], readOnly: false) }
        let decoder = Self.decoder()
        guard let version = try? decoder.decode(VersionOnly.self, from: data) else {
            moveAside(now: now)
            return Loaded(items: [], readOnly: false)
        }
        if version.v > Self.currentVersion {
            let items = (try? decoder.decode(Envelope.self, from: data))?.items ?? []
            return Loaded(items: items, readOnly: true)
        }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            moveAside(now: now)
            return Loaded(items: [], readOnly: false)
        }
        return Loaded(items: envelope.items, readOnly: false)
    }

    func save(_ items: [Item]) throws {
        let data = try Self.encoder().encode(Envelope(v: Self.currentVersion, items: items))
        try Self.atomicWrite(data, to: url)
    }

    private func moveAside(now: Date) {
        let ms = Int64((now.timeIntervalSince1970 * 1000).rounded())
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(ms)")
        try? FileManager.default.moveItem(at: url, to: target)
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISODate.string(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = ISODate.parse(text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid date \(text)")
            }
            return date
        }
        return decoder
    }

    /// Temp file in the same folder (0600), `F_FULLFSYNC`, `rename(2)`; the folder is created 0700.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        let temp = folder.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileSaveError.io(path: temp.path, operation: "create temp", errno: errno) }
        var ok = false
        defer { if !ok { unlink(temp.path) } }
        let failed: Int32? = data.withUnsafeBytes { raw -> Int32? in
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
        if let failed {
            close(fd)
            throw FileSaveError.io(path: temp.path, operation: "write", errno: failed)
        }
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            let code = errno
            close(fd)
            throw FileSaveError.io(path: temp.path, operation: "fsync", errno: code)
        }
        close(fd)
        guard rename(temp.path, url.path) == 0 else { throw FileSaveError.io(path: url.path, operation: "rename", errno: errno) }
        ok = true
    }
}

/// `2026-10-15T02:42:00.000Z` (JavaScript's `toISOString`, like the rest of CODD's JSON); parsing
/// also takes the form without fractional seconds and with offsets.
public enum ISODate {
    private static let plain = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: TimeZone(identifier: "UTC")!)

    /// Whole milliseconds, formatted from the integer (a formatter on the Double would truncate
    /// `…20.123` to `…20.122`), so write → read round trips are exact.
    public static func string(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = ms >= 0 ? ms / 1000 : -((-ms + 999) / 1000)
        let fraction = ms - seconds * 1000
        let base = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(plain)
        let digits = String(fraction)
        return String(base.dropLast()) + "." + String(repeating: "0", count: 3 - digits.count) + digits + "Z"
    }

    /// Parsed and rounded to whole milliseconds.
    public static func parse(_ text: String) -> Date? {
        guard let date = (try? withFraction.parse(text)) ?? (try? plain.parse(text)) else { return nil }
        return Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
