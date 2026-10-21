import AppKit
import Foundation
import Observation
import Testing
@testable import CODD
import CoddUI

/// A view-less subscriber: no window, so the ticker must not start any timer for it.
@MainActor
final class WindowlessSubscriber: SecondTicking {
    var window: NSWindow? { nil }
    var ticks = 0
    func secondTick(now: Date) { ticks += 1 }
}

/// Records how often the host tells the engine it is occluded.
@MainActor
final class CountingSurface: TerminalSurface {
    let view = NSView()
    var gridSize = TerminalGridSize(columns: 80, rows: 24)
    var onGridSizeChange: ((TerminalGridSize) -> Void)?
    var fontSize: CGFloat = 13
    var occludedCalls: [Bool] = []
    func attach(_ target: TerminalTarget) {}
    func setOccluded(_ occluded: Bool) { occludedCalls.append(occluded) }
    func send(_ input: TerminalInput) {}
}

@MainActor
@Suite("Runtime")
struct RuntimeTests {
    @Test func terminalHostSwapsSurfaceAndPlaceholderAndReportsOcclusionOnce() {
        let surface = CountingSurface()
        let host = TerminalHostView(surface: surface)
        host.showPlaceholder(nil)
        #expect(surface.occludedCalls.isEmpty)
        host.showPlaceholder("// 沒有選取 session")
        host.showPlaceholder("// NOTES · 尚未實作")
        #expect(surface.view.isHidden)
        #expect(surface.occludedCalls == [true])
        host.showPlaceholder(nil)
        host.showPlaceholder(nil)
        #expect(!surface.view.isHidden)
        #expect(surface.occludedCalls == [true, false])
    }

    @Test func tickerRunsNoTimerWithoutVisibleSubscribers() {
        let ticker = UITicker()
        let subscriber = WindowlessSubscriber()
        ticker.addSecond(subscriber)
        #expect(!ticker.isSecondTimerRunning)
        ticker.removeSecond(subscriber)
        #expect(!ticker.isSecondTimerRunning)
    }

    @Test func observationLoopCoalescesBurstsIntoOneRerun() async throws {
        let store = MockSessionStore(shiftClock: false)
        let session = try #require(store.session("s1"))
        var runs = 0
        let loop = ObservationLoop { _ = session.title; _ = session.state; runs += 1 }
        #expect(runs == 1)
        session.title = "a"
        session.title = "b"
        session.state = .idle
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs == 2)
        loop.cancel()
        session.title = "c"
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs == 2)
    }

    @Test func observationLoopIgnoresUnreadProperties() async throws {
        let store = MockSessionStore(shiftClock: false)
        let session = try #require(store.session("s1"))
        var runs = 0
        let loop = ObservationLoop { _ = session.state; runs += 1 }
        session.costUSD = 9.99
        session.contextPercent = 1
        try await Task.sleep(for: .milliseconds(50))
        #expect(runs == 1)
        loop.cancel()
    }

    @Test func fakeSurfaceShowsMockContentAndRecordsInput() {
        let surface = FakeTerminalSurface { target in target.sessionID == "s1" ? "<a>hello</a>" : "" }
        surface.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        surface.attach(TerminalTarget(sessionID: "s1", tab: .claude))
        #expect(surface.view.accessibilityValue() as? String == "hello")
        #expect(surface.gridSize.columns > 50 && surface.gridSize.rows > 10)
        surface.send(.key("1"))
        #expect(surface.sentInputs == [.key("1")])
    }

    @Test func mockTranscriptsAvoidForbiddenGlyphs() {
        // SPEC §1/§6: never U+23FA or emoji-presentation characters in mock terminal content.
        let forbidden: [Character] = ["\u{23FA}", "\u{26A0}", "\u{26A1}", "\u{2699}", "\u{23F3}", "\u{25B6}", "\u{2714}",
                                      "\u{2716}", "\u{274C}", "\u{2705}"]
        for id in (1...14).map({ "s\($0)" }) {
            let text = MockTranscripts.primary(for: id)
            #expect(!text.contains { forbidden.contains($0) }, "\(id)")
            #expect(!text.unicodeScalars.contains { $0.value >= 0x1F000 }, "\(id)")
        }
    }

    @Test func statusIconImageRenders() {
        for state in [StatusIconState.normal, .attention, .noHook] {
            let image = BrandMark.statusImage(state)
            #expect(image.size == NSSize(width: 18, height: 18))
            #expect(image.isTemplate == false)
        }
    }
}
