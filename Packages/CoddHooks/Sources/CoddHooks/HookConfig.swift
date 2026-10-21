import CoddCore
import Darwin
import Foundation
import Security

/// The per-install hook endpoint settings in `<dataRoot>/config.json`.
public struct HookConfig: Sendable, Equatable {
    public var port: UInt16
    /// 64 lowercase hex characters (32 random bytes).
    public var token: String
    /// M4 D16: the external MCP token (registered clients, note URLs), 64 lowercase hex
    /// characters. Every config ``HookConfigStore`` returns has one, unless adding it to an M3
    /// file could not be written; `nil` also in values built in code without it.
    public var mcpToken: String?

    public init(port: UInt16, token: String, mcpToken: String? = nil) {
        self.port = port
        self.token = token
        self.mcpToken = mcpToken
    }

    public var endpoint: HookEndpoint { HookEndpoint(port: port) }

    /// 32 bytes from `SecRandomCopyBytes`, hex encoded.
    public static func generateToken() throws(HookConfigError) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw .randomUnavailable(status: status) }
        let hex = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in bytes {
            out.append(hex[Int(b >> 4)])
            out.append(hex[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `[0-9a-f]{64}`.
    public static func isValidToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

public enum HookConfigError: Error, Sendable, Equatable, CustomStringConvertible {
    case io(String)
    /// Every port in the range was taken when a port had to be chosen.
    case noFreePort(ClosedRange<UInt16>)
    case randomUnavailable(status: OSStatus)
    /// config.json belongs to another user; refusing to use or rewrite it.
    case notOwnedByUser(path: String)
    case invalidPort(Int)
    /// M5 D14: config.json was written by a newer CODD (its `v`): it is used as it is and never
    /// rewritten, so the port cannot move and the MCP token cannot rotate.
    case newerVersion(Int)

    public var description: String {
        switch self {
        case .io(let s): return s
        case .noFreePort(let r): return "no free port in \(r.lowerBound)…\(r.upperBound)"
        case .randomUnavailable(let s): return "SecRandomCopyBytes failed (\(s))"
        case .notOwnedByUser(let p): return "\(p) is not owned by the current user"
        case .invalidPort(let p): return "invalid port \(p)"
        case .newerVersion(let v): return "config.json 是較新版本的 CODD 寫的（v\(v)），這個版本不會改寫它"
        }
    }
}

/// How ``HookConfigStore/loadOrCreate()`` obtained the config.
public enum HookConfigOrigin: Sendable, Equatable {
    case loaded
    case created
    /// The file was unreadable as JSON or had an invalid port or token; the original was kept at
    /// `backupPath` and the missing parts were regenerated (a valid port is always kept).
    case repaired(backupPath: String, portChanged: Bool, tokenChanged: Bool)
}

public struct HookConfigLoad: Sendable, Equatable {
    public var config: HookConfig
    public var origin: HookConfigOrigin
    /// The file's `v` when a newer CODD wrote it (origin ``HookConfigOrigin/loaded``): used as it
    /// is, never repaired or rewritten.
    public var newerVersion: Int? = nil
}

/// Loads or creates `<dataRoot>/config.json` (`{"port":…,"token":"…","mcpToken":"…","v":1}`, mode
/// 0600, data root 0700 when CODD creates it).
///
/// The port is chosen once, at creation: 47821 if free, else the first free port up to 47899. A
/// persisted port is never changed by loading, even when it is busy: running Claude sessions have
/// the URL baked into their `--settings`, so a silent move would cut every one of them off. A busy
/// port surfaces as ``HookServerError/portInUse(_:)`` when the server starts, and only an explicit
/// ``reassignPort(excluding:)`` moves it. Unknown keys in the file are preserved on every rewrite.
///
/// M4 (§3.11): a file without a valid `mcpToken` (every M3 file) gains one when it is loaded,
/// rewritten 0600 and atomically with the port, the token and every other key unchanged, so a
/// loaded config has one (unless that rewrite fails: then the hooks load as in M3, without an MCP
/// token, and the next load tries again); the origin stays ``HookConfigOrigin/loaded``. Every rewrite
/// (``reassignPort(excluding:)``, ``setPort(_:)``, a repair) keeps it; only
/// ``rotateMCPToken()`` replaces it.
///
/// M5 D14: a file with `v` above ``currentVersion`` (a newer CODD) loads as it is (port, token,
/// and the MCP token when it has a valid one; ``HookConfigLoad/newerVersion`` says so), is never
/// repaired, never gains an MCP token and is never rewritten: ``reassignPort(excluding:)``,
/// ``setPort(_:)`` and ``rotateMCPToken()`` throw ``HookConfigError/newerVersion(_:)``, and so does
/// loading when such a file has no usable port or token.
public struct HookConfigStore: Sendable {
    public static let fileName = "config.json"
    public static let defaultPort: UInt16 = 47821
    public static let portRange: ClosedRange<UInt16> = 47821...47899
    public static let maxFileBytes = 64 * 1024
    /// The `v` this build writes.
    public static let currentVersion = 1

    public let dataRoot: URL
    /// Whether 127.0.0.1:`port` can be bound right now (injectable for tests).
    public var isPortAvailable: @Sendable (UInt16) -> Bool
    public var portRange: ClosedRange<UInt16>

    public init(dataRoot: URL, portRange: ClosedRange<UInt16> = HookConfigStore.portRange,
                isPortAvailable: @escaping @Sendable (UInt16) -> Bool = PortProbe.isAvailable) {
        self.dataRoot = dataRoot
        self.portRange = portRange
        self.isPortAvailable = isPortAvailable
    }

    public var fileURL: URL { dataRoot.appendingPathComponent(Self.fileName, isDirectory: false) }

    public func loadOrCreate() throws(HookConfigError) -> HookConfigLoad {
        do {
            try FileIO.ensureDirectory(dataRoot)
        } catch {
            throw .io(error.description)
        }
        // Two attempts: a concurrent creator may win the exclusive create between our read and link.
        for _ in 0..<2 {
            if let existing = try readExisting() { return existing }
            let config = HookConfig(port: try choosePort(excluding: []), token: try HookConfig.generateToken(),
                                    mcpToken: try HookConfig.generateToken())
            let created: Bool
            do {
                created = try FileIO.createExclusively(encode(config, preserving: [:]), at: fileURL)
            } catch {
                throw .io(error.description)
            }
            if created { return HookConfigLoad(config: config, origin: .created) }
        }
        guard let existing = try readExisting() else { throw .io("config.json vanished while loading") }
        return existing
    }

    /// Moves the endpoint to the first free port in the range other than `excluding` (and the
    /// current one), keeping the token. Only for an explicit user action: sessions started before
    /// keep posting to the old port until they are restarted.
    public func reassignPort(excluding: Set<UInt16> = []) throws(HookConfigError) -> HookConfig {
        let current = try writableConfig()
        let port = try choosePort(excluding: excluding.union([current.port]))
        return try write(HookConfig(port: port, token: current.token, mcpToken: current.mcpToken))
    }

    /// Persists `port` (explicit user choice), keeping the token and the MCP token.
    public func setPort(_ port: UInt16) throws(HookConfigError) -> HookConfig {
        guard port > 0 else { throw .invalidPort(Int(port)) }
        let current = try writableConfig()
        return try write(HookConfig(port: port, token: current.token, mcpToken: current.mcpToken))
    }

    /// M4 D23 (`輪替`): a new external MCP token, persisted at once (0600, atomic; port, hook token
    /// and other keys unchanged). Registered clients need the new one and every note URL dies;
    /// per-session MCP tokens derive from the hook token and do not change. Apply the result
    /// with `HookServer.setMCPToken(_:)`.
    public func rotateMCPToken() throws(HookConfigError) -> HookConfig {
        let current = try writableConfig()
        var fresh = try HookConfig.generateToken()
        while fresh == current.mcpToken { fresh = try HookConfig.generateToken() }
        return try write(HookConfig(port: current.port, token: current.token, mcpToken: fresh))
    }

    // MARK: - Internals

    /// The loaded config, or ``HookConfigError/newerVersion(_:)`` when a newer CODD owns the file.
    private func writableConfig() throws(HookConfigError) -> HookConfig {
        let load = try loadOrCreate()
        if let version = load.newerVersion { throw .newerVersion(version) }
        return load.config
    }

    private func write(_ config: HookConfig) throws(HookConfigError) -> HookConfig {
        let extra = (try? readObject())?.object ?? [:]
        // Checked again right before the write: a newer file is never replaced.
        if let version = Self.newerVersion(extra) { throw .newerVersion(version) }
        do {
            try FileIO.writeAtomically(encode(config, preserving: extra), to: fileURL, durable: true)
        } catch {
            throw .io(error.description)
        }
        return config
    }

    private func readObject() throws(HookConfigError) -> (object: [String: JSONValue]?, data: Data)? {
        let data: Data?
        do {
            data = try FileIO.read(fileURL, limit: Self.maxFileBytes)
        } catch {
            throw .io(error.description)
        }
        guard let data else { return nil }
        return (JSONValue.parse(data)?.objectValue, data)
    }

    private func readExisting() throws(HookConfigError) -> HookConfigLoad? {
        try checkOwnershipAndMode()
        guard let (object, data) = try readObject() else { return nil }
        let port = object?["port"]?.nonNegativeIntegerValue.flatMap { (1...65535).contains($0) ? UInt16($0) : nil }
        let token = object?["token"]?.stringValue.flatMap { HookConfig.isValidToken($0) ? $0 : nil }
        let mcpToken = object?["mcpToken"]?.stringValue.flatMap { HookConfig.isValidToken($0) ? $0 : nil }
        if let version = Self.newerVersion(object) {
            // A newer CODD's file: as it is, never repaired, no MCP token added.
            guard let port, let token else { throw .newerVersion(version) }
            return HookConfigLoad(config: HookConfig(port: port, token: token, mcpToken: mcpToken), origin: .loaded,
                                  newerVersion: version)
        }
        if let port, let token {
            if let mcpToken {
                return HookConfigLoad(config: HookConfig(port: port, token: token, mcpToken: mcpToken), origin: .loaded)
            }
            return HookConfigLoad(config: addMCPToken(port: port, token: token, object: object ?? [:]), origin: .loaded)
        }

        // Repair: keep the original next to it, keep whatever was valid, regenerate the rest.
        let backup = fileURL.path + ".invalid-\(Int(Date().timeIntervalSince1970))"
        do {
            try FileIO.writeAtomically(data, to: URL(fileURLWithPath: backup), durable: false)
        } catch {
            throw .io(error.description)
        }
        let repairedPort: UInt16
        if let port { repairedPort = port } else { repairedPort = try choosePort(excluding: []) }
        let repairedToken: String
        if let token { repairedToken = token } else { repairedToken = try HookConfig.generateToken() }
        let repairedMCPToken: String
        if let mcpToken { repairedMCPToken = mcpToken } else { repairedMCPToken = try HookConfig.generateToken() }
        let config = HookConfig(port: repairedPort, token: repairedToken, mcpToken: repairedMCPToken)
        do {
            try FileIO.writeAtomically(encode(config, preserving: object ?? [:]), to: fileURL, durable: true)
        } catch {
            throw .io(error.description)
        }
        return HookConfigLoad(config: config, origin: .repaired(backupPath: backup, portChanged: port == nil, tokenChanged: token == nil))
    }

    /// The §3.11 migration: an M3 file (valid port and token, no valid `mcpToken`) gains a fresh
    /// one. The file is re-read after the write and its value returned, so two loaders racing on
    /// one data root end up agreeing on the token that stayed on disk (CODD itself is single
    /// instance per data root, `codd.lock`). Should the rewrite fail (a full disk), the hooks still
    /// load as in M3 and the config has no MCP token (external MCP callers and note URLs are
    /// refused); the next load tries again.
    private func addMCPToken(port: UInt16, token: String, object: [String: JSONValue]) -> HookConfig {
        guard let fresh = try? HookConfig.generateToken() else { return HookConfig(port: port, token: token) }
        let config = HookConfig(port: port, token: token, mcpToken: fresh)
        do {
            try FileIO.writeAtomically(encode(config, preserving: object), to: fileURL, durable: true)
        } catch {
            return HookConfig(port: port, token: token)
        }
        let onDisk = (try? readObject())?.object?["mcpToken"]?.stringValue.flatMap { HookConfig.isValidToken($0) ? $0 : nil }
        return HookConfig(port: port, token: token, mcpToken: onDisk ?? fresh)
    }

    /// The `v` of a parsed config when it is above ``currentVersion``.
    private static func newerVersion(_ object: [String: JSONValue]?) -> Int? {
        guard let version = object?["v"]?.nonNegativeIntegerValue, version > currentVersion else { return nil }
        return version
    }

    /// Refuses a file owned by someone else and tightens a readable-by-others mode to 0600.
    private func checkOwnershipAndMode() throws(HookConfigError) {
        var info = stat()
        guard lstat(fileURL.path, &info) == 0 else { return }
        guard info.st_uid == getuid() else { throw .notOwnedByUser(path: fileURL.path) }
        if (info.st_mode & S_IFMT) == S_IFREG, info.st_mode & 0o077 != 0 { _ = chmod(fileURL.path, 0o600) }
    }

    private func choosePort(excluding: Set<UInt16>) throws(HookConfigError) -> UInt16 {
        for port in portRange where !excluding.contains(port) && isPortAvailable(port) { return port }
        throw .noFreePort(portRange)
    }

    private func encode(_ config: HookConfig, preserving extra: [String: JSONValue]) -> Data {
        var object = extra
        object["v"] = 1
        object["port"] = .number(Double(config.port))
        object["token"] = .string(config.token)
        // A config without one never removes the file's MCP token.
        if let mcpToken = config.mcpToken { object["mcpToken"] = .string(mcpToken) }
        return ((try? JSONValue.object(object).jsonData(prettyPrinted: true)) ?? Data()) + Data("\n".utf8)
    }
}

/// Port availability check by binding a throwaway socket.
public enum PortProbe {
    /// `true` when 127.0.0.1:`port` (TCP) can be bound now. Without SO_REUSEADDR, like the listener.
    public static func isAvailable(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return rc == 0
    }
}
