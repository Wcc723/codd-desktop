import CoddCore
import Darwin
import Foundation
import Synchronization
@testable import CoddHooks

/// A unique temp directory, removed by ``remove()``. Short base path: FSEvents and sockets do not
/// care, but keeping paths short keeps failure messages readable.
struct TempDir {
    let url: URL

    init(_ label: String = "codd-hooks-tests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

/// Collects everything an `AsyncStream` yields, for polling assertions.
final class Collector<Element: Sendable>: Sendable {
    private final class Storage: Sendable {
        let items = Mutex<[Element]>([])
    }

    private let storage = Storage()
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<Element>) {
        let storage = storage
        let t = Task {
            for await item in stream { storage.items.withLock { $0.append(item) } }
        }
        task.withLock { $0 = t }
    }

    var values: [Element] { storage.items.withLock { $0 } }
    var count: Int { storage.items.withLock { $0.count } }

    /// Waits (real time) until `predicate` holds for the collected values.
    @discardableResult
    func wait(timeout: TimeInterval = 5, until predicate: ([Element]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if storage.items.withLock({ predicate($0) }) { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return storage.items.withLock { predicate($0) }
    }

    func wait(count n: Int, timeout: TimeInterval = 5) async -> Bool {
        await wait(timeout: timeout) { $0.count >= n }
    }

    func cancel() {
        task.withLock { $0?.cancel() }
    }
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

/// Registry liveness for tests: a pid is alive when it is in ``alive``.
final class FakeLiveness: ProcessLivenessChecking {
    let alive: Mutex<Set<Int>>

    init(_ pids: Set<Int> = []) {
        alive = Mutex(pids)
    }

    func set(_ pids: Set<Int>) {
        alive.withLock { $0 = pids }
    }

    func isAlive(pid: Int, procStart: String?) -> Bool {
        alive.withLock { $0.contains(pid) }
    }
}

/// Fixed reference time: 2026-10-15T02:42:00Z.
let referenceNow = JSDate.date(milliseconds: 1_792_032_120_000)

let testToken = String(repeating: "ab", count: 32)

/// Blocking raw TCP client for 127.0.0.1 with a receive timeout (tests only).
struct RawClient {
    let fd: Int32

    init(port: UInt16, receiveTimeout: TimeInterval = 5) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(receiveTimeout), tv_usec: Int32((receiveTimeout - floor(receiveTimeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
    }

    @discardableResult
    func send(_ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    @discardableResult
    func send(_ s: String) -> Bool { send(Array(s.utf8)) }

    /// Reads until EOF, error or timeout.
    func readAll(limit: Int = 1 << 20) -> [UInt8] {
        var out: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while out.count < limit {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            out.append(contentsOf: chunk[0..<n])
        }
        return out
    }

    /// Reads until `marker` appears, EOF or timeout.
    func read(until marker: String) -> [UInt8] {
        var out: [UInt8] = []
        var byte: UInt8 = 0
        let m = Array(marker.utf8)
        while true {
            let n = Darwin.read(fd, &byte, 1)
            if n <= 0 { break }
            out.append(byte)
            if out.count >= m.count, Array(out.suffix(m.count)) == m { break }
        }
        return out
    }

    func close() { Darwin.close(fd) }

    /// Half-close: no more data from this side (FIN), reading still works.
    func shutdownWrite() { Darwin.shutdown(fd, SHUT_WR) }

    /// The status code of the first response line in `bytes`.
    static func status(_ bytes: [UInt8]) -> Int? {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.hasPrefix("HTTP/1.1 "), text.count >= 12 else { return nil }
        return Int(text.dropFirst(9).prefix(3))
    }
}

/// One request/response exchange; returns the status (nil = no HTTP response, e.g. reset).
func exchange(port: UInt16, _ request: String) throws -> Int? {
    let client = try RawClient(port: port)
    defer { client.close() }
    client.send(request)
    return RawClient.status(client.readAll())
}

func hookRequest(port: UInt16, token: String? = testToken, session: String? = "7c1e9a04-5b2d-4e8f-9a31-0c6d2e4f8b17",
                 host: String? = nil, extraHeaders: [String] = [], body: String = #"{"hook_event_name":"Stop"}"#,
                 method: String = "POST", path: String = "/hooks") -> String {
    var lines = ["\(method) \(path) HTTP/1.1"]
    lines.append("Host: \(host ?? "127.0.0.1:\(port)")")
    if let token { lines.append("X-CODD-Token: \(token)") }
    if let session { lines.append("X-CODD-Session: \(session)") }
    lines.append("Content-Type: application/json")
    lines.append("Content-Length: \(body.utf8.count)")
    lines += extraHeaders
    return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
}

/// A listening TCP socket on 127.0.0.1 that never accepts (connections complete in the kernel
/// backlog and then hang): simulates a stalled endpoint.
final class StalledListener: Sendable {
    let fd: Int32
    let port: UInt16
    private let closed = Mutex(false)

    /// `port` 0 = ephemeral.
    init(port requested: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    /// Idempotent: a second close(2) of a reused descriptor number would close another test's
    /// socket (tests run in parallel in one process).
    func close() {
        let first = closed.withLock { c in
            defer { c = true }
            return !c
        }
        if first { Darwin.close(fd) }
    }

    deinit { close() }
}

/// A port that was free a moment ago (bound, then released).
func freePort() throws -> UInt16 {
    let l = try StalledListener()
    l.close()
    return l.port
}

/// Port sub-ranges below the ephemeral range (49152…), one per kind of use, so a concurrent
/// test's outgoing connection or random pick cannot take a port between a release and a re-bind.
enum TestPorts {
    static let restart: ClosedRange<UInt16> = 41000...41999
    static let occupied: ClosedRange<UInt16> = 42000...42999
    static let runtime: ClosedRange<UInt16> = 43000...43999
    static let closed: ClosedRange<UInt16> = 44000...44999
}

/// A port in `range` that is free right now.
func freeNonEphemeralPort(in range: ClosedRange<UInt16> = TestPorts.closed) -> UInt16 {
    while true {
        let port = UInt16.random(in: range)
        if PortProbe.isAvailable(port) { return port }
    }
}

/// A ``StalledListener`` on a non-ephemeral port.
func occupyNonEphemeralPort() -> StalledListener {
    while true {
        if let l = try? StalledListener(port: freeNonEphemeralPort(in: TestPorts.occupied)) { return l }
    }
}

/// Builds hook payloads.
func payload(_ event: String, session: String = "11111111-aaaa-4aaa-8aaa-111111111111", _ extra: [String: JSONValue] = [:]) -> HookPayload {
    var o: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(session), "cwd": "/synthetic"]
    for (k, v) in extra { o[k] = v }
    return HookPayload(object: o)
}
