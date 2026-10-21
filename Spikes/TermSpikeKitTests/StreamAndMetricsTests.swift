import Foundation
import Testing
import TermSpikeKit

@Suite("AnsiStreamGenerator")
struct AnsiStreamGeneratorTests {
    @Test("is deterministic and exactly sized", arguments: [1, 4096, 1_000_003])
    func deterministic(size: Int) {
        var first = AnsiStreamGenerator(seed: 42)
        var second = AnsiStreamGenerator(seed: 42)
        let a = first.generate(byteCount: size)
        let b = second.generate(byteCount: size)
        #expect(a.count == size)
        #expect(a == b)
    }

    @Test("is valid UTF-8, escape-heavy and query-free")
    func content() {
        var generator = AnsiStreamGenerator()
        let stream = generator.generate(byteCount: 2 * 1024 * 1024)
        #expect(String(validating: stream, as: UTF8.self) != nil)
        let escapes = stream.reduce(0) { $0 + ($1 == 0x1B ? 1 : 0) }
        #expect(Double(escapes) / Double(stream.count) > 0.02)
        let text = String(decoding: stream, as: UTF8.self)
        #expect(text.contains("\u{1B}[?1049h"))
        #expect(text.contains("\u{1B}[?2026h"))
        #expect(text.contains("修正登入"))
        #expect(text.contains("╭"))
        for query in ["\u{1B}[c", "\u{1B}[>0q", "\u{1B}[?u", "$p", "\u{1B}[6n", "\u{1B}[16t", "7501;?"] {
            #expect(!text.contains(query), "stream must not contain query \(query.debugDescription)")
        }
    }

    @Test("title frequency follows titlePerMille")
    func titleRate() {
        func titles(_ perMille: Int) -> Int {
            var generator = AnsiStreamGenerator(seed: 7, titlePerMille: perMille)
            return String(decoding: generator.generate(byteCount: 1 << 20), as: UTF8.self)
                .components(separatedBy: "\u{1B}]0;").count - 1
        }
        let realistic = titles(1)
        let heavy = titles(100)
        #expect(realistic < 40)
        #expect(heavy > realistic * 20)
    }

    @Test("render test pattern is well-formed")
    func renderPattern() {
        let bytes = RenderTestPattern.bytes
        #expect(String(validating: bytes, as: UTF8.self) != nil)
        let text = RenderTestPattern.text
        #expect(text.hasSuffix("\r\n"))
        #expect(text.contains("\u{1B}]8;;https://ghostty.org/docs\u{1B}\\"))
        #expect(text.contains("|修正登入AB|注音輸入法|"))
    }

    @Test("different seeds differ")
    func seeds() {
        var a = AnsiStreamGenerator(seed: 1)
        var b = AnsiStreamGenerator(seed: 2)
        #expect(a.generate(byteCount: 10_000) != b.generate(byteCount: 10_000))
    }
}

@Suite("Latency")
struct LatencyTests {
    @Test("nearest-rank percentiles")
    func percentiles() {
        let summary = LatencySummary(samples: (1 ... 100).map(Double.init))
        #expect(summary.count == 100)
        #expect(summary.p50 == 50)
        #expect(summary.p95 == 95)
        #expect(summary.p99 == 99)
        #expect(summary.max == 100)
        #expect(summary.mean == 50.5)
        #expect(LatencySummary(samples: []) == .empty)
    }

    @Test("recorder keeps only the newest samples")
    func boundedRecorder() {
        let recorder = LatencyRecorder(capacity: 10)
        for value in 1 ... 25 { recorder.record(Double(value)) }
        let summary = recorder.summary()
        #expect(summary.count == 10)
        #expect(summary.max == 25)
    }

    @Test("pairs keyDown with the next PTY write")
    func keyTracker() async throws {
        let tracker = KeyLatencyTracker(staleAfterNanos: 50_000_000)
        tracker.keyDown(eventTimestamp: ProcessInfo.processInfo.systemUptime)
        tracker.ptyWritten()
        #expect(tracker.hostPath.summary().count == 1)
        #expect(tracker.eventToWrite.summary().count == 1)

        tracker.keyDown(eventTimestamp: 0) // swallowed by an IME: no write follows
        try await Task.sleep(for: .milliseconds(80))
        tracker.keyDown(eventTimestamp: 0)
        #expect(tracker.unmatchedCount == 1)
        tracker.ptyWritten()
        #expect(tracker.hostPath.summary().count == 2)
        tracker.ptyWritten() // a reply with no pending key is ignored
        #expect(tracker.hostPath.summary().count == 2)
    }

    @Test("process metrics are populated")
    func processMetrics() {
        let sample = ProcessMetrics.current()
        #expect(sample.residentBytes > 0)
        #expect(sample.footprintBytes > 0)
        #expect(sample.threads >= 1)
    }
}

@Suite("ChildEnvironment")
struct ChildEnvironmentTests {
    @Test("copies only the allow-list and sets terminal variables")
    func allowList() {
        let parent = [
            "HOME": "/Users/test", "USER": "test", "PATH": "/opt/homebrew/bin:/usr/bin",
            "DYLD_INSERT_LIBRARIES": "/tmp/x.dylib", "CLAUDECODE": "1", "XPC_SERVICE_NAME": "x",
            "LANG": "zh_TW.UTF-8",
        ]
        let env = ChildEnvironment.build(parent: parent, term: "xterm-256color", termProgram: nil)
        #expect(env["HOME"] == "/Users/test")
        #expect(env["PATH"] == ChildEnvironment.basePath)
        #expect(env["DYLD_INSERT_LIBRARIES"] == nil)
        #expect(env["CLAUDECODE"] == nil)
        #expect(env["XPC_SERVICE_NAME"] == nil)
        #expect(env["TERM_PROGRAM"] == nil)
        #expect(env["COLORTERM"] == "truecolor")
        #expect(env["LANG"] == "zh_TW.UTF-8")
        #expect(env["LC_CTYPE"] == "zh_TW.UTF-8")
    }

    @Test("falls back to a UTF-8 locale and applies extras last")
    func fallbacks() {
        let env = ChildEnvironment.build(
            parent: ["LANG": "C"], term: "xterm-ghostty", termProgram: "ghostty",
            extra: ["TERMINFO": "/tmp/terminfo", "TERM": "xterm-ghostty"]
        )
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["TERM_PROGRAM"] == "ghostty")
        #expect(env["TERMINFO"] == "/tmp/terminfo")
    }

    @Test("wraps commands in a login shell")
    func loginShell() {
        #expect(CommandLineSpec.loginShell(command: "zsh -l").arguments == ["zsh", "-l", "-c", "exec zsh -l"])
        #expect(CommandLineSpec.loginShell(command: "claude").arguments == ["zsh", "-l", "-c", "exec claude"])
        #expect(CommandLineSpec.loginShell(command: "cd /tmp && ls").arguments == ["zsh", "-l", "-c", "cd /tmp && ls"])
        #expect(CommandLineSpec.loginShell(command: "  ").arguments == ["-zsh"])
        // zsh's `exec FOO=1 claude` runs a command named FOO=1.
        #expect(CommandLineSpec.loginShell(command: "CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1 claude").arguments
            == ["zsh", "-l", "-c", "CLAUDE_CODE_FORCE_TERMINAL_IMAGES=1 claude"])
        #expect(CommandLineSpec.loginShell(command: "claude --model=opus").arguments
            == ["zsh", "-l", "-c", "exec claude --model=opus"])
    }
}

@Suite("AnsiStreamGenerator geometry")
struct AnsiStreamGeneratorGeometryTests {
    @Test("narrow and short grids do not trap", arguments: [(20, 10), (24, 12), (40, 10), (41, 11), (80, 24)])
    func narrowGrids(columns: Int, rows: Int) {
        var generator = AnsiStreamGenerator(seed: 3, columns: columns, rows: rows)
        let stream = generator.generate(byteCount: 200_000)
        #expect(stream.count == 200_000)
        #expect(String(validating: stream, as: UTF8.self) != nil)
    }
}

@Suite("KeyLatencyTracker IME handling")
struct KeyLatencyTrackerIMETests {
    @Test("a key cancelled as an IME composition does not pair with the next write")
    func cancelledKey() {
        let tracker = KeyLatencyTracker()
        let composing = tracker.keyDown(eventTimestamp: 0) // first key of a 注音 syllable
        tracker.cancel(composing)
        _ = tracker.keyDown(eventTimestamp: 0) // the key that commits
        tracker.ptyWritten()
        #expect(tracker.hostPath.summary().count == 1)
        #expect(tracker.unmatchedCount == 1)
        tracker.ptyWritten()
        #expect(tracker.hostPath.summary().count == 1)
    }

    @Test("cancelling a key that already wrote is a no-op")
    func cancelAfterWrite() {
        let tracker = KeyLatencyTracker()
        let key = tracker.keyDown(eventTimestamp: 0)
        tracker.ptyWritten()
        tracker.cancel(key)
        #expect(tracker.hostPath.summary().count == 1)
        #expect(tracker.unmatchedCount == 0)
    }
}

@Suite("CPU metrics")
struct CPUMetricsTests {
    @Test("CPU time grows with work and converts to percent of a core")
    func cpuTime() {
        let start = ProcessMetrics.cpuSeconds()
        var accumulator: UInt64 = 0
        for value in 0 ..< 20_000_000 { accumulator &+= UInt64(value) &* 2_654_435_761 }
        #expect(accumulator != 1) // keep the loop
        #expect(ProcessMetrics.cpuSeconds() > start)
        #expect(ProcessMetrics.cpuPercent(cpuSeconds: 0.5, wallNanos: 2_000_000_000) == 25)
        #expect(ProcessMetrics.cpuPercent(cpuSeconds: 1, wallNanos: 0) == 0)
    }
}
