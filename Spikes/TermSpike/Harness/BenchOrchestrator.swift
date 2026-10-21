import Foundation
import TermSpikeKit

/// `--bench`: runs every measurement in its own worker process (so engines
/// never share caches, threads or allocator state), prints a table and writes
/// `results/bench.json` + `RESULTS.md`.
enum BenchOrchestrator {
    static let streamSeed: UInt64 = 0xC0DD_2026
    /// Bump when AnsiStreamGenerator's output changes, so cached files are not reused.
    static let generatorVersion = 2
    static let workerTimeout: TimeInterval = 240

    static func run(_ options: BenchOptions) -> Int32 {
        print("TermSpike --bench\(options.quick ? " --quick" : "") (\(BuildInfo.configuration) build)")
        if BuildInfo.configuration == "Debug" {
            print("WARNING: Debug build. SwiftTerm and the Swift wrappers run unoptimized; use the Release build for real numbers.")
        }
        let streamBytes = options.quick ? 8 << 20 : 64 << 20
        let streamURL: URL
        let titleHeavyURL: URL
        do {
            streamURL = try ensureStream(bytes: streamBytes, titlePerMille: 1)
            titleHeavyURL = try ensureStream(bytes: streamBytes, titlePerMille: 100)
        } catch {
            print("could not prepare the stream file: \(error)")
            return 1
        }

        let machineAtStart = MachineInfo.current()
        print("load average: \(machineAtStart.loadAverage ?? "?")")
        var results: [WorkerResult] = []
        let all = specs(
            quick: options.quick, streamPath: streamURL.path, titleHeavyPath: titleHeavyURL.path, streamBytes: streamBytes
        )
        for spec in all {
            print("… \(spec.label)", terminator: "")
            fflush(stdout)
            let started = Date()
            let result = runWorker(spec)
            let note = (result.error.map { "  ERROR \($0)" } ?? "")
                + (result.warnings ?? []).map { "  WARNING \($0)" }.joined()
            print(String(format: "  (%.1f s)%@", Date().timeIntervalSince(started), note))
            results.append(result)
        }

        let report = BenchReport(
            generatedAt: Timestamp.now(),
            build: BuildInfo.configuration,
            machine: machineAtStart,
            quick: options.quick,
            results: results
        )
        print("")
        print(BenchTable.render(report))
        do {
            try ResultsStore.write(report, name: "bench.json", in: options.outputDirectory)
            let markdown = try ResultsStore.regenerateMarkdown(in: options.outputDirectory)
            print("wrote \(ResultsStore.resultsURL(name: "bench.json", in: options.outputDirectory).path)")
            print("wrote \(markdown.path)")
        } catch {
            print("could not write results: \(error)")
            return 1
        }
        return results.contains { $0.error != nil } ? 2 : 0
    }

    static func specs(quick: Bool, streamPath: String, titleHeavyPath: String, streamBytes: Int) -> [WorkerSpec] {
        let runs = quick ? 1 : 3
        // Ghostty throughput runs without cursor blink so a hidden surface
        // renders nothing at all (see the memory section for why that matters).
        let steadyCursor = ["SPIKE_GHOSTTY_CONFIG": "cursor-style-blink=false"]
        var specs: [WorkerSpec] = []
        for (engine, visible) in [("ghostty", true), ("ghostty", false), ("swiftterm", true), ("swiftterm", false), ("swiftterm-headless", false)] {
            specs.append(WorkerSpec(
                kind: .throughput, engine: engine, visible: visible,
                streamPath: streamPath, streamBytes: streamBytes, runs: runs,
                environment: engine == "ghostty" ? steadyCursor : [:]
            ))
        }
        // SwiftTerm can also draw with CoreGraphics: does it avoid the Metal
        // working set that both Metal renderers pull in while drawing?
        let coreGraphics = ["SPIKE_SWIFTTERM_METAL": "0"]
        specs.append(WorkerSpec(
            kind: .throughput, engine: "swiftterm", visible: true,
            streamPath: streamPath, streamBytes: streamBytes, runs: runs, environment: coreGraphics
        ))
        // Stress case: titles hop to the main thread in both engines (Ghostty
        // through its 64-slot app mailbox, SwiftTerm through onMain).
        for (engine, visible) in [("ghostty", true), ("ghostty", false), ("swiftterm", true), ("swiftterm", false)] {
            specs.append(WorkerSpec(
                kind: .throughput, engine: engine, visible: visible,
                streamPath: titleHeavyPath, streamBytes: streamBytes, streamVariant: "title-heavy", runs: runs,
                environment: engine == "ghostty" ? steadyCursor : [:]
            ))
        }
        // Ghostty keeps ~225 MB of Metal working memory resident while any
        // surface renders; a blinking cursor alone redraws every 600 ms. Measure
        // the default (blink on) once and the idle-friendly setting at every N.
        let history = quick ? 512 << 10 : 2 << 20
        specs.append(WorkerSpec(
            kind: .memory, engine: "ghostty", instances: 1, streamPath: streamPath, streamBytes: streamBytes,
            historyBytes: history, environment: ["SPIKE_GHOSTTY_CONFIG": "cursor-style-blink=true"]
        ))
        for engine in ["ghostty", "swiftterm"] {
            for instances in quick ? [1, 6] : [1, 6, 15] {
                specs.append(WorkerSpec(
                    kind: .memory, engine: engine, instances: instances,
                    streamPath: streamPath, streamBytes: streamBytes, historyBytes: history,
                    environment: engine == "ghostty" ? ["SPIKE_GHOSTTY_CONFIG": "cursor-style-blink=false"] : [:]
                ))
            }
        }
        specs.append(WorkerSpec(
            kind: .memory, engine: "swiftterm", instances: quick ? 6 : 15,
            streamPath: streamPath, streamBytes: streamBytes, historyBytes: history, environment: coreGraphics
        ))
        // A real PTY flood: `cat` of the stream file, 4 copies = 256 MiB (the
        // budget's 256 MB cat), with a keystroke echo timed every 25 ms.
        for (engine, visible) in [("ghostty", false), ("ghostty", true), ("swiftterm", false), ("swiftterm", true)] {
            specs.append(WorkerSpec(
                kind: .ptyFlood, engine: engine, visible: visible, streamPath: streamPath, streamBytes: streamBytes,
                environment: engine == "ghostty" ? steadyCursor : [:], floodCopies: quick ? 1 : 4
            ))
        }
        // Interleaved rounds: latency is sensitive to whatever else the Mac is doing.
        for round in 1 ... (quick ? 1 : 3) {
            for engine in ["ghostty", "swiftterm"] {
                specs.append(WorkerSpec(kind: .keyLatency, engine: engine, keyCount: quick ? 60 : 300, round: round))
            }
        }
        return specs
    }

    /// The generated stream is cached in the temp dir so every worker parses
    /// identical bytes without regenerating them.
    static func ensureStream(bytes: Int, titlePerMille: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermSpike-stream-v\(generatorVersion)-\(String(streamSeed, radix: 16))-t\(titlePerMille)-\(bytes).bin")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           (attributes[.size] as? Int) == bytes
        {
            return url
        }
        var generator = AnsiStreamGenerator(seed: streamSeed, titlePerMille: titlePerMille)
        let data = Data(generator.generate(byteCount: bytes))
        try data.write(to: url, options: .atomic)
        return url
    }

    static func runWorker(_ spec: WorkerSpec) -> WorkerResult {
        var failed = WorkerResult(spec: spec, build: BuildInfo.configuration)
        guard let json = try? JSONEncoder().encode(spec),
              let executable = Bundle.main.executableURL
        else {
            failed.error = "could not encode the worker spec"
            return failed
        }
        let process = Process()
        process.executableURL = executable
        process.environment = ProcessInfo.processInfo.environment.merging(spec.environment) { _, new in new }
        process.arguments = ["--bench-worker", String(decoding: json, as: UTF8.self)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            failed.error = "could not start worker: \(error)"
            return failed
        }
        let timeout = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + workerTimeout, execute: timeout)
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()

        let text = String(decoding: output, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(WorkerOutput.prefix) }),
              let result = try? JSONDecoder().decode(
                  WorkerResult.self, from: Data(line.dropFirst(WorkerOutput.prefix.count).utf8)
              )
        else {
            failed.error = "worker exited \(process.terminationStatus) without a result"
            return failed
        }
        return result
    }
}
