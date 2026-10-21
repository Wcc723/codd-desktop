import Foundation

/// The byte encodings the editor reads and writes back unchanged (D24).
public enum TextEncodingKind: String, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE, big5, latin1
}

public enum LineEnding: String, Sendable {
    case lf, crlf, cr

    /// The terminator's bytes in an ASCII-compatible encoding.
    public var text: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }
}

public enum Indentation: Sendable, Equatable {
    case spaces(Int), tabs, unknown
}

/// A file's text plus every fact needed to write it back byte for byte.
///
/// `text` is LF-normalized and does NOT contain the file's final line terminator (a file
/// `a⏎b⏎` reads as `"a\nb"` with `hasFinalNewline`); ``TextFileCodec/encode(_:like:)`` appends it
/// again, so the final newline is written back exactly as it was.
public struct DecodedText: Sendable, Equatable {
    public var text: String
    public var encoding: TextEncodingKind
    /// The most frequent terminator (ties: LF, then CRLF, then CR; LF when there is none).
    public var lineEnding: LineEnding
    public var mixedLineEndings: Bool
    /// Per line, the terminator after it (only when mixed): `lineEndings[i]` ends line `i`; the
    /// last line has one only when `hasFinalNewline`.
    public var lineEndings: [LineEnding]?
    public var hasFinalNewline: Bool
    public var indentation: Indentation
    /// Latin-1 fallback (the bytes are not text CODD can round-trip safely) or larger than
    /// ``TextFileCodec/readOnlyBytes``.
    public var readOnly: Bool

    public init(text: String, encoding: TextEncodingKind = .utf8, lineEnding: LineEnding = .lf, mixedLineEndings: Bool = false,
                lineEndings: [LineEnding]? = nil, hasFinalNewline: Bool = true, indentation: Indentation = .unknown, readOnly: Bool = false) {
        self.text = text
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.mixedLineEndings = mixedLineEndings
        self.lineEndings = lineEndings
        self.hasFinalNewline = hasFinalNewline
        self.indentation = indentation
        self.readOnly = readOnly
    }

    /// `text` split into lines (never empty: an empty text is one empty line).
    public var lines: [String] { TextFileCodec.lines(text) }
}

public enum TextFileError: Error, Equatable, Sendable {
    /// NUL in the first ``TextFileCodec/binarySniffBytes`` bytes (or undecodable UTF-16).
    case binary
    /// Larger than ``TextFileCodec/refuseBytes``.
    case tooLarge(Int)
    /// The text has characters the file's encoding cannot hold (an emoji typed into a Big5 file).
    case unencodable(TextEncodingKind)
}

/// Bytes ↔ ``DecodedText`` (D24): binary sniff, size limits, encoding detection (BOM, UTF-8,
/// Big5, Latin-1), line endings, final newline and indentation.
public enum TextFileCodec {
    public static let binarySniffBytes = 8192
    public static let readOnlyBytes = 5 * 1024 * 1024
    public static let refuseBytes = 50 * 1024 * 1024

    /// Traditional Chinese Big5 as Windows writes it (code page 950, a superset of Big5 for the
    /// characters Taiwan files use). Accepted only when the bytes are not valid UTF-8, decode, and
    /// encode back to exactly the same bytes.
    static let big5Encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.dosChineseTrad.rawValue)))

    public static func decode(_ data: Data) -> Result<DecodedText, TextFileError> {
        if data.count > refuseBytes { return .failure(.tooLarge(data.count)) }
        let bytes = [UInt8](data)
        var kind: TextEncodingKind
        var decoded: String
        var readOnly = data.count > readOnlyBytes
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            if bytes.prefix(binarySniffBytes).contains(0) { return .failure(.binary) }
            guard let text = String(validating: bytes.dropFirst(3), as: UTF8.self) else {
                // A UTF-8 BOM in front of bytes that are not UTF-8: shown, never written.
                return .success(analyze(latin1(bytes), encoding: .latin1, readOnly: true))
            }
            kind = .utf8BOM
            decoded = text
        } else if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            let little = bytes[0] == 0xFF
            let body = Data(bytes.dropFirst(2))
            guard let text = String(data: body, encoding: little ? .utf16LittleEndian : .utf16BigEndian),
                  !text.unicodeScalars.contains("\0"),
                  text.data(using: little ? .utf16LittleEndian : .utf16BigEndian) == body
            else { return .failure(.binary) }
            kind = little ? .utf16LE : .utf16BE
            decoded = text
        } else {
            if bytes.prefix(binarySniffBytes).contains(0) { return .failure(.binary) }
            if let text = String(validating: bytes, as: UTF8.self) {
                kind = .utf8
                decoded = text
            } else if let text = String(data: data, encoding: big5Encoding), text.data(using: big5Encoding) == data {
                kind = .big5
                decoded = text
            } else {
                kind = .latin1
                decoded = latin1(bytes)
                readOnly = true
            }
        }
        return .success(analyze(decoded, encoding: kind, readOnly: readOnly))
    }

    /// Bytes for `text` written the way `original` was read: its encoding and BOM, its line
    /// endings (a mixed file keeps every unchanged line's own terminator, matched through
    /// ``LineDiff``; inside a changed hunk a replaced line keeps the terminator of the line it
    /// replaces, pairwise; added lines take the majority) and its final newline.
    public static func encode(_ text: String, like original: DecodedText) throws -> Data {
        let newLines = lines(text)
        let endings = lineEndings(for: newLines, like: original)
        var out = ""
        out.reserveCapacity(text.utf8.count + newLines.count)
        for (index, line) in newLines.enumerated() {
            out += line
            if index < newLines.count - 1 || original.hasFinalNewline { out += endings[index].text }
        }
        switch original.encoding {
        case .utf8:
            return Data(out.utf8)
        case .utf8BOM:
            return Data([0xEF, 0xBB, 0xBF]) + Data(out.utf8)
        case .utf16LE:
            guard let body = out.data(using: .utf16LittleEndian) else { throw TextFileError.unencodable(.utf16LE) }
            return Data([0xFF, 0xFE]) + body
        case .utf16BE:
            guard let body = out.data(using: .utf16BigEndian) else { throw TextFileError.unencodable(.utf16BE) }
            return Data([0xFE, 0xFF]) + body
        case .big5:
            guard let body = out.data(using: big5Encoding, allowLossyConversion: false) else { throw TextFileError.unencodable(.big5) }
            return body
        case .latin1:
            guard let body = out.data(using: .isoLatin1, allowLossyConversion: false) else { throw TextFileError.unencodable(.latin1) }
            return body
        }
    }

    /// `text` split on `\n` (an empty text is one empty line).
    public static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Analysis

    /// ISO Latin-1 maps every byte to the scalar of the same value, so it always decodes.
    private static func latin1(_ bytes: [UInt8]) -> String {
        String(data: Data(bytes), encoding: .isoLatin1) ?? String(decoding: bytes, as: Unicode.ASCII.self)
    }

    /// LF-normalizes `decoded` and records its terminators, final newline and indentation.
    static func analyze(_ decoded: String, encoding: TextEncodingKind, readOnly: Bool) -> DecodedText {
        var out = [UInt8]()
        let utf8 = Array(decoded.utf8)
        out.reserveCapacity(utf8.count)
        var endings: [LineEnding] = []
        var i = 0
        while i < utf8.count {
            let byte = utf8[i]
            if byte == 0x0D {
                if i + 1 < utf8.count, utf8[i + 1] == 0x0A {
                    endings.append(.crlf)
                    i += 2
                } else {
                    endings.append(.cr)
                    i += 1
                }
                out.append(0x0A)
            } else {
                if byte == 0x0A { endings.append(.lf) }
                out.append(byte)
                i += 1
            }
        }
        let hasFinalNewline = out.last == 0x0A
        if hasFinalNewline { out.removeLast() }
        let text = String(decoding: out, as: UTF8.self)
        var counts: [LineEnding: Int] = [:]
        for ending in endings { counts[ending, default: 0] += 1 }
        let mixed = counts.count > 1
        return DecodedText(text: text, encoding: encoding, lineEnding: preferredMajority(counts) ?? .lf, mixedLineEndings: mixed,
                           lineEndings: mixed ? endings : nil, hasFinalNewline: hasFinalNewline,
                           indentation: detectIndentation(text), readOnly: readOnly)
    }

    /// Highest count wins; ties go to LF, then CRLF, then CR.
    private static func preferredMajority(_ counts: [LineEnding: Int]) -> LineEnding? {
        var best: LineEnding?
        var bestCount = 0
        for ending in [LineEnding.lf, .crlf, .cr] {
            let count = counts[ending] ?? 0
            if count > bestCount {
                best = ending
                bestCount = count
            }
        }
        return best
    }

    /// The terminator after each of `newLines` (see ``encode(_:like:)``).
    static func lineEndings(for newLines: [String], like original: DecodedText) -> [LineEnding] {
        guard original.mixedLineEndings, let oldEndings = original.lineEndings else {
            return Array(repeating: original.lineEnding, count: newLines.count)
        }
        let oldLines = original.lines
        var result = Array(repeating: original.lineEnding, count: newLines.count)
        func oldEnding(_ index: Int) -> LineEnding { index < oldEndings.count ? oldEndings[index] : original.lineEnding }
        var oldIndex = 0
        var newIndex = 0
        for hunk in LineDiff.hunks(old: oldLines, new: newLines) {
            // Unchanged lines before the hunk keep their own endings.
            while newIndex < hunk.newRange.lowerBound {
                result[newIndex] = oldEnding(oldIndex)
                newIndex += 1
                oldIndex += 1
            }
            // Replaced lines keep the ending of the line they replace, pairwise.
            let paired = min(hunk.oldRange.count, hunk.newRange.count)
            for offset in 0..<paired { result[hunk.newRange.lowerBound + offset] = oldEnding(hunk.oldRange.lowerBound + offset) }
            oldIndex = hunk.oldRange.upperBound
            newIndex = hunk.newRange.upperBound
        }
        while newIndex < newLines.count {
            result[newIndex] = oldEnding(oldIndex)
            newIndex += 1
            oldIndex += 1
        }
        return result
    }

    /// Tabs when more indented lines start with a tab; otherwise the most common positive step
    /// between consecutive indented lines (2, 4, 8, 3), like VS Code's guess. Looks at the first
    /// 10,000 lines.
    static func detectIndentation(_ text: String) -> Indentation {
        var tabLines = 0
        var spaceLines = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var lineCount = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineCount += 1
            if lineCount > 10_000 { break }
            let utf8 = line.utf8
            guard let first = utf8.first else { continue }
            var spaces = 0
            var isBlank = true
            for byte in utf8 {
                if byte == 0x20 { spaces += 1; continue }
                if byte == 0x09 { break }
                isBlank = false
                break
            }
            if first == 0x09 {
                tabLines += 1
                continue
            }
            if isBlank, spaces == utf8.count { continue } // whitespace-only line
            if spaces > 0 { spaceLines += 1 }
            let step = spaces - previous
            if step > 1 { steps[step, default: 0] += 1 }
            previous = spaces
        }
        if tabLines > spaceLines, tabLines > 0 { return .tabs }
        guard spaceLines > 0 else { return .unknown }
        let best = [2, 4, 8, 3, 6].max { (steps[$0] ?? 0) < (steps[$1] ?? 0) } ?? 4
        return steps[best] == nil ? .unknown : .spaces(best)
    }
}
