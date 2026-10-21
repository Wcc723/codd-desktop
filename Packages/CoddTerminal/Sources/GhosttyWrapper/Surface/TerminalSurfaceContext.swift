// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalSurfaceContext.swift
//  libghostty-spm
//

import GhosttyKit

public enum TerminalSurfaceContext: Sendable, Equatable {
    case window
    case split

    var ghosttyValue: ghostty_surface_context_e {
        switch self {
        case .window: GHOSTTY_SURFACE_CONTEXT_WINDOW
        case .split: GHOSTTY_SURFACE_CONTEXT_SPLIT
        }
    }
}
