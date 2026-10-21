import AppKit
@testable import CoddUI
import Testing

/// Keyboard focus (M5 D21): Full Keyboard Access decides who takes focus, the helmet focus style
/// shows only for keyboard focus in a key window, the keys, and sizes that never change.
@MainActor
@Suite("Keyboard focus", .serialized)
struct KeyboardFocusTests {
    init() {
        #expect(TestSupport.prepare(), "App/Fonts must register")
    }

    // MARK: Eligibility

    @Test func focusFollowsFullKeyboardAccess() {
        for control in FocusSupport.controls {
            let view = control.make()
            let window = TestSupport.host(view, size: control.size)
            defer { window.close() }
            FocusSupport.with(fullKeyboardAccess: false) {
                #expect(!view.acceptsFirstResponder, "\(control.name) without Full Keyboard Access")
                #expect(!view.canBecomeKeyView, "\(control.name)")
                // AppKit's makeFirstResponder returns true when a refusing view leaves the window
                // itself first responder, so check who holds the focus instead.
                window.makeFirstResponder(view)
                #expect(window.firstResponder !== view, "\(control.name)")
            }
            FocusSupport.with(fullKeyboardAccess: true) {
                #expect(view.acceptsFirstResponder, "\(control.name) with Full Keyboard Access")
                #expect(view.canBecomeKeyView, "\(control.name)")
                (view as? any KeyboardFocusRefusing)?.refusesFirstResponder = true
                #expect(!view.acceptsFirstResponder, "\(control.name) refusing")
                (view as? any KeyboardFocusRefusing)?.refusesFirstResponder = false
                FocusSupport.setEnabled(view, false)
                #expect(!view.acceptsFirstResponder, "\(control.name) disabled")
                FocusSupport.setEnabled(view, true)
                view.isHidden = true
                #expect(!view.canBecomeKeyView, "\(control.name) hidden")
                view.isHidden = false
                #expect(view.canBecomeKeyView)
            }
        }
    }

    /// The window's key-view loop (`nextValidKeyView`) reaches the controls only with Full Keyboard
    /// Access; the editable text field is in it either way.
    @Test func keyLoopMembershipFollowsTheOverride() {
        let views = FocusSupport.controls.map { $0.make() }
        let field = NSTextField(string: "")
        let stack = columnStack(views + [field], spacing: 6)
        let window = TestSupport.host(stack, size: NSSize(width: 400, height: 400))
        defer { window.close() }
        window.recalculateKeyViewLoop()
        func loop() -> [NSView] {
            var out: [NSView] = []
            var seen = Set<ObjectIdentifier>()
            var current = window.contentView?.nextValidKeyView
            while let view = current, seen.insert(ObjectIdentifier(view)).inserted, out.count < 100 {
                out.append(view)
                current = view.nextValidKeyView
            }
            return out
        }
        FocusSupport.with(fullKeyboardAccess: false) {
            let members = loop()
            #expect(members.contains { $0 === field })
            for view in views { #expect(!members.contains { $0 === view }, "\(type(of: view)) is in the loop without Full Keyboard Access") }
        }
        FocusSupport.with(fullKeyboardAccess: true) {
            let members = loop()
            #expect(members.contains { $0 === field })
            for view in views { #expect(members.contains { $0 === view }, "\(type(of: view)) is missing from the loop") }
        }
    }

    /// Turning Full Keyboard Access off hands the focus of a custom control back to its window.
    @Test func turningFullKeyboardAccessOffMovesFocusOff() {
        let button = CoddButton("切換", style: .bracket(.primary, small: false))
        let window = TestSupport.host(button, size: NSSize(width: 90, height: 28))
        defer { window.close() }
        FocusSupport.with(fullKeyboardAccess: true) {
            #expect(KeyboardFocus.focusAsKeyboardNavigation(button))
            #expect(window.firstResponder === button)
            #expect(button.focusTracker.showsFocusRing)
            KeyboardFocus.fullKeyboardAccessOverride = false
            #expect(window.firstResponder !== button)
            #expect(!button.focusTracker.showsFocusRing)
        }
    }

    // MARK: Focus style

    /// The amber ring (border + 1 px inset) is drawn for keyboard focus only: not unfocused, not after
    /// a click that focused the control, not while the window is not key.
    @Test func focusRingOnlyForKeyboardFocus() throws {
        for control in FocusSupport.controls {
            let border = CGPoint(x: 0.5, y: control.size.height / 2)
            let inset = CGPoint(x: 1.5, y: control.size.height / 2)
            try FocusSupport.with(fullKeyboardAccess: true) {
                let plain = control.make()
                let unfocused = try #require(ViewSnapshot.render(plain, size: control.size))
                #expect(!FocusSupport.isAmber(unfocused, at: border) && !FocusSupport.isAmber(unfocused, at: inset), "\(control.name) unfocused")

                let clicked = control.make()
                let mouse = try #require(ViewSnapshot.render(clicked, size: control.size) { _ in
                    #expect(FocusSupport.focusAsMouse(clicked), "\(control.name) takes mouse focus")
                    #expect((clicked as? any KeyboardFocusTracking)?.focusTracker.isKeyboardFocus == false)
                })
                #expect(!FocusSupport.isAmber(mouse, at: border) && !FocusSupport.isAmber(mouse, at: inset), "\(control.name) after a click")

                let tabbed = control.make()
                let keyboard = try #require(ViewSnapshot.render(tabbed, size: control.size) { _ in
                    #expect(KeyboardFocus.focusAsKeyboardNavigation(tabbed), "\(control.name) takes keyboard focus")
                })
                #expect(FocusSupport.isAmber(keyboard, at: border) && FocusSupport.isAmber(keyboard, at: inset), "\(control.name) keyboard focus")
            }
            try FocusSupport.with(fullKeyboardAccess: true, keyWindow: false) {
                let tabbed = control.make()
                let background = try #require(ViewSnapshot.render(tabbed, size: control.size) { _ in
                    KeyboardFocus.focusAsKeyboardNavigation(tabbed)
                })
                #expect(!FocusSupport.isAmber(background, at: inset), "\(control.name) focused in a window that is not key")
            }
        }
    }

    /// `.sd-check` keeps the artboard's outline (1 px amber, 2 px outside the box) instead of the ring.
    @Test func plainCheckboxDrawsTheArtboardOutline() throws {
        try FocusSupport.with(fullKeyboardAccess: true) {
            let size = NSSize(width: 200, height: 20)
            let box = CheckboxButton(title: "同時暫停自動切換", style: .plain)
            let rep = try #require(ViewSnapshot.render(box, size: size) { _ in KeyboardFocus.focusAsKeyboardNavigation(box) })
            #expect(FocusSupport.isAmber(rep, at: CGPoint(x: 14 + 2.5, y: 10)))
            let other = CheckboxButton(title: "同時暫停自動切換", style: .plain)
            let mouse = try #require(ViewSnapshot.render(other, size: size) { _ in FocusSupport.focusAsMouse(other) })
            #expect(!FocusSupport.isAmber(mouse, at: CGPoint(x: 14 + 2.5, y: 10)))
        }
    }

    /// Text inputs keep their focus look, drawn with the same ring.
    @Test func fieldBoxFocusUsesTheRing() throws {
        let field = InputField(placeholder: "別名")
        field.isFocused = true
        let rep = try #require(ViewSnapshot.render(field, size: NSSize(width: 200, height: 30)))
        #expect(FocusSupport.isAmber(rep, at: CGPoint(x: 0.5, y: 15)) && FocusSupport.isAmber(rep, at: CGPoint(x: 1.5, y: 15)))
        #expect(field.shadow?.shadowBlurRadius == KeyboardFocus.ringGlow.shadowBlurRadius)
        #expect(field.shadow?.shadowColor == Palette.amberGlow)
    }

    /// A key the control handled after a click turns its focus visible (`:focus-visible`).
    @Test func keyAfterClickShowsTheRing() throws {
        try FocusSupport.with(fullKeyboardAccess: true) {
            let box = CheckboxButton(title: "每週")
            let window = TestSupport.host(box, size: NSSize(width: 100, height: 26))
            defer { window.close() }
            #expect(FocusSupport.focusAsMouse(box))
            #expect(!box.focusTracker.showsFocusRing)
            box.keyDown(with: try #require(FocusSupport.key(.space)))
            #expect(box.isOn)
            #expect(box.focusTracker.showsFocusRing)
            #expect(box.shadow != nil)
            window.makeFirstResponder(nil)
            #expect(!box.focusTracker.showsFocusRing)
            #expect(box.shadow == nil)
        }
    }

    /// Focus never changes a control's size or frame.
    @Test func intrinsicSizesDoNotChangeWithFocus() {
        for control in FocusSupport.controls {
            let view = control.make()
            let before = view.intrinsicContentSize
            FocusSupport.with(fullKeyboardAccess: true) {
                let window = TestSupport.host(view, size: control.size)
                defer { window.close() }
                let frame = view.frame
                #expect(KeyboardFocus.focusAsKeyboardNavigation(view), "\(control.name)")
                #expect(view.intrinsicContentSize == before, "\(control.name) focused")
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(view.frame == frame, "\(control.name) frame")
                window.makeFirstResponder(nil)
                #expect(view.intrinsicContentSize == before, "\(control.name) after focus")
            }
            #expect(view.intrinsicContentSize == before, "\(control.name) override off")
        }
    }

    // MARK: Keys

    @Test func keyClassification() throws {
        func classify(_ key: KeyboardFocus.Key, _ modifiers: NSEvent.ModifierFlags = []) throws -> KeyboardFocus.Key? {
            KeyboardFocus.key(of: try #require(FocusSupport.key(key, modifiers: modifiers)))
        }
        #expect(try classify(.space) == .space)
        #expect(try classify(.space, .shift) == .space)
        #expect(try classify(.space, .command) == nil)
        #expect(try classify(.return) == .return)
        #expect(try classify(.return, .command) == nil)
        for key in [KeyboardFocus.Key.left, .right, .up, .down] {
            #expect(try classify(key) == key)
            #expect(try classify(key, .option) == nil)
        }
        let letter = try #require(FocusSupport.letterKey)
        #expect(KeyboardFocus.key(of: letter) == nil)
    }

    @Test func originClassification() throws {
        let button = CoddButton("切換", style: .bracket(.normal, small: false))
        let window = TestSupport.host(button, size: NSSize(width: 200, height: 40))
        defer { window.close() }
        button.frame = NSRect(x: 0, y: 0, width: 90, height: 28)
        func mouse(at point: CGPoint, windowNumber: Int) -> NSEvent? {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let inside = button.convert(CGPoint(x: 10, y: 10), to: nil)
        let outside = button.convert(CGPoint(x: 150, y: 10), to: nil)
        let space = try #require(FocusSupport.key(.space))
        let click = try #require(mouse(at: inside, windowNumber: window.windowNumber))
        let clickBeside = try #require(mouse(at: outside, windowNumber: window.windowNumber))
        let clickElsewhere = try #require(mouse(at: inside, windowNumber: window.windowNumber + 9_999))
        #expect(KeyboardFocus.origin(of: nil, for: button) == .program)
        #expect(KeyboardFocus.origin(of: space, for: button) == .keyboard)
        #expect(KeyboardFocus.origin(of: click, for: button) == .mouse)
        #expect(KeyboardFocus.origin(of: clickBeside, for: button) == .program)
        #expect(KeyboardFocus.origin(of: clickElsewhere, for: button) == .program)
    }

    @Test func buttonPressesOnSpaceAndReturn() throws {
        let counter = ActionCounter()
        let button = CoddButton("切換", style: .bracket(.primary, small: false), target: counter, action: #selector(ActionCounter.fire(_:)))
        let catcher = KeyCatcher()
        catcher.addSubview(button)
        button.frame = NSRect(x: 0, y: 0, width: 90, height: 28)
        let window = TestSupport.host(catcher, size: NSSize(width: 120, height: 40))
        defer { window.close() }
        button.keyDown(with: try #require(FocusSupport.key(.space)))
        #expect(counter.count == 1)
        button.keyDown(with: try #require(FocusSupport.key(.return)))
        #expect(counter.count == 2)
        button.keyDown(with: try #require(FocusSupport.letterKey))
        #expect(counter.count == 2)
        #expect(catcher.keyCodes == [0])
    }

    @Test func togglesTakeSpaceAndLeaveReturn() throws {
        let counter = ActionCounter()
        let box = CheckboxButton(title: "每週", target: counter, action: #selector(ActionCounter.fire(_:)))
        let toggle = SwitchToggle(label: "通知")
        toggle.target = counter
        toggle.action = #selector(ActionCounter.fire(_:))
        let catcher = KeyCatcher()
        let placements: [(NSView, CGFloat)] = [(box, 0), (toggle, 120)]
        for (view, x) in placements {
            catcher.addSubview(view)
            view.frame = NSRect(x: x, y: 0, width: view.intrinsicContentSize.width, height: view.intrinsicContentSize.height)
        }
        let window = TestSupport.host(catcher, size: NSSize(width: 200, height: 30))
        defer { window.close() }
        box.keyDown(with: try #require(FocusSupport.key(.space)))
        toggle.keyDown(with: try #require(FocusSupport.key(.space)))
        #expect(box.isOn && toggle.isOn)
        #expect(counter.count == 2)
        box.keyDown(with: try #require(FocusSupport.key(.return)))
        toggle.keyDown(with: try #require(FocusSupport.key(.return)))
        #expect(box.isOn && toggle.isOn)
        #expect(counter.count == 2)
        #expect(catcher.keyCodes == [36, 36])
    }

    @Test func segmentedSwitchMovesWithArrows() throws {
        let counter = ActionCounter()
        let seg = SegmentedSwitch(titles: ["Off", "Subtle", "Full"])
        seg.target = counter
        seg.action = #selector(ActionCounter.fire(_:))
        let catcher = KeyCatcher()
        catcher.addSubview(seg)
        seg.frame = NSRect(origin: .zero, size: seg.intrinsicContentSize)
        let window = TestSupport.host(catcher, size: NSSize(width: 300, height: 30))
        defer { window.close() }
        seg.keyDown(with: try #require(FocusSupport.key(.right)))
        seg.keyDown(with: try #require(FocusSupport.key(.right)))
        #expect(seg.selectedIndex == 2)
        #expect(counter.count == 2)
        seg.keyDown(with: try #require(FocusSupport.key(.right)))
        #expect(seg.selectedIndex == 2)
        #expect(counter.count == 2)
        seg.keyDown(with: try #require(FocusSupport.key(.left)))
        #expect(seg.selectedIndex == 1)
        #expect(counter.count == 3)
        seg.selectedIndex = -1
        seg.keyDown(with: try #require(FocusSupport.key(.space)))
        #expect(seg.selectedIndex == 0)
        #expect(counter.count == 4)
        seg.keyDown(with: try #require(FocusSupport.key(.down)))
        seg.keyDown(with: try #require(FocusSupport.key(.return)))
        #expect(catcher.keyCodes == [125, 36])
    }

    @Test func stepperStepsWithAllArrows() throws {
        let stepper = StepperControl(value: 5, minValue: 1, maxValue: 9, accessibilityLabel: "門檻")
        let catcher = KeyCatcher()
        catcher.addSubview(stepper)
        stepper.frame = NSRect(origin: .zero, size: stepper.intrinsicContentSize)
        let window = TestSupport.host(catcher, size: NSSize(width: 200, height: 30))
        defer { window.close() }
        stepper.keyDown(with: try #require(FocusSupport.key(.up)))
        stepper.keyDown(with: try #require(FocusSupport.key(.right)))
        #expect(stepper.value == 7)
        stepper.keyDown(with: try #require(FocusSupport.key(.down)))
        stepper.keyDown(with: try #require(FocusSupport.key(.left)))
        stepper.keyDown(with: try #require(FocusSupport.key(.left)))
        #expect(stepper.value == 4)
        stepper.keyDown(with: try #require(FocusSupport.key(.return)))
        #expect(catcher.keyCodes == [36])
    }

    /// Arrows pick the neighbouring enabled row and move the keyboard focus with them; Space picks the
    /// focused row; past either end the key goes up the responder chain.
    @Test func radioRowsMoveWithArrows() throws {
        try FocusSupport.with(fullKeyboardAccess: true) {
            var picked: [String] = []
            let rows = ["新對話", "接續先前對話", "停用", "從 Remote Control 啟動"].map { RadioRowView(title: $0, hint: "") }
            for row in rows { row.onClick = { picked.append(row.title) } }
            rows[2].isEnabled = false
            let catcher = KeyCatcher()
            let stack = columnStack(rows, spacing: 4)
            catcher.addSubview(stack)
            stack.pinEdges(to: catcher)
            let window = TestSupport.host(catcher, size: NSSize(width: 300, height: 120))
            defer { window.close() }
            #expect(rows[0].siblingRows.count == 3)
            #expect(KeyboardFocus.focusAsKeyboardNavigation(rows[0]))
            rows[0].keyDown(with: try #require(FocusSupport.key(.down)))
            #expect(picked == ["接續先前對話"])
            #expect(window.firstResponder === rows[1])
            #expect(rows[1].focusTracker.showsFocusRing)
            rows[1].keyDown(with: try #require(FocusSupport.key(.right)))
            #expect(picked.last == "從 Remote Control 啟動")
            #expect(window.firstResponder === rows[3])
            rows[3].keyDown(with: try #require(FocusSupport.key(.down)))
            #expect(catcher.keyCodes == [125])
            rows[3].keyDown(with: try #require(FocusSupport.key(.up)))
            #expect(window.firstResponder === rows[1])
            rows[1].keyDown(with: try #require(FocusSupport.key(.space)))
            #expect(picked == ["接續先前對話", "從 Remote Control 啟動", "接續先前對話", "接續先前對話"])
        }
    }

    @Test func selectOpensItsMenuFromTheKeyboard() throws {
        let select = SelectButton(titles: ["13 px（預設）", "12 px"], accessibilityLabel: "UI 字級")
        var menus: [[String]] = []
        select.menuPresenter = { menu in menus.append(menu.items.map(\.title)) }
        let catcher = KeyCatcher()
        catcher.addSubview(select)
        select.translatesAutoresizingMaskIntoConstraints = true
        select.frame = NSRect(x: 0, y: 0, width: 160, height: 30)
        let window = TestSupport.host(catcher, size: NSSize(width: 200, height: 40))
        defer { window.close() }
        for key in [KeyboardFocus.Key.space, .return, .down, .up] {
            select.keyDown(with: try #require(FocusSupport.key(key)))
        }
        #expect(menus.count == 4)
        #expect(menus.first == ["13 px（預設）", "12 px"])
        select.keyDown(with: try #require(FocusSupport.letterKey))
        #expect(menus.count == 4)
        #expect(catcher.keyCodes == [0])
        select.isEnabled = false
        select.keyDown(with: try #require(FocusSupport.key(.space)))
        #expect(menus.count == 4)
        #expect(catcher.keyCodes == [0, 49])
    }
}
