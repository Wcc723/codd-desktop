import AppKit
import CoddUI
import Foundation
import Observation
import Testing
@testable import CODD

/// FB (2026-11): the sidebar footer's USAGE toggle reads as a control (a tinted box, hover and
/// press states, `收合 ⌃` at the right end while open) and stays in view however many accounts
/// the list shows; the host line `cpu 23% · mem 21/36G · bat 86%` became three meters colored by
/// load (`HostLoad`; memory by macOS's memory pressure, as STATUS), in the sidebar footer and the
/// menu bar footer alike.
@MainActor
@Suite("Sidebar footer toggle and host meters (FB)")
struct FBFooterTests {
    @Test func loadTonesFollowTheThresholds() {
        #expect([0, 59, 60, 84, 85, 100].map { HostLoad.cpu(percent: $0) } == [.ok, .ok, .warn, .warn, .crit, .crit])
        // Memory: the pressure STATUS's MEM card shows, not the used share.
        #expect([.normal, .warning, .critical].map { HostLoad.memory(pressure: $0) } == [.ok, .warn, .crit])
        #expect([100, 41, 40, 21, 20, 0].map { HostLoad.battery(percent: $0, onAC: false) } == [.ok, .ok, .warn, .warn, .crit, .crit])
        // On AC power the battery is charging or full: never a warning (STATUS's BAT card).
        #expect([10, 30, 100].map { HostLoad.battery(percent: $0, onAC: true) } == [.ok, .ok, .ok])
    }

    @Test func metersFollowTheSample() {
        var sample = MockData.hostSample()
        let mock = HostMeters(sample: sample)
        #expect(mock.line == "cpu 23% · mem 21/36G · bat 86%")
        #expect(mock.meters.map(\.label) == ["CPU", "MEM", "BAT"], "BAT on AC power too; the words say so")
        #expect(mock.meters.map(\.valueText) == ["23%", "59%", "86%"])
        #expect(mock.meters.map(\.tone) == [.ok, .ok, .ok])
        #expect(mock.spoken == "主機 CPU 23%，記憶體 21/36G（59%），電池 86%，接上電源")
        // CPU only from the second sample; no battery meter without a battery.
        sample.cpu = nil
        #expect(HostMeters(sample: sample).meters.map(\.label) == ["MEM", "BAT"])
        sample.battery = nil
        #expect(HostMeters(sample: sample).meters.map(\.label) == ["MEM"])
        #expect(HostMeters(sample: sample).line == "mem 21/36G")
        // Loads: the words say the color. 85 % used at normal pressure is fine (as STATUS says).
        let full = HostMeters(sample: MockData.hostSample(cpu: 23, memoryFraction: 0.85))
        #expect(full.meters[1].percent == 85 && full.meters[1].tone == .ok && full.meters[1].loadWord == nil)
        let busy = HostMeters(sample: MockData.hostSample(cpu: 91, memoryFraction: 0.7, pressure: .warning))
        #expect(busy.meters.map(\.tone) == [.crit, .warn, .ok])
        #expect(busy.spoken.hasPrefix("主機 CPU 91%，過高，記憶體 25/36G（70%），壓力偏高，電池 86%"))
        #expect(HostMeters(sample: MockData.hostSample(memoryFraction: 0.5, pressure: .critical)).meters[1].loadWord == "壓力過高")
        var low = MockData.hostSample()
        low.battery = .init(percent: 15, charging: false, onAC: false)
        let unplugged = HostMeters(sample: low).meters.last
        #expect(unplugged?.label == "BAT" && unplugged?.tone == .crit && unplugged?.loadWord == "過低")
        low.battery = .init(percent: 15, charging: true, onAC: true)
        #expect(HostMeters(sample: low).spoken.hasSuffix("電池 15%，充電中"))
    }

    @Test func metersFitTheSidebarFromItsMinimumWidth() {
        let meters = HostMeters(sample: MockData.hostSample())
        let columns = HostMetersView.columns(meters.meters)
        func mode(_ width: CGFloat) -> HostMetersView.Layout.Mode {
            HostMetersView.layout(width: width, count: 3, labelWidth: columns.label, valueWidth: columns.value).mode
        }
        // The footer's insets are 12 on each side.
        #expect(mode(Metrics.sidebarMinWidth - 24) == .bars)
        #expect(mode(Metrics.sidebarWidth - 24) == .bars)
        // Just room for three `CPU 100%` cells 8 apart: labels and values, no bars.
        let valuesOnly = (columns.label + UIZoom.pt(4) + columns.value) * 3 + UIZoom.pt(8) * 2
        #expect(mode(valuesOnly) == .values && mode(valuesOnly - 1) == .numbers)
        #expect(mode(60) == .numbers)
        // A meter at 100 % (a CPU spike) changes nothing: the value column always holds `100%`.
        var spike = MockData.hostSample(cpu: 100, memoryFraction: 1)
        spike.battery = .init(percent: 100, charging: true, onAC: true)
        let peak = HostMeters(sample: spike)
        #expect(peak.meters.map(\.valueText) == ["100%", "100%", "100%"])
        #expect(HostMetersView.columns(peak.meters) == columns)
        for width in [Metrics.sidebarMinWidth - 24, Metrics.sidebarWidth - 24] {
            let layout = HostMetersView.layout(width: width, count: 3, labelWidth: columns.label, valueWidth: columns.value)
            #expect(layout.mode == .bars && layout.barWidth >= UIZoom.pt(HostMetersView.minBar), "\(width): \(layout)")
        }
        // Nothing overlaps: what a mode draws fits the width; wider rows never get shorter bars.
        var lastBar: CGFloat = 0
        for width in stride(from: CGFloat(40), through: 420, by: 2) {
            let layout = HostMetersView.layout(width: width, count: 3, labelWidth: columns.label, valueWidth: columns.value)
            let gap = layout.innerGap
            let cell: CGFloat = switch layout.mode {
            case .bars: columns.label + gap + layout.barWidth + gap + columns.value
            case .values: columns.label + gap + columns.value
            case .numbers: columns.value
            }
            if layout.mode != .numbers { #expect(cell * 3 + layout.cellGap * 2 <= width, "width \(width)") }
            if layout.mode == .bars { #expect(layout.barWidth >= UIZoom.pt(HostMetersView.minBar)) }
            #expect(layout.barWidth >= lastBar || layout.barWidth >= UIZoom.pt(HostMetersView.comfortableBar), "width \(width)")
            lastBar = layout.barWidth
        }
        // The largest UI 字級 keeps the bars at the minimum width too (everything scales).
        UIZoom.withScale(UIZoom.scale(forFontSize: 20)) {
            let zoomed = HostMetersView.columns(peak.meters)
            let layout = HostMetersView.layout(width: Metrics.sidebarMinWidth - UIZoom.pt(24), count: 3, labelWidth: zoomed.label,
                                               valueWidth: zoomed.value)
            #expect(layout.mode == .bars)
        }
    }

    @Test func theFooterAndTheMenuBarShowTheMeters() throws {
        let store = MockSessionStore(shiftClock: false)
        let footer = SidebarFooterView(store: store, accounts: MockAccountStore(), shell: ShellState())
        let view = try #require(footer.descendant(ofType: HostMetersView.self))
        #expect(view.meters == MockData.host.meters)
        #expect(view.accessibilityLabel() == "主機 CPU 23%，記憶體 21/36G（59%），電池 86%，接上電源")
        #expect(view.toolTip == view.accessibilityLabel())
        let content = MenuBarPanelContent.build(store: store, accounts: MockAccountStore())
        #expect(content.hostMeters == MockData.host.meters && content.hostLine == "cpu 23% · mem 21/36G · bat 86%")
        // Before the first sample (real mode): the summary's text.
        store.host.meters = nil
        store.host.line = "CODD · ~/tmp/root"
        let early = SidebarFooterView(store: store, accounts: MockAccountStore(), shell: ShellState())
        let text = try #require(early.descendant(ofType: HostMetersView.self))
        #expect(text.meters == nil && text.accessibilityLabel() == "CODD · ~/tmp/root" && text.currentLayout == nil)
    }

    @Test func theToggleSaysHowToCloseAndPressesLikeAButton() async throws {
        let shell = ShellState()
        let footer = SidebarFooterView(store: MockSessionStore(shiftClock: false), accounts: MockAccountStore(), shell: shell)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = footer
        window.layoutIfNeeded()
        let toggle = try #require(footer.descendant(ofType: FooterToggleView.self))
        #expect(toggle.trailingText == "全部帳號 3")
        #expect(toggle.accessibilityRole() == .disclosureTriangle && toggle.accessibilityLabel() == "展開全部帳號的用量")
        #expect(toggle.toolTip == "展開所有帳號的用量")

        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: toggle.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let inside = NSPoint(x: toggle.bounds.midX, y: toggle.bounds.midY)
        let outside = NSPoint(x: toggle.bounds.midX, y: toggle.bounds.maxY + 40)
        // Held: the press state, no action yet; released outside: nothing happens.
        toggle.mouseDown(with: event(.leftMouseDown, at: inside))
        #expect(toggle.pressed && !shell.footerExpanded)
        toggle.mouseDragged(with: event(.leftMouseDragged, at: outside))
        #expect(!toggle.pressed)
        toggle.mouseUp(with: event(.leftMouseUp, at: outside))
        #expect(!shell.footerExpanded)
        // Released inside: it opens.
        toggle.mouseDown(with: event(.leftMouseDown, at: inside))
        toggle.mouseUp(with: event(.leftMouseUp, at: inside))
        #expect(shell.footerExpanded && !toggle.pressed)
        await m3Eventually("the footer follows") { toggle.trailingText == FooterToggleView.collapseText }
        #expect(toggle.accessibilityLabel() == "收合全部帳號的用量" && toggle.isAccessibilityExpanded())
        #expect(toggle.accessibilityHelp() == "目前帳號 #3 工作，共 3 個帳號")
        // VoiceOver and Full Keyboard Access press it closed again.
        #expect(toggle.accessibilityPerformPress())
        #expect(!shell.footerExpanded)
    }

    @Test func theToggleStaysInViewWithManyAccountsInAShortWindow() async throws {
        let shell = ShellState()
        let controller = SidebarViewController(env: SidebarEnvironment(store: MockSessionStore(shiftClock: false),
                                                                       accounts: ManyAccountsStore(count: 12), shell: shell))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 560), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 280, height: 560))
        shell.footerExpanded = true
        await m3Eventually("the list opens") { !controller.footer.accountListScrollView.isHidden }
        window.layoutIfNeeded()
        let content = try #require(window.contentView)
        // The window keeps its size (it used to grow past the screen with the footer).
        #expect(content.bounds.height == 560)
        let toggle = try #require(controller.footer.descendant(ofType: FooterToggleView.self))
        let meters = try #require(controller.footer.descendant(ofType: HostMetersView.self))
        for view in [toggle, meters] as [NSView] {
            let frame = view.convert(view.bounds, to: nil)
            #expect(content.bounds.contains(frame), "\(type(of: view)) at \(frame)")
        }
        // The rows scroll inside the footer; three session rows stay above it.
        let list = controller.footer.accountListScrollView
        let rows = try #require(list.documentView)
        #expect(list.frame.height > 0 && list.frame.height < rows.frame.height)
        let sessions = try #require(controller.outline.enclosingScrollView)
        #expect(sessions.frame.height >= Metrics.sessionRowHeight * 3 - 0.5, "\(sessions.frame.height)")
    }

    @Test func aShortListDoesNotScroll() async throws {
        let shell = ShellState()
        let controller = SidebarViewController(env: SidebarEnvironment(store: MockSessionStore(shiftClock: false),
                                                                       accounts: MockAccountStore(), shell: shell))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 900), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 280, height: 900))
        shell.footerExpanded = true
        await m3Eventually("the list opens") { !controller.footer.accountListScrollView.isHidden }
        window.layoutIfNeeded()
        let list = controller.footer.accountListScrollView
        let rows = try #require(list.documentView)
        #expect(rows.subviews.count == 3)
        #expect(abs(list.frame.height - rows.frame.height) < 0.5, "\(list.frame.height) vs \(rows.frame.height)")
    }
}

/// An account store with `count` MAX accounts (the footer with a long list).
@MainActor @Observable
final class ManyAccountsStore: AccountStore {
    private(set) var accounts: [AccountVM]
    private(set) var activeAccountID: AccountID? = "1"
    var autoSwitch = AutoSwitchConfig()
    var followingSessionCount = 4
    var switchState: AccountSwitchState = .idle
    var availability: AccountAvailability { .ready }
    var isPlaceholder: Bool { false }
    var sourceLabel: String? { "cswap 0.26.0" }

    init(count: Int) {
        let now = MockData.referenceDate
        accounts = (1...count).map { n in
            AccountVM(id: "\(n)", slot: "#\(n)", alias: "acct\(n)", plan: "MAX",
                      fiveHour: QuotaWindow(remainingPercent: 80, resetsAt: now.addingTimeInterval(3600)),
                      week: QuotaWindow(remainingPercent: 60, resetsAt: now.addingTimeInterval(Double(n) * 86_400)),
                      source: "cswap cache", sourceAt: now, sessionCount: 0)
        }
    }

    func account(_ id: AccountID) -> AccountVM? { accounts.first { $0.id == id } }
    func pinnedCount(for id: AccountID) -> Int { 0 }
    var newSessionAccountOptions: [NewSessionAccountOption] { AccountPinOptions.build(accounts: accounts, activeID: activeAccountID) }
    func switchTo(_ id: AccountID, reason: AccountSwitchReason) async -> AccountSwitchOutcome { .alreadyActive }
    func refresh(userInitiated: Bool) async {}
}
