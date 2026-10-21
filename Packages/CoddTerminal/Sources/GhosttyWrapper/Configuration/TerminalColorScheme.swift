// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalColorScheme.swift
//  libghostty-spm
//

import GhosttyKit

public enum TerminalColorScheme: Sendable {
    case light
    case dark

    var ghosttyValue: ghostty_color_scheme_e {
        switch self {
        case .light: GHOSTTY_COLOR_SCHEME_LIGHT
        case .dark: GHOSTTY_COLOR_SCHEME_DARK
        }
    }
}
