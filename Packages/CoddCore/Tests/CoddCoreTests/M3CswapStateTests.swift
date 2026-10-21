import Foundation
import Testing
@testable import CoddCore

/// A cswap state fixture (`Fixtures/cswap/state/<case>/`) copied into a temp home:
/// `<home>/.claude-swap-backup` (the case's `root/`), `<home>/.claude.json` (`claude.json`),
/// `<home>/.claude/settings.json`. Profiles, symlinks and markers are added by the tests.
struct StateFixture {
    let temp: TempDir
    let home: URL
    let root: URL
    let claudeDir: URL

    var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    var settings: URL { claudeDir.appendingPathComponent("settings.json") }
    var sessions: URL { root.appendingPathComponent("sessions", isDirectory: true) }

    init(_ name: String = "canonical") throws {
        temp = try TempDir("codd-m3-state")
        home = temp.url.appendingPathComponent("home", isDirectory: true)
        root = home.appendingPathComponent(".claude-swap-backup", isDirectory: true)
        claudeDir = home.appendingPathComponent(".claude", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let source = try Fixtures.directory("cswap").appendingPathComponent("state/\(name)", isDirectory: true)
        let sourceRoot = source.appendingPathComponent("root", isDirectory: true)
        if fm.fileExists(atPath: sourceRoot.path) {
            try fm.copyItem(at: sourceRoot, to: root)
        } else {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let sourceClaude = source.appendingPathComponent("claude.json")
        if fm.fileExists(atPath: sourceClaude.path) { try fm.copyItem(at: sourceClaude, to: claudeJSON) }
        try Data("{}\n".utf8).write(to: settings)
    }

    func reader(withSettings: Bool = true) -> CswapStateReader {
        CswapStateReader(root: root, claudeJSONCandidates: CswapStateReader.claudeJSONCandidates(claudeDir: claudeDir),
                         claudeSettingsURL: withSettings ? settings : nil)
    }

    func read(now: Date = referenceNow) throws(CswapStateError) -> CswapStateSnapshot {
        try reader().read(now: now)
    }

    /// Writes `text` at `relative` under the cswap root.
    func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(relative))
    }

    /// A real profile directory `sessions/<name>/`, optionally with a `settings.json`.
    @discardableResult
    func makeProfile(_ name: String, settings: ProfileSettings = .none) throws -> URL {
        let dir = sessions.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("settings.json")
        switch settings {
        case .none: break
        case .symlinkToUser: try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: self.settings.path)
        case .symlinkElsewhere:
            let other = temp.file("other-settings.json")
            try Data("{}".utf8).write(to: other)
            try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: other.path)
        case .regularCopy: try Data("{}\n".utf8).write(to: file)
        }
        return dir
    }

    enum ProfileSettings { case none, symlinkToUser, symlinkElsewhere, regularCopy }
}

/// Every text rendering a value can leak through: description, interpolation, reflection, dump.
func renderings(_ value: Any) -> [String] {
    var dumped = ""
    dump(value, to: &dumped)
    return [String(describing: value), "\(value)", String(reflecting: value), dumped]
}

/// No e-mail of the fixtures (`*@example.com`) and no profile slug (`…-example-com`, cswap's
/// `…_example.com`) in any rendering.
func expectNoAccountLeak(_ value: Any, sourceLocation: SourceLocation = #_sourceLocation) {
    for text in renderings(value) {
        #expect(!text.contains("example.com"), "leaked e-mail: \(text)", sourceLocation: sourceLocation)
        #expect(!text.contains("example-com"), "leaked slug: \(text)", sourceLocation: sourceLocation)
        #expect(!text.contains("example_com"), "leaked slug: \(text)", sourceLocation: sourceLocation)
        #expect(!text.contains("Organization"), "leaked organizationName: \(text)", sourceLocation: sourceLocation)
    }
}

private let fetched3 = Date(timeIntervalSince1970: 1_792_032_108)

/// `currentLogin()` as `slot|plan|loggedIn` (`-` for nil).
private func loginText(_ reader: CswapStateReader) -> String {
    let l = reader.currentLogin()
    return "\(l.existingAccount.map(String.init) ?? "-")|\(l.plan ?? "-")|\(l.loggedIn)"
}
private let fetched12 = Date(timeIntervalSince1970: 1_792_031_940)

@Suite("cswap state reader (M3)")
struct CswapStateReaderTests {
    @Test func canonicalSnapshot() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let s = try f.read()
        #expect(s.accounts.map(\.number) == [1, 2, 3])
        #expect(s.accounts.map(\.alias) == ["個人", "藍鵲", "工作"])
        #expect(s.activeAccountNumber == 3)
        #expect(s.activeSource == .claudeJSON)
        #expect(s.accounts.map(\.isActive) == [false, false, true])
        #expect(s.accounts.map(\.plan) == ["MAX 20x", "MAX 20x", "MAX 20x"])
        #expect(s.accounts.map(\.usageHealth) == [.fresh, .fresh, .fresh])
        #expect(s.accounts.map(\.isDisabled) == [false, false, false])
        #expect(s.warnings.isEmpty)
        #expect(s.readAt == referenceNow)
        #expect(s.root == f.root)

        let a3 = try #require(s.account(3))
        #expect(a3.usageFetchedAt == fetched3)
        #expect(a3.usage?.fiveHour?.pct == 9)
        #expect(a3.usage?.fiveHour?.resetsAt == JSDate.date(fromISO: "2026-10-15T05:39:00Z"))
        #expect(a3.usage?.fiveHour?.countdown == "2h 57m")
        #expect(a3.usage?.sevenDay?.pct == 85)
        #expect(a3.usage?.sevenDay?.resetsAt == JSDate.date(fromISO: "2026-10-18T04:00:00Z"))
        #expect(a3.usage?.scoped.map(\.name) == ["Fable"])
        #expect(a3.usage?.spend?.limit == 50)
        let a1 = try #require(s.account(1))
        #expect(a1.usage?.fiveHour?.resetsAt == nil) // 5h not started
        #expect(a1.usage?.sevenDay?.resetsAt == JSDate.date(milliseconds: 1_792_411_200_441))
        #expect(a1.usageFetchedAt == fetched12)
        #expect(s.account(2)?.usage?.sevenDay?.remainingPercent == 46)
        #expect(s.accounts.allSatisfy { $0.sessionProfile == nil && !$0.sessionProfileStale && $0.sessionProfileSharesSettings == nil })
    }

    /// Each slot carries an opaque, stable token of its login (never the e-mail) that changes when
    /// another login takes the slot (M3 review: quota.json keyed by number only).
    @Test func slotIdentitiesAreOpaqueStableAndFollowTheLogin() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let s = try f.read()
        let ids = s.accounts.map(\.identity)
        #expect(ids.allSatisfy { $0?.count == 16 })
        #expect(Set(ids.compactMap { $0 }).count == 3)
        #expect(try f.read().accounts.map(\.identity) == ids, "stable across reads")
        #expect(ids.allSatisfy { !($0 ?? "").contains("example") })
        expectNoAccountLeak(s)
        // `cswap swap 2 3`: the records trade places.
        let url = f.root.appendingPathComponent("sequence.json")
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "north@example.com", with: "SWAP").replacingOccurrences(of: "work@example.com", with: "north@example.com")
            .replacingOccurrences(of: "SWAP", with: "work@example.com")
            .replacingOccurrences(of: "0000000000b2", with: "SWAPORG").replacingOccurrences(of: "0000000000b3", with: "0000000000b2")
            .replacingOccurrences(of: "SWAPORG", with: "0000000000b3")
        try Data(text.utf8).write(to: url)
        let swapped = try f.read()
        #expect(swapped.account(2)?.identity == s.account(3)?.identity)
        #expect(swapped.account(3)?.identity == s.account(2)?.identity)
    }

    /// SPEC §9 R7: the merged accounts sort #2, #3, #1 (the active one keeps its place).
    @Test func canonicalOrderThroughTheAssembler() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let accounts = AccountAssembler.accounts(state: try f.read(), book: QuotaBook(), now: referenceNow)
        let sorted = AccountOrdering.sorted(accounts, now: referenceNow)
        #expect(sorted.map(\.number) == [2, 3, 1])
        #expect(sorted[1].isActive)
        #expect(sorted.map(\.source) == [.cswap, .cswap, .cswap])
        #expect(sorted.first { $0.number == 3 }?.sourceAt == fetched3)
    }

    @Test func activeFallsBackToTheSequenceFile() throws {
        let f = try StateFixture("fallback")
        defer { f.temp.remove() }
        let s = try f.read()
        #expect(s.activeAccountNumber == 2)
        #expect(s.activeSource == .sequenceFile)
        #expect(s.accounts.map(\.isActive) == [false, true])
        #expect(s.accounts.allSatisfy { $0.usage == nil && $0.usageHealth == .none && $0.plan == nil })
        #expect(s.warnings.isEmpty)
    }

    @Test func unreadableClaudeJSONFallsBackWithAWarning() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try Data("{\"oauthAccount\": {\"emailAddress\": \"teach".utf8).write(to: f.claudeJSON)
        let s = try f.read()
        #expect(s.activeAccountNumber == 3) // sequence.json says 3 as well
        #expect(s.activeSource == .sequenceFile)
        #expect(s.warnings.count == 1)
        #expect(s.warnings.first?.contains(".claude.json") == true)
        // Without the live identity the plan comes from the config backup.
        #expect(s.account(3)?.plan == "MAX 20x")
    }

    @Test func loggedOutClaudeJSONUsesTheSequenceFileSilently() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try Data("{\"numStartups\": 3}".utf8).write(to: f.claudeJSON)
        let s = try f.read()
        #expect(s.activeSource == .sequenceFile)
        #expect(s.activeAccountNumber == 3)
        #expect(s.warnings.isEmpty)
    }

    /// cswap's `current_account_number`: an unmanaged live login is never guessed.
    @Test func anUnmanagedLoginHasNoActiveAccount() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try Data(#"{"oauthAccount": {"emailAddress": "stranger@example.com", "organizationUuid": ""}}"#.utf8).write(to: f.claudeJSON)
        let s = try f.read()
        #expect(s.activeAccountNumber == nil)
        #expect(s.activeSource == .none)
        #expect(s.accounts.allSatisfy { !$0.isActive })
        #expect(s.warnings == ["目前的 Claude 登入不是 cswap 管理的帳號"])
        expectNoAccountLeak(s)
    }

    /// `UsageStore._matches`: a row of another identity (reused slot) is invisible.
    @Test func usageRowsOfAnotherIdentityAreIgnored() throws {
        let f = try StateFixture("mismatch")
        defer { f.temp.remove() }
        let s = try f.read()
        #expect(s.account(1)?.usage?.fiveHour?.pct == 11) // missing organizationUuid == ""
        #expect(s.account(2)?.usage == nil)              // e-mail differs
        #expect(s.account(3)?.usage == nil)              // organization differs
        #expect(s.account(2)?.usageHealth == CswapUsageHealth.none)
        #expect(s.activeAccountNumber == 1)
        #expect(s.activeSource == .sequenceFile)
    }

    @Test func aNewerCacheSchemaIsIgnoredWithAWarning() throws {
        let f = try StateFixture("schema3")
        defer { f.temp.remove() }
        let s = try f.read()
        #expect(s.accounts.allSatisfy { $0.usage == nil })
        #expect(s.warnings.count == 1)
        #expect(s.warnings.first?.contains("版本 3") == true)
        expectNoAccountLeak(s)
    }

    @Test func aTornSequenceFileIsUnreadable() throws {
        let f = try StateFixture("torn")
        defer { f.temp.remove() }
        #expect(throws: CswapStateError.unreadable("sequence.json 不是有效的 JSON")) { try f.read() }
    }

    @Test func aMissingStateRootIsMissing() throws {
        let temp = try TempDir("codd-m3-empty")
        defer { temp.remove() }
        let reader = CswapStateReader(root: temp.file(".claude-swap-backup"), claudeJSONCandidates: [temp.file(".claude.json")])
        #expect(throws: CswapStateError.missing("找不到 sequence.json")) { try reader.read(now: referenceNow) }
    }

    @Test func unsupportedSequenceShapes() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.write("sequence.json", "[1, 2, 3]")
        #expect(throws: CswapStateError.unsupported("sequence.json 格式不符")) { try f.read() }
        try f.write("sequence.json", #"{"accounts": [1, 2]}"#)
        #expect(throws: CswapStateError.unsupported("sequence.json 的 accounts 格式不符")) { try f.read() }
        // A fresh cswap install: no accounts yet.
        try f.write("sequence.json", #"{"activeAccountNumber": null, "sequence": [], "accounts": {}}"#)
        let s = try f.read()
        #expect(s.accounts.isEmpty)
        #expect(s.activeSource == .none)
        #expect(s.warnings.isEmpty)
    }

    @Test func sequenceOrderAndOddKeys() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.write("sequence.json", """
        {"activeAccountNumber": 3, "sequence": [3, 1, 3, 9],
         "accounts": {"1": {"email": "personal@example.com"}, "2": {"email": "north@example.com"},
                      "3": {"email": "work@example.com", "organizationUuid": "00000000-0000-4000-8000-0000000000b3"},
                      "x": {"email": "junk@example.com"}, "12345": {"email": "big@example.com"}, "4": "not an object"}}
        """)
        let s = try f.read()
        #expect(s.accounts.map(\.number) == [3, 1, 2])
        #expect(s.accounts.map(\.alias) == [nil, nil, nil])
    }

    @Test func aTornCacheWarnsAndAMissingCacheDoesNot() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.write("cache/usage.json", #"{"schemaVersion": 2, "accounts": {"1": {"email": "personal@exa"#)
        let torn = try f.read()
        #expect(torn.accounts.allSatisfy { $0.usage == nil && $0.usageHealth == .none })
        #expect(torn.warnings == ["cswap 用量快取（cache/usage.json）無法讀取"])
        try f.remove("cache")
        let missing = try f.read()
        #expect(missing.accounts.allSatisfy { $0.usage == nil })
        #expect(missing.warnings.isEmpty)
        #expect(missing.activeAccountNumber == 3)
    }

    @Test func healthDisabledReloginAndFailing() throws {
        let f = try StateFixture("health")
        defer { f.temp.remove() }
        let s = try f.read()
        let a1 = try #require(s.account(1)), a2 = try #require(s.account(2)), a3 = try #require(s.account(3))
        #expect(a1.isDisabled)
        #expect(a1.usageHealth == .stale) // 1120 s old
        #expect(a2.usageHealth == .reloginRequired) // authDeadStrikes wins over failures
        #expect(a3.usageHealth == .failing("http-500 for •••@•••"))
        #expect(a3.usage?.sevenDay?.pct == 99) // last-good numbers are kept
        #expect(a3.isActive)
        #expect(a3.plan == "MAX 5x") // from .claude.json
        #expect(a1.plan == nil)      // no config backup in this fixture
        expectNoAccountLeak(s)
    }

    @Test func freshnessBoundary() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let edge = try f.read(now: fetched12.addingTimeInterval(CswapUsageHealth.freshness))
        #expect(edge.account(1)?.usageHealth == .fresh)
        let later = try f.read(now: fetched12.addingTimeInterval(CswapUsageHealth.freshness + 1))
        #expect(later.account(1)?.usageHealth == .stale)
        #expect(later.account(3)?.usageHealth == .fresh) // 12 s newer
    }

    @Test func theSingleRealProfileDirectory() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let dir = try f.makeProfile("2-north-example-com")
        let s = try f.read()
        #expect(s.account(2)?.sessionProfile?.path == dir.path)
        #expect(s.account(2)?.sessionProfile?.path.hasSuffix("/sessions/2-north-example-com") == true)
        #expect(s.account(1)?.sessionProfile == nil)
        #expect(s.account(3)?.sessionProfile == nil)
        // "12-…" is not account 1's and "2-…" is not account 12's.
        try f.makeProfile("12-other")
        #expect(try f.read().account(1)?.sessionProfile == nil)
        expectNoAccountLeak(try f.read())
    }

    @Test func aSymlinkedProfileIsIgnored() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let elsewhere = f.temp.file("elsewhere-profile")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.sessions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.sessions.appendingPathComponent("3-work-example-com").path,
                                                   withDestinationPath: elsewhere.path)
        try f.write("sessions/1-file-not-dir", "x")
        let s = try f.read()
        #expect(s.account(3)?.sessionProfile == nil)
        #expect(s.account(1)?.sessionProfile == nil)
    }

    @Test func severalProfilesPreferCswapsOwnName() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("2-old-login")
        try f.makeProfile("2-north_example.com") // claude_swap slugify_email("north@example.com")
        let s = try f.read()
        #expect(s.account(2)?.sessionProfile?.lastPathComponent == "2-north_example.com")
        #expect(s.warnings.isEmpty)
        try FileManager.default.removeItem(at: f.sessions.appendingPathComponent("2-north_example.com"))
        try f.makeProfile("2-another")
        let ambiguous = try f.read()
        #expect(ambiguous.account(2)?.sessionProfile == nil)
        #expect(ambiguous.warnings == ["#2 有多個 cswap session 設定目錄，無法判斷要用哪一個"])
        #expect(CswapStateReader.slugify("North.User+x@Example.com") == "North.User_x_Example.com")
    }

    @Test func staleMarkerSibling() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("2-north-example-com")
        #expect(try f.read().account(2)?.sessionProfileStale == false)
        try f.write("sessions/.2-north-example-com.cswap-stale-credentials", "")
        #expect(try f.read().account(2)?.sessionProfileStale == true)
    }

    @Test func staleMarkerLegacyChild() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("2-north-example-com")
        try f.write("sessions/2-north-example-com/.cswap-stale-credentials", "")
        #expect(try f.read().account(2)?.sessionProfileStale == true)
    }

    @Test func profileSharesSettings() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("1-personal-example-com", settings: .symlinkToUser)
        try f.makeProfile("2-north-example-com", settings: .regularCopy)
        try f.makeProfile("3-work-example-com", settings: .none)
        let s = try f.read()
        #expect(s.account(1)?.sessionProfileSharesSettings == true)
        #expect(s.account(2)?.sessionProfileSharesSettings == false)
        #expect(s.account(3)?.sessionProfileSharesSettings == false)
        // Without a settings URL to compare with: unknown.
        let noURL = try f.reader(withSettings: false).read(now: referenceNow)
        #expect(noURL.accounts.map(\.sessionProfileSharesSettings) == [nil, nil, nil])
    }

    @Test func profileSettingsLinkedElsewhereOrDangling() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("1-personal-example-com", settings: .symlinkElsewhere)
        #expect(try f.read().account(1)?.sessionProfileSharesSettings == false)
        // A link to the user settings path still counts while that file is missing.
        try FileManager.default.removeItem(at: f.sessions.appendingPathComponent("1-personal-example-com"))
        try f.makeProfile("1-personal-example-com", settings: .symlinkToUser)
        try FileManager.default.removeItem(at: f.settings)
        let dangling = CswapStateReader(root: f.root, claudeJSONCandidates: [f.claudeJSON], claudeSettingsURL: f.settings)
        #expect(try dangling.read(now: referenceNow).account(1)?.sessionProfileSharesSettings == true)
    }

    @Test func claudeJSONCandidates() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        #expect(CswapStateReader.claudeJSONCandidates(claudeDir: f.claudeDir).map(\.path) == [f.claudeJSON.path])
        let legacy = f.claudeDir.appendingPathComponent(".config.json")
        try Data("{}".utf8).write(to: legacy)
        #expect(CswapStateReader.claudeJSONCandidates(claudeDir: f.claudeDir).map(\.path) == [legacy.path])
        #expect(CswapStateReader.standardRoot(home: "/Users/u").path == "/Users/u/.claude-swap-backup")
    }

    /// claude_swap/paths.py: `<claudeDir>/.config.json` wins over `~/.claude.json` when it exists.
    @Test func theLegacyConfigJSONDecidesTheActiveAccount() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let source = try Fixtures.directory("cswap").appendingPathComponent("state/legacy-config/config.json")
        try FileManager.default.copyItem(at: source, to: f.claudeDir.appendingPathComponent(".config.json"))
        let s = try f.read()
        #expect(s.activeAccountNumber == 2)
        #expect(s.activeSource == .claudeJSON)
        #expect(s.account(2)?.plan == "TEAM")
        #expect(loginText(f.reader()) == "2|TEAM|true")
    }

    @Test func currentLogin() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let login = f.reader().currentLogin()
        #expect(login.existingAccount == 3)
        #expect(login.plan == "MAX 20x")
        #expect(login.loggedIn)
        try Data(#"{"oauthAccount": {"emailAddress": "new@example.com", "organizationType": "claude_pro"}}"#.utf8).write(to: f.claudeJSON)
        #expect(loginText(f.reader()) == "-|PRO|true")
        try FileManager.default.removeItem(at: f.claudeJSON)
        #expect(loginText(f.reader()) == "-|-|false")
    }

    /// Dialog C (D24): a login change is seen even between two logins cswap does not manage.
    @Test func currentLoginTokenFollowsTheIdentity() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        let reader = f.reader()
        let work = try #require(reader.currentLoginToken())
        try Data(#"{"oauthAccount": {"emailAddress": "new@example.com", "organizationUuid": "org-9"}}"#.utf8).write(to: f.claudeJSON)
        let first = try #require(f.reader().currentLoginToken())
        try Data(#"{"oauthAccount": {"emailAddress": "other@example.com", "organizationUuid": "org-9"}}"#.utf8).write(to: f.claudeJSON)
        let second = try #require(f.reader().currentLoginToken())
        #expect(work != first && first != second)
        #expect(f.reader().currentLogin().existingAccount == nil)
        // The token says nothing readable about the account.
        #expect(!String(describing: second).contains("example"))
        try FileManager.default.removeItem(at: f.claudeJSON)
        #expect(f.reader().currentLoginToken() == nil)
    }

    @Test func configBackupPlansAreCachedByStamp() throws {
        let f = try StateFixture("fallback")
        defer { f.temp.remove() }
        let reader = f.reader()
        #expect(try reader.read(now: referenceNow).account(1)?.plan == nil)
        try f.write("configs/.claude-config-1-personal@example.com.json",
                    #"{"oauthAccount": {"organizationRateLimitTier": "default_claude_max_5x"}}"#)
        #expect(try reader.read(now: referenceNow).account(1)?.plan == "MAX 5x")
        try f.write("configs/.claude-config-1-personal@example.com.json",
                    #"{"oauthAccount": {"organizationType": "claude_enterprise", "x": "longer file"}}"#)
        #expect(try reader.read(now: referenceNow).account(1)?.plan == "ENT")
    }

    @Test func fingerprintUsesFixedLabels() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("2-north-example-com")
        let reader = f.reader()
        let a = reader.fingerprint()
        #expect(Set(a.keys) == ["sequence", "usage", "claudeJSON", "sessions", "config-1", "config-2", "config-3"])
        for (k, v) in a {
            #expect(!k.contains("example") && !v.contains("example") && !v.contains("/"))
        }
        #expect(a["claudeJSON"]?.hasPrefix("0:") == true)
        #expect(reader.fingerprint() == a)
        try f.write("sequence.json", String(decoding: try Data(contentsOf: f.root.appendingPathComponent("sequence.json")), as: UTF8.self) + "\n")
        let b = reader.fingerprint()
        #expect(b["sequence"] != a["sequence"])
        #expect(b["usage"] == a["usage"])
        try f.remove("cache/usage.json")
        #expect(reader.fingerprint()["usage"] == "missing")
        expectNoAccountLeak(reader)
    }

    /// D31: no rendering of any reader result carries an e-mail, an organization name or a slug.
    @Test func nothingLeaksThroughDescriptionsOrDumps() throws {
        let f = try StateFixture()
        defer { f.temp.remove() }
        try f.makeProfile("2-north-example-com", settings: .symlinkToUser)
        try f.makeProfile("3-north_example.com")
        let s = try f.read()
        #expect(s.accounts.filter { $0.sessionProfile != nil }.count == 2)
        expectNoAccountLeak(s)
        for a in s.accounts { expectNoAccountLeak(a) }
        expectNoAccountLeak(s.warnings)
        let merged = AccountAssembler.accounts(state: s, book: QuotaBook(), now: referenceNow)
        for a in merged { expectNoAccountLeak(a) }
        #expect(String(describing: s.account(2) as Any).contains("profile: yes"))
        expectNoAccountLeak(f.reader())

        let health = try StateFixture("health")
        defer { health.temp.remove() }
        expectNoAccountLeak(try health.read())
        let unmanaged = try StateFixture()
        defer { unmanaged.temp.remove() }
        try Data(#"{"oauthAccount": {"emailAddress": "stranger@example.com"}}"#.utf8).write(to: unmanaged.claudeJSON)
        expectNoAccountLeak(try unmanaged.read())
    }

    @Test func errorsCarryNoPathsOrEmails() throws {
        let torn = try StateFixture("torn")
        defer { torn.temp.remove() }
        var errors: [CswapStateError] = [.missing("找不到 sequence.json")]
        do { _ = try torn.read() } catch { errors.append(error) }
        try torn.write("sequence.json", "\"text\"")
        do { _ = try torn.read() } catch { errors.append(error) }
        #expect(errors.count == 3)
        for e in errors {
            expectNoAccountLeak(e)
            for text in renderings(e) { #expect(!text.contains(torn.root.path)) }
            #expect(!e.reason.isEmpty)
        }
    }

    @Test func planLabels() {
        let rows: [(String?, String?, String?)] = [
            ("default_claude_max_20x", "claude_max", "MAX 20x"),
            ("DEFAULT_CLAUDE_MAX_20X", nil, "MAX 20x"),
            ("default_claude_max_5x", nil, "MAX 5x"),
            (nil, "claude_max", "MAX"),
            ("default_claude_ai", "claude_max", "MAX"),
            ("default_claude_pro", nil, "PRO"),
            (nil, "claude_pro", "PRO"),
            (nil, "claude_team", "TEAM"),
            ("default_claude_ai", "claude_enterprise", "ENT"),
            ("default_claude_ai", "claude_free", nil),
            ("", "", nil),
            (nil, nil, nil),
            ("approved_tier", nil, nil),
        ]
        for (tier, type, expected) in rows {
            #expect(PlanLabel.from(rateLimitTier: tier, organizationType: type) == expected, "\(String(describing: tier)) / \(String(describing: type))")
        }
    }
}

@Suite("Account key (D6)")
struct AccountKeyTests {
    /// The table shared with C2's `StatusLineAccountKey`.
    @Test func sharedTable() {
        let home = "/Users/u"
        #expect(AccountKey.from(claudeConfigDir: nil, home: home) == .default)
        #expect(AccountKey.from(claudeConfigDir: "", home: home) == .default)
        #expect(AccountKey.from(claudeConfigDir: "/Users/u/.claude", home: home) == .default)
        #expect(AccountKey.from(claudeConfigDir: "/Users/u/.claude/", home: home) == .default)
        #expect(AccountKey.from(claudeConfigDir: "/Users/u/.claude", home: "/Users/u/") == .default)
        #expect(AccountKey.from(claudeConfigDir: "/Users/u/.claude-swap-backup/sessions/2-north-example-com", home: home) == .cswap(2))
        #expect(AccountKey.from(claudeConfigDir: "/Users/u/.claude-swap-backup/sessions/2-north-example-com/", home: home) == .cswap(2))
        let x2 = "/Users/u/.claude-swap-backup/sessions/x-2"
        #expect(AccountKey.from(claudeConfigDir: x2, home: home) == .other("cfg-" + AccountKey.fnv1a64Hex(x2)))
        #expect(AccountKey.from(claudeConfigDir: "/tmp/cfg", home: home) == .other("cfg-" + AccountKey.fnv1a64Hex("/tmp/cfg")))
        let other = "/Users/u/other/sessions/3-a"
        #expect(AccountKey.from(claudeConfigDir: other, home: home) == .other("cfg-" + AccountKey.fnv1a64Hex(other)))
        #expect(AccountKey.from(claudeConfigDir: "/Users/u/.claude-swap-backup/sessions/12345-a", home: home).rawValue.hasPrefix("cfg-"))
        #expect(AccountKey.from(claudeConfigDir: "/Users/v/.claude", home: home).rawValue.hasPrefix("cfg-"))
    }

    /// FNV-1a 64 reference values (the empty string is the offset basis; "a" from the spec's
    /// published test vectors).
    @Test func fnvVectors() {
        #expect(AccountKey.fnv1a64Hex("") == "cbf29ce484222325")
        #expect(AccountKey.fnv1a64Hex("a") == "af63dc4c8601ec8c")
        #expect(AccountKey.fnv1a64Hex("foobar") == "85944171f73967e8")
        let key = AccountKey.from(claudeConfigDir: "/tmp/cfg", home: "/Users/u").rawValue
        #expect(key.count == 20)
        #expect(key.dropFirst(4).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func rawValues() {
        #expect(AccountKey.default.rawValue == "default")
        #expect(AccountKey.cswap(3).rawValue == "cswap-3")
        #expect(AccountKey(rawValue: "default") == .default)
        #expect(AccountKey(rawValue: "cswap-3") == .cswap(3))
        #expect(AccountKey(rawValue: "cswap-1234") == .cswap(1234))
        #expect(AccountKey(rawValue: "cfg-0123456789abcdef") == .other("cfg-0123456789abcdef"))
        for bad in ["", "Default", "cswap-", "cswap-12345", "cswap-x", "cfg-0123", "cfg-0123456789ABCDEF", "cfg-0123456789abcdefa", "invalid"] {
            #expect(AccountKey(rawValue: bad) == nil, "\(bad)")
        }
        let key = AccountKey.from(claudeConfigDir: "/tmp/cfg", home: "/Users/u")
        #expect(AccountKey(rawValue: key.rawValue) == key)
        #expect("\(AccountKey.cswap(2))" == "cswap-2")
    }

    @Test func profileKeysOfNonStandardRoots() {
        let accounts = [
            CswapStateAccount(number: 2, sessionProfile: URL(fileURLWithPath: "/tmp/codd-test/cswap/sessions/2-north-example-com", isDirectory: true)),
            CswapStateAccount(number: 3, sessionProfile: URL(fileURLWithPath: "/Users/u/.claude-swap-backup/sessions/3-t", isDirectory: true)),
            CswapStateAccount(number: 1),
        ]
        let keys = AccountKey.profileKeys(accounts, home: "/Users/u")
        let expected = "cfg-" + AccountKey.fnv1a64Hex("/tmp/codd-test/cswap/sessions/2-north-example-com")
        #expect(keys == [expected: 2]) // #3 is a cswap-3 key already, #1 has no profile
        #expect(AccountKey.from(claudeConfigDir: accounts[0].sessionProfile?.path, home: "/Users/u") == .other(expected))
    }
}

@Suite("cswap background tools (D13)")
struct CswapProcessDetectorTests {
    @Test func classifyTable() {
        let menubar = ["/Users/u/.local/share/uv/tools/claude-swap/bin/python", "/Users/u/.local/bin/cswap", "menubar"]
        let auto = ["python3", "-m", "claude_swap", "auto", "--interval", "60"]
        #expect(CswapProcessDetector.classify(arguments: [menubar]) == CswapBackgroundTools(menubar: true, auto: false))
        #expect(CswapProcessDetector.classify(arguments: [auto]) == CswapBackgroundTools(menubar: false, auto: true))
        #expect(CswapProcessDetector.classify(arguments: [menubar, auto]) == CswapBackgroundTools(menubar: true, auto: true))
        #expect(CswapProcessDetector.classify(arguments: [["cswap", "--debug", "auto"]]).auto)
        #expect(CswapProcessDetector.classify(arguments: [["/bin/sh", "-c", "cswap menubar"]]).menubar)
        #expect(CswapProcessDetector.classify(arguments: [["/opt/x/claude-swap", "menubar"]]).menubar)
        #expect(CswapProcessDetector.classify(arguments: [["python", "/x/site-packages/claude_swap/__main__.py", "auto"]]).auto)
        let none = CswapBackgroundTools()
        for argv in [["cswap", "list", "--json"], ["cswap", "switch", "2", "--json"], ["cswap"], ["menubar"], ["/usr/bin/auto"],
                     ["vim", "cswap-auto.txt"], ["python3", "server.py", "auto"], ["cswap", "run", "2", "--", "auto"]] {
            #expect(CswapProcessDetector.classify(arguments: [argv]) == none, "\(argv)")
        }
        #expect(CswapProcessDetector.classify(arguments: []) == none)
        #expect(CswapProcessDetector.isCandidate("Python") && CswapProcessDetector.isCandidate("cswap"))
        #expect(!CswapProcessDetector.isCandidate("zsh"))
    }

    /// A python process whose argv reads like `cswap menubar` (no cswap involved) is found by the
    /// kernel scan. Skipped when no python3 is installed.
    @Test(.timeLimit(.minutes(1)))
    func scanFindsAProcessOfThisUser() async throws {
        let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/Library/Developer/CommandLineTools/usr/bin/python3"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = ["-I", "-c", "import time; time.sleep(30)", "cswap", "menubar"]
        p.environment = ["PATH": "/usr/bin:/bin"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        defer {
            p.terminate()
            p.waitUntilExit()
        }
        var found = false
        for _ in 0..<40 where !found {
            found = CswapProcessDetector.scan().menubar
            if !found { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(found)
    }
}
