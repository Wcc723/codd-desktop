import Foundation
import Testing
@testable import CoddPreferences

/// A unique temp directory, removed by ``remove()``.
struct TempDir {
    let url: URL

    init(_ label: String = "codd-prefs-tests") throws {
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

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }
}

func withStore<T>(_ body: (PreferencesStore, TempDir) throws -> T) throws -> T {
    let temp = try TempDir()
    defer { temp.remove() }
    return try body(PreferencesStore(url: temp.file(PreferencesStore.fileName)), temp)
}

/// The defaults as a mutable JSON tree, for building files with one field changed.
func defaultsObject() throws -> [String: Any] {
    let data = try JSONEncoder().encode(CoddPreferences.defaults)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Sets `value` at the dotted `path` of a JSON tree (creating objects on the way).
func setting(_ object: [String: Any], _ path: String, _ value: Any?) -> [String: Any] {
    var parts = path.split(separator: ".").map(String.init)
    let key = parts.removeFirst()
    var copy = object
    if parts.isEmpty {
        copy[key] = value ?? NSNull()
    } else {
        copy[key] = setting(object[key] as? [String: Any] ?? [:], parts.joined(separator: "."), value)
    }
    return copy
}

func lookup(_ object: [String: Any], _ path: String) -> Any? {
    var current: Any? = object
    for part in path.split(separator: ".") {
        current = (current as? [String: Any])?[String(part)]
    }
    return current
}

func write(_ object: [String: Any], to url: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
}

func readObject(_ url: URL) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

func fileMode(_ url: URL) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attrs[.posixPermissions] as? Int)
}
