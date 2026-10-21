import AppKit
import Darwin
import Testing
@testable import CODD

/// Automated launches must never take the user's keyboard focus (see `AppActivation`).
@Suite("Background launches")
struct AppActivationTests {
    @Test func explicitFlagWins() {
        #expect(AppActivation.resolve(arguments: ["CODD", "-codd-background"], environment: [:]))
        #expect(AppActivation.resolve(arguments: ["CODD", "-codd-background", "YES"], environment: [:]))
        #expect(AppActivation.resolve(arguments: ["CODD", "-codd-background", "-codd-mock"], environment: [:]),
                "a bare flag followed by another flag means YES")
        #expect(!AppActivation.resolve(arguments: ["CODD", "-codd-background", "NO", "-codd-data-root", "/tmp/x"],
                                       environment: ["CLAUDECODE": "1"]))
        #expect(AppActivation.resolve(arguments: ["CODD"], environment: ["CODD_BACKGROUND": "1"]))
        #expect(!AppActivation.resolve(arguments: ["CODD"], environment: ["CODD_BACKGROUND": "0", "CLAUDECODE": "1"]))
    }

    @Test func debugDefaultsToBackgroundForAutomatedLaunches() {
        #expect(AppActivation.resolve(arguments: ["CODD"], environment: ["CLAUDECODE": "1"]))
        #expect(AppActivation.resolve(arguments: ["CODD", "-codd-data-root", "/tmp/x"], environment: [:]))
        #expect(AppActivation.resolve(arguments: ["CODD"], environment: ["CODD_DATA_ROOT": "/tmp/x"]))
        #expect(!AppActivation.resolve(arguments: ["CODD"], environment: [:]), "a plain launch from Finder or the Dock")
        #expect(!AppActivation.resolve(arguments: ["CODD", "-codd-mock"], environment: [:]))
    }

    @Test func agentLaunchesNeverUseTheStandardRoot() {
        func refused(_ arguments: [String], _ environment: [String: String]) -> Bool {
            let options = RealModeOptions.parse(arguments: ["CODD"] + arguments, environment: environment, home: "/Users/x")
            return RealModeOptions.standardRootRefusal(options: options, environment: environment) != nil
        }
        let agent = ["CLAUDECODE": "1"]
        #expect(refused([], agent))
        #expect(refused(["-codd-mock YES -codd-data-root /tmp/x"], agent), "a whole argument list passed as one word")
        #expect(!refused(["-codd-data-root", "/tmp/x"], agent))
        #expect(!refused([], agent.merging(["CODD_DATA_ROOT": "/tmp/x"]) { $1 }))
        #expect(!refused(["-codd-mock"], agent))
        #expect(!refused([], agent.merging(["CFFIXED_USER_HOME": "/tmp/home"]) { $1 }))
        #expect(!refused([], agent.merging(["CODD_ALLOW_STANDARD_ROOT": "1"]) { $1 }))
        #expect(!refused([], [:]), "a launch from Finder or a terminal of the user's own")
    }
}

/// Post-M4: background windows and the hosted test process (「不要跳到幕前干擾我」).
@Suite("Background windows (post-M4)")
@MainActor
struct BackgroundWindowsTests {
    /// `KERN_PROCARGS2` as the kernel lays it out: argc, the executable path, padding, the
    /// arguments, the environment, an empty string.
    private func procargs(_ arguments: [String], _ environment: [String]) -> [UInt8] {
        var bytes = withUnsafeBytes(of: Int32(arguments.count).littleEndian) { Array($0) }
        bytes += Array("/Applications/CODD.app/Contents/MacOS/CODD".utf8) + [0, 0, 0]
        for value in arguments + environment { bytes += Array(value.utf8) + [0] }
        return bytes + [0, 0]
    }

    /// Review dock-bg-1: the user's own CODD has the same bundle identifier; only another
    /// background run counts as CODD for the safety net, told by its flags and environment.
    @Test func onlyAnotherBackgroundRunCountsAsCODD() throws {
        let user = try #require(BackgroundWindows.parseProcessArguments(procargs(["/Applications/CODD.app/Contents/MacOS/CODD"],
                                                                                 ["HOME=/Users/x", "PATH=/usr/bin:/bin"])))
        #expect(user.arguments == ["/Applications/CODD.app/Contents/MacOS/CODD"])
        #expect(user.environment == ["HOME": "/Users/x", "PATH": "/usr/bin:/bin"])
        #expect(!AppActivation.resolve(arguments: user.arguments, environment: user.environment), "the user's CODD is another app")
        let run = try #require(BackgroundWindows.parseProcessArguments(procargs(["CODD", "-codd-data-root", "/tmp/r"], ["CODD_BACKGROUND=1"])))
        #expect(run.arguments == ["CODD", "-codd-data-root", "/tmp/r"])
        #expect(AppActivation.resolve(arguments: run.arguments, environment: run.environment))
        #expect(BackgroundWindows.parseProcessArguments([1, 0]) == nil, "too short")
        #expect(BackgroundWindows.parseProcessArguments(withUnsafeBytes(of: Int32(3).littleEndian) { Array($0) } + Array("x\0a\0".utf8)) == nil,
                "fewer arguments than argc")
        // This process, as the kernel reports it.
        let own = try #require(BackgroundWindows.launchContext(of: getpid()))
        #expect(own.arguments == ProcessInfo.processInfo.arguments)
        #expect(own.environment["HOME"] != nil)
    }

    /// The hosted test process keeps every window it orders front behind the other apps' windows
    /// (main.swift installs the hook). The probe window is transparent and click-through, so even a
    /// failure never shows anything to the user.
    @Test func hostedTestWindowsStayBehindOtherApps() {
        #expect(BackgroundWindows.isInstalled)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let me = Int(getpid())
        let onScreen = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
        guard onScreen.contains(where: { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }) else { return }
        let below = (CGWindowListCopyWindowInfo([.optionOnScreenBelowWindow], CGWindowID(window.windowNumber)) as? [[String: Any]]) ?? []
        let others = below.filter { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let pid = info[kCGWindowOwnerPID as String] as? Int, pid != me else { return false }
            let isCODD = CoddIdentity.isCODD(bundleIdentifier: NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier)
            return !(isCODD && BackgroundWindows.isBackgroundRun(pid: pid_t(pid)))
        }
        #expect(others.isEmpty, "another app's window below a test window: \(others.compactMap { $0[kCGWindowOwnerName as String] as? String })")
    }
}
