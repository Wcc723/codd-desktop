import Darwin
import Foundation
import Synchronization
import Testing
@testable import CoddFiles

/// A fresh temp directory (symlinks resolved, so paths compare with what git and FSEvents report),
/// removed when the value goes away.
final class TempDir: Sendable {
    let url: URL

    init(_ label: String = "codd-files") {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        let dir = base.appendingPathComponent("\(label)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let real = realpath(dir.path, nil).map { p -> String in
            defer { free(p) }
            return String(cString: p)
        } ?? dir.path
        url = URL(fileURLWithPath: real, isDirectory: true)
    }

    deinit { remove() }

    /// Removes the folder now. Tests with big trees call it before returning: a deinit that runs
    /// after the last test finished can race the test process's exit and leave files behind.
    func remove() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Read-only test files and folders must not stop the cleanup.
        _ = try? Shell.run("/bin/chmod", ["-R", "u+w", url.path])
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ relative: String) -> URL { url.appendingPathComponent(relative) }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        try write(relative, Data(text.utf8))
    }

    @discardableResult
    func write(_ relative: String, _ data: Data) throws -> URL {
        let target = file(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
        return target
    }
}

/// Synchronous child processes for test setup (git commits, chmod). Not the code under test.
enum Shell {
    struct Failure: Error, CustomStringConvertible {
        var command: String
        var status: Int32
        var output: String
        var description: String { "\(command) exited \(status): \(output)" }
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw Failure(command: ([executable] + arguments).joined(separator: " "), status: process.terminationStatus, output: text)
        }
        return text
    }
}

/// A git work tree built by the test. Every git run (the test's and the reader's) uses an isolated
/// configuration: `GIT_CONFIG_GLOBAL` = an empty file, `GIT_CONFIG_NOSYSTEM=1`, and
/// `-c core.fsmonitor=false`, so the user's own git config never applies and no fsmonitor daemon
/// starts.
struct TestRepo {
    let dir: TempDir
    let root: URL
    let globalConfig: URL

    init(_ name: String = "repo", in dir: TempDir = TempDir("codd-git")) throws {
        self.dir = dir
        root = dir.url.appendingPathComponent(name, isDirectory: true)
        globalConfig = dir.url.appendingPathComponent("empty-gitconfig")
        FileManager.default.createFile(atPath: globalConfig.path, contents: Data())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
    }

    /// The isolation variables (also handed to `GitReader(environment:)`).
    var isolation: [String: String] {
        ["GIT_CONFIG_GLOBAL": globalConfig.path, "GIT_CONFIG_NOSYSTEM": "1"]
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        for (key, value) in isolation { env[key] = value }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        return env
    }

    func reader(timeout: Duration = .seconds(5), log: @escaping @Sendable (String) -> Void = { _ in }) -> GitReader {
        GitReader(timeout: timeout, environment: isolation, log: log)
    }

    @discardableResult
    func git(_ arguments: String..., in folder: URL? = nil) throws -> String {
        try gitArgs(arguments, in: folder)
    }

    @discardableResult
    func gitArgs(_ arguments: [String], in folder: URL? = nil) throws -> String {
        let base = ["-C", (folder ?? root).path, "-c", "user.name=t", "-c", "user.email=t@localhost", "-c", "commit.gpgsign=false",
                    "-c", "core.fsmonitor=false"]
        return try Shell.run("/usr/bin/git", base + arguments, environment: environment)
    }

    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let target = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: target)
        return target
    }

    func commitAll(_ message: String) throws {
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
    }

    /// The index's identity (inode, size, mtime in ns): unchanged ⇔ git did not rewrite it.
    func indexStamp() -> String {
        var st = stat()
        guard stat(root.appendingPathComponent(".git/index").path, &st) == 0 else { return "missing" }
        return "\(st.st_ino)/\(st.st_size)/\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }
}

/// Collects values from an async stream on a background task; tests poll it.
final class Collector<Value: Sendable>: Sendable {
    private let values = Mutex<[Value]>([])
    private let task: Mutex<Task<Void, Never>?> = Mutex(nil)

    init(_ stream: AsyncStream<Value>) {
        let consumer = Task { [self] in
            for await value in stream { self.values.withLock { $0.append(value) } }
        }
        task.withLock { $0 = consumer }
    }

    var all: [Value] { values.withLock { $0 } }
    var count: Int { values.withLock { $0.count } }

    func stop() { task.withLock { $0?.cancel() } }

    /// Waits until `condition` holds for the collected values (polling), up to `timeout`.
    @discardableResult
    func wait(timeout: Duration = .seconds(5), _ condition: ([Value]) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition(all) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(all)
    }
}

/// Lines a test logger received.
final class LogLines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    var sink: @Sendable (String) -> Void { { [self] line in self.lines.withLock { $0.append(line) } } }
}

/// `ps` command lines of every process right now.
func processCommandLines() -> [String] {
    ((try? Shell.run("/bin/ps", ["-axo", "command"])) ?? "").split(separator: "\n").map(String.init)
}
