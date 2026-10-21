import AppKit
import CoddPreferences
import CoddUI
import Testing
@testable import CoddSettingsUI

/// M5 D21: the Settings sidebar and all 13 sections, built from the sample in an offscreen window,
/// have no unlabeled interactive element (CoddUI's `AccessibilityAudit`); the elements outside the
/// key-view loop are printed for the report, not failed. Plus the M5 關於 row that reopens the
/// onboarding.
@MainActor
@Suite struct AccessibilityAuditTests {
    /// The harness's page as the Settings window's content (never ordered in).
    private func window(for harness: Harness) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = harness.root
        harness.root.layoutSubtreeIfNeeded()
        return window
    }

    private func check(_ report: AccessibilityAudit.Report, sourceLocation: SourceLocation = #_sourceLocation) {
        print("A11Y \(report.screen): interactive \(report.interactive), unlabeled \(report.unlabeled.count), outsideKeyLoop \(report.outsideKeyLoop.count)")
        for finding in report.outsideKeyLoop {
            print("A11Y   \(report.screen) outside key loop: \(finding.role) \(finding.path) \(finding.label ?? "")")
        }
        #expect(report.interactive > 0, "\(report.screen): nothing interactive found", sourceLocation: sourceLocation)
        #expect(report.unlabeled.isEmpty, "\(report.screen): \(report.unlabeled.map { "\($0.role) \($0.path)" })", sourceLocation: sourceLocation)
    }

    /// Every section shown in the window (sidebar included), with the key-loop check.
    @Test(arguments: SettingsSection.allCases)
    func section(_ section: SettingsSection) {
        let harness = Harness()
        let window = window(for: harness)
        defer {
            window.contentView = nil
            window.close()
        }
        _ = harness.section(section)
        check(AccessibilityAudit.audit(window: window, screen: "SETTINGS \(section.number) \(section.navEnglish)"))
    }

    @Test func sidebarAlone() {
        let harness = Harness()
        check(AccessibilityAudit.audit(view: harness.root.sidebarView, screen: "SETTINGS sidebar"))
    }

    /// M5 §2.4: 13 關於 › 首次啟動設定 with its hint and `[重新執行]`, which calls `openOnboarding`.
    @Test func aboutRowReopensOnboarding() throws {
        let harness = Harness()
        let about = harness.section(.about, as: AboutSectionView.self)
        let row = try #require(about.rowsByKey["about.onboarding"])
        #expect(row.title == "首次啟動設定")
        #expect(row.hintText == "重新看一次環境偵測、匯入專案、hooks、筆記本、帳號與通知；不會自動改動任何檔案。")
        #expect(row.milestone == nil && row.alphaValue == 1, "a live row, not a later milestone's")
        let button = try #require(about.control("about.onboarding", as: CoddButton.self))
        #expect(button.label == "重新執行")
        #expect(button.accessibilityLabel() == "重新執行首次啟動設定")
        button.performClick(nil)
        #expect(harness.log.calls == ["openOnboarding"])
        #expect(about.rowTitles.contains("首次啟動設定"))
        // The search finds it.
        #expect(about.applySearch("首次啟動"))
        #expect(about.firstSearchHit === row)
        // Callers from before M5 get the no-op default.
        SettingsActions().openOnboarding()
    }

    /// 關於 › 第三方元件授權 `[開啟]` calls `openThirdPartyNotices`; the unofficial-tool line sits under
    /// its card and is found by the search.
    @Test func aboutRowOpensTheThirdPartyNotices() throws {
        let harness = Harness()
        let about = harness.section(.about, as: AboutSectionView.self)
        let row = try #require(about.rowsByKey["about.notices"])
        #expect(row.title == "第三方元件授權")
        #expect(row.milestone == nil && row.alphaValue == 1, "a live row")
        let button = try #require(about.control("about.notices", as: CoddButton.self))
        #expect(button.label == "開啟")
        #expect(button.accessibilityLabel() == "開啟第三方元件授權")
        button.performClick(nil)
        #expect(harness.log.calls == ["openThirdPartyNotices"])
        #expect(about.applySearch("license"))
        #expect(about.firstSearchHit === row)
        #expect(about.disclaimerLabel?.text == "CODD 是個人開發的非官方工具，與 Anthropic 無關；Claude 與 Claude Code 是 Anthropic 的商標。")
        #expect(about.disclaimerLabel?.isDescendant(of: about) == true)
        #expect(about.applySearch("商標"))
        // Callers that predate the row get the no-op default.
        SettingsActions().openThirdPartyNotices()
    }

    /// D21 keyboard: the nav is a list (↑ ↓ select and keep the focus), segmented controls step
    /// with the arrows and expose one radio button per segment.
    @Test func navAndSegmentedKeys() throws {
        let harness = Harness()
        let window = window(for: harness)
        defer {
            KeyboardFocus.fullKeyboardAccessOverride = nil
            window.contentView = nil
            window.close()
        }
        KeyboardFocus.fullKeyboardAccessOverride = true
        harness.root.select(.general)
        let sidebar = harness.root.sidebarView
        let general = try #require(sidebar.items[.general])
        #expect(KeyboardFocus.focusAsKeyboardNavigation(general))
        general.keyDown(with: Self.key(125, "\u{F701}"))
        #expect(window.firstResponder === sidebar.items[.appearance])
        #expect(sidebar.items[.appearance]?.isAccessibilitySelected() == true)

        let about = harness.section(.about, as: AboutSectionView.self)
        let channel = try #require(about.control("about.updateChannel", as: SxSegmented.self))
        let segments = channel.accessibilityChildren() ?? []
        #expect(segments.count == 2)
        #expect((segments.first as? NSAccessibilityElement)?.accessibilityLabel() == "Stable")
        let appearance = harness.section(.appearance)
        let crt = try #require(appearance.control("appearance.crt", as: SxSegmented.self))
        let before = crt.selectedIndex
        #expect(KeyboardFocus.focusAsKeyboardNavigation(crt))
        crt.keyDown(with: Self.key(124, "\u{F703}"))
        #expect(crt.selectedIndex != before || !crt.isSegmentEnabled(before + 1), "→ picks the next segment")
        KeyboardFocus.fullKeyboardAccessOverride = false
        #expect(!crt.acceptsFirstResponder, "no key view without Full Keyboard Access")
    }

    private static func key(_ code: UInt16, _ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
}
