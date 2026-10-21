import AppKit
import CoddUI

/// 09 FOCUS: every keyboard-focusable control unfocused, after a click (mouse focus draws nothing)
/// and keyboard-focused (the helmet `.input:focus` style: amber border + 1 px amber inset; the
/// 8 px glow is a layer shadow, which offscreen snapshots do not draw). Each specimen is rendered in
/// its own offscreen window (one first responder per window), with Full Keyboard Access and the
/// key window forced on, then shown as an image.
extension GalleryBoards {
    private struct FocusSpecimen {
        var name: String
        var size: NSSize?
        /// Fitting height at this width (wrapping content such as the toast).
        var width: CGFloat? = nil
        var make: () -> NSView
        /// The view that takes focus (nil: the specimen itself).
        var focusTarget: ((NSView) -> NSView)?
    }

    private enum FocusState { case none, mouse, keyboard }

    static func focus() -> NSView {
        let savedAccess = KeyboardFocus.fullKeyboardAccessOverride
        let savedKey = KeyboardFocus.keyWindowOverride
        KeyboardFocus.fullKeyboardAccessOverride = true
        KeyboardFocus.keyWindowOverride = true
        defer {
            KeyboardFocus.fullKeyboardAccessOverride = savedAccess
            KeyboardFocus.keyWindowOverride = savedKey
        }

        let specimens: [FocusSpecimen] = [
            FocusSpecimen(name: "CoddButton .btn", size: nil, make: { CoddButton("取消", style: .bracket(.normal, small: false)) }),
            FocusSpecimen(name: ".btn.primary", size: nil, make: { CoddButton("切換", style: .bracket(.primary, small: false)) }),
            FocusSpecimen(name: ".btn.sm.accent", size: nil, make: { CoddButton("Switch", style: .bracket(.accent, small: true)) }),
            FocusSpecimen(name: ".icon-btn", size: nil, make: {
                let button = CoddButton("", style: .icon(.settings))
                button.setAccessibilityLabel("設定")
                return button
            }),
            FocusSpecimen(name: ".pillbtn", size: nil, make: { CoddButton("Needs", style: .pill(count: "3")) }),
            FocusSpecimen(name: ".tab", size: nil, make: { CoddButton("zsh", style: .tab(lamp: "○", lampColor: Palette.dim)) }),
            FocusSpecimen(name: "link", size: nil, make: { CoddButton("開啟 →", style: .link) }),
            FocusSpecimen(name: "CheckboxButton .sx-cb", size: nil, make: { CheckboxButton(title: "5 小時", isOn: true) }),
            FocusSpecimen(name: ".sd-check", size: nil, make: {
                CheckboxButton(title: "同時暫停自動切換", hint: "AUTO-SWITCH 目前 OFF", style: .plain)
            }),
            FocusSpecimen(name: "SegmentedSwitch .seg", size: nil, make: {
                let seg = SegmentedSwitch(titles: ["Off", "Subtle", "Full"])
                seg.selectedIndex = 1
                return seg
            }),
            FocusSpecimen(name: "SwitchToggle .sw", size: nil, make: {
                let toggle = SwitchToggle(label: "通知")
                toggle.isOn = true
                return toggle
            }),
            FocusSpecimen(name: "StepperControl .sx-step", size: nil, make: {
                StepperControl(value: 2, minValue: 1, maxValue: 20, format: { "\(Int($0)) %" }, accessibilityLabel: "自動切換門檻")
            }),
            FocusSpecimen(name: "SelectButton .select", size: NSSize(width: 160, height: 30), make: {
                SelectButton(titles: ["13 px（預設）", "12 px"], accessibilityLabel: "UI 字級")
            }),
            FocusSpecimen(name: "RadioRowView .ns-radio", size: NSSize(width: 340, height: 24), make: {
                let radio = RadioRowView(title: "跟隨全域登入", hint: "切換帳號時一起換")
                radio.isOn = true
                return radio
            }),
            FocusSpecimen(name: "ToastView [UNDO]", size: nil, width: 380, make: {
                ToastView(text: "已切換到 #2 藍鵲", undo: {})
            }, focusTarget: { toast in
                toast.descendant(ofType: CoddButton.self) ?? toast
            }),
        ]

        var rows: [NSView] = []
        for specimen in specimens {
            let cells = [(FocusState.none, "unfocused"), (.mouse, "after a click"), (.keyboard, "keyboard focus")].map { state, caption in
                Specimen.captioned(image(of: specimen, state: state), caption)
            }
            let name = Specimen.sized(Specimen.caption(specimen.name), width: 200)
            let row = Specimen.row([name] + cells, spacing: 24)
            row.alignment = .top
            rows.append(row)
        }
        let input = Specimen.sized(InputField(placeholder: "別名"), width: 220)
        input.text = "工作室"
        input.isFocused = true
        rows.append(Specimen.row([Specimen.sized(Specimen.caption("InputField (any focus)"), width: 200),
                                  Specimen.captioned(input, "focused")], spacing: 24))

        return Specimen.board("FOCUS", caption: "Full Keyboard Access · .input:focus on every control · click draws nothing", sections: [
            Specimen.section("unfocused · after a click · keyboard focus (Tab)", Specimen.column(rows, spacing: 12)),
        ])
    }

    /// The specimen rendered in its own offscreen window, focused as `state` says.
    private static func image(of specimen: FocusSpecimen, state: FocusState) -> NSView {
        let view = specimen.make()
        let rep = ViewSnapshot.render(view, size: specimen.size, width: specimen.width) { window in
            let target = specimen.focusTarget?(view) ?? view
            switch state {
            case .none:
                break
            case .mouse:
                let saved = KeyboardFocus.focusOriginOverride
                KeyboardFocus.focusOriginOverride = .mouse
                window.makeFirstResponder(target)
                KeyboardFocus.focusOriginOverride = saved
            case .keyboard:
                KeyboardFocus.focusAsKeyboardNavigation(target)
            }
        }
        guard let rep else { return Specimen.caption("(not rendered)") }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignLeft
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.widthAnchor.constraint(equalToConstant: rep.size.width).isActive = true
        imageView.heightAnchor.constraint(equalToConstant: rep.size.height).isActive = true
        imageView.setAccessibilityLabel("\(specimen.name) \(state)")
        return imageView
    }
}
