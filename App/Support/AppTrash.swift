import Foundation

/// D38: the one function every M4 move to a system-level trash goes through (a purged note with
/// its assets and history, rings and `holder.log`, Cleanup FILES `移到垃圾桶`, and since M4 also
/// 刪除對話紀錄). The macOS Trash is used only on the standard data root; any other root (tests,
/// throwaway roots, every e2e run) moves into `-codd-trash-dir` when given, else
/// `<dataRoot>/trash/` (0700), so an automated run can never put anything into `~/.Trash`. A
/// note's own TRASH is CODD's `.codd/trash/` and never comes here.
///
/// Each move logs `trash target=system|folder name=<last component>` (never the full path: a
/// note's file name is the user's title).
struct AppTrash: Sendable {
    enum Target: Sendable, Equatable {
        case system
        case folder(String)

        /// `system` / `folder` (the log line, the dump).
        var name: String {
            switch self {
            case .system: "system"
            case .folder: "folder"
            }
        }
    }

    let target: Target
    private let log: @Sendable (String) -> Void
    /// The macOS Trash itself (tests replace it to prove it is never called off the standard root).
    private let systemTrash: @Sendable (URL) throws -> Void

    init(target: Target, log: @escaping @Sendable (String) -> Void = { _ in },
         systemTrash: @escaping @Sendable (URL) throws -> Void = AppTrash.moveToSystemTrash) {
        self.target = target
        self.log = log
        self.systemTrash = systemTrash
    }

    /// The target for a data root: `-codd-trash-dir` wins everywhere (a DEBUG run on the standard
    /// root keeps its moves too), else the macOS Trash on the standard root only, else
    /// `<dataRoot>/trash/`.
    static func target(dataRoot: CoddDataRoot, standardRoot: CoddDataRoot = .standard, trashDir: String?) -> Target {
        if let trashDir, !trashDir.isEmpty { return .folder(trashDir) }
        if dataRoot == standardRoot { return .system }
        return .folder(dataRoot.path + "/trash")
    }

    /// Moves `url` (a file or a folder) to the target.
    func move(_ url: URL) throws {
        switch target {
        case .system:
            try systemTrash(url)
        case .folder(let folder):
            try Self.move(url, into: folder)
        }
        log("trash target=\(target.name) name=\(url.lastPathComponent)")
    }

    /// As a closure (`NotesLibrary`'s `trash:`, the session store's `trash`).
    var function: @Sendable (URL) throws -> Void {
        let trash = self
        return { url in try trash.move(url) }
    }

    nonisolated static func moveToSystemTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Into `folder` (0700, created when missing); a taken name gets ` 2`, ` 3`, … like the Trash.
    nonisolated static func move(_ url: URL, into folder: String) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = url.lastPathComponent
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        var target = base.appendingPathComponent(name)
        var n = 2
        while manager.fileExists(atPath: target.path) {
            target = base.appendingPathComponent("\(name) \(n)")
            n += 1
        }
        try manager.moveItem(at: url, to: target)
    }
}
