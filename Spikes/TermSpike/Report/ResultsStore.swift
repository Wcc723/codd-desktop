import Foundation

/// JSON results under `<dir>/results/`, and `RESULTS.md` rebuilt from
/// whichever of `probe.json` / `bench.json` exist.
enum ResultsStore {
    static func resultsURL(name: String, in directory: URL) -> URL {
        ResultsLocation.resultsFolder(in: directory).appendingPathComponent(name)
    }

    static func write(_ value: some Encodable, name: String, in directory: URL) throws {
        let folder = ResultsLocation.resultsFolder(in: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, name: String, in directory: URL) -> T? {
        guard let data = try? Data(contentsOf: resultsURL(name: name, in: directory)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Rewrites `<dir>/RESULTS.md` and returns its URL.
    @discardableResult
    static func regenerateMarkdown(in directory: URL) throws -> URL {
        let probe = read(ProbeReport.self, name: "probe.json", in: directory)
        let bench = read(BenchReport.self, name: "bench.json", in: directory)
        let url = directory.appendingPathComponent("RESULTS.md")
        try ResultsMarkdown.render(probe: probe, bench: bench).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
