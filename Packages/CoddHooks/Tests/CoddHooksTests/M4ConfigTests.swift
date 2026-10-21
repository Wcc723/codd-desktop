import CoddCore
import Darwin
import Foundation
import Testing
@testable import CoddHooks

@Suite("M4 config.json mcpToken")
struct M4ConfigTests {
    func mode(_ path: String) -> mode_t {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func object(_ url: URL) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue)
    }

    /// Exactly what an M3 build wrote (pretty printed, sorted keys, trailing newline), plus a key
    /// another tool added.
    let m3File = """
    {
      "other" : {
        "keep" : [
          1,
          2
        ]
      },
      "port" : 47830,
      "token" : "\(testToken)",
      "v" : 1
    }

    """

    @Test func anM3FileGainsATokenAndKeepsEverythingElse() throws {
        let tmp = try TempDir("codd-config-m4")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in false })
        try Data(m3File.utf8).write(to: store.fileURL)
        chmod(store.fileURL.path, 0o600)
        let load = try store.loadOrCreate()
        #expect(load.origin == .loaded)
        #expect(load.config.port == 47830 && load.config.token == testToken)
        let mcp = try #require(load.config.mcpToken)
        #expect(HookConfig.isValidToken(mcp) && mcp != testToken)
        #expect(mode(store.fileURL.path) == 0o600)
        let file = try object(store.fileURL)
        #expect(file["mcpToken"] == .string(mcp))
        #expect(file["port"] == 47830 && file["token"] == .string(testToken) && file["v"] == 1)
        #expect(file["other"] == ["keep": [1, 2]])
        #expect(file.keys.sorted() == ["mcpToken", "other", "port", "token", "v"])
        // No backup was made (nothing was invalid) and no temp file is left.
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["config.json"])
        // The next load reads it without rewriting.
        let bytes = try Data(contentsOf: store.fileURL)
        #expect(try store.loadOrCreate() == HookConfigLoad(config: load.config, origin: .loaded))
        #expect(try Data(contentsOf: store.fileURL) == bytes)
    }

    @Test func anInvalidMCPTokenIsReplaced() throws {
        let tmp = try TempDir("codd-config-m4")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in true })
        try Data(#"{"port":47821,"token":"\#(testToken)","mcpToken":"short","v":1}"#.utf8).write(to: store.fileURL)
        let load = try store.loadOrCreate()
        #expect(load.origin == .loaded)
        #expect(load.config.mcpToken.map(HookConfig.isValidToken) == true)
        #expect(try object(store.fileURL)["mcpToken"] == .string(load.config.mcpToken ?? ""))
    }

    @Test func createdFilesHaveOne() throws {
        let tmp = try TempDir("codd-config-m4")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.file("root"), isPortAvailable: { _ in true })
        let load = try store.loadOrCreate()
        #expect(load.origin == .created)
        let mcp = try #require(load.config.mcpToken)
        #expect(HookConfig.isValidToken(mcp) && mcp != load.config.token)
        #expect(try object(store.fileURL)["mcpToken"] == .string(mcp))
        #expect(mode(store.fileURL.path) == 0o600)
    }

    @Test func rotationPersistsAndKeepsPortAndToken() throws {
        let tmp = try TempDir("codd-config-m4")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { $0 != 47822 })
        let first = try store.loadOrCreate().config
        let rotated = try store.rotateMCPToken()
        #expect(rotated.port == first.port && rotated.token == first.token)
        #expect(rotated.mcpToken != first.mcpToken && rotated.mcpToken.map(HookConfig.isValidToken) == true)
        #expect(try store.loadOrCreate().config == rotated)
        #expect(mode(store.fileURL.path) == 0o600)
        // Port changes carry the rotated token through.
        let moved = try store.reassignPort()
        #expect(moved == HookConfig(port: 47823, token: first.token, mcpToken: rotated.mcpToken))
        let set = try store.setPort(50001)
        #expect(set.mcpToken == rotated.mcpToken)
        #expect(try store.loadOrCreate().config == set)
        #expect(try object(store.fileURL)["mcpToken"] == .string(rotated.mcpToken ?? ""))
    }

    @Test func repairsStillWorkAndKeepAValidMCPToken() throws {
        let tmp = try TempDir("codd-config-m4")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in true })
        try Data(#"{"port":47830,"token":"short","mcpToken":"\#(testMCPToken)"}"#.utf8).write(to: store.fileURL)
        let load = try store.loadOrCreate()
        guard case .repaired(_, let portChanged, let tokenChanged) = load.origin else {
            Issue.record("expected a repair, got \(load.origin)")
            return
        }
        #expect(!portChanged && tokenChanged)
        #expect(load.config.mcpToken == testMCPToken)
        // Garbage: everything regenerated, an MCP token included.
        try Data("garbage".utf8).write(to: store.fileURL)
        let fresh = try store.loadOrCreate()
        #expect(fresh.config.mcpToken.map(HookConfig.isValidToken) == true)
        #expect(try store.loadOrCreate().origin == .loaded)
    }

    @Test func aMigrationThatCannotBeWrittenStillLoadsTheHooks() throws {
        let tmp = try TempDir("codd-config-m4")
        defer {
            chmod(tmp.url.path, 0o700)
            tmp.remove()
        }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in true })
        try Data(m3File.utf8).write(to: store.fileURL)
        let before = try Data(contentsOf: store.fileURL)
        chmod(tmp.url.path, 0o500) // no temp file can be created next to config.json
        let load = try store.loadOrCreate()
        #expect(load == HookConfigLoad(config: HookConfig(port: 47830, token: testToken), origin: .loaded))
        #expect(try Data(contentsOf: store.fileURL) == before)
        chmod(tmp.url.path, 0o700)
        #expect(try store.loadOrCreate().config.mcpToken.map(HookConfig.isValidToken) == true)
    }

    @Test func concurrentLoadersOfAnM3FileAgree() async throws {
        let tmp = try TempDir("codd-config-m4")
        defer { tmp.remove() }
        let root = tmp.url
        try Data(m3File.utf8).write(to: root.appendingPathComponent("config.json"))
        // One loader migrates; later ones read what is on disk.
        let first = try HookConfigStore(dataRoot: root, isPortAvailable: { _ in true }).loadOrCreate().config
        let configs = await withTaskGroup(of: HookConfig?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? HookConfigStore(dataRoot: root, isPortAvailable: { _ in true }).loadOrCreate().config }
            }
            var out: [HookConfig?] = []
            for await c in group { out.append(c) }
            return out
        }
        #expect(configs.allSatisfy { $0 == first })
    }

    @Test func sourceCompatibility() {
        // D40: what App/Real/HookPipeline.swift and the M1–M3 tests build.
        let old = HookConfig(port: 47821, token: testToken)
        #expect(old.mcpToken == nil)
        var copy = old
        copy.port = 0
        #expect(copy.endpoint.url == "http://127.0.0.1:0/hooks")
        let configuration = HookServer.Configuration(config: HookConfig(port: 1, token: testToken, mcpToken: testMCPToken))
        #expect(configuration.mcpToken == testMCPToken)
        #expect(HookServer.Configuration(config: old).mcpToken == nil)
        #expect(HookServer.Configuration(port: 0, token: testToken).promptDeadline == .milliseconds(1500))
        #expect(HookServer.Configuration(port: 0, token: testToken).handlerDeadline == .seconds(10))
        #expect(HookServer.Configuration(port: 0, token: testToken).maxResponseBytes == 16 << 20)
    }
}
