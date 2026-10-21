import AppKit

/// A view that shows elapsed-time labels (updated once per second while visible).
@MainActor
public protocol SecondTicking: AnyObject {
    var window: NSWindow? { get }
    func secondTick(now: Date)
}

/// A view with a pulsing lamp. The pulse itself is a Core Animation animation run by the
/// render server; the ticker only tells pulsing views when "Reduce motion" changes.
@MainActor
public protocol PulseSubscriber: AnyObject {
    func motionPreferenceChanged()
}

/// The app's only periodic UI work: one 1 Hz clock for elapsed labels. It runs only while at
/// least one subscriber is actually showing: its window is on screen (not occluded, app not
/// hidden) and, for views, neither the view nor an ancestor is hidden (e.g. the collapsed
/// sidebar in focus mode). A hidden app has zero timers (idle-CPU budget, ARCHITECTURE.md).
///
/// Waiting lamps do NOT use a timer: each pulses with a committed `CAAnimation` (research
/// ui.md §1), so the main thread does no work per pulse. Measured: a 2 Hz main-thread pulse
/// clock cost ~0.33 % CPU of a 0.5 % visible-idle budget. The ticker keeps the "Reduce motion"
/// preference (helmet `prefers-reduced-motion`) and notifies pulsing views when it changes.
@MainActor
public final class UITicker {
    public static let shared = UITicker()

    public var clock = DisplayClock()

    private let secondSubscribers = NSHashTable<AnyObject>.weakObjects()
    private let pulseSubscribers = NSHashTable<AnyObject>.weakObjects()
    private var secondTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let windowIsVisible: @MainActor (NSWindow) -> Bool
    private let reduceMotion: @MainActor () -> Bool

    public var isSecondTimerRunning: Bool { secondTimer != nil }
    /// Views currently pulsing (tests / self-test).
    public var pulseSubscriberCount: Int { pulseSubscribers.allObjects.count }

    /// - Parameters:
    ///   - windowIsVisible: whether a window is on screen (injectable for tests).
    ///   - reduceMotion: the system "Reduce motion" setting (injectable for tests).
    public init(windowIsVisible: @escaping @MainActor (NSWindow) -> Bool = UITicker.isOnScreen,
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.windowIsVisible = windowIsVisible
        self.reduceMotion = reduceMotion
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification,
                                          NSApplication.didHideNotification, NSApplication.didUnhideNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTimers() }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.motionPreferenceChanged() }
        })
    }

    // MARK: 1 Hz subscriptions

    public func addSecond(_ subscriber: SecondTicking) {
        guard !secondSubscribers.contains(subscriber) else { return }
        secondSubscribers.add(subscriber)
        updateTimers()
    }

    public func removeSecond(_ subscriber: SecondTicking) {
        guard secondSubscribers.contains(subscriber) else { return }
        secondSubscribers.remove(subscriber)
        updateTimers()
    }

    /// Re-evaluates the 1 Hz clock. Call when a subscriber moved between windows or was
    /// hidden / shown (window occlusion and app hide are observed here).
    public func updateTimers() {
        let needSecond = secondSubscribers.allObjects.contains { isShowing($0, window: ($0 as? SecondTicking)?.window) }
        if needSecond, secondTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.fireSecond() }
            }
            timer.tolerance = 0.1
            RunLoop.main.add(timer, forMode: .common)
            secondTimer = timer
        } else if !needSecond, let timer = secondTimer {
            timer.invalidate()
            secondTimer = nil
        }
    }

    // Casts start from the stored `AnyObject` (not from a protocol existential): the Swift 6.4
    // optimizer crashed (SILBuilder createCheckedCastBranch assertion) when it inlined an
    // existential → AnyObject → NSView cast chain here in Release builds.
    private func fireSecond() {
        let now = clock.now()
        for object in secondSubscribers.allObjects {
            guard let subscriber = object as? SecondTicking, isShowing(object, window: subscriber.window) else { continue }
            subscriber.secondTick(now: now)
        }
    }

    /// On screen and, for views, not hidden by itself or an ancestor.
    @inline(never)
    private func isShowing(_ subscriber: AnyObject, window: NSWindow?) -> Bool {
        guard let window, windowIsVisible(window) else { return false }
        if let view = subscriber as? NSView, view.isHiddenOrHasHiddenAncestor { return false }
        return true
    }

    // MARK: Pulsing views

    /// False while reduced motion applies (lamps stay lit, no animation): the app's own choice
    /// when it made one (`motionOverride`), else the system setting.
    public var pulsesAllowed: Bool { !(motionOverride ?? reduceMotion()) }

    /// The app's Settings › 外觀 › 減少動態 (M3): nil follows the system, true always reduces,
    /// false always animates. Pulsing views are told when it changes.
    public var motionOverride: Bool? {
        didSet { if motionOverride != oldValue { motionPreferenceChanged() } }
    }

    public func addPulse(_ subscriber: PulseSubscriber) { pulseSubscribers.add(subscriber) }
    public func removePulse(_ subscriber: PulseSubscriber) { pulseSubscribers.remove(subscriber) }

    private func motionPreferenceChanged() {
        for object in pulseSubscribers.allObjects { (object as? PulseSubscriber)?.motionPreferenceChanged() }
    }

    // MARK: Visibility

    /// Default visibility: ordered in, not occluded, app not hidden.
    public static func isOnScreen(_ window: NSWindow) -> Bool {
        #if DEBUG
        // Measurement aid (`-CODDForceVisibleTimers YES`): treat on-screen windows as visible
        // even when the display is asleep or locked, so the timer cost can be measured.
        if forceVisible { return window.isVisible && !NSApp.isHidden }
        #endif
        return window.isVisible && window.occlusionState.contains(.visible) && !NSApp.isHidden
    }

    #if DEBUG
    /// `-CODDForceVisibleTimers YES`; the App also sets it for `-codd-force-render YES` (M5 D17).
    public static var forceVisible = UserDefaults.standard.bool(forKey: "CODDForceVisibleTimers")
    #endif
}
