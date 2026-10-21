import Darwin
import Foundation

/// What a session's composer keeps across launches: the unsent draft and the history.
public struct ComposerState: Sendable, Equatable, Codable {
    public var draft: String
    public var history: ComposerHistory

    public init(draft: String = "", history: ComposerHistory = ComposerHistory()) {
        self.draft = draft
        self.history = history
    }

    public static let empty = ComposerState()

    private enum CodingKeys: String, CodingKey {
        case draft, history
    }

    /// Tolerant: a missing key reads as empty, so a file written with fewer keys still loads.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        draft = try container.decodeIfPresent(String.self, forKey: .draft) ?? ""
        history = try container.decodeIfPresent(ComposerHistory.self, forKey: .history) ?? ComposerHistory()
    }
}

public enum ComposerStateFileError: Error, Sendable, Equatable {
    case encode(String)
    case openTemp(path: String, errno: Int32)
    case write(path: String, errno: Int32)
    case rename(path: String, errno: Int32)
    /// The file on disk was written by a newer CODD (its `v`); it is never replaced.
    case newerVersion(Int)
}

/// `<session dir>/composer.json` (M2 plan D3): `{"draft": …, "history": {"entries": […]}, "v": 1}`,
/// 0600. M5 adds `"v"` (an M4 build ignores the unknown key); a file without it is version 1.
/// A file of a newer version is read as far as its draft and history decode and never saved
/// over. Synchronous blocking I/O: call it off the main actor.
public enum ComposerStateFile {
    public static let name = "composer.json"
    /// The `v` this build writes.
    public static let currentVersion = 1
    /// Each history entry is cut to this many UTF-8 bytes when saved (the draft to `ComposerEncoding.maxBytes`).
    public static let historyEntryMaxBytes = 16 << 10
    /// A larger file is not read (it cannot have been written by `save`).
    static let maxFileBytes = 16 << 20

    /// The saved state, or `.empty` when the file is missing, unreadable or corrupt. A newer
    /// file's draft and history are each used when they decode.
    public static func load(directory: String) -> ComposerState {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maxFileBytes,
              let data = try? Data(contentsOf: url)
        else { return .empty }
        if let state = try? JSONDecoder().decode(ComposerState.self, from: data) { return capped(state) }
        guard let version = version(of: data), version > currentVersion,
              let newer = try? JSONDecoder().decode(NewerState.self, from: data) else { return .empty }
        return capped(ComposerState(draft: newer.draft ?? "", history: newer.history ?? ComposerHistory()))
    }

    /// The integer `v` of the file in `directory`, nil when there is none (an M4 file: version 1).
    public static func storedVersion(directory: String) -> Int? {
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maxFileBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return version(of: data)
    }

    /// Atomically replaces the file (temp file in the same directory, full sync, rename). Does nothing
    /// when `directory` does not exist: the session was removed and its state goes with it.
    public static func save(_ state: ComposerState, directory: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(VersionedState(state: capped(state), v: currentVersion))
        } catch {
            throw ComposerStateFileError.encode(String(describing: error))
        }
        try write(data, to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    /// What `save` writes: the state's members plus `"v"`.
    private struct VersionedState: Encodable {
        let state: ComposerState
        let v: Int

        private enum CodingKeys: String, CodingKey {
            case v
        }

        func encode(to encoder: any Encoder) throws {
            try state.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(v, forKey: .v)
        }
    }

    /// A newer file's members, each on its own (a changed shape of one keeps the other).
    private struct NewerState: Decodable {
        let draft: String?
        let history: ComposerHistory?

        private enum CodingKeys: String, CodingKey {
            case draft, history
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            draft = try? container.decodeIfPresent(String.self, forKey: .draft)
            history = try? container.decodeIfPresent(ComposerHistory.self, forKey: .history)
        }
    }

    /// The top-level `v` when it is a whole number (not a boolean), else nil.
    static func version(of data: Data) -> Int? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = object["v"] as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded(.towardZero) == value, abs(value) < 9_007_199_254_740_992 else { return nil }
        return Int(value)
    }

    /// Throws when the file at `url` now carries a newer `v` (checked right before the rename,
    /// so a newer CODD's file is never replaced even if it appeared after the load).
    private static func checkNotNewer(_ url: URL) throws {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maxFileBytes,
              let data = try? Data(contentsOf: url),
              let version = version(of: data), version > currentVersion else { return }
        throw ComposerStateFileError.newerVersion(version)
    }

    static func capped(_ state: ComposerState) -> ComposerState {
        ComposerState(
            draft: ComposerText.prefix(state.draft, maxUTF8: ComposerEncoding.maxBytes),
            history: state.history.capped(entryBytes: historyEntryMaxBytes)
        )
    }

    /// The CoddCore `AtomicFile` pattern (this package has no dependencies). A directory removed
    /// between the existence check and the open is the same no-op as a missing one.
    private static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0 ... UInt32.max))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            let error = errno
            if error == ENOENT { return }
            throw ComposerStateFileError.openTemp(path: temp.path, errno: error)
        }
        var renamed = false
        defer {
            if !renamed { unlink(temp.path) }
        }
        let writeFailed: Int32? = data.withUnsafeBytes { raw -> Int32? in
            guard var pointer = raw.baseAddress else { return nil }
            var left = raw.count
            while left > 0 {
                let written = Darwin.write(fd, pointer, left)
                if written < 0 {
                    if errno == EINTR { continue }
                    return errno
                }
                left -= written
                pointer = pointer.advanced(by: written)
            }
            return nil
        }
        if let error = writeFailed {
            close(fd)
            throw ComposerStateFileError.write(path: temp.path, errno: error)
        }
        // F_FULLFSYNC flushes the drive cache (plain fsync does not on macOS); a failed sync must not
        // be followed by the rename, or a power loss could leave a torn file in place of a good one.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            let error = errno
            close(fd)
            throw ComposerStateFileError.write(path: temp.path, errno: error)
        }
        close(fd)
        try checkNotNewer(url)
        guard rename(temp.path, url.path) == 0 else {
            let error = errno
            if error == ENOENT { return }
            throw ComposerStateFileError.rename(path: url.path, errno: error)
        }
        renamed = true
    }
}
