/// The `hooks` member of Claude settings: `{<event>: [group]}`, where a group is the official
/// `{matcher?, hooks: [{type, command, timeout?}]}` or the old hand-written `{matcher, command}`
/// (a group that is its own handler). Everything here reads both shapes.
enum HookTree {
    typealias Members = [(key: String, value: OrderedJSON)]

    /// CODD web's hook script; any handler running it is a leftover the installer removes.
    static let legacyMarker = "status-writer.js"

    static func command(of handler: Members) -> String? {
        handler.last(where: { $0.key == "command" })?.value.stringValue
    }

    static func isLegacy(_ handler: Members) -> Bool {
        command(of: handler)?.contains(legacyMarker) ?? false
    }

    /// `osascript … display notification` on Notification / Stop: CODD posts its own
    /// notifications, so these show every alert twice.
    static func isDuplicateNotification(event: String, _ handler: Members) -> Bool {
        guard event == "Notification" || event == "Stop", let command = command(of: handler) else { return false }
        return command.contains("osascript") && command.contains("display notification")
    }

    /// Old-shape group: a `command` string at the group level (checked first, like CODD web).
    static func isOldShape(_ group: Members) -> Bool {
        group.last(where: { $0.key == "command" })?.value.stringValue != nil
    }

    /// Every handler in file order: `body(event, handler)`. Non-object groups and handlers, and
    /// events that are not arrays, carry no handler and are skipped.
    static func forEachHandler(in root: OrderedJSON, _ body: (String, Members) -> Void) {
        guard let events = root["hooks"]?.objectMembers else { return }
        for event in events {
            guard let groups = event.value.arrayElements else { continue }
            for group in groups {
                guard let members = group.objectMembers else { continue }
                if isOldShape(members) {
                    body(event.key, members)
                } else if let handlers = members.last(where: { $0.key == "hooks" })?.value.arrayElements {
                    for handler in handlers {
                        if let h = handler.objectMembers { body(event.key, h) }
                    }
                }
            }
        }
    }

    struct Removal {
        /// Events that lost at least one handler, in file order.
        var events: [String] = []
        var handlers = 0
    }

    /// Removes the handlers `remove` selects. A group is dropped only when this emptied it, an
    /// event key only when its array became empty, and `hooks` only when it became empty;
    /// everything else (other handlers, groups, their keys and order) stays where it was.
    static func removeHandlers(from root: inout OrderedJSON,
                               where remove: (String, Members) -> Bool) throws(ClaudeSettingsError) -> Removal {
        guard let hooksValue = root["hooks"] else { return Removal() }
        guard case .object(var events) = hooksValue else { throw .shapeNotSupported("hooks") }
        var removal = Removal()
        var e = 0
        while e < events.count {
            let event = events[e].key
            guard case .array(let groups) = events[e].value else { throw .shapeNotSupported("hooks.\(event)") }
            var kept: [OrderedJSON] = []
            var removedHere = 0
            for group in groups {
                guard case .object(var members) = group else {
                    kept.append(group)
                    continue
                }
                if isOldShape(members) {
                    if remove(event, members) {
                        removedHere += 1
                    } else {
                        kept.append(group)
                    }
                    continue
                }
                guard let at = members.lastIndex(where: { $0.key == "hooks" }),
                      case .array(let handlers) = members[at].value
                else {
                    kept.append(group)
                    continue
                }
                let remaining = handlers.filter { handler in
                    guard let h = handler.objectMembers else { return true }
                    return !remove(event, h)
                }
                let dropped = handlers.count - remaining.count
                guard dropped > 0 else {
                    kept.append(group)
                    continue
                }
                removedHere += dropped
                if !remaining.isEmpty {
                    members[at].value = .array(remaining)
                    kept.append(.object(members))
                }
            }
            if removedHere > 0 {
                removal.events.append(event)
                removal.handlers += removedHere
                if kept.isEmpty {
                    events.remove(at: e)
                    continue
                }
                events[e].value = .array(kept)
            }
            e += 1
        }
        if removal.handlers > 0 {
            if events.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root.setValue(.object(events), forKey: "hooks")
            }
        }
        return removal
    }

    /// Validates the shapes a hook edit needs, so a plan fails before computing anything.
    static func checkShape(_ root: OrderedJSON) throws(ClaudeSettingsError) {
        guard let hooks = root["hooks"] else { return }
        guard let events = hooks.objectMembers else { throw .shapeNotSupported("hooks") }
        for event in events where event.value.arrayElements == nil {
            throw .shapeNotSupported("hooks.\(event.key)")
        }
    }
}

/// Names a foreign handler the way STATUS lists it: `osascript` 通知, else the program's file
/// name for both (`~/.hook-tap/bin/hook-tap Stop` → `hook-tap`).
enum ForeignToolName {
    static func classify(_ handler: HookTree.Members) -> (name: String, code: String) {
        guard let command = HookTree.command(of: handler) else {
            let type = handler.last(where: { $0.key == "type" })?.value.stringValue ?? "hook"
            return (type, type)
        }
        if command.contains("osascript") { return ("通知", "osascript") }
        let code = programName(command)
        return (code, code)
    }

    /// The basename of the first shell word, quotes removed; leading `NAME=value` assignments
    /// are skipped so `FOO=1 /opt/bin/tool` reads as `tool`.
    static func programName(_ command: String) -> String {
        var scanner = WordScanner(command)
        while let word = scanner.next() {
            if word.isAssignment { continue }
            let base = word.text.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? word.text
            return base.isEmpty ? "command" : base
        }
        return "command"
    }

    /// Minimal POSIX word reader: `'…'`, `"…"` (with `\` escapes), `\x`; stops at unquoted blanks
    /// and the operators `; | & ( ) < >`.
    struct WordScanner {
        private let s: [Unicode.Scalar]
        private var i = 0

        init(_ text: String) {
            s = Array(text.unicodeScalars)
        }

        /// The next word, quotes removed; `isAssignment` when it starts with an unquoted
        /// `NAME=` (the value may be quoted: `BAR='x y'`).
        mutating func next() -> (text: String, isAssignment: Bool)? {
            while i < s.count, s[i] == " " || s[i] == "\t" || s[i] == "\n" { i += 1 }
            guard i < s.count, !isOperator(s[i]) else { return nil }
            var name = i
            while name < s.count, s[name] == "_" || ("A"..."Z").contains(s[name]) || ("a"..."z").contains(s[name])
                || (name > i && ("0"..."9").contains(s[name])) { name += 1 }
            let isAssignment = name > i && name < s.count && s[name] == "="
            var out = String.UnicodeScalarView()
            while i < s.count {
                let c = s[i]
                if c == " " || c == "\t" || c == "\n" || isOperator(c) { break }
                if c == "'" {
                    i += 1
                    while i < s.count, s[i] != "'" { out.append(s[i]); i += 1 }
                    i += 1
                } else if c == "\"" {
                    i += 1
                    while i < s.count, s[i] != "\"" {
                        if s[i] == "\\", i + 1 < s.count { i += 1 }
                        out.append(s[i])
                        i += 1
                    }
                    i += 1
                } else if c == "\\", i + 1 < s.count {
                    out.append(s[i + 1])
                    i += 2
                } else {
                    out.append(c)
                    i += 1
                }
            }
            return (String(out), isAssignment)
        }

        private func isOperator(_ c: Unicode.Scalar) -> Bool {
            c == ";" || c == "|" || c == "&" || c == "(" || c == ")" || c == "<" || c == ">"
        }
    }
}
