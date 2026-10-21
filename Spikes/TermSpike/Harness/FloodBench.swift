import AppKit
import Synchronization
import TermSpikeKit

/// `ptyFlood`: `/bin/cat` prints the stream file `floodCopies` times through a
/// real PTY into the engine, with the same flow control as the interactive
/// app (`PTYSession`). This is the budget's "256 MB `cat` at >= 150 MB/s;
/// input latency during the flood < 50 ms", including the kernel PTY (which
/// hands out at most 1 KiB per read on macOS).
///
/// Input latency is measured as Ctrl+C during the flood: `^C` written to the
/// PTY → the child's exit seen and everything read so far parsed, i.e. the
/// screen stops changing. (A typed character's echo cannot be timed: the
/// macOS tty drops echoes while its output queue is full, which it always
/// is during a flood.)
extension BenchWorker {
    nonisolated static let interruptRounds = 5

    func ptyFlood() async throws -> PTYFloodResult {
        let kind = try engineKind()
        let stream = try loadStream()
        let copies = max(1, spec.floodCopies)
        let harness = HarnessWindow(size: Self.windowSize, title: "TermSpike bench · \(spec.label)")
        await Wait.sleep(.milliseconds(300))
        var onScreen = harness.isVisibleOnScreen
        let host = EngineFactory.make(kind)
        attach(host, to: harness, visible: spec.visible)
        guard await Wait.until(timeout: .seconds(5), { host.isReady }) else {
            throw WorkerError.notReady(kind.label)
        }
        let feeder = host.feeder
        let control = host.parseControl
        // Warm-up outside the timed region: font atlas, first frames.
        _ = await Wait.offMain {
            FeedLoop.run(stream: stream, byteCount: 1 << 20, feeder: feeder, control: control)
        }

        // 1. Throughput: the whole flood, nothing typed.
        let sampler = FootprintSampler(extra: control.pendingBytes)
        sampler.start()
        let start = Monotonic.nanos()
        let flood = try FloodChild(host: host, filePath: spec.streamPath, copies: copies)
        guard await Wait.until(timeout: .seconds(180), every: .milliseconds(10), { flood.counters.exited }) else {
            flood.process.terminate(grace: 0.5)
            throw WorkerError.badSpec("flood did not finish within 180 s")
        }
        await Wait.offMain { control.waitUntilParsed() }
        let seconds = Double(Monotonic.nanos() - start) / 1_000_000_000
        let peak = sampler.stop()
        let delivered = flood.counters.delivered
        let pauses = flood.counters.pauses

        // 2. Ctrl+C in the middle of a flood, a few times.
        let interrupts = LatencyRecorder()
        var timeouts = 0
        for _ in 0 ..< Self.interruptRounds {
            let child = try FloodChild(host: host, filePath: spec.streamPath, copies: max(copies, 4))
            await Wait.sleep(.milliseconds(400))
            guard !child.counters.exited else { continue }
            let sent = Monotonic.nanos()
            child.process.write(Data([0x03]))
            if await Wait.until(timeout: .seconds(5), every: .milliseconds(1), { child.counters.exited }) {
                await Wait.offMain { control.waitUntilParsed() }
                interrupts.record(Monotonic.millis(from: sent, to: Monotonic.nanos()))
            } else {
                timeouts += 1
                child.process.terminate(grace: 0.2)
                _ = await Wait.until(timeout: .seconds(3)) { child.counters.exited }
            }
        }
        onScreen = onScreen && harness.isVisibleOnScreen

        host.setBacklogHandler(highWater: PTYSession.backlogHighWater, lowWater: PTYSession.backlogLowWater, nil)
        let grid = host.io.currentSize?.description ?? "?"
        let renderer: String = if let swiftTerm = host as? SwiftTermHost {
            spec.visible ? (swiftTerm.usesMetal ? "Metal" : "CoreGraphics") : "not in a window"
        } else {
            spec.visible ? "Metal" : "Metal, surface occluded"
        }
        host.tearDown()
        harness.close()

        let fileBytes = stream.count * copies
        return PTYFloodResult(
            grid: grid,
            fileBytes: fileBytes,
            deliveredBytes: delivered,
            seconds: seconds,
            mibPerSecond: Double(fileBytes) / 1_048_576 / seconds,
            visibleOnScreen: onScreen && spec.visible,
            renderer: renderer,
            flowControl: Self.flowControlLabel(kind),
            pauses: pauses,
            maxQueuedMiB: Double(sampler.extraPeak) / 1_048_576,
            peakFootprintMiB: Double(peak) / 1_048_576,
            interruptLatency: interrupts.summary(),
            interruptTimeouts: timeouts
        )
    }
}

extension BenchWorker {
    nonisolated static func flowControlLabel(_ kind: EngineKind) -> String {
        guard kind == .ghostty else { return "none needed: parses on the PTY read queue" }
        guard let marks = PTYSession.backlogMarks else { return "**off** (SPIKE_BACKLOG_KIB=0)" }
        return "PTY reads pause above \(marks.high >> 10) KiB queued, resume at \(marks.low >> 10) KiB"
    }
}

/// One `cat` flood wired to `host` the way `PTYSession` wires a session:
/// output fed on the PTY queue, replies written back, reads paused while the
/// engine's backlog is above the high-water mark.
@MainActor
private struct FloodChild {
    let process: PTYProcess
    let counters = FloodCounters()

    init(host: any TerminalEngineHost, filePath: String, copies: Int) throws {
        let (term, extra) = host.childTerminal()
        let feeder = host.feeder
        let counters = counters
        let process = try PTYProcess(
            spec: PTYLaunchSpec(
                executable: "/bin/cat",
                arguments: ["cat"] + Array(repeating: filePath, count: copies),
                environment: ChildEnvironment.build(
                    parent: ProcessInfo.processInfo.environment, term: term, termProgram: nil, extra: extra
                ),
                workingDirectory: NSTemporaryDirectory(),
                size: host.io.currentSize ?? .fallback
            ),
            label: "flood",
            onOutput: { buffer in
                counters.addDelivered(buffer.count)
                feeder.feed(buffer)
            },
            onExit: { _ in counters.markExited() }
        )
        host.io.setOutput { data in process.write(data) }
        host.io.setResize { size in process.resize(size) }
        host.setBacklogHandler(highWater: PTYSession.backlogHighWater, lowWater: PTYSession.backlogLowWater) { backlogged in
            if backlogged {
                counters.addPause()
                process.pauseReading()
            } else {
                process.resumeReading()
            }
        }
        self.process = process
    }
}

private final class FloodCounters: Sendable {
    private let deliveredBytes = Atomic<Int>(0)
    private let pauseCount = Atomic<Int>(0)
    private let exitSeen = Atomic<Bool>(false)

    var delivered: Int { deliveredBytes.load(ordering: .relaxed) }
    var pauses: Int { pauseCount.load(ordering: .relaxed) }
    var exited: Bool { exitSeen.load(ordering: .acquiring) }

    func addDelivered(_ count: Int) { deliveredBytes.add(count, ordering: .relaxed) }
    func addPause() { pauseCount.add(1, ordering: .relaxed) }
    func markExited() { exitSeen.store(true, ordering: .releasing) }
}
