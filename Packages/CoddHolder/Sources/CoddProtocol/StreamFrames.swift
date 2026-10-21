/// Payload layouts added to v1 behind capability flags (`attach.ack`, `gap.resync`).
///
/// Both carry a mode snapshot: `u32 TerminalModes.bits`, `u32 kitty flags`, `u8 flags` (bit0 = the
/// modes are known). A position is a resync point exactly when its modes are known; a fresh terminal
/// that applies `TerminalModes.restoreSequence()` and then replays from there shows what the child
/// left on screen.
enum ModeSnapshot {
    static let size = 9
    static let knownFlag: UInt8 = 1 << 0

    static func append(_ modes: TerminalModes?, to out: inout [UInt8]) {
        WireBytes.append(modes?.bits ?? 0, to: &out)
        WireBytes.append(modes?.kittyKeyboardFlags ?? 0, to: &out)
        out.append(modes == nil ? 0 : knownFlag)
    }

    /// Reads the snapshot at `index`; nil when the "known" flag is clear.
    static func read(_ payload: UnsafeRawBufferPointer, at index: Int) -> TerminalModes? {
        guard payload[index + 8] & knownFlag != 0 else { return nil }
        return TerminalModes(
            bits: WireBytes.readUInt32(payload, at: index),
            kittyKeyboardFlags: WireBytes.readUInt32(payload, at: index + 4))
    }
}

/// ATTACHED (h→c, 0x0012): `u64 start`, `u64 replayEnd`, mode snapshot (25 bytes), then (holders
/// advertising `attach.modes`) a second mode snapshot: the modes in effect when the ATTACH was
/// processed (34 bytes). A receiver that knows only the first 25 ignores the rest.
///
/// Sent once per ATTACH, to clients that listed `attach.ack` in HELLO `caps`, straight into the
/// outbound stream when the ATTACH is processed. Everything after it belongs to that ATTACH, so a
/// client that re-attaches on the same connection drops OUTPUT / GAP of the earlier attach that was
/// still in flight. OUTPUT then starts at `start`, unless a GAP follows (the requested offset fell
/// out of the ring). Bytes below `replayEnd` are history (a terminal must not answer queries in
/// them again); from `replayEnd` on the output is live.
public struct AttachedInfo: Sendable, Equatable {
    /// The v1 layout (the minimum accepted).
    public static let payloadSize = 16 + ModeSnapshot.size
    /// With `currentModes` (`attach.modes`).
    public static let extendedPayloadSize = payloadSize + ModeSnapshot.size

    /// Offset the ATTACH resolved to: the latest resync point, or the requested offset clamped to
    /// the end of the stream (below the ring start, the requested offset itself; a GAP follows).
    public var start: UInt64
    /// The holder's write offset when the ATTACH was processed.
    public var replayEnd: UInt64
    /// Modes in effect at `start` when it is a resync point that is still in the ring.
    public var modes: TerminalModes?
    /// Modes in effect at `replayEnd` (nil from a holder without `attach.modes`). The replay may
    /// start on the main screen while a full-screen program runs: this says it does.
    public var currentModes: TerminalModes?

    public init(start: UInt64, replayEnd: UInt64, modes: TerminalModes?, currentModes: TerminalModes? = nil) {
        self.start = start
        self.replayEnd = replayEnd
        self.modes = modes
        self.currentModes = currentModes
    }

    public init(payload: UnsafeRawBufferPointer) throws(ProtocolError) {
        guard payload.count >= Self.payloadSize else {
            throw .badPayload(type: .attached, reason: "expected at least \(Self.payloadSize) bytes, got \(payload.count)")
        }
        start = WireBytes.readUInt64(payload, at: 0)
        replayEnd = WireBytes.readUInt64(payload, at: 8)
        modes = ModeSnapshot.read(payload, at: 16)
        currentModes = payload.count >= Self.extendedPayloadSize ? ModeSnapshot.read(payload, at: Self.payloadSize) : nil
    }

    public init(payload: [UInt8]) throws(ProtocolError) {
        let result = payload.withUnsafeBytes { raw -> Result<AttachedInfo, ProtocolError> in
            do throws(ProtocolError) {
                return .success(try AttachedInfo(payload: raw))
            } catch {
                return .failure(error)
            }
        }
        self = try result.get()
    }

    public var payload: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.extendedPayloadSize)
        WireBytes.append(start, to: &out)
        WireBytes.append(replayEnd, to: &out)
        ModeSnapshot.append(modes, to: &out)
        ModeSnapshot.append(currentModes, to: &out)
        return out
    }

    public var frame: Frame { Frame(type: .attached, payload: payload) }
}

/// GAP (h→c, 0x0011) with the `gap.resync` extension: `u64 from`, `u64 to`, then `u64 replayEnd` and
/// a mode snapshot (33 bytes; a v1 decoder reads the first 16 and ignores the rest).
///
/// Bytes `[from, to)` were lost; OUTPUT continues at `to`, which is the ring's latest resync point
/// (or its oldest byte when no point survived; `resumeModes` is nil then). A client resets its
/// terminal, applies `resumeModes.restoreSequence()` and keeps feeding. Bytes below `replayEnd`
/// (the holder's write offset when the GAP was generated) are history, like after ATTACH.
public struct GapInfo: Sendable, Equatable {
    public static let v1PayloadSize = 16
    public static let payloadSize = 24 + ModeSnapshot.size

    public var from: UInt64
    public var to: UInt64
    /// nil from a holder without `gap.resync`.
    public var replayEnd: UInt64?
    public var resumeModes: TerminalModes?

    public init(from: UInt64, to: UInt64, replayEnd: UInt64?, resumeModes: TerminalModes?) {
        self.from = from
        self.to = to
        self.replayEnd = replayEnd
        self.resumeModes = resumeModes
    }

    public init(payload: UnsafeRawBufferPointer) throws(ProtocolError) {
        guard payload.count >= Self.v1PayloadSize else {
            throw .badPayload(type: .gap, reason: "expected at least 16 bytes, got \(payload.count)")
        }
        from = WireBytes.readUInt64(payload, at: 0)
        to = WireBytes.readUInt64(payload, at: 8)
        if payload.count >= Self.payloadSize {
            replayEnd = WireBytes.readUInt64(payload, at: 16)
            resumeModes = ModeSnapshot.read(payload, at: 24)
        } else {
            replayEnd = nil
            resumeModes = nil
        }
    }

    public init(payload: [UInt8]) throws(ProtocolError) {
        let result = payload.withUnsafeBytes { raw -> Result<GapInfo, ProtocolError> in
            do throws(ProtocolError) {
                return .success(try GapInfo(payload: raw))
            } catch {
                return .failure(error)
            }
        }
        self = try result.get()
    }

    /// The extended payload (a holder always sends it; `replayEnd` nil encodes as `to`).
    public var payload: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(Self.payloadSize)
        WireBytes.append(from, to: &out)
        WireBytes.append(to, to: &out)
        WireBytes.append(replayEnd ?? to, to: &out)
        ModeSnapshot.append(resumeModes, to: &out)
        return out
    }

    public var frame: Frame { Frame(type: .gap, payload: payload) }
}
