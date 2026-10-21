/// What one composer send puts on the PTY: the bytes, whether they go as one bracketed paste
/// (holder capability `input.paste`), and whether Enter follows (the holder sends the `\r`).
public struct ComposerPayload: Sendable, Equatable {
    public var bytes: [UInt8]
    public var paste: Bool
    public var submit: Bool

    public init(bytes: [UInt8], paste: Bool, submit: Bool) {
        self.bytes = bytes
        self.paste = paste
        self.submit = submit
    }
}

public enum ComposerEncodingError: Error, Sendable, Equatable {
    /// Nothing left to send after cleaning (only whitespace or control characters).
    case empty
    /// The cleaned text is this many UTF-8 bytes, more than `ComposerEncoding.maxBytes`.
    case tooLong(Int)
}

/// Turns composer text into what goes to the PTY (M2 plan D1, D2). Pure.
///
/// Single-line text is typed as is; anything with a newline or a TAB goes as one paste, because a
/// raw LF would submit early and a raw TAB triggers completion in Claude's prompt. Inside a paste
/// line breaks become CR, the terminal convention for pasted text.
public enum ComposerEncoding {
    /// At most this many UTF-8 bytes per send (the holder's INPUT frame budget).
    public static let maxBytes = 256 << 10

    public static func payload(for text: String, submit: Bool = true) throws(ComposerEncodingError) -> ComposerPayload {
        var scalars = cleaned(text)
        while let last = scalars.last, last.properties.isWhitespace {
            scalars.removeLast()
        }
        guard !scalars.isEmpty else { throw .empty }
        let paste = scalars.contains { $0 == "\n" || $0 == "\t" }
        if paste {
            for index in scalars.indices where scalars[index] == "\n" {
                scalars[index] = "\r"
            }
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let bytes = Array(String(view).utf8)
        guard bytes.count <= maxBytes else { throw .tooLong(bytes.count) }
        return ComposerPayload(bytes: bytes, paste: paste, submit: submit)
    }

    /// Line endings to LF, control characters other than TAB and LF removed.
    ///
    /// CRLF and lone CR become LF; the Unicode line and paragraph separators and NEL do too (the text
    /// view shows them as line breaks, so they are sent as such). C1 controls go with the C0 ones:
    /// U+009B is CSI to an 8-bit-aware parser and none of them has a visible meaning in a prompt.
    static func cleaned(_ text: String) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(text.unicodeScalars.count)
        var afterCR = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x0A, afterCR {
                afterCR = false
                continue
            }
            afterCR = value == 0x0D
            switch value {
            case 0x0D, 0x0A, 0x85, 0x2028, 0x2029:
                out.append("\n")
            case 0x09:
                out.append(scalar)
            case 0x00 ... 0x1F, 0x7F, 0x80 ... 0x9F:
                continue
            default:
                out.append(scalar)
            }
        }
        return out
    }
}
