import AppKit
import Foundation
internal import GhosttyWrapper

/// One terminal on libghostty: one per PTY (a session tab).
///
/// Threading:
/// - `feed`, `replay`, `reset`, `setOutputBacklogHandler`, `pendingOutputByteCount` and
///   `waitUntilParsed` are safe from any thread (the holder stream calls them from its own queue).
///   Bytes are copied into the surface's serial output queue and parsed there, never on the main
///   thread, in the order these calls were made.
/// - `onWrite` runs on libghostty's IO thread.
/// - Everything else, and every other callback, is main-actor.
///
/// Lifecycle: the surface exists while `view` is in a window with a non-zero size. Bytes fed before
/// that wait in the queue (live output past 1 MiB is trimmed from the front; replays are kept) and
/// are parsed once the surface attaches. A hot (occluded) terminal must stay in a window: libghostty
/// drains titles, bells and other app messages only while at least one surface is attached.
@MainActor
public final class TerminalEngine {
    public let configuration: TerminalConfiguration

    /// The terminal's view; place it directly in the AppKit tree (not inside SwiftUI).
    public var view: NSView { terminalView }

    /// Keys, pastes and query replies for the program. Runs on libghostty's IO thread; keep it to a
    /// hand-off (the holder stream's `sendInput`). Bytes produced while it is nil (up to 64 KiB)
    /// are delivered when it is set. Nothing is delivered after `childExited` until
    /// `rebuildForNewProcess`.
    public var onWrite: (@Sendable ([UInt8]) -> Void)? {
        get { io.writeHandler }
        set { io.setWriteHandler(newValue) }
    }

    /// The grid libghostty sized itself to, reported right before it reflows (after layout, a font
    /// change, or a backing-scale change). Coalesced to the latest size per main-queue turn.
    public var onResize: ((TerminalResize) -> Void)?
    /// OSC 0/2 title.
    public var onTitle: ((String) -> Void)?
    /// OSC 7 working directory (a path, `file://` already decoded by libghostty).
    public var onWorkingDirectory: ((String) -> Void)?
    public var onBell: (() -> Void)?
    /// Fires once per process, on the main queue, after the bytes completing the first DA1 reply
    /// (`ESC [ ? … c`) were handed to `onWrite`: the program's startup probes are answered.
    public var onFirstDeviceAttributesReply: (() -> Void)?
    /// ⌘+ / ⌘- / ⌘0 in the terminal, or `fontSize` set here.
    public var onFontSizeChange: ((CGFloat) -> Void)?
    /// A Cmd-clicked link. When nil only http, https and mailto links open with `NSWorkspace`;
    /// any other scheme (file:, smb:, another app's) is dropped, never opened.
    public var onOpenURL: ((URL) -> Void)?
    /// The link under the pointer: an OSC 8 hyperlink's real target or a detected URL, as
    /// libghostty reports it. Nil when the hover ends (also when a new process replaces a surface
    /// that had one).
    public var onHoverLink: ((String?) -> Void)?
    /// OSC 9 / OSC 777 desktop notification requested by the program.
    public var onDesktopNotification: ((_ title: String, _ body: String) -> Void)?

    /// Latest grid reported through `onResize`.
    public private(set) var gridSize: TerminalResize?
    public private(set) var title = ""
    /// Set by `childExited`, cleared by `rebuildForNewProcess`.
    public private(set) var exitStatus: Int32?
    public private(set) var isOccluded = false
    public private(set) var isDisposed = false
    /// The link last reported through `onHoverLink`.
    public private(set) var hoveredLink: String?

    private let terminalView: CoddTerminalView
    private let io = EngineIO()
    private let events = SurfaceEvents()
    private var session: InMemoryTerminalSession
    private var requestedFontSize: CGFloat

    public init(configuration: TerminalConfiguration = .default) {
        self.configuration = configuration
        requestedFontSize = TerminalConfiguration.clampedFontSize(configuration.fontSize)
        session = io.makeSession()
        terminalView = CoddTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminalView.keyEquivalents = configuration.keyEquivalents
        terminalView.pasteImageAsControlV = configuration.pasteImageAsControlV
        terminalView.delegate = events
        terminalView.configuration = Self.options(for: session, fontSize: nil, configuration: configuration)
        terminalView.ignoresWindowOcclusion = Self.rendersWhileWindowOccludedByDefault
        terminalView.controller = TerminalRuntime.controller(for: configuration)

        events.engine = self
        terminalView.onImageOnlyPaste = { [weak self] in
            self?.session.sendInput(Data([0x16]))
        }
        io.setEventHandler { [weak self] event in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
    }

    deinit {
        // Breaks the session ↔ sink reference cycle when the owner never called dispose().
        io.detachSession()
    }

    // MARK: - Bytes in (any thread)

    /// Live PTY output, in stream order. Never blocks.
    public nonisolated func feed(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, let session = io.session else { return }
        if let filtered = io.filterLive(bytes) {
            if !filtered.isEmpty { session.receive(Data(filtered)) }
        } else {
            session.receive(Data(bytes))
        }
    }

    public nonisolated func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    /// History (a reattach replay from the holder's ring): parsed in order with `feed`, but every
    /// reply it would provoke (DA, DSR, DECRQM, OSC reports) is suppressed inside libghostty, so the
    /// program never sees a query answered twice, and OSC 52 clipboard writes are removed before
    /// parsing, so history never overwrites the user's clipboard (`ReplayClipboardFilter`).
    /// Never blocks.
    public nonisolated func replay(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, let session = io.session else { return }
        if let filtered = io.filterReplay(bytes) {
            if !filtered.isEmpty { session.replay(Data(filtered)) }
        } else {
            session.replay(Data(bytes))
        }
    }

    public nonisolated func replay(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { replay($0) }
    }

    /// Replays a history filtered and copied off the main actor (`PreparedReplay`), after
    /// `reset()` like a dead session's ring: replies suppressed as with `replay(_:)`, the
    /// clipboard filter left idle for what follows. O(1) for the caller; never blocks.
    public nonisolated func replay(_ prepared: PreparedReplay) {
        guard !prepared.data.isEmpty, let session = io.session else { return }
        io.resetClipboardFilter()
        session.replay(prepared.data)
    }

    /// Calls `handler(true)` once unparsed bytes (feeds and replays) reach `highWater`, and
    /// `handler(false)` once they fall to `lowWater`: pause and resume reading the holder. Runs on
    /// whichever thread crossed the mark; calls never overlap, alternate, and carry the state
    /// current when they run, so the last call is always the current state. Survives
    /// `rebuildForNewProcess` (the new process starts unbacklogged and reports only a new
    /// crossing); nil removes it, and once that returns the old handler is not called again.
    public nonisolated func setOutputBacklogHandler(
        highWater: Int, lowWater: Int, _ handler: (@Sendable (_ isBacklogged: Bool) -> Void)?
    ) {
        io.setBacklogHandler(highWater: highWater, lowWater: lowWater, handler)
    }

    /// Bytes fed or replayed and not parsed yet.
    public nonisolated var pendingOutputByteCount: Int {
        io.session?.pendingOutputByteCount ?? 0
    }

    /// Blocks until everything fed or replayed so far is parsed (replies included). False when bytes
    /// are still waiting for a surface to attach. On the main thread it keeps libghostty's app
    /// mailbox drained while it waits.
    @discardableResult
    public nonisolated func waitUntilParsed() -> Bool {
        io.session?.waitForPendingOutput() ?? true
    }

    /// `waitUntilParsed` without blocking the caller.
    @discardableResult
    public func parsed() async -> Bool {
        guard let session = io.session else { return true }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: session.waitForPendingOutput())
            }
        }
    }

    /// Full reset (RIS) plus erase scrollback, queued in order with `feed` and `replay`: the clean
    /// slate a resync replay starts from after a GAP. Modes, colors, kitty keyboard flags and the
    /// alternate screen all go back to their defaults. Safe from any thread, so the stream's queue
    /// can call it between the last bytes before a GAP and the first bytes of the resync.
    public nonisolated func reset() {
        // The history before it was cut: a clipboard sequence it ended in is not continued.
        io.resetClipboardFilter()
        // ESC c, CSI 3 J. Through the replay path so nothing it touches can answer the program.
        io.session?.replay(Data([0x1B, 0x63, 0x1B, 0x5B, 0x33, 0x4A]))
    }

    // MARK: - Control (main actor)

    public var fontSize: CGFloat {
        get {
            terminalView.fontSize.map { CGFloat($0) } ?? requestedFontSize
        }
        set {
            let size = TerminalConfiguration.clampedFontSize(newValue)
            requestedFontSize = size
            guard !isDisposed else { return }
            if terminalView.hasSurface {
                terminalView.performBindingAction("set_font_size:\(TerminalConfiguration.number(size))")
            } else {
                // Takes effect when the surface is created.
                terminalView.configuration = Self.options(for: session, fontSize: size, configuration: configuration)
            }
        }
    }

    /// Hidden or covered: stop rendering. Parsing and replies continue.
    public func setOccluded(_ occluded: Bool) {
        isOccluded = occluded
        guard !isDisposed else { return }
        terminalView.setSurfaceVisible(!occluded)
    }

    /// What `rendersWhileWindowOccluded` starts as for engines created afterwards (DEBUG
    /// `-codd-force-render`, M5 D17: set it once at launch, before the first engine).
    public static var rendersWhileWindowOccludedByDefault = false

    /// Keep rendering while the window is covered, hidden or minimized, as if it were on screen
    /// (measurements only: a background test window sits behind the user's windows, and once
    /// AppKit reports it covered libghostty stops drawing). `setOccluded(true)` still stops drawing.
    public var rendersWhileWindowOccluded: Bool {
        get { terminalView.ignoresWindowOcclusion }
        set { terminalView.ignoresWindowOcclusion = newValue }
    }

    /// Makes the terminal the window's first responder.
    @discardableResult
    public func focus() -> Bool {
        guard !isDisposed else { return false }
        return terminalView.acquireProgrammaticFocus()
    }

    /// Pastes text as the user would (bracketed when the program asked for it).
    @discardableResult
    public func paste(_ text: String) -> Bool {
        guard !isDisposed else { return false }
        return terminalView.paste(text: text)
    }

    /// The child is gone: keep the screen as it is and stop sending anything (keys, replies) until
    /// `rebuildForNewProcess`. libghostty itself is never told, because once it knows it stops
    /// encoding keys and asks to close the surface.
    public func childExited(status: Int32) {
        exitStatus = status
        io.setInputEnabled(false)
    }

    /// A fresh surface for a new process in the same tab (RESUME, RESTART): new grid, empty
    /// scrollback, default modes, input flowing again, and the first DA1 reply reported again.
    /// The owner attaches the new stream and replays whatever history it wants shown.
    public func rebuildForNewProcess() {
        guard !isDisposed else { return }
        exitStatus = nil
        _ = io.beginGeneration()
        session = io.makeSession()
        let size = terminalView.fontSize.map { CGFloat($0) } ?? requestedFontSize
        terminalView.configuration = Self.options(for: session, fontSize: size, configuration: configuration)
        gridSize = nil
        // The new surface starts with no hover, so it never reports the old one's end.
        if hoveredLink != nil { surfaceDidUpdateHoverLink(nil) }
    }

    /// Frees the surface and stops every callback. The engine cannot be used again.
    public func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        io.detachSession()
        terminalView.onImageOnlyPaste = nil
        terminalView.controller = nil
        terminalView.delegate = nil
        terminalView.removeFromSuperview()
        events.engine = nil
        onResize = nil
        onTitle = nil
        onWorkingDirectory = nil
        onBell = nil
        onFirstDeviceAttributesReply = nil
        onFontSizeChange = nil
        onOpenURL = nil
        onHoverLink = nil
        onDesktopNotification = nil
    }

    // MARK: - Inspection

    /// Whether a libghostty surface exists right now.
    public var hasSurface: Bool {
        terminalView.hasSurface
    }

    /// Whether this process's first DA1 reply has been written.
    public var hasWrittenDeviceAttributesReply: Bool {
        io.deviceAttributesWritten
    }

    /// The visible rows as text, one line per row; nil without a surface.
    public func readViewportText() -> String? {
        session.readViewportText()
    }

    /// The whole screen including scrollback; nil without a surface.
    public func readScreenText() -> String? {
        session.readScreenText()
    }

    /// Whether libghostty would consume this key-down as one of its own bindings.
    public func isTerminalKeyBinding(_ event: NSEvent) -> Bool {
        terminalView.isGhosttyKeyBinding(event)
    }

    /// Whether the terminal leaves this key-down to the app (a reserved key equivalent).
    public func isReservedKeyEquivalent(_ event: NSEvent) -> Bool {
        terminalView.isReserved(event)
    }

    // MARK: - Private

    private static func options(
        for session: InMemoryTerminalSession, fontSize: CGFloat?, configuration: TerminalConfiguration
    ) -> TerminalSurfaceOptions {
        // A size equal to the config's is left unset: the surface then follows the config on
        // reload, and ⌘0 (reset_font_size) returns to it either way.
        let explicit = fontSize.flatMap { $0 == TerminalConfiguration.clampedFontSize(configuration.fontSize) ? nil : $0 }
        return TerminalSurfaceOptions(backend: .inMemory(session), fontSize: explicit.map { Float($0) })
    }

    private func handle(_ event: EngineIO.Event) {
        guard !isDisposed else { return }
        switch event {
        case let .deviceAttributesReplyWritten(generation):
            guard generation == io.generation else { return }
            onFirstDeviceAttributesReply?()
        case .resized:
            guard let size = io.takeLatestResize(), size != gridSize else { return }
            gridSize = size
            onResize?(size)
        }
    }

    fileprivate func surfaceDidChangeTitle(_ title: String) {
        self.title = title
        onTitle?(title)
    }

    fileprivate func surfaceDidChangeWorkingDirectory(_ path: String) {
        onWorkingDirectory?(path)
    }

    fileprivate func surfaceDidRingBell() {
        onBell?()
    }

    fileprivate func surfaceDidChangeFontSize(_ size: Float) {
        requestedFontSize = CGFloat(size)
        onFontSizeChange?(CGFloat(size))
    }

    fileprivate func surfaceDidRequestOpenURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        if let onOpenURL {
            onOpenURL(url)
        } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate func surfaceDidUpdateHoverLink(_ link: String?) {
        hoveredLink = link
        onHoverLink?(link)
    }

    fileprivate func surfaceDidRequestNotification(title: String, body: String) {
        onDesktopNotification?(title, body)
    }
}

/// The wrapper's delegate protocols, kept off `TerminalEngine`'s public surface.
@MainActor
private final class SurfaceEvents: TerminalSurfaceTitleDelegate, TerminalSurfacePwdDelegate,
    TerminalSurfaceBellDelegate, TerminalSurfaceFontSizeDelegate, TerminalSurfaceOpenURLDelegate,
    TerminalSurfaceHoverLinkDelegate, TerminalSurfaceDesktopNotificationDelegate
{
    weak var engine: TerminalEngine?

    func terminalDidChangeTitle(_ title: String) {
        engine?.surfaceDidChangeTitle(title)
    }

    func terminalDidChangeWorkingDirectory(_ path: String) {
        engine?.surfaceDidChangeWorkingDirectory(path)
    }

    func terminalDidRingBell() {
        engine?.surfaceDidRingBell()
    }

    func terminalDidChangeFontSize(_ fontSize: Float) {
        engine?.surfaceDidChangeFontSize(fontSize)
    }

    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        engine?.surfaceDidRequestOpenURL(url)
    }

    func terminalDidUpdateHoverLink(_ url: String?) {
        engine?.surfaceDidUpdateHoverLink(url)
    }

    func terminalDidRequestDesktopNotification(title: String, body: String) {
        engine?.surfaceDidRequestNotification(title: title, body: body)
    }
}
