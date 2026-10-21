// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalViewportMetrics.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation

struct TerminalViewportMetrics: Equatable {
    var surfaceSize: TerminalGridMetrics
    var scale: Double
}
