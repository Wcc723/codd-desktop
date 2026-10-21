import Foundation

/// A byte-level pass over JSON text that runs before anything recursive sees it.
///
/// `JSONValue`'s `Decodable` conformance recurses once per nesting level, and Foundation only
/// refuses documents nested deeper than 512. On a dispatch worker thread (512 KiB of stack) a body
/// of about 2 KB nested 300 deep overflowed the stack and killed the app, and hook bodies come from
/// any process that holds the session's hook token (every child of a claude session). So arrays
/// and objects below `maxDepth` are replaced by `null` before decoding, and members of the top-level
/// object that the caller never reads (`tool_response`, possibly megabytes) are replaced by `null`
/// without being materialised at all.
///
/// The pass never recurses and never fails: bytes it does not understand are copied unchanged, so
/// invalid JSON stays invalid and the decoder rejects it as before.
enum JSONNesting {
    /// `data` with every array or object that would sit deeper than `maxDepth` replaced by `null`,
    /// and the value of each top-level member named in `nullingTopLevelKeys` replaced by `null`.
    /// Nil when nothing had to change (the common case costs one scan and no copy).
    ///
    /// Keys are compared byte for byte with their UTF-8, so a key spelled with escapes is not
    /// matched (it is then decoded normally, still within `maxDepth`).
    static func pruned(_ data: Data, maxDepth: Int, nullingTopLevelKeys: Set<String> = []) -> Data? {
        let keys = nullingTopLevelKeys.map { Array($0.utf8) }
        return data.withUnsafeBytes { raw -> Data? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var scanner = Scanner(bytes: bytes, maxDepth: max(0, maxDepth), keys: keys)
            return scanner.run().map { Data($0) }
        }
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        let maxDepth: Int
        let keys: [[UInt8]]
        /// Allocated on the first replacement, holding everything before it.
        var out: [UInt8]?
        var depth = 0
        /// The top-level container is an object and the next string at depth 1 is a member name.
        var topIsObject = false
        var expectKey = false
        /// The member name just read is one of `keys`: its value becomes `null`.
        var nullNextValue = false

        init(bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int, keys: [[UInt8]]) {
            self.bytes = bytes
            self.maxDepth = maxDepth
            self.keys = keys
        }

        mutating func run() -> [UInt8]? {
            var i = 0
            let count = bytes.count
            while i < count {
                let c = bytes[i]
                if Self.isWhitespace(c) || c == UInt8(ascii: ":") {
                    copy(i..<(i + 1))
                    i += 1
                    continue
                }
                if nullNextValue, depth == 1 {
                    // The value of a dropped member: skip it whole, whatever it is.
                    nullNextValue = false
                    let end = skipValue(from: i)
                    replace(i..<end)
                    i = end
                    continue
                }
                switch c {
                case UInt8(ascii: "\""):
                    let end = skipString(from: i)
                    if depth == 1, topIsObject, expectKey {
                        expectKey = false
                        nullNextValue = isDroppedKey(i..<end)
                    }
                    copy(i..<end)
                    i = end
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    if depth + 1 > maxDepth {
                        let end = skipValue(from: i)
                        replace(i..<end)
                        i = end
                        continue
                    }
                    depth += 1
                    if depth == 1 {
                        topIsObject = c == UInt8(ascii: "{")
                        expectKey = topIsObject
                    }
                    copy(i..<(i + 1))
                    i += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth = max(0, depth - 1)
                    copy(i..<(i + 1))
                    i += 1
                case UInt8(ascii: ","):
                    if depth == 1, topIsObject { expectKey = true }
                    copy(i..<(i + 1))
                    i += 1
                default:
                    copy(i..<(i + 1))
                    i += 1
                }
            }
            return out
        }

        private mutating func copy(_ range: Range<Int>) {
            guard out != nil else { return }
            out?.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[range]))
        }

        /// Writes `null` instead of `range`.
        private mutating func replace(_ range: Range<Int>) {
            if out == nil {
                var prefix: [UInt8] = []
                prefix.reserveCapacity(min(bytes.count, range.lowerBound + 64))
                prefix.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[..<range.lowerBound]))
                out = prefix
            }
            out?.append(contentsOf: Self.null)
        }

        private func isDroppedKey(_ quoted: Range<Int>) -> Bool {
            guard !keys.isEmpty, quoted.count >= 2 else { return false }
            let name = UnsafeBufferPointer(rebasing: bytes[(quoted.lowerBound + 1)..<(quoted.upperBound - 1)])
            return keys.contains { $0.elementsEqual(name) }
        }

        /// Index after the string starting at `start` (a `"`), or the end of the data.
        private func skipString(from start: Int) -> Int {
            var i = start + 1
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\\"): i += 2
                case UInt8(ascii: "\""): return i + 1
                default: i += 1
                }
            }
            return bytes.count
        }

        /// Index after the value starting at `start`: a string, a whole array or object (strings
        /// inside it skipped), or a scalar up to the next delimiter.
        private func skipValue(from start: Int) -> Int {
            switch bytes[start] {
            case UInt8(ascii: "\""):
                return skipString(from: start)
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var level = 0
                var i = start
                while i < bytes.count {
                    switch bytes[i] {
                    case UInt8(ascii: "\""):
                        i = skipString(from: i)
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        level += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        level -= 1
                        if level == 0 { return i + 1 }
                    default:
                        break
                    }
                    i += 1
                }
                return bytes.count
            default:
                var i = start
                while i < bytes.count {
                    let c = bytes[i]
                    if Self.isWhitespace(c) || c == UInt8(ascii: ",") || c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                        break
                    }
                    i += 1
                }
                return max(i, start + 1)
            }
        }

        private static let null: [UInt8] = Array("null".utf8)

        private static func isWhitespace(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }
    }
}
