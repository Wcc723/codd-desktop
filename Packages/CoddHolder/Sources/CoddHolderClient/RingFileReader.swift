import CoddPosix
import CoddProtocol
import Darwin
import Synchronization

/// The last screen of a session read from its `ring` file (`RingFileReader.read`).
public struct RingSnapshot: Sendable, Equatable {
    /// Stream offset of `bytes[0]`.
    public var start: UInt64
    /// Stream offset after the last byte (the holder's write offset when the file was read).
    public var end: UInt64
    /// The stream bytes `[start, end)`.
    public var bytes: [UInt8]
    /// Modes in effect at `start`: reset a terminal, apply `modes.restoreSequence()`, feed `bytes`.
    /// nil = no resync point survived (or fits the limit): `start` is the oldest byte kept, possibly
    /// inside an escape sequence, and the modes there are unknown.
    public var modes: TerminalModes?
    /// Where the last holder's child started writing (rings continue across holders).
    public var spawnOffset: UInt64
    public var childExited: Bool
    public var signaled: Bool
    /// Exit code, or the signal number when `signaled`; nil while the child had not exited.
    public var exitStatus: Int32?
    /// The holder went through its normal shutdown (header flag); false after a crash or `kill -9`.
    public var holderExitedCleanly: Bool
    /// PTY size the holder last applied.
    public var columns: Int
    public var rows: Int

    public init(
        start: UInt64, end: UInt64, bytes: [UInt8], modes: TerminalModes?, spawnOffset: UInt64, childExited: Bool,
        signaled: Bool, exitStatus: Int32?, holderExitedCleanly: Bool, columns: Int, rows: Int
    ) {
        self.start = start
        self.end = end
        self.bytes = bytes
        self.modes = modes
        self.spawnOffset = spawnOffset
        self.childExited = childExited
        self.signaled = signaled
        self.exitStatus = exitStatus
        self.holderExitedCleanly = holderExitedCleanly
        self.columns = columns
        self.rows = rows
    }
}

public enum RingFileError: Error, Sendable, Equatable, CustomStringConvertible {
    /// No file at the path.
    case missing
    /// The file is not a ring this build understands (magic, version, header size, capacity).
    case notARing(String)
    /// A system call failed, or the ring kept changing under the reader.
    case io(String)

    public var description: String {
        switch self {
        case .missing: "no ring file"
        case .notARing(let reason): "not a ring file: \(reason)"
        case .io(let reason): "cannot read the ring: \(reason)"
        }
    }
}

/// Reads a session's `ring` file from disk, for showing the last screen of a session whose holder
/// is gone (docs/ARCHITECTURE.md, "Ring"). Blocking; read-only (`O_RDONLY`, never `flock`, never
/// writes), so it also works while a holder owns the ring.
///
/// `start` is the point a live holder's WELCOME `resync` would report for the same ring: the
/// selection is `RingResync.replayPoint`, which the holder itself uses. A holder may be writing
/// concurrently (`RingLayout`): the resync table is copied until two copies agree, the data is
/// copied, then `writeOffset` is read again and every byte that the holder could have overwritten
/// meanwhile is dropped (start moves to the next resync point, else modes become unknown). That
/// drop is skipped when the header shows that no holder writes any more (see `writerIsGone`).
public enum RingFileReader {
    /// Whole-read retries when the holder restarted the ring or lapped the copy.
    static let attempts = 4
    /// Copies of the resync table compared before giving up on a stable one.
    static let tableAttempts = 32

    public static func read(path: String, limit: Int = 8 << 20) throws(RingFileError) -> RingSnapshot {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT || errno == ENOTDIR { throw .missing }
            throw .io(SystemError.current("open(\(path))").description)
        }
        defer { Descriptor.closeQuietly(fd) }
        let file = try RingFile(fd: fd)
        let limit = UInt64(max(0, limit))
        var lapped: RingSnapshot?
        for _ in 0..<attempts {
            switch try file.snapshot(limit: limit) {
            case .complete(let snapshot): return snapshot
            case .lapped(let snapshot): lapped = snapshot
            case .restarted: continue
            }
        }
        // A holder that writes almost a whole ring per copy: an empty snapshot at its write offset.
        guard let lapped else { throw .io("the ring kept restarting while it was read") }
        return lapped
    }
}

/// Outcome of one copy attempt.
private enum RingCopy {
    case complete(RingSnapshot)
    /// The holder overwrote everything copied (the snapshot is empty, at the write offset).
    case lapped(RingSnapshot)
    /// The write offset went backwards: a new holder started over on a fresh ring.
    case restarted
}

/// An open ring file whose layout was validated.
private struct RingFile {
    let fd: Int32
    let capacity: UInt64
    let headerSize: Int

    init(fd: Int32) throws(RingFileError) {
        self.fd = fd
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .io(SystemError.current("fstat").description) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw .notARing("not a regular file") }
        let size = UInt64(info.st_size)
        guard size >= UInt64(RingLayout.headerSize) else {
            throw .notARing("\(size) bytes, shorter than the \(RingLayout.headerSize)-byte header")
        }
        let header = try Self.readBytes(fd, at: 0, count: RingLayout.resyncArrayOffset)
        guard header.prefix(RingLayout.magic.count).elementsEqual(RingLayout.magic) else {
            throw .notARing("bad magic")
        }
        let version = header.loadLE(UInt32.self, at: RingLayout.versionOffset)
        guard version == RingLayout.version else { throw .notARing("version \(version)") }
        let headerSize = header.loadLE(UInt32.self, at: RingLayout.headerSizeOffset)
        guard headerSize == UInt32(RingLayout.headerSize) else { throw .notARing("header size \(headerSize)") }
        let capacity = header.loadLE(UInt64.self, at: RingLayout.capacityOffset)
        guard capacity > 0, capacity == size - UInt64(RingLayout.headerSize) else {
            throw .notARing("capacity \(capacity) does not match the file size \(size)")
        }
        self.capacity = capacity
        self.headerSize = RingLayout.headerSize
    }

    /// One copy, made consistent by dropping what the holder may have overwritten meanwhile.
    func snapshot(limit: UInt64) throws(RingFileError) -> RingCopy {
        let header = try Self.readBytes(fd, at: 0, count: RingLayout.resyncArrayOffset)
        let end = header.loadLE(UInt64.self, at: RingLayout.writeOffsetOffset)
        // Acquire for the kernel's copy above: the table and data copies below are ordered after
        // it, so they see everything the holder published up to `end` (it release-stores the
        // offset after the bytes are in place).
        atomicMemoryFence(ordering: .acquiring)
        let oldest = end > capacity ? end - capacity : 0
        let points = try resyncPoints(end: end)

        var start: UInt64
        var modes: TerminalModes?
        if let point = RingResync.replayPoint(points, oldestOffset: oldest) {
            (start, modes) = (point.offset, point.modes)
        } else {
            (start, modes) = (oldest, nil)
        }
        if end - start > limit {
            // The newest point that fits, else the oldest byte that does (modes unknown).
            if let point = points.last(where: { $0.offset <= end && end - $0.offset <= limit && $0.offset >= oldest }) {
                (start, modes) = (point.offset, point.modes)
            } else {
                (start, modes) = (end - limit, nil)
            }
        }

        var bytes = try copyData(from: start, to: end)
        // Ordered after the data copy: a writer that overwrote bytes we copied has moved
        // `writeOffset` at least that far by now, minus the one chunk it may still be writing.
        atomicMemoryFence(ordering: .acquiring)
        let headerAfter = try Self.readBytes(fd, at: 0, count: RingLayout.resyncArrayOffset)
        let after = headerAfter.loadLE(UInt64.self, at: RingLayout.writeOffsetOffset)
        guard after >= end else { return .restarted }
        let reach = after + UInt64(RingLayout.maxWriteChunk)
        let trusted = reach > capacity && !Self.writerIsGone(before: header, after: headerAfter) ? reach - capacity : 0
        var lapped = false
        if start < trusted {
            if trusted >= end {
                bytes = []
                (start, modes) = (end, nil)
                lapped = true
            } else {
                let next = points.first { $0.offset >= trusted && $0.offset <= end }
                let newStart = next?.offset ?? trusted
                bytes.removeFirst(Int(newStart - start))
                (start, modes) = (newStart, next?.modes)
            }
        }

        let flags = header.loadLE(UInt32.self, at: RingLayout.flagsOffset)
        let exited = flags & RingLayout.flagChildExited != 0
        let snapshot = RingSnapshot(
            start: start, end: end, bytes: bytes, modes: modes,
            spawnOffset: header.loadLE(UInt64.self, at: RingLayout.spawnOffsetOffset),
            childExited: exited,
            signaled: flags & RingLayout.flagSignaled != 0,
            exitStatus: exited ? Int32(bitPattern: header.loadLE(UInt32.self, at: RingLayout.exitStatusOffset)) : nil,
            holderExitedCleanly: flags & RingLayout.flagHolderExited != 0,
            columns: Int(header.loadLE(UInt16.self, at: RingLayout.colsOffset)),
            rows: Int(header.loadLE(UInt16.self, at: RingLayout.rowsOffset)))
        return lapped ? .lapped(snapshot) : .complete(snapshot)
    }

    /// No holder can have written during the copy, so nothing needs to be dropped: the header did
    /// not change, and its holder finished (header flag) or no longer runs (its pid is not a holder
    /// process). A new holder on the ring rewrites the header (flags, pid) before its first output,
    /// so one that started meanwhile shows up as a change. Without this, a dead session's replay
    /// would lose the oldest `maxWriteChunk` bytes of a full ring and could differ from WELCOME.
    private static func writerIsGone(before: [UInt8], after: [UInt8]) -> Bool {
        guard before == after else { return false }
        let flags = before.loadLE(UInt32.self, at: RingLayout.flagsOffset)
        if flags & RingLayout.flagHolderExited != 0 { return true }
        let holderPid = Int32(bitPattern: before.loadLE(UInt32.self, at: RingLayout.holderPidOffset))
        return holderPid > 0 && !SessionDirectory.isHolderProcess(holderPid)
    }

    /// The valid header slots, oldest first, from a table copy that two consecutive reads agree on
    /// (`resyncCount` and the slots are plain stores; a holder may be rewriting them). Points past
    /// `end` describe bytes this read does not have and are left out; so are offsets that go
    /// backwards (a damaged table). After `tableAttempts` disagreeing copies: no points.
    private func resyncPoints(end: UInt64) throws(RingFileError) -> [RingResyncPoint] {
        let tableStart = RingLayout.resyncCountOffset
        let tableLength = RingLayout.resyncModesArrayOffset + RingLayout.resyncSlots * 8 - tableStart
        var previous = try Self.readBytes(fd, at: tableStart, count: tableLength)
        for _ in 0..<RingFileReader.tableAttempts {
            atomicMemoryFence(ordering: .acquiring)
            let current = try Self.readBytes(fd, at: tableStart, count: tableLength)
            guard current == previous else {
                previous = current
                continue
            }
            let count = Int(current.loadLE(UInt32.self, at: 0))
            let valid = min(count, RingLayout.resyncSlots)
            var points: [RingResyncPoint] = []
            points.reserveCapacity(valid)
            for index in (count - valid)..<count {
                let slot = index % RingLayout.resyncSlots
                let offset = current.loadLE(UInt64.self, at: RingLayout.resyncArrayOffset - tableStart + slot * 8)
                let modesAt = RingLayout.resyncModesArrayOffset - tableStart + slot * 8
                let modes = TerminalModes(
                    bits: current.loadLE(UInt32.self, at: modesAt), kittyKeyboardFlags: current.loadLE(UInt32.self, at: modesAt + 4))
                guard offset <= end else { break }
                if let last = points.last, offset < last.offset { return [] }
                points.append(RingResyncPoint(offset: offset, modes: modes))
            }
            return points
        }
        return []
    }

    /// Stream bytes `[start, end)` (at most `capacity`), in up to two reads around the wrap.
    private func copyData(from start: UInt64, to end: UInt64) throws(RingFileError) -> [UInt8] {
        let count = Int(end - start)
        guard count > 0 else { return [] }
        var failure: RingFileError?
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            let index = Int(start % capacity)
            let first = min(count, Int(capacity) - index)
            let raw = UnsafeMutableRawBufferPointer(buffer)
            do throws(RingFileError) {
                try Self.read(fd, into: UnsafeMutableRawBufferPointer(rebasing: raw[0..<first]), at: headerSize + index)
                if first < count {
                    try Self.read(fd, into: UnsafeMutableRawBufferPointer(rebasing: raw[first..<count]), at: headerSize)
                }
                initialized = count
            } catch {
                failure = error
                initialized = 0
            }
        }
        if let failure { throw failure }
        return bytes
    }

    private static func readBytes(_ fd: Int32, at offset: Int, count: Int) throws(RingFileError) -> [UInt8] {
        var failure: RingFileError?
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            do throws(RingFileError) {
                try read(fd, into: UnsafeMutableRawBufferPointer(buffer), at: offset)
                initialized = count
            } catch {
                failure = error
                initialized = 0
            }
        }
        if let failure { throw failure }
        return bytes
    }

    /// `pread` until `buffer` is full; a short file (truncated by a new holder) is an error.
    private static func read(_ fd: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int) throws(RingFileError) {
        var done = 0
        while done < buffer.count {
            let count = pread(fd, buffer.baseAddress! + done, buffer.count - done, off_t(offset + done))
            if count > 0 {
                done += count
            } else if count == 0 {
                throw .io("the file ended at \(offset + done) (truncated while reading)")
            } else if errno != EINTR {
                throw .io(SystemError.current("pread").description)
            }
        }
    }
}

private extension Array where Element == UInt8 {
    /// Little-endian integer at `offset` (the ring header's byte order on every supported Mac).
    func loadLE<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
