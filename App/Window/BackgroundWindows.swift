import AppKit
import ObjectiveC

/// Background runs (`AppActivation.isBackground`: scripts, agents, tests) keep every CODD window
/// behind every other app's normal windows (user, 2026-10-18: 「不要跳到幕前干擾我」). Not activating
/// is not enough: macOS puts a window an inactive app orders front directly behind the active app's
/// key window, above every other app's windows.
///
/// One hook on `NSWindow`, installed once at launch (main.swift) and only in background mode or in
/// the hosted unit-test process (tests order windows front too), so no code path can regress it,
/// AppKit's own included (sheets, alerts, child panels, dropdowns):
/// - `orderWindow(_:relativeTo:)` (what `orderFront`, `makeKeyAndOrderFront`, `showWindow`,
///   `isVisible = true` and `orderBack` end in) and `orderFrontRegardless`: an ordering to the front
///   of the level, or relative to another app's window, becomes one just above CODD's frontmost
///   window (a sheet or child window: just above its parent), or to the back of the level when no
///   CODD window shows. Orderings relative to CODD's own windows, to the back and out pass
///   unchanged, so CODD's windows keep their order among themselves, one block behind other apps.
/// - `level`: a level above `.normal` (a floating panel, a modal alert) is held at `.normal`, where
///   the ordering above applies; above it the window would float over every app. AppKit's own menu,
///   tool-tip and status-item windows (system classes at `.statusBar` and up) are left alone.
///
/// The user decides otherwise: while CODD is active (the user clicked one of its windows; CODD never
/// activates itself in background mode) or while a real mouse click into a CODD window is being
/// handled (`CoddApplication.sendEvent`: the status item, a non-activating panel), orderings run
/// unchanged and a held window gets its level back. When CODD resigns active (or unhides), its
/// windows sink behind the other apps again, in their order (`sinkAll`). Only other background CODD
/// runs count as CODD for that check; the user's own CODD (same bundle identifier) is another app.
///
/// Unchanged: drawing, `cacheDisplay` snapshots, key and main window (within CODD), child windows
/// (they stay attached above their parent), modal sessions (`runModal` runs its loop with the
/// window behind). A covered window reports itself occluded: libghostty pauses drawing while
/// terminal state and text keep updating, and `AppDelegate.isViewing` counts a background
/// window as seen.
@MainActor
enum BackgroundWindows {
    private(set) static var isInstalled = false
    /// Orderings sent behind the other apps so far, and windows the safety net put back.
    private(set) static var rewrites = 0
    private(set) static var corrections = 0
    /// Tests of this hook (outside the app) watch every ordering decision here.
    static var trace: ((String) -> Void)?

    private typealias OrderIMP = @convention(c) (NSWindow, Selector, Int, Int) -> Void
    private typealias PlainIMP = @convention(c) (NSWindow, Selector) -> Void
    private typealias LevelIMP = @convention(c) (NSWindow, Selector, Int) -> Void
    /// `id` result passed through untouched (no ARC traffic on a private method's return).
    private typealias ModalIMP = @convention(c) (NSApplication, Selector, NSWindow?, NSWindow?) -> UnsafeMutableRawPointer?

    private static let orderSelector = #selector(NSWindow.order(_:relativeTo:))
    private static let frontRegardlessSelector = #selector(NSWindow.orderFrontRegardless)
    private static let levelSelector = #selector(setter: NSWindow.level)
    /// `runModal(for:)` and `beginModalSession(for:)` order their window through this private
    /// AppKit method, past the public ones. Hooked only when it exists with this shape; without it
    /// the safety net still puts the window back once it shows.
    private static let modalSelector = NSSelectorFromString("_orderFrontModalWindow:relativeToWindow:")
    private static var originalOrder: OrderIMP?
    private static var originalFrontRegardless: PlainIMP?
    private static var originalSetLevel: LevelIMP?
    private static var originalModal: ModalIMP?
    private static var userClickDepth = 0
    /// The level a window asked for while it is held at `.normal` (given back to user orderings).
    private static let wantedLevels = NSMapTable<NSWindow, NSNumber>.weakToStrongObjects()
    private static var observers: [NSObjectProtocol] = []
    private static var log: (String) -> Void = { _ in }
    private static var lastCheck: TimeInterval = -.infinity

    /// Installs the hook (once). Call only when `AppActivation.isBackground` or when hosting unit
    /// tests, before any window.
    static func install(log: @escaping (String) -> Void) {
        guard !isInstalled else { return }
        let order: @convention(block) (NSWindow, Int, Int) -> Void = { window, place, other in
            MainActor.assumeIsolated { BackgroundWindows.order(window, place: place, relativeTo: other) }
        }
        let frontRegardless: @convention(block) (NSWindow) -> Void = { window in
            MainActor.assumeIsolated { BackgroundWindows.orderFrontRegardless(window) }
        }
        let setLevel: @convention(block) (NSWindow, Int) -> Void = { window, level in
            MainActor.assumeIsolated { BackgroundWindows.setLevel(window, level) }
        }
        guard let orderIMP = replace(orderSelector, with: order),
              let frontIMP = replace(frontRegardlessSelector, with: frontRegardless),
              let levelIMP = replace(levelSelector, with: setLevel) else {
            log("error background-windows: NSWindow ordering methods not found")
            return
        }
        originalOrder = unsafeBitCast(orderIMP, to: OrderIMP.self)
        originalFrontRegardless = unsafeBitCast(frontIMP, to: PlainIMP.self)
        originalSetLevel = unsafeBitCast(levelIMP, to: LevelIMP.self)
        isInstalled = true
        self.log = log
        if let method = class_getInstanceMethod(NSApplication.self, modalSelector),
           method_getNumberOfArguments(method) == 4,
           method_getTypeEncoding(method).map({ String(cString: $0).hasPrefix("@") }) == true {
            let modal: @convention(block) (NSApplication, NSWindow?, NSWindow?) -> UnsafeMutableRawPointer? = { app, window, relative in
                let result = MainActor.assumeIsolated { BackgroundWindows.orderFrontModal(app, window, relativeTo: relative) }
                return UnsafeMutableRawPointer(bitPattern: result)
            }
            originalModal = unsafeBitCast(method_setImplementation(method, imp_implementationWithBlock(modal)), to: ModalIMP.self)
        } else {
            log("background windows: no modal ordering hook on this macOS (the safety net covers modal windows)")
        }
        // The safety net, run synchronously where AppKit posts (queue nil). Leaving CODD and an
        // unhide always check; key, main and occlusion changes (a path past the hooks, a later
        // AppKit) check at most once a second, so nothing can make it fight another window.
        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSApplication.didUnhideNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { enforce(throttled: false) }
            })
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { enforce(throttled: true) }
            })
        }
        log("background windows: kept behind other apps' windows")
    }

    private static func replace(_ selector: Selector, with block: Any) -> IMP? {
        guard let method = class_getInstanceMethod(NSWindow.self, selector) else { return nil }
        return method_setImplementation(method, imp_implementationWithBlock(block))
    }

    // MARK: The user's own orderings

    /// A real mouse click (CODD posts no input events; a synthetic key event never counts).
    static func isUserClick(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            event.window != nil
        default: false
        }
    }

    /// Runs the dispatch of a user's click: what it opens or raises is ordered as usual.
    static func duringUserClick(_ body: () -> Void) {
        userClickDepth += 1
        defer { userClickDepth -= 1 }
        body()
    }

    private static var passesThrough: Bool { NSApp.isActive || userClickDepth > 0 }

    // MARK: Hooks

    private static func order(_ window: NSWindow, place raw: Int, relativeTo other: Int) {
        guard let original = originalOrder else { return }
        let place = NSWindow.OrderingMode(rawValue: raw) ?? .above
        if place == .out || isSystemOverlay(window) { return original(window, orderSelector, raw, other) }
        if passesThrough {
            restoreLevel(window)
            trace?("pass \(name(window)) place=\(raw) relative=\(other)")
            return original(window, orderSelector, raw, other)
        }
        holdLevel(window)
        guard let (newPlace, newOther) = target(for: window, place: place, relativeTo: other) else {
            trace?("keep \(name(window)) place=\(raw) relative=\(other)")
            return original(window, orderSelector, raw, other)
        }
        rewrites += 1
        trace?("behind \(name(window)) place=\(raw) relative=\(other) -> place=\(newPlace.rawValue) relative=\(newOther)")
        original(window, orderSelector, newPlace.rawValue, newOther)
    }

    private static func orderFrontRegardless(_ window: NSWindow) {
        guard !passesThrough, !isSystemOverlay(window) else {
            restoreLevel(window)
            trace?("pass-regardless \(name(window))")
            originalFrontRegardless?(window, frontRegardlessSelector)
            return
        }
        order(window, place: NSWindow.OrderingMode.above.rawValue, relativeTo: 0)
    }

    private static func setLevel(_ window: NSWindow, _ raw: Int) {
        guard let original = originalSetLevel else { return }
        let level = NSWindow.Level(rawValue: raw)
        if level <= .normal || passesThrough || isSystemOverlay(window, level: level) {
            wantedLevels.removeObject(forKey: window)
            return original(window, levelSelector, raw)
        }
        wantedLevels.setObject(NSNumber(value: raw), forKey: window)
        trace?("hold-level \(name(window)) wanted=\(raw)")
        original(window, levelSelector, NSWindow.Level.normal.rawValue)
    }

    /// A modal window (`runModal`): above CODD's frontmost window, not the active app's.
    private static func orderFrontModal(_ app: NSApplication, _ window: NSWindow?, relativeTo relative: NSWindow?) -> Int {
        guard let original = originalModal else { return 0 }
        guard let window, relative == nil, !passesThrough, !isSystemOverlay(window) else {
            return Int(bitPattern: original(app, modalSelector, window, relative))
        }
        // AppKit orders it front (given an anchor it leaves the window off screen); it goes behind
        // in the same call, before the window server draws a frame.
        let result = original(app, modalSelector, window, nil)
        rewrites += 1
        holdLevel(window)
        let (place, other) = target(for: window, place: .above, relativeTo: 0) ?? (.below, 0)
        trace?("modal \(name(window)) -> place=\(place.rawValue) relative=\(other)")
        originalOrder?(window, orderSelector, place.rawValue, other)
        return Int(bitPattern: result)
    }

    // MARK: Placement

    /// Where an ordering goes instead; nil when it already keeps the window behind other apps.
    private static func target(for window: NSWindow, place: NSWindow.OrderingMode,
                               relativeTo other: Int) -> (NSWindow.OrderingMode, Int)? {
        if other != 0, other != window.windowNumber, let anchor = NSApp.window(withWindowNumber: other),
           anchor.isVisible, anchor.level == window.level, !isSystemOverlay(anchor) {
            return nil
        }
        if place == .below, other == 0 { return nil }
        if let parent = window.sheetParent ?? window.parent, parent.isVisible, parent.windowNumber > 0 {
            return (.above, parent.windowNumber)
        }
        if let top = frontmostWindow(excluding: window) { return (.above, top.windowNumber) }
        return (.below, 0)
    }

    /// CODD's frontmost normal-level window on the active space other than `window` and the
    /// windows attached to it.
    private static func frontmostWindow(excluding window: NSWindow) -> NSWindow? {
        for number in NSWindow.windowNumbers(options: []) ?? [] {
            guard let candidate = NSApp.window(withWindowNumber: number.intValue), candidate !== window,
                  candidate.level == .normal, !isAttached(candidate, to: window) else { continue }
            return candidate
        }
        return nil
    }

    private static func isAttached(_ candidate: NSWindow, to window: NSWindow) -> Bool {
        var next = candidate.sheetParent ?? candidate.parent
        while let current = next {
            if current === window { return true }
            next = current.sheetParent ?? current.parent
        }
        return false
    }

    /// The safety net: when CODD's frontmost window sits above another app's normal window (the
    /// user left CODD after a click, an unhide, a path past the hooks), every window sinks.
    static func enforce(throttled: Bool) {
        guard isInstalled, !passesThrough else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if throttled, now - lastCheck < 1 { return }
        lastCheck = now
        guard isAboveAnotherApp() else { return }
        corrections += 1
        log("background windows: sunk behind other apps' windows (\(corrections))")
        sinkAll()
    }

    /// What the window server shows: another app's normal window below CODD's frontmost one.
    /// Other background CODD runs do not count (two of them would only swap places); every other
    /// process does, the user's own CODD included: it has the same bundle identifier, so a run is
    /// told by its launch flags and environment (`isBackgroundRun(pid:)`, review dock-bg-1). M5 D1:
    /// a CODD is either bundle id (`CoddIdentity.isCODD`), so a build from before the rename that
    /// runs in the background counts as CODD's own too.
    private static func isAboveAnotherApp() -> Bool {
        let own = (NSWindow.windowNumbers(options: []) ?? []).lazy.compactMap { NSApp.window(withWindowNumber: $0.intValue) }
        guard let front = own.first(where: { $0.level == .normal && !isSystemOverlay($0) }) else { return false }
        let below = (CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow], CGWindowID(front.windowNumber))
            as? [[String: Any]]) ?? []
        let me = ProcessInfo.processInfo.processIdentifier
        var isBackgroundCODD: [pid_t: Bool] = [me: true]
        for info in below where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (info[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) else { continue }
            let skip = isBackgroundCODD[pid]
                ?? (CoddIdentity.isCODD(bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
                    && isBackgroundRun(pid: pid))
            isBackgroundCODD[pid] = skip
            if !skip { return true }
        }
        return false
    }

    /// Whether process `pid` (another CODD) runs in background mode: its arguments and environment
    /// (`KERN_PROCARGS2`, readable for this user's processes) decide as `AppActivation.resolve` does.
    /// Unreadable counts as not background: the net then sinks this run, which never hurts the user.
    nonisolated static func isBackgroundRun(pid: pid_t) -> Bool {
        guard let context = launchContext(of: pid) else { return false }
        return AppActivation.resolve(arguments: context.arguments, environment: context.environment)
    }

    /// The arguments and environment a process was started with, nil when they cannot be read.
    nonisolated static func launchContext(of pid: pid_t) -> (arguments: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// `KERN_PROCARGS2`'s layout: argc (Int32), the executable path, NUL padding, argc arguments,
    /// then `KEY=value` environment strings up to an empty one.
    nonisolated static func parseProcessArguments(_ bytes: [UInt8]) -> (arguments: [String], environment: [String: String])? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        func next() -> String? {
            guard index < bytes.count else { return nil }
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let string = String(decoding: bytes[start..<index], as: UTF8.self)
            index += 1
            return string
        }
        var arguments: [String] = []
        while arguments.count < argc, let argument = next() { arguments.append(argument) }
        guard arguments.count == argc else { return nil }
        var environment: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (arguments, environment)
    }

    /// Every CODD window to the back of its level, keeping their order (front to back, each one
    /// sent behind everything; attached windows follow their parent).
    static func sinkAll() {
        guard let original = originalOrder else { return }
        for number in NSWindow.windowNumbers(options: []) ?? [] {
            guard let window = NSApp.window(withWindowNumber: number.intValue), window.parent == nil,
                  window.sheetParent == nil, !isSystemOverlay(window) else { continue }
            holdLevel(window)
            trace?("sink \(name(window))")
            original(window, orderSelector, NSWindow.OrderingMode.below.rawValue, 0)
        }
    }

    // MARK: Levels

    private static func holdLevel(_ window: NSWindow) {
        guard window.level > .normal, let original = originalSetLevel else { return }
        wantedLevels.setObject(NSNumber(value: window.level.rawValue), forKey: window)
        trace?("hold-level \(name(window)) wanted=\(window.level.rawValue)")
        original(window, levelSelector, NSWindow.Level.normal.rawValue)
    }

    private static func restoreLevel(_ window: NSWindow) {
        guard let wanted = wantedLevels.object(forKey: window), let original = originalSetLevel else { return }
        wantedLevels.removeObject(forKey: window)
        original(window, levelSelector, wanted.intValue)
    }

    /// AppKit's status-item, menu and tool-tip windows: system classes at `.statusBar` and up. A
    /// plain `NSWindow` / `NSPanel` (CODD's own code) never counts, whatever its level.
    private static func isSystemOverlay(_ window: NSWindow, level: NSWindow.Level? = nil) -> Bool {
        guard (level ?? window.level) >= .statusBar else { return false }
        let type: AnyClass = Swift.type(of: window)
        guard type != NSWindow.self, type != NSPanel.self else { return false }
        return Bundle(for: type).bundlePath.hasPrefix("/System/")
    }

    private static func name(_ window: NSWindow) -> String {
        "\(Swift.type(of: window))#\(window.windowNumber)"
    }
}
