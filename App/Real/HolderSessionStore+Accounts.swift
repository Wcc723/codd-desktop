import CoddCore
import Foundation

/// D12 pinned sessions and the account each claude session runs on. A pin is a record's
/// `accountNumber`: either CODD's own (`固定 #n`, started with `CLAUDE_CONFIG_DIR=<the account's cswap
/// profile>`) or a launch profile whose environment sets `CLAUDE_CONFIG_DIR` (the profile pins
/// itself; CODD only records the account). Profile paths contain an e-mail slug: they go into a
/// launch's environment and a transcript lookup, never into a log, the dump or the UI (D31).
extension HolderSessionStore {
    /// `accountID` / `accountPinned` of a CODD claude session: its pin, else the account it
    /// follows (the global login).
    func applyAccount(to session: SessionVM) {
        guard session.kind == .claude, session.externalInfo == nil else { return }
        let pinned = records[session.id]?.accountNumber
        let account = pinned.map(String.init) ?? followingAccountID
        if session.accountID != account { session.accountID = account }
        if session.accountPinned != (pinned != nil) { session.accountPinned = pinned != nil }
    }

    /// The account store's active account changed: following sessions show it.
    func setFollowingAccount(_ id: AccountID?) {
        guard followingAccountID != id else { return }
        followingAccountID = id
        for session in sessionsByID.values.map({ $0 }) + archivedByID.values.map({ $0 }) { applyAccount(to: session) }
    }

    /// Live CODD claude sessions that follow the global login, and those pinned per account
    /// (`12 個 session 約 30 秒內套用`, the pinned counts of the account rows).
    var sessionAccountCounts: (following: Int, pinned: [Int: Int]) {
        var following = 0
        var pinned: [Int: Int] = [:]
        for session in sessionsByID.values.map({ $0 }) + archivedByID.values.map({ $0 })
        where session.kind == .claude && session.state.isLive {
            if let n = records[session.id]?.accountNumber { pinned[n, default: 0] += 1 } else { following += 1 }
        }
        return (following, pinned)
    }

    /// A launch profile's own `CLAUDE_CONFIG_DIR` (absolute), if it sets one.
    func launchProfileConfigDir(_ profileID: String?) -> String? {
        let profile = profiles.document.claudeProfile(id: profileID)
        guard let dir = JSText.nonBlankTrimmed(profile.environment["CLAUDE_CONFIG_DIR"]), dir.hasPrefix("/") else { return nil }
        return dir
    }

    /// The Claude config directory a CODD claude session runs with: its launch profile's, else
    /// its pinned account's profile; nil = the default `<claudeDir>`.
    func claudeConfigDirectory(for id: SessionID) -> String? {
        guard let record = records[id], record.kind == .claude else { return nil }
        if let dir = launchProfileConfigDir(record.launchProfileId) { return dir }
        return record.accountNumber.flatMap { accountProfilePath?($0) }
    }

    /// D12: the transcripts of a pinned session live in `<profile>/projects` (per account, §1):
    /// RESUME's existence check, 刪除對話紀錄, the resend and the last prompt look there.
    func transcriptCatalog(for id: SessionID) -> TranscriptCatalog {
        guard let dir = claudeConfigDirectory(for: id) else { return transcripts }
        let key = Self.standardize(dir)
        if let catalog = configDirCatalogs[key] { return catalog }
        // The directory as the session got it (the key only dedupes spellings).
        let catalog = TranscriptCatalog(projectsDirectory: URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true))
        configDirCatalogs[key] = catalog
        return catalog
    }

    /// `CLAUDE_CONFIG_DIR` for pinning account `n` (a new session: the active account is refused;
    /// a relaunch: only a vanished or stale profile is), else the problem to show (繁體中文).
    func pinnedConfigDir(account n: Int, relaunch: Bool) -> Result<String, PinRefusal> {
        switch accountPinning?(n, relaunch) ?? .notReady {
        case .usable(let path): return .success(path)
        case .notReady: return .failure(PinRefusal("還在讀取 cswap 的帳號，請稍候再試一次。"))
        case .active: return .failure(PinRefusal("#\(n) 是目前的全域登入；cswap 不為它建立獨立設定目錄"))
        case .unknownAccount: return .failure(PinRefusal("沒有 #\(n) 這個 cswap 帳號。"))
        case .needsProfile: return .failure(PinRefusal(AccountPinOptions.staleProfileMessage(String(n))))
        }
    }

    /// RESUME / RESTART of a session pinned by CODD: its profile again (nil: not pinned, or its
    /// launch profile pins itself); a vanished or stale profile is refused (D12).
    func relaunchConfigDir(for id: SessionID) -> Result<String?, PinRefusal> {
        guard let record = records[id], record.kind == .claude, let n = record.accountNumber,
              launchProfileConfigDir(record.launchProfileId) == nil else { return .success(nil) }
        return pinnedConfigDir(account: n, relaunch: true).map { Optional($0) }
    }

    /// The registry folders of the Claude config directories in use besides `<claudeDir>`
    /// (launch profiles' own `CLAUDE_CONFIG_DIR` of CODD sessions).
    var launchProfileRegistryDirectories: [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for record in records.values where record.kind == .claude {
            guard let dir = launchProfileConfigDir(record.launchProfileId), seen.insert(Self.standardize(dir)).inserted else { continue }
            out.append(URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("sessions", isDirectory: true))
        }
        return out
    }
}

/// Why a pin cannot be used (繁體中文, no path).
struct PinRefusal: Error, Equatable {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}
