/// Terminal input/screen modes the holder tracks from the child's output, so a reattaching client can
/// restore them before replaying bytes (a lost `?2004h` would turn a multi-line paste into many submits).
///
/// WELCOME / meta.json form: `{"1":false,"25":true,"1000":false,"1002":false,"1003":false,"1004":false,
/// "1006":false,"1049":false,"2004":false,"2026":false,"kitty":0}` — keys are DEC private mode numbers
/// (47/1047 fold into 1049), `kitty` is the active screen's kitty keyboard flags.
public struct TerminalModes: Sendable, Equatable {
    /// DECCKM, `?1`.
    public var applicationCursorKeys = false
    /// DECTCEM, `?25`.
    public var cursorVisible = true
    /// `?1000` normal mouse tracking.
    public var mouseNormal = false
    /// `?1002` button-event mouse tracking.
    public var mouseButtonEvent = false
    /// `?1003` any-event mouse tracking.
    public var mouseAnyEvent = false
    /// `?1004` focus in/out reports.
    public var focusEvents = false
    /// `?1006` SGR mouse encoding.
    public var mouseSGR = false
    /// `?1049` / `?1047` / `?47` alternate screen.
    public var altScreen = false
    /// `?2004` bracketed paste.
    public var bracketedPaste = false
    /// `?2026` synchronized output (inside an update).
    public var synchronizedOutput = false
    /// Kitty keyboard protocol flags of the active screen (`CSI > n u` / `CSI < u` / `CSI = n ; m u`).
    public var kittyKeyboardFlags: UInt32 = 0

    public init() {}

    /// Applies `CSI ? mode h/l`. Returns false for modes that are not tracked.
    @discardableResult
    public mutating func setDECPrivateMode(_ mode: Int, _ enabled: Bool) -> Bool {
        switch mode {
        case 1: applicationCursorKeys = enabled
        case 25: cursorVisible = enabled
        case 1000: mouseNormal = enabled
        case 1002: mouseButtonEvent = enabled
        case 1003: mouseAnyEvent = enabled
        case 1004: focusEvents = enabled
        case 1006: mouseSGR = enabled
        case 47, 1047, 1049: altScreen = enabled
        case 2004: bracketedPaste = enabled
        case 2026: synchronizedOutput = enabled
        default: return false
        }
        return true
    }

    /// Bytes that put a freshly reset terminal into these modes. `?2026` is deliberately not restored:
    /// starting a synchronized update without its end would freeze the client's rendering.
    /// Before a replay, use the modes in effect at the replay's first byte (WELCOME `resyncModes`).
    public func restoreSequence() -> [UInt8] {
        var out: [UInt8] = []
        func dec(_ mode: Int, _ enabled: Bool) {
            out.append(contentsOf: "\u{1B}[?\(mode)\(enabled ? "h" : "l")".utf8)
        }
        if altScreen { dec(1049, true) }
        if applicationCursorKeys { dec(1, true) }
        if !cursorVisible { dec(25, false) }
        if mouseNormal { dec(1000, true) }
        if mouseButtonEvent { dec(1002, true) }
        if mouseAnyEvent { dec(1003, true) }
        if mouseSGR { dec(1006, true) }
        if focusEvents { dec(1004, true) }
        if bracketedPaste { dec(2004, true) }
        if kittyKeyboardFlags != 0 {
            out.append(contentsOf: "\u{1B}[>\(kittyKeyboardFlags)u".utf8)
        }
        return out
    }

    // MARK: - Compact bit form (ring header)

    private static let bitOrder: [Int] = [1, 25, 1000, 1002, 1003, 1004, 1006, 1049, 2004, 2026]

    private func isEnabled(_ mode: Int) -> Bool {
        switch mode {
        case 1: applicationCursorKeys
        case 25: cursorVisible
        case 1000: mouseNormal
        case 1002: mouseButtonEvent
        case 1003: mouseAnyEvent
        case 1004: focusEvents
        case 1006: mouseSGR
        case 1049: altScreen
        case 2004: bracketedPaste
        case 2026: synchronizedOutput
        default: false
        }
    }

    /// One bit per tracked DEC mode, in the order 1, 25, 1000, 1002, 1003, 1004, 1006, 1049, 2004, 2026.
    public var bits: UInt32 {
        var value: UInt32 = 0
        for (bit, mode) in TerminalModes.bitOrder.enumerated() where isEnabled(mode) {
            value |= 1 << UInt32(bit)
        }
        return value
    }

    public init(bits: UInt32, kittyKeyboardFlags: UInt32) {
        for (bit, mode) in TerminalModes.bitOrder.enumerated() {
            setDECPrivateMode(mode, bits & (1 << UInt32(bit)) != 0)
        }
        self.kittyKeyboardFlags = kittyKeyboardFlags
    }

    // MARK: - JSON

    public func jsonValue() -> JSONValue {
        var members = TerminalModes.bitOrder.map { JSONMember(String($0), .bool(isEnabled($0))) }
        members.append(JSONMember("kitty", .number(UInt64(kittyKeyboardFlags))))
        return .object(members)
    }

    /// Tolerant decoding: missing or malformed keys keep their defaults.
    public init(json: JSONValue) {
        for mode in TerminalModes.bitOrder {
            if let enabled = json[String(mode)]?.boolValue {
                setDECPrivateMode(mode, enabled)
            }
        }
        if let flags = json["kitty"]?.uint64Value {
            kittyKeyboardFlags = UInt32(truncatingIfNeeded: flags)
        }
    }
}

/// OSC 9;4 progress report (ConEmu / Windows Terminal convention, also emitted by some CLIs).
/// state: 0 none, 1 normal, 2 error, 3 indeterminate, 4 paused; value: 0-100.
/// JSON form (WELCOME / meta.json `progress`): `{"state":1,"value":42}`.
public struct TerminalProgress: Sendable, Equatable {
    public var state: Int
    public var value: Int

    public init(state: Int, value: Int) {
        self.state = state
        self.value = value
    }

    public func jsonValue() -> JSONValue {
        .object([JSONMember("state", .number(state)), JSONMember("value", .number(value))])
    }

    public init?(json: JSONValue) {
        guard let state = json["state"]?.intValue else { return nil }
        self.state = state
        self.value = json["value"]?.intValue ?? 0
    }
}
