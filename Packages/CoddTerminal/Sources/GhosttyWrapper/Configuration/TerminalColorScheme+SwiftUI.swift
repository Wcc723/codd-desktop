// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalColorScheme+SwiftUI.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(SwiftUI)
    import SwiftUI

    extension TerminalColorScheme {
        init(_ colorScheme: ColorScheme) {
            switch colorScheme {
            case .dark:
                self = .dark
            default:
                self = .light
            }
        }
    }
#endif
