import Foundation

extension MCPServer {
    /// `tools/call`. Bad `params` (no name, `arguments` not an object, an unknown tool) are
    /// JSON-RPC `-32602`; everything about the tool's own arguments and the backend's answer is a
    /// tool result, `isError: true` when it failed, so the model sees the reason.
    func callTool(_ params: JSONObject, _ context: RequestContext) async -> Result<JSON, RPCError> {
        guard case .string(let name)? = params["name"] else {
            return .failure(.invalidParams("tools/call needs params.name (a string)"))
        }
        let arguments: JSONObject
        switch params["arguments"] {
        case nil, .null?: arguments = JSONObject()
        case .object(let object)?: arguments = object
        default: return .failure(.invalidParams("params.arguments must be an object"))
        }
        guard let tool = MCPTool(rawValue: name) else {
            return .failure(.invalidParams("Unknown tool: \(MCPText.clip(name, 100))"))
        }
        let start = ContinuousClock.now
        let (result, outcome) = await run(tool, ToolArguments(object: arguments), context)
        emit(.tool(caller: context.caller, name: tool.rawValue, outcome: outcome,
                   ms: Self.milliseconds(since: start), at: clock()))
        return .success(result.json)
    }

    private func run(_ tool: MCPTool, _ arguments: ToolArguments, _ context: RequestContext) async
        -> (ToolResult, MCPToolOutcome)
    {
        let output = ToolOutput(dates: dates, now: clock())
        let structured = MCPVersion.hasStructuredOutput(context.protocolVersion)
        let caller = context.caller
        do {
            let result: ToolResult
            switch tool {
            case .search:
                let request = try ToolRequests.search(arguments)
                let hits = try await backend.search(request, caller: caller)
                let shown = request.query.isEmpty ? "" : "「\(MCPText.clip(request.query, 100))」"
                result = output.hits(Array(hits.prefix(request.limit)), empty: "找不到符合\(shown)的筆記。",
                                     structured: structured)
            case .list:
                let request = try ToolRequests.list(arguments)
                let hits = try await backend.list(request, caller: caller)
                result = output.hits(Array(hits.prefix(request.limit)), empty: "沒有符合條件的筆記。",
                                     structured: structured)
            case .read:
                let request = try ToolRequests.read(arguments)
                result = output.note(try await backend.read(request, caller: caller), request: request)
            case .append:
                let request = try ToolRequests.append(arguments)
                result = output.written(try await backend.append(request, caller: caller), verb: "已附加到")
            case .create:
                let request = try ToolRequests.create(arguments)
                let created = try await backend.create(request, caller: caller)
                // Client-chosen text again (the title): clipped before it reaches the app's toast.
                emit(.created(caller: caller, id: MCPText.clip(created.id, 100), uri: MCPText.clip(created.uri, 200),
                              title: MCPText.clip(created.title, MCPLimits.createTitleMaxCharacters), at: clock()))
                result = output.created(created)
            case .write:
                // A client may still hold a tools/list from while AI 可寫入 was ON.
                guard await backend.capabilities(caller: caller).writeEnabled else {
                    let text = "notes_write 未開啟：使用者需要在 CODD 設定 › 筆記本 & MCP 打開「AI 可寫入」。"
                        + "可以改用 notes_append。"
                    return (.error(text), .isError(text))
                }
                let request = try ToolRequests.write(arguments)
                result = output.written(try await backend.write(request, caller: caller), verb: "已改寫")
            }
            return (result, .ok)
        } catch let error as ToolArgumentError {
            return (.error(error.message), .isError(error.message))
        } catch let error as MCPBackendError {
            let text = error.message(timeZone: timeZone)
            return (.error(text), .isError(text))
        } catch {
            let text = "CODD 處理這個請求時發生內部錯誤，請稍後再試。"
            return (.error(text), .failed(String(describing: type(of: error))))
        }
    }
}
