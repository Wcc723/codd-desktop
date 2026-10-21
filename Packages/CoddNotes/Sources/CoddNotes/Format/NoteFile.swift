import Foundation

/// A note file parsed into what the index stores (§3.2 keys, D2 / D3 rules).
struct ParsedNote: Sendable {
    var declaredID: NoteID?
    var title: String
    var titleFromH1: Bool
    var kind: NoteKind
    var tags: [String]
    var sessions: [String]
    var projects: [String]
    /// nil: no valid `ai:` key (the library's default access applies).
    var ai: NoteAIAccess?
    var scope: NoteScope
    var pinned: Bool
    var archived: Bool
    var archivedAt: Date?
    var archivedBy: ArchiveReason?
    var trashedAt: Date?
    var sentAt: Date?
    var sentTo: String?
    var created: Date?
    var updated: Date?
    var condensedFrom: [NoteID]
    var condensedInto: NoteID?
    var createdBy: String
    /// LF line ends.
    var body: String
    var lineEnding: NoteLineEnding
    var flags: NoteFlags
    var hash: String
    var plain: String
    var snippet: String
    var frontmatter: Frontmatter?
}

enum NoteFile {
    static let untitled = "未命名筆記"

    static func decodeText(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    static func parse(data: Data, timeZone: TimeZone) -> ParsedNote {
        let text = decodeText(data)
        let (fm, rawBody, _) = Frontmatter.split(text)
        let crlf: Bool
        if let fm {
            crlf = fm.lineEnding == .crlf
        } else if let firstBreak = text.firstIndex(where: { $0 == "\n" || $0 == "\r\n" }) {
            crlf = text[firstBreak] == "\r\n"
        } else {
            crlf = false
        }
        let body = rawBody.contains("\r\n") ? rawBody.replacingOccurrences(of: "\r\n", with: "\n") : rawBody
        var flags: NoteFlags = []
        if fm == nil { flags.insert(.noFrontmatter) }
        let parsable = fm?.isParsable ?? true
        if !parsable { flags.insert(.unparsableFrontmatter) }
        // An unparsable frontmatter keeps only a recognisable `id:` line, so references survive (D2).
        let usable = parsable ? fm : nil

        func date(_ key: String) -> Date? { usable?.scalar(key).flatMap { ISODate.parse($0, timeZone: timeZone) } }
        func strings(_ key: String) -> [String] {
            if let l = usable?.list(key) { return l }
            if let s = usable?.scalar(key) {
                return s.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
            }
            return []
        }

        var declared: NoteID?
        if let s = usable?.scalar("id") {
            declared = NoteID(rawValue: s.trimmingCharacters(in: .whitespaces))
        } else if !parsable, let fm {
            for line in fm.lines {
                let t = line.text
                if t.hasPrefix("id:") {
                    let v = t.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
                    declared = NoteID(rawValue: v)
                    break
                }
            }
        }

        let lines = BodyLines.split(body)
        let h1 = MarkdownText.firstH1(lines)
        let fmTitle = usable?.scalar("title")?.trimmingCharacters(in: .whitespaces)
        let title = h1?.title ?? ((fmTitle?.isEmpty == false) ? fmTitle! : untitled)

        let tags = normalizeTags(strings("tags"))
        let sessions = dedupe(strings("sessions").map { $0.lowercased() })
        let projects = dedupe(strings("projects").map { HomePath.abbreviate($0) }.filter { !$0.isEmpty })
        let kind = usable?.scalar("kind").flatMap { NoteKind(rawValue: $0.lowercased()) } ?? .note
        let ai = usable?.scalar("ai").flatMap { NoteAIAccess(rawValue: $0.lowercased()) }
        let scope = usable?.scalar("scope").flatMap { NoteScope(rawValue: $0.lowercased()) }
            ?? (projects.isEmpty && sessions.isEmpty ? .global : .project)
        let pinned = usable?.scalar("pinned").map(isTrue) ?? false
        let archived = usable?.scalar("status")?.lowercased() == "archived"
        let condensedFrom = strings("condensedFrom").compactMap { NoteID(rawValue: $0) }
        let plain = MarkdownText.plainText(lines: lines, titleLine: .some(h1?.line))
        return ParsedNote(
            declaredID: declared, title: title, titleFromH1: h1 != nil, kind: kind, tags: tags, sessions: sessions,
            projects: projects, ai: ai, scope: scope, pinned: pinned, archived: archived, archivedAt: date("archived"),
            archivedBy: usable?.scalar("archivedBy").flatMap { ArchiveReason(rawValue: $0.lowercased()) },
            trashedAt: date("trashed"), sentAt: date("sent"), sentTo: usable?.scalar("sentTo")?.lowercased(),
            created: date("created"), updated: date("updated"), condensedFrom: condensedFrom,
            condensedInto: usable?.scalar("condensedInto").flatMap { NoteID(rawValue: $0) },
            createdBy: usable?.scalar("createdBy") ?? "user", body: body, lineEnding: crlf ? .crlf : .lf, flags: flags,
            hash: Hashing.sha256Hex(data), plain: plain, snippet: MarkdownText.snippet(plain), frontmatter: fm)
    }

    static func isTrue(_ s: String) -> Bool {
        ["true", "yes", "on", "1"].contains(s.lowercased())
    }

    static func normalizeTags(_ raw: [String]) -> [String] {
        var out: [String] = []
        for t in raw {
            var s = t.trimmingCharacters(in: .whitespaces).precomposedStringWithCanonicalMapping
            while s.hasPrefix("#") { s.removeFirst() }
            guard !s.isEmpty, !out.contains(where: { $0.lowercased() == s.lowercased() }) else { continue }
            out.append(s)
        }
        return out
    }

    static func dedupe(_ a: [String]) -> [String] {
        var out: [String] = []
        for s in a where !s.isEmpty && !out.contains(s) { out.append(s) }
        return out
    }

    /// The file text: the frontmatter text as is, then the body with the file's line ends.
    static func compose(frontmatter: Frontmatter?, body: String, lineEnding: NoteLineEnding) -> String {
        let b = lineEnding == .crlf ? body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : body
        return (frontmatter?.serialized() ?? "") + b
    }
}
