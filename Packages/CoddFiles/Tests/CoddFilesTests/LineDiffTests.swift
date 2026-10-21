import Foundation
import Testing
@testable import CoddFiles

@Suite("LineDiff")
struct LineDiffTests {
    private func chars(_ text: String) -> [String] { text.map(String.init) }

    /// Applies every hunk (back to front) to `old`; the result must be `new`.
    private func apply(_ hunks: [DiffHunk], to old: [String]) -> [String] {
        var out = old
        for hunk in hunks.reversed() { out.replaceSubrange(hunk.oldRange, with: hunk.newLines) }
        return out
    }

    private func editCount(_ hunks: [DiffHunk]) -> Int {
        hunks.reduce(0) { $0 + $1.oldRange.count + $1.newRange.count }
    }

    /// Classic LCS length by dynamic programming (the reference for minimality).
    private func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var previous = 0
            for (j, y) in b.enumerated() {
                let saved = row[j + 1]
                row[j + 1] = x == y ? previous + 1 : max(row[j + 1], row[j])
                previous = saved
            }
        }
        return row[b.count]
    }

    @Test func myersPaperExample() {
        let old = chars("ABCABBA")
        let new = chars("CBABAC")
        let hunks = LineDiff.hunks(old: old, new: new)
        #expect(apply(hunks, to: old) == new)
        #expect(editCount(hunks) == 5, "D = 5 in Myers (1986)")
    }

    @Test func emptySidesAndEqualInputs() {
        #expect(LineDiff.hunks(old: [], new: []).isEmpty)
        #expect(LineDiff.hunks(old: ["a", "b"], new: ["a", "b"]).isEmpty)
        let insert = LineDiff.hunks(old: [], new: ["x", "y"])
        #expect(insert == [DiffHunk(oldRange: 0..<0, newRange: 0..<2, oldLines: [], newLines: ["x", "y"])])
        let delete = LineDiff.hunks(old: ["x"], new: [])
        #expect(delete == [DiffHunk(oldRange: 0..<1, newRange: 0..<0, oldLines: ["x"], newLines: [])])
    }

    @Test func randomInputsAreMinimalAndApply() {
        var rng = SplitMix(seed: 0xC0DD)
        for _ in 0..<300 {
            let old = (0..<Int(rng.next() % 30)).map { _ in String(rng.next() % 5) }
            let new = (0..<Int(rng.next() % 30)).map { _ in String(rng.next() % 5) }
            let hunks = LineDiff.hunks(old: old, new: new)
            #expect(apply(hunks, to: old) == new)
            #expect(editCount(hunks) == old.count + new.count - 2 * lcs(old, new), "minimal for \(old) → \(new)")
            for hunk in hunks {
                #expect(hunk.oldLines == Array(old[hunk.oldRange]) && hunk.newLines == Array(new[hunk.newRange]))
            }
        }
    }

    @Test func revertingEachHunkRestoresOnlyThatRegion() {
        let old = (1...60).map { "line \($0)" }
        var new = old
        new[4] = "changed 5"                              // hunk 1: replace
        new.insert(contentsOf: ["added a", "added b"], at: 20) // hunk 2: insert
        new.removeSubrange(40...41)                        // hunk 3: delete (indices after the insert)
        new[50] = "changed late"                           // hunk 4
        let hunks = LineDiff.hunks(old: old, new: new)
        #expect(hunks.count == 4)
        for (index, hunk) in hunks.enumerated() {
            let reverted = LineDiff.reverting(hunk, in: new)
            let remaining = LineDiff.hunks(old: old, new: reverted)
            #expect(remaining.count == 3, "hunk \(index) undone, the others stay")
            #expect(!remaining.contains { $0.oldRange == hunk.oldRange }, "hunk \(index) region equals the old lines")
            // Everything outside the hunk is untouched.
            #expect(Array(reverted[..<hunk.newRange.lowerBound]) == Array(new[..<hunk.newRange.lowerBound]))
            #expect(Array(reverted[(hunk.newRange.lowerBound + hunk.oldLines.count)...]) == Array(new[hunk.newRange.upperBound...]))
        }
    }

    @Test func unifiedHeadersFollowGit() {
        // The FileEditor artboard's hunk: lines 40–41 replaced by four lines.
        var old = (1...50).map { "l\($0)" }
        let new: [String] = Array(old[0..<39]) + ["a", "b", "c", "d"] + Array(old[41...])
        let hunks = LineDiff.hunks(old: old, new: new)
        #expect(hunks.count == 1)
        #expect(LineDiff.unifiedHeader(hunks[0]) == "@@ -40,2 +40,4 @@")
        old = ["a", "b", "c"]
        #expect(LineDiff.unifiedHeader(LineDiff.hunks(old: old, new: ["a", "X", "c"])[0]) == "@@ -2 +2 @@")
        #expect(LineDiff.unifiedHeader(LineDiff.hunks(old: old, new: ["a", "b", "c", "d", "e"])[0]) == "@@ -3,0 +4,2 @@")
        #expect(LineDiff.unifiedHeader(LineDiff.hunks(old: old, new: ["b", "c"])[0]) == "@@ -1 +0,0 @@")
    }

    @Test func contextMergesNearbyChanges() {
        let old = (1...30).map { "\($0)" }
        var new = old
        new[5] = "x"
        new[8] = "y"
        new[25] = "z"
        let tight = LineDiff.hunks(old: old, new: new, context: 0)
        #expect(tight.count == 3)
        let wide = LineDiff.hunks(old: old, new: new, context: 3)
        #expect(wide.count == 2)
        #expect(wide[0].oldRange == 2..<12)
        #expect(wide[0].newRange == 2..<12)
        #expect(wide[1].oldRange == 22..<29)
        #expect(LineDiff.reverting(wide[0], in: new)[5] == "6")
    }

    @Test func largeFileWithScatteredEditsIsFast() {
        let old = (0..<20_000).map { "let value\($0) = compute(\($0))" }
        var new = old
        for index in stride(from: 100, to: 20_000, by: 200) { new[index] = "// edited \(index)" }
        let clock = ContinuousClock()
        let start = clock.now
        let hunks = LineDiff.hunks(old: old, new: new)
        let elapsed = clock.now - start
        #expect(hunks.count == 100)
        print("LineDiff 20,000 lines / 100 edits: \(elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 1))))")
        #expect(elapsed < .seconds(2))
        // Completely different inputs stay bounded too (the budget turns them into one replace).
        let other = (0..<20_000).map { "other \($0)" }
        let start2 = clock.now
        let replaced = LineDiff.hunks(old: old, new: other)
        #expect(replaced.count == 1)
        #expect(clock.now - start2 < .seconds(5))
    }
}

/// Deterministic PRNG for the property test.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
