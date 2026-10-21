import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing
@testable import CoddHolderCore

/// Regression tests for defects found in the adversarial review of the holder.
@Suite("Review regressions", .serialized, .timeLimit(.minutes(3)))
struct ReviewRegressionTests {
    // MARK: - Crash: oversized client name

    /// HELLO whose `client` is 300,000 raw DEL bytes: valid JSON (DEL needs no escape on input), but
    /// 1.8 MB once escaped as `\u007f`, so an ERROR quoting it would overflow the 1 MiB frame limit.
    /// Built by hand because our own serializer would escape the bytes on the way out.
    private func rawHello(takeover: Bool) -> [UInt8] {
        let name = [UInt8](repeating: 0x7F, count: 300_000)
        let payload = Array("{\"proto\":1,\"takeover\":\(takeover),\"client\":\"".utf8) + name + Array("\"}".utf8)
        return Frame(type: .hello, payload: payload).encoded()
    }

    private func isWelcome(_ message: Message?) -> Bool {
        if case .welcome = message { return true }
        return false
    }

    @Test("an oversized client name cannot crash the holder (busy and taken-over replies quote it)")
    func hugeClientName() throws {
        let session = try TestSession(["/bin/cat"])
        let first = try HolderConnection(socketPath: session.socketPath)
        try Descriptor.writeAll(first.fd, rawHello(takeover: false))
        #expect(isWelcome(try first.receive(timeoutMilliseconds: 5000)))

        // "session is attached by <name>"
        let refused = try HolderConnection(socketPath: session.socketPath)
        #expect(throws: HolderClientError.self) { _ = try refused.handshake(client: "second") }

        // "taken over by <name>", sent to `first`.
        let third = try HolderConnection(socketPath: session.socketPath)
        try Descriptor.writeAll(third.fd, rawHello(takeover: true))
        #expect(isWelcome(try third.receive(timeoutMilliseconds: 5000)))
        var old = StreamCapture()
        _ = try? first.collect(into: &old, timeoutMilliseconds: 2000) { !$0.errors.isEmpty }
        let message = try #require(old.errors.first?.message)
        #expect(message.utf8.count <= TextLimits.errorMessage)
        #expect(!message.unicodeScalars.contains { $0.value == 0x7F })

        var capture = StreamCapture()
        try third.roundTrip(token: 9, into: &capture)
        #expect(session.isRunning)
    }

    @Test("client text is bounded on a scalar boundary and control characters are neutralized")
    func textLimits() {
        #expect(TextLimits.printable("CODD/0.1", maxBytes: 128) == "CODD/0.1")
        #expect(TextLimits.printable("a\u{1B}[2Jb\u{7F}\u{85}", maxBytes: 128) == "a?[2Jb??")
        // "中" is 3 bytes: never cut inside it.
        #expect(TextLimits.printable("ab中文", maxBytes: 4) == "ab")
        #expect(TextLimits.printable("ab中文", maxBytes: 5) == "ab中")
        #expect(TextLimits.printable(String(repeating: "x", count: 10_000), maxBytes: 128).utf8.count == 128)
    }

    // MARK: - Flow control invariant

    /// Drives a slow but steady consumer (pauses 4 ms per 64 KiB) until `marker`.
    private func consumeSteadily(_ connection: HolderConnection, until marker: String) throws -> (StreamCapture, Int) {
        var capture = StreamCapture(byteLimit: 64 * 1024)
        var received = 0
        var withoutCR = 0
        let deadline = Clock.monotonicNanoseconds() + 60_000_000_000
        while !capture.tailContains(marker), Clock.monotonicNanoseconds() < deadline {
            guard let message = try connection.receive(timeoutMilliseconds: 1000) else { continue }
            capture.absorb(message)
            if case .output(_, let bytes) = message {
                received += bytes.count
                withoutCR += bytes.reduce(0) { $0 + ($1 == 0x0D ? 0 : 1) }
                if received >= 64 << 10 {
                    received = 0
                    Clock.sleep(milliseconds: 4)
                }
            }
        }
        return (capture, withoutCR)
    }

    @Test("a healthy client is never lapped, even with the smallest ring", arguments: [128 << 10, 2 << 20])
    func healthyClientSmallRing(ringSize: Int) throws {
        let script = "sleep 0.2; yes | head -c 8000000 | cat; echo DONE; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script], ringSize: ringSize)
        let (connection, _) = try session.attach(from: 0)
        let (capture, withoutCR) = try consumeSteadily(connection, until: "DONE")
        #expect(capture.tailContains("DONE"))
        #expect(capture.gaps.isEmpty, "gaps: \(capture.gaps.prefix(3))")
        #expect(capture.discontinuities == 0)
        #expect(withoutCR == 8_000_000 + 5)
    }

    // MARK: - GAP policy on ATTACH

    @Test("ATTACH below the ring start reports a GAP and replays from a resync point, not mid-stream")
    func attachBelowRingStart() throws {
        // 300 KB of 'a' (more than the 128 KiB ring), then a clear screen, then the visible screen.
        let script = "head -c 300000 /dev/zero | tr '\\\\0' a; printf '\\033[2JBBB'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script], ringSize: 128 << 10)
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 300_007 })
        let (connection, welcome) = try session.attach(from: 0)
        #expect(welcome.ringStart > 0, "the ring wrapped")
        #expect(welcome.resync == 300_004, "right after ESC [ 2 J")
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("BBB") })
        #expect(capture.gaps.count == 1)
        #expect(capture.gaps.first?.from == 0)
        #expect(capture.gaps.first?.to == welcome.resync)
        #expect(capture.firstOffset == welcome.resync)
        #expect(capture.text.hasPrefix("BBB"))
        #expect(capture.discontinuities == 0)
    }

    // MARK: - Input backpressure

    @Test("input backpressure engages above 4 MiB and does not wedge the holder when the child exits")
    func pausedInputThenChildExit() throws {
        let session = try TestSession(["/bin/sh", "-c", "stty raw -echo; sleep 2"], lingerMilliseconds: 200)
        let (connection, _) = try session.attach(from: 0)
        // Far more than the 4 MiB pause threshold, written from another thread: the write blocks
        // once the holder stops reading this socket.
        var frames: [UInt8] = []
        for message in Message.inputMessages([UInt8](repeating: UInt8(ascii: "x"), count: 8 << 20), submit: false) {
            message.append(to: &frames)
        }
        let fd = connection.fd
        let payload = frames
        Thread { try? Descriptor.writeAll(fd, payload) }.start()
        #expect(waitFor(timeoutMilliseconds: 5000) { session.log.contains("pausing client reads") })
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture, timeoutMilliseconds: 10_000) { $0.exit != nil })
        connection.close()
        #expect(session.waitForExit(timeoutMilliseconds: 5000) != nil, "holder exits after the linger period")
    }

    // MARK: - Control queue

    @Test("PONGs for a client that never reads are bounded; EXIT is still kept")
    func pongFloodBounded() {
        var queue = ControlQueue()
        queue.push(ControlFrame(afterOffset: 0, kind: .exit, bytes: [1]))
        for index in 0..<10_000 {
            queue.push(ControlFrame(afterOffset: 0, kind: .pong, bytes: [UInt8(truncatingIfNeeded: index)]))
        }
        #expect(queue.count == ControlQueue.limit)
        #expect(queue.first?.kind == .exit)
    }

    @Test("a control queue that never runs empty does not keep released frames")
    func controlQueueCompacts() {
        // A client that stays a little behind while titles keep coming: one frame is always pending.
        var queue = ControlQueue()
        queue.push(ControlFrame(afterOffset: 0, kind: .title, bytes: [0]))
        for index in 1...10_000 {
            queue.push(ControlFrame(afterOffset: UInt64(index), kind: .title, bytes: [1]))
            queue.removeFirst()
        }
        #expect(queue.count == 1)
        #expect(queue.first?.afterOffset == 10_000)
        #expect(queue.storageCount < 200, "released frames are compacted (\(queue.storageCount) slots held)")
    }

    // MARK: - Startup failure keeps the previous record

    @Test("a holder that fails to start leaves the previous holder's exit record in the ring header")
    func failedStartKeepsRingRecord() throws {
        let first = try TestSession(["/bin/sh", "-c", "exit 3"], lingerMilliseconds: 0)
        #expect(first.waitForExit(timeoutMilliseconds: 5000) != nil)
        let ringPath = first.sessionDirectory + "/ring"
        #expect(ringFlags(ringPath).map { $0 & RingLayout.flagChildExited != 0 } == true)

        // Same session directory, but a socket path owned by another live holder: exits with 71.
        let blocker = try TestSession(["/bin/cat"])
        let launch = HolderLaunch(
            holderExecutable: TestBinaries.holder, session: "test-session", sessionDirectory: first.sessionDirectory,
            socketPath: blocker.socketPath, cols: 80, rows: 24, cwd: "/tmp", argv: ["/bin/cat"])
        let pid = try HolderSpawner.spawn(launch)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(ProcessTermination(waitStatus: status) == ProcessTermination(status: 71, signaled: false))
        let flags = try #require(ringFlags(ringPath))
        #expect(flags & RingLayout.flagChildExited != 0, "exit record survives the failed start")
        #expect(flags & RingLayout.flagHolderExited != 0)
        #expect(ringInt32(ringPath, at: RingLayout.exitStatusOffset) == 3)
    }

    // MARK: - Modes at the resync point

    @Test("WELCOME resyncModes and the ring header describe the modes at `resync`, modes the current ones")
    func resyncModesInWelcome() throws {
        // Alt screen (resync), then kitty push + bracketed paste after it.
        let script = "printf '\\033[?1049hscreen\\033[>1u\\033[?2004hREADY'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 25 })
        let (connection, welcome) = try session.attach(from: Message.latestResync)
        // The program is on the alternate screen: the replay starts at the main-screen point
        // before it (the spawn offset, within the allowance; M1 review E2E-4), with that point's
        // modes. `modes` are the current ones.
        #expect(welcome.resync == 0, "the spawn point, not the switch at 8")
        #expect(welcome.modes.altScreen && welcome.modes.bracketedPaste && welcome.modes.kittyKeyboardFlags == 1)
        let atResync = try #require(welcome.resyncModes)
        #expect(!atResync.altScreen)
        #expect(!atResync.bracketedPaste && atResync.kittyKeyboardFlags == 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        #expect(capture.firstOffset == welcome.resync)

        // Same data in the ring header for a read-only ring reader: slot 1 (slot 0 is the spawn offset).
        let ringPath = session.sessionDirectory + "/ring"
        #expect(ringInt32(ringPath, at: RingLayout.resyncCountOffset) == 2)
        let bits = ringInt32(ringPath, at: RingLayout.resyncModesArrayOffset + 8).map { UInt32(bitPattern: $0) }
        let kitty = ringInt32(ringPath, at: RingLayout.resyncModesArrayOffset + 12)
        #expect(bits.map { TerminalModes(bits: $0, kittyKeyboardFlags: 0).altScreen } == true)
        #expect(kitty == 0)
    }

    // MARK: - Discovery

    @Test("a meta.json from an earlier boot is never reported live, even if its pid is a holder now")
    func staleBootIsNotLive() throws {
        let session = try TestSession(["/bin/cat"])
        var meta = try #require(session.meta)
        #expect(SessionDirectory.isLive(meta))
        meta.boot = "00000000-0000-0000-0000-000000000000"
        #expect(!SessionDirectory.isLive(meta))
        #expect(!SessionDirectory.isHolderProcess(getpid()), "the test runner is not a holder")
    }

    @Test("--exit-linger-ms is bounded")
    func lingerBounded() {
        let base = ["--session", "s", "--dir", "/s", "--socket", "/a", "--cols", "80", "--rows", "24", "--cwd", "/"]
        #expect(throws: HolderOptions.UsageError.self) {
            try HolderOptions.parse(base + ["--exit-linger-ms", "9223372036854775807", "--", "sh"])
        }
        #expect((try? HolderOptions.parse(base + ["--exit-linger-ms", "86400000", "--", "sh"]))?.exitLingerMilliseconds == 86_400_000)
    }
}

/// Header u32 at `offset` of a ring file.
private func ringInt32(_ path: String, at offset: Int) -> Int32? {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { Descriptor.closeQuietly(fd) }
    var value: Int32 = 0
    guard pread(fd, &value, 4, off_t(offset)) == 4 else { return nil }
    return value
}

private func ringFlags(_ path: String) -> UInt32? {
    ringInt32(path, at: RingLayout.flagsOffset).map { UInt32(bitPattern: $0) }
}
