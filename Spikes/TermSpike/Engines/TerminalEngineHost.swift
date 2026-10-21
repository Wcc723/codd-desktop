import AppKit
import Synchronization
import TermSpikeKit

enum EngineKind: String, Codable, CaseIterable, Sendable {
    case ghostty
    case swiftterm

    var label: String {
        switch self {
        case .ghostty: "GHOSTTY"
        case .swiftterm: "SWIFTTERM"
        }
    }
}

/// Thread-safe feed into an engine ("bytes from the program"). Callable from
/// any thread; the buffer is only valid for the duration of the call.
struct EngineFeeder: Sendable {
    let feed: @Sendable (UnsafeRawBufferPointer) -> Void

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }
}

/// Lets a caller off the main thread observe and wait for parsing.
struct ParseControl: Sendable {
    /// Bytes accepted by the engine but not parsed yet (0 for synchronous engines).
    let pendingBytes: @Sendable () -> Int
    /// Blocks until everything fed so far is parsed. Call it off the main
    /// thread, and only while the main run loop is free: Ghostty's parse can
    /// wait for the main thread to drain its app mailbox (titles), so a
    /// background waiter needs the main thread ticking.
    let waitUntilParsed: @Sendable () -> Void
}

/// Routes what an engine writes "to the program" (key encodings, query
/// replies) and its size changes. Engines call `send` from whatever thread
/// they produce output on; the target is swapped by the pane / probe harness.
final class EngineIO: Sendable {
    private let outputTarget = Mutex<(@Sendable (Data) -> Void)?>(nil)
    private let resizeTarget = Mutex<(@Sendable (PTYWindowSize) -> Void)?>(nil)
    private let lastSize = Mutex<PTYWindowSize?>(nil)

    func setOutput(_ target: (@Sendable (Data) -> Void)?) {
        outputTarget.withLock { $0 = target }
    }

    func setResize(_ target: (@Sendable (PTYWindowSize) -> Void)?) {
        resizeTarget.withLock { $0 = target }
    }

    func send(_ data: Data) {
        guard !data.isEmpty else { return }
        outputTarget.withLock { $0 }?(data)
    }

    func resized(_ size: PTYWindowSize) {
        lastSize.withLock { $0 = size }
        resizeTarget.withLock { $0 }?(size)
    }

    /// The most recent size the engine reported (nil until its first layout).
    var currentSize: PTYWindowSize? { lastSize.withLock { $0 } }
}

/// The spike's view of a terminal engine. Everything here is main-actor
/// except `feeder` / `parseControl` / `io`, which are Sendable and used from
/// the PTY read queue and bench threads.
@MainActor
protocol TerminalEngineHost: AnyObject {
    var kind: EngineKind { get }
    var view: NSView { get }
    var io: EngineIO { get }
    var feeder: EngineFeeder { get }
    var parseControl: ParseControl { get }
    /// True once the engine can parse and answer (Ghostty: surface attached and sized).
    var isReady: Bool { get }
    var title: String { get }

    /// `TERM` and engine-specific variables for children of this engine.
    func childTerminal() -> (term: String, extra: [String: String])
    /// Called after `view` was added to (or removed from) a window.
    func viewDidChangeWindow()
    /// Hidden panes keep parsing but stop rendering. Ghostty: surface occlusion.
    /// SwiftTerm: the pane removes the view from the window (its frame driver
    /// only pauses for window-level invisibility), so this is a no-op there.
    func setRenderingSuspended(_ suspended: Bool)
    func processExited(status: Int32)
    /// Flow control for engines that queue output: `handler(true)` once more
    /// than `highWater` fed bytes wait to be parsed, `handler(false)` once at
    /// most `lowWater` do. Called on whatever thread crossed the mark. Engines
    /// that parse synchronously in `feeder` (SwiftTerm) never call it. `nil`
    /// removes the handler.
    func setBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (_ backlogged: Bool) -> Void)?)
    /// Feeds `bytes` as reconstructed history with the engine's own replies
    /// (DA, DECRQM, XTVERSION, OSC 7501, …) suppressed, parsing off the main
    /// thread, and returns once the bytes are parsed. Returns how it was done
    /// (for the report), or nil when the engine cannot do it. The caller must
    /// not feed live output concurrently (the holder replays the ring before
    /// streaming live bytes).
    func replayWithoutReplies(_ bytes: [UInt8]) async -> String?
    /// Visible text, one line per row (smoke tests; not used on hot paths).
    func screenText() -> String
    func tearDown()
}

@MainActor
enum EngineFactory {
    static func make(_ kind: EngineKind) -> any TerminalEngineHost {
        switch kind {
        case .ghostty: GhosttyHost()
        case .swiftterm: SwiftTermHost()
        }
    }
}
