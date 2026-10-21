import AppKit
import os
import SwiftTerm
import Synchronization
import TermSpikeKit

/// SwiftTerm `TerminalView` (Metal renderer enabled once in a window) fed by
/// the host: `feedSender.feed` parses synchronously on the calling thread
/// (the PTY read queue); replies and key encodings arrive in
/// `TerminalViewDelegate.send` on the main actor.
@MainActor
final class SwiftTermHost: NSObject, TerminalEngineHost {
    let kind = EngineKind.swiftterm
    let io = EngineIO()
    let feeder: EngineFeeder
    let parseControl: ParseControl
    private(set) var title = ""

    private let terminalView: ReplayAwareTerminalView
    private let log = Logger(subsystem: Signposts.subsystem, category: "swiftterm")
    private(set) var metalError: String?

    var view: NSView { terminalView }
    var isReady: Bool { true }

    override init() {
        var options = TerminalOptions.default
        options.cols = 120
        options.rows = 40
        options.scrollback = 10_000
        options.termName = "xterm-256color"
        terminalView = ReplayAwareTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500),
            font: CoddTheme.terminalFont(),
            options: options
        )
        let sender = terminalView.feedSender
        feeder = EngineFeeder { buffer in
            let bytes = [UInt8](buffer)
            sender.feed(byteArray: bytes[...])
        }
        parseControl = ParseControl(pendingBytes: { 0 }, waitUntilParsed: {})
        super.init()
        terminalView.terminalDelegate = self
        applyTheme()
    }

    private func applyTheme() {
        terminalView.nativeBackgroundColor = CoddTheme.color(CoddTheme.background)
        terminalView.nativeForegroundColor = CoddTheme.color(CoddTheme.foreground)
        terminalView.caretColor = CoddTheme.color(CoddTheme.cursor)
        terminalView.caretTextColor = CoddTheme.color(CoddTheme.cursorText)
        terminalView.selectedTextBackgroundColor = CoddTheme.color(CoddTheme.selectionBackground)
        terminalView.installColors(CoddTheme.palette.map { hex in
            let (red, green, blue) = CoddTheme.rgb(hex)
            return SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
        })
    }

    func childTerminal() -> (term: String, extra: [String: String]) {
        ("xterm-256color", [:])
    }

    func viewDidChangeWindow() {
        guard terminalView.window != nil, !terminalView.isUsingMetalRenderer, metalError == nil else { return }
        // Metal is opt-in in 1.99.0; CODD would run it, so the spike does too.
        // SPIKE_SWIFTTERM_METAL=0 keeps the CoreGraphics renderer for comparison.
        guard ProcessInfo.processInfo.environment["SPIKE_SWIFTTERM_METAL"] != "0" else { return }
        do {
            try terminalView.setUseMetal(true)
        } catch {
            metalError = "\(error)"
            log.error("Metal renderer unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    func setRenderingSuspended(_: Bool) {}

    func processExited(status: Int32) {
        terminalView.feed(text: "\r\n[process \(WaitStatus.describe(status))]\r\n")
    }

    /// `feedSender.feed` parses on the caller's thread before it returns, so
    /// the PTY read loop is throttled by parsing itself; nothing queues.
    func setBacklogHandler(highWater _: Int, lowWater _: Int, _: (@Sendable (Bool) -> Void)?) {}

    func replayWithoutReplies(_ bytes: [UInt8]) async -> String? {
        let view = terminalView
        let sender = view.feedSender
        await Wait.offMain {
            // feed() parses synchronously on this thread, and every reply it
            // produces passes through send(source: Terminal) inside the call.
            view.setSuppressingReplies(true)
            sender.feed(byteArray: bytes[...])
            view.setSuppressingReplies(false)
        }
        return "host-side: TerminalView subclass drops send(source: Terminal) while the history parses (keys use another path)"
    }

    func screenText() -> String {
        terminalView.selectAll()
        let text = terminalView.getSelection() ?? ""
        terminalView.selectNone()
        let rows = Int(io.currentSize?.rows ?? 40)
        return text.components(separatedBy: "\n").suffix(rows).joined(separator: "\n")
    }

    func tearDown() {
        io.setOutput(nil)
        io.setResize(nil)
        terminalView.removeFromSuperview()
    }

    var usesMetal: Bool { terminalView.isUsingMetalRenderer }
}

extension SwiftTermHost: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let scale = source.window?.backingScaleFactor ?? 2
        io.resized(PTYWindowSize(
            columns: newCols,
            rows: newRows,
            pixelWidth: Int(source.bounds.width * scale),
            pixelHeight: Int(source.bounds.height * scale)
        ))
    }

    func setTerminalTitle(source _: TerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

    func send(source _: TerminalView, data: ArraySlice<UInt8>) {
        io.send(Data(data))
    }

    func scrolled(source _: TerminalView, position _: Double) {}

    func requestOpenLink(source _: TerminalView, link: String, params _: [String: String]) {
        log.info("open link \(link, privacy: .public)")
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }

    func bell(source _: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source _: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func rangeChanged(source _: TerminalView, startY _: Int, endY _: Int) {}
}

/// SwiftTerm view that can drop the terminal's own output (query replies,
/// focus and mouse reports) while reconstructed history is fed.
///
/// That output leaves the parser through `send(source: Terminal, data:)` on the
/// parsing thread, before SwiftTerm hops it to the main actor, so the flag is
/// checked synchronously and no main-queue fence is needed. User keystrokes
/// take a different path (`TerminalView.send(data:)` → `inputSender`) and are
/// never dropped. SwiftTerm has no replay API of its own; this is what CODD
/// would ship if it picked SwiftTerm.
final class ReplayAwareTerminalView: TerminalView {
    private let suppressing = Atomic<Bool>(false)
    private let dropped = Atomic<Int>(0)

    /// Bytes dropped while suppressing (diagnostics).
    nonisolated var droppedReplyBytes: Int { dropped.load(ordering: .relaxed) }

    nonisolated func setSuppressingReplies(_ on: Bool) {
        suppressing.store(on, ordering: .releasing)
    }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if suppressing.load(ordering: .acquiring) {
            dropped.add(data.count, ordering: .relaxed)
            return
        }
        super.send(source: source, data: data)
    }
}
