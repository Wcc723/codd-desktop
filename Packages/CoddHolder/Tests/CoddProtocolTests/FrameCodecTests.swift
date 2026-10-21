import Testing
@testable import CoddProtocol

/// Deterministic PRNG so fuzz-style tests are reproducible.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let sampleWelcome = Welcome(
    holder: "0.1", session: "0f3c2c1e-1111-4222-8333-944455556666", childPid: 4242, cols: 120, rows: 40,
    ringStart: 10, ringEnd: UInt64.max - 1, resync: 77, modes: TerminalModes(), title: "zsh — ~/src",
    cwd: "/Users/me/專案", exited: true, exitStatus: -3, signaled: false, caps: HolderCapability.v1,
    holderPid: 99, ringSize: 8 << 20, spawnOffset: 5, progress: TerminalProgress(state: 3, value: 0))

let sampleMessages: [Message] = [
    .hello(Hello(client: "CODD/0.1", takeover: true, caps: ["a", "b"])),
    .welcome(sampleWelcome),
    .attach(fromOffset: Message.latestResync),
    .attach(fromOffset: 0),
    .detach,
    .output(offset: 1 << 40, bytes: Array("hello \u{1B}[1mworld\u{1B}[0m 中文".utf8)),
    .output(offset: 0, bytes: []),
    .gap(from: 3, to: 1 << 33),
    .input(flags: .submit, bytes: Array("ls -la".utf8)),
    .input(flags: [], bytes: [0x03]),
    .resize(WindowSize(cols: 300, rows: 80, pixelWidth: 2400, pixelHeight: 1600)),
    .signal(2),
    .repaint,
    .exit(ExitInfo(status: -1, signaled: false)),
    .exit(ExitInfo(status: 9, signaled: true)),
    .ping(token: 0xDEAD_BEEF_0000_0001),
    .pong(token: 7),
    .title("✳ Claude Code"),
    .cwd("/tmp/a b"),
    .bell,
    .error(ErrorInfo(code: "busy", message: "attached by \"CODD\"")),
    .unknown(type: FrameType(rawValue: 0x7777), payload: [1, 2, 3]),
]

func decodeAll(_ bytes: [UInt8], chunks: [Int]) throws -> [Message] {
    var decoder = FrameDecoder()
    var messages: [Message] = []
    var start = 0
    for size in chunks + [bytes.count] {
        let end = min(start + size, bytes.count)
        decoder.append(contentsOf: bytes[start..<end])
        start = end
        while let frame = try decoder.next() {
            messages.append(try Message(frame: frame))
        }
        if start == bytes.count { break }
    }
    #expect(decoder.bufferedByteCount == 0)
    return messages
}

@Suite("Frame codec")
struct FrameCodecTests {
    @Test("every message type survives encode → decode")
    func roundTrip() throws {
        for message in sampleMessages {
            let encoded = message.encoded()
            #expect(WireBytes.readUInt32(encoded, at: 0) == UInt32(encoded.count - 4))
            #expect(WireBytes.readUInt16(encoded, at: 4) == message.type.rawValue)
            var decoder = FrameDecoder()
            decoder.append(contentsOf: encoded)
            let frame = try #require(try decoder.next())
            #expect(try Message(frame: frame) == message)
            #expect(try decoder.next() == nil)
        }
    }

    @Test("wire layout matches docs/ARCHITECTURE.md")
    func wireLayout() {
        #expect(Message.attach(fromOffset: 0x0102_0304_0506_0708).encoded()
            == [0, 0, 0, 10, 0x00, 0x03, 1, 2, 3, 4, 5, 6, 7, 8])
        #expect(Message.input(flags: .submit, bytes: [0x41]).encoded() == [0, 0, 0, 4, 0x00, 0x20, 0x01, 0x41])
        #expect(Message.resize(WindowSize(cols: 0x0102, rows: 0x0304, pixelWidth: 5, pixelHeight: 6)).encoded()
            == [0, 0, 0, 10, 0x00, 0x21, 1, 2, 3, 4, 0, 5, 0, 6])
        #expect(Message.exit(ExitInfo(status: -2, signaled: true)).encoded()
            == [0, 0, 0, 7, 0x00, 0x30, 0xFF, 0xFF, 0xFF, 0xFE, 1])
        #expect(Message.bell.encoded() == [0, 0, 0, 2, 0x00, 0x52])
        #expect(Message.gap(from: 1, to: 2).encoded().count == 4 + 2 + 16)
    }

    @Test("all split points of a multi-frame stream decode identically")
    func everySplitPoint() throws {
        var stream: [UInt8] = []
        for message in sampleMessages { message.append(to: &stream) }
        for split in 0...stream.count {
            #expect(try decodeAll(stream, chunks: [split]) == sampleMessages)
        }
    }

    @Test("random chunkings, including single bytes, decode identically")
    func randomChunking() throws {
        var stream: [UInt8] = []
        for _ in 0..<5 {
            for message in sampleMessages { message.append(to: &stream) }
        }
        let expected = Array(repeating: sampleMessages, count: 5).flatMap { $0 }
        var random = SplitMix64(state: 42)
        for round in 0..<200 {
            var chunks: [Int] = []
            var total = 0
            while total < stream.count {
                let size = round % 10 == 0 ? 1 : Int.random(in: 1...700, using: &random)
                chunks.append(size)
                total += size
            }
            #expect(try decodeAll(stream, chunks: chunks) == expected)
        }
    }

    @Test("a 1 MiB frame is accepted, one byte more is rejected as soon as the header arrives")
    func maximumFrameLength() throws {
        let payload = [UInt8](repeating: 0x61, count: Frame.maxPayloadLength - 8)
        let largest = Message.output(offset: 9, bytes: payload).encoded()
        #expect(WireBytes.readUInt32(largest, at: 0) == UInt32(Frame.maxLength))
        var decoder = FrameDecoder()
        decoder.append(contentsOf: largest)
        let frame = try #require(try decoder.next())
        #expect(frame.payload.count == Frame.maxPayloadLength)

        var rejecting = FrameDecoder()
        var header: [UInt8] = []
        WireBytes.append(UInt32(Frame.maxLength + 1), to: &header)
        rejecting.append(contentsOf: header)
        #expect(throws: ProtocolError.frameTooLarge(length: UInt32(Frame.maxLength + 1))) { try rejecting.next() }
        // Poisoned: further input cannot resynchronize a broken stream.
        rejecting.append(contentsOf: Message.bell.encoded())
        #expect(throws: ProtocolError.self) { try rejecting.next() }
        #expect(rejecting.hasFailed)
    }

    @Test("length fields below 2 are garbage")
    func tooShort() {
        for length: UInt32 in [0, 1] {
            var decoder = FrameDecoder()
            var bytes: [UInt8] = []
            WireBytes.append(length, to: &bytes)
            decoder.append(contentsOf: bytes)
            #expect(throws: ProtocolError.frameTooShort(length: length)) { try decoder.next() }
        }
    }

    @Test("random garbage never crashes the decoder and stays rejected once rejected")
    func garbage() {
        var random = SplitMix64(state: 7)
        for _ in 0..<2000 {
            let count = Int.random(in: 0...64, using: &random)
            let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &random) }
            var decoder = FrameDecoder()
            decoder.append(contentsOf: bytes)
            var failed = false
            for _ in 0..<64 {
                do {
                    guard let frame = try decoder.next() else { break }
                    _ = try? Message(frame: frame)
                } catch {
                    failed = true
                    break
                }
            }
            if failed {
                #expect(decoder.hasFailed)
            }
        }
    }

    @Test("short fixed payloads and bad JSON are payload errors, not crashes")
    func malformedPayloads() {
        #expect(throws: ProtocolError.self) { try Message(frame: Frame(type: .attach, payload: [1, 2, 3])) }
        #expect(throws: ProtocolError.self) { try Message(frame: Frame(type: .resize, payload: [0, 80])) }
        #expect(throws: ProtocolError.self) { try Message(frame: Frame(type: .input, payload: [])) }
        #expect(throws: ProtocolError.self) { try Message(frame: Frame(type: .exit, payload: [0, 0, 0, 0])) }
        #expect(throws: ProtocolError.self) { try Message(frame: Frame(type: .hello, payload: Array("{not json".utf8))) }
        #expect(throws: ProtocolError.self) { try Message(frame: Frame(type: .hello, payload: Array("{\"client\":\"x\"}".utf8))) }
        #expect(throws: ProtocolError.self) { try Message(frame: Frame(type: .welcome, payload: Array("[]".utf8))) }
    }

    @Test("trailing bytes on fixed layouts are ignored (forward compatibility)")
    func trailingBytesIgnored() throws {
        var payload: [UInt8] = []
        WireBytes.append(UInt64(5), to: &payload)
        payload += [0xAA, 0xBB]
        #expect(try Message(frame: Frame(type: .attach, payload: payload)) == .attach(fromOffset: 5))
        #expect(try Message(frame: Frame(type: .detach, payload: [9])) == .detach)
    }

    @Test("large input is split into frames that fit, submit only on the last")
    func inputSplitting() throws {
        let bytes = (0..<(Message.maxInputChunk * 2 + 10)).map { UInt8(truncatingIfNeeded: $0) }
        let messages = Message.inputMessages(bytes, submit: true)
        #expect(messages.count == 3)
        var joined: [UInt8] = []
        for (index, message) in messages.enumerated() {
            guard case .input(let flags, let chunk) = message else {
                Issue.record("not an INPUT message")
                return
            }
            #expect(flags.contains(.submit) == (index == messages.count - 1))
            #expect(message.encoded().count <= Frame.maxLength + 4)
            joined += chunk
        }
        #expect(joined == bytes)
        #expect(Message.inputMessages([1], submit: false) == [.input(flags: [], bytes: [1])])
    }

    @Test("frame type names")
    func typeNames() {
        #expect(FrameType.welcome.description == "WELCOME")
        #expect(FrameType(rawValue: 0x00AB).description == "0x00AB")
    }
}
