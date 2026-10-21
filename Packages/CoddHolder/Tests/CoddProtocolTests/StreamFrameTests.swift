import Testing
@testable import CoddProtocol

/// The zero-copy `FrameDecoder.decode` path and the capability-gated payloads (ATTACHED, GAP extension).
@Suite("Stream frames")
struct StreamFrameTests {
    private func encodedSamples() -> [UInt8] {
        var bytes: [UInt8] = []
        for message in sampleMessages { message.append(to: &bytes) }
        AttachedInfo(start: 7, replayEnd: 99, modes: TerminalModes()).frame.append(to: &bytes)
        Message.output(offset: 3, bytes: [UInt8](repeating: 0x41, count: 200_000)).append(to: &bytes)
        return bytes
    }

    private func referenceFrames(_ bytes: [UInt8]) throws -> [Frame] {
        var decoder = FrameDecoder()
        decoder.append(contentsOf: bytes)
        var frames: [Frame] = []
        while let frame = try decoder.next() { frames.append(frame) }
        return frames
    }

    @Test("decode yields the same frames as next() for any read split")
    func decodeMatchesNext() throws {
        let bytes = encodedSamples()
        let expected = try referenceFrames(bytes)
        var random = SplitMix64(state: 11)
        for round in 0..<40 {
            var decoder = FrameDecoder()
            var frames: [Frame] = []
            var start = 0
            while start < bytes.count {
                let size = round == 0 ? 1 : Int.random(in: 1...70_000, using: &random)
                let end = min(start + size, bytes.count)
                let proceeded = try bytes[start..<end].withUnsafeBytes { raw in
                    try decoder.decode(raw) { type, payload in
                        frames.append(Frame(type: type, payload: Array(payload)))
                        return true
                    }
                }
                #expect(proceeded)
                start = end
            }
            #expect(frames == expected, "round \(round)")
            #expect(decoder.bufferedByteCount == 0)
        }
    }

    @Test("whole frames are passed in place; a split frame is assembled once")
    func decodeIsZeroCopyForWholeFrames() throws {
        let bytes = Message.output(offset: 1, bytes: [1, 2, 3]).encoded() + Message.bell.encoded()
        var decoder = FrameDecoder()
        try bytes.withUnsafeBytes { raw in
            let range = UInt(bitPattern: raw.baseAddress!)..<(UInt(bitPattern: raw.baseAddress!) + UInt(raw.count))
            _ = try decoder.decode(raw) { _, payload in
                if !payload.isEmpty, let base = payload.baseAddress { #expect(range.contains(UInt(bitPattern: base))) }
                return true
            }
        }
        // Split inside the first frame: the first is assembled, the rest of the read is in place.
        var split = FrameDecoder()
        var types: [FrameType] = []
        try bytes[0..<5].withUnsafeBytes { raw in _ = try split.decode(raw) { type, _ in types.append(type); return true } }
        #expect(types.isEmpty)
        #expect(split.bufferedByteCount == 5)
        try bytes[5...].withUnsafeBytes { raw in _ = try split.decode(raw) { type, _ in types.append(type); return true } }
        #expect(types == [.output, .bell])
        #expect(split.bufferedByteCount == 0)
    }

    @Test("a stopping body keeps the rest buffered; an empty decode resumes it")
    func decodeStopAndResume() throws {
        var bytes: [UInt8] = []
        for index in 0..<5 { Message.ping(token: UInt64(index)).append(to: &bytes) }
        var decoder = FrameDecoder()
        var tokens: [UInt64] = []
        let first = try bytes.withUnsafeBytes { raw in
            try decoder.decode(raw) { _, payload in
                tokens.append(WireBytes.readUInt64(payload, at: 0))
                return tokens.count < 2
            }
        }
        #expect(!first)
        #expect(tokens == [0, 1])
        #expect(decoder.bufferedByteCount == 3 * 14)
        let empty = UnsafeRawBufferPointer(start: nil, count: 0)
        let second = try decoder.decode(empty) { _, payload in
            tokens.append(WireBytes.readUInt64(payload, at: 0))
            return tokens.count < 4
        }
        #expect(!second)
        let third = try decoder.decode(empty) { _, payload in
            tokens.append(WireBytes.readUInt64(payload, at: 0))
            return true
        }
        #expect(third)
        #expect(tokens == [0, 1, 2, 3, 4])
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("decode rejects bad length fields and stays failed")
    func decodeErrorsAreSticky() {
        var decoder = FrameDecoder()
        let garbage: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01]
        #expect(throws: ProtocolError.frameTooLarge(length: 0xFFFF_FFFF)) {
            _ = try garbage.withUnsafeBytes { raw in try decoder.decode(raw) { _, _ in true } }
        }
        #expect(decoder.hasFailed)
        #expect(throws: ProtocolError.self) { _ = try decoder.next() }
        var short = FrameDecoder()
        #expect(throws: ProtocolError.frameTooShort(length: 1)) {
            _ = try ([0, 0, 0, 1, 0] as [UInt8]).withUnsafeBytes { raw in try short.decode(raw) { _, _ in true } }
        }
    }

    @Test("ATTACHED round trip; v1 receivers see it as an unknown frame")
    func attachedPayload() throws {
        var modes = TerminalModes()
        modes.altScreen = true
        modes.kittyKeyboardFlags = 5
        for info in [
            AttachedInfo(start: 1 << 40, replayEnd: (1 << 40) + 9, modes: modes),
            AttachedInfo(start: 0, replayEnd: 0, modes: nil),
        ] {
            #expect(info.payload.count == AttachedInfo.extendedPayloadSize)
            #expect(try AttachedInfo(payload: info.payload) == info)
            let message = try Message(frame: info.frame)
            #expect(message == .unknown(type: .attached, payload: info.payload))
        }
        #expect(throws: ProtocolError.self) { _ = try AttachedInfo(payload: [UInt8](repeating: 0, count: 24)) }
        // `attach.modes`: the current modes follow; a v1 (25-byte) payload has none.
        var alternate = TerminalModes()
        alternate.altScreen = true
        let extended = AttachedInfo(start: 5, replayEnd: 9, modes: TerminalModes(), currentModes: alternate)
        #expect(extended.payload.count == AttachedInfo.extendedPayloadSize)
        #expect(try AttachedInfo(payload: extended.payload) == extended)
        let v1 = try AttachedInfo(payload: Array(extended.payload.prefix(AttachedInfo.payloadSize)))
        #expect(v1.currentModes == nil)
        #expect(v1.modes == TerminalModes())
        #expect(HolderCapability.v1.contains(HolderCapability.attachModes))
        #expect(FrameType.attached.description == "ATTACHED")
    }

    @Test("extended GAP round trip; a v1 decoder reads from/to and ignores the rest")
    func gapPayload() throws {
        var modes = TerminalModes()
        modes.bracketedPaste = true
        let gap = GapInfo(from: 10, to: 500, replayEnd: 900, resumeModes: modes)
        #expect(gap.payload.count == GapInfo.payloadSize)
        #expect(try GapInfo(payload: gap.payload) == gap)
        #expect(try Message(frame: gap.frame) == .gap(from: 10, to: 500))
        let unknownModes = GapInfo(from: 1, to: 2, replayEnd: 3, resumeModes: nil)
        #expect(try GapInfo(payload: unknownModes.payload) == unknownModes)
        // A v1 GAP (16 bytes) decodes without the extension.
        let v1 = try GapInfo(payload: Message.gap(from: 4, to: 8).payload)
        #expect(v1 == GapInfo(from: 4, to: 8, replayEnd: nil, resumeModes: nil))
        #expect(throws: ProtocolError.self) { _ = try GapInfo(payload: [UInt8](repeating: 0, count: 15)) }
    }

    @Test("the holder advertises the stream capabilities")
    func capabilities() {
        #expect(HolderCapability.v1.contains(HolderCapability.attachAck))
        #expect(HolderCapability.v1.contains(HolderCapability.gapResync))
        #expect(Set(HolderCapability.v1).count == HolderCapability.v1.count)
    }
}
