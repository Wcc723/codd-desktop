import Foundation

/// Parses `git status --porcelain=v2 --branch -z` output. With `-z` every header and entry ends in
/// NUL, paths are never quoted (spaces, CJK and newlines arrive as raw bytes), and a rename / copy
/// entry is followed by its original path as one more NUL-terminated field.
enum GitStatusParser {
    static func parse(_ data: Data, root: URL) throws -> GitRepoStatus {
        var status = GitRepoStatus(root: root)
        var fields = split(data)[...]
        while let field = fields.popFirst() {
            guard let kind = field.first else { continue }
            switch kind {
            case UInt8(ascii: "#"):
                header(text(field), into: &status)
            case UInt8(ascii: "1"):
                // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
                let (parts, path) = try entry(field, fixed: 8)
                status.changes[path] = change(xy: parts[1])
            case UInt8(ascii: "2"):
                // 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path> NUL <origPath>
                let (parts, path) = try entry(field, fixed: 9)
                guard let original = fields.popFirst() else { throw GitError.malformed("rename without its original path") }
                let score = parts[8]
                status.changes[path] = score.hasPrefix("C") ? .copied : .renamed
                status.renamedFrom[path] = text(original)
            case UInt8(ascii: "u"):
                // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
                let (_, path) = try entry(field, fixed: 10)
                status.changes[path] = .conflicted
            case UInt8(ascii: "?"):
                status.changes[String(text(field).dropFirst(2))] = .untracked
            case UInt8(ascii: "!"):
                continue // ignored entries only appear with --ignored, which the reader never passes
            default:
                throw GitError.malformed("unknown entry kind \(Character(UnicodeScalar(kind)))")
            }
        }
        return status
    }

    /// NUL-terminated fields (the last one may lack its NUL).
    private static func split(_ data: Data) -> [Data] {
        var out: [Data] = []
        var start = data.startIndex
        for index in data.indices where data[index] == 0 {
            out.append(data[start..<index])
            start = data.index(after: index)
        }
        if start < data.endIndex { out.append(data[start..<data.endIndex]) }
        return out
    }

    private static func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    /// The first `fixed` space-separated fields after the kind, then the path (which may contain spaces).
    private static func entry(_ field: Data, fixed: Int) throws -> (parts: [String], path: String) {
        let line = text(field)
        let parts = line.split(separator: " ", maxSplits: fixed, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == fixed + 1, !parts[fixed].isEmpty else { throw GitError.malformed("short entry: \(line.prefix(80))") }
        return (Array(parts.prefix(fixed)), parts[fixed])
    }

    private static func header(_ line: String, into status: inout GitRepoStatus) {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 3 else { return }
        let value = parts[2]
        switch parts[1] {
        case "branch.oid":
            status.headOID = value == "(initial)" ? nil : value
        case "branch.head":
            if value == "(detached)" {
                status.detached = true
                status.branch = nil
            } else {
                status.branch = value
            }
        case "branch.upstream":
            status.upstream = value
        case "branch.ab":
            for token in value.split(separator: " ") {
                if token.hasPrefix("+") { status.ahead = Int(token.dropFirst()) ?? 0 }
                if token.hasPrefix("-") { status.behind = Int(token.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    /// `XY` (index, work tree; `.` = unchanged) to the one change the tree shows.
    private static func change(xy: String) -> GitFileChange {
        let codes = Array(xy)
        let x = codes.first ?? "."
        let y = codes.count > 1 ? codes[1] : "."
        if x == "D" || y == "D" { return .deleted }
        if x == "A" { return .added }
        if x == "T" || y == "T" { return .typeChanged }
        return .modified
    }
}
