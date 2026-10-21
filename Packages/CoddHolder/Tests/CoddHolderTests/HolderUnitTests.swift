import CoddPosix
import CoddProtocol
import Darwin
import Testing
@testable import CoddHolderCore

@Suite("Holder units")
struct HolderUnitTests {
    @Test("options: the documented CLI parses; errors are usage errors")
    func options() throws {
        let parsed = try HolderOptions.parse([
            "--session", "abc-123", "--dir", "/s", "--socket", "/r/a.sock", "--cols", "120", "--rows=40",
            "--cwd", "/tmp", "--ring-size", "2M", "--env-file", "/e", "--", "/bin/zsh", "-l",
        ])
        #expect(parsed.session == "abc-123")
        #expect(parsed.rows == 40)
        #expect(parsed.ringSize == 2 << 20)
        #expect(parsed.envFile == "/e")
        #expect(parsed.argv == ["/bin/zsh", "-l"])
        #expect(parsed.exitLingerMilliseconds == 10_000)
        #expect(parsed.flowControlLimit == 1 << 20, "M1: min(1 MiB, ring / 2)")

        let base = ["--session", "s", "--dir", "/s", "--socket", "/a", "--cols", "80", "--rows", "24", "--cwd", "/"]
        #expect(throws: HolderOptions.UsageError.self) { try HolderOptions.parse(base) }
        #expect(throws: HolderOptions.UsageError.self) { try HolderOptions.parse(base + ["--bogus", "1", "--", "sh"]) }
        #expect(throws: HolderOptions.UsageError.self) { try HolderOptions.parse(base + ["--ring-size", "1K", "--", "sh"]) }
        #expect(try HolderOptions.parse(base + ["--flow-limit", "4M", "--", "sh"]).flowControlLimit == 4 << 20)
        #expect(throws: HolderOptions.UsageError.self) { try HolderOptions.parse(base + ["--flow-limit", "1K", "--", "sh"]) }
        #expect(throws: HolderOptions.UsageError.self) { try HolderOptions.parse(base + ["--flow-limit", "1G", "--", "sh"]) }
        #expect(throws: HolderOptions.UsageError.self) {
            try HolderOptions.parse(["--session", "../x"] + base.dropFirst(2) + ["--", "sh"])
        }
        #expect(HolderOptions.parseByteCount("8M") == 8 << 20)
        #expect(HolderOptions.parseByteCount("12") == 12)
        #expect(HolderOptions.parseByteCount("xM") == nil)
    }

    @Test("env file: NUL separated, invalid entries skipped")
    func envFile() {
        let bytes = Array("PATH=/usr/bin\u{0}\u{0}=bad\u{0}NOEQUALS\u{0}LANG=zh_TW.UTF-8\u{0}EMPTY=".utf8)
        let entries = ChildEnvironment.parseEnvFile(bytes)
        #expect(entries == ["PATH=/usr/bin", "LANG=zh_TW.UTF-8", "EMPTY="])
        #expect(ChildEnvironment.value(of: "LANG", in: entries) == "zh_TW.UTF-8")
        #expect(ChildEnvironment.resolveExecutable("sh", environment: ["PATH=/nonexistent:/bin"]) == "/bin/sh")
        #expect(ChildEnvironment.resolveExecutable("./x", environment: []) == "./x")
        #expect(ChildEnvironment.resolveExecutable("no-such-tool-xyz", environment: ["PATH=/bin"]) == "no-such-tool-xyz")
    }

    @Test("input queue: submit marker holds later input until resolved")
    func inputQueue() {
        var queue = InputQueue()
        queue.append(Array("ab".utf8), submit: true)
        queue.append(Array("cd".utf8), submit: false)
        #expect(queue.pendingBytes == 4)
        #expect(queue.withHeadBytes { Array($0) } == Array("ab".utf8))
        queue.consume(1)
        #expect(queue.withHeadBytes { Array($0) } == Array("b".utf8))
        queue.consume(1)
        #expect(queue.head == .submit)
        #expect(queue.withHeadBytes { _ in 0 } == nil)
        queue.resolveSubmit()
        #expect(queue.withHeadBytes { Array($0) } == [0x0D])
        queue.consume(1)
        #expect(queue.withHeadBytes { Array($0) } == Array("cd".utf8))
        queue.consume(2)
        #expect(queue.isEmpty)
        #expect(queue.pendingBytes == 0)
    }

    @Test("control queue: bells coalesce, overflow drops titles, never EXIT")
    func controlQueue() {
        var queue = ControlQueue()
        queue.push(ControlFrame(afterOffset: 1, kind: .bell, bytes: [1]))
        queue.push(ControlFrame(afterOffset: 2, kind: .bell, bytes: [2]))
        #expect(queue.count == 1)
        queue.push(ControlFrame(afterOffset: 3, kind: .exit, bytes: [3]))
        for index in 0..<(ControlQueue.limit * 2) {
            queue.push(ControlFrame(afterOffset: UInt64(index), kind: .title, bytes: [4]))
        }
        #expect(queue.count <= ControlQueue.limit + 1)
        var sawExit = false
        while let first = queue.first {
            if first.kind == .exit { sawExit = true }
            queue.removeFirst()
        }
        #expect(sawExit)
    }

    @Test("ring: wraps, keeps the last capacity bytes, continues offsets across reopen")
    func ring() throws {
        let directory = try TemporaryDirectory()
        let path = directory.path + "/ring"
        var lastOffset: UInt64 = 0
        do {
            let ring = try RingBuffer(path: path, capacity: 128 << 10)
            ring.beginSession()
            #expect(ring.capacity == 128 << 10)
            #expect(ring.writeOffset == 0)
            var expected: [UInt8] = []
            var counter: UInt8 = 0
            for _ in 0..<40 {
                let region = ring.writableRegion()
                let count = min(region.count, 9000)
                for index in 0..<count {
                    region[index] = counter
                    expected.append(counter)
                    counter &+= 1
                }
                ring.commit(count)
            }
            #expect(ring.writeOffset == UInt64(expected.count))
            #expect(ring.oldestOffset == UInt64(expected.count - ring.capacity))
            var copy: [UInt8] = []
            ring.copy(from: ring.oldestOffset, count: ring.capacity, into: &copy)
            #expect(copy == Array(expected.suffix(ring.capacity)))
            ring.recordResync(ResyncPoint(offset: ring.writeOffset - 10, modes: TerminalModes()))
            #expect(ring.latestResync == ring.writeOffset - 10)
            lastOffset = ring.writeOffset
            #expect(throws: SystemError.self) { _ = try RingBuffer(path: path, capacity: 128 << 10) }
        }
        do {
            let reopened = try RingBuffer(path: path, capacity: 128 << 10)
            reopened.beginSession()
            #expect(reopened.writeOffset == lastOffset)
            #expect(reopened.spawnOffset == lastOffset)
            #expect(reopened.latestResync == lastOffset)
        }
        // A different capacity cannot continue the old layout: offsets restart.
        let resized = try RingBuffer(path: path, capacity: 256 << 10)
        resized.beginSession()
        #expect(resized.writeOffset == 0)
        #expect(resized.oldestOffset == 0)
    }
}
