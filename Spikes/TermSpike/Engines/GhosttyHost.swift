import AppKit
import GhosttyKit
import GhosttyTerminal
import os
import TermSpikeKit

/// One shared libghostty app/config for every surface, so font atlases are
/// shared (`SharedGridSet`) the way CODD would run 15 sessions.
@MainActor
enum GhosttyRuntime {
    static let controller: TerminalController = {
        let colors = TerminalConfiguration { builder in
            builder.withBackground(CoddTheme.background)
            builder.withForeground(CoddTheme.foreground)
            builder.withCursorColor(CoddTheme.cursor)
            builder.withCursorText(CoddTheme.cursorText)
            builder.withSelectionBackground(CoddTheme.selectionBackground)
            builder.withSelectionForeground(CoddTheme.selectionForeground)
            for (index, hex) in CoddTheme.palette.enumerated() {
                builder.withPalette(index, color: hex)
            }
        }
        let base = TerminalConfiguration { builder in
            // Repeated font-family entries form Ghostty's fallback chain.
            builder.withFontFamily(CoddTheme.fontFamily)
            builder.withFontFamily(CoddTheme.cjkFamily)
            builder.withFontSize(Float(CoddTheme.fontSize))
            builder.withFontThicken(false)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withWindowPaddingX(6)
            builder.withWindowPaddingY(4)
            builder.withCustom("scrollback-limit", "10000000")
            builder.withCustom("confirm-close-surface", "false")
            // Diagnostic knob: SPIKE_GHOSTTY_CONFIG="key=value;key=value" appends
            // raw Ghostty config lines (e.g. cursor-style-blink=false).
            for line in (ProcessInfo.processInfo.environment["SPIKE_GHOSTTY_CONFIG"] ?? "").split(separator: ";") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { builder.withCustom(parts[0], parts[1]) }
            }
        }
        // Same colours for light and dark so the system appearance never recolours it.
        return TerminalController(configuration: base, theme: TerminalTheme(light: colors, dark: colors))
    }()
}

/// libghostty surface (Metal) with host-managed I/O via `InMemoryTerminalSession`.
///
/// Bytes from the program go through `session.receive`, which enqueues onto the
/// session's own serial queue (never the main thread). Bytes Ghostty produces
/// (keys, query replies) arrive in the session's `write` closure on Ghostty's
/// IO thread; resizes arrive in its `resize` closure from the same thread.
@MainActor
final class GhosttyHost: TerminalEngineHost {
    let kind = EngineKind.ghostty
    let io = EngineIO()
    let feeder: EngineFeeder
    let parseControl: ParseControl
    private(set) var title = ""

    private let session: InMemoryTerminalSession
    private let terminalView: AppTerminalView
    private var surface: TerminalSurface?
    private let log = Logger(subsystem: Signposts.subsystem, category: "ghostty")

    var view: NSView { terminalView }
    var isReady: Bool { surface != nil && io.currentSize != nil }

    init() {
        let io = io
        let session = InMemoryTerminalSession(
            write: { data in io.send(data) },
            resize: { viewport in
                io.resized(PTYWindowSize(
                    columns: Int(viewport.columns),
                    rows: Int(viewport.rows),
                    pixelWidth: Int(viewport.widthPixels),
                    pixelHeight: Int(viewport.heightPixels)
                ))
            }
        )
        self.session = session
        feeder = EngineFeeder { buffer in session.receive(Data(buffer)) }
        parseControl = ParseControl(
            pendingBytes: { session.pendingOutputByteCount },
            waitUntilParsed: { session.waitForPendingOutput() }
        )
        terminalView = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        terminalView.controller = GhosttyRuntime.controller
    }

    func childTerminal() -> (term: String, extra: [String: String]) {
        var extra: [String: String] = [:]
        if let terminfo = GhosttyRuntimeResources.terminfoDirectoryURL?.path {
            extra["TERMINFO"] = terminfo
        }
        return ("xterm-ghostty", extra)
    }

    func viewDidChangeWindow() {
        terminalView.fitToSize()
    }

    func setRenderingSuspended(_ suspended: Bool) {
        terminalView.setSurfaceVisible(!suspended)
    }

    func processExited(status: Int32) {
        session.finish(exitCode: WaitStatus.exitCode(status), runtimeMilliseconds: 0)
    }

    func setBacklogHandler(highWater: Int, lowWater: Int, _ handler: (@Sendable (Bool) -> Void)?) {
        // `receive` never blocks and queues without limit while a surface is
        // attached; this is the session's own hook for pausing the source.
        session.setOutputBacklogHandler(highWater: highWater, lowWater: lowWater, handler)
    }

    func replayWithoutReplies(_ bytes: [UInt8]) async -> String? {
        guard let raw = surface.flatMap(GhosttySurfaceReflection.rawSurface(of:)) else { return nil }
        let pointer = SurfacePointer(raw: raw)
        let session = session
        await Wait.offMain {
            // Keep the order with bytes already handed to the session queue;
            // the replay call itself parses synchronously under the
            // terminal-state mutex (libghostty-spm patch 0011).
            session.waitForPendingOutput()
            bytes.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                ghostty_surface_write_buffer_replay(pointer.raw, base, UInt(buffer.count))
            }
        }
        return "ghostty_surface_write_buffer_replay (raw surface reached via reflection; the Swift wrapper does not expose it)"
    }

    func screenText() -> String {
        session.readViewportText() ?? "(no surface)"
    }

    func tearDown() {
        io.setOutput(nil)
        io.setResize(nil)
        terminalView.removeFromSuperview()
    }
}

extension GhosttyHost: TerminalSurfaceTitleDelegate, TerminalSurfaceLifecycleDelegate,
    TerminalSurfaceOpenURLDelegate, TerminalSurfaceBellDelegate
{
    func terminalDidChangeTitle(_ title: String) {
        self.title = title
    }

    func terminalDidAttachSurface(_ surface: TerminalSurface) {
        self.surface = surface
    }

    func terminalDidDetachSurface() {
        surface = nil
    }

    func terminalDidRequestOpenURL(_ url: String, kind _: TerminalOpenURLKind) {
        log.info("open url \(url, privacy: .public)")
        if let target = URL(string: url) {
            NSWorkspace.shared.open(target)
        }
    }

    func terminalDidRingBell() {
        NSSound.beep()
    }
}

/// `ghostty_surface_t` handed to a background queue for the replay call.
/// Nothing keeps the surface alive across that hop: the caller must not
/// detach or tear the view down until the replay returns (the probe awaits
/// it). Production code needs the wrapper's `withCurrentSurface` guard.
private struct SurfacePointer: @unchecked Sendable {
    let raw: ghostty_surface_t
}

/// The Swift wrapper keeps the raw `ghostty_surface_t` internal and does not
/// expose `ghostty_surface_write_buffer_replay` (only the C header does). The
/// spike reads the private stored property through reflection to reach it;
/// production code would need the wrapper to expose a replay entry point.
enum GhosttySurfaceReflection {
    @MainActor
    static func rawSurface(of surface: TerminalSurface) -> ghostty_surface_t? {
        for child in Mirror(reflecting: surface).children where child.label == "surface" {
            if let raw = child.value as? ghostty_surface_t {
                return raw
            }
        }
        return nil
    }
}
