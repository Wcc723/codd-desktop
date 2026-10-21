import Foundation

/// CODD's MCP server: one HTTP request in, one HTTP response out (Streamable HTTP, JSON replies
/// only). The hook server (C3) frames and authenticates `POST /mcp` and calls ``handle(_:)``.
///
/// Stateless (D16): no `Mcp-Session-Id`, no per-client state; every request stands alone, so an
/// app relaunch or a port rebind never breaks a connected client. The protocol version of a
/// request is its `MCP-Protocol-Version` header, else `2025-03-26` (the spec's default);
/// `outputSchema` / `structuredContent` appear only for 2025-06-18 and later.
///
/// `server/discover` (the 2026-07-28 probe Claude Code sends first) is answered `-32601`, which
/// makes Claude fall back to the `initialize` handshake. The probe and the handshake are never
/// refused for their version header, so a newer client can always fall back.
///
/// Thread safety: every stored property is immutable and `Sendable`; ``handle(_:)`` may run for
/// many requests at once. The backend is awaited off the caller's actor.
public final class MCPServer: Sendable {
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    /// Answered to an `initialize` asking for a version not in ``supportedProtocolVersions``.
    public static let latestProtocolVersion = "2025-11-25"
    /// The version of a request without an `MCP-Protocol-Version` header (spec default).
    public static let defaultProtocolVersion = "2025-03-26"

    public let info: MCPServerInfo
    /// Single consumer; the newest 512 events are buffered.
    public let events: AsyncStream<MCPEvent>

    let backend: any MCPNotesBackend
    let clock: @Sendable () -> Date
    let timeZone: TimeZone
    let dates: MCPDateText
    private let continuation: AsyncStream<MCPEvent>.Continuation

    /// `timeZone` formats dates in tool text (`updated 10/15 10:05`, RFC 3339 offsets, the purge
    /// day); an addition to the brief's signature, defaulted so `init(info:backend:clock:)` works.
    public init(info: MCPServerInfo, backend: any MCPNotesBackend,
                clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current)
    {
        self.info = info
        self.backend = backend
        self.clock = clock
        self.timeZone = timeZone
        self.dates = MCPDateText(timeZone: timeZone)
        (events, continuation) = AsyncStream.makeStream(of: MCPEvent.self, bufferingPolicy: .bufferingNewest(512))
    }

    deinit { continuation.finish() }

    func emit(_ event: MCPEvent) { continuation.yield(event) }

    /// Methods the version header never blocks: the probe and the legacy handshake (§3.10).
    static let versionExempt: Set<String> = ["initialize", "server/discover", "notifications/initialized"]

    public func handle(_ request: MCPHTTPRequest) async -> MCPHTTPResponse {
        guard request.method.uppercased() == "POST" else { return .methodNotAllowed }

        let body: JSON
        do {
            body = try JSONParser.parse(request.body)
        } catch {
            return .json(400, JSONRPCReply.error(id: .null, RPCError(code: RPCError.parseErrorCode,
                                                                     message: "Parse error: \(error)")))
        }

        let header = request.header("MCP-Protocol-Version")
        let headerSupported = header.map { Self.supportedProtocolVersions.contains($0) } ?? true
        let context = RequestContext(caller: request.caller,
                                     protocolVersion: (headerSupported ? header : nil) ?? Self.defaultProtocolVersion)
        func blockedByVersion(_ message: JSONRPCMessage) -> Bool {
            guard !headerSupported, let method = message.method else { return false }
            return !Self.versionExempt.contains(method)
        }
        func versionRefusal(id: JSON) -> MCPHTTPResponse {
            let supported = Self.supportedProtocolVersions.joined(separator: ", ")
            return .json(400, JSONRPCReply.error(id: id, .invalidRequest(
                "Bad Request: unsupported MCP-Protocol-Version \(MCPText.clip(header ?? "", 40)) (supported: \(supported))")))
        }

        if case .array(let items) = body {
            guard !items.isEmpty else {
                return .json(400, JSONRPCReply.error(id: .null, .invalidRequest("Invalid Request: empty batch")))
            }
            let messages = items.map(JSONRPCMessage.classify)
            if messages.contains(where: blockedByVersion) { return versionRefusal(id: .null) }
            var replies: [JSON] = []
            for message in messages {
                if let reply = await process(message, context) { replies.append(reply) }
            }
            return replies.isEmpty ? .accepted : .json(200, .array(replies))
        }

        let message = JSONRPCMessage.classify(body)
        if case .invalid(let id, let reason) = message {
            return .json(400, JSONRPCReply.error(id: id, .invalidRequest(reason)))
        }
        if blockedByVersion(message) {
            if case .request(let id, _, _) = message { return versionRefusal(id: id) }
            return versionRefusal(id: .null)
        }
        guard let reply = await process(message, context) else { return .accepted }
        return .json(200, reply)
    }

    struct RequestContext: Sendable {
        var caller: MCPCaller
        /// The request's protocol version (validated header or the default).
        var protocolVersion: String
    }

    /// One message → its reply, or nil for notifications and responses.
    private func process(_ message: JSONRPCMessage, _ context: RequestContext) async -> JSON? {
        switch message {
        case .response:
            return nil
        case .invalid(let id, let reason):
            return JSONRPCReply.error(id: id, .invalidRequest(reason))
        case .notification(let method, _):
            emit(.request(caller: context.caller, method: MCPText.clip(method, 100), at: clock()))
            return nil
        case .request(let id, let method, let rawParams):
            emit(.request(caller: context.caller, method: MCPText.clip(method, 100), at: clock()))
            let params: JSONObject
            switch rawParams {
            case nil, .null?: params = JSONObject()
            case .object(let object)?: params = object
            default: return JSONRPCReply.error(id: id, .invalidParams("params must be an object"))
            }
            switch await dispatch(method, params, context) {
            case .success(let result): return JSONRPCReply.result(id: id, result)
            case .failure(let error): return JSONRPCReply.error(id: id, error)
            }
        }
    }

    private func dispatch(_ method: String, _ params: JSONObject, _ context: RequestContext) async
        -> Result<JSON, RPCError>
    {
        switch method {
        case "initialize": return initialize(params, context)
        case "ping": return .success(.object(JSONObject()))
        case "tools/list":
            let capabilities = await backend.capabilities(caller: context.caller)
            let tools = ToolCatalog.definitions(writeEnabled: capabilities.writeEnabled,
                                                protocolVersion: context.protocolVersion)
            return .success(["tools": .array(tools)])
        case "tools/call": return await callTool(params, context)
        case "resources/list": return await listResources(context)
        case "resources/templates/list": return .success(["resourceTemplates": [Self.noteTemplate]])
        case "resources/read": return await readResource(params, context)
        case "prompts/list": return .success(["prompts": [Self.notePrompt]])
        case "prompts/get": return await getPrompt(params, context)
        // Everything else, server/discover included (the probe's legacy verdict, §1).
        default: return .failure(.methodNotFound(method))
        }
    }

    private func initialize(_ params: JSONObject, _ context: RequestContext) -> Result<JSON, RPCError> {
        let version: String
        switch params["protocolVersion"] {
        case .string(let requested)?:
            version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.latestProtocolVersion
        case nil, .null?:
            version = Self.latestProtocolVersion
        default:
            return .failure(.invalidParams("protocolVersion must be a string"))
        }
        let clientInfo = params["clientInfo"]?.object
        // Client-chosen strings are clipped before they reach the app's logs and STATUS.
        emit(.initialized(caller: context.caller, clientName: clientInfo?["name"]?.string.map { MCPText.clip($0, 200) },
                          clientVersion: clientInfo?["version"]?.string.map { MCPText.clip($0, 100) },
                          protocolVersion: version, at: clock()))
        return .success(initializeResult(version: version))
    }

    func initializeResult(version: String) -> JSON {
        var result: JSONObject = [
            "protocolVersion": .string(version),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["listChanged": false],
                "prompts": ["listChanged": false],
            ],
            "serverInfo": ["name": .string(info.name), "title": .string(info.title), "version": .string(info.version)],
        ]
        // Claude Code keeps only the first 4,096 characters; never send more than it reads.
        if !info.instructions.isEmpty { result["instructions"] = .string(String(info.instructions.prefix(4096))) }
        return .object(result)
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }
}
