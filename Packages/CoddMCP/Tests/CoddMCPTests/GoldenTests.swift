import Foundation
import Testing
@testable import CoddMCP

/// The exact `initialize` and `tools/list` responses, pretty-printed in Fixtures/. A change to the
/// wire surface shows up as a fixture diff. To accept an intended change, run the suite once with
/// `CODD_MCP_RECORD_GOLDEN=1` and review the diff of the fixture files.
@Suite("Golden responses")
struct GoldenTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    func check(_ name: String, _ response: MCPHTTPResponse, sourceLocation: SourceLocation = #_sourceLocation) throws {
        #expect(response.status == 200, sourceLocation: sourceLocation)
        let parsed = try JSONParser.parse(response.body)
        let pretty = JSONWriter.pretty(parsed) + "\n"
        let url = Self.fixtures.appendingPathComponent(name)
        if ProcessInfo.processInfo.environment["CODD_MCP_RECORD_GOLDEN"] == "1" {
            try pretty.write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let expected = try String(contentsOf: url, encoding: .utf8)
        #expect(pretty == expected, "\(name) differs from the golden file", sourceLocation: sourceLocation)
        // The wire bytes are the compact form of the same document, byte for byte.
        #expect(response.body == JSONWriter.compact(try JSONParser.parse(expected)), sourceLocation: sourceLocation)
    }

    @Test func initialize() async throws {
        let response = await Fixture.server(version: "0.4.0").post(
            Wire.rpc("initialize", id: 0, params: #"{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.1.302"}}"#),
            version: nil)
        try check("initialize.json", response)
    }

    @Test func toolsList() async throws {
        let response = await Fixture.server(version: "0.4.0").post(Wire.rpc("tools/list", id: 1), version: "2025-11-25")
        try check("tools-list.json", response)
    }

    /// The other two variants: no structured output (2025-03-26) and notes_write listed.
    @Test func toolsListLegacyWithWrite() async throws {
        var canned = FakeBackend.Canned()
        canned.writeEnabled = true
        let response = await Fixture.server(FakeBackend(canned), version: "0.4.0").post(
            Wire.rpc("tools/list", id: 1), version: "2025-03-26")
        try check("tools-list-2025-03-26-write.json", response)
    }
}
