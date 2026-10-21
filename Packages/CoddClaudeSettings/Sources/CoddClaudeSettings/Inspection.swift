/// Another tool's hooks in the user's settings, grouped by program. CODD never edits them
/// (except `停用重複通知`, which removes `osascript` notification duplicates on request).
/// How many of another tool's handlers a change removes and adds (a restore, M3 review).
public struct ForeignHookChange: Sendable, Equatable {
    public var name: String
    public var code: String
    public var removed = 0
    public var added = 0

    public init(name: String, code: String, removed: Int = 0, added: Int = 0) {
        self.name = name
        self.code = code
        self.removed = removed
        self.added = added
    }

    /// `移除 hook-tap ×2`, `加回 hook-tap ×1`, or both.
    public var text: String {
        [removed > 0 ? "移除 \(code) ×\(removed)" : nil, added > 0 ? "加回 \(code) ×\(added)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

public struct ForeignHookTool: Sendable, Equatable {
    /// `通知` for `osascript`, else the program name (`hook-tap`), the same as `code`.
    public var name: String
    /// The program name: `hook-tap`, `osascript`.
    public var code: String
    /// Events with at least one of its handlers, in file order.
    public var events: [String]
    /// `PermissionRequest` handlers with `timeout` ≥ 60 s: Claude waits for them before asking.
    public var blocking: [(event: String, seconds: Int)]

    public init(name: String, code: String, events: [String], blocking: [(event: String, seconds: Int)] = []) {
        self.name = name
        self.code = code
        self.events = events
        self.blocking = blocking
    }

    public static func == (lhs: ForeignHookTool, rhs: ForeignHookTool) -> Bool {
        lhs.name == rhs.name && lhs.code == rhs.code && lhs.events == rhs.events
            && lhs.blocking.count == rhs.blocking.count
            && zip(lhs.blocking, rhs.blocking).allSatisfy { $0.event == $1.event && $0.seconds == $1.seconds }
    }
}

public enum StatusLineState: Sendable, Equatable {
    /// No `statusLine.command`.
    case none
    /// The user's own command, not wrapped by any CODD.
    case user(String)
    /// CODD web's `codd-statusline.js` wrapper; `inner` is the decoded `--chain-b64` command, nil
    /// when it ran standalone.
    case coddWeb(inner: String?)
    /// CODD Desktop's wrapper (D11). `current`: exactly what this CODD would install for the
    /// same chain (`type: "command"` included).
    case coddDesktop(chain: String?, current: Bool)
    /// A CODD wrapper whose `--chain-b64` does not round-trip (or a desktop wrapper edited by
    /// hand): CODD will not rewrite it.
    case undecodable
}

public struct ClaudeSettingsInspection: Sendable, Equatable {
    /// Events with CODD web `status-writer.js` handlers, in file order.
    public var legacyHookEvents: [String]
    public var legacyHandlerCount: Int
    public var foreign: [ForeignHookTool]
    public var statusLine: StatusLineState
    /// `osascript … display notification` handlers on Notification / Stop.
    public var duplicateNotificationHandlers: Int

    public init(legacyHookEvents: [String] = [], legacyHandlerCount: Int = 0, foreign: [ForeignHookTool] = [],
                statusLine: StatusLineState = .none, duplicateNotificationHandlers: Int = 0) {
        self.legacyHookEvents = legacyHookEvents
        self.legacyHandlerCount = legacyHandlerCount
        self.foreign = foreign
        self.statusLine = statusLine
        self.duplicateNotificationHandlers = duplicateNotificationHandlers
    }

    /// CODD web leftovers: hook handlers or its status-line wrapper.
    public var hasLegacy: Bool {
        if legacyHandlerCount > 0 { return true }
        if case .coddWeb = statusLine { return true }
        return false
    }

    /// The command CODD's wrapper chains (or would chain after `更新`), for the STATUS chain
    /// display; nil when there is none or it cannot be decoded.
    public var chainedCommand: String? {
        switch statusLine {
        case .none, .undecodable: return nil
        case .user(let command): return command
        case .coddWeb(let inner): return inner
        case .coddDesktop(let chain, _): return chain
        }
    }

    /// `更新` would change nothing: no legacy and this CODD's wrapper is installed as is.
    public var isUpToDate: Bool {
        guard legacyHandlerCount == 0, case .coddDesktop(_, true) = statusLine else { return false }
        return true
    }
}

/// The statusLine member classified once, with what each action needs to rewrite it.
enum StatusLineKind: Equatable {
    case none
    case user(String)
    case web(inner: String?)
    case webUndecodable
    case desktop(chain: String?)
    case desktopUndecodable

    /// CODD web's status-line script name.
    static let webMarker = "codd-statusline.js"

    static func command(in root: OrderedJSON) -> String? {
        guard let command = root["statusLine"]?["command"]?.stringValue,
              !command.allSatisfy({ $0.isWhitespace })
        else { return nil }
        return command
    }

    static func classify(_ root: OrderedJSON, desktopMarker: String = DesktopStatusLine.binaryMarker) -> StatusLineKind {
        guard let command = command(in: root) else { return .none }
        return classify(command: command, desktopMarker: desktopMarker)
    }

    static func classify(command: String, desktopMarker: String = DesktopStatusLine.binaryMarker) -> StatusLineKind {
        if DesktopStatusLine.looksLikeWrapper(command, marker: desktopMarker) {
            guard let parsed = DesktopStatusLine.parse(command, marker: desktopMarker) else { return .desktopUndecodable }
            return .desktop(chain: parsed.chain)
        }
        if command.contains(webMarker) {
            switch ChainBase64.find(in: command) {
            case .absent: return .web(inner: nil)
            case .decoded(let inner): return .web(inner: inner)
            case .undecodable: return .webUndecodable
            }
        }
        return .user(command)
    }
}

extension ClaudeSettingsInstaller {
    public static func inspect(_ f: ClaudeSettingsFile, desktop: DesktopStatusLine) -> ClaudeSettingsInspection {
        inspect(root: f.root, desktop: desktop)
    }

    static func inspect(root: OrderedJSON, desktop: DesktopStatusLine) -> ClaudeSettingsInspection {
        var result = ClaudeSettingsInspection()
        result.foreign = foreignTools(in: root)
        HookTree.forEachHandler(in: root) { event, handler in
            if HookTree.isLegacy(handler) {
                result.legacyHandlerCount += 1
                if !result.legacyHookEvents.contains(event) { result.legacyHookEvents.append(event) }
            } else if HookTree.isDuplicateNotification(event: event, handler) {
                result.duplicateNotificationHandlers += 1
            }
        }
        switch StatusLineKind.classify(root) {
        case .none: result.statusLine = .none
        case .user(let command): result.statusLine = .user(command)
        case .web(let inner): result.statusLine = .coddWeb(inner: inner)
        case .webUndecodable, .desktopUndecodable: result.statusLine = .undecodable
        case .desktop(let chain):
            let current = StatusLineKind.command(in: root) == desktop.command(chain: chain)
                && root["statusLine"]?["type"]?.stringValue == "command"
            result.statusLine = .coddDesktop(chain: chain, current: current)
        }
        return result
    }

    /// Non-legacy handlers grouped by tool, tools in order of first appearance.
    /// Other tools' handlers one tree has more of than the other, per tool (a restore can
    /// remove or bring back the user's own hooks). Handlers count by event and exact content.
    static func foreignChanges(old: OrderedJSON, new: OrderedJSON) -> [ForeignHookChange] {
        foreignChangeKeys(old: old, new: new).changes
    }

    /// ``foreignChanges(old:new:)`` with the ``SettingsLineRenderer/handlerKey(event:_:)`` of every
    /// handler whose count differs (the diff shows those).
    static func foreignChangeKeys(old: OrderedJSON, new: OrderedJSON) -> (changes: [ForeignHookChange], keys: Set<String>) {
        func census(_ root: OrderedJSON) -> [String: (name: String, code: String, count: Int)] {
            var out: [String: (name: String, code: String, count: Int)] = [:]
            HookTree.forEachHandler(in: root) { event, handler in
                guard !HookTree.isLegacy(handler) else { return }
                let id = ForeignToolName.classify(handler)
                let key = SettingsLineRenderer.handlerKey(event: event, handler)
                out[key] = (id.name, id.code, (out[key]?.count ?? 0) + 1)
            }
            return out
        }
        let before = census(old), after = census(new)
        var changes: [ForeignHookChange] = []
        var keys = Set<String>()
        for key in Set(before.keys).union(after.keys).sorted() {
            let a = before[key]?.count ?? 0, b = after[key]?.count ?? 0
            guard a != b, let id = before[key] ?? after[key] else { continue }
            keys.insert(key)
            let index = changes.firstIndex { $0.code == id.code } ?? {
                changes.append(ForeignHookChange(name: id.name, code: id.code))
                return changes.count - 1
            }()
            if a > b { changes[index].removed += a - b } else { changes[index].added += b - a }
        }
        return (changes, keys)
    }

    static func foreignTools(in root: OrderedJSON) -> [ForeignHookTool] {
        var tools: [ForeignHookTool] = []
        HookTree.forEachHandler(in: root) { event, handler in
            guard !HookTree.isLegacy(handler) else { return }
            let id = ForeignToolName.classify(handler)
            let index: Int
            if let found = tools.firstIndex(where: { $0.code == id.code }) {
                index = found
            } else {
                tools.append(ForeignHookTool(name: id.name, code: id.code, events: []))
                index = tools.count - 1
            }
            if !tools[index].events.contains(event) { tools[index].events.append(event) }
            if event == "PermissionRequest",
               let timeout = handler.last(where: { $0.key == "timeout" })?.value.doubleValue,
               timeout.isFinite, timeout >= 60 {
                let seconds = Int(min(timeout, 1e9).rounded(.down))
                if !tools[index].blocking.contains(where: { $0.event == event && $0.seconds == seconds }) {
                    tools[index].blocking.append((event: event, seconds: seconds))
                }
            }
        }
        return tools
    }
}
