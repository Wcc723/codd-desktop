import Carbon

/// Keyboard input sources for the automated key tests.
///
/// Both engines derive the kitty-protocol key code from
/// `NSEvent.characters(byApplyingModifiers: [])`, i.e. from the *active
/// keyboard layout*. With an input method such as 注音 active, that layout maps
/// letter keys to bopomofo, so the same physical Ctrl+C encodes differently.
/// The probe therefore runs its key matrix under an ASCII layout first and then
/// under the enabled CJK input method, and puts the user's source back.
///
/// Selecting a source is a global, user-visible change (the menu bar input
/// menu flips for a moment); it is only done by `--probe` / `--bench`, and
/// every switch is undone by `restore(_:)`.
@MainActor
enum InputSources {
    /// One selectable keyboard input source.
    struct Source {
        let id: String
        let asciiCapable: Bool
        fileprivate let reference: TISInputSource
    }

    static func currentIdentifier() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "unknown" }
        return string(source, kTISPropertyInputSourceID) ?? "unknown"
    }

    /// The source to measure ASCII behaviour with: the current one when it is
    /// ASCII-capable, else ABC / US, else any enabled ASCII-capable layout.
    static func asciiLayout() -> Source? {
        let sources = enabledKeyboardSources()
        let current = currentIdentifier()
        if let active = sources.first(where: { $0.id == current && $0.asciiCapable }) { return active }
        for preferred in ["com.apple.keylayout.ABC", "com.apple.keylayout.US"] {
            if let match = sources.first(where: { $0.id == preferred }) { return match }
        }
        return sources.first { $0.asciiCapable && $0.id.contains("keylayout") }
    }

    /// The first enabled input method that is not ASCII-capable (注音, 倉頡,
    /// McBopomofo, …), or nil when only plain layouts are enabled.
    static func cjkInputMethod() -> Source? {
        let sources = enabledKeyboardSources().filter { !$0.asciiCapable && $0.id.contains("inputmethod") }
        // Prefer Zhuyin variants: the spike exists to test them.
        return sources.first { $0.id.localizedCaseInsensitiveContains("zhuyin") || $0.id.localizedCaseInsensitiveContains("bopomofo") }
            ?? sources.first
    }

    /// Selects `source` and waits until the system reports it as current.
    /// Returns false when the switch did not take.
    static func select(_ source: Source) async -> Bool {
        guard currentIdentifier() != source.id else { return true }
        guard TISSelectInputSource(source.reference) == noErr else { return false }
        return await Wait.until(timeout: .seconds(2), every: .milliseconds(20)) {
            currentIdentifier() == source.id
        }
    }

    /// Re-selects the source that was current when `identifier` was read.
    static func restore(_ identifier: String) async {
        guard currentIdentifier() != identifier,
              let original = enabledKeyboardSources().first(where: { $0.id == identifier })
        else { return }
        _ = await select(original)
    }

    /// `", secure event input is on"` while some process (the lock screen,
    /// a password field) holds Secure Event Input, which forces an ASCII
    /// layout and blocks switching to an input method; empty otherwise.
    static var secureInputNote: String {
        IsSecureEventInputEnabled() ? ", secure event input is on (screen locked or a password field focused)" : ""
    }

    // MARK: - TIS plumbing

    private static func enabledKeyboardSources() -> [Source] {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        return list.compactMap { source in
            guard bool(source, kTISPropertyInputSourceIsSelectCapable),
                  let id = string(source, kTISPropertyInputSourceID)
            else { return nil }
            return Source(id: id, asciiCapable: bool(source, kTISPropertyInputSourceIsASCIICapable), reference: source)
        }
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func bool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
}
