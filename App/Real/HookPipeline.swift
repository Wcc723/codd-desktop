import CoddComposer
import CoddCore
import CoddFiles
import CoddHooks
import Foundation
import Observation

/// What a hook said about the tool Claude is about to run, for the answer bar and the header
/// (`Bash: npm test -- auth.spec.ts`, an AskUserQuestion's question and options). The state engine
/// keeps only the tool name, so this is read from `tool_input` as the event passes by.
struct HookToolDetail: Sendable, Equatable, Codable {
    var tool: String?
    /// One line: the command, file, URL or pattern the tool works on.
    var summary: String?
    /// AskUserQuestion: the first question and its option labels.
    var question: String?
    var options: [String] = []

    static let summaryMax = 160

    enum Update: Sendable, Equatable {
        case set(HookToolDetail)
        /// A turn boundary or a finished tool: the previous detail no longer applies.
        case clear
    }

    /// `nil` when the event says nothing about the current tool.
    static func update(for payload: HookPayload) -> Update? {
        switch payload.event {
        case .preToolUse?, .permissionRequest?:
            guard let tool = payload.toolName else { return nil }
            return .set(detail(tool: tool, input: payload.raw["tool_input"]?.objectValue ?? [:], cwd: payload.cwd))
        case .postToolUse?, .postToolUseFailure?, .userPromptSubmit?, .stop?, .stopFailure?, .sessionStart?, .sessionEnd?:
            return .clear
        default:
            return nil
        }
    }

    static func detail(tool: String, input: [String: JSONValue], cwd: String?) -> HookToolDetail {
        var detail = HookToolDetail(tool: tool)
        func text(_ key: String) -> String? { input[key]?.stringValue.flatMap(clean) }
        switch tool {
        case "AskUserQuestion":
            let first = input["questions"]?.arrayValue?.first?.objectValue
            detail.question = first?["question"]?.stringValue.flatMap(clean)
            detail.options = (first?["options"]?.arrayValue ?? []).compactMap { option in
                (option.objectValue?["label"]?.stringValue ?? option.stringValue).flatMap(clean)
            }
            detail.summary = detail.question
        case "ExitPlanMode":
            detail.summary = text("plan").map { String($0.prefix(80)) }
        default:
            let path = (text("file_path") ?? text("notebook_path") ?? text("path")).map { relative($0, to: cwd) }
            detail.summary = text("command") ?? path ?? text("url") ?? text("query") ?? text("pattern")
                ?? text("description") ?? text("prompt")
        }
        return detail
    }

    /// One line, collapsed whitespace, no control characters, at most `summaryMax` characters.
    static func clean(_ raw: String) -> String? {
        let scalars = raw.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > summaryMax ? String(collapsed.prefix(summaryMax - 1)) + "…" : collapsed
    }

    static func relative(_ path: String, to cwd: String?) -> String {
        guard let cwd, path.hasPrefix(cwd + "/") else { return path }
        return String(path.dropFirst(cwd.count + 1))
    }
}

/// The answer bar's detail of a waiting claude session, kept next to its holder
/// (`<session dir>/answer.json`, 0600). Hooks never repeat a pending prompt, so after a relaunch
/// the bar showed a bare `Claude 需要授權 ·`, or `1 Yes 2 No` for a question whose real options
/// were Postgres / SQLite / MySQL (review E2E-2).
enum PendingAnswerFile {
    static let name = "answer.json"
    /// Writes in call order, off the main actor.
    private static let queue = DispatchQueue(label: CoddIdentity.label("pending-answer"), qos: .utility)

    /// Blocking read: call off the main actor.
    static func read(directory: String) -> HookToolDetail? {
        guard let data = FileManager.default.contents(atPath: directory + "/" + name), data.count <= 64 * 1024 else { return nil }
        return try? JSONDecoder().decode(HookToolDetail.self, from: data)
    }

    /// `nil` removes the file.
    static func write(_ detail: HookToolDetail?, directory: String) {
        let path = directory + "/" + name
        queue.async {
            guard let detail, let data = try? JSONEncoder().encode(detail) else {
                try? FileManager.default.removeItem(atPath: path)
                return
            }
            guard FileManager.default.fileExists(atPath: directory) else { return }
            let temporary = path + ".tmp"
            guard FileManager.default.createFile(atPath: temporary, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
            if rename(temporary, path) != 0 { try? FileManager.default.removeItem(atPath: temporary) }
        }
    }

    /// Waits for the writes queued so far (tests).
    static func flush() {
        queue.sync {}
    }
}

/// The M4 routes the app serves on the hook server (I2a): `POST /mcp`, `POST /hooks/prompt` and
/// `GET /n/<id>.md`. CoddHooks routes, authenticates and frames them; these closures answer.
struct HookRouteHandlers: Sendable {
    var mcp: HookServer.MCPHandler? = nil
    var prompt: HookServer.PromptHandler? = nil
    var noteURL: HookServer.NoteURLHandler? = nil
}

/// The app-hosted hook pipeline (M1 "degraded mode"): `<dataRoot>/config.json` → `HookServer` on
/// 127.0.0.1 and a `RegistryWatcher` on `<claudeDir>/sessions`, both feeding a
/// `SessionStateEngine` whose batches the session store applies on the main actor.
///
/// Assembled from CoddHooks' public parts rather than `HookRuntime`, so that each hook event is
/// also read for its tool detail (`HookToolDetail`) before the engine sees it. A busy port or a
/// failed listener never stops the app: the status says so (status bar, menu bar icon), the
/// registry still drives the states, and the bind is retried with backoff until it succeeds
/// (a previous CODD still shutting down, a second instance that quit). While the endpoint is not
/// this app's, new claude sessions start without hooks: their token and hook bodies (prompts,
/// commands, file contents) would go to whoever holds the port.
@MainActor @Observable
final class HookPipeline {
    enum Status: Equatable, Sendable {
        case starting
        case listening(port: UInt16)
        /// The port of config.json is taken (`otherCODD`: it answers `/health` as CODD).
        case portInUse(port: UInt16, otherCODD: Bool)
        case failed(String)
    }

    private(set) var status = Status.starting
    /// The endpoint's counters (accepted / rejected by status, last rejection), refreshed by
    /// `refreshStatistics()` (the STATUS page polls it while shown). A rejection of Claude's own
    /// http client (an unexpected Origin or Host header) shows up here.
    private(set) var statistics: HookServerStatistics?
    /// When the last accepted hook event arrived (STATUS: 最近收到資料).
    private(set) var lastEventAt: Date?
    /// Events accepted since launch, counted as they reach the engine.
    private(set) var eventCount = 0
    /// M4: the MCP, prompt and note URL handlers are on the server (with the external MCP
    /// token): the MCP lamps need this and `status.isListening`.
    private(set) var routesInstalled = false
    @ObservationIgnored let engine: SessionStateEngine
    @ObservationIgnored let dataRoot: URL
    @ObservationIgnored let claudeDirectory: ClaudeDirectory
    @ObservationIgnored private(set) var config: HookConfig?
    @ObservationIgnored private(set) var server: HookServer?
    @ObservationIgnored private let watcher: RegistryWatcher
    @ObservationIgnored private let clock: any HookClock
    @ObservationIgnored private var configTask: Task<HookConfig?, Never>?
    @ObservationIgnored private var pumps: [Task<Void, Never>] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var stopped = false
    /// The first bind attempt finished (launches wait for it to know whether hooks can be used).
    @ObservationIgnored private var firstBindDone = false
    @ObservationIgnored private var firstBindWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var routes: HookRouteHandlers?
    @ObservationIgnored private let bindRetryDelays: [Duration]
    /// Delays between bind attempts while the endpoint is down; the last one repeats.
    static let bindRetryDelays: [Duration] = [.seconds(2), .seconds(3), .seconds(5), .seconds(10)]
    @ObservationIgnored private let log: @MainActor (String) -> Void
    /// Engine batches, in order.
    @ObservationIgnored var onBatch: ((SessionStateBatch) -> Void)?
    /// Tool details, each delivered before the engine handles its event.
    @ObservationIgnored var onDetail: ((UUID, HookToolDetail.Update) -> Void)?
    /// M4 D26: the files CODD sessions' Edit / Write / MultiEdit / NotebookEdit named
    /// (`files/ai-touches.json`). Recorded off the main actor as the events pass by.
    let aiTouches: AITouchLog
    /// The touches just recorded (the file editor's chips and the ±10 s attribution, D25).
    @ObservationIgnored var onAITouch: (([AITouch]) -> Void)?
    /// Every registry snapshot, right after the engine ingested it (the watcher's stream has one
    /// consumer, the pump below): the store finds the external sessions in it (D6).
    @ObservationIgnored var onRegistry: ((RegistrySnapshot) -> Void)?
    /// `UserPromptSubmit`'s `prompt` per CODD session: the display form (`cleanPrompt`, D20) and
    /// the whole one for resends (`resendablePrompt`, D26; nil when it cannot be resent whole).
    @ObservationIgnored var onPrompt: ((UUID, String, String?) -> Void)?
    /// D9: status-line reports, at most one per second per account key (the newest wins), for the
    /// account store's quota book.
    @ObservationIgnored var onStatusLine: ((StatusLineReport) -> Void)?
    /// How often one account key reaches `onStatusLine` (D9).
    @ObservationIgnored var statusLineInterval: Duration = .seconds(1)

    /// Ports a test or throwaway data root's config.json is created with (D24): never the range the
    /// user's own CODD and its claude sessions use.
    nonisolated static let testPortRange: ClosedRange<UInt16> = 43000...43999

    /// The range for a new config.json under `root`: the user's (47821–47899) for the standard data
    /// root, `testPortRange` for any other (`-codd-data-root` / `CODD_DATA_ROOT`).
    nonisolated static func portRange(for root: CoddDataRoot) -> ClosedRange<UInt16> {
        root == .standard ? HookConfigStore.portRange : testPortRange
    }

    /// - Parameters:
    ///   - port: replaces config.json's port (tests: 0 = an ephemeral port).
    ///   - portRange: where a config.json created now takes its port from; an existing file is used as is.
    init(dataRoot: URL, claudeDirectory: ClaudeDirectory, port: UInt16? = nil,
         portRange: ClosedRange<UInt16> = HookConfigStore.portRange, clock: any HookClock = SystemHookClock(),
         bindRetryDelays: [Duration] = HookPipeline.bindRetryDelays,
         log: @escaping @MainActor (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.dataRoot = dataRoot
        self.claudeDirectory = claudeDirectory
        self.portRange = portRange
        self.clock = clock
        self.bindRetryDelays = bindRetryDelays.isEmpty ? Self.bindRetryDelays : bindRetryDelays
        self.log = log
        portOverride = port
        engine = SessionStateEngine(configuration: .init(dataRoot: dataRoot, defaultConfigDir: claudeDirectory.path), clock: clock)
        watcher = RegistryWatcher(configuration: .init(directories: [claudeDirectory.registryURL]))
        aiTouches = AITouchLog(file: dataRoot.appendingPathComponent("files/ai-touches.json"), clock: { Date() })
    }

    /// D26: a PostToolUse of a CODD session that names a file (`HookPayload.toolFilePaths`:
    /// relative paths resolved against the payload's `cwd`) as touches of that session at the
    /// time the hook arrived. Every other event gives none.
    nonisolated static func aiTouches(for event: HookEvent) -> [AITouch] {
        let paths = event.payload.toolFilePaths
        guard !paths.isEmpty else { return [] }
        let session = event.sessionID.uuidString.lowercased()
        let tool = event.payload.toolName ?? "Edit"
        return paths.map { AITouch(path: $0, session: session, tool: tool, at: event.receivedAt) }
    }

    @ObservationIgnored private let portOverride: UInt16?
    @ObservationIgnored let portRange: ClosedRange<UInt16>

    /// config.json (created on first use: the first free port of `portRange` — 47821 or the next
    /// free one for the standard data root, a random free one of 43000–43999 for any other — and a
    /// random token). An existing file is used as is.
    func loadConfig() async -> HookConfig? {
        if let configTask { return await configTask.value }
        let root = dataRoot
        let override = portOverride
        let range = portRange
        let task = Task.detached(priority: .userInitiated) { () -> Result<(HookConfig, Bool, Int?), HookConfigError> in
            do throws(HookConfigError) {
                let load = try Self.loadOrCreate(dataRoot: root, range: range)
                var config = load.config
                if let override { config.port = override }
                let chosePort: Bool
                switch load.origin {
                case .created: chosePort = true
                case .repaired(_, let portChanged, _): chosePort = portChanged
                case .loaded: chosePort = false
                }
                return .success((config, chosePort, load.newerVersion))
            } catch {
                return .failure(error)
            }
        }
        let wrapped = Task { [weak self] () -> HookConfig? in
            switch await task.value {
            case .success(let (config, chosePort, newer)):
                if chosePort, range == Self.testPortRange { self?.log("hooks port-range=test") }
                // M5 D14: a newer CODD's config.json is used as it is and never rewritten.
                if let newer { self?.log("hooks config.json is v\(newer) (newer CODD): used read-only") }
                self?.config = config
                return config
            case .failure(let error):
                self?.status = .failed("config.json：\(error)")
                self?.log("error hook config: \(error)")
                return nil
            }
        }
        configTask = wrapped
        return await wrapped.value
    }

    /// The standard range is searched from its start (47821 is the documented default); the test
    /// range from a random point, so throwaway roots created at the same moment rarely pick the
    /// same port. Blocking file I/O.
    nonisolated static func loadOrCreate(dataRoot: URL, range: ClosedRange<UInt16>) throws(HookConfigError) -> HookConfigLoad {
        guard range == testPortRange else { return try HookConfigStore(dataRoot: dataRoot, portRange: range).loadOrCreate() }
        let pivot = UInt16.random(in: range)
        do throws(HookConfigError) {
            return try HookConfigStore(dataRoot: dataRoot, portRange: pivot...range.upperBound).loadOrCreate()
        } catch .noFreePort {
            return try HookConfigStore(dataRoot: dataRoot, portRange: range).loadOrCreate()
        }
    }

    /// Starts the pumps, the registry watcher and the endpoint (once).
    func start() async {
        guard !started else { return }
        started = true
        let engine = engine
        pumps.append(Task.detached(priority: .userInitiated) { [weak self] in
            for await batch in engine.updates { await self?.deliver(batch) }
        })
        let snapshots = watcher.snapshots
        pumps.append(Task.detached(priority: .utility) { [weak self] in
            for await snapshot in snapshots {
                await engine.ingestRegistry(snapshot)
                await self?.deliver(snapshot)
            }
        })
        watcher.start()
        guard let config = await loadConfig() else {
            finishFirstBind()
            return
        }
        let server = HookServer(configuration: .init(config: config), clock: clock)
        self.server = server
        // M4: before the first bind, so no request ever reaches a server without its routes.
        if let routes { await install(routes, on: server) }
        let events = server.events
        let touchLog = aiTouches
        pumps.append(Task.detached(priority: .userInitiated) { [weak self] in
            for await event in events {
                await self?.noteEvent(at: event.receivedAt)
                let touches = Self.aiTouches(for: event)
                if !touches.isEmpty {
                    touchLog.record(touches)
                    await self?.deliver(touches)
                }
                if let update = HookToolDetail.update(for: event.payload) { await self?.deliver(update, for: event.sessionID) }
                if event.payload.event == .userPromptSubmit, let prompt = Self.cleanPrompt(event.payload.raw["prompt"]) {
                    await self?.deliverPrompt(prompt, full: Self.resendablePrompt(event.payload.raw["prompt"]), for: event.sessionID)
                }
                await engine.ingest(event)
            }
        })
        let reports = server.statusLines
        let throttle = StatusLineThrottle(interval: statusLineInterval)
        pumps.append(Task.detached(priority: .utility) { [weak self] in
            for await report in reports {
                await throttle.offer(report) { [weak self] report in await self?.deliver(report) }
            }
        })
        await bind(server, token: config.token, retry: false)
        finishFirstBind()
        if !status.isListening { scheduleRetry(server, token: config.token, attempt: 0) }
    }

    /// M4 I2a: the route handlers, installed on the server once it exists (now, or when `start`
    /// creates it); they survive rebinds and restarts (CoddHooks keeps them across stop / start).
    func setRoutes(_ routes: HookRouteHandlers) {
        self.routes = routes
        guard let server else { return }
        Task { await self.install(routes, on: server) }
    }

    /// M4 D23 `輪替`: a new external MCP token written to config.json (0600, atomic; port and hook
    /// token kept) off the main actor, then handed to the running server and kept in `config`, so
    /// COPY REF, registrations and the note URL route use it at once. Nil on success, else why.
    func rotateMCPToken() async -> String? {
        guard config != nil else { return "config.json 尚未讀取" }
        let root = dataRoot
        let range = portRange
        let result = await Task.detached(priority: .userInitiated) { () -> Result<HookConfig, HookConfigError> in
            do throws(HookConfigError) {
                return .success(try HookConfigStore(dataRoot: root, portRange: range).rotateMCPToken())
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case .success(let rotated):
            config?.mcpToken = rotated.mcpToken
            if let server { await server.setMCPToken(rotated.mcpToken) }
            log("hooks mcp-token rotated")
            return nil
        case .failure(let error):
            log("error hooks mcp-token rotate: \(error)")
            return "\(error)"
        }
    }

    private func install(_ routes: HookRouteHandlers, on server: HookServer) async {
        await server.setMCPToken(config?.mcpToken)
        await server.setMCPHandler(routes.mcp)
        await server.setPromptHandler(routes.prompt)
        await server.setNoteURLHandler(routes.noteURL)
        if !routesInstalled {
            routesInstalled = true
            log("hooks routes mcp=\(routes.mcp != nil) prompt=\(routes.prompt != nil) note-url=\(routes.noteURL != nil) "
                + "external-token=\(config?.mcpToken != nil)")
        }
    }

    /// One bind attempt; the status says how it went. Retries log only a change.
    private func bind(_ server: HookServer, token: String, retry: Bool) async {
        let before = status
        do throws(HookServerError) {
            let port = try await server.start()
            status = .listening(port: port)
            log(retry ? "hooks listening port=\(port) (after a retry)" : "hooks listening port=\(port)")
        } catch {
            if case .portInUse(let port) = error {
                let owner = await HookHealthProbe.probe(port: port, token: token)
                status = .portInUse(port: port, otherCODD: owner == .codd)
                if !retry || status != before { log("error hooks port \(port) in use (\(owner))") }
            } else {
                status = .failed(error.description)
                if !retry || status != before { log("error hooks \(error)") }
            }
        }
    }

    private func scheduleRetry(_ server: HookServer, token: String, attempt: Int) {
        guard !stopped else { return }
        let delay = bindRetryDelays[min(attempt, bindRetryDelays.count - 1)]
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.stopped, !self.status.isListening else { return }
            await self.bind(server, token: token, retry: true)
            if !self.status.isListening { self.scheduleRetry(server, token: token, attempt: attempt + 1) }
        }
    }

    private func finishFirstBind() {
        firstBindDone = true
        let waiters = firstBindWaiters
        firstBindWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Returns once the first bind attempt finished (right away before `start` or after it).
    private func firstBind() async {
        guard started, !firstBindDone else { return }
        await withCheckedContinuation { firstBindWaiters.append($0) }
    }

    private func deliver(_ batch: SessionStateBatch) { onBatch?(batch) }
    private func noteEvent(at date: Date) {
        lastEventAt = date
        eventCount += 1
    }
    private func deliver(_ update: HookToolDetail.Update, for id: UUID) { onDetail?(id, update) }
    private func deliver(_ touches: [AITouch]) { onAITouch?(touches) }
    private func deliver(_ snapshot: RegistrySnapshot) { onRegistry?(snapshot) }
    private func deliverPrompt(_ prompt: String, full: String?, for id: UUID) { onPrompt?(id, prompt, full) }
    private func deliver(_ report: StatusLineReport) { onStatusLine?(report) }

    /// D20: the prompt as one line (controls and newlines become spaces, runs collapsed), at most
    /// 200 characters; nil when blank or not a string. For display only.
    nonisolated static func cleanPrompt(_ value: JSONValue?) -> String? {
        JSText.cleanText(value, max: 200)
    }

    /// D26: the prompt exactly as sent, for a resend: nil when blank, not a string, or more than
    /// one composer send can carry (`ComposerEncoding.maxBytes` after its cleaning), so a resend
    /// is the whole prompt or nothing.
    nonisolated static func resendablePrompt(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value, text.utf8.count <= ComposerEncoding.maxBytes * 2,
              (try? ComposerEncoding.payload(for: text)) != nil else { return nil }
        return text
    }

    /// The per-session hook settings and the token for a claude launch; nil without config.json or
    /// while this app's endpoint is not listening (review SEC-3: the port's holder would receive
    /// the token and every hook body). Waits for the first bind attempt of a starting pipeline.
    func launchSettings(coddHook: String) async -> (settings: ClaudeHookSettings, token: String)? {
        guard let config = await loadConfig() else { return nil }
        await firstBind()
        guard status.isListening else {
            log("hooks not listening (\(status)): claude starts without hooks, states from the registry")
            return nil
        }
        return (ClaudeHookSettings(endpoint: config.endpoint, sessionStartCommand: coddHook), config.token)
    }

    /// The endpoint URL sessions are started with (nil until config.json was read).
    var endpointURL: String? { config?.endpoint.url }

    /// Reads the endpoint's counters into `statistics`.
    func refreshStatistics() async {
        guard let server else { return }
        let current = await server.statistics()
        if current != statistics { statistics = current }
    }

    /// The registry folder the watcher reads (`<claudeDir>/sessions`).
    var registryPath: String { claudeDirectory.registryURL.path }

    /// D12: the registry folders of pinned sessions (`<profile>/sessions`) are watched after
    /// `<claudeDir>/sessions`. The paths carry e-mail slugs: never logged.
    @ObservationIgnored private var extraRegistryDirectories: [URL] = []

    func setExtraRegistryDirectories(_ directories: [URL]) {
        let keys = directories.map { $0.standardizedFileURL.path }
        guard keys != extraRegistryDirectories.map({ $0.standardizedFileURL.path }) else { return }
        extraRegistryDirectories = directories
        watcher.setDirectories([claudeDirectory.registryURL] + directories)
    }

    /// How many extra registry folders are watched (the dump; never their paths).
    var extraRegistryCount: Int { extraRegistryDirectories.count }

    /// App quit: writes pending hook records and releases the port. The streams stay open.
    func shutdown() async {
        stopped = true
        retryTask?.cancel()
        retryTask = nil
        await engine.flush()
        await server?.stop()
        watcher.stop()
    }
}

extension HookPipeline.Status {
    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// D9: at most one status-line report per account key and `interval` reaches the main actor; a
/// report arriving sooner waits, replaced by any newer one of the same key.
actor StatusLineThrottle {
    private let interval: Duration
    private var last: [String: ContinuousClock.Instant] = [:]
    private var pending: [String: StatusLineReport] = [:]
    private let clock = ContinuousClock()

    init(interval: Duration) {
        self.interval = interval
    }

    func offer(_ report: StatusLineReport, deliver: @escaping @Sendable (StatusLineReport) async -> Void) async {
        let key = report.configKey
        let now = clock.now
        if let previous = last[key], now - previous < interval {
            let alreadyWaiting = pending[key] != nil
            pending[key] = report
            guard !alreadyWaiting else { return }
            let wait = interval - (now - previous)
            Task { [weak self] in
                try? await Task.sleep(for: wait)
                await self?.flush(key, deliver: deliver)
            }
            return
        }
        last[key] = now
        await deliver(report)
    }

    private func flush(_ key: String, deliver: @Sendable (StatusLineReport) async -> Void) async {
        guard let report = pending.removeValue(forKey: key) else { return }
        last[key] = clock.now
        await deliver(report)
    }
}
