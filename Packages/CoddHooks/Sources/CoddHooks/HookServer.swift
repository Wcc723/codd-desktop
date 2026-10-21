import CoddCore
import Foundation
import Network
import Synchronization

/// One authenticated hook delivery.
public struct HookEvent: Sendable, Equatable {
    /// The CODD session (`X-CODD-Session`), which is the hook record's terminal id.
    public var sessionID: UUID
    public var payload: HookPayload
    /// When the request was complete (before decoding), from the server's clock.
    public var receivedAt: Date

    public init(sessionID: UUID, payload: HookPayload, receivedAt: Date) {
        self.sessionID = sessionID
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

public enum HookServerError: Error, Sendable, Equatable, CustomStringConvertible {
    /// Another process holds 127.0.0.1:`port` (possibly another CODD; see ``HookHealthProbe``).
    case portInUse(UInt16)
    case invalidToken
    case alreadyRunning
    case listenerFailed(String)

    public var description: String {
        switch self {
        case .portInUse(let p): return "port \(p) is in use"
        case .invalidToken: return "the hook token is empty"
        case .alreadyRunning: return "the hook server is already running"
        case .listenerFailed(let s): return "listener failed: \(s)"
        }
    }
}

/// Counters for diagnostics (Settings / Status page, manual acceptance): why hooks are refused.
public struct HookServerStatistics: Sendable, Equatable {
    /// Hooks answered 204 and yielded.
    public var accepted = 0
    /// Status-line reports answered 204, decoded and yielded on ``HookServer/statusLines``.
    public var statusLinesAccepted = 0
    /// Status-line bodies answered 204 that did not decode (not a JSON object, or a `v` other
    /// than 1); nothing was yielded for them.
    public var statusLinesUndecodable = 0
    /// When the most recent status-line report arrived (decoded or not), from the server's clock.
    public var lastStatusLineAt: Date?
    /// Answers other than 204 / 200 / 100, by status code (both routes).
    public var rejected: [Int: Int] = [:]
    /// Connections closed unanswered (over the limit, or not from 127.0.0.0/8).
    public var refusedConnections = 0
    /// The most recent rejection, e.g. `403 Origin header present`. Never contains a token.
    public var lastRejection: String?
    /// M4: authenticated `/mcp` requests whose body arrived (answered by the MCP handler, or 503
    /// without one).
    public var mcpRequests = 0
    /// M4: `/mcp` requests the server refused once their head was routed (401, 403, 405, 408,
    /// 411, a chunked body over 1 MiB). A `Content-Length` over the limit is refused while the
    /// head is parsed and counts only in ``rejected``.
    public var mcpRejected = 0
    /// M4: `/mcp` handlers that missed the deadline (answered 503).
    public var mcpTimedOut = 0
    /// M4: when the last authenticated `/mcp` request arrived, from the server's clock.
    public var lastMCPAt: Date?
    /// M4: `/hooks/prompt` deliveries (also counted in ``accepted``: each was yielded).
    public var promptHooks = 0
    /// M4: prompt hooks answered 200 with the handler's `additionalContext`.
    public var promptAnswered = 0
    /// M4: prompt hooks whose handler missed the deadline (answered 204).
    public var promptLate = 0
    /// M4: note URL requests with a valid token (passed to the note URL handler).
    public var noteURLRequests = 0

    public init() {}
}

public enum HookServerState: Sendable, Equatable {
    case stopped
    case starting(port: UInt16)
    case listening(port: UInt16)
    case failed(HookServerError)
}

/// The hook endpoint: `POST http://127.0.0.1:<port>/hooks`, `POST /statusline` and `GET /health`,
/// and since M4 `POST /mcp`, `POST /hooks/prompt` and `GET /n/<id>.md` (see the README's wire
/// contract).
///
/// Threading: the listener, every connection and all mutable state live on one private serial
/// queue (hence `@unchecked Sendable`; nothing is touched from another thread). Requests are parsed
/// there, answered `204` as soon as the body is complete, then decoded and yielded on ``events``
/// (hooks) or ``statusLines`` (status-line reports) in the order they completed. Because the answer
/// and the yield happen in the same queue block, a client that waited for its `204` (codd-hook,
/// codd-statusline, Claude's http hooks) can never have its next event yielded before this one.
///
/// Security: bound to 127.0.0.1 only (IPv4, loopback interface, local-only acceptance, and every
/// peer checked again to be 127.0.0.0/8); see ``HookRequestPolicy`` for the per-request checks. At
/// most ``Configuration/maxConnections`` connections are open at once; more wait in the kernel's
/// listen backlog (the listener's connection limit) instead of being reset, and are accepted in
/// arrival order as slots free up. Each connection must send its request head within
/// ``Configuration/headTimeout`` and finish within ``Configuration/readTimeout`` of it, so idle
/// sockets (any local account can open them) hold a slot for about a second, not five, and a burst
/// of more hooks than slots is served instead of refused (review SEC-4, E2E-5). Bodies are
/// limited to 1 MiB (`/hooks`) and 64 KiB (`/statusline`).
///
/// Handler routes (M4): the MCP, prompt and note URL handlers run in a `Task` off the queue, with
/// a deadline; the connection keeps its slot and its read / head timers are off meanwhile, the
/// answer is written back on the queue, and a client that closes first only loses the answer (the
/// handler is never cancelled: an MCP append must not stop half way). Handlers are kept across
/// ``stop()`` / ``start()``. `/hooks/prompt` yields its event before the handler runs.
public final class HookServer: @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// 0 picks an ephemeral port (tests).
        public var port: UInt16
        public var token: String
        public var limits: HTTPRequestParser.Limits
        public var readTimeout: Duration
        /// The request line and headers must arrive within this (capped by `readTimeout`).
        public var headTimeout: Duration
        public var maxConnections: Int
        /// After answering, unread input is drained this long before closing, so the client reads
        /// the answer instead of a connection reset.
        public var drainTimeout: Duration
        /// M4: the external MCP token (config.json `mcpToken`); `nil` refuses every external MCP
        /// caller and every note URL. ``HookServer/setMCPToken(_:)`` changes it at run time.
        public var mcpToken: String?
        /// M4 D19: how long the prompt handler may take before `/hooks/prompt` is answered 204.
        public var promptDeadline: Duration
        /// M4: how long the MCP and note URL handlers may take before the answer is 503.
        public var handlerDeadline: Duration
        /// M4: the largest handler response body; a larger one is answered 500.
        public var maxResponseBytes: Int

        public init(port: UInt16, token: String, limits: HTTPRequestParser.Limits = .init(),
                    readTimeout: Duration = .seconds(5), headTimeout: Duration = .seconds(1), maxConnections: Int = 64,
                    drainTimeout: Duration = .seconds(1), mcpToken: String? = nil,
                    promptDeadline: Duration = .milliseconds(1500), handlerDeadline: Duration = .seconds(10),
                    maxResponseBytes: Int = 16 << 20) {
            self.port = port
            self.token = token
            self.limits = limits
            self.readTimeout = readTimeout
            self.headTimeout = headTimeout
            self.maxConnections = maxConnections
            self.drainTimeout = drainTimeout
            self.mcpToken = mcpToken
            self.promptDeadline = promptDeadline
            self.handlerDeadline = handlerDeadline
            self.maxResponseBytes = maxResponseBytes
        }

        /// Port, hook token and (M4) MCP token of `config`.
        public init(config: HookConfig) {
            self.init(port: config.port, token: config.token, mcpToken: config.mcpToken)
        }
    }

    /// `POST /mcp` (M4 D16): the caller and the request; the answer goes back as is.
    public typealias MCPHandler = @Sendable (MCPRouteCaller, HTTPRouteRequest) async -> HTTPRouteResponse
    /// `POST /hooks/prompt` (M4 D19): the CODD session and the payload (already yielded on
    /// ``events``); `nil` = answer 204.
    public typealias PromptHandler = @Sendable (UUID, HookPayload) async -> PromptHookAnswer?
    /// `GET /n/<id>.md` (M4 D15), token already checked: the note id; the answer goes back as is.
    public typealias NoteURLHandler = @Sendable (String) async -> HTTPRouteResponse

    /// Payload keys dropped before yielding (skipped without being decoded): `tool_response`
    /// (PostToolUse) can be megabytes, and nothing in CODD's state model reads it.
    public static let droppedPayloadKeys: Set<String> = ["tool_response"]

    /// Every accepted hook, for the server's whole lifetime (across restarts). Single consumer.
    /// Buffers the newest 1024 events if the consumer stalls.
    public let events: AsyncStream<HookEvent>
    private let continuation: AsyncStream<HookEvent>.Continuation
    /// Every decoded status-line report, for the server's whole lifetime. Single consumer.
    /// Buffers the newest 256 reports (each run supersedes the previous one of its account anyway).
    public let statusLines: AsyncStream<StatusLineReport>
    private let statusLineContinuation: AsyncStream<StatusLineReport>.Continuation
    private let queue = DispatchQueue(label: "app.codd.hooks.server", qos: .userInitiated)
    private let clock: any HookClock
    private let published = Mutex<HookServerState>(.stopped)

    // Queue-confined.
    private var configuration: Configuration
    private var listener: NWListener?
    private var policy: HookRequestPolicy?
    private var pendingStart: CheckedContinuation<Result<UInt16, HookServerError>, Never>?
    /// Invalidates bind retries scheduled by an earlier start (after a stop).
    private var bindGeneration = 0
    private var connections: [ObjectIdentifier: HookConnection] = [:]
    private var stats = HookServerStatistics()
    private var mcpHandler: MCPHandler?
    private var promptHandler: PromptHandler?
    private var noteURLHandler: NoteURLHandler?

    public init(configuration: Configuration, clock: any HookClock = SystemHookClock()) {
        self.configuration = configuration
        self.clock = clock
        (events, continuation) = AsyncStream.makeStream(of: HookEvent.self, bufferingPolicy: .bufferingNewest(1024))
        (statusLines, statusLineContinuation) = AsyncStream.makeStream(of: StatusLineReport.self,
                                                                       bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        // Nothing else references the server now (queue blocks hold it weakly or retain it), so
        // touching the queue-confined state here is safe; NW objects may be cancelled from any thread.
        listener?.cancel()
        for connection in connections.values { connection.connection.cancel() }
        continuation.finish()
        statusLineContinuation.finish()
    }

    public var state: HookServerState { published.withLock { $0 } }

    /// The bound port while listening.
    public var port: UInt16? {
        if case .listening(let p) = state { return p }
        return nil
    }

    /// Accepted / rejected counters since the server was created.
    public func statistics() async -> HookServerStatistics {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.stats) } }
    }

    /// Open connections (tests and diagnostics).
    public func connectionCount() async -> Int {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.connections.count) } }
    }

    /// Binds and starts listening; returns the bound port.
    @discardableResult
    public func start() async throws(HookServerError) -> UInt16 {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Result<UInt16, HookServerError>, Never>) in
            queue.async { self.startOnQueue(c) }
        }
        return try result.get()
    }

    /// Stops listening and closes every connection. Waits until the port is released.
    public func stop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async { self.stopOnQueue(then: c) }
        }
    }

    /// ``stop()`` then ``start()``, optionally with a new port or token.
    @discardableResult
    public func restart(port: UInt16? = nil, token: String? = nil) async throws(HookServerError) -> UInt16 {
        await stop()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if let port { self.configuration.port = port }
                if let token { self.configuration.token = token }
                c.resume()
            }
        }
        return try await start()
    }

    /// M4: answers authenticated `POST /mcp` requests (`nil`: 503 with a JSON-RPC error).
    public func setMCPHandler(_ handler: MCPHandler?) async {
        await onQueue { self.mcpHandler = handler }
    }

    /// M4: expands `/hooks/prompt` payloads (`nil`: every prompt hook is answered 204).
    public func setPromptHandler(_ handler: PromptHandler?) async {
        await onQueue { self.promptHandler = handler }
    }

    /// M4: answers note URLs whose token is right (`nil`: 404).
    public func setNoteURLHandler(_ handler: NoteURLHandler?) async {
        await onQueue { self.noteURLHandler = handler }
    }

    /// M4 D23: the external MCP token for requests that arrive from now on (after a rotation);
    /// `nil` refuses every external MCP caller and every note URL.
    public func setMCPToken(_ token: String?) async {
        await onQueue {
            self.configuration.mcpToken = token
            self.policy?.mcpToken = token
        }
    }

    private func onQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                body()
                c.resume()
            }
        }
    }

    /// Ends ``events`` and ``statusLines`` (after the last connection was processed). The server
    /// cannot yield again.
    public func finish() async {
        await stop()
        continuation.finish()
        statusLineContinuation.finish()
    }

    // MARK: - Listener (queue)

    private func setState(_ s: HookServerState) {
        published.withLock { $0 = s }
    }

    /// Delays before the second and third bind attempt when the port is busy. Under load,
    /// Network.framework occasionally reports EADDRINUSE for a port that was released a moment
    /// earlier (measured in tests: free again within milliseconds, with nothing holding it), and a
    /// relaunched CODD can race the previous instance's shutdown, so a busy port is only reported
    /// after three attempts (about 200 ms).
    static let bindRetryDelays: [Double] = [0.05, 0.15]

    private func startOnQueue(_ c: CheckedContinuation<Result<UInt16, HookServerError>, Never>) {
        guard listener == nil, pendingStart == nil else { return c.resume(returning: .failure(.alreadyRunning)) }
        guard !configuration.token.isEmpty else {
            setState(.failed(.invalidToken))
            return c.resume(returning: .failure(.invalidToken))
        }
        pendingStart = c
        bindGeneration += 1
        bind(attempt: 0, generation: bindGeneration)
    }

    private func bind(attempt: Int, generation: Int) {
        guard generation == bindGeneration, pendingStart != nil, listener == nil else { return }
        let requested = configuration.port
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requested) ?? .any)
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options { tcp.noDelay = true }
        let l: NWListener
        do {
            l = try NWListener(using: parameters)
        } catch {
            return finishStart(.failure(Self.map(error, port: requested)))
        }
        listener = l
        // Past the limit, connections wait in the backlog (raised again as connections close).
        l.newConnectionLimit = max(1, configuration.maxConnections)
        setState(.starting(port: requested))
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            self.listenerStateChanged(l, state, requested: requested, attempt: attempt, generation: generation)
        }
        l.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        l.start(queue: queue)
    }

    private func finishStart(_ result: Result<UInt16, HookServerError>) {
        switch result {
        case .success(let port): setState(.listening(port: port))
        case .failure(let e): setState(.failed(e))
        }
        pendingStart?.resume(returning: result)
        pendingStart = nil
    }

    private func listenerStateChanged(_ l: NWListener, _ state: NWListener.State, requested: UInt16,
                                      attempt: Int, generation: Int) {
        guard l === listener else { return }
        switch state {
        case .ready:
            let port = l.port?.rawValue ?? requested
            policy = HookRequestPolicy(token: configuration.token, port: port, mcpToken: configuration.mcpToken)
            finishStart(.success(port))
        case .failed(let error), .waiting(let error):
            // A listener that cannot bind reports it here (EADDRINUSE). In `.waiting` it would keep
            // retrying the bind in the background, so it is cancelled, and the next attempt (or the
            // failure) happens only once it is fully cancelled: an abandoned listener must not be
            // able to grab the port the moment it frees up.
            let e = Self.map(error, port: requested)
            listener = nil
            policy = nil
            l.newConnectionHandler = nil
            let retryDelay = e == .portInUse(requested) && attempt < Self.bindRetryDelays.count
                ? Self.bindRetryDelays[attempt] : nil
            cancelAndWait(l) { [weak self] in
                guard let self, generation == self.bindGeneration else { return }
                if let retryDelay {
                    self.queue.asyncAfter(deadline: .now() + retryDelay) {
                        self.bind(attempt: attempt + 1, generation: generation)
                    }
                } else {
                    self.finishStart(.failure(e))
                }
            }
        case .cancelled, .setup:
            break
        @unknown default:
            break
        }
    }

    private func stopOnQueue(then c: CheckedContinuation<Void, Never>) {
        for connection in connections.values { connection.close() }
        connections.removeAll()
        policy = nil
        bindGeneration += 1
        pendingStart?.resume(returning: .failure(.listenerFailed("stopped while starting")))
        pendingStart = nil
        guard let l = listener else {
            if case .failed = state {} else { setState(.stopped) }
            return c.resume()
        }
        listener = nil
        setState(.stopped)
        l.newConnectionHandler = nil
        cancelAndWait(l) { c.resume() }
    }

    /// Cancels `l` and runs `done` once it reports `.cancelled` (its socket is closed), or after
    /// 1 s at the latest.
    private func cancelAndWait(_ l: NWListener, then done: @escaping @Sendable () -> Void) {
        let once = Once()
        l.stateUpdateHandler = { state in
            if case .cancelled = state, once.claim() { done() }
        }
        l.cancel()
        queue.asyncAfter(deadline: .now() + 1) {
            if once.claim() { done() }
        }
    }

    static func map(_ error: any Error, port: UInt16) -> HookServerError {
        if let nw = error as? NWError, case .posix(let code) = nw, code == .EADDRINUSE {
            return .portInUse(port)
        }
        return .listenerFailed(String(describing: error))
    }

    // MARK: - Connections (queue)

    private func accept(_ connection: NWConnection) {
        defer { updateConnectionLimit() }
        guard let policy, connections.count < configuration.maxConnections, Self.isLoopbackPeer(connection.endpoint) else {
            stats.refusedConnections += 1
            connection.cancel()
            return
        }
        let handler = HookConnection(
            connection: connection, queue: queue, policy: policy, limits: configuration.limits,
            readTimeout: configuration.readTimeout, headTimeout: min(configuration.headTimeout, configuration.readTimeout),
            drainTimeout: configuration.drainTimeout, maxResponseBytes: configuration.maxResponseBytes)
        let key = ObjectIdentifier(handler)
        handler.onHook = { [weak self] sessionID, body in
            self?.deliver(sessionID: sessionID, body: body)
        }
        handler.onStatusLine = { [weak self] sessionID, body in
            self?.deliverStatusLine(sessionID: sessionID, body: body)
        }
        handler.onClose = { [weak self] in
            self?.connections[key] = nil
            self?.updateConnectionLimit()
        }
        handler.onReject = { [weak self] status, reason, path in
            guard let self else { return }
            self.stats.rejected[status.rawValue, default: 0] += 1
            self.stats.lastRejection = "\(status.rawValue) \(reason)"
            if path == HookRequestPolicy.mcpPath { self.stats.mcpRejected += 1 }
        }
        handler.onHandlerRoute = { [weak self, weak handler] route, head, body in
            guard let self, let handler else { return }
            self.dispatch(route, head: head, body: body, on: handler)
        }
        connections[key] = handler
        handler.start()
    }

    /// The listener delivers as many new connections as there are free slots; the rest wait.
    private func updateConnectionLimit() {
        listener?.newConnectionLimit = max(0, configuration.maxConnections - connections.count)
    }

    /// Called right after the `204` was handed to the connection.
    private func deliver(sessionID: UUID, body: [UInt8]) {
        let receivedAt = clock.now()
        stats.accepted += 1
        // Bounded nesting and `tool_response` skipped unparsed: this runs on a dispatch worker
        // thread, whose stack a deeply nested body would otherwise overflow.
        let payload = HookPayload(body: Data(body), droppingKeys: Self.droppedPayloadKeys)
        continuation.yield(HookEvent(sessionID: sessionID, payload: payload, receivedAt: receivedAt))
    }

    /// Called right after the `204` was handed to the connection. The body is at most 64 KiB and
    /// decoded by `JSONScan`, which validates without recursion.
    private func deliverStatusLine(sessionID: UUID?, body: [UInt8]) {
        let receivedAt = clock.now()
        stats.lastStatusLineAt = receivedAt
        guard let report = StatusLineReport.decode(body: body, sessionID: sessionID, receivedAt: receivedAt) else {
            stats.statusLinesUndecodable += 1
            return
        }
        stats.statusLinesAccepted += 1
        statusLineContinuation.yield(report)
    }

    // MARK: - Handler routes (queue)

    /// The `/mcp` answer while no MCP handler is installed.
    static let mcpUnavailableBody = Array(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"CODD MCP server is not available"}}"#.utf8)
    /// The `/mcp` answer when the handler misses the deadline (-32001: request timed out).
    static let mcpTimeoutBody = Array(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"CODD MCP request timed out"}}"#.utf8)

    /// A request of a handler route is complete (its body read): runs the handler.
    private func dispatch(_ route: HookRoute, head: HTTPRequestHead, body: [UInt8], on connection: HookConnection) {
        switch route {
        case .promptHook(let sessionID):
            let receivedAt = clock.now()
            stats.accepted += 1
            stats.promptHooks += 1
            let payload = HookPayload(body: Data(body), droppingKeys: Self.droppedPayloadKeys)
            // Yielded first, in the same queue block as any other hook, so states and the last
            // prompt update exactly as on `/hooks`; the answer follows the expansion.
            continuation.yield(HookEvent(sessionID: sessionID, payload: payload, receivedAt: receivedAt))
            guard let handler = promptHandler else { return connection.respond(.empty(.noContent)) }
            connection.awaitHandler(deadline: configuration.promptDeadline, work: {
                guard let answer = await handler(sessionID, payload) else { return .status(204) }
                return .json(answer.jsonBody())
            }, finish: { [weak self] response in
                guard let response else {
                    self?.stats.promptLate += 1
                    return .status(204)
                }
                if response.status == 200 { self?.stats.promptAnswered += 1 }
                return response
            })

        case .mcp(let caller):
            stats.mcpRequests += 1
            stats.lastMCPAt = clock.now()
            guard let handler = mcpHandler else {
                return connection.respond(route: .json(Self.mcpUnavailableBody, status: 503))
            }
            let request = Self.routeRequest(head, body: body)
            let deadline = configuration.handlerDeadline
            connection.awaitHandler(deadline: deadline, work: { await handler(caller, request) }, finish: { [weak self] response in
                if let response { return response }
                self?.noteTimeout("MCP handler over \(Self.milliseconds(deadline)) ms", mcp: true)
                return .json(Self.mcpTimeoutBody, status: 503)
            })

        case .noteURL(let id, _):
            stats.noteURLRequests += 1
            guard let handler = noteURLHandler else { return connection.respond(.empty(.notFound)) }
            let deadline = configuration.handlerDeadline
            connection.awaitHandler(deadline: deadline, work: { await handler(id) }, finish: { [weak self] response in
                if let response { return response }
                self?.noteTimeout("note URL handler over \(Self.milliseconds(deadline)) ms", mcp: false)
                return .status(503)
            })

        case .hook, .statusLine, .health, .reject:
            connection.respond(.empty(.badRequest))
        }
    }

    private func noteTimeout(_ reason: String, mcp: Bool) {
        stats.rejected[HTTPStatus.serviceUnavailable.rawValue, default: 0] += 1
        stats.lastRejection = "503 \(reason)"
        if mcp { stats.mcpTimedOut += 1 }
    }

    static func routeRequest(_ head: HTTPRequestHead, body: [UInt8]) -> HTTPRouteRequest {
        HTTPRouteRequest(method: head.method, path: head.path, query: HookRequestPolicy.query(head.target),
                         headers: head.headers.fields.map { (name: $0.name, value: $0.value) }, body: body)
    }

    static func milliseconds(_ d: Duration) -> Int64 {
        let c = d.components
        return c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
    }

    /// 127.0.0.0/8 only. The listener is already bound to 127.0.0.1 on the loopback interface;
    /// this is the second, independent check the security model asks for.
    static func isLoopbackPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return false }
        return address.rawValue.first == 127
    }
}

/// A one-shot flag usable from `@Sendable` closures.
final class Once: Sendable {
    private let done = Mutex(false)

    /// `true` exactly once.
    func claim() -> Bool {
        done.withLock { d in
            if d { return false }
            d = true
            return true
        }
    }
}

/// One accepted connection: parse one request, answer, drain, close. Confined to the server queue.
final class HookConnection: @unchecked Sendable {
    let connection: NWConnection
    let queue: DispatchQueue
    let policy: HookRequestPolicy
    let readTimeout: Duration
    let headTimeout: Duration
    let drainTimeout: Duration
    let maxResponseBytes: Int
    var onHook: ((UUID, [UInt8]) -> Void)?
    var onStatusLine: ((UUID?, [UInt8]) -> Void)?
    var onClose: (() -> Void)?
    /// Status, reason, and the request path when the head was known.
    var onReject: ((HTTPStatus, String, String?) -> Void)?
    /// M4: a complete request of a handler route (`/mcp`, `/hooks/prompt`, `/n/…`).
    var onHandlerRoute: ((HookRoute, HTTPRequestHead, [UInt8]) -> Void)?

    private var parser: HTTPRequestParser
    private var route: HookRoute?
    private var head: HTTPRequestHead?
    private var healthChallenge: String?
    private var responded = false
    private var answerSent = false
    private var peerFinished = false
    private var closed = false
    private var drained = 0
    private var timer: DispatchWorkItem?
    /// A handler runs for the complete request; its answer (or the deadline's) is still to come.
    private var awaiting = false
    /// Turns the handler's result (`nil` = the deadline passed first) into the answer; consumed by
    /// whichever comes first.
    private var pendingFinish: ((HTTPRouteResponse?) -> HTTPRouteResponse)?

    init(connection: NWConnection, queue: DispatchQueue, policy: HookRequestPolicy, limits: HTTPRequestParser.Limits,
         readTimeout: Duration, headTimeout: Duration, drainTimeout: Duration, maxResponseBytes: Int = 16 << 20) {
        self.connection = connection
        self.queue = queue
        self.policy = policy
        self.readTimeout = readTimeout
        self.headTimeout = headTimeout
        self.drainTimeout = drainTimeout
        self.maxResponseBytes = maxResponseBytes
        parser = HTTPRequestParser(limits: limits)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
        arm(after: headTimeout) { [weak self] in
            guard let self, !self.responded else { return }
            self.onReject?(.requestTimeout, "request head not complete in time", nil)
            // Nothing worth draining from a client that has not even sent a head: free the slot.
            self.respond(.empty(.requestTimeout), drainFor: Self.idleDrain)
        }
        receive()
    }

    /// The head arrived: the rest of the request gets `readTimeout`.
    private func headReceived() {
        arm(after: readTimeout) { [weak self] in
            guard let self, !self.responded, !self.awaiting else { return }
            self.onReject?(.requestTimeout, "request not complete in time", self.head?.path)
            self.respond(.empty(.requestTimeout))
        }
    }

    private func arm(after delay: Duration, _ body: @escaping @Sendable () -> Void) {
        timer?.cancel()
        let item = DispatchWorkItem(block: body)
        timer = item
        let c = delay.components
        let nanos = Int(c.seconds) * 1_000_000_000 + Int(c.attoseconds / 1_000_000_000)
        queue.asyncAfter(deadline: .now() + .nanoseconds(nanos), execute: item)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if self.responded || self.awaiting {
                self.drained += data?.count ?? 0
            } else if let data, !data.isEmpty {
                self.parser.append(data)
                self.process()
                if self.closed { return }
            }
            let ended = isComplete || error != nil
            guard self.responded || self.awaiting else {
                // The client gave up before a complete request.
                return ended ? self.close() : self.receive()
            }
            // Draining after the answer (or while a handler runs): discard input until the client
            // closes (then close once the answer is flushed), 2 MiB, or the drain timer. A client
            // that half-closes while its handler runs still gets the answer.
            if ended {
                self.peerFinished = true
                return self.closeIfFinished()
            }
            if self.drained > 2 << 20 { return self.close() }
            self.receive()
        }
    }

    private func closeIfFinished() {
        if peerFinished, answerSent { close() }
    }

    private func process() {
        do {
            while let event = try parser.next() {
                switch event {
                case .head(let head):
                    self.head = head
                    headReceived()
                    let r = policy.route(head)
                    switch r {
                    case .reject(let status):
                        onReject?(status, policy.rejectionReason(status, head), head.path)
                        let allow = status == .methodNotAllowed ? HookRequestPolicy.allowedMethods(for: head.path) : nil
                        return respond(.empty(status, headers: allow.map { [HTTPField(name: "Allow", value: $0)] } ?? []))
                    case .hook, .statusLine, .mcp, .promptHook:
                        route = r
                        if case .statusLine = r { parser.limitBody(to: HookRequestPolicy.statusLineMaxBodyBytes) }
                        if head.expectsContinue {
                            connection.send(content: HTTPResponse.empty(.continue).serialized(), completion: .idempotent)
                        }
                    case .health:
                        route = r
                        healthChallenge = head.headers.single(HookRequestPolicy.challengeHeader)
                    case .noteURL:
                        route = r
                    }
                case .body(let body):
                    switch route {
                    case .hook(let sessionID)?:
                        respond(.empty(.noContent))
                        onHook?(sessionID, body)
                    case .statusLine(let sessionID)?:
                        respond(.empty(.noContent))
                        onStatusLine?(sessionID, body)
                    case .health(let headOnly)?:
                        respond(HTTPResponse(status: .ok, headers: [HTTPField(name: "Content-Type", value: "application/json")],
                                             body: policy.healthBody(challenge: healthChallenge)), omitBody: headOnly)
                    case .mcp?, .promptHook?, .noteURL?:
                        guard let route, let head, let onHandlerRoute else { return respond(.empty(.serviceUnavailable)) }
                        onHandlerRoute(route, head, body)
                    case .reject?, nil:
                        respond(.empty(.badRequest))
                    }
                    return
                }
            }
        } catch {
            onReject?(error.status, error.reason, head?.path)
            respond(.empty(error.status))
        }
    }

    /// Runs `work` in a `Task` off the queue and answers with `finish(result)`, or with
    /// `finish(nil)` once `deadline` passes first (whichever comes first wins; the other is
    /// dropped). The read / head timers are replaced by the deadline, so they cannot fire meanwhile.
    func awaitHandler(deadline: Duration, work: @escaping @Sendable () async -> HTTPRouteResponse,
                      finish: @escaping (HTTPRouteResponse?) -> HTTPRouteResponse) {
        guard !responded, !closed, !awaiting else { return }
        awaiting = true
        pendingFinish = finish
        arm(after: deadline) { [weak self] in self?.handlerFinished(nil) }
        let queue = queue
        Task { [weak self] in
            let response = await work()
            guard let self else { return }
            queue.async { self.handlerFinished(response) }
        }
    }

    private func handlerFinished(_ response: HTTPRouteResponse?) {
        guard let finish = pendingFinish, !closed else { return }
        pendingFinish = nil
        respond(route: finish(response))
    }

    /// Drain after a head timeout (instead of `drainTimeout`).
    static let idleDrain: Duration = .milliseconds(100)

    func respond(_ response: HTTPResponse, omitBody: Bool = false, drainFor drain: Duration? = nil) {
        sendFinal(response.serialized(omitBody: omitBody), drainFor: drain)
    }

    /// A handler's answer (`HEAD` is never routed to a handler, so the body is always sent).
    func respond(route response: HTTPRouteResponse) {
        if response.body.count > maxResponseBytes {
            onReject?(.internalServerError, "handler response over \(maxResponseBytes) bytes", nil)
        }
        sendFinal(response.serialized(maxBodyBytes: maxResponseBytes), drainFor: nil)
    }

    private func sendFinal(_ bytes: [UInt8], drainFor drain: Duration?) {
        guard !responded, !closed else { return }
        responded = true
        pendingFinish = nil
        arm(after: drain ?? drainTimeout) { [weak self] in self?.close() }
        connection.send(content: bytes, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in
                            guard let self else { return }
                            self.answerSent = true
                            self.closeIfFinished()
                        })
    }

    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        pendingFinish = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        let done = onClose
        onClose = nil
        onHook = nil
        onStatusLine = nil
        onReject = nil
        onHandlerRoute = nil
        done?()
    }
}
