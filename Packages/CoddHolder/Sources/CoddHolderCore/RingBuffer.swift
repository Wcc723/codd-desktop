import CCoddShim
import CoddPosix
import CoddProtocol
import Darwin

/// The session's output ring: an mmap'd file (layout in `RingLayout`) holding the last `capacity`
/// bytes of the child's output, addressed by monotonically increasing u64 stream offsets.
///
/// The PTY is read directly into the mapping (`writableRegion` + `commit`), so output survives a crash
/// of the holder or the app (the dirty pages belong to the file). An existing ring with a valid header
/// and the same capacity is continued, so offsets keep increasing across holder restarts.
/// Call `beginSession()` before the first append.
final class RingBuffer {
    let path: String
    let capacity: Int
    private let fd: Int32
    private let base: UnsafeMutableRawPointer
    private let mappedLength: Int
    private var data: UnsafeMutableRawPointer { base + RingLayout.headerSize }

    /// Stream offset of the next byte.
    private(set) var writeOffset: UInt64
    /// Stream offset where this holder started writing.
    let spawnOffset: UInt64
    /// Newest-last resync points (at most `RingLayout.resyncSlots`), exactly what the header slots hold.
    private(set) var resyncPoints: [RingResyncPoint] = []
    private var resyncCount: UInt32 = 0
    private var flags: UInt32 = 0

    /// Largest contiguous region handed out per PTY read.
    let maxChunk: Int

    /// Opens (or creates) the ring at `path`. Takes an exclusive flock so two holders never share a ring.
    init(path: String, capacity requested: Int) throws(SystemError) {
        let pageSize = 4096
        let capacity = (requested + pageSize - 1) / pageSize * pageSize
        self.path = path
        self.capacity = capacity
        self.maxChunk = min(RingLayout.maxWriteChunk, capacity / 2)
        let total = RingLayout.headerSize + capacity
        mappedLength = total

        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .current("open(\(path))") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = SystemError.current("flock(\(path)) (another holder owns this session)")
            Descriptor.closeQuietly(descriptor)
            throw error
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = SystemError.current("fstat(\(path))")
            Descriptor.closeQuietly(descriptor)
            throw error
        }
        let existingSize = Int(info.st_size)
        if existingSize != total {
            // Fresh file or a different capacity: start over (offsets restart at 0).
            guard ftruncate(descriptor, 0) == 0, ftruncate(descriptor, off_t(total)) == 0 else {
                let error = SystemError.current("ftruncate(\(path))")
                Descriptor.closeQuietly(descriptor)
                throw error
            }
        }
        guard let mapping = mmap(nil, total, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              mapping != UnsafeMutableRawPointer(bitPattern: -1)
        else {
            let error = SystemError.current("mmap(\(path))")
            Descriptor.closeQuietly(descriptor)
            throw error
        }
        fd = descriptor
        base = mapping

        let continued = existingSize == total && RingBuffer.headerIsValid(mapping, capacity: capacity)
        let resumeOffset = continued ? codd_load_acquire_u64(mapping + RingLayout.writeOffsetOffset) : 0
        writeOffset = resumeOffset
        spawnOffset = resumeOffset
        if !continued {
            memset(mapping, 0, RingLayout.headerSize)
            mapping.copyMemory(from: RingLayout.magic, byteCount: RingLayout.magic.count)
            store(RingLayout.version, at: RingLayout.versionOffset)
            store(UInt32(RingLayout.headerSize), at: RingLayout.headerSizeOffset)
            store(UInt64(capacity), at: RingLayout.capacityOffset)
        }
        if !continued {
            codd_store_release_u64(mapping + RingLayout.writeOffsetOffset, writeOffset)
        }
    }

    /// Marks the start of a new child in the header: clears the previous process's exit record and
    /// resync points and records `spawnOffset`. Called once the holder can no longer fail to start, so
    /// a holder that exits early (socket in use, …) leaves the previous holder's record intact.
    func beginSession() {
        memset(base + RingLayout.resyncArrayOffset, 0, RingLayout.resyncSlots * 8)
        memset(base + RingLayout.resyncModesArrayOffset, 0, RingLayout.resyncSlots * 8)
        resyncPoints.removeAll()
        resyncCount = 0
        store(UInt32(0), at: RingLayout.resyncCountOffset)
        flags = 0
        store(UInt32(0), at: RingLayout.flagsOffset)
        store(Int32(0), at: RingLayout.exitStatusOffset)
        store(spawnOffset, at: RingLayout.spawnOffsetOffset)
        codd_store_release_u64(base + RingLayout.writeOffsetOffset, writeOffset)
        recordResync(ResyncPoint(offset: spawnOffset, modes: TerminalModes()))
    }

    deinit {
        munmap(base, mappedLength)
        Descriptor.closeQuietly(fd)
    }

    private static func headerIsValid(_ mapping: UnsafeMutableRawPointer, capacity: Int) -> Bool {
        let magic = UnsafeRawBufferPointer(start: mapping, count: RingLayout.magic.count)
        guard magic.elementsEqual(RingLayout.magic) else { return false }
        let version = mapping.load(fromByteOffset: RingLayout.versionOffset, as: UInt32.self)
        let headerSize = mapping.load(fromByteOffset: RingLayout.headerSizeOffset, as: UInt32.self)
        let storedCapacity = mapping.load(fromByteOffset: RingLayout.capacityOffset, as: UInt64.self)
        return version == RingLayout.version && Int(headerSize) == RingLayout.headerSize
            && storedCapacity == UInt64(capacity)
    }

    private func store<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        base.storeBytes(of: value, toByteOffset: offset, as: T.self)
    }

    // MARK: - Data

    /// Oldest stream offset still held.
    var oldestOffset: UInt64 {
        writeOffset > UInt64(capacity) ? writeOffset - UInt64(capacity) : 0
    }

    /// Contiguous writable space at `writeOffset` (wraps at the end of the data area).
    func writableRegion() -> UnsafeMutableRawBufferPointer {
        let index = Int(writeOffset % UInt64(capacity))
        let length = min(maxChunk, capacity - index)
        return UnsafeMutableRawBufferPointer(start: data + index, count: length)
    }

    /// Publishes `count` bytes written into `writableRegion()`.
    func commit(_ count: Int) {
        writeOffset += UInt64(count)
        codd_store_release_u64(base + RingLayout.writeOffsetOffset, writeOffset)
    }

    /// Appends bytes produced by the holder itself (e.g. an exec failure message).
    func append(_ bytes: [UInt8]) {
        var remaining = bytes[...]
        while !remaining.isEmpty {
            let region = writableRegion()
            let count = min(region.count, remaining.count)
            region.copyBytes(from: remaining.prefix(count))
            commit(count)
            remaining = remaining.dropFirst(count)
        }
    }

    /// Appends `count` bytes starting at stream offset `offset` to `out`.
    /// - Precondition: `oldestOffset <= offset` and `offset + count <= writeOffset`.
    func copy(from offset: UInt64, count: Int, into out: inout [UInt8]) {
        precondition(offset >= oldestOffset && offset + UInt64(count) <= writeOffset, "ring range out of bounds")
        let start = Int(offset % UInt64(capacity))
        let first = min(count, capacity - start)
        out.append(contentsOf: UnsafeRawBufferPointer(start: data + start, count: first))
        if first < count {
            out.append(contentsOf: UnsafeRawBufferPointer(start: data, count: count - first))
        }
    }

    // MARK: - Resync points

    func recordResync(_ event: ResyncPoint) {
        if event.leavesAlternateScreen {
            recordAlternateScreenExit(event)
            return
        }
        let point = RingResyncPoint(offset: event.offset, modes: event.modes)
        if resyncPoints.last?.offset == point.offset {
            // Same offset (e.g. a RIS right after a clear): keep the latest modes, header slot included.
            resyncPoints[resyncPoints.count - 1] = point
            storeResyncModes(point.modes, slot: Int((resyncCount &- 1) % UInt32(RingLayout.resyncSlots)))
            return
        }
        if point.modes.altScreen, let last = resyncPoints.last, last.modes.altScreen {
            // On the alternate screen only the newest point is worth keeping (each one reproduces
            // the full-screen program at least as well as the one before). Appending let a program
            // that redraws often (every SIGWINCH, every REPAINT) push every main-screen point out
            // of the 16 slots, so leaving the alternate screen found none to return to and the
            // replay lost main-screen history still in the ring (review finding).
            resyncPoints[resyncPoints.count - 1] = point
            let slot = Int((resyncCount &- 1) % UInt32(RingLayout.resyncSlots))
            store(point.offset, at: RingLayout.resyncArrayOffset + slot * 8)
            storeResyncModes(point.modes, slot: slot)
            return
        }
        resyncPoints.append(point)
        if resyncPoints.count > RingLayout.resyncSlots { resyncPoints.removeFirst() }
        let slot = Int(resyncCount % UInt32(RingLayout.resyncSlots))
        storeResyncModes(point.modes, slot: slot)
        store(point.offset, at: RingLayout.resyncArrayOffset + slot * 8)
        resyncCount &+= 1
        store(resyncCount, at: RingLayout.resyncCountOffset)
    }

    /// The main screen is back as it was before the switch: points recorded on the alternate screen
    /// can no longer reproduce it, so they are dropped and the last main-screen point becomes the
    /// latest again (replaying from it re-runs the alternate-screen session and the exit). Only when
    /// no main-screen point survives in the ring does the exit offset itself become the resync point
    /// (the replay then starts on a blank main screen, but on a clean sequence boundary).
    private func recordAlternateScreenExit(_ exit: ResyncPoint) {
        let before = resyncPoints.count
        while let last = resyncPoints.last, last.modes.altScreen {
            resyncPoints.removeLast()
        }
        if resyncPoints.count != before { rewriteResyncSlots() }
        if latestSurvivingResync == nil {
            var fallback = exit
            fallback.leavesAlternateScreen = false
            recordResync(fallback)
        }
    }

    /// Rewrites the header's resync slots from `resyncPoints` (index i in slot i, count = points).
    private func rewriteResyncSlots() {
        memset(base + RingLayout.resyncArrayOffset, 0, RingLayout.resyncSlots * 8)
        memset(base + RingLayout.resyncModesArrayOffset, 0, RingLayout.resyncSlots * 8)
        for (slot, point) in resyncPoints.enumerated() {
            store(point.offset, at: RingLayout.resyncArrayOffset + slot * 8)
            storeResyncModes(point.modes, slot: slot)
        }
        resyncCount = UInt32(resyncPoints.count)
        store(resyncCount, at: RingLayout.resyncCountOffset)
    }

    private func storeResyncModes(_ modes: TerminalModes, slot: Int) {
        store(modes.bits, at: RingLayout.resyncModesArrayOffset + slot * 8)
        store(modes.kittyKeyboardFlags, at: RingLayout.resyncModesArrayOffset + slot * 8 + 4)
    }

    /// Latest resync point still in the ring, or `oldestOffset` when none survived.
    var latestResync: UInt64 {
        latestSurvivingResync?.offset ?? oldestOffset
    }

    /// Modes in effect at `latestResync`; nil when it fell back to `oldestOffset` (modes unknown).
    var latestResyncModes: TerminalModes? {
        latestSurvivingResync?.modes
    }

    /// Modes recorded for the resync point at exactly `offset`, if that point is still in the ring.
    func resyncModes(at offset: UInt64) -> TerminalModes? {
        guard offset >= oldestOffset else { return nil }
        return resyncPoints.last { $0.offset == offset }?.modes
    }

    /// See `RingResync.mainScreenReplayAllowance`.
    static let mainScreenReplayAllowance = RingResync.mainScreenReplayAllowance

    /// The point a replay starts from. `RingResync.replayPoint` is shared with `RingFileReader`, which
    /// applies it to the header slots, so a session whose holder is gone replays from exactly the
    /// point this holder reported in WELCOME.
    private var latestSurvivingResync: RingResyncPoint? {
        RingResync.replayPoint(resyncPoints, oldestOffset: oldestOffset)
    }

    // MARK: - Header snapshot fields

    func setProcesses(holder: pid_t, child: pid_t) {
        store(Int32(holder), at: RingLayout.holderPidOffset)
        store(Int32(child), at: RingLayout.childPidOffset)
    }

    func setSize(cols: UInt16, rows: UInt16) {
        store(cols, at: RingLayout.colsOffset)
        store(rows, at: RingLayout.rowsOffset)
    }

    func setModes(_ modes: TerminalModes) {
        store(modes.bits, at: RingLayout.modesOffset)
        store(modes.kittyKeyboardFlags, at: RingLayout.kittyOffset)
    }

    func setExit(status: Int32, signaled: Bool) {
        store(status, at: RingLayout.exitStatusOffset)
        flags |= RingLayout.flagChildExited | (signaled ? RingLayout.flagSignaled : 0)
        store(flags, at: RingLayout.flagsOffset)
    }

    func markHolderExited() {
        flags |= RingLayout.flagHolderExited
        store(flags, at: RingLayout.flagsOffset)
    }

    /// Schedules write-back of dirty pages (MS_ASYNC) or waits for it (MS_SYNC).
    func flush(synchronous: Bool) {
        msync(base, mappedLength, synchronous ? MS_SYNC : MS_ASYNC)
    }
}
