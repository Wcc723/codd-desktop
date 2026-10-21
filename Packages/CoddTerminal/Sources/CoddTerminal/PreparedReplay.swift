import Foundation

/// A history made ready to replay off the main actor: OSC 52 clipboard writes filtered out and
/// the bytes copied into the buffer the parser takes. Handing it to an engine is then O(1), so a
/// dead session's 8 MiB ring never passes through the main actor byte by byte (review
/// concurrency-perf-7; CLAUDE.md: terminal bytes never touch the main actor).
public struct PreparedReplay: Sendable {
    let data: Data

    public var count: Int { data.count }

    /// Filters and copies `bytes` (any thread; blocking for big histories). A clipboard sequence
    /// the history ends in is dropped: nothing live follows a prepared replay.
    public init(_ bytes: [UInt8]) {
        var filter = ReplayClipboardFilter()
        let filtered = bytes.withUnsafeBytes { filter.filterReplay($0) }
        data = filtered.map { Data($0) } ?? Data(bytes)
    }
}
