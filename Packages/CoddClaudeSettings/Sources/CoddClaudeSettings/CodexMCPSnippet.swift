/// The `~/.codex/config.toml` lines the Codex `註冊` dialog shows (M4 §3.12, D22). CODD never
/// writes `~/.codex`; the user pastes this.
public enum CodexMCPSnippet {
    /// ```toml
    /// [mcp_servers.codd]
    /// url = "http://127.0.0.1:47821/mcp"
    /// http_headers = { "X-CODD-Token" = "<mcpToken>" }
    /// ```
    /// with a final newline, so it can be appended to a config file as it is. Both values are
    /// TOML basic strings (quotes, backslashes and controls escaped).
    public static func toml(url: String, token: String) -> String {
        "[mcp_servers.codd]\nurl = \(basicString(url))\nhttp_headers = { \"X-CODD-Token\" = \(basicString(token)) }\n"
    }

    /// A TOML basic string: `"`, `\` and control characters escaped, everything else raw.
    static func basicString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    let hex = String(scalar.value, radix: 16, uppercase: true)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}
