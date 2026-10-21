import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoddHolderClient
@testable import CoddHolderCore

/// `RingFileReader`: the last screen of a session read from its ring file, from the point a live
/// holder's WELCOME `resync` names, safe against a holder writing at the same time.
@Suite("Ring file reader", .serialized, .timeLimit(.minutes(3)))
struct RingFileReaderTests {
    private static let esc = "\u{1B}"

    private var alternate: TerminalModes {
        var modes = TerminalModes()
        modes.altScreen = true
        return modes
    }

    /// Kills the holder with SIGKILL (no shutdown, no header flag) and its child, which would
    /// otherwise only get the hangup of the closed master.
    private func killHard(_ session: TestSession, child: pid_t) {
        kill(session.pid, SIGKILL)
        _ = session.waitForExit(timeoutMilliseconds: 5000)
        if child > 0 { kill(child, SIGKILL) }
    }

    /// Attaches from the latest resync point and collects the replay up to `welcome.ringEnd`.
    private func replay(_ session: TestSession) throws -> (Welcome, [UInt8]) {
        let (connection, welcome) = try session.attach(from: Message.latestResync)
        var capture = StreamCapture()
        let target = Int(welcome.ringEnd - welcome.resync)
        #expect(try connection.collect(into: &capture) { $0.totalBytes >= target })
        #expect(capture.firstOffset == welcome.resync || target == 0)
        connection.close()
        return (welcome, capture.bytes)
    }

    // MARK: - Dead holders

    @Test("holder killed after a clear and an alternate-screen visit: the WELCOME resync point and its bytes")
    func deadHolderAfterAlternateScreen() throws {
        let esc = Self.esc
        let script = "printf 'AAA\(esc)[2JBBB\(esc)[?1049hALT\(esc)[2JALT2\(esc)[?1049lAFTER'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        let total: UInt64 = 3 + 4 + 3 + 8 + 3 + 4 + 4 + 8 + 5
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= total })
        let (welcome, streamed) = try replay(session)
        #expect(welcome.resync == 7, "the main-screen clear; the alternate-screen points were dropped on exit")
        killHard(session, child: welcome.childPid)

        let snapshot = try RingFileReader.read(path: session.sessionDirectory + "/ring")
        #expect(snapshot.start == welcome.resync)
        #expect(snapshot.modes == welcome.resyncModes)
        #expect(snapshot.end == welcome.ringEnd)
        #expect(snapshot.bytes == streamed)
        #expect(String(decoding: snapshot.bytes, as: UTF8.self).hasPrefix("BBB"))
        #expect(!snapshot.childExited && snapshot.exitStatus == nil)
        #expect(!snapshot.holderExitedCleanly, "SIGKILL skips the shutdown")
        #expect(snapshot.spawnOffset == 0)
        #expect(snapshot.columns == 80 && snapshot.rows == 24)
    }

    @Test("holder killed while the alternate screen is on: the main-screen point within 2 MiB")
    func deadHolderOnAlternateScreen() throws {
        let esc = Self.esc
        let script = "printf 'MAIN\(esc)[2JM2\(esc)[?1049;2004hALT\(esc)[2JALT2'; exec cat"
        let session = try TestSession(["/bin/sh", "-c", script])
        let total: UInt64 = 4 + 4 + 2 + 13 + 3 + 4 + 4
        #expect(waitFor { (ringWriteOffset(session) ?? 0) >= total })
        let (welcome, streamed) = try replay(session)
        #expect(welcome.resync == 8, "the main-screen point, not the alternate-screen clear")
        #expect(welcome.modes.altScreen && welcome.modes.bracketedPaste)
        killHard(session, child: welcome.childPid)

        let snapshot = try RingFileReader.read(path: session.sessionDirectory + "/ring")
        #expect(snapshot.start == 8)
        #expect(snapshot.modes == TerminalModes(), "modes at the main-screen point")
        #expect(snapshot.bytes == streamed)
        #expect(String(decoding: snapshot.bytes, as: UTF8.self) == "M2\(esc)[?1049;2004hALT\(esc)[2JALT2")
    }

    @Test("exit fields after a normal exit, and after a signal")
    func exitFields() throws {
        let normal = try TestSession(["/bin/sh", "-c", "sleep 0.2; printf bye; exit 3"], lingerMilliseconds: 100)
        #expect(normal.waitForExit(timeoutMilliseconds: 10_000) != nil)
        let snapshot = try RingFileReader.read(path: normal.sessionDirectory + "/ring")
        #expect(snapshot.childExited)
        #expect(snapshot.exitStatus == 3)
        #expect(!snapshot.signaled)
        #expect(snapshot.holderExitedCleanly)
        #expect(snapshot.start == 0 && snapshot.modes == TerminalModes())
        #expect(String(decoding: snapshot.bytes, as: UTF8.self) == "bye")

        let signaled = try TestSession(["/bin/sh", "-c", "sleep 0.2; printf x; kill -9 $$"], lingerMilliseconds: 100)
        #expect(signaled.waitForExit(timeoutMilliseconds: 10_000) != nil)
        let killed = try RingFileReader.read(path: signaled.sessionDirectory + "/ring")
        #expect(killed.childExited && killed.signaled)
        #expect(killed.exitStatus == SIGKILL)
        #expect(killed.holderExitedCleanly)
    }

    @Test("codd-holderctl ring: summary lines, --raw bytes, --limit, exit 2 without a ring")
    func ctlRing() throws {
        let esc = Self.esc
        let session = try TestSession(["/bin/sh", "-c", "sleep 0.2; printf 'old\(esc)[2Jnew'; exit 4"], lingerMilliseconds: 100)
        #expect(session.waitForExit(timeoutMilliseconds: 10_000) != nil)
        let summary = try runCommand(TestBinaries.ctl, ["ring", session.sessionDirectory])
        #expect(summary.status == 0)
        let lines = Set(summary.output.split(separator: "\n").map(String.init))
        for expected in ["start=7", "end=10", "size=3", "childExited=true", "exitStatus=4", "signaled=false",
                         "holderExitedCleanly=true", "spawnOffset=0", "cols=80", "rows=24"] {
            #expect(lines.contains(expected), "\(expected) in \(summary.output)")
        }
        #expect(lines.contains { $0.hasPrefix("modes={") && $0.contains("\"2004\":false") })
        let raw = try runCommand(TestBinaries.ctl, ["ring", session.sessionDirectory, "--raw"])
        #expect(raw.status == 0 && raw.output == "new")
        let limited = try runCommand(TestBinaries.ctl, ["ring", session.sessionDirectory, "--limit", "2"]).output
        #expect(limited.contains("start=8\n") && limited.contains("modes=unknown"))
        let missing = try runCommand(TestBinaries.ctl, ["ring", session.root.path + "/nowhere"])
        #expect(missing.status == 2)
    }

    // MARK: - Files that are not rings

    @Test("missing file, garbage, wrong size, wrong version, a directory")
    func notRings() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: RingFileError.missing) { try RingFileReader.read(path: directory.path + "/none") }
        #expect(throws: RingFileError.missing) { try RingFileReader.read(path: directory.path + "/none/ring") }

        let garbage = directory.path + "/garbage"
        var random = SplitMix64(state: 3)
        try PosixFile.writeAtomically(garbage, (0..<10_000).map { _ in UInt8.random(in: 0...255, using: &random) })
        #expect(isNotARing { try RingFileReader.read(path: garbage) })
        let short = directory.path + "/short"
        try PosixFile.writeAtomically(short, Array("CODDRING".utf8))
        #expect(isNotARing { try RingFileReader.read(path: short) })
        #expect(isNotARing { try RingFileReader.read(path: directory.path) })

        // A real ring, then damaged: capacity no longer matching the size, then another version.
        let path = directory.path + "/ring"
        do {
            let ring = try RingBuffer(path: path, capacity: 128 << 10)
            ring.beginSession()
            ring.append(Array("ok".utf8))
        }
        #expect(try RingFileReader.read(path: path).bytes == Array("ok".utf8))
        let fd = open(path, O_RDWR)
        defer { Descriptor.closeQuietly(fd) }
        #expect(ftruncate(fd, off_t(RingLayout.headerSize + (128 << 10) + 1)) == 0)
        #expect(isNotARing { try RingFileReader.read(path: path) })
        #expect(ftruncate(fd, off_t(RingLayout.headerSize + (128 << 10))) == 0)
        var version: UInt32 = 2
        #expect(pwrite(fd, &version, 4, off_t(RingLayout.versionOffset)) == 4)
        #expect(isNotARing { try RingFileReader.read(path: path) })
    }

    private func isNotARing(_ body: () throws -> RingSnapshot) -> Bool {
        do {
            _ = try body()
            return false
        } catch RingFileError.notARing {
            return true
        } catch {
            return false
        }
    }

    // MARK: - Same choice as the holder

    @Test("the reader picks exactly the holder's point for random resync histories (lock held by the writer)")
    func sameChoiceAsTheHolder() throws {
        let directory = try TemporaryDirectory()
        var random = SplitMix64(state: 11)
        for round in 0..<200 {
            let path = directory.path + "/ring\(round)"
            let ring = try RingBuffer(path: path, capacity: 128 << 10)
            ring.beginSession()
            var altScreen = false
            for _ in 0..<Int.random(in: 1...40, using: &random) {
                ring.append([UInt8](repeating: 0x61, count: Int.random(in: 1...20_000, using: &random)))
                var modes = TerminalModes()
                modes.bracketedPaste = Bool.random(using: &random)
                switch Int.random(in: 0..<4, using: &random) {
                case 0:  // clear on the current screen
                    modes.altScreen = altScreen
                    ring.recordResync(ResyncPoint(offset: ring.writeOffset, modes: modes))
                case 1:  // enter
                    altScreen = true
                    modes.altScreen = true
                    ring.recordResync(ResyncPoint(offset: ring.writeOffset, modes: modes))
                case 2 where altScreen:  // leave
                    altScreen = false
                    ring.recordResync(ResyncPoint(offset: ring.writeOffset, modes: modes, leavesAlternateScreen: true))
                default:
                    break
                }
            }
            // The ring file is still locked by `ring`: the reader never locks. The flag says no
            // more writes come (like a dead holder), so nothing is dropped as possibly overwritten.
            ring.markHolderExited()
            let snapshot = try RingFileReader.read(path: path, limit: 1 << 30)
            #expect(snapshot.start == ring.latestResync, "round \(round)")
            #expect(snapshot.modes == ring.latestResyncModes, "round \(round)")
            #expect(snapshot.end == ring.writeOffset)
            var expected: [UInt8] = []
            ring.copy(from: snapshot.start, count: Int(snapshot.end - snapshot.start), into: &expected)
            #expect(snapshot.bytes == expected)
        }
    }

    @Test("the main-screen point beyond the 2 MiB allowance is not used, as in the holder")
    func allowanceAsInTheHolder() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/ring"
        let ring = try RingBuffer(path: path, capacity: 8 << 20)
        ring.beginSession()
        ring.append([UInt8](repeating: 0x61, count: 100))
        ring.recordResync(ResyncPoint(offset: 100, modes: alternate))
        ring.append([UInt8](repeating: 0x62, count: Int(RingResync.mainScreenReplayAllowance)))
        #expect(try RingFileReader.read(path: path).start == 0, "100 bytes on the main screen: within the allowance")
        ring.recordResync(ResyncPoint(offset: ring.writeOffset, modes: alternate))
        let snapshot = try RingFileReader.read(path: path)
        #expect(snapshot.start == ring.latestResync)
        #expect(snapshot.start == RingResync.mainScreenReplayAllowance + 100)
        #expect(snapshot.modes == alternate)
    }

    // MARK: - Limit

    @Test("limit: the newest point that fits, else the newest bytes with modes unknown")
    func limit() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/ring"
        let ring = try RingBuffer(path: path, capacity: 1 << 20)
        ring.beginSession()  // point 0
        ring.append([UInt8](repeating: 0x61, count: 1000))
        var bracketed = TerminalModes()
        bracketed.bracketedPaste = true
        ring.recordResync(ResyncPoint(offset: 1000, modes: bracketed))
        ring.append([UInt8](repeating: 0x62, count: 500))

        let whole = try RingFileReader.read(path: path)
        #expect(whole.start == 1000 && whole.modes == bracketed && whole.bytes.count == 500)
        let fits = try RingFileReader.read(path: path, limit: 500)
        #expect(fits.start == 1000 && fits.modes == bracketed)
        let tight = try RingFileReader.read(path: path, limit: 499)
        #expect(tight.start == 1001 && tight.modes == nil && tight.bytes == [UInt8](repeating: 0x62, count: 499))
        let none = try RingFileReader.read(path: path, limit: 0)
        #expect(none.start == 1500 && none.end == 1500 && none.bytes.isEmpty && none.modes == nil)

        // On the alternate screen the chosen main-screen point (0) does not fit, the newer
        // alternate-screen point does.
        ring.recordResync(ResyncPoint(offset: 1500, modes: alternate))
        ring.append([UInt8](repeating: 0x63, count: 100))
        #expect(try RingFileReader.read(path: path).start == 1000)
        let alt = try RingFileReader.read(path: path, limit: 300)
        #expect(alt.start == 1500 && alt.modes == alternate && alt.bytes.count == 100)
    }

    // MARK: - Concurrent writer

    /// A clear about once per ring length (25,000 lines of 12 bytes, ring 256 KiB): the ring holds
    /// one resync point or none, so snapshots start near the oldest byte, where the holder is
    /// overwriting, and the writer rule has to move them (to the next point, or modes unknown).
    @Test("a live holder flooding while the ring is read: every snapshot is a slice of what a client saw")
    func concurrentFlood() throws {
        let floodBytes = 24 << 20
        let session = try TestSession([TestBinaries.helper, "flood", String(floodBytes), "25000"], ringSize: 256 << 10)
        let stream = try HolderStream(socketPath: session.socketPath, clientName: "ring-reader-tests")
        let recorder = StreamRecorder(stream, byteLimit: nil)
        defer { stream.close() }
        stream.start(takeover: false, attachFrom: .offset(0))
        #expect(recorder.wait { $0.text.contains("READY") })
        let path = session.sessionDirectory + "/ring"
        try stream.sendInput([0x67])

        var snapshots = 0
        var withModes = 0
        var nearOldest = 0
        var mismatches: [String] = []
        let deadline = Clock.monotonicNanoseconds() + 60_000_000_000
        while Clock.monotonicNanoseconds() < deadline {
            let snapshot = try RingFileReader.read(path: path)
            snapshots += 1
            if snapshot.bytes.count != Int(snapshot.end - snapshot.start) {
                mismatches.append("count \(snapshot.bytes.count) for [\(snapshot.start), \(snapshot.end))")
            }
            if snapshot.end > (256 << 10), snapshot.start < snapshot.end + UInt64(RingLayout.maxWriteChunk) - (256 << 10) {
                mismatches.append("start \(snapshot.start) inside the chunk a live writer may be overwriting (end \(snapshot.end))")
            }
            if snapshot.end > (256 << 10), snapshot.end - snapshot.start > (128 << 10) { nearOldest += 1 }
            #expect(recorder.wait(timeoutMilliseconds: 20_000) { $0.totalBytes >= Int(snapshot.end) })
            let matches = recorder.read { state -> Bool in
                guard Int(snapshot.end) <= state.bytes.count else { return false }
                return state.bytes[Int(snapshot.start)..<Int(snapshot.end)].elementsEqual(snapshot.bytes)
            }
            if !matches { mismatches.append("bytes differ in [\(snapshot.start), \(snapshot.end))") }
            if let modes = snapshot.modes {
                withModes += 1
                let isPoint = snapshot.start == 0 || recorder.read { state in
                    snapshot.start >= 4 && state.bytes[Int(snapshot.start - 4)..<Int(snapshot.start)].elementsEqual([0x1B, 0x5B, 0x32, 0x4A])
                }
                if !isPoint || modes != TerminalModes() { mismatches.append("start \(snapshot.start) is not a resync point") }
            }
            if recorder.read({ $0.tailContains("FLOOD-END") }) { break }
        }
        let state = recorder.snapshot
        #expect(state.gaps.isEmpty && state.discontinuities == 0, "the client saw every byte")
        #expect(state.tailContains("FLOOD-END"))
        #expect(mismatches.isEmpty, "\(mismatches.prefix(5))")
        #expect(snapshots >= 20)
        #expect(nearOldest > 0, "some snapshots started in the oldest half of the ring")
        print("MEASURE ring reads during a \(floodBytes >> 20) MiB flood: \(snapshots) snapshots, \(withModes) at a resync point, \(nearOldest) starting in the oldest half")
    }

    // MARK: - Measurement

    @Test("measure: reading a full 8 MiB ring")
    func measureFullRingRead() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/ring"
        let ring = try RingBuffer(path: path, capacity: 8 << 20)
        ring.beginSession()
        var random = SplitMix64(state: 5)
        let block = (0..<(1 << 20)).map { _ in UInt8.random(in: 0x20...0x7E, using: &random) }
        for _ in 0..<9 { ring.append(block) }
        // The newest point at the ring's oldest byte: the whole 8 MiB is replayed.
        ring.recordResync(ResyncPoint(offset: ring.oldestOffset, modes: TerminalModes()))
        ring.markHolderExited()
        var timings: [Double] = []
        var size = 0
        for _ in 0..<20 {
            let started = Clock.monotonicNanoseconds()
            let snapshot = try RingFileReader.read(path: path)
            timings.append(Double(Clock.monotonicNanoseconds() - started) / 1e6)
            size = snapshot.bytes.count
        }
        #expect(size == 8 << 20)
        var expected: [UInt8] = []
        ring.copy(from: ring.oldestOffset, count: 8 << 20, into: &expected)
        #expect(try RingFileReader.read(path: path).bytes == expected)
        timings.sort()
        let median = timings[timings.count / 2]
        print("MEASURE ring read: \(size) bytes, median \(String(format: "%.2f", median)) ms, max \(String(format: "%.2f", timings.last ?? 0)) ms (20 reads, page cache warm)")
        #expect(median < 200)
    }
}
