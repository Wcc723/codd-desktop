import CoddCore
import Darwin
import Foundation
import Testing
@testable import CoddHooks

@Suite("Hook config")
struct HookConfigTests {
    func mode(_ path: String) -> mode_t {
        var info = stat()
        return stat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }

    func json(_ url: URL) throws -> JSONValue {
        try #require(JSONValue.parse(Data(contentsOf: url)))
    }

    @Test func createsWithDefaultPortAndPrivateModes() throws {
        let tmp = try TempDir("codd-config")
        defer { tmp.remove() }
        let root = tmp.file("data/root")
        let store = HookConfigStore(dataRoot: root, isPortAvailable: { _ in true })
        let load = try store.loadOrCreate()
        #expect(load.origin == .created)
        #expect(load.config.port == 47821)
        #expect(HookConfig.isValidToken(load.config.token))
        #expect(mode(root.path) == 0o700)
        #expect(mode(store.fileURL.path) == 0o600)
        let file = try json(store.fileURL)
        #expect(file["port"] == 47821)
        #expect(file["token"] == .string(load.config.token))
        #expect(file["v"] == 1)
        #expect(load.config.endpoint.url == "http://127.0.0.1:47821/hooks")

        // Loading again returns the same values, without rewriting the file.
        let before = try Data(contentsOf: store.fileURL)
        let again = try store.loadOrCreate()
        #expect(again == HookConfigLoad(config: load.config, origin: .loaded))
        #expect(try Data(contentsOf: store.fileURL) == before)
    }

    @Test func tokensAreRandom() throws {
        let a = try HookConfig.generateToken(), b = try HookConfig.generateToken()
        #expect(a != b)
        #expect(HookConfig.isValidToken(a) && HookConfig.isValidToken(b))
        #expect(!HookConfig.isValidToken(String(a.dropLast())))
        #expect(!HookConfig.isValidToken(a.uppercased()))
    }

    @Test func busyDefaultPortPicksTheNextFreeOneOnce() throws {
        let tmp = try TempDir("codd-config")
        defer { tmp.remove() }
        let busy: Set<UInt16> = [47821, 47822]
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { !busy.contains($0) })
        #expect(try store.loadOrCreate().config.port == 47823)
        // Later the persisted port is busy: loading never moves it (sessions have it baked in).
        let everythingBusy = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in false })
        let load = try everythingBusy.loadOrCreate()
        #expect(load.config.port == 47823)
        #expect(load.origin == .loaded)
    }

    @Test func noFreePortIsTyped() throws {
        let tmp = try TempDir("codd-config")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in false })
        #expect(throws: HookConfigError.noFreePort(47821...47899)) { try store.loadOrCreate() }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func explicitPortChangesKeepTheToken() throws {
        let tmp = try TempDir("codd-config")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { $0 != 47822 })
        let first = try store.loadOrCreate().config
        let moved = try store.reassignPort()
        #expect(moved.port == 47823) // 47821 is the current one, 47822 is busy
        #expect(moved.token == first.token)
        #expect(try store.loadOrCreate().config == moved)
        let set = try store.setPort(50000)
        // M4: the MCP token is carried through like the hook token.
        #expect(set == HookConfig(port: 50000, token: first.token, mcpToken: first.mcpToken))
        #expect(mode(store.fileURL.path) == 0o600)
    }

    @Test func repairsAnInvalidFileKeepingABackupAndValidParts() throws {
        let tmp = try TempDir("codd-config")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in true })
        // Valid port, bad token, plus a key CODD does not know.
        try Data(#"{"port":47830,"token":"short","other":"keep me"}"#.utf8).write(to: store.fileURL)
        let load = try store.loadOrCreate()
        guard case .repaired(let backup, let portChanged, let tokenChanged) = load.origin else {
            Issue.record("expected repair, got \(load.origin)")
            return
        }
        #expect(load.config.port == 47830)
        #expect(!portChanged && tokenChanged)
        #expect(HookConfig.isValidToken(load.config.token))
        #expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: backup)), as: UTF8.self).contains("short"))
        let file = try json(store.fileURL)
        #expect(file["other"] == "keep me")
        #expect(try store.loadOrCreate().origin == .loaded)

        // Not JSON at all.
        try Data("garbage".utf8).write(to: store.fileURL)
        let fresh = try store.loadOrCreate()
        #expect(fresh.config.port == 47821)
        if case .repaired(_, let portChanged, let tokenChanged) = fresh.origin {
            #expect(portChanged && tokenChanged)
        } else {
            Issue.record("expected repair")
        }
    }

    @Test func tightensALooseMode() throws {
        let tmp = try TempDir("codd-config")
        defer { tmp.remove() }
        let store = HookConfigStore(dataRoot: tmp.url, isPortAvailable: { _ in true })
        _ = try store.loadOrCreate()
        chmod(store.fileURL.path, 0o644)
        _ = try store.loadOrCreate()
        #expect(mode(store.fileURL.path) == 0o600)
    }

    @Test func concurrentCreatorsAgree() async throws {
        let tmp = try TempDir("codd-config")
        defer { tmp.remove() }
        let root = tmp.url
        let configs = await withTaskGroup(of: HookConfig?.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try? HookConfigStore(dataRoot: root, isPortAvailable: { _ in true }).loadOrCreate().config
                }
            }
            var out: [HookConfig?] = []
            for await c in group { out.append(c) }
            return out
        }
        #expect(configs.allSatisfy { $0 != nil })
        #expect(Set(configs.compactMap { $0?.token }).count == 1)
        // No temp files left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names == ["config.json"])
    }

    @Test func portProbe() async throws {
        let l = occupyNonEphemeralPort()
        defer { l.close() }
        #expect(!PortProbe.isAvailable(l.port))
        l.close()
        // A test running in parallel may pick the same port from the range for a moment.
        #expect(await eventually(timeout: 2) { PortProbe.isAvailable(l.port) })
    }
}
