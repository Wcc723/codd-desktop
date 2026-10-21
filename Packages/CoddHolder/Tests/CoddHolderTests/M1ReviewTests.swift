import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import CoddHolderCore

/// Regression tests for the M1 review findings on the holder and its streaming client.
@Suite("M1 review regressions", .serialized, .timeLimit(.minutes(3)))
struct M1ReviewTests {
    // MARK: - HolderStream: pause inside a frame that straddles the replay end

    /// The app pauses from inside an OUTPUT callback when the engine's backlog crosses 4 MiB. When
    /// that callback was the replay half of a frame straddling `replayEnd`, the live half was
    /// dropped (the decoder had consumed the frame) and no GAP said so.
    @Test("a pause in the replay half of a straddling frame loses nothing")
    func pauseInStraddlingFrame() throws {
        var pausePoints = 0
        for _ in 0..<5 {
            let script = "i=0; while :; do printf '%0200d\\n' $i; i=$((i+1)); done"
            let session = try TestSession(["/bin/sh", "-c", script])
            defer { session.stop() }
            #expect(waitFor(timeoutMilliseconds: 10_000) { (ringWriteOffset(session) ?? 0) >= 3_000_000 })
            let stream = try HolderStream(socketPath: session.socketPath, clientName: "m1-review")
            let recorder = StreamRecorder(stream, byteLimit: 4096)
            let replayEnd = Atomic<UInt64>(0)
            let paused = TestFlag()
            stream.onAttach = { [recorder] attach in
                replayEnd.store(attach.replayEnd, ordering: .relaxed)
                recorder.mark("attach")
            }
            stream.onOutput = { [recorder, weak stream] offset, bytes, phase in
                recorder.recordOutput(offset, bytes, phase)
                let end = offset + UInt64(bytes.count)
                if phase == .replay, end == replayEnd.load(ordering: .relaxed), let stream, paused.setOnce() {
                    recorder.mark("paused")
                    stream.pauseReading()
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) { [weak stream] in
                        stream?.resumeReading()
                    }
                }
            }
            stream.start(takeover: false, attachFrom: .latestResync)
            #expect(recorder.wait(timeoutMilliseconds: 10_000) { $0.totalBytes > 4_000_000 })
            stream.close()
            let state = recorder.snapshot
            if state.index(of: { $0 == .mark("paused") }) != nil { pausePoints += 1 }
            #expect(state.discontinuities == 0, "OUTPUT skipped bytes without a GAP")
            #expect(state.gaps.isEmpty)
        }
        #expect(pausePoints > 0)
    }

    // MARK: - Holder: ERROR taken-over reaches a client that is reading

    /// While output streamed, the holder's outbound buffer was never empty, so `reject` skipped
    /// the ERROR and the taken-over client only saw EOF (`peerClosed`), which the app treated as
    /// a crash and answered with a reconnect that took the holder back.
    @Test("a client taken over while it reads streaming output gets ERROR taken-over")
    func takeoverOfReadingClientDeliversError() throws {
        for _ in 0..<3 {
            let session = try TestSession(["/bin/sh", "-c", "exec yes"])
            defer { session.stop() }
            let victim = try HolderStream(socketPath: session.socketPath, clientName: "victim")
            let recorder = StreamRecorder(victim, byteLimit: 1024)
            victim.onOutput = { [recorder] offset, bytes, phase in
                recorder.recordOutput(offset, bytes, phase)
                // Slower than `yes`, like an engine parsing, but fast enough to drain the socket
                // buffers within reject's 500 ms bound even on a loaded machine (2 ms per frame
                // did not: a client that falls that far behind only sees EOF, by design).
                usleep(200)
            }
            victim.start(takeover: true, attachFrom: .latestResync)
            #expect(recorder.wait { $0.totalBytes > 1_000_000 })
            let thief = try HolderStream(socketPath: session.socketPath, clientName: "thief")
            let thiefRecorder = StreamRecorder(thief, byteLimit: 1024)
            thief.start(takeover: true, attachFrom: .noAttach)
            #expect(recorder.wait(timeoutMilliseconds: 10_000) { !$0.closeReasons.isEmpty })
            #expect(thiefRecorder.wait { $0.welcome != nil })
            let reasons = recorder.snapshot.closeReasons
            #expect(reasons.first.map { reason in
                if case .holderError(let info) = reason { info.code == HolderErrorCode.takenOver } else { false }
            } == true, "\(reasons)")
            #expect(recorder.snapshot.discontinuities == 0, "ERROR started inside a frame")
            thief.close()
            victim.close()
        }
    }

    // MARK: - Ring: alternate-screen redraws keep main-screen points

    @Test("main-screen history survives a full-screen program that cleared its screen 20 times")
    func alternateScreenClearsKeepMainScreenHistory() throws {
        let script = "printf 'MAINTEXT\\r\\n'; printf '\\033[?1049h'; i=0; while [ $i -lt 20 ]; do "
            + "printf '\\033[H\\033[2Jframe%d' $i; i=$((i+1)); done; printf '\\033[?1049l'; printf 'AFTER'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        defer { session.stop() }
        #expect(waitFor { (ringWriteOffset(session) ?? 0) > 200 })
        Clock.sleep(milliseconds: 200)
        let stream = try HolderStream(socketPath: session.socketPath, clientName: "m1-review")
        let recorder = StreamRecorder(stream, byteLimit: 1 << 20)
        stream.start(takeover: false, attachFrom: .latestResync)
        #expect(recorder.wait { $0.text.contains("AFTER") })
        stream.close()
        let state = recorder.snapshot
        #expect(state.welcome?.resync == 0, "the spawn point, still in the ring")
        #expect(state.text.hasPrefix("MAINTEXT"))
    }

    // MARK: - Installer: a running app's copy survives another instance's collection

    @Test("GC keeps an old copy a running app marked in use, and a reinstall restarts the grace period")
    func garbageCollectionHonoursCopiesInUse() throws {
        let root = try TemporaryDirectory()
        let bin = root.path + "/bin"
        let bytes = try PosixFile.readAll(TestBinaries.holder, maxBytes: 256 << 20)
        try PosixFile.ensurePrivateDirectory(bin)
        let marked = bin + "/codd-holder-aaaaaaaaaaaa"
        let unmarked = bin + "/codd-holder-bbbbbbbbbbbb"
        for path in [marked, unmarked] {
            try PosixFile.writeAtomically(path, bytes, mode: 0o755)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: path)
        }
        #expect(HolderBinaryInstaller.markInUse(marked))
        #expect(HolderBinaryInstaller.markInUse(marked), "idempotent")
        let removed = HolderBinaryInstaller.collectGarbage(dataRoot: root.path, keeping: [], minimumAgeSeconds: 60)
        #expect(removed == [unmarked])
        #expect(PosixFile.exists(marked))

        // Reusing an old verified copy refreshes its mtime: the grace period starts again.
        let installed = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: installed.path)
        let again = try HolderBinaryInstaller.install(bundledHolder: TestBinaries.holder, dataRoot: root.path)
        #expect(!again.copied)
        #expect(HolderBinaryInstaller.collectGarbage(dataRoot: root.path, keeping: [], minimumAgeSeconds: 60).isEmpty)
        #expect(PosixFile.exists(installed.path))
    }

    // MARK: - Holder: a missing working directory is named as such

    @Test("a chdir failure names the folder, not the program")
    func chdirFailureNamesTheFolder() throws {
        let missing = "/tmp/codd-m1-review-missing-\(getpid())"
        let session = try TestSession(["/bin/cat"], cwd: missing)
        defer { session.stop() }
        let (connection, welcome) = try session.attach(from: 0)
        var capture = StreamCapture()
        if !welcome.exited { _ = try connection.collect(into: &capture) { $0.exit != nil } }
        _ = try connection.collect(into: &capture, timeoutMilliseconds: 500) { $0.text.contains("chdir failed") }
        #expect(capture.text.contains("codd-holder: \(missing): chdir failed"), "\(capture.text.debugDescription)")
        #expect(!capture.text.contains("/bin/cat: chdir"))
    }

    /// Review E2E-4: reattaching while a full-screen program ran replayed from its newest point
    /// only, so once it exited the main screen (the shell's history, the command line) was blank.
    @Test("an attach during a full-screen program replays the main screen before it, and says the program is on")
    func attachDuringAlternateScreenKeepsTheMainScreen() throws {
        let script = "printf 'SHELL-HISTORY\\r\\n'; printf '\\033[?1049h\\033[H\\033[2Jfull-screen'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        defer { session.stop() }
        #expect(waitFor { (ringWriteOffset(session) ?? 0) > 30 })
        Clock.sleep(milliseconds: 150)
        let stream = try HolderStream(socketPath: session.socketPath, clientName: "m1-review")
        let recorder = StreamRecorder(stream, byteLimit: 1 << 20)
        stream.start(takeover: false, attachFrom: .latestResync)
        #expect(recorder.wait { $0.text.contains("full-screen") })
        stream.close()
        let state = recorder.snapshot
        #expect(state.welcome?.resync == 0)
        #expect(state.welcome?.modes.altScreen == true)
        #expect(state.text.hasPrefix("SHELL-HISTORY"))
        let attach = try #require(state.attaches.first)
        #expect(attach.modes?.altScreen == false, "the replay starts on the main screen")
        #expect(attach.currentModes?.altScreen == true, "and ends in the program (REPAINT is due)")
    }

    // MARK: - ClientConnection: frame-aligned buffer

    @Test("dropping unsent frames keeps a partly written frame whole; compaction keeps frame boundaries")
    func outbufStaysFrameAligned() {
        let connection = ClientConnection(tag: 1, fd: -1, now: 0)
        let first = Message.title("first").encoded()
        let second = Message.output(offset: 0, bytes: [UInt8](repeating: 0x61, count: 100)).encoded()
        let third = Message.title("third").encoded()
        connection.outbuf = first + second + third
        // Mid-way through the second frame: it stays, the third goes.
        connection.outIndex = first.count + 10
        connection.dropUnsentFrames()
        #expect(connection.outbuf == first + second)
        // On a boundary: nothing partly written, everything unsent goes.
        connection.outbuf = first + second + third
        connection.outIndex = first.count
        connection.dropUnsentFrames()
        #expect(connection.outbuf == first)

        // Compaction past 256 KiB removes only whole frames.
        let big = Message.output(offset: 0, bytes: [UInt8](repeating: 0x62, count: 60_000)).encoded()
        connection.outbuf = Array([[UInt8]](repeating: big, count: 6).joined())
        connection.outIndex = 5 * big.count - 7
        connection.compactOutbuf()
        #expect(connection.outIndex == big.count - 7)
        #expect(connection.outbuf == big + big)
    }
}
