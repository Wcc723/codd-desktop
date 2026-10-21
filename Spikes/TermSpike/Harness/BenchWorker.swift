import AppKit
import TermSpikeKit

/// One measurement in a fresh process (`--bench-worker`). Prints exactly one
/// `TERMSPIKE_RESULT {json}` line on stdout.
@MainActor
struct BenchWorker {
    let spec: WorkerSpec

    static let windowSize = NSSize(width: 1000, height: 640)

    func run() async -> Int32 {
        var result = WorkerResult(spec: spec, build: BuildInfo.configuration)
        do {
            switch spec.kind {
            case .throughput: result.throughput = try await throughput()
            case .memory: result.memory = try await memory()
            case .keyLatency: result.keyLatency = try await keyLatency()
            case .ptyFlood: result.ptyFlood = try await ptyFlood()
            }
        } catch {
            result.error = "\(error)"
        }
        result.warnings = Self.warnings(for: result)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = (try? encoder.encode(result)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        print(WorkerOutput.prefix + json)
        return result.error == nil ? 0 : 1
    }

    /// A "visible" measurement taken while the window was not on screen
    /// (display asleep, screen locked, window covered) did not render: AppKit
    /// pauses SwiftTerm's display link then, while Ghostty keeps drawing, so
    /// the two engines are no longer compared like for like.
    static func warnings(for result: WorkerResult) -> [String]? {
        var warnings: [String] = []
        let offScreen = "the window was not on screen (display asleep, locked or covered); rendering-dependent numbers (MiB/s, peak fp) are invalid"
        if let throughput = result.throughput, result.spec.visible, result.spec.engine != "swiftterm-headless",
           !throughput.visibleOnScreen
        {
            warnings.append("visible run, but \(offScreen)")
        }
        if let memory = result.memory, memory.visibleOnScreen == false {
            warnings.append("visible instance, but \(offScreen)")
        }
        if let flood = result.ptyFlood, result.spec.visible, !flood.visibleOnScreen {
            warnings.append("visible run, but \(offScreen)")
        }
        if let latency = result.keyLatency, !latency.inputSource.contains("keylayout") {
            warnings.append("input source \(latency.inputSource) is an input method; synthetic keys may be composed instead of written")
        }
        return warnings.isEmpty ? nil : warnings
    }

    func engineKind() throws -> EngineKind {
        guard let kind = EngineKind(rawValue: spec.engine) else {
            throw WorkerError.badSpec("unknown engine \(spec.engine)")
        }
        return kind
    }

    func loadStream() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: spec.streamPath), options: .alwaysMapped)
    }

    // MARK: - Throughput

    private func throughput() async throws -> ThroughputResult {
        let stream = try loadStream()
        let bytes = min(spec.streamBytes, stream.count)
        var seconds: [Double] = []
        var grid = "120×40"
        var renderer = "none (parser only)"
        var onScreen = false
        var peak: UInt64 = 0

        if spec.engine == "swiftterm-headless" {
            for _ in 0 ..< spec.runs {
                let sampler = FootprintSampler()
                sampler.start()
                let elapsed = await Wait.offMain {
                    HeadlessSwiftTerm.measure(stream: stream, byteCount: bytes, columns: 120, rows: 40)
                }
                peak = max(peak, sampler.stop())
                seconds.append(elapsed)
            }
        } else {
            let kind = try engineKind()
            let harness = HarnessWindow(size: Self.windowSize, title: "TermSpike bench · \(spec.label)")
            await Wait.sleep(.milliseconds(300))
            onScreen = harness.isVisibleOnScreen
            for _ in 0 ..< spec.runs {
                let host = EngineFactory.make(kind)
                attach(host, to: harness, visible: spec.visible)
                guard await Wait.until(timeout: .seconds(5), { host.isReady }) else {
                    throw WorkerError.notReady(kind.label)
                }
                // Warm-up outside the timed region: font atlas, first frames.
                let feeder = host.feeder
                let control = host.parseControl
                _ = await Wait.offMain {
                    FeedLoop.run(stream: stream, byteCount: 1 << 20, feeder: feeder, control: control)
                }
                // Diagnostic hook: SPIKE_SETTLE_SECONDS=N idles before the timed run,
                // so GPU memory from the first frames can be released first.
                if let settle = ProcessInfo.processInfo.environment["SPIKE_SETTLE_SECONDS"].flatMap(Double.init), settle > 0 {
                    await Wait.sleep(.milliseconds(Int(settle * 1000)))
                }
                let sampler = FootprintSampler()
                sampler.start()
                let elapsed = await Wait.offMain {
                    FeedLoop.run(stream: stream, byteCount: bytes, feeder: feeder, control: control)
                }
                peak = max(peak, sampler.stop())
                seconds.append(elapsed)
                grid = host.io.currentSize?.description ?? grid
                if let swiftTerm = host as? SwiftTermHost {
                    renderer = spec.visible ? (swiftTerm.usesMetal ? "Metal" : "CoreGraphics") : "not in a window"
                } else {
                    renderer = spec.visible ? "Metal" : "Metal, surface occluded"
                }
                host.tearDown()
                await Wait.sleep(.milliseconds(300))
            }
            onScreen = onScreen && harness.isVisibleOnScreen
            harness.close()
        }
        let median = seconds.sorted()[seconds.count / 2]
        return ThroughputResult(
            grid: grid,
            bytes: bytes,
            chunkBytes: FeedLoop.chunkBytes,
            seconds: seconds,
            medianSeconds: median,
            mibPerSecond: Double(bytes) / 1_048_576 / median,
            visibleOnScreen: onScreen && spec.visible,
            renderer: renderer,
            peakFootprintMiB: Double(peak) / 1_048_576
        )
    }

    /// Visible: in the on-screen window. Hidden: Ghostty stays in the window
    /// with its surface occluded (it needs a window to have a surface at all);
    /// SwiftTerm is kept out of any window (its frame driver stops there).
    ///
    /// Hidden Ghostty surfaces are occluded *before* they join the window, so
    /// the surface is born occluded and never renders a first frame (a single
    /// frame pulls in Ghostty's ~225 MB Metal working set for a few seconds).
    func attach(_ host: any TerminalEngineHost, to harness: HarnessWindow, visible: Bool) {
        if visible || host.kind == .ghostty {
            if !visible {
                host.setRenderingSuspended(true)
                host.view.isHidden = true
            }
            harness.host(host.view)
            host.viewDidChangeWindow()
        } else {
            host.view.frame = NSRect(origin: .zero, size: Self.windowSize)
            host.viewDidChangeWindow()
        }
    }

    // MARK: - Memory

    private func memory() async throws -> MemoryResult {
        let kind = try engineKind()
        let stream = try loadStream()
        let harness = HarnessWindow(size: Self.windowSize, title: "TermSpike bench · \(spec.label)")
        await Wait.sleep(.seconds(1))
        let baseline = ProcessMetrics.current()

        var hosts: [any TerminalEngineHost] = []
        var processes: [PTYProcess] = []
        // Diagnostic hook: SPIKE_ALL_HIDDEN=1 hides every instance (no renderer frames at all).
        let allHidden = ProcessInfo.processInfo.environment["SPIKE_ALL_HIDDEN"] == "1"
        for index in 0 ..< spec.instances {
            let host = EngineFactory.make(kind)
            attach(host, to: harness, visible: index == 0 && !allHidden)
            guard await Wait.until(timeout: .seconds(5), { host.isReady }) else {
                throw WorkerError.notReady(kind.label)
            }
            processes.append(try spawnIdleShell(for: host))
            let feeder = host.feeder
            let history = spec.historyBytes
            await Wait.offMain {
                stream.withUnsafeBytes { raw in
                    feeder.feed(UnsafeRawBufferPointer(rebasing: raw[0 ..< min(history, raw.count)]))
                }
            }
            hosts.append(host)
        }
        await Wait.sleep(.seconds(2))
        for host in hosts {
            let control = host.parseControl
            await Wait.offMain { control.waitUntilParsed() }
        }
        await Wait.sleep(.seconds(1))
        let loaded = ProcessMetrics.current()
        // Diagnostic hook: SPIKE_HOLD_SECONDS=N keeps the worker alive so
        // `footprint` / `vmmap -summary` can inspect it.
        if let hold = ProcessInfo.processInfo.environment["SPIKE_HOLD_SECONDS"].flatMap(Int.init), hold > 0 {
            FileHandle.standardError.write(Data("holding pid \(getpid()) for \(hold) s\n".utf8))
            await Wait.sleep(.seconds(hold))
        }

        // Idle CPU: nothing is fed. A blinking cursor or a frame driver that
        // never pauses shows up here (budget: < 0.5 % visible, < 0.1 % hidden).
        let idleCPU = await Self.cpuPercent(during: { await Wait.sleep(.seconds(3)) })

        // The visible instance streams for 3 s (16 KiB every 8 ms, so every
        // frame has damage) while the hidden ones sit idle: what the 300 MB
        // budget must absorb whenever a tab is streaming.
        var streamingPeak: UInt64 = 0
        var streamedBytes = 0
        var streamingCPU: Double?
        var visibleOnScreen: Bool?
        if let visible = hosts.first, !allHidden {
            visibleOnScreen = harness.isVisibleOnScreen
            let feeder = visible.feeder
            let sampler = FootprintSampler()
            sampler.start()
            let history = spec.historyBytes
            streamingCPU = await Self.cpuPercent(during: {
                streamedBytes = await Wait.offMain {
                    PacedFeed.run(
                        stream: stream, from: history, feeder: feeder,
                        chunkBytes: 16 << 10, intervalMicros: 8000, seconds: 3
                    )
                }
            })
            streamingPeak = sampler.stop()
            visibleOnScreen = (visibleOnScreen ?? false) && harness.isVisibleOnScreen
        }

        for process in processes { process.terminate(grace: 0.5) }
        await Wait.sleep(.milliseconds(300))
        hosts.forEach { $0.tearDown() }
        harness.close()

        let delta = Double(Int64(loaded.footprintBytes) - Int64(baseline.footprintBytes)) / 1_048_576
        return MemoryResult(
            instances: spec.instances,
            visibleInstances: 1,
            historyBytesPerInstance: spec.historyBytes,
            hiddenStrategy: kind == .ghostty
                ? "in window, view hidden + ghostty_surface_set_occlusion"
                : "view not in any window",
            baseline: baseline,
            loaded: loaded,
            deltaFootprintMiB: delta,
            deltaResidentMiB: Double(Int64(loaded.residentBytes) - Int64(baseline.residentBytes)) / 1_048_576,
            perInstanceFootprintMiB: delta / Double(max(1, spec.instances)),
            idleCPUPercent: idleCPU,
            streamingPeakFootprintMiB: streamingPeak > 0 ? Double(streamingPeak) / 1_048_576 : nil,
            streamingCPUPercent: streamingCPU,
            streamedBytes: streamedBytes > 0 ? streamedBytes : nil,
            visibleOnScreen: visibleOnScreen
        )
    }

    /// CPU used by this process while `work` runs, as % of one core.
    private static func cpuPercent(during work: () async -> Void) async -> Double {
        let cpuStart = ProcessMetrics.cpuSeconds()
        let wallStart = Monotonic.nanos()
        await work()
        return ProcessMetrics.cpuPercent(
            cpuSeconds: ProcessMetrics.cpuSeconds() - cpuStart,
            wallNanos: Monotonic.nanos() - wallStart
        )
    }

    /// A live, idle child (`zsh -f`: no rc files, never touches Claude).
    private func spawnIdleShell(for host: any TerminalEngineHost) throws -> PTYProcess {
        let (term, extra) = host.childTerminal()
        let environment = ChildEnvironment.build(
            parent: ProcessInfo.processInfo.environment, term: term, termProgram: nil, extra: extra
        )
        let feeder = host.feeder
        let process = try PTYProcess(
            spec: PTYLaunchSpec(
                executable: "/bin/zsh",
                arguments: ["zsh", "-f"],
                environment: environment,
                workingDirectory: NSTemporaryDirectory(),
                size: host.io.currentSize ?? .fallback
            ),
            label: "bench",
            onOutput: { buffer in feeder.feed(buffer) },
            onExit: { _ in }
        )
        host.io.setOutput { data in process.write(data) }
        host.io.setResize { size in process.resize(size) }
        return process
    }

    // MARK: - Key latency

    private func keyLatency() async throws -> KeyLatencyResult {
        let kind = try engineKind()
        let harness = HarnessWindow(size: Self.windowSize, title: "TermSpike bench · \(spec.label)")
        let host = EngineFactory.make(kind)
        harness.host(host.view)
        host.viewDidChangeWindow()
        harness.makeKey(host.view)
        guard await Wait.until(timeout: .seconds(5), { host.isReady }) else {
            throw WorkerError.notReady(kind.label)
        }

        let tracker = KeyLatencyTracker()
        // Same keys, ended when the engine hands its encoding to the host
        // (Ghostty: its IO thread; SwiftTerm: the main actor), to split the
        // engine's own share from the host's hop to write(2).
        let emitted = KeyLatencyTracker(emitsSignposts: false)
        let echo = EchoTimer()
        let (term, extra) = host.childTerminal()
        let feeder = host.feeder
        let process = try PTYProcess(
            spec: PTYLaunchSpec(
                executable: "/bin/cat",
                arguments: ["cat"],
                environment: ChildEnvironment.build(
                    parent: ProcessInfo.processInfo.environment, term: term, termProgram: nil, extra: extra
                ),
                workingDirectory: NSTemporaryDirectory(),
                size: host.io.currentSize ?? .fallback
            ),
            label: "keylat",
            onOutput: { buffer in
                echo.outputArrived()
                feeder.feed(buffer)
            },
            onWrite: { _ in tracker.ptyWritten() },
            onExit: { _ in }
        )
        host.io.setOutput { data in
            emitted.ptyWritten()
            process.write(data)
        }
        host.io.setResize { size in process.resize(size) }
        await Wait.sleep(.milliseconds(500))

        // An input method would compose the letters instead of writing them;
        // measure under an ASCII layout and put the user's source back after.
        let originalSource = InputSources.currentIdentifier()
        if let ascii = InputSources.asciiLayout() {
            _ = await InputSources.select(ascii)
            harness.makeKey(host.view)
        }
        let key = SyntheticKey.letterA
        for index in 0 ..< spec.keyCount {
            guard let down = key.event(.keyDown, in: harness.window),
                  let up = key.event(.keyUp, in: harness.window) else { continue }
            tracker.keyDown(eventTimestamp: down.timestamp)
            emitted.keyDown(eventTimestamp: down.timestamp)
            echo.keyDown()
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
            await Wait.sleep(.milliseconds(12))
            if index % 100 == 99 {
                // Keep cat's canonical line well below MAX_CANON (1024).
                // No keyDown is pending here, so this write and its echo pair with nothing.
                process.write(Data([0x15])) // ^U kills the line
                await Wait.sleep(.milliseconds(20))
            }
        }
        await Wait.sleep(.milliseconds(300))
        let inputSource = InputSources.currentIdentifier()
        await InputSources.restore(originalSource)
        process.terminate(grace: 0.5)
        host.tearDown()
        harness.close()
        return KeyLatencyResult(
            keys: spec.keyCount,
            delivery: "NSApp.sendEvent (synthetic NSEvent, app \(NSApp.isActive ? "active" : "inactive"))",
            inputSource: inputSource,
            keyToWrite: tracker.hostPath.summary(),
            keyToEmit: emitted.hostPath.summary(),
            keyToEcho: echo.recorder.summary(),
            unmatched: tracker.unmatchedCount
        )
    }
}

/// Samples phys_footprint on the main actor every 25 ms while a timed run
/// executes on a background thread, plus an optional second gauge (e.g. an
/// engine's queued bytes).
@MainActor
final class FootprintSampler {
    private var peak: UInt64 = 0
    private(set) var extraPeak = 0
    private var task: Task<Void, Never>?
    private let extra: (@Sendable () -> Int)?

    init(extra: (@Sendable () -> Int)? = nil) {
        self.extra = extra
    }

    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let sample = ProcessMetrics.current().footprintBytes
                if let self {
                    self.peak = max(self.peak, sample)
                    if let extra = self.extra { self.extraPeak = max(self.extraPeak, extra()) }
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
    }

    /// Stops sampling and returns the peak in bytes.
    func stop() -> UInt64 {
        task?.cancel()
        task = nil
        return max(peak, ProcessMetrics.current().footprintBytes)
    }
}

enum WorkerError: Error, CustomStringConvertible {
    case badSpec(String)
    case notReady(String)

    var description: String {
        switch self {
        case let .badSpec(reason): "bad spec: \(reason)"
        case let .notReady(engine): "\(engine) did not become ready within 5 s"
        }
    }
}
