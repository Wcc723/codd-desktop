/// Layout of the `ring` file in a session directory (mmap'd by the holder read-write, by the app read-only).
///
/// ```
/// offset  size  field (little-endian, naturally aligned)
///      0     8  magic "CODDRING"
///      8     4  version (1)
///     12     4  headerSize (4096)
///     16     8  capacity (data bytes)
///     24     8  writeOffset   stream offset of the next byte; release-stored AFTER the data is in place
///     32     8  spawnOffset   stream offset where the current holder's child started
///     40     4  holderPid
///     44     4  childPid
///     48     2  cols
///     50     2  rows
///     52     4  flags         bit0 child exited, bit1 signaled, bit2 holder exited cleanly
///     56     4  exitStatus
///     60     4  modes bits    TerminalModes.bits
///     64     4  kitty flags
///     68     4  resyncCount   resync points recorded (point i lives in slot i % 16; the last
///                             min(count, 16) are valid). It shrinks when leaving the alternate screen
///                             drops the points recorded on it (the slots are then rewritten from 0).
///     72   128  resync[16]    u64 stream offsets
///    200   128  resyncModes[16]  per slot: u32 TerminalModes.bits, u32 kitty flags in effect AT that
///                             offset (what a fresh terminal needs before replaying from it)
///   4096     …  data: the byte at stream offset `o` lives at headerSize + (o % capacity)
/// ```
///
/// Header fields other than `writeOffset` are plain stores without cross-process ordering: a reader
/// copies `resyncCount`, the slots, then `resyncCount` again, retries when it changed, and only
/// trusts offsets inside `[writeOffset - capacity, writeOffset]`. The point to replay from is
/// `RingResync.replayPoint` of the valid slots (oldest first): the same choice a live holder
/// reports in WELCOME `resync`.
///
/// Readers that copy data while the holder runs must re-read `writeOffset` afterwards and only trust
/// offsets `>= writeOffsetAfter - capacity + RingLayout.maxWriteChunk` (the holder reads the PTY
/// straight into the ring, in chunks of at most `maxWriteChunk`). `CoddHolderClient.RingFileReader`
/// is that reader (read-only, never locks).
public enum RingLayout {
    public static let magic: [UInt8] = Array("CODDRING".utf8)
    public static let version: UInt32 = 1
    public static let headerSize = 4096
    public static let resyncSlots = 16
    /// Largest single PTY read into the ring.
    public static let maxWriteChunk = 64 * 1024

    public static let magicOffset = 0
    public static let versionOffset = 8
    public static let headerSizeOffset = 12
    public static let capacityOffset = 16
    public static let writeOffsetOffset = 24
    public static let spawnOffsetOffset = 32
    public static let holderPidOffset = 40
    public static let childPidOffset = 44
    public static let colsOffset = 48
    public static let rowsOffset = 50
    public static let flagsOffset = 52
    public static let exitStatusOffset = 56
    public static let modesOffset = 60
    public static let kittyOffset = 64
    public static let resyncCountOffset = 68
    public static let resyncArrayOffset = 72
    /// `resyncSlots` entries of 8 bytes: u32 mode bits, u32 kitty flags.
    public static let resyncModesArrayOffset = 200

    public static let flagChildExited: UInt32 = 1 << 0
    public static let flagSignaled: UInt32 = 1 << 1
    public static let flagHolderExited: UInt32 = 1 << 2
}
