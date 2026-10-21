import Foundation
import Testing
@testable import CoddOnboarding

/// `scripts/m5-fixtures/make-import-fixture.sh` into a temp folder, read back as its EXPECT lines say.
@Suite("Import fixture (scripts/m5-fixtures)")
struct FixtureTests {
    static var script: String {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        return repo.appendingPathComponent("scripts/m5-fixtures/make-import-fixture.sh").path
    }

    struct Expected: Equatable {
        let rank: Int
        let path: String
        let transcripts: Int
        let hidden: String
    }

    static func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TMPDIR"] = NSTemporaryDirectory()
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("the catalog reads the fixture exactly as its EXPECT lines say, and changes nothing")
    func readsAsExpected() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        let (status, output) = try Self.run([box.claudeDir.path, box.work])
        #expect(status == 0)
        var expected: [Expected] = []
        var absent: [String] = []
        var source: String?
        for line in output.split(separator: "\n").map(String.init) {
            let parts = line.split(separator: " ").map(String.init)
            switch parts.first {
            case "EXPECT":
                guard parts.count == 5, let rank = Int(parts[1]) else { continue }
                expected.append(Expected(rank: rank, path: parts[2], transcripts: Int(parts[3].dropFirst("transcripts=".count)) ?? -1,
                                         hidden: String(parts[4].dropFirst("hidden=".count))))
            case "ABSENT": absent.append(parts.dropFirst().joined(separator: " "))
            case "SOURCE": source = parts.dropFirst().joined(separator: " ")
            default: break
            }
        }
        #expect(expected.count == 8)
        let config = try #require(source)
        let before = Fingerprint(config)

        let result = box.read()
        // The script writes realpath()s (/private/var/…), while the sandbox root went through
        // resolvingSymlinksInPath, which drops /private: look the rows up by the script's spelling.
        let work = try #require(realpath(box.work, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        #expect(result.source == "~/.claude.json")
        #expect(result.candidates.map(\.path) == expected.sorted { $0.rank < $1.rank }.map(\.path))
        for item in expected {
            let found = result.candidate(item.path)
            #expect(found?.transcripts == item.transcripts, "\(item.path)")
            #expect((found?.hidden?.rawValue ?? "none") == item.hidden, "\(item.path)")
        }
        for path in absent { #expect(result.candidate(path) == nil) }
        #expect(!String(describing: result).contains("@example.com"))
        #expect(result.candidate(work + "/labs/mcp")?.prefix == "labs/")
        #expect(result.candidate(work + "/labs/x")?.prefix == "labs/")
        #expect(Fingerprint(config) == before)

        // Pre-check and the suggestion the e2e test relies on.
        let selection = ImportSelection.initial(result, existing: [], now: Date(), home: box.home)
        #expect(selection.checked == Set(["clients/alpha-web", "labs/mcp", "clients/alpha-api", "solo-tool", "labs/x"].map { work + "/" + $0 }))
        let (options, suggestion) = GroupSuggester.suggest(for: result.candidates, checked: selection.checked, existing: [], home: box.home)
        #expect(options.filter { $0.kind == .new }.map(\.name) == ["clients", "labs"])
        #expect(suggestion[work + "/clients/legacy-site"] == suggestion[work + "/clients/alpha-web"])
        #expect(suggestion[work + "/solo-tool"] == GroupOption.ungroupedKey)
    }

    @Test("it refuses an existing .claude.json, a folder outside the temp folders and a parent that is the temp folder")
    func refusals() throws {
        let box = try Sandbox()
        defer { box.cleanUp() }
        try Data("{}".utf8).write(to: URL(fileURLWithPath: box.configPath))
        #expect(try Self.run([box.claudeDir.path, box.work]).status == 1)
        #expect(try Data(contentsOf: URL(fileURLWithPath: box.configPath)) == Data("{}".utf8))
        #expect(try Self.run([NSHomeDirectory() + "/codd-fixture-never/.claude", box.work]).status == 1)
        #expect(!FileManager.default.fileExists(atPath: NSHomeDirectory() + "/codd-fixture-never"))
        #expect(try Self.run([NSTemporaryDirectory() + ".claude", box.work]).status == 1)
        #expect(try Self.run([box.claudeDir.path]).status == 2)
    }
}
