import Foundation

/// Arguments the model got wrong. Reported as an `isError` tool result (not a JSON-RPC error), so
/// the model reads the reason and can retry, as the 2025-11-25 spec asks for input validation.
struct ToolArgumentError: Error, Sendable, Equatable {
    var message: String

    init(_ detail: String) { message = "Invalid arguments: \(detail)" }
}

/// Typed, lenient reads of a `tools/call` `arguments` object. Unknown keys are ignored; `null`
/// counts as absent; integers may arrive as `10`, `10.0` or `"10"` and booleans as `"true"`
/// (models sometimes quote them); anything else of the wrong type is an error.
struct ToolArguments {
    let object: JSONObject

    private func value(_ key: String) -> JSON? {
        guard let value = object[key], value != .null else { return nil }
        return value
    }

    func string(_ key: String) throws(ToolArgumentError) -> String? {
        guard let value = value(key) else { return nil }
        guard case .string(let s) = value else { throw ToolArgumentError("\"\(key)\" must be a string.") }
        return s
    }

    func bool(_ key: String) throws(ToolArgumentError) -> Bool? {
        switch value(key) {
        case nil: return nil
        case .bool(let b)?: return b
        case .string(let s)? where s.lowercased() == "true": return true
        case .string(let s)? where s.lowercased() == "false": return false
        default: throw ToolArgumentError("\"\(key)\" must be true or false.")
        }
    }

    /// Whole numbers only; huge magnitudes are kept as ±10^15 so the caller's clamp still applies.
    func integer(_ key: String) throws(ToolArgumentError) -> Int? {
        let bound = 1_000_000_000_000_000
        let failure = ToolArgumentError("\"\(key)\" must be an integer.")
        switch value(key) {
        case nil:
            return nil
        case .number(let n)?:
            let d = n.doubleValue
            guard d.isFinite, d == d.rounded(.towardZero) else { throw failure }
            return Int(min(max(d, -Double(bound)), Double(bound)))
        case .string(let s)?:
            let text = s.trimmingCharacters(in: .whitespaces)
            let digits = text.hasPrefix("-") ? text.dropFirst() : Substring(text)
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw failure }
            guard let exact = Int(text) else { return text.hasPrefix("-") ? -bound : bound }
            return min(max(exact, -bound), bound)
        default:
            throw failure
        }
    }

    /// An array of strings; a single string is taken as a one-element array.
    func strings(_ key: String) throws(ToolArgumentError) -> [String]? {
        switch value(key) {
        case nil: return nil
        case .string(let s)?: return [s]
        case .array(let items)?:
            var out: [String] = []
            for item in items {
                guard case .string(let s) = item else { throw ToolArgumentError("\"\(key)\" must be an array of strings.") }
                out.append(s)
            }
            return out
        default: throw ToolArgumentError("\"\(key)\" must be an array of strings.")
        }
    }

    static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

/// §3.10 validation and clamping, one function per tool.
enum ToolRequests {
    private static let kinds: Set<String> = ["note", "prompt", "scratch"]

    private static func parseRef(_ a: ToolArguments) throws(ToolArgumentError) -> String {
        let ref = (try a.string("ref") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ref.isEmpty else {
            throw ToolArgumentError("\"ref\" is required: a note id, codd://note/<id> or [[note:<id>]].")
        }
        guard ref.count <= MCPLimits.refMaxCharacters else {
            throw ToolArgumentError("\"ref\" is longer than \(MCPLimits.refMaxCharacters) characters.")
        }
        return ref
    }

    private static func parseKind(_ a: ToolArguments) throws(ToolArgumentError) -> String? {
        guard let raw = try a.string("kind") else { return nil }
        let kind = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if kind.isEmpty { return nil }
        guard kinds.contains(kind) else {
            throw ToolArgumentError("\"kind\" must be \"note\", \"prompt\" or \"scratch\".")
        }
        return kind
    }

    private static func parseMarkdown(_ a: ToolArguments, limit: Int, tool: MCPTool) throws(ToolArgumentError) -> String {
        guard let markdown = try a.string("markdown"),
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw ToolArgumentError("\"markdown\" is required and must not be empty.") }
        let count = markdown.count
        guard count <= limit else {
            let hint = tool == .append ? " Split it into several appends." : ""
            throw ToolArgumentError("\"markdown\" has \(count) characters; the limit is \(limit).\(hint)")
        }
        return markdown
    }

    static func search(_ a: ToolArguments) throws(ToolArgumentError) -> MCPSearchRequest {
        guard let rawQuery = try a.string("query") else { throw ToolArgumentError("\"query\" is required.") }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count <= MCPLimits.queryMaxCharacters else {
            throw ToolArgumentError("\"query\" is longer than \(MCPLimits.queryMaxCharacters) characters.")
        }
        var scope = MCPSearchRequest.Scope.all
        if let raw = try a.string("scope") {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if !name.isEmpty {
                guard let parsed = MCPSearchRequest.Scope(rawValue: name) else {
                    throw ToolArgumentError("\"scope\" must be \"all\" or \"project\".")
                }
                scope = parsed
            }
        }
        var tags: [String] = []
        for raw in try a.strings("tags") ?? [] {
            var tag = raw.trimmingCharacters(in: .whitespaces)
            while tag.hasPrefix("#") { tag.removeFirst() }
            if !tag.isEmpty, !tags.contains(tag) { tags.append(tag) }
        }
        let kind = try parseKind(a)
        guard !query.isEmpty || !tags.isEmpty || kind != nil else {
            throw ToolArgumentError("\"query\" is empty; give words, #tags, \"tags\" or \"kind\".")
        }
        let limit = ToolArguments.clamp(try a.integer("limit") ?? MCPLimits.searchDefaultLimit, MCPLimits.searchLimit)
        return MCPSearchRequest(query: query, scope: scope, tags: tags, kind: kind,
                                includeArchived: try a.bool("include_archived") ?? false, limit: limit)
    }

    static func list(_ a: ToolArguments) throws(ToolArgumentError) -> MCPListRequest {
        var session: String?
        if let raw = try a.string("session")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            if raw.lowercased() == "current" {
                session = "current"
            } else if let uuid = UUID(uuidString: raw) {
                session = uuid.uuidString.lowercased()
            } else {
                throw ToolArgumentError("\"session\" must be \"current\" or a CODD session UUID.")
            }
        }
        var project: String?
        if let raw = try a.string("project")?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            project = raw.lowercased() == "current" ? "current" : raw
        }
        let days = try a.integer("days").map { ToolArguments.clamp($0, MCPLimits.listDays) }
        let limit = ToolArguments.clamp(try a.integer("limit") ?? MCPLimits.listDefaultLimit, MCPLimits.listLimit)
        return MCPListRequest(session: session, project: project, kind: try parseKind(a), pinned: try a.bool("pinned"),
                              days: days, includeArchived: try a.bool("include_archived") ?? false, limit: limit)
    }

    static func read(_ a: ToolArguments) throws(ToolArgumentError) -> MCPReadRequest {
        let ref = try parseRef(a)
        let offset = ToolArguments.clamp(try a.integer("offset") ?? 0, 0...1_000_000_000)
        let maxChars = ToolArguments.clamp(try a.integer("max_chars") ?? MCPLimits.readDefaultMaxChars,
                                           MCPLimits.readMaxChars)
        return MCPReadRequest(ref: ref, offset: offset, maxChars: maxChars,
                              includeImages: try a.bool("include_images") ?? true)
    }

    static func append(_ a: ToolArguments) throws(ToolArgumentError) -> MCPAppendRequest {
        let ref = try parseRef(a)
        let markdown = try parseMarkdown(a, limit: MCPLimits.appendMaxCharacters, tool: .append)
        var heading: String?
        if let raw = try a.string("heading") {
            let line = String(MCPText.oneLine(raw).prefix(MCPLimits.headingMaxCharacters))
                .trimmingCharacters(in: .whitespaces)
            heading = line.isEmpty ? nil : line
        }
        return MCPAppendRequest(ref: ref, markdown: markdown, heading: heading)
    }

    static func write(_ a: ToolArguments) throws(ToolArgumentError) -> MCPWriteRequest {
        let ref = try parseRef(a)
        return MCPWriteRequest(ref: ref, markdown: try parseMarkdown(a, limit: MCPLimits.writeMaxCharacters, tool: .write))
    }

    /// `notes_create`: `title` (one line, a leading `# ` dropped), `body` (non-blank, ≤ 100,000
    /// characters), `tags` (the tag editor's cleaning), `kind` `note` / `prompt`.
    static func create(_ a: ToolArguments) throws(ToolArgumentError) -> MCPCreateRequest {
        guard let rawTitle = try a.string("title") else {
            throw ToolArgumentError("\"title\" is required: the note's title, one line.")
        }
        let title = createTitle(rawTitle)
        guard !title.isEmpty else { throw ToolArgumentError("\"title\" is empty; give the note a title.") }
        guard title.count <= MCPLimits.createTitleMaxCharacters else {
            throw ToolArgumentError("\"title\" is longer than \(MCPLimits.createTitleMaxCharacters) characters.")
        }
        guard let body = try a.string("body"), !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolArgumentError("\"body\" is required and must not be empty: the note's Markdown.")
        }
        let count = body.count
        guard count <= MCPLimits.createMaxBodyCharacters else {
            throw ToolArgumentError("\"body\" has \(count) characters; the limit is \(MCPLimits.createMaxBodyCharacters). "
                + "Create a shorter note and add the rest with notes_append.")
        }
        var tags: [String] = []
        for raw in try a.strings("tags") ?? [] {
            let tag = createTag(raw)
            guard !tag.isEmpty, !tags.contains(where: { $0.lowercased() == tag.lowercased() }) else { continue }
            guard tag.count <= MCPLimits.createTagMaxCharacters else {
                throw ToolArgumentError("a tag is longer than \(MCPLimits.createTagMaxCharacters) characters.")
            }
            tags.append(tag)
        }
        guard tags.count <= MCPLimits.createMaxTags else {
            throw ToolArgumentError("\"tags\" has \(tags.count) tags; the limit is \(MCPLimits.createMaxTags).")
        }
        var kind = "note"
        if let raw = try a.string("kind") {
            let name = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if !name.isEmpty {
                guard name == "note" || name == "prompt" else {
                    throw ToolArgumentError("\"kind\" must be \"note\" or \"prompt\".")
                }
                kind = name
            }
        }
        return MCPCreateRequest(title: title, body: body, tags: tags, kind: kind)
    }

    /// One line, trimmed, without a leading Markdown heading marker (`# 報告` → `報告`, a bare `#`
    /// → empty; `#12 bug` keeps its `#`).
    static func createTitle(_ raw: String) -> String {
        var title = MCPText.oneLine(raw)
        let marker = title.prefix { $0 == "#" }
        if !marker.isEmpty, marker.count <= 6 {
            let rest = title.dropFirst(marker.count)
            if rest.isEmpty || rest.first?.isWhitespace == true { title = String(rest) }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// The Notebook's tag editor (`TagEditorView.clean`): trimmed, `#` stripped at both ends,
    /// whitespace as `-`; then NFC like the notes library.
    static func createTag(_ raw: String) -> String {
        let stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dashed = String(stripped.map { $0.isWhitespace ? "-" : $0 })
        return dashed.precomposedStringWithCanonicalMapping
    }
}
