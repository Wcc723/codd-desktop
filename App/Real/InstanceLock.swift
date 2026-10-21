import Darwin
import Foundation

/// Who holds a data root's `codd.lock` (its JSON content).
struct InstanceLockOwner: Sendable, Equatable {
    var pid: pid_t
    /// The owner's app bundle path.
    var app: String?
    /// Milliseconds since 1970.
    var startedAt: Int64?
}

/// One CODD per data root (D9): `<dataRoot>/codd.lock` (0600) held with `flock(LOCK_EX | LOCK_NB)`
/// for the app's whole life, content `{"pid":…,"app":"<bundle path>","startedAt":ms}`.
///
/// The kernel drops the flock when the process dies (crash, `kill -9`), so a stale file of a dead
/// process is simply locked again; the pid inside is only read to find the running owner. The fd is
/// `O_CLOEXEC` (holders never inherit it: a holder outliving the app must not keep the root locked).
/// Taken before anything else touches the data root (store start, hook config, binary install).
final class InstanceLock: @unchecked Sendable {
    // @unchecked: `fd` changes only in `release()`, called once by the owner (app quit, tests).

    enum Outcome: Sendable {
        case acquired(InstanceLock)
        /// Another process holds the lock; its owner record when it could be read.
        case heldByAnother(InstanceLockOwner?)
        /// The file could not be created or opened (permissions, a read-only volume).
        case failed(String)
    }

    static let fileName = "codd.lock"
    /// How long a second instance waits for the owner to have written its record (a CODD that is
    /// just starting holds the lock a moment before the content is there).
    static let ownerReadWindow: Duration = .milliseconds(300)

    let path: String
    let owner: InstanceLockOwner
    private var fd: Int32

    private init(path: String, fd: Int32, owner: InstanceLockOwner) {
        self.path = path
        self.fd = fd
        self.owner = owner
    }

    deinit { release() }

    static func path(dataRoot: String) -> String { dataRoot + "/" + fileName }

    /// Creates the data root (0700) when missing, opens or creates `codd.lock` and takes the lock.
    /// Blocking file I/O (a few syscalls; fine at launch on the main thread).
    static func acquire(dataRoot: String, pid: pid_t = getpid(), app: String = Bundle.main.bundlePath,
                        now: Date = Date()) -> Outcome {
        do {
            try FileManager.default.createDirectory(atPath: dataRoot, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .failed("cannot create \(dataRoot): \(error.localizedDescription)")
        }
        let path = path(dataRoot: dataRoot)
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return .failed("cannot open \(path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            guard code == EWOULDBLOCK else { return .failed("flock \(path): \(String(cString: strerror(code)))") }
            return .heldByAnother(waitForOwner(path: path))
        }
        // An earlier file may have been created with a wider mode (or by an older build).
        _ = fchmod(fd, 0o600)
        let owner = InstanceLockOwner(pid: pid, app: app, startedAt: Int64((now.timeIntervalSince1970 * 1000).rounded()))
        let bytes = Array(encode(owner).utf8)
        guard ftruncate(fd, 0) == 0,
              bytes.withUnsafeBytes({ pwrite(fd, $0.baseAddress, $0.count, 0) }) == bytes.count else {
            let reason = String(cString: strerror(errno))
            close(fd)
            return .failed("cannot write \(path): \(reason)")
        }
        return .acquired(InstanceLock(path: path, fd: fd, owner: owner))
    }

    /// Releases the lock (closing the fd drops the flock). The file stays: the next CODD locks it again.
    func release() {
        guard fd >= 0 else { return }
        close(fd)
        fd = -1
    }

    var isHeld: Bool { fd >= 0 }
    /// The locked descriptor (tests check `FD_CLOEXEC`).
    var fileDescriptor: Int32 { fd }

    /// The record in `path` (nil when missing, empty or not ours).
    static func readOwner(path: String) -> InstanceLockOwner? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0 else { return nil }
        return InstanceLockOwner(pid: pid, app: object["app"] as? String, startedAt: (object["startedAt"] as? NSNumber)?.int64Value)
    }

    private static func waitForOwner(path: String) -> InstanceLockOwner? {
        let clock = ContinuousClock()
        let deadline = clock.now + ownerReadWindow
        while true {
            if let owner = readOwner(path: path) { return owner }
            guard clock.now < deadline else { return nil }
            usleep(20_000)
        }
    }

    static func encode(_ owner: InstanceLockOwner) -> String {
        var object: [String: Any] = ["pid": Int(owner.pid)]
        if let app = owner.app { object["app"] = app }
        if let startedAt = owner.startedAt { object["startedAt"] = startedAt }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The spelling both instances use for the show-window request (D28): the physical path, so
    /// `/var/…` and `/private/var/…` (or a symlinked root) name the same folder.
    static func canonicalRoot(_ path: String) -> String {
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

/// D28: a second instance asks the lock holder of the same data root to show its main window.
///
/// M5 D1: posted and observed under both bundle ids' names (`CoddIdentity.showMainWindowNames`),
/// so a new build launched while an older CODD holds the lock still brings that one forward, and
/// an older build's request reaches a new lock holder. A holder that hears both posts shows its
/// window twice, which is the same as once.
enum ShowMainWindowRequest {
    static var names: [Notification.Name] { CoddIdentity.showMainWindowNames }

    /// `object` is the canonical data root path (`InstanceLock.canonicalRoot`).
    static func post(dataRoot: String) {
        let root = InstanceLock.canonicalRoot(dataRoot)
        for name in names {
            DistributedNotificationCenter.default().postNotificationName(name, object: root, userInfo: nil, deliverImmediately: true)
        }
    }

    /// Calls `handler` on the main actor for requests naming this data root only (one observer
    /// per name; the caller keeps the returned tokens).
    @MainActor
    static func observe(dataRoot: String, _ handler: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        let root = InstanceLock.canonicalRoot(dataRoot)
        return names.map { name in
            DistributedNotificationCenter.default().addObserver(forName: name, object: root, queue: .main) { note in
                guard note.object as? String == root else { return }
                MainActor.assumeIsolated { handler() }
            }
        }
    }
}
