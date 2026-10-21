/// A resync point as the ring header stores it (`RingLayout` slots): replaying from `offset` onto a
/// reset terminal that first got `modes.restoreSequence()` reproduces what the child had drawn.
public struct RingResyncPoint: Sendable, Equatable {
    public var offset: UInt64
    /// Modes in effect AT `offset`.
    public var modes: TerminalModes

    public init(offset: UInt64, modes: TerminalModes) {
        self.offset = offset
        self.modes = modes
    }
}

/// Which resync point a replay of a ring starts from. One function for the live holder (WELCOME
/// `resync`, ATTACH `UINT64_MAX`, the GAP resume point) and `RingFileReader` (the last screen of a
/// session whose holder is gone), so the two can never pick differently for the same ring.
public enum RingResync {
    /// While a full-screen program runs, how much more a replay from the last main-screen point may
    /// cost than one from the newest alternate-screen point.
    public static let mainScreenReplayAllowance: UInt64 = 2 << 20

    /// The point to replay from, or nil when none is left in the ring (replay from `oldestOffset`
    /// then; the modes there are unknown).
    ///
    /// The newest point still in the ring. On the alternate screen, the last main-screen point
    /// instead, when it is still in the ring and at most `mainScreenReplayAllowance` before it: a
    /// replay from there restores the main screen the program returns to as well (from the newest
    /// point, quitting vim after a relaunch showed a blank shell; review E2E-4), and the allowance
    /// keeps a long-running TUI's reattach from replaying the whole ring.
    ///
    /// - Parameters:
    ///   - points: recorded points, oldest first (the holder's list, or the header's valid slots).
    ///   - oldestOffset: the ring's oldest stream offset (`writeOffset - capacity`, or 0).
    public static func replayPoint(_ points: [RingResyncPoint], oldestOffset: UInt64) -> RingResyncPoint? {
        guard let last = points.last, last.offset >= oldestOffset else { return nil }
        guard last.modes.altScreen,
              let main = points.last(where: { !$0.modes.altScreen }), main.offset >= oldestOffset,
              main.offset <= last.offset, last.offset - main.offset <= mainScreenReplayAllowance
        else { return last }
        return main
    }
}
