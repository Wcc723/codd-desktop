import CoddHolderClient
import CoddProtocol
import Synchronization

/// Everything one `HolderStream` delivered, for the checks to poll from the main thread (the
/// callbacks run on the stream's own queue).
final class StreamRecorder: Sendable {
    struct State {
        var welcome: Welcome?
        var attaches: [HolderAttach] = []
        /// OUTPUT bytes in delivery order (replay first, then live).
        var bytes: [UInt8] = []
        /// How many of `bytes` came as `.replay`.
        var replayBytes = 0
        /// Offset the next OUTPUT must start at (set by each attach and GAP).
        var nextOffset: UInt64?
        /// OUTPUT that did not continue the previous one.
        var discontinuities = 0
        var gaps: [GapInfo] = []
        var exit: ExitInfo?
        var error: ErrorInfo?
        var closed: HolderStreamCloseReason?
    }

    private let state = Mutex(State())

    /// Sets every callback of `stream`; call before `start`. The stream keeps the recorder alive
    /// until `onClosed`, the recorder never references the stream.
    init(_ stream: HolderStream) {
        stream.onWelcome = { welcome in self.update { $0.welcome = welcome } }
        stream.onAttach = { attach in
            self.update {
                $0.attaches.append(attach)
                $0.nextOffset = attach.start
            }
        }
        stream.onOutput = { offset, buffer, phase in
            let bytes = Array(buffer)
            self.update { state in
                if let expected = state.nextOffset, expected != offset { state.discontinuities += 1 }
                state.nextOffset = offset + UInt64(bytes.count)
                if phase == .replay { state.replayBytes += bytes.count }
                state.bytes.append(contentsOf: bytes)
            }
        }
        stream.onGap = { gap in
            self.update {
                $0.gaps.append(gap)
                $0.nextOffset = gap.to
            }
        }
        stream.onExit = { info in self.update { $0.exit = info } }
        stream.onError = { info in self.update { $0.error = info } }
        stream.onClosed = { reason in self.update { $0.closed = reason } }
    }

    private func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    func read<T: Sendable>(_ body: (State) -> T) -> T {
        state.withLock { body($0) }
    }

    var snapshot: State { read { $0 } }
}
