import Darwin
import Foundation

/// Claude Code's lock on its global config, taken the way its bundled proper-lockfile takes it
/// (verified in the 2.1.302 bundle, README "The ~/.claude.json lock"): `mkdir("<file>.lock")` where
/// `<file>` is the path as Claude names it (no symlink resolved), `EEXIST` = held, a lock whose
/// mtime is more than 10 s old = stale. Claude's holder refreshes the mtime every 5 s, so a live
/// holder's lock is never stale; Claude itself removes a stale lock, CODD never does (a foreign
/// lock is never ours to delete). Blocking: call off the main actor.
struct UserConfigLock {
    /// proper-lockfile's `stale` default (`stale: 1e4`), which `saveConfigWithLock` keeps.
    static let staleAge: TimeInterval = 10
    /// How often a busy lock is looked at again while waiting.
    static let pollInterval: TimeInterval = 0.05

    let path: String
    private let device: dev_t
    private let inode: ino_t

    private init(path: String, device: dev_t, inode: ino_t) {
        self.path = path
        self.device = device
        self.inode = inode
    }

    /// Takes the lock at `path`, waiting up to `wait` while another holder's lock is fresh.
    /// `.lockBusy` when it stays held, `.staleLock(message)` when it is (or becomes) older than
    /// ``staleAge``; `display` names the lock in that message.
    static func acquire(_ path: String, wait: Duration, display: String) throws(ClaudeUserConfigMCPError) -> UserConfigLock {
        let deadline = Date().addingTimeInterval(seconds(wait))
        while true {
            // Mode 0777 before the umask, like node's fs.mkdir default.
            if mkdir(path, 0o777) == 0 {
                var info = stat()
                guard lstat(path, &info) == 0 else {
                    let code = errno
                    rmdir(path)
                    throw .io(SettingsFS.errnoText("lstat lock", code))
                }
                return UserConfigLock(path: path, device: info.st_dev, inode: info.st_ino)
            }
            let code = errno
            guard code == EEXIST else { throw .io(SettingsFS.errnoText("mkdir lock", code)) }
            var info = stat()
            // Released between the mkdir and the lstat: try again at once.
            guard lstat(path, &info) == 0 else {
                if Date() >= deadline { throw .lockBusy }
                continue
            }
            let now = Date()
            if age(info, now: now) > staleAge { throw .staleLock(staleMessage(display)) }
            let left = deadline.timeIntervalSince(now)
            guard left > 0 else { throw .lockBusy }
            usleep(useconds_t(min(left, pollInterval) * 1_000_000))
        }
    }

    /// `~/.claude.json.lock 看起來是殘留的鎖，請確認沒有 claude 在執行後再試` (with the lock's own path).
    static func staleMessage(_ display: String) -> String {
        "\(display) 看起來是殘留的鎖，請確認沒有 claude 在執行後再試"
    }

    /// Seconds since the lock directory's mtime (negative for Claude's own locks, whose mtime it
    /// sets up to a second ahead).
    static func age(_ info: stat, now: Date) -> TimeInterval {
        let mtime = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        return now.timeIntervalSince1970 - mtime
    }

    static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return max(0, TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18)
    }

    /// The directory at ``path`` is still the one this lock created (nobody removed it as stale
    /// and took it over).
    var isHeld: Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_dev == device && info.st_ino == inode
    }

    /// Moves the lock's mtime to now, as proper-lockfile's update timer does, so a long read of
    /// a large file never lets another writer call the lock stale. `.lockBusy` when the lock was
    /// lost.
    func refresh() throws(ClaudeUserConfigMCPError) {
        guard isHeld else { throw .lockBusy }
        utimes(path, nil)
    }

    /// Removes the lock directory, only when it is still ours.
    func release() {
        if isHeld { rmdir(path) }
    }
}
