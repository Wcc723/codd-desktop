import Foundation

/// How the binary was asked to run.
///
/// - (no flag): interactive comparison window. Optional: `--layout ghostty|swiftterm|sbs`,
///   `--command "zsh -l"`, `--autostart` (press START), `--pattern` (feed the render test pattern).
/// - `--probe [--out DIR]`: answer Claude's startup probes and key encodings in
///   both engines, print a report, write `results/probe.json` and `RESULTS.md`.
/// - `--bench [--quick] [--out DIR]`: spawn one worker process per measurement
///   (throughput, memory, key latency), print a table, write `results/bench.json`
///   and `RESULTS.md`.
/// - `--report [--out DIR]`: rebuild `RESULTS.md` from the existing `results/*.json`.
/// - `--bench-worker JSON`: internal; one measurement, result on stdout.
struct InteractiveOptions {
    var layout = 0
    var command = "zsh -l"
    var autostart = false
    var pattern = false
    /// Print each visible engine's screen text after this many seconds, then quit.
    var dumpAfter: Double?
}

enum LaunchMode {
    case interactive(InteractiveOptions)
    case probe(outputDirectory: URL)
    case bench(BenchOptions)
    case report(outputDirectory: URL)
    case benchWorker(WorkerSpec)
    case invalid(String)

    static func parse(_ arguments: [String]) -> LaunchMode {
        let args = Array(arguments.dropFirst())
        let outputDirectory = ResultsLocation.directory(override: value(after: "--out", in: args))
        if args.contains("--probe") {
            return .probe(outputDirectory: outputDirectory)
        }
        if args.contains("--report") {
            return .report(outputDirectory: outputDirectory)
        }
        if args.contains("--bench") {
            return .bench(BenchOptions(quick: args.contains("--quick"), outputDirectory: outputDirectory))
        }
        if let json = value(after: "--bench-worker", in: args) {
            do {
                return .benchWorker(try JSONDecoder().decode(WorkerSpec.self, from: Data(json.utf8)))
            } catch {
                return .invalid("bad --bench-worker spec: \(error)")
            }
        }
        var options = InteractiveOptions()
        switch value(after: "--layout", in: args) {
        case "swiftterm": options.layout = 1
        case "sbs", "side-by-side": options.layout = 2
        default: options.layout = 0
        }
        if let command = value(after: "--command", in: args) { options.command = command }
        options.autostart = args.contains("--autostart")
        options.pattern = args.contains("--pattern")
        options.dumpAfter = value(after: "--dump-after", in: args).flatMap(Double.init)
        return .interactive(options)
    }

    private static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}

/// Where results are written: `--out`, else the source folder baked into
/// Info.plist at build time (`Spikes/TermSpike`), else the current directory.
enum ResultsLocation {
    static func directory(override: String?) -> URL {
        if let override, !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let baked = Bundle.main.object(forInfoDictionaryKey: "TermSpikeResultsDir") as? String,
           !baked.isEmpty, !baked.contains("$(")
        {
            return URL(fileURLWithPath: baked, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    static func resultsFolder(in directory: URL) -> URL {
        directory.appendingPathComponent("results", isDirectory: true)
    }
}

enum BuildInfo {
    #if DEBUG
        static let configuration = "Debug"
    #else
        static let configuration = "Release"
    #endif

    /// Keep in sync with Spikes/project.yml (and Package.resolved).
    static let ghosttyVersion = "libghostty-spm 2.2.2026101301 (rev d403978; Ghostty main 1e9e14af5df1)"
    static let swiftTermVersion = "SwiftTerm 1.99.0 (rev 2dad6a1)"
}
