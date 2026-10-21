// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(UIKit)
    import UIKit

    public typealias TerminalView = UITerminalView
#elseif canImport(AppKit)
    import AppKit

    public typealias TerminalView = AppTerminalView
#endif
