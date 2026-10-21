import AppKit
import Foundation
import Synchronization
import Testing
@testable import CoddTerminal

/// keyDown → onWrite latency through the real path (interpretKeyEvents, `ghostty_surface_key`,
/// libghostty's IO thread, the engine's write sink). A measurement, not a pass/fail gate: run with
/// `CODD_TERMINAL_MEASURE=1 swift test … --filter KeyLatency` (add `-c release` for release
/// numbers). The only assertion is a loose sanity bound.
@Suite(
    "KeyLatency",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["CODD_TERMINAL_MEASURE"] != nil)
)
@MainActor
struct KeyLatencyMeasurement {
    @Test func keyDownToOnWrite() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        harness.window.makeFirstResponder(harness.engine.view)
        #expect(await eventually { harness.engine.gridSize != nil })
        let stamps = Mutex<[UInt64]>([])
        harness.engine.onWrite = { _ in
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            stamps.withLock { $0.append(now) }
        }
        let keys: [(String, UInt16)] = [("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03)]
        var samples: [Double] = []
        for index in 0 ..< 400 {
            let (characters, keyCode) = keys[index % keys.count]
            let event = harness.keyDown(characters, keyCode: keyCode)
            let before = stamps.withLock { $0.count }
            let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            harness.engine.view.keyDown(with: event)
            guard await eventually(timeout: .seconds(1), { stamps.withLock { $0.count } > before }) else {
                Issue.record("key \(index) never reached onWrite")
                return
            }
            let end = stamps.withLock { $0[before] }
            samples.append(Double(end &- start) / 1_000_000)
            try? await Task.sleep(for: .milliseconds(2))
        }
        let warm = Array(samples.dropFirst(20)).sorted()
        func percentile(_ fraction: Double) -> Double {
            warm[min(warm.count - 1, Int(Double(warm.count) * fraction))]
        }
        let line = String(
            format: "KEYLATENCY keyDown→onWrite n=%d p50=%.3f ms p90=%.3f ms p99=%.3f ms max=%.3f ms",
            warm.count, percentile(0.5), percentile(0.9), percentile(0.99), warm.last ?? 0
        )
        print(line)
        #expect(percentile(0.5) < 50)
    }

    /// Parse throughput of `feed` (no PTY): colored log lines in 64 KiB chunks, as a holder stream
    /// delivers them, then `replay` of the same bytes.
    @Test func feedAndReplayThroughput() async {
        let harness = SurfaceHarness()
        defer { harness.tearDown() }
        #expect(await eventually { harness.engine.gridSize != nil })
        var line = 0
        var stream: [UInt8] = []
        while stream.count < 32 << 20 {
            line += 1
            stream += Array("\u{1B}[32m\(line)\u{1B}[0m src/session/terminal.swift:\(line % 997) \u{1B}[1mwarning\u{1B}[0m: 修正登入 API 401 — value \(line * 7919)\r\n".utf8)
        }
        let chunks = stride(from: 0, to: stream.count, by: 64 << 10).map {
            Array(stream[$0 ..< min($0 + (64 << 10), stream.count)])
        }
        for mode in ["feed", "replay"] {
            let start = ContinuousClock.now
            for chunk in chunks {
                if mode == "feed" { harness.engine.feed(chunk) } else { harness.engine.replay(chunk) }
            }
            harness.engine.waitUntilParsed()
            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            print(String(format: "THROUGHPUT %@ %.1f MiB in %.3f s = %.1f MiB/s",
                         mode, Double(stream.count) / 1_048_576, seconds, Double(stream.count) / 1_048_576 / seconds))
            // The last line must be on screen, or nothing was measured.
            #expect(harness.viewportLines.last?.hasPrefix("\(line) src/session/terminal.swift") == true,
                    "\(harness.viewportLines.last.debugDescription)")
            harness.engine.reset()
        }
    }
}
