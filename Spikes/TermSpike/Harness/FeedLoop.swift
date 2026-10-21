import Foundation
import SwiftTerm
import Synchronization
import TermSpikeKit

/// Feeds a byte stream into an engine the way a PTY read loop would: fixed
/// chunks from one background thread, with backpressure on engines that queue
/// (Ghostty's session queue is unbounded otherwise), then waits until every
/// byte is parsed. Never called on the main thread.
enum FeedLoop {
    static let chunkBytes = 64 * 1024
    static let highWater = 8 * 1024 * 1024
    static let lowWater = 2 * 1024 * 1024

    /// Returns elapsed seconds from the first chunk to "fully parsed".
    static func run(stream: Data, byteCount: Int, feeder: EngineFeeder, control: ParseControl) -> Double {
        let count = min(byteCount, stream.count)
        let start = Monotonic.nanos()
        stream.withUnsafeBytes { raw in
            var offset = 0
            while offset < count {
                let end = min(offset + chunkBytes, count)
                feeder.feed(UnsafeRawBufferPointer(rebasing: raw[offset ..< end]))
                offset = end
                if control.pendingBytes() > highWater {
                    while control.pendingBytes() > lowWater {
                        usleep(200)
                    }
                }
            }
        }
        control.waitUntilParsed()
        return Double(Monotonic.nanos() - start) / 1_000_000_000
    }
}

/// Feeds a stream at a steady pace (like a program printing continuously)
/// rather than as fast as possible, so the renderer always has damage to draw.
/// Never called on the main thread.
enum PacedFeed {
    /// Returns the number of bytes fed.
    static func run(
        stream: Data, from start: Int, feeder: EngineFeeder,
        chunkBytes: Int, intervalMicros: UInt32, seconds: Double
    ) -> Int {
        let deadline = Monotonic.nanos() + UInt64(seconds * 1_000_000_000)
        var offset = min(max(0, start), stream.count)
        var fed = 0
        stream.withUnsafeBytes { raw in
            while Monotonic.nanos() < deadline, raw.count > 0 {
                if offset >= raw.count { offset = 0 }
                let end = min(offset + chunkBytes, raw.count)
                feeder.feed(UnsafeRawBufferPointer(rebasing: raw[offset ..< end]))
                fed += end - offset
                offset = end
                usleep(intervalMicros)
            }
        }
        return fed
    }
}

/// SwiftTerm's `Terminal` with no view: parser and buffer only.
enum HeadlessSwiftTerm {
    static func measure(stream: Data, byteCount: Int, columns: Int, rows: Int) -> Double {
        var options = TerminalOptions.default
        options.cols = columns
        options.rows = rows
        options.scrollback = 10_000
        let delegate = NullTerminalDelegate()
        let terminal = Terminal(delegate: delegate, options: options)
        let count = min(byteCount, stream.count)
        let start = Monotonic.nanos()
        stream.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset < count {
                let end = min(offset + FeedLoop.chunkBytes, count)
                let chunk = Array(bytes[offset ..< end])
                terminal.terminalLock.withLock {
                    terminal.feed(buffer: chunk[...])
                }
                offset = end
            }
        }
        let elapsed = Double(Monotonic.nanos() - start) / 1_000_000_000
        withExtendedLifetime(delegate) {}
        return elapsed
    }
}

/// Discards everything a headless terminal reports.
private final class NullTerminalDelegate: TerminalDelegate {
    func send(source _: Terminal, data _: ArraySlice<UInt8>) {}
}

/// Pairs synthetic keyDowns with the next PTY output (the tty echo) to time
/// keyDown → echo read → engine feed.
final class EchoTimer: Sendable {
    private let pending = Mutex<UInt64?>(nil)
    let recorder = LatencyRecorder()

    func keyDown() {
        pending.withLock { $0 = Monotonic.nanos() }
    }

    func outputArrived() {
        let now = Monotonic.nanos()
        if let start = pending.withLock({ value -> UInt64? in
            defer { value = nil }
            return value
        }) {
            recorder.record(Monotonic.millis(from: start, to: now))
        }
    }
}
