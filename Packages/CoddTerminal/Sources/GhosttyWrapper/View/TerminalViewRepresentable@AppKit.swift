// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.
//
//  TerminalViewRepresentable@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if !canImport(UIKit) && canImport(AppKit)
    import AppKit
    import SwiftUI

    extension TerminalViewRepresentable: NSViewRepresentable {
        func makeNSView(context _: Context) -> TerminalView {
            let view = context.makePlatformView?() ?? TerminalView(frame: .zero)
            configureView(view, initial: true)
            view.focusBridge.onFocusChange = { focused in
                focusBinding.setFocused(focused)
            }
            Self.synchronizeFocus(view, with: focusBinding)
            return view
        }

        func updateNSView(_ view: TerminalView, context _: Context) {
            configureView(view, initial: false)
            view.focusBridge.onFocusChange = { focused in
                focusBinding.setFocused(focused)
            }
            Self.synchronizeFocus(view, with: focusBinding)
        }

        static func dismantleNSView(_ view: TerminalView, coordinator _: ()) {
            view.focusBridge.onFocusChange = nil
        }
    }
#endif
