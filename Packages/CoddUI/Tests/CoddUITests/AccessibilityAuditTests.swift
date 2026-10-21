import AppKit
import CoddUI
import Testing

/// AccessibilityAudit (M5 D21, plan §2.6) on offscreen windows that are never ordered in.
@MainActor
@Suite("Accessibility audit", .serialized)
struct AccessibilityAuditTests {
    init() {
        #expect(TestSupport.prepare(), "App/Fonts must register")
    }

    private static let image = NSImage(size: NSSize(width: 16, height: 16))

    @Test func flagsUnlabeledImageButtonsAndAcceptsLabeledOnes() {
        let bare = NSButton(image: Self.image, target: nil, action: nil)
        let labeled = NSButton(image: Self.image, target: nil, action: nil)
        labeled.setAccessibilityLabel("設定")
        let titled = NSButton(title: "OK", target: nil, action: nil)
        let icon = CoddButton("", style: .icon(.settings))
        let namedIcon = CoddButton("", style: .icon(.search))
        namedIcon.setAccessibilityLabel("搜尋")
        let field = NSTextField(string: "")
        field.placeholderString = "名稱"
        let stack = hStack([bare, labeled, titled, icon, namedIcon, field], spacing: 8)
        let window = TestSupport.host(stack, size: NSSize(width: 640, height: 40))
        defer { window.close() }

        let report = AccessibilityAudit.audit(window: window, screen: "buttons", checkKeyLoop: false)
        #expect(report.screen == "buttons")
        #expect(report.interactive == 6)
        #expect(Set(report.unlabeled.map(\.path)) == ["Window/ContentView/NSButton[1]", "Window/ContentView/CoddButton[1]"])
        #expect(report.unlabeled.allSatisfy { $0.role == "AXButton" && $0.problem == AccessibilityAudit.Finding.unlabeled && $0.label == nil })
        #expect(report.outsideKeyLoop.isEmpty)
        let bareFinding = report.unlabeled.first { $0.path.hasSuffix("NSButton[1]") }
        #expect(bareFinding?.frame == bare.convert(bare.bounds, to: nil))
    }

    /// A legacy scroller's arrows and page areas (AppKit's unlabeled AXButton parts) are not
    /// findings; an unlabeled button inside the scroll view still is.
    @Test func scrollerPartsAreNotFindings() {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 2000))
        let bare = NSButton(image: Self.image, target: nil, action: nil)
        bare.frame = NSRect(x: 4, y: 4, width: 28, height: 28)
        document.addSubview(bare)
        scroll.documentView = document
        let window = TestSupport.host(scroll, size: NSSize(width: 240, height: 200))
        defer { window.close() }
        let report = AccessibilityAudit.audit(window: window, screen: "scroll", checkKeyLoop: false)
        #expect(report.unlabeled.map(\.path).allSatisfy { !$0.contains("NSScroller") })
        #expect(report.unlabeled.count == 1)
    }

    @Test func hiddenZeroSizedAndTransparentViewsAreIgnored() {
        let root = FlippedView()
        func add(_ view: NSView, to parent: NSView, frame: NSRect) {
            parent.addSubview(view)
            view.frame = frame
        }
        let hidden = NSButton(image: Self.image, target: nil, action: nil)
        hidden.isHidden = true
        add(hidden, to: root, frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        let ghost = NSButton(image: Self.image, target: nil, action: nil)
        ghost.alphaValue = 0
        add(ghost, to: root, frame: NSRect(x: 30, y: 0, width: 28, height: 28))
        add(NSButton(image: Self.image, target: nil, action: nil), to: root, frame: .zero)
        let faded = FlippedView()
        faded.alphaValue = 0
        add(faded, to: root, frame: NSRect(x: 60, y: 0, width: 100, height: 30))
        add(CoddButton("", style: .icon(.plus)), to: faded, frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        let hiddenGroup = FlippedView()
        hiddenGroup.isHidden = true
        add(hiddenGroup, to: root, frame: NSRect(x: 170, y: 0, width: 100, height: 30))
        add(CoddButton("", style: .icon(.plus)), to: hiddenGroup, frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        add(NSButton(title: "OK", target: nil, action: nil), to: root, frame: NSRect(x: 280, y: 0, width: 60, height: 28))
        let window = TestSupport.host(root, size: NSSize(width: 400, height: 40))
        defer { window.close() }

        let report = AccessibilityAudit.audit(window: window, screen: "hidden")
        #expect(report.interactive == 1)
        #expect(report.unlabeled.isEmpty)
    }

    /// The key-loop walk forces Full Keyboard Access on (and restores the override): CoddUI controls
    /// and their accessibility children are in the loop, a view that never takes focus is listed,
    /// disabled controls are not.
    @Test func keyLoopMembershipWithTheOverrideOnAndOff() {
        for access in [false, true] {
            FocusSupport.with(fullKeyboardAccess: access) {
                let button = CoddButton("切換", style: .bracket(.primary, small: false))
                let box = CheckboxButton(title: "每週")
                let seg = SegmentedSwitch(titles: ["Tree", "State"])
                let outside = PressOnlyView(label: "外部")
                let disabled = CoddButton("停用", style: .bracket(.normal, small: false))
                disabled.isEnabled = false
                let field = NSTextField(string: "")
                field.setAccessibilityLabel("名稱")
                let stack = hStack([button, box, seg, outside, disabled, field], spacing: 8)
                let window = TestSupport.host(stack, size: NSSize(width: 700, height: 40))
                defer { window.close() }

                let report = AccessibilityAudit.audit(window: window, screen: "loop")
                #expect(report.outsideKeyLoop.map(\.path) == ["Window/ContentView/PressOnlyView"], "override \(access)")
                #expect(report.outsideKeyLoop.first?.problem == AccessibilityAudit.Finding.notInKeyLoop)
                #expect(report.outsideKeyLoop.first?.label == "外部")
                // button, checkbox, 2 segments, the press-only view, the disabled button, the field.
                #expect(report.interactive == 7)
                #expect(report.unlabeled.isEmpty)
                #expect(KeyboardFocus.fullKeyboardAccessOverride == access)
                #expect(button.acceptsFirstResponder == access)
            }
        }
    }

    @Test func reportsAreCodableWithStablePaths() throws {
        func makeWindow() -> NSWindow {
            let card = CardView(title: "~/.claude")
            let icon = CoddButton("", style: .icon(.plus))
            card.setHeader(trailing: [icon, CoddButton("更新", style: .bracket(.normal, small: true))])
            return TestSupport.host(card, size: NSSize(width: 400, height: 120))
        }
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        let a = AccessibilityAudit.audit(window: first, screen: "card")
        let b = AccessibilityAudit.audit(window: second, screen: "card")
        #expect(a.unlabeled.map(\.path) == b.unlabeled.map(\.path))
        #expect(a.unlabeled.map(\.path) == ["Window/ContentView/CardView/CoddButton[1]"])

        let summary = AccessibilityAudit.Summary(screens: [a, b])
        #expect(summary.unlabeled == 2)
        let data = try JSONEncoder().encode(summary)
        #expect(try JSONDecoder().decode(AccessibilityAudit.Summary.self, from: data) == summary)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["unlabeled"] as? Int == 2)
        #expect((object["screens"] as? [[String: Any]])?.first?["screen"] as? String == "card")
    }

    @Test func auditsADetachedView() {
        let card = CardView(title: "MCP")
        card.frame = NSRect(x: 0, y: 0, width: 300, height: 100)
        let icon = CoddButton("", style: .icon(.plus))
        card.contentView.addSubview(icon)
        icon.frame = NSRect(x: 0, y: 0, width: 28, height: 28)
        let report = AccessibilityAudit.audit(view: card, screen: "detached")
        #expect(report.interactive == 1)
        #expect(report.unlabeled.map(\.path) == ["CardView/CoddButton"])
        #expect(report.outsideKeyLoop.isEmpty)
    }

    /// A disabled form row hides its controls from VoiceOver, so the audit does not see them.
    @Test func disabledFormRowsAreSkipped() {
        let row = FormRowView(name: "門檻", controls: [CoddButton("", style: .icon(.plus))], milestone: "M5")
        let window = TestSupport.host(row, size: NSSize(width: 640, height: 51))
        defer { window.close() }
        #expect(AccessibilityAudit.audit(window: window, screen: "row").unlabeled.count == 1)
        row.isEnabled = false
        #expect(AccessibilityAudit.audit(window: window, screen: "row").interactive == 0)
    }

    @Test func interactiveRolesMatchThePlan() {
        for role in ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
                     "AXComboBox", "AXSlider", "AXIncrementor", "AXLink", "AXDisclosureTriangle", "AXRow", "AXCell"] {
            #expect(AccessibilityAudit.interactiveRoles.contains(role), "\(role)")
        }
        #expect(!AccessibilityAudit.interactiveRoles.contains("AXStaticText"))
        #expect(!AccessibilityAudit.interactiveRoles.contains("AXGroup"))
    }
}

/// An accessibility button that never takes keyboard focus (a click-only custom view).
private final class PressOnlyView: NSView {
    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 20) }
    override func accessibilityPerformPress() -> Bool { true }
}
