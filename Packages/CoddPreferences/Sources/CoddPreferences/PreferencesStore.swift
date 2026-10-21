import Darwin
import Foundation
import Synchronization

public enum PreferencesStoreError: Error, Sendable, Equatable {
    /// The file was written by a newer CODD (its version); it is never overwritten.
    case newerVersion(Int)
    /// The file could not be read at load; it is not overwritten either (it may be fine).
    case unreadable(String)
    case io(String)
}

/// `<dataRoot>/preferences.json` (M3 D14): pretty printed with 2-space indents and sorted keys,
/// mode 0600, replaced atomically. The app debounces saves itself (300 ms after the last change).
///
/// Loading never fails: a bad field falls back to its default alone, keys this version does not
/// know are kept for the next save (at every level), a newer file makes the store read-only, and
/// an unparsable file is moved aside so the defaults can be saved without losing it.
///
/// Synchronous I/O, serialized by an internal lock: call it off the main actor.
public final class PreferencesStore: Sendable {
    public static let fileName = "preferences.json"
    /// UserDefaults key of the M1 / M2 notifications switch (`SessionNotifier`).
    public static let legacyNotificationsKey = "CODDNotificationsEnabled"

    public enum Origin: Sendable, Equatable, CustomStringConvertible {
        /// No file yet: the defaults (nothing is written until ``PreferencesStore/save(_:)``).
        case created
        case loaded
        /// Loaded, but these comma-separated paths (file order) had a wrong type, an unknown
        /// value or an out-of-range number and use their default (or the clamped value).
        case repaired(String)
        /// Written by a newer CODD (its version): its known fields are used, saving throws.
        case newerReadOnly(Int)
        /// Not JSON (or not an object): renamed to this file name in the same directory
        /// (`preferences.json.corrupt-<epoch-ms>`) and the defaults used.
        case corruptMovedAside(String)
        /// The file exists but could not be read or moved aside (permissions, a directory, …):
        /// the defaults are used and saving throws, so the file is never replaced blind.
        case unreadable(String)

        public var description: String {
            switch self {
            case .created: "created"
            case .loaded: "loaded"
            case .repaired(let paths): "repaired(\(paths))"
            case .newerReadOnly(let v): "newerReadOnly(\(v))"
            case .corruptMovedAside(let name): "corruptMovedAside(\(name))"
            case .unreadable(let reason): "unreadable(\(reason))"
            }
        }
    }

    private struct State {
        /// The file as last loaded or saved; its unknown keys are written back under the model's.
        var base: PrefJSON?
        var newerVersion: Int?
        var unreadable: String?
    }

    public let url: URL
    private let state = Mutex(State())

    public init(url: URL) {
        self.url = url
    }

    /// True after loading a newer or unreadable file: ``save(_:)`` throws.
    public var isReadOnly: Bool {
        state.withLock { $0.newerVersion != nil || $0.unreadable != nil }
    }

    /// Reads the file (see the type's rules). `now` names a moved-aside corrupt file.
    public func load(now: Date = Date()) -> (CoddPreferences, Origin) {
        state.withLock { state in
            state = State()
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return (.defaults, .created)
            } catch {
                let reason = Self.reason(error)
                state.unreadable = reason
                return (.defaults, .unreadable(reason))
            }
            guard let json = try? JSONDecoder().decode(PrefJSON.self, from: data), let object = json.objectValue else {
                do {
                    return (.defaults, .corruptMovedAside(try moveAside(now: now)))
                } catch {
                    let reason = "corrupt and not moved aside: " + Self.reason(error)
                    state.unreadable = reason
                    return (.defaults, .unreadable(reason))
                }
            }
            state.base = json
            var (preferences, repaired) = CoddPreferences.read(json)
            preferences.version = CoddPreferences.currentVersion
            switch object["version"]?.integer {
            case let v? where v > CoddPreferences.currentVersion:
                state.newerVersion = v
                return (preferences, .newerReadOnly(v))
            case let v? where v >= 1:
                break
            default:
                // A hand-written file without a usable version is read as the current one.
                repaired.insert("version", at: 0)
            }
            return (preferences, repaired.isEmpty ? .loaded : .repaired(repaired.joined(separator: ", ")))
        }
    }

    /// Writes `preferences` over the last loaded file's unknown keys. Throws instead of replacing a
    /// newer file (also one that appeared on disk since the load) or a file that was unreadable.
    public func save(_ preferences: CoddPreferences) throws(PreferencesStoreError) {
        try state.withLock { (state: inout State) throws(PreferencesStoreError) in
            if let v = state.newerVersion { throw .newerVersion(v) }
            if let reason = state.unreadable { throw .unreadable(reason) }
            if let existing = try? Data(contentsOf: url),
               let v = (try? JSONDecoder().decode(PrefJSON.self, from: existing))?.objectValue?["version"]?.integer,
               v > CoddPreferences.currentVersion {
                state.newerVersion = v
                throw .newerVersion(v)
            }
            let merged = preferences.documentJSON().merged(over: state.base)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data: Data
            do {
                data = try encoder.encode(merged)
            } catch {
                throw .io(Self.reason(error))
            }
            do {
                try PrefAtomicFile.write(data, to: url)
            } catch {
                throw .io(Self.reason(error))
            }
            state.base = merged
        }
    }

    /// M1 / M2 kept one notifications switch in UserDefaults (WAITING and ERROR banners). When the
    /// user had turned it off, those two events stay silent in the M3 matrix; DONE and EXITED are
    /// new events and keep their defaults. The key itself is left alone. Returns whether anything
    /// changed (call it once, when the store reports ``Origin/created``).
    public static func migrateLegacyNotifications(from defaults: UserDefaults, into preferences: inout CoddPreferences) -> Bool {
        // `bool(forKey:)` also reads the string form an argument domain gives (`NO`).
        let stored = defaults.object(forKey: legacyNotificationsKey) == nil ? nil : defaults.bool(forKey: legacyNotificationsKey)
        return migrateLegacyNotifications(enabled: stored, into: &preferences)
    }

    /// The rule of ``migrateLegacyNotifications(from:into:)``; `enabled` nil = never set.
    static func migrateLegacyNotifications(enabled: Bool?, into preferences: inout CoddPreferences) -> Bool {
        guard enabled == false else { return false }
        let before = preferences.notifications
        preferences.notifications.waiting.notify = false
        preferences.notifications.error.notify = false
        return preferences.notifications != before
    }

    /// Renames the unreadable file aside (`preferences.json.corrupt-<epoch-ms>`, `-2`… when
    /// taken) and returns the new file name.
    private func moveAside(now: Date) throws -> String {
        let dir = url.deletingLastPathComponent()
        let stem = "\(url.lastPathComponent).corrupt-\(Int64((now.timeIntervalSince1970 * 1000).rounded(.down)))"
        var name = stem
        var n = 2
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) {
            name = "\(stem)-\(n)"
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent(name))
        return name
    }

    private static func reason(_ error: any Error) -> String {
        if let cocoa = error as? CocoaError, let underlying = cocoa.userInfo[NSUnderlyingErrorKey] as? NSError {
            return "\(cocoa.code.rawValue) \(underlying.domain) \(underlying.code)"
        }
        return String(describing: error)
    }
}

/// Crash-safe replacement: temp file in the same directory, `F_FULLFSYNC`, `rename(2)`. The same
/// steps as CoddCore's `AtomicFile`, copied so this package needs no dependency.
enum PrefAtomicFile {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func write(_ data: Data, to url: URL, permissions: mode_t = 0o600, directoryPermissions: mode_t = 0o700) throws {
        let dir = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: directoryPermissions)])
        }
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
        guard fd >= 0 else { throw Failure(description: "open temp errno \(errno)") }
        var ok = false
        defer {
            if !ok { unlink(temp.path) }
        }
        let writeErrno: Int32? = data.withUnsafeBytes { raw -> Int32? in
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
        if let e = writeErrno {
            close(fd)
            throw Failure(description: "write errno \(e)")
        }
        // `fsync` does not flush the drive's cache on macOS; F_FULLFSYNC does (fsync where it is
        // unsupported). Never rename after a failed sync: a power loss could leave a torn file.
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 {
            let e = errno
            close(fd)
            throw Failure(description: "sync errno \(e)")
        }
        // The umask may have narrowed the mode given to open(2); 0600 is the contract.
        fchmod(fd, permissions)
        close(fd)
        guard rename(temp.path, url.path) == 0 else { throw Failure(description: "rename errno \(errno)") }
        ok = true
    }
}
