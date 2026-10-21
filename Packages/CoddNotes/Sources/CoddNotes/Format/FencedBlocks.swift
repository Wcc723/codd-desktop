import Foundation

/// A line of a Markdown body with its UTF-16 position (for `NSRange`s the editor can use).
struct BodyLine: Sendable, Equatable {
    var text: String
    /// UTF-16 offset of the line start in the body.
    var offset: Int
    /// UTF-16 length of the line text (without the terminator).
    var length: Int
    /// UTF-16 length of the terminator (`\n` = 1, `\r\n` = 2, last line 0).
    var terminator: Int

    var end: Int { offset + length + terminator }
}

enum BodyLines {
    /// Lines with UTF-16 offsets (a CRLF is one terminator of 2 units). Built on the standard
    /// library's optimized split and UTF-16 count, which matters in debug builds.
    static func split(_ body: String) -> [BodyLine] {
        var out: [BodyLine] = []
        var offset = 0
        let parts = body.utf8.split(separator: 10, omittingEmptySubsequences: false)
        out.reserveCapacity(parts.count)
        for (k, part) in parts.enumerated() {
            let isLast = k == parts.count - 1
            if isLast, part.isEmpty, !out.isEmpty { break }
            var sub = Substring(part)
            var term = isLast ? 0 : 1
            if !isLast, sub.utf8.last == 13 {
                sub = sub.dropLast()
                term = 2
            }
            let text = String(sub)
            let len = text.utf16.count
            out.append(BodyLine(text: text, offset: offset, length: len, terminator: term))
            offset += len + term
        }
        return out
    }

    /// UTF-16 units of a valid UTF-8 byte range: one per scalar, two for 4-byte scalars.
    static func utf16Count(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Int {
        String(decoding: bytes[from..<to], as: UTF8.self).utf16.count
    }
}

/// An image on a line of its own: `![alt](path)` (optionally `![alt](<path with spaces>)` or with a title).
public struct ImageLine: Sendable, Equatable {
    public var line: Int
    public var alt: String
    public var path: String
}

/// A fenced code block (``` or ~~~).
public struct FencedBlock: Sendable, Equatable {
    /// The info string after the opening fence (`codd-annotations`).
    public var info: String
    /// The lines between the fences, joined with `\n`.
    public var content: String
    /// UTF-16 range of the whole block, opening fence to the closing fence's terminator.
    public var range: NSRange
    /// UTF-16 range of the content lines.
    public var contentRange: NSRange
    /// 0-based line of the opening fence.
    public var startLine: Int
    /// 0-based line of the closing fence (the last line when the block is never closed).
    public var endLine: Int
    /// The image line directly above the opening fence, if any (D10: one block per image).
    public var imageLine: Int?
    public var imagePath: String?
}

public enum FencedBlocks {
    /// Every fenced block whose info string's first word is `info` (case-sensitive), in body order.
    public static func find(info: String, in body: String) -> [FencedBlock] {
        all(in: body).filter { $0.info.split(separator: " ").first.map(String.init) == info }
    }

    /// Replaces the `info` block that follows image line `imageLine` (0-based) with one holding
    /// `json`, inserts it after the image line when there is none, or removes it when `json` is nil.
    /// Every other byte of the body stays as it was.
    public static func replacingBlock(after imageLine: Int, info: String, with json: String?, in body: String) -> String {
        let lines = BodyLines.split(body)
        guard imageLine >= 0, imageLine < lines.count else { return body }
        let ns = body as NSString
        let nl = lines[imageLine].terminator == 2 ? "\r\n" : "\n"
        let existing = find(info: info, in: body).first { $0.imageLine == imageLine }
        let blockText = json.map { "```\(info)\(nl)\($0)\(nl)```" }
        if let existing {
            let r = existing.range
            if let blockText {
                // Keep the old block's terminator (or none at the end of the body).
                let endsWithTerminator = r.location + r.length <= ns.length && lines[existing.endLine].terminator > 0
                return ns.replacingCharacters(in: r, with: blockText + (endsWithTerminator ? nl : ""))
            }
            return ns.replacingCharacters(in: r, with: "")
        }
        guard let blockText else { return body }
        let image = lines[imageLine]
        if image.terminator == 0 {
            return body + nl + blockText
        }
        return ns.replacingCharacters(in: NSRange(location: image.end, length: 0), with: blockText + nl)
    }

    /// Image lines of the body (outside code blocks).
    public static func imageLines(in body: String) -> [ImageLine] {
        imageLines(BodyLines.split(body))
    }

    static func imageLines(_ lines: [BodyLine]) -> [ImageLine] {
        var out: [ImageLine] = []
        var fence: Fence?
        for (k, l) in lines.enumerated() {
            if let f = fence {
                if f.closes(l.text) { fence = nil }
                continue
            }
            if let f = Fence(opening: l.text) {
                fence = f
                continue
            }
            if let (alt, path) = parseImage(l.text) { out.append(ImageLine(line: k, alt: alt, path: path)) }
        }
        return out
    }

    static func all(in body: String) -> [FencedBlock] {
        let lines = BodyLines.split(body)
        var out: [FencedBlock] = []
        var k = 0
        while k < lines.count {
            guard let f = Fence(opening: lines[k].text) else {
                k += 1
                continue
            }
            var j = k + 1
            while j < lines.count, !f.closes(lines[j].text) { j += 1 }
            let closed = j < lines.count
            let endLine = closed ? j : lines.count - 1
            let contentLines = closed ? Array(lines[(k + 1)..<j]) : Array(lines[min(k + 1, lines.count)...])
            let start = lines[k].offset
            let end = lines[endLine].end
            let contentStart = k + 1 < lines.count ? lines[k + 1].offset : lines[k].end
            let contentEnd = contentLines.last.map { $0.offset + $0.length } ?? contentStart
            var imageLine: Int?
            var imagePath: String?
            if k > 0, let (_, path) = parseImage(lines[k - 1].text) {
                imageLine = k - 1
                imagePath = path
            }
            out.append(FencedBlock(
                info: f.info, content: contentLines.map(\.text).joined(separator: "\n"),
                range: NSRange(location: start, length: end - start),
                contentRange: NSRange(location: contentStart, length: max(0, contentEnd - contentStart)),
                startLine: k, endLine: endLine, imageLine: imageLine, imagePath: imagePath))
            k = endLine + 1
        }
        return out
    }

    /// `![alt](path)` alone on a line (leading / trailing blanks allowed).
    static func parseImage(_ line: String) -> (String, String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("!["), t.hasSuffix(")") else { return nil }
        guard let altEnd = t.range(of: "](") else { return nil }
        let alt = String(t[t.index(t.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        var dest = String(t[altEnd.upperBound..<t.index(before: t.endIndex)])
        if dest.hasPrefix("<") {
            guard let close = dest.firstIndex(of: ">") else { return nil }
            dest = String(dest[dest.index(after: dest.startIndex)..<close])
        } else {
            // Drop an optional title: `path "title"`.
            if let space = dest.firstIndex(of: " ") { dest = String(dest[..<space]) }
        }
        guard !dest.isEmpty, !alt.contains("](") else { return nil }
        return (alt, dest)
    }
}

/// A fence opening line: up to 3 spaces, then ≥ 3 backticks or tildes, then the info string.
struct Fence {
    let char: Character
    let length: Int
    let info: String

    init?(opening line: String) {
        // Fast reject: the first non-blank byte must be a backtick or a tilde.
        var firstByte: UInt8 = 0
        for b in line.utf8 where b != 32 {
            firstByte = b
            break
        }
        guard firstByte == 96 || firstByte == 126 else { return nil }
        var t = Substring(line)
        var indent = 0
        while t.first == " ", indent < 4 {
            t.removeFirst()
            indent += 1
        }
        guard indent < 4, let c = t.first, c == "`" || c == "~" else { return nil }
        var n = 0
        while t.first == c {
            t.removeFirst()
            n += 1
        }
        guard n >= 3 else { return nil }
        let rest = t.trimmingCharacters(in: .whitespaces)
        if c == "`", rest.contains("`") { return nil }
        char = c
        length = n
        info = rest
    }

    func closes(_ line: String) -> Bool {
        var t = Substring(line)
        var indent = 0
        while t.first == " ", indent < 4 {
            t.removeFirst()
            indent += 1
        }
        guard indent < 4 else { return false }
        var n = 0
        while t.first == char {
            t.removeFirst()
            n += 1
        }
        return n >= length && t.allSatisfy { $0 == " " || $0 == "\t" }
    }
}
