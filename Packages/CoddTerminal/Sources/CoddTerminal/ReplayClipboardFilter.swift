import Darwin

/// Removes OSC 52 (clipboard) sequences from replayed history.
///
/// libghostty suppresses the replies a replay would provoke (patch 0011), but not a clipboard
/// write: with Ghostty's default `clipboard-write = allow`, every cold attach and every relaunch
/// re-ran whatever a program once copied through OSC 52 (tmux `set-clipboard`, nvim's OSC 52
/// provider, tools on an ssh host) and silently replaced what the user had copied since; a
/// hostile payload kept coming back on every switch. History is shown, never executed, so the
/// whole sequence goes, whatever its selection or payload (queries included).
///
/// Stateful across calls: a sequence split between two replay chunks is still dropped whole, and
/// so is one the replay ends in the middle of (a frame straddling the replay/live boundary): live
/// bytes pass through the filter only until that sequence is over. Live OSC 52 is never touched.
struct ReplayClipboardFilter: Sendable {
    private enum State: Sendable, Equatable {
        case ground
        /// After ESC (held back).
        case escape
        /// After `ESC ]` and these digits (held back).
        case oscNumber([UInt8])
        /// Inside an OSC 52: everything up to its terminator is dropped.
        case dropping
        /// ESC inside the dropped sequence: `\` ends it (ST), anything else starts a new one.
        case droppingEscape
    }

    private var state = State.ground

    /// Nothing is held back or being dropped: live bytes need no filtering.
    var isIdle: Bool { state == .ground }

    /// Forgets a sequence in progress (the history was cut: a reset or a new process follows).
    mutating func reset() {
        state = .ground
    }

    /// The replayed bytes to parse, or nil when they pass unchanged.
    ///
    /// Every replay goes through here (up to a whole 8 MiB ring per cold switch), so the common case
    /// is a `memchr` walk over the ESC bytes and no copy: only a chunk in which an OSC 52 starts,
    /// or that ends inside what could be one, takes the byte-by-byte path.
    mutating func filterReplay(_ bytes: UnsafeRawBufferPointer) -> [UInt8]? {
        let input = bytes.bindMemory(to: UInt8.self)
        guard state != .ground || Self.mayStartClipboardSequence(bytes) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(input.count + 8)
        for byte in input { step(byte, into: &out) }
        return out
    }

    /// Whether `ESC ] 5 2 ;` starts somewhere in `bytes`, or `bytes` ends with a proper prefix of it.
    private static func mayStartClipboardSequence(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return false }
        var index = 0
        while index < bytes.count, let hit = memchr(base + index, Int32(esc), bytes.count - index) {
            let at = base.distance(to: UnsafeRawPointer(hit))
            let available = min(bytes.count - at, introducer.count)
            var matches = true
            for k in 1..<available where bytes[at + k] != introducer[k] {
                matches = false
                break
            }
            if matches { return true }  // the whole introducer, or a prefix of it at the end
            index = at + 1
        }
        return false
    }

    /// Live bytes: filtered only while a sequence that began in the replay is unfinished; nil when
    /// they pass unchanged.
    mutating func filterLive(_ bytes: UnsafeRawBufferPointer) -> [UInt8]? {
        guard state != .ground else { return nil }
        let input = bytes.bindMemory(to: UInt8.self)
        var out: [UInt8] = []
        out.reserveCapacity(input.count + 8)
        var index = input.startIndex
        while index < input.endIndex, state != .ground {
            step(input[index], into: &out)
            index += 1
        }
        out.append(contentsOf: input[index...])
        return out
    }

    private mutating func step(_ byte: UInt8, into out: inout [UInt8]) {
        switch state {
        case .ground:
            if byte == Self.esc {
                state = .escape
            } else {
                out.append(byte)
            }
        case .escape:
            if byte == Self.oscIntroducer {
                state = .oscNumber([])
            } else {
                out.append(Self.esc)
                state = .ground
                step(byte, into: &out)
            }
        case .oscNumber(let digits):
            if byte == Self.semicolon, digits == Self.clipboardNumber {
                state = .dropping
            } else if (0x30...0x39).contains(byte), digits.count < Self.clipboardNumber.count {
                state = .oscNumber(digits + [byte])
            } else {
                // Another OSC (title, cwd, 520, ...): released as it came.
                out.append(Self.esc)
                out.append(Self.oscIntroducer)
                out.append(contentsOf: digits)
                state = .ground
                step(byte, into: &out)
            }
        case .dropping:
            switch byte {
            case Self.bel, Self.can, Self.sub: state = .ground
            case Self.esc: state = .droppingEscape
            default: break
            }
        case .droppingEscape:
            if byte == Self.backslash {
                state = .ground
            } else {
                // ESC ended the string and starts another sequence.
                state = .escape
                step(byte, into: &out)
            }
        }
    }

    private static let esc: UInt8 = 0x1B
    private static let bel: UInt8 = 0x07
    private static let can: UInt8 = 0x18
    private static let sub: UInt8 = 0x1A
    private static let oscIntroducer = UInt8(ascii: "]")
    private static let semicolon = UInt8(ascii: ";")
    private static let backslash = UInt8(ascii: "\\")
    private static let clipboardNumber: [UInt8] = Array("52".utf8)
    /// `ESC ] 5 2 ;`
    private static let introducer: [UInt8] = [0x1B] + Array("]52;".utf8)
}
