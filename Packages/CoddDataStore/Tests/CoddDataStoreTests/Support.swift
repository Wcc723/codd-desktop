import Darwin
import Foundation
@testable import CoddDataStore

/// A unique data root under the temp folder, removed by ``remove()``. Nothing a test does touches
/// the user's real data root.
struct TempRoot {
    let url: URL

    init(_ label: String = "codd-datastore") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    func path(_ relative: String) -> String {
        url.appendingPathComponent(relative).path
    }

    @discardableResult
    func write(_ relative: String, _ text: String, mode: mode_t = 0o600) throws -> String {
        try write(relative, Data(text.utf8), mode: mode)
    }

    @discardableResult
    func write(_ relative: String, _ data: Data, mode: mode_t = 0o600) throws -> String {
        let target = path(relative)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: target))
        chmod(target, mode)
        return target
    }

    func read(_ relative: String) -> Data? {
        FileManager.default.contents(atPath: path(relative))
    }

    struct NotAnObject: Error {}

    /// The file parsed as a JSON object.
    func jsonObject(_ relative: String) throws -> [String: Any] {
        guard let data = read(relative), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotAnObject()
        }
        return object
    }

    func exists(_ relative: String) -> Bool {
        var info = stat()
        return lstat(path(relative), &info) == 0
    }

    func mode(_ relative: String) -> mode_t {
        var info = stat()
        return lstat(path(relative), &info) == 0 ? info.st_mode & 0o777 : 0
    }

    /// Every entry below the root (relative paths, links not followed), with its bytes for files.
    func snapshot() -> [String: Data?] {
        var out: [String: Data?] = [:]
        guard let walker = FileManager.default.enumerator(atPath: url.path) else { return out }
        while let relative = walker.nextObject() as? String {
            var info = stat()
            guard lstat(path(relative), &info) == 0 else { continue }
            out[relative] = (info.st_mode & S_IFMT) == S_IFREG ? read(relative) : nil
        }
        return out
    }

    /// Names in the folder of `relative` (or the root) that start with `prefix`.
    func names(in folder: String = "", prefix: String) -> [String] {
        let dir = folder.isEmpty ? url.path : path(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
    }
}

/// Collects the preflight's log lines.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var sink: @Sendable (String) -> Void {
        { [self] line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}

enum Fixture {
    /// A fixed moment in October 2026 (aside and backup names derive from it).
    static let now = Date(timeIntervalSince1970: 1_792_285_323)
    static let session = "0f3a1c2e-1111-4a4a-8b8b-123456789abc"

    /// Each inventoried file in the exact shape its store writes (docs/ARCHITECTURE.md "Data root").
    static let storeShapes: [String: String] = [
        "layout.json": """
        {
          "groups" : [
            {
              "collapsed" : false,
              "color" : "blue",
              "id" : "8C1B2D3E-0000-4000-8000-000000000001",
              "name" : "未分類",
              "projects" : [

              ]
            }
          ],
          "version" : 1
        }
        """,
        "panes.json": """
        {
          "sessions" : {
            "\(session)" : {
              "composerOpen" : true,
              "panelMaximized" : false,
              "selected" : "claude",
              "tabs" : [

              ]
            }
          },
          "version" : 1
        }
        """,
        "preferences.json": """
        {
          "general" : {
            "launchAtLogin" : false
          },
          "version" : 1
        }
        """,
        "profiles.json": """
        {
          "defaultProfileId" : "claude",
          "profiles" : [
            {
              "environment" : {

              },
              "extraArguments" : [

              ],
              "id" : "claude",
              "kind" : "claude",
              "name" : "Claude"
            }
          ],
          "version" : 1
        }
        """,
        "cleanup.json": """
        {
          "digest" : {

          },
          "files" : {

          },
          "retention" : {
            "firstRunAt" : "2026-10-18T01:02:03Z"
          },
          "sessions" : {

          },
          "v" : 1
        }

        """,
        "claude-settings-backups.json": """
        {
          "backups" : [
            {
              "at" : "2026-10-17T02:42:10.000Z",
              "name" : "settings.json.codd-bak-20261017-104210",
              "reason" : "更新 hooks 與 statusline",
              "settingsPath" : "~/.claude/settings.json"
            }
          ],
          "v" : 1
        }
        """,
        "files/recent.json": #"{"items":[{"openedAt":"2026-10-18T01:02:03.000Z","path":"/tmp/x/a.md"}],"v":1}"#,
        "files/ai-touches.json": #"{"items":[],"v":1}"#,
        "onboarding.json": #"{"appVersion":"1.0.0","build":"12","completedAt":"2026-10-18T01:02:03Z","v":1}"#,
        "sessions/\(session)/composer.json": #"{"draft":"還沒送出","history":{"entries":["修正登入 API 401"]},"v":1}"#,
        "notes/.codd/notebook.json": "{\"v\":1,\"createdAt\":\"2026-10-18T09:02:03+08:00\"}\n",
        "notes/.codd/state.json": "{\"v\":1,\"notes\":{}}\n",
        "notes/.codd/tombstones.json": "{\"v\":1,\"items\":[]}\n",
        "config.json": """
        {
          "mcpToken" : "\(String(repeating: "b", count: 64))",
          "port" : 47821,
          "token" : "\(String(repeating: "a", count: 64))",
          "v" : 1
        }

        """,
        "quota.json": #"{"accounts":{},"autoSwitch":{},"v":1}"#,
        "hooks/\(session).json": #"{"sessionId":"x","state":"idle"}"#,
        "sessions/\(session)/answer.json": #"{"tool":"Bash","summary":"ls"}"#,
    ]

    /// The inventory row of `pattern`.
    static func spec(_ pattern: String) -> DataFileSpec {
        DataInventory.all.first { $0.pattern == pattern }!
    }

    /// A concrete path for a pattern (one session, one hook record).
    static func path(for pattern: String) -> String {
        pattern.replacingOccurrences(of: "sessions/*/", with: "sessions/\(session)/")
            .replacingOccurrences(of: "hooks/*.json", with: "hooks/\(session).json")
    }

    /// A JSON object with the version member set (or left out when `version` is nil).
    static func object(key: String?, version: String?) -> String {
        guard let key, let version else { return #"{"payload":"x"}"# }
        return #"{"payload":"x","\#(key)":\#(version)}"#
    }

    static func preflight(_ root: TempRoot, registry: MigrationRegistry = .standard, maxFileBytes: Int = DataPreflight.maxFileBytes,
                          now: Date = Fixture.now, log: LogLines? = nil) -> DataPreflight {
        var sink: @Sendable (String) -> Void = { _ in }
        if let log { sink = log.sink }
        return DataPreflight(root: root.url, registry: registry, maxFileBytes: maxFileBytes, now: { now }, log: sink)
    }
}
