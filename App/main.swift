import AppKit

/// `CoddApplication` first, so `NSApp` is it (background launches never activate and keep their
/// windows behind other apps, see `AppActivation` and `BackgroundWindows`).
let app = CoddApplication.shared

/// Hosted unit tests load into this process; they need the module, not the UI.
let isHostingUnitTests = ProcessInfo.processInfo.environment.keys.contains { key in
    key == "XCTestConfigurationFilePath" || key == "XCTestSessionIdentifier" || key == "XCTestBundlePath"
}

if isHostingUnitTests {
    app.setActivationPolicy(.prohibited)
    // Tests order windows front too (the hover card, sheets, panels): they stay behind every other
    // app like a background run's (「不要跳到幕前干擾我」).
    BackgroundWindows.install(log: HolderSessionStore.printLog)
    app.run()
} else {
    #if DEBUG
    if let refusal = RealModeOptions.standardRootRefusal(options: .current, environment: ProcessInfo.processInfo.environment) {
        FileHandle.standardError.write(Data((refusal + "\n").utf8))
        exit(64)
    }
    #endif
    // Before the delegate builds any window: a background run keeps them all behind other apps.
    if AppActivation.isBackground { BackgroundWindows.install(log: HolderSessionStore.printLog) }
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(AppActivation.isBackground ? .accessory : .regular)
    app.run()
}
