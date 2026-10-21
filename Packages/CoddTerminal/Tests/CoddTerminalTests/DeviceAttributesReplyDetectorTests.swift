import Testing
@testable import CoddTerminal

@Suite("DA1 reply detector")
struct DeviceAttributesReplyDetectorTests {
    private static func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    /// `#expect` cannot call a mutating method on its operand.
    private func feed(_ detector: inout DeviceAttributesReplyDetector, _ bytes: [UInt8]) -> Bool {
        detector.consume(bytes)
    }

    @Test(arguments: [
        "\u{1B}[?62;22;52c",          // libghostty's reply
        "\u{1B}[?65;4;1;2;6;21;22;17;28c", // SwiftTerm's reply
        "\u{1B}[?1;2c",
        "\u{1B}[?c",
    ])
    func findsWholeReply(reply: String) {
        var detector = DeviceAttributesReplyDetector()
        #expect(feed(&detector, Self.bytes(reply)))
    }

    @Test func findsReplySplitAcrossEveryBoundary() {
        let reply = Self.bytes("ab\u{1B}[?62;22;52cxy")
        for split in 1 ..< reply.count {
            var detector = DeviceAttributesReplyDetector()
            let first = detector.consume(Array(reply[..<split]))
            let second = detector.consume(Array(reply[split...]))
            // The reply ends at index 13 (the `c`); exactly one chunk contains it.
            #expect(first != second, "split at \(split)")
            #expect(first == (split > 13), "split at \(split)")
        }
    }

    @Test func findsReplyFedOneByteAtATime() {
        var detector = DeviceAttributesReplyDetector()
        var hits = 0
        for byte in Self.bytes("\u{1B}[>0q\u{1B}[?2026;2$y\u{1B}[?62;22c") where detector.consume([byte]) {
            hits += 1
        }
        #expect(hits == 1)
    }

    @Test(arguments: [
        "\u{1B}[>1;10;0c",      // DA2 (secondary), not DA1
        "\u{1B}[?2026;2$y",     // DECRPM
        "\u{1B}[?0u",           // kitty keyboard flags
        "\u{1B}[62;22c",        // no `?`
        "\u{1B}[?62;22;52",     // unfinished
        "\u{1B}[13;2u",         // Shift+Enter under kitty keyboard
        "\u{1B}[A\u{1B}[?",     // arrow then a dangling prefix
        "plain text c",
        "?62;22c",              // no ESC [
    ])
    func ignoresOtherSequences(text: String) {
        var detector = DeviceAttributesReplyDetector()
        #expect(!feed(&detector, Self.bytes(text)))
    }

    @Test func escapeInsideCandidateRestartsMatching() {
        var detector = DeviceAttributesReplyDetector()
        #expect(feed(&detector, Self.bytes("\u{1B}[?62;\u{1B}[?1c")))
        #expect(!feed(&detector, Self.bytes("\u{1B}[?62;x1c")))
    }

    @Test func countsEveryReplyAndResets() {
        var detector = DeviceAttributesReplyDetector()
        #expect(feed(&detector, Self.bytes("\u{1B}[?62c")))
        #expect(feed(&detector, Self.bytes("\u{1B}[?62c")))
        #expect(!feed(&detector, Self.bytes("\u{1B}[?6")))
        detector.reset()
        #expect(!feed(&detector, Self.bytes("2c")))
    }

    @Test func overlongParametersAreNotAReply() {
        var detector = DeviceAttributesReplyDetector()
        let long = "\u{1B}[?" + String(repeating: "1;", count: 40) + "c"
        #expect(!feed(&detector, Self.bytes(long)))
    }
}
