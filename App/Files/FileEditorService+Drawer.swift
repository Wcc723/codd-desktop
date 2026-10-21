import CoddFiles
import CoddNotebookUI
import Foundation

/// The session drawer's `AI 改過的檔案 · n  vs HEAD` (D26, Split artboard): the files this session
/// touched (newest first, with `AI HH:mm`), then the other git-modified files of its cwd without a
/// chip, at most 8. Built only while the drawer shows; git runs read-only (names only) and only
/// when the cwd is a repository.
extension FileEditorService {
    static let drawerFileLimit = 8

    func drawerSection(for id: SessionID) async -> NotesDrawerFilesSection? {
        guard let session = store.session(id), !session.external, session.kind == .claude,
              let project = store.project(session.projectID) else { return nil }
        let cwd = URL(fileURLWithPath: rootForCwd(project.cwd), isDirectory: true).standardizedFileURL
        let since = clock().addingTimeInterval(-AITouchLog.retention)
        let touchLog = self.touchLog
        let key = id.lowercased()
        let touched = await Task.detached(priority: .utility) { () -> [AITouch] in
            (touchLog?.touches(under: cwd, since: since) ?? []).filter { $0.session.lowercased() == key }
        }.value
        let scratch = FilesWorkspace(root: cwd)
        var changes: [String: GitFileChange] = [:]
        if let repo = await git.repoRoot(for: cwd), let status = try? await git.status(root: repo) {
            scratch.gitPrefix = Self.prefix(of: scratch, in: repo)
            for (path, change) in status.changes {
                if let relative = scratch.rootRelative(gitPath: path) { changes[relative] = change }
            }
        }
        var rows: [NotesDrawerFile] = []
        var seen = Set<String>()
        for touch in touched {
            guard let relative = scratch.relativePath(touch.path), !relative.isEmpty, seen.insert(relative).inserted else { continue }
            rows.append(Self.drawerRow(scratch, relative: relative, change: changes[relative], chip: "AI \(hourMinute(touch.at))"))
        }
        for relative in changes.keys.sorted() where !seen.contains(relative) {
            seen.insert(relative)
            rows.append(Self.drawerRow(scratch, relative: relative, change: changes[relative], chip: nil))
        }
        guard !rows.isEmpty else { return nil }
        let shown = Array(rows.prefix(Self.drawerFileLimit))
        return NotesDrawerFilesSection(count: shown.count, files: shown, aiTag: NotebookPresenter.tag(session.tag))
    }

    /// `punch.vue  M  AI 10:41` / `src/pages/`; the id is the file's absolute path.
    static func drawerRow(_ workspace: FilesWorkspace, relative: String, change: GitFileChange?, chip: String?) -> NotesDrawerFile {
        let folder = (relative as NSString).deletingLastPathComponent
        return NotesDrawerFile(id: workspace.url(of: relative).path, name: (relative as NSString).lastPathComponent,
                               status: change?.letter, aiChip: chip, directory: folder.isEmpty ? "./" : folder + "/")
    }
}

extension GitFileChange {
    /// The one-letter badge (`M`, `A`, `D`, `R`, `C`, `U`, `!`, `T`).
    var letter: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "U"
        case .conflicted: "!"
        case .typeChanged: "T"
        }
    }
}
