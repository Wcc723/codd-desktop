/// The five tools of §3.10 and `notes_create` (user feedback 2026-10-19). The order is the
/// `tools/list` order.
enum MCPTool: String, CaseIterable, Sendable {
    case search = "notes_search"
    case list = "notes_list"
    case read = "notes_read"
    case append = "notes_append"
    case create = "notes_create"
    case write = "notes_write"
}

/// Protocol revisions are dates, so they compare as strings.
enum MCPVersion {
    /// `outputSchema`, `structuredContent` and the top-level tool `title` arrived in 2025-06-18.
    static func hasStructuredOutput(_ version: String) -> Bool { version >= "2025-06-18" }
}

/// `tools/list` entries. Descriptions are short English with the facts a model needs to pick the
/// tool (Claude Code loads `alwaysLoad` tools upfront and defers the rest behind tool search).
enum ToolCatalog {
    static func definitions(writeEnabled: Bool, protocolVersion: String) -> [JSON] {
        let structured = MCPVersion.hasStructuredOutput(protocolVersion)
        return MCPTool.allCases
            .filter { $0 != .write || writeEnabled }
            .map { definition($0, structured: structured) }
    }

    static func definition(_ tool: MCPTool, structured: Bool) -> JSON {
        var object: JSONObject = ["name": .string(tool.rawValue)]
        if structured { object["title"] = .string(title(tool)) }
        object["description"] = .string(description(tool))
        object["inputSchema"] = inputSchema(tool)
        if structured, tool == .search || tool == .list { object["outputSchema"] = resultsSchema }
        object["annotations"] = annotations(tool)
        if let meta = meta(tool) { object["_meta"] = meta }
        return .object(object)
    }

    static func title(_ tool: MCPTool) -> String {
        switch tool {
        case .search: return "Search CODD notes"
        case .list: return "List CODD notes"
        case .read: return "Read a CODD note"
        case .append: return "Append to a CODD note"
        case .create: return "Create a CODD note"
        case .write: return "Replace a CODD note body"
        }
    }

    static func description(_ tool: MCPTool) -> String {
        switch tool {
        case .search:
            return "Search the user's CODD notes (Markdown, often in Traditional Chinese / 繁體中文) by words, "
                + "\"quoted phrases\" or #tags. Returns titles, codd://note/<id> refs, kinds, update times "
                + "and snippets. Open a result with notes_read."
        case .list:
            return "List the user's CODD notes, newest first: recent notes, notes linked to the current session "
                + "or project, pinned notes, prompts. Open a result with notes_read."
        case .read:
            return "Read one CODD note by ref (an id, codd://note/<id> or [[note:<id>]]). Returns its Markdown "
                + "(often 繁體中文) with absolute file paths, its images as image blocks, and each image's "
                + "annotations as numbered items in original image pixels (origin top-left). Long notes are "
                + "paged: call again with the offset it reports."
        case .append:
            return "Append a Markdown section to the end of a CODD note whose AI access is APPEND (other notes "
                + "refuse). The section is marked as written by AI; existing text is never changed. The user "
                + "may be asked to approve."
        case .create:
            return "Create a NEW note in the user's CODD notebook (INBOX) for the user to read there: a report, "
                + "plan, review or summary they asked you to put in CODD, instead of a Markdown file in the "
                + "project. It is linked to this session and its project, its AI access is APPEND (add to it "
                + "later with notes_append), and it never changes an existing note. Returns the new "
                + "codd://note/<id> ref and the file path. The user may be asked to approve."
        case .write:
            return "Replace the body (everything after the title line) of a CODD note whose AI access is "
                + "APPEND. CODD keeps a snapshot of the old text and always asks the user first. Prefer "
                + "notes_append."
        }
    }

    private static func integer(_ range: ClosedRange<Int>, default value: Int, _ description: String) -> JSON {
        [
            "type": "integer", "minimum": .integer(range.lowerBound), "maximum": .integer(range.upperBound),
            "default": .integer(value), "description": .string(description),
        ]
    }

    private static let ref: JSON = [
        "type": "string", "minLength": 1,
        "description": "The note: an id (rwd-punch-k7x2), codd://note/<id> or [[note:<id>]].",
    ]

    private static let kind: JSON = [
        "type": "string", "enum": ["note", "prompt", "scratch"],
        "description": "Only notes of this kind.",
    ]

    private static let includeArchived: JSON = [
        "type": "boolean", "default": false, "description": "Also include archived notes.",
    ]

    static func inputSchema(_ tool: MCPTool) -> JSON {
        switch tool {
        case .search:
            return [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": .string(
                            "Words to find in titles, bodies and tags; all must match. Chinese terms of any "
                                + "length work. #tag filters by tag, \"quoted phrases\" keep their spaces."),
                    ],
                    "scope": [
                        "type": "string", "enum": ["all", "project"], "default": "all",
                        "description": .string(
                            "all: every note you may see. project: only notes of the current session's "
                                + "project or linked to the session."),
                    ],
                    "tags": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Only notes with all of these tags (without #).",
                    ],
                    "kind": kind,
                    "include_archived": includeArchived,
                    "limit": integer(MCPLimits.searchLimit, default: MCPLimits.searchDefaultLimit,
                                     "Maximum number of results."),
                ],
                "required": ["query"],
            ]
        case .list:
            return [
                "type": "object",
                "properties": [
                    "session": [
                        "type": "string",
                        "description": "\"current\" for notes linked to this session, or a CODD session UUID.",
                    ],
                    "project": [
                        "type": "string",
                        "description": "\"current\" for notes of this session's project, or a project path.",
                    ],
                    "kind": kind,
                    "pinned": ["type": "boolean", "description": "Only pinned (true) or unpinned (false) notes."],
                    "days": integer(MCPLimits.listDays, default: 30, "Only notes updated in the last N days.")
                        .removingDefault(),
                    "include_archived": includeArchived,
                    "limit": integer(MCPLimits.listLimit, default: MCPLimits.listDefaultLimit,
                                     "Maximum number of results."),
                ],
            ]
        case .read:
            return [
                "type": "object",
                "properties": [
                    "ref": ref,
                    "offset": [
                        "type": "integer", "minimum": 0, "default": 0,
                        "description": "Character offset to start from; use the offset a previous page reported.",
                    ],
                    "max_chars": integer(MCPLimits.readMaxChars, default: MCPLimits.readDefaultMaxChars,
                                         "Characters of note text per page."),
                    "include_images": [
                        "type": "boolean", "default": true,
                        "description": .string(
                            "Attach the note's images (at most \(MCPLimits.maxImageBlocks)) as image blocks."),
                    ],
                ],
                "required": ["ref"],
            ]
        case .append:
            return [
                "type": "object",
                "properties": [
                    "ref": ref,
                    "markdown": [
                        "type": "string", "minLength": 1, "maxLength": .integer(MCPLimits.appendMaxCharacters),
                        "description": "The Markdown to append, in the language of the note.",
                    ],
                    "heading": [
                        "type": "string", "maxLength": .integer(MCPLimits.headingMaxCharacters),
                        "description": "Heading of the new section (default: AI 附加 · HH:mm).",
                    ],
                ],
                "required": ["ref", "markdown"],
            ]
        case .create:
            return [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string", "minLength": 1, "maxLength": .integer(MCPLimits.createTitleMaxCharacters),
                        "description": "The note's title, one line without #.",
                    ],
                    "body": [
                        "type": "string", "minLength": 1, "maxLength": .integer(MCPLimits.createMaxBodyCharacters),
                        "description": .string(
                            "The note's Markdown, without the title line, in the language the user works in. "
                                + "Longer text: create the note, then add the rest with notes_append."),
                    ],
                    "tags": [
                        "type": "array", "items": ["type": "string"],
                        "description": .string("Tags (without #), at most \(MCPLimits.createMaxTags)."),
                    ],
                    "kind": [
                        "type": "string", "enum": ["note", "prompt"], "default": "note",
                        "description": "note (the default), or prompt for a prompt the user will send later.",
                    ],
                ],
                "required": ["title", "body"],
            ]
        case .write:
            return [
                "type": "object",
                "properties": [
                    "ref": ref,
                    "markdown": [
                        "type": "string", "minLength": 1, "maxLength": .integer(MCPLimits.writeMaxCharacters),
                        "description": "The new body, without the title line (it is kept).",
                    ],
                ],
                "required": ["ref", "markdown"],
            ]
        }
    }

    /// `structuredContent` of notes_search / notes_list. Plain types only (no `format`, no `enum`):
    /// Claude Code validates every structured result against this schema and fails the call when it
    /// does not match, so it must accept whatever strings the backend reports.
    static let resultsSchema: JSON = [
        "type": "object",
        "properties": [
            "results": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string"],
                        "uri": ["type": "string", "description": "codd://note/<id>"],
                        "title": ["type": "string"],
                        "kind": ["type": "string", "description": "note, prompt or scratch"],
                        "tags": ["type": "array", "items": ["type": "string"]],
                        "updated": ["type": "string", "description": "RFC 3339 date-time"],
                        "snippet": ["type": "string"],
                        "path": ["type": "string", "description": "Absolute path of the note file"],
                        "state": ["type": "string", "description": "active or archived"],
                    ],
                    "required": ["id", "uri", "title", "kind", "tags", "updated", "snippet", "path", "state"],
                ],
            ],
        ],
        "required": ["results"],
    ]

    static func annotations(_ tool: MCPTool) -> JSON {
        switch tool {
        case .search, .list, .read:
            return [
                "title": .string(title(tool)), "readOnlyHint": true, "destructiveHint": false,
                "idempotentHint": true, "openWorldHint": false,
            ]
        case .append, .create:
            return [
                "title": .string(title(tool)), "readOnlyHint": false, "destructiveHint": false,
                "idempotentHint": false, "openWorldHint": false,
            ]
        case .write:
            return [
                "title": .string(title(tool)), "readOnlyHint": false, "destructiveHint": true,
                "idempotentHint": true, "openWorldHint": false,
            ]
        }
    }

    static func meta(_ tool: MCPTool) -> JSON? {
        switch tool {
        case .search: return ["anthropic/alwaysLoad": true]
        case .read: return ["anthropic/alwaysLoad": true, "anthropic/maxResultSizeChars": 200_000]
        case .write: return ["anthropic/requiresUserInteraction": true]
        // notes_create keeps Claude Code's normal permission prompt (never in CODD's allow list,
        // never requiresUserInteraction, so the user can choose to always allow it).
        case .list, .append, .create: return nil
        }
    }
}

private extension JSON {
    /// `days` has no default (absent = no time filter) but shares the integer helper.
    func removingDefault() -> JSON {
        guard case .object(var object) = self else { return self }
        object["default"] = nil
        return .object(object)
    }
}
