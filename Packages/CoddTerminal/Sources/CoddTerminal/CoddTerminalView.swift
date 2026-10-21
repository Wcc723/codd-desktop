import AppKit
internal import GhosttyWrapper

/// libghostty's AppKit view with CODD's key-equivalent policy on top.
///
/// Everything else (keyDown → `interpretKeyEvents` → NSTextInputClient for 注音 and other input
/// methods, mouse, selection, scroll, copy/paste, drag and drop) is the wrapper's own code path,
/// unchanged. Only Cmd chords are looked at here, and only before the wrapper sees them.
@MainActor
final class CoddTerminalView: AppTerminalView {
    var keyEquivalents = KeyEquivalentPolicy.codd
    var pasteImageAsControlV = true
    /// Sends Ctrl+V to the program (set by the engine).
    var onImageOnlyPaste: (() -> Void)?

    /// Declines reserved chords so AppKit offers them to the main menu next. Everything else goes
    /// through the wrapper, which consumes a chord only when libghostty has a binding for it.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isReserved(event) {
            return false
        }
        if pasteImageAsControlV, event.type == .keyDown, window?.firstResponder === self,
           Self.isImageOnlyPaste(event, pasteboard: .general)
        {
            onImageOnlyPaste?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// A reserved chord that no menu item took arrives here; pass it up the responder chain rather
    /// than encoding it for the program.
    override func keyDown(with event: NSEvent) {
        if isReserved(event) {
            nextResponder?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    /// The release of a reserved chord: libghostty never saw the press, so it must not see the
    /// release either (a program that asked for key-release events would get a stray one).
    override func keyUp(with event: NSEvent) {
        if isReserved(event) {
            nextResponder?.keyUp(with: event)
            return
        }
        super.keyUp(with: event)
    }

    override func selectionContextMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "拷貝", action: #selector(copy(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    func isReserved(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown || event.type == .keyUp else { return false }
        return keyEquivalents.isReserved(
            characters: event.charactersIgnoringModifiers,
            keyCode: event.keyCode,
            modifiers: KeyModifiers(event.modifierFlags)
        )
    }

    /// Plain ⌘V while the pasteboard has image data and no text or file URL.
    static func isImageOnlyPaste(_ event: NSEvent, pasteboard: NSPasteboard) -> Bool {
        guard KeyModifiers(event.modifierFlags) == .command,
              KeyChord.unshifted(event.charactersIgnoringModifiers ?? "") == "v" || event.keyCode == 0x09
        else { return false }
        let hasImage = pasteboard.availableType(from: [.png, .tiff]) != nil
        let hasText = pasteboard.availableType(from: [.string, .fileURL, .URL]) != nil
        return hasImage && !hasText
    }
}

extension KeyModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var modifiers: KeyModifiers = []
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        self = modifiers
    }
}
