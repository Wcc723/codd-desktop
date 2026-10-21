/// INPUT flags byte.
public struct InputFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// The holder writes `\r` 10 ms after the last payload byte reached the PTY (50 ms after a paste).
    public static let submit = InputFlags(rawValue: 1 << 0)
    /// Capability `input.paste`: the frame's bytes are one paste. The holder wraps them in
    /// `ESC [ 200 ~ … ESC [ 201 ~` (markers inside removed) when the child has `?2004` on, else
    /// queues them unchanged. Holders without the capability ignore the bit.
    public static let paste = InputFlags(rawValue: 1 << 1)
}

/// RESIZE payload (TIOCSWINSZ).
public struct WindowSize: Sendable, Equatable {
    public var cols: UInt16
    public var rows: UInt16
    public var pixelWidth: UInt16
    public var pixelHeight: UInt16

    public init(cols: UInt16, rows: UInt16, pixelWidth: UInt16 = 0, pixelHeight: UInt16 = 0) {
        self.cols = cols
        self.rows = rows
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// EXIT payload: exit code, or the signal number when `signaled`.
public struct ExitInfo: Sendable, Equatable {
    public var status: Int32
    public var signaled: Bool

    public init(status: Int32, signaled: Bool) {
        self.status = status
        self.signaled = signaled
    }
}
