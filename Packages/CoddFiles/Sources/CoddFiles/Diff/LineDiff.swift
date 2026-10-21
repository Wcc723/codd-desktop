import Foundation

/// One changed region between two line arrays (0-based ranges; an empty range is the insertion
/// point). With context, both ranges include the unchanged lines around the change.
public struct DiffHunk: Sendable, Equatable {
    public var oldRange: Range<Int>
    public var newRange: Range<Int>
    public var oldLines: [String]
    public var newLines: [String]

    public init(oldRange: Range<Int>, newRange: Range<Int>, oldLines: [String], newLines: [String]) {
        self.oldRange = oldRange
        self.newRange = newRange
        self.oldLines = oldLines
        self.newLines = newLines
    }
}

/// Line diffs for SHOW AI CHANGES (D27), the notes history compare (D8) and the mixed-EOL save
/// mapping (D24).
///
/// Myers' O(ND) algorithm in its linear-space form (the middle-snake bisection as in Google's
/// diff-match-patch `diff_bisect`), after trimming the common prefix and suffix. Deterministic:
/// the same input always gives the same hunks, deletions come before insertions. A work budget
/// (about 5·10⁷ steps per bisection) bounds pathological inputs: a region that exceeds it is
/// reported as one replace hunk instead of the minimal script.
public enum LineDiff {
    public static func hunks(old: [String], new: [String], context: Int = 0) -> [DiffHunk] {
        var ids: [String: Int] = [:]
        ids.reserveCapacity(old.count + new.count)
        func id(_ line: String) -> Int {
            if let known = ids[line] { return known }
            let next = ids.count
            ids[line] = next
            return next
        }
        let a = old.map(id)
        let b = new.map(id)
        var runs: [Run] = []
        diff(a[...], b[...], into: &runs)
        let raw = regions(runs)
        let grouped = group(raw, context: max(0, context), oldCount: old.count, newCount: new.count)
        return grouped.map { DiffHunk(oldRange: $0.old, newRange: $0.new, oldLines: Array(old[$0.old]), newLines: Array(new[$0.new])) }
    }

    /// `new` with `hunk` undone: its new lines replaced by its old lines; everything else as is.
    /// (Indices of later hunks shift; recompute the hunks after a revert.)
    public static func reverting(_ hunk: DiffHunk, in new: [String]) -> [String] {
        let lower = min(max(0, hunk.newRange.lowerBound), new.count)
        let upper = min(max(lower, hunk.newRange.upperBound), new.count)
        return Array(new[..<lower]) + hunk.oldLines + Array(new[upper...])
    }

    /// `@@ -40,2 +40,4 @@` (git's form: 1-based starts, `,1` omitted, an empty side starts at the
    /// line before it).
    public static func unifiedHeader(_ hunk: DiffHunk) -> String {
        func side(_ range: Range<Int>) -> String {
            let start = range.isEmpty ? range.lowerBound : range.lowerBound + 1
            return range.count == 1 ? "\(start)" : "\(start),\(range.count)"
        }
        return "@@ -\(side(hunk.oldRange)) +\(side(hunk.newRange)) @@"
    }

    // MARK: - Edit script

    enum Run: Equatable {
        case equal(Int), delete(Int), insert(Int)
    }

    private static func append(_ run: Run, to runs: inout [Run]) {
        switch (runs.last, run) {
        case (.equal(let a)?, .equal(let b)): runs[runs.count - 1] = .equal(a + b)
        case (.delete(let a)?, .delete(let b)): runs[runs.count - 1] = .delete(a + b)
        case (.insert(let a)?, .insert(let b)): runs[runs.count - 1] = .insert(a + b)
        default: runs.append(run)
        }
    }

    static func diff(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>, into runs: inout [Run]) {
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[a.startIndex + prefix] == b[b.startIndex + prefix] { prefix += 1 }
        if prefix > 0 { append(.equal(prefix), to: &runs) }
        let a1 = a.dropFirst(prefix)
        let b1 = b.dropFirst(prefix)
        var suffix = 0
        while suffix < a1.count, suffix < b1.count, a1[a1.endIndex - 1 - suffix] == b1[b1.endIndex - 1 - suffix] { suffix += 1 }
        let a2 = a1.dropLast(suffix)
        let b2 = b1.dropLast(suffix)
        if a2.isEmpty {
            if !b2.isEmpty { append(.insert(b2.count), to: &runs) }
        } else if b2.isEmpty {
            append(.delete(a2.count), to: &runs)
        } else {
            bisect(a2, b2, into: &runs)
        }
        if suffix > 0 { append(.equal(suffix), to: &runs) }
    }

    /// Finds the middle snake and splits the problem there (diff-match-patch `diff_bisect`).
    private static func bisect(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>, into runs: inout [Run]) {
        let n = a.count
        let m = b.count
        let fullD = (n + m + 1) / 2
        let budget = max(256, 50_000_000 / max(1, n + m))
        let maxD = min(fullD, budget)
        let offset = fullD
        let length = 2 * fullD + 2
        var v1 = [Int](repeating: -1, count: length)
        var v2 = [Int](repeating: -1, count: length)
        v1[offset + 1] = 0
        v2[offset + 1] = 0
        let delta = n - m
        let front = delta % 2 != 0
        var k1start = 0, k1end = 0, k2start = 0, k2end = 0
        let a0 = a.startIndex
        let b0 = b.startIndex
        for d in 0..<maxD {
            var k1 = -d + k1start
            while k1 <= d - k1end {
                let k1Offset = offset + k1
                var x1: Int
                if k1 == -d || (k1 != d && v1[k1Offset - 1] < v1[k1Offset + 1]) {
                    x1 = v1[k1Offset + 1]
                } else {
                    x1 = v1[k1Offset - 1] + 1
                }
                var y1 = x1 - k1
                while x1 < n, y1 < m, a[a0 + x1] == b[b0 + y1] {
                    x1 += 1
                    y1 += 1
                }
                v1[k1Offset] = x1
                if x1 > n {
                    k1end += 2
                } else if y1 > m {
                    k1start += 2
                } else if front {
                    let k2Offset = offset + delta - k1
                    if k2Offset >= 0, k2Offset < length, v2[k2Offset] != -1 {
                        let x2 = n - v2[k2Offset]
                        if x1 >= x2 {
                            split(a, b, x1, y1, into: &runs)
                            return
                        }
                    }
                }
                k1 += 2
            }
            var k2 = -d + k2start
            while k2 <= d - k2end {
                let k2Offset = offset + k2
                var x2: Int
                if k2 == -d || (k2 != d && v2[k2Offset - 1] < v2[k2Offset + 1]) {
                    x2 = v2[k2Offset + 1]
                } else {
                    x2 = v2[k2Offset - 1] + 1
                }
                var y2 = x2 - k2
                while x2 < n, y2 < m, a[a0 + n - x2 - 1] == b[b0 + m - y2 - 1] {
                    x2 += 1
                    y2 += 1
                }
                v2[k2Offset] = x2
                if x2 > n {
                    k2end += 2
                } else if y2 > m {
                    k2start += 2
                } else if !front {
                    let k1Offset = offset + delta - k2
                    if k1Offset >= 0, k1Offset < length, v1[k1Offset] != -1 {
                        let x1 = v1[k1Offset]
                        let y1 = offset + x1 - k1Offset
                        if x1 >= n - x2 {
                            split(a, b, x1, y1, into: &runs)
                            return
                        }
                    }
                }
                k2 += 2
            }
        }
        // No common subsequence (or over budget): one replace.
        append(.delete(n), to: &runs)
        append(.insert(m), to: &runs)
    }

    private static func split(_ a: ArraySlice<Int>, _ b: ArraySlice<Int>, _ x: Int, _ y: Int, into runs: inout [Run]) {
        let aSplit = a.startIndex + x
        let bSplit = b.startIndex + y
        diff(a[a.startIndex..<aSplit], b[b.startIndex..<bSplit], into: &runs)
        diff(a[aSplit..<a.endIndex], b[bSplit..<b.endIndex], into: &runs)
    }

    // MARK: - Hunks

    struct Region: Equatable {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// Maximal runs of deletes / inserts between equal runs.
    static func regions(_ runs: [Run]) -> [Region] {
        var out: [Region] = []
        var oldPos = 0
        var newPos = 0
        var open: (old: Int, new: Int)?
        for run in runs {
            switch run {
            case .equal(let count):
                if let start = open {
                    out.append(Region(old: start.old..<oldPos, new: start.new..<newPos))
                    open = nil
                }
                oldPos += count
                newPos += count
            case .delete(let count):
                if open == nil { open = (oldPos, newPos) }
                oldPos += count
            case .insert(let count):
                if open == nil { open = (oldPos, newPos) }
                newPos += count
            }
        }
        if let start = open { out.append(Region(old: start.old..<oldPos, new: start.new..<newPos)) }
        return out
    }

    /// Adds `context` unchanged lines around each region and merges regions whose context touches.
    static func group(_ regions: [Region], context: Int, oldCount: Int, newCount: Int) -> [Region] {
        guard context > 0 else { return regions }
        var out: [Region] = []
        var index = 0
        while index < regions.count {
            var first = regions[index]
            var last = first
            index += 1
            while index < regions.count, regions[index].old.lowerBound - last.old.upperBound <= 2 * context {
                last = regions[index]
                index += 1
            }
            let before = min(context, first.old.lowerBound, first.new.lowerBound)
            let after = min(context, oldCount - last.old.upperBound, newCount - last.new.upperBound)
            first.old = (first.old.lowerBound - before)..<(last.old.upperBound + after)
            first.new = (first.new.lowerBound - before)..<(last.new.upperBound + after)
            out.append(first)
        }
        return out
    }
}
