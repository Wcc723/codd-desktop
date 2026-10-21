import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing

/// `HolderStream` against real holders in temporary directories (children: /bin/sh, cat, yes).
@Suite("Holder stream", .serialized, .timeLimit(.minutes(3)))
struct HolderStreamTests {
    private func makeStream(
        _ session: TestSession, client: String = "stream-tests", options: HolderStreamOptions = HolderStreamOptions(),
        byteLimit: Int? = 1 << 20
    ) throws -> (HolderStream, StreamRecorder) {
        let stream = try HolderStream(socketPath: session.socketPath, clientName: client, options: options)
        return (stream, StreamRecorder(stream, byteLimit: byteLimit))
    }

    private func isOutput(_ event: StreamRecorder.Event) -> Bool {
        if case .output = event { return true }
        return false
    }

    private func isExit(_ event: StreamRecorder.Event) -> Bool {
        if case .exit = event { return true }
        return false
    }

    private func isAttach(_ event: StreamRecorder.Event) -> Bool {
        if case .attach = event { return true }
        return false
    }

    // MARK: - Attach, replay, live

    @Test("attach from the latest resync point replays the screen, then streams live output")
    func replayThenLive() throws {
        let session = try TestSession(["/bin/sh", "-c", "printf AAA; printf '\\033[2J'; printf BBB; exec cat"])
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 10 })
        let (stream, recorder) = try makeStream(session)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .latestResync)
        #expect(recorder.wait { $0.text.contains("BBB") })
        try stream.sendInput(Array("live\n".utf8))
        #expect(recorder.wait { $0.text.contains("live\r\nlive\r\n") })

        let state = recorder.snapshot
        let welcome = try #require(state.welcome)
        #expect(welcome.resync == 7, "right after ESC [ 2 J")
        #expect(welcome.caps.contains(HolderCapability.attachAck))
        let attach = try #require(state.attaches.first)
        #expect(attach == HolderAttach(requested: .latestResync, start: 7, replayEnd: 10, modes: TerminalModes(),
                                       currentModes: TerminalModes(), acknowledged: true))
        #expect(state.text.hasPrefix("BBB"))
        let outputs = state.events.compactMap { event -> (UInt64, Int, OutputPhase)? in
            if case .output(let offset, let count, let phase) = event { (offset, count, phase) } else { nil }
        }
        #expect(outputs.first.map { $0.0 == 7 && $0.2 == .replay } == true)
        #expect(outputs.dropFirst().allSatisfy { $0.2 == .live }, "everything after the replayed BBB is live")
        #expect(state.index(of: { if case .welcome = $0 { true } else { false } })! < state.index(of: isAttach)!)
        #expect(state.index(of: isAttach)! < state.index(of: isOutput)!)
        #expect(state.discontinuities == 0)
        #expect(state.wrongQueue == 0, "callbacks run on the stream's queue")
    }

    @Test("an ATTACH below the ring start: GAP to a resync point with its modes, then the screen")
    func attachBelowRingStart() throws {
        let script = "head -c 300000 /dev/zero | tr '\\\\0' a; printf '\\033[?2004h\\033[2JBBB'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script], ringSize: 128 << 10)
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 300_015 })
        let (stream, recorder) = try makeStream(session)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.text.contains("BBB") })
        let state = recorder.snapshot
        let attach = try #require(state.attaches.first)
        #expect(attach.start == 0 && attach.modes == nil && attach.replayEnd == 300_015)
        let gap = try #require(state.gaps.first)
        var bracketed = TerminalModes()
        bracketed.bracketedPaste = true
        #expect(gap == GapInfo(from: 0, to: 300_012, replayEnd: 300_015, resumeModes: bracketed))
        #expect(state.text == "BBB")
        #expect(state.discontinuities == 0)
    }

    @Test("detach stops OUTPUT; a new attach on the same connection replays")
    func detachAndReattach() throws {
        let session = try TestSession(["/bin/sh", "-c", "printf AAA; printf '\\033[2J'; printf BBB; exec cat"])
        let (stream, recorder) = try makeStream(session)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.text.contains("BBB") })
        stream.detach()
        try stream.sendInput(Array("while-detached\n".utf8))
        stream.ping(token: 41)
        #expect(recorder.wait { $0.pongs.contains(41) })
        Clock.sleep(milliseconds: 100)
        let detachedTotal = recorder.snapshot.totalBytes
        #expect(!recorder.snapshot.text.contains("while-detached"), "no OUTPUT while detached")

        stream.attach(from: .latestResync)
        #expect(recorder.wait { $0.attaches.count == 2 && $0.text.contains("while-detached\r\nwhile-detached\r\n") })
        let state = recorder.snapshot
        let second = state.attaches[1]
        #expect(second.start == 7 && second.acknowledged)
        #expect(state.totalBytes - detachedTotal == Int(second.replayEnd - second.start))
        #expect(state.discontinuities == 0)
    }

    @Test("re-attaching mid-flood drops OUTPUT of the old attach that was still in flight")
    func reattachDropsStaleOutput() throws {
        let script = "while :; do printf '\\033[2J'; head -c 200000 /dev/zero | tr '\\\\0' x; done"
        let session = try TestSession(["/bin/sh", "-c", script], ringSize: 4 << 20)
        let (stream, recorder) = try makeStream(session, byteLimit: 4096)
        defer { stream.close() }
        // Request the re-attach from inside onOutput, so the marker sits exactly at the request.
        let requested = TestFlag()
        stream.onOutput = { [recorder, weak stream] offset, bytes, phase in
            recorder.recordOutput(offset, bytes, phase)
            if recorder.totalBytes > 2 << 20, requested.setOnce() {
                recorder.mark("reattach")
                stream?.attach(from: .latestResync)
            }
        }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait(timeoutMilliseconds: 20_000) { $0.attaches.count == 2 && $0.totalBytes > 4 << 20 })
        let state = recorder.snapshot
        let mark = try #require(state.index { $0 == .mark("reattach") })
        let second = try #require(state.lastIndex(of: isAttach))
        #expect(!state.events[(mark + 1)..<second].contains(where: isOutput), "stale OUTPUT was dropped")
        if case .output(let offset, _, let phase) = state.events[second + 1], case .attach(let attach) = state.events[second] {
            #expect(offset == attach.start)
            #expect(phase == .replay)
            #expect(attach.modes == TerminalModes())
        } else {
            Issue.record("OUTPUT must follow the second attach: \(state.events[second...].prefix(2))")
        }
        #expect(state.discontinuities == 0)
        #expect(state.wrongQueue == 0)
    }

    // MARK: - Input and control frames

    @Test("INPUT round trip, with the submit flag, and a 300 KB paste")
    func inputRoundTrip() throws {
        let session = try TestSession(["/bin/cat"])
        let (stream, recorder) = try makeStream(session)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        try stream.sendInput(Array("plain\n".utf8))
        #expect(recorder.wait { $0.text.contains("plain\r\nplain\r\n") })
        try stream.sendInput(Array("submitted".utf8), submit: true)
        #expect(recorder.wait { $0.text.contains("submitted\r\nsubmitted\r\n") })

        let raw = try TestSession(["/bin/sh", "-c", "stty raw -echo; printf READY; exec cat"])
        let (rawStream, rawRecorder) = try makeStream(raw, byteLimit: nil)
        defer { rawStream.close() }
        rawStream.start(takeover: false, attachFrom: .offset(0))
        #expect(rawRecorder.wait { $0.text.contains("READY") })
        var random = SplitMix64(state: 7)
        let paste = (0..<300_000).map { _ in UInt8.random(in: 0x20...0x7E, using: &random) }
        let start = rawRecorder.snapshot.bytes.count
        try rawStream.sendInput(paste)
        #expect(rawRecorder.wait(timeoutMilliseconds: 20_000) { $0.bytes.count - start >= paste.count })
        let echoed = Array(rawRecorder.snapshot.bytes[start...])
        #expect(echoed.count == paste.count)
        #expect(fnv1a(echoed) == fnv1a(paste))
        #expect(rawStream.pendingOutboundBytes == 0)
    }

    @Test("RESIZE, SIGNAL and REPAINT reach the PTY")
    func controlFrames() throws {
        let shell = try TestSession(["/bin/sh"])
        let (stream, recorder) = try makeStream(shell)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        stream.resize(WindowSize(cols: 101, rows: 41))
        try stream.sendInput(Array("stty size\n".utf8))
        #expect(recorder.wait { $0.text.contains("41 101") })

        let cat = try TestSession(["/bin/cat"])
        let (catStream, catRecorder) = try makeStream(cat)
        defer { catStream.close() }
        catStream.start(takeover: false, attachFrom: .offset(0))
        catStream.signal(SIGINT)
        #expect(catRecorder.wait { !$0.exits.isEmpty })
        #expect(catRecorder.snapshot.exits == [ExitInfo(status: SIGINT, signaled: true)])

        let script = "trap 'echo SIZE $(stty size)' WINCH; echo READY; while :; do sleep 0.02; done"
        let trapping = try TestSession(["/bin/sh", "-c", script], cols: 80, rows: 24)
        let (repaintStream, repaintRecorder) = try makeStream(trapping)
        defer { repaintStream.close() }
        repaintStream.start(takeover: false, attachFrom: .offset(0))
        #expect(repaintRecorder.wait { $0.text.contains("READY") })
        repaintStream.repaint()
        #expect(repaintRecorder.wait { $0.text.contains("SIZE 24 79") && $0.text.contains("SIZE 24 80") })
    }

    @Test("OSC title / cwd and BEL arrive as onTitle / onCwd / onBell after the output that produced them")
    func titleCwdBell() throws {
        let session = try TestSession(["/bin/sh"])
        let (stream, recorder) = try makeStream(session)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.welcome != nil })
        let command = "printf '\\033]0;stream-title\\007\\033]7;file://h/tmp/x%%20y\\007\\007'\n"
        try stream.sendInput(Array(command.utf8))
        #expect(recorder.wait { state in
            state.events.contains(.title("stream-title")) && state.events.contains(.cwd("/tmp/x y"))
                && state.events.contains(.bell)
        })
        let state = recorder.snapshot
        let title = try #require(state.index { $0 == .title("stream-title") })
        // The OSC itself is part of an OUTPUT frame delivered before the TITLE.
        #expect(state.events[..<title].contains(where: isOutput))
        #expect(state.bytes.contains(0x1B), "the OSC bytes are in the stream too")
        #expect(state.wrongQueue == 0)
    }

    // MARK: - Takeover and refusal

    @Test("takeover: the second stream kicks the first (onError, then onClosed once); without takeover, refused")
    func takeover() throws {
        let session = try TestSession(["/bin/cat"])
        let (first, firstRecorder) = try makeStream(session, client: "first")
        defer { first.close() }
        first.start(takeover: false, attachFrom: .offset(0))
        #expect(firstRecorder.wait { $0.welcome != nil })

        let (refused, refusedRecorder) = try makeStream(session, client: "refused")
        refused.start(takeover: false, attachFrom: .offset(0))
        #expect(refusedRecorder.wait { !$0.closeReasons.isEmpty })
        #expect(refusedRecorder.snapshot.errors.map(\.code) == [HolderErrorCode.busy])
        #expect(refusedRecorder.snapshot.closeReasons.count == 1)
        if case .holderError(let info) = refusedRecorder.snapshot.closeReasons.first {
            #expect(info.code == HolderErrorCode.busy)
        } else {
            Issue.record("refused stream closed with \(refusedRecorder.snapshot.closeReasons)")
        }
        #expect(refused.isClosed)

        let (second, secondRecorder) = try makeStream(session, client: "second")
        defer { second.close() }
        second.start(takeover: true, attachFrom: .offset(0))
        #expect(firstRecorder.wait { !$0.closeReasons.isEmpty })
        #expect(firstRecorder.snapshot.errors.map(\.code) == [HolderErrorCode.takenOver])
        try second.sendInput(Array("still-works\n".utf8))
        #expect(secondRecorder.wait { $0.text.contains("still-works\r\nstill-works") })
        #expect(throws: HolderStreamError.closed) { try first.sendInput([0x61]) }
        Clock.sleep(milliseconds: 100)
        #expect(firstRecorder.snapshot.closeReasons.count == 1, "onClosed exactly once")
        #expect(firstRecorder.snapshot.afterClosed == 0)
    }

    // MARK: - Backpressure

    @Test("paused reading: the holder pauses the child, then drops; GAP resyncs at a clear-screen point")
    func pausedReadingLeadsToGap() throws {
        let script = "i=0; while [ $i -lt 60 ]; do printf '\\033[2J'; yes | head -c 400000 | cat; i=$((i+1)); done; echo; echo FLOOD-DONE; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script], ringSize: 1 << 20)
        let (stream, recorder) = try makeStream(session, byteLimit: 64 * 1024)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .latestResync)
        #expect(recorder.wait { $0.totalBytes > 0 })
        stream.pauseReading()
        #expect(stream.isReadingPaused)
        Clock.sleep(milliseconds: 100)
        let frozen = recorder.snapshot.events.count
        Clock.sleep(milliseconds: 1400)
        #expect(recorder.snapshot.events.count == frozen, "nothing is delivered while paused")
        #expect((ringWriteOffset(session) ?? 0) > 4 << 20, "drop mode: the child kept running")
        #expect(session.log.contains("drop mode"))

        stream.resumeReading()
        #expect(recorder.wait(timeoutMilliseconds: 90_000) { $0.tailContains("FLOOD-DONE") })
        let state = recorder.snapshot
        #expect(!state.gaps.isEmpty, "the stalled stream is told about the bytes it missed")
        for gap in state.gaps {
            #expect(gap.from < gap.to)
            #expect(gap.resumeModes == TerminalModes(), "GAP resumes at a clear-screen resync point")
            #expect((gap.replayEnd ?? 0) >= gap.to)
        }
        // OUTPUT right after a GAP is history up to the GAP's replayEnd.
        if let gapIndex = state.index(of: { if case .gap = $0 { true } else { false } }),
           case .gap(let gap) = state.events[gapIndex], gapIndex + 1 < state.events.count,
           case .output(let offset, _, let phase) = state.events[gapIndex + 1] {
            #expect(offset == gap.to)
            #expect(phase == (offset < (gap.replayEnd ?? 0) ? .replay : .live))
        }
        #expect(state.discontinuities == 0)
    }

    @Test("the outbound queue is bounded: input the child does not read is refused, never dropped")
    func outboundQueueBound() throws {
        let session = try TestSession(["/bin/sh", "-c", "stty raw -echo; sleep 30"])
        var options = HolderStreamOptions()
        options.maxOutboundBytes = 1 << 20
        let (stream, recorder) = try makeStream(session, options: options)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.welcome != nil })
        let chunk = [UInt8](repeating: UInt8(ascii: "x"), count: 64 << 10)
        var accepted = 0
        var refusals = 0
        var lastRefusal: HolderStreamError?
        // A refusal is retried: it only means the queue is full right now. The queue is stuck once
        // refusals persist for half a second.
        let deadline = Clock.monotonicNanoseconds() + 30_000_000_000
        while refusals < 50, Clock.monotonicNanoseconds() < deadline, accepted < 64 << 20 {
            do {
                try stream.sendInput(chunk)
                accepted += chunk.count
                refusals = 0
            } catch {
                lastRefusal = error
                refusals += 1
                Clock.sleep(milliseconds: 10)
            }
        }
        guard refusals >= 50, case .outboundQueueFull(let pending, let limit) = lastRefusal else {
            Issue.record("the queue never stayed full: accepted \(accepted), last \(String(describing: lastRefusal))")
            return
        }
        #expect(limit == 1 << 20)
        #expect(pending + chunk.count > limit)
        // The holder took its 4 MiB input queue plus socket buffers before the client queue filled.
        #expect(accepted > 4 << 20, "accepted \(accepted)")
        #expect(stream.pendingOutboundBytes <= limit)
        #expect(!stream.isClosed, "a full queue does not end the stream")
        stream.close()
        #expect(recorder.wait { !$0.closeReasons.isEmpty })
        #expect(stream.pendingOutboundBytes == 0, "discarded bytes leave the count")
    }

    // MARK: - EXIT ordering

    @Test("child exited before HELLO: onExit follows the whole replay")
    func exitAfterReplay() throws {
        let session = try TestSession(
            ["/bin/sh", "-c", "head -c 3000000 /dev/zero | tr '\\\\0' a; exit 5"], lingerMilliseconds: 20_000)
        #expect(waitFor(timeoutMilliseconds: 10_000) { session.meta?.exited == true })
        let (stream, recorder) = try makeStream(session, byteLimit: 4096)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { !$0.exits.isEmpty })
        Clock.sleep(milliseconds: 50)
        let state = recorder.snapshot
        #expect(state.welcome?.exited == true)
        #expect(state.exits == [ExitInfo(status: 5, signaled: false)])
        #expect(state.totalBytes == 3_000_000)
        #expect(state.lastIndex(of: isOutput)! < state.index(of: isExit)!, "EXIT after the last OUTPUT")
        #expect(state.attaches.first?.replayEnd == 3_000_000)
        #expect(state.events.allSatisfy { if case .output(_, _, let phase) = $0 { phase == .replay } else { true } })
    }

    @Test("an EXIT that overtakes the ATTACH on the wire is held back until the replay is done")
    func exitOvertakingAttach() throws {
        let script = "printf PRE; read x; head -c 500000 /dev/zero | tr '\\\\0' b; printf POST; exit 4"
        let session = try TestSession(["/bin/sh", "-c", script], lingerMilliseconds: 20_000)
        let (stream, recorder) = try makeStream(session, byteLimit: 4096)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .noAttach)
        #expect(recorder.wait { $0.welcome != nil })
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 3 })
        // Not reading: the holder writes EXIT into the socket before our ATTACH even exists.
        stream.pauseReading()
        try stream.sendInput([0x0A])
        #expect(waitFor(timeoutMilliseconds: 10_000) { session.meta?.exited == true })
        Clock.sleep(milliseconds: 50)
        stream.attach(from: .offset(0))
        stream.resumeReading()
        #expect(recorder.wait { !$0.exits.isEmpty })
        let state = recorder.snapshot
        #expect(state.exits == [ExitInfo(status: 4, signaled: false)])
        #expect(state.tailContains("POST"))
        #expect(state.lastIndex(of: isOutput)! < state.index(of: isExit)!)
        #expect(state.index(of: isAttach)! < state.index(of: isExit)!)
    }

    @Test("without an attach EXIT is immediate; a later attach replays without a second onExit")
    func exitWithoutAttach() throws {
        let session = try TestSession(["/bin/sh", "-c", "printf PRE; read x; printf POST; exit 3"], lingerMilliseconds: 20_000)
        let (stream, recorder) = try makeStream(session)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .noAttach)
        #expect(recorder.wait { $0.welcome != nil })
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= 3 }, "PRE before the tty echoes our newline")
        try stream.sendInput([0x0A])
        #expect(recorder.wait { !$0.exits.isEmpty })
        #expect(recorder.snapshot.totalBytes == 0)
        stream.attach(from: .offset(0))
        #expect(recorder.wait { $0.text.contains("POST") })
        Clock.sleep(milliseconds: 100)
        #expect(recorder.snapshot.exits == [ExitInfo(status: 3, signaled: false)])
        #expect(recorder.snapshot.text.hasPrefix("PRE"))
    }

    // MARK: - Ending

    @Test("holder killed: onClosed(peerClosed) exactly once, nothing after it")
    func holderKilled() throws {
        let session = try TestSession(["/bin/cat"])
        let (stream, recorder) = try makeStream(session)
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.welcome != nil })
        kill(session.pid, SIGKILL)
        #expect(recorder.wait { !$0.closeReasons.isEmpty })
        Clock.sleep(milliseconds: 100)
        #expect(recorder.snapshot.closeReasons == [.peerClosed])
        #expect(recorder.snapshot.afterClosed == 0)
        #expect(stream.isClosed)
        #expect(throws: HolderStreamError.closed) { try stream.sendInput([0x61]) }
        stream.close()  // no second onClosed
        Clock.sleep(milliseconds: 50)
        #expect(recorder.snapshot.closeReasons.count == 1)
    }

    @Test("close(): onClosed(closedLocally) once; the holder keeps running and accepts a new client")
    func closeLocally() throws {
        let session = try TestSession(["/bin/cat"])
        let (stream, recorder) = try makeStream(session)
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.welcome != nil })
        stream.close()
        #expect(recorder.wait { !$0.closeReasons.isEmpty })
        #expect(recorder.snapshot.closeReasons == [.closedLocally])
        let (again, againRecorder) = try makeStream(session)
        defer { again.close() }
        again.start(takeover: false, attachFrom: .noAttach)
        #expect(againRecorder.wait { $0.welcome != nil }, "the first client is gone, no takeover needed")
    }

    @Test("connecting to a socket nobody listens on throws connectFailed")
    func connectFailure() throws {
        let root = try TemporaryDirectory()
        #expect(throws: HolderStreamError.self) {
            _ = try HolderStream(socketPath: root.path + "/missing.sock", clientName: "x")
        }
    }

    @Test("keepalive: PINGs keep an idle stream open; a stopped holder times out")
    func keepalive() throws {
        let session = try TestSession(["/bin/cat"])
        var options = HolderStreamOptions()
        options.keepaliveIntervalMilliseconds = 50
        options.keepaliveTimeoutMilliseconds = 300
        let (stream, recorder) = try makeStream(session, options: options)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.welcome != nil })
        Clock.sleep(milliseconds: 600)
        #expect(!stream.isClosed, "PONGs answer the keepalive")
        #expect(recorder.snapshot.pongs.isEmpty, "keepalive PONGs are not reported")
        kill(session.pid, SIGSTOP)
        defer { kill(session.pid, SIGCONT) }
        #expect(recorder.wait(timeoutMilliseconds: 3000) { !$0.closeReasons.isEmpty })
        #expect(recorder.snapshot.closeReasons == [.keepaliveTimeout])
    }

    // MARK: - Throughput

    @Test("throughput: 20 MB live through the PTY, and a 32 MiB ring replay")
    func throughput() throws {
        let total = 20_000_000
        let live = try TestSession(["/bin/sh", "-c", "sleep 0.3; head -c \(total) /dev/zero; printf END; exec cat"])
        let (stream, recorder) = try makeStream(live, byteLimit: 1024)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.totalBytes > 0 })
        let start = Clock.monotonicNanoseconds()
        let startBytes = recorder.snapshot.totalBytes
        #expect(recorder.wait(timeoutMilliseconds: 60_000) { $0.tailContains("END") })
        let seconds = Double(Clock.monotonicNanoseconds() - start) / 1e9
        let state = recorder.snapshot
        let rate = Double(state.totalBytes - startBytes) / seconds / 1e6
        print("MEASURE stream live PTY->socket->callback: \(String(format: "%.0f", rate)) MB/s (\(state.totalBytes) bytes)")
        #expect(state.totalBytes == total + 3)
        #expect(state.gaps.isEmpty)
        #expect(state.discontinuities == 0)

        let ringSize = 32 << 20
        let filler = try TestSession(["/bin/sh", "-c", "head -c \(ringSize + 100_000) /dev/zero; exec cat"], ringSize: ringSize)
        #expect(waitFor(timeoutMilliseconds: 20_000) { (ringWriteOffset(filler) ?? 0) >= UInt64(ringSize + 100_000) })
        let (replay, replayRecorder) = try makeStream(filler, byteLimit: 1024)
        defer { replay.close() }
        let replayStart = Clock.monotonicNanoseconds()
        replay.start(takeover: false, attachFrom: .latestResync)
        #expect(replayRecorder.wait(timeoutMilliseconds: 30_000) { state in
            guard let attach = state.attaches.first else { return false }
            return state.totalBytes >= Int(attach.replayEnd - attach.start)
        })
        let replaySeconds = Double(Clock.monotonicNanoseconds() - replayStart) / 1e9
        let replayed = replayRecorder.snapshot.totalBytes
        print("MEASURE stream ring replay: \(String(format: "%.0f", Double(replayed) / replaySeconds / 1e6)) MB/s (\(replayed) bytes)")
        #expect(replayRecorder.snapshot.discontinuities == 0)
    }
}
