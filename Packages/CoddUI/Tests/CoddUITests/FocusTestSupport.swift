import AppKit
import CoddUI

/// Helpers for the keyboard focus and accessibility tests (public API only).
@MainActor
enum FocusSupport {
    /// Runs `body` with Full Keyboard Access and the key window forced, then restores every
    /// ``KeyboardFocus`` override (other suites run without them).
    static func with(fullKeyboardAccess: Bool, keyWindow: Bool = true, _ body: () throws -> Void) rethrows {
        let savedAccess = KeyboardFocus.fullKeyboardAccessOverride
        let savedKey = KeyboardFocus.keyWindowOverride
        let savedOrigin = KeyboardFocus.focusOriginOverride
        KeyboardFocus.fullKeyboardAccessOverride = fullKeyboardAccess
        KeyboardFocus.keyWindowOverride = keyWindow
        defer {
            KeyboardFocus.fullKeyboardAccessOverride = savedAccess
            KeyboardFocus.keyWindowOverride = savedKey
            KeyboardFocus.focusOriginOverride = savedOrigin
        }
        try body()
    }

    /// Makes `view` the first responder as a click inside it would.
    @discardableResult
    static func focusAsMouse(_ view: NSView) -> Bool {
        let saved = KeyboardFocus.focusOriginOverride
        KeyboardFocus.focusOriginOverride = .mouse
        defer { KeyboardFocus.focusOriginOverride = saved }
        return view.window?.makeFirstResponder(view) ?? false
    }

    /// One focusable control kind, made fresh for every use.
    struct ControlCase {
        let name: String
        let size: NSSize
        let make: () -> NSView
    }

    static var controls: [ControlCase] {
        [
            ControlCase(name: "CoddButton", size: NSSize(width: 90, height: 28)) { CoddButton("取消", style: .bracket(.normal, small: false)) },
            ControlCase(name: "CheckboxButton", size: NSSize(width: 100, height: 26)) { CheckboxButton(title: "每週") },
            ControlCase(name: "SegmentedSwitch", size: NSSize(width: 160, height: 26)) {
                let seg = SegmentedSwitch(titles: ["Off", "Subtle", "Full"])
                seg.selectedIndex = 1
                return seg
            },
            ControlCase(name: "SwitchToggle", size: NSSize(width: 30, height: 16)) { SwitchToggle(label: "通知") },
            ControlCase(name: "StepperControl", size: NSSize(width: 110, height: 26)) {
                StepperControl(value: 2, minValue: 1, maxValue: 20, accessibilityLabel: "門檻")
            },
            ControlCase(name: "SelectButton", size: NSSize(width: 160, height: 30)) {
                SelectButton(titles: ["13 px（預設）", "12 px"], accessibilityLabel: "UI 字級")
            },
            ControlCase(name: "RadioRowView", size: NSSize(width: 300, height: 24)) { RadioRowView(title: "新對話", hint: "自動帶 --session-id") },
        ]
    }

    /// `isEnabled` of any of the custom controls.
    static func setEnabled(_ view: NSView, _ enabled: Bool) {
        switch view {
        case let control as NSControl: control.isEnabled = enabled
        case let select as SelectButton: select.isEnabled = enabled
        case let radio as RadioRowView: radio.isEnabled = enabled
        default: break
        }
    }

    /// Whether the pixel at `point` is the focus amber.
    static func isAmber(_ rep: NSBitmapImageRep, at point: CGPoint) -> Bool {
        TestSupport.close(TestSupport.rgb(ViewSnapshot.color(at: point, in: rep)), TestSupport.rgb(Palette.amber), tolerance: 14)
    }

    /// A key event with a key code (arrows get their function-key characters).
    static func key(_ key: KeyboardFocus.Key, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        let (characters, code): (String, UInt16)
        switch key {
        case .space: (characters, code) = (" ", 49)
        case .return: (characters, code) = ("\r", 36)
        case .left: (characters, code) = (String(UnicodeScalar(NSLeftArrowFunctionKey)!), 123)
        case .right: (characters, code) = (String(UnicodeScalar(NSRightArrowFunctionKey)!), 124)
        case .down: (characters, code) = (String(UnicodeScalar(NSDownArrowFunctionKey)!), 125)
        case .up: (characters, code) = (String(UnicodeScalar(NSUpArrowFunctionKey)!), 126)
        }
        let flags: NSEvent.ModifierFlags = [KeyboardFocus.Key.left, .right, .up, .down].contains(key) ? modifiers.union([.numericPad, .function]) : modifiers
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// A key the controls do not handle (`a`).
    static var letterKey: NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)
    }
}

/// A superview that records the keys its subviews pass up the responder chain (so an unhandled key
/// never reaches NSApplication, which would beep).
final class KeyCatcher: FlippedView {
    private(set) var keyCodes: [UInt16] = []

    override func keyDown(with event: NSEvent) { keyCodes.append(event.keyCode) }
}
