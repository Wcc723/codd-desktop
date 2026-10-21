// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalTheme.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

public struct TerminalTheme: Sendable, Hashable {
    public var light: TerminalConfiguration
    public var dark: TerminalConfiguration

    public init(
        light: TerminalConfiguration = .init(),
        dark: TerminalConfiguration = .init(),
    ) {
        self.light = light
        self.dark = dark
    }

    var isEmpty: Bool {
        light.isEmpty && dark.isEmpty
    }

    func configuration(for colorScheme: TerminalColorScheme) -> TerminalConfiguration {
        switch colorScheme {
        case .light:
            light
        case .dark:
            dark
        }
    }
}
