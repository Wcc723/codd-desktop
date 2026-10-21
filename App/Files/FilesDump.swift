import Foundation
import CoddFiles

/// The `files` key of the state dump (§6): the current workspace's root, git facts, the AI
/// touches, the tabs (with their encoding, EOL, language, SHOW AI CHANGES, baseline and hunks)
/// and the banner. Never file contents.
@MainActor
enum FilesDump {
    static func object(_ service: FileEditorService, mode: NotesMode, dirtySheet: String?) -> [String: Any] {
        var out: [String: Any] = ["shown": mode == .files, "workspaces": service.workspaces.map(\.rootPath), "saves": service.saveCount]
        if let save = service.lastSave {
            out["lastSave"] = ["path": save.path, "ok": save.ok, "error": save.error.map { $0 as Any } ?? NSNull()]
        }
        if let open = service.lastOpen {
            out["lastOpen"] = ["path": open.path, "ms": (open.ms * 10).rounded() / 10, "bytes": open.bytes]
        }
        out["lastRefusal"] = service.lastRefusal.map { $0 as Any } ?? NSNull()
        out["dirtySheet"] = dirtySheet.map { $0 as Any } ?? NSNull()
        guard let workspace = service.current else {
            out["root"] = NSNull()
            return out
        }
        out["root"] = workspace.rootPath
        out["repo"] = workspace.isRepo
        out["gitLoaded"] = workspace.gitLoaded
        out["gitRuns"] = workspace.gitRuns
        out["gitStatusMs"] = workspace.gitStatusMs.map { ($0 * 10).rounded() / 10 as Any } ?? NSNull()
        out["branch"] = workspace.status?.branch.map { $0 as Any } ?? NSNull()
        out["ahead"] = workspace.status?.ahead ?? 0
        out["behind"] = workspace.status?.behind ?? 0
        out["modified"] = workspace.changedPaths
        out["ignored"] = workspace.ignored.sorted()
        out["aiTouched"] = workspace.touches.keys.sorted().map { path -> [String: Any] in
            let touch = workspace.touches[path]
            return ["path": path, "session": touch?.session ?? "", "tool": touch?.tool ?? ""]
        }
        out["expanded"] = workspace.expanded.sorted()
        out["filter"] = ["text": workspace.filter, "results": Array(workspace.filterResults.prefix(10)), "index": workspace.filterIndex]
        out["session"] = service.session(for: workspace).map { $0.id as Any } ?? NSNull()
        out["selected"] = workspace.selectedTabID.map { $0 as Any } ?? NSNull()
        out["tabs"] = workspace.tabs.map { tab(service, $0) }
        if let banner = service.bannerModel() {
            var object: [String: Any] = ["title": banner.title, "unsaved": banner.showsUnsaved, "canReload": banner.canReload]
            object["session"] = service.selectedTab?.state?.pendingDisk?.aiSession ?? NSNull()
            out["banner"] = object
        } else {
            out["banner"] = NSNull()
        }
        return out
    }

    static func tab(_ service: FileEditorService, _ tab: FileTab) -> [String: Any] {
        var object: [String: Any] = ["id": tab.id, "title": tab.title, "preview": tab.isPreview, "dirty": tab.isDirty,
                                     "note": tab.noteID != nil, "showAI": tab.showAI, "baseline": tab.baseline.rawValue,
                                     "line": tab.caret.line, "column": tab.caret.column]
        object["path"] = tab.url.map { $0.path as Any } ?? NSNull()
        object["failure"] = tab.failure.map { $0 as Any } ?? NSNull()
        if let state = tab.state {
            let decoded = state.decoded
            object["encoding"] = decoded.encoding.rawValue
            object["eol"] = decoded.lineEnding.rawValue + (decoded.mixedLineEndings ? "*" : "")
            object["finalNewline"] = decoded.hasFinalNewline
            object["readOnly"] = decoded.readOnly
            object["plain"] = tab.plainMode
            object["bytes"] = state.disk.size
            object["hash"] = String(state.disk.sha256.prefix(12))
            object["banner"] = state.pendingDisk != nil
            object["aiBaseline"] = state.aiBaseline.map { ["session": $0.session ?? "", "at": ISO8601DateFormatter().string(from: $0.at)] as Any }
                ?? NSNull()
        }
        object["language"] = tab.language.rawValue
        object["indentation"] = tab.state.map { indentation($0.decoded.indentation) as Any } ?? NSNull()
        object["hunks"] = tab.hunks.enumerated().map { index, hunk -> [String: Any] in
            ["index": index, "range": LineDiff.unifiedHeader(hunk), "removed": hunk.oldLines.count, "added": hunk.newLines.count,
             "accepted": tab.accepted.contains(FileTab.hunkKey(hunk, baseline: tab.hunksBaseline))]
        }
        object["diffRuns"] = tab.diffRuns
        if let query = tab.findQuery {
            object["find"] = ["query": query, "current": tab.findCount?.current ?? 0, "total": tab.findCount?.total ?? 0]
        }
        return object
    }

    static func indentation(_ value: Indentation) -> String {
        switch value {
        case .spaces(let n): "spaces:\(n)"
        case .tabs: "tabs"
        case .unknown: "unknown"
        }
    }

    /// What the dump shows, as one string (the dump loop rewrites it when this changes).
    static func signature(_ service: FileEditorService) -> String {
        guard let workspace = service.current else { return "none|\(service.saveCount)" }
        let tabs = workspace.tabs.map { tab in
            "\(tab.id):\(tab.isPreview):\(tab.isDirty):\(tab.showAI):\(tab.baseline.rawValue):\(tab.hunks.count):\(tab.accepted.count)"
                + ":\(tab.state?.pendingDisk?.aiSession ?? "-"):\(tab.state?.pendingDisk != nil):\(tab.state?.disk.sha256 ?? "-")"
                + ":\(tab.findCount?.total ?? -2):\(tab.diffRuns):\(tab.failure ?? "")"
        }.joined(separator: ",")
        return "\(workspace.rootPath)|\(workspace.status?.branch ?? "-")|\(workspace.changedPaths.count)|\(workspace.touches.count)|"
            + "\(workspace.gitRuns)|\(workspace.selectedTabID ?? "-")|\(tabs)|\(service.saveCount)|\(service.lastRefusal ?? "")|"
            + "\(workspace.filter)|\(workspace.filterResults.count)"
    }
}
