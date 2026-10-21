/// Bracketed paste (`?2004`): a terminal sends `ESC [ 200 ~`, the pasted text, `ESC [ 201 ~`, so the
/// program takes the newlines in it as text instead of as Enter.
///
/// Used by the holder for INPUT with the `paste` flag (capability `input.paste`) and by clients that
/// bracket a paste themselves for a holder without that capability, so both strip the same way.
public enum BracketedPaste {
    /// `ESC [ 2 0 0 ~`
    public static let startMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    /// `ESC [ 2 0 1 ~`
    public static let endMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
    /// Bytes `wrap` adds at most.
    public static let overhead = startMarker.count + endMarker.count

    /// `bytes` without any `ESC [ 200 ~` / `ESC [ 201 ~`, so pasted text can never end (or restart) the
    /// bracket around it. One pass that removes a marker as soon as its last byte arrives: removing
    /// one can uncover another (`ESC [ 20` + marker + `0 ~`), which is removed in turn, so the result
    /// contains none. Markers cannot overlap, so the order of removals does not change the result.
    public static func strippingMarkers(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0x1B) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        for byte in bytes {
            out.append(byte)
            if byte == 0x7E, endsWithMarker(out) { out.removeLast(startMarker.count) }
        }
        return out
    }

    /// `ESC [ 200 ~` + `strippingMarkers(bytes)` + `ESC [ 201 ~`; empty when nothing is left to paste
    /// (an empty bracket would only reach the program as a paste event without text).
    public static func wrap(_ bytes: [UInt8]) -> [UInt8] {
        let content = strippingMarkers(bytes)
        guard !content.isEmpty else { return [] }
        var out: [UInt8] = []
        out.reserveCapacity(content.count + overhead)
        out.append(contentsOf: startMarker)
        out.append(contentsOf: content)
        out.append(contentsOf: endMarker)
        return out
    }

    private static func endsWithMarker(_ out: [UInt8]) -> Bool {
        let count = out.count
        guard count >= 6 else { return false }
        return out[count - 6] == 0x1B && out[count - 5] == 0x5B && out[count - 4] == 0x32 && out[count - 3] == 0x30
            && (out[count - 2] == 0x30 || out[count - 2] == 0x31)
    }
}
