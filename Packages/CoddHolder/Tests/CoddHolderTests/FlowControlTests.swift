import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing

/// Reads the ring header's writeOffset straight from the file (what the app's read-only mmap sees).
func ringWriteOffset(_ session: TestSession) -> UInt64? {
    let fd = open(session.sessionDirectory + "/ring", O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { Descriptor.closeQuietly(fd) }
    var value: UInt64 = 0
    guard pread(fd, &value, 8, off_t(RingLayout.writeOffsetOffset)) == 8 else { return nil }
    return value
}

@Suite("Flow control", .serialized, .timeLimit(.minutes(3)))
struct FlowControlTests {
    // `head` line-buffers on a tty (one 2-byte write per line, slow in any terminal); `| cat` makes the
    // child write in large chunks so the test exercises the holder rather than the tty layer.
    @Test("flood + stalled client: the child keeps running, the client gets GAP and resyncs")
    func floodWithStalledClient() throws {
        let script = "yes | head -c 50000000 | cat; echo; echo FLOOD-DONE; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script], ringSize: 1 << 20)
        let (connection, _) = try session.attach(from: 0)

        // A deliberately slow client: read nothing for 1.5 s, three times the 500 ms stall watchdog.
        Clock.sleep(milliseconds: 1500)
        let writtenDuringStall = ringWriteOffset(session) ?? 0
        #expect(writtenDuringStall > 4 << 20, "the holder kept draining the PTY (\(writtenDuringStall) bytes)")

        var capture = StreamCapture(byteLimit: 64 * 1024)
        let finished = try connection.collect(into: &capture, timeoutMilliseconds: 90_000) { $0.tailContains("FLOOD-DONE") }
        #expect(finished)
        #expect(!capture.gaps.isEmpty, "a stalled client must be told about the bytes it missed")
        #expect(capture.discontinuities == 0, "OUTPUT offsets continue exactly where each GAP ends")
        for gap in capture.gaps { #expect(gap.from < gap.to) }

        // Resync: a new client (takeover) replays the ring from the latest resync point.
        let (fresh, welcome) = try session.connect(takeover: true)
        try fresh.send(.attach(fromOffset: Message.latestResync))
        var replay = StreamCapture(byteLimit: 64 * 1024)
        #expect(try fresh.collect(into: &replay, timeoutMilliseconds: 30_000) { $0.tailContains("FLOOD-DONE") })
        #expect(replay.firstOffset == welcome.resync)
        #expect(replay.gaps.isEmpty)
        #expect(welcome.ringEnd - welcome.ringStart == 1 << 20)
    }

    @Test("the child is paused at min(1 MiB, ring / 2) pending bytes, then a stall switches to drop mode")
    func pauseThreshold() throws {
        let session = try TestSession(["/bin/sh", "-c", "yes | head -c 50000000 | cat; exec cat"], ringSize: 8 << 20)
        let (connection, _) = try session.attach(from: 0)  // never reads
        // Within the 500 ms stall window: 1 MiB pending in the holder plus what the socket buffers
        // hold (about 1 MiB). The old 4 MiB limit stopped the child at about 5 MiB.
        let paused = try #require(stableRingOffset(session), "the PTY was never paused")
        #expect(paused >= 1 << 20, "paused at \(paused)")
        #expect(paused < 3 << 20, "paused at \(paused): the threshold is 1 MiB, not 4 MiB")
        // No write progress for 500 ms: drop mode, the child runs on and the ring wraps.
        #expect(waitFor(timeoutMilliseconds: 10_000) { (ringWriteOffset(session) ?? 0) > 16 << 20 })
        #expect(session.log.contains("drop mode"))
        connection.close()

        // A small ring caps the mark at half its size.
        let small = try TestSession(["/bin/sh", "-c", "yes | head -c 50000000 | cat; exec cat"], ringSize: 256 << 10)
        let (stalled, _) = try small.attach(from: 0)
        let smallPaused = try #require(stableRingOffset(small), "the PTY was never paused")
        #expect(smallPaused < (128 << 10) + (1536 << 10), "paused at \(smallPaused)")
        stalled.close()
    }

    /// The ring's write offset once it stayed unchanged for 100 ms (the PTY is paused), nil if that
    /// did not happen within 2 s.
    private func stableRingOffset(_ session: TestSession) -> UInt64? {
        let deadline = Clock.monotonicNanoseconds() + 2_000_000_000
        var last = ringWriteOffset(session) ?? 0
        var stableSince = Clock.monotonicNanoseconds()
        while Clock.monotonicNanoseconds() < deadline {
            Clock.sleep(milliseconds: 20)
            let current = ringWriteOffset(session) ?? 0
            if current != last || current == 0 {
                last = current
                stableSince = Clock.monotonicNanoseconds()
            } else if Clock.monotonicNanoseconds() - stableSince >= 100_000_000 {
                return current
            }
        }
        return nil
    }

    @Test("a slow but steady client is protected by backpressure: no GAP, nothing lost")
    func steadyClientGetsEverything() throws {
        let script = "sleep 0.2; yes | head -c 8000000 | cat; echo DONE; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script], ringSize: 1 << 20)
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture(byteLimit: 64 * 1024)
        var received = 0
        var withoutCR = 0
        let deadline = Clock.monotonicNanoseconds() + 60_000_000_000
        while !capture.tailContains("DONE"), Clock.monotonicNanoseconds() < deadline {
            guard let message = try connection.receive(timeoutMilliseconds: 1000) else { continue }
            capture.absorb(message)
            // ~16 MB/s consumer: pause 16 ms per 256 KiB received (frames are small when caught up).
            if case .output(_, let bytes) = message {
                received += bytes.count
                withoutCR += bytes.reduce(0) { $0 + ($1 == 0x0D ? 0 : 1) }
                if received >= 256 << 10 {
                    received = 0
                    Clock.sleep(milliseconds: 16)
                }
            }
        }
        #expect(capture.tailContains("DONE"))
        #expect(capture.gaps.isEmpty)
        #expect(capture.discontinuities == 0)
        // 4,000,000 × "y\n" then "DONE\n". CRs are not counted: the tty adds one per newline (ONLCR)
        // and, under backpressure, occasionally a second one when it retries the expansion.
        #expect(withoutCR == 8_000_000 + 5)
    }
}

