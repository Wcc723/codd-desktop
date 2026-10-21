import Carbon.HIToolbox
import Foundation

/// Why a global hotkey could not be registered; `message` is the 繁中 line shown under the row.
public enum GlobalHotkeyError: Error, Equatable, Sendable, CustomStringConvertible, LocalizedError {
    /// Another app (or another registration) already holds the combo (`eventHotKeyExistsErr`).
    case alreadyInUse(KeyCombo)
    /// No ⌘ ⌥ ⌃ in the combo: it would swallow ordinary typing everywhere.
    case needsModifier(KeyCombo)
    /// The process has no application event target (no window server session).
    case noEventTarget
    /// Any other Carbon failure.
    case failed(KeyCombo, Int32)

    public var message: String {
        switch self {
        case .alreadyInUse(let combo): "\(combo) 已被其他 App 使用，請改用別的組合鍵"
        case .needsModifier(let combo): "\(combo) 需要包含 ⌘、⌥ 或 ⌃"
        case .noEventTarget: "無法註冊全域快捷鍵：沒有可用的事件目標"
        case .failed(let combo, let status): "無法註冊 \(combo)（OSStatus \(status)）"
        }
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

/// One system-wide hotkey through Carbon's `RegisterEventHotKey` on the application event
/// target (no Accessibility permission needed), registered with `kEventHotKeyExclusive` so CODD
/// never takes a combo another app already holds (D22; ⌥Space is the default of other tools too).
/// One registration per instance: `register` replaces the previous combo only when the new one
/// succeeded, so a refused combo leaves the old one working. The action runs on the main actor.
@MainActor
public final class GlobalHotkey {
    public private(set) var registered: KeyCombo?
    private var action: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Tells this instance's presses from other instances' (each has its own id).
    let identifier: UInt32

    /// `'CODD'`.
    static let signature: OSType = 0x434F_4444
    private static var nextIdentifier: UInt32 = 1

    public init() {
        identifier = Self.nextIdentifier
        Self.nextIdentifier &+= 1
    }

    isolated deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers `combo` exclusively. Throws `GlobalHotkeyError` (the previous registration, if
    /// any, then stays). Registering the combo that is already registered only swaps the action.
    public func register(_ combo: KeyCombo, action: @escaping @MainActor () -> Void) throws {
        guard combo.hasRequiredModifier else { throw GlobalHotkeyError.needsModifier(combo) }
        if combo == registered, hotKeyRef != nil {
            self.action = action
            return
        }
        guard let target = GetApplicationEventTarget() else { throw GlobalHotkeyError.noEventTarget }
        try installHandler(on: target, for: combo)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, target, OptionBits(kEventHotKeyExclusive), &ref)
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) { throw GlobalHotkeyError.alreadyInUse(combo) }
            throw GlobalHotkeyError.failed(combo, status)
        }
        if let old = hotKeyRef { UnregisterEventHotKey(old) }
        hotKeyRef = ref
        registered = combo
        self.action = action
    }

    /// Releases the combo (no-op when nothing is registered).
    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
        action = nil
    }

    /// One `kEventHotKeyPressed` handler per instance on the application target; it answers
    /// only for this instance's id, so several instances coexist.
    private func installHandler(on target: EventTargetRef, for combo: KeyCombo) throws {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(target, globalHotkeyHandler, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &ref)
        guard status == noErr, let ref else { throw GlobalHotkeyError.failed(combo, status) }
        handlerRef = ref
    }

    /// A press of hotkey `id`: runs the action when it is this instance's.
    func fire(signature: OSType, id: UInt32) -> Bool {
        guard signature == Self.signature, id == identifier, hotKeyRef != nil, let action else { return false }
        action()
        return true
    }
}

/// The Carbon callback (no captures, so it converts to a C function pointer). Carbon delivers
/// application-target events on the main thread; `userData` is the unretained `GlobalHotkey`,
/// valid until its deinit removes this handler.
private func globalHotkeyHandler(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var id = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &id)
    guard status == noErr else { return status }
    // Plain values into the isolated closure (raw pointers and C structs are not Sendable).
    let address = UInt(bitPattern: userData)
    let signature = id.signature
    let number = id.id
    let handled = MainActor.assumeIsolated { () -> Bool in
        guard let pointer = UnsafeRawPointer(bitPattern: address) else { return false }
        return Unmanaged<GlobalHotkey>.fromOpaque(pointer).takeUnretainedValue().fire(signature: signature, id: number)
    }
    return handled ? noErr : OSStatus(eventNotHandledErr)
}
