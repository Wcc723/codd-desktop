import CoddCore
import Darwin
import Foundation
import Testing
@testable import CoddHooks

/// M5 D14: a config.json from a newer CODD is used as it is and never rewritten; v1 unchanged.
@Suite("Hook config versions")
struct HookConfigVersionTests {
    static let mcpToken = String(repeating: "cd", count: 32)

    func store(_ tmp: TempDir) -> HookConfigStore {
        HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in true })
    }

    func write(_ text: String, to store: HookConfigStore) throws {
        try Data(text.utf8).write(to: store.fileURL)
        chmod(store.fileURL.path, 0o600)
    }

    @Test func newerFileLoadsAsItIsAndIsNeverRewritten() throws {
        let tmp = try TempDir("codd-config-v")
        defer { tmp.remove() }
        let store = store(tmp)
        let newer = #"{"future":{"x":1},"mcpToken":"\#(Self.mcpToken)","port":47833,"token":"\#(testToken)","v":2}"#
        try write(newer, to: store)
        let load = try store.loadOrCreate()
        #expect(load == HookConfigLoad(config: HookConfig(port: 47833, token: testToken, mcpToken: Self.mcpToken), origin: .loaded,
                                       newerVersion: 2))
        #expect(throws: HookConfigError.newerVersion(2)) { try store.reassignPort() }
        #expect(throws: HookConfigError.newerVersion(2)) { try store.setPort(47850) }
        #expect(throws: HookConfigError.newerVersion(2)) { try store.rotateMCPToken() }
        #expect(try Data(contentsOf: store.fileURL) == Data(newer.utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["config.json"])
    }

    @Test func newerFileWithoutMCPTokenNeverGainsOne() throws {
        let tmp = try TempDir("codd-config-v")
        defer { tmp.remove() }
        let store = store(tmp)
        let newer = #"{"port":47821,"token":"\#(testToken)","v":5}"#
        try write(newer, to: store)
        let load = try store.loadOrCreate()
        #expect(load.config == HookConfig(port: 47821, token: testToken, mcpToken: nil))
        #expect(load.newerVersion == 5)
        #expect(try Data(contentsOf: store.fileURL) == Data(newer.utf8))
    }

    @Test func newerFileIsNeverRepaired() throws {
        let tmp = try TempDir("codd-config-v")
        defer { tmp.remove() }
        let store = store(tmp)
        let newer = #"{"endpoint":{"port":47821},"secret":"elsewhere","v":2}"#
        try write(newer, to: store)
        #expect(throws: HookConfigError.newerVersion(2)) { try store.loadOrCreate() }
        #expect(try Data(contentsOf: store.fileURL) == Data(newer.utf8))
        // No `.invalid-<s>` backup either: nothing was repaired.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["config.json"])
    }

    @Test func versionOneBehaviourIsUnchanged() throws {
        let tmp = try TempDir("codd-config-v")
        defer { tmp.remove() }
        let store = store(tmp)
        try write(#"{"mcpToken":"\#(Self.mcpToken)","port":47830,"token":"\#(testToken)","v":1}"#, to: store)
        let load = try store.loadOrCreate()
        #expect(load == HookConfigLoad(config: HookConfig(port: 47830, token: testToken, mcpToken: Self.mcpToken), origin: .loaded))
        let moved = try store.setPort(47840)
        #expect(moved.port == 47840 && moved.token == testToken && moved.mcpToken == Self.mcpToken)
        let rotated = try store.rotateMCPToken()
        #expect(rotated.mcpToken != Self.mcpToken && rotated.port == 47840)
        let file = try #require(JSONValue.parse(Data(contentsOf: store.fileURL))?.objectValue)
        #expect(file["v"] == 1 && file["port"] == 47840)
    }

    @Test func missingOrOddVersionIsStillRepairedAndRewritten() throws {
        for version in ["", #","v":"2""#, #","v":0"#] {
            let tmp = try TempDir("codd-config-v")
            defer { tmp.remove() }
            let store = store(tmp)
            try write(#"{"port":47830,"token":"\#(testToken)"\#(version)}"#, to: store)
            let load = try store.loadOrCreate()
            #expect(load.newerVersion == nil, "\(version)")
            #expect(load.config.port == 47830)
            // M4: the file gained an MCP token and v 1.
            let file = try #require(JSONValue.parse(Data(contentsOf: store.fileURL))?.objectValue)
            #expect(file["v"] == 1 && file["mcpToken"] == .string(load.config.mcpToken ?? ""), "\(version)")
        }
    }

    @Test func newerFileThatAppearsLaterIsNotReplaced() throws {
        let tmp = try TempDir("codd-config-v")
        defer { tmp.remove() }
        let store = store(tmp)
        _ = try store.loadOrCreate()
        let newer = #"{"mcpToken":"\#(Self.mcpToken)","port":47821,"token":"\#(testToken)","v":3}"#
        try write(newer, to: store)
        #expect(throws: HookConfigError.newerVersion(3)) { try store.rotateMCPToken() }
        #expect(try Data(contentsOf: store.fileURL) == Data(newer.utf8))
        #expect(HookConfigError.newerVersion(3).description == "config.json 是較新版本的 CODD 寫的（v3），這個版本不會改寫它")
    }
}
