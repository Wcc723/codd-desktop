import CoddCore
import CoddHooks
import CoddPreferences
import CoddUI
import Foundation
import Observation

/// Where cswap and its state root are for this run (D3).
struct CswapLocation: Equatable, Sendable {
    var executable: String?
    var root: URL?

    /// D3. The standard data root uses Settings › 帳號 › cswap 路徑, else `cswap` on the captured
    /// login-shell PATH, else `~/.local/bin/cswap`, and `~/.claude-swap-backup`. Any other data root
    /// gets neither unless DEBUG `-codd-cswap-path` / `-codd-cswap-root` name them, so test and
    /// throwaway instances never read the user's accounts or run the real cswap. The DEBUG flags
    /// win on the standard root too, and only as a pair: a DEBUG state root with the user's real
    /// cswap (or a DEBUG cswap with the real state) would switch the real login using account
    /// numbers read from the other side, so either flag alone gives no cswap (D3, M3 review).
    static func resolve(standardRoot: Bool, debugPath: String?, debugRoot: String?, preferredPath: String?,
                        loginPATH: String?, home: String, isExecutable: (String) -> Bool) -> CswapLocation {
        if (debugPath == nil) != (debugRoot == nil) { return CswapLocation(executable: nil, root: nil) }
        let root = debugRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (standardRoot ? CswapStateReader.standardRoot(home: home) : nil)
        if let debugPath { return CswapLocation(executable: isExecutable(debugPath) ? debugPath : nil, root: root) }
        guard standardRoot else { return CswapLocation(executable: nil, root: root) }
        if let preferred = preferredPath.map({ PathFormat.expandTilde($0) }), !preferred.isEmpty {
            // An explicit path that does not work is not silently replaced by another cswap.
            return CswapLocation(executable: preferred.hasPrefix("/") && isExecutable(preferred) ? preferred : nil, root: root)
        }
        for dir in (loginPATH ?? "").split(separator: ":") where dir.hasPrefix("/") {
            let candidate = dir.hasSuffix("/") ? "\(dir)cswap" : "\(dir)/cswap"
            if isExecutable(candidate) { return CswapLocation(executable: candidate, root: root) }
        }
        let fallback = home + "/.local/bin/cswap"
        return CswapLocation(executable: isExecutable(fallback) ? fallback : nil, root: root)
    }
}

/// D38: every cswap run logs `exec cswap path=<abbreviated> sub=<subcommand>` and nothing else of
/// its argv (aliases and account numbers stay out of the log too).
struct LoggingCommandRunner: CommandRunner {
    let base: any CommandRunner
    let tool: String
    let log: @Sendable (String) -> Void

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        log("exec \(tool) path=\(HolderSessionStore.abbreviate(invocation.executable)) sub=\(invocation.arguments.first ?? "-")")
        return try await base.run(invocation)
    }
}

/// The status-line reports the account store saw (STATUS, the `statusline` dump key).
struct StatusLineStats: Equatable, Sendable {
    var accepted = 0
    /// Reports with numbers that could not be given to an account (D6).
    var dropped = 0
    var lastKey: String?
    var lastAt: Date?
    /// The account the last attributed report went to (`3`, `default`).
    var lastAccount: String?
}

/// D12: whether account n can be pinned right now (the profile path never leaves the store
/// except into a launch's `CLAUDE_CONFIG_DIR`).
enum AccountPinResolution: Equatable, Sendable {
    case usable(path: String)
    /// The global login: cswap keeps no profile for it.
    case active
    /// No `cswap run` profile, or cswap marked it stale (`cswap run <n>` re-seeds it).
    case needsProfile
    case unknownAccount
    /// The accounts are still being read (or cswap is not available).
    case notReady
}

/// The real `AccountStore` (M3 I1b): accounts from cswap's own state files (read only, D2), quota
/// from status-line reports and cswap's cache (D1, D7) merged in `<dataRoot>/quota.json`,
/// switches through `cswap switch` (D5).
///
/// - Reads run off the main actor at start, on FSEvents of the state root and on a 15 s poll that
///   skips unchanged fingerprints (a full read every 5 min catches profile changes the fingerprint
///   does not see). `cswap list --json` (which makes cswap fetch usage) runs only from
///   `refresh(userInitiated: true)` while the files are unusable, at most once per 10 min (D1).
/// - E-mails never reach this type: the reader keeps them inside its call (D2); aliases are
///   redacted for display; cswap's messages are redacted by `CswapClient` and again here (D31).
///   The session profile paths (an e-mail slug) are kept only for pinning and never logged,
///   dumped or shown.
@MainActor @Observable
final class CswapAccountStore: AccountStore {
    // MARK: Observed state

    private(set) var accounts: [AccountVM] = []
    private(set) var activeAccountID: AccountID?
    private(set) var switchState: AccountSwitchState = .idle
    private(set) var cswapVersion: CswapVersion?
    /// cswap's own state as found (before the D4 pseudo account is considered).
    private(set) var baseAvailability: AccountAvailability = .loading
    private(set) var statusLine = StatusLineStats()
    /// 繁體中文 lines from the reader (no e-mails, no paths).
    private(set) var warnings: [String] = []
    /// The last full state read off the main actor, in ms (the dump's `readMs`; measurements).
    @ObservationIgnored private(set) var lastReadMilliseconds: Double?
    /// The last switch, for the dump (`lastSwitch{from,to,reason,at,outcome}`).
    private(set) var lastSwitch: (from: Int?, to: Int, reason: AccountSwitchReason, at: Date, outcome: String)?
    /// The list shown comes from the D1 `cswap list` fallback, not the state files.
    private(set) var usingListFallback = false
    /// Settings › 帳號 › 自動切換 (from the preferences).
    private(set) var autoSwitch = AutoSwitchConfig()
    /// `<profile>/sessions` of every known account with a cswap session profile: the registry of
    /// pinned sessions (D12), watched next to `<claudeDir>/sessions`. Never logged or dumped.
    private(set) var profileRegistryDirectories: [URL] = []

    var isPlaceholder: Bool { false }
    var sourceLabel: String? { cswapVersion.map { "cswap \($0)" } }

    var availability: AccountAvailability {
        if baseAvailability.isReady || baseAvailability == .loading { return baseAvailability }
        guard hasDefaultLoginEntry else { return baseAvailability }
        // The pseudo row already shows numbers: no "usage appears once claude reports" any more.
        return .pseudo(note: baseAvailability == .noCswap ? AccountAvailability.pseudoNote
                       : baseAvailability.note ?? AccountAvailability.pseudoNote)
    }

    /// The book knows the global login's numbers (D4). Observed apart from the book, so a view
    /// reading `availability` does not redraw on every status-line report.
    private(set) var hasDefaultLoginEntry = false

    // MARK: Inputs

    struct Configuration {
        var isStandardRoot: Bool
        var debugCswapPath: String?
        var debugCswapRoot: String?
        /// `<claudeDir>`: `.claude.json` candidates (D3) and the registry of the global login.
        var claudeDirectory: URL
        /// The Claude settings file a profile's `settings.json` symlink should resolve to.
        var claudeSettingsURL: URL?
        /// `<dataRoot>/quota.json`; nil keeps the book in memory (tests).
        var quotaURL: URL?
        var home = NSHomeDirectory()
        /// cswap's parent environment before scrubbing; nil = the login environment, else the
        /// app's own (`CswapEnvironment.make` strips the Claude / CODD names either way).
        var parentEnvironment: [String: String]?
        var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
        /// Poll and save timings (tests shorten them).
        var pollInterval: Duration = .seconds(15)
        var fullReadEvery = 20
        var saveDelay: Duration = .seconds(2)
        /// The longest a change waits while reports keep restarting the 2 s debounce.
        var maxSaveDelay: Duration = .seconds(15)
        /// A suspected login change (D6) re-reads the state at most this often.
        var suspectedReadInterval: TimeInterval = 15
        var fallbackInterval: TimeInterval = 600
        var watchFiles = true
    }

    @ObservationIgnored let configuration: Configuration
    @ObservationIgnored private let runner: any CommandRunner
    @ObservationIgnored private let log: @MainActor (String) -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    /// Settings › 帳號 › cswap 路徑 (standard data root only).
    @ObservationIgnored private var preferredPath: String?
    /// Live sessions following the global login and pinned per account (D12), from the session store.
    @ObservationIgnored var sessionCounts: (@MainActor () -> (following: Int, pinned: [Int: Int]))?

    // MARK: Internal state

    @ObservationIgnored private(set) var location = CswapLocation()
    @ObservationIgnored private var client: CswapClient?
    @ObservationIgnored private var reader: CswapStateReader?
    @ObservationIgnored private(set) var snapshot: CswapStateSnapshot?
    @ObservationIgnored private var fingerprint: [String: String]?
    /// The quota cache (D7). Not observed: views read the `AccountVM`s it fills.
    @ObservationIgnored private(set) var book = QuotaBook() {
        didSet {
            let has = book.entry(.defaultLogin) != nil
            if hasDefaultLoginEntry != has { hasDefaultLoginEntry = has }
        }
    }
    @ObservationIgnored private var switchMark: SwitchMark?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var readChain: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: FileEventWatcher?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savePending = false
    /// When the oldest unsaved change was made (the debounce's maximum wait counts from it).
    @ObservationIgnored private var pendingSince: ContinuousClock.Instant?
    /// Reports received before the first read, newest per key, attributed once the state is known.
    @ObservationIgnored private var pendingReports: [String: StatusLineReport] = [:]
    @ObservationIgnored private var lastSuspectedRead: Date?
    @ObservationIgnored private var loginChangeLog: [String: Date] = [:]
    @ObservationIgnored private var lastFallbackAt: Date?
    @ObservationIgnored private var seenKeys = Set<String>()
    @ObservationIgnored private var dropLog: [String: (at: Date, skipped: Int)] = [:]
    @ObservationIgnored private var countsLoop: ObservationLoop?
    @ObservationIgnored private let saveQueue = DispatchQueue(label: CoddIdentity.label("quota"), qos: .utility)

    init(configuration: Configuration, runner: any CommandRunner = ProcessCommandRunner(),
         now: @escaping @MainActor () -> Date = { Date() },
         log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.configuration = configuration
        self.runner = runner
        self.now = now
        self.log = log
    }

    // MARK: Start

    /// Loads quota.json, finds cswap (D3), checks its version, reads its state and starts
    /// watching. Later calls wait for the first.
    func start() async {
        if let startTask { return await startTask.value }
        let task = Task { [weak self] () -> Void in await self?.performStart() }
        startTask = task
        await task.value
    }

    private func performStart() async {
        started = true
        if let url = configuration.quotaURL {
            let store = QuotaStore(url: url)
            let loaded = await Task.detached(priority: .utility) { store.load() }.value
            book = loaded
        }
        countsLoop = ObservationLoop(track: { [weak self] () -> [String: Int] in
            guard let self, let counts = self.sessionCounts?() else { return [:] }
            var out = Dictionary(uniqueKeysWithValues: counts.pinned.map { (String($0.key), $0.value) })
            out[NewSessionAccountOption.followID] = counts.following
            return out
        }, apply: { [weak self] _ in self?.applySessionCounts() })
        await locateAndRead()
        replayPendingReports()
        startWatching()
    }

    /// D3 resolution, `--version` (≥ 0.26), the first read.
    private func locateAndRead() async {
        let config = configuration
        var loginPATH: String?
        var parent = config.parentEnvironment
        if parent == nil {
            let login = await LoginEnvironment.current()
            parent = login ?? ProcessInfo.processInfo.environment
            loginPATH = login?["PATH"]
        } else {
            loginPATH = parent?["PATH"]
        }
        let preferred = config.isStandardRoot ? preferredPath : nil
        let isExecutable = config.isExecutable
        location = CswapLocation.resolve(standardRoot: config.isStandardRoot, debugPath: config.debugCswapPath,
                                         debugRoot: config.debugCswapRoot, preferredPath: preferred, loginPATH: loginPATH,
                                         home: config.home, isExecutable: isExecutable)
        guard let executable = location.executable, let root = location.root else {
            client = nil
            reader = nil
            setBase(.noCswap)
            if (config.debugCswapPath == nil) != (config.debugCswapRoot == nil) {
                log("accounts debug cswap flags refused: -codd-cswap-path and -codd-cswap-root go together")
            }
            log("accounts availability=noCswap standardRoot=\(config.isStandardRoot)")
            reassemble()
            return
        }
        let log = self.log
        let logging = LoggingCommandRunner(base: runner, tool: "cswap") { line in Task { @MainActor in log(line) } }
        let client = CswapClient(runner: logging, configuration: .init(executable: executable, parentEnvironment: parent ?? [:]))
        self.client = client
        do {
            let version = try await client.version()
            cswapVersion = version
            guard version.isSupported else {
                reader = nil
                setBase(.unsupported(version: version.description))
                self.log("accounts availability=unsupported version=\(version)")
                reassemble()
                return
            }
        } catch {
            cswapVersion = nil
            reader = nil
            if case CswapError.runner(.launchFailed) = error {
                setBase(.noCswap)
                self.log("accounts availability=noCswap (cswap did not start)")
            } else {
                setBase(.unsupported(version: "未知"))
                self.log("accounts availability=unsupported version=unknown (\(Self.kind(of: error)))")
            }
            reassemble()
            return
        }
        reader = CswapStateReader(root: root, claudeJSONCandidates: CswapStateReader.claudeJSONCandidates(claudeDir: config.claudeDirectory),
                                  claudeSettingsURL: config.claudeSettingsURL)
        fingerprint = nil
        await read(force: true)
    }

    private func startWatching() {
        if configuration.watchFiles, let root = location.root, reader != nil {
            let watcher = FileEventWatcher(path: root.path) { [weak self] in
                guard let self else { return }
                Task { await self.read(force: false) }
            }
            watcher.start()
            self.watcher = watcher
        }
        let interval = configuration.pollInterval
        let fullEvery = max(1, configuration.fullReadEvery)
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                tick += 1
                await self.read(force: tick % fullEvery == 0)
                // Passed resets roll over (QuotaWindow.status(at:)) even without a new number.
                self.reassemble()
            }
        }
    }

    /// App quit: writes a pending quota.json now.
    func shutdown() {
        pollTask?.cancel()
        pollTask = nil
        watcher?.stop()
        watcher = nil
        flush()
    }

    // MARK: Preferences

    /// Settings › 帳號 (auto-switch rule, cswap path). A changed cswap path is looked up again.
    func apply(preferences: CoddPreferences) {
        let rule = preferences.accounts.autoSwitch
        let next = AutoSwitchConfig(enabled: rule.enabled, thresholdPercent: rule.thresholdPercent, checkFiveHour: rule.checkFiveHour,
                                    checkWeek: rule.checkWeekly, cooldownSeconds: rule.cooldownSeconds)
        if next != autoSwitch { autoSwitch = next }
        let path = preferences.accounts.cswapPath
        guard path != preferredPath else { return }
        preferredPath = path
        guard started, configuration.isStandardRoot, configuration.debugCswapPath == nil else { return }
        Task { [weak self] in
            await self?.locateAndRead()
            self?.restartWatching()
        }
    }

    private func restartWatching() {
        pollTask?.cancel()
        watcher?.stop()
        watcher = nil
        startWatching()
    }

    // MARK: Reading

    /// One read off the main actor (serialized). Without `force` an unchanged fingerprint skips it.
    func read(force: Bool) async {
        let previous = readChain
        let task = Task { [weak self] () -> Void in
            await previous?.value
            await self?.performRead(force: force)
        }
        readChain = task
        await task.value
    }

    private func performRead(force: Bool) async {
        guard let reader else { return }
        let known = force ? nil : fingerprint
        let at = now()
        let result = await Task.detached(priority: .utility) { () -> (fingerprint: [String: String], read: Result<CswapStateSnapshot, CswapStateError>?, ms: Double?) in
            let stamp = reader.fingerprint()
            if let known, known == stamp { return (stamp, nil, nil) }
            let start = ContinuousClock.now
            do throws(CswapStateError) {
                let snapshot = try reader.read(now: at)
                let elapsed = (ContinuousClock.now - start).components
                return (stamp, .success(snapshot), Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            } catch {
                return (stamp, .failure(error), nil)
            }
        }.value
        fingerprint = result.fingerprint
        if let ms = result.ms { lastReadMilliseconds = ms }
        switch result.read {
        case nil:
            return
        case .success(let snapshot)?:
            apply(snapshot, fallback: false)
        case .failure(.missing)?:
            // cswap creates its state on the first `cswap add`: no state yet is "no accounts yet",
            // which dialog C can fix, not an unreadable state pointing at the `cswap list` fallback.
            guard let root = location.root else { return }
            apply(CswapStateSnapshot(root: root, accounts: [], activeAccountNumber: nil, activeSource: .none, readAt: at),
                  fallback: false)
        case .failure(let error)?:
            if usingListFallback, snapshot != nil {
                // The D1 list stays until the files are usable again.
                log("accounts read failed (\(Self.stateErrorKind(error))): keeping the cswap list result")
                return
            }
            snapshot = nil
            setBase(.unreadable(reason: error.reason))
            warnings = []
            log("accounts availability=unreadable (\(Self.stateErrorKind(error)))")
            reassemble()
        }
    }

    /// A new snapshot: switch detection (D6), cswap's cache into the book (D7), the view models.
    private func apply(_ next: CswapStateSnapshot, fallback: Bool) {
        let previousActive = snapshot?.activeAccountNumber
        let previousCount = snapshot?.accounts.count
        snapshot = next
        usingListFallback = fallback
        warnings = next.warnings.map(EmailRedaction.redact)
        let registries = next.accounts.compactMap { $0.sessionProfile?.appendingPathComponent("sessions", isDirectory: true) }
        if registries.map(\.path) != profileRegistryDirectories.map(\.path) { profileRegistryDirectories = registries }
        if let before = previousActive, let after = next.activeAccountNumber, before != after,
           !(switchMark.map { $0.to == after && now().timeIntervalSince($0.at) < QuotaAttribution.switchGrace } ?? false) {
            // A switch outside CODD (cswap in a terminal, cswap auto): the same grace as ours.
            switchMark = SwitchMark(at: now(), from: before, to: after)
            log("accounts active changed #\(before) -> #\(after) (detected)")
        }
        // Book entries follow their login: `cswap swap` / `move` / `remove` keep slot numbers but
        // hand them to other logins (a number alone named the wrong account, M3 review).
        var changed = book.reconcile(slots: Self.slots(next))
        for account in next.accounts {
            if let observation = QuotaObservation.fromCswap(account), book.ingest(observation) { changed = true }
        }
        if changed { scheduleSave() }
        setBase(.ready)
        if previousActive != next.activeAccountNumber || previousCount != next.accounts.count {
            log("accounts read accounts=\(next.accounts.count) active=\(next.activeAccountNumber.map { "#\($0)" } ?? "-") "
                + "source=\(next.activeSource) warnings=\(next.warnings.count)\(fallback ? " via=list" : "")")
        }
        reassemble()
    }

    private func setBase(_ value: AccountAvailability) {
        if baseAvailability != value { baseAvailability = value }
    }

    /// Every slot of `state` with the login it holds (nil when unknown, e.g. the D1 list).
    static func slots(_ state: CswapStateSnapshot) -> [Int: String?] {
        var out: [Int: String?] = [:]
        for account in state.accounts { out[account.number] = .some(account.identity) }
        return out
    }

    /// Re-reads now; `userInitiated` may run the D1 `cswap list --json` fallback while the state
    /// files are unusable (at most once per 10 min, never at launch or on a timer).
    func refresh(userInitiated: Bool) async {
        await start()
        if userInitiated, reader == nil {
            // cswap may have been installed (or updated) since: look for it again.
            await locateAndRead()
            restartWatching()
        } else if reader != nil {
            await read(force: true)
        }
        guard userInitiated, case .unreadable = baseAvailability, let client, let root = location.root,
              cswapVersion?.isSupported == true else { return }
        let at = now()
        if let last = lastFallbackAt, at.timeIntervalSince(last) < configuration.fallbackInterval {
            log("cswap list fallback skipped (once per 10 min)")
            return
        }
        lastFallbackAt = at
        log("cswap list fallback")
        do {
            let list = try await client.list()
            // organizationName and the warning arrays are dropped here: they carry e-mails (D31).
            let active = list.activeAccount?.number
            let rows = list.accounts.map { row in
                CswapStateAccount(number: row.number, alias: row.alias, isActive: row.number == active, isDisabled: row.disabled,
                                  usage: row.effectiveUsage, usageFetchedAt: row.effectiveUsageFetchedAt,
                                  usageHealth: Self.health(row.usageStatus, fetchedAt: row.effectiveUsageFetchedAt, now: at))
            }
            apply(CswapStateSnapshot(root: root, accounts: rows, activeAccountNumber: active, activeSource: .sequenceFile, readAt: at),
                  fallback: true)
        } catch {
            log("cswap list fallback failed (\(Self.kind(of: error)))")
        }
    }

    // MARK: View models

    /// State + book → `AccountVM`s in R7 order (instances kept per id, so rows update in place),
    /// or the D4 pseudo account.
    private func reassemble() {
        let at = now()
        var next: [AccountVM] = []
        if let snapshot, baseAvailability.isReady, !snapshot.accounts.isEmpty {
            let merged = CoddCore.AccountOrdering.sorted(AccountAssembler.accounts(state: snapshot, book: book, now: at), now: at)
            for account in merged {
                let vm = viewModel(id: String(account.number))
                fill(vm, from: account, at: at)
                next.append(vm)
            }
        } else if let entry = book.entry(.defaultLogin) {
            let vm = viewModel(id: Self.pseudoID)
            fillPseudo(vm, entry: entry, at: at)
            next.append(vm)
        }
        let active = snapshot.flatMap { baseAvailability.isReady && !$0.accounts.isEmpty ? $0.activeAccountNumber.map(String.init) : nil }
            ?? (next.first?.isPseudo == true ? Self.pseudoID : nil)
        if activeAccountID != active { activeAccountID = active }
        if next.map(\.id) != accounts.map(\.id) || zip(next, accounts).contains(where: { $0 !== $1 }) { accounts = next }
        applySessionCounts()
    }

    static let pseudoID: AccountID = "default"

    private func viewModel(id: AccountID) -> AccountVM {
        if let existing = accounts.first(where: { $0.id == id }) { return existing }
        return AccountVM(id: id, slot: "", alias: "", plan: nil, fiveHour: .unknown, week: .unknown, source: "", sourceAt: nil,
                         sessionCount: 0)
    }

    private func fill(_ vm: AccountVM, from account: Account, at: Date) {
        set(vm, \.slot, "#\(account.number)")
        set(vm, \.alias, account.alias.map(EmailRedaction.redact) ?? "")
        set(vm, \.plan, account.plan)
        set(vm, \.fiveHour, Self.window(account.fiveHour, at: at))
        set(vm, \.week, Self.window(account.weekly, at: at))
        set(vm, \.scoped, account.scoped.map { scoped in
            let status = scoped.window.status(at: at)
            return ScopedQuota(name: scoped.name, remainingPercent: Self.percent(status.remainingPercent), resetsAt: status.upcomingReset)
        })
        set(vm, \.source, Self.sourceLabel(account.source))
        set(vm, \.sourceAt, account.sourceAt)
        let pace = book.pace(for: .number(account.number), now: at)
        set(vm, \.weekExhaustsAt, pace?.aheadOfPace == true ? pace?.projectedExhaustionAt.map(Self.minute) : nil)
        set(vm, \.health, Self.health(account.usageHealth, source: account.source, sourceAt: account.sourceAt, now: at))
        set(vm, \.isDisabled, account.isDisabled)
        set(vm, \.hasSessionProfile, account.sessionProfile != nil)
        set(vm, \.profileStale, account.sessionProfileStale)
        set(vm, \.isPseudo, false)
    }

    /// D4: `#— 目前登入` from the global login's status-line numbers.
    private func fillPseudo(_ vm: AccountVM, entry: QuotaEntry, at: Date) {
        set(vm, \.slot, "—")
        set(vm, \.alias, "目前登入")
        set(vm, \.plan, nil)
        set(vm, \.fiveHour, Self.window(entry.fiveHour?.window, at: at))
        set(vm, \.week, Self.window(entry.weekly?.window, at: at))
        set(vm, \.scoped, [])
        let newest = entry.newest
        set(vm, \.source, Self.sourceLabel(newest?.source))
        set(vm, \.sourceAt, newest?.at)
        let pace = book.pace(for: .defaultLogin, now: at)
        set(vm, \.weekExhaustsAt, pace?.aheadOfPace == true ? pace?.projectedExhaustionAt.map(Self.minute) : nil)
        set(vm, \.health, .ok)
        set(vm, \.isPseudo, true)
    }

    /// The projected exhaustion to the minute it is shown at (`預估 10/17 18:00 用完`): computed
    /// from the capture time, it moved with every report and rebuilt every view showing it.
    static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// Writes only what changed (a row that reads one property is not invalidated by another).
    private func set<T: Equatable>(_ vm: AccountVM, _ keyPath: ReferenceWritableKeyPath<AccountVM, T>, _ value: T) {
        if vm[keyPath: keyPath] != value { vm[keyPath: keyPath] = value }
    }

    private func applySessionCounts() {
        let counts = sessionCounts?() ?? (following: 0, pinned: [:])
        for vm in accounts {
            let count = vm.id == activeAccountID ? counts.following : (vm.number.flatMap { counts.pinned[$0] } ?? 0)
            if vm.sessionCount != count { vm.sessionCount = count }
        }
    }

    /// CoddCore's used-percent window → the app's remaining-percent window, evaluated at `at`.
    static func window(_ window: CoddCore.QuotaWindow?, at: Date) -> QuotaWindow {
        guard let window else { return .unknown }
        let status = window.status(at: at)
        return QuotaWindow(remainingPercent: percent(status.remainingPercent), resetsAt: status.upcomingReset, started: !status.notStarted)
    }

    static func percent(_ value: Double) -> Int { Int(max(0, min(100, value)).rounded()) }

    static func sourceLabel(_ source: QuotaSource?) -> String {
        switch source {
        case .statusline?: "statusline"
        case .cswap?: "cswap cache"
        case nil: ""
        }
    }

    static func health(_ health: CswapUsageHealth) -> AccountHealth {
        switch health {
        case .none, .fresh: .ok
        case .stale: .stale
        case .failing(let message): .failing(EmailRedaction.redact(message))
        case .reloginRequired: .reloginRequired
        }
    }

    /// The card's health follows the numbers it shows (M3 review: a live status-line account read
    /// `◌ 舊資料 · statusline · 0s 前`): cswap's cache age matters only while the newest numbers are
    /// cswap's; status-line numbers are fresh for ``CswapUsageHealth/freshness`` after their capture.
    /// cswap's failing / re-login states stay whatever the source.
    static func health(_ health: CswapUsageHealth, source: QuotaSource?, sourceAt: Date?, now: Date) -> AccountHealth {
        switch health {
        case .failing, .reloginRequired:
            return Self.health(health)
        case .none, .fresh, .stale:
            guard source == .statusline, let sourceAt else { return Self.health(health) }
            return now.timeIntervalSince(sourceAt) <= CswapUsageHealth.freshness ? .ok : .stale
        }
    }

    /// `cswap list` rows (D1 fallback) carry a status instead of cswap's cache bookkeeping.
    static func health(_ status: CswapUsageStatus, fetchedAt: Date?, now: Date) -> CswapUsageHealth {
        switch status {
        case .reloginRequired: return .reloginRequired
        case .ok:
            guard let fetchedAt else { return .none }
            return now.timeIntervalSince(fetchedAt) <= CswapUsageHealth.freshness ? .fresh : .stale
        default: return fetchedAt == nil ? .none : .stale
        }
    }

    // MARK: AccountStore

    func account(_ id: AccountID) -> AccountVM? { accounts.first { $0.id == id } }

    var followingSessionCount: Int { sessionCounts?().following ?? 0 }

    func pinnedCount(for id: AccountID) -> Int {
        guard let number = Int(id) else { return 0 }
        return sessionCounts?().pinned[number] ?? 0
    }

    var newSessionAccountOptions: [NewSessionAccountOption] {
        AccountPinOptions.build(accounts: accounts, activeID: activeAccountID)
    }

    /// D5: `cswap switch <n> --json`, retried while Claude Code holds its credential lock (at most 3
    /// runs, progress in `switchState`), one switch at a time. Success marks the switch for the
    /// attribution grace (D6) and re-reads the state.
    func switchTo(_ id: AccountID, reason: AccountSwitchReason) async -> AccountSwitchOutcome {
        guard !switchState.isSwitching else { return .refused("正在切換帳號，請稍候") }
        guard baseAvailability.isReady, let client else { return .refused(availability.note ?? "帳號還在讀取") }
        guard let number = Int(id), let target = snapshot?.account(number) else { return .refused("沒有這個帳號") }
        let from = snapshot?.activeAccountNumber
        guard number != from else { return .alreadyActive }
        let started = now()
        switchState = .switching(to: id, reason: reason, attempt: 1, since: started)
        log("accounts switch to=#\(target.number) from=\(from.map { "#\($0)" } ?? "-") reason=\(reason.rawValue)")
        do {
            let response = try await client.switchAccount(to: number) { [weak self] attempt in
                Task { @MainActor in self?.attempt(attempt, to: id, reason: reason, since: started) }
            }
            if response.switched {
                switchMark = SwitchMark(at: now(), from: from, to: number)
            }
            await read(force: true)
            switchState = .idle
            guard response.switched else {
                lastSwitch = (from, number, reason, now(), "already-active")
                log("accounts switch to=#\(number) already active")
                return .alreadyActive
            }
            lastSwitch = (from, number, reason, now(), "switched")
            log("accounts switched to=#\(number) reason=\(reason.rawValue)")
            return .switched(from: from.map(String.init), to: id, following: followingSessionCount)
        } catch {
            let message = Self.failureMessage(error)
            switchState = .failed(message: message, at: now())
            lastSwitch = (from, number, reason, now(), "failed")
            log("accounts switch to=#\(number) failed (\(Self.kind(of: error)))")
            return .failed(message)
        }
    }

    private func attempt(_ attempt: Int, to id: AccountID, reason: AccountSwitchReason, since: Date) {
        guard case .switching(let target, _, let current, _) = switchState, target == id, current != attempt else { return }
        switchState = .switching(to: id, reason: reason, attempt: attempt, since: since)
    }

    /// The toast's message (繁體中文 where CODD writes it; cswap's own text redacted, D31).
    static func failureMessage(_ error: any Error) -> String {
        let text: String
        switch error {
        case CswapError.reported(let type, let message):
            text = type == "ClaudeCodeLockTimeout" ? "Claude Code 的 credential lock 一直被占用（已試 3 次）" : (message.isEmpty ? type : message)
        case CswapError.failed(let status, let stderr):
            text = stderr.isEmpty ? "cswap 結束碼 \(status)" : stderr
        case CswapError.runner(.timedOut):
            text = "cswap 沒有回應（逾時）"
        case CswapError.runner(.launchFailed):
            text = "無法執行 cswap"
        case CswapError.runner(.outputTooLarge):
            text = "cswap 的輸出過大"
        case CswapError.runner(.cancelled):
            text = "已取消"
        case CswapError.malformedOutput:
            text = "cswap 的回應無法解讀"
        case CswapError.unsupportedSchema:
            text = "cswap 的 JSON 版本不符（需要 ≥ 0.26）"
        default:
            text = "未知的錯誤"
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(EmailRedaction.redact(line).prefix(200))
    }

    /// A log-safe name for an error: never its message (cswap's carry e-mails).
    static func kind(of error: any Error) -> String {
        switch error {
        case CswapError.reported(let type, _): "reported \(EmailRedaction.redact(type))"
        case CswapError.failed(let status, _): "exit \(status)"
        case CswapError.runner(let runnerError): "runner \(runnerError.kindName)"
        case CswapError.malformedOutput: "malformed output"
        case CswapError.unsupportedSchema(let v): "schema \(v.map(String.init) ?? "?")"
        default: "error"
        }
    }

    static func stateErrorKind(_ error: CswapStateError) -> String {
        switch error {
        case .missing: "missing"
        case .unreadable: "unreadable"
        case .unsupported: "unsupported"
        }
    }

    // MARK: Status line (D6, D9)

    /// One status-line report (≤ 1 Hz per account key, `HookPipeline`): attributed to an account
    /// (D6) and merged into the book (D7). A suspected login change re-reads cswap's state.
    func ingest(_ report: StatusLineReport) {
        statusLine.accepted += 1
        statusLine.lastKey = report.configKey
        statusLine.lastAt = report.receivedAt
        guard report.fiveHour != nil || report.sevenDay != nil else { return }
        // Before the first read nothing says whether cswap has accounts: a `default` report would
        // land on the D4 pseudo account and stay in quota.json (holders that outlived the last
        // quit report right away). The newest per key waits for the first read (M3 review).
        if baseAvailability == .loading {
            pendingReports[report.configKey] = report
            return
        }
        attribute(report)
    }

    /// The reports that arrived while the accounts were loading, now that the state is known.
    private func replayPendingReports() {
        let pending = pendingReports.values.sorted { $0.receivedAt < $1.receivedAt }
        pendingReports = [:]
        for report in pending { attribute(report) }
    }

    private func attribute(_ report: StatusLineReport) {
        guard let key = AccountKey(rawValue: report.configKey) else {
            drop(report, why: "invalid key")
            return
        }
        let state = baseAvailability.isReady ? snapshot : nil
        let accounts = state?.accounts ?? []
        let result = QuotaAttribution.account(for: key, weeklyResetsAt: report.sevenDay?.resetsAt, activeAccount: state?.activeAccountNumber,
                                              hasCswapAccounts: !accounts.isEmpty, lastSwitch: switchMark, book: book,
                                              profileKeys: AccountKey.profileKeys(accounts, home: configuration.home), now: now(),
                                              slots: state.map(Self.slots))
        if result.suspectedLoginChange { suspectLoginChange(key: report.configKey) }
        guard let ref = result.account else {
            drop(report, why: "not attributable")
            return
        }
        if case .number(let n) = ref, state?.account(n) == nil {
            drop(report, why: "unknown account")
            return
        }
        var identity: String?
        if case .number(let n) = ref { identity = state?.account(n)?.identity }
        let observation = QuotaObservation.fromStatusLine(
            account: ref, fiveHour: report.fiveHour.map { CoddCore.QuotaWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) },
            weekly: report.sevenDay.map { CoddCore.QuotaWindow(usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) },
            capturedAt: report.receivedAt, identity: identity)
        statusLine.lastAccount = ref.key
        if seenKeys.insert(report.configKey).inserted {
            log("statusline first report key=\(report.configKey) account=\(ref.key)")
        }
        if book.ingest(observation) {
            scheduleSave()
            reassemble()
        }
    }

    /// D6's suspected login change: a re-read (skipped when cswap's files have not changed) at
    /// most every 15 s and a log line at most once a minute per key. An idle claude keeps
    /// reporting the previous account's reset after a switch (its rate_limits come from its last
    /// API response), up to once a second (M3 review).
    private func suspectLoginChange(key: String) {
        let at = now()
        if at.timeIntervalSince(loginChangeLog[key] ?? .distantPast) >= 60 {
            loginChangeLog[key] = at
            log("statusline key=\(key) suggests a login change: re-reading cswap state")
        }
        guard at.timeIntervalSince(lastSuspectedRead ?? .distantPast) >= configuration.suspectedReadInterval else { return }
        lastSuspectedRead = at
        Task { [weak self] in await self?.read(force: false) }
    }

    /// Logged at most once a minute per key and reason (reports come every second or so).
    private func drop(_ report: StatusLineReport, why: String) {
        statusLine.dropped += 1
        let key = report.configKey + " " + why
        let at = now()
        var entry = dropLog[key] ?? (at: .distantPast, skipped: 0)
        if at.timeIntervalSince(entry.at) >= 60 {
            log("statusline dropped key=\(report.configKey) (\(why))" + (entry.skipped > 0 ? " +\(entry.skipped) more" : ""))
            entry = (at, 0)
        } else {
            entry.skipped += 1
        }
        dropLog[key] = entry
    }

    // MARK: Pinning (D12)

    /// Whether account n can be pinned now (`.usable` carries the profile path for the launch).
    /// A new pin of the active account is refused; a `relaunch` of a session pinned before keeps
    /// its profile while it exists and is not stale.
    func pinResolution(_ number: Int, relaunch: Bool = false) -> AccountPinResolution {
        guard baseAvailability.isReady, let snapshot, !usingListFallback else { return .notReady }
        guard let account = snapshot.account(number) else { return .unknownAccount }
        if account.isActive, !relaunch { return .active }
        guard let profile = account.sessionProfile, !account.sessionProfileStale else { return .needsProfile }
        return .usable(path: profile.path)
    }

    /// Account n's profile path, stale or not (where its pinned sessions keep their transcripts).
    func profilePath(_ number: Int) -> String? {
        snapshot?.account(number)?.sessionProfile?.path
    }

    /// The account a `CLAUDE_CONFIG_DIR` belongs to (a launch profile's own pin): a cswap profile
    /// path names its number, any other path matches a known profile by its D6 key.
    func account(forConfigDir dir: String) -> Int? {
        switch AccountKey.from(claudeConfigDir: dir, home: configuration.home) {
        case .cswap(let n): return n
        case .other(let raw): return AccountKey.profileKeys(snapshot?.accounts ?? [], home: configuration.home)[raw]
        case .default: return nil
        }
    }


    // MARK: STATUS, auto-switch, dialog C (M3 I2)

    /// The merged accounts (cswap state + the quota book) the auto-switch policy decides on (D13);
    /// empty while cswap's state is not usable.
    func coreAccounts(now at: Date) -> [Account] {
        guard let snapshot, baseAvailability.isReady else { return [] }
        return AccountAssembler.accounts(state: snapshot, book: book, now: at)
    }

    /// STATUS profile card: account n's `cswap run` profile shares `~/.claude/settings.json`
    /// (nil without a profile or when it could not be checked). The path itself never leaves.
    func profileSharesSettings(_ number: Int) -> Bool? {
        snapshot?.account(number)?.sessionProfileSharesSettings
    }

    /// `~/.claude-swap-backup`, abbreviated (STATUS header); nil without a state root.
    var rootDisplayPath: String? { location.root.map { HolderSessionStore.abbreviate($0.path) } }

    /// The cswap executable in use (dialog C's `cswap add-token` shell); nil without one (D3).
    var executablePath: String? { client == nil ? nil : location.executable }

    /// The current login compared with cswap's accounts (dialog C step 2), off the main actor; nil
    /// without a readable cswap state. `token` changes with the identity (never the e-mail).
    func currentLogin() async -> CurrentLogin? {
        guard let reader else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CurrentLogin in
            let login = reader.currentLogin()
            return CurrentLogin(token: reader.currentLoginToken(), existingAccount: login.existingAccount, plan: login.plan,
                                loggedIn: login.loggedIn)
        }.value
    }

    /// Free slot numbers after the highest known one (dialog C's select: `#4`, `#5`, …).
    func nextFreeSlots(count: Int = 3) -> [Int] {
        let used = Set(snapshot?.accounts.map(\.number) ?? [])
        var slots: [Int] = []
        var n = 1
        while slots.count < count, n <= 9999 {
            if !used.contains(n), n > (used.max() ?? 0) { slots.append(n) }
            n += 1
        }
        return slots
    }

    /// D24: `cswap add --slot n --alias a` (captures the current login), then the state is read
    /// again. The alias is validated with cswap's own rule first (D34): an invalid one never
    /// reaches cswap. Returns the failure message (redacted, D31), nil on success.
    func addCurrentLogin(slot: Int, alias: String?) async -> String? {
        guard let client, baseAvailability.isReady else { return availability.note ?? "找不到 cswap" }
        var normalized: String?
        if let alias, !alias.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let valid = CswapAlias.normalize(alias) else { return CswapAlias.hint }
            normalized = valid
        }
        log("accounts add slot=#\(slot) alias=\(normalized == nil ? "no" : "yes")")
        do {
            try await client.addCurrentLogin(slot: slot, alias: normalized)
        } catch {
            log("accounts add failed (\(Self.kind(of: error)))")
            return Self.failureMessage(error)
        }
        await read(force: true)
        // `cswap add` answers 0 when it declined to overwrite another account's slot (stdin is not a
        // terminal): only the state says whether the login landed there.
        guard snapshot?.account(slot) != nil else {
            log("accounts add slot=#\(slot) not in the state after add")
            return "cswap 沒有把目前的登入加入 #\(slot)（編號可能已被使用）"
        }
        return nil
    }

    /// Settings › 帳號 alias (D34): `cswap alias n <alias>` (nil: `--unset`), then the state is
    /// read again. The alias is checked with cswap's own rule first: an invalid one never reaches
    /// cswap. Returns the failure message (redacted, D31), nil on success.
    func setAlias(_ alias: String?, account number: Int) async -> String? {
        guard let client, baseAvailability.isReady else { return availability.note ?? "找不到 cswap" }
        var normalized: String?
        if let alias {
            guard let valid = CswapAlias.normalize(alias) else { return CswapAlias.hint }
            normalized = valid
        }
        log("accounts alias #\(number) \(normalized == nil ? "unset" : "set")")
        do {
            try await client.setAlias(normalized, account: number)
        } catch {
            log("accounts alias failed (\(Self.kind(of: error)))")
            return Self.failureMessage(error)
        }
        await read(force: true)
        return nil
    }

    // MARK: quota.json (D7, D37)

    /// D37: the last automatic switch, kept in quota.json across relaunches.
    var lastAutoSwitchAt: Date? {
        get { book.lastAutoSwitchAt }
        set {
            guard book.lastAutoSwitchAt != newValue else { return }
            book.lastAutoSwitchAt = newValue
            // Written right away (off the main actor): the cooldown must survive a crash even
            // while reports keep the debounce from ever firing.
            scheduleSave(immediately: true)
        }
    }

    /// Debounced by ``Configuration/saveDelay``, but a change never waits longer than
    /// ``Configuration/maxSaveDelay``: steady 1 Hz reports used to restart the debounce forever,
    /// so quota.json was written only at quit (M3 review).
    private func scheduleSave(immediately: Bool = false) {
        guard configuration.quotaURL != nil else { return }
        savePending = true
        let started = pendingSince ?? ContinuousClock.now
        pendingSince = started
        if immediately || ContinuousClock.now - started >= configuration.maxSaveDelay {
            save(waiting: false)
            return
        }
        saveTask?.cancel()
        let delay = min(configuration.saveDelay, configuration.maxSaveDelay - (ContinuousClock.now - started))
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save(waiting: false)
        }
    }

    /// Writes a pending change now and waits for it, and for a write already on its way (the
    /// cooldown's immediate save), so the quit never cuts one short (quit; tests).
    func flush() {
        save(waiting: true)
        saveQueue.sync {}
    }

    private func save(waiting: Bool) {
        guard savePending, let url = configuration.quotaURL else { return }
        savePending = false
        pendingSince = nil
        saveTask?.cancel()
        saveTask = nil
        let book = self.book
        let store = QuotaStore(url: url)
        let log = self.log
        let write: @Sendable () -> Void = {
            do throws(QuotaStoreError) {
                try store.save(book)
            } catch {
                Task { @MainActor in log("error quota.json not saved (\(error))") }
            }
        }
        if waiting { saveQueue.sync(execute: write) } else { saveQueue.async(execute: write) }
    }

    // MARK: Dump

    /// `-codd-dump-state` keys `accounts`, `quota` and `statusline` (no e-mails, no paths, D31).
    var dumpObject: (accounts: [String: Any], quota: [String: Any], statusline: [String: Any]) {
        func iso(_ date: Date?) -> Any { date.map { JSDate.isoString($0) as Any } ?? NSNull() }
        func window(_ vm: QuotaWindow, sourced: SourcedWindow?) -> [String: Any] {
            ["remaining": vm.known ? vm.remainingPercent as Any : NSNull(), "resetsAt": iso(vm.resetsAt), "started": vm.started,
             "source": sourced.map { $0.source.rawValue as Any } ?? NSNull(), "capturedAt": iso(sourced?.capturedAt)]
        }
        let order = accounts.map { vm -> [String: Any] in
            let entry = book.entry(vm.number.map(QuotaAccountRef.number) ?? .defaultLogin)
            return [
                "id": vm.id, "slot": vm.slot, "alias": vm.alias, "plan": vm.plan as Any? ?? NSNull(), "active": vm.id == activeAccountID,
                "five": window(vm.fiveHour, sourced: entry?.fiveHour), "weekly": window(vm.week, sourced: entry?.weekly),
                "pace": vm.weekExhaustsAt.map { ["aheadOfPace": true, "projectedExhaustionAt": JSDate.isoString($0)] as Any } ?? NSNull(),
                "source": vm.source, "sourceAt": iso(vm.sourceAt), "sessionCount": vm.sessionCount, "pinnedCount": pinnedCount(for: vm.id),
                "health": vm.health.key, "disabled": vm.isDisabled, "hasSessionProfile": vm.hasSessionProfile,
                "profileStale": vm.profileStale, "pseudo": vm.isPseudo,
            ]
        }
        var switchState: [String: Any] = ["state": self.switchState.key]
        switch self.switchState {
        case .switching(let to, let reason, let attempt, let since):
            switchState["to"] = to; switchState["reason"] = reason.rawValue; switchState["attempt"] = attempt; switchState["since"] = iso(since)
        case .failed(let message, let at):
            switchState["message"] = message; switchState["at"] = iso(at)
        case .idle: break
        }
        var accountsObject: [String: Any] = [
            "availability": availability.key, "note": availability.note as Any? ?? NSNull(),
            "cswapVersion": cswapVersion.map { $0.description as Any } ?? NSNull(), "active": activeAccountID as Any? ?? NSNull(),
            "order": order, "switchState": switchState, "warnings": warnings, "fallback": usingListFallback,
            "following": followingSessionCount, "cswapPath": location.executable.map { HolderSessionStore.abbreviate($0) as Any } ?? NSNull(),
            "readMs": lastReadMilliseconds.map { $0 as Any } ?? NSNull(),
        ]
        if let last = lastSwitch {
            accountsObject["lastSwitch"] = ["from": last.from.map { $0 as Any } ?? NSNull(), "to": last.to, "reason": last.reason.rawValue,
                                            "at": JSDate.isoString(last.at), "outcome": last.outcome]
        } else {
            accountsObject["lastSwitch"] = NSNull()
        }
        let quotaJSON = (try? book.json.jsonData()).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
        let quota: [String: Any] = ["entries": quotaJSON["accounts"] ?? [:], "lastAutoSwitchAt": iso(book.lastAutoSwitchAt)]
        let statusline: [String: Any] = ["accepted": statusLine.accepted, "dropped": statusLine.dropped,
                                         "lastKey": statusLine.lastKey as Any? ?? NSNull(), "lastAt": iso(statusLine.lastAt),
                                         "lastAccount": statusLine.lastAccount as Any? ?? NSNull()]
        return (accountsObject, quota, statusline)
    }
}

extension CommandRunnerError {
    /// A log-safe name (a launch failure's text may carry a path).
    var kindName: String {
        switch self {
        case .launchFailed: "launchFailed"
        case .timedOut: "timedOut"
        case .outputTooLarge: "outputTooLarge"
        case .cancelled: "cancelled"
        }
    }
}

/// The global login as dialog C sees it (D24): who it is among cswap's accounts, never the e-mail.
struct CurrentLogin: Equatable, Sendable {
    /// Changes whenever the identity does (also between two logins cswap does not manage).
    var token: UInt64?
    /// The cswap account it is, nil for a login cswap does not manage yet.
    var existingAccount: Int?
    var plan: String?
    var loggedIn: Bool
}
