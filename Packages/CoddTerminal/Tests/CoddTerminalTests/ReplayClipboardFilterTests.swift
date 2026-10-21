import Foundation
import Testing
@testable import CoddTerminal

/// Review SEC-2: replayed history re-ran OSC 52 clipboard writes on every cold attach and relaunch.
@Suite("Replay clipboard filter")
struct ReplayClipboardFilterTests {
    private static let esc = "\u{1B}"
    /// Writes (BEL and ST terminated, any selection), a query, and OSCs that must survive.
    static let history = "a\(esc)]52;c;Q09ERC1SRVZJRVc=\u{07}b\(esc)]52;;?\(esc)\\c\(esc)]0;title\u{07}d"
        + "\(esc)]520;not-clipboard\u{07}e\(esc)[31mred\(esc)]52;p;eA==\(esc)[0mf\(esc)]5;x\u{07}g"
    static let expected = "abc\(esc)]0;title\u{07}d\(esc)]520;not-clipboard\u{07}e\(esc)[31mred\(esc)[0mf\(esc)]5;x\u{07}g"

    private func replay(_ chunks: [[UInt8]], into filter: inout ReplayClipboardFilter) -> [UInt8] {
        var out: [UInt8] = []
        for chunk in chunks {
            out += chunk.withUnsafeBytes { filter.filterReplay($0) } ?? chunk
        }
        return out
    }

    @Test func clipboardSequencesLeaveTheReplayWhole() {
        var filter = ReplayClipboardFilter()
        let out = replay([Array(Self.history.utf8)], into: &filter)
        #expect(String(decoding: out, as: UTF8.self) == Self.expected)
        #expect(filter.isIdle)
    }

    /// Chunk boundaries fall anywhere (64 KiB OUTPUT frames): every split gives the same result.
    @Test func everySplitPointGivesTheSameResult() {
        let bytes = Array(Self.history.utf8)
        for split in 0...bytes.count {
            var filter = ReplayClipboardFilter()
            let out = replay([Array(bytes[..<split]), Array(bytes[split...])], into: &filter)
            #expect(String(decoding: out, as: UTF8.self) == Self.expected, "split at \(split)")
        }
        // One byte at a time.
        var filter = ReplayClipboardFilter()
        let out = replay(bytes.map { [$0] }, into: &filter)
        #expect(String(decoding: out, as: UTF8.self) == Self.expected)
    }

    @Test func plainHistoryPassesWithoutACopy() {
        var filter = ReplayClipboardFilter()
        let plain = Array("no escapes at all\r\n".utf8)
        #expect(plain.withUnsafeBytes { filter.filterReplay($0) } == nil)
        let live = Array("\(Self.esc)]52;c;eA==\u{07}".utf8)
        // Live output is never filtered while idle: a program copying now is the user's business.
        #expect(live.withUnsafeBytes { filter.filterLive($0) } == nil)
    }

    /// A frame straddling the replay end: the sequence the replay ended in is dropped to its end,
    /// the live bytes after it pass, a live OSC 52 after that too.
    @Test func sequenceCutAtTheReplayEndIsFinishedInTheLiveBytes() {
        var filter = ReplayClipboardFilter()
        let head = Array("old\(Self.esc)]52;c;Zm9".utf8)
        let tail = Array("v\(Self.esc)\\live\(Self.esc)]52;c;eA==\u{07}".utf8)
        let replayed = head.withUnsafeBytes { filter.filterReplay($0) } ?? head
        #expect(String(decoding: replayed, as: UTF8.self) == "old")
        #expect(!filter.isIdle)
        let live = tail.withUnsafeBytes { filter.filterLive($0) } ?? tail
        #expect(String(decoding: live, as: UTF8.self) == "live\(Self.esc)]52;c;eA==\u{07}")
        #expect(filter.isIdle)

        // An ESC held back at the end of the replay is released into the live bytes.
        let held = Array("x\(Self.esc)".utf8)
        #expect(String(decoding: held.withUnsafeBytes { filter.filterReplay($0) } ?? held, as: UTF8.self) == "x")
        let next = Array("[1mbold".utf8)
        #expect(String(decoding: next.withUnsafeBytes { filter.filterLive($0) } ?? next, as: UTF8.self) == "\(Self.esc)[1mbold")
    }

    @Test func resetForgetsASequenceInProgress() {
        var filter = ReplayClipboardFilter()
        let head = Array("\(Self.esc)]52;c;Zm9v".utf8)
        _ = head.withUnsafeBytes { filter.filterReplay($0) }
        #expect(!filter.isIdle)
        filter.reset()
        #expect(filter.isIdle)
        let after = Array("after reset".utf8)
        #expect(after.withUnsafeBytes { filter.filterReplay($0) } == nil)
    }

    /// Review concurrency-perf-7: a ring prepared off the main actor is the filtered history,
    /// and a sequence it ends in does not swallow what is replayed after it (the footer).
    @Test func preparedReplayIsTheFilteredHistory() async {
        let bytes = Array(Self.history.utf8)
        let prepared = await Task.detached { PreparedReplay(bytes) }.value
        #expect(String(decoding: prepared.data, as: UTF8.self) == Self.expected)
        let plain = Array("plain\r\n".utf8)
        #expect(PreparedReplay(plain).data == Data(plain))
        let cut = PreparedReplay(Array("old\(Self.esc)]52;c;Zm9".utf8))
        #expect(String(decoding: cut.data, as: UTF8.self) == "old")
        #expect(PreparedReplay([]).count == 0)
    }

    /// The engine's filter starts over with every new session (a new process) and on `reset`.
    @Test func engineFilterResetsWithANewSession() {
        let io = EngineIO()
        _ = io.makeSession()
        let head = Array("\(Self.esc)]52;c;Zm9v".utf8)
        #expect(head.withUnsafeBytes { io.filterReplay($0) } == [])
        let live = Array("still dropped\u{07}live".utf8)
        #expect(live.withUnsafeBytes { io.filterLive($0) }.map { String(decoding: $0, as: UTF8.self) } == "live")
        _ = head.withUnsafeBytes { io.filterReplay($0) }
        _ = io.makeSession()
        #expect(live.withUnsafeBytes { io.filterLive($0) } == nil)
        io.detachSession()
    }
}
