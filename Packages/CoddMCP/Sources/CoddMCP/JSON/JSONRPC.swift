/// A JSON-RPC error object.
struct RPCError: Error, Sendable, Equatable {
    var code: Int
    var message: String
    var data: JSON?

    static let parseErrorCode = -32700
    static let invalidRequestCode = -32600
    static let methodNotFoundCode = -32601
    static let invalidParamsCode = -32602
    static let internalErrorCode = -32603

    static func invalidRequest(_ message: String) -> RPCError { RPCError(code: invalidRequestCode, message: message) }
    static func methodNotFound(_ method: String) -> RPCError {
        RPCError(code: methodNotFoundCode, message: "Method not found: \(MCPText.clip(method, 100))")
    }
    static func invalidParams(_ message: String, data: JSON? = nil) -> RPCError {
        RPCError(code: invalidParamsCode, message: message, data: data)
    }
    static func internalError(_ message: String = "Internal error") -> RPCError {
        RPCError(code: internalErrorCode, message: message)
    }

    var json: JSON {
        var object: JSONObject = ["code": .integer(code), "message": .string(message)]
        if let data { object["data"] = data }
        return .object(object)
    }
}

/// One element of a POST body, classified per JSON-RPC 2.0.
enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSON, method: String, params: JSON?)
    case notification(method: String, params: JSON?)
    /// A reply to a server-to-client request. CODD never sends any, so these are dropped (202).
    case response
    /// Not a valid message; answered `-32600` with the id when one could be read.
    case invalid(id: JSON, reason: String)

    static func classify(_ value: JSON) -> JSONRPCMessage {
        guard case .object(let object) = value else {
            return .invalid(id: .null, reason: "Invalid Request: a message must be a JSON object")
        }
        let rawID = object["id"]
        let id: JSON?
        switch rawID {
        case .string?, .number?: id = rawID
        default: id = nil
        }
        guard object["jsonrpc"] == .string("2.0") else {
            return .invalid(id: id ?? .null, reason: "Invalid Request: jsonrpc must be \"2.0\"")
        }
        guard let methodValue = object["method"] else {
            if object["result"] != nil || object["error"] != nil { return .response }
            return .invalid(id: id ?? .null, reason: "Invalid Request: no method")
        }
        guard case .string(let method) = methodValue else {
            return .invalid(id: id ?? .null, reason: "Invalid Request: method must be a string")
        }
        guard rawID != nil else { return .notification(method: method, params: object["params"]) }
        guard let id else {
            return .invalid(id: .null, reason: "Invalid Request: id must be a string or a number")
        }
        return .request(id: id, method: method, params: object["params"])
    }

    var method: String? {
        switch self {
        case .request(_, let method, _), .notification(let method, _): return method
        case .response, .invalid: return nil
        }
    }
}

enum JSONRPCReply {
    static func result(id: JSON, _ result: JSON) -> JSON {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func error(id: JSON, _ error: RPCError) -> JSON {
        ["jsonrpc": "2.0", "id": id, "error": error.json]
    }
}
