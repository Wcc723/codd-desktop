/// One sequence (or run of plain bytes) a terminal wrote back to the program.
public enum ReplyToken: Sendable, Equatable, Codable {
    /// `ESC [ params intermediates final`
    case csi(params: String, intermediates: String, final: String)
    /// `ESC P payload ST`
    case dcs(String)
    /// `ESC ] payload (BEL | ST)`
    case osc(String)
    /// `ESC _ payload ST`
    case apc(String)
    /// Any other escape (`ESC x`).
    case escape(String)
    /// Bytes outside escape sequences (key text, etc.).
    case text([UInt8])

    /// The token re-encoded with visible escapes, e.g. `\e[?2026;2$y`.
    public var display: String {
        switch self {
        case let .csi(params, intermediates, final): "\\e[\(params)\(intermediates)\(final)"
        case let .dcs(payload): "\\eP\(payload)\\e\\\\"
        case let .osc(payload): "\\e]\(payload)\\e\\\\"
        case let .apc(payload): "\\e_\(payload)\\e\\\\"
        case let .escape(rest): "\\e\(rest)"
        case let .text(bytes): ByteEscaper.escape(bytes)
        }
    }
}

/// Splits terminal output into escape-sequence tokens. Tolerates truncation
/// (an unterminated sequence at the end becomes `.text` of its raw bytes) and
/// broken sequences (their prefix becomes `.text`; decoding resumes at the
/// byte that broke them, so later replies are still found).
public enum ReplyDecoder {
    public static func decode(_ bytes: [UInt8]) -> [ReplyToken] {
        var tokens: [ReplyToken] = []
        var plain: [UInt8] = []
        var index = 0

        func flushPlain() {
            if !plain.isEmpty {
                tokens.append(.text(plain))
                plain.removeAll()
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            guard byte == 0x1B, index + 1 < bytes.count else {
                plain.append(byte)
                index += 1
                continue
            }
            let introducer = bytes[index + 1]
            switch introducer {
            case UInt8(ascii: "["):
                switch parseCSI(bytes, from: index + 2) {
                case let .complete(token, next):
                    flushPlain()
                    tokens.append(token)
                    index = next
                case let .malformed(stop):
                    // Keep the broken prefix as text and resume at the byte
                    // that broke it (often the ESC of the next reply).
                    plain.append(contentsOf: bytes[index ..< stop])
                    index = stop
                case .truncated:
                    plain.append(contentsOf: bytes[index...])
                    index = bytes.count
                }
            case UInt8(ascii: "P"), UInt8(ascii: "]"), UInt8(ascii: "_"):
                switch parseString(bytes, from: index + 2, allowBEL: introducer == UInt8(ascii: "]")) {
                case let .complete(payload, next):
                    flushPlain()
                    switch introducer {
                    case UInt8(ascii: "P"): tokens.append(.dcs(payload))
                    case UInt8(ascii: "]"): tokens.append(.osc(payload))
                    default: tokens.append(.apc(payload))
                    }
                    index = next
                case let .malformed(stop):
                    plain.append(contentsOf: bytes[index ..< stop])
                    index = stop
                case .truncated:
                    plain.append(contentsOf: bytes[index...])
                    index = bytes.count
                }
            default:
                flushPlain()
                tokens.append(.escape(String(decoding: [introducer], as: UTF8.self)))
                index += 2
            }
        }
        flushPlain()
        return tokens
    }

    private enum Parse<Value> {
        /// The sequence and the index just past it.
        case complete(Value, Int)
        /// Broken by the byte at this index (not consumed).
        case malformed(Int)
        /// Input ended inside the sequence.
        case truncated
    }

    private static func parseCSI(_ bytes: [UInt8], from start: Int) -> Parse<ReplyToken> {
        var index = start
        var params: [UInt8] = []
        var intermediates: [UInt8] = []
        while index < bytes.count, (0x30 ... 0x3F).contains(bytes[index]) {
            params.append(bytes[index])
            index += 1
        }
        while index < bytes.count, (0x20 ... 0x2F).contains(bytes[index]) {
            intermediates.append(bytes[index])
            index += 1
        }
        guard index < bytes.count else { return .truncated }
        guard (0x40 ... 0x7E).contains(bytes[index]) else { return .malformed(index) }
        let token = ReplyToken.csi(
            params: String(decoding: params, as: UTF8.self),
            intermediates: String(decoding: intermediates, as: UTF8.self),
            final: String(decoding: [bytes[index]], as: UTF8.self)
        )
        return .complete(token, index + 1)
    }

    /// Reads up to ST (`ESC \`), or BEL when `allowBEL`. Any other ESC aborts
    /// the string (as in a VT parser) and is left for the next token.
    private static func parseString(_ bytes: [UInt8], from start: Int, allowBEL: Bool) -> Parse<String> {
        var index = start
        while index < bytes.count {
            if allowBEL, bytes[index] == 0x07 {
                return .complete(String(decoding: bytes[start ..< index], as: UTF8.self), index + 1)
            }
            if bytes[index] == 0x1B {
                guard index + 1 < bytes.count else { return .truncated }
                if bytes[index + 1] == UInt8(ascii: "\\") {
                    return .complete(String(decoding: bytes[start ..< index], as: UTF8.self), index + 2)
                }
                return .malformed(index)
            }
            index += 1
        }
        return .truncated
    }
}

/// Maps reply tokens to the probe that caused them and explains the answer.
public enum ProbeInterpreter {
    public struct Answer: Sendable, Equatable, Codable {
        public var probeID: String
        public var answered: Bool
        public var raw: String
        public var meaning: String
    }

    /// Whether `token` is a reply to `probe`, by the same rule Claude Code
    /// 2.1.300 matches it with (its `match:` functions): OSC 7501 counts only
    /// with data starting `?`, the graphics reply only with Claude's id 31.
    public static func matches(_ token: ReplyToken, _ probe: ProbeSpec) -> Bool {
        switch (probe.id, token) {
        case let ("xtversion", .dcs(payload)):
            return payload.hasPrefix(">|")
        case let ("kitty-keyboard", .csi(params, intermediates, final)):
            return final == "u" && intermediates.isEmpty && params.hasPrefix("?")
        case let ("decrqm-2026", .csi(params, intermediates, final)):
            return final == "y" && intermediates == "$" && params.hasPrefix("?2026;")
        case let ("decrqm-1016", .csi(params, intermediates, final)):
            return final == "y" && intermediates == "$" && params.hasPrefix("?1016;")
        case let ("osc-7501", .osc(payload)):
            return payload.hasPrefix("7501;?")
        case let ("kitty-graphics", .apc(payload)):
            return payload.hasPrefix("G") && kittyGraphicsID(payload) == ClaudeProbes.kittyGraphicsID
        case let ("csi-16t", .csi(params, intermediates, final)):
            return final == "t" && intermediates.isEmpty && params.hasPrefix("6;")
        case let ("da1", .csi(params, intermediates, final)):
            return final == "c" && intermediates.isEmpty && params.hasPrefix("?")
        default:
            return false
        }
    }

    /// One answer per probe, in probe order. Tokens no probe claims are ignored.
    public static func answers(for probes: [ProbeSpec], tokens: [ReplyToken]) -> [Answer] {
        probes.map { probe in
            let replies = tokens.filter { matches($0, probe) }
            guard !replies.isEmpty else {
                return Answer(probeID: probe.id, answered: false, raw: "", meaning: "no reply")
            }
            return Answer(
                probeID: probe.id,
                answered: true,
                raw: replies.map(\.display).joined(separator: " "),
                meaning: replies.map { explain($0, probe) }.joined(separator: "; ")
            )
        }
    }

    /// Tokens that match none of `probes` (unexpected output during probing).
    public static func unclaimed(_ tokens: [ReplyToken], probes: [ProbeSpec]) -> [ReplyToken] {
        tokens.filter { token in !probes.contains { matches(token, $0) } }
    }

    /// The `i=` key of a kitty graphics APC payload (`Gi=31;OK` → 31).
    static func kittyGraphicsID(_ payload: String) -> Int? {
        let control = payload.dropFirst().prefix { $0 != ";" }
        for pair in control.split(separator: ",") where pair.hasPrefix("i=") {
            return Int(pair.dropFirst(2))
        }
        return nil
    }

    static func explain(_ token: ReplyToken, _ probe: ProbeSpec) -> String {
        switch token {
        case let .dcs(payload):
            return "identifies as \"\(payload.dropFirst(2))\""
        case let .csi(params, _, final) where final == "u":
            return "kitty keyboard flags = \(params.dropFirst())"
        case let .csi(params, _, final) where final == "y":
            let value = params.split(separator: ";").last.map(String.init) ?? "?"
            return "mode \(params.dropFirst().split(separator: ";").first ?? "?") = \(decrpmName(value))"
        case let .csi(params, _, final) where final == "t":
            let parts = params.split(separator: ";")
            if parts.count == 3 { return "cell \(parts[2])×\(parts[1]) px" }
            return "cell size \(params)"
        case let .csi(params, _, final) where final == "c":
            return "DA1 attributes \(params.dropFirst())"
        case let .osc(payload):
            return "program status: \(payload)"
        case let .apc(payload):
            return payload.contains("OK") ? "kitty graphics supported (\(payload))" : "kitty graphics: \(payload)"
        default:
            return token.display
        }
    }

    static func decrpmName(_ value: String) -> String {
        switch value {
        case "0": "0 not recognized"
        case "1": "1 set"
        case "2": "2 reset"
        case "3": "3 permanently set"
        case "4": "4 permanently reset"
        default: value
        }
    }
}

/// Renders bytes with C-style escapes (`\e`, `\r`, `\x16`).
public enum ByteEscaper {
    public static func escape(_ bytes: [UInt8]) -> String {
        var out = ""
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            switch scalar.value {
            case 0x1B: out += "\\e"
            case 0x0D: out += "\\r"
            case 0x0A: out += "\\n"
            case 0x09: out += "\\t"
            case 0x7F: out += "\\x7f"
            case 0 ..< 0x20:
                let hex = String(scalar.value, radix: 16)
                out += "\\x" + (hex.count == 1 ? "0" + hex : hex)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
