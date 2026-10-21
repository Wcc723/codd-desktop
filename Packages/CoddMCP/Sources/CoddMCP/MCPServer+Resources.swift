import Foundation

extension MCPServer {
    static let noteTemplate: JSON = [
        "uriTemplate": "codd://note/{id}",
        "name": "note",
        "title": "CODD note",
        "description": "A CODD note by id: its Markdown (often 繁體中文) with absolute image paths and annotations.",
        "mimeType": "text/markdown",
    ]

    static let notePrompt: JSON = [
        "name": "note",
        "title": "CODD note",
        "description": "Insert a CODD note (its text, image paths and annotations) into the conversation.",
        "arguments": [
            ["name": "id", "description": "The note id (rwd-punch-k7x2) or codd://note/<id>.", "required": true],
        ],
    ]

    func listResources(_ context: RequestContext) async -> Result<JSON, RPCError> {
        do {
            let entries = try await backend.resources(caller: context.caller).prefix(MCPLimits.maxResources)
            let resources: [JSON] = entries.map { entry in
                var object: JSONObject = [
                    "uri": .string(entry.uri), "name": .string(entry.name), "mimeType": .string(entry.mimeType),
                ]
                if let modified = entry.lastModified {
                    object["annotations"] = ["lastModified": .string(dates.iso(modified))]
                }
                return .object(object)
            }
            return .success(["resources": .array(resources)])
        } catch let error as MCPBackendError {
            return .failure(rpcError(error, subject: "resources"))
        } catch {
            return .failure(.internalError())
        }
    }

    func readResource(_ params: JSONObject, _ context: RequestContext) async -> Result<JSON, RPCError> {
        guard case .string(let uri)? = params["uri"], !uri.isEmpty else {
            return .failure(.invalidParams("resources/read needs params.uri (a string)"))
        }
        let result: Result<JSON, RPCError>
        do {
            let text = try await backend.readResource(uri: uri, caller: context.caller)
            result = .success([
                "contents": [["uri": .string(uri), "mimeType": "text/markdown", "text": .string(text)]],
            ])
        } catch let error as MCPBackendError {
            result = .failure(rpcError(error, subject: uri))
        } catch {
            result = .failure(.internalError())
        }
        var ok = false
        if case .success = result { ok = true }
        // Clipped: the app logs and displays it, and the client chose its length.
        emit(.resource(caller: context.caller, uri: MCPText.clip(uri, 500), ok: ok, at: clock()))
        return result
    }

    func getPrompt(_ params: JSONObject, _ context: RequestContext) async -> Result<JSON, RPCError> {
        guard case .string(let name)? = params["name"] else {
            return .failure(.invalidParams("prompts/get needs params.name (a string)"))
        }
        guard name == "note" else { return .failure(.invalidParams("Unknown prompt: \(MCPText.clip(name, 100))")) }
        let arguments: JSONObject
        switch params["arguments"] {
        case nil, .null?: arguments = JSONObject()
        case .object(let object)?: arguments = object
        default: return .failure(.invalidParams("params.arguments must be an object"))
        }
        let id = arguments["id"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty else {
            return .failure(.invalidParams("The note prompt needs the argument id (a note id or codd://note/<id>)"))
        }
        do {
            let text = try await backend.promptNote(id: id, caller: context.caller)
            return .success([
                "description": .string("CODD note \(MCPText.clip(id, 100))"),
                "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]],
            ])
        } catch let error as MCPBackendError {
            return .failure(rpcError(error, subject: id))
        } catch {
            return .failure(.internalError())
        }
    }

    /// Resource and prompt refusals: `-32602` with `data.state` for "this note is not there for
    /// you" (`unknown` covers not found, OFF and out of scope alike, so nothing leaks), `trashed`
    /// with `purgeAt`, `purged`; `-32603` when the notebook itself failed.
    func rpcError(_ error: MCPBackendError, subject: String) -> RPCError {
        switch error {
        case .notFound, .accessDenied, .invalid:
            return .invalidParams(MCPBackendError.notFound(subject).message(timeZone: timeZone),
                                  data: ["state": "unknown"])
        case .trashed(_, let purgeAt):
            var data: JSONObject = ["state": "trashed"]
            if let purgeAt { data["purgeAt"] = .string(dates.iso(purgeAt)) }
            return .invalidParams(error.message(timeZone: timeZone), data: .object(data))
        case .purged:
            return .invalidParams(error.message(timeZone: timeZone), data: ["state": "purged"])
        case .tooLarge, .unavailable:
            return .internalError(error.message(timeZone: timeZone))
        }
    }
}
