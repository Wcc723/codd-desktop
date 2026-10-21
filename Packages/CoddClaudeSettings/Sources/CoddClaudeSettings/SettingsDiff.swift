/// One line of the Hook 差異 dialog.
public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable {
        /// `@@ -a,b +c,d @@  "hooks"`.
        case hunk
        case context
        case added
        case removed
        /// Consecutive lines of other tools' handlers kept on both sides, shown as `…（保留既有 n 組
        /// hook）`. A handler only one side has is shown as removed / added lines instead.
        case elided
    }

    public var kind: Kind
    /// 1-based line in the current file (context and removed lines).
    public var oldNumber: Int?
    /// 1-based line in the new file (context and added lines).
    public var newNumber: Int?
    public var text: String

    public init(kind: Kind, oldNumber: Int? = nil, newNumber: Int? = nil, text: String) {
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

/// A pretty-printed line with what the diff needs to know about it.
struct RenderedLine {
    var text: String
    /// The top-level member the line belongs to; nil for the root braces.
    var member: String?
    /// Identity of the innermost hook group or handler (0: none). Two lines match in the diff
    /// only when text and tag agree, so a removed CODD web group can never be "matched" with
    /// the structurally identical lines of a neighbouring foreign group.
    var tag: Int
    /// Inside another tool's handler that the plan keeps: never shown, only counted. A handler
    /// one side has more of than the other (a restore removing the user's hooks) is not foreign
    /// here: its lines show as removed / added (M3 review: they were folded into `…（保留既有 n
    /// 組 hook）`).
    var foreign: Bool
    /// What the dialog shows when it differs from ``text`` (a secret masked as `••••`); the diff
    /// still matches lines on ``text``, so a rotated token shows as a changed line.
    var display: String? = nil
}

/// Interns hook-object identities (event + compact JSON) to small integers for both sides.
final class TagTable {
    private var ids: [String: Int] = [:]

    func id(event: String, _ value: OrderedJSON) -> Int {
        let key = event + "\u{1F}" + JSONWriter.compact(value)
        if let id = ids[key] { return id }
        let id = ids.count + 1
        ids[key] = id
        return id
    }
}

/// Renders a settings root into the exact lines of `serialized(indent:)`, annotating `hooks`.
struct SettingsLineRenderer {
    let gap: String
    /// True for a handler the plan acts on (CODD web's, or a duplicate notification being
    /// removed): it is shown; any other handler is foreign.
    let shown: (String, HookTree.Members) -> Bool
    let tags: TagTable
    /// ``handlerKey(event:_:)`` of other tools' handlers the change removes or adds: shown.
    let changedForeign: Set<String>
    private(set) var lines: [RenderedLine] = []

    init(indent: String, tags: TagTable, changedForeign: Set<String> = [], shown: @escaping (String, HookTree.Members) -> Bool) {
        gap = String(decoding: JSONWriter.gap(indent), as: UTF8.self)
        self.tags = tags
        self.changedForeign = changedForeign
        self.shown = shown
    }

    static func render(_ root: OrderedJSON, indent: String, tags: TagTable, changedForeign: Set<String> = [],
                       shown: @escaping (String, HookTree.Members) -> Bool) -> [RenderedLine] {
        var renderer = SettingsLineRenderer(indent: indent, tags: tags, changedForeign: changedForeign, shown: shown)
        renderer.renderRoot(root)
        return renderer.lines
    }

    /// One handler's identity across both trees: its event and exact content.
    static func handlerKey(event: String, _ handler: HookTree.Members) -> String {
        event + "\u{1F}" + JSONWriter.compact(.object(handler))
    }

    /// A foreign group (or old-shape handler) the change keeps as it is.
    private func isKeptForeign(event: String, group: OrderedJSON) -> Bool {
        guard !changedForeign.isEmpty, let members = group.objectMembers else { return true }
        if HookTree.isOldShape(members) { return !changedForeign.contains(Self.handlerKey(event: event, members)) }
        let handlers = members.last(where: { $0.key == "hooks" })?.value.arrayElements ?? []
        return !handlers.contains { h in h.objectMembers.map { changedForeign.contains(Self.handlerKey(event: event, $0)) } ?? false }
    }

    private mutating func add(_ level: Int, _ content: String, _ member: String?, tag: Int = 0, foreign: Bool = false) {
        let text = level == 0 ? content : String(repeating: gap, count: level) + content
        lines.append(RenderedLine(text: text, member: member, tag: tag, foreign: foreign))
    }

    private func comma(_ more: Bool) -> String { more ? "," : "" }

    private mutating func renderRoot(_ root: OrderedJSON) {
        guard case .object(let members) = root, !members.isEmpty, !gap.isEmpty else {
            add(0, root.serialized(indent: gap), nil)
            return
        }
        add(0, "{", nil)
        for (i, member) in members.enumerated() {
            let more = i < members.count - 1
            let prefix = JSONWriter.quoted(member.key) + ": "
            if member.key == "hooks", case .object(let events) = member.value, !events.isEmpty {
                add(1, prefix + "{", "hooks")
                for (j, event) in events.enumerated() {
                    let moreEvents = j < events.count - 1
                    let eventPrefix = JSONWriter.quoted(event.key) + ": "
                    if case .array(let groups) = event.value, !groups.isEmpty {
                        add(2, eventPrefix + "[", "hooks")
                        for (k, group) in groups.enumerated() {
                            renderGroup(group, event: event.key, level: 3, more: k < groups.count - 1)
                        }
                        add(2, "]" + comma(moreEvents), "hooks")
                    } else {
                        // `[]` carries nothing; any other shape is not ours to show.
                        let isArray = event.value.arrayElements != nil
                        emit(event.value, level: 2, prefix: eventPrefix, more: moreEvents, member: "hooks",
                             tag: isArray ? 0 : tags.id(event: event.key, event.value), foreign: !isArray)
                    }
                }
                add(1, "}" + comma(more), "hooks")
            } else {
                emit(member.value, level: 1, prefix: prefix, more: more, member: member.key, tag: 0, foreign: false)
            }
        }
        add(0, "}", nil)
    }

    private mutating func renderGroup(_ group: OrderedJSON, event: String, level: Int, more: Bool) {
        let groupTag = tags.id(event: event, group)
        guard case .object(let members) = group else {
            emit(group, level: level, prefix: "", more: more, member: "hooks", tag: groupTag, foreign: true)
            return
        }
        if HookTree.isOldShape(members) {
            emit(group, level: level, prefix: "", more: more, member: "hooks", tag: groupTag,
                 foreign: !shown(event, members) && isKeptForeign(event: event, group: group))
            return
        }
        let handlers = members.last(where: { $0.key == "hooks" })?.value.arrayElements ?? []
        let anyShown = handlers.contains { h in h.objectMembers.map { shown(event, $0) } ?? false }
        guard anyShown else {
            emit(group, level: level, prefix: "", more: more, member: "hooks", tag: groupTag,
                 foreign: isKeptForeign(event: event, group: group))
            return
        }
        // A group holding a handler the plan acts on: its own lines are shown, other handlers
        // inside it stay foreign.
        add(level, "{", "hooks", tag: groupTag)
        let hooksIndex = members.lastIndex(where: { $0.key == "hooks" })
        for (i, member) in members.enumerated() {
            let moreMembers = i < members.count - 1
            let prefix = JSONWriter.quoted(member.key) + ": "
            if i == hooksIndex, case .array(let list) = member.value, !list.isEmpty {
                add(level + 1, prefix + "[", "hooks", tag: groupTag)
                for (k, handler) in list.enumerated() {
                    let isShown = handler.objectMembers.map { shown(event, $0) || changedForeign.contains(Self.handlerKey(event: event, $0)) }
                        ?? false
                    emit(handler, level: level + 2, prefix: "", more: k < list.count - 1, member: "hooks",
                         tag: tags.id(event: event, handler), foreign: !isShown)
                }
                add(level + 1, "]" + comma(moreMembers), "hooks", tag: groupTag)
            } else {
                emit(member.value, level: level + 1, prefix: prefix, more: moreMembers, member: "hooks", tag: groupTag, foreign: false)
            }
        }
        add(level, "}" + comma(more), "hooks", tag: groupTag)
    }

    private mutating func emit(_ value: OrderedJSON, level: Int, prefix: String, more: Bool,
                               member: String?, tag: Int, foreign: Bool) {
        switch value {
        case .object(let members) where !members.isEmpty:
            add(level, prefix + "{", member, tag: tag, foreign: foreign)
            for (i, m) in members.enumerated() {
                emit(m.value, level: level + 1, prefix: JSONWriter.quoted(m.key) + ": ", more: i < members.count - 1,
                     member: member, tag: tag, foreign: foreign)
            }
            add(level, "}" + comma(more), member, tag: tag, foreign: foreign)
        case .array(let elements) where !elements.isEmpty:
            add(level, prefix + "[", member, tag: tag, foreign: foreign)
            for (i, element) in elements.enumerated() {
                emit(element, level: level + 1, prefix: "", more: i < elements.count - 1, member: member, tag: tag, foreign: foreign)
            }
            add(level, "]" + comma(more), member, tag: tag, foreign: foreign)
        default:
            add(level, prefix + JSONWriter.compact(value) + comma(more), member, tag: tag, foreign: foreign)
        }
    }
}

/// Unified diff of the `hooks` and `statusLine` members only (each member is diffed on its own
/// block of lines, so nothing outside them can appear), with real file line numbers.
enum SettingsDiff {
    static let scope = ["hooks", "statusLine"]
    static let contextLines = 2

    struct Result {
        var lines: [DiffLine] = []
        var added = 0
        var removed = 0
    }

    static func elidedText(_ count: Int) -> String { "…（保留既有 \(count) 組 hook）" }

    static func make(old: [RenderedLine], new: [RenderedLine]) -> Result {
        let oldOrder = memberOrder(old), newOrder = memberOrder(new)
        var sections: [(position: Int, lines: [DiffLine])] = []
        var interned: [String: Int] = [:]
        func key(_ line: RenderedLine) -> Int {
            let k = "\(line.tag)\u{1}\(line.text)"
            if let id = interned[k] { return id }
            let id = interned.count
            interned[k] = id
            return id
        }
        for member in scope where oldOrder.contains(member) || newOrder.contains(member) {
            let o = block(member, in: old, order: oldOrder, otherOrder: newOrder)
            let n = block(member, in: new, order: newOrder, otherOrder: oldOrder)
            let oldLines = Array(old[o.range]), newLines = Array(new[n.range])
            let ops = foreignFirst(LineDiff.diff(oldLines.map(key), newLines.map(key)), old: oldLines, new: newLines)
            let hunks = hunkLines(ops, member: member, old: oldLines, oldStart: o.start, new: newLines, newStart: n.start)
            if !hunks.isEmpty { sections.append((n.start, hunks)) }
        }
        var result = Result()
        for section in sections.sorted(by: { $0.position < $1.position }) {
            result.lines.append(contentsOf: section.lines)
        }
        for line in result.lines {
            if line.kind == .added { result.added += 1 }
            if line.kind == .removed { result.removed += 1 }
        }
        return result
    }

    /// Within each block of changes, moves the leading foreign removals and additions to the
    /// front. Removing the last group of an event turns the kept group before it from `},` into
    /// `}`; without this the `}` lands after the removed lines as a second elided line.
    /// Removals keep their order and additions theirs, so the diff stays valid.
    static func foreignFirst(_ ops: [LineDiff.Op], old: [RenderedLine], new: [RenderedLine]) -> [LineDiff.Op] {
        var out: [LineDiff.Op] = []
        out.reserveCapacity(ops.count)
        var k = 0
        while k < ops.count {
            if case .equal = ops[k] {
                out.append(ops[k])
                k += 1
                continue
            }
            var deletes: [LineDiff.Op] = [], inserts: [LineDiff.Op] = []
            block: while k < ops.count {
                switch ops[k] {
                case .equal: break block
                case .delete: deletes.append(ops[k])
                case .insert: inserts.append(ops[k])
                }
                k += 1
            }
            func isForeign(_ op: LineDiff.Op) -> Bool {
                switch op {
                case .delete(let o): old[o].foreign
                case .insert(let n): new[n].foreign
                case .equal: false
                }
            }
            let foreignDeletes = deletes.prefix(while: isForeign).count
            let foreignInserts = inserts.prefix(while: isForeign).count
            out.append(contentsOf: deletes[..<foreignDeletes])
            out.append(contentsOf: inserts[..<foreignInserts])
            out.append(contentsOf: deletes[foreignDeletes...])
            out.append(contentsOf: inserts[foreignInserts...])
        }
        return out
    }

    private static func memberOrder(_ lines: [RenderedLine]) -> [String] {
        var order: [String] = []
        for line in lines {
            if let m = line.member, order.last != m { order.append(m) }
        }
        return order
    }

    /// The member's line range and the 1-based number of its first line. A member missing on
    /// this side gets an empty range placed after the nearest preceding member (in the other
    /// side's order) that does exist here.
    private static func block(_ member: String, in lines: [RenderedLine], order: [String],
                              otherOrder: [String]) -> (range: Range<Int>, start: Int) {
        if let first = lines.firstIndex(where: { $0.member == member }),
           let last = lines.lastIndex(where: { $0.member == member }) {
            return (first..<(last + 1), first + 1)
        }
        var anchor = lines.isEmpty ? 0 : 1
        if let at = otherOrder.firstIndex(of: member) {
            for previous in otherOrder[..<at].reversed() where order.contains(previous) {
                if let last = lines.lastIndex(where: { $0.member == previous }) {
                    anchor = last + 1
                    break
                }
            }
        }
        return (anchor..<anchor, anchor + 1)
    }

    /// Unified hunks (``contextLines`` of context) of `ops` over the member's lines, numbered from
    /// `oldStart` / `newStart`; each run of foreign lines becomes one `elided(count of their tags)`
    /// line.
    static func hunkLines(_ ops: [LineDiff.Op], member: String, old: [RenderedLine], oldStart: Int,
                          new: [RenderedLine], newStart: Int,
                          elided: (Int) -> String = { SettingsDiff.elidedText($0) }) -> [DiffLine] {
        let changes = ops.indices.filter { if case .equal = ops[$0] { return false } else { return true } }
        guard let firstChange = changes.first else { return [] }
        var ranges: [Range<Int>] = []
        var start = max(0, firstChange - contextLines)
        var end = min(ops.count, firstChange + 1 + contextLines)
        for index in changes.dropFirst() {
            if index - contextLines <= end {
                end = min(ops.count, index + 1 + contextLines)
            } else {
                ranges.append(start..<end)
                start = index - contextLines
                end = min(ops.count, index + 1 + contextLines)
            }
        }
        ranges.append(start..<end)

        // Old / new lines consumed before each op.
        var oldBefore = [Int](repeating: 0, count: ops.count + 1)
        var newBefore = [Int](repeating: 0, count: ops.count + 1)
        for (k, op) in ops.enumerated() {
            switch op {
            case .equal: oldBefore[k + 1] = oldBefore[k] + 1; newBefore[k + 1] = newBefore[k] + 1
            case .delete: oldBefore[k + 1] = oldBefore[k] + 1; newBefore[k + 1] = newBefore[k]
            case .insert: oldBefore[k + 1] = oldBefore[k]; newBefore[k + 1] = newBefore[k] + 1
            }
        }

        var out: [DiffLine] = []
        for range in ranges {
            let oldCount = oldBefore[range.upperBound] - oldBefore[range.lowerBound]
            let newCount = newBefore[range.upperBound] - newBefore[range.lowerBound]
            let a = oldStart + oldBefore[range.lowerBound] - (oldCount == 0 ? 1 : 0)
            let c = newStart + newBefore[range.lowerBound] - (newCount == 0 ? 1 : 0)
            out.append(DiffLine(kind: .hunk, text: "@@ -\(a),\(oldCount) +\(c),\(newCount) @@  \(JSONWriter.quoted(member))"))

            var foreignTags: Set<Int> = []
            func flush() {
                if !foreignTags.isEmpty {
                    out.append(DiffLine(kind: .elided, text: elided(foreignTags.count)))
                    foreignTags.removeAll()
                }
            }
            for op in ops[range] {
                let line: DiffLine
                let source: RenderedLine
                let foreign: Bool
                switch op {
                case .equal(let o, let n):
                    source = old[o]
                    foreign = old[o].foreign || new[n].foreign
                    line = DiffLine(kind: .context, oldNumber: oldStart + o, newNumber: newStart + n,
                                    text: old[o].display ?? old[o].text)
                case .delete(let o):
                    source = old[o]
                    foreign = old[o].foreign
                    line = DiffLine(kind: .removed, oldNumber: oldStart + o, text: old[o].display ?? old[o].text)
                case .insert(let n):
                    source = new[n]
                    foreign = new[n].foreign
                    line = DiffLine(kind: .added, newNumber: newStart + n, text: new[n].display ?? new[n].text)
                }
                if foreign {
                    foreignTags.insert(source.tag)
                } else {
                    flush()
                    out.append(line)
                }
            }
            flush()
        }
        return out
    }
}

/// Myers' O((N+M)·D) line diff on interned line keys, with common prefix / suffix trimmed first.
enum LineDiff {
    enum Op: Equatable {
        case equal(Int, Int)
        case delete(Int)
        case insert(Int)
    }

    /// Above this many edits the diff degrades to "all removed, all added" (bounded memory).
    static let maximumEdits = 1000

    static func diff(_ a: [Int], _ b: [Int]) -> [Op] {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var ops: [Op] = (0..<prefix).map { .equal($0, $0) }
        let middle = core(Array(a[prefix..<(a.count - suffix)]), Array(b[prefix..<(b.count - suffix)]))
        for op in middle {
            switch op {
            case .equal(let x, let y): ops.append(.equal(x + prefix, y + prefix))
            case .delete(let x): ops.append(.delete(x + prefix))
            case .insert(let y): ops.append(.insert(y + prefix))
            }
        }
        for k in 0..<suffix { ops.append(.equal(a.count - suffix + k, b.count - suffix + k)) }
        return ops
    }

    private static func core(_ a: [Int], _ b: [Int]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { .insert($0) } }
        if m == 0 { return (0..<n).map { .delete($0) } }
        let limit = min(n + m, maximumEdits)
        let offset = n + m + 1
        var v = [Int](repeating: 0, count: 2 * offset + 1)
        // trace[d] = v[-d...d] after step d: O(D²) memory.
        var trace: [[Int]] = []
        var found = -1
        search: for d in 0...limit {
            var k = -d
            while k <= d {
                var x = (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]))
                    ? v[offset + k + 1]
                    : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    trace.append(Array(v[(offset - d)...(offset + d)]))
                    found = d
                    break search
                }
                k += 2
            }
            trace.append(Array(v[(offset - d)...(offset + d)]))
        }
        guard found >= 0 else {
            return (0..<n).map { .delete($0) } + (0..<m).map { .insert($0) }
        }
        var ops: [Op] = []
        var x = n, y = m
        var d = found
        while d > 0 {
            let previous = trace[d - 1]
            let k = x - y
            let down = k == -d || (k != d && previous[k - 1 + d - 1] < previous[k + 1 + d - 1])
            let previousK = down ? k + 1 : k - 1
            let previousX = previous[previousK + d - 1]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                ops.append(.equal(x - 1, y - 1))
                x -= 1
                y -= 1
            }
            if down {
                ops.append(.insert(y - 1))
            } else {
                ops.append(.delete(x - 1))
            }
            x = previousX
            y = previousY
            d -= 1
        }
        while x > 0, y > 0 {
            ops.append(.equal(x - 1, y - 1))
            x -= 1
            y -= 1
        }
        return ops.reversed()
    }
}
