import AppKit
import CoddPreferences
import CoddUI

/// The live Dock tile's state machine, apart from drawing and time (user decision 2026-10-18).
/// The tile stays still normally (the system-rendered bundle icon); when a session starts needing
/// the user (the menu bar's attention condition: waiting or error), the amber cell blinks slowly
/// 3 times (dim, lit, ...; one step each `stepSeconds`) and then stays lit until no session needs
/// the user. It blinks again whenever the number of sessions needing attention grows. Paused
/// notifications (D23) and a hidden Dock icon show the normal tile; reduced motion skips the blink.
struct DockTileMachine: Equatable, Sendable {
    struct Input: Equatable, Sendable {
        /// Sessions needing the user (waiting + error).
        var attention: Int
        /// `暫停通知` is on (D23).
        var paused: Bool
        /// CODD has a Dock icon (`.regular`: not hidden by 顯示於 Dock, not a background launch).
        var dockShown: Bool
    }

    /// Steps after the first frame: dim, lit, dim, lit, dim, then lit for good (3 blinks).
    static let blinkSteps = 5
    /// About 0.6 s dim, 0.6 s lit.
    static let stepSeconds = 0.6

    private(set) var frame: DockTileFrame = .normal
    /// Steps still to come (> 0 while blinking).
    private(set) var stepsLeft = 0
    /// The attention count the tile last reacted to (0 while the tile is normal).
    private(set) var count = 0

    var isBlinking: Bool { stepsLeft > 0 }

    /// Applies new inputs; true when a blink (re)started and its first step must be scheduled.
    mutating func update(_ input: Input, reduceMotion: Bool) -> Bool {
        guard input.dockShown, !input.paused, input.attention > 0 else {
            frame = .normal
            stepsLeft = 0
            count = 0
            return false
        }
        let grew = input.attention > count
        count = input.attention
        guard grew else { return false } // lit, or still blinking
        if reduceMotion {
            frame = .lit
            stepsLeft = 0
            return false
        }
        frame = .dim
        stepsLeft = Self.blinkSteps
        return true
    }

    /// One blink step; true when another follows. Reduced motion (turned on mid-blink) ends it lit.
    mutating func step(reduceMotion: Bool) -> Bool {
        guard stepsLeft > 0 else { return false }
        if reduceMotion {
            frame = .lit
            stepsLeft = 0
            return false
        }
        stepsLeft -= 1
        frame = stepsLeft == 0 || frame == .dim ? .lit : .dim
        return stepsLeft > 0
    }
}

/// A one-shot delay (tests run them by hand).
@MainActor
protocol DockTileScheduling: AnyObject {
    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> any DockTileScheduled
}

@MainActor
protocol DockTileScheduled: AnyObject {
    func cancel()
}

/// The live scheduler: one sleeping task per pending step (nothing runs outside a blink, except
/// the one wake-up at the end of a pause while sessions need attention).
@MainActor
final class DockTileTaskScheduler: DockTileScheduling {
    private final class Handle: DockTileScheduled {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }

    func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) -> any DockTileScheduled {
        Handle(Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(40))
            guard !Task.isCancelled else { return }
            action()
        })
    }
}

/// Drives the Dock tile from the sessions and Settings › 通知 (observation loop), the Dock policy
/// (`refresh()` after it changes) and reduced motion (read when a blink starts and at each step).
/// `show` is called only when the frame changes.
@MainActor
final class DockTileController {
    private struct Snapshot: Equatable {
        var attention: Int
        var pausedUntil: Date?
        var dockShown: Bool
    }

    private(set) var machine = DockTileMachine()
    /// What `show` was last given.
    private(set) var shown: DockTileFrame = .normal
    private var loop: ObservationLoop?
    private var pendingStep: (any DockTileScheduled)?
    private var pauseWake: (any DockTileScheduled)?
    private var pauseWakeAt: Date?
    private let reduceMotion: @MainActor () -> Bool
    private let now: @MainActor () -> Date
    private let scheduler: any DockTileScheduling
    private let show: @MainActor (DockTileFrame) -> Void

    /// - Parameters:
    ///   - attention: sessions needing the user, read inside observation tracking.
    ///   - pausedUntil: Settings › 通知's `pausedUntil` (D23), read inside observation tracking.
    ///   - dockShown: whether CODD has a Dock icon (not observable: call `refresh()` when it changes).
    init(attention: @escaping @MainActor () -> Int,
         pausedUntil: @escaping @MainActor () -> Date?,
         dockShown: @escaping @MainActor () -> Bool,
         reduceMotion: @escaping @MainActor () -> Bool,
         now: @escaping @MainActor () -> Date = Date.init,
         scheduler: any DockTileScheduling = DockTileTaskScheduler(),
         show: @escaping @MainActor (DockTileFrame) -> Void) {
        self.reduceMotion = reduceMotion
        self.now = now
        self.scheduler = scheduler
        self.show = show
        loop = ObservationLoop(track: {
            Snapshot(attention: attention(), pausedUntil: pausedUntil(), dockShown: dockShown())
        }, apply: { [weak self] snapshot in self?.apply(snapshot) })
    }

    /// The app's tile: the menu bar's attention condition, the D23 pause, the Dock policy
    /// (`NSApp.activationPolicy()`), reduced motion as the lamps see it (Settings › 外觀 ›
    /// 減少動態, else the system setting) and `NSApp.dockTile`.
    static func live(store: any SessionStore, preferences: PreferencesService) -> DockTileController {
        let renderer = DockTileRenderer(tile: NSApp.dockTile)
        return DockTileController(attention: { [weak store] in (store?.allSessions ?? []).filter { $0.state.needsAttention }.count },
                                  pausedUntil: { preferences.preferences.notifications.pausedUntil },
                                  dockShown: { NSApp.activationPolicy() == .regular },
                                  reduceMotion: { !UITicker.shared.pulsesAllowed },
                                  show: { renderer.show($0) })
    }

    /// Re-reads every input now (the Dock policy changed).
    func refresh() { loop?.refresh() }

    func cancel() {
        loop?.cancel()
        pendingStep?.cancel()
        pauseWake?.cancel()
    }

    private func apply(_ snapshot: Snapshot) {
        let current = now()
        let paused = snapshot.pausedUntil.map { $0 > current } ?? false
        let input = DockTileMachine.Input(attention: snapshot.attention, paused: paused, dockShown: snapshot.dockShown)
        if machine.update(input, reduceMotion: reduceMotion()) {
            scheduleStep()
        } else if !machine.isBlinking {
            pendingStep?.cancel()
            pendingStep = nil
        }
        // The pause ends by itself: look again then, but only while it hides an attention tile.
        if paused, snapshot.dockShown, snapshot.attention > 0, let until = snapshot.pausedUntil {
            schedulePauseWake(at: until, now: current)
        } else {
            pauseWake?.cancel()
            pauseWake = nil
            pauseWakeAt = nil
        }
        present()
    }

    private func scheduleStep() {
        pendingStep?.cancel()
        pendingStep = scheduler.schedule(after: DockTileMachine.stepSeconds) { [weak self] in self?.step() }
    }

    private func step() {
        pendingStep = nil
        if machine.step(reduceMotion: reduceMotion()) { scheduleStep() }
        present()
    }

    private func schedulePauseWake(at until: Date, now current: Date) {
        guard pauseWakeAt != until else { return }
        pauseWake?.cancel()
        pauseWakeAt = until
        pauseWake = scheduler.schedule(after: max(1, until.timeIntervalSince(current) + 0.5)) { [weak self] in
            self?.pauseWake = nil
            self?.pauseWakeAt = nil
            self?.refresh()
        }
    }

    private func present() {
        guard machine.frame != shown else { return }
        shown = machine.frame
        show(shown)
    }
}

/// Puts frames on `NSDockTile`: `normal` is `contentView = nil` (the system-rendered bundle
/// icon, the user's icon style respected); `dim` / `lit` are pre-rendered 8-bit bitmaps
/// (`DockTileArt`) in one image view, drawn only while the tile needs them and released when it
/// is normal again. `display()` only when the frame changes (the controller calls this then).
@MainActor
final class DockTileRenderer {
    private let tile: NSDockTile
    private var view: NSImageView?
    private var images: [DockTileFrame: NSImage] = [:]

    init(tile: NSDockTile) { self.tile = tile }

    func show(_ frame: DockTileFrame) {
        guard frame != .normal else {
            guard tile.contentView != nil || view != nil else { return }
            tile.contentView = nil
            view = nil
            images = [:]
            tile.display()
            return
        }
        guard let image = images[frame] ?? DockTileArt.image(frame) else { return }
        images[frame] = image
        let view = self.view ?? {
            let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            view.imageScaling = .scaleProportionallyUpOrDown
            view.imageFrameStyle = .none
            view.autoresizingMask = [.width, .height]
            self.view = view
            return view
        }()
        view.image = image
        if tile.contentView !== view { tile.contentView = view }
        tile.display()
    }
}
