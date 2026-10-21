import Foundation

/// Claude Code hook event names that the state machine reacts to.
/// (Other events are accepted and only refresh `event` / `last_event_at`.)
public enum HookEventName: String, Sendable, CaseIterable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case sessionEnd = "SessionEnd"
    case preCompact = "PreCompact"
    case postCompact = "PostCompact"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
}

/// One hook event as delivered by Claude Code (JSON body of an `http` hook, or stdin of a
/// `command` hook).
///
/// Fields are read with the exact JavaScript rules of status-writer.js: `str(v)` accepts only
/// strings with non-whitespace content and returns them UNtrimmed; `p.source` is compared raw.
public struct HookPayload: Sendable, Equatable {
    /// The raw JSON object (empty when the body was blank, invalid or not an object).
    public let raw: [String: JSONValue]

    public init(object: [String: JSONValue]) {
        raw = object
    }

    /// Parses a request body leniently (status-writer.js `safeParse(readStdin())`). Members named in
    /// `droppingKeys` are left out without being decoded.
    public init(body: Data, droppingKeys: Set<String> = []) {
        var object = JSONValue.parseObjectLeniently(body, nullingTopLevelKeys: droppingKeys)
        for key in droppingKeys { object[key] = nil }
        raw = object
    }

    /// `str(p.hook_event_name)`.
    public var eventName: String? { JSText.nonBlank(raw["hook_event_name"]) }
    /// The event as a known enum value (exact, case-sensitive match).
    public var event: HookEventName? { eventName.flatMap(HookEventName.init(rawValue:)) }
    /// `str(p.session_id)`.
    public var sessionId: String? { JSText.nonBlank(raw["session_id"]) }
    /// `str(p.transcript_path)`.
    public var transcriptPath: String? { JSText.nonBlank(raw["transcript_path"]) }
    /// `str(p.cwd)`.
    public var cwd: String? { JSText.nonBlank(raw["cwd"]) }
    /// `str(p.tool_name)`.
    public var toolName: String? { JSText.nonBlank(raw["tool_name"]) }
    /// `str(p.notification_type)`.
    public var notificationType: String? { JSText.nonBlank(raw["notification_type"]) }
    /// `str(p.message)`.
    public var message: String? { JSText.nonBlank(raw["message"]) }
    /// `p.source` exactly as sent (compared with `===` in the original).
    public var source: JSONValue? { raw["source"] }
    /// `str(p.trigger)` (PreCompact / PostCompact: `manual` or `auto`).
    public var trigger: String? { JSText.nonBlank(raw["trigger"]) }
    /// `str(p.error)` (StopFailure error type).
    public var error: String? { JSText.nonBlank(raw["error"]) }

    /// `p.source === value`.
    func sourceIs(_ value: String) -> Bool {
        source == .string(value)
    }
}

// MARK: - M4

extension HookPayload {
    /// Tools whose `tool_input` names the file they changed (D26), and the member that holds it.
    static let fileTools: [String: String] = [
        "Edit": "file_path", "Write": "file_path", "MultiEdit": "file_path", "NotebookEdit": "notebook_path",
    ]

    /// UserPromptSubmit's `prompt` (`str(p.prompt)`: a string with non-whitespace content, untrimmed);
    /// `nil` for any other event.
    public var prompt: String? {
        guard event == .userPromptSubmit else { return nil }
        return JSText.nonBlank(raw["prompt"])
    }

    /// M4 D26: the files a PostToolUse changed: `tool_input.file_path` of Edit / Write / MultiEdit
    /// and `tool_input.notebook_path` of NotebookEdit. A relative path is resolved against the
    /// payload's `cwd` (dropped without one), `~` / `~/…` against the home folder; the result is
    /// absolute and lexically standardized (`//`, `.` and `..` removed, symlinks untouched). Every
    /// other event or tool gives `[]`. Bash-made changes are not seen (known issue).
    public var toolFilePaths: [String] {
        guard event == .postToolUse, let tool = toolName, let key = Self.fileTools[tool],
              case .object(let input)? = raw["tool_input"] else { return [] }
        // One path per tool call today (MultiEdit edits one file); an array so a tool naming
        // several files can be added without changing callers.
        guard case .string(let value)? = input[key], let path = Self.absolutePath(value, cwd: cwd) else { return [] }
        return [path]
    }

    static func absolutePath(_ path: String, cwd: String?) -> String? {
        guard !JSText.trim(path).isEmpty, !path.contains("\0") else { return nil }
        let absolute: String
        if path.hasPrefix("/") {
            absolute = path
        } else if path == "~" || path.hasPrefix("~/") {
            absolute = NSHomeDirectory() + path.dropFirst()
        } else {
            guard let cwd, cwd.hasPrefix("/") else { return nil }
            absolute = cwd.hasSuffix("/") ? cwd + path : cwd + "/" + path
        }
        return lexicallyStandardized(absolute)
    }

    /// An absolute path with empty and `.` components removed and `..` applied (never above `/`),
    /// without touching the file system (symlinks stay as named).
    static func lexicallyStandardized(_ absolute: String) -> String {
        var parts: [Substring] = []
        for component in absolute.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
