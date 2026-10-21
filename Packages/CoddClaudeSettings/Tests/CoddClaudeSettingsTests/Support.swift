import Darwin
import Foundation
@testable import CoddClaudeSettings

/// A unique temp directory, removed by ``remove()``. Every file a test reads or writes lives in
/// one; nothing touches the user's real ~/.claude.
struct TempDir {
    let url: URL

    init(_ label: String = "codd-settings-tests") throws {
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

    var path: String { url.path }

    @discardableResult
    func write(_ name: String, _ text: String, mode: mode_t = 0o644) throws -> URL {
        let target = file(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        chmod(target.path, mode)
        return target
    }
}

enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        String(decoding: try data(name), as: UTF8.self)
    }

    static let roundTripNames = [
        "user-settings.json", "user-settings-4space.json", "tabs-no-newline.json", "unicode.json",
        "nested-empty.json", "empty-object.json", "numbers.json", "allchars.json",
    ]

    /// The hook-tap status line the CODD web wrapper chains, under the temp dir (a fake `~/.hook-tap`).
    static func hookTapStatusLine(_ tmp: TempDir) -> String { "\(tmp.path)/.hook-tap/statusline.sh" }

    /// The synthetic user settings (CODD web hooks on 10 events in both shapes, hook-tap on 12,
    /// two osascript notifications, the CODD web status-line wrapper) with the temp dir filled in.
    static func userSettings(_ tmp: TempDir, fourSpaces: Bool = false) throws -> String {
        let template = try text(fourSpaces ? "user-settings-4space.json" : "user-settings.json")
        let inner = hookTapStatusLine(tmp)
        return template
            .replacingOccurrences(of: "@B64@", with: Data(inner.utf8).base64EncodedString())
            .replacingOccurrences(of: "@TMP@", with: tmp.path)
    }

    static func writeUserSettings(_ tmp: TempDir, name: String = "settings.json", fourSpaces: Bool = false) throws -> URL {
        try tmp.write(name, try userSettings(tmp, fourSpaces: fourSpaces))
    }
}

extension ClaudeSettingsInstaller {
    /// A desktop wrapper under a test data root.
    static func testDesktop(_ tmp: TempDir) -> DesktopStatusLine {
        DesktopStatusLine(dataRoot: "\(tmp.path)/Application Support/CODD")
    }
}

func fileMode(_ path: String) -> mode_t {
    var info = stat()
    return stat(path, &info) == 0 ? info.st_mode & 0o777 : 0
}

func isSymlink(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
}

/// Runs `/bin/sh -c <command>` with `stdin` (from a temp file, so a command that never reads it
/// cannot cause a broken pipe) and returns stdout and the exit status.
func runShell(_ command: String, stdin: String = "") throws -> (output: String, status: Int32) {
    let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("codd-settings-stdin-\(UUID().uuidString)")
    try Data(stdin.utf8).write(to: inputURL)
    defer { try? FileManager.default.removeItem(at: inputURL) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = ["PATH": "/usr/bin:/bin"]
    let output = Pipe()
    process.standardInput = try FileHandle(forReadingFrom: inputURL)
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (String(decoding: data, as: UTF8.self), process.terminationStatus)
}

/// Every handler object in file order with its event, for structural comparisons.
func handlers(in root: OrderedJSON) -> [(event: String, handler: OrderedJSON)] {
    var out: [(event: String, handler: OrderedJSON)] = []
    HookTree.forEachHandler(in: root) { event, members in out.append((event, .object(members))) }
    return out
}

/// `value` pretty-printed and indented as it sits at `level` inside a file with `indent`.
func embedded(_ value: OrderedJSON, indent: String, level: Int) -> String {
    let pad = String(repeating: indent, count: level)
    return pad + value.serialized(indent: indent).replacingOccurrences(of: "\n", with: "\n" + pad)
}

/// True when a hook group (either shape) runs CODD web's status-writer.js.
func containsLegacy(_ group: OrderedJSON) -> Bool {
    let root = OrderedJSON.object([(key: "hooks", value: .object([(key: "E", value: .array([group]))]))])
    return handlers(in: root).contains { HookTree.isLegacy($0.handler.objectMembers ?? []) }
}
