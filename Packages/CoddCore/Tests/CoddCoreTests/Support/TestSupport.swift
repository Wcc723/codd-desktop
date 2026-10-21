import Foundation
@testable import CoddCore

enum FixtureError: Error {
    case missing(String)
    case malformed(String)
}

/// Access to the bundled fixture directories (`hooks`, `registry`, `cswap`).
enum Fixtures {
    static func directory(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil) else { throw FixtureError.missing(name) }
        return url
    }

    static func data(_ dir: String, _ file: String) throws -> Data {
        try Data(contentsOf: directory(dir).appendingPathComponent(file))
    }

    static func json(_ dir: String, _ file: String) throws -> JSONValue {
        guard let v = JSONValue.parse(try data(dir, file)) else { throw FixtureError.malformed(file) }
        return v
    }
}

/// A unique temp directory, removed by ``remove()``.
struct TempDir {
    let url: URL

    init(_ label: String = "codd-core-tests") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }
}

extension JSONValue {
    /// Object member lookup that throws (for fixture parsing in tests).
    func require(_ key: String) throws -> JSONValue {
        guard let v = self[key] else { throw FixtureError.malformed("missing \(key)") }
        return v
    }
}

/// Encodes any Encodable and re-parses it as a ``JSONValue`` (order-insensitive comparison).
func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    guard let v = JSONValue.parse(data) else { throw FixtureError.malformed("encode") }
    return v
}

/// Removes keys from an object value (for comparing modulo extension fields).
func removingKeys(_ keys: Set<String>, from value: JSONValue?) -> JSONValue? {
    guard case .object(var o)? = value else { return value }
    for k in keys { o[k] = nil }
    return .object(o)
}

/// Fixed reference time used across tests: 2026-10-15T02:42:00Z (10:42 in Taipei, SPEC §5 "now").
let referenceNow = JSDate.date(milliseconds: 1_792_032_120_000)

/// A recording fake ``CommandRunner``.
final class FakeRunner: CommandRunner, @unchecked Sendable {
    typealias Handler = @Sendable (CommandInvocation) async throws -> CommandResult
    private let lock = NSLock()
    private var _invocations: [CommandInvocation] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    convenience init(stdout: Data, status: Int32 = 0, stderr: Data = Data()) {
        self.init { _ in CommandResult(status: status, stdout: stdout, stderr: stderr) }
    }

    var invocations: [CommandInvocation] {
        lock.withLock { _invocations }
    }

    func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        lock.withLock { _invocations.append(invocation) }
        return try await handler(invocation)
    }
}
