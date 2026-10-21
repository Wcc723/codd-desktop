// zorder-watch <seconds> [owner=CODD] [--exe-prefix <dir>] [--ignore-prefix <dir>]… [--never-ignore-prefix <dir>]…
//              [--watch-pid <pid>]
// Samples the on-screen window stack every 200 ms and reports every moment a window of <owner> sits above a
// normal (layer 0) window of another app. Exit 1 if that ever happened.
//
// Owner: without --exe-prefix every window whose owner NAME is <owner> (so the user's own CODD counts as the
// run's). With --exe-prefix only windows whose owning process runs an executable under that path count (the
// app under test, e.g. `<derived data>/CODD.app/`); the user's own CODD is then an app like any other.
// Windows of processes under an --ignore-prefix (other agents' background test builds and SwiftPM demos,
// ordered back like a test CODD) are neither owner nor other app, unless they are under a
// --never-ignore-prefix (the user's own `build/user-*` builds always count as other apps). Precedence:
// --exe-prefix (owner), then --never-ignore-prefix (other), then --ignore-prefix (ignored). Prefixes are plain
// string prefixes (`<repo>/.build` also covers `.build-core`), compared after realpath and Unicode NFC
// normalization (the repo path contains CJK characters).
// --watch-pid ends the run with the summary once that process is gone, so a watcher whose script died
// does not keep sampling for the rest of its hour.
// Line-buffered output (a redirected log shows every line at once); SIGINT / SIGTERM end the run early
// with the summary line, so a stopped watch still reports what it saw.
import CoreGraphics
import Darwin
import Foundation

setlinebuf(stdout)

func usage(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("zorder-watch: \(message)\n" +
        "usage: zorder-watch <seconds> [owner] [--exe-prefix <dir>] [--ignore-prefix <dir>]... " +
        "[--never-ignore-prefix <dir>]... [--watch-pid <pid>]\n").utf8))
    exit(64)
}

/// realpath of the longest existing ancestor with the rest appended, NFC normalized. A prefix such as
/// `<repo>/build/user-` names no file, and a trailing slash is kept so `CODD.app/` never matches `CODD.app2`.
func normalizedPrefix(_ path: String) -> String {
    let trailingSlash = path.count > 1 && path.hasSuffix("/")
    var head = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    while head.count > 1 && head.hasSuffix("/") { head.removeLast() }
    var rest: [String] = []
    var resolved = ""
    while true {
        if let real = realpath(head, nil) {
            resolved = String(cString: real)
            free(real)
            break
        }
        let parent = (head as NSString).deletingLastPathComponent
        if parent == head || parent.isEmpty { resolved = head; break }
        rest.insert((head as NSString).lastPathComponent, at: 0)
        head = parent
    }
    for component in rest { resolved += (resolved.hasSuffix("/") ? "" : "/") + component }
    if trailingSlash && !resolved.hasSuffix("/") { resolved += "/" }
    return resolved.precomposedStringWithCanonicalMapping
}

var positional: [String] = []
var exePrefix: String?
var ignorePrefixes: [String] = []
var neverIgnorePrefixes: [String] = []
var watchPid: pid_t?
var argIndex = 1
let argv = CommandLine.arguments
while argIndex < argv.count {
    let arg = argv[argIndex]
    func value() -> String {
        guard argIndex + 1 < argv.count else { usage("\(arg) needs a value") }
        argIndex += 1
        return argv[argIndex]
    }
    switch arg {
    case "--exe-prefix": exePrefix = normalizedPrefix(value())
    case "--ignore-prefix": ignorePrefixes.append(normalizedPrefix(value()))
    case "--never-ignore-prefix": neverIgnorePrefixes.append(normalizedPrefix(value()))
    case "--watch-pid":
        guard let pid = pid_t(value()), pid > 0 else { usage("--watch-pid needs a process id") }
        watchPid = pid
    case "-h", "--help": usage("help")
    default:
        if arg.hasPrefix("--") { usage("unknown option \(arg)") }
        positional.append(arg)
    }
    argIndex += 1
}
guard positional.count <= 2 else { usage("too many arguments") }
let seconds = Double(positional.first ?? "30") ?? 30
let owner = positional.count > 1 ? positional[1] : "CODD"
let byExecutable = exePrefix != nil

enum Kind { case owner, other, ignored }

/// Classifies a window's process (see the header for the precedence). A class rather than global
/// functions over the top-level state, so the file compiles in Swift 5 and Swift 6 language modes.
final class Classifier {
    let owner: String
    let exePrefix: String?
    let ignorePrefixes: [String]
    let neverIgnorePrefixes: [String]
    /// Raw kernel path -> normalized path (realpath once per distinct path).
    private var resolvedPaths: [String: String] = [:]

    init(owner: String, exePrefix: String?, ignorePrefixes: [String], neverIgnorePrefixes: [String]) {
        self.owner = owner
        self.exePrefix = exePrefix
        self.ignorePrefixes = ignorePrefixes
        self.neverIgnorePrefixes = neverIgnorePrefixes
    }

    /// Whether classifying needs the process path at all (the plain name mode does not).
    var needsPaths: Bool { exePrefix != nil || !ignorePrefixes.isEmpty }

    /// NFC normalized executable path of a process (nil when it cannot be read, e.g. another user's).
    func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let raw = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        if let known = resolvedPaths[raw] { return known }
        let resolved = normalizedPrefix(raw)
        resolvedPaths[raw] = resolved
        return resolved
    }

    func kind(name: String, path: String?) -> Kind {
        if let exePrefix {
            if let path, path.utf8.starts(with: exePrefix.utf8) { return .owner }
        } else if name == owner {
            return .owner
        }
        guard let path else { return .other }
        if Self.under(path, neverIgnorePrefixes) { return .other }
        if Self.under(path, ignorePrefixes) { return .ignored }
        return .other
    }

    private static func under(_ path: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { path.utf8.starts(with: $0.utf8) }
    }
}
let classifier = Classifier(owner: owner, exePrefix: exePrefix, ignorePrefixes: ignorePrefixes,
                            neverIgnorePrefixes: neverIgnorePrefixes)

let end = Date().addingTimeInterval(seconds)
nonisolated(unsafe) var stopSignal: sig_atomic_t = 0
signal(SIGINT) { _ in stopSignal = 1 }
signal(SIGTERM) { _ in stopSignal = 1 }
var start = "zorder start seconds=\(Int(seconds)) owner=\(owner) pid=\(getpid())"
if let exePrefix { start += " exe-prefix=\(exePrefix)" }
if !ignorePrefixes.isEmpty || !neverIgnorePrefixes.isEmpty {
    start += " ignore=\(ignorePrefixes.count) never-ignore=\(neverIgnorePrefixes.count)"
}
if let watchPid { start += " watch-pid=\(watchPid)" }
print(start)
var samples = 0, violations = 0, sawOwner = 0
var ignoredPids = Set<pid_t>(), ownerPids = Set<pid_t>()
var watchedGone = false
while Date() < end, stopSignal == 0 {
    if let watchPid, kill(watchPid, 0) != 0, errno == ESRCH {
        watchedGone = true
        break
    }
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
    // Front to back; layer 0 only (status items, menus and the Dock are other layers).
    var windows: [(kind: Kind, label: String)] = []
    for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
        let name = info[kCGWindowOwnerName as String] as? String ?? "?"
        let pid = (info[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } ?? 0
        let path = pid > 0 && classifier.needsPaths ? classifier.executablePath(pid) : nil
        let k = classifier.kind(name: name, path: path)
        switch k {
        case .ignored:
            if ignoredPids.insert(pid).inserted, ignoredPids.count <= 20 {
                print("IGNORED pid=\(pid) \(name) \(path ?? "?")")
            }
            continue
        case .owner:
            if byExecutable, ownerPids.insert(pid).inserted, ownerPids.count <= 20 {
                print("OWNER pid=\(pid) \(path ?? "?")")
            }
        case .other:
            break
        }
        windows.append((k, byExecutable ? "\(name)[\(pid)]" : name))
    }
    if let first = windows.firstIndex(where: { $0.kind == .owner }) {
        sawOwner += 1
        let above = windows[first...].dropFirst().filter { $0.kind == .other }.map(\.label)
        if !above.isEmpty {
            violations += 1
            if violations <= 20 {
                print("ABOVE \(ISO8601DateFormatter().string(from: Date())): \(owner) window above \(Set(above).sorted().joined(separator: ", "))")
            }
        }
    }
    samples += 1
    usleep(200_000)
}
let stopped = stopSignal != 0 ? " stopped=signal" : watchedGone ? " stopped=watch-pid" : ""
print("zorder samples=\(samples) withOwner=\(sawOwner) violations=\(violations) ignored=\(ignoredPids.count)" + stopped)
exit(violations > 0 ? 1 : 0)
