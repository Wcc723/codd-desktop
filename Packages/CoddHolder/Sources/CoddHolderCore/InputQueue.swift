/// Bytes waiting to be written to the PTY master, plus submit markers.
///
/// PTY input capacity is about 1 KB, so writes are partial and resumed on EVFILT_WRITE. A submit
/// marker blocks everything behind it until the holder has written `\r`, 10 ms (50 ms behind a
/// paste) after the last byte in front of it reached the PTY; this keeps "paste, then Enter"
/// ordered even when more INPUT arrives during the delay.
struct InputQueue {
    enum Item: Equatable {
        case bytes([UInt8])
        /// `\r` after `Holder.submitDelayNanoseconds`.
        case submit
        /// `\r` after `Holder.pasteSubmitDelayNanoseconds`: the bytes in front were a paste, and a
        /// program that parses a bracketed paste must not take a quick `\r` as part of it.
        case pasteSubmit
    }

    private var items: [Item] = []
    private var headIndex = 0
    /// Bytes of the head item already written.
    private var headProgress = 0
    private(set) var pendingBytes = 0

    var isEmpty: Bool { headIndex == items.count }

    var head: Item? { isEmpty ? nil : items[headIndex] }

    /// Queues `bytes` (one paste unit when `paste`), then a submit marker if asked for.
    mutating func append(_ bytes: [UInt8], submit: Bool, paste: Bool = false) {
        if !bytes.isEmpty {
            items.append(.bytes(bytes))
            pendingBytes += bytes.count
        }
        if submit { items.append(paste ? .pasteSubmit : .submit) }
    }

    /// The head is a submit marker of either kind.
    var headIsSubmit: Bool { head == .submit || head == .pasteSubmit }

    /// Unwritten bytes of the head item, if it is a byte item.
    func withHeadBytes<R>(_ body: (UnsafeRawBufferPointer) -> R) -> R? {
        guard let head, case .bytes(let bytes) = head else { return nil }
        return bytes.withUnsafeBytes { raw in
            body(UnsafeRawBufferPointer(rebasing: raw[headProgress...]))
        }
    }

    /// Records that `count` bytes of the head item were written. Returns true when the item is done.
    @discardableResult
    mutating func consume(_ count: Int) -> Bool {
        guard let head, case .bytes(let bytes) = head else { return false }
        headProgress += count
        pendingBytes -= count
        if headProgress >= bytes.count {
            popHead()
            return true
        }
        return false
    }

    /// Replaces a submit marker at the head with the `\r` to write.
    mutating func resolveSubmit() {
        guard headIsSubmit else { return }
        items[headIndex] = .bytes([0x0D])
        headProgress = 0
        pendingBytes += 1
    }

    private mutating func popHead() {
        headIndex += 1
        headProgress = 0
        if headIndex == items.count {
            items.removeAll(keepingCapacity: items.capacity <= 64)
            headIndex = 0
        } else if headIndex >= 64 {
            items.removeFirst(headIndex)
            headIndex = 0
        }
    }

    mutating func removeAll() {
        items.removeAll()
        headIndex = 0
        headProgress = 0
        pendingBytes = 0
    }
}
