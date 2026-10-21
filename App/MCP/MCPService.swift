import CoddClaudeSettings
import CoddCore
import CoddHooks
import CoddMCP
import CoddNotes
import CoddPreferences
import CoddSettingsUI
import CoddStatusUI
import CoddUI
import Foundation
import Observation

/// CODD's MCP server in the app (M4 I2a, D16–D21): CoddMCP's `MCPServer` named `codd` over the
/// notes (`NotesMCPBackend`), served on the hook server's loopback port next to the hooks. It
/// installs the three M4 routes on `HookPipeline` (`/mcp`, `/hooks/prompt`, `/n/<id>.md`), feeds
/// the request path's context (library, session facts, AI 可寫入) from the main actor, and keeps
/// what the rail, the status bar, the Notebook footer, STATUS and Settings show: whether it runs,
/// the endpoint, the clients (D21), the Claude Code registration (inspected here; written by
/// `MCPRegistrationService`, I2b) and the prompt expansions. Real mode only: mock mode never
/// installs a route (D35).
@MainActor @Observable
final class MCPService {
    /// A D21 client: a CODD session after its `initialize` (or, after a CODD restart, its first
    /// request) while it is live, or an external token with its `clientInfo.name` seen in the last
    /// 30 minutes.
    struct Client: Equatable, Sendable {
        enum Kind: String, Sendable { case session, external }
        /// The lowercase session id, or `ext:<client name>`.
        var key: String
        var kind: Kind
        /// `Claude Code`, `Codex CLI`, or the raw `clientInfo.name`.
        var clientKind: String
        /// The session's title, or the external client's name.
        var title: String
        var since: Date
    }

    struct ToolCall: Equatable, Sendable {
        var name: String
        /// `ok`, `isError` or `failed`.
        var outcome: String
        var ms: Double
        var caller: String
    }

    /// A note an AI made with `notes_create` (the toast `Claude 建立了筆記：<title>`).
    struct CreatedNote: Equatable, Sendable {
        var id: String
        var title: String
        /// `Claude Code`, `Codex CLI`, `external` or the raw client name (``NotesMCPContext/clientKind(for:)``).
        var clientKind: String
    }

    /// The dump's `promptExpansion`.
    struct ExpansionStats: Equatable, Sendable {
        var count = 0
        var late = 0
        var lastRefs: [String] = []
        var lastExpanded: [String] = []
        var lastChars = 0
        var lastMs: Double?
    }

    /// Claude Code's user-scope entry (`<claudeDir>/../.claude.json`, C10's read-only inspection).
    enum Registration: Equatable, Sendable {
        case unknown
        case notRegistered
        /// `tokenMatches == false`: the token was rotated since (D23).
        case registered(tokenMatches: Bool?)
        /// The file cannot be read or parsed (繁體中文 reason for the hint).
        case unavailable(String)
    }

    /// External clients count this long after they were last seen (D21).
    static let externalWindow: TimeInterval = 30 * 60

    private(set) var clients: [Client] = []
    /// Requests and notifications the server saw (every JSON-RPC message).
    private(set) var requests = 0
    private(set) var toolCalls = 0
    private(set) var lastTool: ToolCall?
    /// Notes made with `notes_create` this run (the dump's `mcp.notesCreated`).
    private(set) var notesCreated = 0
    private(set) var expansion = ExpansionStats()
    private(set) var claudeCode: Registration = .unknown
    /// CODE-3: `~/.claude.json` or a CODD backup of it holds a token the group or others may read
    /// (a registration made before CODD wrote such files 0600); the row offers `收緊`.
    private(set) var claudeCodeExposed = false

    @ObservationIgnored let context: NotesMCPContext
    @ObservationIgnored let server: MCPServer
    @ObservationIgnored let expander: PromptExpansion
    @ObservationIgnored let urls: NoteURLResponder
    /// The expansions' records, delivered on the main actor (`promptExpansion`).
    @ObservationIgnored private let records: AsyncStream<PromptExpansion.Record>
    @ObservationIgnored private var recordsTask: Task<Void, Never>?
    @ObservationIgnored private weak var holders: HolderSessionStore?
    @ObservationIgnored private let notes: NotesService
    @ObservationIgnored private let log: @Sendable (String) -> Void
    @ObservationIgnored private var started = false
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var loops: [ObservationLoop] = []
    /// Per tracked client: when it connected and when it was last seen.
    @ObservationIgnored private var sessionClients: [String: (since: Date, lastSeen: Date, name: String?)] = [:]
    @ObservationIgnored private var externalClients: [String: (since: Date, lastSeen: Date)] = [:]
    @ObservationIgnored private var lastExternal: String?
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var registrationKey: String?
    /// I2b: the file the registration writes (`MCPRegistrationTarget`); nil inspects
    /// `<claudeDir>/../.claude.json` read only, as I2a did.
    @ObservationIgnored var registrationFile: URL?
    /// `notes_create` made a note (the app shows its toast; never activates CODD).
    @ObservationIgnored var onNoteCreated: ((CreatedNote) -> Void)?

    init(holders: HolderSessionStore, notes: NotesService, expansionDeadline: Duration = .milliseconds(1300),
         log: @escaping @Sendable (String) -> Void = { HolderSessionStore.printLog($0) }) {
        self.holders = holders
        self.notes = notes
        self.log = log
        let context = NotesMCPContext(clock: notes.clock, timeZone: notes.timeZone)
        self.context = context
        server = MCPServer(info: MCPServerInfo(version: VersionProbe.appShortVersion), backend: NotesMCPBackend(context: context),
                           timeZone: notes.timeZone)
        urls = NoteURLResponder(context: context, log: log)
        let (records, sink) = AsyncStream.makeStream(of: PromptExpansion.Record.self, bufferingPolicy: .bufferingNewest(64))
        self.records = records
        expander = PromptExpansion(context: context, deadline: expansionDeadline, report: { sink.yield($0) }, log: log)
    }

    // MARK: Facts for the surfaces

    /// The endpoint and its handlers run (the lamps go green, D21).
    var running: Bool {
        guard let hooks = holders?.hooks else { return false }
        return hooks.routesInstalled && hooks.status.isListening
    }

    /// The hook server's port, which MCP shares (D16): the bound one, else config.json's.
    var port: UInt16? {
        guard let hooks = holders?.hooks else { return nil }
        if case .listening(let port) = hooks.status { return port }
        return hooks.config?.port
    }

    /// `127.0.0.1:<port>` (`—` before config.json was read).
    var endpoint: String { port.map { "127.0.0.1:\($0)" } ?? "—" }

    /// `http://127.0.0.1:<port>/mcp`, what registrations and per-session configs point at.
    var url: String? { port.map { HookEndpoint(port: $0, path: "/mcp").url } }

    var clientCount: Int { clients.count }

    // MARK: Lifecycle

    /// Installs the routes on the hook pipeline (before or after its server exists: the pipeline
    /// installs them on creation and they survive rebinds) and starts following the server's
    /// events, the notebook and the sessions.
    func start() {
        guard !started, let hooks = holders?.hooks else { return }
        started = true
        let server = self.server
        let expander = self.expander
        let urls = self.urls
        hooks.setRoutes(HookRouteHandlers(
            mcp: { caller, request in
                let mcpCaller: MCPCaller = switch caller {
                case .session(let id): .session(id)
                case .external: .external
                }
                let response = await server.handle(MCPHTTPRequest(method: request.method, headers: request.headers, body: request.body,
                                                                  caller: mcpCaller))
                return HTTPRouteResponse(status: response.status, contentType: response.contentType, headers: response.headers,
                                         body: response.body)
            },
            prompt: { sessionID, payload in await expander.answer(sessionID: sessionID, prompt: payload.prompt) },
            noteURL: { id in await urls.respond(id) }))
        let events = server.events
        eventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }
        let records = self.records
        recordsTask = Task { [weak self] in
            for await record in records {
                guard let self else { return }
                self.record(record)
            }
        }
        let notes = self.notes
        let context = self.context
        loops.append(ObservationLoop(track: { () -> Bool in notes.availability.isReady }, apply: { ready in
            context.setLibrary(ready ? notes.library : nil)
        }))
        if let holders {
            loops.append(ObservationLoop(track: { () -> [String: NotesMCPContext.Session] in
                var facts: [String: NotesMCPContext.Session] = [:]
                for session in holders.sessionsByID.values where !session.external {
                    let project = holders.project(session.projectID)
                    facts[session.id.lowercased()] = NotesMCPContext.Session(
                        title: session.title, cwd: project?.cwd ?? holders.runtime(session.id)?.cwd,
                        live: session.state.isLive, project: project.flatMap { $0.isTransient ? nil : $0.cwd })
                }
                return facts
            }, apply: { [weak self] facts in
                context.setSessions(facts)
                self?.rebuildClients()
            }))
        }
        // The registration rows have a value before STATUS or Settings first shows (and after a
        // rebind to another port).
        loops.append(ObservationLoop(track: { [weak self] () -> String? in
            guard let self, self.running else { return nil }
            return self.url
        }, apply: { [weak self] url in
            guard url != nil else { return }
            Task { await self?.refreshRegistrations() }
        }))
        // Externals expire 30 minutes after they were last seen even when nothing else happens.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                self.rebuildClients()
            }
        }
    }

    /// Settings › 筆記本 & MCP: AI 可寫入 (D17) and 自動掛載 MCP (D18) take effect for the next
    /// request / launch.
    func apply(preferences value: CoddPreferences) {
        context.writeEnabled = value.notebook.aiCanWrite
        holders?.autoAttachMCP = value.notebook.autoAttachMCP
    }

    func stop() {
        eventsTask?.cancel()
        recordsTask?.cancel()
        ticker?.cancel()
        for loop in loops { loop.cancel() }
        loops = []
    }

    // MARK: Events (D21)

    func handle(_ event: MCPEvent) {
        switch event {
        case .request(let caller, _, let at):
            requests += 1
            switch caller.kind {
            case .session(let id):
                let key = id.uuidString.lowercased()
                if sessionClients[key] != nil {
                    sessionClients[key]?.lastSeen = at
                } else {
                    // A session that initialized before CODD restarted keeps calling without a new
                    // `initialize` (stateless MCP, the holder outlived the app): its first request counts it.
                    sessionClients[key] = (since: at, lastSeen: at, name: nil)
                    rebuildClients()
                }
            case .external:
                if let key = lastExternal { externalClients[key]?.lastSeen = at }
            }
        case .initialized(let caller, let name, _, let version, let at):
            context.setClientName(name, for: caller)
            switch caller.kind {
            case .session(let id):
                let key = id.uuidString.lowercased()
                if var tracked = sessionClients[key] {
                    tracked.lastSeen = at
                    tracked.name = name ?? tracked.name
                    sessionClients[key] = tracked
                } else {
                    sessionClients[key] = (since: at, lastSeen: at, name: name)
                }
            case .external:
                let key = name.flatMap { JSText.nonBlankTrimmed($0) } ?? "external"
                externalClients[key] = (since: externalClients[key]?.since ?? at, lastSeen: at)
                lastExternal = key
            }
            log("mcp initialized caller=\(Self.callerName(caller)) "
                + "client=\(Self.logSafe(NotesMCPContext.clientKind(name, session: caller.sessionID != nil))) protocol=\(Self.logSafe(version))")
            rebuildClients()
        case .tool(let caller, let name, let outcome, let ms, _):
            let text: String = switch outcome {
            case .ok: "ok"
            case .isError: "isError"
            case .failed: "failed"
            }
            toolCalls += 1
            lastTool = ToolCall(name: name, outcome: text, ms: ms, caller: Self.callerName(caller))
            log(String(format: "mcp tool=%@ outcome=%@ ms=%.2f caller=%@", Self.logSafe(name), text, ms, Self.callerName(caller)))
        case .resource(let caller, _, let ok, _):
            log("mcp resource ok=\(ok) caller=\(Self.callerName(caller))")
        case .created(let caller, let id, _, let title, _):
            notesCreated += 1
            log("mcp note-created id=\(Self.logSafe(id)) caller=\(Self.callerName(caller))")
            onNoteCreated?(CreatedNote(id: id, title: title, clientKind: context.clientKind(for: caller)))
        }
    }

    /// A client-chosen string as one short log token (no controls or spaces, at most 60 characters),
    /// so a client name can never forge a log line.
    nonisolated static func logSafe(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { $0.properties.generalCategory == .control || $0 == " " ? "_" : Character($0) }
        return String(String(scalars).prefix(60))
    }

    /// `session` or `external` (never a token, never a title).
    static func callerName(_ caller: MCPCaller) -> String {
        caller.sessionID == nil ? "external" : "session"
    }

    /// The published client list: live CODD sessions after their `initialize`, externals seen in
    /// the last 30 minutes.
    func rebuildClients() {
        let now = self.now()
        var next: [Client] = []
        for (key, tracked) in sessionClients {
            guard let session = holders?.sessionsByID[key] ?? holders?.sessionsByID[key.uppercased()]
                    ?? holders?.sessionsByID.values.first(where: { $0.id.lowercased() == key }),
                  session.state.isLive else {
                sessionClients[key] = nil
                continue
            }
            next.append(Client(key: key, kind: .session, clientKind: NotesMCPContext.clientKind(tracked.name, session: true),
                               title: session.title, since: tracked.since))
        }
        for (name, tracked) in externalClients {
            guard now.timeIntervalSince(tracked.lastSeen) <= Self.externalWindow else {
                externalClients[name] = nil
                continue
            }
            next.append(Client(key: "ext:\(name)", kind: .external, clientKind: NotesMCPContext.clientKind(name, session: false),
                               title: name, since: tracked.since))
        }
        next.sort { ($0.since, $0.key) < ($1.since, $1.key) }
        if next != clients { clients = next }
    }

    private func record(_ record: PromptExpansion.Record) {
        if record.late {
            expansion.late += 1
        } else {
            expansion.count += 1
        }
        expansion.lastRefs = record.refs
        expansion.lastExpanded = record.expanded
        expansion.lastChars = record.chars
        expansion.lastMs = record.ms
    }

    // MARK: Registration (D22: inspected here, written by `MCPRegistrationService`)

    /// `<claudeDir>/../.claude.json`: where Claude Code keeps user-scope MCP servers.
    nonisolated static func globalConfigURL(claudeDirectory: ClaudeDirectory) -> URL {
        URL(fileURLWithPath: claudeDirectory.path, isDirectory: true).deletingLastPathComponent()
            .appendingPathComponent(".claude.json", isDirectory: false).standardizedFileURL
    }

    /// Re-reads Claude Code's registration off the main actor (STATUS / Settings refreshes). On a
    /// test data root the real `~/.claude.json` is never read (D37).
    /// `force`: inspect again even when the file, the endpoint and the token look unchanged (after
    /// a write that may have changed only modes).
    func refreshRegistrations(force: Bool = false) async {
        guard let holders, let url else { return }
        let file = registrationFile ?? Self.globalConfigURL(claudeDirectory: holders.claudeDirectory)
        if holders.root != .standard, RealModeOptions.protectedPathReason(file.path) != nil {
            if claudeCode != .unknown { claudeCode = .unknown }
            if claudeCodeExposed { claudeCodeExposed = false }
            return
        }
        let token = holders.hooks?.config?.mcpToken
        // STATUS refreshes every 5 s: a `.claude.json` of several MB is parsed again only when
        // it, the endpoint or the token changed.
        let key = Self.registrationKey(file: file.path, url: url, token: token)
        guard force || key != registrationKey else { return }
        registrationKey = key
        let result = await Task.detached(priority: .utility) { () -> (Registration, Bool) in
            do {
                let inspection = try ClaudeUserConfigMCPInstaller(file: file, backupsIndex: nil).inspect(ourURL: url, token: token)
                guard inspection.fileExists else { return (.notRegistered, false) }
                guard inspection.parsable else { return (.unavailable("~/.claude.json 無法解析"), inspection.exposesToken) }
                guard let entry = inspection.codd, let entryURL = entry.url, Self.sameEndpoint(entryURL, url) else {
                    return (.notRegistered, inspection.exposesToken)
                }
                return (.registered(tokenMatches: entry.tokenMatches), inspection.exposesToken)
            } catch {
                return (.unavailable("讀不到 ~/.claude.json"), false)
            }
        }.value
        if result.0 != claudeCode { claudeCode = result.0 }
        if result.1 != claudeCodeExposed { claudeCodeExposed = result.1 }
    }

    /// The inputs of the last inspection: the file's size, mtime, inode and mode, the endpoint, the
    /// token's hash.
    nonisolated static func registrationKey(file: String, url: String, token: String?) -> String {
        var info = stat()
        let stamp = stat(file, &info) == 0
            ? "\(info.st_size)-\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)-\(info.st_ino)-\(info.st_mode)" : "missing"
        return "\(stamp)|\(url)|\(token.map { String($0.hashValue) } ?? "-")"
    }

    /// Scheme and host case, `localhost` for `127.0.0.1` and a trailing `/` ignored.
    nonisolated static func sameEndpoint(_ a: String, _ b: String) -> Bool {
        func normalized(_ url: String) -> String {
            var s = url.trimmingCharacters(in: .whitespaces).lowercased()
            while s.hasSuffix("/") { s.removeLast() }
            return s.replacingOccurrences(of: "://localhost", with: "://127.0.0.1")
        }
        return normalized(a) == normalized(b)
    }

    // MARK: Dump (§6; never a token)

    var dumpObject: [String: Any] {
        let configs = (holders?.mcpSessionConfigs ?? [:]).sorted { $0.key < $1.key }.map { id, config -> [String: Any] in
            ["session": id, "serverName": config.serverName.map { $0 as Any } ?? NSNull(),
             "file": config.file.map { $0 as Any } ?? NSNull(), "registeredOurs": config.registeredOurs]
        }
        return [
            "running": running, "endpoint": endpoint,
            "clients": clients.map { ["key": $0.key, "kind": $0.kind.rawValue, "name": $0.clientKind, "title": $0.title,
                                      "since": JSDate.isoString($0.since)] },
            "requests": requests, "toolCalls": toolCalls, "notesCreated": notesCreated,
            "lastTool": lastTool.map { ["name": $0.name, "outcome": $0.outcome, "ms": $0.ms, "caller": $0.caller] as Any } ?? NSNull(),
            "rejections": holders?.hooks?.statistics?.mcpRejected ?? 0,
            "sessionConfigs": configs,
            "claudeCode": Self.registrationName(claudeCode),
            "claudeCodeExposed": claudeCodeExposed,
        ]
    }

    var expansionDump: [String: Any] {
        ["count": expansion.count, "late": expansion.late, "lastRefs": expansion.lastRefs, "lastExpanded": expansion.lastExpanded,
         "lastChars": expansion.lastChars, "lastMs": expansion.lastMs.map { $0 as Any } ?? NSNull()]
    }

    static func registrationName(_ state: Registration) -> String {
        switch state {
        case .unknown: "unknown"
        case .notRegistered: "notRegistered"
        case .registered(let matches): matches == false ? "needsReregister" : "registered"
        case .unavailable: "unavailable"
        }
    }
}

/// The STATUS card's and Settings' registration rows (D22). Claude Code's button registers,
/// re-registers (a rotated token), tightens modes (`收緊`, CODE-3: registered with the current
/// token in a file or backup others may read) or removes; it is disabled with the reason as hint
/// and tooltip on a test data root without `-codd-claude-json`, while the hook server is down, or
/// while a write runs. Codex opens its snippet; Claude Desktop is `FUTURE`.
enum MCPRegistrationRows {
    static let tightenTitle = "收緊"

    static func status(_ claudeCode: MCPService.Registration, claudeCodeReason: String? = nil,
                       codexReason: String? = nil, exposed: Bool = false) -> [StatusMCPRegistration] {
        let claude: StatusMCPRegistration
        let enabled = claudeCodeReason == nil
        let hint = claudeCodeReason ?? "user scope"
        switch claudeCode {
        case .registered(let matches) where matches == false:
            claude = row("claude-code", "Claude Code", hint, "◆ 需要重新註冊", .warn, "註冊", enabled, claudeCodeReason, accent: true)
        case .registered where exposed:
            claude = row("claude-code", "Claude Code", hint, "◆ 權限過寬", .warn, tightenTitle, enabled, claudeCodeReason, accent: true)
        case .registered:
            claude = row("claude-code", "Claude Code", hint, "● 已註冊", .ok, "移除", enabled, claudeCodeReason)
        case .notRegistered:
            claude = row("claude-code", "Claude Code", hint, "○ 未註冊", .muted, "註冊", enabled, claudeCodeReason, accent: true)
        case .unknown:
            claude = row("claude-code", "Claude Code", hint, "—", .muted, "註冊", enabled, claudeCodeReason, accent: true)
        case .unavailable(let reason):
            claude = row("claude-code", "Claude Code", claudeCodeReason ?? reason, "▲ 讀不到", .crit, "註冊", enabled, claudeCodeReason,
                         accent: true)
        }
        return [claude,
                row("codex", "Codex", "~/.codex/config.toml", "○ 未註冊", .muted, "註冊", codexReason == nil, codexReason, accent: true),
                StatusMCPRegistration(id: "claude-desktop", name: "Claude Desktop", hint: "擴充功能", state: "○ 未安裝", stateTone: .muted,
                                      actionTitle: "安裝 .mcpb", actionEnabled: false, chip: "FUTURE")]
    }

    private static func row(_ id: String, _ name: String, _ hint: String, _ state: String, _ tone: Tone, _ action: String,
                            _ enabled: Bool, _ tip: String?, accent: Bool = false) -> StatusMCPRegistration {
        StatusMCPRegistration(id: id, name: name, hint: hint, state: state, stateTone: tone, actionTitle: action, actionEnabled: enabled,
                              accent: accent, toolTip: tip)
    }

    static func settings(_ claudeCode: MCPService.Registration, claudeCodeReason: String? = nil,
                         codexReason: String? = nil, exposed: Bool = false) -> [SettingsMCPRegistration] {
        let claude: SettingsMCPRegistration
        let enabled = claudeCodeReason == nil
        switch claudeCode {
        case .registered(let matches) where matches == false:
            claude = SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: claudeCodeReason ?? "需要重新註冊（token 已輪替）",
                                             isOn: true, actionTitle: "註冊", actionEnabled: enabled, accent: true, toolTip: claudeCodeReason)
        case .registered where exposed:
            claude = SettingsMCPRegistration(id: "claude-code", name: "Claude Code",
                                             hint: claudeCodeReason ?? "已註冊 · 檔案權限過寬，其他帳號讀得到 token",
                                             isOn: true, actionTitle: tightenTitle, actionEnabled: enabled, accent: true,
                                             toolTip: claudeCodeReason)
        case .registered:
            claude = SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: claudeCodeReason ?? "已註冊 · user scope",
                                             isOn: true, actionTitle: "移除", actionEnabled: enabled, toolTip: claudeCodeReason)
        case .notRegistered:
            claude = SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: claudeCodeReason ?? "未註冊", actionTitle: "註冊",
                                             actionEnabled: enabled, accent: true, toolTip: claudeCodeReason)
        case .unknown:
            claude = SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: claudeCodeReason ?? "—", actionTitle: "註冊",
                                             actionEnabled: enabled, accent: true, toolTip: claudeCodeReason)
        case .unavailable(let reason):
            claude = SettingsMCPRegistration(id: "claude-code", name: "Claude Code", hint: claudeCodeReason ?? reason, actionTitle: "註冊",
                                             actionEnabled: enabled, accent: true, toolTip: claudeCodeReason)
        }
        return [claude,
                SettingsMCPRegistration(id: "codex", name: "Codex", hint: "未註冊", actionTitle: "註冊", actionEnabled: codexReason == nil,
                                        accent: true, toolTip: codexReason),
                SettingsMCPRegistration(id: "claude-desktop", name: "Claude Desktop", hint: "未安裝", actionTitle: "安裝 .mcpb",
                                        actionEnabled: false, accent: true, chip: "FUTURE")]
    }

    /// Claude Code's button: `移除` while CODD's entry is there with the current token, else
    /// `註冊` (a rotated token is re-registered in place); `收緊` (`exposed`) is a registration
    /// whose plan only makes the files 0600.
    static func claudeCodeKind(_ state: MCPService.Registration, exposed: Bool = false) -> MCPRegistrationService.Kind {
        if case .registered(let matches) = state, matches != false, !exposed { return .remove }
        return .register
    }
}
