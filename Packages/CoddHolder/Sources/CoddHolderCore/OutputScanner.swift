import CoddProtocol
import Darwin

/// Tiny escape-sequence scanner over the child's output (no emulator).
///
/// Follows the DEC/vt100.net parser state machine closely enough to stay in sync with a real
/// terminal engine (ESC aborts any string or sequence, CAN/SUB return to ground, C0 controls inside
/// CSI are executed) and tracks:
/// - OSC 0/2 title, OSC 7 cwd (file:// URL decoded), OSC 9;4 progress, BEL outside strings;
/// - DEC private modes (see `TerminalModes`) and kitty keyboard flag stacks (one per screen);
/// - resync points: the offset right after `CSI 2 J`, `ESC c` and the switch from the main
///   to the alternate screen (`?1049/1047/47 h`), plus alternate-screen exits (`?… l`), which
///   invalidate the points recorded on the alternate screen (see `ResyncPoint.leavesAlternateScreen`).
///
/// The ground state skips text with `memchr`, so plain output costs two vectorized scans.
/// A resync point: replaying from `offset` onto a reset terminal that first got `modes` reproduces
/// the screen and the input modes (kitty flags included) exactly as the child left them.
struct ResyncPoint: Equatable {
    var offset: UInt64
    /// Modes in effect right after the clearing sequence (alt screen already entered, etc.).
    var modes: TerminalModes
    /// Not a resync point but an alternate-screen exit at `offset`. Leaving the alternate screen
    /// brings back the main screen as it was before the switch, so the points recorded on the
    /// alternate screen cannot reproduce the screen any more; the ring drops them and replays from
    /// the last main-screen point instead (`offset` only serves as a fallback when none is left).
    var leavesAlternateScreen = false
}

struct OutputScanner {
    private enum State: UInt8 {
        case ground, escape, escapeIntermediate, csi, csiIgnore, osc, string
    }

    /// Accumulated results since the last `takeEvents()`.
    struct Events: Equatable {
        var titleChanged = false
        var cwdChanged = false
        var progressChanged = false
        var modesChanged = false
        var bells = 0
        /// A `?2026l` (end of synchronized update) was seen.
        var syncEnded = false
        /// Resync points and alternate-screen exits in stream order (bounded); apply them in order.
        var resyncs: [ResyncPoint] = []

        var isEmpty: Bool { self == Events() }
    }

    static let maxOSCLength = 4096
    static let maxParameters = 16
    static let maxKittyDepth = 16

    private(set) var modes = TerminalModes()
    private(set) var title: String?
    private(set) var cwd: String?
    private(set) var progress: TerminalProgress?
    private var events = Events()

    private var state = State.ground
    private var privateMarker: UInt8 = 0
    private var intermediate: UInt8 = 0
    private var parameters: [Int] = []
    private var currentParameter = -1
    private var oscBuffer: [UInt8] = []
    private var oscOverflow = false
    private var kittyMain: [UInt32] = []
    private var kittyAlternate: [UInt32] = []

    init() {
        parameters.reserveCapacity(Self.maxParameters)
        oscBuffer.reserveCapacity(256)
    }

    mutating func takeEvents() -> Events {
        let taken = events
        events = Events()
        return taken
    }

    /// Scans `bytes`, whose first byte has stream offset `offset`.
    mutating func scan(_ bytes: UnsafeRawBufferPointer, at offset: UInt64) {
        guard let base = bytes.baseAddress else { return }
        let count = bytes.count
        var index = 0
        while index < count {
            if state == .ground {
                let remaining = count - index
                let escape = memchr(base + index, 0x1B, remaining).map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                countBells(base, from: index, to: escape)
                guard escape < count else { return }
                index = escape + 1
                state = .escape
                continue
            }
            let byte = base.load(fromByteOffset: index, as: UInt8.self)
            index += 1
            step(byte, offsetAfter: offset + UInt64(index))
        }
    }

    private mutating func countBells(_ base: UnsafeRawPointer, from start: Int, to end: Int) {
        var position = start
        while position < end, let bell = memchr(base + position, 0x07, end - position) {
            events.bells += 1
            position = base.distance(to: UnsafeRawPointer(bell)) + 1
        }
    }

    private mutating func step(_ byte: UInt8, offsetAfter: UInt64) {
        // "Anywhere" transitions of the DEC parser.
        switch byte {
        case 0x18, 0x1A:  // CAN, SUB
            state = .ground
            return
        case 0x1B:
            if state == .osc { dispatchOSC() }
            state = .escape
            return
        default:
            break
        }

        switch state {
        case .ground:
            if byte == 0x07 { events.bells += 1 }
        case .escape:
            switch byte {
            case 0x5B:  // [
                beginCSI()
            case 0x5D:  // ]
                oscBuffer.removeAll(keepingCapacity: true)
                oscOverflow = false
                state = .osc
            case 0x50, 0x58, 0x5E, 0x5F:  // DCS, SOS, PM, APC
                state = .string
            case 0x63:  // RIS
                resetToInitialState()
                recordResync(offsetAfter)
                state = .ground
            case 0x20...0x2F:
                state = .escapeIntermediate
            case 0x07:
                events.bells += 1
            case 0x00...0x1F, 0x7F:
                break  // executed / ignored, stay in escape
            default:
                state = .ground
            }
        case .escapeIntermediate:
            if (0x30...0x7E).contains(byte) { state = .ground }
        case .csi:
            stepCSI(byte, offsetAfter: offsetAfter)
        case .csiIgnore:
            if (0x40...0x7E).contains(byte) {
                state = .ground
            } else if byte == 0x07 {
                events.bells += 1
            }
        case .osc:
            if byte == 0x07 {
                dispatchOSC()
                state = .ground
            } else if byte >= 0x20 || byte == 0x09 {
                if oscBuffer.count < Self.maxOSCLength {
                    oscBuffer.append(byte)
                } else {
                    oscOverflow = true
                }
            }
        case .string:
            break  // DCS / SOS / PM / APC payload: ignored until ESC (ST) or CAN/SUB.
        }
    }

    // MARK: - CSI

    private mutating func beginCSI() {
        state = .csi
        privateMarker = 0
        intermediate = 0
        parameters.removeAll(keepingCapacity: true)
        currentParameter = -1
    }

    private mutating func stepCSI(_ byte: UInt8, offsetAfter: UInt64) {
        switch byte {
        case 0x30...0x39:
            let digit = Int(byte - 0x30)
            currentParameter = currentParameter < 0 ? digit : min(currentParameter * 10 + digit, 1 << 20)
        case 0x3A, 0x3B:  // ':' sub-parameter and ';' separators
            pushParameter()
        case 0x3C...0x3F:
            if parameters.isEmpty && currentParameter < 0 && privateMarker == 0 && intermediate == 0 {
                privateMarker = byte
            } else {
                state = .csiIgnore
            }
        case 0x20...0x2F:
            intermediate = byte
        case 0x40...0x7E:
            pushParameter()
            dispatchCSI(final: byte, offsetAfter: offsetAfter)
            state = .ground
        case 0x07:
            events.bells += 1
        default:
            break  // other C0 controls are executed by the terminal, nothing to track
        }
    }

    private mutating func pushParameter() {
        if parameters.count < Self.maxParameters {
            parameters.append(currentParameter)  // -1 = omitted
        }
        currentParameter = -1
    }

    private func parameter(_ index: Int, default fallback: Int) -> Int {
        guard index < parameters.count, parameters[index] >= 0 else { return fallback }
        return parameters[index]
    }

    private mutating func dispatchCSI(final: UInt8, offsetAfter: UInt64) {
        switch (privateMarker, intermediate, final) {
        case (UInt8(ascii: "?"), 0, UInt8(ascii: "h")), (UInt8(ascii: "?"), 0, UInt8(ascii: "l")):
            let enabled = final == UInt8(ascii: "h")
            let wasAlternate = modes.altScreen
            for mode in parameters where mode >= 0 {
                applyDECMode(mode, enabled)
            }
            // Recorded after the whole sequence: `offsetAfter` is past every parameter, so the point
            // must carry all of them (`CSI ? 1049 ; 1 h` includes application cursor keys).
            if !wasAlternate && modes.altScreen {
                recordResync(offsetAfter)
            } else if wasAlternate && !modes.altScreen {
                recordAlternateScreenExit(offsetAfter)
            }
        case (0, 0, UInt8(ascii: "J")):
            let mode = parameter(0, default: 0)
            // Only 2 clears the visible screen. 3 erases just the scrollback: a replay from right
            // after a lone `CSI 3 J` would lose what is still on screen. (`clear` sends 2J then 3J,
            // so its point after 2J replays the 3J harmlessly.)
            if mode == 2 { recordResync(offsetAfter) }
        case (UInt8(ascii: ">"), 0, UInt8(ascii: "u")):
            pushKitty(UInt32(clamping: parameter(0, default: 0)))
        case (UInt8(ascii: "<"), 0, UInt8(ascii: "u")):
            popKitty(parameter(0, default: 1))
        case (UInt8(ascii: "="), 0, UInt8(ascii: "u")):
            setKitty(UInt32(clamping: parameter(0, default: 0)), mode: parameter(1, default: 1))
        case (0, UInt8(ascii: "!"), UInt8(ascii: "p")):  // DECSTR soft reset
            var updated = modes
            updated.applicationCursorKeys = false
            updated.cursorVisible = true
            updateModes(updated)
        default:
            break
        }
    }

    private mutating func applyDECMode(_ mode: Int, _ enabled: Bool) {
        var updated = modes
        guard updated.setDECPrivateMode(mode, enabled) else { return }
        let screenSwitch = mode == 47 || mode == 1047 || mode == 1049
        if mode == 2026 && !enabled { events.syncEnded = true }
        if screenSwitch {
            updated.kittyKeyboardFlags = (enabled ? kittyAlternate : kittyMain).last ?? 0
        }
        updateModes(updated)
    }

    private mutating func updateModes(_ updated: TerminalModes) {
        if updated != modes {
            modes = updated
            events.modesChanged = true
        }
    }

    // MARK: - Kitty keyboard protocol

    private mutating func withActiveKittyStack(_ body: (inout [UInt32]) -> Void) {
        if modes.altScreen {
            body(&kittyAlternate)
        } else {
            body(&kittyMain)
        }
        var updated = modes
        updated.kittyKeyboardFlags = (modes.altScreen ? kittyAlternate : kittyMain).last ?? 0
        updateModes(updated)
    }

    private mutating func pushKitty(_ flags: UInt32) {
        withActiveKittyStack { stack in
            if stack.count >= Self.maxKittyDepth { stack.removeFirst() }
            stack.append(flags)
        }
    }

    private mutating func popKitty(_ count: Int) {
        withActiveKittyStack { stack in
            stack.removeLast(min(max(count, 0), stack.count))
        }
    }

    /// `CSI = flags ; mode u`: 1 = replace, 2 = set bits, 3 = clear bits (of the top entry).
    private mutating func setKitty(_ flags: UInt32, mode: Int) {
        withActiveKittyStack { stack in
            let current = stack.last ?? 0
            let next: UInt32
            switch mode {
            case 2: next = current | flags
            case 3: next = current & ~flags
            default: next = flags
            }
            if stack.isEmpty {
                stack.append(next)
            } else {
                stack[stack.count - 1] = next
            }
        }
    }

    // MARK: - OSC

    private mutating func dispatchOSC() {
        guard !oscOverflow else { return }
        let bytes = oscBuffer
        let separator = bytes.firstIndex(of: UInt8(ascii: ";")) ?? bytes.endIndex
        let command = String(decoding: bytes[..<separator], as: UTF8.self)
        let text = separator < bytes.endIndex ? Array(bytes[(separator + 1)...]) : []
        switch command {
        case "0", "2":
            let newTitle = String(decoding: text, as: UTF8.self)
            if newTitle != title {
                title = newTitle
                events.titleChanged = true
            }
        case "7":
            if let path = OutputScanner.decodeCwdURL(text), path != cwd {
                cwd = path
                events.cwdChanged = true
            }
        case "9":
            if let parsed = OutputScanner.parseProgress(text), parsed != progress {
                progress = parsed
                events.progressChanged = true
            }
        default:
            break
        }
    }

    /// OSC 9;4;state;value (ConEmu progress). Plain OSC 9 notifications return nil.
    static func parseProgress(_ text: [UInt8]) -> TerminalProgress? {
        let fields = text.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        guard fields.first.map({ Array($0) }) == [UInt8(ascii: "4")] else { return nil }
        func number(_ index: Int) -> Int {
            guard index < fields.count else { return 0 }
            return Int(String(decoding: fields[index], as: UTF8.self)) ?? 0
        }
        return TerminalProgress(state: number(1), value: min(max(number(2), 0), 100))
    }

    /// `file://host/path%20x` → `/path x`; plain absolute paths pass through.
    static func decodeCwdURL(_ text: [UInt8]) -> String? {
        var bytes = text[...]
        for scheme in ["file://", "kitty-shell-cwd://"] {
            let prefix = Array(scheme.utf8)
            if bytes.starts(with: prefix) {
                bytes = bytes.dropFirst(prefix.count)
                guard let slash = bytes.firstIndex(of: UInt8(ascii: "/")) else { return nil }
                bytes = bytes[slash...]
                break
            }
        }
        guard bytes.first == UInt8(ascii: "/") else { return nil }
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.endIndex,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(byte)
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: - Reset / resync

    private mutating func resetToInitialState() {
        kittyMain.removeAll()
        kittyAlternate.removeAll()
        updateModes(TerminalModes())
    }

    /// Records `offset` with the modes in effect there (callers update `modes` first).
    private mutating func recordResync(_ offset: UInt64) {
        appendResyncEvent(ResyncPoint(offset: offset, modes: modes))
    }

    /// Reports that the alternate screen was left at `offset` (modes are the main screen's again).
    private mutating func recordAlternateScreenExit(_ offset: UInt64) {
        appendResyncEvent(ResyncPoint(offset: offset, modes: modes, leavesAlternateScreen: true))
    }

    private mutating func appendResyncEvent(_ point: ResyncPoint) {
        let offset = point.offset
        if events.resyncs.last?.offset == offset {
            events.resyncs[events.resyncs.count - 1] = point
            return
        }
        if events.resyncs.count >= RingLayout.resyncSlots { events.resyncs.removeFirst() }
        events.resyncs.append(point)
    }
}
