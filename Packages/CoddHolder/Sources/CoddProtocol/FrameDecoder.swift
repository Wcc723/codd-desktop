/// Incremental frame decoder: feed it whatever `read()` returned (partial frames, several frames at
/// once) and pull complete frames with `next()`.
///
/// The length field is validated as soon as its 4 bytes have arrived, so garbage is rejected without
/// buffering the bogus body it claims. After an error the decoder stays failed: the byte stream has
/// lost framing and the connection must be closed.
public struct FrameDecoder: Sendable {
    /// Largest accepted length-field value.
    public let maxLength: Int

    private var buffer: [UInt8] = []
    /// Index of the first unconsumed byte in `buffer`.
    private var head = 0
    private var failure: ProtocolError?

    /// Buffers above this capacity are released once fully consumed (after a large INPUT, say).
    private static let retainedCapacity = 256 * 1024

    public init(maxLength: Int = Frame.maxLength) {
        precondition(maxLength >= Frame.typeFieldSize && maxLength <= Frame.maxLength, "invalid maxLength")
        self.maxLength = maxLength
    }

    /// Bytes received but not yet returned as frames.
    public var bufferedByteCount: Int { buffer.count - head }

    /// True once a framing error was reported.
    public var hasFailed: Bool { failure != nil }

    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        compactIfNeeded()
        buffer.append(contentsOf: bytes)
    }

    public mutating func append<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
        compactIfNeeded()
        buffer.append(contentsOf: bytes)
    }

    /// Returns the next complete frame, `nil` if more bytes are needed, or throws on a framing error.
    public mutating func next() throws(ProtocolError) -> Frame? {
        if let failure { throw failure }
        let available = buffer.count - head
        guard available >= Frame.lengthFieldSize else { return nil }
        let total = Frame.lengthFieldSize + (try validatedLength(WireBytes.readUInt32(buffer, at: head)))
        guard available >= total else { return nil }
        let type = FrameType(rawValue: WireBytes.readUInt16(buffer, at: head + Frame.lengthFieldSize))
        let payload = Array(buffer[(head + Frame.headerSize)..<(head + total)])
        head += total
        if head == buffer.count { releaseConsumed() }
        return Frame(type: type, payload: payload)
    }

    /// Feeds `input` and hands every complete frame to `body` with its payload borrowed, so a
    /// streaming client does not copy OUTPUT bytes on their way to the terminal. Frames that lie
    /// entirely inside `input` are passed in place; only a frame split across reads is assembled
    /// in the internal buffer (each byte is copied at most once). The payload pointer is valid only
    /// during the call.
    ///
    /// `body` returns false to stop (a paused or closed consumer): the unconsumed rest of `input`
    /// is buffered, and a later call (with empty input) delivers it. Returns false when `body`
    /// stopped. Shares state with `append` / `next()`; framing errors are sticky as there.
    public mutating func decode(
        _ input: UnsafeRawBufferPointer, _ body: (FrameType, UnsafeRawBufferPointer) -> Bool
    ) throws(ProtocolError) -> Bool {
        if let failure { throw failure }
        var position = 0
        // Frames that start in the buffer: complete each from `input`, then deliver it from there.
        while head < buffer.count {
            if buffer.count - head < Frame.lengthFieldSize {
                position += take(from: input, at: position, count: Frame.lengthFieldSize - (buffer.count - head))
                if buffer.count - head < Frame.lengthFieldSize { return true }
            }
            let total = Frame.lengthFieldSize + (try validatedLength(WireBytes.readUInt32(buffer, at: head)))
            if buffer.count - head < total {
                position += take(from: input, at: position, count: total - (buffer.count - head))
                if buffer.count - head < total { return true }
            }
            let start = head
            let type = FrameType(rawValue: WireBytes.readUInt16(buffer, at: start + Frame.lengthFieldSize))
            let proceed = buffer.withUnsafeBytes { raw in
                body(type, UnsafeRawBufferPointer(rebasing: raw[(start + Frame.headerSize)..<(start + total)]))
            }
            head += total
            if head == buffer.count { releaseConsumed() }
            if !proceed {
                _ = take(from: input, at: position, count: input.count - position)
                return false
            }
        }
        // Frames entirely inside `input`: no copy.
        var proceed = true
        while proceed, input.count - position >= Frame.lengthFieldSize {
            let total = Frame.lengthFieldSize + (try validatedLength(WireBytes.readUInt32(input, at: position)))
            guard input.count - position >= total else { break }
            let type = FrameType(rawValue: WireBytes.readUInt16(input, at: position + Frame.lengthFieldSize))
            proceed = body(type, UnsafeRawBufferPointer(rebasing: input[(position + Frame.headerSize)..<(position + total)]))
            position += total
        }
        // The partial frame at the end (or everything after a stop) waits in the buffer.
        _ = take(from: input, at: position, count: input.count - position)
        return proceed
    }

    /// Appends up to `count` bytes of `input` from `position` to the buffer; returns how many.
    private mutating func take(from input: UnsafeRawBufferPointer, at position: Int, count: Int) -> Int {
        let available = min(count, input.count - position)
        guard available > 0 else { return 0 }
        compactIfNeeded()
        buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: input[position..<(position + available)]))
        return available
    }

    /// Checks a length field like `next()` does (the failure is sticky).
    private mutating func validatedLength(_ length: UInt32) throws(ProtocolError) -> Int {
        if length < UInt32(Frame.typeFieldSize) {
            let error = ProtocolError.frameTooShort(length: length)
            failure = error
            throw error
        }
        if length > UInt32(maxLength) {
            let error = ProtocolError.frameTooLarge(length: length)
            failure = error
            throw error
        }
        return Int(length)
    }

    private mutating func releaseConsumed() {
        if buffer.capacity > FrameDecoder.retainedCapacity {
            buffer = []
        } else {
            buffer.removeAll(keepingCapacity: true)
        }
        head = 0
    }

    /// Drops consumed bytes before appending so the buffer does not grow without bound.
    private mutating func compactIfNeeded() {
        guard head > 0 else { return }
        if head == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 * 1024 || head * 2 >= buffer.count {
            buffer.removeSubrange(0..<head)
            head = 0
        }
    }
}
