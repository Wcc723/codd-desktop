import Testing
@testable import CoddProtocol

/// `BracketedPaste` (marker stripping shared by holder and clients), the `input.paste` wire bits and
/// `RingResync.replayPoint` (the replay start shared by the holder and `RingFileReader`).
@Suite("Paste and resync selection")
struct PasteAndResyncTests {
    private static let start = BracketedPaste.startMarker
    private static let end = BracketedPaste.endMarker

    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    /// Reference: remove the first marker found until none is left.
    private func naiveStrip(_ input: [UInt8]) -> [UInt8] {
        var current = input
        while true {
            var found: Int?
            if current.count >= 6 {
                for index in 0...(current.count - 6) {
                    let window = Array(current[index..<(index + 6)])
                    if window == Self.start || window == Self.end {
                        found = index
                        break
                    }
                }
            }
            guard let index = found else { return current }
            current.removeSubrange(index..<(index + 6))
        }
    }

    private func containsMarker(_ input: [UInt8]) -> Bool {
        guard input.count >= 6 else { return false }
        return (0...(input.count - 6)).contains { index in
            let window = Array(input[index..<(index + 6)])
            return window == Self.start || window == Self.end
        }
    }

    // MARK: - Stripping

    @Test("markers are removed, including the ones removal uncovers; near-markers stay")
    func stripping() {
        let esc = "\u{1B}"
        #expect(BracketedPaste.strippingMarkers(bytes("plain\ntext")) == bytes("plain\ntext"))
        #expect(BracketedPaste.strippingMarkers(bytes("a\(esc)[200~b\(esc)[201~c")) == bytes("abc"))
        #expect(BracketedPaste.strippingMarkers(bytes("\(esc)[20\(esc)[200~0~")) == [])
        #expect(BracketedPaste.strippingMarkers(bytes("\(esc)[20\(esc)[20\(esc)[201~0~1~x")) == bytes("x"), "two levels")
        #expect(BracketedPaste.strippingMarkers(bytes("\(esc)[2001~\(esc)[202~\(esc)[200")) == bytes("\(esc)[2001~\(esc)[202~\(esc)[200"))
        #expect(BracketedPaste.strippingMarkers(bytes("\(esc)[A\(esc)[1;5C")) == bytes("\(esc)[A\(esc)[1;5C"), "other sequences stay")
    }

    @Test("fuzz: the result never contains a marker and equals repeated removal")
    func strippingFuzz() {
        var state: UInt64 = 0x1234_5678
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        // An alphabet that builds markers often.
        let alphabet: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x31, 0x7E, 0x61]
        for _ in 0..<5000 {
            let length = Int(next() % 40)
            let input = (0..<length).map { _ in alphabet[Int(next() % UInt64(alphabet.count))] }
            let stripped = BracketedPaste.strippingMarkers(input)
            #expect(!containsMarker(stripped))
            #expect(stripped == naiveStrip(input))
            #expect(BracketedPaste.strippingMarkers(stripped) == stripped)
        }
    }

    @Test("wrap brackets the stripped content; nothing left means nothing to paste")
    func wrap() {
        #expect(BracketedPaste.wrap(bytes("hi\nthere")) == Self.start + bytes("hi\nthere") + Self.end)
        #expect(BracketedPaste.wrap([]) == [])
        #expect(BracketedPaste.wrap(Self.end + Self.start) == [])
        #expect(BracketedPaste.overhead == 12)
    }

    // MARK: - Wire

    @Test("INPUT paste flag is bit1, round-trips, and input.paste is advertised")
    func wireBits() throws {
        #expect(InputFlags.paste.rawValue == 0x02)
        let message = Message.input(flags: [.paste, .submit], bytes: bytes("x"))
        #expect(message.payload == [0x03] + bytes("x"))
        #expect(try Message(frame: message.frame) == message)
        #expect(HolderCapability.inputPaste == "input.paste")
        #expect(HolderCapability.v1.contains(HolderCapability.inputPaste))
        let split = Message.inputMessages([UInt8](repeating: 0x61, count: Message.maxInputChunk + 1), submit: true, paste: true)
        let flags = split.compactMap { message -> InputFlags? in
            if case .input(let flags, _) = message { flags } else { nil }
        }
        #expect(flags == [.paste, [.paste, .submit]])
        #expect(Message.inputMessages(bytes("y"), submit: true) == [.input(flags: .submit, bytes: bytes("y"))])
    }

    // MARK: - Resync selection

    private func point(_ offset: UInt64, alt: Bool = false) -> RingResyncPoint {
        var modes = TerminalModes()
        modes.altScreen = alt
        return RingResyncPoint(offset: offset, modes: modes)
    }

    @Test("newest point in the ring; the main-screen point within 2 MiB while the alternate screen is on")
    func replayPoint() {
        let allowance = RingResync.mainScreenReplayAllowance
        #expect(RingResync.replayPoint([], oldestOffset: 0) == nil)
        #expect(RingResync.replayPoint([point(5), point(9)], oldestOffset: 0) == point(9))
        #expect(RingResync.replayPoint([point(5), point(9)], oldestOffset: 10) == nil, "the newest fell out: none survived")
        #expect(RingResync.replayPoint([point(5), point(9, alt: true)], oldestOffset: 0) == point(5))
        #expect(RingResync.replayPoint([point(5), point(9, alt: true)], oldestOffset: 6) == point(9, alt: true), "main point out of the ring")
        #expect(RingResync.replayPoint([point(0), point(allowance, alt: true)], oldestOffset: 0) == point(0))
        #expect(RingResync.replayPoint([point(0), point(allowance + 1, alt: true)], oldestOffset: 0) == point(allowance + 1, alt: true))
        #expect(RingResync.replayPoint([point(9, alt: true)], oldestOffset: 0) == point(9, alt: true), "no main-screen point")
        // A damaged table (offsets going backwards) must not trap.
        #expect(RingResync.replayPoint([point(50), point(9, alt: true)], oldestOffset: 0) == point(9, alt: true))
    }
}
