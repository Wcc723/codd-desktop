import AppKit
import CoddTerminal
import Foundation
import Synchronization

/// One `TerminalEngine` in a window that is never ordered on screen: enough for libghostty to build
/// a real Metal-backed surface, parse, answer queries and report sizes, headlessly.
///
/// The engine view sits inside `KeyRecorderView`, so a key the terminal passes up the responder
/// chain is recorded instead of reaching the window (which would beep).
@MainActor
final class SurfaceHarness {
    let engine: TerminalEngine
    let window: NSWindow
    let host: KeyRecorderView
    let written = ByteLog()
    private(set) var deviceAttributesReplies = 0
    private(set) var resizes: [TerminalResize] = []

    init(configuration: TerminalConfiguration = .default, size: NSSize = NSSize(width: 800, height: 500)) {
        _ = NSApplication.shared
        engine = TerminalEngine(configuration: configuration)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        host = KeyRecorderView(frame: NSRect(origin: .zero, size: size))
        let written = written
        engine.onWrite = { written.append($0) }
        engine.onFirstDeviceAttributesReply = { [weak self] in self?.deviceAttributesReplies += 1 }
        engine.onResize = { [weak self] size in self?.resizes.append(size) }
        engine.view.frame = host.bounds
        engine.view.autoresizingMask = [.width, .height]
        host.addSubview(engine.view)
        window.contentView = host
    }

    /// Detaches everything; call at the end of every test.
    func tearDown() {
        engine.dispose()
        window.contentView = nil
        window.close()
    }

    func feed(_ text: String) {
        engine.feed(Array(text.utf8))
    }

    func replay(_ text: String) {
        engine.replay(Array(text.utf8))
    }

    /// Parses everything queued, then lets libghostty's IO thread and the main queue deliver what
    /// the parse produced (replies, resizes, titles).
    func settle() async {
        engine.waitUntilParsed()
        try? await Task.sleep(for: .milliseconds(30))
    }

    /// The visible rows, trailing blank rows dropped.
    var viewportLines: [String] {
        let lines = (engine.readViewportText() ?? "").components(separatedBy: "\n")
        return Array(lines.reversed().drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed())
    }

    /// A key-down as AppKit would deliver it to the terminal view (first responder).
    func keyDown(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    func type(_ characters: String, keyCode: UInt16) {
        let event = keyDown(characters, keyCode: keyCode)
        engine.view.keyDown(with: event)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// Bytes the engine wrote (keys, replies), appended from libghostty's IO thread.
final class ByteLog: Sendable {
    private let storage = Mutex<[UInt8]>([])

    func append(_ bytes: [UInt8]) {
        storage.withLock { $0 += bytes }
    }

    var bytes: [UInt8] {
        storage.withLock { $0 }
    }

    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    func removeAll() {
        storage.withLock { $0.removeAll() }
    }
}

/// The terminal view's superview: records key-downs the terminal passed up the responder chain.
final class KeyRecorderView: NSView {
    private(set) var forwardedKeys: [String] = []

    override func keyDown(with event: NSEvent) {
        forwardedKeys.append(event.charactersIgnoringModifiers ?? "")
    }

    override func keyUp(with event: NSEvent) {
        forwardedKeys.append(event.charactersIgnoringModifiers ?? "")
    }
}
