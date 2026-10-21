import CoddProtocol

/// How INPUT goes on the wire; shared by `HolderStream` and `HolderConnection` so both clients
/// paste the same way.
enum InputFraming {
    /// What to send for one input: the payload and whether frames carry the paste flag.
    ///
    /// A holder with `input.paste` decides itself by the child's current modes: the bytes go out
    /// unchanged with the flag. An older holder ignores the flag, so the client brackets: when
    /// `modes` (the newest it knows: WELCOME `modes`, replaced by every ATTACHED's current modes)
    /// have `?2004` on, the payload is `BracketedPaste.wrap` (same marker stripping as the holder)
    /// and goes out as plain INPUT; otherwise as is. Those modes can be stale (the child may have
    /// changed them since); only the holder sees every byte.
    static func prepare(
        _ bytes: [UInt8], paste: Bool, holderSupportsPaste: Bool, modes: TerminalModes?
    ) -> (payload: [UInt8], pasteFlag: Bool) {
        guard paste else { return (bytes, false) }
        if holderSupportsPaste { return (bytes, true) }
        return (modes?.bracketedPaste == true ? BracketedPaste.wrap(bytes) : bytes, false)
    }

    /// Bytes `appendFrames` can produce for `byteCount` input bytes (the client's own bracket
    /// included), reserved against the outbound limit before the stream's queue decides.
    static func reservation(byteCount: Int, paste: Bool) -> Int {
        let payload = byteCount + (paste ? BracketedPaste.overhead : 0)
        return payload + frameCount(payload) * (Frame.headerSize + 1)
    }

    /// Appends INPUT frames for `payload`, split at `Message.maxInputChunk`: only the last carries
    /// submit, every one the paste flag (the holder treats one frame as one paste). An empty payload
    /// still makes one frame (a bare submit). Returns the number of bytes appended.
    @discardableResult
    static func appendFrames(_ payload: [UInt8], submit: Bool, paste: Bool, to out: inout [UInt8]) -> Int {
        let before = out.count
        let pasteFlag: InputFlags = paste ? .paste : []
        var start = 0
        repeat {
            let end = min(start + Message.maxInputChunk, payload.count)
            let flags = pasteFlag.union(end == payload.count && submit ? .submit : [])
            Frame.appendHeader(type: .input, payloadLength: 1 + end - start, to: &out)
            out.append(flags.rawValue)
            out.append(contentsOf: payload[start..<end])
            start = end
        } while start < payload.count
        return out.count - before
    }

    private static func frameCount(_ payloadBytes: Int) -> Int {
        max(1, (payloadBytes + Message.maxInputChunk - 1) / Message.maxInputChunk)
    }
}
