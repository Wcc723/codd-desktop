import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Testing
@testable import CoddHolderCore

/// Resync points and the alternate screen.
///
/// Leaving the alternate screen restores the main screen as it was before the switch. A replay that
/// starts at (or after) the switch cannot reproduce that content, so the holder must fall back to the
/// last main-screen point; otherwise reattaching after `vim`, `less` or `htop` shows a blank shell.
@Suite("Alternate screen resync", .serialized, .timeLimit(.minutes(2)))
struct AlternateScreenResyncTests {
    private static let esc = "\u{1B}"

    private func resyncEvents(_ text: String, chunk: Int) -> [ResyncPoint] {
        var scanner = OutputScanner()
        var events: [ResyncPoint] = []
        let bytes = Array(text.utf8)
        var start = 0
        while start < bytes.count {
            let end = min(bytes.count, start + chunk)
            bytes[start..<end].withUnsafeBytes { scanner.scan($0, at: UInt64(start)) }
            events += scanner.takeEvents().resyncs
            start = end
        }
        return events
    }

    private var alternate: TerminalModes {
        var modes = TerminalModes()
        modes.altScreen = true
        return modes
    }

    // MARK: - Scanner

    @Test("entering records a point, leaving reports an exit; re-entering or leaving twice does neither")
    func scannerReportsTransitionsOnly() {
        let esc = Self.esc
        // 0..<8 enter, 8..<16 enter again (no-op), 16 "x", 17..<25 leave, 25..<33 leave again (no-op).
        let text = "\(esc)[?1049h" + "\(esc)[?1049h" + "x\(esc)[?1049l" + "\(esc)[?1049l"
        for chunk in [1, 3, 1000] {
            let events = resyncEvents(text, chunk: chunk)
            #expect(events.map(\.offset) == [8, 25])
            #expect(events.map(\.leavesAlternateScreen) == [false, true])
            #expect(events.first?.modes.altScreen == true)
            #expect(events.last?.modes.altScreen == false)
        }
    }

    @Test("modes set in the same CSI as the screen switch belong to the resync point")
    func combinedSequence() {
        for chunk in [1, 1000] {
            let events = resyncEvents("\(Self.esc)[?1049;1;2004h", chunk: chunk)
            #expect(events.count == 1)
            let modes = events.first?.modes
            #expect(modes?.altScreen == true)
            #expect(modes?.applicationCursorKeys == true, "?1 is part of the sequence the point follows")
            #expect(modes?.bracketedPaste == true)
        }
    }

    // MARK: - Ring

    @Test("leaving drops the alternate-screen points; the last main-screen point is latest again")
    func ringFallsBackToMainScreenPoint() throws {
        let directory = try TemporaryDirectory()
        let ring = try RingBuffer(path: directory.path + "/ring", capacity: 128 << 10)
        ring.beginSession()  // point 0: the spawn offset, main screen
        ring.append([UInt8](repeating: 0x61, count: 1000))
        ring.recordResync(ResyncPoint(offset: 100, modes: TerminalModes()))
        ring.recordResync(ResyncPoint(offset: 200, modes: alternate))
        ring.recordResync(ResyncPoint(offset: 300, modes: alternate))
        // While the program runs, the main-screen point is the one to replay from (within the
        // allowance): it restores the main screen too (review E2E-4).
        #expect(ring.latestResync == 100)
        #expect(ring.latestResyncModes == TerminalModes())

        ring.recordResync(ResyncPoint(offset: 400, modes: TerminalModes(), leavesAlternateScreen: true))
        #expect(ring.latestResync == 100)
        #expect(ring.latestResyncModes == TerminalModes())

        // The header a read-only reader sees: two points, rewritten from slot 0.
        let path = directory.path + "/ring"
        #expect(headerUInt32(path, at: RingLayout.resyncCountOffset) == 2)
        #expect(headerUInt64(path, at: RingLayout.resyncArrayOffset) == 0)
        #expect(headerUInt64(path, at: RingLayout.resyncArrayOffset + 8) == 100)
        #expect(headerUInt64(path, at: RingLayout.resyncArrayOffset + 16) == 0, "dropped slots are cleared")

        // Points recorded afterwards continue in the next slot.
        ring.recordResync(ResyncPoint(offset: 500, modes: TerminalModes()))
        #expect(headerUInt32(path, at: RingLayout.resyncCountOffset) == 3)
        #expect(headerUInt64(path, at: RingLayout.resyncArrayOffset + 16) == 500)
        #expect(ring.latestResync == 500)
    }

    @Test("on the alternate screen, a main-screen point too far back is not used; the newest point is")
    func mainScreenPointBeyondTheAllowance() throws {
        let directory = try TemporaryDirectory()
        let ring = try RingBuffer(path: directory.path + "/ring", capacity: 8 << 20)
        ring.beginSession()
        let far = RingBuffer.mainScreenReplayAllowance + 1000
        ring.append([UInt8](repeating: 0x61, count: Int(far) + 10))
        ring.recordResync(ResyncPoint(offset: 500, modes: alternate))
        #expect(ring.latestResync == 0, "within the allowance")
        ring.recordResync(ResyncPoint(offset: far, modes: alternate))
        #expect(ring.latestResync == far)
        #expect(ring.latestResyncModes == alternate)
    }

    /// Review finding: sixteen alternate-screen points used to push the spawn point out of the 16
    /// slots, and leaving the alternate screen then replayed from the exit offset (a blank main
    /// screen) although the main-screen point was still in the ring. Only the newest
    /// alternate-screen point is kept now.
    @Test("alternate-screen points replace each other and never push main-screen points out")
    func alternateScreenPointsDoNotEvictMainScreenPoints() throws {
        let directory = try TemporaryDirectory()
        let ring = try RingBuffer(path: directory.path + "/ring", capacity: 128 << 10)
        ring.beginSession()
        ring.append([UInt8](repeating: 0x61, count: 1000))
        for index in 0..<(3 * RingLayout.resyncSlots) {
            ring.recordResync(ResyncPoint(offset: 500 + UInt64(index), modes: alternate))
        }
        #expect(ring.resyncPoints.map(\.offset) == [0, 547])
        #expect(ring.latestResync == 0, "the main-screen point, within the allowance")
        let path = directory.path + "/ring"
        #expect(headerUInt32(path, at: RingLayout.resyncCountOffset) == 2)
        #expect(headerUInt64(path, at: RingLayout.resyncArrayOffset + 8) == 547)
        ring.recordResync(ResyncPoint(offset: 600, modes: TerminalModes(), leavesAlternateScreen: true))
        #expect(ring.latestResync == 0)
        #expect(ring.latestResyncModes == TerminalModes())
    }

    @Test("without a main-screen point left in the ring, the exit offset becomes the resync point")
    func ringFallsBackToExitOffset() throws {
        let directory = try TemporaryDirectory()
        let ring = try RingBuffer(path: directory.path + "/ring", capacity: 128 << 10)
        ring.beginSession()
        ring.append([UInt8](repeating: 0x61, count: 200_000))  // the spawn point (0) is overwritten
        ring.recordResync(ResyncPoint(offset: 150_000, modes: alternate))
        ring.recordResync(ResyncPoint(offset: 199_000, modes: TerminalModes(), leavesAlternateScreen: true))
        #expect(ring.latestResync == 199_000)
        #expect(ring.latestResyncModes == TerminalModes())
    }

    @Test("a main-screen point that fell out of the ring is not used; the exit offset is")
    func ringIgnoresOverwrittenMainScreenPoint() throws {
        let directory = try TemporaryDirectory()
        let ring = try RingBuffer(path: directory.path + "/ring", capacity: 128 << 10)
        ring.beginSession()
        ring.recordResync(ResyncPoint(offset: 0, modes: TerminalModes()))
        ring.append([UInt8](repeating: 0x61, count: 300_000))  // the ring now starts at 168,928
        ring.recordResync(ResyncPoint(offset: 200_000, modes: alternate))
        ring.recordResync(ResyncPoint(offset: 290_000, modes: TerminalModes(), leavesAlternateScreen: true))
        #expect(ring.oldestOffset > 0)
        #expect(ring.latestResync == 290_000)
    }

    // MARK: - End to end

    @Test("reattaching after the alternate screen was left replays the main screen from before the switch")
    func replayAfterAlternateScreen() throws {
        // "MAIN-TEXT\r\n" (ONLCR) ends at 11, enter ends at 19, the clear inside it at 26, the exit at 38.
        let script = "printf 'MAIN-TEXT\\n\\033[?1049hALT\\033[2JALT2\\033[?1049lAFTER'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 43 })
        let (connection, welcome) = try session.attach(from: Message.latestResync)
        #expect(welcome.resync == 0, "the spawn point, not the switch (19), the clear (26) or the exit (38)")
        #expect(welcome.resyncModes == TerminalModes())
        #expect(!welcome.modes.altScreen)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("AFTER") })
        #expect(capture.firstOffset == 0)
        #expect(capture.text.hasPrefix("MAIN-TEXT"))

        let ringPath = session.sessionDirectory + "/ring"
        #expect(headerUInt32(ringPath, at: RingLayout.resyncCountOffset) == 1)
        #expect(headerUInt64(ringPath, at: RingLayout.resyncArrayOffset) == 0)
    }
}

private func headerUInt32(_ path: String, at offset: Int) -> UInt32? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { Descriptor.closeQuietly(fd) }
    var value: UInt32 = 0
    guard pread(fd, &value, 4, off_t(offset)) == 4 else { return nil }
    return value
}

private func headerUInt64(_ path: String, at offset: Int) -> UInt64? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { Descriptor.closeQuietly(fd) }
    var value: UInt64 = 0
    guard pread(fd, &value, 8, off_t(offset)) == 8 else { return nil }
    return value
}
