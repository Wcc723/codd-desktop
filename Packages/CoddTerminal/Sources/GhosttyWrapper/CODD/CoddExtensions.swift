//
//  CoddExtensions.swift
//  CODD additions to the vendored libghostty-spm wrapper (not upstream code).
//
//  The few entry points CODD's engine needs that upstream keeps internal. They live in this
//  module because they touch `internal` wrapper state (the raw surface); everything else CODD
//  does goes through the wrapper's public API.
//

import AppKit
import Foundation
import GhosttyKit

public extension AppTerminalView {
    /// Whether libghostty has a key binding for this key-down event (for example Cmd+C →
    /// `copy_to_clipboard`). The view's own `performKeyEquivalent` asks the same question to decide
    /// whether the terminal consumes a Cmd shortcut. False while no surface exists.
    func isGhosttyKeyBinding(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let rawSurface = surface?.rawValue else { return false }
        var keyEvent = event.buildKeyInput(action: GHOSTTY_ACTION_PRESS)
        var bindingFlags = ghostty_binding_flags_e(rawValue: 0)
        let text = event.characters ?? ""
        return text.withCString { pointer in
            keyEvent.text = pointer
            return ghostty_surface_key_is_binding(rawSurface, keyEvent, &bindingFlags)
        }
    }

    /// Whether a surface currently exists (the view is in a window with a usable size and has a
    /// controller).
    var hasSurface: Bool {
        surface != nil
    }

    /// Render as if the window were on screen even while it is covered, hidden or minimized (DEBUG
    /// measurements, M5 D17: a background test window sits behind the user's windows and stops
    /// drawing once AppKit reports it covered). The host's own `setSurfaceVisible(false)` still
    /// stops drawing.
    var ignoresWindowOcclusion: Bool {
        get { core.ignoresWindowOcclusion }
        set { core.ignoresWindowOcclusion = newValue }
    }
}

public extension InMemoryTerminalSession {
    /// The whole screen as text, scrollback included (`GHOSTTY_POINT_SCREEN` from its top-left to its
    /// bottom-right cell), or nil when no surface is attached. Soft-wrapped rows are joined, so this
    /// is for inspection and tests, not for indexing rows (use `readViewportText()` for that).
    func readScreenText() -> String? {
        withCurrentSurface { surface -> String? in
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                    x: 0,
                    y: 0,
                ),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_SCREEN,
                    coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                    x: 0,
                    y: 0,
                ),
                rectangle: false,
            )
            var out = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
            defer { ghostty_surface_free_text(surface, &out) }
            guard let textPointer = out.text, out.text_len > 0 else { return "" }
            let bytes = UnsafeBufferPointer(start: textPointer, count: Int(out.text_len))
                .map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        } ?? nil
    }
}

public extension TerminalController {
    /// libghostty's diagnostics for a config text (one entry per rejected line), without creating
    /// an app or a surface. An empty result means every line parsed. Initializes the libghostty
    /// runtime on first use, exactly as creating a controller would.
    static func configurationDiagnostics(for contents: String) -> [String] {
        initializeRuntimeIfNeeded()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codd-ghostty-config-check", isDirectory: true)
        let url = directory.appendingPathComponent("check-\(UUID().uuidString).conf")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            return ["could not write the config to check: \(error)"]
        }
        defer { try? FileManager.default.removeItem(at: url) }

        guard let config = ghostty_config_new() else { return ["ghostty_config_new returned nil"] }
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, url.path)
        ghostty_config_finalize(config)
        let count = ghostty_config_diagnostics_count(config)
        return (0 ..< count).compactMap { index in
            ghostty_config_get_diagnostic(config, index).message.map { String(cString: $0) }
        }
    }
}

/// libghostty's build information.
public enum GhosttyBuildInfo {
    /// The version libghostty reports (the same string its XTVERSION reply carries after `ghostty `),
    /// for example `1.3.2-HEAD+1e9e14af5`.
    public static var version: String {
        let info = ghostty_info()
        guard let pointer = info.version, info.version_len > 0 else { return "" }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: Int(info.version_len))
        return String(decoding: bytes, as: UTF8.self)
    }
}
