/// Bounds for client-supplied text the holder repeats back (ERROR messages, log lines).
///
/// A HELLO may legally carry up to 1 MiB of `client` name. Quoting that in an ERROR frame would
/// exceed the frame limit once JSON-escaped (control characters and DEL become 6-byte `\u00XX`) and
/// trip `Frame.appendHeader`'s precondition, crashing the holder and with it the session.
enum TextLimits {
    /// Longest client name kept from HELLO (UTF-8 bytes).
    static let clientName = 128
    /// Longest ERROR `message` (UTF-8 bytes, before JSON escaping).
    static let errorMessage = 1024

    /// `text` cut to at most `maxBytes` UTF-8 bytes on a scalar boundary, with C0 controls, DEL and
    /// C1 controls replaced by "?" (keeps log lines on one line and bounds the escaped size at 2x).
    static func printable(_ text: String, maxBytes: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var used = 0
        for scalar in text.unicodeScalars {
            let safe: Unicode.Scalar = scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? "?" : scalar
            let size = UTF8.width(safe)
            guard used + size <= maxBytes else { break }
            scalars.append(safe)
            used += size
        }
        return String(scalars)
    }
}
