import Foundation
import Testing
@testable import CoddCore

/// Golden data produced by running the original session-insights.js `enrichOne` against crafted
/// hook and registry files (Fixtures/gen/gen-session-insights.mjs).
struct InsightsGolden {
    struct Scenario: CustomTestStringConvertible, Sendable {
        var name: String
        var record: JSONValue
        var hook: JSONValue?
        var registry: [JSONValue]
        var expected: JSONValue
        var testDescription: String { name }
    }

    let terminalId: String
    let scenarios: [Scenario]

    static func load() throws -> InsightsGolden {
        let root = try Fixtures.json("hooks", "session-insights-activity.golden.json")
        let scenarios = try (root.require("scenarios").arrayValue ?? []).map { sc in
            Scenario(
                name: sc["name"]?.stringValue ?? "?",
                record: try sc.require("record"),
                hook: sc["hook"].flatMap { $0 == .null ? nil : $0 },
                registry: sc["registry"]?.arrayValue ?? [],
                expected: try sc.require("expected"))
        }
        return InsightsGolden(terminalId: try root.require("terminalId").stringValue ?? "", scenarios: scenarios)
    }

    static let shared: InsightsGolden? = try? load()
    static var scenarioList: [Scenario] { shared?.scenarios ?? [] }

    /// Writes the scenario's registry files into a temp dir, reads them back with the real reader,
    /// and merges.
    static func merge(_ sc: Scenario, terminalId: String, dialect: HookDialect) throws -> SessionActivity {
        let tmp = try TempDir("codd-insights")
        defer { tmp.remove() }
        for entry in sc.registry {
            let name = try entry.require("file").stringValue ?? "x"
            let bytes: Data = try entry["raw"]?.stringValue.map { Data($0.utf8) } ?? entry.require("body").jsonData()
            try bytes.write(to: tmp.file(name))
        }
        let registry = ClaudeRegistryReader().read(directory: tmp.url)
        let hook = try sc.hook.map { try JSONDecoder().decode(HookSessionState.self, from: $0.jsonData()) }
        let exitedAt = JSDate.date(fromISO: sc.record["exited_at"]?.stringValue)
        let context = ActivityContext(
            terminalId: terminalId,
            pid: sc.record["pid"]?.exactIntegerValue,
            claudeSessionId: sc.record["claude_session_id"]?.stringValue,
            process: sc.record["status"]?.stringValue == "exited" ? .exited(at: exitedAt) : .running)
        return ActivityMerger(dialect: dialect).merge(context: context, hook: hook, registry: registry)
    }
}

@Suite("session-insights.js activity merge golden fixtures")
struct ActivityMergerGoldenTests {
    @Test func fixtureIsPresent() throws {
        #expect(try InsightsGolden.load().scenarios.count >= 40)
    }

    @Test("web dialect equals the original", arguments: InsightsGolden.scenarioList)
    func webDialectMatchesOriginal(_ sc: InsightsGolden.Scenario) throws {
        let golden = try #require(InsightsGolden.shared)
        let activity = try InsightsGolden.merge(sc, terminalId: golden.terminalId, dialect: .web)
        #expect(try jsonValue(activity) == sc.expected, "\(sc.name)")
    }

    /// Scenarios where the desktop dialect intentionally differs (documented in ActivityMerger).
    static let desktopDifferences: Set<String> = [
        "no_hook_registry_waiting",               // reason from waitingFor ("input needed" → question)
        "hook_state_unknown_string_uses_registry", // hook "error" is a known desktop state
        "hook_state_compacting_no_registry",       // hook "compacting" is a known desktop state
    ]

    @Test("desktop dialect equals web except documented cases", arguments: InsightsGolden.scenarioList)
    func desktopAgreesExceptDocumentedCases(_ sc: InsightsGolden.Scenario) throws {
        let golden = try #require(InsightsGolden.shared)
        let web = try InsightsGolden.merge(sc, terminalId: golden.terminalId, dialect: .web)
        let desktop = try InsightsGolden.merge(sc, terminalId: golden.terminalId, dialect: .desktop)
        if Self.desktopDifferences.contains(sc.name) {
            #expect(web != desktop)
        } else {
            #expect(web == desktop)
        }
    }
}
