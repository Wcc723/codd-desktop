import AppKit
import Synchronization
import TermSpikeKit

/// A real, on-screen window for automated runs. Ghostty only creates a surface
/// for a view that is in a window and has a size; a floating window in the
/// top-left corner stays unoccluded so "visible" really renders.
@MainActor
final class HarnessWindow {
    let window: NSWindow
    let content: NSView

    init(size: NSSize = NSSize(width: 1000, height: 640), title: String) {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: screenFrame.minX + 40, y: screenFrame.maxY - size.height - 40)
        window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.level = .floating
        window.isReleasedWhenClosed = false
        content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        window.contentView = content
        window.orderFrontRegardless()
    }

    /// Adds `view` filling the content view.
    func host(_ view: NSView) {
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)
    }

    func makeKey(_ view: NSView) {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    var isVisibleOnScreen: Bool { window.occlusionState.contains(.visible) }

    func close() {
        window.orderOut(nil)
        window.close()
    }
}

@MainActor
enum Wait {
    /// Lets the main run loop work (Ghostty ticks, SwiftTerm main-actor hops)
    /// until `condition` holds or `timeout` passes. Returns the final value.
    @discardableResult
    static func until(
        timeout: Duration,
        every interval: Duration = .milliseconds(5),
        _ condition: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: interval)
        }
        return condition()
    }

    static func sleep(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    /// Runs `work` on a background queue and resumes on the main actor.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }
}

/// Collects what an engine writes back, with the arrival time of each chunk.
final class ReplyCapture: Sendable {
    private let chunks = Mutex<[(nanos: UInt64, bytes: [UInt8])]>([])

    var sink: @Sendable (Data) -> Void {
        { [self] data in
            let now = Monotonic.nanos()
            chunks.withLock { $0.append((now, [UInt8](data))) }
        }
    }

    func reset() {
        chunks.withLock { $0.removeAll() }
    }

    var bytes: [UInt8] { chunks.withLock { $0.flatMap(\.bytes) } }
    var firstArrival: UInt64? { chunks.withLock { $0.first?.nanos } }
    var isEmpty: Bool { chunks.withLock { $0.isEmpty } }
}

/// A key to synthesize as an `NSEvent`.
struct SyntheticKey: Sendable {
    let name: String
    let keyCode: UInt16
    let characters: String
    let charactersIgnoringModifiers: String
    let modifiers: NSEvent.ModifierFlags.RawValue
    /// Encodings Claude Code's input decoder handles as intended for this key.
    let acceptable: [String]

    static let enter = SyntheticKey(name: "Enter", keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r", modifiers: 0, acceptable: ["\r", "\u{1B}[13u"])
    static let shiftEnter = SyntheticKey(name: "Shift+Enter", keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r", modifiers: NSEvent.ModifierFlags.shift.rawValue, acceptable: ["\u{1B}[13;2u", "\u{1B}[27;2;13~"])
    static let optionEnter = SyntheticKey(name: "Option+Enter", keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r", modifiers: NSEvent.ModifierFlags.option.rawValue, acceptable: ["\u{1B}\r", "\u{1B}[13;3u", "\u{1B}[27;3;13~"])
    static let controlV = SyntheticKey(name: "Ctrl+V", keyCode: 9, characters: "\u{16}", charactersIgnoringModifiers: "v", modifiers: NSEvent.ModifierFlags.control.rawValue, acceptable: ["\u{16}", "\u{1B}[118;5u"])
    static let controlC = SyntheticKey(name: "Ctrl+C", keyCode: 8, characters: "\u{03}", charactersIgnoringModifiers: "c", modifiers: NSEvent.ModifierFlags.control.rawValue, acceptable: ["\u{03}", "\u{1B}[99;5u"])
    static let escape = SyntheticKey(name: "Esc", keyCode: 53, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", modifiers: 0, acceptable: ["\u{1B}", "\u{1B}[27u"])
    static let shiftTab = SyntheticKey(name: "Shift+Tab", keyCode: 48, characters: "\u{19}", charactersIgnoringModifiers: "\u{19}", modifiers: NSEvent.ModifierFlags.shift.rawValue, acceptable: ["\u{1B}[Z", "\u{1B}[9;2u", "\u{1B}[27;2;9~"])
    static let letterA = SyntheticKey(name: "a", keyCode: 0, characters: "a", charactersIgnoringModifiers: "a", modifiers: 0, acceptable: ["a"])

    static let probeSet: [SyntheticKey] = [enter, shiftEnter, optionEnter, controlV, controlC, escape, shiftTab, letterA]

    @MainActor
    func event(_ type: NSEvent.EventType, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: modifiers),
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}

/// Writes one JSON line for the orchestrator to pick up.
enum WorkerOutput {
    static let prefix = "TERMSPIKE_RESULT "
}
