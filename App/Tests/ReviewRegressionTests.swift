import AppKit
import Foundation
import Testing
@testable import CODD
import CoddUI

/// Target for banner actions.
private final class BannerTarget: NSObject {
    @objc func a() {}
    @objc func b() {}
}

/// A view that ticks once per second.
private final class TickingView: NSView, SecondTicking {
    func secondTick(now: Date) {}
}

/// No-op main-menu commands.
private final class NoopCommands: NSObject, CoddCommands {
    func showSettings(_ sender: Any?) {}
    func showQuickSwitch(_ sender: Any?) {}
    func toggleSessionSidebar(_ sender: Any?) {}
    func selectSessionByNumber(_ sender: NSMenuItem) {}
    func selectNextSession(_ sender: Any?) {}
    func selectPreviousSession(_ sender: Any?) {}
    func allowCurrentSession(_ sender: Any?) {}
    func newShellTab(_ sender: Any?) {}
    func toggleBottomTerminal(_ sender: Any?) {}
    func showMainWindow(_ sender: Any?) {}
    func focusSidebarFilter(_ sender: Any?) {}
    func newSession(_ sender: Any?) {}
    func quitApp(_ sender: Any?) {}
    func togglePinCurrentSession(_ sender: Any?) {}
    func stopCurrentSession(_ sender: Any?) {}
    func toggleComposer(_ sender: Any?) {}
}

/// Regression tests for defects found in review (timers, rebuilt buttons, panel churn, menu).
@MainActor
@Suite("Review regressions")
struct ReviewRegressionTests {
    /// An offscreen window the injected ticker treats as visible.
    private func windowWithView() -> (NSWindow, NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        return (window, container)
    }

    @Test func waitingLampPulsesWithACommittedAnimationNotATimer() {
        let ticker = UITicker(windowIsVisible: { _ in true }, reduceMotion: { false })
        let (window, container) = windowWithView()
        let lamp = LampView(frame: NSRect(x: 0, y: 0, width: 12, height: 16))
        lamp.ticker = ticker
        lamp.configure(StateStyle.of(.waiting))
        #expect(!lamp.isPulsing) // not in a window yet
        container.addSubview(lamp)
        #expect(lamp.isPulsing)
        #expect(ticker.pulseSubscriberCount == 1)
        #expect(!ticker.isSecondTimerRunning) // no app timer drives the pulse

        lamp.configure(StateStyle.of(.busy))
        #expect(!lamp.isPulsing)
        #expect(ticker.pulseSubscriberCount == 0)
        lamp.configure(StateStyle.of(.waiting))
        #expect(lamp.isPulsing)
        lamp.removeFromSuperview() // e.g. a row recycled by the outline
        #expect(!lamp.isPulsing)
        #expect(ticker.pulseSubscriberCount == 0)
        _ = window
    }

    @Test func reduceMotionKeepsTheLampLit() {
        final class Preference { var reduce = true }
        let preference = Preference()
        let ticker = UITicker(windowIsVisible: { _ in true }, reduceMotion: { preference.reduce })
        let (window, container) = windowWithView()
        let lamp = LampView(frame: NSRect(x: 0, y: 0, width: 12, height: 16))
        lamp.ticker = ticker
        lamp.configure(StateStyle.of(.waiting))
        container.addSubview(lamp)
        #expect(!ticker.pulsesAllowed)
        #expect(!lamp.isPulsing)
        #expect(ticker.pulseSubscriberCount == 1) // still listening for the preference to change
        preference.reduce = false
        lamp.motionPreferenceChanged()
        #expect(lamp.isPulsing)
        _ = window
    }

    @Test func secondClockIgnoresHiddenViews() {
        let ticker = UITicker(windowIsVisible: { _ in true }, reduceMotion: { false })
        let (_, container) = windowWithView()
        let view = TickingView(frame: container.bounds)
        container.addSubview(view)
        view.isHidden = true
        ticker.addSecond(view)
        #expect(!ticker.isSecondTimerRunning)
        view.isHidden = false
        ticker.updateTimers()
        #expect(ticker.isSecondTimerRunning)
        ticker.removeSecond(view)
        #expect(!ticker.isSecondTimerRunning)
    }

    @Test func bannerKeepsItsButtonsAcrossTicks() {
        let target = BannerTarget()
        let banner = BannerView()
        let actions = [BannerAction(title: "↻ 重送上一則", action: #selector(BannerTarget.a)),
                       BannerAction(title: "⟲ 稍後自動重試", action: #selector(BannerTarget.b))]
        banner.show(.error, glyph: "▲", glyphColor: Palette.danger, message: "API 過載 · 1m 前", actions: actions, target: target)
        let first = banner.actionButtons
        #expect(first.count == 2)
        banner.show(.error, glyph: "▲", glyphColor: Palette.danger, message: "API 過載 · 2m 前", actions: actions, target: target)
        #expect(banner.actionButtons.count == 2)
        #expect(zip(first, banner.actionButtons).allSatisfy { $0 === $1 })
        banner.show(.info, glyph: "EXT", glyphColor: Palette.dim, message: "外部",
                    actions: [BannerAction(title: "接管到 CODD", action: #selector(BannerTarget.a), variant: .accent)], target: target)
        #expect(banner.actionButtons.count == 1)
        #expect(banner.actionButtons.first !== first.first)
    }

    @Test func answerBarKeepsItsKeysWhenNothingChanged() {
        let bar = AnswerBarView()
        bar.configure(reason: .permission, tool: "Bash", detail: "npm test -- auth.spec.ts", options: [])
        let keys = bar.keyButtons
        #expect(keys.map(\.label) == ["Yes", "Always", "No", "取消"])
        bar.configure(reason: .permission, tool: "Bash", detail: "npm test -- auth.spec.ts", options: [])
        #expect(zip(keys, bar.keyButtons).allSatisfy { $0 === $1 })
        bar.configure(reason: .question, tool: "AskUserQuestion", detail: "CSV？", options: ["UTF-8 BOM", "Big5"])
        #expect(bar.keyButtons.map(\.label) == ["UTF-8 BOM", "Big5", "取消"])
    }

    @Test func panelContentFollowsTheArtboard() {
        let store = MockSessionStore(shiftClock: false)
        let accounts = MockAccountStore()
        let content = MenuBarPanelContent.build(store: store, accounts: accounts)
        #expect(content.accountIDs == ["2", "3", "1"]) // R7
        #expect(content.needs.map(\.id) == ["s1", "s2", "s3"])
        #expect(content.needs.first?.model.isPermission == true)
        #expect(content.needs[1].model.detailLead == "問：")
        #expect(content.needs[2].model.detailLead == "API 529 ")
        #expect(content.ready.map(\.id) == ["s4"])
        #expect(content.runningCount == 9)
        #expect(content.running.map(\.id) == ["northlab", "northweb", "github"])
        #expect(content.running.flatMap(\.rows).map(\.id) == ["s7", "s8", "s9", "s10"])
        #expect(content.running.first?.rows.first?.model.accountChip == "#2")
        #expect(content.more == MenuBarPanelContent.More(hidden: 5, busy: 1, idle: 4)) // `+5 more · ● 1 · ○ 4 idle`
    }

    @Test func panelLayoutIsStableWhenOnlyRowContentChanges() {
        let store = MockSessionStore(shiftClock: false)
        let accounts = MockAccountStore()
        let before = MenuBarPanelContent.build(store: store, accounts: accounts)
        store.session("s9")?.tool = "Bash"
        store.session("s1")?.detail = "npm test"
        let after = MenuBarPanelContent.build(store: store, accounts: accounts)
        #expect(after != before)
        #expect(after.layout == before.layout)
        store.answer("s1", key: "1") // leaves NEEDS YOU
        #expect(MenuBarPanelContent.build(store: store, accounts: accounts).layout != before.layout)
    }

    @Test func panelUpdatesRowsInPlace() async throws {
        let store = MockSessionStore(shiftClock: false)
        let accounts = MockAccountStore()
        let actions = MenuBarPanelActions(openSession: { _ in }, allow: { _ in }, openMain: {}, openSettings: { _ in },
                                          newSession: {}, quickNote: {})
        let panel = MenuBarPanelView(store: store, accounts: accounts, actions: actions)
        panel.activate()
        let needs = try #require(panel.needsRowView("s1"))
        let running = try #require(panel.compactRowView("s9"))
        store.session("s9")?.tool = "Bash"
        store.session("s1")?.detail = "npm test"
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.needsRowView("s1") === needs)
        #expect(panel.compactRowView("s9") === running)
        #expect(running.model.prefix == "Bash")
        #expect(needs.model.detail == "npm test")
        store.answer("s2", key: "esc") // membership changes: rebuilt
        try await Task.sleep(for: .milliseconds(50))
        #expect(panel.needsRowView("s2") == nil)
        #expect(panel.needsRowView("s1") !== needs)
        panel.deactivate()
    }

    @Test func mainMenuHasCloseWindow() throws {
        let previousWindowsMenu = NSApp.windowsMenu
        defer { NSApp.windowsMenu = previousWindowsMenu }
        let menu = MainMenuBuilder.build(commands: NoopCommands())
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        let close = try #require(items.first { $0.action == #selector(NSWindow.performClose(_:)) })
        #expect(close.keyEquivalent == "w" && close.keyEquivalentModifierMask == [.command])
    }

    @Test func durationsNeverTrapOnBadIntervals() {
        #expect(DurationFormat.compact(.nan) == "0s")
        #expect(DurationFormat.compact(.infinity) == "0s")
        #expect(DurationFormat.compact(1e300).hasSuffix("h"))
        let now = Date()
        #expect(DurationFormat.countdown(to: Date.distantFuture, now: now).hasSuffix("後"))
    }
}
