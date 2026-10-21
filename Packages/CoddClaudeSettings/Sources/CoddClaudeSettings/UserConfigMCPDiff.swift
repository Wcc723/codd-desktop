/// The registration preview's diff (M4 D22): only the top-level `mcpServers` member, the edited
/// server's lines shown, every other server elided as `…（保留既有 n 個 MCP server）`, header and
/// environment values (and any secret-looking key's value) shown as `••••`. Lines are the member
/// as `JSON.stringify(x, null, 2)` lays it out, numbered from the member's line in the file.
enum UserConfigMCPDiff {
    static let member = "mcpServers"
    static let mask = "\"••••\""

    static func elidedText(_ count: Int) -> String { "…（保留既有 \(count) 個 MCP server）" }

    /// `servers` (the member's value; nil: no member) rendered as the member's lines, one level
    /// in. `more`: another top-level member follows, so the closing line carries a comma.
    static func render(_ servers: OrderedJSON?, gap: String, more: Bool, target: String, tags: TagTable) -> [RenderedLine] {
        guard let servers else { return [] }
        var renderer = Renderer(gap: gap, target: target, tags: tags)
        renderer.renderMember(servers, more: more)
        return renderer.lines
    }

    /// Hunks over the two renderings, `oldStart` / `newStart` the 1-based file lines of their
    /// first lines (for a side without the member: the line after which it would sit, plus one).
    static func make(old: [RenderedLine], oldStart: Int, new: [RenderedLine], newStart: Int) -> SettingsDiff.Result {
        var interned: [String: Int] = [:]
        func key(_ line: RenderedLine) -> Int {
            let k = "\(line.tag)\u{1}\(line.text)"
            if let id = interned[k] { return id }
            let id = interned.count
            interned[k] = id
            return id
        }
        let ops = SettingsDiff.foreignFirst(LineDiff.diff(old.map(key), new.map(key)), old: old, new: new)
        var result = SettingsDiff.Result()
        result.lines = SettingsDiff.hunkLines(ops, member: member, old: old, oldStart: oldStart, new: new,
                                              newStart: newStart, elided: elidedText)
        for line in result.lines {
            if line.kind == .added { result.added += 1 }
            if line.kind == .removed { result.removed += 1 }
        }
        return result
    }

    /// Keys whose whole value is masked: `headers` / `env` objects and anything named like a
    /// credential.
    static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        if lower == "headers" || lower == "env" { return true }
        return ["token", "secret", "password", "passwd", "authorization", "cookie", "apikey", "api_key", "api-key",
                "credential"].contains { lower.contains($0) }
    }

    private struct Renderer {
        let gap: String
        let target: String
        let tags: TagTable
        var lines: [RenderedLine] = []

        init(gap: String, target: String, tags: TagTable) {
            self.gap = gap
            self.target = target
            self.tags = tags
        }

        mutating func renderMember(_ servers: OrderedJSON, more: Bool) {
            let prefix = JSONWriter.quoted(UserConfigMCPDiff.member) + ": "
            guard case .object(let members) = servers, !members.isEmpty else {
                add(1, prefix + JSONWriter.compact(servers) + comma(more), tag: 0, foreign: false)
                return
            }
            add(1, prefix + "{", tag: 0, foreign: false)
            for (i, server) in members.enumerated() {
                emit(server.value, level: 2, prefix: JSONWriter.quoted(server.key) + ": ", more: i < members.count - 1,
                     tag: tags.id(event: server.key, .null), foreign: server.key != target, secret: false)
            }
            add(1, "}" + comma(more), tag: 0, foreign: false)
        }

        private func comma(_ more: Bool) -> String { more ? "," : "" }

        private mutating func add(_ level: Int, _ content: String, display: String? = nil, tag: Int, foreign: Bool) {
            let pad = String(repeating: gap, count: level)
            lines.append(RenderedLine(text: pad + content, member: UserConfigMCPDiff.member, tag: tag, foreign: foreign,
                                      display: display.map { pad + $0 }))
        }

        private mutating func emit(_ value: OrderedJSON, level: Int, prefix: String, more: Bool, tag: Int,
                                   foreign: Bool, secret: Bool) {
            switch value {
            case .object(let members) where !members.isEmpty:
                add(level, prefix + "{", tag: tag, foreign: foreign)
                for (i, m) in members.enumerated() {
                    emit(m.value, level: level + 1, prefix: JSONWriter.quoted(m.key) + ": ", more: i < members.count - 1,
                         tag: tag, foreign: foreign, secret: secret || UserConfigMCPDiff.isSecretKey(m.key))
                }
                add(level, "}" + comma(more), tag: tag, foreign: foreign)
            case .array(let elements) where !elements.isEmpty:
                add(level, prefix + "[", tag: tag, foreign: foreign)
                for (i, element) in elements.enumerated() {
                    emit(element, level: level + 1, prefix: "", more: i < elements.count - 1, tag: tag, foreign: foreign,
                         secret: secret)
                }
                add(level, "]" + comma(more), tag: tag, foreign: foreign)
            default:
                let text = prefix + JSONWriter.compact(value) + comma(more)
                var display: String?
                if secret {
                    switch value {
                    case .string, .number: display = prefix + UserConfigMCPDiff.mask + comma(more)
                    default: break
                    }
                }
                add(level, text, display: display, tag: tag, foreign: foreign)
            }
        }
    }
}
