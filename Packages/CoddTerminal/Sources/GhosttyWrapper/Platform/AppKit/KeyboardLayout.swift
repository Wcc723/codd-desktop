// Vendored from libghostty-spm (https://github.com/Lakr233/libghostty-spm), commit d403978c6687
// (release 2.2.2026101301), Sources/GhosttyTerminal. MIT License, Copyright (c) 2026 @Lakr233;
// see Packages/CoddTerminal/NOTICE. CODD changes are marked `CODD:`.

#if !canImport(UIKit) && canImport(AppKit)
    import Carbon.HIToolbox

    enum KeyboardLayout {
        static var id: String? {
            guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
            else {
                return nil
            }

            guard let rawProperty = TISGetInputSourceProperty(
                inputSource,
                kTISPropertyInputSourceID,
            ) else {
                return nil
            }

            let property = unsafeBitCast(rawProperty, to: CFString.self)
            return property as String
        }
    }
#endif
