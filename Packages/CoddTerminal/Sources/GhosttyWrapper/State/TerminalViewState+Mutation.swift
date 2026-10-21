// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalViewState+Mutation.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

import Combine
import SwiftUI

public extension TerminalViewState {
    func adopt(colorScheme: ColorScheme) {
        adopt(terminalColorScheme: TerminalColorScheme(colorScheme))
    }

    func adopt(terminalColorScheme colorScheme: TerminalColorScheme) {
        guard colorScheme != controller.effectiveColorScheme else { return }
        controller.setColorScheme(colorScheme) {
            self.objectWillChange.send()
        }
        publishBackgroundColor()
    }

    @discardableResult
    func setTheme(_ theme: TerminalTheme) -> Bool {
        let changed = controller.setTheme(theme) {
            self.objectWillChange.send()
        }
        publishBackgroundColor()
        return changed
    }

    @discardableResult
    func setTerminalConfiguration(
        _ terminalConfiguration: TerminalConfiguration,
    ) -> Bool {
        let changed = controller.setTerminalConfiguration(terminalConfiguration) {
            self.objectWillChange.send()
        }
        publishBackgroundColor()
        return changed
    }
}

extension TerminalViewState {
    func publishBackgroundColor() {
        let color = programBackgroundColor ?? controller.backgroundColor
        guard backgroundColor != color else { return }
        backgroundColor = color
    }
}
