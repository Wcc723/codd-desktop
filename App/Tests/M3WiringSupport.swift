import CoddCore
import CoddHooks
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CODD

/// Shared fixtures of the M3 I1b tests: a fake cswap 0.26 state root in cswap's file formats
/// (the C9 `make-cswap-state.sh` layout and SPEC §5 accounts, e-mails `*@example.com` only), a
/// scripted cswap `CommandRunner`, and temp folders. Nothing here runs the real cswap, a claude or
/// touches `~`.

/// A fresh, short `$TMPDIR` folder (socket paths must fit 104 bytes).
func m3TempFolder(_ prefix: String) throws -> String {
    var template = Array(((ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp") + "/\(prefix).XXXXXX").utf8CString)
    let created = try #require(mkdtemp(&template))
    let path = String(cString: created)
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
}

/// Kills every process naming `root` in its argv, then removes the folder.
func m3RemoveFolder(_ root: String) {
    let pkill = Process()
    pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    pkill.arguments = ["-KILL", "-f", root + "/"]
    try? pkill.run()
    pkill.waitUntilExit()
    try? FileManager.default.removeItem(atPath: root)
}

@MainActor
func m3Eventually(_ what: String, timeout: Duration = .seconds(8), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "timed out waiting for \(what)")
}

/// The leak check of D31: no e-mail of the fixtures (`@example.com`), and no profile slug
/// (`example.com` as cswap writes it, `example-com` as the plan spells it).
func m3ExpectNoAccountLeak(_ text: String, _ what: String) {
    #expect(!text.contains("@example.com"), "\(what) shows an e-mail")
    #expect(!text.contains("example.com"), "\(what) shows a profile slug or e-mail")
    #expect(!text.contains("example-com"), "\(what) shows a profile slug")
}

/// cswap's state root and the global login, written like cswap 0.26 writes them.
struct FakeCswapState {
    struct Account {
        var number: Int
        var email: String
        var organization: String
        var organizationName: String
        var alias: String?
        var tier: String
        /// `(used %, reset offset in s or nil)` of five_hour and seven_day.
        var five: (Double, TimeInterval?)
        var week: (Double, TimeInterval?)
        var fetchedAgo: TimeInterval
    }

    static let d: TimeInterval = 86_400
    static let h: TimeInterval = 3_600
    static let m: TimeInterval = 60

    /// SPEC §5: #1 個人, #2 藍鵲 (MAX 20x), #3 工作 (active); #4 only with `accounts: 4`.
    static let sample: [Account] = [
        Account(number: 1, email: "personal@example.com", organization: "", organizationName: "personal@example.com's Organization",
                alias: "個人", tier: "default_claude_max_20x", five: (0, nil), week: (0, 4 * d + 9 * h), fetchedAgo: 3 * m),
        Account(number: 2, email: "north@example.com", organization: "org-2", organizationName: "Synthetic North Org",
                alias: "藍鵲", tier: "default_claude_max_20x", five: (2, 2 * h + 37 * m), week: (54, 1 * d + 12 * h), fetchedAgo: 3 * m),
        Account(number: 3, email: "work@example.com", organization: "", organizationName: "",
                alias: "工作", tier: "default_claude_max_20x", five: (9, 2 * h + 57 * m), week: (85, 3 * d + 1 * h), fetchedAgo: 10 * m),
        Account(number: 4, email: "new@example.com", organization: "org-4", organizationName: "Synthetic Org 4",
                alias: nil, tier: "default_claude_max_5x", five: (30, 1 * h + 10 * m), week: (20, 5 * d + 2 * h), fetchedAgo: 3 * m),
    ]

    /// `<home>` holds `.claude/`, `.claude.json` and the state root (`rootName`, cswap's own
    /// `.claude-swap-backup` unless a test wants a root CODD's CLI does not recognise).
    let home: URL
    let rootName: String
    let now: Date
    let accounts: [Account]

    var root: URL { home.appendingPathComponent(rootName, isDirectory: true) }
    var claudeDir: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    var claudeJSON: URL { home.appendingPathComponent(".claude.json") }
    var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    init(home: String, rootName: String = ".claude-swap-backup", now: Date, count: Int = 3) {
        self.home = URL(fileURLWithPath: home, isDirectory: true)
        self.rootName = rootName
        self.now = now
        accounts = Array(Self.sample.prefix(count))
    }

    /// `sessions/<n>-<slugify(email)>` (cswap's real slug: `north_example.com`).
    func profile(_ n: Int) -> URL {
        let email = accounts.first { $0.number == n }?.email ?? "x"
        let slug = String(email.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" })
        return root.appendingPathComponent("sessions/\(n)-\(slug)", isDirectory: true)
    }

    /// Writes everything. `profiles`: accounts with a `cswap run` profile; `stale`: those with
    /// cswap's stale marker; `unsupportedSequence`: `accounts` as an array (the reader refuses it).
    func write(active: Int = 3, profiles: [Int] = [2], stale: [Int] = [], unsupportedSequence: Bool = false) throws {
        let fm = FileManager.default
        for dir in [root, root.appendingPathComponent("cache"), root.appendingPathComponent("configs"),
                    root.appendingPathComponent("sessions"), claudeDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var records: [String: Any] = [:]
        for a in accounts {
            var record: [String: Any] = ["email": a.email, "uuid": "00000000-0000-4000-8000-00000000000\(a.number)",
                                         "organizationUuid": a.organization, "organizationName": a.organizationName,
                                         "added": "2026-09-0\(a.number)T00:00:00Z"]
            if let alias = a.alias { record["alias"] = alias }
            records[String(a.number)] = record
        }
        let sequence: [String: Any] = ["activeAccountNumber": active, "lastUpdated": "2026-10-15T02:30:00Z",
                                       "sequence": accounts.map(\.number),
                                       "accounts": unsupportedSequence ? Array(records.values) as Any : records as Any]
        try json(sequence).write(to: root.appendingPathComponent("sequence.json"))
        var usage: [String: Any] = [:]
        for a in accounts {
            func window(_ w: (Double, TimeInterval?)) -> [String: Any] {
                var o: [String: Any] = ["pct": w.0]
                if let offset = w.1 { o["resets_at"] = Self.iso(now.addingTimeInterval(offset)) }
                return o
            }
            var lastGood: [String: Any] = ["five_hour": window(a.five), "seven_day": window(a.week)]
            if a.number == 2 { lastGood["scoped"] = [["name": "Fable", "pct": 0.0]] }
            usage[String(a.number)] = ["email": a.email, "organizationUuid": a.organization, "lastGood": lastGood,
                                       "fetchedAt": now.addingTimeInterval(-a.fetchedAgo).timeIntervalSince1970,
                                       "consecutiveFailures": 0, "lastError": NSNull(), "authDeadStrikes": 0]
        }
        try json(["schemaVersion": 2, "accounts": usage]).write(to: root.appendingPathComponent("cache/usage.json"))
        for a in accounts {
            try json(["oauthAccount": oauth(a), "projects": [:]])
                .write(to: root.appendingPathComponent("configs/.claude-config-\(a.number)-\(a.email).json"))
        }
        for n in profiles {
            try fm.createDirectory(at: profile(n).appendingPathComponent("sessions"), withIntermediateDirectories: true)
            try fm.createDirectory(at: profile(n).appendingPathComponent("projects"), withIntermediateDirectories: true)
        }
        for n in stale {
            let marker = root.appendingPathComponent("sessions/.\(profile(n).lastPathComponent).cswap-stale-credentials")
            try Data().write(to: marker)
        }
        try setLogin(active)
    }

    /// The global login (what `cswap switch` changes): `.claude.json` `oauthAccount` and
    /// `sequence.json` `activeAccountNumber`.
    func setLogin(_ n: Int) throws {
        guard let a = accounts.first(where: { $0.number == n }) else { return }
        try json(["numStartups": 3, "oauthAccount": oauth(a), "projects": [:]]).write(to: claudeJSON)
        let url = root.appendingPathComponent("sequence.json")
        if var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] {
            object["activeAccountNumber"] = n
            try json(object).write(to: url)
        }
    }

    /// A `claude /login` into an account cswap does not manage yet (dialog C step 1).
    func setLoginIdentity(email: String, organization: String, tier: String = "default_claude_max_5x") throws {
        let oauth: [String: Any] = ["accountUuid": "00000000-0000-4000-8000-000000000099", "emailAddress": email,
                                    "organizationUuid": organization, "organizationName": "Synthetic New Org",
                                    "organizationRateLimitTier": tier, "organizationType": "claude_max"]
        try json(["numStartups": 3, "oauthAccount": oauth, "projects": [:]]).write(to: claudeJSON)
    }

    /// `cswap add --slot n --alias a`: the identity in `.claude.json` becomes account n (cswap's
    /// record, config backup and active number).
    func addCurrentLogin(slot: Int, alias: String?) throws {
        let current = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeJSON)) as? [String: Any]
        guard let oauth = current?["oauthAccount"] as? [String: Any], let email = oauth["emailAddress"] as? String else { return }
        let url = root.appendingPathComponent("sequence.json")
        guard var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any],
              var records = object["accounts"] as? [String: Any], var sequence = object["sequence"] as? [Int] else { return }
        var record: [String: Any] = ["email": email, "uuid": "00000000-0000-4000-8000-000000000099",
                                     "organizationUuid": oauth["organizationUuid"] ?? "", "organizationName": oauth["organizationName"] ?? "",
                                     "added": "2026-10-15T02:40:00Z"]
        if let alias { record["alias"] = alias }
        records[String(slot)] = record
        if !sequence.contains(slot) { sequence.append(slot) }
        object["accounts"] = records
        object["sequence"] = sequence.sorted()
        object["activeAccountNumber"] = slot
        try json(object).write(to: url)
        try json(["oauthAccount": oauth, "projects": [:]])
            .write(to: root.appendingPathComponent("configs/.claude-config-\(slot)-\(email).json"))
    }

    private func oauth(_ a: Account) -> [String: Any] {
        ["accountUuid": "00000000-0000-4000-8000-00000000000\(a.number)", "emailAddress": a.email, "organizationUuid": a.organization,
         "organizationName": a.organizationName, "organizationRateLimitTier": a.tier, "organizationType": "claude_max"]
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func iso(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'+00:00'"
        return formatter.string(from: date)
    }

    /// The weekly reset of account n as written (whole seconds).
    func weeklyReset(_ n: Int) -> Date? {
        accounts.first { $0.number == n }?.week.1.map { Date(timeIntervalSince1970: (now.timeIntervalSince1970 + $0).rounded(.down)) }
    }
}

/// A scripted cswap: `--version`, `switch <n> --json` (emulating the login change on the fake
/// state), `list --json`; every call recorded. Lock timeouts and failures carry the e-mails, like
/// cswap's own messages, so the redaction is exercised.
final class FakeCswapRunner: CommandRunner, Sendable {
    struct Script: Sendable {
        var version = "cswap 0.26.0"
        /// The first n switches fail with `ClaudeCodeLockTimeout`.
        var lockFailures = 0
        var failSwitch = false
        /// Per switch run, before answering (progress can be watched meanwhile).
        var switchDelay: Duration = .zero
        var listJSON: String?
    }

    private let state = Mutex<(script: Script, calls: [[String]])>((Script(), []))
    /// Runs on a switch that succeeds (the test changes the fake login).
    let onSwitch: @Sendable (Int) -> Void
    /// Runs on `add --slot n --alias a` (the test adds the current login to the fake state).
    let onAdd: @Sendable (Int, String?) -> Void

    init(script: Script = Script(), onSwitch: @escaping @Sendable (Int) -> Void = { _ in },
         onAdd: @escaping @Sendable (Int, String?) -> Void = { _, _ in }) {
        state.withLock { $0.script = script }
        self.onSwitch = onSwitch
        self.onAdd = onAdd
    }

    var calls: [[String]] { state.withLock { $0.calls } }

    func setScript(_ edit: (inout Script) -> Void) { state.withLock { edit(&$0.script) } }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        let script = state.withLock { s -> Script in
            s.calls.append(invocation.arguments)
            return s.script
        }
        let args = invocation.arguments
        switch args.first {
        case "--version":
            return CommandResult(status: 0, stdout: Data((script.version + "\n").utf8))
        case "switch":
            if script.switchDelay > .zero { try await Task.sleep(for: script.switchDelay) }
            let number = Int(args.dropFirst().first ?? "") ?? 0
            let failLock = state.withLock { s -> Bool in
                guard s.script.lockFailures > 0 else { return false }
                s.script.lockFailures -= 1
                return true
            }
            if failLock {
                return Self.envelope("ClaudeCodeLockTimeout",
                                     "Could not acquire .claude.lock while switching work@example.com to Account-\(number) (north@example.com)")
            }
            if script.failSwitch {
                return Self.envelope("SwitchError", "Switch from work@example.com to north@example.com failed: keychain busy")
            }
            onSwitch(number)
            let body = #"{"schemaVersion":1,"switched":true,"from":{"number":3,"email":"work@example.com"},"to":{"number":\#(number),"email":"north@example.com"},"strategy":"direct","reason":"switched","message":"Switched to Account-\#(number) (north@example.com)","warnings":["pid 4242 still runs as work@example.com"]}"#
            return CommandResult(status: 0, stdout: Data(body.utf8))
        case "list":
            return CommandResult(status: 0, stdout: Data((script.listJSON ?? #"{"schemaVersion":1,"accounts":[]}"#).utf8))
        case "alias":
            // `alias N <name>` / `alias N --unset` (Settings › 帳號, M3 I3): cswap prints nothing useful.
            return CommandResult(status: 0, stdout: Data())
        case "add":
            let slot = args.firstIndex(of: "--slot").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 0
            let alias = args.firstIndex(of: "--alias").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
            onAdd(slot, alias)
            // cswap prints the e-mail; CODD discards add's stdout (D31).
            return CommandResult(status: 0, stdout: Data("Added Account \(slot): new@example.com [personal]\n".utf8))
        default:
            return CommandResult(status: 2, stdout: Data(), stderr: Data("unsupported".utf8))
        }
    }

    static func envelope(_ type: String, _ message: String) -> CommandResult {
        let body = #"{"schemaVersion":1,"error":{"type":"\#(type)","message":"\#(message)"}}"#
        return CommandResult(status: 1, stdout: Data(body.utf8))
    }
}

/// A `CswapAccountStore` on a fake state with a scripted runner, its log lines and a clock the
/// test moves.
@MainActor
final class AccountStoreFixture {
    let folder: String
    let state: FakeCswapState
    let runner: FakeCswapRunner
    let logs = Recorder<String>()
    var clock: Date
    private(set) var store: CswapAccountStore!

    /// `standardRoot: false` without `debug`: a test data root without DEBUG flags (D3: no cswap).
    init(_ prefix: String = "codd-i1b", rootName: String = ".claude-swap-backup", count: Int = 3, active: Int = 3,
         profiles: [Int] = [2], stale: [Int] = [], unsupported: Bool = false, debug: Bool = true, quota: Bool = false,
         script: FakeCswapRunner.Script = FakeCswapRunner.Script(),
         configure: (inout CswapAccountStore.Configuration) -> Void = { _ in }) throws {
        folder = try m3TempFolder(prefix)
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970).rounded(.down))
        clock = now
        let state = FakeCswapState(home: folder + "/home", rootName: rootName, now: now, count: count)
        self.state = state
        try state.write(active: active, profiles: profiles, stale: stale, unsupportedSequence: unsupported)
        runner = FakeCswapRunner(script: script, onSwitch: { number in try? state.setLogin(number) },
                                 onAdd: { slot, alias in try? state.addCurrentLogin(slot: slot, alias: alias) })
        var configuration = CswapAccountStore.Configuration(
            isStandardRoot: false, debugCswapPath: debug ? folder + "/bin/cswap" : nil, debugCswapRoot: debug ? state.root.path : nil,
            claudeDirectory: state.claudeDir, claudeSettingsURL: state.settingsURL,
            quotaURL: quota ? URL(fileURLWithPath: folder + "/data/quota.json") : nil)
        configuration.home = folder + "/home"
        configuration.parentEnvironment = ["PATH": "/usr/bin:/bin", "HOME": folder + "/home"]
        configuration.isExecutable = { _ in true }
        configuration.watchFiles = false
        configuration.pollInterval = .seconds(3600)
        configuration.saveDelay = .milliseconds(20)
        configure(&configuration)
        let logs = self.logs
        store = CswapAccountStore(configuration: configuration, runner: runner, now: { [unowned self] in self.clock },
                                  log: { logs.append($0) })
        if quota { try FileManager.default.createDirectory(atPath: folder + "/data", withIntermediateDirectories: true) }
    }

    deinit {
        m3RemoveFolder(folder)
    }

    /// A status-line report as `HookServer` decodes it.
    func report(key: String, five: Double? = nil, fiveReset: Date? = nil, week: Double? = nil, weekReset: Date? = nil) -> StatusLineReport {
        StatusLineReport(sessionID: nil, claudeSessionId: "c-1", configKey: key,
                         fiveHour: five.map { StatusLineWindow(usedPercent: $0, resetsAt: fiveReset) },
                         sevenDay: week.map { StatusLineWindow(usedPercent: $0, resetsAt: weekReset) },
                         hadRateLimits: five != nil || week != nil, receivedAt: clock)
    }

    /// Everything the store logged and dumped, for the D31 leak check.
    var exposedText: String {
        let dump = store.dumpObject
        let objects: [Any] = [dump.accounts, dump.quota, dump.statusline,
                              store.newSessionAccountOptions.map { ["id": $0.id, "title": $0.title, "hint": $0.hint ?? ""] }]
        let json = objects.compactMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) }
        return (logs.values + json).joined(separator: "\n")
    }
}
