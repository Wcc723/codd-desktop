import Foundation

/// UTF-16 offsets of every line start (LF-separated; N newlines make N + 1 lines, the last one
/// possibly empty, as the gutter numbers them). Updated per text storage edit by splicing only
/// the lines the edit touched and shifting the rest, so a keystroke in a 1 MB file stays cheap.
struct LineIndex {
    private(set) var starts: [Int] = [0]
    private(set) var length = 0

    var count: Int { starts.count }

    /// Old lines `line ..< line + oldCount` became new lines `line ..< line + newCount` (both ≥ 1:
    /// the line holding the edit's start is always part of it).
    struct Edit: Equatable {
        var line: Int
        var oldCount: Int
        var newCount: Int

        var delta: Int { newCount - oldCount }
    }

    mutating func rebuild(_ text: NSString) {
        var result = [0]
        let total = text.length
        result.reserveCapacity(total / 32 + 1)
        // Native searches: a Swift loop over every unit is slow in debug builds (60+ ms per MB).
        var position = 0
        while position < total {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: position, length: total - position))
            guard found.location != NSNotFound else { break }
            result.append(found.location + 1)
            position = found.location + 1
        }
        starts = result
        length = total
    }

    /// The line holding UTF-16 offset `offset` (the last line for offsets at or past the end).
    func line(containing offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    func start(of line: Int) -> Int {
        starts[max(0, min(line, starts.count - 1))]
    }

    /// The line's characters without its newline.
    func range(of line: Int) -> NSRange {
        let start = start(of: line)
        let end = line + 1 < starts.count ? starts[line + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The line's characters with its newline (for invalidating layout / display).
    func rangeWithNewline(of line: Int) -> NSRange {
        let start = start(of: line)
        let end = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Applies a text storage edit: `editedRange` is in the new text, `delta` its change in length.
    mutating func apply(editedRange: NSRange, delta: Int, text: NSString) -> Edit {
        let editStart = editedRange.location
        let oldEnd = NSMaxRange(editedRange) - delta
        let first = line(containing: editStart)
        var removedEnd = first + 1
        while removedEnd < starts.count, starts[removedEnd] <= oldEnd { removedEnd += 1 }
        var inserted: [Int] = []
        let newEnd = NSMaxRange(editedRange)
        var position = editStart
        while position < newEnd {
            let found = text.range(of: "\n", options: .literal, range: NSRange(location: position, length: newEnd - position))
            guard found.location != NSNotFound else { break }
            inserted.append(found.location + 1)
            position = found.location + 1
        }
        if delta != 0 {
            starts.withUnsafeMutableBufferPointer { all in
                for k in removedEnd ..< all.count { all[k] += delta }
            }
        }
        starts.replaceSubrange(first + 1 ..< removedEnd, with: inserted)
        length += delta
        return Edit(line: first, oldCount: removedEnd - first, newCount: inserted.count + 1)
    }
}
