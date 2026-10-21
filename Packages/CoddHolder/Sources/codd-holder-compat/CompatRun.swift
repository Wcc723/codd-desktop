import CoddHolderClient
import CoddProtocol
import Darwin

/// The docs/M5-PLAN.md §2.9 checks against one holder binary, in order, with the CURRENT client
/// code only (`HolderSpawner`, `SessionDirectory`, `HolderStream`, `RingFileReader`): spawn, meta,
/// welcome, stream, input, resize, reattach, paste, ring, stop. Each prints one
/// `COMPAT <label> <check> ok|FAIL <detail>` line; a check whose prerequisite failed prints FAIL
/// `not run`. The holder and its child are ended whatever happened.
final class CompatRun {
    struct Options {
        var holder: String
        var root: String
        var label: String
    }

    /// Every check finishes (or fails) within this (plan: at most 10 s per step).
    static let stepTimeoutMilliseconds: UInt64 = 10_000
    /// Longer than every step plus the cleanup; the emergency handler ends the run after it.
    static let watchdogSeconds = 150
    static let clientName = "codd-holder-compat/0.1"
    static let session = "compat"

    /// `HolderOptions.parse` `known` at 37a9388 (M1), unchanged through M4: the spawn uses no other
    /// flag, so the current `HolderLaunch` must stay inside it for old holders.
    static let m1HolderFlags: Set<String> = [
        "--session", "--dir", "--socket", "--cols", "--rows", "--cwd", "--ring-size", "--env-file",
        "--exit-linger-ms", "--log", "--flow-limit",
    ]

    /// The child: bracketed paste on BEFORE the ready marker (the paste check relies on WELCOME /
    /// ATTACHED modes with ?2004 on), a WINCH trap printing `stty size`, and input lines echoed as
    /// `got:<line>`. The reader runs in the background on a copy of the tty (an asynchronous list
    /// gets /dev/null as stdin) because bash 3.2 (/bin/sh) runs traps only after a `read` builtin
    /// returns, while `wait` is interrupted by a trapped signal in every POSIX shell.
    static let childScript = """
        trap 'stty size' WINCH
        printf '\\033[?2004h'
        printf 'compat-ready\\n'
        exec 3<&0
        while IFS= read -r line <&3; do printf 'got:%s\\n' "$line"; done &
        reader=$!
        while kill -0 "$reader" 2>/dev/null; do wait "$reader"; done
        """

    static let readyMarker = Array("compat-ready".utf8)
    static let bracketedPasteOn = Array("\u{1B}[?2004h".utf8)
    static let inputText = Array("compat-input".utf8)
    static let pasteText = Array("compat-paste".utf8)
    /// What the child prints for the input line (ONLCR turns its `\n` into `\r\n`).
    static let inputEcho = Array("got:compat-input\r\n".utf8)
    /// The paste must reach the child bracketed, whoever brackets it.
    static let pasteEcho = Array("got:".utf8) + BracketedPaste.startMarker + pasteText + BracketedPaste.endMarker
        + Array("\r\n".utf8)
    static let resizedSize = WindowSize(cols: 100, rows: 30)
    static let resizeEcho = Array("30 100".utf8)

    let options: Options
    private var label: String { options.label }
    private var root: String { options.root }
    private var sessionDirectory: String { root + "/sessions/" + Self.session }
    private var socketPath: String { root + "/run/s.sock" }
    private var environmentPath: String { root + "/env" }
    private var logPath: String { root + "/holder.log" }
    private var stderrPath: String { root + "/holder.stderr" }

    private var results: [(name: String, ok: Bool)] = []
    private var stepDeadline: UInt64 = 0

    private var holderPid: pid_t = 0
    private var holderReaped = false
    private var holderWaitStatus: Int32?
    private var childPid: pid_t = 0
    private var welcome: Welcome?
    private var first: (stream: HolderStream, recorder: StreamRecorder)?
    private var second: (stream: HolderStream, recorder: StreamRecorder)?

    init(_ options: Options) {
        self.options = options
    }

    /// Runs every check, ends the holder and child, and returns whether all passed.
    func run() -> Bool {
        check("spawn", spawn)
        check("meta", requires: ["spawn"], checkMeta)
        check("welcome", requires: ["spawn"], checkWelcome)
        check("stream", requires: ["welcome"], checkStream)
        check("input", requires: ["stream"], checkInput)
        check("resize", requires: ["stream"], checkResize)
        check("reattach", requires: ["spawn"], checkReattach)
        check("paste", requires: ["spawn"], checkPaste)
        check("ring", requires: ["spawn"], checkRing)
        check("stop", requires: ["spawn"], checkStop)
        cleanUp()
        return results.allSatisfy(\.ok)
    }

    // MARK: - Runner

    private func passed(_ name: String) -> Bool {
        results.contains { $0.name == name && $0.ok }
    }

    private func check(_ name: String, requires: [String] = [], _ body: () throws(CheckFailure) -> String) {
        let missing = requires.filter { !passed($0) }
        guard missing.isEmpty else {
            record(name, ok: false, "not run: needs \(missing.joined(separator: ", "))")
            return
        }
        let started = Monotonic.milliseconds()
        stepDeadline = started + Self.stepTimeoutMilliseconds
        do throws(CheckFailure) {
            let detail = try body()
            record(name, ok: true, "\(detail) (\(Monotonic.milliseconds() - started) ms)")
        } catch {
            record(name, ok: false, "\(error.detail) (\(Monotonic.milliseconds() - started) ms)")
        }
    }

    private func record(_ name: String, ok: Bool, _ detail: String) {
        results.append((name, ok))
        Report.line("COMPAT \(label) \(name) \(ok ? "ok" : "FAIL") \(Report.singleLine(detail))")
    }

    /// Polls within the current step's deadline (and `timeoutMilliseconds`, if shorter).
    @discardableResult
    private func waitUntil(_ timeoutMilliseconds: Int? = nil, _ condition: () -> Bool) -> Bool {
        var deadline = stepDeadline
        if let timeoutMilliseconds { deadline = min(deadline, Monotonic.milliseconds() + UInt64(timeoutMilliseconds)) }
        return Monotonic.poll(until: deadline, condition)
    }

    private var remainingMilliseconds: Int {
        let now = Monotonic.milliseconds()
        return now < stepDeadline ? Int(stepDeadline - now) : 0
    }

    /// Waits for `needle` in the stream's bytes from index `mark` on.
    private func waitForBytes(_ needle: [UInt8], in recorder: StreamRecorder, from mark: Int, what: String) throws(CheckFailure) {
        waitUntil { recorder.read { Bytes.contains(needle, in: $0.bytes, from: mark) || $0.closed != nil } }
        let state = recorder.snapshot
        if Bytes.contains(needle, in: state.bytes, from: mark) { return }
        let after = Bytes.excerpt(state.bytes[min(mark, state.bytes.count)...])
        if let closed = state.closed {
            throw CheckFailure("stream closed (\(closed)) before \(what) \(Bytes.excerpt(needle)); got \(after)")
        }
        throw CheckFailure("no \(what) \(Bytes.excerpt(needle)) within the step timeout; got \(after)")
    }

    // MARK: - Checks

    /// HolderSpawner with only M1 flags and `--exit-linger-ms 500`; the socket must accept.
    private func spawn() throws(CheckFailure) -> String {
        let socketBytes = socketPath.utf8.count
        guard socketBytes < 104 else {
            throw CheckFailure("socket path is \(socketBytes) bytes (sun_path holds 103); use a shorter --root")
        }
        guard access(options.holder, X_OK) == 0 else {
            throw CheckFailure("\(options.holder) is not executable: \(Files.errnoText())")
        }
        // A predictable child environment (the holder gives the child exactly this list).
        let environment = [
            "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TERM=xterm-256color", "LANG=en_US.UTF-8", "LC_CTYPE=UTF-8",
            "HOME=\(root)",
        ]
        guard Files.write(environmentPath, environment.flatMap { Array($0.utf8) + [0] }) else {
            throw CheckFailure("cannot write \(environmentPath): \(Files.errnoText())")
        }
        let launch = HolderLaunch(
            holderExecutable: options.holder, session: Self.session, sessionDirectory: sessionDirectory,
            socketPath: socketPath, cols: 80, rows: 24, cwd: root, envFile: environmentPath,
            exitLingerMilliseconds: 500, logPath: logPath, argv: ["/bin/sh", "-c", Self.childScript])
        let flags = launch.arguments.dropFirst().prefix { $0 != "--" }.filter { $0.hasPrefix("--") }
        let unknown = flags.filter { !Self.m1HolderFlags.contains($0) }
        guard unknown.isEmpty else {
            throw CheckFailure("HolderLaunch uses flags the M1 holder does not know: \(unknown.joined(separator: " "))")
        }
        let pid: pid_t
        do {
            pid = try HolderSpawner.spawn(launch, stderrPath: stderrPath)
        } catch {
            throw CheckFailure("HolderSpawner.spawn: \(error)")
        }
        holderPid = pid
        Emergency.shared.holderPid.store(pid, ordering: .releasing)
        guard HolderSpawner.waitForSocket(socketPath, timeoutMilliseconds: remainingMilliseconds, pid: pid) else {
            var reason = "socket did not accept connections"
            if reapHolder(), let status = holderWaitStatus { reason = "holder ended (\(describeWaitStatus(status)))" }
            // Usage errors go to stderr; later startup failures to --log.
            var output = Files.head(stderrPath)
            if output.isEmpty { output = Files.head(logPath) }
            throw CheckFailure("\(reason); holder said \(Bytes.excerpt(output.prefix { $0 != 0x0A }, limit: 300))")
        }
        return "pid=\(pid) flags=\(flags.joined(separator: ","))"
    }

    /// meta.json v1 through `SessionDirectory.list` (the app's discovery path), holder alive.
    private func checkMeta() throws(CheckFailure) -> String {
        var record: SessionRecord?
        waitUntil(5_000) {
            record = (try? SessionDirectory.list(root: root + "/sessions"))?.first { $0.meta.session == Self.session }
            return record != nil
        }
        guard let record else { throw CheckFailure("SessionDirectory.list found no meta.json for session \(Self.session)") }
        let meta = record.meta
        if meta.childPid > 0 {
            childPid = meta.childPid
            Emergency.shared.childPid.store(meta.childPid, ordering: .releasing)
        }
        var problems: [String] = []
        if meta.version != HolderMeta.currentVersion { problems.append("v=\(meta.version)") }
        if meta.holderPid != holderPid { problems.append("holderPid=\(meta.holderPid), spawned \(holderPid)") }
        if meta.childPid <= 0 { problems.append("childPid=\(meta.childPid)") }
        if meta.cols != 80 || meta.rows != 24 { problems.append("size \(meta.cols)x\(meta.rows), expected 80x24") }
        if meta.exited || meta.holderExited { problems.append("exited=\(meta.exited) holderExited=\(meta.holderExited)") }
        if !record.holderAlive { problems.append("SessionDirectory says the holder is not live") }
        guard problems.isEmpty else { throw CheckFailure(problems.joined(separator: "; ")) }
        return "v=\(meta.version) holder=\(meta.holderVersion) childPid=\(meta.childPid) ringSize=\(meta.ringSize) live"
    }

    private func connect() throws(CheckFailure) -> (stream: HolderStream, recorder: StreamRecorder) {
        let stream: HolderStream
        do {
            stream = try HolderStream(socketPath: socketPath, clientName: Self.clientName)
        } catch {
            throw CheckFailure("HolderStream: \(error)")
        }
        return (stream, StreamRecorder(stream))
    }

    /// HELLO with the client's default caps plus ATTACH latest in one write; WELCOME proto 1.
    private func checkWelcome() throws(CheckFailure) -> String {
        let connection = try connect()
        first = connection
        connection.stream.start(takeover: false, attachFrom: .latestResync)
        waitUntil { connection.recorder.read { $0.welcome != nil || $0.closed != nil } }
        let state = connection.recorder.snapshot
        guard let welcome = state.welcome else {
            throw CheckFailure("no WELCOME: \(state.closed.map { "\($0)" } ?? "timeout")")
        }
        self.welcome = welcome
        if childPid == 0, welcome.childPid > 0 {
            childPid = welcome.childPid
            Emergency.shared.childPid.store(welcome.childPid, ordering: .releasing)
        }
        var problems: [String] = []
        if welcome.proto != 1 { problems.append("proto=\(welcome.proto)") }
        if welcome.caps.isEmpty { problems.append("no caps") }
        if welcome.session != Self.session { problems.append("session=\(welcome.session)") }
        if !(welcome.ringStart <= welcome.resync && welcome.resync <= welcome.ringEnd) {
            problems.append("resync \(welcome.resync) outside [\(welcome.ringStart), \(welcome.ringEnd)]")
        }
        if let pid = welcome.holderPid, pid != holderPid { problems.append("holderPid=\(pid)") }
        if welcome.exited { problems.append("child already exited") }
        let summary = "proto=\(welcome.proto) holder=\(welcome.holder) caps=\(welcome.caps.joined(separator: ",")) "
            + "ringStart=\(welcome.ringStart) ringEnd=\(welcome.ringEnd) resync=\(welcome.resync)"
        guard problems.isEmpty else { throw CheckFailure(problems.joined(separator: "; ") + "; " + summary) }
        return summary
    }

    /// The child's ESC[?2004h, then compat-ready, contiguous from the attach start.
    private func checkStream() throws(CheckFailure) -> String {
        guard let recorder = first?.recorder else { throw CheckFailure("no stream") }
        waitUntil {
            recorder.read { (!$0.attaches.isEmpty && Bytes.contains(Self.readyMarker, in: $0.bytes)) || $0.closed != nil }
        }
        let state = recorder.snapshot
        guard let attach = state.attaches.first else {
            throw CheckFailure("no attach took effect: \(state.closed.map { "\($0)" } ?? "timeout")")
        }
        guard let readyAt = Bytes.firstIndex(of: Self.readyMarker, in: state.bytes) else {
            throw CheckFailure("no compat-ready; got \(Bytes.excerpt(state.bytes))")
        }
        var problems: [String] = []
        if let modeAt = Bytes.firstIndex(of: Self.bracketedPasteOn, in: state.bytes) {
            if modeAt > readyAt { problems.append("ESC[?2004h after compat-ready") }
        } else {
            problems.append("ESC[?2004h missing before compat-ready")
        }
        if !attach.acknowledged { problems.append("no ATTACHED (attach.ack)") }
        if let welcome, attach.start != welcome.resync {
            problems.append("attach start \(attach.start) != WELCOME resync \(welcome.resync)")
        }
        if state.discontinuities > 0 { problems.append("\(state.discontinuities) OUTPUT discontinuities") }
        if !state.gaps.isEmpty { problems.append("\(state.gaps.count) GAP") }
        if let closed = state.closed { problems.append("stream closed: \(closed)") }
        let summary = "attach start=\(attach.start) replayEnd=\(attach.replayEnd) ack=\(attach.acknowledged) bytes=\(state.bytes.count)"
        guard problems.isEmpty else { throw CheckFailure(problems.joined(separator: "; ") + "; " + summary) }
        return summary + " in order"
    }

    /// INPUT with submit: the child echoes got:<line>.
    private func checkInput() throws(CheckFailure) -> String {
        guard let (stream, recorder) = first else { throw CheckFailure("no stream") }
        let mark = recorder.read { $0.bytes.count }
        let sent = Monotonic.milliseconds()
        do {
            try stream.sendInput(Self.inputText, submit: true)
        } catch {
            throw CheckFailure("sendInput: \(error)")
        }
        try waitForBytes(Self.inputEcho, in: recorder, from: mark, what: "echo")
        return "got:compat-input after \(Monotonic.milliseconds() - sent) ms"
    }

    /// RESIZE 100x30: the child's WINCH trap prints `30 100`.
    private func checkResize() throws(CheckFailure) -> String {
        guard let (stream, recorder) = first else { throw CheckFailure("no stream") }
        let mark = recorder.read { $0.bytes.count }
        let sent = Monotonic.milliseconds()
        stream.resize(Self.resizedSize)
        try waitForBytes(Self.resizeEcho, in: recorder, from: mark, what: "stty size")
        return "stty size printed 30 100 after \(Monotonic.milliseconds() - sent) ms"
    }

    /// close, reconnect WITHOUT takeover (retried while the holder still reports `busy` for the
    /// closed connection), ATTACH latest: the replay carries compat-ready and ATTACHED's current
    /// modes have ?2004 on.
    private func checkReattach() throws(CheckFailure) -> String {
        if let previous = first {
            previous.stream.close()
            waitUntil(2_000) { previous.recorder.read { $0.closed != nil } }
            first = nil
        }
        var busyRetries = 0
        while true {
            let connection = try connect()
            connection.stream.start(takeover: false, attachFrom: .latestResync)
            waitUntil { connection.recorder.read { $0.welcome != nil || $0.closed != nil } }
            let state = connection.recorder.snapshot
            if state.welcome != nil {
                second = connection
                break
            }
            connection.stream.close()
            if case .holderError(let info)? = state.closed, info.code == HolderErrorCode.busy, remainingMilliseconds > 100 {
                busyRetries += 1
                usleep(50_000)
                continue
            }
            throw CheckFailure("no WELCOME on reconnect: \(state.closed.map { "\($0)" } ?? "timeout") (busy retries \(busyRetries))")
        }
        guard let recorder = second?.recorder else { throw CheckFailure("no stream") }
        waitUntil {
            recorder.read {
                (!$0.attaches.isEmpty && Bytes.contains(Self.readyMarker, in: Array($0.bytes.prefix($0.replayBytes))))
                    || $0.closed != nil
            }
        }
        let state = recorder.snapshot
        guard let attach = state.attaches.first else {
            throw CheckFailure("no attach took effect: \(state.closed.map { "\($0)" } ?? "timeout")")
        }
        let replay = Array(state.bytes.prefix(state.replayBytes))
        var problems: [String] = []
        if !Bytes.contains(Self.readyMarker, in: replay) {
            problems.append("replay lacks compat-ready; got \(Bytes.excerpt(state.bytes))")
        }
        if !attach.acknowledged { problems.append("no ATTACHED (attach.ack)") }
        if let resync = state.welcome?.resync, attach.start != resync {
            problems.append("attach start \(attach.start) != WELCOME resync \(resync)")
        }
        let current: String
        if let modes = attach.currentModes {
            current = modes.bracketedPaste ? "on" : "off"
            if !modes.bracketedPaste { problems.append("ATTACHED current modes have ?2004 off") }
        } else {
            current = "absent"
            problems.append("ATTACHED carries no current modes (attach.modes)")
        }
        let atStart = attach.modes.map { $0.bracketedPaste ? "on" : "off" } ?? "unknown"
        let summary = "busyRetries=\(busyRetries) start=\(attach.start) replayEnd=\(attach.replayEnd) "
            + "replayed=\(state.replayBytes) ?2004 at start=\(atStart) current=\(current)"
        guard problems.isEmpty else { throw CheckFailure(problems.joined(separator: "; ") + "; " + summary) }
        return summary
    }

    /// A paste plus submit after the reattach: the echoed line is bracketed for every holder (the
    /// holder brackets with `input.paste`; the client brackets from ATTACHED's modes without it).
    private func checkPaste() throws(CheckFailure) -> String {
        guard let (stream, recorder) = second else { throw CheckFailure("not run: no reattached stream") }
        let mark = recorder.read { $0.bytes.count }
        let byHolder = stream.supportsPaste
        let sent = Monotonic.milliseconds()
        do {
            try stream.sendInput(Self.pasteText, submit: true, paste: true)
        } catch {
            throw CheckFailure("sendInput(paste:): \(error)")
        }
        try waitForBytes(Self.pasteEcho, in: recorder, from: mark, what: "bracketed echo")
        let who = byHolder ? "holder (input.paste)" : "client (holder without input.paste)"
        return "got:ESC[200~compat-paste ESC[201~ bracketed by the \(who) after \(Monotonic.milliseconds() - sent) ms"
    }

    /// RingFileReader on the live holder's ring: the markers, the resized PTY size, a resync point.
    private func checkRing() throws(CheckFailure) -> String {
        let path = sessionDirectory + "/ring"
        let snapshot: RingSnapshot
        do {
            snapshot = try RingFileReader.read(path: path)
        } catch {
            throw CheckFailure("RingFileReader.read(\(path)): \(error)")
        }
        var problems: [String] = []
        for (name, marker) in [("compat-ready", Self.readyMarker), ("input echo", Self.inputEcho), ("paste echo", Self.pasteEcho)]
        where !Bytes.contains(marker, in: snapshot.bytes) {
            problems.append("ring lacks the \(name)")
        }
        if snapshot.columns != Int(Self.resizedSize.cols) || snapshot.rows != Int(Self.resizedSize.rows) {
            problems.append("ring size \(snapshot.columns)x\(snapshot.rows), expected 100x30")
        }
        if snapshot.modes == nil { problems.append("no resync point (modes unknown)") }
        if snapshot.childExited { problems.append("childExited before stop") }
        let summary = "start=\(snapshot.start) end=\(snapshot.end) bytes=\(snapshot.bytes.count) "
            + "size=\(snapshot.columns)x\(snapshot.rows) spawnOffset=\(snapshot.spawnOffset)"
        guard problems.isEmpty else {
            throw CheckFailure(problems.joined(separator: "; ") + "; " + summary + " " + Bytes.excerpt(snapshot.bytes))
        }
        return summary
    }

    /// SIGTERM: EXIT reaches the attached stream, the holder is gone within 5 s, meta.json says
    /// holderExited, and nothing of the child's process group is left.
    private func checkStop() throws(CheckFailure) -> String {
        guard !reapHolder() else { throw CheckFailure("holder already gone before SIGTERM") }
        let sent = Monotonic.milliseconds()
        guard kill(holderPid, SIGTERM) == 0 else { throw CheckFailure("kill(SIGTERM): \(Files.errnoText())") }
        var problems: [String] = []
        let gone = waitUntil(5_000) { reapHolder() }
        let goneAfter = Monotonic.milliseconds() - sent
        if !gone { problems.append("holder still running 5 s after SIGTERM") }
        var exitText = "none"
        if let recorder = second?.recorder {
            waitUntil(1_000) { recorder.read { $0.exit != nil } }
            if let exit = recorder.read({ $0.exit }) {
                exitText = "status=\(exit.status) signaled=\(exit.signaled)"
            } else {
                problems.append("no EXIT on the attached stream")
            }
        } else {
            problems.append("no attached stream to receive EXIT")
        }
        let meta = SessionDirectory.readMeta(directory: sessionDirectory)
        if let meta {
            if !meta.holderExited { problems.append("meta holderExited=false") }
        } else {
            problems.append("meta.json unreadable after stop")
        }
        // The holder waits for its direct child only; the background reader ends on the SIGHUP that
        // the exiting session leader sends, a moment later.
        let group = childPid
        if gone, group > 0, !waitUntil(1_000, { kill(-group, 0) != 0 }) {
            problems.append("child process group \(group) still alive")
        }
        let status = holderWaitStatus.map(describeWaitStatus) ?? "running"
        let metaText = meta.map { "holderExited=\($0.holderExited) exited=\($0.exited)" } ?? "unreadable"
        let summary = "EXIT \(exitText); holder gone after \(goneAfter) ms (\(status)); meta \(metaText)"
        guard problems.isEmpty else { throw CheckFailure(problems.joined(separator: "; ") + "; " + summary) }
        return summary
    }

    // MARK: - Processes

    /// Reaps the holder if it exited; true once it is gone (or was never started).
    private func reapHolder() -> Bool {
        guard holderPid > 0, !holderReaped else { return true }
        var status: Int32 = 0
        let result = waitpid(holderPid, &status, WNOHANG)
        guard result == holderPid || (result < 0 && errno == ECHILD) else { return false }
        holderReaped = true
        if result == holderPid { holderWaitStatus = status }
        Emergency.shared.holderPid.store(0, ordering: .releasing)
        return true
    }

    /// Closes the streams, then ends the holder (SIGTERM, SIGKILL after 5 s) and whatever is left of
    /// the child's process group (the holder normally ends it itself).
    private func cleanUp() {
        first?.stream.close()
        second?.stream.close()
        first = nil
        second = nil
        if !reapHolder() {
            kill(holderPid, SIGTERM)
            if !Monotonic.poll(timeoutMilliseconds: 5_000, reapHolder) {
                kill(holderPid, SIGKILL)
                var status: Int32 = 0
                waitpid(holderPid, &status, 0)
                holderReaped = true
                Emergency.shared.holderPid.store(0, ordering: .releasing)
            }
        }
        if childPid > 0, kill(-childPid, 0) == 0 {
            let group = childPid
            if !Monotonic.poll(timeoutMilliseconds: 1_000, { kill(-group, 0) != 0 }) {
                kill(-group, SIGKILL)
                Report.error("codd-holder-compat: killed the leftover child process group \(group)\n")
            }
        }
        Emergency.shared.childPid.store(0, ordering: .releasing)
    }
}
