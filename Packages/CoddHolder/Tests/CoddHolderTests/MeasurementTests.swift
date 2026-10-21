import CoddHolderClient
import CoddPosix
import CoddProtocol
import Darwin
import Foundation
import Testing

/// Prints `MEASURE …` lines (idle memory, socket throughput, input latency). Assertions are loose
/// regression guards; the numbers in the report come from a release build
/// (`CODD_HOLDER_PRODUCTS=<release dir> swift test --filter Measurements`).
@Suite("Measurements", .serialized, .timeLimit(.minutes(3)))
struct MeasurementTests {
    @Test("idle holder memory")
    func idleMemory() throws {
        let session = try TestSession(["/bin/sh"])
        Clock.sleep(milliseconds: 1000)
        let rss = try runCommand("/bin/ps", ["-o", "rss=", "-p", String(session.pid)]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let footprintOutput = (try? runCommand("/usr/bin/footprint", [String(session.pid)]).output) ?? ""
        let footprint = footprintOutput.components(separatedBy: "Footprint: ").dropFirst().first?
            .components(separatedBy: " (").first ?? "?"
        print("MEASURE idle holder: rss=\(rss) KB footprint=\(footprint) binary=\(TestBinaries.holder)")
        #expect(Int(rss).map { $0 < 32 * 1024 } ?? false)
        // docs/ARCHITECTURE.md budget: holder <= 2.5 MB (phys_footprint, which excludes shared libraries
        // and the file-backed ring). Linking Foundation alone would add ~0.45 MB.
        // RSS also counts touched shared-cache pages and, once output arrived, the resident ring pages
        // (an 8 MiB ring filled by a flood measured rss 10.6 MB at an unchanged 1.5 MB footprint).
        let kilobytes = footprintKilobytes(footprint)
        #expect(kilobytes != nil, "footprint(1) output not understood: \(footprintOutput.prefix(200))")
        if let kilobytes {
            #expect(kilobytes <= 2560, "idle footprint \(footprint) exceeds the 2.5 MB budget")
        }
    }

    /// "1648 KB" / "2.1 MB" → kilobytes.
    private func footprintKilobytes(_ text: String) -> Double? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        switch parts[1] {
        case "KB": return value
        case "MB": return value * 1024
        default: return nil
        }
    }

    @Test("throughput: ring replay and live PTY flood through the socket")
    func throughput() throws {
        // Replay: a 64 MiB ring filled up front, then streamed as fast as the client reads.
        let ringSize = 64 << 20
        let filler = try TestSession(["/bin/sh", "-c", "head -c \(ringSize + 100_000) /dev/zero; exec cat"], ringSize: ringSize)
        #expect(waitFor(timeoutMilliseconds: 20_000) { (ringWriteOffset(filler) ?? 0) >= UInt64(ringSize + 100_000) })
        let (replay, welcome) = try filler.attach(from: Message.latestResync)
        var replayed = StreamCapture(byteLimit: 1024)
        let replayStart = Clock.monotonicNanoseconds()
        let target = Int(welcome.ringEnd - welcome.resync)
        #expect(try replay.collect(into: &replayed, timeoutMilliseconds: 30_000) { $0.totalBytes >= target })
        let replaySeconds = Double(Clock.monotonicNanoseconds() - replayStart) / 1e9
        let replayRate = Double(target) / replaySeconds / 1e6
        print("MEASURE replay throughput: \(String(format: "%.0f", replayRate)) MB/s (\(target) bytes)")

        // Live: 100 MB through the PTY and the socket with the client attached.
        let total = 100_000_000
        let live = try TestSession(["/bin/sh", "-c", "sleep 0.3; head -c \(total) /dev/zero; printf END; exec cat"])
        let (connection, _) = try live.attach(from: 0)
        var capture = StreamCapture(byteLimit: 1024)
        #expect(try connection.collect(into: &capture, timeoutMilliseconds: 10_000) { $0.totalBytes > 0 })
        let start = Clock.monotonicNanoseconds()
        let startBytes = capture.totalBytes
        #expect(try connection.collect(into: &capture, timeoutMilliseconds: 120_000) { $0.tailContains("END") })
        let seconds = Double(Clock.monotonicNanoseconds() - start) / 1e9
        let rate = Double(capture.totalBytes - startBytes) / seconds / 1e6
        print("MEASURE live PTY->socket throughput: \(String(format: "%.0f", rate)) MB/s (\(capture.totalBytes) bytes, gaps \(capture.gaps.count))")
        #expect(capture.gaps.isEmpty)
    }

    /// The holder's threshold decides how much output is queued between the child and a terminal
    /// that cannot keep up: everything above it is still drawn after Ctrl+C stopped the child.
    @Test("Ctrl+C under a flood with a 50 MB/s consumer: 4 MiB vs 1 MiB threshold")
    func interruptLatency() throws {
        let rate = 50e6  // bytes per second: a busy, visible terminal
        var medians: [Int: Double] = [:]
        for limit in [4 << 20, 1 << 20] {
            var samples: [Double] = []
            for _ in 0..<5 {
                let session = try TestSession(["/bin/sh", "-c", "trap 'echo; echo AFTER-INT' INT; yes; exec cat"], flowControlLimit: limit)
                let (connection, _) = try session.attach(from: 0)
                var capture = StreamCapture(byteLimit: 4096)
                let start = Clock.monotonicNanoseconds()
                // Paced consumer: never more than `rate` bytes per second.
                func consume(until done: (StreamCapture) -> Bool, deadline: UInt64) throws -> Bool {
                    while Clock.monotonicNanoseconds() < deadline {
                        if done(capture) { return true }
                        guard let message = try connection.receive(timeoutMilliseconds: 100) else { continue }
                        capture.absorb(message)
                        let due = Double(capture.totalBytes) / rate
                        let elapsed = Double(Clock.monotonicNanoseconds() - start) / 1e9
                        if due > elapsed { usleep(useconds_t((due - elapsed) * 1e6)) }
                    }
                    return done(capture)
                }
                // 400 ms of flood: the backlog reaches the high-water mark.
                _ = try consume(until: { _ in false }, deadline: start + 400_000_000)
                let interrupted = Clock.monotonicNanoseconds()
                try connection.send(.input(flags: [], bytes: [0x03]))
                let stopped = try consume(until: { $0.tailContains("AFTER-INT") }, deadline: interrupted + 10_000_000_000)
                #expect(stopped)
                if stopped { samples.append(Double(Clock.monotonicNanoseconds() - interrupted) / 1e6) }
                #expect(capture.gaps.isEmpty, "a paced consumer is protected, not dropped")
            }
            let sorted = samples.sorted()
            medians[limit] = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            print("MEASURE Ctrl+C under flood, threshold \(limit >> 20) MiB, consumer 50 MB/s: "
                + "p50 \(String(format: "%.1f", medians[limit] ?? 0)) ms, max \(String(format: "%.1f", sorted.last ?? 0)) ms (n=\(sorted.count))")
        }
        if let old = medians[4 << 20], let new = medians[1 << 20] {
            #expect(new < old, "1 MiB (\(new) ms) must beat 4 MiB (\(old) ms)")
        }
    }

    @Test("INPUT → PTY latency")
    func inputLatency() throws {
        // One-way: client send time → child read time (both CLOCK_UPTIME_RAW).
        let session = try TestSession([TestBinaries.helper, "stamp"])
        let (connection, _) = try session.attach(from: 0)
        var capture = StreamCapture()
        #expect(try connection.collect(into: &capture) { $0.text.contains("READY") })
        var oneWay: [Double] = []
        for index in 0..<1000 {
            let byte = UInt8(ascii: "a") + UInt8(index % 26)
            capture = StreamCapture()
            let sent = Clock.monotonicNanoseconds()
            try connection.send(.input(flags: [], bytes: [byte]))
            guard try connection.collect(into: &capture, timeoutMilliseconds: 2000, until: { parseStamps($0.text).count == 1 }) else {
                Issue.record("no stamp for input \(index)")
                break
            }
            if let stamp = parseStamps(capture.text).first, stamp.nanoseconds >= sent {
                oneWay.append(Double(stamp.nanoseconds - sent) / 1000)
            }
        }
        // Round trip through the tty echo (INPUT → PTY → line discipline echo → OUTPUT).
        let echoSession = try TestSession(["/bin/cat"])
        let (echo, _) = try echoSession.attach(from: 0)
        var echoCapture = StreamCapture()
        try echo.roundTrip(token: 1, into: &echoCapture)
        var roundTrips: [Double] = []
        for index in 0..<1000 {
            let byte = UInt8(ascii: "a") + UInt8(index % 26)
            let before = echoCapture.totalBytes
            let sent = Clock.monotonicNanoseconds()
            try echo.send(.input(flags: [], bytes: [byte]))
            guard try echo.collect(into: &echoCapture, timeoutMilliseconds: 2000, until: { $0.totalBytes > before }) else { break }
            roundTrips.append(Double(Clock.monotonicNanoseconds() - sent) / 1000)
        }
        print("MEASURE INPUT->child read (one-way): \(percentiles(oneWay))")
        print("MEASURE INPUT->echo->OUTPUT (round trip): \(percentiles(roundTrips))")
        #expect(oneWay.count > 900)
    }
}

func percentiles(_ samples: [Double]) -> String {
    guard !samples.isEmpty else { return "no samples" }
    let sorted = samples.sorted()
    func at(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))] }
    return String(format: "p50 %.1f us, p99 %.1f us, max %.1f us (n=%d)", at(0.5), at(0.99), sorted.last ?? 0, sorted.count)
}
