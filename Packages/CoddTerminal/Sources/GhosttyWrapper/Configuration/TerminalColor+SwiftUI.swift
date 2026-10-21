// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalColor+SwiftUI.swift
//  libghostty-spm
//

#if canImport(SwiftUI)
    import SwiftUI

    public extension Color {
        /// sRGB: the space ghostty renders in unless `window-colorspace`
        /// says otherwise.
        init(_ color: TerminalColor) {
            self.init(
                .sRGB,
                red: Double(color.red) / 255,
                green: Double(color.green) / 255,
                blue: Double(color.blue) / 255,
                opacity: 1,
            )
        }
    }
#endif
