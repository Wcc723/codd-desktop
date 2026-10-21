/// Finds a primary device attributes reply (DA1, `ESC [ ? Ps ; … c`) in the bytes the terminal
/// writes back to the program, across arbitrary chunk boundaries.
///
/// CODD's probe policy (docs/M1-PLAN.md) keeps a new `claude` process's surface attached until
/// the terminal has answered its startup probes; Claude Code closes each probe burst with DA1, so
/// the first DA1 reply marks the point where every earlier probe has been answered. DA2 (`ESC [ >`)
/// and DECRPM (`ESC [ ? … $ y`) share the prefix but are not DA1. User keys never produce
/// `ESC [ ?`, so a match in the write stream is always a reply.
public struct DeviceAttributesReplyDetector: Sendable, Equatable {
    private enum State: Sendable, Equatable {
        case ground
        case escape
        case csi
        case parameters
    }

    private var state = State.ground
    /// Parameter bytes seen in the current candidate; a real reply has a handful.
    private var parameterCount = 0
    private static let maxParameterBytes = 64

    public init() {}

    /// Feeds the next chunk; true when a complete DA1 reply ends inside it.
    public mutating func consume(_ bytes: UnsafeRawBufferPointer) -> Bool {
        var found = false
        for byte in bytes where step(byte) {
            found = true
        }
        return found
    }

    public mutating func consume(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { consume($0) }
    }

    public mutating func reset() {
        state = .ground
        parameterCount = 0
    }

    /// One byte; true when it completes a reply.
    private mutating func step(_ byte: UInt8) -> Bool {
        if byte == 0x1B {
            state = .escape
            parameterCount = 0
            return false
        }
        switch state {
        case .ground:
            return false
        case .escape:
            state = byte == UInt8(ascii: "[") ? .csi : .ground
            return false
        case .csi:
            state = byte == UInt8(ascii: "?") ? .parameters : .ground
            return false
        case .parameters:
            if byte == UInt8(ascii: "c") {
                state = .ground
                return true
            }
            let isParameter = (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: ";")
            parameterCount += 1
            if !isParameter || parameterCount > Self.maxParameterBytes {
                state = .ground
            }
            return false
        }
    }
}
