import CoddClaudeSettings
import CoddCore
import CoddHolderClient
import Foundation

/// A resolved holder start for one shell session. Plain data: built on the main actor, run off it.
struct HolderStartPlan: Sendable, Equatable {
    var sessionID: String
    var directory: String
    var socketPath: String
    var cwd: String
    var argv: [String]
    /// The child's exact environment (holder `--env-file`).
    var environment: [String: String]
    var cols: UInt16
    var rows: UInt16
    var ringSize: Int
    /// M4 D18, claude plans only: `<directory>/mcp.json`, written (0600, atomic) from `mcpConfig`
    /// once the directory exists, or removed when this launch has none (自動掛載 MCP OFF, the
    /// user's own registration), so a stale file never outlives the switch.
    var mcpConfigFile: String? = nil
    /// The per-session MCP config (its token is a secret: never logged or dumped).
    var mcpConfig: MCPLaunchConfig? = nil
}

enum HolderStartError: Error, Equatable, CustomStringConvertible {
    case socketPathTooLong(String)
    case launch(String)
    case files(String)
    case spawn(String)
    case notReady(String)
    /// `claude` is on neither the login shell's PATH nor `~/.local/bin` (the PATH searched).
    case claudeNotFound(String)

    var description: String {
        switch self {
        case .socketPathTooLong(let dir): "socket path under \(dir) exceeds 103 bytes (use a shorter data root)"
        case .launch(let reason): "cannot build the launch: \(reason)"
        case .files(let reason): "cannot prepare the session directory: \(reason)"
        case .spawn(let reason): "cannot start codd-holder: \(reason)"
        case .notReady(let reason): reason
        case .claudeNotFound(let path): "claude not found on PATH \(path) or in ~/.local/bin"
        }
    }

    /// What the session pane shows (繁體中文, one line).
    var userMessage: String {
        switch self {
        case .claudeNotFound: "找不到 claude 執行檔：登入 shell 的 PATH 與 ~/.local/bin/claude 都沒有。請先安裝 Claude Code，或確認 PATH。"
        case .socketPathTooLong: "資料位置的路徑太長，holder 的 socket 放不下（上限 103 bytes）。"
        case .launch(let reason): "無法組出啟動指令：\(reason)"
        case .files(let reason): "無法建立 session 資料夾：\(reason)"
        case .spawn(let reason): "無法啟動 codd-holder：\(reason)"
        case .notReady(let reason): "codd-holder 沒有回應：\(reason)"
        }
    }
}

/// How a claude session starts (new-session sheet, RESUME, RESTART).
struct ClaudeLaunchOptions: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        /// `--session-id <CODD session id>`.
        case new
        /// `--resume <Claude session id>` (the latest one hooks reported, else the CODD id).
        case resume(String)
        /// A new conversation in an existing CODD session: `--session-id <fresh id>`.
        case restart(UUID)
    }

    var mode: Mode = .new
    /// The launch profile (D5); nil = the default profile. A missing or non-claude id falls back
    /// to the default (`LaunchProfileDocument.claudeProfile(id:)`).
    var profileID: String?
    var name: String?
    var model: String?
    var permissionMode: String?
    /// D22 `從 Remote Control 啟動`: adds `--remote-control` unless the profile already passes it.
    /// Not remembered for a later RESUME.
    var remoteControl = false
    /// D12: the ⌘N select's `固定 #n`; the store turns it into `claudeConfigDir` and records it.
    var accountNumber: Int?
    /// D12: `CLAUDE_CONFIG_DIR` of a pinned session (a cswap session profile). It contains the
    /// account's e-mail slug: never logged, dumped or shown (D31).
    var claudeConfigDir: String?
}

/// Starts `codd-holder` processes for sessions and shell tabs: argv from CoddCore's
/// `LaunchBuilder` (claude: `--session-id` / `--resume`, `--settings` with the per-session hooks),
/// the exact child environment from `ShellEnvironment`, the spawn from `HolderSpawner` (own
/// session, CLOEXEC_DEFAULT) using the installed copy of the holder binary.
struct HolderLauncher: Sendable {
    /// docs/ARCHITECTURE.md: 8 MiB rings for shells. Claude sessions get the same (the
    /// architecture's 2 MiB was sized for full-screen tabs; Claude Code draws inline by default
    /// and a longer ring keeps more of a conversation for the replay after a relaunch).
    static let shellRingSize = 8 << 20
    static let claudeRingSize = 8 << 20
    /// Until a terminal reports its grid, holders start at this size.
    static let defaultColumns: UInt16 = 120
    static let defaultRows: UInt16 = 36
    static let readyTimeoutMilliseconds = 3000
    /// The holder's own environment. It never reads it (the child gets `--env-file`), and an app
    /// started from Xcode must not hand `DYLD_*` to holders that outlive it.
    static let holderEnvironment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
    static let envFileName = "spawn.env"
    static let logFileName = "holder.log"

    /// `<dataRoot>/bin/codd-holder-<digest>` in normal runs (`HolderBinary.install`).
    var holderExecutable: String
    var root: CoddDataRoot
    /// Replaces `$SHELL -l` (smoke runs: `/bin/zsh -f`).
    var shellArgvOverride: [String]?
    /// DEBUG `-codd-claude-path`: this executable instead of the `claude` on the login PATH.
    var claudePathOverride: String?
    /// Whether a path is an executable file (tests resolve `claude` against nothing).
    var isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    /// Test seam (M5 D20): awaited off the main actor right before the store spawns a holder with
    /// this launcher, so a test can stop a session while its spawn is in flight without a sleep
    /// race. Nil in the app.
    var beforeStart: (@Sendable () async -> Void)?
    /// The SessionStart command hook baked into every claude session's `--settings`: the copy
    /// under `<dataRoot>/bin` (`CoddHookBinary.install`), else the bundle's own file.
    var coddHookPath: String? = HolderLauncher.bundledCoddHook
    /// D8: the status-line command of claude sessions with hooks (`CoddStatusLineBinary.install`);
    /// nil starts them without a CODD status line.
    var coddStatusLinePath: String?
    /// Launch profiles (D5): `<dataRoot>/profiles.json` through `LaunchProfiles`, which pushes
    /// every change here (`HolderSessionStore.applyLaunchProfiles`); tests set their own.
    var profiles: [LaunchProfile] = LaunchProfile.builtIn
    /// The profile a claude session without (or with an unknown) profile id starts with.
    var defaultProfileID = LaunchProfileDocument.builtInDefaultId

    var profileDocument: LaunchProfileDocument {
        LaunchProfileDocument(profiles: profiles, defaultProfileId: defaultProfileID)
    }

    init(holderExecutable: String, root: CoddDataRoot, shellArgvOverride: [String]? = nil, claudePathOverride: String? = nil) {
        self.holderExecutable = holderExecutable
        self.root = root
        self.shellArgvOverride = shellArgvOverride
        self.claudePathOverride = claudePathOverride
    }

    /// `Contents/MacOS/codd-holder`, copied there by the "Embed codd-holder" build phase. Never
    /// spawned from there (`HolderBinary.install` copies it out first).
    static var bundledHolder: String? { bundledTool("codd-holder") }

    /// `Contents/MacOS/codd-hook` ("Embed codd-hook" build phase). Never baked into a session
    /// from there when the copy-out works (`CoddHookBinary.install`): a moved, rebuilt or updated
    /// app would break SessionStart of every running session.
    static var bundledCoddHook: String? { bundledTool("codd-hook") }

    /// `Contents/MacOS/codd-statusline` ("Embed codd-statusline" build phase).
    static var bundledCoddStatusLine: String? { bundledTool("codd-statusline") }

    static func bundledTool(_ name: String) -> String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Resolves argv, environment and paths.
    /// - Parameters:
    ///   - directory: the holder's `--dir`; default `sessions/<id>` (a shell tab passes
    ///     `sessions/<owner>/tabs/<id>`, which session discovery does not list).
    ///   - socketPath: reuses a restarted session's socket.
    ///   - loginEnvironment: the captured login-shell environment (nil: defaults only).
    ///   - grid: the terminal's size, when one is already laid out.
    func plan(sessionID: UUID, cwd: String, directory: String? = nil, socketPath: String? = nil,
              loginEnvironment: [String: String]? = nil, grid: TerminalGridSize? = nil) throws(HolderStartError) -> HolderStartPlan {
        let id = sessionID.uuidString.lowercased()
        guard let socket = socketPath ?? root.socketPath(for: id) else { throw .socketPathTooLong(root.runPath) }
        // D5: shell sessions and shell tabs use the first shell profile (its shell and environment).
        let profile = profileDocument.shellProfile
        let base = ProcessInfo.processInfo.environment
        let spec: LaunchSpec
        do {
            spec = try LaunchBuilder(hooks: nil).build(
                LaunchRequest(profile: profile, cwd: cwd, sessionId: sessionID),
                baseEnvironment: base, loginEnvironment: loginEnvironment, hookToken: "")
        } catch {
            throw .launch(String(describing: error))
        }
        // The profile's variables with the same blocked-name rules as a claude profile's.
        let environment = ShellEnvironment.build(base: base, login: loginEnvironment, sessionID: sessionID,
                                                 overrides: profile.environment)
        func clamp(_ value: Int?, _ fallback: UInt16) -> UInt16 {
            guard let value, value > 1 else { return fallback }
            return UInt16(clamping: value)
        }
        return HolderStartPlan(
            sessionID: id, directory: directory ?? root.sessionDirectory(id), socketPath: socket, cwd: spec.cwd,
            argv: shellArgvOverride ?? spec.argv, environment: environment,
            cols: clamp(grid?.columns, Self.defaultColumns), rows: clamp(grid?.rows, Self.defaultRows),
            ringSize: Self.shellRingSize)
    }

    /// Resolves a claude session: `claude` from the login PATH (or the DEBUG override), the
    /// session's `--settings` hooks, `CODD_SESSION_ID` / `CODD_HOOK_TOKEN` / `CODD_HOOK_URL`, and the
    /// login environment minus the deny-list.
    /// - Parameters:
    ///   - hooks: the hook settings and token; nil starts claude without CODD hooks (config.json
    ///     unreadable): its state then comes from the registry only.
    ///   - mcp: M4 D18, the session's MCP config: written to `<sessionDir>/mcp.json` by `start`
    ///     and passed as `--mcp-config <that path>` right before `--settings` (only with hooks:
    ///     CODD's MCP server lives on the hook port).
    func planClaude(sessionID: UUID, cwd: String, options: ClaudeLaunchOptions,
                    hooks: (settings: ClaudeHookSettings, token: String)?, mcp: MCPLaunchConfig? = nil, socketPath: String? = nil,
                    loginEnvironment: [String: String]? = nil, grid: TerminalGridSize? = nil) throws(HolderStartError) -> HolderStartPlan {
        let id = sessionID.uuidString.lowercased()
        guard let socket = socketPath ?? root.socketPath(for: id) else { throw .socketPathTooLong(root.runPath) }
        let base = ProcessInfo.processInfo.environment
        // D5: the named claude profile, else the default, else the first claude profile.
        var profile = profileDocument.claudeProfile(id: options.profileID)
        if options.remoteControl, !profile.extraArguments.contains(where: Self.isRemoteControlFlag) {
            profile.extraArguments.append("--remote-control")
        }
        let launchID: UUID
        let mode: LaunchRequest.Mode
        var resumeID: String?
        switch options.mode {
        case .new: launchID = sessionID; mode = .new
        case .restart(let fresh): launchID = fresh; mode = .new
        case .resume(let claudeID): launchID = sessionID; mode = .resume; resumeID = claudeID
        }
        let override = claudePathOverride
        let isExecutable = self.isExecutable
        // With an override, `claude` only has to resolve to something; argv[0] is replaced below.
        let builder = LaunchBuilder(hooks: hooks?.settings, isExecutable: { path in
            (override != nil && path.hasSuffix("/claude")) || isExecutable(path)
        })
        let directory = root.sessionDirectory(id)
        let mcpFile = directory + "/" + Self.mcpConfigName
        let mcpConfig = hooks == nil ? nil : mcp
        let request = LaunchRequest(profile: profile, cwd: cwd, sessionId: launchID, mode: mode, resumeClaudeSessionId: resumeID,
                                    name: options.name, model: options.model,
                                    permissionMode: options.permissionMode.map(PermissionMode.init(rawValue:)),
                                    claudeConfigDir: options.claudeConfigDir, mcpConfigPath: mcpConfig == nil ? nil : mcpFile)
        var spec: LaunchSpec
        do {
            spec = try builder.build(request, baseEnvironment: base, loginEnvironment: loginEnvironment, hookToken: hooks?.token ?? "")
        } catch LaunchBuildError.executableNotFound {
            let path = SpawnEnvironmentBuilder().build(base: base, login: loginEnvironment, sessionId: sessionID, hookToken: nil)["PATH"]
            throw .claudeNotFound(path ?? "")
        } catch LaunchBuildError.invalidValue("CLAUDE_CONFIG_DIR", _) {
            // The value is a cswap profile path (an e-mail slug): never in a message or a log (D31).
            throw .launch("帳號的設定目錄不是絕對路徑")
        } catch {
            throw .launch(String(describing: error))
        }
        if let override { spec.argv[0] = override }
        var extra: [String: String] = [:]
        if let hooks { extra[CoddEnvironmentName.hookURL] = hooks.settings.endpoint.url }
        // §0: the holder environment is ShellEnvironment's, not `spec.environment`, so CODD's own
        // additions (CODD_STATUSLINE_CHAIN, a pinned CLAUDE_CONFIG_DIR) are merged in here and win
        // over the login environment and the profile; the auth overrides of a pinned session go.
        extra.merge(spec.coddEnvironment) { _, codd in codd }
        // Hooks name the CODD session even when the conversation id differs (RESTART).
        // The profile's own variables too (review SEC-6: they were dropped here, so an
        // account-pinned profile would have run on the default account).
        var environment = ShellEnvironment.build(base: base, login: loginEnvironment, sessionID: sessionID,
                                                 hookToken: hooks?.token, overrides: profile.environment, extra: extra)
        for name in spec.removedNames { environment[name] = nil }
        func clamp(_ value: Int?, _ fallback: UInt16) -> UInt16 {
            guard let value, value > 1 else { return fallback }
            return UInt16(clamping: value)
        }
        return HolderStartPlan(
            sessionID: id, directory: directory, socketPath: socket, cwd: spec.cwd, argv: spec.argv,
            environment: environment, cols: clamp(grid?.columns, Self.defaultColumns), rows: clamp(grid?.rows, Self.defaultRows),
            ringSize: Self.claudeRingSize, mcpConfigFile: mcpFile, mcpConfig: mcpConfig)
    }

    /// D18: the per-session MCP config's name inside the session directory.
    static let mcpConfigName = "mcp.json"

    /// D8 / D35: the per-session `statusLine` for `--settings`: `command` (the installed
    /// codd-statusline), and the user's own status line chained (`CODD_STATUSLINE_CHAIN`) with its
    /// `padding` / `refreshInterval` / `hideVimModeIndicator`, read read-only from the session cwd's
    /// `.claude/settings.local.json`, `.claude/settings.json`, then `userSettings` (first with a
    /// command wins; missing or unreadable files are skipped). Blocking file I/O: call off main.
    static func statusLineInjection(command: String, cwd: String, userSettings: URL) -> StatusLineInjection {
        let files = UserStatusLine.loadFiles(UserStatusLine.candidateURLs(cwd: cwd, userSettings: userSettings))
        guard let chain = UserStatusLine.chain(from: files) else { return StatusLineInjection(command: command) }
        var extras: [String: JSONValue] = [:]
        for (key, raw) in chain.extras {
            if let value = JSONValue.parse(Data(raw.utf8)) { extras[key] = value }
        }
        return StatusLineInjection(command: command, extras: extras, chainCommand: chain.command)
    }

    /// `--remote-control` or `--remote-control=…` (a profile such as `claude-rc` passes it itself).
    static func isRemoteControlFlag(_ argument: String) -> Bool {
        argument == "--remote-control" || argument.hasPrefix("--remote-control=")
    }

    /// Creates the session directory (0700), writes a claude session's `mcp.json` (M4) and the env
    /// file (both 0600), spawns the holder and waits
    /// until its socket accepts connections. Blocking (file I/O, up to 3 s): call it off the main
    /// actor. Returns the holder pid.
    func start(_ plan: HolderStartPlan) throws(HolderStartError) -> pid_t {
        let manager = FileManager.default
        let envPath = plan.directory + "/" + Self.envFileName
        do {
            try root.prepare()
            try manager.createDirectory(atPath: plan.directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            // D18: regenerated at every launch, RESUME and RESTART (claude reads it at startup);
            // before the env file, so a failure here never leaves that file (it holds the hook token).
            if let file = plan.mcpConfigFile {
                if let config = plan.mcpConfig {
                    do {
                        try config.write(to: URL(fileURLWithPath: file, isDirectory: false))
                    } catch {
                        throw HolderStartError.files("cannot write \(Self.mcpConfigName)")
                    }
                } else if manager.fileExists(atPath: file) {
                    try? manager.removeItem(atPath: file)
                }
            }
            let bytes = try EnvironmentFile.encode(plan.environment)
            guard manager.createFile(atPath: envPath, contents: bytes, attributes: [.posixPermissions: 0o600]) else {
                throw HolderStartError.files("cannot write \(envPath)")
            }
        } catch let error as HolderStartError {
            throw error
        } catch {
            throw .files(String(describing: error))
        }
        // The holder reads the file before it listens; it is not needed once the socket is up.
        defer { try? manager.removeItem(atPath: envPath) }

        let launch = HolderLaunch(
            holderExecutable: holderExecutable, session: plan.sessionID, sessionDirectory: plan.directory,
            socketPath: plan.socketPath, cols: plan.cols, rows: plan.rows, cwd: plan.cwd,
            ringSize: plan.ringSize, envFile: envPath, logPath: plan.directory + "/" + Self.logFileName,
            argv: plan.argv)
        let pid: pid_t
        do {
            pid = try HolderSpawner.spawn(launch, environment: Self.holderEnvironment)
        } catch {
            throw .spawn(String(describing: error))
        }
        ChildReaper.shared.watch(pid)
        guard HolderSpawner.waitForSocket(plan.socketPath, timeoutMilliseconds: Self.readyTimeoutMilliseconds, pid: pid) else {
            kill(pid, SIGTERM)
            throw .notReady("holder \(pid) did not open \(plan.socketPath) (see \(plan.directory)/\(Self.logFileName))")
        }
        return pid
    }
}

/// The holder binary CODD spawns from (M1 plan, "Holder binary"): the bundled `codd-holder`
/// copied to `<dataRoot>/bin/codd-holder-<sha256 prefix>`, so app updates and rebuilds never
/// touch a running holder's file. Older copies no process runs are collected at launch.
enum HolderBinary {
    /// Installs the bundled holder under `root` and collects unused copies. Blocking file I/O:
    /// call it off the main actor. Falls back to the bundle's own file when copying fails.
    static func install(root: CoddDataRoot, log: @Sendable (String) -> Void) -> String? {
        guard let bundled = HolderLauncher.bundledHolder else { return nil }
        do {
            try root.prepare()
            let installation = try HolderBinaryInstaller.install(bundledHolder: bundled, dataRoot: root.path)
            // Spawns come from this copy for the whole run: another instance must not collect it.
            HolderBinaryInstaller.markInUse(installation.path)
            let removed = HolderBinaryInstaller.collectGarbage(dataRoot: root.path, keeping: [installation.path])
            log("holder binary \(installation.path) copied=\(installation.copied) removed=\(removed.count)")
            return installation.path
        } catch {
            log("error holder binary not installed (\(error)); spawning from the bundle")
            return bundled
        }
    }
}

/// The SessionStart hook CODD bakes into claude sessions: the bundled `codd-hook` copied to
/// `<dataRoot>/bin/codd-hook-<sha256 prefix>` like the holder. Its absolute path lives in every
/// running session's `--settings` (Claude runs it again on `/clear` and on resume), so a copy is
/// collected only when no live holder's argv names it any more.
enum CoddHookBinary {
    static let namePrefix = "codd-hook-"

    /// Installs the bundled codd-hook under `root` (no collection: that needs the live sessions).
    /// Blocking file I/O: call it off the main actor. Falls back to the bundle's own file.
    static func install(root: CoddDataRoot, log: @Sendable (String) -> Void) -> String? {
        guard let bundled = HolderLauncher.bundledCoddHook else {
            log("error codd-hook is missing from the app bundle: SessionStart hooks are not sent")
            return nil
        }
        do {
            try root.prepare()
            let installation = try HolderBinaryInstaller.install(bundled: bundled, dataRoot: root.path, namePrefix: namePrefix)
            // New sessions name this copy in their --settings: keep it while this app runs.
            HolderBinaryInstaller.markInUse(installation.path)
            log("codd-hook binary \(installation.path) copied=\(installation.copied)")
            return installation.path
        } catch {
            log("error codd-hook not installed (\(error)); sessions use the bundle's copy")
            return bundled
        }
    }

    /// The installed codd-hook copies named in `argvs` (holder children's argv: the path sits in
    /// the `--settings` JSON, possibly with escaped slashes).
    static func referencedPaths(in argvs: [[String]], root: CoddDataRoot) -> Set<String> {
        referencedPaths(in: argvs, root: root, namePrefix: namePrefix)
    }

    /// The installed `<namePrefix><digest>` copies named anywhere in `argvs`. The status line's
    /// command is single-quoted (a `'` in the root reads `'\''`, `'\\''` inside the JSON), so the
    /// quote escapes are undone before matching.
    static func referencedPaths(in argvs: [[String]], root: CoddDataRoot, namePrefix: String) -> Set<String> {
        let prefix = root.path + "/" + HolderBinaryInstaller.directoryName + "/" + namePrefix
        var found = Set<String>()
        for argument in argvs.joined() where argument.contains(namePrefix) {
            let plain = argument.replacingOccurrences(of: "\\/", with: "/")
                .replacingOccurrences(of: "'\\\\''", with: "'").replacingOccurrences(of: "'\\''", with: "'")
            var rest = Substring(plain)
            while let range = rest.range(of: prefix) {
                let digest = rest[range.upperBound...].prefix(HolderBinaryInstaller.digestLength)
                let path = prefix + digest
                if HolderBinaryInstaller.isInstalledName((path as NSString).lastPathComponent, prefix: namePrefix) {
                    found.insert(path)
                }
                rest = rest[range.upperBound...]
            }
        }
        return found
    }

    /// Removes unused copies: not `current`, not referenced by a live session, old enough.
    @discardableResult
    static func collectGarbage(root: CoddDataRoot, current: String?, liveArgv: [[String]],
                               log: @Sendable (String) -> Void) -> [String] {
        let keeping = Array(referencedPaths(in: liveArgv, root: root)) + (current.map { [$0] } ?? [])
        let removed = HolderBinaryInstaller.collectGarbage(dataRoot: root.path, namePrefix: namePrefix, keeping: keeping)
        if !removed.isEmpty { log("codd-hook binary removed=\(removed.count) kept=\(keeping.count)") }
        return removed
    }
}

/// D8 / D11: the status-line command of CODD's claude sessions. The bundled `codd-statusline` is
/// copied to `<dataRoot>/bin/codd-statusline-<sha256 prefix>` like codd-hook (its path is baked
/// into every claude session's `--settings`; a copy no live holder's argv names is collected), and
/// to the stable `<dataRoot>/bin/codd-statusline` the optional global status line runs (D11:
/// refreshed through temp + rename, so a running copy keeps its inode; never collected).
enum CoddStatusLineBinary {
    static let namePrefix = "codd-statusline-"
    static let stableName = "codd-statusline"

    /// Installs both copies (no collection: that needs the live sessions). Blocking file I/O.
    static func install(root: CoddDataRoot, log: @Sendable (String) -> Void) -> String? {
        guard let bundled = HolderLauncher.bundledCoddStatusLine else {
            log("error codd-statusline is missing from the app bundle: claude sessions start without CODD's status line")
            return nil
        }
        do {
            try root.prepare()
            let installation = try HolderBinaryInstaller.install(bundled: bundled, dataRoot: root.path, namePrefix: namePrefix)
            HolderBinaryInstaller.markInUse(installation.path)
            let stable = (try? installStable(bundled: bundled, root: root)) ?? false
            log("codd-statusline binary \(installation.path) copied=\(installation.copied) stable=\(stable ? "refreshed" : "current")")
            return installation.path
        } catch {
            log("error codd-statusline not installed (\(error)); sessions use the bundle's copy")
            return bundled
        }
    }

    /// `<dataRoot>/bin/codd-statusline`: replaced (temp file, 0755, rename) when its bytes differ
    /// from the bundle's. Returns whether it was written.
    @discardableResult
    static func installStable(bundled: String, root: CoddDataRoot) throws -> Bool {
        let manager = FileManager.default
        let directory = root.path + "/" + HolderBinaryInstaller.directoryName
        let target = directory + "/" + stableName
        let bytes = try Data(contentsOf: URL(fileURLWithPath: bundled))
        if let existing = manager.contents(atPath: target), existing == bytes { return false }
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory + "/.\(stableName).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp"
        guard manager.createFile(atPath: temporary, contents: bytes, attributes: [.posixPermissions: 0o755]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary, target) == 0 else {
            try? manager.removeItem(atPath: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        return true
    }

    /// Removes hashed copies no live session names (the current one always stays).
    @discardableResult
    static func collectGarbage(root: CoddDataRoot, current: String?, liveArgv: [[String]], log: @Sendable (String) -> Void) -> [String] {
        let keeping = Array(CoddHookBinary.referencedPaths(in: liveArgv, root: root, namePrefix: namePrefix)) + (current.map { [$0] } ?? [])
        let removed = HolderBinaryInstaller.collectGarbage(dataRoot: root.path, namePrefix: namePrefix, keeping: keeping)
        if !removed.isEmpty { log("codd-statusline binary removed=\(removed.count) kept=\(keeping.count)") }
        return removed
    }
}
