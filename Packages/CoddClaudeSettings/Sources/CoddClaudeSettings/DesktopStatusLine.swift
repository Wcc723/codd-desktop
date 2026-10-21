import Foundation

/// CODD Desktop's optional global status line (D11): a shell guard around
/// `<root>/bin/codd-statusline`, so a removed or moved CODD never blanks the user's status line
/// (the `else` branch runs the chained command with the same stdin).
public struct DesktopStatusLine: Sendable, Equatable {
    /// `<dataRoot>/bin/codd-statusline` (the stable copy, never collected).
    public var binary: String
    public var dataRoot: String

    public init(binary: String, dataRoot: String) {
        self.binary = binary
        self.dataRoot = dataRoot
    }

    /// The wrapper for the standard binary location under `dataRoot`.
    public init(dataRoot: String) {
        self.init(binary: (dataRoot as NSString).appendingPathComponent("bin/codd-statusline"), dataRoot: dataRoot)
    }

    /// Both substrings every desktop wrapper contains (cheap pre-check before ``parse(_:)``).
    public static let binaryMarker = "/bin/codd-statusline"
    static let dataRootFlag = "--data-root"

    /// `if [ -x '<binary>' ]; then '<binary>' --data-root '<root>' --chain-b64 <b64>; else /bin/sh -c '<chain>'; fi`,
    /// or without a chain `if [ -x '<binary>' ]; then '<binary>' --data-root '<root>'; fi`.
    /// The chain goes through `/bin/sh -c` in single quotes so `fi`, `&` or newlines inside it
    /// cannot break the `if`; an empty chain counts as none.
    public func command(chain: String?) -> String {
        let bin = ShellQuote.single(binary)
        let head = "if [ -x \(bin) ]; then \(bin) --data-root \(ShellQuote.single(dataRoot))"
        guard let chain, !chain.isEmpty else { return head + "; fi" }
        return head + " --chain-b64 \(ChainBase64.encode(chain)); else /bin/sh -c \(ShellQuote.single(chain)); fi"
    }

    /// Recognizes exactly the text ``command(chain:)`` writes (any binary, root and chain). Nil
    /// for anything else, including a wrapper whose `--chain-b64` does not round-trip or whose
    /// `else` branch no longer matches the encoded chain (hand edits are not guessed at).
    public static func parse(_ command: String) -> (binary: String, dataRoot: String, chain: String?)? {
        parse(command, marker: binaryMarker)
    }

    static func parse(_ command: String, marker: String) -> (binary: String, dataRoot: String, chain: String?)? {
        guard looksLikeWrapper(command, marker: marker) else { return nil }
        var s = ShellScanner(command)
        guard s.consume("if [ -x "), let binary = s.singleQuoted(), s.consume(" ]; then "),
              s.singleQuoted() == binary, s.consume(" --data-root "), let dataRoot = s.singleQuoted()
        else { return nil }
        if s.consume("; fi") {
            return s.atEnd ? (binary, dataRoot, nil) : nil
        }
        guard s.consume(" --chain-b64 "), let encoded = s.base64Token(),
              let chain = ChainBase64.decode(encoded), !chain.isEmpty,
              s.consume("; else /bin/sh -c "), s.singleQuoted() == chain, s.consume("; fi"), s.atEnd
        else { return nil }
        return (binary, dataRoot, chain)
    }

    static func looksLikeWrapper(_ command: String, marker: String = binaryMarker) -> Bool {
        command.contains(marker) && command.contains(dataRootFlag)
    }
}

/// POSIX single quoting: `'…'` with each `'` written as `'\''`.
enum ShellQuote {
    static func single(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The `--chain-b64` payload: standard base64 (with padding) of the command's UTF-8. Decoding
/// insists on the round trip, like CODD web: a payload that re-encodes differently was altered.
enum ChainBase64 {
    static func encode(_ chain: String) -> String {
        Data(chain.utf8).base64EncodedString()
    }

    static func decode(_ token: String) -> String? {
        guard !token.isEmpty, let data = Data(base64Encoded: token),
              let text = String(validating: data, as: UTF8.self), encode(text) == token
        else { return nil }
        return text
    }

    static func isBase64Character(_ c: Unicode.Scalar) -> Bool {
        switch c {
        case "A"..."Z", "a"..."z", "0"..."9", "+", "/", "=": return true
        default: return false
        }
    }

    /// CODD web's `--chain-b64\s+([A-Za-z0-9+/=]+)`: `.absent` without the flag and a token.
    enum Lookup: Equatable {
        case absent
        case decoded(String)
        case undecodable
    }

    static func find(in command: String) -> Lookup {
        let scalars = Array(command.unicodeScalars)
        let flag = Array("--chain-b64".unicodeScalars)
        guard scalars.count >= flag.count else { return .absent }
        var k = 0
        while k + flag.count <= scalars.count {
            if scalars[k..<(k + flag.count)].elementsEqual(flag) {
                var j = k + flag.count
                let spaceStart = j
                while j < scalars.count, scalars[j].properties.isWhitespace { j += 1 }
                let tokenStart = j
                while j < scalars.count, isBase64Character(scalars[j]) { j += 1 }
                if tokenStart > spaceStart, j > tokenStart {
                    var view = String.UnicodeScalarView()
                    view.append(contentsOf: scalars[tokenStart..<j])
                    return decode(String(view)).map(Lookup.decoded) ?? .undecodable
                }
            }
            k += 1
        }
        return .absent
    }
}

/// A cursor over a command line for the exact wrapper grammar.
struct ShellScanner {
    private let scalars: [Unicode.Scalar]
    private var i = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var atEnd: Bool { i == scalars.count }

    mutating func consume(_ literal: String) -> Bool {
        let lit = Array(literal.unicodeScalars)
        guard i + lit.count <= scalars.count, scalars[i..<(i + lit.count)].elementsEqual(lit) else { return false }
        i += lit.count
        return true
    }

    /// `'…'` optionally continued by `\''…'` segments (an escaped quote); the unquoted text.
    mutating func singleQuoted() -> String? {
        guard i < scalars.count, scalars[i] == "'" else { return nil }
        var out = String.UnicodeScalarView()
        var k = i + 1
        while true {
            guard k < scalars.count else { return nil }
            let c = scalars[k]
            if c != "'" {
                out.append(c)
                k += 1
                continue
            }
            // Closing quote; `\''` continues the same word with a literal quote.
            if k + 3 < scalars.count, scalars[k + 1] == "\\", scalars[k + 2] == "'", scalars[k + 3] == "'" {
                out.append("'")
                k += 4
                continue
            }
            i = k + 1
            return String(out)
        }
    }

    mutating func base64Token() -> String? {
        let start = i
        while i < scalars.count, ChainBase64.isBase64Character(scalars[i]) { i += 1 }
        guard i > start else { return nil }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start..<i])
        return String(view)
    }
}
