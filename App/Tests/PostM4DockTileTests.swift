import AppKit
import CoddPreferences
import Foundation
import Testing
@testable import CODD

/// Post-M4 live Dock tile: the state machine and the controller with an injected clock and
/// scheduler (nothing here touches `NSApp.dockTile`), plus the art's geometry.

/// One-shot delays run by hand.
@MainActor
private final class ManualScheduler: DockTileScheduling {
    final class Item: DockTileScheduled {
        let delay: Double
        let action: @MainActor @Sendable () -> Void
        var cancelled = false
        init(delay: Double, action: @escaping @MainActor @Sendable () -> Void) {
            self.delay = delay
            self.action = action
        }
        func cancel() { cancelled = true }
    }

    private(set) var items: [Item] = []
    var pending: [Item] { items.filter { !$0.cancelled } }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> any DockTileScheduled {
        let item = Item(delay: seconds, action: action)
        items.append(item)
        return item
    }

    /// Runs the oldest pending item; its delay (nil: nothing pending).
    @discardableResult
    func runNext() -> Double? {
        guard let item = pending.first else { return nil }
        item.cancelled = true
        item.action()
        return item.delay
    }
}

/// The controller's inputs and what it showed.
@MainActor
private final class TileHarness {
    var attention = 0
    var pausedUntil: Date?
    var dockShown = true
    var reduceMotion = false
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var frames: [DockTileFrame] = []
    let scheduler = ManualScheduler()
    private(set) var controller: DockTileController!

    init() {
        controller = DockTileController(attention: { [unowned self] in attention }, pausedUntil: { [unowned self] in pausedUntil },
                                        dockShown: { [unowned self] in dockShown }, reduceMotion: { [unowned self] in reduceMotion },
                                        now: { [unowned self] in now }, scheduler: scheduler,
                                        show: { [unowned self] in frames.append($0) })
    }

    func set(attention: Int) {
        self.attention = attention
        controller.refresh()
    }

    /// Runs every pending blink step; how many ran.
    @discardableResult
    func finishBlink() -> Int {
        var steps = 0
        while let delay = scheduler.pending.first?.delay, delay == DockTileMachine.stepSeconds {
            scheduler.runNext()
            steps += 1
        }
        return steps
    }
}

private let blink: [DockTileFrame] = [.dim, .lit, .dim, .lit, .dim, .lit]

@MainActor
@Suite("Live Dock tile (post-M4)")
struct PostM4DockTileTests {
    @Test func machineBlinksThreeTimesThenStaysLit() {
        var machine = DockTileMachine()
        let input = DockTileMachine.Input(attention: 1, paused: false, dockShown: true)
        // (`#expect` cannot call mutating members: results go through locals.)
        let started = machine.update(input, reduceMotion: false)
        #expect(started, "entering attention starts a blink")
        var frames = [machine.frame]
        while machine.step(reduceMotion: false) { frames.append(machine.frame) }
        frames.append(machine.frame)
        #expect(frames == blink, "dim / lit three times, then lit")
        #expect(!machine.isBlinking)
        let more = machine.step(reduceMotion: false)
        #expect(!more, "no steps once lit")
        let again = machine.update(input, reduceMotion: false)
        #expect(!again, "the same count does not blink again")
        #expect(machine.frame == .lit)
        _ = machine.update(DockTileMachine.Input(attention: 0, paused: false, dockShown: true), reduceMotion: false)
        #expect(machine.frame == .normal)
    }

    @Test func normalBlinkLitNormal() {
        let tile = TileHarness()
        #expect(tile.frames.isEmpty, "a still tile from the start: nothing drawn")
        #expect(tile.scheduler.pending.isEmpty, "no timer while nothing needs the user")
        tile.set(attention: 1)
        #expect(tile.frames == [.dim])
        #expect(tile.scheduler.pending.map(\.delay) == [DockTileMachine.stepSeconds])
        #expect(tile.finishBlink() == DockTileMachine.blinkSteps)
        #expect(tile.frames == blink)
        #expect(tile.scheduler.pending.isEmpty, "no timer once lit")
        tile.set(attention: 1)
        #expect(tile.frames == blink, "an unchanged count draws nothing")
        tile.set(attention: 0)
        #expect(tile.frames == blink + [.normal], "back to the bundle icon")
        #expect(tile.scheduler.pending.isEmpty)
    }

    @Test func growthBlinksAgain() {
        let tile = TileHarness()
        tile.set(attention: 1)
        tile.finishBlink()
        tile.set(attention: 2)
        #expect(tile.frames == blink + [.dim], "one more session needs the user: blink again")
        tile.finishBlink()
        #expect(tile.frames == blink + blink)
        // Fewer: stays lit; back up to two: a new session needs the user again.
        tile.set(attention: 1)
        #expect(tile.frames == blink + blink)
        tile.set(attention: 2)
        #expect(tile.frames.last == .dim)
        // Growth in the middle of a blink restarts it (the pending step is replaced).
        tile.scheduler.runNext() // lit
        tile.scheduler.runNext() // dim
        tile.set(attention: 3)
        #expect(tile.scheduler.pending.count == 1, "one step pending, the old one cancelled")
        #expect(tile.finishBlink() == DockTileMachine.blinkSteps, "a full blink from the restart")
        #expect(tile.frames.last == .lit)
        // A decrease in the middle of a blink lets it finish.
        tile.set(attention: 4)
        tile.set(attention: 2)
        #expect(tile.finishBlink() == DockTileMachine.blinkSteps)
        #expect(tile.frames.last == .lit)
    }

    @Test func attentionEndingMidBlinkStopsTheTimer() {
        let tile = TileHarness()
        tile.set(attention: 1)
        tile.scheduler.runNext()
        tile.set(attention: 0)
        #expect(tile.frames == [.dim, .lit, .normal])
        #expect(tile.scheduler.pending.isEmpty)
    }

    @Test func pausedShowsNoBlinkAndNoLitTile() {
        let tile = TileHarness()
        tile.pausedUntil = tile.now.addingTimeInterval(3600)
        tile.set(attention: 2)
        #expect(tile.frames.isEmpty, "paused: the bundle icon, no blink, no lit tile")
        // One wake-up at the end of the pause, nothing else.
        #expect(tile.scheduler.pending.map(\.delay) == [3600.5])
        tile.set(attention: 3)
        #expect(tile.scheduler.pending.count == 1, "the same pause end is not scheduled twice")
        // The pause ends: the tile enters attention.
        tile.now = tile.now.addingTimeInterval(3601)
        tile.scheduler.runNext()
        #expect(tile.frames == [.dim])
        tile.finishBlink()
        #expect(tile.frames == blink)
        // Pausing while lit: back to the bundle icon.
        tile.pausedUntil = tile.now.addingTimeInterval(600)
        tile.controller.refresh()
        #expect(tile.frames == blink + [.normal])
        // Resuming by hand (`恢復通知`): the wake-up is dropped.
        tile.pausedUntil = nil
        tile.controller.refresh()
        #expect(tile.frames == blink + [.normal, .dim])
        #expect(tile.scheduler.pending.map(\.delay) == [DockTileMachine.stepSeconds])
    }

    @Test func reduceMotionGoesStraightToLit() {
        let tile = TileHarness()
        tile.reduceMotion = true
        tile.set(attention: 1)
        #expect(tile.frames == [.lit])
        #expect(tile.scheduler.pending.isEmpty, "no blink, no timer")
        tile.set(attention: 2)
        #expect(tile.frames == [.lit], "growth: still lit, no blink")
        // Turned on in the middle of a blink: the next step ends it lit.
        let other = TileHarness()
        other.set(attention: 1)
        other.reduceMotion = true
        other.scheduler.runNext()
        #expect(other.frames == [.dim, .lit])
        #expect(other.scheduler.pending.isEmpty)
    }

    @Test func hiddenDockDoesNothing() {
        let tile = TileHarness()
        tile.dockShown = false
        tile.set(attention: 3)
        #expect(tile.frames.isEmpty, "no Dock icon (顯示於 Dock off, or a background launch): nothing drawn")
        #expect(tile.scheduler.pending.isEmpty)
        tile.pausedUntil = tile.now.addingTimeInterval(60)
        tile.controller.refresh()
        #expect(tile.scheduler.pending.isEmpty, "no pause wake-up either")
        // Hidden while lit: back to normal; shown again with sessions waiting: blink.
        tile.pausedUntil = nil
        tile.dockShown = true
        tile.controller.refresh()
        tile.finishBlink()
        #expect(tile.frames == blink)
        tile.dockShown = false
        tile.controller.refresh()
        #expect(tile.frames == blink + [.normal])
    }

    @Test func followsTheSessionsAndThePause() async {
        let store = MockSessionStore()
        let preferences = PreferencesService.inMemory()
        let scheduler = ManualScheduler()
        var frames: [DockTileFrame] = []
        let controller = DockTileController(attention: { store.allSessions.filter { $0.state.needsAttention }.count },
                                            pausedUntil: { preferences.preferences.notifications.pausedUntil },
                                            dockShown: { true }, reduceMotion: { false }, scheduler: scheduler,
                                            show: { frames.append($0) })
        let waiting = store.allSessions.filter { $0.state.needsAttention }
        #expect(!waiting.isEmpty, "the mock has sessions waiting")
        #expect(frames == [.dim])
        for session in waiting { session.state = .busy }
        await eventually("normal once nobody waits") { frames.last == .normal }
        waiting.first?.state = .waiting
        await eventually("a blink when one waits again") { frames.last == .dim }
        preferences.update { $0.notifications.pausedUntil = Date().addingTimeInterval(3600) }
        await eventually("normal while paused") { frames.last == .normal }
        controller.cancel()
    }

    @Test func artFramesAreSmallBitmapsOnTheIconGrid() throws {
        for frame in DockTileFrame.allCases {
            let image = try #require(DockTileArt.cgImage(frame))
            #expect(image.width == 512 && image.height == 512)
            #expect(image.bitsPerComponent == 8, "8-bit, no deep-color copy")
        }
        let lit = try #require(DockTileArt.cgImage(.lit)), dim = try #require(DockTileArt.cgImage(.dim))
        let normal = try #require(DockTileArt.cgImage(.normal))
        // The accent cell's center (art 608, 608 → canvas 100 + 608 · 824 / 1024 = 589 → 294.6 px).
        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: 4)
            buffer.withUnsafeMutableBytes { raw in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let ctx = CGContext(data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return }
                // The image placed so that its pixel (x, y), counted from the top left, covers the 1 × 1 context.
                ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
            }
            return buffer
        }
        let center = 295
        #expect(pixel(normal, center, center)[0] > 240, "the amber cell as the bundle icon shows it")
        #expect(pixel(lit, center, center)[0] == 255, "lit: full amber")
        #expect(pixel(dim, center, center)[0] < 100, "dim: the amber cell dimmed")
        // Outside the 824 shape (corner of the canvas): transparent; inside near the edge: opaque.
        #expect(pixel(normal, 2, 2)[3] == 0)
        #expect(pixel(normal, 256, 60)[3] == 255)
        // The glow lights the background next to the accent cell, only when lit.
        let beside = 340 // right of the cell (cell ends at 320 px), before the bracket
        #expect(pixel(lit, beside, center)[0] > pixel(normal, beside, center)[0] + 20)
    }
}

@MainActor
private func eventually(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    #expect(condition(), "timed out waiting for \(what)")
}
