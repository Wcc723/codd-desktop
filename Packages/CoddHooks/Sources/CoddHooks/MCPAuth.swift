import CryptoKit
import Foundation
import Security

/// Tokens of the MCP routes (M4 D15, D16, D23).
///
/// - A CODD session authenticates with a token derived from the hook token and its own id, so the
///   per-session `mcp.json` (0600) holds a literal that is useless for any other session, and no
///   new secret has to be stored per session. Rotating the external token never changes these.
/// - External clients (a user-scope registration, curl) use the external MCP token, config.json
///   `mcpToken`.
/// - A note URL (`/n/<id>.md?t=…`) carries a per-note token derived from the external token: a
///   leaked URL reads only that note, and every URL dies when the token is rotated.
public enum MCPAuth {
    /// Lowercase hex HMAC-SHA256 keyed with `hookToken`'s UTF-8 over
    /// `codd-mcp-v1:<sessionID lowercased>` (64 characters).
    public static func sessionToken(hookToken: String, sessionID: UUID) -> String {
        hmacHex(key: hookToken, message: "codd-mcp-v1:\(sessionID.uuidString.lowercased())")
    }

    /// The first 24 lowercase hex characters of HMAC-SHA256 keyed with `mcpToken`'s UTF-8 over
    /// `codd-note-url-v1:<noteID>`.
    public static func noteURLToken(mcpToken: String, noteID: String) -> String {
        String(hmacHex(key: mcpToken, message: "codd-note-url-v1:\(noteID)").prefix(24))
    }

    /// 32 random bytes from `SecRandomCopyBytes`, lowercase hex (64 characters). Should the system
    /// generator ever fail, the bytes come from `SystemRandomNumberGenerator` (also the kernel's
    /// CSPRNG on Darwin), so the result is always a fresh secret.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return hex(bytes)
    }

    /// Whether `presented` is `sessionID`'s token (constant time).
    public static func isValidSessionToken(_ presented: String, hookToken: String, sessionID: UUID) -> Bool {
        HookRequestPolicy.constantTimeEquals(Array(presented.utf8), Array(sessionToken(hookToken: hookToken, sessionID: sessionID).utf8))
    }

    /// Whether `presented` is the note URL token of `noteID` (constant time); always `false`
    /// without an MCP token.
    public static func isValidNoteURLToken(_ presented: String, mcpToken: String?, noteID: String) -> Bool {
        guard let mcpToken, !mcpToken.isEmpty else { return false }
        return HookRequestPolicy.constantTimeEquals(Array(presented.utf8), Array(noteURLToken(mcpToken: mcpToken, noteID: noteID).utf8))
    }

    static func hmacHex(key: String, message: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(key.utf8)))
        return hex(Array(code))
    }

    static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(digits[Int(b >> 4)])
            out.append(digits[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
