import AppKit
import CoddDataStore

/// M5 I1: the data preflight and its banners (D14), the launch-to-sidebar line (D16) and the
/// dump keys `bundle` and `dataFiles` (§5).
extension AppDelegate {
    // MARK: Data preflight (D14)

    /// First thing in real mode's start task, before any store reads its file: older files are
    /// migrated after a backup, newer ones left alone, corrupt USER DATA moved aside, corrupt
    /// DERIVED data removed, `cache/` wiped when its VERSION differs. Every issue becomes a
    /// queued problem banner (one at a time).
    func runDataPreflight(_ holders: HolderSessionStore) async {
        await dataFiles.runPreflight(root: holders.root.url) { [weak holders] in holders?.queueDataIssue($0) }
    }

    /// After the stores loaded (sessions, notes, accounts, the first retention run): the stores'
    /// own `<name>.corrupt-<ms>` moves of this launch get the same corrupt banner.
    func sweepAsideFiles(_ holders: HolderSessionStore) async {
        let since = LaunchTiming.processStart() ?? launchDate
        await dataFiles.sweep(root: holders.root.url, since: since) { [weak holders] in holders?.queueDataIssue($0) }
        #if DEBUG
        scheduleStateDump()
        #endif
    }

    // MARK: Launch to sidebar (D16)

    /// `perf launch-to-sidebar ms=<n> rows=<n>`, once, when the sidebar first shows the loaded
    /// layout (real mode: when the store installed it, `HolderSessionStore.onLoaded`; mock mode:
    /// the first turn after the window showed), counted from the kernel's process start. Every build.
    func logLaunchToSidebar() {
        guard !launchToSidebarLogged, let main = mainWindow, let window = main.window else { return }
        launchToSidebarLogged = true
        // The structure loop would apply the loaded layout on a later turn; do it now (a no-op
        // then) and draw it, so the time is that of the rows on screen.
        main.sidebar.apply(main.sidebar.buildSnapshot())
        if window.isVisible {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        guard let start = LaunchTiming.processStart() else { return }
        HolderSessionStore.printLog(LaunchTiming.launchToSidebarLine(milliseconds: Date().timeIntervalSince(start) * 1000,
                                                                     rows: main.sidebar.outline.numberOfRows))
    }

    // MARK: Dump (§5)

    /// `bundle {id, version, build, legacyDefaultsMigrated, legacyDefaults, autosavesLayout}`.
    var bundleDump: [String: Any] {
        ["id": CoddIdentity.runningBundleIdentifier, "version": CoddIdentity.version, "build": CoddIdentity.build,
         "legacyDefaultsMigrated": legacyDefaults.legacyDefaultsMigrated.map { $0 as Any } ?? NSNull(),
         "legacyDefaults": legacyDefaults.key, "autosavesLayout": autosavesLayout]
    }

    /// `dataFiles` (see `DataFilesMonitor.dump`).
    var dataFilesDump: [String: Any] {
        dataFiles.dump(bannersShown: holderStore?.queuedProblemsShown.count ?? 0,
                       bannersQueued: holderStore?.problemQueue.count ?? 0)
    }
}
