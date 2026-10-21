import AppKit
import CoddCleanupUI
import CoddCore
import CoddNotebookUI
import CoddNotes
import CoddPreferences
import CoddTextKit
import CoddUI

/// Maps the retention candidates (D31) onto C12's `CleanupPageModel`: the row texts the engines
/// formatted (`stale 21d`, `最後開啟 9/24`, `resume expires 4d`), the kind / project chips, the
/// badge tones of the artboard, the POLICY card from Settings › 清理, and the meta rule
/// (`每週一 09:00 · 15 項 · 上次 10/08`). Pure apart from reading main-actor view models.
@MainActor
struct CleanupPresenter {
    let notebook: NotebookPresenter
    let resolve: (String) -> String
    /// Active notes by id (kind, project, title of the candidates).
    let notes: [NoteID: NoteSummary]
    /// A CODD session, archived ones included.
    let session: (String) -> SessionVM?
    let project: (ProjectID) -> ProjectVM?

    /// D31: SESSIONS have no 移到垃圾桶 and no condense; FILES no condense, and nothing to archive.
    static let bulkDisabled: [CleanupTab: Set<String>] = [
        .sessions: [CleanupBulkAction.trash, CleanupBulkAction.condense],
        .files: [CleanupBulkAction.archive, CleanupBulkAction.condense],
    ]

    static let fileActions = [CleanupRowAction.keep, CleanupRowAction.trash]

    // MARK: Rows

    func noteRow(_ c: NoteCleanupCandidate) -> CleanupRow {
        let m = notes[c.id]?.metadata
        return CleanupRow(id: c.id.rawValue, title: m?.title ?? c.title, chips: noteChips(m), why: c.why, sub: c.sub, badge: c.badge,
                   badgeTone: Self.tone(badge: c.badge), aiHint: Self.aiHint(c))
    }

    func noteChips(_ m: NoteMetadata?) -> [CleanupChip] {
        guard let m else { return [] }
        let kind: CleanupChip
        switch m.kind {
        case .note: kind = .kind("NOTE")
        case .scratch: kind = .kind("SCRATCH", dashed: true)
        case .prompt: kind = m.isPromptDraft ? .kind("PROMPT · 草稿", tone: .amber, dashed: true) : .kind("PROMPT", tone: .amber)
        }
        return [kind, projectChip(m.primaryProject)]
    }

    func projectChip(_ path: String?) -> CleanupChip {
        guard let path, !path.isEmpty else { return .faint("未連結專案") }
        let info = notebook.projectInfo(path, resolve: resolve)
        return .project(info.name, color: info.tag?.color)
    }

    func sessionRow(_ c: SessionCleanupCandidate) -> CleanupRow {
        let id = c.id.uuidString.lowercased()
        let s = session(id)
        var chips: [CleanupChip] = []
        if let s { chips.append(.kind(s.state == .exited ? "EXITED" : "STOPPED")) }
        chips.append(projectChip(s.flatMap { project($0.projectID)?.cwd }))
        return CleanupRow(id: id, title: s?.title ?? "session", chips: chips, why: c.why, sub: c.sub, badge: c.badge,
                          badgeTone: Self.tone(badge: c.badge))
    }

    func fileRow(_ f: RetentionService.FileCandidate) -> CleanupRow {
        switch f {
        case .image(let c, _):
            let m = notes[c.id]?.metadata
            return CleanupRow(id: f.id, title: c.why, chips: [.kind("IMAGE"), projectChip(m?.primaryProject)],
                              why: "筆記與保留的版本都沒有引用", sub: c.sub, badge: c.badge, actions: Self.fileActions)
        case .ring(let c):
            let s = session(c.id.uuidString.lowercased())
            let owner = s.map { "「\($0.title)」的終端機紀錄" } ?? "session 的終端機紀錄"
            return CleanupRow(id: f.id, title: c.why, chips: [.kind("LOG"), projectChip(s.flatMap { project($0.projectID)?.cwd })],
                              why: c.sub, sub: owner, badge: c.badge, badgeTone: .amber, actions: Self.fileActions)
        case .recent(let r):
            return CleanupRow(id: f.id, title: "最近開啟 · " + (r.path as NSString).lastPathComponent,
                              chips: [.kind("FILE"), projectChip(r.root.isEmpty ? nil : r.root)],
                              why: "檔案已不存在", sub: PathFormat.abbreviateHome(r.path), badge: "missing", actions: Self.fileActions)
        }
    }

    /// The artboard's tones: an archive within a day and `resume expires` / `deletes in` amber,
    /// `dup` cyan, the rest plain.
    static func tone(badge: String) -> ChipKind {
        if badge.hasPrefix("dup ") { return .cyan }
        if badge.hasPrefix("resume expires") || badge.hasPrefix("deletes in") { return .amber }
        if badge.hasPrefix("archives in "), let days = Int(badge.dropFirst("archives in ".count).prefix { $0.isNumber }), days <= 1 {
            return .amber
        }
        return .plain
    }

    static func aiHint(_ c: NoteCleanupCandidate) -> CleanupAIHint {
        switch c.aiHint {
        case .keep?: .keep(c.aiHintText ?? c.aiHint?.text ?? "")
        case .condense?: .condense(c.aiHintText ?? "適合濃縮")
        case .read?: .read(c.aiHintText ?? c.aiHint?.text ?? "")
        case nil: .none
        }
    }

    // MARK: Page parts

    /// `每週一 09:00 · 15 項 · 上次 10/08`.
    static func meta(_ prefs: CoddPreferences, total: Int, lastShownAt: Date?, calendar: Calendar) -> String {
        var text = CleanupDigest.scheduleText(prefs.cleanup.digest) + " · \(total) 項"
        if let last = lastShownAt {
            let p = calendar.dateComponents([.month, .day], from: last)
            text += String(format: " · 上次 %02d/%02d", p.month ?? 0, p.day ?? 0)
        }
        return text
    }

    /// POLICY · 保留規則 from Settings › 清理 (the artboard's texts with the user's values).
    static func policy(_ prefs: CoddPreferences) -> CleanupPolicyModel {
        let c = prefs.cleanup
        func days(_ value: Int?) -> String? { value.map { "\($0)d" } }
        let lifecycle = [
            CleanupPolicyStep(name: "Active", sub: "編輯、開啟、送出都算活動"),
            CleanupPolicyStep(name: "Stale", detail: days(c.notesStaleDays) ?? "—", sub: c.notesStaleDays == nil ? "不標示" : "變暗 · 仍可搜尋"),
            CleanupPolicyStep(name: "Archive", detail: days(c.notesArchiveDays) ?? "—",
                              sub: c.notesArchiveDays == nil ? "不自動封存" : "MCP 預設不列出 · 可還原"),
            CleanupPolicyStep(name: "Trash", sub: "只有你能丟"),
            CleanupPolicyStep(name: "Purge", detail: "\(c.trashPurgeDays)d", sub: c.tombstoneDays.map { "tombstone \($0) 天" } ?? "tombstone 永久"),
        ]
        let scratch = c.scratchArchiveDays.map { "\($0) 天後封存 · 含已送出 prompt" } ?? "不自動封存"
        var sessions: [String] = []
        sessions.append(c.sessionsStaleDays.map { "停止 \($0) 天 → stale" } ?? "不標示 stale")
        sessions.append(c.sessionsArchiveDays.map { "\($0) 天 → 封存" } ?? "不自動封存")
        let logs = c.scrollbackDeleteDays.map { "終端機紀錄封存 \($0) 天後刪除" } ?? "終端機紀錄不自動刪除"
        let rules = [
            CleanupPolicyRule(term: "Scratch", text: scratch),
            CleanupPolicyRule(term: "豁免", text: c.exempt ? "釘選 · 使用中 session 的筆記" : "關閉"),
            CleanupPolicyRule(term: "提醒", text: CleanupDigest.ruleText(c.digest)),
            CleanupPolicyRule(term: "濃縮", text: "手動 · 原稿只封存不刪除"),
            CleanupPolicyRule(term: "Sessions", text: sessions.joined(separator: " · ")),
            CleanupPolicyRule(term: "Logs", text: logs),
        ]
        return CleanupPolicyModel(lifecycle: lifecycle, rules: rules)
    }

    // MARK: Condense card

    /// The CONDENSE · PREVIEW card for `runner`'s sources.
    static func condense(_ runner: CondenseRunner, notebook: NotebookPresenter, resolve: (String) -> String, notes: [NoteID: NoteSummary],
                         longSections: [NoteID: Int], accounts: [CondenseAccountOption], account: String, accountTitle: String,
                         accountHint: String, model: String, elapsed: String, now: Date, timeZone: TimeZone) -> CondenseModel {
        let sources = runner.sources.map { s -> CondenseSource in
            let label = s.oldSectionsOnly ? "（舊段落 \(s.oldSections ?? longSections[s.id] ?? 0) 段）" : ""
            let kind = s.kind == .prompt ? "PROMPT" : (s.kind == .scratch ? "SCRATCH" : "NOTE")
            let tag = s.project.flatMap { notebook.projectInfo($0, resolve: resolve).tag?.color }
            return CondenseSource(title: s.title + label, kind: kind, tagColor: tag)
        }
        var models = CoddPreferences.Cleanup.condenseModelOptions
        if !models.contains(model) { models.append(model) }
        let state: CondenseState
        var preview: NSAttributedString?
        switch runner.phase {
        case .idle: state = .idle
        case .running: state = .running(elapsed: elapsed)
        case .preview(let output):
            state = .preview
            preview = previewText(output)
        case .failed(let reason): state = .failed(reason)
        }
        return CondenseModel(
            title: "濃縮 \(runner.sources.count) 則 → 1 則摘要", sources: sources, accountTitle: "\(accountTitle) · \(model)",
            accounts: accounts, models: models, selectedAccountID: account, selectedModel: model, accountHint: accountHint,
            previewRef: "codd://note/\(CondenseRunner.idPrefix(now: now, timeZone: timeZone))-…", preview: preview, state: state,
            disabledReason: runner.unavailableReason())
    }

    /// The summary as the read-only renderer draws it, at the card's 11 pt.
    static func previewText(_ markdown: String) -> NSAttributedString {
        MarkdownRender.attributedPreview(markdown, style: MarkdownEditorStyle.notebook.scaled(by: 0.8), maxLines: nil)
    }
}
