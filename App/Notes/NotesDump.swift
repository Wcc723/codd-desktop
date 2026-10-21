import CoddNotes
import Foundation

/// The state dump's core `notes` key (M4 §6, I1a part): `{root, available, reason?, index {rebuilt,
/// reason, count, buildMs}, counts {inbox, pinned, prompts, stale, archive, trash, byProject},
/// list {name, ids}, selected {id, title, kind, ai, scope, pinned, status, dirty, mode, caret,
/// hash} | null, search {query, ids, ms} | null, lastPaste {asset, resized, bytes} | null,
/// externalEvents, externalReloads, banner, saves, quickNote {id, kind} | null, mode, rebuild}`, and
/// (I1b) `history {id, count, ids}`, `activity {id, last[{at, action, client, via}]}`, `copyRef {form,
/// text, chars, target}` (the URL token masked), `annotate {open, id, image, items, lastDone}`,
/// `lastAction {kind, id, ok, error}`, and (I2b) `lastSend {attempts, last {action, note, session,
/// outcome, bytes, paste, at}}`. Ids, counts and file names only: never a note's text,
/// never a token.
@MainActor
enum NotesDump {
    static func object(service: NotesService, editor: NoteEditorController?, mode: NotesMode,
                       area: NotesAreaViewController? = nil) -> [String: Any] {
        var out: [String: Any] = ["root": service.notesRoot.path, "available": service.availability.isReady, "mode": mode.rawValue]
        switch service.availability {
        case .closed: out["state"] = "closed"
        case .loading: out["state"] = "loading"
        case .ready: out["state"] = "ready"
        case .unavailable(let reason): out["state"] = "unavailable"; out["reason"] = reason
        }
        if let report = service.openReport {
            out["index"] = index(report)
        } else {
            out["index"] = NSNull()
        }
        out["rebuild"] = service.lastRebuild.map(index) ?? NSNull()
        let c = service.counts
        out["counts"] = ["inbox": c.inbox, "pinned": c.pinned, "prompts": c.prompts, "stale": c.stale, "archive": c.archive,
                         "trash": c.trash, "byProject": c.byProject]
        out["list"] = ["name": listName(service.list), "ids": service.rows.map(\.id.rawValue)]
        if let search = service.search, !service.searchText.isEmpty {
            out["search"] = ["query": search.query, "ids": search.hits.map(\.summary.id.rawValue),
                             "ms": (search.ms * 100).rounded() / 100] as [String: Any]
        } else {
            out["search"] = NSNull()
        }
        if let paste = service.lastPaste {
            out["lastPaste"] = ["asset": paste.asset, "resized": paste.resized, "bytes": paste.bytes, "reused": paste.reused]
        } else {
            out["lastPaste"] = NSNull()
        }
        out["externalEvents"] = service.externalEvents
        if let quick = service.quickNote {
            out["quickNote"] = ["id": quick.id?.rawValue as Any? ?? NSNull(), "kind": quick.kind.rawValue]
        } else {
            out["quickNote"] = NSNull()
        }
        out["selected"] = editor.map(selected) ?? NSNull()
        if let editor {
            out["externalReloads"] = editor.externalReloads
            out["banner"] = editor.diskConflict != nil
            out["saves"] = editor.saveCount
            out["openMs"] = editor.lastOpenMs.map { ($0 * 10).rounded() / 10 } as Any? ?? NSNull()
        }
        features(service: service, area: area, into: &out)
        return out
    }

    /// The I1b keys.
    private static func features(service: NotesService, area: NotesAreaViewController?, into out: inout [String: Any]) {
        if let selected = service.selected {
            let id = selected.document.metadata.id.rawValue
            out["history"] = ["id": id, "count": selected.history.count, "ids": selected.history.map(\.id),
                              "reasons": selected.history.map { $0.reason ?? "" }] as [String: Any]
            let iso = ISO8601DateFormatter()
            out["activity"] = ["id": id, "last": selected.activity.prefix(5).map { event in
                ["at": iso.string(from: event.at), "action": event.action, "client": event.client as Any? ?? NSNull(), "via": event.via]
                    as [String: Any]
            }] as [String: Any]
        } else {
            out["history"] = NSNull()
            out["activity"] = NSNull()
        }
        guard let area else { return }
        // I2b (D14): the last send (ids, sizes and the outcome; never the text).
        out["lastSend"] = area.sending?.dumpObject ?? NSNull()
        if let copy = area.lastCopyRef {
            out["copyRef"] = ["form": copy.form, "text": copy.text, "chars": copy.chars, "target": copy.target] as [String: Any]
        } else {
            out["copyRef"] = NSNull()
        }
        var annotate: [String: Any] = ["open": area.annotateSession != nil]
        if let session = area.annotateSession {
            annotate["id"] = session.noteID.rawValue
            annotate["image"] = session.blockImage
            annotate["items"] = session.screen.document.items.count
            annotate["status"] = session.modeView.statusBar.modeTexts
        }
        if let done = area.lastAnnotate {
            annotate["lastDone"] = ["id": done.id, "image": done.asset, "items": done.items,
                                    "annotatedPNG": done.annotatedPNG as Any? ?? NSNull()] as [String: Any]
        }
        out["annotate"] = annotate
        if let action = area.lastAction {
            out["lastAction"] = ["kind": action.kind, "id": action.id, "ok": action.ok, "error": action.error as Any? ?? NSNull()]
                as [String: Any]
        } else {
            out["lastAction"] = NSNull()
        }
        if let menu = area.chrome.presentedMenu { out["menu"] = menu.rawValue }
    }

    private static func index(_ report: NotesOpenReport) -> [String: Any] {
        ["rebuilt": report.rebuilt, "reason": report.reason as Any? ?? NSNull(), "count": report.count,
         "buildMs": (report.buildMs * 10).rounded() / 10, "warnings": report.warnings.count]
    }

    static func listName(_ list: SmartList) -> String {
        switch list {
        case .inbox: "inbox"
        case .pinned: "pinned"
        case .prompts: "prompts"
        case .stale: "stale"
        case .archive: "archive"
        case .trash: "trash"
        case .project(let path): "project:" + path
        }
    }

    private static func selected(_ editor: NoteEditorController) -> Any {
        guard editor.hasContent else { return NSNull() }
        let m = editor.document?.metadata
        var out: [String: Any] = [
            "id": editor.noteID?.rawValue as Any? ?? NSNull(),
            "title": m?.title ?? NoteDraft.title(of: editor.text) ?? editor.draft?.title ?? "",
            "kind": (m?.kind ?? editor.draft?.kind ?? .note).rawValue,
            "dirty": editor.isDirty,
            "mode": editor.mode == .source ? "source" : "live",
            "caret": ["line": editor.caret.line, "column": editor.caret.column],
            "hash": editor.baseHash as Any? ?? NSNull(),
            "draft": editor.draft != nil,
            "file": editor.document?.fileURL.lastPathComponent as Any? ?? NSNull(),
        ]
        if let m {
            out["ai"] = m.ai.rawValue
            out["scope"] = m.scope.rawValue
            out["pinned"] = m.pinned
            out["status"] = m.state.status
            out["sessions"] = m.links.sessions
            out["projects"] = m.links.projects
            out["tags"] = m.tags
        }
        return out
    }
}
