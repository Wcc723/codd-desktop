import Foundation
import Testing
@testable import CoddCore

/// Golden data produced by EXECUTING the original status-writer.js (Fixtures/gen/gen-status-writer.mjs).
struct StatusWriterGolden {
    struct Scenario: CustomTestStringConvertible, Sendable {
        var name: String
        var seed: String?
        var steps: [StepBox]
        var testDescription: String { name }
    }

    /// One event: request body, injected clock, and what the original wrote.
    struct StepBox: Sendable {
        var now: String
        var body: Data
        var written: Bool
        var state: JSONValue?
    }

    let terminalId: String
    let configDir: String
    let scenarios: [Scenario]

    static func load() throws -> StatusWriterGolden {
        let root = try Fixtures.json("hooks", "status-writer.golden.json")
        let scenarios = try (root.require("scenarios").arrayValue ?? []).map { sc -> Scenario in
            let steps = try (sc.require("steps").arrayValue ?? []).map { st -> StepBox in
                let body: Data
                if let payload = st["payload"] {
                    body = try payload.jsonData()
                } else {
                    body = Data((st["stdin"]?.stringValue ?? "").utf8)
                }
                let state = st["state"].flatMap { $0 == .null ? nil : $0 }
                return StepBox(now: try st.require("now").stringValue ?? "", body: body,
                               written: st["written"]?.boolValue ?? false, state: state)
            }
            return Scenario(name: sc["name"]?.stringValue ?? "?", seed: sc["seed"]?.stringValue, steps: steps)
        }
        return StatusWriterGolden(
            terminalId: try root.require("terminalId").stringValue ?? "",
            configDir: try root.require("configDir").stringValue ?? "",
            scenarios: scenarios)
    }

    static let shared: StatusWriterGolden? = try? load()
    static var scenarioList: [Scenario] { shared?.scenarios ?? [] }

    /// `loadPrev(file)`: invalid JSON or a non-object → `{}` (nil here).
    static func decodeSeed(_ seed: String?) -> HookSessionState? {
        guard let seed, let json = JSONValue.parse(Data(seed.utf8)), json.objectValue != nil else { return nil }
        return try? JSONDecoder().decode(HookSessionState.self, from: Data(seed.utf8))
    }

    /// Runs one scenario through a reducer, returning the per-step outputs.
    static func run(_ sc: Scenario, dialect: HookDialect, terminalId: String, configDir: String) -> [HookSessionState?] {
        let reducer = HookReducer(dialect: dialect, configDir: configDir)
        var prev = decodeSeed(sc.seed)
        var outputs: [HookSessionState?] = []
        for step in sc.steps {
            let next = reducer.apply(prev, HookPayload(body: step.body), terminalId: terminalId, nowISO: step.now)
            outputs.append(next)
            if let next { prev = next }
        }
        return outputs
    }
}

@Suite("status-writer.js golden fixtures")
struct HookReducerGoldenTests {
    @Test func fixtureIsPresentAndLarge() throws {
        let golden = try StatusWriterGolden.load()
        #expect(golden.scenarios.count >= 20)
        #expect(golden.scenarios.reduce(0) { $0 + $1.steps.count } >= 150)
    }

    @Test("web dialect equals the original", arguments: StatusWriterGolden.scenarioList)
    func webDialectMatchesOriginal(_ sc: StatusWriterGolden.Scenario) throws {
        let golden = try #require(StatusWriterGolden.shared)
        let outputs = StatusWriterGolden.run(sc, dialect: .web, terminalId: golden.terminalId, configDir: golden.configDir)
        for (i, (step, out)) in zip(sc.steps, outputs).enumerated() {
            if step.written {
                let out = try #require(out, "\(sc.name) step \(i): Swift ignored an event the original wrote")
                #expect(try jsonValue(out) == step.state, "\(sc.name) step \(i)")
            } else {
                #expect(out == nil, "\(sc.name) step \(i): Swift wrote an event the original ignored")
            }
        }
    }

    /// The original re-reads its state FILE before every event; the Swift runner above keeps the
    /// value in memory. Reloading through the encoded file must give the same results, i.e. the
    /// file format loses nothing the reducer depends on (both dialects).
    @Test("state survives the file round trip between events", arguments: StatusWriterGolden.scenarioList)
    func fileRoundTripBetweenEvents(_ sc: StatusWriterGolden.Scenario) throws {
        let golden = try #require(StatusWriterGolden.shared)
        for dialect in [HookDialect.web, .desktop] {
            let reducer = HookReducer(dialect: dialect, configDir: golden.configDir)
            let inMemory = StatusWriterGolden.run(sc, dialect: dialect, terminalId: golden.terminalId, configDir: golden.configDir)
            var prev = StatusWriterGolden.decodeSeed(sc.seed)
            for (i, step) in sc.steps.enumerated() {
                let next = reducer.apply(prev, HookPayload(body: step.body), terminalId: golden.terminalId, nowISO: step.now)
                #expect(next == inMemory[i], "\(sc.name) step \(i) \(dialect)")
                if let next {
                    let reloaded = try JSONDecoder().decode(HookSessionState.self, from: JSONEncoder().encode(next))
                    #expect(reloaded == next, "\(sc.name) step \(i) \(dialect): lossy file format")
                    prev = reloaded
                }
            }
        }
    }

    /// Events the desktop dialect treats differently (documented extensions).
    static let extensionEvents: Set<String> = ["StopFailure", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop"]

    @Test("desktop dialect equals web when no extension event occurs", arguments: StatusWriterGolden.scenarioList)
    func desktopDialectAgreesOutsideExtensions(_ sc: StatusWriterGolden.Scenario) throws {
        let golden = try #require(StatusWriterGolden.shared)
        let usesExtensions = sc.steps.contains { step in
            let event = JSONValue.parse(step.body)?["hook_event_name"]?.stringValue ?? ""
            return Self.extensionEvents.contains(event)
        }
        let web = StatusWriterGolden.run(sc, dialect: .web, terminalId: golden.terminalId, configDir: golden.configDir)
        let desktop = StatusWriterGolden.run(sc, dialect: .desktop, terminalId: golden.terminalId, configDir: golden.configDir)
        if usesExtensions {
            // Same accept/ignore decisions, same identity fields.
            for (w, d) in zip(web, desktop) {
                #expect((w == nil) == (d == nil))
                #expect(w?.sessionId == d?.sessionId)
                #expect(w?.lastPrompt == d?.lastPrompt)
                #expect(w?.toolCount == d?.toolCount)
            }
        } else {
            #expect(web == desktop)
        }
    }

    @Test func subagentScenarioDiffersOnlyByCounter() throws {
        let golden = try #require(StatusWriterGolden.shared)
        let sc = try #require(golden.scenarios.first { $0.name == "subagents_are_noops" })
        let web = StatusWriterGolden.run(sc, dialect: .web, terminalId: golden.terminalId, configDir: golden.configDir)
        let desktop = StatusWriterGolden.run(sc, dialect: .desktop, terminalId: golden.terminalId, configDir: golden.configDir)
        for (w, d) in zip(web, desktop) {
            let wj = try w.map(jsonValue), dj = try d.map(jsonValue)
            #expect(removingKeys(["subagents_active"], from: wj) == removingKeys(["subagents_active"], from: dj))
        }
        #expect(desktop.compactMap { $0?.subagentsActive }.max() == 2)
        #expect(desktop.last??.subagentsActive == 0)
    }
}
