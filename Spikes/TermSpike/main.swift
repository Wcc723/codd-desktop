import AppKit

// Entry point. `--bench` is a plain orchestrator (no NSApplication): it spawns
// this same binary once per measurement with `--bench-worker`, so every number
// comes from a fresh process. Everything else runs an AppKit app.
let mode = LaunchMode.parse(CommandLine.arguments)

switch mode {
case let .bench(options):
    exit(BenchOrchestrator.run(options))
case let .report(outputDirectory):
    do {
        print("wrote \(try ResultsStore.regenerateMarkdown(in: outputDirectory).path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("TermSpike: could not write RESULTS.md: \(error)\n".utf8))
        exit(1)
    }
case let .invalid(message):
    FileHandle.standardError.write(Data("TermSpike: \(message)\n".utf8))
    exit(64)
default:
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate(mode: mode)
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        _ = delegate
    }
}
