import CoddProtocol

/// A non-OUTPUT frame queued for a client. It is released only once the client's OUTPUT cursor has
/// passed `afterOffset`, so TITLE/BELL/EXIT never overtake the output that produced them.
struct ControlFrame {
    enum Kind {
        case title, cwd, bell, exit, pong, other

        /// Superseded or best-effort frames that may be dropped when the queue is full. PONG is
        /// droppable so a client that sends PINGs but never reads cannot grow the queue without bound.
        var isDroppable: Bool {
            switch self {
            case .title, .cwd, .bell, .pong: true
            case .exit, .other: false
            }
        }
    }

    var afterOffset: UInt64
    var kind: Kind
    var bytes: [UInt8]
}

/// FIFO of control frames, bounded so a stalled client cannot grow it without limit (only
/// non-droppable frames can exceed `limit`, and there is at most one WELCOME and one EXIT).
struct ControlQueue {
    static let limit = 256

    private var items: [ControlFrame] = []
    private var head = 0

    var first: ControlFrame? { head < items.count ? items[head] : nil }
    var count: Int { items.count - head }
    /// Slots held, released ones included (bounded by compaction in `removeFirst`).
    var storageCount: Int { items.count }

    mutating func push(_ frame: ControlFrame) {
        // A bell right behind an unsent bell adds nothing.
        if frame.kind == .bell, let last = items.last, head < items.count, last.kind == .bell { return }
        if count >= Self.limit {
            // Drop the oldest droppable frame; EXIT and handshake frames are never dropped.
            if let victim = items[head...].firstIndex(where: { $0.kind.isDroppable }) {
                items.remove(at: victim)
            } else if frame.kind.isDroppable {
                return
            }
        }
        items.append(frame)
    }

    mutating func removeFirst() {
        guard head < items.count else { return }
        head += 1
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 && head * 2 >= items.count {
            // A queue that never runs empty (titles keep arriving while a slow client is behind)
            // would otherwise keep every released frame forever.
            items.removeFirst(head)
            head = 0
        }
    }
}

/// One accepted socket: pending (before HELLO) or the attached client.
final class ClientConnection {
    /// Unique, never-reused kqueue tag.
    let tag: UInt
    let fd: Int32
    let acceptedAtNanoseconds: UInt64

    var decoder = FrameDecoder()
    var handshakeDone = false
    var clientName = ""
    /// HELLO `caps` listed `attach.ack`: every ATTACH is answered with ATTACHED.
    var wantsAttachAck = false

    /// Streaming OUTPUT (after ATTACH, until DETACH).
    var attached = false
    /// Next stream offset to send as OUTPUT.
    var cursor: UInt64 = 0
    /// Drop mode: the holder no longer pauses the PTY for this client; lapped bytes become GAP.
    var dropping = false
    /// Last time a socket write made progress (stall watchdog reference).
    var lastProgressNanoseconds: UInt64

    /// Materialized bytes not yet written (current frames).
    var outbuf: [UInt8] = []
    var outIndex = 0
    var control = ControlQueue()

    var writeInterestEnabled = false
    /// Socket reads are disabled because the PTY input queue is over its limit.
    var readPaused = false

    init(tag: UInt, fd: Int32, now: UInt64) {
        self.tag = tag
        self.fd = fd
        self.acceptedAtNanoseconds = now
        self.lastProgressNanoseconds = now
        outbuf.reserveCapacity(Self.outputFrameBytes + 64)
    }

    /// OUTPUT payload bytes per frame.
    static let outputFrameBytes = 64 * 1024
    /// Materialize more frames only while fewer than this many bytes are unsent.
    static let refillThreshold = 128 * 1024

    var unsentByteCount: Int { outbuf.count - outIndex }

    /// Bytes the client still has to receive: unsent frame bytes plus ring bytes past the cursor.
    func pendingBytes(writeOffset: UInt64) -> UInt64 {
        let ringPending = attached && writeOffset > cursor ? writeOffset - cursor : 0
        return ringPending + UInt64(unsentByteCount)
    }

    func enqueue(_ message: Message, kind: ControlFrame.Kind, afterOffset: UInt64) {
        control.push(ControlFrame(afterOffset: afterOffset, kind: kind, bytes: message.encoded()))
    }

    /// `outbuf` always starts on a frame boundary (everything appended is whole frames, and
    /// compaction only removes whole frames), so `reject` can find where the frame being written
    /// ends.
    func compactOutbuf() {
        if outIndex == outbuf.count {
            outbuf.removeAll(keepingCapacity: outbuf.capacity <= 512 * 1024)
            outIndex = 0
        } else if outIndex > 256 * 1024 {
            let boundary = frameStart(containing: outIndex)
            guard boundary > 0 else { return }
            outbuf.removeFirst(boundary)
            outIndex -= boundary
        }
    }

    /// Drops every frame not started on the wire yet; a partly written frame stays (it must be
    /// finished before anything else can follow it).
    func dropUnsentFrames() {
        let start = frameStart(containing: outIndex)
        let keep = start < outIndex ? min(outbuf.count, start + Self.frameLength(outbuf, at: start)) : start
        if keep < outbuf.count { outbuf.removeSubrange(keep...) }
    }

    /// Start of the frame that `index` falls into (`index` itself when a frame starts there).
    private func frameStart(containing index: Int) -> Int {
        var position = 0
        while position < outbuf.count {
            let end = position + Self.frameLength(outbuf, at: position)
            if end > index { return position }
            position = end
        }
        return position
    }

    /// Bytes of the frame at `position` (header included); the rest of the buffer when the
    /// length field itself is cut off.
    private static func frameLength(_ bytes: [UInt8], at position: Int) -> Int {
        guard bytes.count - position >= Frame.lengthFieldSize else { return bytes.count - position }
        let length = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8
            | Int(bytes[position + 3])
        return Frame.lengthFieldSize + length
    }
}
