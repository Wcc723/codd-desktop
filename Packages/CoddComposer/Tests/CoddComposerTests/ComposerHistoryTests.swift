import Foundation
import Testing
@testable import CoddComposer

@Suite("Composer history")
struct ComposerHistoryTests {
    @Test func walksBackAndForthAndGivesTheStashBackOnce() {
        var history = ComposerHistory(entries: ["one", "two", "three"])
        #expect(history.previous(current: "draft") == "three")
        #expect(history.isWalking)
        #expect(history.previous(current: "three") == "two")
        #expect(history.previous(current: "two") == "one")
        // At the oldest: nothing older, the composer keeps "one".
        #expect(history.previous(current: "one") == nil)
        #expect(history.next() == "two")
        #expect(history.next() == "three")
        // Past the newest: the text the walk started from, once.
        #expect(history.next() == "draft")
        #expect(!history.isWalking)
        #expect(history.next() == nil)
        // A new walk stashes again.
        #expect(history.previous(current: "new draft") == "three")
        #expect(history.next() == "new draft")
    }

    @Test func emptyHistoryHasNothingToWalk() {
        var history = ComposerHistory()
        #expect(history.previous(current: "x") == nil)
        #expect(history.next() == nil)
        #expect(!history.isWalking)
    }

    @Test func nextWithoutAWalkIsNil() {
        var history = ComposerHistory(entries: ["a"])
        #expect(history.next() == nil)
    }

    @Test func recordTrimsIgnoresEmptyAndCollapsesRepeats() {
        var history = ComposerHistory()
        history.record("修正登入 API 401  \n\n")
        history.record("   \n\t")
        history.record("")
        history.record("修正登入 API 401")
        history.record("第一行\n第二行\n")
        history.record("修正登入 API 401")
        #expect(history.entries == ["修正登入 API 401", "第一行\n第二行", "修正登入 API 401"])
    }

    @Test func recordKeepsLeadingWhitespace() {
        var history = ComposerHistory()
        history.record("  indented\n")
        #expect(history.entries == ["  indented"])
    }

    @Test func recordKeepsTheNewestLimit() {
        var history = ComposerHistory()
        for index in 0 ..< 150 {
            history.record("prompt \(index)")
        }
        #expect(history.entries.count == ComposerHistory.limit)
        #expect(history.entries.first == "prompt 50")
        #expect(history.entries.last == "prompt 149")
    }

    @Test func initKeepsTheNewestLimit() {
        let history = ComposerHistory(entries: (0 ..< 120).map { "p\($0)" })
        #expect(history.entries.count == 100)
        #expect(history.entries.first == "p20")
    }

    @Test func recordEndsAWalk() {
        var history = ComposerHistory(entries: ["a", "b"])
        _ = history.previous(current: "draft")
        _ = history.previous(current: "b")
        history.record("c")
        #expect(!history.isWalking)
        #expect(history.previous(current: "") == "c")
    }

    @Test func resetCursorEndsAWalkAndDropsTheStash() {
        var history = ComposerHistory(entries: ["a", "b"])
        #expect(history.previous(current: "draft") == "b")
        history.resetCursor()
        #expect(!history.isWalking)
        #expect(history.next() == nil)
        #expect(history.previous(current: "other") == "b")
        #expect(history.next() == "other")
    }

    @Test func equalityAndCodingIgnoreTheWalk() throws {
        var walking = ComposerHistory(entries: ["a", "b"])
        _ = walking.previous(current: "draft")
        #expect(walking == ComposerHistory(entries: ["a", "b"]))
        let data = try JSONEncoder().encode(walking)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?.keys.sorted() == ["entries"])
        var decoded = try JSONDecoder().decode(ComposerHistory.self, from: data)
        #expect(decoded.entries == ["a", "b"])
        #expect(!decoded.isWalking)
        #expect(decoded.next() == nil)
    }

    @Test func decodingKeepsTheNewestLimit() throws {
        let entries = (0 ..< 130).map { "e\($0)" }
        let data = try JSONSerialization.data(withJSONObject: ["entries": entries])
        let decoded = try JSONDecoder().decode(ComposerHistory.self, from: data)
        #expect(decoded.entries.count == 100)
        #expect(decoded.entries.first == "e30")
    }
}
