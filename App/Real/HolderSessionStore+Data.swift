import AppKit
import CoddDataStore

/// M5 D14: the data preflight's issues as problem banners.
extension HolderSessionStore {
    /// One preflight issue, or a store's own move found by the post-load aside sweep, as a queued
    /// banner (for every session; `[在 Finder 中顯示]` for a file moved aside).
    func queueDataIssue(_ issue: DataIssue) {
        let reveal = issue.kind == .corrupt ? issue.aside.map { root.path + "/" + $0 } : nil
        queueProblem(StoreProblem(message: issue.message, at: clock.now(), sessionID: nil, revealPath: reveal))
    }

    /// `[在 Finder 中顯示]`: the moved file in Finder, on the user's click only. A background run
    /// (scripts, agents, tests) never reveals anything (D39): it logs and skips.
    func revealProblemFile() {
        guard let path = problem?.revealPath else { return }
        let name = (path as NSString).lastPathComponent
        guard !AppActivation.isBackground else {
            log("data reveal skipped (background run) file=\(name)")
            return
        }
        log("data reveal file=\(name)")
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
